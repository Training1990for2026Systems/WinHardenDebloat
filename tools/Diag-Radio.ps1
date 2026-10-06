<#
================================================================================
 WinHardenDebloat  -  tools\Diag-Radio.ps1   (READ-ONLY diagnostic, 2026-09-28)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Finds what turns a radio (Bluetooth / Wi-Fi) "on but dormant" and then back off
 a minute or two later. Changes NOTHING. Writes one report to logs\.

 How it runs:
   1. Snapshot A  (as things are now)
   2. You switch the radio ON in Settings (Bluetooth and/or Wi-Fi), press Enter
   3. Snapshot B  (right after you switched it on)
   4. Waits 3 minutes (X skips the wait)
   5. Snapshot C, then prints what CHANGED between B and C, plus every System /
      Bluetooth / WLAN event logged between A and C.

   Run from an elevated PowerShell in the project folder:
   powershell -ExecutionPolicy Bypass -File .\tools\Diag-Radio.ps1
================================================================================
#>
[CmdletBinding()]
param([int]$WaitSeconds = 180)
$ErrorActionPreference = 'Continue'

$root   = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $root 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$report = Join-Path $logDir ('diag-radio_{0}.txt' -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
$lines  = New-Object System.Collections.Generic.List[string]
function Out-Rep { param([string]$T) $lines.Add($T); Write-Host $T }

$caps = @('radios', 'bluetoothSync', 'bluetooth', 'wiFiDirect', 'location')
$svcNames = @('bthserv', 'BTAGService', 'BthAvctpSvc', 'RmSvc', 'DeviceAssociationService', 'WlanSvc', 'WwanSvc', 'camsvc',
              'RasMan', 'RasAuto', 'SstpSvc', 'RemoteAccess', 'TapiSrv', 'IKEEXT', 'PolicyAgent', 'WinHttpAutoProxySvc',
              'LanmanWorkstation', 'LanmanServer', 'WFDSConMgrSvc', 'icssvc', 'NcbService', 'netprofm', 'NlaSvc', 'Dhcp',
              'DsmSvc', 'DeviceInstall', 'PlugPlay', 'mpssvc', 'BFE', 'iphlpsvc')

function Get-RegDump {
    param([string]$Path)
    $o = @()
    $k = Get-Item -LiteralPath $Path -EA SilentlyContinue
    if (-not $k) { return @("  $Path : (key missing)") }
    foreach ($n in $k.GetValueNames()) { $o += ("  {0} : {1} = {2}" -f $Path, $(if ($n) { $n } else { '(default)' }), (@($k.GetValue($n)) -join ',')) }
    if (-not $k.GetValueNames().Count) { $o += "  $Path : (no values)" }
    $o
}

function Get-Snapshot {
    $s = New-Object System.Collections.Generic.List[string]
    $s.Add('[consent store - radios / bluetooth / location]')
    foreach ($hive in 'HKCU', 'HKLM') {
        foreach ($c in $caps) {
            $p = "${hive}:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\$c"
            $v = try { (Get-ItemProperty -LiteralPath $p -Name Value -EA Stop).Value } catch { '(unset)' }
            $s.Add(("  {0} {1,-14} Value={2}" -f $hive, $c, $v))
            if ($hive -eq 'HKCU') {
                foreach ($sub in @(Get-ChildItem -LiteralPath $p -EA SilentlyContinue)) {
                    $sv = try { (Get-ItemProperty -LiteralPath $sub.PSPath -Name Value -EA Stop).Value } catch { '-' }
                    $s.Add(("      {0,-14} {1} Value={2}" -f $c, $sub.PSChildName, $sv))
                }
            }
        }
    }
    $s.Add('[App Privacy policy]');           foreach ($l in Get-RegDump 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy') { $s.Add($l) }
    $s.Add('[Radio management / airplane]');  foreach ($l in Get-RegDump 'HKLM:\SYSTEM\CurrentControlSet\Control\RadioManagement\SystemRadioState') { $s.Add($l) }
    $s.Add('[Device install restrictions]');  foreach ($l in Get-RegDump 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions') { $s.Add($l) }
    foreach ($l in Get-RegDump 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions\DenyDeviceIDs') { $s.Add($l) }
    $s.Add('[services  name  status/start]')
    foreach ($n in $svcNames) {
        $sv = Get-Service -Name $n -EA SilentlyContinue
        $s.Add($(if ($sv) { "  {0,-26} {1}/{2}" -f $n, $sv.Status, $sv.StartType } else { "  {0,-26} (not present)" -f $n }))
    }
    foreach ($sv in @(Get-Service -EA SilentlyContinue | Where-Object { $_.Name -like 'BluetoothUserService_*' -or $_.Name -like 'DevicesFlowUserSvc_*' -or $_.Name -like 'DeviceAssociationBrokerSvc_*' })) {
        $s.Add(("  {0,-26} {1}/{2}" -f $sv.Name, $sv.Status, $sv.StartType))
    }
    $s.Add('[network adapters (incl. hidden)  name | description | status | operational | media | admin]')
    foreach ($a in @(Get-NetAdapter -IncludeHidden -EA SilentlyContinue | Sort-Object Name)) {
        $s.Add(("  {0} | {1} | {2} | {3} | {4} | {5}" -f $a.Name, $a.InterfaceDescription, $a.Status, $a.InterfaceOperationalStatus, $a.MediaConnectionState, $a.AdminStatus))
    }
    $s.Add('[devices: Bluetooth + Net class  name | status | problem | present]')
    foreach ($d in @(Get-PnpDevice -EA SilentlyContinue | Where-Object { $_.Class -in @('Bluetooth', 'Net') } | Sort-Object Class, FriendlyName)) {
        $s.Add(("  [{0}] {1} | {2} | {3} | {4}" -f $d.Class, $d.FriendlyName, $d.Status, $d.ConfigManagerErrorCode, $d.Present))
    }
    $s.Add('[Bluetooth-looking devices, any class  class | name | status | problem | present]')
    foreach ($d in @(Get-PnpDevice -EA SilentlyContinue | Where-Object { "$($_.FriendlyName) $($_.InstanceId) $($_.Class)" -match 'Bluetooth|^BTH|\\BTH|VID_8087' } | Sort-Object Class, FriendlyName)) {
        $s.Add(("  [{0}] {1} | {2} | {3} | {4}" -f $d.Class, $d.FriendlyName, $d.Status, $d.ConfigManagerErrorCode, $d.Present))
    }
    $s.Add('[devices with a problem (any class, present)  class | name | problem | id]')
    foreach ($d in @(Get-PnpDevice -PresentOnly -EA SilentlyContinue | Where-Object { "$($_.ConfigManagerErrorCode)" -notmatch 'NONE|^0$' } | Sort-Object Class, FriendlyName)) {
        $s.Add(("  [{0}] {1} | {2} | {3}" -f $d.Class, $d.FriendlyName, $d.ConfigManagerErrorCode, $d.InstanceId))
    }
    $s.Add('[firewall profiles  name enabled in/out]')
    foreach ($fp in @(Get-NetFirewallProfile -EA SilentlyContinue)) { $s.Add(("  {0} {1} {2}/{3}" -f $fp.Name, $fp.Enabled, $fp.DefaultInboundAction, $fp.DefaultOutboundAction)) }
    ,$s.ToArray()
}

Out-Rep ('WinHardenDebloat - RADIO DIAGNOSTIC (read-only)   {0}   {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME)
try { $os = Get-CimInstance Win32_OperatingSystem; Out-Rep ('Windows: {0}  build {1}' -f $os.Caption, $os.BuildNumber) } catch { }
$t0 = Get-Date
Out-Rep ''; Out-Rep '==== SNAPSHOT A (as things are now) ===='
$A = Get-Snapshot; foreach ($l in $A) { Out-Rep $l }

Write-Host ''
Write-Host ' Now open Settings and switch the radio ON (Bluetooth and/or Wi-Fi) the way you normally do.' -ForegroundColor Yellow
Read-Host ' When it shows ON, press Enter here' | Out-Null
Out-Rep ''; Out-Rep ('==== SNAPSHOT B (right after switching ON)  {0} ====' -f (Get-Date -Format 'HH:mm:ss'))
$B = Get-Snapshot; foreach ($l in $B) { Out-Rep $l }

Write-Host ''
Write-Host (' Waiting {0} s so the problem can happen - leave it running (type X to stop early)...' -f $WaitSeconds) -ForegroundColor Yellow
try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } catch { }   # drop keys typed before the wait
$end = (Get-Date).AddSeconds($WaitSeconds)
while ((Get-Date) -lt $end) {
    if ([Console]::KeyAvailable) { $k = [Console]::ReadKey($true); if ($k.Key -eq 'X') { break } }
    Write-Host ("`r  {0,4} s left " -f [int](($end - (Get-Date)).TotalSeconds)) -NoNewline
    Start-Sleep -Milliseconds 500
}
Write-Host ''
Out-Rep ''; Out-Rep ('==== SNAPSHOT C (after the wait)  {0} ====' -f (Get-Date -Format 'HH:mm:ss'))
$C = Get-Snapshot; foreach ($l in $C) { Out-Rep $l }

Out-Rep ''; Out-Rep '==== CHANGED between A -> B (what switching ON changed) ===='
foreach ($d in @(Compare-Object -ReferenceObject $A -DifferenceObject $B)) { Out-Rep ('  {0} {1}' -f $(if ($d.SideIndicator -eq '=>') { 'NOW ' } else { 'WAS ' }), $d.InputObject) }
Out-Rep ''; Out-Rep '==== CHANGED between B -> C (what flipped back by itself) ===='
$bc = @(Compare-Object -ReferenceObject $B -DifferenceObject $C)
if (-not $bc.Count) { Out-Rep '  (nothing changed)' }
foreach ($d in $bc) { Out-Rep ('  {0} {1}' -f $(if ($d.SideIndicator -eq '=>') { 'NOW ' } else { 'WAS ' }), $d.InputObject) }

Out-Rep ''; Out-Rep '==== EVENTS between A and C (System + Bluetooth + WLAN + device setup) ===='
$logs = @('System', 'Microsoft-Windows-WLAN-AutoConfig/Operational', 'Microsoft-Windows-Bluetooth-BthLEPrepairing/Operational',
          'Microsoft-Windows-Bluetooth-MTPEnum/Operational', 'Microsoft-Windows-Kernel-PnP/Configuration', 'Microsoft-Windows-DeviceSetupManager/Admin',
          'Microsoft-Windows-DeviceSetupManager/Operational', 'Microsoft-Windows-NetworkProfile/Operational')
$ev = foreach ($ln in $logs) { Get-WinEvent -FilterHashtable @{ LogName = $ln; StartTime = $t0 } -MaxEvents 400 -EA SilentlyContinue }
foreach ($e in @($ev | Sort-Object TimeCreated)) {
    $msg = (("$($e.Message)" -split "`r?`n")[0])
    if ($msg.Length -gt 180) { $msg = $msg.Substring(0, 180) }
    Out-Rep ('  {0:HH:mm:ss}  {1,-45} {2,5}  {3}' -f $e.TimeCreated, $e.ProviderName, $e.Id, $msg)
}
if (-not @($ev).Count) { Out-Rep '  (no events)' }

Out-Rep ''; Out-Rep '==== BUSIEST PROCESSES (total CPU seconds so far) - for the "sluggish" check ===='
foreach ($pp in @(Get-Process -EA SilentlyContinue | Sort-Object CPU -Descending | Select-Object -First 12)) {
    Out-Rep ('  {0,-32} cpu {1,8:N1} s   pid {2}' -f $pp.ProcessName, $pp.CPU, $pp.Id)
}
Out-Rep ''; Out-Rep '==== DEVICE-INSTALL ATTEMPTS in the last 24 h (a blocked install retrying shows up here) ===='
$dev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Kernel-PnP/Configuration'; StartTime = (Get-Date).AddHours(-24) } -MaxEvents 2000 -EA SilentlyContinue)
Out-Rep ('  Kernel-PnP configuration events: {0}' -f $dev.Count)
foreach ($g in @($dev | Group-Object Id | Sort-Object Count -Descending | Select-Object -First 6)) { Out-Rep ('  event {0,5}: {1} time(s)' -f $g.Name, $g.Count) }
foreach ($e in @($dev | Where-Object { $_.Id -in @(411, 412, 440, 441, 442) } | Select-Object -First 10)) {
    $m = (("$($e.Message)" -split "`r?`n")[0]); if ($m.Length -gt 160) { $m = $m.Substring(0, 160) }
    Out-Rep ('  {0:MM-dd HH:mm:ss}  {1,4}  {2}' -f $e.TimeCreated, $e.Id, $m)
}

$lines | Set-Content -LiteralPath $report -Encoding UTF8
Write-Host ''
Write-Host (' Report saved: {0}' -f $report) -ForegroundColor Green
Write-Host ' Nothing was changed. The report contains this PC''s name and device IDs - check it before sharing.' -ForegroundColor Green
