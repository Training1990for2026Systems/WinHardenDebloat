<#
================================================================================
 WHD Next  -  WHD-Placeholder.ps1   (stand-in for the real program)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Build step 3 only. The launcher (Start-WHD.ps1) starts this file in the chosen
 engine so the hand-over can be tested before the real WHD Next is wired in
 (build step 4). It only prints what it sees. It changes nothing and writes no
 files. It will be removed once the real program is in place.
================================================================================
#>
[CmdletBinding()]
param(
    [ValidateSet('Full', 'Safe')][string]$Mode = 'Safe'
)

$isAdmin = $false
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

$engine   = ('{0} {1}' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
$isCore   = ($PSVersionTable.PSEdition -eq 'Core')
$expected = $true
if ($Mode -eq 'Full' -and -not $isCore) { $expected = $false }
if ($Mode -eq 'Safe' -and $isCore)      { $expected = $false }

Write-Host ' +--------------------------------------------------------------+' -ForegroundColor White
Write-Host ' |  WHD Next - PLACEHOLDER (the real program comes in step 4)    |' -ForegroundColor White
Write-Host ' +--------------------------------------------------------------+' -ForegroundColor White
if ($Mode -eq 'Full') {
    Write-Host '   Mode ............. FULL  (all WHD functions would be available)' -ForegroundColor Green
} else {
    Write-Host '   Mode ............. SAFE MODE  (checks, Verify, Undo and re-apply only)' -ForegroundColor Yellow
}
Write-Host ('   Running on ....... {0}' -f $engine)
Write-Host ('   Program folder ... {0}' -f $PSHOME)
Write-Host ('   Administrator .... {0}' -f $(if ($isAdmin) { 'yes' } else { 'no' }))
Write-Host ('   Started from ..... {0}' -f $PSScriptRoot)
if ($expected) {
    Write-Host '   Hand-over ........ correct engine for this mode' -ForegroundColor Green
} else {
    Write-Host '   Hand-over ........ WRONG engine for this mode' -ForegroundColor Red
}
Write-Host ''
Write-Host '   Nothing was changed. This placeholder only prints what it sees.' -ForegroundColor Green

if ($expected) { exit 0 } else { exit 2 }
