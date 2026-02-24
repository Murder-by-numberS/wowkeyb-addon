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

-- Convert WoWKeyb profile to WoW bindings
-- WoWKeyb format: { keybinds: [{ key: "1"|"SHIFT+1"|"E", spell: { spellId, name } }] }
local function applyProfile(profile)
    if not profile or not profile.keybinds or #profile.keybinds == 0 then
        return false, "No keybinds in profile"
    end

    if InCombatLockdown() then
        return false, "Cannot apply keybindings while in combat"
    end

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

    local applied = 0
    local skipped = 0

    for wowKey, spell in pairs(keyToSpell) do
        local spellId = tonumber(spell.spellId or spell.spell_id)
        local spellName = spell.name

        -- Prefer spell ID for accuracy; fallback to name
        if spellId then
            local nameFromId = GetSpellInfo(spellId)
            if nameFromId then
                spellName = nameFromId
            end
        end

        if not spellName or spellName == "" then
            skipped = skipped + 1
        else
            local ok = SetBindingSpell(wowKey, spellName)
            if ok then
                applied = applied + 1
            else
                skipped = skipped + 1
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

    else
        print("|cff00ff00[WoWKeyb]|r Commands:")
        print("  /wowkeyb apply <name>  - Apply a stored profile")
        print("  /wowkeyb switch <name> - Switch to a profile (alias for apply)")
        print("  /wowkeyb toggle       - Toggle between last two profiles")
        print("  /wowkeyb import <name> - Import profile from JSON (paste in dialog)")
        print("  /wowkeyb list         - List stored profiles")
        print("  /wowkeyb delete <name> - Delete a stored profile")
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

print("|cff00ff00[WoWKeyb]|r Loaded. Type /wowkeyb for help.")
