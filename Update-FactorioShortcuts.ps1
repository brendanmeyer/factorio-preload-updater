<#
Version: 1.0.0

Finds Desktop, Start Menu, and taskbar shortcuts that launch factorio.exe
directly and repoints them at Update-FactorioMods.ps1, so launching from any
of them also runs the mod-update pass first. Nothing is deleted outright -
every changed shortcut is backed up alongside itself as a .bak file.

Steam-launched (.url, steam://rungameid/...) shortcuts are left alone: once
the Steam Launch Options wrapper is set up (see README.md), Steam's own Play
button already runs the update pass, so there's nothing for those to gain
from being repointed here.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Defaults to the updater script sitting next to this one.
    [string]$UpdaterScriptPath = (Join-Path $PSScriptRoot 'Update-FactorioMods.ps1')
)

if (-not (Test-Path -LiteralPath $UpdaterScriptPath)) {
    Write-Error "Updater script not found: $UpdaterScriptPath"
    exit 1
}
$UpdaterScriptPath = (Resolve-Path -LiteralPath $UpdaterScriptPath).Path
$updaterArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$UpdaterScriptPath`""

# All-users (Common*) locations are included but silently skipped per-shortcut
# if they're not writable (e.g. the script isn't running elevated) - readable
# without admin rights, so we can still find them and just warn on write failure.
# Classic (Win32) taskbar pins are backed by .lnk files in this same
# "User Pinned\TaskBar" folder, same as Start Menu/Desktop shortcuts.
$candidateFolders = @(
    [Environment]::GetFolderPath('Desktop')
    [Environment]::GetFolderPath('CommonDesktopDirectory')
    [Environment]::GetFolderPath('Programs')
    [Environment]::GetFolderPath('CommonPrograms')
    (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

$shell = New-Object -ComObject WScript.Shell
$changed = 0

foreach ($folder in $candidateFolders) {
    Get-ChildItem -LiteralPath $folder -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object {
            $lnkPath = $_.FullName
            $shortcut = $shell.CreateShortcut($lnkPath)

            if ($shortcut.TargetPath -notlike '*factorio.exe') { return }
            if ($shortcut.Arguments -like "*$([IO.Path]::GetFileName($UpdaterScriptPath))*") {
                Write-Host "Already up to date: $lnkPath"
                return
            }

            $backupPath = "$lnkPath.bak"
            if (-not (Test-Path -LiteralPath $backupPath)) {
                Copy-Item -LiteralPath $lnkPath -Destination $backupPath
            }

            if ($PSCmdlet.ShouldProcess($lnkPath, 'Repoint shortcut at updater script')) {
                try {
                    $originalExe = $shortcut.TargetPath
                    $shortcut.TargetPath = 'powershell.exe'
                    $shortcut.Arguments = $updaterArgs
                    # Keep the familiar Factorio icon rather than PowerShell's.
                    $shortcut.IconLocation = "$originalExe,0"
                    $shortcut.Save()
                    Write-Host "Updated: $lnkPath (was -> $originalExe)"
                    $changed++
                } catch {
                    Write-Warning "Could not update '$lnkPath': $($_.Exception.Message)"
                }
            }
        }
}

if ($changed -eq 0) {
    Write-Host 'No Factorio Desktop/Start Menu/taskbar shortcuts needed updating.'
} else {
    Write-Host "Done - $changed shortcut(s) updated. Originals are kept alongside as .bak files."
}
