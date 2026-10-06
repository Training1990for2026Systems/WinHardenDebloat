<#
================================================================================
 WHD Next  -  tools\Test-WHDAlert.ps1   (development tool)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Build step 5 helper. Shows the small update-guard alert window with SAMPLE text,
 so its look can be checked without waiting for a real alert.

 It changes no Windows setting. It does NOT register the event log source (that
 happens only when the update guard is installed). If the source already exists
 it writes one clearly marked TEST entry; otherwise it only says so.

   pwsh       -ExecutionPolicy Bypass -File .\next\tools\Test-WHDAlert.ps1     (PowerShell 7)
   powershell -ExecutionPolicy Bypass -File .\next\tools\Test-WHDAlert.ps1     (Windows PowerShell 5.1)
================================================================================
#>
[CmdletBinding()]
param()
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$nextDir  = Split-Path -Parent $toolsDir
$script:WHDRoot    = $nextDir
$script:WHDExecute = $false
. (Join-Path $nextDir 'modules\Common.ps1')

Write-Host ''
Write-Host (' Engine: {0} {1}   ({2})' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion, (Get-WHDModeText))
$sample = Join-Path $nextDir 'Run.txt'                 # any existing text file, just to show the "Open the report" button
$lines = @(
    'RESULT  : ALERT - see the !! lines below',
    '  !! CHANGED  SAMPLE: reg HKLM:\SOFTWARE\Example\Setting   now: 0',
    '  !! 1 app(s) WHD removed CAME BACK:',
    '',
    'THIS IS A TEST. Nothing was checked and nothing was changed.'
)
$src = Test-WHDEventSource
Write-Host (' Event log source "WHD Next" registered: {0}' -f $src)
if ($src) {
    $w = Write-WHDEventLog -Type 'Information' -EventId 1999 -Message 'WHD Next: TEST entry from tools\Test-WHDAlert.ps1 (no real alert).'
    Write-Host (' Test entry written to the Application log: {0}' -f $w)
} else {
    Write-Host ' (No entry written - the source is registered when the update guard is installed.)'
}
Write-Host ' Showing the alert window now - close it to finish ...'
$ok = Show-WHDAlertWindow -Title 'WHD Next - update guard (TEST)' -Heading 'The update guard found something to look at' -Lines $lines -ReportPath $sample
Write-Host (' Window shown: {0}' -f $ok)
Write-Host ' Nothing on this PC was changed.' -ForegroundColor Green
