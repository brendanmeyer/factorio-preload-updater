@echo off
rem Wrapper for Steam's "Launch Options" %command% substitution.
rem Runs the mod updater (without launching Factorio itself), then executes
rem whatever command Steam passes in - i.e. the real factorio.exe + its args -
rem so Steam still owns the actual launch. See README.md for setup.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-FactorioMods.ps1" -NoLaunch

%*
