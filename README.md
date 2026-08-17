# Factorio Preload Updater

A PowerShell script that runs before Factorio: it checks your installed mods
against the [Mod Portal](https://mods.factorio.com), downloads any updates,
then launches Factorio (Steam or standalone).

## Requirements

- Windows with PowerShell 5.1+ (built in) or PowerShell 7.
- You must have logged into the Mod Portal at least once from Factorio's
  in-game "Mods" browser, so `player-data.json` has saved credentials. The
  script reuses those, it never asks for or stores a password itself.

## Usage

```powershell
.\Update-FactorioMods.ps1
```

Check for updates without downloading or launching anything:

```powershell
.\Update-FactorioMods.ps1 -DryRun
```

Skip the mod-update pass and just launch:

```powershell
.\Update-FactorioMods.ps1 -SkipModUpdate
```

Download updates but don't launch Factorio:

```powershell
.\Update-FactorioMods.ps1 -NoLaunch
```

Forward extra arguments to Factorio itself (e.g. to join a server or load a save):

```powershell
.\Update-FactorioMods.ps1 -mp-connect 1.2.3.4
```

## Running automatically when you press Play in Steam

Steam's per-game "Launch Options" support a `%command%` placeholder: whatever
you put before it runs first, and `%command%` expands to Steam's own launch
command for the game (the real `factorio.exe` plus any args Steam adds), so
your wrapper stays in control while Steam still does the actual launch.

`Launch-Wrapper.bat` (included here) does exactly that: it runs the updater
with `-NoLaunch`, then executes `%*` (the command Steam passed it) to start
the real game.

To wire it up:

1. In Steam, right-click **Factorio** → **Properties** → **General**.
2. In **Launch Options**, enter:
   ```
   "C:\path\to\factorio-preload-updater\Launch-Wrapper.bat" %command%
   ```
   (use the actual path to where you cloned this repo).
3. Close the dialog. Pressing **Play** now runs the mod update pass first,
   then launches Factorio as normal.

A console window is shown while the update check runs. If there are no mod
updates, this only adds about a second before the game window appears;
actual downloads take longer, depending on mod size and connection speed.

**Automated option:** rather than typing the Launch Options in by hand, run:

```powershell
.\Set-FactorioSteamLaunchOptions.ps1
```

This edits Steam's own `localconfig.vdf` directly to set Factorio's Launch
Options to the wrapper string above. Steam keeps an in-memory copy of this
file while running and will silently overwrite an external edit, so the
script requires Steam to be fully closed first. If it's still running, the
script tells you to quit it and waits until it actually closes before making
any change. The file is backed up alongside itself as `localconfig.vdf.bak`
first. Add `-WhatIf` to preview the change without making it.

## Updating Desktop / Start Menu shortcuts

If you're using Steam and have the [Launch Options
wrapper](#running-automatically-when-you-press-play-in-steam) set up, this
section shouldn't be necessary. Steam runs the wrapper for any launch that
goes through Steam, whether that's the Play button or a shortcut pointing at
`steam://rungameid/427520`, so those shortcuts already trigger the update
pass without being changed.

This section only applies to shortcuts that launch `factorio.exe` directly,
bypassing Steam entirely (standalone installs, or a manually created
shortcut):

1. Right-click the shortcut → **Properties** → **Shortcut** tab.
2. Replace the **Target** field with:
   ```
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\path\to\factorio-preload-updater\Update-FactorioMods.ps1"
   ```
   (use the actual path to where you cloned this repo).
3. The icon will change to the generic PowerShell icon. To restore the
   Factorio icon, click **Change Icon...**, browse to the real
   `factorio.exe` (e.g. `...\Factorio\bin\x64\factorio.exe`), and pick it.
4. Click **OK**.

**Automated option:** rather than editing shortcuts by hand, run:

```powershell
.\Update-FactorioShortcuts.ps1
```

This scans your Desktop and Start Menu (both your own and, if writable, the
all-users locations) and repoints any `.lnk` shortcut targeting
`factorio.exe` directly at the updater script, keeping the original
Factorio icon. Steam `.url` shortcuts are left alone, since they go through
Steam and already work as described above.

Every shortcut it touches is backed up alongside itself as a `.bak` file
first. Nothing is deleted outright, so you can restore the original by
renaming the `.bak` back. Add `-WhatIf` to preview the changes without
making them.

## Configuration

A `config.json` is created next to the script on first run, with these
defaults:

```json
{
  "ModsPath": null,
  "FactorioExePath": null,
  "LaunchMode": "SteamProtocol",
  "SteamAppId": "427520",
  "OnlyUpdateEnabledMods": false
}
```

- `ModsPath` / `FactorioExePath`: set these if auto-detection picks the
  wrong install (e.g. multiple Factorio copies, a non-standard Steam
  library, or a custom `--mod-directory`). `null` means auto-detect.
- `LaunchMode`: `SteamProtocol` (default, launches via `steam://rungameid`),
  `SteamExe` or `Standalone` (launch the resolved `factorio.exe` directly).
  Direct-exe launching is used automatically instead of `SteamProtocol`
  whenever you pass extra arguments, since the `steam://` protocol can't
  carry them.
- `OnlyUpdateEnabledMods`: `false` (default) checks and updates every
  installed mod. Set to `true` to skip mods marked disabled in
  `mod-list.json`, so only mods you actually have enabled get checked
  against the Mod Portal.

## What it does and doesn't do

- Updates are simply the highest version published on the Mod Portal for
  each installed mod - Factorio version compatibility is not filtered on,
  since mods are generally usable across nearby game versions and requiring
  an exact match caused real updates to be missed.
- Downloaded zips are verified against the Mod Portal's published SHA1
  before being kept.
- Old mod zip versions are **left in place**. Factorio itself keeps
  multiple versions of a mod around (for save compatibility), so this
  script only ever adds a new zip, never deletes or unpacks one.
- Unpacked/dev mod folders (a folder with `info.json` instead of a zip)
  are never touched, only reported as skipped.
- If credentials are missing, the mod portal is unreachable, or the
  installed game version can't be determined, the update pass is skipped
  with a warning. Factorio still launches.
