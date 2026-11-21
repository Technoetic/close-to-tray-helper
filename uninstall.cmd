@echo off
setlocal DisableDelayedExpansion
set "PSModulePath="
set "_ps=%~dp0uninstall.ps1"
set "_leave="
if /i "%CD%\"=="%~dp0" set "_leave=1"
if /i "%CD%"=="%~dp0" set "_leave=1"
if "%~1"=="" if not defined CI (
  if defined _leave (
    (goto) 2>nul & cd /d "%TEMP%" & "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%_ps%" %* && (pause & exit /b 0) || (pause & exit /b 1)
  )
  (goto) 2>nul & "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%_ps%" %* && (pause & exit /b 0) || (pause & exit /b 1)
)
if defined _leave (
  (goto) 2>nul & cd /d "%TEMP%" & "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%_ps%" %*
)
(goto) 2>nul & "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%_ps%" %*
