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
    if WoWKeybDB.minimap.hide == nil then WoWKeybDB.minimap.hide = false end
    if WoWKeybDB.minimap.minimapPos == nil then
        WoWKeybDB.minimap.minimapPos = tonumber(WoWKeybDB.minimap.angle) or 225
    end
    WoWKeybDB.minimap.angle = nil
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
    normalized = normalized:gsub("CONTROL%-", "CTRL-")
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

    local function matchesAnyProfileVariant(profileValue, candidates)
        if not profileValue then return true end
        if type(candidates) ~= "table" or #candidates == 0 then
            -- Fail open when runtime data is unavailable to avoid hiding valid profiles.
            return true
        end

        local pv = normalizeClassName(profileValue)
        if not pv then return true end
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
            appendDebug("runtime candidates are numeric-only; skipping strict text match for value=" .. tostring(profileValue))
            return true
        end
        for _, candidate in ipairs(candidates) do
            local cv = normalizeClassName(candidate)
            if cv and cv ~= "" then
                if pv == cv then return true end
                -- Handle format drift like "holypaladin" vs "holy", or token variants.
                if pv:find(cv, 1, true) or cv:find(pv, 1, true) then
                    return true
                end
            end
        end
        return false
    end

    local profileSpec = normalizeClassName(profile.spec)
    if profileSpec then
        local currentSpecVariants = labelCollection.spec.variants
        appendDebug("profile.spec=" .. tostring(profile.spec))
        appendDebug("current spec ids=" .. table.concat(labelCollection.spec.ids, ", "))
        appendDebug("current spec names=" .. table.concat(labelCollection.spec.names, ", "))
        appendDebug("current spec variants=" .. table.concat(currentSpecVariants, ", "))

        if not matchesAnyProfileVariant(profileSpec, currentSpecVariants) then
            appendDebug("spec match result=false")
            if debug then
                print("|cffffcc00[WoWKeyb]|r [match-debug:" .. tostring(debugLabel) .. "] " .. table.concat(debugLines, " | "))
            end
            return false
        end
        appendDebug("spec match result=true")
    end

    local profileHeroTalent = normalizeClassName(profile.heroTalent)
    if profileHeroTalent then
        local heroVariants = labelCollection.hero.variants
        appendDebug("profile.heroTalent=" .. tostring(profile.heroTalent))
        appendDebug("current hero ids=" .. table.concat(labelCollection.hero.ids, ", "))
        appendDebug("current hero names=" .. table.concat(labelCollection.hero.names, ", "))
        appendDebug("current hero variants=" .. table.concat(heroVariants, ", "))

        if not matchesAnyProfileVariant(profileHeroTalent, heroVariants) then
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
            if bar and bar.id then
                byId[bar.id] = idx - 1 -- zero-based bar index to match slot math
            end
        end
    end
    return byId
end

local function resolvePreferredSlot(profile, keybind, wowKey, layoutBarIndexById)
    local hasLayout = profile and profile.layout and profile.layout.bars and #profile.layout.bars > 0

    -- 1) Explicit barId + slotIndex from web app
    if keybind and keybind.barId and (keybind.slotIndex or keybind.slot_index) ~= nil then
        local barIdx = layoutBarIndexById[keybind.barId]
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
                if bar and type(bar.slotKeys) == "table" and wowKey and wowKey ~= "" then
                    for _, candidate in ipairs(candidates) do
                        local slotKey = normalizeKey(bar.slotKeys[candidate + 1] or "")
                        if slotKey == wowKey then
                            return (barIdx * 12) + candidate + 1
                        end
                    end
                end

                -- Fall back to first valid candidate.
                local slot = (barIdx * 12) + candidates[1] + 1
                if slot >= 1 and slot <= 60 then
                    return slot
                end
            end
        end
    end

    -- 2) Fallback for legacy payloads: infer bar+slot by key grouping
    local layoutMap = KEY_TO_LAYOUT_SLOT[wowKey]
    if hasLayout and layoutMap and profile.layout.bars[layoutMap.barIndex + 1] then
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
    if not profileMatchesCurrentSpecAndHero(profile, "apply") then
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
            local slotKeys = bar and bar.slotKeys
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
            if keybind and keybind.spell and (keybind.spell.spellId or keybind.spell.name) then
                local nk = normalizeKey(keybind.key or "")
                local slot = resolvePreferredSlot(profile, keybind, nk, layoutBarIndexById)
                if (not slot) and nk and nk ~= "" and layoutKeyToSlots[nk] then
                    for _, candidate in ipairs(layoutKeyToSlots[nk]) do
                        if not slotToData[candidate] then
                            slot = candidate
                            break
                        end
                    end
                end
                if slot and not slotToData[slot] then
                    slotToData[slot] = {
                        spell = keybind.spell,
                        wowKey = nk,
                        slot = slot,
                    }
                end
            end
        end
        local sortedSlots = {}
        for slot in pairs(slotToData) do sortedSlots[#sortedSlots + 1] = slot end
        table.sort(sortedSlots)
        for _, slot in ipairs(sortedSlots) do
            entries[#entries + 1] = slotToData[slot]
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

    for _, entry in ipairs(entries) do
        local spell = entry.spell
        local slot = entry.slot
        local wowKey = entry.wowKey
        if not slot then
            skipped = skipped + 1
        else
            local spellId = tonumber(spell.spellId or spell.spell_id)
            local spellName = spell.name

            if spellId then
                local nameFromId = GetSpellInfo(spellId)
                if nameFromId then spellName = nameFromId end
            end

            if (not spellId and not spellName) or spellName == "" then
                skipped = skipped + 1
            else
                local actionSlot = toBlizzardActionSlot(slot)
                local keepMacro = actionSlotMacroContainsSpell(actionSlot, spellId, spellName, macroParseCache)

                -- 1. Place spell on action bar (default WoW UI)
                if not keepMacro then
                    local pickedUp = false
                    if spellId and type(PickupSpell) == "function" then
                        pcall(function()
                            PickupSpell(spellId)
                        end)
                        pickedUp = GetCursorInfo() ~= nil
                    end
                    if (not pickedUp) and spellName and spellName ~= "" and type(PickupSpell) == "function" then
                        if spellId then
                            PickupSpell(spellName)
                        else
                            PickupSpell(spellName)
                        end
                        pickedUp = GetCursorInfo() ~= nil
                    end

                    if pickedUp then
                        PlaceAction(actionSlot)
                        ClearCursor()
                    end
                end

                -- 2. Bind key to action bar slot
                local command = SLOT_COMMANDS[slot]
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
                        if ok then applied = applied + 1 else skipped = skipped + 1 end
                    else
                        skipped = skipped + 1
                    end
                else
                    skipped = skipped + 1
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

    for _, kb in ipairs(keybinds) do
        if kb and kb.spell and (kb.spell.spellId or kb.spell.spell_id or kb.spell.name) then
            local spell = kb.spell or {}
            local spellName = tostring(spell.name or "")
            local spellIcon = spell.icon
            local wowKey = normalizeKey(kb.key or "")
            local slot = resolvePreferredSlot(profile, kb, wowKey, layoutBarIndexById)

            if slot then
                slotData[slot] = slotData[slot] or {
                    key = tostring(kb.key or ""),
                    spellName = spellName ~= "" and spellName or "(no spell)",
                    icon = spellIcon,
                }
            end
        end
    end

    local bars = profile and profile.layout and profile.layout.bars or {}
    for barIdx = 1, 5 do
        local bar = bars[barIdx]
        local slotKeys = (bar and type(bar.slotKeys) == "table") and bar.slotKeys or {}
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
    cell.keyText:SetText(cleanKey)
    -- Bars should be icon/key focused; ability names are shown on hover in keyboard.
    cell.spellText:SetText("")
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
                cell.keyText:SetText("-")

                cell.spellText = cell:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                cell.spellText:SetPoint("BOTTOMLEFT", 2, 2)
                cell.spellText:SetPoint("BOTTOMRIGHT", -2, 2)
                cell.spellText:SetJustifyH("LEFT")
                cell.spellText:SetText("-")

                viewerFrame.barCells[barIdx][slotIdx] = cell
            end
        end

        local refreshBtn = CreateFrame("Button", nil, viewerFrame, "UIPanelButtonTemplate")
        refreshBtn:SetSize(120, 22)
        refreshBtn:SetPoint("BOTTOM", viewerFrame, "BOTTOM", 90, 18)
        refreshBtn:SetText("Refresh")
        refreshBtn:SetScript("OnClick", function()
            refreshViewerFrame(viewerFrame)
        end)

        local closeBtn = CreateFrame("Button", nil, viewerFrame, "UIPanelButtonTemplate")
        closeBtn:SetSize(120, 22)
        closeBtn:SetPoint("BOTTOM", viewerFrame, "BOTTOM", -90, 18)
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

    local function refreshProfileSelector()
        local profiles = listStoredProfiles(true)
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

        UIDropDownMenu_Initialize(profileDropdown, function(self, level)
            for _, name in ipairs(selectorOptions) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = name
                info.checked = (name == selectedProfileName)
                info.func = function()
                    selectedProfileName = name
                    UIDropDownMenu_SetText(profileDropdown, name)
                    panel.forceVisibleProfileName = nil
                    local ok, result = applySelectionByName(name)
                    if ok then
                        print("|cff00ff00[WoWKeyb]|r " .. result)
                    else
                        print("|cffff0000[WoWKeyb]|r " .. tostring(result or "Failed to apply"))
                    end
                    refreshCurrentProfileText()
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
        UIDropDownMenu_SetText(profileDropdown, selectedProfileName or BLIZZARD_DEFAULT_PROFILE)
    end
    panel.refreshProfileSelector = refreshProfileSelector
    refreshProfileSelector()

    local importBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    importBtn:SetSize(180, 24)
    importBtn:SetPoint("TOPLEFT", profileDropdown, "BOTTOMLEFT", 16, -10)
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

    local deleteBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    deleteBtn:SetSize(180, 24)
    deleteBtn:SetPoint("TOPLEFT", viewerBtn, "BOTTOMLEFT", 0, -8)
    deleteBtn:SetText("Delete Selected Profile")
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
    helpText:SetWidth(520)
    helpText:SetJustifyH("LEFT")
    helpText:SetText("Tip: Selecting a profile auto-applies it. Use /wowkeyb switch <name> to swap profiles, then move bars in WoW Edit Mode.")

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
        print("  /wowkeyb debugmatch [name] - Print class/spec/hero match diagnostics")
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

                    -- Persist the canonical storage key in the profile payload for consistency.
                    decoded.name = importedName
                    WoWKeybDB.profiles[importedName] = decoded

                    print("|cff00ff00[WoWKeyb]|r Imported profile: " .. importedName)

                    local classMatch = profileMatchesCurrentClass(decoded, "import")
                    local specHeroMatch = profileMatchesCurrentSpecAndHero(decoded, "import")
                    local canOfferApply = classMatch and specHeroMatch

                    if not canOfferApply then
                        if WoWKeyb.optionsPanel then
                            WoWKeyb.optionsPanel.forceVisibleProfileName = importedName
                        end
                        local mismatchReason = "class/spec/hero mismatch"
                        if not classMatch then
                            mismatchReason = "class mismatch"
                        elseif not specHeroMatch then
                            mismatchReason = "spec/hero mismatch"
                        end
                        print("|cffffcc00[WoWKeyb]|r Imported profile but did not apply (" .. mismatchReason .. ").")
                        print("|cffffcc00[WoWKeyb]|r Imported profile kept visible in selector for debugging. Run /wowkeyb debugmatch \"" .. tostring(importedName) .. "\"")
                    else
                        if WoWKeyb.optionsPanel then
                            WoWKeyb.optionsPanel.forceVisibleProfileName = nil
                        end
                        if not StaticPopupDialogs["WOWKEYB_IMPORT_APPLY_CONFIRM"] then
                            StaticPopupDialogs["WOWKEYB_IMPORT_APPLY_CONFIRM"] = {
                                text = "Apply imported profile \"%s\" now?",
                                button1 = "Apply",
                                button2 = "Not now",
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
                        StaticPopup_Show("WOWKEYB_IMPORT_APPLY_CONFIRM", importedName, nil, importedName)
                    end

                    if WoWKeyb.optionsPanel and WoWKeyb.optionsPanel.refreshCurrentProfileText then
                        WoWKeyb.optionsPanel.refreshCurrentProfileText()
                    end
                    if WoWKeyb.optionsPanel and WoWKeyb.optionsPanel.refreshProfileSelector then
                        WoWKeyb.optionsPanel.refreshProfileSelector()
                    end
                    importFrame:Hide()
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
        end
    end)
end

print("|cff00ff00[WoWKeyb]|r Loaded. Type /wowkeyb for help.")
