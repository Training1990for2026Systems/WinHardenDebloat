#requires -Version 7.6
<#
 WHD Next 3.0  -  Public/Initialize-WHDSession.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 Starts a WHD session: new session stamp, log file logs\run_<session>.log,
 dry-run unless -Execute, safe mode with -SafeMode (D14). EXECUTE needs an
 administrator window; without one the session stays a dry-run. -DataRoot: the
 WHD folder when the code runs from elsewhere (the update guard's locked copy).
 -LogName: the log file's first word (run, guard).
#>
function Initialize-WHDSession {
    [CmdletBinding()]
    param([string]$Root, [switch]$Execute, [switch]$SafeMode, [string]$DataRoot, [ValidatePattern('^[a-z]+$')][string]$LogName = 'run')
    if ($Root) { Initialize-WHDState -Root $Root } else { Initialize-WHDState }
    $s = $script:WHDState
    if ($DataRoot) { $s.DataRoot = $DataRoot }
    $s.SafeMode = [bool]$SafeMode
    $logs = Join-Path $s.DataRoot 'logs'
    try {
        if (-not (Test-Path -LiteralPath $logs)) { [void](New-Item -ItemType Directory -Path $logs -Force -ErrorAction Stop) }
        $s.LogFile = Join-Path $logs ('{0}_{1}.log' -f $LogName, $s.Stamp)
    } catch { $s.LogFile = $null }
    $s.Initialized = $true
    Write-WHDLog -Message ('Session start | WHD Next {0} | PowerShell {1} | {2} | admin={3} | root={4}{5}' -f (Get-WHDEngineInfo).Version, $PSVersionTable.PSVersion, (Get-WHDModeText), $s.IsAdmin, $s.Root, $(if ($s.DataRoot -ne $s.Root) { ' | data=' + $s.DataRoot } else { '' }))
    if ($Execute) { Set-WHDMode -Execute $true | Out-Null }
    return (Get-WHDSession)
}
