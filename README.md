# WoWKeyb Addon

World of Warcraft addon for applying keybinding profiles from [WoWKeyb](https://wowkeyb.gg).

**Source:** [github.com/Murder-by-numberS/wowkeyb-addon](https://github.com/Murder-by-numberS/wowkeyb-addon)

## Installation

### Option A: Download from CurseForge (Recommended)

1. Download from [CurseForge](https://www.curseforge.com/wow/addons/wowkeyb) (or use WoWUp/CurseForge app)
2. The addon manager will install it automatically, or extract the zip to your AddOns folder

### Option B: Manual Install

1. Download or clone this repository
2. Copy the `WoWKeyb` folder to your WoW addons directory:
   - **Windows**: `World of Warcraft\_retail_\Interface\AddOns\WoWKeyb`
   - **Mac**: `World of Warcraft/_retail_/Interface/AddOns/WoWKeyb`
3. Restart WoW or enable the addon from the AddOns list at the character select screen

## Usage

### Export from WoWKeyb

1. Go to [WoWKeyb](https://wowkeyb.gg) and open a keybinding profile
2. Click **Export for Addon** – the profile JSON is copied to your clipboard

### Import in WoW

1. Log in to a character (must be out of combat)
2. Type: `/wowkeyb import YourProfileName` (e.g. `FrostMage`, `MyWarrior`)
3. Press Enter – an import dialog opens
4. Paste the JSON (Ctrl+V) and click **Import**

### Apply the Profile

1. Type: `/wowkeyb apply YourProfileName`
2. Your keybindings are applied and saved

### Commands

| Command | Description |
|---------|-------------|
| `/wowkeyb` or `/wk` | Show help |
| `/wowkeyb import <name>` | Import a profile from pasted JSON |
| `/wowkeyb apply <name>` | Apply a stored profile |
| `/wowkeyb switch <name>` | Switch to a profile (same as apply) |
| `/wowkeyb toggle` | **Toggle between last two profiles** – great for switching specs |
| `/wowkeyb list` | List stored profiles |
| `/wowkeyb delete <name>` | Delete a stored profile |

### Toggle Between Profiles

Use `/wowkeyb toggle` to switch between the last two profiles you applied. Example:

1. Apply your Frost Mage profile: `/wowkeyb apply FrostMage`
2. Apply your Fire Mage profile: `/wowkeyb apply FireMage`
3. Toggle back to Frost: `/wowkeyb toggle`
4. Toggle to Fire again: `/wowkeyb toggle`

You can bind a macro to toggle for quick spec switching:

```
/wowkeyb toggle
```

## Requirements

- World of Warcraft: Dragonflight (10.1.5) or later
- Must be out of combat to apply keybindings

## How It Works

The addon **places spells on action bars** and **binds keys to those slots** – using WoW's default action bar system. This means:

- **Spells appear on your action bars** (main bar, multi-bars)
- **Keys are bound to action bar slots** (1–12 = main bar, SHIFT+1–12 = bar 2, etc.)
- **Works with the default WoW UI** – no ElvUI or other addons required

**Slot mapping:**
- `1`–`12` → Main action bar (slots 1–12)
- `SHIFT+1`–`12` → Bar 2 (slots 13–24)
- `CTRL+1`–`12` → Bar 3 (slots 25–36)
- `ALT+1`–`12` → Bar 4 (slots 37–48)
- Letter keys (`E`, `R`, `Q`, etc.) → Bar 5 (slots 49–60)

If multiple spells share the same key in your profile, only the first one is used (WoW allows one binding per key).

## Related

- [WoWKeyb](https://wowkeyb.gg) – Create and share keybinding profiles in your browser
- [CurseForge](https://www.curseforge.com/wow/addons/wowkeyb) – Download the addon (once published)

---

## Publishing to CurseForge (For Maintainers)

### 0. Create the GitHub Repository

1. Go to [GitHub Organizations](https://github.com/orgs/Murder-by-numberS/repositories/new)
2. Create a new repository named **wowkeyb-addon**
3. Set visibility to **Public** (or Private if preferred)
4. Do **not** initialize with README (the repo already has one)
5. After creation, add the remote and push:

```bash
cd wowkeyb-addon
git init
git add -A
git commit -m "Initial commit: WoWKeyb addon v1.0.0"
git branch -M main
git remote add origin https://github.com/Murder-by-numberS/wowkeyb-addon.git
git push -u origin main
```

### 1. Create the CurseForge Project

1. Go to [CurseForge Authors](https://authors.curseforge.com/) and log in
2. Click **Create Project** → select **World of Warcraft**
3. Fill in: Name (WoWKeyb), summary, description, license (MIT), category (Combat)
4. Submit for review (usually approved within 24–48 hours)

### 2. Link the Repository

1. In your project's **Repository** settings, add: `https://github.com/Murder-by-numberS/wowkeyb-addon`
2. CurseForge will use the repo for automatic packaging

### 3. Automatic Packaging (Webhook)

1. Generate an API token at [CurseForge API Tokens](https://www.curseforge.com/account/api-tokens)
2. Add a webhook to your GitHub repo: **Settings → Webhooks → Add webhook**
3. Payload URL: `https://www.curseforge.com/api/projects/{projectID}/package?token={token}`
4. Replace `{projectID}` with your project ID (from the project's About section)
5. Push a tag (e.g. `v1.0.0`) to trigger a new release

### 4. Release Types

- Tag with `alpha` (e.g. `1.0.0-alpha`) → Alpha release
- Tag with `beta` (e.g. `1.0.0-beta`) → Beta release
- Tag without modifier (e.g. `v1.0.0`) → Release

The `pkgmeta.yaml` in this repo configures packaging. Update `CHANGELOG.md` before each release.
