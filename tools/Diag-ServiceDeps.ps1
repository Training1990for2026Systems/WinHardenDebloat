<#
================================================================================
 WinHardenDebloat  -  tools\Diag-ServiceDeps.ps1   (READ-ONLY diagnostic, 2026-09-29)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Lists what depends on a Windows service, so you can see what stops working
 when that service is turned off - for example why Wi-Fi stops when the WinHTTP
 proxy service (WinHttpAutoProxySvc, the default target) is disabled. Read from
 the PC's own configuration and event log. Changes NOTHING.

   1. Which services depend on the target service (directly and further down).
   2. The full "needs these to run" chain of WLAN AutoConfig (WlanSvc) and
      IP Helper (iphlpsvc) - where the target appears in it.
   3. Service Control Manager errors from the last days (7000/7001/7003/7023/
      7024/7026) - e.g. "WLAN AutoConfig depends on X which failed to start".
   4. Start type, triggers and configured dependencies (sc.exe qc / qtriggerinfo).

   Run in an elevated PowerShell in the project folder:
   powershell -ExecutionPolicy Bypass -File .\tools\Diag-ServiceDeps.ps1
   (optional: -Target <service name> -Days <n>)
================================================================================
#>
[CmdletBinding()]
param([string]$Target = 'WinHttpAutoProxySvc', [int]$Days = 3)
$ErrorActionPreference = 'Continue'

$root   = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $root 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$report = Join-Path $logDir ('diag-svcdeps_{0}.txt' -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
$lines  = New-Object System.Collections.Generic.List[string]
function Out-Rep { param([string]$T) $lines.Add($T); Write-Host $T }
$svcRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services'

function Get-SvcLine {
    param([string]$Name)
    $s = Get-Service -Name $Name -EA SilentlyContinue
    if (-not $s) { return ('{0} (not a service / not present)' -f $Name) }
    '{0} [{1}]  {2}/{3}' -f $s.Name, $s.DisplayName, $s.Status, $s.StartType
}
# Registry DependOnService / DependOnGroup = the exact configured dependencies.
function Get-SvcDependsOn {
    param([string]$Name)
    $k = Get-ItemProperty -LiteralPath (Join-Path $svcRoot $Name) -EA SilentlyContinue
    if (-not $k) { return @() }
    @(@($k.DependOnService) + @($k.DependOnGroup | ForEach-Object { "group:$_" }) | Where-Object { $_ })
}
function Show-NeedsTree {
    param([string]$Name, [int]$Depth = 0, [System.Collections.Generic.HashSet[string]]$Seen)
    if (-not $Seen) { $Seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase) }
    $mark = if ($Name -ieq $Target) { '   <== TARGET' } else { '' }
    Out-Rep (('  ' * ($Depth + 1)) + '- ' + (Get-SvcLine $Name) + $mark)
    if (-not $Seen.Add($Name) -or $Depth -gt 6) { return }
    foreach ($d in (Get-SvcDependsOn $Name)) { if ($d -notlike 'group:*') { Show-NeedsTree -Name $d -Depth ($Depth + 1) -Seen $Seen } else { Out-Rep (('  ' * ($Depth + 2)) + '- ' + $d) } }
}

Out-Rep ('WinHardenDebloat - SERVICE DEPENDENCY DIAGNOSTIC (read-only)   {0}   {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME)
try { $os = Get-CimInstance Win32_OperatingSystem; Out-Rep ('Windows: {0}  build {1}' -f $os.Caption, $os.BuildNumber) } catch { }
Out-Rep ('Target service: {0}' -f (Get-SvcLine $Target))

Out-Rep ''; Out-Rep ('==== 1. SERVICES THAT NEED {0} (they cannot start while it is disabled) ====' -f $Target)
$direct = @(Get-ChildItem -LiteralPath $svcRoot -EA SilentlyContinue | Where-Object {
    $d = (Get-ItemProperty -LiteralPath $_.PSPath -Name DependOnService -EA SilentlyContinue).DependOnService
    @($d) -contains $Target })
if (-not $direct.Count) { Out-Rep '  (no service lists it in DependOnService)' }
foreach ($k in $direct) {
    Out-Rep ('  - ' + (Get-SvcLine $k.PSChildName))
    foreach ($k2 in @(Get-ChildItem -LiteralPath $svcRoot -EA SilentlyContinue | Where-Object {
            @((Get-ItemProperty -LiteralPath $_.PSPath -Name DependOnService -EA SilentlyContinue).DependOnService) -contains $k.PSChildName })) {
        Out-Rep ('      - (needs {0}) {1}' -f $k.PSChildName, (Get-SvcLine $k2.PSChildName))
    }
}

foreach ($top in 'WlanSvc', 'iphlpsvc', 'Wcmsvc', 'Dhcp', 'Dnscache', 'NlaSvc') {
    Out-Rep ''; Out-Rep ('==== 2. WHAT {0} NEEDS TO RUN (configured dependency chain) ====' -f $top)
    Show-NeedsTree -Name $top
}

Out-Rep ''; Out-Rep ('==== 3. SERVICE START ERRORS in the last {0} day(s) (Service Control Manager) ====' -f $Days)
$ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7000, 7001, 7003, 7023, 7024, 7026; StartTime = (Get-Date).AddDays(-1 * $Days) } -MaxEvents 300 -EA SilentlyContinue)
if (-not $ev.Count) { Out-Rep '  (none)' }
foreach ($e in @($ev | Sort-Object TimeCreated)) {
    $m = (("$($e.Message)" -replace "`r?`n", ' ') -replace '\s+', ' ')
    if ($m.Length -gt 220) { $m = $m.Substring(0, 220) }
    Out-Rep ('  {0:MM-dd HH:mm:ss}  {1,5}  {2}' -f $e.TimeCreated, $e.Id, $m)
}

Out-Rep ''; Out-Rep '==== 4. CONFIGURATION (sc.exe qc + qtriggerinfo) ===='
foreach ($n in $Target, 'WlanSvc', 'iphlpsvc', 'Wcmsvc') {
    Out-Rep ('  ---- {0} ----' -f $n)
    foreach ($a in @('qc', 'qtriggerinfo')) {
        $o = @(& sc.exe $a $n 2>&1 | ForEach-Object { "$_" } | Where-Object { $_.Trim() })
        foreach ($l in $o) { Out-Rep ('    ' + $l.TrimEnd()) }
    }
}

$lines | Set-Content -LiteralPath $report -Encoding UTF8
Write-Host ''
Write-Host (' Report saved: {0}' -f $report) -ForegroundColor Green
Write-Host ' Nothing was changed. The report contains this PC''s name and device IDs - check it before sharing.' -ForegroundColor Green
