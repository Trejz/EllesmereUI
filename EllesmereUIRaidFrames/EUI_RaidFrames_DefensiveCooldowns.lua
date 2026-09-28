if EUI_CLIENT_BLOCKED then return end

-------------------------------------------------------------------------------
-- EUI_RaidFrames_DefensiveCooldowns.lua
-- Displays the defensive and active-mitigation spell set for each group member.
-- Cooldowns for other players are inferred from observed casts; WoW does not
-- expose their live spell cooldown state to addons.
-------------------------------------------------------------------------------

local _, ns = ...
local addon = EllesmereUIRaidFrames

local TRACKER = {}
ns.RF_DefensiveCooldowns = TRACKER

local ICON_SIZE = 18
local ICON_GAP = 1
local ROW_HEIGHT = 22
local MAX_ROWS = 40
local UPDATE_INTERVAL = 0.25

local spellInfo = {}
local spellOrder = {}
local guidState = {}
local unitByGUID = {}
local buttonHosts = setmetatable({}, { __mode = "k" })
local overviewRows = {}
local elapsedSinceUpdate = 0
local overview
local initialized = false

local function GetProfile()
    local db = ns.db
    local profile = db and db.profile
    profile.defensiveCooldowns = profile.defensiveCooldowns or {}
    return profile.defensiveCooldowns
end

local function BuildSpellList()
    if #spellOrder > 0 then return end
    local presets = EllesmereUI.BUFF_PRESETS and EllesmereUI.BUFF_PRESETS.spells
    if not presets then return end

    local seen = {}
    for _, presetName in ipairs({ "defensives", "activemitigation" }) do
        for spellID, data in pairs(presets[presetName] or {}) do
            if not seen[spellID] then
                seen[spellID] = true
                spellOrder[#spellOrder + 1] = spellID
                spellInfo[spellID] = {
                    class = data.class,
                    primary = spellID,
                    cooldown = nil,
                }
            end
            for _, alternateID in ipairs(data.alts or {}) do
                spellInfo[alternateID] = {
                    class = data.class,
                    primary = spellID,
                    cooldown = nil,
                }
            end
        end
    end
    table.sort(spellOrder)
end

local function GetSpellTexture(spellID)
    if C_Spell and C_Spell.GetSpellTexture then
        return C_Spell.GetSpellTexture(spellID) or 136243
    end
    return _G.GetSpellTexture and _G.GetSpellTexture(spellID) or 136243
end

local function GetBaseCooldown(spellID)
    local info = spellInfo[spellID]
    if info and info.cooldown ~= nil then return info.cooldown end
    local duration
    if GetSpellBaseCooldown then
        local value = GetSpellBaseCooldown(spellID)
        duration = value and value > 0 and value / 1000 or nil
    end
    if info then info.cooldown = duration end
    return duration
end

local function IsSpellForClass(spellID, class)
    local info = spellInfo[spellID]
    return info and (not info.class or info.class == "ALL" or info.class == class)
end

local function ResolvePrimary(spellID)
    local info = spellInfo[spellID]
    return info and info.primary or spellID
end

local function GetState(guid, spellID)
    local state = guidState[guid]
    return state and state[ResolvePrimary(spellID)]
end

local function EnsureState(guid, spellID)
    guidState[guid] = guidState[guid] or {}
    local primary = ResolvePrimary(spellID)
    guidState[guid][primary] = guidState[guid][primary] or {}
    return guidState[guid][primary]
end

local function BuildIcon(parent, spellID)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(ICON_SIZE, ICON_SIZE)

    local texture = frame:CreateTexture(nil, "ARTWORK")
    texture:SetAllPoints()
    texture:SetTexture(GetSpellTexture(spellID))
    texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    frame.texture = texture

    local cooldown = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
    cooldown:SetAllPoints()
    cooldown:SetDrawEdge(false)
    cooldown:SetHideCountdownNumbers(true)
    cooldown:SetReverse(true)
    frame.cooldown = cooldown

    local border = frame:CreateTexture(nil, "OVERLAY")
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetColorTexture(0.05, 0.82, 0.62, 0)
    frame.border = border

    frame.spellID = spellID
    return frame
end

local function ApplyIcon(frame, guid, spellID, now)
    local state = GetState(guid, spellID)
    local remaining = state and state.endsAt and state.endsAt - now or 0
    if remaining > 0 and state.duration then
        frame.cooldown:SetCooldown(state.startedAt, state.duration)
        frame.texture:SetDesaturated(true)
    else
        frame.cooldown:SetCooldown(0, 0)
        frame.texture:SetDesaturated(false)
    end
    frame.border:SetAlpha(state and state.active and 1 or 0)
end

local function GetUnitClass(unit)
    local _, class = UnitClass(unit)
    return class
end

local function BuildUnitMap()
    wipe(unitByGUID)
    local units = { "player" }
    for i = 1, 4 do units[#units + 1] = "party" .. i end
    for i = 1, 40 do units[#units + 1] = "raid" .. i end
    for i = 1, #units do
        local unit = units[i]
        local guid = UnitGUID(unit)
        if guid then unitByGUID[guid] = unit end
    end
end

local function ConfigureButton(button, unit, now)
    local class = GetUnitClass(unit)
    local host = buttonHosts[button]
    if not host then
        host = CreateFrame("Frame", nil, button)
        host:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
        host:SetSize(1, ICON_SIZE)
        host:SetFrameLevel(100)
        buttonHosts[button] = host
    end

    local x = 0
    for i = 1, #spellOrder do
        local spellID = spellOrder[i]
        if IsSpellForClass(spellID, class) then
            host.icons = host.icons or {}
            local icon = host.icons[spellID]
            if not icon then
                icon = BuildIcon(host, spellID)
                host.icons[spellID] = icon
            end
            icon:ClearAllPoints()
            icon:SetPoint("LEFT", host, "LEFT", x, 0)
            icon:Show()
            ApplyIcon(icon, UnitGUID(unit), spellID, now)
            x = x + ICON_SIZE + ICON_GAP
        end
    end
    host:SetWidth(math.max(1, x))
    host:SetShown(x > 0 and GetProfile().showOnFrames ~= false and button:IsShown())
end

local function GetButtonUnit(button)
    return button:GetAttribute("unit") or button._fbUnit
end

local function RefreshButtons(now)
    local buttons = ns._allButtons or {}
    for i = 1, #buttons do
        local button = buttons[i]
        local unit = button and GetButtonUnit(button)
        if button and unit and UnitExists(unit) then
            ConfigureButton(button, unit, now)
        elseif buttonHosts[button] then
            buttonHosts[button]:Hide()
        end
    end
end

local function CreateOverviewRow(index)
    local row = CreateFrame("Frame", nil, overview)
    row:SetSize(overview:GetWidth() - 12, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", overview, "TOPLEFT", 6, -6 - (index - 1) * ROW_HEIGHT)

    local name = row:CreateFontString(nil, "OVERLAY")
    name:SetPoint("LEFT", row, "LEFT")
    name:SetWidth(100)
    name:SetJustifyH("LEFT")
    name:SetFont((EllesmereUI.GetFontPath and EllesmereUI.GetFontPath("raidFrames")) or STANDARD_TEXT_FONT, 10, "")
    row.name = name
    row.icons = {}
    return row
end

local function ApplyOverviewRow(row, unit, now)
    local class = GetUnitClass(unit)
    local guid = UnitGUID(unit)
    row.name:SetText(UnitName(unit) or unit)
    local x = 108
    local index = 0
    for i = 1, #spellOrder do
        local spellID = spellOrder[i]
        if IsSpellForClass(spellID, class) then
            index = index + 1
            local icon = row.icons[spellID]
            if not icon then
                icon = BuildIcon(row, spellID)
                row.icons[spellID] = icon
            end
            icon:ClearAllPoints()
            icon:SetPoint("LEFT", row, "LEFT", x, 0)
            icon:Show()
            ApplyIcon(icon, guid, spellID, now)
            x = x + ICON_SIZE + ICON_GAP
        end
    end
    for spellID, icon in pairs(row.icons) do
        if not IsSpellForClass(spellID, class) then icon:Hide() end
    end
    row:Show()
end

local function RefreshOverview(now)
    if not overview then return end
    local profile = GetProfile()
    overview:SetShown(profile.showOverview ~= false)
    if not overview:IsShown() then return end

    BuildUnitMap()
    local index = 0
    local units = { "player" }
    for i = 1, 4 do units[#units + 1] = "party" .. i end
    for i = 1, 40 do units[#units + 1] = "raid" .. i end
    for i = 1, #units do
        if UnitExists(units[i]) then
            index = index + 1
            overviewRows[index] = overviewRows[index] or CreateOverviewRow(index)
            ApplyOverviewRow(overviewRows[index], units[i], now)
        end
    end
    for i = index + 1, #overviewRows do overviewRows[i]:Hide() end
    overview:SetHeight(math.max(34, 12 + index * ROW_HEIGHT))
end

local function RefreshAll()
    local now = GetTime()
    RefreshButtons(now)
    RefreshOverview(now)
end

local function RecordCast(sourceGUID, spellID)
    local info = spellInfo[spellID]
    if not info then return end
    local duration = GetBaseCooldown(spellID)
    local state = EnsureState(sourceGUID, spellID)
    state.startedAt = GetTime()
    state.duration = duration
    state.endsAt = duration and state.startedAt + duration or nil
    state.active = true
end

local function HandleAura(sourceGUID, spellID, active)
    if not spellInfo[spellID] then return end
    local state = EnsureState(sourceGUID, spellID)
    state.active = active
end

local function OnCombatLog()
    local _, event, _, sourceGUID, _, _, _, destGUID, _, _, _, spellID = CombatLogGetCurrentEventInfo()
    if event == "SPELL_CAST_SUCCESS" then
        RecordCast(sourceGUID, spellID)
    elseif event == "SPELL_AURA_APPLIED" or event == "SPELL_AURA_REFRESH" then
        HandleAura(destGUID, spellID, true)
    elseif event == "SPELL_AURA_REMOVED" then
        HandleAura(destGUID, spellID, false)
    end
    RefreshAll()
end

local function InitializeOverview()
    overview = CreateFrame("Frame", "EUIRaidDefensiveCooldowns", UIParent)
    overview:SetSize(440, 40)
    overview:SetPoint("CENTER", UIParent, "CENTER", 0, -180)
    overview:SetFrameStrata("HIGH")
    overview:SetMovable(true)
    overview:EnableMouse(true)
    overview:RegisterForDrag("LeftButton")
    overview:SetScript("OnDragStart", overview.StartMoving)
    overview:SetScript("OnDragStop", function(frame)
        frame:StopMovingOrSizing()
        local left, bottom = frame:GetLeft(), frame:GetBottom()
        local scale = UIParent:GetEffectiveScale()
        local profile = GetProfile()
        profile.overviewPosition = { x = left * scale, y = bottom * scale }
    end)
    local profile = GetProfile()
    if profile.overviewPosition then
        local position = profile.overviewPosition
        overview:ClearAllPoints()
        overview:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", position.x / UIParent:GetEffectiveScale(), position.y / UIParent:GetEffectiveScale())
    end
    local background = overview:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(0, 0, 0, 0.55)
    overview.background = background
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
eventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        BuildSpellList()
        InitializeOverview()
        initialized = true
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        if initialized then OnCombatLog() end
        return
    end
    if initialized then
        BuildUnitMap()
        RefreshAll()
    end
end)

eventFrame:SetScript("OnUpdate", function(_, elapsed)
    if not initialized then return end
    elapsedSinceUpdate = elapsedSinceUpdate + elapsed
    if elapsedSinceUpdate < UPDATE_INTERVAL then return end
    elapsedSinceUpdate = 0
    RefreshAll()
end)