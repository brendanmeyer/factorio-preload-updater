@echo off
rem Version: 1.0.2.1
rem Wrapper for Steam's "Launch Options" %command% substitution.
rem Runs the mod updater (without launching Factorio itself) with the console
rem window visible, hides that window, then executes whatever command Steam
rem passes in - i.e. the real factorio.exe + its args - so Steam still owns
rem the actual launch and can track the play session. See README.md for setup.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-FactorioMods.ps1" -NoLaunch

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Hide-Console.ps1"

%*
