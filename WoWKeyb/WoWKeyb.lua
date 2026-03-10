--[[
    WoWKeyb Addon
    Apply keybinding profiles from WoWKeyb (wowkeyb.gg)
    Usage: /wowkeyb or /wk
]]

local addonName, WoWKeyb = ...
WoWKeyb.addonName = addonName
local BLIZZARD_DEFAULT_PROFILE = "Blizzard Default"
local MINIMAP_LDB_NAME = "WoWKeyb"
local SHARE_CODE_PREFIX = "WK1:"
local ENABLE_LIVE_SLOT_SYNC = false
WoWKeyb.isApplyingProfile = false

local function getAddonVersion()
    local version = nil
    if C_AddOns and type(C_AddOns.GetAddOnMetadata) == "function" then
        version = C_AddOns.GetAddOnMetadata(addonName, "Version")
        if (not version or version == "") then
            version = C_AddOns.GetAddOnMetadata("WoWKeyb", "Version")
        end
    end
    if (not version or version == "") and type(GetAddOnMetadata) == "function" then
        version = GetAddOnMetadata(addonName, "Version")
        if (not version or version == "") then
            version = GetAddOnMetadata("WoWKeyb", "Version")
        end
    end
    if not version or version == "" then
        return "unknown"
    end
    return tostring(version)
end

local function addonChat(message)
    if DEFAULT_CHAT_FRAME and type(DEFAULT_CHAT_FRAME.AddMessage) == "function" then
        DEFAULT_CHAT_FRAME:AddMessage(tostring(message or ""))
        return
    end
    print(tostring(message or ""))
end

-- Default saved variables
local function ensureDBDefaults()
    if type(WoWKeybDB) ~= "table" then
        WoWKeybDB = {}
    end
    WoWKeybDB.profiles = WoWKeybDB.profiles or {}
    if WoWKeybDB.lastApplied == nil then WoWKeybDB.lastApplied = nil end
    if WoWKeybDB.currentProfile == nil then WoWKeybDB.currentProfile = BLIZZARD_DEFAULT_PROFILE end
    if WoWKeybDB.previousProfile == nil then WoWKeybDB.previousProfile = nil end
    if WoWKeybDB.customBarsUnlocked == nil then
        WoWKeybDB.customBarsUnlocked = false
    end
    if type(WoWKeybDB.customBarPositions) ~= "table" then
        WoWKeybDB.customBarPositions = {}
    end
    if type(WoWKeybDB.minimap) ~= "table" then
        WoWKeybDB.minimap = {}
    end
    if type(WoWKeybDB.preferredProfileByContext) ~= "table" then
        WoWKeybDB.preferredProfileByContext = {}
    end
    if WoWKeybDB.debugApplySlots == nil then
        WoWKeybDB.debugApplySlots = false
    end
    if WoWKeybDB.debugViewerSlots == nil then
        WoWKeybDB.debugViewerSlots = false
    end
    if WoWKeybDB.minimap.hide == nil then WoWKeybDB.minimap.hide = false end
    if WoWKeybDB.minimap.minimapPos == nil then
        WoWKeybDB.minimap.minimapPos = tonumber(WoWKeybDB.minimap.angle) or 225
    end
    WoWKeybDB.minimap.angle = nil
end

local function buildCurrentPlayerContextKey()
    local function normalizeContextValue(value)
        if not value then return nil end
        local normalized = tostring(value):lower():gsub("[%s%-%_]", "")
        if normalized == "" then return nil end
        return normalized
    end

    local _, englishClass, classToken = UnitClass("player")
    local classValue = normalizeContextValue(englishClass or classToken) or "unknown"

    local specPart = "none"
    local specIndex = GetSpecialization and GetSpecialization() or nil
    if specIndex and GetSpecializationInfo then
        local specId, specName = GetSpecializationInfo(specIndex)
        specPart = tostring(specId or normalizeContextValue(specName) or "none")
    end

    local heroPart = "none"
    if C_ClassTalents and type(C_ClassTalents.GetActiveHeroTalentSpec) == "function" then
        local okHero, activeHeroId = pcall(C_ClassTalents.GetActiveHeroTalentSpec)
        if okHero and activeHeroId then
            heroPart = tostring(activeHeroId)
        end
    end

    return classValue .. "|" .. specPart .. "|" .. heroPart
end

local function setPreferredProfileForCurrentContext(profileName)
    ensureDBDefaults()
    if not profileName or profileName == "" or profileName == BLIZZARD_DEFAULT_PROFILE then
        return
    end
    WoWKeybDB.preferredProfileByContext[buildCurrentPlayerContextKey()] = profileName
end

local function getPreferredProfileForCurrentContext()
    ensureDBDefaults()
    return WoWKeybDB.preferredProfileByContext[buildCurrentPlayerContextKey()]
end

ensureDBDefaults()

-- WoW uses hyphen for modifiers (SHIFT-1), WoWKeyb uses plus (SHIFT+1)
local function toWoWKeyFormat(key)
    if not key or key == "" then return nil end
    return key:gsub("%+", "-"):upper()
end

-- Normalize key for grouping (multiple spells can share a key - we use first only)
local function normalizeKey(key)
    if not key then return nil end
    local normalized = tostring(key):upper()
    normalized = normalized:gsub("%s*%+%s*", "-")
    normalized = normalized:gsub("%s+", "-")
    normalized = normalized:gsub("%-+", "-")
    normalized = normalized:gsub("^%-", "")
    normalized = normalized:gsub("%-$", "")
    normalized = normalized:gsub("SHFIT%-", "SHIFT-")
    normalized = normalized:gsub("SHFT%-", "SHIFT-")
    normalized = normalized:gsub("CONTROL%-", "CTRL-")
    normalized = normalized:gsub("CNTRL%-", "CTRL-")
    -- Expand shorthand modifier aliases often seen in compact displays:
    -- S+5 -> SHIFT-5, C+S+5 -> CTRL-SHIFT-5, A+1 -> ALT-1
    local parts = {}
    for part in normalized:gmatch("[^-]+") do
        parts[#parts + 1] = part
    end
    if #parts > 1 then
        for i = 1, (#parts - 1) do
            if parts[i] == "S" then
                parts[i] = "SHIFT"
            elseif parts[i] == "C" then
                parts[i] = "CTRL"
            elseif parts[i] == "A" then
                parts[i] = "ALT"
            end
        end
        normalized = table.concat(parts, "-")
    end
    -- Support symbol shorthand often used for shifted numbers.
    local shiftedNumberBySymbol = {
        ["!"] = "1", ["@"] = "2", ["#"] = "3", ["$"] = "4", ["%"] = "5",
        ["^"] = "6", ["&"] = "7", ["*"] = "8", ["("] = "9", [")"] = "0",
    }
    local shiftedNumber = shiftedNumberBySymbol[normalized]
    if shiftedNumber then
        normalized = "SHIFT-" .. shiftedNumber
    end
    return normalized
end

local function normalizeClassName(value)
    if not value then return nil end
    local normalized = tostring(value):lower():gsub("[%s%-%_]", "")
    if normalized == "" then return nil end
    return normalized
end

local function addUniqueLabel(list, seen, value)
    if value == nil then return end
    local str = tostring(value)
    if str == "" then return end
    if seen[str] then return end
    seen[str] = true
    list[#list + 1] = str
end

local function buildPlayerLabelCollection()
    local labels = {
        class = { variants = {}, _seen = {} },
        spec = { variants = {}, names = {}, ids = {}, _seenVariants = {}, _seenNames = {}, _seenIds = {} },
        hero = { variants = {}, names = {}, ids = {}, _seenVariants = {}, _seenNames = {}, _seenIds = {} },
    }

    local localizedClass, englishClass, classToken = UnitClass("player")
    addUniqueLabel(labels.class.variants, labels.class._seen, localizedClass)
    addUniqueLabel(labels.class.variants, labels.class._seen, englishClass)
    addUniqueLabel(labels.class.variants, labels.class._seen, classToken)

    local currentSpecId = nil
    local currentSpecName = nil
    local specIndex = GetSpecialization and GetSpecialization() or nil
    if specIndex and GetSpecializationInfo then
        local specId, specName = GetSpecializationInfo(specIndex)
        currentSpecId = specId
        currentSpecName = specName
        addUniqueLabel(labels.spec.ids, labels.spec._seenIds, specId)
        addUniqueLabel(labels.spec.names, labels.spec._seenNames, specName)
        addUniqueLabel(labels.spec.variants, labels.spec._seenVariants, specName)
        addUniqueLabel(labels.spec.variants, labels.spec._seenVariants, specId)

        -- Backward-compatible variants used by older profile encodings.
        addUniqueLabel(labels.spec.variants, labels.spec._seenVariants, tostring(specName or "") .. tostring(englishClass or ""))
        addUniqueLabel(labels.spec.variants, labels.spec._seenVariants, tostring(englishClass or "") .. tostring(specName or ""))
    end

    local configId = nil
    if C_ClassTalents and type(C_ClassTalents.GetActiveConfigID) == "function" then
        local okConfig, activeConfigId = pcall(C_ClassTalents.GetActiveConfigID)
        if okConfig then
            configId = activeConfigId
        end
    end

    local function addHeroDetails(heroSubTreeId)
        if not heroSubTreeId then return end
        addUniqueLabel(labels.hero.ids, labels.hero._seenIds, heroSubTreeId)
        addUniqueLabel(labels.hero.variants, labels.hero._seenVariants, heroSubTreeId)

        if configId and C_Traits and type(C_Traits.GetSubTreeInfo) == "function" then
            local okSubTree, subTreeInfo = pcall(C_Traits.GetSubTreeInfo, configId, heroSubTreeId)
            if okSubTree and type(subTreeInfo) == "table" then
                addUniqueLabel(labels.hero.names, labels.hero._seenNames, subTreeInfo.name)
                addUniqueLabel(labels.hero.names, labels.hero._seenNames, subTreeInfo.description)
                addUniqueLabel(labels.hero.variants, labels.hero._seenVariants, subTreeInfo.name)
                addUniqueLabel(labels.hero.variants, labels.hero._seenVariants, subTreeInfo.description)
            end
        end

        if C_ClassTalents and type(C_ClassTalents.GetHeroTalentSpecInfo) == "function" then
            local okInfo, heroInfo = pcall(C_ClassTalents.GetHeroTalentSpecInfo, heroSubTreeId)
            if okInfo and type(heroInfo) == "table" then
                addUniqueLabel(labels.hero.names, labels.hero._seenNames, heroInfo.name)
                addUniqueLabel(labels.hero.names, labels.hero._seenNames, heroInfo.heroTalentName)
                addUniqueLabel(labels.hero.variants, labels.hero._seenVariants, heroInfo.name)
                addUniqueLabel(labels.hero.variants, labels.hero._seenVariants, heroInfo.heroTalentName)
            end
        end
    end

    if C_ClassTalents and type(C_ClassTalents.GetActiveHeroTalentSpec) == "function" then
        local okHero, activeHeroId = pcall(C_ClassTalents.GetActiveHeroTalentSpec)
        if okHero and activeHeroId then
            addHeroDetails(activeHeroId)
        end
    end

    if C_ClassTalents and type(C_ClassTalents.GetHeroTalentSpecsForClassSpec) == "function" then
        local okHeroOptions, heroSubTreeIds = pcall(C_ClassTalents.GetHeroTalentSpecsForClassSpec, configId, currentSpecId)
        if okHeroOptions and type(heroSubTreeIds) == "table" then
            for _, heroSubTreeId in ipairs(heroSubTreeIds) do
                addHeroDetails(heroSubTreeId)
            end
        end
    end

    labels.class._seen = nil
    labels.spec._seenVariants = nil
    labels.spec._seenNames = nil
    labels.spec._seenIds = nil
    labels.hero._seenVariants = nil
    labels.hero._seenNames = nil
    labels.hero._seenIds = nil

    return labels
end

local function profileMatchesCurrentClass(profile, debugLabel)
    if not profile then return true end

    local profileClass = normalizeClassName(profile.class)
    if not profileClass then
        -- Backward compatibility for older profiles that did not include class.
        if debugLabel then
            print("|cffffcc00[WoWKeyb]|r [match-debug:" .. tostring(debugLabel) .. "] profile.class is empty; class check skipped")
        end
        return true
    end

    local labelCollection = buildPlayerLabelCollection()
    local playerVariants = {}
    for _, variant in ipairs(labelCollection.class.variants) do
        playerVariants[#playerVariants + 1] = normalizeClassName(variant)
    end

    for _, variant in ipairs(playerVariants) do
        if variant and variant == profileClass then
            if debugLabel then
                print("|cffffcc00[WoWKeyb]|r [match-debug:" .. tostring(debugLabel) .. "] profile.class=" .. tostring(profile.class)
                    .. " player variants=" .. table.concat(playerVariants, ", ") .. " class match=true")
            end
            return true
        end
    end
    if debugLabel then
        print("|cffffcc00[WoWKeyb]|r [match-debug:" .. tostring(debugLabel) .. "] profile.class=" .. tostring(profile.class)
            .. " player variants=" .. table.concat(playerVariants, ", ") .. " class match=false")
    end
    return false
end

local function profileValueMatchesCandidates(profileValue, candidates, classVariants)
    if not profileValue then
        return true, false
    end
    if type(candidates) ~= "table" or #candidates == 0 then
        -- Fail open when runtime data is unavailable to avoid hiding valid profiles.
        return true, false
    end

    local function startsWith(str, prefix)
        if not str or not prefix then return false end
        return str:sub(1, #prefix) == prefix
    end

    local normalizedClassTokens = {}
    if type(classVariants) == "table" then
        local seen = {}
        for _, classVariant in ipairs(classVariants) do
            local token = normalizeClassName(classVariant)
            if token and token ~= "" and not seen[token] then
                seen[token] = true
                normalizedClassTokens[#normalizedClassTokens + 1] = token
            end
        end
    end

    local function stripClassTokens(value)
        local normalized = normalizeClassName(value)
        if not normalized or normalized == "" then
            return nil
        end
        local changed = true
        while changed do
            changed = false
            for _, token in ipairs(normalizedClassTokens) do
                if token ~= "" and normalized ~= token then
                    if startsWith(normalized, token) then
                        normalized = normalized:sub(#token + 1)
                        changed = true
                    elseif normalized:sub(-#token) == token then
                        normalized = normalized:sub(1, #normalized - #token)
                        changed = true
                    end
                end
            end
        end
        if normalized == "" then
            return nil
        end
        return normalized
    end

    local pv = normalizeClassName(profileValue)
    if not pv then
        return true, false
    end
    local pvStripped = stripClassTokens(profileValue)

    local profileHasLetters = pv:match("%a") ~= nil
    local hasAnyTextCandidate = false
    for _, candidate in ipairs(candidates) do
        local cv = normalizeClassName(candidate)
        if cv and cv ~= "" and cv:match("%a") then
            hasAnyTextCandidate = true
            break
        end
    end

    -- Some client/build combinations only return hero numeric IDs (e.g. "50")
    -- without a hero talent name. Avoid false-negative mismatches in that case.
    if profileHasLetters and not hasAnyTextCandidate then
        return true, true
    end

    for _, candidate in ipairs(candidates) do
        local cv = normalizeClassName(candidate)
        if cv and cv ~= "" then
            if pv == cv then
                return true, false
            end
            local cvStripped = stripClassTokens(candidate)
            if pvStripped and cvStripped and pvStripped == cvStripped then
                return true, false
            end
            -- Limited prefix fallback for abbreviations (e.g. ret/retribution).
            if pvStripped and cvStripped and #pvStripped >= 3 and #cvStripped >= 3
                and (startsWith(pvStripped, cvStripped) or startsWith(cvStripped, pvStripped)) then
                return true, false
            end
        end
    end

    return false, false
end

local function getProfileMatchDiagnostics(profile)
    local labels = buildPlayerLabelCollection()
    local diagnostics = {
        classOk = true,
        specOk = true,
        heroOk = true,
        matches = true,
        reasons = {},
        reasonSummary = "match",
    }

    local profileClass = normalizeClassName(profile and profile.class)
    if profileClass then
        diagnostics.classOk = false
        for _, variant in ipairs(labels.class.variants) do
            local candidate = normalizeClassName(variant)
            if candidate and candidate == profileClass then
                diagnostics.classOk = true
                break
            end
        end
        if not diagnostics.classOk then
            diagnostics.reasons[#diagnostics.reasons + 1] = string.format(
                "Class mismatch (profile: %s, player: %s)",
                tostring(profile.class or "unknown"),
                table.concat(labels.class.variants, ", ")
            )
        end
    end

    local profileSpec = profile and (profile.spec or profile.spec_id or profile.specId or profile.specialization) or nil
    local specOk, skippedSpecStrictText = profileValueMatchesCandidates(profileSpec, labels.spec.variants, labels.class.variants)
    diagnostics.specOk = specOk
    if not diagnostics.specOk then
        diagnostics.reasons[#diagnostics.reasons + 1] = string.format(
            "Spec mismatch (profile: %s, player variants: %s)",
            tostring(profileSpec or "unknown"),
            table.concat(labels.spec.variants, ", ")
        )
    elseif skippedSpecStrictText then
        diagnostics.reasons[#diagnostics.reasons + 1] = "Spec match used numeric-only fallback"
    end

    local profileHero = profile and (profile.heroTalent or profile.hero_talent or profile.hero_talent_id or profile.heroTalentId) or nil
    local heroOk, skippedHeroStrictText = profileValueMatchesCandidates(profileHero, labels.hero.variants, labels.class.variants)
    diagnostics.heroOk = heroOk
    if not diagnostics.heroOk then
        diagnostics.reasons[#diagnostics.reasons + 1] = string.format(
            "Hero mismatch (profile: %s, player variants: %s)",
            tostring(profileHero or "unknown"),
            table.concat(labels.hero.variants, ", ")
        )
    elseif skippedHeroStrictText then
        diagnostics.reasons[#diagnostics.reasons + 1] = "Hero match used numeric-only fallback"
    end

    diagnostics.matches = diagnostics.classOk and diagnostics.specOk and diagnostics.heroOk
    if diagnostics.matches then
        diagnostics.reasonSummary = "match"
    else
        local parts = {}
        if not diagnostics.classOk then parts[#parts + 1] = "class" end
        if not diagnostics.specOk then parts[#parts + 1] = "spec" end
        if not diagnostics.heroOk then parts[#parts + 1] = "hero" end
        diagnostics.reasonSummary = table.concat(parts, "/")
    end

    return diagnostics
end

local function getProfileContextSummary(profile)
    if type(profile) ~= "table" then
        return "Unknown / - / -"
    end
    local classValue = tostring(profile.class or "Unknown")
    local specValue = tostring(profile.spec or profile.spec_id or profile.specId or profile.specialization or "-")
    local heroValue = tostring(profile.heroTalent or profile.hero_talent or profile.hero_talent_id or profile.heroTalentId or "-")
    return string.format("%s / %s / %s", classValue, specValue, heroValue)
end

local function profileMatchesCurrentSpecAndHero(profile, debugLabel)
    if not profile then return true end
    local debug = debugLabel ~= nil
    local debugLines = {}
    local function appendDebug(line)
        if debug then
            debugLines[#debugLines + 1] = tostring(line)
        end
    end
    local labelCollection = buildPlayerLabelCollection()

    local profileSpecRaw = profile.spec or profile.spec_id or profile.specId or profile.specialization
    local profileSpec = normalizeClassName(profileSpecRaw)
    if profileSpec then
        local currentSpecVariants = labelCollection.spec.variants
        appendDebug("profile.spec=" .. tostring(profileSpecRaw))
        appendDebug("current spec ids=" .. table.concat(labelCollection.spec.ids, ", "))
        appendDebug("current spec names=" .. table.concat(labelCollection.spec.names, ", "))
        appendDebug("current spec variants=" .. table.concat(currentSpecVariants, ", "))

        local specMatch, specFallbackUsed = profileValueMatchesCandidates(profileSpecRaw, currentSpecVariants, labelCollection.class.variants)
        if specFallbackUsed then
            appendDebug("runtime candidates are numeric-only; skipping strict text match for value=" .. tostring(profileSpecRaw))
        end
        if not specMatch then
            appendDebug("spec match result=false")
            if debug then
                print("|cffffcc00[WoWKeyb]|r [match-debug:" .. tostring(debugLabel) .. "] " .. table.concat(debugLines, " | "))
            end
            return false
        end
        appendDebug("spec match result=true")
    end

    local profileHeroRaw = profile.heroTalent or profile.hero_talent or profile.hero_talent_id or profile.heroTalentId
    local profileHeroTalent = normalizeClassName(profileHeroRaw)
    if profileHeroTalent then
        local heroVariants = labelCollection.hero.variants
        appendDebug("profile.heroTalent=" .. tostring(profileHeroRaw))
        appendDebug("current hero ids=" .. table.concat(labelCollection.hero.ids, ", "))
        appendDebug("current hero names=" .. table.concat(labelCollection.hero.names, ", "))
        appendDebug("current hero variants=" .. table.concat(heroVariants, ", "))

        local heroMatch, heroFallbackUsed = profileValueMatchesCandidates(profileHeroRaw, heroVariants, labelCollection.class.variants)
        if heroFallbackUsed then
            appendDebug("runtime candidates are numeric-only; skipping strict text match for value=" .. tostring(profileHeroRaw))
        end
        if not heroMatch then
            appendDebug("hero match result=false")
            if debug then
                print("|cffffcc00[WoWKeyb]|r [match-debug:" .. tostring(debugLabel) .. "] " .. table.concat(debugLines, " | "))
            end
            return false
        end
        appendDebug("hero match result=true")
    end

    if debug then
        print("|cffffcc00[WoWKeyb]|r [match-debug:" .. tostring(debugLabel) .. "] " .. table.concat(debugLines, " | "))
    end
    return true
end

-- Display key labels similar to Blizzard action bar hotkeys.
local function formatHotkeyLabel(key)
    if not key or key == "" then return "" end
    local k = normalizeKey(key) or ""
    return k
        :gsub("SHIFT%-", "S-")
        :gsub("CTRL%-", "C-")
        :gsub("ALT%-", "A-")
end

-- Action bar slot ID to WoW binding command (default UI)
local SLOT_COMMANDS = {}
for i = 1, 12 do SLOT_COMMANDS[i] = "ACTIONBUTTON" .. i end
for i = 1, 12 do SLOT_COMMANDS[12 + i] = "MULTIACTIONBAR1BUTTON" .. i end
for i = 1, 12 do SLOT_COMMANDS[24 + i] = "MULTIACTIONBAR2BUTTON" .. i end
for i = 1, 12 do SLOT_COMMANDS[36 + i] = "MULTIACTIONBAR3BUTTON" .. i end
for i = 1, 12 do SLOT_COMMANDS[48 + i] = "MULTIACTIONBAR4BUTTON" .. i end

-- Convert logical WoWKeyb slot (1..60 across bars 1..5) to Blizzard action slot IDs
-- used by PlaceAction/GetActionInfo.
local function toBlizzardActionSlot(slot)
    if not slot or slot < 1 or slot > 60 then return slot end
    local bar = math.floor((slot - 1) / 12) + 1
    local idx = ((slot - 1) % 12) + 1
    if bar == 1 then
        return idx -- 1..12
    elseif bar == 2 then
        return 60 + idx -- MultiBarBottomLeft: 61..72
    elseif bar == 3 then
        return 48 + idx -- MultiBarBottomRight: 49..60
    elseif bar == 4 then
        return 24 + idx -- MultiBarRight: 25..36
    elseif bar == 5 then
        return 36 + idx -- MultiBarLeft: 37..48
    end
    return slot
end

-- Map WoWKeyb key to action bar slot (1-60). Uses Blizzard default layout for number keys.
-- Other keys (E, R, Q, etc.) get slots 49+ so they appear on bar 5.
local KEY_TO_SLOT = {}
for i = 1, 12 do KEY_TO_SLOT[tostring(i)] = i end
for i = 1, 12 do KEY_TO_SLOT["SHIFT-" .. i] = 12 + i end
for i = 1, 12 do KEY_TO_SLOT["CTRL-" .. i] = 24 + i end
for i = 1, 12 do KEY_TO_SLOT["ALT-" .. i] = 36 + i end

-- Key to bar/slot for layout mode (when no barId): 1->main:0, 2->main:1, Shift+1->bar2:0, etc.
local KEY_TO_LAYOUT_SLOT = {}
for i = 1, 12 do KEY_TO_LAYOUT_SLOT[tostring(i)] = { barIndex = 0, slotIndex = i - 1 } end
for i = 1, 12 do KEY_TO_LAYOUT_SLOT["SHIFT-" .. i] = { barIndex = 1, slotIndex = i - 1 } end
for i = 1, 12 do KEY_TO_LAYOUT_SLOT["CTRL-" .. i] = { barIndex = 2, slotIndex = i - 1 } end
for i = 1, 12 do KEY_TO_LAYOUT_SLOT["ALT-" .. i] = { barIndex = 3, slotIndex = i - 1 } end
local getStoredProfile
local applyProfile

-- Frames created by WoWKeyb for custom layout (cleared on each apply)
local WoWKeybCustomFrames = {}
local WoWKeybCustomMovers = {}

local function setCustomBarsMovableEnabled(enabled)
    for _, mover in ipairs(WoWKeybCustomMovers) do
        if mover and mover.EnableMouse then
            mover:EnableMouse(enabled)
            if enabled then
                mover:Show()
            else
                mover:Hide()
            end
        end
    end
end

local function clearCustomLayoutFrames()
    for _, frame in ipairs(WoWKeybCustomFrames) do
        if frame and frame.UnregisterAllEvents then
            frame:UnregisterAllEvents()
        end
        if frame and frame.Hide then
            frame:Hide()
        end
        if frame and frame.SetParent then
            frame:SetParent(nil)
        end
    end
    WoWKeybCustomFrames = {}
    WoWKeybCustomMovers = {}
end

-- Apply profile using custom layout (SecureActionButton frames at saved positions)
local function applyProfileWithLayout(profile)
    ensureDBDefaults()
    local layout = profile.layout
    if not layout or not layout.bars or #layout.bars == 0 then
        return false, "No layout in profile"
    end

    local GetSpellInfo = C_Spell and C_Spell.GetSpellName or _G.GetSpellInfo
    local screenW = layout.screenWidth or 2560
    local screenH = layout.screenHeight or 1440
    local wowW = GetScreenWidth()
    local wowH = GetScreenHeight()
    local scaleX = wowW / screenW
    local scaleY = wowH / screenH

    -- Build keybind map: barId -> { slotIndex -> { key, spell } }
    local barKeybinds = {}
    for _, keybind in ipairs(profile.keybinds or {}) do
        if keybind.key and keybind.spell and (keybind.spell.spellId or keybind.spell.name) then
            local nk = normalizeKey(keybind.key)
            local barId, slotIndex
            if keybind.barId and (keybind.slotIndex or keybind.slot_index) ~= nil then
                barId = keybind.barId
                slotIndex = keybind.slotIndex or keybind.slot_index
            else
                local mapping = KEY_TO_LAYOUT_SLOT[nk]
                if mapping and layout.bars[mapping.barIndex + 1] then
                    barId = layout.bars[mapping.barIndex + 1].id
                    slotIndex = mapping.slotIndex
                end
            end
            if barId and slotIndex ~= nil then
                barKeybinds[barId] = barKeybinds[barId] or {}
                if not barKeybinds[barId][slotIndex] then
                    barKeybinds[barId][slotIndex] = { key = nk, spell = keybind.spell }
                end
            end
        end
    end

    clearCustomLayoutFrames()

    local applied = 0
    -- Match web editor proportions more closely so imported layouts line up in-game.
    local baseSlotSize = 40
    local baseGap = 4
    local basePadding = 6

    local profileName = tostring(profile.name or "Unknown")
    WoWKeybDB.customBarPositions[profileName] = WoWKeybDB.customBarPositions[profileName] or {}
    local profileOverrides = WoWKeybDB.customBarPositions[profileName]

    for barIdx, bar in ipairs(layout.bars) do
        local pos = bar.position or {}
        local px = pos.x or (screenW / 2)
        local py = pos.y or (screenH - 50)
        local orient = bar.orientation or "horizontal"
        local numSlots = bar.slots or 12
        local barScale = tonumber(bar.scale) or 1
        local slotSize = math.max(20, baseSlotSize * barScale)
        local gap = math.max(1, baseGap * barScale)
        local padding = math.max(2, basePadding * barScale)

        -- Convert design pixels to WoW coords (origin bottom-left)
        local offsetX = math.floor(((px - screenW / 2) * scaleX) + 0.5)
        local offsetY = math.floor(((screenH / 2 - py) * scaleY) + 0.5)
        local savedPos = bar and bar.id and profileOverrides[bar.id] or nil
        if savedPos and type(savedPos.x) == "number" and type(savedPos.y) == "number" then
            offsetX = savedPos.x
            offsetY = savedPos.y
        end

        local barWidth, barHeight
        if orient == "vertical" then
            barWidth = slotSize + (padding * 2)
            barHeight = (numSlots * slotSize) + ((numSlots - 1) * gap) + (padding * 2)
        else
            barWidth = (numSlots * slotSize) + ((numSlots - 1) * gap) + (padding * 2)
            barHeight = slotSize + (padding * 2)
        end

        local container = CreateFrame("Frame", "WoWKeybBar" .. barIdx, UIParent)
        container:SetSize(barWidth, barHeight)
        container:SetPoint("CENTER", UIParent, "CENTER", offsetX, offsetY)
        container:SetFrameStrata("MEDIUM")
        container:SetFrameLevel(10)
        container:SetMovable(true)
        container:SetClampedToScreen(true)
        table.insert(WoWKeybCustomFrames, container)

        local mover = CreateFrame("Frame", nil, container, "BackdropTemplate")
        mover:SetAllPoints(container)
        mover:SetFrameStrata("TOOLTIP")
        mover:SetFrameLevel(container:GetFrameLevel() + 50)
        if mover.SetBackdrop then
            mover:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = false,
                edgeSize = 10,
                insets = { left = 2, right = 2, top = 2, bottom = 2 },
            })
            mover:SetBackdropColor(0.1, 0.55, 1, 0.18)
            mover:SetBackdropBorderColor(0.1, 0.75, 1, 0.9)
        end
        mover:RegisterForDrag("LeftButton")
        mover:SetScript("OnDragStart", function(self)
            if not WoWKeybDB.customBarsUnlocked then return end
            if InCombatLockdown() then
                print("|cffffcc00[WoWKeyb]|r Can't move bars while in combat.")
                return
            end
            local parent = self:GetParent()
            if parent and parent.StartMoving then
                parent:StartMoving()
            end
        end)
        mover:SetScript("OnDragStop", function(self)
            local parent = self:GetParent()
            if parent and parent.StopMovingOrSizing then
                parent:StopMovingOrSizing()
                local _, _, _, xOfs, yOfs = parent:GetPoint(1)
                if type(xOfs) == "number" and type(yOfs) == "number" and bar and bar.id then
                    profileOverrides[bar.id] = {
                        x = math.floor(xOfs + 0.5),
                        y = math.floor(yOfs + 0.5),
                    }
                end
            end
        end)
        local moveText = mover:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        moveText:SetPoint("TOP", mover, "TOP", 0, -3)
        moveText:SetText("Drag")
        moveText:SetTextColor(0.85, 0.95, 1, 0.95)
        table.insert(WoWKeybCustomMovers, mover)
        table.insert(WoWKeybCustomFrames, mover)

        local slots = barKeybinds[bar.id] or {}

        for slotIdx = 0, numSlots - 1 do
            local slotData = slots[slotIdx]
            local btnName = "WoWKeybBtn" .. barIdx .. "_" .. slotIdx

            local btn = CreateFrame("Button", btnName, container, "SecureActionButtonTemplate")
            btn:SetSize(slotSize, slotSize)
            btn:SetFrameStrata("MEDIUM")
            btn:SetFrameLevel(20)

            if orient == "vertical" then
                btn:SetPoint("TOP", container, "TOP", 0, -padding - (slotIdx * (slotSize + gap)))
            else
                btn:SetPoint("LEFT", container, "LEFT", padding + (slotIdx * (slotSize + gap)), 0)
            end

            -- Style the button (border + optional spell icon)
            btn:SetNormalTexture("Interface\\Buttons\\UI-Quickslot2")
            btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
            btn:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")

            -- Show key/slot labels so bars look and read like normal WoW action bars.
            local displayKey = nil
            if bar.slotKeys and bar.slotKeys[slotIdx + 1] and bar.slotKeys[slotIdx + 1] ~= "" then
                displayKey = bar.slotKeys[slotIdx + 1]
            elseif slotData and slotData.key then
                displayKey = slotData.key
            end
            local hotkeyText = formatHotkeyLabel(displayKey)
            if hotkeyText == "" then
                hotkeyText = tostring(slotIdx + 1)
            end
            local hotkey = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
            hotkey:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
            hotkey:SetText(hotkeyText)
            hotkey:SetJustifyH("RIGHT")
            hotkey:SetTextColor(1, 0.82, 0, 0.95)
            btn.WoWKeybHotkey = hotkey

            if slotData and slotData.spell then
                local spell = slotData.spell
                local spellId = tonumber(spell.spellId or spell.spell_id)
                local spellName = spell.name

                if spellId then
                    local nameFromId, _, icon = GetSpellInfo(spellId)
                    if nameFromId then spellName = nameFromId end
                    if icon then
                        local tex = btn:CreateTexture(nil, "ARTWORK")
                        tex:SetPoint("TOPLEFT", 2, -2)
                        tex:SetPoint("BOTTOMRIGHT", -2, 2)
                        tex:SetTexture(icon)
                    end
                end

                if spellId or (spellName and spellName ~= "") then
                    btn:SetAttribute("type", "spell")
                    if spellId then
                        btn:SetAttribute("spell", spellId)
                    else
                        btn:SetAttribute("spell", spellName)
                    end

                    local ok = SetBindingClick(slotData.key, btnName, "LeftButton")
                    if ok then applied = applied + 1 end
                end
            end

            table.insert(WoWKeybCustomFrames, btn)
        end
    end

    local bindingSet = GetCurrentBindingSet()
    SaveBindings(bindingSet)
    setCustomBarsMovableEnabled(WoWKeybDB.customBarsUnlocked == true)

    return true, string.format("Applied %d keybindings (custom layout)", applied)
end

-- Convert WoWKeyb profile to WoW action bars + keybindings
-- Applies to Blizzard's existing action bars only (no custom frame creation).
local function buildLayoutBarIndexById(profile)
    local byId = {}
    if profile and profile.layout and profile.layout.bars then
        for idx, bar in ipairs(profile.layout.bars) do
            local barId = bar and (bar.id or bar.bar_id)
            if barId then
                local mappedIdx = idx - 1 -- zero-based bar index to match slot math
                byId[barId] = mappedIdx
                byId[tostring(barId)] = mappedIdx
                local numericBarId = tonumber(barId)
                if numericBarId ~= nil then
                    byId[numericBarId] = mappedIdx
                end
            end
        end
    end
    return byId
end

local function getLayoutBarIndex(layoutBarIndexById, barId)
    if not layoutBarIndexById or barId == nil then
        return nil
    end

    local direct = layoutBarIndexById[barId]
    if direct ~= nil then return direct end

    local asString = tostring(barId)
    if asString ~= "" then
        local byString = layoutBarIndexById[asString]
        if byString ~= nil then return byString end
    end

    local asNumber = tonumber(barId)
    if asNumber ~= nil then
        local byNumber = layoutBarIndexById[asNumber]
        if byNumber ~= nil then return byNumber end
    end

    return nil
end

local function resolveSlotFromLayoutKeys(profile, wowKey)
    if not profile or not profile.layout or type(profile.layout.bars) ~= "table" then
        return nil
    end
    if not wowKey or wowKey == "" then
        return nil
    end

    for barIdx, bar in ipairs(profile.layout.bars) do
        local slotKeys = (bar and type(bar.slotKeys) == "table" and bar.slotKeys)
            or (bar and type(bar.slot_keys) == "table" and bar.slot_keys)
            or {}
        for slotIdx = 1, 12 do
            local slotKey = normalizeKey(slotKeys[slotIdx] or "")
            if slotKey == wowKey then
                local slot = ((barIdx - 1) * 12) + slotIdx
                if slot >= 1 and slot <= 60 then
                    return slot
                end
            end
        end
    end

    return nil
end

local function resolveExplicitSlotCandidate(keybind, layoutBarIndexById)
    local keybindBarId = keybind and (keybind.barId or keybind.bar_id) or nil
    if not keybind or not keybindBarId or (keybind.slotIndex or keybind.slot_index) == nil then
        return nil
    end

    local barIdx = getLayoutBarIndex(layoutBarIndexById, keybindBarId)
    local rawSlotIdx = tonumber(keybind.slotIndex or keybind.slot_index)
    if barIdx == nil or not rawSlotIdx then
        return nil
    end

    local candidates = {}
    local seen = {}
    local function addCandidate(idx)
        if idx and idx >= 0 and idx <= 11 and not seen[idx] then
            candidates[#candidates + 1] = idx
            seen[idx] = true
        end
    end

    -- Support both legacy zero-based (0-11) and one-based (1-12) slot indexing.
    addCandidate(rawSlotIdx)
    addCandidate(rawSlotIdx - 1)

    for _, candidate in ipairs(candidates) do
        local slot = (barIdx * 12) + candidate + 1
        if slot >= 1 and slot <= 60 then
            return slot
        end
    end

    return nil
end

local function resolvePreferredSlot(profile, keybind, wowKey, layoutBarIndexById)
    local hasLayout = profile and profile.layout and profile.layout.bars and #profile.layout.bars > 0

    -- 1) Explicit barId + slotIndex from web app
    local keybindBarId = keybind and (keybind.barId or keybind.bar_id) or nil
    if keybind and keybindBarId and (keybind.slotIndex or keybind.slot_index) ~= nil then
        local barIdx = getLayoutBarIndex(layoutBarIndexById, keybindBarId)
        local rawSlotIdx = tonumber(keybind.slotIndex or keybind.slot_index)
        if barIdx ~= nil and rawSlotIdx then
            local candidates = {}
            local seen = {}
            local function addCandidate(idx)
                if idx and idx >= 0 and idx <= 11 and not seen[idx] then
                    candidates[#candidates + 1] = idx
                    seen[idx] = true
                end
            end

            -- Support both legacy zero-based (0-11) and one-based (1-12) slot indexing.
            addCandidate(rawSlotIdx)
            addCandidate(rawSlotIdx - 1)

            if #candidates > 0 then
                -- If we have layout + key, prefer the candidate whose layout slotKey matches key.
                local bar = hasLayout and profile.layout and profile.layout.bars and profile.layout.bars[barIdx + 1] or nil
                local barSlotKeys = (bar and type(bar.slotKeys) == "table" and bar.slotKeys)
                    or (bar and type(bar.slot_keys) == "table" and bar.slot_keys)
                    or {}
                if wowKey and wowKey ~= "" then
                    for _, candidate in ipairs(candidates) do
                        local slotKey = normalizeKey(barSlotKeys[candidate + 1] or "")
                        if slotKey == wowKey then
                            return (barIdx * 12) + candidate + 1
                        end
                    end
                    -- Explicit bar/slot metadata exists but does not match the key for this bar's layout.
                    -- Do not force-fallback to the explicit candidate; continue to key-based resolution below.
                    if hasLayout then
                        return nil
                    end
                end

                -- Fall back to first valid candidate.
                return resolveExplicitSlotCandidate(keybind, layoutBarIndexById)
            end
        end
    end

    -- 2) Fallback for legacy payloads: infer bar+slot by key grouping
    if hasLayout then
        -- In layout mode, honor the profile's actual slotKeys first.
        local layoutSlot = resolveSlotFromLayoutKeys(profile, wowKey)
        if layoutSlot then
            return layoutSlot
        end
        -- If layout exists but key is not present in slotKeys, avoid default SHIFT->bar2 style
        -- fallback so stale mappings do not place abilities on the wrong bar.
        return nil
    end
    local layoutMap = KEY_TO_LAYOUT_SLOT[wowKey]
    if layoutMap then
        local slot = (layoutMap.barIndex * 12) + layoutMap.slotIndex + 1
        if slot >= 1 and slot <= 60 then
            return slot
        end
    end

    -- 3) Default direct key mapping (only when layout is absent).
    if hasLayout then
        return nil
    end
    return KEY_TO_SLOT[wowKey]
end

local function readSpellFromActionSlot(slot)
    if not slot or slot < 1 or slot > 120 then
        return nil
    end

    local actionType, actionId = GetActionInfo(slot)
    if actionType ~= "spell" or not actionId then
        return nil
    end

    local spellName, spellIcon = "", ""
    if C_Spell and C_Spell.GetSpellName then
        spellName = C_Spell.GetSpellName(actionId) or spellName
    end
    if C_Spell and C_Spell.GetSpellTexture then
        spellIcon = C_Spell.GetSpellTexture(actionId) or spellIcon
    end
    if (not spellName or spellName == "") and _G.GetSpellInfo then
        local fallbackName, _, fallbackIcon = _G.GetSpellInfo(actionId)
        spellName = fallbackName or spellName
        spellIcon = fallbackIcon or spellIcon
    end

    return {
        spellId = tostring(actionId),
        name = spellName or "",
        icon = spellIcon or "",
    }
end

local function normalizeSpellText(value)
    local s = tostring(value or ""):lower()
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("%s+", " ")
    return s
end

local function parseMacroSpellData(body)
    local parsed = {
        spellIds = {},
        spellNames = {},
    }
    if not body or body == "" then
        return parsed
    end

    local function registerToken(rawToken)
        local token = tostring(rawToken or "")
        token = token:gsub("^%s+", ""):gsub("%s+$", "")
        token = token:gsub("^!+", "")
        token = token:gsub("^reset=[^,%s;]+%s*", "")
        token = token:gsub("^@[^%s]+%s*", "")
        token = token:gsub("^target=[^%s]+%s*", "")
        token = token:gsub("^%s+", ""):gsub("%s+$", "")
        if token == "" then return end

        local spellId = token:match("spell:(%d+)")
        if spellId then
            parsed.spellIds[tonumber(spellId)] = true
            return
        end

        local numericToken = token:match("^(%d+)$")
        if numericToken then
            parsed.spellIds[tonumber(numericToken)] = true
            return
        end

        local normalizedName = normalizeSpellText(token)
        if normalizedName ~= "" then
            parsed.spellNames[normalizedName] = true
        end
    end

    for line in tostring(body):gmatch("[^\r\n]+") do
        local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
        local lower = trimmed:lower()

        if lower:find("^#showtooltip", 1, true) then
            local arg = trimmed:gsub("^#showtooltip%s*", "")
            local normalized = arg:gsub("%b[]", " ")
            for part in normalized:gmatch("[^,;]+") do
                registerToken(part)
            end
        elseif lower:find("^/castsequence", 1, true) then
            local arg = trimmed:gsub("^/castsequence%s*", "")
            local normalized = arg:gsub("%b[]", " ")
            for part in normalized:gmatch("[^,;]+") do
                registerToken(part)
            end
        elseif lower:find("^/cast", 1, true) or lower:find("^/use", 1, true) then
            local arg = trimmed:gsub("^/%S+%s*", "")
            local normalized = arg:gsub("%b[]", " ")
            for part in normalized:gmatch("[^,;]+") do
                registerToken(part)
            end
        end
    end

    return parsed
end

local function actionSlotMacroContainsSpell(actionSlot, spellId, spellName, parseCache)
    if not actionSlot or actionSlot < 1 then return false end
    if type(GetMacroInfo) ~= "function" then return false end
    local actionType, actionId = GetActionInfo(actionSlot)
    if actionType ~= "macro" or not actionId then
        return false
    end

    local _, _, body = GetMacroInfo(actionId)
    if not body or body == "" then
        return false
    end

    local cacheKey = tostring(actionId) .. ":" .. tostring(body)
    if not parseCache[cacheKey] then
        parseCache[cacheKey] = parseMacroSpellData(body)
    end
    local parsed = parseCache[cacheKey]
    if not parsed then return false end

    local targetId = tonumber(spellId)
    if targetId and parsed.spellIds[targetId] then
        return true
    end

    local targetName = normalizeSpellText(spellName)
    if targetName ~= "" and parsed.spellNames[targetName] then
        return true
    end

    return false
end

local function actionSlotHasMacro(actionSlot)
    if not actionSlot then return false end
    local actionType = GetActionInfo(actionSlot)
    return actionType == "macro"
end

local function syncProfileSpellsFromActionBars(profileName)
    ensureDBDefaults()
    local targetName = profileName or WoWKeybDB.currentProfile
    if not targetName or targetName == BLIZZARD_DEFAULT_PROFILE then
        return false, 0
    end

    local profile = getStoredProfile(targetName)
    if not profile or type(profile.keybinds) ~= "table" then
        return false, 0
    end
    if not profileMatchesCurrentClass(profile) then
        return false, 0
    end
    if not profileMatchesCurrentSpecAndHero(profile) then
        return false, 0
    end

    local layoutBarIndexById = buildLayoutBarIndexById(profile)
    local changed = 0

    for _, keybind in ipairs(profile.keybinds) do
        if keybind and keybind.key then
            local wowKey = normalizeKey(keybind.key)
            local slot = resolvePreferredSlot(profile, keybind, wowKey, layoutBarIndexById)
            if slot then
                local currentSpell = keybind.spell or {}
                local barSpell = readSpellFromActionSlot(toBlizzardActionSlot(slot))
                if barSpell then
                    local prevId = tostring(currentSpell.spellId or currentSpell.spell_id or "")
                    local prevName = tostring(currentSpell.name or "")
                    local prevIcon = tostring(currentSpell.icon or "")
                    if prevId ~= barSpell.spellId or prevName ~= barSpell.name or prevIcon ~= barSpell.icon then
                        keybind.spell = {
                            spellId = barSpell.spellId,
                            name = barSpell.name,
                            icon = barSpell.icon,
                            description = currentSpell.description or "",
                        }
                        changed = changed + 1
                    end
                end
            end
        end
    end

    return true, changed
end

local function wowBindingToProfileKey(bindingKey)
    if not bindingKey or bindingKey == "" then
        return ""
    end

    -- Convert WoW binding format (CTRL-SHIFT-E) to profile format (Ctrl+Shift+E).
    local key = tostring(bindingKey):upper()
    key = key:gsub("CTRL%-", "Ctrl+")
    key = key:gsub("SHIFT%-", "Shift+")
    key = key:gsub("ALT%-", "Alt+")
    return key
end

local function firstBindingForCommand(command)
    if not command or command == "" then
        return nil
    end
    local keys = { GetBindingKey(command) }
    for _, key in ipairs(keys) do
        if key and key ~= "" then
            return key
        end
    end
    return nil
end

local function syncProfileLayoutKeysFromBindings(profileName)
    ensureDBDefaults()
    local targetName = profileName or WoWKeybDB.currentProfile
    if not targetName or targetName == BLIZZARD_DEFAULT_PROFILE then
        return false, 0
    end

    local profile = getStoredProfile(targetName)
    if not profile or not profile.layout or type(profile.layout.bars) ~= "table" then
        return false, 0
    end

    local changed = 0
    for barIdx, bar in ipairs(profile.layout.bars) do
        if type(bar) == "table" then
            local slots = tonumber(bar.slots) or 12
            slots = math.min(math.max(1, slots), 12)
            bar.slotKeys = type(bar.slotKeys) == "table" and bar.slotKeys or {}
            for slotIdx = 1, slots do
                local globalSlot = ((barIdx - 1) * 12) + slotIdx
                local command = SLOT_COMMANDS[globalSlot]
                if command then
                    local wowKey = firstBindingForCommand(command)
                    local profileKey = wowBindingToProfileKey(wowKey)
                    local prev = tostring(bar.slotKeys[slotIdx] or "")
                    if prev ~= profileKey then
                        bar.slotKeys[slotIdx] = profileKey
                        changed = changed + 1
                    end
                end
            end
        end
    end

    -- Keep keybind entries aligned with slot key assignments so export/reimport is stable.
    local layoutBarIndexById = buildLayoutBarIndexById(profile)
    if type(profile.keybinds) == "table" then
        for _, keybind in ipairs(profile.keybinds) do
            if keybind then
                local wowKey = normalizeKey(keybind.key or "")
                local slot = resolvePreferredSlot(profile, keybind, wowKey, layoutBarIndexById)
                if slot then
                    local barIndex = math.floor((slot - 1) / 12) + 1
                    local slotIndex = ((slot - 1) % 12) + 1
                    local bar = profile.layout.bars[barIndex]
                    local slotKey = (bar and bar.slotKeys and bar.slotKeys[slotIndex]) or ""
                    local prev = tostring(keybind.key or "")
                    if prev ~= slotKey then
                        keybind.key = slotKey
                        changed = changed + 1
                    end
                end
            end
        end
    end

    return true, changed
end

local function ensureBlizzardBarsVisible()
    pcall(function() SetCVar("alwaysShowActionBars", "1") end)
    pcall(function() SetCVar("showMultiActionBar1", "1") end)
    pcall(function() SetCVar("showMultiActionBar2", "1") end)
    pcall(function() SetCVar("showMultiActionBar3", "1") end)
    pcall(function() SetCVar("showMultiActionBar4", "1") end)
    if MultiActionBar_Update then pcall(MultiActionBar_Update) end
    if MultiActionBar_UpdateGrid then pcall(MultiActionBar_UpdateGrid) end
end

local function setDefaultBarsAlpha(alpha)
    local targets = {
        _G.MainMenuBar,
        _G.MainMenuBarArtFrame,
        _G.MainMenuBarTexture0,
        _G.MainMenuBarTexture1,
        _G.MainMenuBarTexture2,
        _G.MainMenuBarTexture3,
        _G.MainMenuBarLeftEndCap,
        _G.MainMenuBarRightEndCap,
        _G.MultiBarBottomLeft,
        _G.MultiBarBottomRight,
        _G.MultiBarRight,
        _G.MultiBarLeft,
        _G.PossessBarFrame,
        _G.StanceBarFrame,
        _G.PetActionBarFrame,
    }
    for _, frame in ipairs(targets) do
        if frame and frame.SetAlpha then
            pcall(function() frame:SetAlpha(alpha) end)
        end
    end
end

local function applyBarModeVisibility(useCustomBars)
    if useCustomBars then
        pcall(function() SetCVar("showMultiActionBar1", "0") end)
        pcall(function() SetCVar("showMultiActionBar2", "0") end)
        pcall(function() SetCVar("showMultiActionBar3", "0") end)
        pcall(function() SetCVar("showMultiActionBar4", "0") end)
        pcall(function() SetCVar("alwaysShowActionBars", "0") end)
        if MultiActionBar_Update then pcall(MultiActionBar_Update) end
        setDefaultBarsAlpha(0)
    else
        ensureBlizzardBarsVisible()
        setDefaultBarsAlpha(1)
    end
end

local function applyBlizzardDefaultProfile()
    ensureDBDefaults()
    clearCustomLayoutFrames()
    applyBarModeVisibility(false)

    -- Remove all keybindings for Blizzard action bar commands when returning
    -- to Blizzard Default profile, so no WoWKeyb-applied binds remain.
    for slot = 1, 60 do
        local command = SLOT_COMMANDS[slot]
        if command and type(GetBindingKey) == "function" then
            local keys = { GetBindingKey(command) }
            for _, existingKey in ipairs(keys) do
                if existingKey and existingKey ~= "" then
                    SetBinding(existingKey)
                end
            end
        end
    end

    -- Re-apply Blizzard-style primary bar defaults:
    -- ActionButton1..12 => 1,2,3,4,5,6,7,8,9,0,-,=
    local defaultMainBarKeys = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "=" }
    for slot = 1, 12 do
        local command = SLOT_COMMANDS[slot]
        local key = defaultMainBarKeys[slot]
        if command and key and key ~= "" then
            SetBinding(key, command)
        end
    end

    if type(GetCurrentBindingSet) == "function" and type(SaveBindings) == "function" then
        local bindingSet = GetCurrentBindingSet()
        SaveBindings(bindingSet)
    end

    WoWKeybDB.lastApplied = {
        name = BLIZZARD_DEFAULT_PROFILE,
        applied = 0,
        skipped = 0,
        time = time(),
    }
    if WoWKeybDB.currentProfile ~= BLIZZARD_DEFAULT_PROFILE then
        WoWKeybDB.previousProfile = WoWKeybDB.currentProfile
        WoWKeybDB.currentProfile = BLIZZARD_DEFAULT_PROFILE
    end
    return true, "Applied Blizzard default bars"
end

local function applySelectionByName(target)
    ensureDBDefaults()
    if not target or target == "" then
        return false, "No profile selected"
    end
    if target == BLIZZARD_DEFAULT_PROFILE then
        return applyBlizzardDefaultProfile()
    end
    local profile = getStoredProfile(target)
    if not profile then
        return false, "Profile not found: " .. tostring(target)
    end
    local ok, result = applyProfile(profile)
    if ok then
        -- Keep active profile pointer tied to the stored profile key used for selection.
        if WoWKeybDB.currentProfile ~= target then
            WoWKeybDB.previousProfile = WoWKeybDB.currentProfile
            WoWKeybDB.currentProfile = target
        end
        setPreferredProfileForCurrentContext(target)
    end
    return ok, result
end

applyProfile = function(profile)
    ensureDBDefaults()
    if not profile or not profile.keybinds or #profile.keybinds == 0 then
        return false, "No keybinds in profile"
    end

    if not profileMatchesCurrentClass(profile) then
        local _, englishClass, classToken = UnitClass("player")
        local playerClass = englishClass or classToken or "Unknown"
        return false, string.format(
            "Profile class mismatch: profile is %s, current character is %s",
            tostring(profile.class or "unknown"),
            tostring(playerClass)
        )
    end
    if not profileMatchesCurrentSpecAndHero(profile) then
        return false, string.format(
            "Profile spec/hero mismatch: profile is %s / %s (run /wowkeyb debugmatch \"%s\")",
            tostring(profile.spec or "unknown"),
            tostring(profile.heroTalent or "unknown"),
            tostring(profile.name or "profile")
        )
    end

    if InCombatLockdown() then
        return false, "Cannot apply keybindings while in combat"
    end

    WoWKeyb.isApplyingProfile = true

    local hasLayout = profile and profile.layout and profile.layout.bars and #profile.layout.bars > 0
    clearCustomLayoutFrames()
    applyBarModeVisibility(false)

    local PickupSpell = _G.PickupSpell
    if C_Spell and type(C_Spell.PickupSpell) == "function" then
        PickupSpell = C_Spell.PickupSpell
    end
    local GetSpellInfo = C_Spell and C_Spell.GetSpellName or _G.GetSpellInfo
    local layoutBarIndexById = buildLayoutBarIndexById(profile)
    local layoutSlotToKey = {}

    if hasLayout then
        -- Build explicit slot -> key mapping from layout slotKeys so action bar bindings
        -- follow the action bar editor even when spell records are sparse.
        for barIdx, bar in ipairs(profile.layout.bars) do
            local slotKeys = (bar and type(bar.slotKeys) == "table" and bar.slotKeys)
                or (bar and type(bar.slot_keys) == "table" and bar.slot_keys)
            if type(slotKeys) == "table" then
                for slotIdx = 1, 12 do
                    local rawKey = slotKeys[slotIdx]
                    local wowLayoutKey = normalizeKey(rawKey)
                    if wowLayoutKey and wowLayoutKey ~= "" then
                        local slot = ((barIdx - 1) * 12) + slotIdx
                        if slot >= 1 and slot <= 60 and SLOT_COMMANDS[slot] then
                            layoutSlotToKey[slot] = wowLayoutKey
                        end
                    end
                end
            end
        end
    end

    -- Remove existing bindings for action bar commands before re-applying.
    -- This prevents stale bindings from older profiles from sticking around.
    for slot = 1, 60 do
        local command = SLOT_COMMANDS[slot]
        if command then
            local keys = { GetBindingKey(command) }
            for _, existingKey in ipairs(keys) do
                if existingKey and existingKey ~= "" then
                    SetBinding(existingKey)
                end
            end
        end
    end

    -- Apply layout-defined slot keys immediately, even for empty slots.
    for slot, wowLayoutKey in pairs(layoutSlotToKey) do
        local command = SLOT_COMMANDS[slot]
        if command then
            SetBinding(wowLayoutKey, command)
        end
    end

    local entries = {}
    if hasLayout then
        -- In layout mode, spell placement should follow resolved slot mapping even when
        -- keybind.key is missing/empty, since bindings may come from layout.slotKeys.
        local slotToData = {}
        local layoutKeyToSlots = {}
        for slot, layoutKey in pairs(layoutSlotToKey) do
            if layoutKey and layoutKey ~= "" then
                layoutKeyToSlots[layoutKey] = layoutKeyToSlots[layoutKey] or {}
                table.insert(layoutKeyToSlots[layoutKey], slot)
            end
        end
        for _, slots in pairs(layoutKeyToSlots) do
            table.sort(slots)
        end
        for _, keybind in ipairs(profile.keybinds) do
            if keybind and keybind.spell and (keybind.spell.spellId or keybind.spell.spell_id or keybind.spell.id or keybind.spell.name) then
                local nk = normalizeKey(keybind.key or "")
                local keybindHasExplicitSlot = (keybind.barId or keybind.bar_id) and ((keybind.slotIndex or keybind.slot_index) ~= nil)
                local slot = resolvePreferredSlot(profile, keybind, nk, layoutBarIndexById)
                if (not slot) and nk and nk ~= "" and layoutKeyToSlots[nk] then
                    for _, candidate in ipairs(layoutKeyToSlots[nk]) do
                        if not slotToData[candidate] then
                            slot = candidate
                            break
                        end
                    end
                end
                if (not slot) and keybindHasExplicitSlot then
                    -- If key text is stale/malformed, still allow explicit bar/slot metadata.
                    -- Only do this when key-based lookup produced no candidates.
                    if (not nk) or nk == "" or not layoutKeyToSlots[nk] then
                        local explicitSlot = resolveExplicitSlotCandidate(keybind, layoutBarIndexById)
                        if explicitSlot and not slotToData[explicitSlot] then
                            slot = explicitSlot
                        end
                    end
                end
                if slot then
                    local existing = slotToData[slot]
                    if not existing then
                        slotToData[slot] = {
                            spell = keybind.spell,
                            wowKey = nk,
                            slot = slot,
                            hasExplicitSlot = keybindHasExplicitSlot and true or false,
                        }
                    else
                        -- Resolve collisions deterministically:
                        -- 1) Prefer entry whose key matches layout slot key.
                        -- 2) Then prefer entry with explicit barId+slotIndex.
                        local expectedKey = layoutSlotToKey[slot]
                        local newMatchesLayoutKey = expectedKey and expectedKey ~= "" and nk == expectedKey
                        local existingMatchesLayoutKey = expectedKey and expectedKey ~= ""
                            and existing.wowKey
                            and existing.wowKey == expectedKey
                        local existingSpell = existing.spell or {}
                        local existingHasSpellIdentity = (existingSpell.spellId or existingSpell.spell_id or existingSpell.id
                            or existingSpell.name or existingSpell.spellName or existingSpell.spell_name) and true or false
                        local newSpell = keybind.spell or {}
                        local newHasSpellIdentity = (newSpell.spellId or newSpell.spell_id or newSpell.id
                            or newSpell.name or newSpell.spellName or newSpell.spell_name) and true or false

                        local shouldReplace = false
                        if newMatchesLayoutKey and not existingMatchesLayoutKey then
                            shouldReplace = true
                        elseif keybindHasExplicitSlot and not existing.hasExplicitSlot then
                            shouldReplace = true
                        elseif newMatchesLayoutKey and existingMatchesLayoutKey and newHasSpellIdentity and not existingHasSpellIdentity then
                            shouldReplace = true
                        end

                        if shouldReplace then
                            slotToData[slot] = {
                                spell = keybind.spell,
                                wowKey = nk,
                                slot = slot,
                                hasExplicitSlot = keybindHasExplicitSlot and true or false,
                            }
                        end
                    end
                end
            end
        end
        local sortedSlots = {}
        for slot in pairs(slotToData) do sortedSlots[#sortedSlots + 1] = slot end
        table.sort(sortedSlots)
        for _, slot in ipairs(sortedSlots) do
            entries[#entries + 1] = slotToData[slot]
        end

        -- In layout mode, clear slots that are not populated by the imported profile.
        -- This prevents stale spells from previous profiles appearing as "wrong replacements".
        if type(ClearAction) == "function" then
            for slot = 1, 60 do
                if not slotToData[slot] then
                    local actionSlot = toBlizzardActionSlot(slot)
                    if not actionSlotHasMacro(actionSlot) then
                        pcall(function()
                            ClearAction(actionSlot)
                        end)
                    end
                end
            end
        end
    else
        -- Non-layout mode keeps legacy key-first behavior.
        local keyToData = {}
        for _, keybind in ipairs(profile.keybinds) do
            if keybind and keybind.key and keybind.spell and (keybind.spell.spellId or keybind.spell.name) then
                local nk = normalizeKey(keybind.key)
                if not keyToData[nk] then
                    keyToData[nk] = {
                        spell = keybind.spell,
                        preferredSlot = resolvePreferredSlot(profile, keybind, nk, layoutBarIndexById),
                    }
                end
            end
        end

        local sortedKeys = {}
        for k in pairs(keyToData) do sortedKeys[#sortedKeys + 1] = k end
        table.sort(sortedKeys)

        local nextExtraSlot = 49
        for _, wowKey in ipairs(sortedKeys) do
            local slot = keyToData[wowKey].preferredSlot
            if not slot and nextExtraSlot <= 60 then
                slot = nextExtraSlot
                nextExtraSlot = nextExtraSlot + 1
            end
            entries[#entries + 1] = {
                spell = keyToData[wowKey].spell,
                wowKey = wowKey,
                slot = slot,
            }
        end
    end

    local applied = 0
    local skipped = 0
    local macroParseCache = {}
    local debugApplySlots = WoWKeybDB.debugApplySlots == true

    for _, entry in ipairs(entries) do
        local spell = entry.spell
        local slot = entry.slot
        local wowKey = entry.wowKey
        local debugSpellId = tostring(spell and (spell.spellId or spell.spell_id or spell.id) or "")
        local debugSpellName = tostring(spell and (spell.name or spell.spellName or spell.spell_name or spell.ability_name or spell.abilityName) or "")
        if not slot then
            skipped = skipped + 1
            if debugApplySlots then
                addonChat("|cffffcc00[WoWKeyb]|r [slot-debug] slot=<none> key=" .. tostring(wowKey or "")
                    .. " spellId=" .. debugSpellId .. " spell=\"" .. debugSpellName .. "\" result=skip reason=no-slot")
            end
        else
            local spellId = tonumber(spell.spellId or spell.spell_id or spell.id)
            if not spellId then
                local rawSpellId = tostring(spell.spellId or spell.spell_id or spell.id or "")
                local numericOnly = rawSpellId:gsub("[^0-9]", "")
                if numericOnly ~= "" then
                    spellId = tonumber(numericOnly)
                end
            end
            local spellName = spell.name or spell.spellName or spell.spell_name or spell.ability_name or spell.abilityName

            if spellId then
                local nameFromId = GetSpellInfo(spellId)
                if nameFromId then spellName = nameFromId end
            end

            if (not spellId and not spellName) or spellName == "" then
                skipped = skipped + 1
                if debugApplySlots then
                    addonChat("|cffffcc00[WoWKeyb]|r [slot-debug] slot=" .. tostring(slot)
                        .. " blizzSlot=" .. tostring(toBlizzardActionSlot(slot))
                        .. " key=" .. tostring(wowKey or "")
                        .. " spellId=" .. tostring(spellId or "")
                        .. " spell=\"" .. tostring(spellName or "") .. "\" result=skip reason=missing-spell")
                end
            else
                local actionSlot = toBlizzardActionSlot(slot)
                local keepMacro = actionSlotMacroContainsSpell(actionSlot, spellId, spellName, macroParseCache)
                local slotHasMacro = actionSlotHasMacro(actionSlot)
                local placeResult = "not-attempted"
                local placeReason = "n/a"

                -- 1. Place spell on action bar (default WoW UI)
                if not keepMacro then
                    -- Clear target slot first so failed pickup does not leave stale/incorrect icons.
                    if type(ClearAction) == "function" then
                        pcall(function()
                            ClearAction(actionSlot)
                        end)
                    end

                    local pickedUp = false
                    if spellId and type(PickupSpell) == "function" then
                        if debugApplySlots then
                            addonChat("|cffffcc00[WoWKeyb]|r [slot-debug] slot=" .. tostring(slot)
                                .. " blizzSlot=" .. tostring(actionSlot)
                                .. " try=pickup-by-id spellId=" .. tostring(spellId))
                        end
                        pcall(function()
                            PickupSpell(spellId)
                        end)
                        local cursorType = GetCursorInfo()
                        pickedUp = cursorType ~= nil
                        if debugApplySlots then
                            addonChat("|cffffcc00[WoWKeyb]|r [slot-debug] slot=" .. tostring(slot)
                                .. " blizzSlot=" .. tostring(actionSlot)
                                .. " try=pickup-by-id result=" .. tostring(pickedUp and "ok" or "fail")
                                .. " cursorType=" .. tostring(cursorType))
                        end
                    end
                    if (not pickedUp) and spellName and spellName ~= "" and type(PickupSpell) == "function" then
                        if debugApplySlots then
                            addonChat("|cffffcc00[WoWKeyb]|r [slot-debug] slot=" .. tostring(slot)
                                .. " blizzSlot=" .. tostring(actionSlot)
                                .. " try=pickup-by-name spell=\"" .. tostring(spellName) .. "\"")
                        end
                        PickupSpell(spellName)
                        local cursorType = GetCursorInfo()
                        pickedUp = cursorType ~= nil
                        if debugApplySlots then
                            addonChat("|cffffcc00[WoWKeyb]|r [slot-debug] slot=" .. tostring(slot)
                                .. " blizzSlot=" .. tostring(actionSlot)
                                .. " try=pickup-by-name result=" .. tostring(pickedUp and "ok" or "fail")
                                .. " cursorType=" .. tostring(cursorType))
                        end
                    end

                    if pickedUp then
                        PlaceAction(actionSlot)
                        ClearCursor()
                        placeResult = "placed"
                        placeReason = "pickup-success"
                    else
                        placeResult = "skip"
                        placeReason = "pickup-failed"
                    end
                else
                    placeResult = "skip"
                    placeReason = slotHasMacro and "macro-contains-spell" or "macro-kept"
                end

                -- 2. Bind key to action bar slot
                local command = SLOT_COMMANDS[slot]
                local bindResult = "skip"
                local bindReason = "missing-command"
                if command then
                    local bindingKey
                    if hasLayout then
                        -- In layout mode, only bind keys explicitly assigned to the slot.
                        -- This keeps unassigned slots unbound even if legacy keybind records still have keys.
                        bindingKey = layoutSlotToKey[slot]
                    else
                        bindingKey = wowKey
                    end

                    if bindingKey and bindingKey ~= "" then
                        local ok = SetBinding(bindingKey, command)
                        if ok then
                            applied = applied + 1
                            bindResult = "bound"
                            bindReason = "ok"
                        else
                            skipped = skipped + 1
                            bindResult = "skip"
                            bindReason = "setbinding-failed"
                        end
                    else
                        skipped = skipped + 1
                        bindResult = "skip"
                        bindReason = "empty-binding-key"
                    end
                else
                    skipped = skipped + 1
                    bindResult = "skip"
                    bindReason = "missing-command"
                end

                if debugApplySlots then
                    local actualSpell = readSpellFromActionSlot(actionSlot)
                    local actualSpellId = actualSpell and tostring(actualSpell.spellId or "") or ""
                    local actualSpellName = actualSpell and tostring(actualSpell.name or "") or ""
                    addonChat("|cffffcc00[WoWKeyb]|r [slot-debug] slot=" .. tostring(slot)
                        .. " blizzSlot=" .. tostring(actionSlot)
                        .. " key=" .. tostring(wowKey or "")
                        .. " spellId=" .. tostring(spellId or "")
                        .. " spell=\"" .. tostring(spellName or "") .. "\""
                        .. " place=" .. tostring(placeResult) .. "(" .. tostring(placeReason) .. ")"
                        .. " bind=" .. tostring(bindResult) .. "(" .. tostring(bindReason) .. ")"
                        .. " actualSpellId=" .. tostring(actualSpellId ~= "" and actualSpellId or "-")
                        .. " actualSpell=\"" .. tostring(actualSpellName ~= "" and actualSpellName or "-") .. "\"")
                end
            end
        end
    end

    local bindingSet = GetCurrentBindingSet()
    SaveBindings(bindingSet)

    local profileName = profile.name or "Unknown"
    WoWKeybDB.lastApplied = {
        name = profileName,
        applied = applied,
        skipped = skipped,
        time = time(),
    }

    -- Update toggle history (current <-> previous)
    if WoWKeybDB.currentProfile ~= profileName then
        WoWKeybDB.previousProfile = WoWKeybDB.currentProfile
        WoWKeybDB.currentProfile = profileName
    end

    WoWKeyb.isApplyingProfile = false
    return true, string.format("Applied %d keybindings (%d skipped) [mode: blizzard]", applied, skipped)
end

-- Toggle between current and previous profile
local function toggleProfile()
    if not WoWKeybDB.previousProfile then
        return false, "No previous profile to toggle to. Apply at least two different profiles first."
    end
    local target = WoWKeybDB.previousProfile
    local ok, result = applySelectionByName(target)
    if ok then
        return true, "Switched to: " .. target
    end
    return false, result
end

-- Load profile from WoWKeyb export format (JSON)
-- Expected format: { name, keybinds: [{ key, spell: { spellId, name, icon, description } }] }
local function loadProfileFromString(jsonStr)
    local success, err = pcall(function()
        local decoded = LibStub and LibStub("AceSerializer-3.0", true) and LibStub("AceSerializer-3.0"):Deserialize(jsonStr)
        if decoded then return decoded end
        -- Fallback: try JSON decode if available
        if type(jsonStr) == "string" then
            -- Simple JSON parse for our format (no external lib required for basic case)
            local profile = {}
            profile.keybinds = {}
            -- Very basic: expect format from WoWKeyb API
            local count = 0
            for keybind in jsonStr:gmatch('{"key":"([^"]*)","spell":{([^}]+)}}') do
                count = count + 1
            end
            if count == 0 then
                -- Try WoW's built-in if any
                return nil
            end
        end
        return nil
    end)
    if success and err then return err end
    return nil
end

-- Store profile in SavedVariables for later use
local function storeProfile(profileName, profile)
    if not profileName or not profile then return false end
    WoWKeybDB.profiles[profileName] = profile
    return true
end

-- Get stored profile
getStoredProfile = function(profileName)
    return WoWKeybDB.profiles[profileName or ""]
end

-- List stored profiles
local function listStoredProfiles(onlyCurrentCharacterContext)
    local list = {}
    for name, profile in pairs(WoWKeybDB.profiles) do
        local include = true
        if onlyCurrentCharacterContext then
            include = profileMatchesCurrentClass(profile) and profileMatchesCurrentSpecAndHero(profile)
        end
        if include then
            table.insert(list, name)
        end
    end
    table.sort(list)
    return list
end

local function shouldAnnounceContextAutoSwitch(triggerEvent)
    return triggerEvent == "PLAYER_SPECIALIZATION_CHANGED"
        or triggerEvent == "ACTIVE_TALENT_GROUP_CHANGED"
end

local function enforceCurrentProfileForPlayerContext(triggerEvent)
    ensureDBDefaults()
    local current = WoWKeybDB.currentProfile or BLIZZARD_DEFAULT_PROFILE

    local matchingProfiles = listStoredProfiles(true)
    local target = BLIZZARD_DEFAULT_PROFILE
    local targetReason = "default"

    if #matchingProfiles > 0 then
        local preferred = getPreferredProfileForCurrentContext()
        if preferred and WoWKeybDB.profiles[preferred] then
            for _, candidate in ipairs(matchingProfiles) do
                if candidate == preferred then
                    target = preferred
                    targetReason = "preferred"
                    break
                end
            end
        end
        if target == BLIZZARD_DEFAULT_PROFILE then
            for _, candidate in ipairs(matchingProfiles) do
                if candidate == current then
                    target = current
                    targetReason = "current"
                    break
                end
            end
        end
        if target == BLIZZARD_DEFAULT_PROFILE then
            target = matchingProfiles[1]
            targetReason = "first_match"
        end
    end

    if target == current then
        if target ~= BLIZZARD_DEFAULT_PROFILE then
            setPreferredProfileForCurrentContext(target)
        end
        return
    end

    local ok, result = applySelectionByName(target)
    if ok then
        local announce = shouldAnnounceContextAutoSwitch(triggerEvent)
        if target == BLIZZARD_DEFAULT_PROFILE then
            if announce then
                print("|cffffcc00[WoWKeyb]|r No matching WoWKeyb profile for current class/spec/hero after "
                    .. tostring(triggerEvent or "context change")
                    .. "; switched to Blizzard Default.")
            end
        else
            if announce then
                print("|cff00ff00[WoWKeyb]|r Auto-selected profile for current class/spec/hero (" .. tostring(targetReason) .. "): " .. tostring(target))
            end
        end
    else
        print("|cffff0000[WoWKeyb]|r Failed to apply context profile " .. tostring(target) .. ": " .. tostring(result or "unknown error"))
    end
end

local function jsonEscape(str)
    str = tostring(str or "")
    str = str:gsub("\\", "\\\\")
    str = str:gsub('"', '\\"')
    str = str:gsub("\n", "\\n")
    str = str:gsub("\r", "\\r")
    str = str:gsub("\t", "\\t")
    return str
end

local function toJSONArray(items)
    return "[" .. table.concat(items, ",") .. "]"
end

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64Encode(input)
    if not input or input == "" then return "" end
    local bytes = { string.byte(input, 1, #input) }
    local output = {}

    for i = 1, #bytes, 3 do
        local b1 = bytes[i] or 0
        local b2 = bytes[i + 1] or 0
        local b3 = bytes[i + 2] or 0
        local n = (b1 * 65536) + (b2 * 256) + b3

        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64

        output[#output + 1] = BASE64_ALPHABET:sub(c1 + 1, c1 + 1)
        output[#output + 1] = BASE64_ALPHABET:sub(c2 + 1, c2 + 1)
        output[#output + 1] = (i + 1 <= #bytes) and BASE64_ALPHABET:sub(c3 + 1, c3 + 1) or "="
        output[#output + 1] = (i + 2 <= #bytes) and BASE64_ALPHABET:sub(c4 + 1, c4 + 1) or "="
    end

    return table.concat(output)
end

local function base64Decode(input)
    if not input or input == "" then return "" end
    local clean = tostring(input):gsub("%s+", "")
    if (#clean % 4) ~= 0 then
        return nil
    end

    local indexByChar = {}
    for i = 1, #BASE64_ALPHABET do
        indexByChar[BASE64_ALPHABET:sub(i, i)] = i - 1
    end

    local output = {}
    for i = 1, #clean, 4 do
        local c1 = clean:sub(i, i)
        local c2 = clean:sub(i + 1, i + 1)
        local c3 = clean:sub(i + 2, i + 2)
        local c4 = clean:sub(i + 3, i + 3)

        local v1 = indexByChar[c1]
        local v2 = indexByChar[c2]
        local v3 = (c3 == "=") and nil or indexByChar[c3]
        local v4 = (c4 == "=") and nil or indexByChar[c4]

        if v1 == nil or v2 == nil or (c3 ~= "=" and v3 == nil) or (c4 ~= "=" and v4 == nil) then
            return nil
        end

        local n = (v1 * 262144) + (v2 * 4096) + ((v3 or 0) * 64) + (v4 or 0)
        local b1 = math.floor(n / 65536) % 256
        local b2 = math.floor(n / 256) % 256
        local b3 = n % 256

        output[#output + 1] = string.char(b1)
        if c3 ~= "=" then output[#output + 1] = string.char(b2) end
        if c4 ~= "=" then output[#output + 1] = string.char(b3) end
    end

    return table.concat(output)
end

local function encodeProfileShareCode(json)
    return SHARE_CODE_PREFIX .. base64Encode(json or "")
end

local function decodeProfileShareCode(text)
    local raw = tostring(text or "")
    local trimmed = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed:sub(1, #SHARE_CODE_PREFIX):upper() ~= SHARE_CODE_PREFIX then
        return nil
    end
    local payload = trimmed:sub(#SHARE_CODE_PREFIX + 1)
    if payload == "" then
        return nil
    end
    return base64Decode(payload)
end

local function serializeSyncedProfile(profileName, profile)
    ensureDBDefaults()
    if not profile then
        return nil, "Profile not found"
    end

    local pName = tostring(profile.name or profileName or "ImportedProfile")
    local keybindChunks = {}
    local keybinds = profile.keybinds or {}
    for _, kb in ipairs(keybinds) do
        local spell = kb.spell or {}
        local spellId = tostring(spell.spellId or spell.spell_id or "")
        local key = tostring(kb.key or "")
        local spellJson = table.concat({
            '{"spellId":"', jsonEscape(spellId),
            '","name":"', jsonEscape(spell.name or ""),
            '","icon":"', jsonEscape(spell.icon or ""),
            '","description":"', jsonEscape(spell.description or ""),
            '"}'
        })
        local kbJson = table.concat({
            '{"key":"', jsonEscape(key),
            '","spell":', spellJson,
            ',"barId":"', jsonEscape(kb.barId or kb.bar_id or ""),
            '","slotIndex":', tostring(tonumber(kb.slotIndex or kb.slot_index) or 0),
            '}'
        })
        table.insert(keybindChunks, kbJson)
    end

    local layout = profile.layout or {}
    local bars = layout.bars or {}
    local layoutChunks = {}
    local screenW = tonumber(layout.screenWidth) or 2560
    local screenH = tonumber(layout.screenHeight) or 1440
    for _, bar in ipairs(bars) do
        local pos = bar.position or {}
        local px = tonumber(pos.x) or (screenW / 2)
        local py = tonumber(pos.y) or (screenH / 2)

        local slotKeys = {}
        for _, key in ipairs(bar.slotKeys or {}) do
            table.insert(slotKeys, '"' .. jsonEscape(key or "") .. '"')
        end

        local barJson = table.concat({
            '{"id":"', jsonEscape(bar.id or ""),
            '","slots":', tostring(tonumber(bar.slots) or 12),
            ',"slotKeys":', toJSONArray(slotKeys),
            ',"position":{"anchor":"', jsonEscape((pos.anchor or "center")),
            '","x":', tostring(math.floor(px + 0.5)),
            ',"y":', tostring(math.floor(py + 0.5)),
            '},"orientation":"', jsonEscape(bar.orientation or "horizontal"),
            '","scale":', tostring(tonumber(bar.scale) or 1),
            '}'
        })
        table.insert(layoutChunks, barJson)
    end

    local layoutJson = table.concat({
        '{"bars":', toJSONArray(layoutChunks),
        ',"barMode":"', jsonEscape("blizzard"),
        '","screenWidth":', tostring(screenW),
        ',"screenHeight":', tostring(screenH),
        ',"barGap":', tostring(tonumber(layout.barGap) or 16),
        '}'
    })

    local profileJson = table.concat({
        '{"name":"', jsonEscape(pName),
        '","keybinds":', toJSONArray(keybindChunks),
        ',"layout":', layoutJson,
        '}'
    })
    return profileJson
end

local function buildViewerData(profile)
    local keyToEntries = {}
    local slotData = {}
    local keybinds = profile and profile.keybinds or {}
    local layoutBarIndexById = buildLayoutBarIndexById(profile)
    local debugViewerSlots = WoWKeybDB.debugViewerSlots == true
    local function resolveViewerSpellIcon(spell)
        if type(spell) ~= "table" then return nil end
        local function hasIcon(value)
            return value and tostring(value) ~= ""
        end

        local existingIcon = spell.icon
        if hasIcon(existingIcon) then
            local iconStr = tostring(existingIcon)
            local lowerIcon = iconStr:lower()
            -- WoW textures cannot use web URLs, so ignore those and resolve locally.
            if not lowerIcon:find("^https?://") then
                return existingIcon
            end
        end

        local spellId = tonumber(spell.spellId or spell.spell_id or spell.id)
        if not spellId then
            local rawSpellId = tostring(spell.spellId or spell.spell_id or spell.id or "")
            local numericOnly = rawSpellId:gsub("[^0-9]", "")
            if numericOnly ~= "" then
                spellId = tonumber(numericOnly)
            end
        end

        local spellName = tostring(spell.name or spell.spellName or spell.spell_name or spell.ability_name or spell.abilityName or "")

        -- Retail API: C_Spell.GetSpellInfo may return a table with iconID/iconFileID.
        if C_Spell and type(C_Spell.GetSpellInfo) == "function" then
            local function resolveFromSpellInfo(ref)
                if not ref or ref == "" then return nil end
                local okInfo, info = pcall(C_Spell.GetSpellInfo, ref)
                if not okInfo or not info then return nil end
                if type(info) == "table" then
                    local icon = info.iconID or info.iconFileID or info.icon
                    if hasIcon(icon) then
                        return icon
                    end
                end
                return nil
            end
            local infoIcon = resolveFromSpellInfo(spellId)
            if hasIcon(infoIcon) then
                return infoIcon
            end
            infoIcon = resolveFromSpellInfo(spellName)
            if hasIcon(infoIcon) then
                return infoIcon
            end
        end

        if spellId and C_Spell and type(C_Spell.GetSpellTexture) == "function" then
            local okTexture, texture = pcall(C_Spell.GetSpellTexture, spellId)
            if okTexture and hasIcon(texture) then
                return texture
            end
        end
        if spellId and _G.GetSpellInfo then
            local _, _, texture = _G.GetSpellInfo(spellId)
            if hasIcon(texture) then
                return texture
            end
        end

        if spellName ~= "" and _G.GetSpellInfo then
            local _, _, texture = _G.GetSpellInfo(spellName)
            if hasIcon(texture) then
                return texture
            end
        end

        if hasIcon(existingIcon) then
            return existingIcon
        end
        return nil
    end

    local function viewerBaseKey(key)
        local k = normalizeKey(key)
        if not k or k == "" then return nil end
        -- Group modifier variants (SHIFT/CTRL/ALT) on the same base key tile.
        local changed = true
        while changed do
            changed = false
            if k:find("^SHIFT%-") then
                k = k:gsub("^SHIFT%-", "")
                changed = true
            elseif k:find("^CTRL%-") then
                k = k:gsub("^CTRL%-", "")
                changed = true
            elseif k:find("^ALT%-") then
                k = k:gsub("^ALT%-", "")
                changed = true
            end
        end
        return k
    end

    local bars = profile and profile.layout and profile.layout.bars or {}
    local layoutKeyToSlots = {}
    for barIdx = 1, 5 do
        local bar = bars[barIdx]
        local slotKeys = (bar and type(bar.slotKeys) == "table" and bar.slotKeys)
            or (bar and type(bar.slot_keys) == "table" and bar.slot_keys)
            or {}
        for slotIdx = 1, 12 do
            local normalizedLayoutKey = normalizeKey(slotKeys[slotIdx] or "")
            if normalizedLayoutKey and normalizedLayoutKey ~= "" then
                local globalSlot = ((barIdx - 1) * 12) + slotIdx
                layoutKeyToSlots[normalizedLayoutKey] = layoutKeyToSlots[normalizedLayoutKey] or {}
                table.insert(layoutKeyToSlots[normalizedLayoutKey], globalSlot)
            end
        end
    end
    for _, slots in pairs(layoutKeyToSlots) do
        table.sort(slots)
    end

    for _, kb in ipairs(keybinds) do
        if kb and kb.spell and (kb.spell.spellId or kb.spell.spell_id or kb.spell.id or kb.spell.name) then
            local spell = kb.spell or {}
            local spellName = tostring(spell.name or spell.spellName or spell.spell_name or spell.ability_name or spell.abilityName or "")
            local spellIcon = resolveViewerSpellIcon(spell)
            local wowKey = normalizeKey(kb.key or "")
            local slot = resolvePreferredSlot(profile, kb, wowKey, layoutBarIndexById)
            if (not slot) and wowKey and wowKey ~= "" and layoutKeyToSlots[wowKey] then
                for _, candidate in ipairs(layoutKeyToSlots[wowKey]) do
                    if not slotData[candidate] then
                        slot = candidate
                        break
                    end
                end
            end
            if (not slot) and ((kb.barId or kb.bar_id) and (kb.slotIndex or kb.slot_index) ~= nil) then
                if (not wowKey) or wowKey == "" or not layoutKeyToSlots[wowKey] then
                    local explicitSlot = resolveExplicitSlotCandidate(kb, layoutBarIndexById)
                    if explicitSlot and not slotData[explicitSlot] then
                        slot = explicitSlot
                    end
                end
            end

            if slot then
                if spellName == "" and _G.GetSpellInfo then
                    local parsedId = tonumber(spell.spellId or spell.spell_id or spell.id)
                    if not parsedId then
                        local rawSpellId = tostring(spell.spellId or spell.spell_id or spell.id or "")
                        local numericOnly = rawSpellId:gsub("[^0-9]", "")
                        if numericOnly ~= "" then
                            parsedId = tonumber(numericOnly)
                        end
                    end
                    if parsedId then
                        local maybeName = _G.GetSpellInfo(parsedId)
                        if maybeName and maybeName ~= "" then
                            spellName = tostring(maybeName)
                        end
                    end
                end
                local nextEntry = {
                    key = tostring(kb.key or ""),
                    spellName = spellName ~= "" and spellName or "(no spell)",
                    icon = spellIcon,
                }
                local existingEntry = slotData[slot]
                if not existingEntry then
                    slotData[slot] = nextEntry
                else
                    local existingHasVisual = existingEntry.icon and tostring(existingEntry.icon) ~= ""
                    local nextHasVisual = nextEntry.icon and tostring(nextEntry.icon) ~= ""
                    local existingHasName = existingEntry.spellName and existingEntry.spellName ~= "" and existingEntry.spellName ~= "(no spell)"
                    local nextHasName = nextEntry.spellName and nextEntry.spellName ~= "" and nextEntry.spellName ~= "(no spell)"
                    if (nextHasVisual and not existingHasVisual)
                        or (nextHasName and not existingHasName) then
                        slotData[slot] = nextEntry
                    end
                end
                if debugViewerSlots then
                    addonChat("|cffffcc00[WoWKeyb]|r [viewer-debug] slot=" .. tostring(slot)
                        .. " key=" .. tostring(kb.key or "")
                        .. " normalized=" .. tostring(wowKey or "")
                        .. " spellId=" .. tostring(spell.spellId or spell.spell_id or spell.id or "")
                        .. " spell=\"" .. tostring(spellName ~= "" and spellName or "(no spell)") .. "\""
                        .. " icon=" .. tostring(spellIcon and "yes" or "no"))
                end
            elseif debugViewerSlots then
                addonChat("|cffffcc00[WoWKeyb]|r [viewer-debug] slot=<none>"
                    .. " key=" .. tostring(kb.key or "")
                    .. " normalized=" .. tostring(wowKey or "")
                    .. " spellId=" .. tostring(spell.spellId or spell.spell_id or spell.id or "")
                    .. " spell=\"" .. tostring(spellName or "") .. "\" reason=no-resolved-slot")
            end
        end
    end

    for barIdx = 1, 5 do
        local bar = bars[barIdx]
        local slotKeys = (bar and type(bar.slotKeys) == "table" and bar.slotKeys)
            or (bar and type(bar.slot_keys) == "table" and bar.slot_keys)
            or {}
        for slotIdx = 1, 12 do
            local globalSlot = ((barIdx - 1) * 12) + slotIdx
            local existing = slotData[globalSlot]
            local fallbackKey = tostring(slotKeys[slotIdx] or "")
            if existing then
                if (not existing.key or existing.key == "") and fallbackKey ~= "" then
                    existing.key = fallbackKey
                end
            else
                slotData[globalSlot] = {
                    key = fallbackKey,
                    spellName = "-",
                    icon = nil,
                }
            end
        end
    end

    -- Build keyboard entries from final resolved slot data so layout.slotKeys (e.g. Shift+5)
    -- are reflected even when original keybind records have empty/missing key fields.
    keyToEntries = {}
    for slot = 1, 60 do
        local entry = slotData[slot]
        if entry and entry.key and entry.key ~= "" then
            local normalizedEntryKey = normalizeKey(entry.key)
            local baseKey = viewerBaseKey(normalizedEntryKey)
            if baseKey and baseKey ~= "" then
                keyToEntries[baseKey] = keyToEntries[baseKey] or {}
                table.insert(keyToEntries[baseKey], {
                    key = tostring(entry.key or ""),
                    spellName = tostring(entry.spellName or "-"),
                    icon = entry.icon,
                    slot = slot,
                })
            end
        end
    end

    return keyToEntries, slotData
end

local function setBarViewerCell(cell, key, spellName, icon)
    if not cell then return end
    local cleanKey = (key and key ~= "") and key or "-"
    -- Keep slot visuals icon-only; show keybind details on hover tooltip.
    cell.keyText:SetText("")
    cell.spellText:SetText("")
    cell.viewerKey = cleanKey
    cell.viewerSpellName = (spellName and spellName ~= "") and spellName or "-"
    cell.viewerIcon = icon
    if icon and icon ~= "" then
        cell.icon:SetTexture(icon)
        cell.icon:Show()
    else
        cell.icon:SetTexture(nil)
        cell.icon:Hide()
    end
end

local function slotToBarSlotLabel(slot)
    if not slot then return "Unmapped" end
    local bar = math.floor((slot - 1) / 12) + 1
    local idx = ((slot - 1) % 12) + 1
    return string.format("Bar %d Slot %d", bar, idx)
end

local function showBarCellTooltip(cell)
    if not cell then return end
    local slot = cell.viewerSlot
    local keyLabel = tostring(cell.viewerKey or "-")
    local spellLabel = tostring(cell.viewerSpellName or "-")
    local icon = cell.viewerIcon

    GameTooltip:SetOwner(cell, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(slotToBarSlotLabel(slot), 1, 1, 1)
    if icon and icon ~= "" then
        GameTooltip:AddLine(string.format("|T%s:14|t %s", tostring(icon), spellLabel), 0.95, 0.95, 0.95)
    else
        GameTooltip:AddLine(spellLabel, 0.95, 0.95, 0.95)
    end
    GameTooltip:AddLine("Bind: " .. keyLabel, 0.8, 0.8, 0.8)
    GameTooltip:Show()
end

local function showKeyboardCellTooltip(cell)
    local key = cell and cell.viewerKey
    if not key then return end
    local entries = (cell and cell.viewerEntries) or {}

    GameTooltip:SetOwner(cell, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("Key: " .. tostring(key), 1, 1, 1)
    if #entries == 0 then
        GameTooltip:AddLine("No abilities assigned", 0.8, 0.8, 0.8)
    else
        GameTooltip:AddLine(string.format("%d ability binding(s)", #entries), 0.8, 0.8, 0.8)
        for _, entry in ipairs(entries) do
            local iconPrefix = ""
            if entry.icon and entry.icon ~= "" then
                iconPrefix = string.format("|T%s:14|t ", tostring(entry.icon))
            end
            local name = entry.spellName or "(no spell)"
            local slotLabel = slotToBarSlotLabel(entry.slot)
            local keyLabel = tostring(entry.key or key or "-")
            GameTooltip:AddLine(
                string.format("%s%s - %s - Bind: %s", iconPrefix, name, slotLabel, keyLabel),
                0.95, 0.95, 0.95
            )
        end
    end
    GameTooltip:Show()
end

local function setKeyboardViewerCell(cell, key, entries)
    if not cell then return end
    local cleanKey = (key and key ~= "") and key or "-"
    local list = entries or {}
    local first = list[1]
    cell.viewerKey = cleanKey
    cell.viewerEntries = list
    cell.keyText:SetText(cleanKey)

    if first and first.icon and first.icon ~= "" then
        cell.icon:SetTexture(first.icon)
        cell.icon:Show()
    else
        cell.icon:SetTexture(nil)
        cell.icon:Hide()
    end

    if #list > 1 then
        cell.countText:SetText("x" .. tostring(#list))
        cell.countText:Show()
    else
        cell.countText:SetText("")
        cell.countText:Hide()
    end
end

local function refreshViewerFrame(frame)
    if not frame or not frame.profileName then return end
    local profile = getStoredProfile(frame.profileName)
    if not profile then return end

    frame.metaText:SetText(string.format(
        "Profile: %s    Class: %s    Spec: %s    Hero Talent: %s",
        tostring(profile.name or frame.profileName or "Unknown"),
        tostring(profile.class or "Unknown"),
        tostring(profile.spec or "-"),
        tostring(profile.heroTalent or "-")
    ))

    local keyToEntries, slotData = buildViewerData(profile)

    for key, cell in pairs(frame.keyboardCells) do
        local entries = keyToEntries[key] or {}
        setKeyboardViewerCell(cell, key, entries)
    end

    for barIdx = 1, 5 do
        for slotIdx = 1, 12 do
            local globalSlot = ((barIdx - 1) * 12) + slotIdx
            local data = slotData[globalSlot] or { key = "-", spellName = "-", icon = nil }
            local cell = frame.barCells[barIdx][slotIdx]
            setBarViewerCell(cell, data.key, data.spellName, data.icon)
        end
    end
end

local viewerFrame
function WoWKeyb:ShowKeybindingViewer(profileName)
    local target = profileName or WoWKeybDB.currentProfile
    if not target or target == BLIZZARD_DEFAULT_PROFILE then
        print("|cffff0000[WoWKeyb]|r Select a non-default profile first.")
        return
    end
    local profile = getStoredProfile(target)
    if not profile then
        print("|cffff0000[WoWKeyb]|r Profile not found: " .. tostring(target))
        return
    end

    if viewerFrame and viewerFrame:IsShown() then
        viewerFrame:Hide()
    end

    if not viewerFrame then
        viewerFrame = CreateFrame("Frame", "WoWKeybViewerFrame", UIParent, "BackdropTemplate")
        viewerFrame:SetSize(1020, 740)
        viewerFrame:SetPoint("CENTER")
        viewerFrame:SetFrameStrata("DIALOG")
        viewerFrame:SetFrameLevel(120)
        if viewerFrame.SetBackdrop then
            viewerFrame:SetBackdrop({
                bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                tile = true, tileSize = 32, edgeSize = 32,
                insets = { left = 11, right = 12, top = 12, bottom = 11 },
            })
        end
        viewerFrame:SetMovable(true)
        viewerFrame:EnableMouse(true)
        viewerFrame:RegisterForDrag("LeftButton")
        viewerFrame:SetScript("OnDragStart", function() viewerFrame:StartMoving() end)
        viewerFrame:SetScript("OnDragStop", function() viewerFrame:StopMovingOrSizing() end)

        local title = viewerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOPLEFT", 18, -18)
        title:SetText("WoWKeyb - Keybinding Viewer (read-only)")

        local subtitle = viewerFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
        subtitle:SetText("Visual read-only keyboard and action bar mapping")

        local metaText = viewerFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        metaText:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -8)
        metaText:SetText("")
        viewerFrame.metaText = metaText

        local keyboardTitle = viewerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        keyboardTitle:SetPoint("TOPLEFT", metaText, "BOTTOMLEFT", 0, -12)
        keyboardTitle:SetText("Keyboard (base keys)")

        local keyboardContainer = CreateFrame("Frame", nil, viewerFrame, "BackdropTemplate")
        keyboardContainer:SetPoint("TOPLEFT", keyboardTitle, "BOTTOMLEFT", 0, -6)
        keyboardContainer:SetSize(980, 220)
        if keyboardContainer.SetBackdrop then
            keyboardContainer:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = false, edgeSize = 10,
                insets = { left = 2, right = 2, top = 2, bottom = 2 },
            })
            keyboardContainer:SetBackdropColor(0.05, 0.05, 0.06, 0.9)
            keyboardContainer:SetBackdropBorderColor(0.25, 0.25, 0.3, 0.9)
        end

        viewerFrame.keyboardCells = {}
        local keyboardRows = {
            { keys = { "1","2","3","4","5","6","7","8","9","0","-","=" }, indent = 12 },
            { keys = { "Q","W","E","R","T","Y","U","I","O","P" }, indent = 44 },
            { keys = { "A","S","D","F","G","H","J","K","L" }, indent = 62 },
            { keys = { "Z","X","C","V","B","N","M" }, indent = 94 },
        }

        local keyW, keyH, gap = 66, 44, 6
        for rowIdx, row in ipairs(keyboardRows) do
            for colIdx, key in ipairs(row.keys) do
                local cell = CreateFrame("Frame", nil, keyboardContainer, "BackdropTemplate")
                cell:SetSize(keyW, keyH)
                cell:SetPoint("TOPLEFT", row.indent + (colIdx - 1) * (keyW + gap), -10 - (rowIdx - 1) * (keyH + 8))
                if cell.SetBackdrop then
                    cell:SetBackdrop({
                        bgFile = "Interface\\Buttons\\WHITE8X8",
                        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                        tile = false, edgeSize = 8,
                        insets = { left = 1, right = 1, top = 1, bottom = 1 },
                    })
                    cell:SetBackdropColor(0.12, 0.12, 0.15, 0.95)
                    cell:SetBackdropBorderColor(0.35, 0.35, 0.4, 0.95)
                end

                cell.icon = cell:CreateTexture(nil, "ARTWORK")
                cell.icon:SetSize(18, 18)
                cell.icon:SetPoint("LEFT", 4, 0)
                cell.icon:Hide()

                cell.keyText = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                cell.keyText:SetPoint("TOPRIGHT", -4, -4)
                cell.keyText:SetText(key)

                cell.countText = cell:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                cell.countText:SetPoint("BOTTOMRIGHT", -4, 4)
                cell.countText:SetText("")
                cell.countText:Hide()

                cell:SetScript("OnEnter", function(self)
                    if self.SetBackdropColor then
                        self:SetBackdropColor(0.18, 0.18, 0.22, 0.98)
                    end
                    if self.SetBackdropBorderColor then
                        self:SetBackdropBorderColor(0.6, 0.6, 0.75, 1)
                    end
                    showKeyboardCellTooltip(self)
                end)
                cell:SetScript("OnLeave", function(self)
                    if self.SetBackdropColor then
                        self:SetBackdropColor(0.12, 0.12, 0.15, 0.95)
                    end
                    if self.SetBackdropBorderColor then
                        self:SetBackdropBorderColor(0.35, 0.35, 0.4, 0.95)
                    end
                    GameTooltip:Hide()
                end)

                viewerFrame.keyboardCells[key] = cell
            end
        end

        local barsTitle = viewerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        barsTitle:SetPoint("TOPLEFT", keyboardContainer, "BOTTOMLEFT", 0, -12)
        barsTitle:SetText("Blizzard Action Bars (1-5)")

        local barsContainer = CreateFrame("Frame", nil, viewerFrame, "BackdropTemplate")
        barsContainer:SetPoint("TOPLEFT", barsTitle, "BOTTOMLEFT", 0, -6)
        -- Keep a large footer gap so the bottom action bar never overlaps controls.
        barsContainer:SetSize(980, 322)
        if barsContainer.SetBackdrop then
            barsContainer:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = false, edgeSize = 10,
                insets = { left = 2, right = 2, top = 2, bottom = 2 },
            })
            barsContainer:SetBackdropColor(0.05, 0.05, 0.06, 0.9)
            barsContainer:SetBackdropBorderColor(0.25, 0.25, 0.3, 0.9)
        end

        viewerFrame.barCells = {}
        local slotSize, slotGap, rowHeight = 38, 5, 60
        for barIdx = 1, 5 do
            local barLabel = barsContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            barLabel:SetPoint("TOPLEFT", 10, -12 - (barIdx - 1) * rowHeight)
            barLabel:SetText("Bar " .. tostring(barIdx))

            viewerFrame.barCells[barIdx] = {}
            for slotIdx = 1, 12 do
                local cell = CreateFrame("Frame", nil, barsContainer, "BackdropTemplate")
                cell:SetSize(slotSize, slotSize)
                cell:SetPoint("TOPLEFT", 80 + (slotIdx - 1) * (slotSize + slotGap), -8 - (barIdx - 1) * rowHeight)
                if cell.SetBackdrop then
                    cell:SetBackdrop({
                        bgFile = "Interface\\Buttons\\WHITE8X8",
                        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                        tile = false, edgeSize = 8,
                        insets = { left = 1, right = 1, top = 1, bottom = 1 },
                    })
                    cell:SetBackdropColor(0.12, 0.12, 0.15, 0.95)
                    cell:SetBackdropBorderColor(0.35, 0.35, 0.4, 0.95)
                end

                cell.icon = cell:CreateTexture(nil, "ARTWORK")
                cell.icon:SetPoint("TOPLEFT", 2, -2)
                cell.icon:SetPoint("BOTTOMRIGHT", -2, 2)
                cell.icon:Hide()

                cell.keyText = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                cell.keyText:SetPoint("TOPLEFT", 2, -2)
                cell.keyText:SetText("")

                cell.spellText = cell:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                cell.spellText:SetPoint("BOTTOMLEFT", 2, 2)
                cell.spellText:SetPoint("BOTTOMRIGHT", -2, 2)
                cell.spellText:SetJustifyH("LEFT")
                cell.spellText:SetText("")
                cell.viewerSlot = ((barIdx - 1) * 12) + slotIdx

                cell:SetScript("OnEnter", function(self)
                    if self.SetBackdropColor then
                        self:SetBackdropColor(0.18, 0.18, 0.22, 0.98)
                    end
                    if self.SetBackdropBorderColor then
                        self:SetBackdropBorderColor(0.6, 0.6, 0.75, 1)
                    end
                    showBarCellTooltip(self)
                end)
                cell:SetScript("OnLeave", function(self)
                    if self.SetBackdropColor then
                        self:SetBackdropColor(0.12, 0.12, 0.15, 0.95)
                    end
                    if self.SetBackdropBorderColor then
                        self:SetBackdropBorderColor(0.35, 0.35, 0.4, 0.95)
                    end
                    GameTooltip:Hide()
                end)

                viewerFrame.barCells[barIdx][slotIdx] = cell
            end
        end

        local refreshBtn = CreateFrame("Button", nil, viewerFrame, "UIPanelButtonTemplate")
        refreshBtn:SetSize(120, 22)
        refreshBtn:SetPoint("BOTTOM", viewerFrame, "BOTTOM", 140, 18)
        refreshBtn:SetText("Refresh")
        refreshBtn:SetScript("OnClick", function()
            refreshViewerFrame(viewerFrame)
        end)

        local applyBtn = CreateFrame("Button", nil, viewerFrame, "UIPanelButtonTemplate")
        applyBtn:SetSize(120, 22)
        applyBtn:SetPoint("BOTTOM", viewerFrame, "BOTTOM", 0, 18)
        applyBtn:SetText("Apply Profile")
        applyBtn:SetScript("OnClick", function()
            local target = viewerFrame and viewerFrame.profileName
            if not target then
                print("|cffff0000[WoWKeyb]|r No selected profile to apply.")
                return
            end
            local okApply, resultApply = applySelectionByName(target)
            if okApply then
                print("|cff00ff00[WoWKeyb]|r " .. tostring(resultApply))
            else
                print("|cffff0000[WoWKeyb]|r Failed to apply profile: " .. tostring(resultApply or "Unknown error"))
            end
            if WoWKeyb.optionsPanel and WoWKeyb.optionsPanel.refreshCurrentProfileText then
                WoWKeyb.optionsPanel.refreshCurrentProfileText()
            end
            if WoWKeyb.optionsPanel and WoWKeyb.optionsPanel.refreshProfileSelector then
                WoWKeyb.optionsPanel.refreshProfileSelector()
            end
            refreshViewerFrame(viewerFrame)
        end)

        local closeBtn = CreateFrame("Button", nil, viewerFrame, "UIPanelButtonTemplate")
        closeBtn:SetSize(120, 22)
        closeBtn:SetPoint("BOTTOM", viewerFrame, "BOTTOM", -140, 18)
        closeBtn:SetText("Close")
        closeBtn:SetScript("OnClick", function() viewerFrame:Hide() end)
    end

    viewerFrame.profileName = target
    viewerFrame:Show()
    refreshViewerFrame(viewerFrame)
end

local exportFrame
function WoWKeyb:ShowExportDialog(profileName)
    local profile = getStoredProfile(profileName)
    if not profile then
        print("|cffff0000[WoWKeyb]|r Profile not found: " .. tostring(profileName))
        return
    end

    -- Export should reflect current in-game bars/bindings so users can round-trip
    -- from game -> addon export -> web import without losing edits.
    syncProfileSpellsFromActionBars(profileName)
    syncProfileLayoutKeysFromBindings(profileName)

    local json, err = serializeSyncedProfile(profileName, profile)
    if not json then
        print("|cffff0000[WoWKeyb]|r Failed to build export share code payload: " .. tostring(err or "unknown error"))
        return
    end
    local shareCode = encodeProfileShareCode(json)

    if exportFrame and exportFrame:IsShown() then
        exportFrame:Hide()
    end

    if not exportFrame then
        exportFrame = CreateFrame("Frame", "WoWKeybExportFrame", UIParent, "BackdropTemplate")
        exportFrame:SetSize(560, 420)
        exportFrame:SetPoint("CENTER")
        exportFrame:SetFrameStrata("DIALOG")
        exportFrame:SetFrameLevel(110)
        if exportFrame.SetBackdrop then
            exportFrame:SetBackdrop({
                bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                tile = true, tileSize = 32, edgeSize = 32,
                insets = { left = 11, right = 12, top = 12, bottom = 11 }
            })
        end
        exportFrame:SetMovable(true)
        exportFrame:EnableMouse(true)
        exportFrame:RegisterForDrag("LeftButton")
        exportFrame:SetScript("OnDragStart", function() exportFrame:StartMoving() end)
        exportFrame:SetScript("OnDragStop", function() exportFrame:StopMovingOrSizing() end)

        local title = exportFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOP", 0, -20)
        title:SetText("WoWKeyb - Export Share Code")

        local subtitle = exportFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        subtitle:SetPoint("TOP", title, "BOTTOM", 0, -6)
        subtitle:SetText("Copy this share code and import it in WoWKeyb.")

        local scroll = CreateFrame("ScrollFrame", "WoWKeybExportScroll", exportFrame, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 20, -62)
        scroll:SetPoint("BOTTOMRIGHT", -40, 60)

        local edit = CreateFrame("EditBox", "WoWKeybExportEdit", scroll)
        edit:SetSize(480, 320)
        edit:SetMultiLine(true)
        edit:SetAutoFocus(false)
        edit:EnableKeyboard(true)
        edit:EnableMouse(true)
        edit:SetMaxLetters(0)
        edit:SetFontObject("GameFontHighlightSmall")
        edit:SetTextInsets(6, 6, 6, 6)
        edit:SetScript("OnEscapePressed", function() exportFrame:Hide() end)
        edit:SetScript("OnEnterPressed", function(self)
            self:Insert("\n")
        end)
        scroll:SetScrollChild(edit)
        exportFrame.editBox = edit

        local selectBtn = CreateFrame("Button", nil, exportFrame, "UIPanelButtonTemplate")
        selectBtn:SetSize(150, 22)
        selectBtn:SetPoint("BOTTOM", exportFrame, "BOTTOM", 90, 20)
        selectBtn:SetText("Select All")
        selectBtn:SetScript("OnClick", function()
            if exportFrame.editBox then
                exportFrame.editBox:SetFocus()
                exportFrame.editBox:HighlightText()
            end
        end)

        local closeBtn = CreateFrame("Button", nil, exportFrame, "UIPanelButtonTemplate")
        closeBtn:SetSize(120, 22)
        closeBtn:SetPoint("BOTTOM", exportFrame, "BOTTOM", -90, 20)
        closeBtn:SetText("Close")
        closeBtn:SetScript("OnClick", function() exportFrame:Hide() end)
    end

    exportFrame:Show()
    WoWKeybExportEdit:SetText(shareCode)
    WoWKeybExportEdit:SetFocus()
    WoWKeybExportEdit:HighlightText()
end

local function openAddonSettings()
    if Settings and Settings.OpenToCategory and WoWKeyb.settingsCategoryID then
        Settings.OpenToCategory(WoWKeyb.settingsCategoryID)
        return
    end
    if InterfaceOptionsFrame_OpenToCategory and WoWKeyb.optionsPanel then
        InterfaceOptionsFrame_OpenToCategory(WoWKeyb.optionsPanel)
        InterfaceOptionsFrame_OpenToCategory(WoWKeyb.optionsPanel) -- Call twice for older Blizzard quirk
    end
end

local function createSettingsPanel()
    if WoWKeyb.optionsPanel then return end

    local panel = CreateFrame("Frame", "WoWKeybOptionsPanel", UIParent)
    panel.name = "WoWKeyb"
    local selectedProfileName = nil

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("WoWKeyb")

    local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    subtitle:SetText("Import and apply your WoWKeyb profiles.")

    local versionText = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    versionText:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -4)
    versionText:SetText("Version: " .. getAddonVersion())

    local currentProfileText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    currentProfileText:SetPoint("TOPLEFT", versionText, "BOTTOMLEFT", 0, -14)
    currentProfileText:SetText("Current profile: None")

    local function refreshCurrentProfileText()
        currentProfileText:SetText("Current profile: " .. tostring(WoWKeybDB.currentProfile or "None"))
    end
    panel.refreshCurrentProfileText = refreshCurrentProfileText
    refreshCurrentProfileText()

    local profileLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    profileLabel:SetPoint("TOPLEFT", currentProfileText, "BOTTOMLEFT", 0, -18)
    profileLabel:SetText("Selected profile:")

    local profileDropdown = CreateFrame("Frame", "WoWKeybProfileDropdown", panel, "UIDropDownMenuTemplate")
    profileDropdown:SetPoint("TOPLEFT", profileLabel, "BOTTOMLEFT", -16, -4)
    UIDropDownMenu_SetWidth(profileDropdown, 220)
    local applyBtn

    local profileStatusText = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    profileStatusText:SetPoint("TOPLEFT", profileDropdown, "TOPRIGHT", 24, 20)
    profileStatusText:SetWidth(360)
    profileStatusText:SetJustifyH("LEFT")
    profileStatusText:SetJustifyV("TOP")
    if profileStatusText.SetWordWrap then
        profileStatusText:SetWordWrap(true)
    end
    if profileStatusText.SetMaxLines then
        profileStatusText:SetMaxLines(18)
    end
    profileStatusText:SetText("")

    local function selectedProfileCanApply()
        local target = selectedProfileName or BLIZZARD_DEFAULT_PROFILE
        if target == BLIZZARD_DEFAULT_PROFILE then
            return true
        end
        local profile = WoWKeybDB.profiles[target]
        if not profile then
            return false
        end
        local diagnostics = getProfileMatchDiagnostics(profile)
        return diagnostics and diagnostics.matches or false
    end

    local function refreshApplyButtonState()
        if not applyBtn then return end
        local canApply = selectedProfileCanApply()
        if applyBtn.Enable then
            if canApply then
                applyBtn:Enable()
            else
                applyBtn:Disable()
            end
        end
        applyBtn:SetText("Apply Selected Profile")
    end

    local function refreshProfileSelector()
        local profiles = listStoredProfiles(false)
        local selectorOptions = { BLIZZARD_DEFAULT_PROFILE }
        for _, name in ipairs(profiles) do
            table.insert(selectorOptions, name)
        end
        -- Keep the most recently imported profile visible in the selector
        -- even if strict class/spec/hero filtering currently excludes it.
        local forceVisibleProfile = panel.forceVisibleProfileName
        if forceVisibleProfile and forceVisibleProfile ~= BLIZZARD_DEFAULT_PROFILE and WoWKeybDB.profiles[forceVisibleProfile] then
            local alreadyListed = false
            for _, optionName in ipairs(selectorOptions) do
                if optionName == forceVisibleProfile then
                    alreadyListed = true
                    break
                end
            end
            if not alreadyListed then
                table.insert(selectorOptions, forceVisibleProfile)
            end
        end

        -- Keep dropdown aligned with real applied/current profile state,
        -- especially after imports that update WoWKeybDB.currentProfile.
        local preferredSelection = WoWKeybDB.currentProfile or BLIZZARD_DEFAULT_PROFILE
        if preferredSelection == BLIZZARD_DEFAULT_PROFILE or WoWKeybDB.profiles[preferredSelection] then
            selectedProfileName = preferredSelection
        end

        local isValidSelection = false
        for _, name in ipairs(selectorOptions) do
            if name == selectedProfileName then
                isValidSelection = true
                break
            end
        end
        if not isValidSelection then
            selectedProfileName = WoWKeybDB.currentProfile or BLIZZARD_DEFAULT_PROFILE
            local selectedIsStoredProfile = selectedProfileName == BLIZZARD_DEFAULT_PROFILE or WoWKeybDB.profiles[selectedProfileName]
            if not selectedIsStoredProfile then
                selectedProfileName = BLIZZARD_DEFAULT_PROFILE
            end
        end

        local contextKey = buildCurrentPlayerContextKey()
        local preferredProfile = getPreferredProfileForCurrentContext()
        local labels = buildPlayerLabelCollection()
        local classLabel = labels.class.variants[1] or "Unknown"
        local specLabel = labels.spec.names[1] or labels.spec.ids[1] or "-"
        local heroLabel = labels.hero.names[1] or labels.hero.ids[1] or "-"

        local mismatchLines = {}
        local matchingProfiles = {}
        local function summarizeNames(items, maxShown)
            local count = #items
            if count == 0 then
                return "none"
            end
            local shown = {}
            local limit = math.min(count, maxShown)
            for i = 1, limit do
                shown[#shown + 1] = tostring(items[i])
            end
            local summary = table.concat(shown, ", ")
            if count > maxShown then
                summary = summary .. string.format(" ... +%d more", count - maxShown)
            end
            return summary
        end
        UIDropDownMenu_Initialize(profileDropdown, function(self, level)
            for _, name in ipairs(selectorOptions) do
                local info = UIDropDownMenu_CreateInfo()
                local displayName = name
                if name ~= BLIZZARD_DEFAULT_PROFILE then
                    local profile = WoWKeybDB.profiles[name]
                    local diagnostics = getProfileMatchDiagnostics(profile)
                    local contextSummary = getProfileContextSummary(profile)
                    displayName = string.format("%s [%s]", displayName, contextSummary)
                    if preferredProfile and name == preferredProfile then
                        displayName = displayName .. " - PREFERRED"
                    end
                    if diagnostics and not diagnostics.matches then
                        displayName = string.format("%s - NO MATCH (%s)", displayName, diagnostics.reasonSummary)
                        local profileClass = tostring(profile and profile.class or "Unknown")
                        local profileSpec = tostring(profile and (profile.spec or profile.spec_id or profile.specId or profile.specialization) or "-")
                        local profileHero = tostring(profile and (profile.heroTalent or profile.hero_talent or profile.hero_talent_id or profile.heroTalentId) or "-")
                        mismatchLines[#mismatchLines + 1] = string.format(
                            " - %s: %s (profile: %s / %s / %s)",
                            name,
                            tostring(diagnostics.reasonSummary or "unknown"),
                            profileClass,
                            profileSpec,
                            profileHero
                        )
                    else
                        matchingProfiles[#matchingProfiles + 1] = name
                    end
                end
                info.text = displayName
                info.checked = (name == selectedProfileName)
                info.func = function()
                    selectedProfileName = name
                    UIDropDownMenu_SetText(profileDropdown, name)
                    panel.forceVisibleProfileName = nil
                    refreshApplyButtonState()
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
        UIDropDownMenu_SetText(profileDropdown, selectedProfileName or BLIZZARD_DEFAULT_PROFILE)
        refreshApplyButtonState()

        local mismatchCount = #mismatchLines
        local mismatchLinesToShow = {}
        local mismatchLimit = 6
        for i = 1, math.min(mismatchCount, mismatchLimit) do
            mismatchLinesToShow[#mismatchLinesToShow + 1] = mismatchLines[i]
        end

        local statusLines = {
            string.format("Character setup: %s / %s / %s", tostring(classLabel), tostring(specLabel), tostring(heroLabel)),
            string.format("Auto-select key: %s", tostring(contextKey)),
            string.format("Preferred for this setup: %s", tostring(preferredProfile or "none")),
            string.format("Profiles for this setup (%d): %s", #matchingProfiles, summarizeNames(matchingProfiles, 6)),
            "",
        }
        if mismatchCount == 0 then
            statusLines[#statusLines + 1] = "Other profiles: none"
        else
            statusLines[#statusLines + 1] = string.format("Other profiles (%d):", mismatchCount)
            for _, line in ipairs(mismatchLinesToShow) do
                statusLines[#statusLines + 1] = line
            end
            if mismatchCount > mismatchLimit then
                statusLines[#statusLines + 1] = string.format(" - ... +%d more (use /wowkeyb contexts)", mismatchCount - mismatchLimit)
            end
        end
        profileStatusText:SetText(table.concat(statusLines, "\n"))
    end
    panel.refreshProfileSelector = refreshProfileSelector
    refreshProfileSelector()

    applyBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    applyBtn:SetSize(180, 24)
    applyBtn:SetPoint("TOPLEFT", profileDropdown, "BOTTOMLEFT", 16, -10)
    applyBtn:SetText("Apply Selected Profile")
    applyBtn:SetScript("OnClick", function()
        local target = selectedProfileName or BLIZZARD_DEFAULT_PROFILE
        if not target then
            print("|cffff0000[WoWKeyb]|r No selected profile to apply.")
            return
        end
        if target ~= BLIZZARD_DEFAULT_PROFILE and not selectedProfileCanApply() then
            print("|cffff0000[WoWKeyb]|r Selected profile does not match current class/spec/hero and cannot be applied.")
            return
        end
        local ok, result = applySelectionByName(target)
        if ok then
            print("|cff00ff00[WoWKeyb]|r " .. tostring(result))
        else
            print("|cffff0000[WoWKeyb]|r " .. tostring(result or "Failed to apply"))
        end
        refreshCurrentProfileText()
        refreshProfileSelector()
    end)
    refreshApplyButtonState()

    local importBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    importBtn:SetSize(180, 24)
    importBtn:SetPoint("TOPLEFT", applyBtn, "BOTTOMLEFT", 0, -8)
    importBtn:SetText("Import Profile")
    importBtn:SetScript("OnClick", function()
        WoWKeyb:ShowImportDialog("ImportedProfile")
    end)

    local exportBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    exportBtn:SetSize(180, 24)
    exportBtn:SetPoint("TOPLEFT", importBtn, "BOTTOMLEFT", 0, -8)
    exportBtn:SetText("Export Selected Profile")
    exportBtn:SetScript("OnClick", function()
        local target = selectedProfileName or WoWKeybDB.currentProfile
        if not target then
            print("|cffff0000[WoWKeyb]|r No selected profile to export.")
            return
        end
        if target == BLIZZARD_DEFAULT_PROFILE then
            print("|cffff0000[WoWKeyb]|r Blizzard Default cannot be exported.")
            return
        end
        WoWKeyb:ShowExportDialog(target)
    end)

    local viewerBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    viewerBtn:SetSize(180, 24)
    viewerBtn:SetPoint("TOPLEFT", exportBtn, "BOTTOMLEFT", 0, -8)
    viewerBtn:SetText("View Keybinding Map")
    viewerBtn:SetScript("OnClick", function()
        local target = selectedProfileName or WoWKeybDB.currentProfile
        if not target then
            print("|cffff0000[WoWKeyb]|r No selected profile to view.")
            return
        end
        if target == BLIZZARD_DEFAULT_PROFILE then
            print("|cffff0000[WoWKeyb]|r Blizzard Default has no profile mapping to view.")
            return
        end
        WoWKeyb:ShowKeybindingViewer(target)
    end)

    local renameBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    renameBtn:SetSize(180, 24)
    renameBtn:SetPoint("TOPLEFT", viewerBtn, "BOTTOMLEFT", 0, -8)
    renameBtn:SetText("Rename Selected Profile")

    local deleteBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    deleteBtn:SetSize(180, 24)
    deleteBtn:SetPoint("TOPLEFT", renameBtn, "BOTTOMLEFT", 0, -8)
    deleteBtn:SetText("Delete Selected Profile")

    local function renameProfileByName(oldName, newName)
        local sourceName = tostring(oldName or ""):gsub("^%s+", ""):gsub("%s+$", "")
        local targetName = tostring(newName or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if sourceName == "" then
            print("|cffff0000[WoWKeyb]|r No selected profile.")
            return
        end
        if sourceName == BLIZZARD_DEFAULT_PROFILE then
            print("|cffff0000[WoWKeyb]|r Blizzard Default cannot be renamed.")
            return
        end
        if not WoWKeybDB.profiles[sourceName] then
            print("|cffff0000[WoWKeyb]|r Profile not found: " .. sourceName)
            return
        end
        if targetName == "" then
            print("|cffff0000[WoWKeyb]|r New profile name cannot be empty.")
            return
        end
        if targetName == BLIZZARD_DEFAULT_PROFILE then
            print("|cffff0000[WoWKeyb]|r That name is reserved.")
            return
        end
        if targetName ~= sourceName and WoWKeybDB.profiles[targetName] then
            print("|cffff0000[WoWKeyb]|r A profile with that name already exists.")
            return
        end
        if targetName == sourceName then
            return
        end

        local profile = WoWKeybDB.profiles[sourceName]
        profile.name = targetName
        WoWKeybDB.profiles[targetName] = profile
        WoWKeybDB.profiles[sourceName] = nil

        if WoWKeybDB.currentProfile == sourceName then
            WoWKeybDB.currentProfile = targetName
        end
        if WoWKeybDB.previousProfile == sourceName then
            WoWKeybDB.previousProfile = targetName
        end
        if panel.forceVisibleProfileName == sourceName then
            panel.forceVisibleProfileName = targetName
        end
        for contextKey, preferredName in pairs(WoWKeybDB.preferredProfileByContext or {}) do
            if preferredName == sourceName then
                WoWKeybDB.preferredProfileByContext[contextKey] = targetName
            end
        end

        selectedProfileName = targetName
        print("|cff00ff00[WoWKeyb]|r Renamed profile: " .. sourceName .. " -> " .. targetName)
        refreshProfileSelector()
        refreshCurrentProfileText()
    end

    if not StaticPopupDialogs["WOWKEYB_RENAME_PROFILE"] then
        StaticPopupDialogs["WOWKEYB_RENAME_PROFILE"] = {
            text = "Rename selected WoWKeyb profile \"%s\"",
            button1 = "Rename",
            button2 = "Cancel",
            hasEditBox = true,
            maxLetters = 100,
            OnShow = function(self, data)
                local editBox = self.editBox
                if not editBox then return end
                editBox:SetAutoFocus(true)
                editBox:SetText((data and data.oldName) or "")
                editBox:HighlightText()
            end,
            OnAccept = function(self, data)
                local editBox = self and self.editBox
                local newName = editBox and editBox:GetText() or ""
                local oldName = data and data.oldName or nil
                renameProfileByName(oldName, newName)
            end,
            EditBoxOnEnterPressed = function(self)
                local parent = self:GetParent()
                if parent then
                    local data = parent.data
                    local oldName = data and data.oldName or nil
                    local newName = self:GetText() or ""
                    renameProfileByName(oldName, newName)
                    parent:Hide()
                end
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end

    renameBtn:SetScript("OnClick", function()
        local target = selectedProfileName
        if not target then
            print("|cffff0000[WoWKeyb]|r No selected profile.")
            return
        end
        if target == BLIZZARD_DEFAULT_PROFILE then
            print("|cffff0000[WoWKeyb]|r Blizzard Default cannot be renamed.")
            return
        end
        StaticPopup_Show("WOWKEYB_RENAME_PROFILE", target, nil, { oldName = target })
    end)

    local function deleteProfileByName(target)
        if not target then
            print("|cffff0000[WoWKeyb]|r No selected profile.")
            return
        end
        if target == BLIZZARD_DEFAULT_PROFILE then
            print("|cffff0000[WoWKeyb]|r Blizzard Default cannot be deleted.")
            return
        end
        if not WoWKeybDB.profiles[target] then
            print("|cffff0000[WoWKeyb]|r Selected profile not found: " .. tostring(target))
            selectedProfileName = nil
            refreshProfileSelector()
            refreshCurrentProfileText()
            return
        end

        WoWKeybDB.profiles[target] = nil
        print("|cff00ff00[WoWKeyb]|r Deleted profile: " .. tostring(target))

        if WoWKeybDB.currentProfile == target then
            WoWKeybDB.currentProfile = BLIZZARD_DEFAULT_PROFILE
            if WoWKeybDB.previousProfile and WoWKeybDB.profiles[WoWKeybDB.previousProfile] then
                WoWKeybDB.currentProfile = WoWKeybDB.previousProfile
            end
        end
        if WoWKeybDB.previousProfile == target then
            WoWKeybDB.previousProfile = BLIZZARD_DEFAULT_PROFILE
        end
        if not WoWKeybDB.currentProfile then
            WoWKeybDB.currentProfile = BLIZZARD_DEFAULT_PROFILE
        end
        selectedProfileName = WoWKeybDB.currentProfile

        refreshProfileSelector()
        refreshCurrentProfileText()
    end

    if not StaticPopupDialogs["WOWKEYB_DELETE_PROFILE_CONFIRM"] then
        StaticPopupDialogs["WOWKEYB_DELETE_PROFILE_CONFIRM"] = {
            text = "Delete selected WoWKeyb profile \"%s\"?",
            button1 = "Delete",
            button2 = "Cancel",
            OnAccept = function(_, data)
                deleteProfileByName(data)
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end

    deleteBtn:SetScript("OnClick", function()
        local target = selectedProfileName
        if not target then
            print("|cffff0000[WoWKeyb]|r No selected profile.")
            return
        end
        StaticPopup_Show("WOWKEYB_DELETE_PROFILE_CONFIRM", target, nil, target)
    end)

    local helpText = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    helpText:SetPoint("TOPLEFT", deleteBtn, "BOTTOMLEFT", 0, -14)
    helpText:SetWidth(280)
    helpText:SetJustifyH("LEFT")
    helpText:SetText("Tip: Selecting a profile only updates selection. Use Apply Selected Profile to apply a matching profile.")

    WoWKeyb.optionsPanel = panel

    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name, panel.name)
        Settings.RegisterAddOnCategory(category)
        WoWKeyb.settingsCategoryID = category:GetID()
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

local function createMinimapButton()
    ensureDBDefaults()

    local libStub = _G.LibStub
    if not libStub then
        print("|cffff0000[WoWKeyb]|r LibStub missing; minimap icon disabled.")
        return
    end

    local ldb = libStub("LibDataBroker-1.1", true)
    local iconLib = libStub("LibDBIcon-1.0", true)
    if not ldb or not iconLib then
        print("|cffff0000[WoWKeyb]|r LibDBIcon dependencies missing; minimap icon disabled.")
        return
    end

    -- Register LDB launcher once; refresh on subsequent initializations.
    if not WoWKeyb.ldbObject then
        WoWKeyb.ldbObject = ldb:NewDataObject(MINIMAP_LDB_NAME, {
            type = "launcher",
            icon = "Interface\\AddOns\\WoWKeyb\\media\\wowkeyb",
            iconCoords = { 0.02, 0.98, 0.02, 0.98 },
            OnClick = function(_, mouseButton)
                if mouseButton == "LeftButton" then
                    openAddonSettings()
                end
            end,
            OnTooltipShow = function(tooltip)
                tooltip:AddLine("WoWKeyb")
                tooltip:AddLine("Left-click: Open settings", 0.8, 0.8, 0.8)
                tooltip:AddLine("Drag: Move icon", 0.8, 0.8, 0.8)
            end,
        })
    end

    if not iconLib:IsRegistered(MINIMAP_LDB_NAME) then
        iconLib:Register(MINIMAP_LDB_NAME, WoWKeyb.ldbObject, WoWKeybDB.minimap)
    else
        iconLib:Refresh(MINIMAP_LDB_NAME, WoWKeybDB.minimap)
    end

    WoWKeyb.minimapIconLib = iconLib
    if WoWKeybDB.minimap.hide then
        iconLib:Hide(MINIMAP_LDB_NAME)
    else
        iconLib:Show(MINIMAP_LDB_NAME)
    end
end

-- Slash command handler
local function slashHandler(msg)
    msg = msg and msg:trim() or ""
    local cmd, arg = msg:match("^(%S+)%s*(.*)$")
    cmd = (cmd or msg):lower()
    arg = arg and arg:trim() or ""
    arg = arg:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")

    if cmd == "apply" or cmd == "a" then
        if arg == "" then
            print("|cff00ff00[WoWKeyb]|r Usage: /wowkeyb apply <profile name>")
            print("|cff00ff00[WoWKeyb]|r Default profile: " .. BLIZZARD_DEFAULT_PROFILE)
            local list = listStoredProfiles(true)
            if #list > 0 then
                print("|cff00ff00[WoWKeyb]|r Stored profiles: " .. table.concat(list, ", "))
            else
                print("|cff00ff00[WoWKeyb]|r No matching profiles for this character context. Use /wowkeyb import <profile name> to paste a share code first.")
            end
            return
        end
        local ok, result = applySelectionByName(arg)
        if ok then
            print("|cff00ff00[WoWKeyb]|r " .. result)
        else
            print("|cffff0000[WoWKeyb]|r " .. (result or "Failed to apply"))
        end

    elseif cmd == "import" or cmd == "i" then
        if arg == "" then
            print("|cff00ff00[WoWKeyb]|r Usage: /wowkeyb import <profile name>")
            print("|cff00ff00[WoWKeyb]|r Then paste the profile code in the next edit box.")
            return
        end
        -- Open a frame for paste - we'll use a simple editbox
        WoWKeyb:ShowImportDialog(arg)
        return

    elseif cmd == "list" or cmd == "l" then
        local list = listStoredProfiles(true)
        if #list == 0 then
            print("|cff00ff00[WoWKeyb]|r No matching profiles for this character context.")
        else
            print("|cff00ff00[WoWKeyb]|r Stored profiles: " .. table.concat(list, ", "))
        end

    elseif cmd == "listall" or cmd == "la" then
        local list = listStoredProfiles(false)
        if #list == 0 then
            print("|cff00ff00[WoWKeyb]|r No stored profiles.")
        else
            print("|cff00ff00[WoWKeyb]|r All stored profiles: " .. table.concat(list, ", "))
        end

    elseif cmd == "mismatches" or cmd == "mm" then
        local list = listStoredProfiles(false)
        local hasMismatch = false
        for _, name in ipairs(list) do
            local profile = getStoredProfile(name)
            local diagnostics = getProfileMatchDiagnostics(profile)
            if diagnostics and not diagnostics.matches then
                hasMismatch = true
                print("|cffffcc00[WoWKeyb]|r [mismatch] " .. tostring(name) .. " -> " .. table.concat(diagnostics.reasons, " | "))
            end
        end
        if not hasMismatch then
            print("|cff00ff00[WoWKeyb]|r No profile mismatches for current class/spec/hero.")
        end

    elseif cmd == "contexts" or cmd == "ctx" then
        local list = listStoredProfiles(false)
        if #list == 0 then
            print("|cff00ff00[WoWKeyb]|r No stored profiles.")
        else
            for _, name in ipairs(list) do
                local profile = getStoredProfile(name)
                local diagnostics = getProfileMatchDiagnostics(profile)
                local marker = diagnostics and diagnostics.matches and "MATCH" or ("NO MATCH: " .. tostring(diagnostics and diagnostics.reasonSummary or "unknown"))
                print("|cffffcc00[WoWKeyb]|r [context] " .. tostring(name) .. " -> " .. getProfileContextSummary(profile) .. " [" .. marker .. "]")
            end
        end

    elseif cmd == "preferred" or cmd == "pref" then
        local labels = buildPlayerLabelCollection()
        local classLabel = labels.class.variants[1] or "Unknown"
        local specLabel = labels.spec.names[1] or labels.spec.ids[1] or "-"
        local heroLabel = labels.hero.names[1] or labels.hero.ids[1] or "-"
        local contextKey = buildCurrentPlayerContextKey()
        local preferredProfile = getPreferredProfileForCurrentContext()

        print("|cffffcc00[WoWKeyb]|r [preferred] context: " .. tostring(classLabel) .. " / " .. tostring(specLabel) .. " / " .. tostring(heroLabel))
        print("|cffffcc00[WoWKeyb]|r [preferred] key: " .. tostring(contextKey))
        if preferredProfile and WoWKeybDB.profiles[preferredProfile] then
            print("|cff00ff00[WoWKeyb]|r [preferred] profile: " .. tostring(preferredProfile))
        else
            print("|cffffcc00[WoWKeyb]|r [preferred] profile: none")
        end

        local hasAny = false
        for key, profileName in pairs(WoWKeybDB.preferredProfileByContext or {}) do
            hasAny = true
            print("|cffffcc00[WoWKeyb]|r [preferred-map] " .. tostring(key) .. " -> " .. tostring(profileName))
        end
        if not hasAny then
            print("|cffffcc00[WoWKeyb]|r [preferred-map] none")
        end

    elseif cmd == "debugmatch" or cmd == "dm" then
        local target = arg ~= "" and arg or WoWKeybDB.currentProfile
        if not target or target == BLIZZARD_DEFAULT_PROFILE then
            print("|cffff0000[WoWKeyb]|r Select a non-default profile first or pass a name: /wowkeyb debugmatch <profile>")
            return
        end
        local profile = getStoredProfile(target)
        if not profile then
            print("|cffff0000[WoWKeyb]|r Profile not found: " .. tostring(target))
            return
        end
        local classOk = profileMatchesCurrentClass(profile, "debugmatch")
        local specHeroOk = profileMatchesCurrentSpecAndHero(profile, "debugmatch")
        print("|cffffcc00[WoWKeyb]|r [match-debug] profile=" .. tostring(target)
            .. " class_ok=" .. tostring(classOk)
            .. " spec_hero_ok=" .. tostring(specHeroOk))

    elseif cmd == "slotdebug" or cmd == "sd" then
        if arg == "on" then
            WoWKeybDB.debugApplySlots = true
            print("|cff00ff00[WoWKeyb]|r Slot apply debug enabled.")
        elseif arg == "off" then
            WoWKeybDB.debugApplySlots = false
            print("|cff00ff00[WoWKeyb]|r Slot apply debug disabled.")
        else
            print("|cff00ff00[WoWKeyb]|r Slot apply debug is " .. tostring(WoWKeybDB.debugApplySlots == true and "ON" or "OFF")
                .. ". Use /wowkeyb slotdebug on|off")
        end

    elseif cmd == "viewerdebug" or cmd == "vd" then
        if arg == "on" then
            WoWKeybDB.debugViewerSlots = true
            print("|cff00ff00[WoWKeyb]|r Viewer slot debug enabled.")
        elseif arg == "off" then
            WoWKeybDB.debugViewerSlots = false
            print("|cff00ff00[WoWKeyb]|r Viewer slot debug disabled.")
        else
            print("|cff00ff00[WoWKeyb]|r Viewer slot debug is " .. tostring(WoWKeybDB.debugViewerSlots == true and "ON" or "OFF")
                .. ". Use /wowkeyb viewerdebug on|off")
        end

    elseif cmd == "labels" or cmd == "ids" then
        local labels = buildPlayerLabelCollection()
        print("|cffffcc00[WoWKeyb]|r [labels] class variants: " .. table.concat(labels.class.variants, ", "))
        print("|cffffcc00[WoWKeyb]|r [labels] spec ids: " .. table.concat(labels.spec.ids, ", "))
        print("|cffffcc00[WoWKeyb]|r [labels] spec names: " .. table.concat(labels.spec.names, ", "))
        print("|cffffcc00[WoWKeyb]|r [labels] spec variants: " .. table.concat(labels.spec.variants, ", "))
        print("|cffffcc00[WoWKeyb]|r [labels] hero ids: " .. table.concat(labels.hero.ids, ", "))
        print("|cffffcc00[WoWKeyb]|r [labels] hero names: " .. table.concat(labels.hero.names, ", "))
        print("|cffffcc00[WoWKeyb]|r [labels] hero variants: " .. table.concat(labels.hero.variants, ", "))

    elseif cmd == "delete" or cmd == "d" then
        if arg == "" then
            print("|cff00ff00[WoWKeyb]|r Usage: /wowkeyb delete <profile name>")
            return
        end
        if arg == BLIZZARD_DEFAULT_PROFILE then
            print("|cffff0000[WoWKeyb]|r Blizzard Default cannot be deleted.")
            return
        end
        if WoWKeybDB.profiles[arg] then
            WoWKeybDB.profiles[arg] = nil
            print("|cff00ff00[WoWKeyb]|r Deleted profile: " .. arg)
        else
            print("|cffff0000[WoWKeyb]|r Profile not found: " .. arg)
        end

    elseif cmd == "toggle" or cmd == "t" then
        local ok, result = toggleProfile()
        if ok then
            print("|cff00ff00[WoWKeyb]|r " .. result)
        else
            print("|cffff0000[WoWKeyb]|r " .. (result or "Toggle failed"))
        end

    elseif cmd == "switch" or cmd == "s" then
        if arg == "" then
            print("|cff00ff00[WoWKeyb]|r Usage: /wowkeyb switch <profile name>")
            if WoWKeybDB.currentProfile then
                print("|cff00ff00[WoWKeyb]|r Current: " .. WoWKeybDB.currentProfile)
            end
            return
        end
        local ok, result = applySelectionByName(arg)
        if ok then
            print("|cff00ff00[WoWKeyb]|r " .. result)
        else
            print("|cffff0000[WoWKeyb]|r " .. (result or "Failed to apply"))
        end

    elseif cmd == "options" or cmd == "o" then
        openAddonSettings()
        return

    elseif cmd == "export" or cmd == "e" then
        local target = arg ~= "" and arg or WoWKeybDB.currentProfile
        if not target then
            print("|cffff0000[WoWKeyb]|r No target profile. Usage: /wowkeyb export <profile name>")
            return
        end
        if target == BLIZZARD_DEFAULT_PROFILE then
            print("|cffff0000[WoWKeyb]|r Blizzard Default cannot be exported.")
            return
        end
        if not getStoredProfile(target) then
            print("|cffff0000[WoWKeyb]|r Profile not found: " .. tostring(target))
            return
        end
        WoWKeyb:ShowExportDialog(target)
        return

    elseif cmd == "view" or cmd == "v" then
        local target = arg ~= "" and arg or WoWKeybDB.currentProfile
        if not target then
            print("|cffff0000[WoWKeyb]|r No target profile. Usage: /wowkeyb view <profile name>")
            return
        end
        if target == BLIZZARD_DEFAULT_PROFILE then
            print("|cffff0000[WoWKeyb]|r Blizzard Default has no profile mapping to view.")
            return
        end
        if not getStoredProfile(target) then
            print("|cffff0000[WoWKeyb]|r Profile not found: " .. tostring(target))
            return
        end
        WoWKeyb:ShowKeybindingViewer(target)
        return

    else
        print("|cff00ff00[WoWKeyb]|r Commands:")
        print("  /wowkeyb apply <name>  - Apply a stored profile")
        print("  /wowkeyb switch <name> - Switch to a profile (alias for apply)")
        print("  /wowkeyb toggle       - Toggle between last two profiles")
        print("  /wowkeyb import <name> - Import profile from profile code")
        print("  /wowkeyb export [name] - Export selected profile as share code string")
        print("  /wowkeyb view [name]   - Open read-only keybinding map viewer")
        print("  /wowkeyb list         - List stored profiles")
        print("  /wowkeyb listall      - List all profiles (ignore class/spec filter)")
        print("  /wowkeyb mismatches   - List non-matching profiles and reasons")
        print("  /wowkeyb contexts     - List profile class/spec/hero contexts")
        print("  /wowkeyb preferred    - Show preferred profile mapping by context")
        print("  /wowkeyb debugmatch [name] - Print class/spec/hero match diagnostics")
        print("  /wowkeyb slotdebug on|off - Toggle apply slot debug logs")
        print("  /wowkeyb viewerdebug on|off - Toggle viewer slot debug logs")
        print("  /wowkeyb labels       - Print class/spec/hero ID+label collection")
        print("  /wowkeyb delete <name> - Delete a stored profile")
        print("  /wowkeyb options      - Open WoWKeyb AddOn settings")
    end
end

-- Import dialog: simple scrollable edit box for pasting profile code.
local importFrame
function WoWKeyb:ShowImportDialog(profileName)
    if importFrame and importFrame:IsShown() then
        importFrame:Hide()
        return
    end

    if not importFrame then
        importFrame = CreateFrame("Frame", "WoWKeybImportFrame", UIParent, "BackdropTemplate")
        importFrame:SetSize(500, 400)
        importFrame:SetPoint("CENTER")
        importFrame:SetFrameStrata("DIALOG")
        importFrame:SetFrameLevel(100)
        if importFrame.SetBackdrop then
            importFrame:SetBackdrop({
                bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                tile = true, tileSize = 32, edgeSize = 32,
                insets = { left = 11, right = 12, top = 12, bottom = 11 }
            })
        end
        importFrame:SetMovable(true)
        importFrame:EnableMouse(true)
        importFrame:RegisterForDrag("LeftButton")
        importFrame:SetScript("OnMouseDown", function()
            if importFrame.editBox then
                importFrame.editBox:SetFocus()
            end
        end)

        local title = importFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOP", 0, -20)
        title:SetText("WoWKeyb - Paste Profile Code")

        local scroll = CreateFrame("ScrollFrame", "WoWKeybImportScroll", importFrame, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 20, -50)
        scroll:SetPoint("BOTTOMRIGHT", -40, 60)

        local edit = CreateFrame("EditBox", "WoWKeybImportEdit", scroll)
        edit:SetSize(400, 300)
        edit:SetMultiLine(true)
        edit:SetAutoFocus(false)
        edit:EnableKeyboard(true)
        edit:EnableMouse(true)
        edit:SetMaxLetters(0)
        edit:SetFontObject("GameFontHighlight")
        edit:SetTextInsets(6, 6, 6, 6)
        edit:SetScript("OnMouseDown", function(self)
            self:SetFocus()
        end)
        edit:SetScript("OnEscapePressed", function() importFrame:Hide() end)
        edit:SetScript("OnEnterPressed", function(self)
            self:Insert("\n")
        end)
        edit:SetScript("OnTextChanged", function(self, userInput)
            if userInput then
                local textHeight = 0
                if self.GetStringHeight then
                    textHeight = self:GetStringHeight() or 0
                elseif self.GetHeight then
                    textHeight = self:GetHeight() or 0
                end
                local viewHeight = scroll:GetHeight() or 0
                scroll:SetVerticalScroll(math.max(0, textHeight - viewHeight))
            end
        end)
        scroll:SetScrollChild(edit)
        importFrame.editBox = edit

        local closeBtn = CreateFrame("Button", nil, importFrame, "UIPanelButtonTemplate")
        closeBtn:SetSize(120, 22)
        closeBtn:SetPoint("BOTTOM", importFrame, "BOTTOM", 60, 20)
        closeBtn:SetText("Import")
        closeBtn:SetScript("OnClick", function()
            local text = edit:GetText()
            if text and text:trim() ~= "" then
                local ok, decoded = pcall(function()
                    local normalizedText = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    local decodedShareJson = decodeProfileShareCode(normalizedText)
                    local payload = decodedShareJson or normalizedText
                    -- WoW doesn't have JSON built-in; use a simple parser for our format.
                    return WoWKeyb:ParseWoWKeybJSON(payload)
                end)
                if ok and decoded then
                    local importedName = importFrame.profileName
                    if decoded.name and tostring(decoded.name):trim() ~= "" then
                        importedName = tostring(decoded.name)
                    end

                    local function completeImport(targetName)
                        decoded.name = targetName
                        WoWKeybDB.profiles[targetName] = decoded

                        print("|cff00ff00[WoWKeyb]|r Imported profile: " .. targetName)
                        -- Open viewer immediately after import so users can inspect slot/key mapping.
                        WoWKeyb:ShowKeybindingViewer(targetName)

                        local classMatch = profileMatchesCurrentClass(decoded)
                        local specHeroMatch = profileMatchesCurrentSpecAndHero(decoded)
                        local canOfferApply = classMatch and specHeroMatch

                        if not canOfferApply then
                            if WoWKeyb.optionsPanel then
                                WoWKeyb.optionsPanel.forceVisibleProfileName = targetName
                            end
                            local mismatchReason = "class/spec/hero mismatch"
                            if not classMatch then
                                mismatchReason = "class mismatch"
                            elseif not specHeroMatch then
                                mismatchReason = "spec/hero mismatch"
                            end
                            print("|cffffcc00[WoWKeyb]|r Imported profile but did not apply (" .. mismatchReason .. ").")
                            print("|cffffcc00[WoWKeyb]|r Imported profile kept visible in selector for debugging. Run /wowkeyb debugmatch \"" .. tostring(targetName) .. "\"")
                        else
                            if WoWKeyb.optionsPanel then
                                WoWKeyb.optionsPanel.forceVisibleProfileName = nil
                            end
                            if not StaticPopupDialogs["WOWKEYB_IMPORT_APPLY_CONFIRM"] then
                                StaticPopupDialogs["WOWKEYB_IMPORT_APPLY_CONFIRM"] = {
                                    text = "Preview opened for imported profile \"%s\".\nApply this profile now?",
                                    button1 = "Confirm Apply",
                                    button2 = "Cancel",
                                    OnAccept = function(_, data)
                                        local okApply, resultApply = applySelectionByName(data)
                                        if okApply then
                                            print("|cff00ff00[WoWKeyb]|r " .. tostring(resultApply))
                                        else
                                            print("|cffff0000[WoWKeyb]|r Failed to apply imported profile: " .. tostring(resultApply or "Unknown error"))
                                        end
                                        if WoWKeyb.optionsPanel and WoWKeyb.optionsPanel.refreshCurrentProfileText then
                                            WoWKeyb.optionsPanel.refreshCurrentProfileText()
                                        end
                                        if WoWKeyb.optionsPanel and WoWKeyb.optionsPanel.refreshProfileSelector then
                                            WoWKeyb.optionsPanel.refreshProfileSelector()
                                        end
                                        if viewerFrame and viewerFrame:IsShown() then
                                            viewerFrame.profileName = data
                                            refreshViewerFrame(viewerFrame)
                                        end
                                    end,
                                    timeout = 0,
                                    whileDead = true,
                                    hideOnEscape = true,
                                    preferredIndex = 3,
                                }
                            end
                            StaticPopup_Show("WOWKEYB_IMPORT_APPLY_CONFIRM", targetName, nil, targetName)
                        end

                        if WoWKeyb.optionsPanel and WoWKeyb.optionsPanel.refreshCurrentProfileText then
                            WoWKeyb.optionsPanel.refreshCurrentProfileText()
                        end
                        if WoWKeyb.optionsPanel and WoWKeyb.optionsPanel.refreshProfileSelector then
                            WoWKeyb.optionsPanel.refreshProfileSelector()
                        end
                        importFrame:Hide()
                    end

                    if WoWKeybDB.profiles[importedName] then
                        if not StaticPopupDialogs["WOWKEYB_IMPORT_CONFLICT"] then
                            StaticPopupDialogs["WOWKEYB_IMPORT_CONFLICT"] = {
                                text = "Profile \"%s\" already exists.\nUpdate existing or save a copy?",
                                button1 = "Update Existing",
                                button2 = "Save as Copy",
                                OnAccept = function(_, data)
                                    if data and data.onUpdate then
                                        data.onUpdate()
                                    end
                                end,
                                OnCancel = function(_, data, reason)
                                    if reason == "clicked" and data and data.onCopy then
                                        data.onCopy()
                                    end
                                end,
                                timeout = 0,
                                whileDead = true,
                                hideOnEscape = true,
                                preferredIndex = 3,
                            }
                        end

                        local function buildCopyName(baseName)
                            local candidate = tostring(baseName) .. " (Copy)"
                            if not WoWKeybDB.profiles[candidate] then
                                return candidate
                            end
                            local index = 2
                            while true do
                                candidate = string.format("%s (Copy %d)", tostring(baseName), index)
                                if not WoWKeybDB.profiles[candidate] then
                                    return candidate
                                end
                                index = index + 1
                            end
                        end

                        StaticPopup_Show("WOWKEYB_IMPORT_CONFLICT", importedName, nil, {
                            onUpdate = function()
                                completeImport(importedName)
                            end,
                            onCopy = function()
                                completeImport(buildCopyName(importedName))
                            end,
                        })
                    else
                        completeImport(importedName)
                    end
                else
                    print("|cffff0000[WoWKeyb]|r Invalid profile code. Please paste a WoWKeyb export code.")
                end
            end
        end)

        local cancelBtn = CreateFrame("Button", nil, importFrame, "UIPanelButtonTemplate")
        cancelBtn:SetSize(120, 22)
        cancelBtn:SetPoint("BOTTOM", importFrame, "BOTTOM", -60, 20)
        cancelBtn:SetText("Cancel")
        cancelBtn:SetScript("OnClick", function() importFrame:Hide() end)
    end

    importFrame.profileName = profileName
    importFrame:SetScript("OnDragStart", function() importFrame:StartMoving() end)
    importFrame:SetScript("OnDragStop", function() importFrame:StopMovingOrSizing() end)
    importFrame:Show()
    WoWKeybImportEdit:SetText("")
    WoWKeybImportEdit:SetFocus()
end

-- Simple JSON parser for WoWKeyb profile format
-- Handles: {"name":"...","keybinds":[{"key":"1","spell":{"spellId":"123","name":"Spell Name"}}]}
function WoWKeyb:ParseWoWKeybJSON(str)
    if not str or type(str) ~= "string" then return nil end
    str = str:gsub("^%s+", ""):gsub("%s+$", "")

    -- Try to decode using a minimal approach
    local pos = 1
    local parseValue, parseObject, parseArray
    local function skipWhitespace()
        while pos <= #str and str:sub(pos, pos):match("%s") do pos = pos + 1 end
    end
    local function expect(c)
        skipWhitespace()
        if str:sub(pos, pos + #c - 1) == c then
            pos = pos + #c
            return true
        end
        return false
    end
    local function parseString()
        skipWhitespace()
        local quote = str:sub(pos, pos)
        if quote ~= '"' then return nil end
        pos = pos + 1
        local start = pos
        while pos <= #str do
            local ch = str:sub(pos, pos)
            if ch == '\\' then pos = pos + 2
            elseif ch == '"' then
                local s = str:sub(start, pos - 1):gsub('\\"', '"'):gsub("\\\\", "\\")
                pos = pos + 1
                return s
            else pos = pos + 1 end
        end
        return nil
    end
    local function parseNumber()
        skipWhitespace()
        local start = pos
        while pos <= #str and str:sub(pos, pos):match("[%d%.%-%+]") do pos = pos + 1 end
        if pos > start then
            return tonumber(str:sub(start, pos - 1))
        end
        return nil
    end
    function parseValue()
        skipWhitespace()
        local ch = str:sub(pos, pos)
        if ch == '"' then return parseString()
        elseif ch == '{' then return parseObject()
        elseif ch == '[' then return parseArray()
        elseif ch == 't' and str:sub(pos, pos+3) == "true" then pos = pos + 4; return true
        elseif ch == 'f' and str:sub(pos, pos+4) == "false" then pos = pos + 5; return false
        elseif ch == 'n' and str:sub(pos, pos+3) == "null" then pos = pos + 4; return nil
        elseif ch == '-' or ch:match("%d") then return parseNumber()
        end
        return nil
    end
    function parseObject()
        if not expect("{") then return nil end
        local obj = {}
        skipWhitespace()
        if str:sub(pos, pos) == "}" then pos = pos + 1; return obj end
        repeat
            skipWhitespace()
            local key = parseString()
            if not key then return nil end
            if not expect(":") then return nil end
            obj[key] = parseValue()
            skipWhitespace()
            if str:sub(pos, pos) == "," then pos = pos + 1
            elseif str:sub(pos, pos) == "}" then pos = pos + 1; return obj
            else return nil end
        until false
    end
    function parseArray()
        if not expect("[") then return nil end
        local arr = {}
        skipWhitespace()
        if str:sub(pos, pos) == "]" then pos = pos + 1; return arr end
        repeat
            table.insert(arr, parseValue())
            skipWhitespace()
            if str:sub(pos, pos) == "," then pos = pos + 1
            elseif str:sub(pos, pos) == "]" then pos = pos + 1; return arr
            else return nil end
        until false
    end

    local result = parseObject()
    if result and result.keybinds then
        return result
    end
    return nil
end

-- Register slash commands
SLASH_WOWKEYB1 = "/wowkeyb"
SLASH_WOWKEYB2 = "/wk"
SlashCmdList["WOWKEYB"] = slashHandler

-- Export for other addons / macros
WoWKeyb.ApplyProfile = applyProfile
WoWKeyb.ToggleProfile = toggleProfile
WoWKeyb.StoreProfile = storeProfile
WoWKeyb.GetStoredProfile = getStoredProfile
WoWKeyb.ListStoredProfiles = listStoredProfiles
WoWKeyb.ToWoWKeyFormat = toWoWKeyFormat

-- Initialize UI integration (settings panel + minimap button)
do
    local initFrame = CreateFrame("Frame")
    initFrame:RegisterEvent("PLAYER_LOGIN")
    initFrame:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_LOGIN" then
            createSettingsPanel()
            createMinimapButton()

            -- Keep stored profile spells in sync with manual bar changes in-game.
            local syncFrame = CreateFrame("Frame")
            syncFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
            syncFrame:SetScript("OnEvent", function(_, _, slot)
                if not slot then return end
                if not ENABLE_LIVE_SLOT_SYNC then return end
                if not WoWKeybDB or not WoWKeybDB.currentProfile then return end
                if WoWKeybDB.currentProfile == BLIZZARD_DEFAULT_PROFILE then return end
                if WoWKeyb.isApplyingProfile then return end
                syncProfileSpellsFromActionBars(WoWKeybDB.currentProfile)
            end)

            -- When class/spec/hero context changes, ensure current selection still makes sense.
            local contextFrame = CreateFrame("Frame")
            contextFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
            contextFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
            contextFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
            if C_ClassTalents then
                contextFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
            end

            local pendingContextCheck = false
            local function queueContextCheck(triggerEvent)
                if pendingContextCheck then return end
                pendingContextCheck = true

                local function runCheck()
                    pendingContextCheck = false
                    enforceCurrentProfileForPlayerContext(triggerEvent)
                    if WoWKeyb.optionsPanel then
                        if WoWKeyb.optionsPanel.refreshProfileSelector then
                            WoWKeyb.optionsPanel.refreshProfileSelector()
                        end
                        if WoWKeyb.optionsPanel.refreshCurrentProfileText then
                            WoWKeyb.optionsPanel.refreshCurrentProfileText()
                        end
                    end
                end

                if C_Timer and type(C_Timer.After) == "function" then
                    C_Timer.After(0.25, runCheck)
                else
                    runCheck()
                end
            end

            contextFrame:SetScript("OnEvent", function(_, contextEvent, arg1)
                if contextEvent == "PLAYER_SPECIALIZATION_CHANGED" and arg1 ~= "player" then
                    return
                end
                queueContextCheck(contextEvent)
            end)
        end
    end)
end

print("|cff00ff00[WoWKeyb]|r Loaded. Type /wowkeyb for help.")
