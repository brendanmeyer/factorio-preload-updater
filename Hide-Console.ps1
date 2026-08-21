<#
Version: 1.0.3

Hides the console window of whichever process calls this script - used by
Launch-Wrapper.bat to make the console disappear once the mod update check
is done, without closing the process itself (Steam still needs it alive to
track the play session while Factorio runs). See README.md for setup.

This only works reliably under the classic console host (conhost.exe).
Windows Terminal - the default terminal app on modern Windows 11 - hosts
console processes in its own window and appears to convert an externally
requested hide into a minimize instead, so Launch-Wrapper.bat is invoked
via an explicit "conhost.exe" prefix (see Set-FactorioSteamLaunchOptions.ps1
and README.md) to force the classic host regardless of that system setting.
#>

Add-Type -Name Win -Namespace Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
'@

$SW_HIDE = 0
[Native.Win]::ShowWindow([Native.Win]::GetConsoleWindow(), $SW_HIDE) | Out-Null
