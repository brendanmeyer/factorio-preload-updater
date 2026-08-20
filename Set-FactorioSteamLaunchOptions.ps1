<#
Version: 1.0.2.2

Sets Factorio's Steam "Launch Options" (the %command% wrapper) directly in
Steam's own config file, instead of typing it in by hand.

Steam keeps this value in a Valve KeyValues ("VDF") file under
userdata\<id>\config\localconfig.vdf, and holds its own copy in memory while
running - if Steam is open, it will overwrite this file with its in-memory
copy when it next writes or exits, silently undoing an external edit. So
Steam must be fully closed before this script touches the file; it waits
for that rather than guessing.

Only the one LaunchOptions value for Factorio's app ID is touched. The file
is backed up (once, as .vdf.bak) before any change, and a brace-balance
sanity check runs before the result is written back.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # What to set Factorio's Launch Options to. Defaults to the Launch-Wrapper.bat
    # %command% wrapper sitting next to this script (see README.md).
    [string]$LaunchOptions,

    # Defaults to config.json's SteamAppId next to this script, or Factorio's own ID.
    [string]$SteamAppId,

    # Numeric userdata\<id> folder to edit, if you have more than one Steam
    # account on this machine and auto-detection picks the wrong one.
    [string]$SteamUserId
)

# ---- Resolve inputs ---------------------------------------------------

if (-not $LaunchOptions) {
    $wrapperPath = Join-Path $PSScriptRoot 'Launch-Wrapper.bat'
    if (-not (Test-Path -LiteralPath $wrapperPath)) {
        Write-Error "Launch-Wrapper.bat not found next to this script (expected at $wrapperPath). Pass -LaunchOptions explicitly, or run Launch-Wrapper.bat's setup first."
        exit 1
    }
    $resolvedWrapper = (Resolve-Path -LiteralPath $wrapperPath).Path
    # conhost.exe forces the classic console host regardless of the user's
    # system-wide default terminal app setting - Windows Terminal hosts the
    # window itself and doesn't let Hide-Console.ps1 truly hide it (an
    # external hide request just minimizes it instead). Steam doesn't search
    # PATH the way cmd.exe would, so the bare exe name isn't found - it needs
    # the full path.
    $conhostPath = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $LaunchOptions = "`"$conhostPath`" `"$resolvedWrapper`" %command%"
}

if (-not $SteamAppId) {
    $configPath = Join-Path $PSScriptRoot 'config.json'
    if (Test-Path -LiteralPath $configPath) {
        try {
            $SteamAppId = (Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).SteamAppId
        } catch {
            Write-Warning "Could not read SteamAppId from '$configPath': $($_.Exception.Message)"
        }
    }
    if (-not $SteamAppId) { $SteamAppId = '427520' }
}

# ---- Find Steam ---------------------------------------------------------

$steamKey = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name 'SteamPath' -ErrorAction SilentlyContinue
if (-not $steamKey) {
    Write-Error 'Could not find a Steam installation (HKCU:\Software\Valve\Steam has no SteamPath).'
    exit 1
}
$steamPath = $steamKey.SteamPath -replace '/', '\'

# ---- Require Steam to be closed, and wait for it ------------------------

$steamProcess = Get-Process -Name 'steam' -ErrorAction SilentlyContinue
if ($steamProcess) {
    Write-Host 'Steam is currently running. This script edits Steam''s own config file,'
    Write-Host 'which Steam will silently overwrite on exit if it stays open - please'
    Write-Host 'fully quit Steam now (right-click the tray icon -> Exit, not just close the window).'
    Write-Host 'Waiting for Steam to close...'
    while (Get-Process -Name 'steam' -ErrorAction SilentlyContinue) {
        Start-Sleep -Seconds 2
    }
    Write-Host 'Steam has closed. Continuing.'
}

# ---- Find the right userdata\<id>\config\localconfig.vdf ----------------

$userdataRoot = Join-Path $steamPath 'userdata'
if (-not (Test-Path -LiteralPath $userdataRoot)) {
    Write-Error "No userdata folder found under '$steamPath' - has any account logged into Steam on this machine?"
    exit 1
}

if ($SteamUserId) {
    $vdfPath = Join-Path $userdataRoot "$SteamUserId\config\localconfig.vdf"
    if (-not (Test-Path -LiteralPath $vdfPath)) {
        Write-Error "No localconfig.vdf found for -SteamUserId '$SteamUserId' (looked at '$vdfPath')."
        exit 1
    }
} else {
    $candidates = Get-ChildItem -LiteralPath $userdataRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'config\localconfig.vdf') }

    if (-not $candidates) {
        Write-Error "No localconfig.vdf found under any '$userdataRoot\<id>\config' folder."
        exit 1
    } elseif (@($candidates).Count -eq 1) {
        $vdfPath = Join-Path $candidates[0].FullName 'config\localconfig.vdf'
    } else {
        # Multiple Steam accounts have used this machine - pick whichever
        # localconfig.vdf was written to most recently, and say so, rather
        # than silently guessing which account is "current".
        $newest = $candidates |
            ForEach-Object { Get-Item -LiteralPath (Join-Path $_.FullName 'config\localconfig.vdf') } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        $vdfPath = $newest.FullName
        Write-Warning "Multiple Steam accounts found on this machine; using the most recently updated config: $vdfPath (pass -SteamUserId to pick a specific one)."
    }
}

Write-Host "Using: $vdfPath"

# ---- Minimal VDF (Valve KeyValues) navigation ----------------------------
# Steam writes each brace on its own line, which these helpers rely on -
# they are not a general VDF parser, just enough to locate one specific
# nested value without disturbing anything else in the file.

function Find-VdfChild {
    param($Lines, [int]$ParentOpenIdx, [int]$ParentCloseIdx, [string]$KeyName)

    $depth = 0
    for ($i = $ParentOpenIdx + 1; $i -lt $ParentCloseIdx; $i++) {
        $trimmed = $Lines[$i].Trim()
        if ($depth -eq 0 -and $trimmed -match '^"([^"]+)"\s*$' -and $Matches[1] -ieq $KeyName) {
            $openIdx = $i + 1
            while ($Lines[$openIdx].Trim() -eq '') { $openIdx++ }
            if ($Lines[$openIdx].Trim() -eq '{') {
                $d = 1
                $j = $openIdx + 1
                while ($d -gt 0) {
                    $t = $Lines[$j].Trim()
                    if ($t -eq '{') { $d++ } elseif ($t -eq '}') { $d-- }
                    $j++
                }
                return [PSCustomObject]@{ KeyLine = $i; OpenLine = $openIdx; CloseLine = $j - 1 }
            }
        }
        if ($trimmed -eq '{') { $depth++ }
        elseif ($trimmed -eq '}') { $depth-- }
    }
    return $null
}

function Get-OrAddVdfChildBlock {
    param($Lines, [int]$ParentOpenIdx, [int]$ParentCloseIdx, [string]$KeyName, [string]$Indent)

    $existing = Find-VdfChild -Lines $Lines -ParentOpenIdx $ParentOpenIdx -ParentCloseIdx $ParentCloseIdx -KeyName $KeyName
    if ($existing) {
        return [PSCustomObject]@{ Block = $existing; ParentCloseIdx = $ParentCloseIdx }
    }

    # Not found - create it as the first child of the parent block.
    $insertAt = $ParentOpenIdx + 1
    $Lines.Insert($insertAt, "$Indent`"$KeyName`"")
    $Lines.Insert($insertAt + 1, "$Indent{")
    $Lines.Insert($insertAt + 2, "$Indent}")
    $newBlock = [PSCustomObject]@{ KeyLine = $insertAt; OpenLine = ($insertAt + 1); CloseLine = ($insertAt + 2) }
    return [PSCustomObject]@{ Block = $newBlock; ParentCloseIdx = ($ParentCloseIdx + 3) }
}

# ---- Read, edit, and sanity-check the file in memory ---------------------

$raw = Get-Content -LiteralPath $vdfPath -Raw
$eol = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
$lines = [System.Collections.Generic.List[string]]::new(($raw -split "`r`n|`r|`n"))
# Splitting can leave one trailing empty element if the file ends with a
# newline - drop it so line-count math (used for the root's close-brace
# search) doesn't get thrown off by a phantom last line.
if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
    $lines.RemoveAt($lines.Count - 1)
}

if ($lines[0].Trim() -notmatch '^"UserLocalConfigStore"\s*$') {
    Write-Error "Unexpected localconfig.vdf format: first line isn't `"UserLocalConfigStore`" - aborting without changes."
    exit 1
}
if ($lines[1].Trim() -ne '{') {
    Write-Error 'Unexpected localconfig.vdf format: second line is not an opening brace - aborting without changes.'
    exit 1
}
$rootClose = $lines.Count - 1
if ($lines[$rootClose].Trim() -ne '}') {
    Write-Error 'Unexpected localconfig.vdf format: last line is not a closing brace - aborting without changes.'
    exit 1
}

$open = 1
$close = $rootClose
$indent = ''
foreach ($key in @('Software', 'Valve', 'Steam', 'apps')) {
    $indent += "`t"
    $result = Get-OrAddVdfChildBlock -Lines $lines -ParentOpenIdx $open -ParentCloseIdx $close -KeyName $key -Indent $indent
    $open = $result.Block.OpenLine
    $close = $result.Block.CloseLine
}

$indent += "`t"
$appResult = Get-OrAddVdfChildBlock -Lines $lines -ParentOpenIdx $open -ParentCloseIdx $close -KeyName $SteamAppId -Indent $indent
$open = $appResult.Block.OpenLine
$close = $appResult.Block.CloseLine

# Confirmed against a real localconfig.vdf: Steam's own writer escapes both
# backslashes ('\' -> '\\') and quotes ('"' -> '\"'). Backslashes must be
# escaped first, so the backslash just added before each escaped quote isn't
# itself re-escaped.
$escapedValue = ($LaunchOptions -replace '\\', '\\') -replace '"', '\"'
$leafIndent = $indent + "`t"

$depth = 0
$foundIdx = -1
$oldValue = $null
for ($i = $open + 1; $i -lt $close; $i++) {
    $t = $lines[$i].Trim()
    if ($depth -eq 0 -and $t -match '^"LaunchOptions"\s+"(.*)"\s*$') {
        $foundIdx = $i
        $oldValue = $Matches[1]
        break
    }
    if ($t -eq '{') { $depth++ } elseif ($t -eq '}') { $depth-- }
}

if ($foundIdx -ge 0) {
    if ($oldValue -eq $escapedValue) {
        Write-Host "LaunchOptions for app $SteamAppId is already set to the requested value - nothing to change."
        exit 0
    }
    Write-Host "Replacing existing LaunchOptions for app $SteamAppId`: '$oldValue' -> '$LaunchOptions'"
    $lines[$foundIdx] = "$leafIndent`"LaunchOptions`"`t`t`"$escapedValue`""
} else {
    Write-Host "Adding LaunchOptions for app $SteamAppId`: '$LaunchOptions'"
    $lines.Insert($open + 1, "$leafIndent`"LaunchOptions`"`t`t`"$escapedValue`"")
}

# Cheap corruption check before touching disk: every '{' must have a match.
$joinedForCount = $lines -join "`n"
$openCount = ($joinedForCount.ToCharArray() | Where-Object { $_ -eq '{' }).Count
$closeCount = ($joinedForCount.ToCharArray() | Where-Object { $_ -eq '}' }).Count
if ($openCount -ne $closeCount) {
    Write-Error "Brace count mismatch after editing ($openCount '{' vs $closeCount '}') - aborting without writing, to avoid corrupting the file."
    exit 1
}

# ---- Write back -----------------------------------------------------------

if ($PSCmdlet.ShouldProcess($vdfPath, 'Update Factorio LaunchOptions')) {
    $backupPath = "$vdfPath.bak"
    if (-not (Test-Path -LiteralPath $backupPath)) {
        Copy-Item -LiteralPath $vdfPath -Destination $backupPath
        Write-Host "Backed up original to: $backupPath"
    }

    $newContent = ($lines -join $eol) + $eol
    [IO.File]::WriteAllText($vdfPath, $newContent, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host 'Done. You can reopen Steam now.'
}
