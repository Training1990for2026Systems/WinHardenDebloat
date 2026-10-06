<#
================================================================================
 WHD Next  -  tools\Get-WHDCimInfo.ps1   (development tool, READ-ONLY)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Build step 5 helper. Microsoft's web pages for the Defender CIM classes are out
 of date, so this reads the facts from THIS PC instead:
   * which parameters the CIM methods WHD Next calls really have, and their types
   * the numbers behind the "UpdateSource" names used by Update-MpSignature
   * the current Defender values WHD's write test will touch (numbers only)

 It CHANGES NOTHING. It only reads class definitions and current values, and
 writes one text report to  next\reports\ciminfo_<date_time>.txt .

   pwsh -ExecutionPolicy Bypass -File .\next\tools\Get-WHDCimInfo.ps1
   (Windows PowerShell 5.1 works too.)
================================================================================
#>
[CmdletBinding()]
param([string]$ReportRoot)

$ErrorActionPreference = 'Continue'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$nextDir  = Split-Path -Parent $toolsDir
if (-not $ReportRoot) { $ReportRoot = Join-Path $nextDir 'reports' }
if (-not (Test-Path -LiteralPath $ReportRoot)) { New-Item -ItemType Directory -Path $ReportRoot -Force | Out-Null }
$out = New-Object System.Collections.Generic.List[string]
function Add-Line { param([string]$Text = '') $out.Add($Text) }

$defNs = 'root/Microsoft/Windows/Defender'
Add-Line 'WHD Next - CIM facts from this PC (read-only)'
Add-Line ('Created : {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Add-Line ('Engine  : {0} {1}' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
Add-Line ''

function Add-MethodInfo {
    param([string]$Namespace, [string]$ClassName, [string]$Method, [string[]]$Only)
    try {
        $cls = Get-CimClass -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop
        $m = $cls.CimClassMethods[$Method]
        if (-not $m) { Add-Line ('  {0}.{1}: METHOD NOT FOUND' -f $ClassName, $Method); return }
        $all = @($m.Parameters)
        Add-Line ('  {0}.{1}  ({2} parameters, returns {3})' -f $ClassName, $Method, $all.Count, $m.ReturnType)
        foreach ($p in $all) {
            if ($Only -and ($Only -notcontains $p.Name)) { continue }
            $q = @($p.Qualifiers | Where-Object { $_.Name -in @('ValueMap', 'Values', 'In', 'Out') } | ForEach-Object {
                if ($_.Value -is [array]) { '{0}=[{1}]' -f $_.Name, (@($_.Value) -join ',') } else { '{0}={1}' -f $_.Name, $_.Value } })
            Add-Line ('      {0,-44} {1,-12} {2}' -f $p.Name, $p.CimType, ($q -join '  '))
        }
        if ($Only) {
            foreach ($n in $Only) { if (-not ($all | Where-Object { $_.Name -eq $n })) { Add-Line ('      {0,-44} NOT A PARAMETER OF THIS METHOD' -f $n) } }
        }
    } catch { Add-Line ('  {0}.{1}: could not be read: {2}' -f $ClassName, $Method, $_.Exception.Message) }
}

Add-Line '== 1. Defender settings class: the parameters WHD Next uses =='
$used = @('PUAProtection', 'EnableNetworkProtection', 'EnableControlledFolderAccess', 'AttackSurfaceReductionRules_Ids', 'AttackSurfaceReductionRules_Actions')
Add-MethodInfo -Namespace $defNs -ClassName 'MSFT_MpPreference' -Method 'Set'    -Only $used
Add-MethodInfo -Namespace $defNs -ClassName 'MSFT_MpPreference' -Method 'Add'    -Only @('AttackSurfaceReductionRules_Ids', 'AttackSurfaceReductionRules_Actions')
Add-MethodInfo -Namespace $defNs -ClassName 'MSFT_MpPreference' -Method 'Remove' -Only @('AttackSurfaceReductionRules_Ids', 'AttackSurfaceReductionRules_Actions')
Add-Line ''

Add-Line '== 2. Defender definitions class (replacement for Update-MpSignature) =='
Add-MethodInfo -Namespace $defNs -ClassName 'MSFT_MpSignature' -Method 'Update'
Add-Line ''

Add-Line '== 3. How Microsoft''s own Update-MpSignature command maps to that method (from its definition file) =='
try {
    $modBase = $null
    foreach ($name in @('ConfigDefender', 'Defender')) {
        $mod = Get-Module -ListAvailable -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($mod) { $modBase = $mod.ModuleBase; break }
    }
    if (-not $modBase) {
        $guess = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules\ConfigDefender'
        if (Test-Path -LiteralPath $guess) { $modBase = $guess }
    }
    if (-not $modBase) { Add-Line '  Defender module folder not found.' }
    else {
        Add-Line ('  module folder: {0}' -f $modBase)
        $cdxml = Get-ChildItem -LiteralPath $modBase -Filter 'MSFT_MpSignature.cdxml' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $cdxml) { Add-Line '  MSFT_MpSignature.cdxml not found.' }
        else {
            [xml]$x = Get-Content -LiteralPath $cdxml.FullName -Raw
            foreach ($en in @($x.SelectNodes("//*[local-name()='Enum']"))) {
                $vals = @($en.SelectNodes("*[local-name()='Value']") | ForEach-Object { '{0}={1}' -f $_.Name, $_.Value })
                Add-Line ('  enum {0} ({1}): {2}' -f $en.EnumName, $en.UnderlyingType, ($vals -join ', '))
            }
            foreach ($mt in @($x.SelectNodes("//*[local-name()='Method']"))) {
                Add-Line ('  method used: {0}' -f $mt.MethodName)
                foreach ($pa in @($mt.SelectNodes(".//*[local-name()='Parameter']"))) {
                    $ty = $pa.SelectSingleNode("*[local-name()='Type']")
                    $tn = ''; if ($ty) { $tn = $ty.PSType }
                    Add-Line ('      parameter {0,-40} {1}' -f $pa.ParameterName, $tn)
                }
            }
        }
    }
} catch { Add-Line ('  could not read the definition file: {0}' -f $_.Exception.Message) }
Add-Line ''

Add-Line '== 4. System Restore class =='
Add-MethodInfo -Namespace 'root/default' -ClassName 'SystemRestore' -Method 'Enable'
Add-MethodInfo -Namespace 'root/default' -ClassName 'SystemRestore' -Method 'CreateRestorePoint'
try {
    $rp = @(Get-CimInstance -Namespace 'root/default' -ClassName 'SystemRestore' -ErrorAction Stop)
    Add-Line ('  restore points on this PC: {0}' -f $rp.Count)
    foreach ($r in ($rp | Sort-Object SequenceNumber | Select-Object -Last 5)) {
        Add-Line ('      #{0}  type {1}  {2}' -f $r.SequenceNumber, $r.RestorePointType, $r.Description)
    }
} catch { Add-Line ('  restore points could not be listed: {0}  (needs a terminal opened with "Run as administrator")' -f $_.Exception.Message) }
Add-Line ''

Add-Line '== 5. Current Defender values (numbers only) =='
try {
    $mp = Get-CimInstance -Namespace $defNs -ClassName 'MSFT_MpPreference' -ErrorAction Stop
    foreach ($n in @('PUAProtection', 'EnableNetworkProtection', 'EnableControlledFolderAccess')) { Add-Line ('  {0,-32} {1}' -f $n, $mp.$n) }
    $ids = @($mp.AttackSurfaceReductionRules_Ids | Where-Object { $_ }); $acts = @($mp.AttackSurfaceReductionRules_Actions)
    Add-Line ('  attack surface rules configured  {0}' -f $ids.Count)
    for ($i = 0; $i -lt $ids.Count; $i++) { Add-Line ('      {0}  action {1}' -f $ids[$i], $acts[$i]) }
} catch { Add-Line ('  settings could not be read: {0}' -f $_.Exception.Message) }
try {
    $st = Get-CimInstance -Namespace $defNs -ClassName 'MSFT_MpComputerStatus' -ErrorAction Stop
    Add-Line ('  {0,-32} {1}' -f 'AntivirusEnabled', $st.AntivirusEnabled)
    Add-Line ('  {0,-32} {1}' -f 'AMRunningMode', $st.AMRunningMode)
    Add-Line ('  {0,-32} {1}' -f 'IsTamperProtected', $st.IsTamperProtected)
    Add-Line ('  {0,-32} {1}' -f 'AntivirusSignatureVersion', $st.AntivirusSignatureVersion)
    Add-Line ('  {0,-32} {1}' -f 'AntivirusSignatureAge (days)', $st.AntivirusSignatureAge)
} catch { Add-Line ('  status could not be read: {0}' -f $_.Exception.Message) }
Add-Line ''

Add-Line '== 6. Event log source for guard alerts =='
try { Add-Line ('  source "WHD Next" registered: {0}' -f (Test-Path -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\WHD Next')) }
catch { Add-Line ('  could not be checked: {0}' -f $_.Exception.Message) }

$file = Join-Path $ReportRoot ('ciminfo_{0}.txt' -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
$out | Set-Content -LiteralPath $file -Encoding ASCII
$out | ForEach-Object { Write-Host $_ }
Write-Host ''
Write-Host (' Report: {0}' -f $file) -ForegroundColor Cyan
Write-Host ' Nothing on this PC was changed.' -ForegroundColor Green
