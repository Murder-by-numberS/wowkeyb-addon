--[[
    WoWKeyb Addon
    Apply keybinding profiles from WoWKeyb (wowkeyb.gg)
    Usage: /wowkeyb or /wk
]]

local addonName, WoWKeyb = ...
WoWKeyb.addonName = addonName

-- Default saved variables
WoWKeybDB = WoWKeybDB or {
    profiles = {},
    lastApplied = nil,
    currentProfile = nil,   -- Last profile applied (for toggle)
    previousProfile = nil,  -- Profile before current (for toggle)
}
WoWKeybDB.minimap = WoWKeybDB.minimap or {
    hide = false,
    angle = 225,
}

-- WoW uses hyphen for modifiers (SHIFT-1), WoWKeyb uses plus (SHIFT+1)
local function toWoWKeyFormat(key)
    if not key or key == "" then return nil end
    return key:gsub("%+", "-"):upper()
end

-- Normalize key for grouping (multiple spells can share a key - we use first only)
local function normalizeKey(key)
    if not key then return nil end
    return key:gsub("%+", "-"):upper()
end

-- Action bar slot ID to WoW binding command (default UI)
local SLOT_COMMANDS = {}
for i = 1, 12 do SLOT_COMMANDS[i] = "ACTIONBUTTON" .. i end
for i = 1, 12 do SLOT_COMMANDS[12 + i] = "MULTIACTIONBAR1BUTTON" .. i end
for i = 1, 12 do SLOT_COMMANDS[24 + i] = "MULTIACTIONBAR2BUTTON" .. i end
for i = 1, 12 do SLOT_COMMANDS[36 + i] = "MULTIACTIONBAR3BUTTON" .. i end
for i = 1, 12 do SLOT_COMMANDS[48 + i] = "MULTIACTIONBAR4BUTTON" .. i end

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

-- Frames created by WoWKeyb for custom layout (cleared on each apply)
local WoWKeybCustomFrames = {}

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
end

-- Apply profile using custom layout (SecureActionButton frames at saved positions)
local function applyProfileWithLayout(profile)
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
    local slotSize = 36
    local gap = 4

    for barIdx, bar in ipairs(layout.bars) do
        local pos = bar.position or {}
        local px = pos.x or (screenW / 2)
        local py = pos.y or (screenH - 50)
        local orient = bar.orientation or "horizontal"
        local numSlots = bar.slots or 12

        -- Convert design pixels to WoW coords (origin bottom-left)
        local offsetX = (px - screenW / 2) * scaleX
        local offsetY = (screenH / 2 - py) * scaleY

        local barWidth, barHeight
        if orient == "vertical" then
            barWidth = slotSize + gap
            barHeight = numSlots * (slotSize + gap) - gap
        else
            barWidth = numSlots * (slotSize + gap) - gap
            barHeight = slotSize + gap
        end

        local container = CreateFrame("Frame", "WoWKeybBar" .. barIdx, UIParent)
        container:SetSize(barWidth, barHeight)
        container:SetPoint("CENTER", UIParent, "CENTER", offsetX, offsetY)
        container:SetFrameStrata("MEDIUM")
        container:SetFrameLevel(10)
        table.insert(WoWKeybCustomFrames, container)

        local slots = barKeybinds[bar.id] or {}

        for slotIdx = 0, numSlots - 1 do
            local slotData = slots[slotIdx]
            local btnName = "WoWKeybBtn" .. barIdx .. "_" .. slotIdx

            local btn = CreateFrame("Button", btnName, container, "SecureActionButtonTemplate")
            btn:SetSize(slotSize, slotSize)
            btn:SetFrameStrata("MEDIUM")
            btn:SetFrameLevel(20)

            if orient == "vertical" then
                btn:SetPoint("TOP", container, "TOP", 0, -slotIdx * (slotSize + gap))
            else
                btn:SetPoint("LEFT", container, "LEFT", slotIdx * (slotSize + gap), 0)
            end

            -- Style the button (border + optional spell icon)
            btn:SetNormalTexture("Interface\\Buttons\\UI-Quickslot2")
            btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
            btn:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")

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

    return true, string.format("Applied %d keybindings (custom layout)", applied)
end

-- Convert WoWKeyb profile to WoW action bars + keybindings
-- Uses custom layout (SecureActionButton) if profile has layout, else default WoW UI
local function applyProfile(profile)
    if not profile or not profile.keybinds or #profile.keybinds == 0 then
        return false, "No keybinds in profile"
    end

    if InCombatLockdown() then
        return false, "Cannot apply keybindings while in combat"
    end

    -- Use custom layout when profile has layout with bars
    if profile.layout and profile.layout.bars and #profile.layout.bars > 0 then
        local ok, result = applyProfileWithLayout(profile)
        if ok then
            local profileName = profile.name or "Unknown"
            WoWKeybDB.lastApplied = { name = profileName, applied = 0, skipped = 0, time = time() }
            if WoWKeybDB.currentProfile ~= profileName then
                WoWKeybDB.previousProfile = WoWKeybDB.currentProfile
                WoWKeybDB.currentProfile = profileName
            end
        end
        return ok, result
    end

    -- Default mode: clear any previous custom layout frames
    clearCustomLayoutFrames()

    local PickupSpell = C_Spell and C_Spell.PickupSpell or _G.PickupSpell
    local GetSpellInfo = C_Spell and C_Spell.GetSpellName or _G.GetSpellInfo

    -- Group by key (WoW allows one binding per key; use first spell if multiple)
    local keyToSpell = {}
    for _, keybind in ipairs(profile.keybinds) do
        if keybind.key and keybind.spell and (keybind.spell.spellId or keybind.spell.name) then
            local nk = normalizeKey(keybind.key)
            if not keyToSpell[nk] then
                keyToSpell[nk] = keybind.spell
            end
        end
    end

    -- Assign slots for keys not in KEY_TO_SLOT (letters, etc.)
    -- Sort keys for deterministic slot assignment
    local sortedKeys = {}
    for k in pairs(keyToSpell) do sortedKeys[#sortedKeys + 1] = k end
    table.sort(sortedKeys)

    local nextExtraSlot = 49
    local keyToSlotMap = {}
    for _, wowKey in ipairs(sortedKeys) do
        local slot = KEY_TO_SLOT[wowKey]
        if not slot and nextExtraSlot <= 60 then
            slot = nextExtraSlot
            nextExtraSlot = nextExtraSlot + 1
        end
        keyToSlotMap[wowKey] = slot
    end

    local applied = 0
    local skipped = 0

    for _, wowKey in ipairs(sortedKeys) do
        local spell = keyToSpell[wowKey]
        local slot = keyToSlotMap[wowKey]
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
                -- 1. Place spell on action bar (default WoW UI)
                pcall(function()
                    if spellId then
                        PickupSpell(spellId)
                    else
                        PickupSpell(spellName)
                    end
                end)
                if GetCursorInfo() then
                    PlaceAction(slot)
                    ClearCursor()
                end

                -- 2. Bind key to action bar slot
                local command = SLOT_COMMANDS[slot]
                if command then
                    local ok = SetBinding(wowKey, command)
                    if ok then applied = applied + 1 else skipped = skipped + 1 end
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

    return true, string.format("Applied %d keybindings (%d skipped)", applied, skipped)
end

-- Toggle between current and previous profile
local function toggleProfile()
    if not WoWKeybDB.previousProfile then
        return false, "No previous profile to toggle to. Apply at least two different profiles first."
    end
    local target = WoWKeybDB.previousProfile
    local profile = getStoredProfile(target)
    if not profile then
        return false, "Previous profile not found: " .. tostring(target)
    end
    local ok, result = applyProfile(profile)
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
local function getStoredProfile(profileName)
    return WoWKeybDB.profiles[profileName or ""]
end

-- List stored profiles
local function listStoredProfiles()
    local list = {}
    for name, _ in pairs(WoWKeybDB.profiles) do
        table.insert(list, name)
    end
    table.sort(list)
    return list
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

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("WoWKeyb")

    local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    subtitle:SetText("Import and apply your WoWKeyb profiles.")

    local currentProfileText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    currentProfileText:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -18)
    currentProfileText:SetText("Current profile: None")

    local function refreshCurrentProfileText()
        currentProfileText:SetText("Current profile: " .. tostring(WoWKeybDB.currentProfile or "None"))
    end
    panel.refreshCurrentProfileText = refreshCurrentProfileText
    refreshCurrentProfileText()

    local importBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    importBtn:SetSize(180, 24)
    importBtn:SetPoint("TOPLEFT", currentProfileText, "BOTTOMLEFT", 0, -14)
    importBtn:SetText("Import Profile JSON")
    importBtn:SetScript("OnClick", function()
        WoWKeyb:ShowImportDialog("ImportedProfile")
    end)

    local listBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    listBtn:SetSize(180, 24)
    listBtn:SetPoint("TOPLEFT", importBtn, "BOTTOMLEFT", 0, -8)
    listBtn:SetText("List Profiles")
    listBtn:SetScript("OnClick", function()
        local list = listStoredProfiles()
        if #list == 0 then
            print("|cff00ff00[WoWKeyb]|r No stored profiles.")
        else
            print("|cff00ff00[WoWKeyb]|r Stored profiles: " .. table.concat(list, ", "))
        end
    end)

    local applyBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    applyBtn:SetSize(180, 24)
    applyBtn:SetPoint("TOPLEFT", listBtn, "BOTTOMLEFT", 0, -8)
    applyBtn:SetText("Apply Current Profile")
    applyBtn:SetScript("OnClick", function()
        local current = WoWKeybDB.currentProfile
        if not current then
            print("|cffff0000[WoWKeyb]|r No current profile. Import/apply one first.")
            return
        end
        local profile = getStoredProfile(current)
        if not profile then
            print("|cffff0000[WoWKeyb]|r Current profile not found in storage.")
            return
        end
        local ok, result = applyProfile(profile)
        if ok then
            print("|cff00ff00[WoWKeyb]|r " .. result)
        else
            print("|cffff0000[WoWKeyb]|r " .. tostring(result or "Failed to apply"))
        end
        refreshCurrentProfileText()
    end)

    local helpText = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    helpText:SetPoint("TOPLEFT", applyBtn, "BOTTOMLEFT", 0, -14)
    helpText:SetWidth(520)
    helpText:SetJustifyH("LEFT")
    helpText:SetText("Tip: You can also use slash commands: /wowkeyb import <name>, /wowkeyb apply <name>, /wowkeyb list")

    WoWKeyb.optionsPanel = panel

    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name, panel.name)
        Settings.RegisterAddOnCategory(category)
        WoWKeyb.settingsCategoryID = category:GetID()
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

local function updateMinimapButtonPosition()
    if not WoWKeyb.minimapButton then return end
    local angle = WoWKeybDB.minimap and WoWKeybDB.minimap.angle or 225
    local radians = math.rad(angle)
    local radius = 80
    local x = math.cos(radians) * radius
    local y = math.sin(radians) * radius
    WoWKeyb.minimapButton:ClearAllPoints()
    WoWKeyb.minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function safeAtan2(y, x)
    if math.atan2 then
        return math.atan2(y, x)
    end
    if x > 0 then return math.atan(y / x) end
    if x < 0 and y >= 0 then return math.atan(y / x) + math.pi end
    if x < 0 and y < 0 then return math.atan(y / x) - math.pi end
    if x == 0 and y > 0 then return math.pi / 2 end
    if x == 0 and y < 0 then return -math.pi / 2 end
    return 0
end

local function createMinimapButton()
    if WoWKeyb.minimapButton or not Minimap then return end

    local btn = CreateFrame("Button", "WoWKeybMinimapButton", Minimap)
    btn:SetSize(32, 32)
    btn:SetFrameStrata("MEDIUM")
    btn:SetMovable(true)
    btn:EnableMouse(true)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("RightButton")

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\ICONS\\INV_Misc_Book_09")
    btn.icon = icon

    local overlay = btn:CreateTexture(nil, "OVERLAY")
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetSize(54, 54)
    overlay:SetPoint("TOPLEFT")
    btn.overlay = overlay

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("WoWKeyb")
        GameTooltip:AddLine("Left-click: Open settings", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Right-drag: Move icon", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    btn:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "LeftButton" then
            openAddonSettings()
        end
    end)

    btn:SetScript("OnDragStart", function(self)
        self.isDragging = true
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local scale = UIParent:GetScale()
            px = px / scale
            py = py / scale
            local angle = math.deg(safeAtan2(py - my, px - mx))
            if angle < 0 then angle = angle + 360 end
            WoWKeybDB.minimap.angle = angle
            updateMinimapButtonPosition()
        end)
    end)
    btn:SetScript("OnDragStop", function(self)
        self.isDragging = false
        self:SetScript("OnUpdate", nil)
    end)

    WoWKeyb.minimapButton = btn
    updateMinimapButtonPosition()

    if WoWKeybDB.minimap and WoWKeybDB.minimap.hide then
        btn:Hide()
    else
        btn:Show()
    end
end

-- Slash command handler
local function slashHandler(msg)
    msg = msg and msg:trim() or ""
    local cmd, arg = msg:match("^(%S+)%s*(.*)$")
    cmd = (cmd or msg):lower()
    arg = arg and arg:trim() or ""

    if cmd == "apply" or cmd == "a" then
        if arg == "" then
            print("|cff00ff00[WoWKeyb]|r Usage: /wowkeyb apply <profile name>")
            local list = listStoredProfiles()
            if #list > 0 then
                print("|cff00ff00[WoWKeyb]|r Stored profiles: " .. table.concat(list, ", "))
            else
                print("|cff00ff00[WoWKeyb]|r No stored profiles. Use /wowkeyb import <profile name> to paste JSON first.")
            end
            return
        end
        local profile = getStoredProfile(arg)
        if not profile then
            print("|cffff0000[WoWKeyb]|r Profile not found: " .. arg)
            return
        end
        local ok, result = applyProfile(profile)
        if ok then
            print("|cff00ff00[WoWKeyb]|r " .. result)
        else
            print("|cffff0000[WoWKeyb]|r " .. (result or "Failed to apply"))
        end

    elseif cmd == "import" or cmd == "i" then
        if arg == "" then
            print("|cff00ff00[WoWKeyb]|r Usage: /wowkeyb import <profile name>")
            print("|cff00ff00[WoWKeyb]|r Then paste the JSON profile in the next edit box.")
            return
        end
        -- Open a frame for paste - we'll use a simple editbox
        WoWKeyb:ShowImportDialog(arg)
        return

    elseif cmd == "list" or cmd == "l" then
        local list = listStoredProfiles()
        if #list == 0 then
            print("|cff00ff00[WoWKeyb]|r No stored profiles.")
        else
            print("|cff00ff00[WoWKeyb]|r Stored profiles: " .. table.concat(list, ", "))
        end

    elseif cmd == "delete" or cmd == "d" then
        if arg == "" then
            print("|cff00ff00[WoWKeyb]|r Usage: /wowkeyb delete <profile name>")
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
        local profile = getStoredProfile(arg)
        if not profile then
            print("|cffff0000[WoWKeyb]|r Profile not found: " .. arg)
            return
        end
        local ok, result = applyProfile(profile)
        if ok then
            print("|cff00ff00[WoWKeyb]|r " .. result)
        else
            print("|cffff0000[WoWKeyb]|r " .. (result or "Failed to apply"))
        end

    elseif cmd == "options" or cmd == "o" then
        openAddonSettings()
        return

    else
        print("|cff00ff00[WoWKeyb]|r Commands:")
        print("  /wowkeyb apply <name>  - Apply a stored profile")
        print("  /wowkeyb switch <name> - Switch to a profile (alias for apply)")
        print("  /wowkeyb toggle       - Toggle between last two profiles")
        print("  /wowkeyb import <name> - Import profile from JSON (paste in dialog)")
        print("  /wowkeyb list         - List stored profiles")
        print("  /wowkeyb delete <name> - Delete a stored profile")
        print("  /wowkeyb options      - Open WoWKeyb AddOn settings")
    end
end

-- Import dialog: simple scrollable edit box for pasting JSON
local importFrame
function WoWKeyb:ShowImportDialog(profileName)
    if importFrame and importFrame:IsShown() then
        importFrame:Hide()
        return
    end

    if not importFrame then
        importFrame = CreateFrame("Frame", "WoWKeybImportFrame", UIParent)
        importFrame:SetSize(500, 400)
        importFrame:SetPoint("CENTER")
        importFrame:SetFrameStrata("DIALOG")
        importFrame:SetFrameLevel(100)
        importFrame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 }
        })
        importFrame:SetMovable(true)
        importFrame:EnableMouse(true)
        importFrame:RegisterForDrag("LeftButton")

        local title = importFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOP", 0, -20)
        title:SetText("WoWKeyb - Paste Profile JSON")

        local scroll = CreateFrame("ScrollFrame", "WoWKeybImportScroll", importFrame, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 20, -50)
        scroll:SetPoint("BOTTOMRIGHT", -40, 60)

        local edit = CreateFrame("EditBox", "WoWKeybImportEdit", scroll)
        edit:SetSize(400, 300)
        edit:SetMultiLine(true)
        edit:SetAutoFocus(false)
        edit:SetFontObject("GameFontHighlight")
        edit:SetScript("OnEscape", function() importFrame:Hide() end)
        scroll:SetScrollChild(edit)

        local closeBtn = CreateFrame("Button", nil, importFrame, "UIPanelButtonTemplate")
        closeBtn:SetSize(120, 22)
        closeBtn:SetPoint("BOTTOM", importFrame, "BOTTOM", 60, 20)
        closeBtn:SetText("Import")
        closeBtn:SetScript("OnClick", function()
            local text = edit:GetText()
            if text and text:trim() ~= "" then
                local ok, decoded = pcall(function()
                    -- WoW doesn't have JSON built-in; use a simple parser for our format
                    return WoWKeyb:ParseWoWKeybJSON(text)
                end)
                if ok and decoded then
                    WoWKeybDB.profiles[importFrame.profileName] = decoded
                    print("|cff00ff00[WoWKeyb]|r Imported profile: " .. importFrame.profileName)
                    if WoWKeyb.optionsPanel and WoWKeyb.optionsPanel.refreshCurrentProfileText then
                        WoWKeyb.optionsPanel.refreshCurrentProfileText()
                    end
                    importFrame:Hide()
                else
                    print("|cffff0000[WoWKeyb]|r Invalid JSON. Please paste the exact export from WoWKeyb.")
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
    local function parseValue()
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
    local function parseObject()
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
    local function parseArray()
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
        end
    end)
end

print("|cff00ff00[WoWKeyb]|r Loaded. Type /wowkeyb for help.")
