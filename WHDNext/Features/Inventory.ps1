#requires -Version 7.6
<#
================================================================================
 WHD Next 3.0  -  Features/Inventory.ps1   (build step 6a)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 READ-ONLY - changes nothing, in every mode. Same features as WHD Next 2.0's
 Inventory.ps1 (D8), written new for 7.6 (main menu 1 and D, D81):
   1  inventory   Store apps installed vs staged (provisioned) for new users,
                  C:\Windows\SystemApps (+ SxS), optional features (Recall),
                  Windows capabilities, WinSxS manifests, AppLocker readiness
                  (Application Identity service + cache files), installed
                  programs (uninstall registry). Every AI-related surface is
                  flagged. CSV files + REPORT.txt in inventory\<time>\; each
                  scan is compared with the previous scan of THIS PC.
   D  compare     the two newest scans of this PC (or two named ones): NEW,
                  GONE, CHANGED per surface; an app WHD removed that is back is
                  marked CAME BACK. Saved as DIFF-vs-<older>.txt / .csv.
 The AppLocker policy itself is not read: its commands come from Windows
 PowerShell 5.1, which 3.0 never borrows (rebuild plan, rules for the code).
 Scans are tagged with this PC (MachineGuid); another PC's scans never count.
================================================================================
#>

# AI-related package names (flag only, never an action) - Windows 11 24H2 / 25H2.
$script:WHDInvAiTags = [ordered]@{
    'Copilot'        = @('Microsoft.Copilot', 'MicrosoftWindows.Client.CoPilot', '*Copilot*')
    'M365 Copilot'   = @('Microsoft.MicrosoftOfficeHub')
    'Cortana'        = @('Microsoft.549981C3F5F10')
    'Power Automate' = @('Microsoft.PowerAutomateDesktop')
    'AI platform'    = @('MicrosoftWindows.Client.CoreAI', 'MicrosoftWindows.Client.AIX', 'Microsoft.AIFabric.CBS*', 'Microsoft.Windows.AugLoop.CBS')
    'AI agents/MCP'  = @('MdOdrMcpFilterPackage', '*McpFilter*')
    'Web Experience' = @('MicrosoftWindows.Client.WebExperience', 'Microsoft.WidgetsPlatformRuntime')
    'Bing'           = @('Microsoft.BingSearch', 'Microsoft.BingWeather', 'Microsoft.BingNews')
    'Notepad (AI)'   = @('Microsoft.WindowsNotepad')
    'Paint (AI)'     = @('Microsoft.Paint')
    'Photos (AI)'    = @('Microsoft.Windows.Photos')
    'Phone Link'     = @('Microsoft.YourPhone')
}
$script:WHDInvSurfaces = @(
    @{ S = 'Store apps';         F = 'appx-packages.csv';     K = 'Name';        X = @('State', 'Version') }
    @{ S = 'Optional features';  F = 'optional-features.csv'; K = 'FeatureName'; X = @('State') }
    @{ S = 'Capabilities';       F = 'capabilities.csv';      K = 'Name';        X = @('State') }
    @{ S = 'Installed programs'; F = 'win32-apps.csv';        K = 'DisplayName'; X = @('Version') }
    @{ S = 'SystemApps folders'; F = 'systemapps.csv';        K = 'Folder';      X = @() }
)
$script:WHDInvOverride = $null       # tests only: the inventory folder
$script:WHDInvWinDirOverride = $null # tests only: the Windows folder

function Get-WHDInvRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($script:WHDInvOverride) { return $script:WHDInvOverride }
    return (Join-Path $script:WHDState.DataRoot 'inventory')
}
function Get-WHDInvWinDir {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($script:WHDInvWinDirOverride) { return $script:WHDInvWinDirOverride }
    if ($env:windir) { return $env:windir }
    if ($env:SystemRoot) { return $env:SystemRoot }
    return 'C:\Windows'
}
function Get-WHDInvAiTag {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Name)
    if (-not $Name) { return '' }
    $base = $Name -replace '_[0-9a-z]{13}$', ''           # SystemApps folders carry the publisher hash
    foreach ($k in $script:WHDInvAiTags.Keys) { foreach ($p in $script:WHDInvAiTags[$k]) { if ($Name -like $p -or $base -like $p) { return $k } } }
    return ''
}

# ---- Windows itself, read-only (tests swap these) -------------------------------------------------------------------
function Get-WHDInvOs {
    [CmdletBinding()]
    param()
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Caption = [string]$os.Caption; Version = [string]$os.Version; BuildNumber = [string]$os.BuildNumber
        UBR = $(if ($cv -and $cv.PSObject.Properties['UBR']) { [string]$cv.UBR } else { '' })
        DisplayVer = $(if ($cv -and $cv.PSObject.Properties['DisplayVersion']) { [string]$cv.DisplayVersion } else { '' })
        Architecture = [string]$os.OSArchitecture
    }
}
function Get-WHDInvAppx {
    [CmdletBinding()]
    param([switch]$AllUsers)
    if ($AllUsers) { return @(Get-AppxPackage -AllUsers -ErrorAction Stop) }
    return @(Get-AppxPackage -ErrorAction Stop)
}
function Get-WHDInvProvisioned { [CmdletBinding()] param() return @(Get-AppxProvisionedPackage -Online -ErrorAction Stop) }
function Get-WHDInvFeature { [CmdletBinding()] param() return @(Get-WindowsOptionalFeature -Online -ErrorAction Stop | Select-Object FeatureName, State) }
function Get-WHDInvCapability { [CmdletBinding()] param() return @(Get-WindowsCapability -Online -ErrorAction Stop | Select-Object Name, State) }
function Get-WHDInvFolder {
    # Sub-folders of one folder (names and paths), or none.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-ChildItem -LiteralPath $Path -Directory -ErrorAction SilentlyContinue)
}
function Get-WHDInvFileCount {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    return @(Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue).Count
}
function Get-WHDInvAppLocker {
    # Application Identity service (AppLocker rules are ignored when it does not run) and the cache files.
    [CmdletBinding()]
    param()
    $svc = Get-Service -Name AppIDSvc -ErrorAction SilentlyContinue
    $start = $null
    try { $start = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\AppIDSvc' -ErrorAction Stop).Start } catch { $start = $null }
    $dir = [System.IO.Path]::Combine((Get-WHDInvWinDir), 'System32', 'AppLocker')
    $files = @(if (Test-Path -LiteralPath $dir) { Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Select-Object Name, Length, LastWriteTime })
    [pscustomobject]@{
        Status = $(if ($svc) { [string]$svc.Status } else { 'unknown' })
        StartType = $(switch ($start) { 2 { 'Automatic' } 3 { 'Manual' } 4 { 'Disabled' } default { [string]$start } })
        Live = [bool]($svc -and [string]$svc.Status -eq 'Running'); Files = $files
    }
}
function Get-WHDInvWin32 {
    # Installed programs from the three uninstall keys (machine 64 / 32 bit, this user), named ones only.
    [CmdletBinding()]
    param()
    $out = foreach ($rp in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall') {
        if (-not (Test-Path -LiteralPath $rp)) { continue }
        foreach ($k in @(Get-ChildItem -LiteralPath $rp -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p -or -not $p.PSObject.Properties['DisplayName'] -or -not [string]$p.DisplayName) { continue }
            $get = { param($n) if ($p.PSObject.Properties[$n]) { [string]$p.$n } else { '' } }
            [pscustomobject]@{ DisplayName = [string]$p.DisplayName; Version = (& $get 'DisplayVersion'); Publisher = (& $get 'Publisher'); InstallDate = (& $get 'InstallDate'); UninstallString = (& $get 'UninstallString'); Hive = ($rp -split ':')[0] }
        }
    }
    return @($out)
}

# ---- scans of this PC ------------------------------------------------------------------------------------------------
function Test-WHDInvScanThisPC {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$ScanDir)
    $f = Join-Path $ScanDir 'os-info.json'
    if (-not (Test-Path -LiteralPath $f)) { return $false }
    try { $o = Get-Content -LiteralPath $f -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable } catch { return $false }
    if ([string]$o['MachineId']) { return (([string]$o['MachineId']).ToLowerInvariant() -eq (Get-WHDMachineId)) }
    return $true                                          # an untagged scan (2.0 before G13): judged by nothing else here
}
function Get-WHDInvScan {
    # Complete scans of this PC, oldest first.
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $root = Get-WHDInvRoot
    if (-not (Test-Path -LiteralPath $root)) { return , @() }
    return , @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object {
        (Test-Path -LiteralPath (Join-Path $_.FullName 'appx-packages.csv')) -and (Test-Path -LiteralPath (Join-Path $_.FullName 'REPORT.txt')) -and (Test-WHDInvScanThisPC -ScanDir $_.FullName)
    } | Sort-Object Name)
}
function Get-WHDInvRemovedPackage {
    # Package name (lower case) -> time, for every app WHD removed on this PC (appx / provisioned).
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $map = @{}
    foreach ($s in @(Get-WHDHistorySession)) {
        foreach ($e in Get-WHDHistoryEntry -SessionPath $s.Path -Source $s.Source) {
            if ([string]$e['Kind'] -in 'appx', 'provisioned' -and [string]$e['Package']) { $map[([string]$e['Package']).ToLowerInvariant()] = [string]$e['Time'] }
        }
    }
    return $map
}
function Import-WHDInvCsv {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$File)
    $p = Join-Path $Dir $File
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return , @(Import-Csv -LiteralPath $p)
}
function Compare-WHDInvSurface {
    [CmdletBinding()]
    [OutputType([object[]])]
    param($OldRows, $NewRows, [string]$Surface, [string]$Key, [string[]]$Fields, [hashtable]$Removed)
    if ($null -eq $OldRows -or $null -eq $NewRows) { return , @([pscustomobject]@{ Surface = $Surface; Change = 'SKIPPED'; Item = '(file missing in one of the scans)'; Old = ''; New = ''; Note = '' }) }
    $o = @{}; foreach ($r in $OldRows) { $k = [string]$r.$Key; if ($k) { $o[$k] = $r } }
    $n = @{}; foreach ($r in $NewRows) { $k = [string]$r.$Key; if ($k) { $n[$k] = $r } }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($k in @($n.Keys | Sort-Object)) {
        if (-not $o.ContainsKey($k)) {
            $note = if ($Removed -and $Removed.ContainsKey($k.ToLowerInvariant())) { 'CAME BACK - removed by WHD on {0}' -f $Removed[$k.ToLowerInvariant()] } else { '' }
            $rows.Add([pscustomobject]@{ Surface = $Surface; Change = 'NEW'; Item = $k; Old = ''; New = (@($Fields | ForEach-Object { [string]$n[$k].$_ } | Where-Object { $_ }) -join ', '); Note = $note })
        } else {
            $ob = @(); $nb = @()
            foreach ($f in $Fields) { if ([string]$o[$k].$f -ne [string]$n[$k].$f) { $ob += ('{0}={1}' -f $f, $o[$k].$f); $nb += ('{0}={1}' -f $f, $n[$k].$f) } }
            if ($nb.Count) { $rows.Add([pscustomobject]@{ Surface = $Surface; Change = 'CHANGED'; Item = $k; Old = ($ob -join ', '); New = ($nb -join ', '); Note = '' }) }
        }
    }
    foreach ($k in @($o.Keys | Sort-Object)) {
        if (-not $n.ContainsKey($k)) { $rows.Add([pscustomobject]@{ Surface = $Surface; Change = 'GONE'; Item = $k; Old = (@($Fields | ForEach-Object { [string]$o[$k].$_ } | Where-Object { $_ }) -join ', '); New = ''; Note = '' }) }
    }
    return , $rows.ToArray()
}
function Get-WHDInvDiff {
    # Compares two scan folders; writes DIFF-vs-<older>.txt / .csv into the newer one.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OldDir, [Parameter(Mandatory)][string]$NewDir)
    $removed = Get-WHDInvRemovedPackage
    $all = [System.Collections.Generic.List[object]]::new()
    $lines = [System.Collections.Generic.List[string]]::new()
    $oldName = Split-Path $OldDir -Leaf
    $lines.Add(('  Compared: {0}  ->  {1}' -f $oldName, (Split-Path $NewDir -Leaf)))
    foreach ($sf in $script:WHDInvSurfaces) {
        $rm = if ($sf.S -eq 'Store apps') { $removed } else { $null }
        $rows = Compare-WHDInvSurface -OldRows (Import-WHDInvCsv -Dir $OldDir -File $sf.F) -NewRows (Import-WHDInvCsv -Dir $NewDir -File $sf.F) -Surface $sf.S -Key $sf.K -Fields $sf.X -Removed $rm
        foreach ($r in $rows) { $all.Add($r) }
        if (@($rows | Where-Object Change -eq 'SKIPPED').Count) { $lines.Add(('  {0,-20} skipped (file missing in one scan)' -f $sf.S)); continue }
        $lines.Add(('  {0,-20} {1} new, {2} gone, {3} changed' -f $sf.S, @($rows | Where-Object Change -eq 'NEW').Count, @($rows | Where-Object Change -eq 'GONE').Count, @($rows | Where-Object Change -eq 'CHANGED').Count))
        foreach ($r in $rows) {
            $t = switch ($r.Change) { 'NEW' { '      NEW      {0}  ({1})' -f $r.Item, $r.New } 'GONE' { '      GONE     {0}  ({1})' -f $r.Item, $r.Old } default { '      CHANGED  {0}  {1}  ->  {2}' -f $r.Item, $r.Old, $r.New } }
            if ($r.Note) { $t += ('   <-- ' + $r.Note) }
            $lines.Add($t)
        }
    }
    $back = @($all | Where-Object { $_.Note -like 'CAME BACK*' }).Count
    if ($back) { $lines.Add(('  !! {0} app(s) that WHD removed are back - see the CAME BACK lines (main menu V re-removes them).' -f $back)) }
    if (-not @($all | Where-Object { $_.Change -in 'NEW', 'GONE', 'CHANGED' }).Count) { $lines.Add('  No differences.') }
    $base = Join-Path $NewDir ('DIFF-vs-' + $oldName)
    try {
        $all | Export-Csv -LiteralPath ($base + '.csv') -NoTypeInformation -Encoding utf8
        (@('INVENTORY COMPARISON (read-only)') + $lines.ToArray()) | Set-Content -LiteralPath ($base + '.txt') -Encoding utf8
    } catch { Write-WHDLog -Message ('The comparison could not be saved: {0}' -f $_.Exception.Message) -Level 'WARN' }
    [pscustomobject]@{ Lines = $lines.ToArray(); Rows = $all.ToArray(); TextPath = ($base + '.txt'); CameBack = $back }
}

# ---- 1. inventory -----------------------------------------------------------------------------------------------------
function Invoke-WHDInventory {
    # Read-only scan into inventory\<time>\. Runs in every mode (it changes nothing). Returns the scan folder.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $admin = [bool]$script:WHDState.IsAdmin
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $out = Join-Path (Get-WHDInvRoot) $stamp
    [void](New-Item -ItemType Directory -Path $out -Force -ErrorAction Stop)
    Write-WHDLog -Message ('INVENTORY (read-only - changes nothing): {0}' -f $out) -Level 'ACT'
    if (-not $admin) { Write-WHDLog -Message 'Not an administrator window: the staged apps, optional features and capabilities are left out (marked in the report).' -Level 'WARN' }
    $csv = { param($rows, $file) @($rows) | Export-Csv -LiteralPath (Join-Path $out $file) -NoTypeInformation -Encoding utf8 }
    # OS + this PC's tag
    $os = $null
    try { $os = Get-WHDInvOs } catch { Write-WHDLog -Message ('Windows version could not be read: {0}' -f $_.Exception.Message) -Level 'WARN' }
    $info = [ordered]@{ Caption = ''; Version = ''; BuildNumber = ''; UBR = ''; DisplayVer = ''; Architecture = ''; Elevated = $admin; ScannedUtc = (Get-Date).ToUniversalTime().ToString('o'); MachineId = (Get-WHDMachineId); Computer = [Environment]::MachineName; By = 'WHD Next 3.0' }
    if ($os) { foreach ($k in 'Caption', 'Version', 'BuildNumber', 'UBR', 'DisplayVer', 'Architecture') { $info[$k] = $os.$k } }
    [pscustomobject]$info | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $out 'os-info.json') -Encoding utf8
    Write-WHDLog -Message ('Windows: {0}  {1} (build {2}.{3})' -f $info.Caption, $info.DisplayVer, $info.BuildNumber, $info.UBR)
    # Store apps: installed vs staged
    $byName = [ordered]@{}
    $mk = { param($n) if (-not $byName.Contains($n)) { $byName[$n] = [pscustomobject]@{ AiTag = (Get-WHDInvAiTag -Name $n); State = ''; Installed = $false; Provisioned = $false; NonRemovable = $false; Name = $n; Version = ''; Publisher = ''; SignatureKind = ''; InstallLocation = '' } }; $byName[$n] }
    try {
        foreach ($p in (Get-WHDInvAppx -AllUsers:$admin)) {
            $o = & $mk ([string]$p.Name); $o.Installed = $true; $o.Version = [string]$p.Version; $o.Publisher = [string]$p.Publisher; $o.InstallLocation = [string]$p.InstallLocation
            if ($p.PSObject.Properties['NonRemovable']) { $o.NonRemovable = [bool]$p.NonRemovable }
            if ($p.PSObject.Properties['SignatureKind']) { $o.SignatureKind = [string]$p.SignatureKind }
        }
    } catch { Write-WHDLog -Message ('Installed apps could not be read: {0}' -f $_.Exception.Message) -Level 'WARN' }
    if ($admin) {
        try { foreach ($p in (Get-WHDInvProvisioned)) { $o = & $mk ([string]$p.DisplayName); $o.Provisioned = $true; if (-not $o.Version) { $o.Version = [string]$p.Version }; if (-not $o.Publisher) { $o.Publisher = [string]$p.PublisherId } } }
        catch { Write-WHDLog -Message ('Staged apps could not be read: {0}' -f $_.Exception.Message) -Level 'WARN' }
    }
    $appx = @(foreach ($o in $byName.Values) { $o.State = if ($o.Installed -and $o.Provisioned) { 'both' } elseif ($o.Installed) { 'installed-only' } else { 'staged-only' }; $o })
    & $csv @($appx | Sort-Object AiTag, Name) 'appx-packages.csv'
    $ai = @($appx | Where-Object AiTag | Sort-Object AiTag, Name)
    & $csv @($ai | Select-Object AiTag, State, Installed, Provisioned, NonRemovable, Name, Version) 'ai-packages.csv'
    $cInst = @($appx | Where-Object Installed).Count; $cStage = @($appx | Where-Object State -eq 'staged-only').Count; $cBoth = @($appx | Where-Object State -eq 'both').Count
    Write-WHDLog -Message ('Store apps: {0} installed, {1} staged only, {2} both ({3} in all)' -f $cInst, $cStage, $cBoth, $appx.Count)
    foreach ($a in $ai) { Write-WHDLog -Message ('  AI: {0,-15} {1,-14} {2}' -f $a.AiTag, $a.State, $a.Name) }
    # SystemApps (+ SxS)
    $sysDir = [System.IO.Path]::Combine((Get-WHDInvWinDir), 'SystemApps')
    $sys = @(foreach ($d in (Get-WHDInvFolder -Path $sysDir)) { if ($d.Name -ne 'SxS') { [pscustomobject]@{ Folder = $d.Name; AiTag = (Get-WHDInvAiTag -Name $d.Name); Path = $d.FullName } } })
    $sys += @(foreach ($d in (Get-WHDInvFolder -Path ([System.IO.Path]::Combine($sysDir, 'SxS')))) { [pscustomobject]@{ Folder = ('SxS\' + $d.Name); AiTag = (Get-WHDInvAiTag -Name $d.Name); Path = $d.FullName } })
    & $csv $sys 'systemapps.csv'
    Write-WHDLog -Message ('SystemApps: {0} component folders (part of Windows - flagged, never touched)' -f $sys.Count)
    # optional features + capabilities
    $feat = @(); $caps = @()
    if ($admin) {
        try { $feat = @(Get-WHDInvFeature | ForEach-Object { [pscustomobject]@{ FeatureName = [string]$_.FeatureName; State = [string]$_.State; AiTag = $(if ([string]$_.FeatureName -like '*Recall*') { 'Recall' } else { '' }) } }) }
        catch { Write-WHDLog -Message ('Optional features could not be read: {0}' -f $_.Exception.Message) -Level 'WARN' }
        try { $caps = @(Get-WHDInvCapability | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; State = [string]$_.State } }) }
        catch { Write-WHDLog -Message ('Capabilities could not be read: {0}' -f $_.Exception.Message) -Level 'WARN' }
    }
    & $csv $feat 'optional-features.csv'
    & $csv $caps 'capabilities.csv'
    $recall = @($feat | Where-Object AiTag -eq 'Recall')
    Write-WHDLog -Message $(if ($recall.Count) { 'Recall (optional feature): {0}' -f (($recall | ForEach-Object State) -join ', ') } else { 'Recall (optional feature): not on this PC' })
    # WinSxS
    $sxsDir = [System.IO.Path]::Combine((Get-WHDInvWinDir), 'WinSxS')
    $sxs = [pscustomobject]@{ Path = $sxsDir; Exists = (Test-Path -LiteralPath $sxsDir); ManifestCount = (Get-WHDInvFileCount -Path ([System.IO.Path]::Combine($sxsDir, 'Manifests'))) }
    $sxs | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $out 'winsxs.json') -Encoding utf8
    # AppLocker readiness
    $al = Get-WHDInvAppLocker
    & $csv $al.Files 'applocker-cache-files.csv'
    [pscustomobject]@{ ServiceStatus = $al.Status; StartType = $al.StartType; EnforcementLive = $al.Live } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $out 'applocker-service.json') -Encoding utf8
    # installed programs
    $w32 = @(Get-WHDInvWin32 | Sort-Object DisplayName -Unique | ForEach-Object { $_ | Add-Member -NotePropertyName AiTag -NotePropertyValue (Get-WHDInvAiTag -Name $_.DisplayName) -PassThru -Force })
    & $csv $w32 'win32-apps.csv'
    Write-WHDLog -Message ('Installed programs: {0}' -f $w32.Count)
    # the report
    $r = [System.Collections.Generic.List[string]]::new()
    $r.Add('================================================================')
    $r.Add(' WHD Next 3.0  -  INVENTORY REPORT (read-only)')
    $r.Add('================================================================')
    $r.Add(('Scanned : {0}  (UTC {1})' -f $info.Computer, $info.ScannedUtc))
    $r.Add(('Windows : {0}  {1}  build {2}.{3}  {4}' -f $info.Caption, $info.DisplayVer, $info.BuildNumber, $info.UBR, $info.Architecture))
    $r.Add(('Admin   : {0}{1}' -f $admin, $(if (-not $admin) { '   <-- limited: staged apps, optional features and capabilities left out' } else { '' })))
    $r.Add('')
    $r.Add('-- STORE APPS (installed vs staged for new users) ---------------')
    $r.Add(('  installed for a user ........ {0}' -f $cInst))
    $r.Add(('  staged only (new users) ..... {0}' -f $cStage))
    $r.Add(('  both ........................ {0}' -f $cBoth))
    $r.Add(('  in all ...................... {0}' -f $appx.Count))
    $r.Add('')
    $r.Add('-- AI SURFACES FOUND --------------------------------------------')
    if ($ai.Count) { foreach ($a in $ai) { $r.Add(('  [{0,-14}] {1,-14} removable={2,-5} {3}' -f $a.AiTag, $a.State, (-not $a.NonRemovable), $a.Name)) } } else { $r.Add('  (none of the known names)') }
    if ($recall.Count) { $r.Add(('  [Recall        ] optional feature  state={0}' -f (($recall | ForEach-Object State) -join ','))) }
    $sysAi = @($sys | Where-Object AiTag)
    if ($sysAi.Count) { $r.Add('  SystemApps folders flagged AI (part of Windows - not removable):'); foreach ($s in $sysAi) { $r.Add(('    [{0,-14}] {1}' -f $s.AiTag, $s.Folder)) } }
    $r.Add('')
    $r.Add('-- CHANGES SINCE THE LAST SCAN OF THIS PC ----------------------')
    $prev = @((Get-WHDInvScan) | Where-Object { $_.Name -lt $stamp })
    if ($prev.Count) {
        try { foreach ($l in (Get-WHDInvDiff -OldDir $prev[-1].FullName -NewDir $out).Lines) { $r.Add($l) } } catch { $r.Add(('  comparison failed: {0}' -f $_.Exception.Message)) }
    } else { $r.Add('  (no earlier scan of this PC to compare with)') }
    $r.Add('')
    $r.Add('-- SURFACES -----------------------------------------------------')
    $r.Add(('  SystemApps folders .......... {0}' -f $sys.Count))
    $r.Add(('  Optional features ........... {0}' -f $feat.Count))
    $r.Add(('  Windows capabilities ........ {0}' -f $caps.Count))
    $r.Add(('  WinSxS manifests ............ {0}' -f $sxs.ManifestCount))
    $r.Add(('  Installed programs .......... {0}' -f $w32.Count))
    $r.Add('')
    $r.Add('-- APPLOCKER (readiness) ----------------------------------------')
    $r.Add(('  Application Identity ........ {0} / {1}' -f $al.Status, $al.StartType))
    $r.Add(('  Rules enforced .............. {0}' -f $al.Live))
    $r.Add(('  Cache files ................. {0}' -f @($al.Files).Count))
    $r.Add('  (The policy itself is not read: its commands come from Windows PowerShell 5.1.)')
    $r.Add('')
    $r.Add('NOTE: This scan changed NOTHING. It only reads and reports.')
    $r.Add('================================================================')
    $r | Set-Content -LiteralPath (Join-Path $out 'REPORT.txt') -Encoding utf8
    Write-Host ''
    foreach ($l in $r) { Write-Host $l }
    Write-WHDLog -Message ('Inventory saved: {0}' -f (Join-Path $out 'REPORT.txt')) -Level 'OK'
    return $out
}

# ---- D. compare two scans ------------------------------------------------------------------------------------------
function Invoke-WHDInventoryCompare {
    # The two newest scans of this PC, or the named ones (folder names). Read-only.
    [CmdletBinding()]
    param([string]$Old, [string]$New)
    $scans = Get-WHDInvScan
    $pick = { param($v) if (-not $v) { return $null }; $m = @($scans | Where-Object Name -eq $v); if ($m.Count) { return $m[0].FullName }; return $null }
    $newDir = & $pick $New; $oldDir = & $pick $Old
    if (-not $newDir -and $scans.Count) { $newDir = $scans[-1].FullName }
    if (-not $oldDir -and $newDir) { $older = @($scans | Where-Object { $_.FullName -ne $newDir -and $_.Name -lt (Split-Path $newDir -Leaf) }); if ($older.Count) { $oldDir = $older[-1].FullName } }
    if (-not $newDir -or -not $oldDir) { Write-WHDLog -Message 'Two complete inventory scans of this PC are needed - run the inventory (1) again first.' -Level 'WARN'; return }
    Write-WHDLog -Message 'INVENTORY COMPARISON (read-only)' -Level 'ACT'
    $d = Get-WHDInvDiff -OldDir $oldDir -NewDir $newDir
    foreach ($l in $d.Lines) { Write-WHDLog -Message $l }
    Write-WHDLog -Message ('Saved: {0}' -f $d.TextPath) -Level 'OK'
    return $d
}
