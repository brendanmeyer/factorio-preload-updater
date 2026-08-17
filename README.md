# Factorio Preload Updater

A PowerShell script that runs before Factorio: it checks your installed mods
against the [Mod Portal](https://mods.factorio.com), downloads any updates,
then launches Factorio (Steam or standalone).

## Requirements

- Windows with PowerShell 5.1+ (built in) or PowerShell 7.
- You must have logged into the Mod Portal at least once from Factorio's
  in-game "Mods" browser, so `player-data.json` has saved credentials. The
  script reuses those — it never asks for or stores a password itself.

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

## Configuration

A `config.json` is created next to the script on first run, with these
defaults:

```json
{
  "ModsPath": null,
  "FactorioExePath": null,
  "LaunchMode": "SteamProtocol",
  "SteamAppId": "427520"
}
```

- `ModsPath` / `FactorioExePath` — set these if auto-detection picks the
  wrong install (e.g. multiple Factorio copies, a non-standard Steam
  library, or a custom `--mod-directory`). `null` means auto-detect.
- `LaunchMode` — `SteamProtocol` (default, launches via `steam://rungameid`),
  `SteamExe` or `Standalone` (launch the resolved `factorio.exe` directly).
  Direct-exe launching is used automatically instead of `SteamProtocol`
  whenever you pass extra arguments, since the `steam://` protocol can't
  carry them.

## What it does and doesn't do

- Updates are simply the highest version published on the Mod Portal for
  each installed mod - Factorio version compatibility is not filtered on,
  since mods are generally usable across nearby game versions and requiring
  an exact match caused real updates to be missed.
- Downloaded zips are verified against the Mod Portal's published SHA1
  before being kept.
- Old mod zip versions are **left in place** — Factorio itself keeps
  multiple versions of a mod around (for save compatibility), so this
  script only ever adds a new zip, never deletes or unpacks one.
- Unpacked/dev mod folders (a folder with `info.json` instead of a zip)
  are never touched, only reported as skipped.
- If credentials are missing, the mod portal is unreachable, or the
  installed game version can't be determined, the update pass is skipped
  with a warning — Factorio still launches.
