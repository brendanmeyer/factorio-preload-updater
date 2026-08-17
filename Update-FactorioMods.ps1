#Requires -Version 5.1
<#
Version: 1.0.0.2

Checks installed Factorio mods against the Mod Portal, downloads any updates
using the credentials Factorio already saved after an in-game login, then
launches Factorio (Steam or standalone).
#>

[CmdletBinding()]
param(
    [switch]$SkipModUpdate,
    [switch]$NoLaunch,
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
        ModsPath              = $null              # null = auto-detect %APPDATA%\Factorio\mods
        FactorioExePath       = $null              # null = auto-detect (Steam, then standalone)
        LaunchMode            = 'SteamProtocol'    # SteamProtocol | SteamExe | Standalone
        SteamAppId            = '427520'           # Factorio's Steam app id
        OnlyUpdateEnabledMods = $false             # $false = update every installed mod (default)
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

# Factorio tracks per-mod enabled/disabled state in mod-list.json, next to
# the mods themselves. A mod with no entry there is treated as enabled (that
# mirrors Factorio's own behavior for a mod it hasn't seen yet), so this only
# needs to report which mods are explicitly disabled.
function Get-DisabledModNames {
    param([string]$ModsPath)

    $disabled = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $modListPath = Join-Path $ModsPath 'mod-list.json'
    if (-not (Test-Path -LiteralPath $modListPath)) { return $disabled }

    $modList = Get-Content -LiteralPath $modListPath -Raw | ConvertFrom-Json
    foreach ($entry in $modList.mods) {
        if ($entry.enabled -eq $false) { [void]$disabled.Add($entry.name) }
    }
    return $disabled
}

# ---------------------------------------------------------------------------
# Mod portal lookup + update
# ---------------------------------------------------------------------------

# Looks up the latest release for every given mod name using the portal's
# batch list endpoint (GET /api/mods?namelist=...) instead of one request per
# mod - collapses dozens of separate connections (and just as many chances
# for a single one to stall) into a couple of batched calls. Chunked to keep
# the query string well short of typical server URL-length limits even with
# a very large mod list. A short per-request timeout means one bad
# connection can no longer stall the whole check for a long time.
#
# Just takes the highest-versioned release on the portal, regardless of its
# declared factorio_version - mods are generally usable across nearby game
# versions, and requiring an exact major.minor match caused real updates to
# be missed for mods whose author hadn't re-tagged for the newest game version yet.
function Get-LatestReleases {
    param([string[]]$ModNames)

    $latestByName = @{}
    if (-not $ModNames -or $ModNames.Count -eq 0) { return $latestByName }

    $batchSize = 50
    for ($i = 0; $i -lt $ModNames.Count; $i += $batchSize) {
        $batch = $ModNames[$i..([Math]::Min($i + $batchSize, $ModNames.Count) - 1)]
        $namelistParam = ($batch | ForEach-Object { "namelist=$([uri]::EscapeDataString($_))" }) -join '&'
        $url = "https://mods.factorio.com/api/mods?page_size=max&$namelistParam"

        try {
            $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 15
        } catch {
            Write-Warning "  Could not look up mods on the mod portal: $($_.Exception.Message)"
            continue
        }

        foreach ($mod in $resp.results) {
            if (-not $mod.releases) { continue }
            $latestByName[$mod.name] = $mod.releases | Sort-Object { [version]$_.version } -Descending | Select-Object -First 1
        }
    }

    return $latestByName
}

# Downloads one release and adds it to the mods folder - the actual work
# done inside each parallel runspace below. The existing zip(s) for this mod
# are deliberately left in place - Factorio keeps old versions around
# itself, and other saves/mod-list entries may still pin an older version.
$UpdateModScriptBlock = {
    param($ModsPath, $ModName, $Release, $Username, $Token)

    # Appending username/token as query params is how the portal
    # authenticates downloads - see https://wiki.factorio.com/Mod_portal_API.
    $downloadUrl = "https://mods.factorio.com$($Release.download_url)?username=$Username&token=$Token"
    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).zip"

    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempFile -UseBasicParsing -TimeoutSec 60
    } catch {
        Remove-Item -LiteralPath $tempFile -ErrorAction SilentlyContinue
        return [PSCustomObject]@{ ModName = $ModName; Success = $false; Error = "Download failed: $($_.Exception.Message)" }
    }

    # Verify integrity before it ever touches the real mods folder.
    $actualHash = (Get-FileHash -LiteralPath $tempFile -Algorithm SHA1).Hash
    if (-not ($actualHash -ieq $Release.sha1)) {
        Remove-Item -LiteralPath $tempFile -ErrorAction SilentlyContinue
        return [PSCustomObject]@{ ModName = $ModName; Success = $false; Error = 'SHA1 mismatch - keeping existing version.' }
    }

    $newZipPath = Join-Path $ModsPath $Release.file_name
    Move-Item -LiteralPath $tempFile -Destination $newZipPath -Force
    return [PSCustomObject]@{ ModName = $ModName; Success = $true; Version = $Release.version }
}

# Downloads are network-bound (mostly waiting on the mod portal, not on CPU),
# so running several at once cuts total wait time a lot for the common case
# of multiple mods updating together. Uses a runspace pool rather than
# Start-Job or ForEach-Object -Parallel so this works unchanged on both
# Windows PowerShell 5.1 and PowerShell 7, with no extra modules.
function Update-ModsInParallel {
    param(
        [string]$ModsPath,
        [System.Collections.Generic.List[object]]$Updates,
        [string]$Username,
        [string]$Token,
        [int]$MaxConcurrency = 5
    )

    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $MaxConcurrency)
    $pool.Open()

    $running = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($item in $Updates) {
            $ps = [System.Management.Automation.PowerShell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($UpdateModScriptBlock).
                AddArgument($ModsPath).AddArgument($item.Name).AddArgument($item.Release).
                AddArgument($Username).AddArgument($Token)
            $running.Add([PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Done = $false })
        }

        $total = $running.Count
        $completed = 0
        $results = [System.Collections.Generic.List[object]]::new()
        Write-Progress -Activity 'Downloading mod updates' -Status "0 of $total" -PercentComplete 0
        while ($completed -lt $total) {
            foreach ($job in $running) {
                if (-not $job.Done -and $job.Handle.IsCompleted) {
                    $results.AddRange([object[]]$job.PS.EndInvoke($job.Handle))
                    $job.PS.Dispose()
                    $job.Done = $true
                    $completed++
                    Write-Progress -Activity 'Downloading mod updates' -Status "$completed of $total" -PercentComplete ([int](100 * $completed / $total))
                }
            }
            if ($completed -lt $total) { Start-Sleep -Milliseconds 100 }
        }
        Write-Progress -Activity 'Downloading mod updates' -Completed
        return $results
    } finally {
        $pool.Close()
        $pool.Dispose()
    }
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

        $modsToCheck = $mods.Mods
        if ($config.OnlyUpdateEnabledMods) {
            $disabledMods = Get-DisabledModNames -ModsPath $modsPath
            $modsToCheck = @($mods.Mods | Where-Object {
                if ($disabledMods.Contains($_.Name)) {
                    Write-Host "Skipped '$($_.Name)': disabled in mod-list.json."
                    return $false
                }
                return $true
            })
        }

        $latestReleases = Get-LatestReleases -ModNames ($modsToCheck | ForEach-Object { $_.Name })

        # First pass just decides what needs downloading, so all the
        # downloads themselves can run together afterward instead of one at
        # a time.
        $toUpdate = [System.Collections.Generic.List[object]]::new()
        foreach ($mod in $modsToCheck) {
            Write-Host "Checking '$($mod.Name)' ($($mod.LatestVersion) installed)..."
            $release = $latestReleases[$mod.Name]
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

            $toUpdate.Add([PSCustomObject]@{ Name = $mod.Name; Release = $release })
        }

        if ($toUpdate.Count -gt 0) {
            Write-Host "Downloading $($toUpdate.Count) mod update(s)..."
            $results = Update-ModsInParallel -ModsPath $modsPath -Updates $toUpdate -Username $creds.Username -Token $creds.Token
            foreach ($result in $results) {
                if ($result.Success) {
                    Write-Host "  Downloaded '$($result.ModName)' $($result.Version) (previous version(s) left in place)."
                } else {
                    Write-Warning "  '$($result.ModName)': $($result.Error)"
                }
            }
        }
    }
}

if ($DryRun) {
    Write-Host "Dry run complete - not launching Factorio."
    exit 0
}

if ($NoLaunch) {
    Write-Host "Done - not launching Factorio (-NoLaunch)."
    exit 0
}

Start-Factorio -Config $config -Install $install -ExtraArgs $FactorioArgs
