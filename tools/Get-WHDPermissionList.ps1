#requires -Version 7.6 -PSEdition Core
<#
================================================================================
 WHD Next 3.0  -  tools\Get-WHDPermissionList.ps1   (READ-ONLY)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Lists every app permission Windows keeps on this PC - the entries behind
 Settings > Privacy & security > App permissions - so the Permissions module
 (build step 5.6, D43) can show the full list. Changes NOTHING.
 For each permission: this user's switch, the PC-wide switch, the desktop-apps
 switch, how many apps have their own entry, and every App Privacy policy value.
 Writes the report to logs\permission-list_<date>_<time>.txt and shows it.
 Run from the WHD-Next-pwsh folder in PowerShell 7.6:
   .\tools\Get-WHDPermissionList.ps1
 -Watch : finds where Windows keeps a switch. Takes a snapshot of this user's
          Windows settings, the consent store and the policy keys, waits while
          you flip switches in Settings, takes a second snapshot and lists every
          value that changed. Still changes nothing itself. Report:
          logs\permission-watch_<date>_<time>.txt
   .\tools\Get-WHDPermissionList.ps1 -Watch
================================================================================
#>
[CmdletBinding()]
param([switch]$Watch)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Continue'

$hkcu = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'
$hklm = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'
$pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
$lines = [System.Collections.Generic.List[string]]::new()
function Add-Line { param([string]$Text = '') $lines.Add($Text) }

# ---- -Watch: before / after snapshot of the registry areas Settings writes to ----------------
$script:WatchRoots = @(
    @{ Hive = 'HKCU'; Path = 'Software\Microsoft\Windows\CurrentVersion' }
    @{ Hive = 'HKCU'; Path = 'Software\Microsoft\Speech_OneCore' }
    @{ Hive = 'HKCU'; Path = 'Software\Policies' }
    @{ Hive = 'HKLM'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager' }
    @{ Hive = 'HKLM'; Path = 'SOFTWARE\Policies\Microsoft\Windows' }
)

function Get-RegValueText {
    param($Key, [string]$Name)
    $kind = $Key.GetValueKind($Name)
    $v = $Key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $t = if ($v -is [byte[]]) { ($v | ForEach-Object { $_.ToString('X2') }) -join '' } elseif ($v -is [array]) { $v -join '|' } else { [string]$v }
    if ($t.Length -gt 200) { $t = $t.Substring(0, 200) + '...' }
    return ('{0}:{1}' -f $kind, $t)
}

function Get-RegSnapshot {
    # Every value under the watch roots: 'HIVE\path\name' -> 'Kind:value'. Read only.
    $snap = @{}
    foreach ($r in $script:WatchRoots) {
        $base = if ($r.Hive -eq 'HKCU') { [Microsoft.Win32.Registry]::CurrentUser } else { [Microsoft.Win32.Registry]::LocalMachine }
        $stack = [System.Collections.Generic.Stack[string]]::new()
        $stack.Push($r.Path)
        while ($stack.Count) {
            $p = $stack.Pop()
            $k = $null
            try { $k = $base.OpenSubKey($p, $false) } catch { $k = $null }
            if (-not $k) { continue }
            try {
                foreach ($n in $k.GetValueNames()) { try { $snap[('{0}\{1}\{2}' -f $r.Hive, $p, $n)] = Get-RegValueText -Key $k -Name $n } catch { $snap[('{0}\{1}\{2}' -f $r.Hive, $p, $n)] = '(unreadable)' } }
                foreach ($sk in $k.GetSubKeyNames()) { $stack.Push(('{0}\{1}' -f $p, $sk)) }
                $snap[('{0}\{1}\' -f $r.Hive, $p)] = '(key)'
            } catch { Write-Verbose ('skipped {0}' -f $p) }
            finally { $k.Dispose() }
        }
    }
    return $snap
}

function Compare-RegSnapshot {
    # Lines for every value added, removed or changed between two snapshots (pure).
    param([hashtable]$Before, [hashtable]$After)
    $out = foreach ($n in @($After.Keys | Sort-Object)) {
        if (-not $Before.ContainsKey($n)) { if ($n.EndsWith('\')) { 'NEW KEY  {0}' -f $n } else { 'NEW      {0} = {1}' -f $n, $After[$n] } }
        elseif ($Before[$n] -ne $After[$n]) { 'CHANGED  {0}' -f $n; '           before {0}' -f $Before[$n]; '           after  {0}' -f $After[$n] }
    }
    $gone = foreach ($n in @($Before.Keys | Sort-Object)) { if (-not $After.ContainsKey($n)) { 'GONE     {0} (was {1})' -f $n, $Before[$n] } }
    return @(@($out) + @($gone))
}

if ($Watch) {
    Write-Output 'WATCH (read only): taking the first snapshot ...'
    $before = Get-RegSnapshot
    Write-Output ('  {0:N0} values read.' -f $before.Count)
    Write-Output ''
    Write-Output '  Now, in Settings > Privacy & security, flip the switches to find (for example'
    Write-Output '  Downloads folder, then Automatic file downloads): change each one, then put it back if you like.'
    [void](Read-Host '  Press Enter when done')
    $after = Get-RegSnapshot
    $diff = @(Compare-RegSnapshot -Before $before -After $after)
    $lines.Add(('WHD Next 3.0 - permission WATCH (read-only)   {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
    $lines.Add(('Snapshots: {0:N0} values before, {1:N0} after; {2} line(s) of difference' -f $before.Count, $after.Count, $diff.Count))
    $lines.Add('')
    if (-not $diff.Count) { $lines.Add('(nothing changed in the watched areas)') }
    foreach ($d in $diff) { $lines.Add($d) }
    $logDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) { [void](New-Item -ItemType Directory -Path $logDir -Force) }
    $out = Join-Path $logDir ('permission-watch_{0}.txt' -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
    Set-Content -LiteralPath $out -Value $lines -Encoding ascii
    $lines | ForEach-Object { Write-Output $_ }
    Write-Output ''
    Write-Output ('Saved: {0}' -f $out)
    return
}

function Get-SwitchValue {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '-' }
    $k = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $k -or (@($k.GetValueNames()) -notcontains 'Value')) { return '(unset)' }
    return [string]$k.GetValue('Value')
}

$cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
$get = { param($n) if ($cv -and $cv.PSObject.Properties[$n]) { [string]$cv.$n } else { '?' } }
Add-Line ('WHD Next 3.0 - app permission list (read-only)   {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Add-Line ('PC {0} | {1} {2} | build {3}.{4} | PowerShell {5}' -f $env:COMPUTERNAME, (& $get 'ProductName'), (& $get 'DisplayVersion'), (& $get 'CurrentBuild'), (& $get 'UBR'), $PSVersionTable.PSVersion)
Add-Line ('Edition: {0}' -f (& $get 'EditionID'))
Add-Line ''

$names = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($root in $hkcu, $hklm) {
    if (Test-Path -LiteralPath $root) { foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) { [void]$names.Add([string]$k.PSChildName) } }
}
Add-Line ('PERMISSIONS FOUND: {0}' -f $names.Count)
Add-Line ('{0,-40} {1,-8} {2,-8} {3,-10} {4}' -f 'permission (Windows name)', 'user', 'PC-wide', 'desktop', 'apps listed')
Add-Line ('{0,-40} {1,-8} {2,-8} {3,-10} {4}' -f '-------------------------', '----', '-------', '-------', '-----------')
foreach ($n in $names) {
    $uPath = Join-Path $hkcu $n
    $apps = 0
    if (Test-Path -LiteralPath $uPath) {
        $apps = @(Get-ChildItem -LiteralPath $uPath -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -ne 'NonPackaged' }).Count
        $np = Join-Path $uPath 'NonPackaged'
        if (Test-Path -LiteralPath $np) { $apps += @(Get-ChildItem -LiteralPath $np -ErrorAction SilentlyContinue).Count }
    }
    Add-Line ('{0,-40} {1,-8} {2,-8} {3,-10} {4}' -f $n, (Get-SwitchValue -Path $uPath), (Get-SwitchValue -Path (Join-Path $hklm $n)), (Get-SwitchValue -Path (Join-Path $uPath 'NonPackaged')), $apps)
}
Add-Line ''
Add-Line 'APP PRIVACY POLICY VALUES (HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy; 0 user decides, 1 force allow, 2 force deny)'
if (Test-Path -LiteralPath $pol) {
    $pk = Get-Item -LiteralPath $pol -ErrorAction SilentlyContinue
    $vn = @(if ($pk) { $pk.GetValueNames() | Sort-Object })
    if (-not $vn.Count) { Add-Line '  (none)' }
    foreach ($v in $vn) { Add-Line ('  {0,-45} {1}' -f $v, $pk.GetValue($v)) }
} else { Add-Line '  (no policy key)' }

Add-Line ''
Add-Line 'POLICY DEFINITIONS ON THIS PC (C:\Windows\PolicyDefinitions - Windows'' own lock names; read only)'
$pd = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'PolicyDefinitions' } else { '' }
foreach ($file in $(if ($pd) { 'AppPrivacy', 'CAM_AI', 'Speech', 'StorageSense' })) {
    $admx = Join-Path $pd ('{0}.admx' -f $file)
    if (-not (Test-Path -LiteralPath $admx)) { Add-Line ('  {0}.admx: not on this PC' -f $file); continue }
    $text = @{}
    $adml = Join-Path $pd ('en-US\{0}.adml' -f $file)
    if (Test-Path -LiteralPath $adml) {
        try {
            [xml]$lx = Get-Content -LiteralPath $adml -Raw
            foreach ($s in @($lx.SelectNodes("//*[local-name()='string']"))) { $text[[string]$s.GetAttribute('id')] = [string]$s.InnerText }
        } catch { Add-Line ('  {0}.adml could not be read: {1}' -f $file, $_.Exception.Message) }
    }
    try { [xml]$x = Get-Content -LiteralPath $admx -Raw }
    catch { Add-Line ('  {0}.admx could not be read: {1}' -f $file, $_.Exception.Message); continue }
    Add-Line ('  {0}.admx' -f $file)
    foreach ($p in @($x.SelectNodes("//*[local-name()='policy']"))) {
        $disp = [string]$p.GetAttribute('displayName') -replace '^\$\(string\.(.+)\)$', '$1'
        $name = if ($text.ContainsKey($disp)) { $text[$disp] } else { $disp }
        $vals = @($p.SelectNodes(".//*[@valueName]") | ForEach-Object { [string]$_.GetAttribute('valueName') } | Where-Object { $_ -and $_ -notmatch '_(ForceAllow|ForceDeny|UserInControlOf)TheseApps$' } | Select-Object -Unique)
        if ($p.GetAttribute('valueName')) { $vals = @([string]$p.GetAttribute('valueName')) + $vals }
        Add-Line ('    {0,-34} {1}' -f ($vals -join ' / '), $name)
        Add-Line ('    {0,-34}   key: {1}' -f '', [string]$p.GetAttribute('key'))
    }
}

$logDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { [void](New-Item -ItemType Directory -Path $logDir -Force) }
$out = Join-Path $logDir ('permission-list_{0}.txt' -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
Set-Content -LiteralPath $out -Value $lines -Encoding ascii
$lines | ForEach-Object { Write-Output $_ }
Write-Output ''
Write-Output ('Saved: {0}' -f $out)
