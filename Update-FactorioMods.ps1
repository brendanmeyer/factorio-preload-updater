#Requires -Version 5.1
<#
Checks installed Factorio mods against the Mod Portal, downloads any updates
using the credentials Factorio already saved after an in-game login, then
launches Factorio (Steam or standalone).
#>

[CmdletBinding()]
param(
    [switch]$SkipModUpdate,
    [switch]$DryRun,
    [string]$ConfigPath,

    # Anything not bound to a named param above (e.g. -mp-connect 1.2.3.4)
    # falls in here and gets forwarded straight through to Factorio.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$FactorioArgs
)

$ErrorActionPreference = 'Stop'
# Some Windows machines still default to TLS 1.0, which mods.factorio.com rejects.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $ScriptDir 'config.json'
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

# Loads config.json next to the script, filling in any keys a user's file is
# missing (so old config files don't break when new options are added), and
# writes out a default file on first run.
function Get-ScriptConfig {
    param([string]$Path)

    $defaults = [ordered]@{
        ModsPath        = $null              # null = auto-detect %APPDATA%\Factorio\mods
        FactorioExePath = $null              # null = auto-detect (Steam, then standalone)
        LaunchMode      = 'SteamProtocol'    # SteamProtocol | SteamExe | Standalone
        SteamAppId      = '427520'           # Factorio's Steam app id
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        ($defaults | ConvertTo-Json) | Set-Content -LiteralPath $Path -Encoding UTF8
        return [PSCustomObject]$defaults
    }

    $loaded = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($key in $defaults.Keys) {
        if (-not (Get-Member -InputObject $loaded -Name $key -MemberType NoteProperty)) {
            $loaded | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key]
        }
    }
    return $loaded
}

# ---------------------------------------------------------------------------
# Discovery: user data dir, Factorio install, installed game version
# ---------------------------------------------------------------------------

# Factorio's per-user data (saves, mods, credentials) normally lives under
# %APPDATA%\Factorio regardless of whether the game itself is Steam or
# standalone. A user can redirect it via config-path.cfg, so we check that
# before falling back to the default.
function Get-FactorioUserDataPath {
    $default = Join-Path $env:APPDATA 'Factorio'

    $configPathCfg = Join-Path $default 'config-path.cfg'
    if (Test-Path -LiteralPath $configPathCfg) {
        $line = Get-Content -LiteralPath $configPathCfg | Where-Object { $_ -match '^\s*write-data\s*=\s*(.+)$' }
        if ($line) {
            $candidate = ($line -replace '^\s*write-data\s*=\s*', '').Trim()
            # __PATH__ placeholders (e.g. __PATH__executable__) need resolving
            # we don't attempt that here; just fall back to the default instead.
            if ($candidate -notmatch '__PATH__' -and (Test-Path -LiteralPath $candidate)) {
                return $candidate
            }
        }
    }

    return $default
}

# Finds a Steam install of Factorio by reading Steam's own registry key and
# library-folder list, since the game can live in any Steam library, not just
# the default one under the main Steam install.
function Find-SteamFactorioInstall {
    param([string]$AppId)

    $steamPath = $null
    try {
        $steamPath = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction Stop).SteamPath
    } catch {
        return $null
    }
    if (-not $steamPath) { return $null }
    $steamPath = $steamPath -replace '/', '\'

    $libraryPaths = [System.Collections.Generic.List[string]]::new()
    $libraryPaths.Add($steamPath)

    # libraryfolders.vdf lists every additional Steam library the user added.
    $vdfCandidates = @(
        (Join-Path $steamPath 'steamapps\libraryfolders.vdf'),
        (Join-Path $steamPath 'config\libraryfolders.vdf')
    )
    foreach ($vdf in $vdfCandidates) {
        if (Test-Path -LiteralPath $vdf) {
            $vdfMatches = Select-String -Path $vdf -Pattern '"path"\s*"([^"]+)"'
            foreach ($m in $vdfMatches) {
                $p = $m.Matches[0].Groups[1].Value -replace '\\\\', '\'
                if ($p -and (Test-Path -LiteralPath $p)) { $libraryPaths.Add($p) }
            }
        }
    }

    foreach ($lib in ($libraryPaths | Select-Object -Unique)) {
        $installRoot = Join-Path $lib "steamapps\common\Factorio"
        $exe = Join-Path $installRoot 'bin\x64\factorio.exe'
        if (Test-Path -LiteralPath $exe) {
            return [PSCustomObject]@{
                Source      = 'Steam'
                InstallRoot = $installRoot
                ExePath     = $exe
            }
        }
    }
    return $null
}

# Falls back to a standalone (non-Steam) install: common install locations
# first, then the Windows uninstall registry as a last resort.
function Find-StandaloneFactorioInstall {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Factorio\bin\x64\factorio.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Factorio\bin\x64\factorio.exe')
    )
    foreach ($exe in $candidates) {
        if ($exe -and (Test-Path -LiteralPath $exe)) {
            return [PSCustomObject]@{
                Source      = 'Standalone'
                InstallRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $exe))
                ExePath     = $exe
            }
        }
    }

    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($keyPath in $uninstallKeys) {
        $entries = Get-ItemProperty $keyPath -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'Factorio*' -and $_.InstallLocation }
        foreach ($entryItem in $entries) {
            $exe = Join-Path $entryItem.InstallLocation 'bin\x64\factorio.exe'
            if (Test-Path -LiteralPath $exe) {
                return [PSCustomObject]@{
                    Source      = 'Standalone'
                    InstallRoot = $entryItem.InstallLocation.TrimEnd('\')
                    ExePath     = $exe
                }
            }
        }
    }
    return $null
}

# Resolution order: explicit config override, then Steam, then standalone.
function Find-FactorioInstall {
    param($Config)

    if ($Config.FactorioExePath -and (Test-Path -LiteralPath $Config.FactorioExePath)) {
        $exe = $Config.FactorioExePath
        return [PSCustomObject]@{
            Source      = 'Configured'
            InstallRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $exe))
            ExePath     = $exe
        }
    }

    $steam = Find-SteamFactorioInstall -AppId $Config.SteamAppId
    if ($steam) { return $steam }

    $standalone = Find-StandaloneFactorioInstall
    if ($standalone) { return $standalone }

    return $null
}

# The installed game version (e.g. "1.1.110") comes from the bundled "base"
# mod's info.json, which every Factorio install ships. We only need the
# major.minor part of it to filter compatible mod releases later.
function Get-InstalledFactorioVersion {
    param([string]$InstallRoot)

    $infoPath = Join-Path $InstallRoot 'data\base\info.json'
    if (-not (Test-Path -LiteralPath $infoPath)) { return $null }
    $info = Get-Content -LiteralPath $infoPath -Raw | ConvertFrom-Json
    return $info.version
}

# ---------------------------------------------------------------------------
# Mod portal credentials + installed mods
# ---------------------------------------------------------------------------

# Factorio writes service-username/service-token into player-data.json the
# first time you log in from the in-game mods browser. Reusing them means
# this script never has to handle a password.
function Get-ModPortalCredentials {
    param([string]$UserDataPath)

    $playerDataPath = Join-Path $UserDataPath 'player-data.json'
    if (-not (Test-Path -LiteralPath $playerDataPath)) { return $null }

    $playerData = Get-Content -LiteralPath $playerDataPath -Raw | ConvertFrom-Json
    $username = $playerData.'service-username'
    $token = $playerData.'service-token'
    if (-not $username -or -not $token) { return $null }

    return [PSCustomObject]@{ Username = $username; Token = $token }
}

# Factorio mods on disk are either:
#   - a "{name}_{version}.zip" file (the normal case; Factorio reads mods
#     straight out of the zip, it never unpacks them), or
#   - an unpacked folder containing info.json (a dev mod / mod worked on
#     locally). Those are never touched here - only listed so the user knows
#     they were skipped.
# Factorio itself is fine with multiple versions of the same mod's zip
# sitting side by side (it keeps old ones around for save compatibility), so
# we group by mod name and track the newest version already on disk rather
# than assuming there's exactly one file per mod.
function Get-InstalledMods {
    param([string]$ModsPath)

    $byName = [ordered]@{}
    $unpacked = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-Path -LiteralPath $ModsPath)) {
        return [PSCustomObject]@{ Mods = $byName.Values; Unpacked = $unpacked }
    }

    Get-ChildItem -LiteralPath $ModsPath -Filter '*.zip' -File | ForEach-Object {
        if ($_.BaseName -match '^(?<name>.+)_(?<version>\d+\.\d+\.\d+)$') {
            $name = $Matches.name
            $version = $Matches.version
            if (-not $byName.Contains($name)) {
                $byName[$name] = [PSCustomObject]@{
                    Name           = $name
                    LatestVersion  = $version
                    InstalledPaths = [System.Collections.Generic.List[string]]::new()
                }
            }
            $byName[$name].InstalledPaths.Add($_.FullName)
            if ([version]$version -gt [version]$byName[$name].LatestVersion) {
                $byName[$name].LatestVersion = $version
            }
        }
    }

    Get-ChildItem -LiteralPath $ModsPath -Directory | ForEach-Object {
        if (Test-Path -LiteralPath (Join-Path $_.FullName 'info.json')) {
            $unpacked.Add($_.Name)
        }
    }

    return [PSCustomObject]@{ Mods = $byName.Values; Unpacked = $unpacked }
}

# ---------------------------------------------------------------------------
# Mod portal lookup + update
# ---------------------------------------------------------------------------

# Just take the highest-versioned release on the portal, regardless of its
# declared factorio_version - mods are generally usable across nearby game
# versions, and requiring an exact major.minor match caused real updates to
# be missed for mods whose author hadn't re-tagged for the newest game version yet.
function Get-LatestRelease {
    param([string]$ModName)

    try {
        $mod = Invoke-RestMethod -Uri "https://mods.factorio.com/api/mods/$ModName" -Method Get
    } catch {
        Write-Warning "  Could not look up '$ModName' on the mod portal: $($_.Exception.Message)"
        return $null
    }

    if (-not $mod.releases) { return $null }

    return $mod.releases | Sort-Object { [version]$_.version } -Descending | Select-Object -First 1
}

# Downloads one mod release and adds it to the mods folder. The existing
# zip(s) for this mod are deliberately left in place - Factorio keeps old
# versions around itself, and other saves/mod-list entries may still pin an
# older version.
function Update-Mod {
    param(
        [string]$ModsPath,
        [string]$ModName,
        $Release,
        [string]$Username,
        [string]$Token
    )

    # Appending username/token as query params is how the portal
    # authenticates downloads - see https://wiki.factorio.com/Mod_portal_API.
    $downloadUrl = "https://mods.factorio.com$($Release.download_url)?username=$Username&token=$Token"
    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).zip"

    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempFile -UseBasicParsing
    } catch {
        Write-Warning "  Download failed for '$ModName': $($_.Exception.Message)"
        Remove-Item -LiteralPath $tempFile -ErrorAction SilentlyContinue
        return $false
    }

    # Verify integrity before it ever touches the real mods folder.
    $actualHash = (Get-FileHash -LiteralPath $tempFile -Algorithm SHA1).Hash
    if (-not ($actualHash -ieq $Release.sha1)) {
        Write-Warning "  SHA1 mismatch for '$ModName' - keeping existing version."
        Remove-Item -LiteralPath $tempFile -ErrorAction SilentlyContinue
        return $false
    }

    $newZipPath = Join-Path $ModsPath $Release.file_name
    Move-Item -LiteralPath $tempFile -Destination $newZipPath -Force
    return $true
}

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------

function Start-Factorio {
    param(
        $Config,
        $Install,
        [string[]]$ExtraArgs
    )

    $hasArgs = $ExtraArgs -and $ExtraArgs.Count -gt 0
    $mode = $Config.LaunchMode

    # steam://rungameid can't carry command-line args, so if the caller
    # wants args forwarded we transparently switch to a direct exe launch.
    if ($mode -eq 'SteamProtocol' -and $hasArgs) {
        Write-Host "Extra arguments were given, but steam:// launches can't carry them - launching factorio.exe directly instead."
        $mode = 'SteamExe'
    }

    if ($mode -eq 'SteamProtocol') {
        Write-Host "Launching Factorio via Steam..."
        Start-Process "steam://rungameid/$($Config.SteamAppId)"
        return
    }

    if (-not $Install) {
        throw "Cannot launch directly: no Factorio install was found."
    }

    Write-Host "Launching Factorio directly: $($Install.ExePath)"
    if ($hasArgs) {
        Start-Process -FilePath $Install.ExePath -ArgumentList $ExtraArgs
    } else {
        Start-Process -FilePath $Install.ExePath
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$config = Get-ScriptConfig -Path $ConfigPath

$userDataPath = Get-FactorioUserDataPath
$modsPath = if ($config.ModsPath) { $config.ModsPath } else { Join-Path $userDataPath 'mods' }

$install = Find-FactorioInstall -Config $config
if (-not $install) {
    Write-Error "Could not find a Factorio installation (Steam or standalone). Set 'FactorioExePath' in $ConfigPath."
    exit 1
}
Write-Host "Found Factorio install ($($install.Source)): $($install.ExePath)"

$gameVersion = Get-InstalledFactorioVersion -InstallRoot $install.InstallRoot
if ($gameVersion) {
    Write-Host "Installed Factorio version: $gameVersion"
}

# Mod-update failures (no credentials, network down, portal error) should
# never stop the game from launching - they just skip straight to launch.
if (-not $SkipModUpdate) {
    $creds = Get-ModPortalCredentials -UserDataPath $userDataPath
    if (-not $creds) {
        Write-Warning "No saved mod portal credentials found in player-data.json (log in from the in-game mods browser once). Skipping mod update pass."
    } else {
        $mods = Get-InstalledMods -ModsPath $modsPath
        foreach ($unpacked in $mods.Unpacked) {
            Write-Host "Skipped '$unpacked': unpacked/dev mod, not auto-updated."
        }

        foreach ($mod in $mods.Mods) {
            Write-Host "Checking '$($mod.Name)' ($($mod.LatestVersion) installed)..."
            $release = Get-LatestRelease -ModName $mod.Name
            if (-not $release) {
                Write-Host "  Not found on the mod portal."
                continue
            }

            if ([version]$release.version -le [version]$mod.LatestVersion) {
                Write-Host "  Up to date."
                continue
            }

            Write-Host "  Update available: $($mod.LatestVersion) -> $($release.version)"
            if ($DryRun) {
                Write-Host "  (dry run: not downloading)"
                continue
            }

            if (Update-Mod -ModsPath $modsPath -ModName $mod.Name -Release $release -Username $creds.Username -Token $creds.Token) {
                Write-Host "  Downloaded $($release.version) (previous version(s) left in place)."
            }
        }
    }
}

if ($DryRun) {
    Write-Host "Dry run complete - not launching Factorio."
    exit 0
}

Start-Factorio -Config $config -Install $install -ExtraArgs $FactorioArgs
