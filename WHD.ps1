#requires -Version 7.6 -PSEdition Core
<#
================================================================================
 WHD Next 3.0  -  WHD.ps1   (entry point, PowerShell 7.6 or newer stable)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 BUILD STEP 6 - MAIN MENU AND WINDOW. Starts a session (log in logs\, change history in
 restore\), asks once how to take over WHD Next 2.0's history (D18), then opens
 the main menu. Switches for one job instead of the menu:
   -Gui          the window instead of the menu (build step 6b)
   -Guard        the update guard's check (read-only), then end - started by the guard's task
                 through Start-WHDGuard.ps1 with -DataRoot <the WHD folder> (build step 7)
   -Plan         the full dry-run of everything (changes nothing), then end
   -Verify       check every recorded change of this PC (read-only)
   -UndoPreview  dry-run of undoing the WHOLE history (always a dry-run - changes nothing)
   -UndoTest     undo the step 3 test value (HKCU:\Software\WinHardenDebloatNext\EngineTest);
                 with -Execute it is real (asks first)
   -Profile <name>  apply a profile (minimum, average, strict, your own, or a .json path), then end;
                 with -Execute it is real (one question first)
   -Menu <name>  open one menu directly (Security, Firewall, Updates, AI, General, Privacy, Win32,
                 Devices, Permissions, Maintenance, TimeRegion, Theme, Undo)
   -EngineTest   send one harmless test change through the change gate
                 (HKCU:\Software\WinHardenDebloatNext\EngineTest, Step3 = 1)
   -Execute      start with EXECUTE on (asks first; restore point before the first change)
   -SafeMode     D14: start in safe mode
 Start it with Start-WHD.cmd / Start-WHD.ps1. Windows PowerShell 5.1 refuses this file.
================================================================================
#>
[CmdletBinding()]
param(
    [switch]$Execute,
    [switch]$SafeMode,
    [switch]$EngineTest,
    [switch]$Verify,
    [switch]$UndoPreview,
    [switch]$UndoTest,
    [switch]$Plan,
    [switch]$Gui,
    [switch]$Guard,
    [string]$DataRoot,
    [Alias('Profile')][string]$ProfileName,
    [ValidateSet('Security', 'Firewall', 'Updates', 'AI', 'General', 'Privacy', 'Win32', 'Devices', 'Permissions', 'Maintenance', 'TimeRegion', 'Theme', 'Undo', 'Guard', 'Profiles')][string]$Menu
)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path $PSScriptRoot 'WHDNext/WHDNext.psd1') -Force
if ($Guard) {
    # the update guard's check: read-only, asks nothing, then ends (exit 0 = it ran; the front door alerts otherwise)
    $null = Initialize-WHDSession -Root $PSScriptRoot -DataRoot $DataRoot -LogName 'guard'
    $r = Invoke-WHDGuardRun
    exit $(if ($r) { 0 } else { 1 })
}
$info = Get-WHDEngineInfo
Write-Host ''
Write-Host ('  {0} {1}  -  PowerShell {2}' -f $info.Product, $info.Version, $info.PowerShell) -ForegroundColor Cyan
$session = Initialize-WHDSession -Root $PSScriptRoot -Execute:($Execute -and -not $UndoPreview) -SafeMode:$SafeMode
if ($UndoPreview -and $Execute) { Write-Host '  -UndoPreview is always a dry-run: -Execute is ignored.' -ForegroundColor Yellow }
$takeover = Invoke-WHDHistoryTakeover
Update-WHDGuardRefresh
if ($EngineTest) { $session = Invoke-WHDEngineTest }
if ($Verify) { $null = Invoke-WHDVerify -All; $session = Get-WHDSession }
if ($UndoPreview) { $null = Invoke-WHDUndo -All; $session = Get-WHDSession }
if ($Plan) { Invoke-WHDPlan; $session = Get-WHDSession }
if ($Menu) { Invoke-WHDMenu -Name $Menu; $session = Get-WHDSession }
if ($ProfileName) { Invoke-WHDProfileRun -Name $ProfileName; $session = Get-WHDSession }
if ($UndoTest) {
    $ids = @(Get-WHDUndoList | Where-Object { $_.Kind -eq 'reg' -and $_.Description -like '*\WinHardenDebloatNext\EngineTest\Step3*' } | ForEach-Object Id)
    if ($ids.Count) { $null = Invoke-WHDUndo -Id $ids } else { Write-Host '  No step 3 test value left to undo.' -ForegroundColor Yellow }
    $session = Get-WHDSession
}
if ($Gui) { Show-WHDWindow; $session = Get-WHDSession }
elseif (-not ($EngineTest -or $Verify -or $UndoPreview -or $UndoTest -or $Plan -or $Menu -or $ProfileName)) { Invoke-WHDMenu -Name Main; $session = Get-WHDSession }
Write-Host ''
Write-Host ('  Mode ............ {0}' -f $session.Mode)
Write-Host ('  Administrator ... {0}' -f $(if ($session.IsAdmin) { 'yes' } else { 'no' }))
Write-Host ('  Changes ......... planned {0}, done {1}, failed {2}, skipped {3}' -f $session.Planned, $session.Done, $session.Failed, $session.Skipped)
Write-Host ('  Restore point ... {0}' -f $(if ($session.RestoreDone) { 'made this session' } else { 'not needed (nothing real changed)' }))
Write-Host ('  Log ............. {0}' -f $session.LogFile)
if ($session.Done -gt 0) { Write-Host ('  Change history .. {0}' -f $session.RestoreFolder) }
$hist = @(Get-WHDHistory)
$nh = if ($takeover) { if ($takeover['Mode'] -eq 'copy') { 'copied once from ' + $takeover['Source'] } else { 'read in place from ' + $takeover['Source'] } } else { 'none taken over' }
$histChanges = 0; foreach ($h in $hist) { $histChanges += [int]$h.Entries }      # no Measure-Object: with no history it has no Sum (strict mode, P46)
Write-Host ('  History ......... {0} session(s), {1} change(s); WHD Next 2.0: {2}' -f $hist.Count, $histChanges, $nh)
Write-Host ''
Write-Host '  Session ended. The log above has everything that was done or planned.' -ForegroundColor DarkGray
Write-Host ''
