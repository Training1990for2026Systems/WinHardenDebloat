@echo off
rem ============================================================================
rem  WHD Next - Start-WHD.cmd   (double-click starter)
rem  Author : Training1990for2026Systems   Contact: t90018273@gmail.com
rem  License: MIT (see LICENSE)            Built with Claude by Anthropic
rem ----------------------------------------------------------------------------
rem  Opens the launcher (Start-WHD.ps1) with Windows PowerShell 5.1, which is on
rem  every Windows PC. This file changes nothing by itself.
rem ============================================================================
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-WHD.ps1" %*
echo.
pause
