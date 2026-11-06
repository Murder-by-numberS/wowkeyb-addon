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
local ENABLE_LIVE_PROFILE_SYNC = false
local ADDON_SHARE_PREFIX = "WOWKEYB1"
local SHARE_PROTOCOL_VERSION = "1"
local SHARE_CHUNK_SIZE = 180
local SHARE_ENTRY_TTL_SECONDS = 600
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
    if type(WoWKeybDB.lastProfileByCharacter) ~= "table" then
        WoWKeybDB.lastProfileByCharacter = {}
    end
    if WoWKeybDB.debugApplySlots == nil then
        WoWKeybDB.debugApplySlots = false
    end
    if WoWKeybDB.debugViewerSlots == nil then
        WoWKeybDB.debugViewerSlots = false
    end
    if WoWKeybDB.debugApplyAssignments == nil then
        WoWKeybDB.debugApplyAssignments = false
    end
    if WoWKeybDB.minimap.hide == nil then WoWKeybDB.minimap.hide = false end
    if WoWKeybDB.minimap.minimapPos == nil then
        WoWKeybDB.minimap.minimapPos = tonumber(WoWKeybDB.minimap.angle) or 225
    end
    WoWKeybDB.minimap.angle = nil
end

local function getCurrentCharacterProfileKey()
    local characterName = UnitName and UnitName("player") or nil
    local realmName = GetRealmName and GetRealmName() or nil
    if type(characterName) ~= "string" or characterName == "" then
        return nil
    end
    if type(realmName) ~= "string" or realmName == "" then
        realmName = "unknown"
    end
    return tostring(characterName):lower() .. "-" .. tostring(realmName):lower()
end

local function rememberCurrentProfileForCharacter(profileName)
    ensureDBDefaults()
    local characterKey = getCurrentCharacterProfileKey()
    if not characterKey then
        return
    end
    local storedProfile = tostring(profileName or "")
    if storedProfile == "" then
        storedProfile = BLIZZARD_DEFAULT_PROFILE
    end
    WoWKeybDB.lastProfileByCharacter[characterKey] = storedProfile
end

local function setCurrentProfile(profileName, persistCharacterSelection)
    ensureDBDefaults()
    local resolved = tostring(profileName or "")
    if resolved == "" then
        resolved = BLIZZARD_DEFAULT_PROFILE
    end
    WoWKeybDB.currentProfile = resolved
    if persistCharacterSelection ~= false then
        rememberCurrentProfileForCharacter(resolved)
    end
end

local function restoreCurrentProfileForCharacter()
    ensureDBDefaults()
    local characterKey = getCurrentCharacterProfileKey()
    if not characterKey then
        return
    end
    local saved = WoWKeybDB.lastProfileByCharacter[characterKey]
    if type(saved) ~= "string" or saved == "" then
        return
    end
    if saved == BLIZZARD_DEFAULT_PROFILE or WoWKeybDB.profiles[saved] then
        setCurrentProfile(saved, false)
        return
    end
    setCurrentProfile(BLIZZARD_DEFAULT_PROFILE, false)
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
    -- Profile selection is strictly manual.
    -- Keep this as a no-op to avoid mutating old preferred mappings.
    return
end

local function getPreferredProfileForCurrentContext()
    -- Profile selection is strictly manual.
    return nil
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

local function formatClassLabel(classValue)
    local raw = tostring(classValue or "")
    if raw == "" then
        return "Unknown"
    end
    local token = raw:upper()
    if _G.LOCALIZED_CLASS_NAMES_MALE and _G.LOCALIZED_CLASS_NAMES_MALE[token] then
        return tostring(_G.LOCALIZED_CLASS_NAMES_MALE[token])
    end
    if _G.LOCALIZED_CLASS_NAMES_FEMALE and _G.LOCALIZED_CLASS_NAMES_FEMALE[token] then
        return tostring(_G.LOCALIZED_CLASS_NAMES_FEMALE[token])
    end
    if token == raw then
        local lowered = raw:lower()
        return lowered:gsub("(%a)([%w_]*)", function(first, rest)
            return string.upper(first) .. tostring(rest or "")
        end)
    end
    return raw
end

local function resolveHeroTalentNameFromId(heroId)
    local idNum = tonumber(heroId)
    if not idNum or idNum <= 0 then
        return ""
    end

    if C_ClassTalents and type(C_ClassTalents.GetHeroTalentSpecInfo) == "function" then
        local okInfo, heroInfo = pcall(C_ClassTalents.GetHeroTalentSpecInfo, idNum)
        if okInfo and type(heroInfo) == "table" then
            local heroName = tostring(heroInfo.name or heroInfo.heroTalentName or "")
            if heroName ~= "" then
                return heroName
            end
        end
    end

    local configId = nil
    if C_ClassTalents and type(C_ClassTalents.GetActiveConfigID) == "function" then
        local okConfig, activeConfigId = pcall(C_ClassTalents.GetActiveConfigID)
        if okConfig and activeConfigId then
            configId = activeConfigId
        end
    end
    if configId and C_Traits and type(C_Traits.GetSubTreeInfo) == "function" then
        local okSubTree, subTreeInfo = pcall(C_Traits.GetSubTreeInfo, configId, idNum)
        if okSubTree and type(subTreeInfo) == "table" then
            local heroName = tostring(subTreeInfo.name or subTreeInfo.description or "")
            if heroName ~= "" then
                return heroName
            end
        end
    end

    return ""
end

local function formatHeroTalentLabel(heroValue, heroIdValue)
    local value = tostring(heroValue or "")
    local idValue = tostring(heroIdValue or "")
    local valueLooksNumeric = value ~= "" and value:match("^%d+$") ~= nil
    if value ~= "" and not valueLooksNumeric then
        return value
    end

    local idCandidate = idValue ~= "" and idValue or value
    if idCandidate ~= "" then
        local resolved = resolveHeroTalentNameFromId(idCandidate)
        if resolved ~= "" then
            return resolved
        end
        return tostring(idCandidate)
    end

    return "-"
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
    local classValue = formatClassLabel(profile.class)
    local specValue = tostring(profile.spec or profile.spec_id or profile.specId or profile.specialization or "-")
    local heroValue = formatHeroTalentLabel(
        profile.heroTalent or profile.hero_talent or profile.hero_talent_id or profile.heroTalentId,
        profile.heroTalentId or profile.hero_talent_id
    )
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
for i = 1, 12 do SLOT_COMMANDS[60 + i] = "MULTIACTIONBAR5BUTTON" .. i end
for i = 1, 12 do SLOT_COMMANDS[72 + i] = "MULTIACTIONBAR6BUTTON" .. i end
for i = 1, 12 do SLOT_COMMANDS[84 + i] = "MULTIACTIONBAR7BUTTON" .. i end

local VIEWER_BAR_COUNT = 8
local VIEWER_SLOT_COUNT = VIEWER_BAR_COUNT * 12
local isActionBarShown
local ensureLayoutBarsFromGame

-- Convert logical WoWKeyb slot (1..60 across bars 1..5) to Blizzard action slot IDs
-- used by PlaceAction/GetActionInfo.
local function toBlizzardActionSlot(slot)
    if not slot or slot < 1 or slot > 96 then return slot end
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
    elseif bar == 6 then
        return 144 + idx -- MultiBar5: 145..156
    elseif bar == 7 then
        return 156 + idx -- MultiBar6: 157..168
    elseif bar == 8 then
        return 168 + idx -- MultiBar7: 169..180
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
                if slot >= 1 and slot <= VIEWER_SLOT_COUNT then
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
        if slot >= 1 and slot <= VIEWER_SLOT_COUNT then
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
        if slot >= 1 and slot <= VIEWER_SLOT_COUNT then
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
    if not slot or slot < 1 or slot > 180 then
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

local function readUtilityActionFromActionSlot(slot, actionTypeOverride, actionIdOverride)
    if not slot or slot < 1 or slot > 180 then
        return nil
    end

    local actionType, actionId = actionTypeOverride, actionIdOverride
    if not actionType then
        actionType, actionId = GetActionInfo(slot)
    end
    if not actionType then
        return nil
    end

    local normalizedType = tostring(actionType):lower()
    local texture = GetActionTexture and GetActionTexture(slot) or nil

    if normalizedType == "item" and actionId then
        local itemId = tonumber(actionId)
        local itemName = ""
        local itemIcon = texture
        local isTrinket = false
        if itemId then
            local equipSlot = nil
            if type(GetItemInfo) == "function" then
                local n, _, _, _, _, _, _, _, slotName, i = GetItemInfo(itemId)
                if n then itemName = tostring(n) end
                if slotName then equipSlot = tostring(slotName) end
                if not itemIcon and i then itemIcon = i end
            end
            if not equipSlot and C_Item and type(C_Item.GetItemInventoryTypeByID) == "function" then
                local okSlot, inventoryType = pcall(C_Item.GetItemInventoryTypeByID, itemId)
                if okSlot and tonumber(inventoryType) == 12 then
                    equipSlot = "INVTYPE_TRINKET"
                end
            end
            isTrinket = equipSlot == "INVTYPE_TRINKET"
            if itemName == "" and C_Item and type(C_Item.GetItemNameByID) == "function" then
                local okName, resolvedName = pcall(C_Item.GetItemNameByID, itemId)
                if okName and resolvedName then
                    itemName = tostring(resolvedName)
                end
            end
            if not itemIcon and type(GetItemIcon) == "function" then
                itemIcon = GetItemIcon(itemId)
            end
        end

        local isToy = itemId and type(PlayerHasToy) == "function" and PlayerHasToy(itemId) == true
        if isToy then
            return {
                spellId = "toy:" .. tostring(itemId or ""),
                name = "Toy",
                icon = itemIcon or "",
                actionType = "toy",
            }
        end

        if isTrinket then
            return {
                spellId = "item:" .. tostring(itemId or actionId or ""),
                name = itemName ~= "" and itemName or "Trinket",
                icon = itemIcon or "",
                actionType = "trinket",
            }
        end

        return {
            spellId = "item:" .. tostring(itemId or actionId or ""),
            name = itemName ~= "" and itemName or "Item",
            icon = itemIcon or "",
            actionType = "item",
        }
    end

    if normalizedType == "mount" or normalizedType == "summonmount" or normalizedType == "companion" then
        return {
            spellId = "mount:" .. tostring(actionId or ""),
            name = "Mount",
            icon = texture or "",
            actionType = "mount",
        }
    end

    return nil
end

local function readMacroFromActionSlot(slot)
    if not slot or slot < 1 or slot > 180 then
        return nil
    end

    local actionType, actionId = GetActionInfo(slot)
    if actionType ~= "macro" or not actionId then
        return nil
    end
    if type(GetMacroInfo) ~= "function" then
        return nil
    end

    local macroIndex = nil
    local macroName, macroIcon, macroBody = nil, nil, nil
    local function hasMacroPayload(nameValue, iconValue, bodyValue)
        return (nameValue and tostring(nameValue) ~= "")
            or (iconValue and tostring(iconValue) ~= "" and tostring(iconValue) ~= "0")
            or (bodyValue and tostring(bodyValue) ~= "")
    end
    local numericActionId = tonumber(actionId)
    if numericActionId then
        local n, i, b = GetMacroInfo(numericActionId)
        if hasMacroPayload(n, i, b) then
            macroIndex = numericActionId
            macroName, macroIcon, macroBody = n, i, b
        end
    end
    if not macroIndex and type(GetActionText) == "function" and type(GetMacroIndexByName) == "function" then
        local actionText = tostring(GetActionText(slot) or "")
        if actionText ~= "" then
            local byName = GetMacroIndexByName(actionText)
            if byName and tonumber(byName) and tonumber(byName) > 0 then
                macroIndex = tonumber(byName)
                macroName, macroIcon, macroBody = GetMacroInfo(macroIndex)
            end
            if (not macroName or tostring(macroName) == "") and actionText ~= "" then
                macroName = actionText
            end
        end
    end

    local macroId = tostring(macroIndex or actionId or "")
    local macroText = tostring(macroBody or "")
    if (not macroIcon or tostring(macroIcon) == "" or tostring(macroIcon) == "0") and type(GetActionTexture) == "function" then
        local actionTexture = GetActionTexture(slot)
        if actionTexture and tostring(actionTexture) ~= "" and tostring(actionTexture) ~= "0" then
            macroIcon = actionTexture
        end
    end

    return {
        spellId = "macro:" .. macroId,
        name = tostring(macroName or "WoWKeybMacro"),
        icon = macroIcon or "",
        actionType = "macro",
        isMacro = true,
        macroId = macroId,
        macroText = macroText,
    }
end

local function resolveMacroDisplayFromActionSlot(actionSlot, actionId, fallbackName, fallbackIcon, fallbackBody)
    local name = tostring(fallbackName or "")
    local icon = fallbackIcon
    local body = tostring(fallbackBody or "")

    local function iconIsUsable(value)
        if not value then return false end
        local raw = tostring(value)
        if raw == "" or raw == "0" then return false end
        if raw:lower():find("^https?://") then return false end
        return true
    end

    if actionId and type(GetMacroInfo) == "function" then
        local macroName, macroIcon, macroBody = GetMacroInfo(actionId)
        if macroName and tostring(macroName) ~= "" then
            name = tostring(macroName)
        end
        if iconIsUsable(macroIcon) then
            icon = macroIcon
        end
        if macroBody and tostring(macroBody) ~= "" then
            body = tostring(macroBody)
        end
    end

    if (not iconIsUsable(icon)) and actionSlot and type(GetActionTexture) == "function" then
        local actionTexture = GetActionTexture(actionSlot)
        if iconIsUsable(actionTexture) then
            icon = actionTexture
        end
    end

    if name == "" then
        name = "Macro"
    end
    return name, icon, body
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
        spellNameCandidates = {},
    }
    if not body or body == "" then
        return parsed
    end

    local function registerToken(rawToken)
        local token = tostring(rawToken or "")
        token = token:gsub("^%s+", ""):gsub("%s+$", "")
        token = token:gsub("^!+", "")
        token = token:gsub("^reset=[^,%s;]+%s*", "")
        token = token:gsub("^%[[^%]]+%]%s*", "")
        token = token:gsub("^@[^%s]+%s*", "")
        token = token:gsub("^target=[^%s]+%s*", "")
        token = token:gsub("^%[[^%]]+%]%s*", "")
        token = token:gsub("%s*%b()%s*$", "")
        token = token:gsub("%s*%.+$", "")
        token = token:gsub("^%s*null%s*$", "")
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
        if token ~= "" then
            parsed.spellNameCandidates[token] = true
        end
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

    local targetId = tonumber(spellId)
    local targetName = normalizeSpellText(spellName)
    local resolvedTargetName = nil
    if targetId and _G.GetSpellInfo then
        resolvedTargetName = _G.GetSpellInfo(targetId)
        resolvedTargetName = normalizeSpellText(resolvedTargetName)
    end

    -- Prefer native WoW macro spell resolution when available.
    if type(GetMacroSpell) == "function" then
        local macroSpellA, macroSpellB = GetMacroSpell(actionId)
        local function matchesMacroSpellValue(value)
            if value == nil then return false end
            local valueNum = tonumber(value)
            if targetId and valueNum and valueNum == targetId then
                return true
            end
            local normalizedValue = normalizeSpellText(value)
            if targetName ~= "" and normalizedValue == targetName then
                return true
            end
            if resolvedTargetName and resolvedTargetName ~= "" and normalizedValue == resolvedTargetName then
                return true
            end
            return false
        end
        if matchesMacroSpellValue(macroSpellA) or matchesMacroSpellValue(macroSpellB) then
            return true
        end
    end

    local cacheKey = tostring(actionId) .. ":" .. tostring(body)
    if not parseCache[cacheKey] then
        parseCache[cacheKey] = parseMacroSpellData(body)
    end
    local parsed = parseCache[cacheKey]
    if not parsed then return false end

    if targetId and parsed.spellIds[targetId] then
        return true
    end

    if targetName ~= "" and parsed.spellNames[targetName] then
        return true
    end
    if resolvedTargetName and resolvedTargetName ~= "" and parsed.spellNames[resolvedTargetName] then
        return true
    end

    -- Heuristic fallback for conditional mouseover macros where parser can miss variants.
    local normalizedBody = normalizeSpellText(body)
    if normalizedBody ~= "" then
        if targetId and normalizedBody:find("spell:" .. tostring(targetId), 1, true) then
            return true
        end
        if targetName ~= "" and normalizedBody:find(targetName, 1, true) then
            return true
        end
        if resolvedTargetName and resolvedTargetName ~= "" and normalizedBody:find(resolvedTargetName, 1, true) then
            return true
        end
    end

    return false
end

local function actionSlotHasMacro(actionSlot)
    if not actionSlot then return false end
    local actionType = GetActionInfo(actionSlot)
    return actionType == "macro"
end

local function normalizeMacroBodyForMatch(body)
    if not body then return "" end
    local normalized = tostring(body):gsub("\r\n", "\n"):gsub("\r", "\n")
    local lines = {}
    for line in normalized:gmatch("[^\n]*") do
        if line == "" and #lines == 0 then
            -- Skip leading empty lines.
        else
            local trimmed = tostring(line):gsub("\t", " ")
            trimmed = trimmed:gsub("^%s+", ""):gsub("%s+$", "")
            trimmed = trimmed:gsub("%s+", " ")
            trimmed = trimmed:lower()
            if trimmed ~= "" then
                lines[#lines + 1] = trimmed
            end
        end
    end
    return table.concat(lines, "\n")
end

local function sanitizeMacroName(rawName)
    local name = tostring(rawName or ""):gsub("[\r\n\t]", " ")
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then
        name = "WoWKeybMacro"
    end
    -- WoW macro names are limited to 16 characters.
    if #name > 16 then
        name = name:sub(1, 16)
    end
    return name
end

local function normalizeMacroNameForMatch(rawName)
    local name = tostring(rawName or "")
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    name = name:gsub("%s+", " ")
    name = name:lower()
    return name
end

local function normalizeMacroId(raw)
    local value = tostring(raw or "")
    if value == "" then
        return ""
    end
    return value
end

local function isGenericMacroName(rawName)
    local normalized = normalizeMacroNameForMatch(rawName)
    return normalized == "" or normalized == "macro" or normalized == "wowkeybmacro"
end

local function buildProfileMacroLookup(profile)
    local lookup = { byId = {}, byName = {} }
    local function registerMacroId(idValue, payload)
        local key = tostring(idValue or "")
        if key == "" then return end
        lookup.byId[key] = payload
        local stripped = key:match("^macro:(.+)$")
        if stripped and stripped ~= "" then
            lookup.byId[stripped] = payload
        end
    end
    if type(profile) ~= "table" or type(profile.macros) ~= "table" then
        return lookup
    end
    for _, macro in ipairs(profile.macros) do
        if type(macro) == "table" then
            local macroId = tostring(macro.id or macro.macroId or macro.macro_id or "")
            local macroName = tostring(macro.name or macro.macroName or macro.macro_name or "")
            local macroBody = macro.macroText or macro.macro_text or macro.text or macro.body
            local payload = {
                name = macroName,
                body = tostring(macroBody or ""),
                icon = tostring(macro.icon or ""),
                sourceSpellId = tostring(macro.sourceSpellId or macro.source_spell_id or ""),
                sourceSpellName = tostring(macro.sourceSpellName or macro.source_spell_name or ""),
            }
            if macroId ~= "" then
                registerMacroId(macroId, payload)
            end
            local normalizedName = normalizeSpellText(macroName)
            if normalizedName ~= "" and not isGenericMacroName(normalizedName) then
                lookup.byName[normalizedName] = payload
            end
        end
    end
    return lookup
end

local function extractMacroPayload(spell, macroLookup)
    if type(spell) ~= "table" then return nil end

    local actionType = tostring(spell.actionType or spell.action_type or ""):lower()
    local isMacro = spell.isMacro == true or actionType == "macro"
    local spellIdRaw = tostring(spell.spellId or spell.spell_id or "")
    local macroId = tostring(spell.macroId or spell.macro_id or "")
    local sourceSpellId = tostring(spell.sourceSpellId or spell.source_spell_id or "")
    local sourceSpellName = tostring(spell.sourceSpellName or spell.source_spell_name or "")
    if macroId == "" then
        local fromSpellId = spellIdRaw:match("^macro:(.+)$")
        if fromSpellId and fromSpellId ~= "" then
            macroId = tostring(fromSpellId)
            isMacro = true
        end
    end
    if spellIdRaw:lower():find("^macro:") then
        isMacro = true
    end

    local macroText = spell.macroText or spell.macro_text or spell.text or spell.body
    local resolvedIcon = spell.icon
    if (macroId ~= "")
        or (type(macroText) == "string" and macroText:trim() ~= "")
        or (type(sourceSpellId) == "string" and sourceSpellId ~= "")
        or (type(sourceSpellName) == "string" and sourceSpellName ~= "") then
        isMacro = true
    end

    if not isMacro then
        return nil
    end

    if (not macroText or tostring(macroText):trim() == "") then
        -- Legacy/partial payload fallback: some exports only carried macro text in description.
        local desc = spell.description
        if desc and tostring(desc):trim() ~= "" then
            macroText = desc
        end
    end
    local macroName = spell.name or spell.macroName or spell.macro_name or "WoWKeybMacro"
    local payloadSource = "spell"

    local resolvedFromLookup = nil
    if macroLookup then
        if macroId ~= "" and macroLookup.byId[macroId] then
            resolvedFromLookup = macroLookup.byId[macroId]
        end
        if (not resolvedFromLookup) and (macroName and tostring(macroName):trim() ~= "") then
            local normalizedLookupName = normalizeSpellText(macroName)
            if normalizedLookupName ~= "" and macroLookup.byName[normalizedLookupName] then
                resolvedFromLookup = macroLookup.byName[normalizedLookupName]
            end
        end
    end

    if (not macroText or tostring(macroText):trim() == "") and macroLookup then
        if macroId ~= "" and macroLookup.byId[macroId] then
            macroText = macroLookup.byId[macroId].body
            macroName = macroLookup.byId[macroId].name or macroName
            if sourceSpellId == "" and macroLookup.byId[macroId].sourceSpellId and tostring(macroLookup.byId[macroId].sourceSpellId) ~= "" then
                sourceSpellId = tostring(macroLookup.byId[macroId].sourceSpellId)
            end
            if sourceSpellName == "" and macroLookup.byId[macroId].sourceSpellName and tostring(macroLookup.byId[macroId].sourceSpellName) ~= "" then
                sourceSpellName = tostring(macroLookup.byId[macroId].sourceSpellName)
            end
            if (not resolvedIcon or tostring(resolvedIcon) == "" or tostring(resolvedIcon) == "0")
                and macroLookup.byId[macroId].icon and tostring(macroLookup.byId[macroId].icon) ~= "" then
                resolvedIcon = macroLookup.byId[macroId].icon
            end
            payloadSource = "profile-by-id"
        end
        if (not macroText or tostring(macroText):trim() == "") then
            local normalizedName = normalizeSpellText(macroName)
            if normalizedName ~= "" and not isGenericMacroName(normalizedName) and macroLookup.byName[normalizedName] then
                macroText = macroLookup.byName[normalizedName].body
                macroName = macroLookup.byName[normalizedName].name or macroName
                if sourceSpellId == "" and macroLookup.byName[normalizedName].sourceSpellId and tostring(macroLookup.byName[normalizedName].sourceSpellId) ~= "" then
                    sourceSpellId = tostring(macroLookup.byName[normalizedName].sourceSpellId)
                end
                if sourceSpellName == "" and macroLookup.byName[normalizedName].sourceSpellName and tostring(macroLookup.byName[normalizedName].sourceSpellName) ~= "" then
                    sourceSpellName = tostring(macroLookup.byName[normalizedName].sourceSpellName)
                end
                if (not resolvedIcon or tostring(resolvedIcon) == "" or tostring(resolvedIcon) == "0")
                    and macroLookup.byName[normalizedName].icon and tostring(macroLookup.byName[normalizedName].icon) ~= "" then
                    resolvedIcon = macroLookup.byName[normalizedName].icon
                end
                payloadSource = "profile-by-name"
            end
        end
    end

    -- Even when body already exists, prefer richer stored macro metadata (name/icon/source spell)
    -- over generic fallback values for cross-profile viewing.
    if resolvedFromLookup then
        if isGenericMacroName(macroName) and resolvedFromLookup.name and tostring(resolvedFromLookup.name):trim() ~= "" then
            macroName = tostring(resolvedFromLookup.name)
        end
        if (not resolvedIcon or tostring(resolvedIcon) == "" or tostring(resolvedIcon) == "0")
            and resolvedFromLookup.icon and tostring(resolvedFromLookup.icon) ~= "" then
            resolvedIcon = tostring(resolvedFromLookup.icon)
        end
        if sourceSpellId == "" and resolvedFromLookup.sourceSpellId and tostring(resolvedFromLookup.sourceSpellId) ~= "" then
            sourceSpellId = tostring(resolvedFromLookup.sourceSpellId)
        end
        if sourceSpellName == "" and resolvedFromLookup.sourceSpellName and tostring(resolvedFromLookup.sourceSpellName) ~= "" then
            sourceSpellName = tostring(resolvedFromLookup.sourceSpellName)
        end
    end

    local macroBody = tostring(macroText or "")
    local hasMacroBody = macroBody:trim() ~= ""
    local hasMacroIdentity = (macroId and macroId ~= "")
        or (normalizeSpellText(macroName) ~= "")
    if (not hasMacroBody) and (not hasMacroIdentity) then
        return nil
    end

    return {
        macroId = macroId,
        name = sanitizeMacroName(macroName),
        body = macroBody,
        source = payloadSource,
        icon = resolvedIcon,
        sourceSpellId = sourceSpellId,
        sourceSpellName = sourceSpellName,
    }
end

local function getAllMacroIndexes()
    local list = {}
    if type(GetNumMacros) ~= "function" then
        return list
    end
    local globalCount, characterCount = GetNumMacros()
    local total = (tonumber(globalCount) or 0) + (tonumber(characterCount) or 0)
    for index = 1, total do
        list[#list + 1] = index
    end
    return list
end

local function findExistingMacroByBody(body)
    local normalizedTarget = normalizeMacroBodyForMatch(body)
    if normalizedTarget == "" or type(GetMacroInfo) ~= "function" then
        return nil
    end

    for _, index in ipairs(getAllMacroIndexes()) do
        local _, _, macroBody = GetMacroInfo(index)
        if normalizeMacroBodyForMatch(macroBody) == normalizedTarget then
            return index
        end
    end
    return nil
end

local function findExistingMacroByName(name)
    local target = normalizeMacroNameForMatch(name)
    if target == "" or type(GetMacroInfo) ~= "function" then
        return nil
    end
    for _, index in ipairs(getAllMacroIndexes()) do
        local macroName = GetMacroInfo(index)
        if normalizeMacroNameForMatch(macroName) == target then
            return index
        end
    end
    return nil
end

local function getMacroAccountMatchDiagnostics(payload)
    local total = #getAllMacroIndexes()
    local byName = findExistingMacroByName(payload and payload.name)
    local byBody = findExistingMacroByBody(payload and payload.body)
    return {
        total = total,
        byName = byName,
        byBody = byBody,
    }
end

local function macroNameExists(name)
    if not name or name == "" or type(GetMacroInfo) ~= "function" then
        return false
    end
    for _, index in ipairs(getAllMacroIndexes()) do
        local macroName = GetMacroInfo(index)
        if macroName == name then
            return true
        end
    end
    return false
end

local function buildUniqueMacroName(baseName)
    local base = sanitizeMacroName(baseName)
    if not macroNameExists(base) then
        return base
    end
    for i = 1, 99 do
        local suffix = tostring(i)
        local allowedBaseLength = 16 - #suffix
        if allowedBaseLength < 1 then allowedBaseLength = 1 end
        local candidate = base:sub(1, allowedBaseLength) .. suffix
        if not macroNameExists(candidate) then
            return candidate
        end
    end
    return base:sub(1, 15) .. "9"
end

local function ensureMacroForPayload(payload)
    if type(payload) ~= "table" or not payload.body or payload.body == "" then
        return nil, "missing-body"
    end
    local existing = findExistingMacroByBody(payload.body)
    if existing then
        return existing, "reused-existing-body"
    end
    if not isGenericMacroName(payload.name) and type(GetMacroIndexByName) == "function" then
        local byApiName = GetMacroIndexByName(tostring(payload.name or ""))
        if byApiName and tonumber(byApiName) and tonumber(byApiName) > 0 then
            return tonumber(byApiName), "reused-existing-name-api"
        end
    end
    if not isGenericMacroName(payload.name) then
        local byName = findExistingMacroByName(payload.name)
        if byName then
            return byName, "reused-existing-name"
        end
    end
    if type(CreateMacro) ~= "function" then
        return nil, "create-macro-unavailable"
    end

    local macroName = buildUniqueMacroName(payload.name or "WoWKeybMacro")
    local icon = "INV_MISC_QUESTIONMARK"
    local okCreate, createdIndex = pcall(function()
        return CreateMacro(macroName, icon, payload.body, true)
    end)
    if okCreate and createdIndex and tonumber(createdIndex) and tonumber(createdIndex) > 0 then
        return tonumber(createdIndex), "created"
    end
    return nil, "create-failed"
end

local function resolveMacroIconForPayload(payload, macroIndex)
    local function hasIcon(value)
        if not value then return false end
        local iconStr = tostring(value)
        if iconStr == "" or iconStr == "0" then
            return false
        end
        if iconStr:lower():find("^https?://") then
            return false
        end
        return true
    end

    local function resolveSpellTexture(ref)
        if not ref or ref == "" then return nil end
        if C_Spell and type(C_Spell.GetSpellTexture) == "function" then
            local okTex, texture = pcall(C_Spell.GetSpellTexture, ref)
            if okTex and hasIcon(texture) then
                return texture
            end
        end
        if _G.GetSpellInfo then
            local _, _, texture = _G.GetSpellInfo(ref)
            if hasIcon(texture) then
                return texture
            end
        end
        return nil
    end

    -- First try WoW's own macro spell resolution.
    if macroIndex and type(GetMacroSpell) == "function" then
        local macroSpellA, macroSpellB = GetMacroSpell(macroIndex)
        local fromMacro = resolveSpellTexture(tonumber(macroSpellA) or macroSpellA)
            or resolveSpellTexture(tonumber(macroSpellB) or macroSpellB)
        if hasIcon(fromMacro) then
            return fromMacro
        end
    end

    -- Parse macro body for first referenced spell id/name.
    local parsed = parseMacroSpellData(payload and payload.body or "")
    if parsed and type(parsed.spellIds) == "table" then
        for spellId in pairs(parsed.spellIds) do
            local texture = resolveSpellTexture(tonumber(spellId))
            if hasIcon(texture) then
                return texture
            end
        end
    end
    if parsed and type(parsed.spellNameCandidates) == "table" then
        local rawNameCandidates = parsed.spellNameCandidates
        for spellName in pairs(rawNameCandidates) do
            local texture = resolveSpellTexture(spellName)
            if hasIcon(texture) then
                return texture
            end
        end
    end
    if parsed and type(parsed.spellNames) == "table" then
        for spellName in pairs(parsed.spellNames) do
            local texture = resolveSpellTexture(spellName)
            if hasIcon(texture) then
                return texture
            end
        end
    end

    -- Source ability metadata from imports is often available pre-apply.
    local sourceSpellId = tonumber(payload and (payload.sourceSpellId or payload.source_spell_id) or "")
    if sourceSpellId and sourceSpellId > 0 then
        local texture = resolveSpellTexture(sourceSpellId)
        if hasIcon(texture) then
            return texture
        end
    end
    local sourceSpellName = tostring(payload and (payload.sourceSpellName or payload.source_spell_name) or "")
    if sourceSpellName ~= "" then
        local texture = resolveSpellTexture(sourceSpellName)
        if hasIcon(texture) then
            return texture
        end
    end

    -- Last fallback: payload icon if it is WoW-usable (not a web URL).
    local payloadIcon = payload and payload.icon
    if hasIcon(payloadIcon) then
        return payloadIcon
    end

    return nil
end

local wowBindingToProfileKey

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
    local previousBySlot = {}
    if type(profile.keybinds) == "table" then
        for _, keybind in ipairs(profile.keybinds) do
            if type(keybind) == "table" then
                local wowKey = normalizeKey(keybind.key)
                local slot = resolvePreferredSlot(profile, keybind, wowKey, layoutBarIndexById)
                if slot then
                    previousBySlot[slot] = keybind
                end
            end
        end
    end

    local rebuiltKeybinds = {}
    local rebuiltBySlot = {}
    for slot = 1, VIEWER_SLOT_COUNT do
        local actionSlot = toBlizzardActionSlot(slot)
        local actionType, actionId = GetActionInfo(actionSlot)
        local previous = previousBySlot[slot]
        local previousSpell = type(previous) == "table" and type(previous.spell) == "table" and previous.spell or {}
        local nextSpell = nil

        if actionType == "macro" then
            local barMacro = readMacroFromActionSlot(actionSlot)
            if barMacro then
                local macroName = tostring(barMacro.name or "")
                if isGenericMacroName(macroName) and not isGenericMacroName(previousSpell.name) then
                    macroName = tostring(previousSpell.name or macroName)
                end
                local macroText = tostring(barMacro.macroText or "")
                if macroText == "" then
                    macroText = tostring(previousSpell.macroText or previousSpell.macro_text or previousSpell.text or previousSpell.body or "")
                end
                nextSpell = {
                    spellId = barMacro.spellId,
                    name = macroName ~= "" and macroName or "WoWKeybMacro",
                    icon = barMacro.icon,
                    actionType = "macro",
                    isMacro = true,
                    macroId = barMacro.macroId,
                    macroText = macroText,
                    sourceSpellId = previousSpell.sourceSpellId or previousSpell.source_spell_id or "",
                    sourceSpellName = previousSpell.sourceSpellName or previousSpell.source_spell_name or "",
                }
            else
                local macroName, macroIcon = nil, nil
                if actionId and type(GetMacroInfo) == "function" then
                    macroName, macroIcon = GetMacroInfo(actionId)
                end
                nextSpell = {
                    spellId = "macro:" .. tostring(actionId or ""),
                    name = tostring(macroName or previousSpell.name or "WoWKeybMacro"),
                    icon = macroIcon or previousSpell.icon or "",
                    actionType = "macro",
                    isMacro = true,
                    macroId = tostring(actionId or previousSpell.macroId or previousSpell.macro_id or ""),
                    macroText = tostring(previousSpell.macroText or previousSpell.macro_text or previousSpell.text or previousSpell.body or ""),
                    sourceSpellId = previousSpell.sourceSpellId or previousSpell.source_spell_id or "",
                    sourceSpellName = previousSpell.sourceSpellName or previousSpell.source_spell_name or "",
                }
            end
        else
            local barSpell = readSpellFromActionSlot(actionSlot)
            local utilityAction = nil
            if not barSpell then
                utilityAction = readUtilityActionFromActionSlot(actionSlot, actionType, actionId)
            end
            if barSpell then
                nextSpell = {
                    spellId = barSpell.spellId,
                    name = barSpell.name,
                    icon = barSpell.icon,
                    actionType = "spell",
                    isMacro = false,
                }
            elseif utilityAction then
                nextSpell = {
                    spellId = utilityAction.spellId,
                    name = utilityAction.name,
                    icon = utilityAction.icon,
                    actionType = utilityAction.actionType,
                    isMacro = false,
                }
            end
        end

        if nextSpell then
            local barIdx = math.floor((slot - 1) / 12) + 1
            local slotIdx = ((slot - 1) % 12) + 1
            local command = SLOT_COMMANDS[slot]
            local wowKey = nil
            if command and command ~= "" then
                local keys = { GetBindingKey(command) }
                for _, key in ipairs(keys) do
                    if key and key ~= "" then
                        wowKey = key
                        break
                    end
                end
            end
            local profileKey = wowBindingToProfileKey(wowKey)
            local keybind = {
                key = profileKey,
                spell = nextSpell,
                barId = "bar" .. tostring(barIdx),
                slotIndex = slotIdx - 1,
            }
            rebuiltKeybinds[#rebuiltKeybinds + 1] = keybind
            rebuiltBySlot[slot] = keybind
        end
    end

    local function slotSignature(kb)
        if type(kb) ~= "table" then
            return ""
        end
        local spell = type(kb.spell) == "table" and kb.spell or {}
        return table.concat({
            tostring(kb.key or ""),
            tostring(kb.barId or kb.bar_id or ""),
            tostring(tonumber(kb.slotIndex or kb.slot_index) or 0),
            tostring(spell.spellId or spell.spell_id or ""),
            tostring(spell.name or ""),
            tostring(spell.icon or ""),
            tostring(spell.actionType or spell.action_type or ""),
            tostring(spell.isMacro == true),
            tostring(spell.macroId or spell.macro_id or ""),
            tostring(spell.macroText or spell.macro_text or spell.text or spell.body or ""),
            tostring(spell.sourceSpellId or spell.source_spell_id or ""),
            tostring(spell.sourceSpellName or spell.source_spell_name or ""),
        }, "\31")
    end

    for slot = 1, VIEWER_SLOT_COUNT do
        if slotSignature(previousBySlot[slot]) ~= slotSignature(rebuiltBySlot[slot]) then
            changed = changed + 1
        end
    end
    profile.keybinds = rebuiltKeybinds

    -- Persist a normalized macro catalog (including icons) for cross-character viewer/export use.
    local macroById = {}
    if type(profile.macros) == "table" then
        for _, macro in ipairs(profile.macros) do
            if type(macro) == "table" then
                local existingId = tostring(macro.id or macro.macroId or macro.macro_id or "")
                if existingId ~= "" then
                    macroById[existingId] = {
                        id = existingId,
                        name = tostring(macro.name or macro.macroName or macro.macro_name or "WoWKeybMacro"),
                        macroText = tostring(macro.macroText or macro.macro_text or macro.text or macro.body or ""),
                        icon = tostring(macro.icon or ""),
                        sourceSpellId = tostring(macro.sourceSpellId or macro.source_spell_id or ""),
                        sourceSpellName = tostring(macro.sourceSpellName or macro.source_spell_name or ""),
                    }
                end
            end
        end
    end
    if type(profile.keybinds) == "table" then
        for _, keybind in ipairs(profile.keybinds) do
            local spell = keybind and keybind.spell
            if type(spell) == "table" then
                local spellIdRaw = tostring(spell.spellId or spell.spell_id or "")
                local actionType = tostring(spell.actionType or spell.action_type or ""):lower()
                local isMacro = spell.isMacro == true or actionType == "macro" or spellIdRaw:find("^macro:") ~= nil
                if isMacro then
                    local macroId = tostring(spell.macroId or spell.macro_id or spellIdRaw:match("^macro:(.+)$") or "")
                    local macroText = tostring(spell.macroText or spell.macro_text or spell.text or spell.body or "")
                    if macroId ~= "" then
                        local existing = macroById[macroId] or {}
                        macroById[macroId] = {
                            id = macroId,
                            name = tostring(spell.name or existing.name or "WoWKeybMacro"),
                            macroText = macroText ~= "" and macroText or tostring(existing.macroText or ""),
                            icon = tostring(spell.icon or existing.icon or ""),
                            sourceSpellId = tostring(spell.sourceSpellId or spell.source_spell_id or existing.sourceSpellId or ""),
                            sourceSpellName = tostring(spell.sourceSpellName or spell.source_spell_name or existing.sourceSpellName or ""),
                        }
                    end
                end
            end
        end
    end
    local mergedMacros = {}
    for _, macro in pairs(macroById) do
        if type(macro) == "table" and tostring(macro.id or "") ~= "" then
            mergedMacros[#mergedMacros + 1] = macro
        end
    end
    table.sort(mergedMacros, function(a, b)
        return tostring(a.name or ""):lower() < tostring(b.name or ""):lower()
    end)
    profile.macros = mergedMacros
    if ensureLayoutBarsFromGame then
        ensureLayoutBarsFromGame(profile)
    end

    return true, changed
end

wowBindingToProfileKey = function(bindingKey)
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

ensureLayoutBarsFromGame = function(profile)
    if type(profile) ~= "table" then
        return
    end
    profile.layout = type(profile.layout) == "table" and profile.layout or {}
    local bars = type(profile.layout.bars) == "table" and profile.layout.bars or {}
    for barIdx = 1, VIEWER_BAR_COUNT do
        local bar = bars[barIdx]
        local created = false
        if type(bar) ~= "table" then
            created = true
            bar = {
                id = "bar" .. tostring(barIdx),
                slots = 12,
                slotKeys = {},
                position = {
                    anchor = "center",
                    x = 1280,
                    y = 720,
                },
                orientation = "horizontal",
                scale = 1,
            }
            bars[barIdx] = bar
        end
        bar.slots = tonumber(bar.slots) or 12
        if barIdx == 1 then
            bar.enabled = true
        elseif isActionBarShown then
            bar.enabled = isActionBarShown(barIdx) and true or false
        elseif bar.enabled == nil then
            bar.enabled = true
        end
        if created then
            bar.slotKeys = {}
            for slotIdx = 1, 12 do
                local globalSlot = ((barIdx - 1) * 12) + slotIdx
                local command = SLOT_COMMANDS[globalSlot]
                local wowKey = command and firstBindingForCommand(command) or nil
                bar.slotKeys[slotIdx] = wowBindingToProfileKey(wowKey)
            end
        end
    end
    profile.layout.bars = bars
    if not profile.layout.barMode and not profile.layout.bar_mode then
        profile.layout.barMode = "blizzard"
    end
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

local function syncProfileContextFromPlayer(profileName)
    ensureDBDefaults()
    local targetName = profileName or WoWKeybDB.currentProfile
    if not targetName or targetName == BLIZZARD_DEFAULT_PROFILE then
        return false, 0
    end

    local profile = getStoredProfile(targetName)
    if type(profile) ~= "table" then
        return false, 0
    end

    local changed = 0

    local _, englishClass, classToken = UnitClass("player")
    local classValue = tostring(englishClass or classToken or "")
    if classValue ~= "" and tostring(profile.class or "") ~= classValue then
        profile.class = classValue
        changed = changed + 1
    end

    local specId, specName
    local specIndex = GetSpecialization and GetSpecialization() or nil
    if specIndex and GetSpecializationInfo then
        specId, specName = GetSpecializationInfo(specIndex)
    end
    local specValue = tostring(specName or specId or "")
    local specIdValue = specId and tostring(specId) or ""
    if specValue ~= "" and tostring(profile.spec or profile.spec_id or profile.specId or profile.specialization or "") ~= specValue then
        profile.spec = specValue
        changed = changed + 1
    end
    if specIdValue ~= "" and tostring(profile.specId or profile.spec_id or "") ~= specIdValue then
        profile.specId = specIdValue
        changed = changed + 1
    end

    local heroIdValue = ""
    local heroNameValue = ""
    if C_ClassTalents and type(C_ClassTalents.GetActiveHeroTalentSpec) == "function" then
        local okHero, activeHeroId = pcall(C_ClassTalents.GetActiveHeroTalentSpec)
        if okHero and activeHeroId then
            heroIdValue = tostring(activeHeroId)
            heroNameValue = resolveHeroTalentNameFromId(activeHeroId)
        end
    end
    local heroValue = heroNameValue ~= "" and heroNameValue or heroIdValue
    if heroValue ~= "" and tostring(profile.heroTalent or profile.hero_talent or profile.hero_talent_id or profile.heroTalentId or "") ~= heroValue then
        profile.heroTalent = heroValue
        changed = changed + 1
    end
    if heroIdValue ~= "" and tostring(profile.heroTalentId or profile.hero_talent_id or "") ~= heroIdValue then
        profile.heroTalentId = heroIdValue
        changed = changed + 1
    end

    return true, changed
end

local canRefreshViewerFromGame

local function syncProfileSnapshotFromGame(profileName, options)
    local targetName = profileName or WoWKeybDB.currentProfile
    local snapshotAt = time()
    local profile = getStoredProfile(targetName)
    if type(profile) ~= "table" then
        return {
            contextOk = false,
            contextChanged = 0,
            spellsOk = false,
            spellsChanged = 0,
            layoutOk = false,
            layoutChanged = 0,
            snapshotAt = snapshotAt,
            blocked = true,
            blockedReason = "profile-not-found",
        }
    end

    -- Never overwrite an off-context profile with live bars/bindings from another character/spec,
    -- unless an explicit capture operation requests a forced sync.
    local forceSync = type(options) == "table" and options.force == true
    if not forceSync and not canRefreshViewerFromGame(targetName) then
        return {
            contextOk = false,
            contextChanged = 0,
            spellsOk = false,
            spellsChanged = 0,
            layoutOk = false,
            layoutChanged = 0,
            snapshotAt = snapshotAt,
            blocked = true,
            blockedReason = "inactive-or-context-mismatch",
        }
    end

    local contextOk, contextChanged = syncProfileContextFromPlayer(profileName)
    local spellsOk, spellsChanged = syncProfileSpellsFromActionBars(profileName)
    local layoutOk, layoutChanged = syncProfileLayoutKeysFromBindings(profileName)
    if type(profile) == "table" then
        profile.lastSnapshotAt = snapshotAt
    end
    return {
        contextOk = contextOk == true,
        contextChanged = tonumber(contextChanged) or 0,
        spellsOk = spellsOk == true,
        spellsChanged = tonumber(spellsChanged) or 0,
        layoutOk = layoutOk == true,
        layoutChanged = tonumber(layoutChanged) or 0,
        snapshotAt = snapshotAt,
    }
end

canRefreshViewerFromGame = function(profileName)
    if not ENABLE_LIVE_PROFILE_SYNC then
        return false
    end
    local targetName = tostring(profileName or "")
    if targetName == "" or targetName == BLIZZARD_DEFAULT_PROFILE then
        return false
    end
    if tostring(WoWKeybDB and WoWKeybDB.currentProfile or "") ~= targetName then
        return false
    end
    local profile = getStoredProfile(targetName)
    if type(profile) ~= "table" then
        return false
    end
    if not profileMatchesCurrentClass(profile) then
        return false
    end
    if not profileMatchesCurrentSpecAndHero(profile) then
        return false
    end
    return true
end

local function canSaveViewerBarsToProfile(profileName)
    ensureDBDefaults()
    local targetName = tostring(profileName or "")
    if targetName == "" or targetName == BLIZZARD_DEFAULT_PROFILE then
        return false, "invalid-target"
    end
    if tostring(WoWKeybDB.currentProfile or "") ~= targetName then
        return false, "not-active-profile"
    end
    local profile = getStoredProfile(targetName)
    if type(profile) ~= "table" then
        return false, "profile-not-found"
    end
    if not profileMatchesCurrentClass(profile) then
        return false, "class-mismatch"
    end
    if not profileMatchesCurrentSpecAndHero(profile) then
        return false, "spec-hero-mismatch"
    end
    return true, nil
end

local function buildUniqueAutoProfileName(baseName)
    local name = tostring(baseName or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then
        name = "Auto Profile"
    end
    if not WoWKeybDB.profiles[name] then
        return name
    end
    local index = 2
    while true do
        local candidate = string.format("%s (%d)", name, index)
        if not WoWKeybDB.profiles[candidate] then
            return candidate
        end
        index = index + 1
    end
end

local function createProfileFromCurrentGameContext()
    ensureDBDefaults()

    local _, englishClass, classToken = UnitClass("player")
    local className = tostring(englishClass or classToken or "Unknown")

    local specId, specName
    local specIndex = GetSpecialization and GetSpecialization() or nil
    if specIndex and GetSpecializationInfo then
        specId, specName = GetSpecializationInfo(specIndex)
    end
    local resolvedSpecName = tostring(specName or specId or "Unknown Spec")
    local resolvedSpecId = specId and tostring(specId) or ""

    local heroIdValue = ""
    local heroNameValue = ""
    if C_ClassTalents and type(C_ClassTalents.GetActiveHeroTalentSpec) == "function" then
        local okHero, activeHeroId = pcall(C_ClassTalents.GetActiveHeroTalentSpec)
        if okHero and activeHeroId then
            heroIdValue = tostring(activeHeroId)
            heroNameValue = resolveHeroTalentNameFromId(activeHeroId)
        end
    end
    local resolvedHeroName = heroNameValue ~= "" and heroNameValue or (heroIdValue ~= "" and heroIdValue or "No Hero")

    local baseProfileName = string.format("%s - %s - %s", className, resolvedSpecName, resolvedHeroName)
    local profileName = buildUniqueAutoProfileName(baseProfileName)

    local profile = {
        name = profileName,
        class = className,
        spec = resolvedSpecName,
        specId = resolvedSpecId,
        heroTalent = resolvedHeroName,
        heroTalentId = heroIdValue,
        keybinds = {},
        layout = {
            bars = {},
            barMode = "blizzard",
            screenWidth = 2560,
            screenHeight = 1440,
            barGap = 16,
        },
    }

    ensureLayoutBarsFromGame(profile)

    for slot = 1, VIEWER_SLOT_COUNT do
        local actionSlot = toBlizzardActionSlot(slot)
        local spell = readMacroFromActionSlot(actionSlot) or readSpellFromActionSlot(actionSlot)
        if spell then
            local barIdx = math.floor((slot - 1) / 12) + 1
            local slotIdx = ((slot - 1) % 12) + 1
            local command = SLOT_COMMANDS[slot]
            local wowKey = command and firstBindingForCommand(command) or nil
            local profileKey = wowBindingToProfileKey(wowKey)

            local keybind = {
                key = profileKey,
                spell = spell,
                barId = "bar" .. tostring(barIdx),
                slotIndex = slotIdx - 1,
            }
            profile.keybinds[#profile.keybinds + 1] = keybind
        end
    end

    WoWKeybDB.profiles[profileName] = profile
    return profileName, profile
end

local function layoutBarEnabled(bar, barIndex)
    if barIndex == 1 then
        return true
    end
    if type(bar) ~= "table" then
        return true
    end
    local flag = bar.enabled
    if flag == nil then
        flag = bar.is_enabled
    end
    if flag == false or flag == 0 or flag == "0" or flag == "false" then
        return false
    end
    return true
end

local function setActionBarShown(barIndex, shown)
    if barIndex < 2 or barIndex > VIEWER_BAR_COUNT then
        return
    end
    local cvarValue = shown and "1" or "0"
    pcall(function() SetCVar("showMultiActionBar" .. (barIndex - 1), cvarValue) end)
    if Settings and type(Settings.SetValue) == "function" then
        pcall(Settings.SetValue, "PROXY_SHOW_ACTIONBAR_" .. barIndex, shown and true or false)
    end
end

local function refreshActionBarVisibility()
    if MultiActionBar_Update then pcall(MultiActionBar_Update) end
    if MultiActionBar_UpdateGrid then pcall(MultiActionBar_UpdateGrid) end
end

local function ensureBlizzardBarsVisible()
    pcall(function() SetCVar("alwaysShowActionBars", "1") end)
    for barIndex = 2, 5 do
        setActionBarShown(barIndex, true)
    end
    refreshActionBarVisibility()
end

local function applyProfileBarVisibility(profile)
    local bars = profile and profile.layout and profile.layout.bars
    if type(bars) ~= "table" or #bars == 0 then
        ensureBlizzardBarsVisible()
        return
    end
    local count = math.min(#bars, VIEWER_BAR_COUNT)
    for barIndex = 2, count do
        setActionBarShown(barIndex, layoutBarEnabled(bars[barIndex], barIndex))
    end
    refreshActionBarVisibility()
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
        for barIndex = 2, 5 do
            setActionBarShown(barIndex, false)
        end
        pcall(function() SetCVar("alwaysShowActionBars", "0") end)
        refreshActionBarVisibility()
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
    for slot = 1, VIEWER_SLOT_COUNT do
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
        setCurrentProfile(BLIZZARD_DEFAULT_PROFILE)
    end
    return true, "Applied Blizzard default bars"
end

local function clearActionBarsAndBindings()
    if InCombatLockdown() then
        return false, "Cannot clear bars and bindings while in combat"
    end

    for slot = 1, VIEWER_SLOT_COUNT do
        local actionSlot = toBlizzardActionSlot(slot)
        if actionSlot and type(ClearAction) == "function" then
            pcall(function()
                ClearAction(actionSlot)
            end)
        end
    end

    for slot = 1, VIEWER_SLOT_COUNT do
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

    if type(GetCurrentBindingSet) == "function" and type(SaveBindings) == "function" then
        local bindingSet = GetCurrentBindingSet()
        SaveBindings(bindingSet)
    end

    return true
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
            setCurrentProfile(target)
        end
        setPreferredProfileForCurrentContext(target)

        -- After a successful apply, immediately snapshot the stored profile from game
        -- so viewer/export reflects the latest applied bars, keys, and macros.
        syncProfileSnapshotFromGame(target, { force = true })
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
    applyProfileBarVisibility(profile)
    setDefaultBarsAlpha(1)

    local PickupSpell = _G.PickupSpell
    if C_Spell and type(C_Spell.PickupSpell) == "function" then
        PickupSpell = C_Spell.PickupSpell
    end
    local GetSpellInfo = C_Spell and C_Spell.GetSpellName or _G.GetSpellInfo
    local layoutBarIndexById = buildLayoutBarIndexById(profile)
    local layoutSlotToKey = {}
    local macroLookup = buildProfileMacroLookup(profile)

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
                        if slot >= 1 and slot <= VIEWER_SLOT_COUNT and SLOT_COMMANDS[slot] then
                            layoutSlotToKey[slot] = wowLayoutKey
                        end
                    end
                end
            end
        end
    end

    -- Only the bars stored on this profile are cleared and rewritten.
    -- Extra bars the profile does not mention stay as they are in game.
    local managedSlotCount = 60
    if hasLayout then
        local barCount = math.min(#profile.layout.bars, VIEWER_BAR_COUNT)
        if barCount < 1 then
            barCount = 1
        end
        managedSlotCount = barCount * 12
    end

    -- Remove existing bindings for action bar commands before re-applying.
    -- This prevents stale bindings from older profiles from sticking around.
    for slot = 1, managedSlotCount do
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
            for slot = 1, managedSlotCount do
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
    local macroAssignments = 0
    local macroCreated = 0
    local macroReused = 0
    local macroFailed = 0
    local macroPlaced = 0
    local macroParseCache = {}
    local debugApplySlots = WoWKeybDB.debugApplySlots == true
    local debugApplyAssignments = WoWKeybDB.debugApplyAssignments == true

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
            local entryActionType = tostring(spell.actionType or spell.action_type or ""):lower()
            local macroPayload = extractMacroPayload(spell, macroLookup)
            if debugApplyAssignments and not macroPayload then
                local rawActionType = tostring(spell and (spell.actionType or spell.action_type) or "")
                local rawIsMacro = tostring(spell and spell.isMacro or false)
                local rawSpellId = tostring(spell and (spell.spellId or spell.spell_id or spell.id) or "")
                local rawMacroId = tostring(spell and (spell.macroId or spell.macro_id) or "")
                local rawMacroText = tostring(spell and (spell.macroText or spell.macro_text or spell.text or spell.body) or "")
                addonChat("|cffffcc00[WoWKeyb]|r [macro-detect] slot=" .. tostring(slot)
                    .. " key=" .. tostring(wowKey or "-")
                    .. " detected=false"
                    .. " actionType=" .. tostring(rawActionType ~= "" and rawActionType or "-")
                    .. " isMacro=" .. tostring(rawIsMacro)
                    .. " spellId=" .. tostring(rawSpellId ~= "" and rawSpellId or "-")
                    .. " macroId=" .. tostring(rawMacroId ~= "" and rawMacroId or "-")
                    .. " macroTextLen=" .. tostring(#rawMacroText))
            end

            if spellId then
                local nameFromId = GetSpellInfo(spellId)
                if nameFromId then spellName = nameFromId end
            end

            if (not macroPayload) and entryActionType ~= "" and entryActionType ~= "spell" then
                skipped = skipped + 1
                if debugApplySlots then
                    addonChat("|cffffcc00[WoWKeyb]|r [slot-debug] slot=" .. tostring(slot)
                        .. " blizzSlot=" .. tostring(toBlizzardActionSlot(slot))
                        .. " key=" .. tostring(wowKey or "")
                        .. " spellId=" .. tostring(spellId or "")
                        .. " spell=\"" .. tostring(spellName or "") .. "\" result=skip reason=unsupported-action-type("
                        .. tostring(entryActionType) .. ")")
                end
            elseif (not macroPayload) and ((not spellId and not spellName) or spellName == "") then
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
                local macroResult = "n/a"
                local isMacroAssignment = macroPayload and true or false

                -- 1. Place spell on action bar (default WoW UI)
                if macroPayload then
                    macroAssignments = macroAssignments + 1
                    if debugApplyAssignments or debugApplySlots then
                        local accountDiag = getMacroAccountMatchDiagnostics(macroPayload)
                        addonChat("|cffffcc00[WoWKeyb]|r [macro-account] slot=" .. tostring(slot)
                            .. " key=" .. tostring(wowKey or "-")
                            .. " macroName=\"" .. tostring(macroPayload.name or "WoWKeybMacro") .. "\""
                            .. " totalAccountMacros=" .. tostring(accountDiag.total or 0)
                            .. " byName=" .. tostring(accountDiag.byName or "-")
                            .. " byBody=" .. tostring(accountDiag.byBody or "-"))
                    end
                    local macroIndex, ensureReason = ensureMacroForPayload(macroPayload)
                    macroResult = ensureReason or "unknown"
                    if ensureReason == "created" then
                        macroCreated = macroCreated + 1
                    elseif ensureReason and tostring(ensureReason):find("^reused%-existing") then
                        macroReused = macroReused + 1
                    elseif not macroIndex then
                        macroFailed = macroFailed + 1
                    end
                    if debugApplyAssignments or debugApplySlots then
                        addonChat("|cffffcc00[WoWKeyb]|r [macro-ensure] slot=" .. tostring(slot)
                            .. " blizzSlot=" .. tostring(actionSlot)
                            .. " key=" .. tostring(wowKey or "-")
                            .. " macroId=" .. tostring(macroPayload.macroId or "-")
                            .. " macroName=\"" .. tostring(macroPayload.name or "WoWKeybMacro") .. "\""
                            .. " result=" .. tostring(macroResult)
                            .. " macroIndex=" .. tostring(macroIndex or "-"))
                    end
                    if macroIndex and type(PickupMacro) == "function" then
                        if ensureReason == "created" and type(EditMacro) == "function" and type(GetMacroInfo) == "function" then
                            local resolvedIcon = resolveMacroIconForPayload(macroPayload, macroIndex)
                            if resolvedIcon then
                                local macroNameForEdit, _, macroBodyForEdit = GetMacroInfo(macroIndex)
                                pcall(function()
                                    EditMacro(
                                        macroIndex,
                                        macroNameForEdit or macroPayload.name or "WoWKeybMacro",
                                        resolvedIcon,
                                        macroBodyForEdit or macroPayload.body or "",
                                        true
                                    )
                                end)
                            end
                        end
                        if type(ClearAction) == "function" then
                            pcall(function()
                                ClearAction(actionSlot)
                            end)
                        end
                        local pickedUpMacro = false
                        local cursorType = nil
                        local cursorPayload = nil
                        pcall(function()
                            PickupMacro(macroIndex)
                        end)
                        cursorType, cursorPayload = GetCursorInfo()
                        pickedUpMacro = cursorType == "macro"
                        if pickedUpMacro then
                            PlaceAction(actionSlot)
                            ClearCursor()
                            placeResult = "placed"
                            placeReason = "macro-" .. tostring(ensureReason or "ready")
                            macroPlaced = macroPlaced + 1
                            if debugApplyAssignments or debugApplySlots then
                                addonChat("|cffffcc00[WoWKeyb]|r [macro-place] slot=" .. tostring(slot)
                                    .. " blizzSlot=" .. tostring(actionSlot)
                                    .. " macroIndex=" .. tostring(macroIndex)
                                    .. " result=placed")
                            end
                        else
                            placeResult = "skip"
                            placeReason = "macro-pickup-failed"
                            if debugApplyAssignments or debugApplySlots then
                                addonChat("|cffffcc00[WoWKeyb]|r [macro-place] slot=" .. tostring(slot)
                                    .. " blizzSlot=" .. tostring(actionSlot)
                                    .. " macroIndex=" .. tostring(macroIndex)
                                    .. " result=skip reason=pickup-failed"
                                    .. " cursorType=" .. tostring(cursorType or "-")
                                    .. " cursorPayload=" .. tostring(cursorPayload or "-"))
                            end
                        end
                    else
                        placeResult = "skip"
                        placeReason = "macro-missing"
                        if debugApplyAssignments or debugApplySlots then
                            addonChat("|cffffcc00[WoWKeyb]|r [macro-place] slot=" .. tostring(slot)
                                .. " blizzSlot=" .. tostring(actionSlot)
                                .. " result=skip reason=macro-missing")
                        end
                    end
                elseif not keepMacro then
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

                -- Temporary visibility: print what this slot is receiving during apply.
                local assignedLabel
                if isMacroAssignment then
                    local macroName = tostring(macroPayload and macroPayload.name or "Macro")
                    local macroId = tostring(macroPayload and macroPayload.macroId or "")
                    if macroId ~= "" then
                        assignedLabel = string.format("macro \"%s\" [id:%s]", macroName, macroId)
                    else
                        assignedLabel = string.format("macro \"%s\"", macroName)
                    end
                else
                    local resolvedSpellName = tostring(spellName or "")
                    if resolvedSpellName == "" then
                        resolvedSpellName = "(unknown spell)"
                    end
                    assignedLabel = string.format("spell \"%s\"", resolvedSpellName)
                end
                if debugApplyAssignments then
                    addonChat("|cffffcc00[WoWKeyb]|r [apply] slot=" .. tostring(slot)
                        .. " blizzSlot=" .. tostring(actionSlot)
                        .. " key=" .. tostring(wowKey or "-")
                        .. " assign=" .. assignedLabel)
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
                    local macroDebugId = macroPayload and tostring(macroPayload.macroId or "") or ""
                    local macroDebugName = macroPayload and tostring(macroPayload.name or "") or ""
                    local macroDebugSource = macroPayload and tostring(macroPayload.source or "") or ""
                    local macroBodyLen = macroPayload and #tostring(macroPayload.body or "") or 0
                    addonChat("|cffffcc00[WoWKeyb]|r [macro-debug] slot=" .. tostring(slot)
                        .. " blizzSlot=" .. tostring(actionSlot)
                        .. " key=" .. tostring(wowKey or "")
                        .. " id=" .. tostring(macroDebugId ~= "" and macroDebugId or "-")
                        .. " name=\"" .. tostring(macroDebugName ~= "" and macroDebugName or "-") .. "\""
                        .. " bodyChars=" .. tostring(macroBodyLen)
                        .. " source=" .. tostring(macroDebugSource ~= "" and macroDebugSource or "-")
                        .. " ensure=" .. tostring(macroResult))
                    local actualSpell = readSpellFromActionSlot(actionSlot)
                    local actualSpellId = actualSpell and tostring(actualSpell.spellId or "") or ""
                    local actualSpellName = actualSpell and tostring(actualSpell.name or "") or ""
                    addonChat("|cffffcc00[WoWKeyb]|r [slot-debug] slot=" .. tostring(slot)
                        .. " blizzSlot=" .. tostring(actionSlot)
                        .. " key=" .. tostring(wowKey or "")
                        .. " spellId=" .. tostring(spellId or "")
                        .. " spell=\"" .. tostring(spellName or "") .. "\""
                        .. " place=" .. tostring(placeResult) .. "(" .. tostring(placeReason) .. ")"
                        .. " macro=" .. tostring(macroResult)
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
        setCurrentProfile(profileName)
    end

    WoWKeyb.isApplyingProfile = false
    local summary = string.format("Applied %d keybindings (%d skipped) [mode: blizzard]", applied, skipped)
    if macroAssignments > 0 then
        summary = summary .. string.format(
            " | Macros: %d assigned, %d placed, %d created, %d reused, %d failed",
            macroAssignments,
            macroPlaced,
            macroCreated,
            macroReused,
            macroFailed
        )
    end
    return true, summary
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
    -- Strictly manual profile selection:
    -- never auto-switch to another WoWKeyb profile, but reset to Blizzard Default
    -- if the carried current profile does not match the active character context.
    ensureDBDefaults()

    local current = tostring(WoWKeybDB.currentProfile or "")
    if current == "" then
        setCurrentProfile(BLIZZARD_DEFAULT_PROFILE, false)
        return
    end
    if current == BLIZZARD_DEFAULT_PROFILE then
        return
    end

    local profile = getStoredProfile(current)
    local shouldFallback = false
    if type(profile) ~= "table" then
        shouldFallback = true
    else
        if not profileMatchesCurrentClass(profile) then
            shouldFallback = true
        elseif not profileMatchesCurrentSpecAndHero(profile) then
            shouldFallback = true
        end
    end

    if not shouldFallback then
        return
    end

    WoWKeybDB.previousProfile = current
    setCurrentProfile(BLIZZARD_DEFAULT_PROFILE, false)

    local announce = shouldAnnounceContextAutoSwitch(triggerEvent)
    if announce then
        print("|cffffcc00[WoWKeyb]|r Current profile \"" .. tostring(current)
            .. "\" does not match this character setup. Switched to Blizzard Default.")
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
    local output = {}
    local inputLength = #input

    -- Process in fixed-size windows; avoid huge vararg expansion from string.byte(input, 1, #input).
    for i = 1, inputLength, 3 do
        local b1, b2, b3 = string.byte(input, i, i + 2)
        b1 = b1 or 0
        b2 = b2 or 0
        b3 = b3 or 0
        local n = (b1 * 65536) + (b2 * 256) + b3

        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64

        output[#output + 1] = BASE64_ALPHABET:sub(c1 + 1, c1 + 1)
        output[#output + 1] = BASE64_ALPHABET:sub(c2 + 1, c2 + 1)
        output[#output + 1] = (i + 1 <= inputLength) and BASE64_ALPHABET:sub(c3 + 1, c3 + 1) or "="
        output[#output + 1] = (i + 2 <= inputLength) and BASE64_ALPHABET:sub(c4 + 1, c4 + 1) or "="
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

local incomingShareTransfers = {}
local pendingShareImports = {}

local function computeShareChecksum(text)
    local sum = 0
    local input = tostring(text or "")
    for i = 1, #input do
        sum = (sum + (string.byte(input, i) or 0)) % 2147483647
    end
    return tostring(sum)
end

local function splitIntoShareChunks(text, chunkSize)
    local chunks = {}
    local payload = tostring(text or "")
    local size = tonumber(chunkSize) or SHARE_CHUNK_SIZE
    if size < 1 then size = SHARE_CHUNK_SIZE end
    if payload == "" then
        chunks[1] = ""
        return chunks
    end
    for i = 1, #payload, size do
        chunks[#chunks + 1] = payload:sub(i, i + size - 1)
    end
    return chunks
end

local function trimRealmFromName(fullName)
    local value = tostring(fullName or "")
    local nameOnly = value:match("^([^%-]+)")
    if nameOnly and nameOnly ~= "" then
        return nameOnly
    end
    return value
end

local function buildUniqueProfileName(baseName)
    local root = tostring(baseName or ""):trim()
    if root == "" then
        root = "ImportedProfile"
    end
    if not WoWKeybDB.profiles[root] then
        return root
    end
    local candidate = root .. " (Copy)"
    if not WoWKeybDB.profiles[candidate] then
        return candidate
    end
    local index = 2
    while true do
        candidate = string.format("%s (Copy %d)", root, index)
        if not WoWKeybDB.profiles[candidate] then
            return candidate
        end
        index = index + 1
    end
end

local function refreshOptionsPanelViews()
    if WoWKeyb.optionsPanel and WoWKeyb.optionsPanel.refreshCurrentProfileText then
        WoWKeyb.optionsPanel.refreshCurrentProfileText()
    end
    if WoWKeyb.optionsPanel and WoWKeyb.optionsPanel.refreshProfileSelector then
        WoWKeyb.optionsPanel.refreshProfileSelector()
    end
end

local function importSharedPayload(payload, senderLabel, profileHint)
    local normalizedPayload = tostring(payload or ""):trim()
    if normalizedPayload == "" then
        return false, "Empty share payload"
    end
    local decodedJson = decodeProfileShareCode(normalizedPayload) or normalizedPayload
    local decoded = WoWKeyb:ParseWoWKeybJSON(decodedJson)
    if not decoded or type(decoded) ~= "table" or type(decoded.keybinds) ~= "table" then
        return false, "Invalid shared profile payload"
    end

    local baseName = tostring(decoded.name or profileHint or "ImportedProfile")
    local finalName = buildUniqueProfileName(baseName)
    decoded.name = finalName
    WoWKeybDB.profiles[finalName] = decoded

    refreshOptionsPanelViews()
    print("|cff00ff00[WoWKeyb]|r Imported shared profile: " .. tostring(finalName)
        .. " from " .. tostring(senderLabel or "unknown sender"))
    return true, finalName
end

local function cleanupExpiredShareState()
    local now = time()
    for key, transfer in pairs(incomingShareTransfers) do
        if type(transfer) ~= "table" or (transfer.createdAt and (now - transfer.createdAt) > SHARE_ENTRY_TTL_SECONDS) then
            incomingShareTransfers[key] = nil
        end
    end
    for token, pending in pairs(pendingShareImports) do
        if type(pending) ~= "table" or (pending.createdAt and (now - pending.createdAt) > SHARE_ENTRY_TTL_SECONDS) then
            pendingShareImports[token] = nil
        end
    end
end

local function shareTokenFor(sender, transferId)
    local safeSender = tostring(sender or "unknown"):gsub("[|:%s]", "_")
    local safeTransferId = tostring(transferId or ""):gsub("[|:%s]", "_")
    return safeSender .. "_" .. safeTransferId
end

local function promptImportSharedToken(token)
    local entry = pendingShareImports[token]
    if type(entry) ~= "table" then
        print("|cffff0000[WoWKeyb]|r Shared profile link expired or not found.")
        return
    end
    if not StaticPopupDialogs["WOWKEYB_IMPORT_SHARED_CONFIRM"] then
        StaticPopupDialogs["WOWKEYB_IMPORT_SHARED_CONFIRM"] = {
            text = "Import shared profile \"%s\" from %s?",
            button1 = "Import",
            button2 = "Cancel",
            OnAccept = function(_, data)
                if type(data) ~= "table" then
                    return
                end
                local ok, result = importSharedPayload(data.payload, data.sender, data.profileName)
                if ok then
                    pendingShareImports[data.token] = nil
                    WoWKeyb:ShowKeybindingViewer(result)
                else
                    print("|cffff0000[WoWKeyb]|r Failed to import shared profile: " .. tostring(result or "Unknown error"))
                end
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end
    StaticPopup_Show("WOWKEYB_IMPORT_SHARED_CONFIRM", tostring(entry.profileName or "SharedProfile"), tostring(entry.sender or "unknown"), {
        token = token,
        sender = entry.sender,
        profileName = entry.profileName,
        payload = entry.payload,
    })
end

local function handleIncomingShareAddonMessage(message, sender)
    cleanupExpiredShareState()
    local fields = {}
    for part in tostring(message or ""):gmatch("([^|]+)") do
        fields[#fields + 1] = part
    end
    if fields[1] ~= "WKSHARE" or fields[2] ~= SHARE_PROTOCOL_VERSION then
        return
    end

    local msgType = fields[3]
    local transferId = tostring(fields[4] or "")
    if transferId == "" then
        return
    end

    local senderKey = tostring(sender or "unknown")
    local transferKey = senderKey .. ":" .. transferId
    local now = time()

    if msgType == "START" then
        local totalChunks = tonumber(fields[5] or "0") or 0
        local totalLength = tonumber(fields[6] or "0") or 0
        local profileName = tostring(fields[7] or "SharedProfile")
        incomingShareTransfers[transferKey] = {
            sender = senderKey,
            transferId = transferId,
            totalChunks = totalChunks,
            totalLength = totalLength,
            profileName = profileName,
            chunks = {},
            createdAt = now,
        }
        return
    end

    local transfer = incomingShareTransfers[transferKey]
    if type(transfer) ~= "table" then
        return
    end
    transfer.createdAt = now

    if msgType == "CHUNK" then
        local idx = tonumber(fields[5] or "0") or 0
        local chunkData = tostring(fields[6] or "")
        if idx >= 1 and idx <= math.max(transfer.totalChunks, 1) then
            transfer.chunks[idx] = chunkData
        end
        return
    end

    if msgType == "END" then
        local expectedChecksum = tostring(fields[5] or "")
        local assembled = {}
        for i = 1, transfer.totalChunks do
            local piece = transfer.chunks[i]
            if piece == nil then
                print("|cffff0000[WoWKeyb]|r Shared profile transfer incomplete from " .. tostring(senderKey))
                incomingShareTransfers[transferKey] = nil
                return
            end
            assembled[#assembled + 1] = piece
        end
        local payload = table.concat(assembled)
        if transfer.totalLength > 0 and #payload ~= transfer.totalLength then
            print("|cffff0000[WoWKeyb]|r Shared profile transfer size mismatch from " .. tostring(senderKey))
            incomingShareTransfers[transferKey] = nil
            return
        end
        local actualChecksum = computeShareChecksum(payload)
        if expectedChecksum ~= "" and expectedChecksum ~= actualChecksum then
            print("|cffff0000[WoWKeyb]|r Shared profile checksum mismatch from " .. tostring(senderKey))
            incomingShareTransfers[transferKey] = nil
            return
        end

        local token = shareTokenFor(senderKey, transferId)
        pendingShareImports[token] = {
            token = token,
            sender = senderKey,
            profileName = transfer.profileName,
            payload = payload,
            createdAt = now,
        }
        incomingShareTransfers[transferKey] = nil

        local fromName = trimRealmFromName(senderKey)
        local displayName = tostring(transfer.profileName or "SharedProfile")
        local importLink = string.format("|Hwowkeybshare:%s|h|cff00ff00[Import \"%s\" from %s]|r|h", token, displayName, fromName)
        print("|cffffcc00[WoWKeyb]|r Shared profile received: " .. importLink)
    end
end

local function sendProfileShareWhisper(targetPlayer, profileName, shareCode)
    if not C_ChatInfo or type(C_ChatInfo.SendAddonMessage) ~= "function" then
        return false, "Addon chat API unavailable"
    end
    local target = tostring(targetPlayer or ""):trim()
    if target == "" then
        return false, "Missing target player"
    end
    local payload = tostring(shareCode or "")
    if payload == "" then
        return false, "Empty share code"
    end
    local chunks = splitIntoShareChunks(payload, SHARE_CHUNK_SIZE)
    local transferId = string.format("%d%04d", tonumber(time() or 0) % 100000000, math.random(0, 9999))
    local safeProfileName = tostring(profileName or "SharedProfile"):gsub("|", "/")
    local checksum = computeShareChecksum(payload)

    local queue = {}
    queue[#queue + 1] = table.concat({
        "WKSHARE",
        SHARE_PROTOCOL_VERSION,
        "START",
        transferId,
        tostring(#chunks),
        tostring(#payload),
        safeProfileName,
    }, "|")
    for i, chunk in ipairs(chunks) do
        queue[#queue + 1] = table.concat({
            "WKSHARE",
            SHARE_PROTOCOL_VERSION,
            "CHUNK",
            transferId,
            tostring(i),
            tostring(chunk or ""),
        }, "|")
    end
    queue[#queue + 1] = table.concat({
        "WKSHARE",
        SHARE_PROTOCOL_VERSION,
        "END",
        transferId,
        checksum,
    }, "|")

    local function sendAt(index)
        local messagePart = queue[index]
        if not messagePart then
            return
        end
        C_ChatInfo.SendAddonMessage(ADDON_SHARE_PREFIX, messagePart, "WHISPER", target)
        if index < #queue and C_Timer and type(C_Timer.After) == "function" then
            C_Timer.After(0.03, function()
                sendAt(index + 1)
            end)
        end
    end

    if C_Timer and type(C_Timer.After) == "function" then
        sendAt(1)
    else
        for i = 1, #queue do
            C_ChatInfo.SendAddonMessage(ADDON_SHARE_PREFIX, queue[i], "WHISPER", target)
        end
    end
    return true, string.format("Sent profile \"%s\" to %s (%d chunks)", tostring(profileName or "SharedProfile"), target, #chunks)
end

local function serializeSyncedProfile(profileName, profile)
    ensureDBDefaults()
    if not profile then
        return nil, "Profile not found"
    end

    local pName = tostring(profile.name or profileName or "ImportedProfile")
    local keybindChunks = {}
    local macroChunks = {}
    local macroById = {}
    local function collectMacro(macroId, macroName, macroText, sourceSpellId, sourceSpellName, macroIcon)
        local id = normalizeMacroId(macroId)
        local text = tostring(macroText or "")
        if id == "" or text == "" then return end
        if macroById[id] then return end
        macroById[id] = true
        macroChunks[#macroChunks + 1] = table.concat({
            '{"id":"', jsonEscape(id),
            '","name":"', jsonEscape(macroName or "WoWKeybMacro"),
            '","macroText":"', jsonEscape(text),
            '","icon":"', jsonEscape(macroIcon or ""),
            '","sourceSpellId":"', jsonEscape(sourceSpellId or ""),
            '","sourceSpellName":"', jsonEscape(sourceSpellName or ""),
            '"}'
        })
    end
    local keybinds = profile.keybinds or {}
    for _, kb in ipairs(keybinds) do
        local spell = kb.spell or {}
        local spellId = tostring(spell.spellId or spell.spell_id or "")
        local key = tostring(kb.key or "")
        local actionType = tostring(spell.actionType or spell.action_type or "")
        local isMacro = (spell.isMacro == true) or (actionType:lower() == "macro") or spellId:lower():find("^macro:") ~= nil
        local macroId = normalizeMacroId(spell.macroId or spell.macro_id or spellId:match("^macro:(.+)$"))
        local macroText = tostring(spell.macroText or spell.macro_text or spell.text or spell.body or "")
        local sourceSpellId = tostring(spell.sourceSpellId or spell.source_spell_id or "")
        local sourceSpellName = tostring(spell.sourceSpellName or spell.source_spell_name or "")
        local spellJson = table.concat({
            '{"spellId":"', jsonEscape(spellId),
            '","name":"', jsonEscape(spell.name or ""),
            '","icon":"', jsonEscape(spell.icon or ""),
            '","description":"', jsonEscape(spell.description or ""),
            '","actionType":"', jsonEscape(actionType ~= "" and actionType or (isMacro and "macro" or "spell")),
            '","isMacro":', tostring(isMacro and true or false),
            ',"macroId":"', jsonEscape(macroId),
            '","macroText":"', jsonEscape(macroText),
            '","sourceSpellId":"', jsonEscape(sourceSpellId),
            '","sourceSpellName":"', jsonEscape(sourceSpellName),
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
        if isMacro and macroId ~= "" and macroText ~= "" then
            collectMacro(macroId, spell.name or spell.macroName or "WoWKeybMacro", macroText, sourceSpellId, sourceSpellName, spell.icon)
        end
    end

    if type(profile.macros) == "table" then
        for _, macro in ipairs(profile.macros) do
            if type(macro) == "table" then
                local macroId = normalizeMacroId(macro.id or macro.macroId or macro.macro_id)
                local macroText = macro.macroText or macro.macro_text or macro.text or macro.body
                local macroName = macro.name or macro.macroName or macro.macro_name or "WoWKeybMacro"
                local sourceSpellId = macro.sourceSpellId or macro.source_spell_id or ""
                local sourceSpellName = macro.sourceSpellName or macro.source_spell_name or ""
                collectMacro(macroId, macroName, macroText, sourceSpellId, sourceSpellName, macro.icon)
            end
        end
    end

    local layout = profile.layout or {}
    local bars = layout.bars or {}
    local layoutChunks = {}
    local screenW = tonumber(layout.screenWidth) or 2560
    local screenH = tonumber(layout.screenHeight) or 1440
    for barIndex, bar in ipairs(bars) do
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
            ',"enabled":', layoutBarEnabled(bar, barIndex) and "true" or "false",
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

    local exportedAt = tostring(time())
    local snapshotAt = tostring(profile.lastSnapshotAt or profile.last_snapshot_at or exportedAt)

    local profileJson = table.concat({
        '{"name":"', jsonEscape(pName),
        '","exportedAt":"', jsonEscape(exportedAt),
        '","snapshotAt":"', jsonEscape(snapshotAt),
        '","class":"', jsonEscape(profile.class or ""),
        '","spec":"', jsonEscape(profile.spec or profile.spec_id or profile.specId or profile.specialization or ""),
        '","specId":"', jsonEscape(profile.specId or profile.spec_id or ""),
        '","heroTalent":"', jsonEscape(profile.heroTalent or profile.hero_talent or profile.hero_talent_id or profile.heroTalentId or ""),
        '","heroTalentId":"', jsonEscape(profile.heroTalentId or profile.hero_talent_id or ""),
        '","keybinds":', toJSONArray(keybindChunks),
        ',"macros":', toJSONArray(macroChunks),
        ',"layout":', layoutJson,
        '}'
    })
    return profileJson
end

local function buildViewerData(profile)
    local keyToEntries = {}
    local slotData = {}
    local macroEntries = {}
    local keybinds = profile and profile.keybinds or {}
    local layoutBarIndexById = buildLayoutBarIndexById(profile)
    local debugViewerSlots = WoWKeybDB.debugViewerSlots == true
    local macroLookup = buildProfileMacroLookup(profile)
    local macroBySignature = {}

    local function formatMacroUsage(slot, key)
        local keyLabel = tostring(key or "")
        if keyLabel == "" then keyLabel = "-" end
        if not slot then
            return "Key " .. keyLabel
        end
        local barIdx = math.floor((slot - 1) / 12) + 1
        local slotIdx = ((slot - 1) % 12) + 1
        return string.format("Bar %d Slot %d (%s)", barIdx, slotIdx, keyLabel)
    end

    local function ensureMacroEntry(macroPayload)
        if type(macroPayload) ~= "table" then return nil end
        local signature = ""
        if macroPayload.macroId and tostring(macroPayload.macroId) ~= "" then
            signature = "id:" .. tostring(macroPayload.macroId)
        else
            local normalizedBody = normalizeMacroBodyForMatch(macroPayload.body)
            if normalizedBody ~= "" then
                signature = "body:" .. normalizedBody
            else
                signature = "name:" .. tostring(macroPayload.name or "")
            end
        end
        if signature == "" then
            return nil
        end
        local existing = macroBySignature[signature]
        if existing then
            if (not existing.icon or existing.icon == "") and macroPayload.icon and tostring(macroPayload.icon) ~= "" then
                existing.icon = tostring(macroPayload.icon)
            end
            if (not existing.body or existing.body == "") and macroPayload.body and tostring(macroPayload.body) ~= "" then
                existing.body = tostring(macroPayload.body)
            end
            if (not existing.sourceSpellId or existing.sourceSpellId == "")
                and macroPayload.sourceSpellId and tostring(macroPayload.sourceSpellId) ~= "" then
                existing.sourceSpellId = tostring(macroPayload.sourceSpellId)
            end
            if (not existing.sourceSpellName or existing.sourceSpellName == "")
                and macroPayload.sourceSpellName and tostring(macroPayload.sourceSpellName) ~= "" then
                existing.sourceSpellName = tostring(macroPayload.sourceSpellName)
            end
            return existing
        end
        local entry = {
            name = tostring(macroPayload.name or "WoWKeybMacro"),
            macroId = tostring(macroPayload.macroId or ""),
            source = tostring(macroPayload.source or "spell"),
            icon = tostring(macroPayload.icon or ""),
            body = tostring(macroPayload.body or ""),
            sourceSpellId = tostring(macroPayload.sourceSpellId or ""),
            sourceSpellName = tostring(macroPayload.sourceSpellName or ""),
            usages = {},
        }
        macroBySignature[signature] = entry
        macroEntries[#macroEntries + 1] = entry
        return entry
    end
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

    local function resolveViewerMacroIcon(spell, macroPayload)
        if type(macroPayload) ~= "table" then return nil end

        local existingIcon = spell and spell.icon
        if existingIcon and tostring(existingIcon) ~= "" then
            local iconStr = tostring(existingIcon)
            local lowerIcon = iconStr:lower()
            if iconStr ~= "0" and not lowerIcon:find("^https?://") then
                return existingIcon
            end
        end

        local macroIndex
        local macroBody = tostring(macroPayload.body or "")
        if macroBody ~= "" and type(GetMacroInfo) == "function" then
            macroIndex = findExistingMacroByBody(macroBody)
        end
        if (not macroIndex) and type(GetMacroIndexByName) == "function" then
            local byName = GetMacroIndexByName(tostring(macroPayload.name or ""))
            if byName and tonumber(byName) and tonumber(byName) > 0 then
                macroIndex = tonumber(byName)
            end
        end
        if macroIndex and type(GetMacroInfo) == "function" then
            local _, macroIcon = GetMacroInfo(macroIndex)
            if macroIcon and tostring(macroIcon) ~= "" and tostring(macroIcon) ~= "0" then
                return macroIcon
            end
        end

        local fallbackIcon = resolveMacroIconForPayload({
            body = tostring(macroPayload.body or ""),
            icon = macroPayload.icon or (spell and spell.icon),
            sourceSpellId = tostring(macroPayload.sourceSpellId or (spell and (spell.sourceSpellId or spell.source_spell_id)) or ""),
            sourceSpellName = tostring(macroPayload.sourceSpellName or (spell and (spell.sourceSpellName or spell.source_spell_name)) or ""),
        }, macroIndex)
        if fallbackIcon and tostring(fallbackIcon) ~= "" then
            return fallbackIcon
        end
        return nil
    end

    local function resolveViewerMacroDisplay(spell, macroPayload)
        if type(macroPayload) ~= "table" then
            return "", nil
        end

        local displayName = tostring((spell and spell.name) or macroPayload.name or "")
        local normalized = displayName:lower():gsub("^%s+", ""):gsub("%s+$", "")
        local needsNameLookup = (normalized == "" or normalized == "macro")
        local resolvedIcon = resolveViewerMacroIcon(spell, macroPayload)

        local macroId = tonumber(macroPayload.macroId or (spell and spell.macroId) or (spell and spell.macro_id) or "")
        if needsNameLookup and macroId and macroId > 0 and type(GetMacroInfo) == "function" then
            local macroName, macroIcon = GetMacroInfo(macroId)
            if macroName and tostring(macroName) ~= "" then
                displayName = tostring(macroName)
                needsNameLookup = false
            end
            if (not resolvedIcon or tostring(resolvedIcon) == "") and macroIcon and tostring(macroIcon) ~= "" then
                resolvedIcon = macroIcon
            end
        end

        if (needsNameLookup or not resolvedIcon or tostring(resolvedIcon) == "")
            and type(GetMacroIndexByName) == "function" then
            local lookupName = tostring(macroPayload.name or displayName or "")
            if lookupName ~= "" then
                local byName = GetMacroIndexByName(lookupName)
                if byName and tonumber(byName) and tonumber(byName) > 0 and type(GetMacroInfo) == "function" then
                    local macroName, macroIcon = GetMacroInfo(tonumber(byName))
                    if needsNameLookup and macroName and tostring(macroName) ~= "" then
                        displayName = tostring(macroName)
                        needsNameLookup = false
                    end
                    if (not resolvedIcon or tostring(resolvedIcon) == "") and macroIcon and tostring(macroIcon) ~= "" then
                        resolvedIcon = macroIcon
                    end
                end
            end
        end

        if displayName == "" then
            displayName = tostring(macroPayload.name or "Macro")
        end
        return displayName, resolvedIcon
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
    for barIdx = 1, VIEWER_BAR_COUNT do
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
            local wowKey = normalizeKey(kb.key or "")
            local slot = resolvePreferredSlot(profile, kb, wowKey, layoutBarIndexById)
            -- Viewer fallback: prefer explicit bar/slot metadata when available so
            -- cross-character profile viewing does not drop entries on key mismatch.
            if (not slot) and ((kb.barId or kb.bar_id) and (kb.slotIndex or kb.slot_index) ~= nil) then
                local explicitSlot = resolveExplicitSlotCandidate(kb, layoutBarIndexById)
                if explicitSlot and not slotData[explicitSlot] then
                    slot = explicitSlot
                end
            end
            if (not slot) and wowKey and wowKey ~= "" and layoutKeyToSlots[wowKey] then
                for _, candidate in ipairs(layoutKeyToSlots[wowKey]) do
                    if not slotData[candidate] then
                        slot = candidate
                        break
                    end
                end
            end
            local macroPayload = extractMacroPayload(spell, macroLookup)
            if not macroPayload then
                local actionType = tostring(spell.actionType or spell.action_type or ""):lower()
                local spellIdRaw = tostring(spell.spellId or spell.spell_id or "")
                local isMacroSpell = spell.isMacro == true or actionType == "macro" or spellIdRaw:find("^macro:") ~= nil
                if isMacroSpell then
                    local fallbackMacroId = tostring(spell.macroId or spell.macro_id or spellIdRaw:match("^macro:(.+)$") or "")
                    macroPayload = {
                        macroId = fallbackMacroId,
                        name = tostring(spell.name or spell.macroName or spell.macro_name or "WoWKeybMacro"),
                        body = tostring(spell.macroText or spell.macro_text or spell.text or spell.body or ""),
                        source = "spell-fallback",
                    }
                end
            end
            local spellIcon = (macroPayload and resolveViewerMacroIcon(spell, macroPayload)) or resolveViewerSpellIcon(spell)
            if macroPayload then
                local macroDisplayName, macroDisplayIcon = resolveViewerMacroDisplay(spell, macroPayload)
                if macroDisplayName and macroDisplayName ~= "" then
                    spellName = macroDisplayName
                end
                if (not spellIcon or tostring(spellIcon) == "") and macroDisplayIcon and tostring(macroDisplayIcon) ~= "" then
                    spellIcon = macroDisplayIcon
                end
            end
            if macroPayload then
                macroPayload.icon = spellIcon or macroPayload.icon
                local macroEntry = ensureMacroEntry(macroPayload)
                if macroEntry then
                    if (not macroEntry.icon or macroEntry.icon == "") and spellIcon and tostring(spellIcon) ~= "" then
                        macroEntry.icon = tostring(spellIcon)
                    end
                    macroEntry.usages[#macroEntry.usages + 1] = formatMacroUsage(slot, kb.key or "")
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

    if type(profile) == "table" and type(profile.macros) == "table" then
        for _, macro in ipairs(profile.macros) do
            if type(macro) == "table" then
                local macroBody = macro.macroText or macro.macro_text or macro.text or macro.body
                local seededPayload = {
                    macroId = tostring(macro.id or macro.macroId or macro.macro_id or ""),
                    name = sanitizeMacroName(macro.name or macro.macroName or macro.macro_name or "WoWKeybMacro"),
                    body = tostring(macroBody or ""),
                    icon = tostring(macro.icon or ""),
                    sourceSpellId = tostring(macro.sourceSpellId or macro.source_spell_id or ""),
                    sourceSpellName = tostring(macro.sourceSpellName or macro.source_spell_name or ""),
                    source = "profile-list",
                }
                ensureMacroEntry(seededPayload)
            end
        end
    end

    for barIdx = 1, VIEWER_BAR_COUNT do
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
    for slot = 1, VIEWER_SLOT_COUNT do
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

    table.sort(macroEntries, function(a, b)
        local an = tostring(a and a.name or ""):lower()
        local bn = tostring(b and b.name or ""):lower()
        return an < bn
    end)

    for _, macroEntry in ipairs(macroEntries) do
        if type(macroEntry) == "table" then
            local iconStr = tostring(macroEntry.icon or "")
            local hasUsableIcon = iconStr ~= "" and iconStr ~= "0" and not iconStr:lower():find("^https?://")
            if not hasUsableIcon then
            local macroIndex = nil
            local macroId = tonumber(macroEntry.macroId or "")
            if macroId and macroId > 0 and type(GetMacroInfo) == "function" then
                local _, macroIcon = GetMacroInfo(macroId)
                if macroIcon and tostring(macroIcon) ~= "" then
                    macroEntry.icon = tostring(macroIcon)
                    macroIndex = macroId
                end
            end
            if (not macroIndex) and type(GetMacroIndexByName) == "function" then
                local byName = GetMacroIndexByName(tostring(macroEntry.name or ""))
                if byName and tonumber(byName) and tonumber(byName) > 0 then
                    macroIndex = tonumber(byName)
                    if type(GetMacroInfo) == "function" then
                        local _, macroIcon = GetMacroInfo(macroIndex)
                        if macroIcon and tostring(macroIcon) ~= "" then
                            macroEntry.icon = tostring(macroIcon)
                        end
                    end
                end
            end
            local iconAfterMacroLookup = tostring(macroEntry.icon or "")
            if iconAfterMacroLookup == "" or iconAfterMacroLookup == "0" or iconAfterMacroLookup:lower():find("^https?://") then
                local fallbackIcon = resolveMacroIconForPayload({
                    body = tostring(macroEntry.body or ""),
                    icon = macroEntry.icon,
                    sourceSpellId = tostring(macroEntry.sourceSpellId or ""),
                    sourceSpellName = tostring(macroEntry.sourceSpellName or ""),
                }, macroIndex)
                if fallbackIcon and tostring(fallbackIcon) ~= "" then
                    macroEntry.icon = tostring(fallbackIcon)
                end
            end
            local iconAfterFallback = tostring(macroEntry.icon or "")
            if iconAfterFallback == "" or iconAfterFallback == "0" or iconAfterFallback:lower():find("^https?://") then
                local sourceSpellId = tonumber(macroEntry.sourceSpellId or "")
                local sourceSpellName = tostring(macroEntry.sourceSpellName or "")
                if sourceSpellId and sourceSpellId > 0 then
                    if C_Spell and type(C_Spell.GetSpellTexture) == "function" then
                        local okTex, tex = pcall(C_Spell.GetSpellTexture, sourceSpellId)
                        if okTex and tex and tostring(tex) ~= "" then
                            macroEntry.icon = tostring(tex)
                        end
                    end
                    if tostring(macroEntry.icon or "") == "" and _G.GetSpellInfo then
                        local _, _, tex = _G.GetSpellInfo(sourceSpellId)
                        if tex and tostring(tex) ~= "" then
                            macroEntry.icon = tostring(tex)
                        end
                    end
                end
                if tostring(macroEntry.icon or "") == "" and sourceSpellName ~= "" and _G.GetSpellInfo then
                    local _, _, tex = _G.GetSpellInfo(sourceSpellName)
                    if tex and tostring(tex) ~= "" then
                        macroEntry.icon = tostring(tex)
                    end
                end
            end
            end
        end
    end

    return keyToEntries, slotData, macroEntries
end

local function setBarViewerCell(cell, key, spellName, icon)
    if not cell then return end
    local cleanKey = (key and key ~= "") and key or "-"
    local compactKey = cleanKey
    compactKey = compactKey:gsub("Ctrl%+", "C+")
    compactKey = compactKey:gsub("Shift%+", "S+")
    compactKey = compactKey:gsub("Alt%+", "A+")
    if compactKey == "-" then
        compactKey = ""
    end

    if cell.keyText then
        cell.keyText:SetText(compactKey)
    end
    if cell.keyBadge then
        if compactKey ~= "" then
            cell.keyBadge:Show()
        else
            cell.keyBadge:Hide()
        end
    end
    cell.spellText:SetText("")
    cell.viewerKey = cleanKey
    cell.viewerSpellName = (spellName and spellName ~= "") and spellName or "-"

    local iconRef = nil
    if icon and tostring(icon) ~= "" and tostring(icon) ~= "0" and not tostring(icon):lower():find("^https?://") then
        local iconText = tostring(icon):gsub("^%s+", ""):gsub("%s+$", "")
        local numeric = tonumber(iconText)
        if numeric and numeric > 0 then
            iconRef = numeric
        elseif iconText:find("\\", 1, true) then
            iconRef = iconText
        elseif iconText ~= "" then
            iconRef = "Interface\\Icons\\" .. iconText
        end
    end
    if (not iconRef) and cell.viewerSpellName and cell.viewerSpellName ~= "-" and cell.viewerSpellName ~= "" then
        iconRef = "Interface\\Icons\\INV_Misc_QuestionMark"
    end
    cell.viewerIcon = iconRef
    if iconRef then
        cell.icon:SetTexture(iconRef)
        cell.icon:Show()
    else
        cell.icon:SetTexture(nil)
        cell.icon:Hide()
    end
end

local function readLiveViewerBarSlot(slot)
    if not slot or slot < 1 or slot > VIEWER_SLOT_COUNT then
        return nil
    end
    local actionSlot = toBlizzardActionSlot(slot)
    local actionType, actionId = GetActionInfo(actionSlot)
    if not actionType then
        return nil
    end

    if actionType == "spell" then
        local spell = readSpellFromActionSlot(actionSlot)
        if spell then
            return {
                spellName = tostring(spell.name or "(no spell)"),
                icon = spell.icon,
            }
        end
    elseif actionType == "macro" then
        local macro = readMacroFromActionSlot(actionSlot)
        if macro then
            local macroName, macroIcon = resolveMacroDisplayFromActionSlot(
                actionSlot,
                actionId,
                macro.name,
                macro.icon,
                macro.macroText
            )
            return {
                spellName = macroName,
                icon = macroIcon,
            }
        end
        if actionId and type(GetMacroInfo) == "function" then
            local macroName, macroIcon = resolveMacroDisplayFromActionSlot(actionSlot, actionId, nil, nil, nil)
            return {
                spellName = tostring(macroName or "Macro"),
                icon = macroIcon,
            }
        end
    else
        local utilityAction = readUtilityActionFromActionSlot(actionSlot, actionType, actionId)
        if utilityAction then
            return {
                spellName = tostring(utilityAction.name or "(no spell)"),
                icon = utilityAction.icon,
            }
        end
        local texture = GetActionTexture and GetActionTexture(actionSlot) or nil
        local actionText = GetActionText and GetActionText(actionSlot) or nil
        local fallbackName = tostring(actionText or actionType or "(no spell)")
        if texture then
            return {
                spellName = fallbackName,
                icon = texture,
            }
        end
    end

    return nil
end

local function buildLiveViewerSlotData()
    local slotData = {}
    for slot = 1, VIEWER_SLOT_COUNT do
        local live = readLiveViewerBarSlot(slot)
        local keyValue = ""
        local command = SLOT_COMMANDS[slot]
        if command then
            keyValue = tostring(wowBindingToProfileKey(firstBindingForCommand(command)) or "")
        end
        slotData[slot] = {
            key = keyValue,
            spellName = live and tostring(live.spellName or "-") or "-",
            icon = live and live.icon or nil,
        }
    end
    return slotData
end

local function overlayLiveViewerBarData(profile, slotData)
    if type(slotData) ~= "table" then
        return
    end
    local bars = profile and profile.layout and profile.layout.bars or {}

    for slot = 1, VIEWER_SLOT_COUNT do
        local live = readLiveViewerBarSlot(slot)
        local existing = slotData[slot] or { key = "", spellName = "-", icon = nil }
        local keyValue = tostring(existing.key or "")
        if keyValue == "" then
            local barIdx = math.floor((slot - 1) / 12) + 1
            local slotIdx = ((slot - 1) % 12) + 1
            local bar = bars[barIdx]
            local layoutKey = (bar and bar.slotKeys and bar.slotKeys[slotIdx]) or ""
            if layoutKey ~= "" then
                keyValue = tostring(layoutKey)
            else
                local command = SLOT_COMMANDS[slot]
                if command then
                    keyValue = wowBindingToProfileKey(firstBindingForCommand(command))
                end
            end
        end

        if live then
            slotData[slot] = {
                key = keyValue,
                spellName = tostring(live.spellName or "-"),
                icon = live.icon,
            }
        else
            slotData[slot] = {
                key = keyValue,
                spellName = "-",
                icon = nil,
            }
        end
    end
end

local function showMacroCellTooltip(cell)
    local macro = cell and cell.viewerMacro
    if type(macro) ~= "table" then
        return
    end
    GameTooltip:SetOwner(cell, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()

    local name = tostring(macro.name or "WoWKeybMacro")
    local icon = tostring(macro.icon or "")
    local macroId = tostring(macro.macroId or "")
    local body = tostring(macro.body or "")
    local usages = type(macro.usages) == "table" and macro.usages or {}

    if icon ~= "" then
        GameTooltip:AddLine(string.format("|T%s:14|t %s", icon, name), 1, 1, 1)
    else
        GameTooltip:AddLine(name, 1, 1, 1)
    end
    if macroId ~= "" then
        GameTooltip:AddLine("Macro ID: " .. macroId, 0.8, 0.8, 0.8)
    end
    if #usages > 0 then
        GameTooltip:AddLine("Usage:", 0.9, 0.9, 0.9)
        for i = 1, math.min(#usages, 3) do
            GameTooltip:AddLine(" - " .. tostring(usages[i]), 0.8, 0.8, 0.8)
        end
        if #usages > 3 then
            GameTooltip:AddLine(string.format(" - ... +%d more", #usages - 3), 0.7, 0.7, 0.7)
        end
    else
        GameTooltip:AddLine("Usage: Unassigned", 0.8, 0.8, 0.8)
    end
    if body ~= "" then
        local compactBody = body:gsub("\r", "")
        if #compactBody > 240 then
            compactBody = compactBody:sub(1, 240) .. "..."
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Macro Body:", 0.9, 0.9, 0.9)
        GameTooltip:AddLine(compactBody, 0.85, 0.85, 0.85, true)
    else
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Macro Body: not captured", 0.75, 0.75, 0.75)
    end
    GameTooltip:Show()
end

local function setMacroViewerCell(cell, macro)
    if not cell then return end
    if type(macro) ~= "table" then
        cell.viewerMacro = nil
        cell.icon:SetTexture(nil)
        cell.icon:Hide()
        cell.usageText:SetText("")
        cell:Hide()
        return
    end

    cell.viewerMacro = macro
    local icon = tostring(macro.icon or "")
    icon = icon:gsub("^%s+", ""):gsub("%s+$", "")
    if icon == "" or icon == "0" or icon:lower():find("^https?://") then
        icon = "INV_MISC_QUESTIONMARK"
    end
    local textureRef = tonumber(icon)
    if not textureRef or textureRef <= 0 then
        if icon:find("\\", 1, true) then
            textureRef = icon
        else
            textureRef = "Interface\\Icons\\" .. icon
        end
    end
    cell.icon:SetTexture(textureRef)
    cell.icon:Show()
    local usageCount = type(macro.usages) == "table" and #macro.usages or 0
    if usageCount > 0 then
        cell.usageText:SetText(tostring(usageCount))
    else
        cell.usageText:SetText("")
    end
    cell:Show()
end

local function slotToBarSlotLabel(slot)
    if not slot then return "Unmapped" end
    local bar = math.floor((slot - 1) / 12) + 1
    local idx = ((slot - 1) % 12) + 1
    return string.format("Bar %d Slot %d", bar, idx)
end

local function macroEntrySignature(entry)
    if type(entry) ~= "table" then
        return ""
    end
    local macroId = tostring(entry.macroId or "")
    if macroId ~= "" then
        return "id:" .. macroId
    end
    local normalizedBody = normalizeMacroBodyForMatch(entry.body)
    if normalizedBody ~= "" then
        return "body:" .. normalizedBody
    end
    local name = tostring(entry.name or ""):lower()
    if name ~= "" then
        return "name:" .. name
    end
    return ""
end

local function buildLiveMacroEntriesFromBars(slotData)
    local entries = {}
    local bySignature = {}

    for slot = 1, VIEWER_SLOT_COUNT do
        local actionSlot = toBlizzardActionSlot(slot)
        local actionType, actionId = GetActionInfo(actionSlot)
        if actionType == "macro" and actionId and type(GetMacroInfo) == "function" then
            local rawName, rawIcon, rawBody = GetMacroInfo(actionId)
            local macroName, macroIcon, macroBody = resolveMacroDisplayFromActionSlot(
                actionSlot,
                actionId,
                rawName,
                rawIcon,
                rawBody
            )
            local keyLabel = tostring(slotData and slotData[slot] and slotData[slot].key or "")
            if keyLabel == "" then keyLabel = "-" end
            local usageLabel = string.format("%s (%s)", slotToBarSlotLabel(slot), keyLabel)

            local entry = {
                name = tostring(macroName or "WoWKeybMacro"),
                macroId = tostring(actionId or ""),
                source = "live-bar",
                icon = tostring(macroIcon or ""),
                body = tostring(macroBody or ""),
                usages = {},
            }
            local signature = macroEntrySignature(entry)
            if signature == "" then
                signature = "slot:" .. tostring(slot)
            end

            local existing = bySignature[signature]
            if not existing then
                existing = entry
                entries[#entries + 1] = existing
                bySignature[signature] = existing
            end
            existing.usages[#existing.usages + 1] = usageLabel

            if (not existing.icon or existing.icon == "") and macroIcon and tostring(macroIcon) ~= "" then
                existing.icon = tostring(macroIcon)
            end
            if (not existing.body or existing.body == "") and macroBody and tostring(macroBody) ~= "" then
                existing.body = tostring(macroBody)
            end
        end
    end

    table.sort(entries, function(a, b)
        return tostring(a.name or ""):lower() < tostring(b.name or ""):lower()
    end)
    return entries, bySignature
end

local function filterMacroEntriesForDisplay(entries)
    if type(entries) ~= "table" then
        return {}
    end
    local function trim(value)
        return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
    end
    local function hasUsableIcon(value)
        local icon = trim(value)
        return icon ~= "" and icon ~= "0" and not icon:lower():find("^https?://")
    end
    local function entryQuality(entry)
        if type(entry) ~= "table" then
            return 0
        end
        local score = 0
        local name = trim(entry.name)
        if name ~= "" and not isGenericMacroName(name) then
            score = score + 100
        end
        if trim(entry.body) ~= "" then
            score = score + 60
        end
        if hasUsableIcon(entry.icon) then
            score = score + 20
        end
        if trim(entry.sourceSpellId) ~= "" or trim(entry.sourceSpellName) ~= "" then
            score = score + 10
        end
        return score
    end
    local function addMissingFields(target, source)
        if type(target) ~= "table" or type(source) ~= "table" then return end
        if (trim(target.name) == "" or isGenericMacroName(target.name)) and trim(source.name) ~= "" and not isGenericMacroName(source.name) then
            target.name = tostring(source.name)
        end
        if trim(target.body) == "" and trim(source.body) ~= "" then
            target.body = tostring(source.body)
        end
        if not hasUsableIcon(target.icon) and hasUsableIcon(source.icon) then
            target.icon = tostring(source.icon)
        end
        if trim(target.sourceSpellId) == "" and trim(source.sourceSpellId) ~= "" then
            target.sourceSpellId = tostring(source.sourceSpellId)
        end
        if trim(target.sourceSpellName) == "" and trim(source.sourceSpellName) ~= "" then
            target.sourceSpellName = tostring(source.sourceSpellName)
        end
        local targetUsages = type(target.usages) == "table" and target.usages or {}
        local sourceUsages = type(source.usages) == "table" and source.usages or {}
        local seen = {}
        for _, usage in ipairs(targetUsages) do
            seen[tostring(usage)] = true
        end
        for _, usage in ipairs(sourceUsages) do
            local key = tostring(usage)
            if not seen[key] then
                targetUsages[#targetUsages + 1] = key
                seen[key] = true
            end
        end
        target.usages = targetUsages
    end

    -- First, collapse entries that point to the same usage slot(s), preferring richer metadata.
    local byUsageSignature = {}
    local usageCollapsed = {}
    for _, entry in ipairs(entries) do
        if type(entry) == "table" then
            local usages = type(entry.usages) == "table" and entry.usages or {}
            if #usages > 0 then
                local sorted = {}
                for _, usage in ipairs(usages) do
                    sorted[#sorted + 1] = tostring(usage)
                end
                table.sort(sorted)
                local usageSignature = table.concat(sorted, " | ")
                local existing = byUsageSignature[usageSignature]
                if not existing then
                    byUsageSignature[usageSignature] = entry
                    usageCollapsed[#usageCollapsed + 1] = entry
                else
                    if entryQuality(entry) > entryQuality(existing) then
                        addMissingFields(entry, existing)
                        byUsageSignature[usageSignature] = entry
                        for idx, value in ipairs(usageCollapsed) do
                            if value == existing then
                                usageCollapsed[idx] = entry
                                break
                            end
                        end
                    else
                        addMissingFields(existing, entry)
                    end
                end
            else
                usageCollapsed[#usageCollapsed + 1] = entry
            end
        end
    end

    local used = {}
    local unusedBySignature = {}
    local unused = {}
    for _, entry in ipairs(usageCollapsed) do
        local usageCount = (type(entry) == "table" and type(entry.usages) == "table") and #entry.usages or 0
        if usageCount > 0 then
            used[#used + 1] = entry
        else
            local signature = macroEntrySignature(entry)
            if signature == "" then
                signature = "name:" .. normalizeMacroNameForMatch(entry and entry.name or "")
            end
            local existing = unusedBySignature[signature]
            if not existing then
                unusedBySignature[signature] = entry
                unused[#unused + 1] = entry
            else
                if entryQuality(entry) > entryQuality(existing) then
                    addMissingFields(entry, existing)
                    unusedBySignature[signature] = entry
                    for idx, value in ipairs(unused) do
                        if value == existing then
                            unused[idx] = entry
                            break
                        end
                    end
                else
                    addMissingFields(existing, entry)
                end
            end
        end
    end

    if #used > 0 then
        return used
    end
    return unused
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
    GameTooltip:AddLine("Drag onto a key to move this ability.", 0.8, 0.8, 0.8)
    GameTooltip:Show()
end

local function bindingMatchesLayer(rawKey, layer)
    local normalized = normalizeKey(rawKey) or ""
    local hasShift = normalized:find("SHIFT-", 1, true) ~= nil
    local hasCtrl = normalized:find("CTRL-", 1, true) ~= nil
    local hasAlt = normalized:find("ALT-", 1, true) ~= nil
    layer = tostring(layer or "")
    if layer == "SHIFT" then
        return hasShift and not hasCtrl and not hasAlt
    elseif layer == "CTRL" then
        return hasCtrl and not hasShift and not hasAlt
    elseif layer == "ALT" then
        return hasAlt and not hasShift and not hasCtrl
    end
    return not hasShift and not hasCtrl and not hasAlt
end

local function showKeyboardCellTooltip(cell)
    local key = cell and cell.viewerKey
    if not key then return end
    local entries = (cell and cell.viewerEntries) or {}
    local extras = (cell and cell.viewerExtra) or {}

    GameTooltip:SetOwner(cell, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("Key: " .. tostring(key), 1, 1, 1)
    if #entries == 0 then
        GameTooltip:AddLine("Nothing bound on this layer", 0.8, 0.8, 0.8)
    else
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
    GameTooltip:AddLine("Drag to move. Right-click to clear this key after confirming.", 0.8, 0.8, 0.8)
    if #extras > 0 then
        GameTooltip:AddLine("Other modifier layers", 0.95, 0.78, 0.35)
        for _, entry in ipairs(extras) do
            local name = entry.spellName or "(no spell)"
            local keyLabel = tostring(entry.key or "-")
            GameTooltip:AddLine(keyLabel .. " - " .. name, 0.8, 0.8, 0.8)
        end
    end
    GameTooltip:Show()
end

local function resolveViewerIconRef(icon)
    if not icon or tostring(icon) == "" or tostring(icon) == "0" then
        return nil
    end
    if tostring(icon):lower():find("^https?://") then
        return nil
    end
    local iconText = tostring(icon):gsub("^%s+", ""):gsub("%s+$", "")
    local numeric = tonumber(iconText)
    if numeric and numeric > 0 then
        return numeric
    end
    if iconText:find("\\", 1, true) then
        return iconText
    end
    if iconText ~= "" then
        return "Interface\\Icons\\" .. iconText
    end
    return nil
end

local function setKeyboardViewerCell(cell, key, entries, extras)
    if not cell then return end
    local cleanKey = (key and key ~= "") and key or "-"
    local list = entries or {}
    local first = list[1]
    for _, candidate in ipairs(list) do
        local candidateIcon = candidate and candidate.icon and tostring(candidate.icon) or ""
        candidateIcon = candidateIcon:gsub("^%s+", ""):gsub("%s+$", "")
        if candidateIcon ~= "" and candidateIcon ~= "0" and not candidateIcon:lower():find("^https?://") then
            first = candidate
            break
        end
    end
    local extraList = extras or {}
    cell.viewerKey = cleanKey
    cell.viewerEntries = list
    cell.viewerExtra = extraList
    cell.keyText:SetText(cleanKey)

    local iconRef = resolveViewerIconRef(first and first.icon)
    if (not iconRef) and #list > 0 then
        iconRef = "Interface\\Icons\\INV_Misc_QuestionMark"
    end
    if iconRef then
        cell.icon:SetTexture(iconRef)
        cell.icon:Show()
        if cell.keyPlate then
            cell.keyPlate:Show()
        end
        cell.keyText:ClearAllPoints()
        cell.keyText:SetPoint("BOTTOM", 0, 1)
        cell.keyText:SetJustifyH("CENTER")
    else
        cell.icon:SetTexture(nil)
        cell.icon:Hide()
        if cell.keyPlate then
            cell.keyPlate:Hide()
        end
        cell.keyText:ClearAllPoints()
        cell.keyText:SetPoint("CENTER")
        cell.keyText:SetJustifyH("CENTER")
    end

    if cell.layerMark then
        if #extraList > 0 then
            cell.layerMark:Show()
        else
            cell.layerMark:Hide()
        end
    end

    if #list > 1 then
        cell.countText:SetText("x" .. tostring(#list))
        cell.countText:Show()
    else
        cell.countText:SetText("")
        cell.countText:Hide()
    end
end

-- Viewer UI: one palette + helpers so nested panels/cells match; hover uses the same ramps.
local WK_VIEWER_THEME = {
    panelBg = { 0.07, 0.07, 0.09, 0.92 },
    panelBorder = { 0.24, 0.24, 0.30, 0.95 },
    cellBg = { 0.14, 0.14, 0.17, 0.98 },
    cellBorder = { 0.40, 0.40, 0.46, 0.95 },
    cellBgHi = { 0.22, 0.22, 0.26, 0.99 },
    cellBorderHi = { 0.58, 0.60, 0.72, 1 },
}

-- Keybinding viewer: margins + vertical rhythm (content inset vs footer buttons).
local WK_VIEWER_LAYOUT = {
    padX = 20,
    padTop = 20,
    padBottom = 48,
    contentWidth = 980,
    gapAfterTitle = 6,
    gapAfterSubtitle = 8,
    gapSection = 16,
    gapTitleToPanel = 8,
    panelInnerPad = 10,
    macroScrollInset = 10,
    macroScrollRightInset = 28,
    btnBottomPad = 14,
    btnBetween = 16,
}

local function wkApplyViewerPanelBackdrop(f)
    if not f or not f.SetBackdrop then return end
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    f:SetBackdropColor(unpack(WK_VIEWER_THEME.panelBg))
    f:SetBackdropBorderColor(unpack(WK_VIEWER_THEME.panelBorder))
end

local function wkApplyViewerCellBackdrop(f)
    if not f or not f.SetBackdrop then return end
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 8,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    f:SetBackdropColor(unpack(WK_VIEWER_THEME.cellBg))
    f:SetBackdropBorderColor(unpack(WK_VIEWER_THEME.cellBorder))
end

local function wkCreatePageSwitcher(parent, activePage)
    local host = CreateFrame("Frame", nil, parent)
    host:SetSize(188, 22)
    local pages = {
        { id = "map", label = "Map" },
        { id = "settings", label = "Profiles" },
    }
    for index, def in ipairs(pages) do
        local chip = CreateFrame("Button", nil, host, "BackdropTemplate")
        chip:SetSize(90, 22)
        chip:SetPoint("LEFT", host, "LEFT", (index - 1) * 96, 0)
        if chip.SetBackdrop then
            chip:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Buttons\\WHITE8X8",
                tile = false, edgeSize = 1,
                insets = { left = 1, right = 1, top = 1, bottom = 1 },
            })
            if def.id == activePage then
                chip:SetBackdropColor(0.30, 0.36, 0.48, 1)
                chip:SetBackdropBorderColor(0.78, 0.84, 1, 1)
            else
                chip:SetBackdropColor(0.12, 0.12, 0.15, 1)
                chip:SetBackdropBorderColor(0.34, 0.34, 0.40, 1)
            end
        end
        local label = chip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("CENTER")
        label:SetText(def.label)
        chip:SetScript("OnClick", function()
            if def.id ~= activePage and WoWKeyb.Open then
                WoWKeyb:Open(def.id)
            end
        end)
    end
    return host
end

local function wkSetViewerCellHover(f, hover)
    if not f or not f.SetBackdropColor then return end
    if hover then
        f:SetBackdropColor(unpack(WK_VIEWER_THEME.cellBgHi))
        if f.SetBackdropBorderColor then
            f:SetBackdropBorderColor(unpack(WK_VIEWER_THEME.cellBorderHi))
        end
    else
        f:SetBackdropColor(unpack(WK_VIEWER_THEME.cellBg))
        if f.SetBackdropBorderColor then
            f:SetBackdropBorderColor(unpack(WK_VIEWER_THEME.cellBorder))
        end
    end
end

local function isViewerActionBarEnabled(barIndex)
    if barIndex < 1 or barIndex > VIEWER_BAR_COUNT then
        return false
    end
    if Settings and type(Settings.GetValue) == "function" then
        local ok, value = pcall(Settings.GetValue, "PROXY_SHOW_ACTIONBAR_" .. barIndex)
        if ok and value ~= nil then
            if value == true or value == 1 or value == "1" then
                return true
            end
            if value == false or value == 0 or value == "0" then
                return false
            end
        end
    end
    if barIndex > 1 then
        local cvar = GetCVar("SHOW_MULTI_ACTIONBAR_" .. (barIndex - 1))
        if cvar ~= nil then
            return cvar == "1"
        end
    end
    local frameNames = {
        [1] = "MainActionBar",
        [2] = "MultiBarBottomLeft",
        [3] = "MultiBarBottomRight",
        [4] = "MultiBarRight",
        [5] = "MultiBarLeft",
        [6] = "MultiBar5",
        [7] = "MultiBar6",
        [8] = "MultiBar7",
    }
    local frame = _G[frameNames[barIndex]]
    if barIndex == 1 and not frame then
        frame = _G.MainMenuBar
    end
    if frame and frame.IsShown then
        return frame:IsShown()
    end
    return barIndex == 1
end
isActionBarShown = isViewerActionBarEnabled

local function layoutViewerActionBars(frame)
    if not frame or not frame.barCells or not frame.barsContainer then
        return
    end
    local visible = {}
    for barIdx = 1, VIEWER_BAR_COUNT do
        if isViewerActionBarEnabled(barIdx) then
            visible[#visible + 1] = barIdx
        end
    end
    local rowHeight = 60
    local barsPad = WK_VIEWER_LAYOUT.panelInnerPad
    local slotSize, slotGap = 38, 5
    local shown = {}
    for displayIndex, barIdx in ipairs(visible) do
        shown[barIdx] = true
        local label = frame.barLabels and frame.barLabels[barIdx]
        if label then
            label:ClearAllPoints()
            label:SetPoint("TOPLEFT", frame.barsContainer, "TOPLEFT", barsPad, -12 - (displayIndex - 1) * rowHeight)
            label:Show()
        end
        local cells = frame.barCells[barIdx]
        if cells then
            for slotIdx = 1, 12 do
                local cell = cells[slotIdx]
                if cell then
                    cell:ClearAllPoints()
                    cell:SetPoint("TOPLEFT", 80 + (slotIdx - 1) * (slotSize + slotGap), -(barsPad - 2) - (displayIndex - 1) * rowHeight)
                    cell:Show()
                end
            end
        end
    end
    for barIdx = 1, VIEWER_BAR_COUNT do
        if not shown[barIdx] then
            if frame.barLabels and frame.barLabels[barIdx] then
                frame.barLabels[barIdx]:Hide()
            end
            local cells = frame.barCells[barIdx]
            if cells then
                for slotIdx = 1, 12 do
                    if cells[slotIdx] then
                        cells[slotIdx]:Hide()
                    end
                end
            end
        end
    end
    local barHeight = math.max(rowHeight, 16 + (#visible * rowHeight))
    frame.barsContainer:SetHeight(barHeight)
    frame:SetHeight(678 + barHeight)
end

local function refreshLayerChips(frame)
    if not frame or not frame.layerButtons then return end
    local active = tostring(frame.modifierLayer or "")
    for _, chip in ipairs(frame.layerButtons) do
        local selected = chip.layerId == active
        if selected then
            chip:SetBackdropColor(0.30, 0.36, 0.48, 1)
            chip:SetBackdropBorderColor(0.78, 0.84, 1, 1)
            if chip.label then
                chip.label:SetTextColor(1, 1, 1)
            end
        else
            chip:SetBackdropColor(0.12, 0.12, 0.15, 1)
            chip:SetBackdropBorderColor(0.34, 0.34, 0.40, 1)
            if chip.label then
                chip.label:SetTextColor(0.78, 0.78, 0.84)
            end
        end
    end
end

local function refreshViewerFrame(frame)
    if not frame then return end
    local liveOnly = frame.liveOnly == true
    local profile = nil
    if liveOnly then
        local labels = buildPlayerLabelCollection()
        frame.metaText:SetText(string.format(
            "Live binds    %s    %s    %s",
            tostring(labels.class.variants[1] or "Unknown"),
            tostring(labels.spec.names[1] or labels.spec.ids[1] or "-"),
            tostring(labels.hero.names[1] or labels.hero.ids[1] or "-")
        ))
        if frame.subtitle then
            frame.subtitle:SetText("Drag a spell between the bars and the keys. Right-click a key to confirm clearing it.")
        end
    else
        if not frame.profileName then return end
        profile = getStoredProfile(frame.profileName)
        if not profile then return end
        frame.metaText:SetText(string.format(
            "Profile: %s    Class: %s    Spec: %s    Hero Talent: %s",
            tostring(profile.name or frame.profileName or "Unknown"),
            formatClassLabel(profile.class),
            tostring(profile.spec or "-"),
            formatHeroTalentLabel(
                profile.heroTalent or profile.hero_talent or profile.hero_talent_id or profile.heroTalentId,
                profile.heroTalentId or profile.hero_talent_id
            )
        ))
        if frame.subtitle then
            frame.subtitle:SetText("Drag a spell between the bars and the keys. Right-click a key to confirm clearing it.")
        end
    end

    local keyToEntries, slotData, macroEntries
    local showLiveOverlay
    if liveOnly then
        keyToEntries = {}
        slotData = buildLiveViewerSlotData()
        macroEntries = buildLiveMacroEntriesFromBars(slotData)
        showLiveOverlay = true
    else
        keyToEntries, slotData, macroEntries = buildViewerData(profile)
        showLiveOverlay = canSaveViewerBarsToProfile(frame.profileName)
    end
    if showLiveOverlay and not liveOnly then
        overlayLiveViewerBarData(profile, slotData)
    end
    keyToEntries = {}
    for slot = 1, VIEWER_SLOT_COUNT do
        local entry = slotData[slot]
        local keyCandidates = {}
        local keySeen = {}

        local function addKeyCandidate(rawKey)
            local profileKey = tostring(rawKey or "")
            if profileKey == "" then
                return
            end
            local normalizedCandidate = normalizeKey(profileKey)
            if normalizedCandidate == "" or keySeen[normalizedCandidate] then
                return
            end
            keySeen[normalizedCandidate] = true
            keyCandidates[#keyCandidates + 1] = profileKey
        end

        if entry and entry.key and entry.key ~= "" then
            addKeyCandidate(entry.key)
        end

        -- Include all live bindings for this slot command so secondary binds (e.g. G)
        -- appear in the keyboard map even when a different primary bind exists.
        if showLiveOverlay then
            local command = SLOT_COMMANDS[slot]
            if command and command ~= "" then
                local keys = { GetBindingKey(command) }
                for _, rawWowKey in ipairs(keys) do
                    if rawWowKey and rawWowKey ~= "" then
                        addKeyCandidate(wowBindingToProfileKey(rawWowKey))
                    end
                end
            end
        end

        for _, candidateKey in ipairs(keyCandidates) do
            local normalizedEntryKey = normalizeKey(candidateKey)
            local baseKey = normalizedEntryKey
            local changed = true
            while changed and baseKey and baseKey ~= "" do
                changed = false
                if baseKey:find("^SHIFT%-") then
                    baseKey = baseKey:gsub("^SHIFT%-", "")
                    changed = true
                elseif baseKey:find("^CTRL%-") then
                    baseKey = baseKey:gsub("^CTRL%-", "")
                    changed = true
                elseif baseKey:find("^ALT%-") then
                    baseKey = baseKey:gsub("^ALT%-", "")
                    changed = true
                end
            end
            if baseKey and baseKey ~= "" then
                keyToEntries[baseKey] = keyToEntries[baseKey] or {}
                table.insert(keyToEntries[baseKey], {
                    key = tostring(candidateKey or ""),
                    spellName = tostring((entry and entry.spellName) or "-"),
                    icon = entry and entry.icon or nil,
                    slot = slot,
                })
            end
        end
    end
    local liveMacroEntries, liveBySignature = buildLiveMacroEntriesFromBars(slotData)
    if showLiveOverlay and #liveMacroEntries > 0 then
        for _, macro in ipairs(macroEntries or {}) do
            local signature = macroEntrySignature(macro)
            if signature ~= "" and not liveBySignature[signature] then
                liveMacroEntries[#liveMacroEntries + 1] = macro
            end
        end
        table.sort(liveMacroEntries, function(a, b)
            return tostring(a and a.name or ""):lower() < tostring(b and b.name or ""):lower()
        end)
        macroEntries = liveMacroEntries
    end
    macroEntries = filterMacroEntriesForDisplay(macroEntries)

    if liveOnly then
        if frame.refreshBtn then
            frame.refreshBtn:Hide()
        end
        if frame.applyBtn then
            frame.applyBtn:Hide()
        end
        if frame.closeBtn then
            frame.closeBtn:ClearAllPoints()
            frame.closeBtn:SetPoint("BOTTOM", frame, "BOTTOM", 0, WK_VIEWER_LAYOUT.btnBottomPad)
        end
    else
        if frame.closeBtn and frame.applyBtn then
            frame.closeBtn:ClearAllPoints()
            frame.closeBtn:SetPoint("BOTTOMRIGHT", frame.applyBtn, "BOTTOMLEFT", -WK_VIEWER_LAYOUT.btnBetween, 0)
        end
        if frame.refreshBtn then
            local canSave = canSaveViewerBarsToProfile(frame.profileName)
            if canSave then
                frame.refreshBtn:Enable()
                frame.refreshBtn:SetAlpha(1)
            else
                frame.refreshBtn:Disable()
                frame.refreshBtn:SetAlpha(0.5)
            end
            frame.refreshBtn:Show()
        end

        if frame.applyBtn then
            local diagnostics = getProfileMatchDiagnostics(profile)
            if diagnostics and diagnostics.matches then
                frame.applyBtn:Show()
            else
                frame.applyBtn:Hide()
            end
        end
    end

    local activeLayer = tostring(frame.modifierLayer or "")
    for key, cell in pairs(frame.keyboardCells) do
        local entries = keyToEntries[key] or {}
        local layerEntries = {}
        local extraEntries = {}
        for _, entry in ipairs(entries) do
            if bindingMatchesLayer(entry.key, activeLayer) then
                layerEntries[#layerEntries + 1] = entry
            else
                extraEntries[#extraEntries + 1] = entry
            end
        end
        setKeyboardViewerCell(cell, key, layerEntries, extraEntries)
        local bindingKey = key
        if activeLayer == "SHIFT" then
            bindingKey = "SHIFT-" .. key
        elseif activeLayer == "CTRL" then
            bindingKey = "CTRL-" .. key
        elseif activeLayer == "ALT" then
            bindingKey = "ALT-" .. key
        end
        cell.dragBindingKey = bindingKey
        cell.dragSlot = layerEntries[1] and layerEntries[1].slot or nil
    end
    refreshLayerChips(frame)

    for barIdx = 1, VIEWER_BAR_COUNT do
        if frame.barCells[barIdx] then
            for slotIdx = 1, 12 do
                local globalSlot = ((barIdx - 1) * 12) + slotIdx
                local data = slotData[globalSlot] or { key = "-", spellName = "-", icon = nil }
                local cell = frame.barCells[barIdx][slotIdx]
                setBarViewerCell(cell, data.key, data.spellName, data.icon)
            end
        end
    end
    layoutViewerActionBars(frame)

    if frame.macroCells and frame.macroScrollContent then
        local entries = type(macroEntries) == "table" and macroEntries or {}
        local iconSize, iconGap, perRow = 38, 6, 20
        for i, macro in ipairs(entries) do
            local cell = frame.macroCells[i]
            if not cell then
                cell = CreateFrame("Frame", nil, frame.macroScrollContent, "BackdropTemplate")
                cell:SetSize(iconSize, iconSize)
                wkApplyViewerCellBackdrop(cell)
                cell.icon = cell:CreateTexture(nil, "ARTWORK")
                cell.icon:SetPoint("TOPLEFT", 2, -2)
                cell.icon:SetPoint("BOTTOMRIGHT", -2, 2)
                cell.icon:Hide()
                cell.usageText = cell:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                cell.usageText:SetPoint("BOTTOMRIGHT", -2, 2)
                cell.usageText:SetText("")
                cell:SetScript("OnEnter", function(self)
                    wkSetViewerCellHover(self, true)
                    showMacroCellTooltip(self)
                end)
                cell:SetScript("OnLeave", function(self)
                    wkSetViewerCellHover(self, false)
                    GameTooltip:Hide()
                end)
                frame.macroCells[i] = cell
            end

            local row = math.floor((i - 1) / perRow)
            local col = (i - 1) % perRow
            cell:SetPoint("TOPLEFT", col * (iconSize + iconGap), -row * (iconSize + iconGap))
            setMacroViewerCell(cell, macro)
        end

        for i = #entries + 1, #frame.macroCells do
            setMacroViewerCell(frame.macroCells[i], nil)
        end

        local rows = math.max(1, math.ceil(math.max(#entries, 1) / perRow))
        local contentHeight = rows * (iconSize + iconGap)
        frame.macroScrollContent:SetSize(1, contentHeight)

        if frame.macroEmptyText then
            if #entries == 0 then
                frame.macroEmptyText:Show()
            else
                frame.macroEmptyText:Hide()
            end
        end
    end
end

local COMMAND_TO_SLOT = {}
for slot, command in pairs(SLOT_COMMANDS) do
    COMMAND_TO_SLOT[command] = slot
end

local viewerFrame
local viewerDrag

local function viewerEditBlocked()
    if InCombatLockdown() then
        print("|cffffcc00[WoWKeyb]|r Leave combat before moving abilities.")
        return true
    end
    if viewerFrame and not viewerFrame.liveOnly and not canSaveViewerBarsToProfile(viewerFrame.profileName) then
        print("|cffffcc00[WoWKeyb]|r Apply this profile before moving abilities on its map.")
        return true
    end
    return false
end

local function saveViewerBindings()
    if type(GetCurrentBindingSet) == "function" and type(SaveBindings) == "function" then
        local bindingSet = GetCurrentBindingSet()
        if bindingSet then
            SaveBindings(bindingSet)
        end
    end
end

local function firstFreeBarSlot()
    local function slotIsOpen(slot)
        local actionType = GetActionInfo(toBlizzardActionSlot(slot))
        local command = SLOT_COMMANDS[slot]
        local bound = command and firstBindingForCommand(command)
        return not actionType and (not bound or bound == "")
    end
    local function searchBar(barIdx)
        if not isViewerActionBarEnabled(barIdx) then
            return nil
        end
        for slotIdx = 1, 12 do
            local slot = ((barIdx - 1) * 12) + slotIdx
            if slotIsOpen(slot) then
                return slot
            end
        end
        return nil
    end
    for _, barIdx in ipairs({ 5, 6, 7, 8, 2, 3, 4, 1 }) do
        local slot = searchBar(barIdx)
        if slot then
            return slot
        end
    end
    return nil
end

local function refreshOpenViewer()
    if viewerFrame and not viewerFrame.liveOnly and viewerFrame.profileName then
        if canSaveViewerBarsToProfile(viewerFrame.profileName) then
            syncProfileSnapshotFromGame(viewerFrame.profileName, { force = true })
        end
    end
    if viewerFrame then
        refreshViewerFrame(viewerFrame)
    end
end

local function beginSlotDrag(logicalSlot, bindingKey)
    if viewerEditBlocked() then
        return
    end
    if not logicalSlot then
        return
    end
    local actionSlot = toBlizzardActionSlot(logicalSlot)
    if not GetActionInfo(actionSlot) then
        return
    end
    PickupAction(actionSlot)
    viewerDrag = { slot = logicalSlot, bindingKey = bindingKey }
end

local function dropOnViewerTarget(destSlot, destBindingKey, fromKey)
    if viewerEditBlocked() then
        if GetCursorInfo() then
            ClearCursor()
        end
        viewerDrag = nil
        return
    end
    if not GetCursorInfo() then
        viewerDrag = nil
        return
    end

    local sourceSlot = viewerDrag and viewerDrag.slot
    local sourceKey = viewerDrag and viewerDrag.bindingKey
    local movingKeyOntoSameSpell = fromKey and sourceSlot and not destSlot

    if movingKeyOntoSameSpell then
        destSlot = sourceSlot
    end
    if not destSlot then
        destSlot = firstFreeBarSlot()
    end
    if not destSlot then
        if GetCursorInfo() then
            ClearCursor()
        end
        viewerDrag = nil
        print("|cffffcc00[WoWKeyb]|r No open bar slot for that key.")
        return
    end

    local destAction = toBlizzardActionSlot(destSlot)
    if sourceSlot and sourceSlot == destSlot then
        PlaceAction(destAction)
    else
        PlaceAction(destAction)
        if GetCursorInfo() and sourceSlot and sourceSlot ~= destSlot then
            PlaceAction(toBlizzardActionSlot(sourceSlot))
        end
    end

    if destBindingKey and SLOT_COMMANDS[destSlot] then
        SetBinding(destBindingKey, SLOT_COMMANDS[destSlot])
    end
    if movingKeyOntoSameSpell and sourceKey and destBindingKey and sourceKey ~= destBindingKey then
        SetBinding(sourceKey)
    end
    saveViewerBindings()
    viewerDrag = nil
    refreshOpenViewer()
end

local function clearViewerBinding(bindingKey)
    if viewerEditBlocked() then
        return
    end
    if not bindingKey or bindingKey == "" then
        return
    end
    SetBinding(bindingKey)
    saveViewerBindings()
    refreshOpenViewer()
end

local function promptClearViewerBinding(bindingKey)
    if viewerEditBlocked() then
        return
    end
    if not bindingKey or bindingKey == "" then
        return
    end
    local currentAction = type(GetBindingAction) == "function" and GetBindingAction(bindingKey) or nil
    if not currentAction or currentAction == "" then
        return
    end
    if not StaticPopupDialogs["WOWKEYB_CLEAR_KEY_CONFIRM"] then
        StaticPopupDialogs["WOWKEYB_CLEAR_KEY_CONFIRM"] = {
            text = "Clear the binding for %s?",
            button1 = "Clear",
            button2 = "Cancel",
            OnAccept = function(_, data)
                if type(data) == "string" and data ~= "" then
                    clearViewerBinding(data)
                end
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end
    StaticPopup_Show("WOWKEYB_CLEAR_KEY_CONFIRM", formatHotkeyLabel(bindingKey), nil, bindingKey)
end

function WoWKeyb:ShowKeybindingViewer(profileName)
    local liveOnly = profileName == nil or profileName == "" or profileName == BLIZZARD_DEFAULT_PROFILE
    local target = profileName
    if liveOnly then
        target = nil
    else
        local profile = getStoredProfile(target)
        if not profile then
            print("|cffff0000[WoWKeyb]|r Profile not found: " .. tostring(target))
            return
        end
    end

    if not viewerFrame then
        viewerFrame = CreateFrame("Frame", "WoWKeybViewerFrame", UIParent, "BackdropTemplate")
        viewerFrame:SetSize(1020, 1000)
        viewerFrame:SetPoint("CENTER")
        viewerFrame:SetFrameStrata("DIALOG")
        viewerFrame:SetFrameLevel(120)
        viewerFrame:SetClampedToScreen(true)
        if viewerFrame.SetBackdrop then
            viewerFrame:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Buttons\\WHITE8X8",
                tile = false, edgeSize = 1,
                insets = { left = 1, right = 1, top = 1, bottom = 1 },
            })
            viewerFrame:SetBackdropColor(0.05, 0.05, 0.07, 0.96)
            viewerFrame:SetBackdropBorderColor(0.32, 0.32, 0.38, 1)
        end
        viewerFrame:SetMovable(true)
        viewerFrame:EnableMouse(true)
        viewerFrame:RegisterForDrag("LeftButton")
        viewerFrame:SetScript("OnDragStart", function() viewerFrame:StartMoving() end)
        viewerFrame:SetScript("OnDragStop", function() viewerFrame:StopMovingOrSizing() end)

        local viewerContent = CreateFrame("Frame", nil, viewerFrame)
        viewerContent:SetPoint("TOPLEFT", viewerFrame, "TOPLEFT", WK_VIEWER_LAYOUT.padX, -WK_VIEWER_LAYOUT.padTop)
        viewerContent:SetPoint("BOTTOMRIGHT", viewerFrame, "BOTTOMRIGHT", -WK_VIEWER_LAYOUT.padX, WK_VIEWER_LAYOUT.padBottom)

        local title = viewerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOPLEFT", viewerContent, "TOPLEFT", 0, 0)
        title:SetText("WoWKeyb")

        local versionText = viewerFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        versionText:SetPoint("LEFT", title, "RIGHT", 8, -1)
        versionText:SetText("v" .. getAddonVersion())

        local pageSwitch = wkCreatePageSwitcher(viewerFrame, "map")
        pageSwitch:SetPoint("TOPRIGHT", viewerFrame, "TOPRIGHT", -20, -18)
        pageSwitch:SetFrameLevel(viewerFrame:GetFrameLevel() + 20)

        local subtitle = viewerFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -WK_VIEWER_LAYOUT.gapAfterTitle)
        subtitle:SetText("Icons are what is bound right now. Pick Shift, Ctrl, or Alt to see that layer.")
        viewerFrame.subtitle = subtitle

        local metaText = viewerFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        metaText:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -WK_VIEWER_LAYOUT.gapAfterSubtitle)
        metaText:SetText("")
        viewerFrame.metaText = metaText

        local layerHost = CreateFrame("Frame", nil, viewerFrame)
        layerHost:SetPoint("TOPLEFT", metaText, "BOTTOMLEFT", 0, -10)
        layerHost:SetSize(WK_VIEWER_LAYOUT.contentWidth, 24)
        viewerFrame.layerButtons = {}
        viewerFrame.modifierLayer = ""
        local layerDefs = {
            { id = "", label = "Base" },
            { id = "SHIFT", label = "Shift" },
            { id = "CTRL", label = "Ctrl" },
            { id = "ALT", label = "Alt" },
        }
        for index, def in ipairs(layerDefs) do
            local chip = CreateFrame("Button", nil, layerHost, "BackdropTemplate")
            chip:SetSize(84, 22)
            chip:SetPoint("LEFT", layerHost, "LEFT", (index - 1) * 92, 0)
            chip.layerId = def.id
            if chip.SetBackdrop then
                chip:SetBackdrop({
                    bgFile = "Interface\\Buttons\\WHITE8X8",
                    edgeFile = "Interface\\Buttons\\WHITE8X8",
                    tile = false, edgeSize = 1,
                    insets = { left = 1, right = 1, top = 1, bottom = 1 },
                })
            end
            chip.label = chip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            chip.label:SetPoint("CENTER")
            chip.label:SetText(def.label)
            chip:SetScript("OnClick", function(self)
                viewerFrame.modifierLayer = self.layerId
                refreshViewerFrame(viewerFrame)
            end)
            viewerFrame.layerButtons[index] = chip
        end

        local keyboardContainer = CreateFrame("Frame", nil, viewerFrame, "BackdropTemplate")
        keyboardContainer:SetPoint("TOPLEFT", layerHost, "BOTTOMLEFT", 0, -8)
        keyboardContainer:SetSize(WK_VIEWER_LAYOUT.contentWidth, 276)
        wkApplyViewerPanelBackdrop(keyboardContainer)

        viewerFrame.keyboardCells = {}
        local keyboardRows = {
            { keys = { "1","2","3","4","5","6","7","8","9","0","-","=" }, indent = 8 },
            { keys = { "Q","W","E","R","T","Y","U","I","O","P" }, indent = 36 },
            { keys = { "A","S","D","F","G","H","J","K","L" }, indent = 64 },
            { keys = { "Z","X","C","V","B","N","M" }, indent = 96 },
        }

        local keyW, keyH, gap = 64, 58, 5
        local kbdPad = 12
        local kbdRowGap = 6
        for rowIdx, row in ipairs(keyboardRows) do
            for colIdx, key in ipairs(row.keys) do
                local cell = CreateFrame("Frame", nil, keyboardContainer, "BackdropTemplate")
                cell:SetSize(keyW, keyH)
                cell:SetPoint("TOPLEFT", row.indent + (colIdx - 1) * (keyW + gap), -kbdPad - (rowIdx - 1) * (keyH + kbdRowGap))
                wkApplyViewerCellBackdrop(cell)

                cell.icon = cell:CreateTexture(nil, "ARTWORK")
                cell.icon:SetPoint("TOPLEFT", 2, -2)
                cell.icon:SetPoint("BOTTOMRIGHT", -2, 2)
                cell.icon:Hide()

                cell.keyPlate = cell:CreateTexture(nil, "OVERLAY")
                cell.keyPlate:SetTexture("Interface\\Buttons\\WHITE8X8")
                cell.keyPlate:SetPoint("BOTTOMLEFT", 2, 2)
                cell.keyPlate:SetPoint("BOTTOMRIGHT", -2, 2)
                cell.keyPlate:SetHeight(14)
                cell.keyPlate:SetVertexColor(0, 0, 0, 0.72)
                cell.keyPlate:Hide()

                cell.layerMark = cell:CreateTexture(nil, "OVERLAY")
                cell.layerMark:SetTexture("Interface\\Buttons\\WHITE8X8")
                cell.layerMark:SetPoint("TOPLEFT", 3, -3)
                cell.layerMark:SetSize(16, 3)
                cell.layerMark:SetVertexColor(0.95, 0.78, 0.28, 1)
                cell.layerMark:Hide()

                cell.keyText = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                cell.keyText:SetPoint("CENTER")
                cell.keyText:SetText(key)
                cell.keyText:SetShadowOffset(1, -1)

                cell.countText = cell:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                cell.countText:SetPoint("TOPRIGHT", -3, -3)
                cell.countText:SetText("")
                cell.countText:Hide()

                cell:SetScript("OnEnter", function(self)
                    wkSetViewerCellHover(self, true)
                    showKeyboardCellTooltip(self)
                end)
                cell:SetScript("OnLeave", function(self)
                    wkSetViewerCellHover(self, false)
                    GameTooltip:Hide()
                end)
                cell:EnableMouse(true)
                cell:RegisterForDrag("LeftButton")
                cell:SetScript("OnDragStart", function(self)
                    beginSlotDrag(self.dragSlot, self.dragBindingKey)
                end)
                cell:SetScript("OnReceiveDrag", function(self)
                    dropOnViewerTarget(self.dragSlot, self.dragBindingKey, true)
                end)
                cell:SetScript("OnMouseUp", function(self, button)
                    if button ~= "LeftButton" or not GetCursorInfo() then
                        return
                    end
                    if viewerDrag and viewerDrag.slot == self.dragSlot and viewerDrag.bindingKey == self.dragBindingKey then
                        return
                    end
                    dropOnViewerTarget(self.dragSlot, self.dragBindingKey, true)
                end)
                cell:SetScript("OnMouseDown", function(self, button)
                    if button ~= "RightButton" then
                        return
                    end
                    if GetCursorInfo() then
                        ClearCursor()
                        viewerDrag = nil
                        return
                    end
                    promptClearViewerBinding(self.dragBindingKey)
                end)

                viewerFrame.keyboardCells[key] = cell
            end
        end

        local barsTitle = viewerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        barsTitle:SetPoint("TOPLEFT", keyboardContainer, "BOTTOMLEFT", 0, -WK_VIEWER_LAYOUT.gapSection)
        barsTitle:SetText("Action Bars")

        local barsContainer = CreateFrame("Frame", nil, viewerFrame, "BackdropTemplate")
        barsContainer:SetPoint("TOPLEFT", barsTitle, "BOTTOMLEFT", 0, -WK_VIEWER_LAYOUT.gapTitleToPanel)
        -- Keep a large footer gap so the bottom action bar never overlaps controls.
        barsContainer:SetSize(WK_VIEWER_LAYOUT.contentWidth, 322)
        wkApplyViewerPanelBackdrop(barsContainer)
        viewerFrame.barsContainer = barsContainer

        viewerFrame.barCells = {}
        viewerFrame.barLabels = {}
        local slotSize, slotGap, rowHeight = 38, 5, 60
        local barsPad = WK_VIEWER_LAYOUT.panelInnerPad
        for barIdx = 1, VIEWER_BAR_COUNT do
            local barLabel = barsContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            barLabel:SetPoint("TOPLEFT", barsContainer, "TOPLEFT", barsPad, -12 - (barIdx - 1) * rowHeight)
            barLabel:SetText("Bar " .. tostring(barIdx))
            viewerFrame.barLabels[barIdx] = barLabel

            viewerFrame.barCells[barIdx] = {}
            for slotIdx = 1, 12 do
                local cell = CreateFrame("Frame", nil, barsContainer, "BackdropTemplate")
                cell:SetSize(slotSize, slotSize)
                cell:SetPoint("TOPLEFT", 80 + (slotIdx - 1) * (slotSize + slotGap), -(barsPad - 2) - (barIdx - 1) * rowHeight)
                wkApplyViewerCellBackdrop(cell)

                cell.icon = cell:CreateTexture(nil, "ARTWORK")
                cell.icon:SetPoint("TOPLEFT", 2, -2)
                cell.icon:SetPoint("BOTTOMRIGHT", -2, 2)
                cell.icon:Hide()

                cell.keyText = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                cell.keyText:SetPoint("BOTTOM", 0, 3)
                cell.keyText:SetText("")

                cell.keyBadge = cell:CreateTexture(nil, "OVERLAY")
                cell.keyBadge:SetTexture("Interface\\Buttons\\WHITE8X8")
                cell.keyBadge:SetPoint("BOTTOMLEFT", 2, 2)
                cell.keyBadge:SetPoint("BOTTOMRIGHT", -2, 2)
                cell.keyBadge:SetHeight(11)
                cell.keyBadge:SetVertexColor(0, 0, 0, 0.72)
                cell.keyBadge:Hide()

                cell.spellText = cell:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                cell.spellText:SetPoint("BOTTOMLEFT", 2, 2)
                cell.spellText:SetPoint("BOTTOMRIGHT", -2, 2)
                cell.spellText:SetJustifyH("LEFT")
                cell.spellText:SetText("")
                cell.viewerSlot = ((barIdx - 1) * 12) + slotIdx

                cell:SetScript("OnEnter", function(self)
                    wkSetViewerCellHover(self, true)
                    showBarCellTooltip(self)
                end)
                cell:SetScript("OnLeave", function(self)
                    wkSetViewerCellHover(self, false)
                    GameTooltip:Hide()
                end)
                cell:EnableMouse(true)
                cell:RegisterForDrag("LeftButton")
                cell:SetScript("OnDragStart", function(self)
                    beginSlotDrag(self.viewerSlot, nil)
                end)
                cell:SetScript("OnReceiveDrag", function(self)
                    dropOnViewerTarget(self.viewerSlot, nil, false)
                end)
                cell:SetScript("OnMouseUp", function(self, button)
                    if button ~= "LeftButton" or not GetCursorInfo() then
                        return
                    end
                    if viewerDrag and viewerDrag.slot == self.viewerSlot and viewerDrag.bindingKey == nil then
                        return
                    end
                    dropOnViewerTarget(self.viewerSlot, nil, false)
                end)

                viewerFrame.barCells[barIdx][slotIdx] = cell
            end
        end

        local macrosTitle = viewerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        macrosTitle:SetPoint("TOPLEFT", barsContainer, "BOTTOMLEFT", 0, -WK_VIEWER_LAYOUT.gapSection)
        macrosTitle:SetText("Macros In Profile")

        local macrosContainer = CreateFrame("Frame", nil, viewerFrame, "BackdropTemplate")
        macrosContainer:SetPoint("TOPLEFT", macrosTitle, "BOTTOMLEFT", 0, -WK_VIEWER_LAYOUT.gapTitleToPanel)
        macrosContainer:SetSize(WK_VIEWER_LAYOUT.contentWidth, 96)
        wkApplyViewerPanelBackdrop(macrosContainer)

        local macroScroll = CreateFrame("ScrollFrame", nil, macrosContainer, "UIPanelScrollFrameTemplate")
        macroScroll:SetPoint("TOPLEFT", WK_VIEWER_LAYOUT.macroScrollInset, -WK_VIEWER_LAYOUT.macroScrollInset)
        macroScroll:SetPoint("BOTTOMRIGHT", -WK_VIEWER_LAYOUT.macroScrollRightInset, WK_VIEWER_LAYOUT.macroScrollInset)
        local macroScrollContent = CreateFrame("Frame", nil, macroScroll)
        macroScrollContent:SetSize(1, 1)
        macroScroll:SetScrollChild(macroScrollContent)
        viewerFrame.macroScroll = macroScroll
        viewerFrame.macroScrollContent = macroScrollContent
        viewerFrame.macroCells = {}

        local macroEmptyText = macrosContainer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        macroEmptyText:SetPoint("CENTER")
        macroEmptyText:SetText("No macros found in this profile.")
        viewerFrame.macroEmptyText = macroEmptyText

        local refreshBtn = CreateFrame("Button", nil, viewerFrame, "UIPanelButtonTemplate")
        refreshBtn:SetSize(170, 22)
        refreshBtn:SetText("Save Current Bars")
        refreshBtn:SetScript("OnClick", function()
            local targetProfile = viewerFrame and viewerFrame.profileName
            if not targetProfile then
                print("|cffff0000[WoWKeyb]|r No selected profile to save.")
                return
            end
            local canSave, reason = canSaveViewerBarsToProfile(targetProfile)
            if not canSave then
                if reason == "not-active-profile" then
                    print("|cffffcc00[WoWKeyb]|r Save Current Bars is only available for the currently active profile.")
                elseif reason == "class-mismatch" or reason == "spec-hero-mismatch" then
                    print("|cffffcc00[WoWKeyb]|r Save Current Bars requires the selected profile to match current class/spec/hero.")
                else
                    print("|cffff0000[WoWKeyb]|r Cannot save current bars for this profile.")
                end
                return
            end
            local syncResult = syncProfileSnapshotFromGame(targetProfile, { force = true })
            if syncResult.blocked then
                print("|cffff0000[WoWKeyb]|r Failed to save current bars: " .. tostring(syncResult.blockedReason or "unknown error"))
                return
            end
            refreshViewerFrame(viewerFrame)
            local statusColor = (syncResult.contextOk and syncResult.spellsOk and syncResult.layoutOk) and "|cff00ff00" or "|cffffcc00"
            print(statusColor .. "[WoWKeyb]|r Saved current bars to profile: context "
                .. tostring(syncResult.contextChanged) .. ", spells/macros "
                .. tostring(syncResult.spellsChanged) .. ", bindings "
                .. tostring(syncResult.layoutChanged) .. ".")
        end)
        viewerFrame.refreshBtn = refreshBtn

        local applyBtn = CreateFrame("Button", nil, viewerFrame, "UIPanelButtonTemplate")
        applyBtn:SetSize(120, 22)
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
        viewerFrame.applyBtn = applyBtn

        local closeBtn = CreateFrame("Button", nil, viewerFrame, "UIPanelButtonTemplate")
        closeBtn:SetSize(120, 22)
        closeBtn:SetText("Close")
        closeBtn:SetScript("OnClick", function() viewerFrame:Hide() end)
        viewerFrame.closeBtn = closeBtn

        applyBtn:SetPoint("BOTTOM", viewerFrame, "BOTTOM", 0, WK_VIEWER_LAYOUT.btnBottomPad)
        closeBtn:SetPoint("BOTTOMRIGHT", applyBtn, "BOTTOMLEFT", -WK_VIEWER_LAYOUT.btnBetween, 0)
        refreshBtn:SetPoint("BOTTOMLEFT", applyBtn, "BOTTOMRIGHT", WK_VIEWER_LAYOUT.btnBetween, 0)
    end

    viewerFrame.liveOnly = liveOnly
    viewerFrame.profileName = target
    if viewerFrame.modifierLayer == nil then
        viewerFrame.modifierLayer = ""
    end
    viewerFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    viewerFrame:SetFrameLevel(220)
    viewerFrame:Show()
    refreshViewerFrame(viewerFrame)
    if WoWKeyb.HideSettingsPage then
        WoWKeyb:HideSettingsPage()
    end
end

function WoWKeyb:ToggleLiveViewer()
    if viewerFrame and viewerFrame:IsShown() and viewerFrame.liveOnly then
        viewerFrame:Hide()
        return
    end
    WoWKeyb:ShowKeybindingViewer(nil)
end

local exportFrame
local function computeExportSummaryCounts(profile)
    local keybinds = (type(profile) == "table" and type(profile.keybinds) == "table") and profile.keybinds or {}
    local keybindCount = #keybinds

    local macroSeen = {}
    local macroCount = 0
    local function trimValue(value)
        return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
    end
    local function addMacro(macroId, macroName, macroText)
        local body = trimValue(macroText)
        if body == "" then
            return
        end
        local normalizedId = normalizeMacroId(macroId)
        local signature = ""
        if normalizedId ~= "" then
            signature = "id:" .. normalizedId
        else
            signature = "body:" .. normalizeMacroBodyForMatch(body) .. "|name:" .. normalizeMacroNameForMatch(macroName)
        end
        if signature == "" or macroSeen[signature] then
            return
        end
        macroSeen[signature] = true
        macroCount = macroCount + 1
    end

    for _, kb in ipairs(keybinds) do
        if type(kb) == "table" then
            local spell = kb.spell or {}
            local actionType = tostring(spell.actionType or spell.action_type or ""):lower()
            local spellId = tostring(spell.spellId or spell.spell_id or "")
            local isMacro = spell.isMacro == true or actionType == "macro" or spellId:lower():find("^macro:") ~= nil
            if isMacro then
                local macroId = spell.macroId or spell.macro_id or spellId
                local macroName = spell.name or spell.macroName or spell.macro_name or "WoWKeybMacro"
                local macroText = spell.macroText or spell.macro_text or spell.text or spell.body
                addMacro(macroId, macroName, macroText)
            end
        end
    end

    if type(profile) == "table" and type(profile.macros) == "table" then
        for _, macro in ipairs(profile.macros) do
            if type(macro) == "table" then
                addMacro(
                    macro.id or macro.macroId or macro.macro_id,
                    macro.name or macro.macroName or macro.macro_name or "WoWKeybMacro",
                    macro.macroText or macro.macro_text or macro.text or macro.body
                )
            end
        end
    end

    return keybindCount, macroCount
end

function WoWKeyb:ShowExportDialog(profileName)
    local profile = getStoredProfile(profileName)
    if not profile then
        print("|cffff0000[WoWKeyb]|r Profile not found: " .. tostring(profileName))
        return
    end

    -- Export uses stored profile data when live syncing is disabled.
    local syncResult = {
        contextOk = true,
        contextChanged = 0,
        spellsOk = true,
        spellsChanged = 0,
        layoutOk = true,
        layoutChanged = 0,
    }
    if canRefreshViewerFromGame(profileName) then
        syncResult = syncProfileSnapshotFromGame(profileName)
        if not (syncResult.contextOk and syncResult.spellsOk and syncResult.layoutOk) then
            print("|cffffcc00[WoWKeyb]|r Export snapshot completed with partial sync; data may be incomplete for this profile.")
        end
    else
        print("|cffffcc00[WoWKeyb]|r Exporting stored profile data (live syncing disabled).")
    end

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
        exportFrame:SetClampedToScreen(true)
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
        subtitle:SetText("Press Ctrl+C to copy the share code. This window closes after you copy.")
        exportFrame.subtitle = subtitle

        local summary = exportFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        summary:SetPoint("TOP", subtitle, "BOTTOM", 0, -6)
        summary:SetText("")
        exportFrame.summaryText = summary

        local scroll = CreateFrame("ScrollFrame", "WoWKeybExportScroll", exportFrame, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 20, -84)
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
            self:HighlightText()
        end)
        local copyModifierDown = false
        local function isCopyModifier(key)
            return key == "LCTRL" or key == "RCTRL" or key == "LMETA" or key == "RMETA"
        end
        edit:SetScript("OnKeyDown", function(_, key)
            if isCopyModifier(key) then
                copyModifierDown = true
            end
        end)
        edit:SetScript("OnKeyUp", function(_, key)
            if isCopyModifier(key) then
                if C_Timer and type(C_Timer.After) == "function" then
                    C_Timer.After(0.2, function()
                        copyModifierDown = false
                    end)
                else
                    copyModifierDown = false
                end
                return
            end
            if copyModifierDown and (key == "C" or key == "X") then
                local function closeExport()
                    if exportFrame then
                        exportFrame:Hide()
                    end
                end
                if C_Timer and type(C_Timer.After) == "function" then
                    C_Timer.After(0.1, closeExport)
                else
                    closeExport()
                end
            end
        end)
        scroll:SetScrollChild(edit)
        exportFrame.editBox = edit

        local closeBtn = CreateFrame("Button", nil, exportFrame, "UIPanelButtonTemplate")
        closeBtn:SetSize(120, 22)
        closeBtn:SetPoint("BOTTOM", exportFrame, "BOTTOM", 0, 20)
        closeBtn:SetText("Close")
        closeBtn:SetScript("OnClick", function() exportFrame:Hide() end)
    end

    exportFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    exportFrame:SetFrameLevel(230)
    exportFrame:Show()
    local keybindCount, macroCount = computeExportSummaryCounts(profile)
    if exportFrame.summaryText then
        exportFrame.summaryText:SetText(string.format("Keybinds included: %d    Macros included: %d", keybindCount, macroCount))
    end
    WoWKeybExportEdit:SetText(shareCode)
    WoWKeybExportEdit:SetFocus()
    WoWKeybExportEdit:HighlightText()
end

local profileBrowser
local CLASS_FILE_BY_NAME = {
    deathknight = "DEATHKNIGHT",
    demonhunter = "DEMONHUNTER",
    druid = "DRUID",
    evoker = "EVOKER",
    hunter = "HUNTER",
    mage = "MAGE",
    monk = "MONK",
    paladin = "PALADIN",
    priest = "PRIEST",
    rogue = "ROGUE",
    shaman = "SHAMAN",
    warlock = "WARLOCK",
    warrior = "WARRIOR",
}

local function profileBrowserClassColor(profile)
    local token = normalizeClassName(profile and profile.class)
    local classFile = token and CLASS_FILE_BY_NAME[token] or nil
    local color = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] or nil
    if color then
        return color.r, color.g, color.b
    end
    return 0.86, 0.86, 0.9
end

local function profileBrowserContext(profile)
    local classLabel = formatClassLabel(profile and profile.class)
    local specValue = tostring(profile and (profile.spec or profile.spec_id or profile.specId or profile.specialization) or "")
    local heroValue = formatHeroTalentLabel(
        profile and (profile.heroTalent or profile.hero_talent or profile.hero_talent_id or profile.heroTalentId),
        profile and (profile.heroTalentId or profile.hero_talent_id)
    )
    if specValue == "-" then specValue = "" end
    if heroValue == "-" then heroValue = "" end
    local parts = { classLabel }
    if specValue ~= "" then parts[#parts + 1] = specValue end
    if heroValue ~= "" then parts[#parts + 1] = heroValue end
    return classLabel, table.concat(parts, "   ·   "), (classLabel .. " " .. specValue .. " " .. heroValue)
end

local function profileBrowserMismatchLabel(reasonSummary)
    local reason = tostring(reasonSummary or "")
    if reason:find("class", 1, true) then return "Other class" end
    if reason:find("spec", 1, true) then return "Other spec" end
    if reason:find("hero", 1, true) then return "Other hero" end
    return "Different setup"
end

local function raiseWoWKeybPopup(frame, level)
    if not frame then return end
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetFrameLevel(level or 200)
end

function WoWKeyb:RefreshProfileBrowser()
    if profileBrowser and profileBrowser:IsShown() and profileBrowser.Refresh then
        profileBrowser:Refresh(false)
    end
end

function WoWKeyb:ShowProfileBrowser()
    if not profileBrowser then
        local         frame = CreateFrame("Frame", "WoWKeybProfileBrowser", UIParent, "BackdropTemplate")
        frame:SetSize(700, 640)
        frame:SetPoint("CENTER")
        frame:SetFrameStrata("FULLSCREEN_DIALOG")
        frame:SetFrameLevel(180)
        frame:SetClampedToScreen(true)
        frame:SetMovable(true)
        frame:EnableMouse(true)
        frame:EnableKeyboard(true)
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
        frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
        frame:SetScript("OnKeyDown", function(self, key)
            if key == "ESCAPE" then
                self:SetPropagateKeyboardInput(false)
                self:Hide()
            else
                self:SetPropagateKeyboardInput(true)
            end
        end)
        if frame.SetBackdrop then
            frame:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Buttons\\WHITE8X8",
                tile = false, edgeSize = 1,
                insets = { left = 1, right = 1, top = 1, bottom = 1 },
            })
            frame:SetBackdropColor(0.05, 0.05, 0.07, 0.97)
            frame:SetBackdropBorderColor(0.32, 0.32, 0.38, 1)
        end

        local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOPLEFT", 18, -16)
        title:SetText("WoWKeyb")

        local versionText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        versionText:SetPoint("LEFT", title, "RIGHT", 8, -1)
        versionText:SetText("v" .. getAddonVersion())

        local subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
        subtitle:SetText("Profiles")
        frame.subtitle = subtitle

        local closeX = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
        closeX:SetPoint("TOPRIGHT", -4, -4)
        closeX:SetScript("OnClick", function() frame:Hide() end)

        local pageSwitch = wkCreatePageSwitcher(frame, "settings")
        pageSwitch:SetPoint("RIGHT", closeX, "LEFT", -4, 0)
        pageSwitch:SetFrameLevel(frame:GetFrameLevel() + 20)

        local search = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
        search:SetSize(300, 24)
        search:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 6, -12)
        search:SetAutoFocus(false)
        search:SetMaxLetters(80)
        search:SetScript("OnEscapePressed", function(self)
            if self:GetText() ~= "" then
                self:SetText("")
            end
            self:ClearFocus()
        end)
        search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        local searchPlaceholder = search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        searchPlaceholder:SetPoint("LEFT", search, "LEFT", 4, 0)
        searchPlaceholder:SetText("Search name, class, or spec")
        frame.searchBox = search
        frame.searchText = ""

        local function styleChip(chip, selected)
            if not chip.SetBackdrop then return end
            if selected then
                chip:SetBackdropColor(0.30, 0.36, 0.48, 1)
                chip:SetBackdropBorderColor(0.78, 0.84, 1, 1)
            else
                chip:SetBackdropColor(0.12, 0.12, 0.15, 1)
                chip:SetBackdropBorderColor(0.34, 0.34, 0.40, 1)
            end
        end

        frame.filter = "all"
        frame.filterButtons = {}
        local filters = {
            { id = "all", label = "All", width = 64 },
            { id = "match", label = "This character", width = 120 },
            { id = "other", label = "Other classes", width = 110 },
        }
        for index, def in ipairs(filters) do
            local chip = CreateFrame("Button", nil, frame, "BackdropTemplate")
            chip:SetSize(def.width, 22)
            if index == 1 then
                chip:SetPoint("TOPLEFT", search, "BOTTOMLEFT", -6, -8)
            else
                chip:SetPoint("LEFT", frame.filterButtons[index - 1], "RIGHT", 6, 0)
            end
            if chip.SetBackdrop then
                chip:SetBackdrop({
                    bgFile = "Interface\\Buttons\\WHITE8X8",
                    edgeFile = "Interface\\Buttons\\WHITE8X8",
                    tile = false, edgeSize = 1,
                    insets = { left = 1, right = 1, top = 1, bottom = 1 },
                })
            end
            chip.label = chip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            chip.label:SetPoint("CENTER")
            chip.label:SetText(def.label)
            chip.filterId = def.id
            chip:SetScript("OnClick", function(self)
                frame.filter = self.filterId
                frame:Refresh(true)
            end)
            styleChip(chip, def.id == "all")
            frame.filterButtons[index] = chip
        end
        frame.styleChip = styleChip

        local function makeHeaderChip(label, width, anchor, onClick)
            local chip = CreateFrame("Button", nil, frame, "BackdropTemplate")
            chip:SetSize(width, 22)
            chip:SetPoint("LEFT", anchor, "RIGHT", 8, 0)
            if chip.SetBackdrop then
                chip:SetBackdrop({
                    bgFile = "Interface\\Buttons\\WHITE8X8",
                    edgeFile = "Interface\\Buttons\\WHITE8X8",
                    tile = false, edgeSize = 1,
                    insets = { left = 1, right = 1, top = 1, bottom = 1 },
                })
                chip:SetBackdropColor(0.12, 0.12, 0.15, 1)
                chip:SetBackdropBorderColor(0.34, 0.34, 0.40, 1)
            end
            chip.label = chip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            chip.label:SetPoint("CENTER")
            chip.label:SetText(label)
            chip:SetScript("OnClick", onClick)
            chip:SetScript("OnEnter", function(self)
                if self.SetBackdropBorderColor then
                    self:SetBackdropBorderColor(0.78, 0.84, 1, 1)
                end
            end)
            chip:SetScript("OnLeave", function(self)
                if self.SetBackdropBorderColor then
                    self:SetBackdropBorderColor(0.34, 0.34, 0.40, 1)
                end
            end)
            return chip
        end

        if not StaticPopupDialogs["WOWKEYB_SETTINGS_NEW_NAME"] then
            StaticPopupDialogs["WOWKEYB_SETTINGS_NEW_NAME"] = {
                text = "Name the new profile",
                button1 = "Create",
                button2 = "Cancel",
                hasEditBox = true,
                maxLetters = 100,
                OnShow = function(self)
                    if self.editBox then
                        self.editBox:SetText("")
                        self.editBox:SetFocus()
                    end
                end,
                OnAccept = function(self)
                    local panel = WoWKeyb.optionsPanel
                    local name = self.editBox and self.editBox:GetText() or ""
                    if panel and panel.beginCreate then
                        panel.beginCreate(name)
                    end
                end,
                EditBoxOnEnterPressed = function(self)
                    local parent = self:GetParent()
                    local panel = WoWKeyb.optionsPanel
                    if panel and panel.beginCreate then
                        panel.beginCreate(self:GetText() or "")
                    end
                    if parent then parent:Hide() end
                end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
                preferredIndex = 3,
            }
        end

        local newChip = makeHeaderChip("New", 64, frame.filterButtons[#frame.filterButtons], function()
            StaticPopup_Show("WOWKEYB_SETTINGS_NEW_NAME")
        end)
        makeHeaderChip("Import", 72, newChip, function()
            WoWKeyb:ShowImportDialog("ImportedProfile")
        end)

        local listPanel = CreateFrame("Frame", nil, frame, "BackdropTemplate")
        listPanel:SetPoint("TOPLEFT", 16, -124)
        listPanel:SetPoint("BOTTOMRIGHT", -16, 156)
        if listPanel.SetBackdrop then
            listPanel:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = false, edgeSize = 10,
                insets = { left = 2, right = 2, top = 2, bottom = 2 },
            })
            listPanel:SetBackdropColor(0.07, 0.07, 0.09, 0.92)
            listPanel:SetBackdropBorderColor(0.24, 0.24, 0.30, 0.95)
        end

        local scroll = CreateFrame("ScrollFrame", "WoWKeybProfileBrowserScroll", listPanel, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 8, -8)
        scroll:SetPoint("BOTTOMRIGHT", -28, 8)
        local listChild = CreateFrame("Frame", nil, scroll)
        listChild:SetSize(560, 1)
        scroll:SetScrollChild(listChild)
        frame.scroll = scroll
        frame.listChild = listChild
        frame.profileRows = {}
        frame.headerRows = {}

        local emptyText = listPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        emptyText:SetPoint("CENTER", 0, 8)
        emptyText:SetWidth(420)
        emptyText:SetJustifyH("CENTER")
        emptyText:SetText("No imported profiles yet.\nImport a share code from wowkeyb.gg.")
        frame.emptyText = emptyText

        local function scrollList(delta)
            local current = scroll:GetVerticalScroll()
            local range = scroll:GetVerticalScrollRange() or 0
            local nextScroll = current - (delta * 52)
            if nextScroll < 0 then nextScroll = 0 end
            if nextScroll > range then nextScroll = range end
            scroll:SetVerticalScroll(nextScroll)
        end
        scroll:EnableMouseWheel(true)
        scroll:SetScript("OnMouseWheel", function(_, delta) scrollList(delta) end)
        frame.scrollList = scrollList

        local detail = CreateFrame("Frame", nil, frame, "BackdropTemplate")
        detail:SetPoint("BOTTOMLEFT", 16, 16)
        detail:SetPoint("BOTTOMRIGHT", -16, 16)
        detail:SetHeight(128)
        wkApplyViewerPanelBackdrop(detail)
        frame.detailCard = detail

        local detailName = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        detailName:SetPoint("TOPLEFT", 14, -12)
        detailName:SetWidth(420)
        detailName:SetJustifyH("LEFT")
        detailName:SetText("Select a profile")
        frame.detailName = detailName

        local detailMeta = detail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        detailMeta:SetPoint("TOPLEFT", detailName, "BOTTOMLEFT", 0, -4)
        detailMeta:SetWidth(640)
        detailMeta:SetJustifyH("LEFT")
        detailMeta:SetText("Click one in the list. Actions apply to that profile only.")
        frame.detailMeta = detailMeta

        local detailStatus = detail:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        detailStatus:SetPoint("TOPLEFT", detailMeta, "BOTTOMLEFT", 0, -2)
        detailStatus:SetJustifyH("LEFT")
        detailStatus:SetText("")
        frame.detailStatus = detailStatus

        local function selectedProfile()
            local name = frame.selectedName
            if not name or not WoWKeybDB.profiles[name] then
                return nil, nil
            end
            return name, WoWKeybDB.profiles[name]
        end

        local function canApplySelection()
            local name, profile = selectedProfile()
            if not profile then
                return false, "Select a profile."
            end
            local diagnostics = getProfileMatchDiagnostics(profile)
            if diagnostics and not diagnostics.matches then
                return false, "This profile is for a different " .. tostring(diagnostics.reasonSummary or "setup") .. "."
            end
            return true, name
        end

        local function syncSettingsSelection(name)
            local panel = WoWKeyb.optionsPanel
            if panel and panel.selectProfile then
                panel.selectProfile(name)
            elseif panel then
                panel.userSelectedProfile = name
            end
        end

        local function applySelected()
            local allowed, reasonOrName = canApplySelection()
            if not allowed then
                print("|cffff0000[WoWKeyb]|r " .. tostring(reasonOrName or "That profile cannot be applied."))
                return
            end
            local ok, result = applySelectionByName(reasonOrName)
            if ok then
                print("|cff00ff00[WoWKeyb]|r " .. tostring(result))
                local panel = WoWKeyb.optionsPanel
                if panel and panel.refreshCurrentProfileText then
                    panel.refreshCurrentProfileText()
                end
                if panel and panel.refreshProfileSelector then
                    panel.refreshProfileSelector()
                else
                    frame:Refresh(false)
                end
            else
                print("|cffff0000[WoWKeyb]|r " .. tostring(result or "Failed to apply"))
            end
        end

        local function runProfileAction(methodName)
            local name = selectedProfile()
            if not name then
                return
            end
            local panel = WoWKeyb.optionsPanel
            local method = panel and panel[methodName]
            if type(method) ~= "function" then
                print("|cffff0000[WoWKeyb]|r Profile actions are not ready yet.")
                return
            end
            method(name)
        end

        frame.detailActions = {}
        local actionDefs = {
            { id = "apply", label = "Apply", width = 72 },
            { id = "view", label = "View map", width = 88 },
            { id = "export", label = "Export", width = 72 },
            { id = "duplicate", label = "Duplicate", width = 88 },
            { id = "rename", label = "Rename", width = 76 },
            { id = "reset", label = "Reset", width = 64 },
            { id = "delete", label = "Delete", width = 68 },
        }
        for index, def in ipairs(actionDefs) do
            local button = CreateFrame("Button", nil, detail, "BackdropTemplate")
            button:SetSize(def.width, 22)
            button.actionId = def.id
            if index == 1 then
                button:SetPoint("BOTTOMLEFT", 14, 12)
            else
                button:SetPoint("LEFT", frame.detailActions[index - 1], "RIGHT", 6, 0)
            end
            if button.SetBackdrop then
                button:SetBackdrop({
                    bgFile = "Interface\\Buttons\\WHITE8X8",
                    edgeFile = "Interface\\Buttons\\WHITE8X8",
                    tile = false, edgeSize = 1,
                    insets = { left = 1, right = 1, top = 1, bottom = 1 },
                })
                button:SetBackdropColor(0.16, 0.16, 0.2, 1)
                button:SetBackdropBorderColor(0.4, 0.4, 0.48, 1)
            end
            button.label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            button.label:SetPoint("CENTER")
            button.label:SetText(def.label)
            button:SetScript("OnClick", function(self)
                if self.actionId == "apply" then
                    applySelected()
                elseif self.actionId == "view" then
                    local name = selectedProfile()
                    if name then WoWKeyb:ShowKeybindingViewer(name) end
                elseif self.actionId == "export" then
                    local name = selectedProfile()
                    if name then WoWKeyb:ShowExportDialog(name) end
                elseif self.actionId == "duplicate" then
                    runProfileAction("duplicateProfile")
                elseif self.actionId == "rename" then
                    runProfileAction("renameProfile")
                elseif self.actionId == "reset" then
                    runProfileAction("resetProfile")
                elseif self.actionId == "delete" then
                    runProfileAction("deleteProfile")
                end
            end)
            button:SetScript("OnEnter", function(self)
                if self.SetBackdropColor then
                    self:SetBackdropColor(0.24, 0.28, 0.36, 1)
                    self:SetBackdropBorderColor(0.78, 0.84, 1, 1)
                end
                if self.actionId == "apply" then
                    local allowed, reason = canApplySelection()
                    GameTooltip:SetOwner(self, "ANCHOR_TOP")
                    GameTooltip:ClearLines()
                    if allowed then
                        GameTooltip:AddLine("Apply this profile to your current character.", 1, 1, 1)
                    else
                        GameTooltip:AddLine(tostring(reason or "Cannot apply this profile."), 1, 0.82, 0.35, true)
                    end
                    GameTooltip:Show()
                end
            end)
            button:SetScript("OnLeave", function(self)
                GameTooltip:Hide()
                if self.SetBackdropColor then
                    self:SetBackdropColor(0.16, 0.16, 0.2, 1)
                    self:SetBackdropBorderColor(0.4, 0.4, 0.48, 1)
                end
            end)
            button:Hide()
            frame.detailActions[index] = button
        end

        local function updateDetail()
            local name, profile = selectedProfile()
            if not profile then
                detailName:SetText("Select a profile")
                detailMeta:SetText("Click one in the list. Actions apply to that profile only.")
                detailMeta:SetTextColor(0.8, 0.8, 0.8)
                detailStatus:SetText("")
                for _, button in ipairs(frame.detailActions) do
                    button:Hide()
                end
                return
            end
            local _, contextLine = profileBrowserContext(profile)
            local keybindCount, macroCount = computeExportSummaryCounts(profile)
            local diagnostics = getProfileMatchDiagnostics(profile)
            local matches = diagnostics and diagnostics.matches
            local isActive = tostring(WoWKeybDB.currentProfile or "") == tostring(name)
            detailName:SetText(name)
            detailMeta:SetText(contextLine)
            local cr, cg, cb = profileBrowserClassColor(profile)
            detailMeta:SetTextColor(cr, cg, cb)
            local status = matches and "Ready for this character" or profileBrowserMismatchLabel(diagnostics and diagnostics.reasonSummary)
            if isActive then
                status = "Active"
            end
            detailStatus:SetText(string.format("%s    ·    %d keys    ·    %d macros", status, keybindCount, macroCount))
            if isActive or matches then
                detailStatus:SetTextColor(0.45, 0.95, 0.55)
            else
                detailStatus:SetTextColor(0.95, 0.78, 0.35)
            end
            for _, button in ipairs(frame.detailActions) do
                button:Show()
                if button.actionId == "apply" then
                    button:SetAlpha(matches and 1 or 0.45)
                else
                    button:SetAlpha(1)
                end
            end
        end
        frame.updateDetail = updateDetail

        local function hidePool(pool)
            for _, row in ipairs(pool) do
                row:Hide()
            end
        end

        local function acquireHeader(index)
            local row = frame.headerRows[index]
            if row then
                row:Show()
                return row
            end
            row = CreateFrame("Frame", nil, listChild)
            row:SetSize(548, 18)
            row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.label:SetPoint("LEFT", 2, 0)
            row:EnableMouseWheel(true)
            row:SetScript("OnMouseWheel", function(_, delta) scrollList(delta) end)
            frame.headerRows[index] = row
            return row
        end

        local function acquireProfileRow(index)
            local row = frame.profileRows[index]
            if row then
                row:Show()
                return row
            end
            row = CreateFrame("Button", nil, listChild, "BackdropTemplate")
            row:SetSize(548, 48)
            row:RegisterForClicks("LeftButtonUp")
            if row.SetBackdrop then
                row:SetBackdrop({
                    bgFile = "Interface\\Buttons\\WHITE8X8",
                    edgeFile = "Interface\\Buttons\\WHITE8X8",
                    tile = false, edgeSize = 1,
                    insets = { left = 1, right = 1, top = 1, bottom = 1 },
                })
            end
            row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.nameText:SetPoint("TOPLEFT", 10, -7)
            row.nameText:SetWidth(360)
            row.nameText:SetJustifyH("LEFT")
            row.nameText:SetWordWrap(false)
            row.metaText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            row.metaText:SetPoint("TOPLEFT", 10, -26)
            row.metaText:SetWidth(340)
            row.metaText:SetJustifyH("LEFT")
            row.metaText:SetWordWrap(false)
            row.statusText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.statusText:SetPoint("TOPRIGHT", -10, -8)
            row.statusText:SetJustifyH("RIGHT")
            row.countText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            row.countText:SetPoint("TOPRIGHT", -10, -26)
            row.countText:SetJustifyH("RIGHT")
            row:SetScript("OnClick", function(self)
                local name = self.entry and self.entry.name or nil
                local now = GetTime()
                local isDouble = self.lastClickName == name and self.lastClickTime and (now - self.lastClickTime) <= 0.3
                self.lastClickName = name
                self.lastClickTime = now
                frame.selectedName = name
                if name then
                    syncSettingsSelection(name)
                end
                if isDouble then
                    applySelected()
                    return
                end
                frame:Refresh(false)
            end)
            row:SetScript("OnEnter", function(self)
                if self.SetBackdropColor and frame.selectedName ~= (self.entry and self.entry.name) then
                    self:SetBackdropColor(0.18, 0.18, 0.22, 1)
                    self:SetBackdropBorderColor(0.45, 0.45, 0.52, 1)
                end
                local entry = self.entry
                if entry and entry.reasons and #entry.reasons > 0 then
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:ClearLines()
                    GameTooltip:AddLine(entry.name, 1, 1, 1)
                    for _, reason in ipairs(entry.reasons) do
                        GameTooltip:AddLine(reason, 0.95, 0.82, 0.45, true)
                    end
                    GameTooltip:Show()
                end
            end)
            row:SetScript("OnLeave", function(self)
                GameTooltip:Hide()
                if not self.SetBackdropColor then return end
                local selected = frame.selectedName == (self.entry and self.entry.name)
                if selected then
                    self:SetBackdropColor(0.20, 0.26, 0.36, 1)
                    self:SetBackdropBorderColor(0.78, 0.84, 1, 1)
                else
                    self:SetBackdropColor(0.11, 0.11, 0.14, 1)
                    self:SetBackdropBorderColor(0.28, 0.28, 0.34, 1)
                end
            end)
            row:EnableMouseWheel(true)
            row:SetScript("OnMouseWheel", function(_, delta) scrollList(delta) end)
            frame.profileRows[index] = row
            return row
        end

        function frame:Refresh(resetScroll)
            if frame.refreshing then return end
            frame.refreshing = true

            local query = tostring(frame.searchText or ""):lower()
            local filterId = frame.filter or "all"
            for _, chip in ipairs(frame.filterButtons) do
                frame.styleChip(chip, chip.filterId == filterId)
            end

            local panel = WoWKeyb.optionsPanel
            if panel and panel.getSelectedProfile then
                local fromPanel = panel.getSelectedProfile()
                if fromPanel and fromPanel ~= BLIZZARD_DEFAULT_PROFILE and WoWKeybDB.profiles[fromPanel] then
                    frame.selectedName = fromPanel
                elseif fromPanel == BLIZZARD_DEFAULT_PROFILE then
                    frame.selectedName = nil
                end
            end
            if frame.selectedName and not WoWKeybDB.profiles[frame.selectedName] then
                frame.selectedName = nil
            end

            local currentName = tostring(WoWKeybDB.currentProfile or "")
            local entries = {}
            local totalCount = 0
            local matchTotal = 0
            for name, profile in pairs(WoWKeybDB.profiles or {}) do
                if type(profile) == "table" then
                    totalCount = totalCount + 1
                    local diagnostics = getProfileMatchDiagnostics(profile)
                    local matches = diagnostics and diagnostics.matches or false
                    if matches then
                        matchTotal = matchTotal + 1
                    end
                    local _, contextLine, searchBlob = profileBrowserContext(profile)
                    local haystack = (tostring(name) .. " " .. searchBlob):lower()
                    local queryOk = query == "" or haystack:find(query, 1, true) ~= nil
                    local filterOk = filterId == "all" or (filterId == "match" and matches) or (filterId == "other" and not matches)
                    if queryOk and filterOk then
                        local keybindCount, macroCount = computeExportSummaryCounts(profile)
                        entries[#entries + 1] = {
                            name = tostring(name),
                            sortName = tostring(name):lower(),
                            profile = profile,
                            matches = matches,
                            active = tostring(name) == currentName,
                            contextLine = contextLine,
                            statusLabel = matches and "Ready" or profileBrowserMismatchLabel(diagnostics and diagnostics.reasonSummary),
                            reasons = (diagnostics and not matches) and diagnostics.reasons or nil,
                            keybindCount = keybindCount,
                            macroCount = macroCount,
                        }
                    end
                end
            end
            table.sort(entries, function(a, b)
                if a.matches ~= b.matches then
                    return a.matches
                end
                if a.active ~= b.active then
                    return a.active
                end
                return a.sortName < b.sortName
            end)

            if totalCount == 0 then
                frame.subtitle:SetText("Nothing imported yet.")
            else
                frame.subtitle:SetText(string.format("Profiles   ·   %d imported   ·   %d for this character", totalCount, matchTotal))
            end

            hidePool(frame.headerRows)
            hidePool(frame.profileRows)

            local y = -4
            local headerIndex = 0
            local rowIndex = 0
            local lastGroup = nil
            for _, entry in ipairs(entries) do
                local group = entry.matches and "This character" or "Other classes"
                if group ~= lastGroup then
                    lastGroup = group
                    headerIndex = headerIndex + 1
                    local header = acquireHeader(headerIndex)
                    header:SetPoint("TOPLEFT", listChild, "TOPLEFT", 4, y)
                    header.label:SetText(group)
                    y = y - 22
                end
                rowIndex = rowIndex + 1
                local row = acquireProfileRow(rowIndex)
                row.entry = entry
                row:SetPoint("TOPLEFT", listChild, "TOPLEFT", 2, y)
                row.nameText:SetText(entry.name)
                local cr, cg, cb = profileBrowserClassColor(entry.profile)
                row.metaText:SetText(entry.contextLine)
                row.metaText:SetTextColor(cr, cg, cb)
                local statusR, statusG, statusB = 0.55, 0.85, 0.55
                local status = entry.statusLabel
                if entry.active then
                    status = "Active"
                    statusR, statusG, statusB = 0.45, 0.95, 0.55
                elseif not entry.matches then
                    statusR, statusG, statusB = 0.95, 0.78, 0.35
                end
                row.statusText:SetText(status)
                row.statusText:SetTextColor(statusR, statusG, statusB)
                row.countText:SetText(string.format("%d keys   ·   %d macros", entry.keybindCount, entry.macroCount))
                local selected = frame.selectedName == entry.name
                if row.SetBackdropColor then
                    if selected then
                        row:SetBackdropColor(0.20, 0.26, 0.36, 1)
                        row:SetBackdropBorderColor(0.78, 0.84, 1, 1)
                    else
                        row:SetBackdropColor(0.11, 0.11, 0.14, 1)
                        row:SetBackdropBorderColor(0.28, 0.28, 0.34, 1)
                    end
                end
                y = y - 54
            end

            local listHeight = math.max(scroll:GetHeight() or 0, math.abs(y) + 8)
            listChild:SetHeight(listHeight)
            scroll:UpdateScrollChildRect()
            if resetScroll then
                scroll:SetVerticalScroll(0)
            else
                local range = scroll:GetVerticalScrollRange() or 0
                local current = scroll:GetVerticalScroll()
                if current > range then
                    scroll:SetVerticalScroll(range)
                end
            end

            updateDetail()
            if #entries == 0 then
                if totalCount == 0 then
                    emptyText:SetText("No imported profiles yet.\nImport a share code from wowkeyb.gg.")
                elseif query ~= "" then
                    emptyText:SetText("No profiles match that search.")
                else
                    emptyText:SetText("No profiles in this filter.")
                end
                emptyText:Show()
            else
                emptyText:Hide()
            end

            frame.refreshing = false
        end

        search:SetScript("OnTextChanged", function(self)
            searchPlaceholder:SetShown(self:GetText() == "")
            local nextQuery = tostring(self:GetText() or "")
            if nextQuery == frame.searchText then
                return
            end
            frame.searchText = nextQuery
            frame:Refresh(true)
        end)
        searchPlaceholder:SetShown(true)

        profileBrowser = frame
    end

    profileBrowser:Show()
    raiseWoWKeybPopup(profileBrowser, 180)
    profileBrowser:Refresh(false)
    if viewerFrame and viewerFrame:IsShown() then
        viewerFrame:Hide()
    end
end

function WoWKeyb:HideSettingsPage()
    if profileBrowser then
        profileBrowser:Hide()
    end
end

local function snapshotShownPoint(target)
    if not target or not target:IsShown() then
        return nil
    end
    local point, relativeTo, relativePoint, x, y = target:GetPoint(1)
    if not point then
        return nil
    end
    return {
        point = point,
        relativeTo = relativeTo,
        relativePoint = relativePoint,
        x = x,
        y = y,
    }
end

local function applyShownPoint(target, snap)
    if not target or not snap or not snap.point then
        return
    end
    target:ClearAllPoints()
    target:SetPoint(snap.point, snap.relativeTo or UIParent, snap.relativePoint or snap.point, snap.x or 0, snap.y or 0)
end

function WoWKeyb:Open(page)
    if page == "settings" then
        local snap = snapshotShownPoint(viewerFrame)
        WoWKeyb:ShowProfileBrowser()
        applyShownPoint(profileBrowser, snap)
        return
    end
    local snap = snapshotShownPoint(profileBrowser)
    WoWKeyb:ShowKeybindingViewer(nil)
    applyShownPoint(viewerFrame, snap)
end

function WoWKeyb:ToggleProfileBrowser()
    WoWKeyb:Open("settings")
end

local function openAddonSettings()
    WoWKeyb:Open("settings")
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
    subtitle:SetText("Left-click the minimap icon for the keybind map. Right-click for profiles.")

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

    local importBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    importBtn:SetSize(160, 24)
    importBtn:SetPoint("TOPLEFT", currentProfileText, "BOTTOMLEFT", 0, -8)
    importBtn:SetText("Import Profile")
    importBtn:SetScript("OnClick", function()
        WoWKeyb:ShowImportDialog("ImportedProfile")
    end)

    local browseBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    browseBtn:SetSize(160, 24)
    browseBtn:SetPoint("LEFT", importBtn, "RIGHT", 8, 0)
    browseBtn:SetText("Browse Profiles")
    browseBtn:SetScript("OnClick", function()
        WoWKeyb:ShowProfileBrowser()
    end)

    local profileLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    profileLabel:SetPoint("TOPLEFT", importBtn, "BOTTOMLEFT", 0, -18)
    profileLabel:SetText("Selected profile:")

    local profileDropdown = CreateFrame("Frame", "WoWKeybProfileDropdown", panel, "UIDropDownMenuTemplate")
    profileDropdown:SetPoint("TOPLEFT", profileLabel, "BOTTOMLEFT", -16, -4)
    UIDropDownMenu_SetWidth(profileDropdown, 220)
    local applyBtn
    local createBtn
    local duplicateBtn
    local resetBtn
    local selectedViewerBtn

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
        if applyBtn then
            local canApply = selectedProfileCanApply()
            if applyBtn.Enable then
                if canApply then
                    applyBtn:Enable()
                else
                    applyBtn:Disable()
                end
            end
            applyBtn:SetText("Apply Profile")
        end
        if selectedViewerBtn then
            local target = selectedProfileName or WoWKeybDB.currentProfile
            local canView = target
                and target ~= BLIZZARD_DEFAULT_PROFILE
                and WoWKeybDB.profiles[target] ~= nil
            if canView then
                selectedViewerBtn:Enable()
            else
                selectedViewerBtn:Disable()
            end
        end
    end

    local function deepCopy(value)
        if type(value) ~= "table" then
            return value
        end
        local out = {}
        for k, v in pairs(value) do
            out[deepCopy(k)] = deepCopy(v)
        end
        return out
    end

    local function buildDefaultLayoutBars()
        local bars = {}
        for barIdx = 1, VIEWER_BAR_COUNT do
            bars[barIdx] = {
                id = "bar" .. tostring(barIdx),
                slots = 12,
                slotKeys = {},
                position = {
                    anchor = "center",
                    x = 1280,
                    y = 720,
                },
                orientation = "horizontal",
                scale = 1,
                enabled = barIdx == 1 or (isActionBarShown and isActionBarShown(barIdx)) or false,
            }
        end
        return bars
    end

    local function buildDefaultProfileState(profileName, existingProfile)
        local profile = type(existingProfile) == "table" and existingProfile or {}
        local classValue = tostring(profile.class or "")
        local specValue = tostring(profile.spec or profile.spec_id or profile.specId or profile.specialization or "")
        local specIdValue = tostring(profile.specId or profile.spec_id or "")
        local heroValue = tostring(profile.heroTalent or profile.hero_talent or profile.hero_talent_id or profile.heroTalentId or "")
        local heroIdValue = tostring(profile.heroTalentId or profile.hero_talent_id or "")

        if classValue == "" then
            local _, englishClass, classToken = UnitClass("player")
            classValue = tostring(englishClass or classToken or "Unknown")
        end
        if specValue == "" then
            local specIndex = GetSpecialization and GetSpecialization() or nil
            if specIndex and GetSpecializationInfo then
                local specId, specName = GetSpecializationInfo(specIndex)
                specValue = tostring(specName or specId or "")
                specIdValue = specId and tostring(specId) or specIdValue
            end
        end
        if heroValue == "" and C_ClassTalents and type(C_ClassTalents.GetActiveHeroTalentSpec) == "function" then
            local okHero, activeHeroId = pcall(C_ClassTalents.GetActiveHeroTalentSpec)
            if okHero and activeHeroId then
                heroIdValue = tostring(activeHeroId)
                if type(C_ClassTalents.GetHeroTalentSpecInfo) == "function" then
                    local okInfo, heroInfo = pcall(C_ClassTalents.GetHeroTalentSpecInfo, activeHeroId)
                    if okInfo and type(heroInfo) == "table" then
                        heroValue = tostring(heroInfo.name or heroInfo.heroTalentName or "")
                    end
                end
                if heroValue == "" then
                    heroValue = heroIdValue
                end
            end
        end

        return {
            name = tostring(profileName or "New Profile"),
            class = classValue,
            spec = specValue,
            specId = specIdValue,
            heroTalent = heroValue,
            heroTalentId = heroIdValue,
            keybinds = {},
            macros = {},
            layout = {
                bars = buildDefaultLayoutBars(),
                barMode = "blizzard",
                screenWidth = 2560,
                screenHeight = 1440,
                barGap = 16,
            },
        }
    end

    local function getCurrentPlayerContextValues()
        local _, englishClass, classToken = UnitClass("player")
        local classValue = tostring(englishClass or classToken or "Unknown")

        local specId, specName = nil, nil
        local specIndex = GetSpecialization and GetSpecialization() or nil
        if specIndex and GetSpecializationInfo then
            specId, specName = GetSpecializationInfo(specIndex)
        end
        local specValue = tostring(specName or specId or "")
        local specIdValue = specId and tostring(specId) or ""

        local heroIdValue = ""
        local heroValue = ""
        if C_ClassTalents and type(C_ClassTalents.GetActiveHeroTalentSpec) == "function" then
            local okHero, activeHeroId = pcall(C_ClassTalents.GetActiveHeroTalentSpec)
            if okHero and activeHeroId then
                heroIdValue = tostring(activeHeroId)
                heroValue = resolveHeroTalentNameFromId(activeHeroId)
                if heroValue == "" then
                    heroValue = heroIdValue
                end
            end
        end

        return {
            class = classValue,
            spec = specValue,
            specId = specIdValue,
            heroTalent = heroValue,
            heroTalentId = heroIdValue,
        }
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
        local preferredSelection = panel.userSelectedProfile or WoWKeybDB.currentProfile or BLIZZARD_DEFAULT_PROFILE
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
            panel.userSelectedProfile = nil
            selectedProfileName = WoWKeybDB.currentProfile or BLIZZARD_DEFAULT_PROFILE
            local selectedIsStoredProfile = selectedProfileName == BLIZZARD_DEFAULT_PROFILE or WoWKeybDB.profiles[selectedProfileName]
            if not selectedIsStoredProfile then
                selectedProfileName = BLIZZARD_DEFAULT_PROFILE
            end
        end

        local preferredProfile = getPreferredProfileForCurrentContext()
        local labels = buildPlayerLabelCollection()
        local classLabel = labels.class.variants[1] or "Unknown"
        local specLabel = labels.spec.names[1] or labels.spec.ids[1] or "-"
        local heroLabel = labels.hero.names[1] or labels.hero.ids[1] or "-"

        local matchCount = 0
        for _, name in ipairs(profiles) do
            local diagnostics = getProfileMatchDiagnostics(WoWKeybDB.profiles[name])
            if diagnostics and diagnostics.matches then
                matchCount = matchCount + 1
            end
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
                    end
                end
                info.text = displayName
                info.checked = (name == selectedProfileName)
                info.func = function()
                    selectedProfileName = name
                    panel.userSelectedProfile = name
                    UIDropDownMenu_SetText(profileDropdown, name)
                    panel.forceVisibleProfileName = nil
                    refreshApplyButtonState()
                    if WoWKeyb.RefreshProfileBrowser then
                        WoWKeyb:RefreshProfileBrowser()
                    end
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
        UIDropDownMenu_SetText(profileDropdown, selectedProfileName or BLIZZARD_DEFAULT_PROFILE)
        refreshApplyButtonState()

        local importedCount = 0
        for _, name in ipairs(selectorOptions) do
            if name ~= BLIZZARD_DEFAULT_PROFILE then
                importedCount = importedCount + 1
            end
        end
        profileStatusText:SetText(string.format(
            "%s / %s / %s\n%d imported, %d for this character.\nUse Browse Profiles to search the full list.",
            tostring(classLabel),
            tostring(specLabel),
            tostring(heroLabel),
            importedCount,
            matchCount
        ))
        if WoWKeyb.RefreshProfileBrowser then
            WoWKeyb:RefreshProfileBrowser()
        end
    end
    panel.selectProfile = function(name)
        local target = tostring(name or "")
        if target == "" then
            return
        end
        if target ~= BLIZZARD_DEFAULT_PROFILE and not WoWKeybDB.profiles[target] then
            return
        end
        selectedProfileName = target
        panel.userSelectedProfile = target
        panel.forceVisibleProfileName = nil
        UIDropDownMenu_SetText(profileDropdown, target)
        refreshApplyButtonState()
    end
    panel.getSelectedProfile = function()
        return selectedProfileName
    end
    panel.refreshProfileSelector = refreshProfileSelector
    refreshProfileSelector()

    local newProfileLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    -- Keep New/Copy controls below selected-profile action buttons.
    newProfileLabel:SetPoint("TOPLEFT", profileDropdown, "BOTTOMLEFT", 16, -150)
    newProfileLabel:SetText("New:")

    local newProfileEdit = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    newProfileEdit:SetSize(170, 24)
    newProfileEdit:SetPoint("TOPLEFT", newProfileLabel, "BOTTOMLEFT", 0, -4)
    newProfileEdit:SetAutoFocus(false)
    newProfileEdit:SetMaxLetters(100)

    createBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    createBtn:SetSize(100, 24)
    createBtn:SetPoint("TOPLEFT", newProfileEdit, "BOTTOMLEFT", 0, -6)
    createBtn:SetText("Create New")
    createBtn:Disable()
    createBtn:SetAlpha(0.5)

    local function refreshCreateButtonState()
        local targetName = tostring(newProfileEdit:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if targetName ~= "" then
            createBtn:Enable()
            createBtn:SetAlpha(1)
        else
            createBtn:Disable()
            createBtn:SetAlpha(0.5)
        end
    end
    newProfileEdit:SetScript("OnTextChanged", refreshCreateButtonState)
    refreshCreateButtonState()

    local function validateNewProfileNameFromInput()
        local targetName = tostring(newProfileEdit:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if InCombatLockdown() then
            print("|cffff0000[WoWKeyb]|r Cannot create a new profile while in combat.")
            return nil
        end
        if targetName == "" then
            print("|cffff0000[WoWKeyb]|r New profile name cannot be empty.")
            return nil
        end
        if targetName == BLIZZARD_DEFAULT_PROFILE then
            print("|cffff0000[WoWKeyb]|r That name is reserved.")
            return nil
        end
        if WoWKeybDB.profiles[targetName] then
            print("|cffff0000[WoWKeyb]|r A profile with that name already exists.")
            return nil
        end
        return targetName
    end

    local function applyFreshBlizzardBarsAndBindings()
        local cleared, clearErr = clearActionBarsAndBindings()
        if not cleared then
            return false, tostring(clearErr or "Failed to clear bars and bindings.")
        end

        clearCustomLayoutFrames()
        applyBarModeVisibility(false)

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

        return true
    end

    local function createProfileWithMode(targetName, mode)
        if mode == "fresh" then
            local freshOk, freshErr = applyFreshBlizzardBarsAndBindings()
            if not freshOk then
                print("|cffff0000[WoWKeyb]|r " .. tostring(freshErr or "Failed to apply Blizzard default bars and keybindings."))
                return false
            end
        end

        WoWKeybDB.profiles[targetName] = buildDefaultProfileState(targetName, nil)
        local createdProfile = WoWKeybDB.profiles[targetName]
        local context = getCurrentPlayerContextValues()
        if type(createdProfile) == "table" and type(context) == "table" then
            createdProfile.class = context.class
            createdProfile.spec = context.spec
            createdProfile.specId = context.specId
            createdProfile.heroTalent = context.heroTalent
            createdProfile.heroTalentId = context.heroTalentId
        end
        selectedProfileName = targetName
        WoWKeybDB.previousProfile = WoWKeybDB.currentProfile
        setCurrentProfile(targetName)
        setPreferredProfileForCurrentContext(targetName)

        if mode == "current" then
            local syncResult = syncProfileSnapshotFromGame(targetName, { force = true })
            if syncResult and not syncResult.blocked then
                print("|cff00ff00[WoWKeyb]|r Created profile: " .. tostring(targetName)
                    .. " from current action bars.")
            else
                print("|cffffcc00[WoWKeyb]|r Created profile: " .. tostring(targetName)
                    .. ", but saving current bars failed. Open View Keybinding Map and click Save Current Bars.")
            end
        elseif mode == "fresh" then
            print("|cff00ff00[WoWKeyb]|r Created profile: " .. tostring(targetName)
                .. " with fresh bars and Blizzard default keybindings.")
        else
            print("|cff00ff00[WoWKeyb]|r Created profile: " .. tostring(targetName))
        end

        newProfileEdit:SetText("")
        refreshCreateButtonState()
        refreshProfileSelector()
        refreshCurrentProfileText()
        return true
    end

    if not StaticPopupDialogs["WOWKEYB_CREATE_PROFILE_MODE"] then
        StaticPopupDialogs["WOWKEYB_CREATE_PROFILE_MODE"] = {
            text = "Create profile \"%s\" from current action bars, or make fresh (clear bars + Blizzard default keybinds)?",
            button1 = "From Current Bars",
            button2 = "Make Fresh",
            OnAccept = function(_, data)
                local targetName = type(data) == "table" and data.targetName or nil
                if targetName and targetName ~= "" then
                    createProfileWithMode(targetName, "current")
                end
            end,
            OnCancel = function(_, data, reason)
                -- button2 click should create fresh; escape/close should cancel.
                if tostring(reason or "") ~= "clicked" then
                    return
                end
                local targetName = type(data) == "table" and data.targetName or nil
                if targetName and targetName ~= "" then
                    createProfileWithMode(targetName, "fresh")
                end
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end

    createBtn:SetScript("OnClick", function()
        local targetName = validateNewProfileNameFromInput()
        if not targetName then
            return
        end
        StaticPopup_Show("WOWKEYB_CREATE_PROFILE_MODE", targetName, nil, { targetName = targetName })
    end)

    duplicateBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    duplicateBtn:SetSize(180, 24)
    duplicateBtn:SetPoint("TOPLEFT", createBtn, "BOTTOMLEFT", 0, -10)
    duplicateBtn:SetText("Copy Profile")
    duplicateBtn:SetScript("OnClick", function()
        local source = selectedProfileName or WoWKeybDB.currentProfile
        if not source or source == "" then
            print("|cffff0000[WoWKeyb]|r Select a profile first.")
            return
        end
        if source == BLIZZARD_DEFAULT_PROFILE then
            print("|cffff0000[WoWKeyb]|r Blizzard Default cannot be copied.")
            return
        end
        local sourceProfile = WoWKeybDB.profiles[source]
        if not sourceProfile then
            print("|cffff0000[WoWKeyb]|r Source profile not found: " .. tostring(source))
            return
        end

        local function buildUniqueCopiedProfileName(baseName)
            local seed = tostring(baseName or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if seed == "" then
                seed = "Copied Profile"
            end

            local copyRoot = seed
            local rootWithIndex = seed:match("^(.-)%s%-%s[Cc]opy%s+%d+$")
            if rootWithIndex then
                copyRoot = tostring(rootWithIndex):gsub("%s+$", "")
            else
                local rootWithoutIndex = seed:match("^(.-)%s%-%s[Cc]opy$")
                if rootWithoutIndex then
                    copyRoot = tostring(rootWithoutIndex):gsub("%s+$", "")
                end
            end

            if copyRoot == "" then
                copyRoot = "Copied Profile"
            end

            local familyPrefix = copyRoot .. " - Copy"
            local maxCopyIndex = 0
            for profileName, _ in pairs(WoWKeybDB.profiles or {}) do
                local existingName = tostring(profileName or "")
                if existingName == familyPrefix then
                    if maxCopyIndex < 1 then
                        maxCopyIndex = 1
                    end
                elseif existingName:sub(1, #familyPrefix + 1) == (familyPrefix .. " ") then
                    local suffix = existingName:sub(#familyPrefix + 2)
                    local parsed = tonumber(suffix)
                    if parsed and parsed > maxCopyIndex then
                        maxCopyIndex = parsed
                    end
                end
            end

            local candidate = familyPrefix
            if maxCopyIndex > 0 then
                candidate = string.format("%s %d", familyPrefix, maxCopyIndex + 1)
            end
            if candidate == BLIZZARD_DEFAULT_PROFILE then
                return candidate .. " 1"
            end
            return candidate
        end

        local copiedProfile = deepCopy(sourceProfile)
        local newProfileName = buildUniqueCopiedProfileName(tostring(source))
        copiedProfile.name = newProfileName
        WoWKeybDB.profiles[newProfileName] = copiedProfile
        selectedProfileName = newProfileName
        panel.forceVisibleProfileName = newProfileName

        print("|cff00ff00[WoWKeyb]|r Created copied profile \"" .. tostring(newProfileName) .. "\" from \"" .. tostring(source) .. "\".")
        refreshProfileSelector()
        refreshCurrentProfileText()
    end)

    selectedViewerBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    selectedViewerBtn:SetSize(180, 24)
    selectedViewerBtn:SetPoint("TOPLEFT", profileDropdown, "BOTTOMLEFT", 16, -8)
    selectedViewerBtn:SetText("View Keybinding Map")
    selectedViewerBtn:SetMotionScriptsWhileDisabled(true)
    selectedViewerBtn:SetScript("OnEnter", function(self)
        local target = selectedProfileName or WoWKeybDB.currentProfile
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()
        if not target or target == BLIZZARD_DEFAULT_PROFILE or not WoWKeybDB.profiles[target] then
            GameTooltip:AddLine("No saved map for Blizzard Default", 1, 1, 1)
            GameTooltip:AddLine("Left-click the minimap icon to see your current binds.", 0.8, 0.8, 0.8)
        else
            GameTooltip:AddLine("Open the saved map for this profile.", 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    selectedViewerBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    selectedViewerBtn:SetScript("OnClick", function()
        local target = selectedProfileName or WoWKeybDB.currentProfile
        if not target or target == BLIZZARD_DEFAULT_PROFILE or not WoWKeybDB.profiles[target] then
            return
        end
        WoWKeyb:ShowKeybindingViewer(target)
    end)

    local exportBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    exportBtn:SetSize(180, 24)
    exportBtn:SetPoint("TOPLEFT", selectedViewerBtn, "BOTTOMLEFT", 0, -8)
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

    local renameBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    renameBtn:SetSize(180, 24)
    renameBtn:SetPoint("TOPLEFT", exportBtn, "BOTTOMLEFT", 0, -8)
    renameBtn:SetText("Rename Profile")

    duplicateBtn:ClearAllPoints()
    duplicateBtn:SetPoint("TOPLEFT", renameBtn, "BOTTOMLEFT", 0, -8)

    local deleteBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    deleteBtn:SetSize(180, 24)
    deleteBtn:SetPoint("TOPLEFT", duplicateBtn, "BOTTOMLEFT", 0, -8)
    deleteBtn:SetText("Delete Profile")

    resetBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    resetBtn:SetSize(180, 24)
    resetBtn:SetPoint("TOPLEFT", deleteBtn, "BOTTOMLEFT", 0, -8)
    resetBtn:SetText("Reset Profile")
    resetBtn:SetScript("OnClick", function()
        local target = selectedProfileName
        if not target then
            print("|cffff0000[WoWKeyb]|r No selected profile.")
            return
        end
        if target == BLIZZARD_DEFAULT_PROFILE then
            print("|cffff0000[WoWKeyb]|r Blizzard Default cannot be reset.")
            return
        end
        StaticPopup_Show("WOWKEYB_RESET_PROFILE_CONFIRM", target, nil, target)
    end)

    applyBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    applyBtn:SetSize(180, 24)
    applyBtn:SetPoint("TOPLEFT", selectedViewerBtn, "BOTTOMLEFT", 0, -8)
    applyBtn:SetText("Apply Profile")
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
    exportBtn:ClearAllPoints()
    exportBtn:SetPoint("TOPLEFT", applyBtn, "BOTTOMLEFT", 0, -8)
    refreshApplyButtonState()


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
            setCurrentProfile(targetName)
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

    local function resolveRenamePopupOldName(popup, popupArgData)
        local popupData = popupArgData
        if popupData == nil and popup then
            popupData = popup.data
        end
        if type(popupData) == "table" then
            if popupData.oldName and popupData.oldName ~= "" then
                return tostring(popupData.oldName)
            end
        elseif type(popupData) == "string" and popupData ~= "" then
            return tostring(popupData)
        end
        if type(selectedProfileName) == "string" and selectedProfileName ~= "" then
            return tostring(selectedProfileName)
        end
        if WoWKeybDB and type(WoWKeybDB.currentProfile) == "string" and WoWKeybDB.currentProfile ~= "" then
            return tostring(WoWKeybDB.currentProfile)
        end
        return ""
    end

    local function resolveRenamePopupNewName(popup, editBox)
        if popup and popup.editBox and type(popup.editBox.GetText) == "function" then
            local txt = popup.editBox:GetText()
            if txt ~= nil then
                return tostring(txt)
            end
        end
        if editBox and type(editBox.GetText) == "function" then
            local txt = editBox:GetText()
            if txt ~= nil then
                return tostring(txt)
            end
        end
        if StaticPopup1 and StaticPopup1.which == "WOWKEYB_RENAME_PROFILE" and StaticPopup1EditBox and type(StaticPopup1EditBox.GetText) == "function" then
            return tostring(StaticPopup1EditBox:GetText() or "")
        end
        if StaticPopup2 and StaticPopup2.which == "WOWKEYB_RENAME_PROFILE" and StaticPopup2EditBox and type(StaticPopup2EditBox.GetText) == "function" then
            return tostring(StaticPopup2EditBox:GetText() or "")
        end
        return ""
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
                local oldName = resolveRenamePopupOldName(self, data)
                editBox:SetAutoFocus(true)
                editBox:SetText(tostring(oldName or ""))
                editBox:HighlightText()
            end,
            OnAccept = function(self, data)
                local oldName = resolveRenamePopupOldName(self, data)
                local newName = resolveRenamePopupNewName(self, nil)
                renameProfileByName(oldName, newName)
            end,
            EditBoxOnEnterPressed = function(self)
                local parent = self:GetParent()
                local oldName = resolveRenamePopupOldName(parent, parent and parent.data or nil)
                local newName = resolveRenamePopupNewName(parent, self)
                renameProfileByName(oldName, newName)
                if parent then parent:Hide() end
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
            setCurrentProfile(BLIZZARD_DEFAULT_PROFILE)
            if WoWKeybDB.previousProfile and WoWKeybDB.profiles[WoWKeybDB.previousProfile] then
                setCurrentProfile(WoWKeybDB.previousProfile)
            end
        end
        if WoWKeybDB.previousProfile == target then
            WoWKeybDB.previousProfile = BLIZZARD_DEFAULT_PROFILE
        end
        if not WoWKeybDB.currentProfile then
            setCurrentProfile(BLIZZARD_DEFAULT_PROFILE)
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

    if not StaticPopupDialogs["WOWKEYB_RESET_PROFILE_CONFIRM"] then
        StaticPopupDialogs["WOWKEYB_RESET_PROFILE_CONFIRM"] = {
            text = "Reset selected WoWKeyb profile \"%s\" to defaults?",
            button1 = "Reset",
            button2 = "Cancel",
            OnAccept = function(_, data)
                local target = tostring(data or "")
                if target == "" or target == BLIZZARD_DEFAULT_PROFILE then
                    return
                end
                local existing = WoWKeybDB.profiles[target]
                if type(existing) ~= "table" then
                    print("|cffff0000[WoWKeyb]|r Profile not found: " .. tostring(target))
                    return
                end
                WoWKeybDB.profiles[target] = buildDefaultProfileState(target, existing)
                print("|cff00ff00[WoWKeyb]|r Reset profile: " .. tostring(target))
                refreshProfileSelector()
                refreshCurrentProfileText()
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end

    refreshProfileSelector()
    refreshCurrentProfileText()

    local helpText = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    helpText:SetPoint("TOPLEFT", resetBtn, "BOTTOMLEFT", 0, -22)
    helpText:SetWidth(280)
    helpText:SetJustifyH("LEFT")
    helpText:SetText("Tip: Selecting a profile only changes selection. Use Apply Profile to apply a matching profile.")

    local applyLogCheckbox = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    applyLogCheckbox:SetPoint("TOPLEFT", helpText, "BOTTOMLEFT", -2, -14)
    applyLogCheckbox:SetChecked(WoWKeybDB.debugApplyAssignments == true)
    if applyLogCheckbox.Text then
        applyLogCheckbox.Text:SetText("Show per-slot apply chat logs")
    end
    applyLogCheckbox:SetScript("OnClick", function(self)
        WoWKeybDB.debugApplyAssignments = self:GetChecked() and true or false
    end)

    panel.beginCreate = function(rawName)
        newProfileEdit:SetText(tostring(rawName or ""))
        local targetName = validateNewProfileNameFromInput()
        if not targetName then
            return
        end
        StaticPopup_Show("WOWKEYB_CREATE_PROFILE_MODE", targetName, nil, { targetName = targetName })
    end
    panel.duplicateProfile = function(name)
        if name and name ~= "" then
            selectedProfileName = name
            panel.userSelectedProfile = name
        end
        duplicateBtn:Click()
    end
    panel.renameProfile = function(name)
        if name and name ~= "" then
            selectedProfileName = name
            panel.userSelectedProfile = name
        end
        renameBtn:Click()
    end
    panel.deleteProfile = function(name)
        if name and name ~= "" then
            selectedProfileName = name
            panel.userSelectedProfile = name
        end
        deleteBtn:Click()
    end
    panel.resetProfile = function(name)
        if name and name ~= "" then
            selectedProfileName = name
            panel.userSelectedProfile = name
        end
        resetBtn:Click()
    end

    local legacySettingsWidgets = {
        importBtn,
        browseBtn,
        profileLabel,
        profileDropdown,
        profileStatusText,
        newProfileLabel,
        newProfileEdit,
        createBtn,
        duplicateBtn,
        selectedViewerBtn,
        exportBtn,
        renameBtn,
        deleteBtn,
        resetBtn,
        applyBtn,
        helpText,
    }
    for _, widget in ipairs(legacySettingsWidgets) do
        if widget and widget.Hide then
            widget:Hide()
        end
    end
    applyLogCheckbox:ClearAllPoints()
    applyLogCheckbox:SetPoint("TOPLEFT", currentProfileText, "BOTTOMLEFT", -2, -18)

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
                if mouseButton == "RightButton" then
                    WoWKeyb:Open("settings")
                    return
                end
                WoWKeyb:Open("map")
            end,
            OnTooltipShow = function(tooltip)
                tooltip:AddLine("WoWKeyb")
                tooltip:AddLine("Left-click: Keybind map", 0.8, 0.8, 0.8)
                tooltip:AddLine("Right-click: Profiles", 0.8, 0.8, 0.8)
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
            local list = listStoredProfiles(false)
            if #list > 0 then
                print("|cff00ff00[WoWKeyb]|r Stored profiles: " .. table.concat(list, ", "))
            else
                print("|cff00ff00[WoWKeyb]|r No stored profiles yet. Use /wowkeyb import <profile name> to paste a share code first.")
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

    elseif cmd == "list" or cmd == "l" or cmd == "profiles" or cmd == "browse" or cmd == "p" then
        WoWKeyb:ShowProfileBrowser()
        return

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

    elseif cmd == "applylog" or cmd == "al" then
        if arg == "on" then
            WoWKeybDB.debugApplyAssignments = true
            print("|cff00ff00[WoWKeyb]|r Apply assignment chat logs enabled.")
        elseif arg == "off" then
            WoWKeybDB.debugApplyAssignments = false
            print("|cff00ff00[WoWKeyb]|r Apply assignment chat logs disabled.")
        else
            print("|cff00ff00[WoWKeyb]|r Apply assignment chat logs are "
                .. tostring(WoWKeybDB.debugApplyAssignments == true and "ON" or "OFF")
                .. ". Use /wowkeyb applylog on|off")
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

    elseif cmd == "share" or cmd == "sh" then
        local targetPlayer, profileArg = arg:match("^(%S+)%s*(.*)$")
        if not targetPlayer or targetPlayer == "" then
            print("|cff00ff00[WoWKeyb]|r Usage: /wowkeyb share <player> [profile name]")
            return
        end
        local targetProfile = profileArg and profileArg:trim() or ""
        if targetProfile == "" then
            targetProfile = WoWKeybDB.currentProfile
        end
        if not targetProfile or targetProfile == "" then
            print("|cffff0000[WoWKeyb]|r No profile selected to share.")
            return
        end
        if targetProfile == BLIZZARD_DEFAULT_PROFILE then
            print("|cffff0000[WoWKeyb]|r Blizzard Default cannot be shared.")
            return
        end
        local profile = getStoredProfile(targetProfile)
        if not profile then
            print("|cffff0000[WoWKeyb]|r Profile not found: " .. tostring(targetProfile))
            return
        end

        -- Only sync from live game state when sharing the active profile.
        if canRefreshViewerFromGame(targetProfile) then
            syncProfileSnapshotFromGame(targetProfile)
        end

        local json, err = serializeSyncedProfile(targetProfile, profile)
        if not json then
            print("|cffff0000[WoWKeyb]|r Failed to build shared payload: " .. tostring(err or "unknown error"))
            return
        end
        local shareCode = encodeProfileShareCode(json)
        local okShare, shareMsg = sendProfileShareWhisper(targetPlayer, targetProfile, shareCode)
        if okShare then
            print("|cff00ff00[WoWKeyb]|r " .. tostring(shareMsg))
        else
            print("|cffff0000[WoWKeyb]|r Share failed: " .. tostring(shareMsg or "unknown error"))
        end
        return

    elseif cmd == "shareaccept" or cmd == "sa" then
        if arg == "" then
            print("|cff00ff00[WoWKeyb]|r Usage: /wowkeyb shareaccept <token>")
            return
        end
        promptImportSharedToken(arg)
        return

    elseif cmd == "view" or cmd == "v" or cmd == "keyboard" or cmd == "k" or cmd == "" then
        if arg == "" or arg == "live" then
            WoWKeyb:ShowKeybindingViewer(nil)
            return
        end
        if arg == BLIZZARD_DEFAULT_PROFILE then
            WoWKeyb:ShowKeybindingViewer(nil)
            return
        end
        if not getStoredProfile(arg) then
            print("|cffff0000[WoWKeyb]|r Profile not found: " .. tostring(arg))
            return
        end
        WoWKeyb:ShowKeybindingViewer(arg)
        return

    elseif cmd == "help" or cmd == "h" or cmd == "?" then
        print("|cff00ff00[WoWKeyb]|r Commands:")
        print("  /wowkeyb              - Open the in-game keybind keyboard")
        print("  /wowkeyb view [name]  - Open live binds, or a stored profile map")
        print("  /wowkeyb apply <name>  - Apply a stored profile")
        print("  /wowkeyb switch <name> - Switch to a profile (alias for apply)")
        print("  /wowkeyb toggle       - Toggle between last two profiles")
        print("  /wowkeyb import <name> - Import profile from profile code")
        print("  /wowkeyb profiles     - Browse imported profiles")
        print("  /wowkeyb export [name] - Export selected profile as share code string")
        print("  /wowkeyb share <player> [name] - Whisper a profile to another WoWKeyb user")
        print("  /wowkeyb options      - Open the profiles page")
        return

    else
        print("|cff00ff00[WoWKeyb]|r Commands:")
        print("  /wowkeyb apply <name>  - Apply a stored profile")
        print("  /wowkeyb switch <name> - Switch to a profile (alias for apply)")
        print("  /wowkeyb toggle       - Toggle between last two profiles")
        print("  /wowkeyb import <name> - Import profile from profile code")
        print("  /wowkeyb profiles     - Browse imported profiles")
        print("  /wowkeyb export [name] - Export selected profile as share code string")
        print("  /wowkeyb share <player> [name] - Whisper a profile to another WoWKeyb user")
        print("  /wowkeyb view [name]   - Open read-only keybinding map viewer")
        print("  /wowkeyb listall      - List all profiles (ignore class/spec filter)")
        print("  /wowkeyb mismatches   - List non-matching profiles and reasons")
        print("  /wowkeyb contexts     - List profile class/spec/hero contexts")
        print("  /wowkeyb preferred    - Show preferred profile mapping by context")
        print("  /wowkeyb debugmatch [name] - Print class/spec/hero match diagnostics")
        print("  /wowkeyb slotdebug on|off - Toggle apply slot debug logs")
        print("  /wowkeyb applylog on|off - Toggle per-slot apply assignment logs")
        print("  /wowkeyb viewerdebug on|off - Toggle viewer slot debug logs")
        print("  /wowkeyb labels       - Print class/spec/hero ID+label collection")
        print("  /wowkeyb delete <name> - Delete a stored profile")
        print("  /wowkeyb options      - Open the profiles page")
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
        importFrame:SetClampedToScreen(true)
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
    importFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    importFrame:SetFrameLevel(240)
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
        local function unescapeJsonString(raw)
            if raw == nil or raw == "" then return raw or "" end
            local out = raw
            -- Decode common JSON escapes first.
            out = out:gsub("\\n", "\n")
            out = out:gsub("\\r", "\r")
            out = out:gsub("\\t", "\t")
            out = out:gsub("\\b", "\b")
            out = out:gsub("\\f", "\f")
            out = out:gsub("\\/", "/")
            -- Decode escaped quote/slash last.
            out = out:gsub('\\"', '"')
            out = out:gsub("\\\\", "\\")
            return out
        end
        while pos <= #str do
            local ch = str:sub(pos, pos)
            if ch == '\\' then pos = pos + 2
            elseif ch == '"' then
                local s = unescapeJsonString(str:sub(start, pos - 1))
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

local function ensureShareLinkHook()
    if WoWKeyb.shareLinkHookInstalled then
        return
    end
    local previousSetItemRef = SetItemRef
    SetItemRef = function(link, text, button, chatFrame, ...)
        if type(link) == "string" and link:sub(1, 13) == "wowkeybshare:" then
            local token = link:sub(14)
            promptImportSharedToken(token)
            return
        end
        if previousSetItemRef then
            return previousSetItemRef(link, text, button, chatFrame, ...)
        end
    end
    WoWKeyb.shareLinkHookInstalled = true
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
            restoreCurrentProfileForCharacter()
            createSettingsPanel()
            createMinimapButton()
            ensureShareLinkHook()
            if C_ChatInfo and type(C_ChatInfo.RegisterAddonMessagePrefix) == "function" then
                C_ChatInfo.RegisterAddonMessagePrefix(ADDON_SHARE_PREFIX)
            end

            local shareFrame = CreateFrame("Frame")
            shareFrame:RegisterEvent("CHAT_MSG_ADDON")
            shareFrame:SetScript("OnEvent", function(_, _, prefix, message, _, sender)
                if prefix ~= ADDON_SHARE_PREFIX then
                    return
                end
                handleIncomingShareAddonMessage(message, sender)
            end)

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

print("|cff00ff00[WoWKeyb]|r Loaded. Type /wowkeyb to open the keyboard, or /wowkeyb help.")
