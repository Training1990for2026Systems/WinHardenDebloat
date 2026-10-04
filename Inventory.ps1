<#
================================================================================
 WinHardenDebloat  -  Inventory.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 READ-ONLY. This script changes NOTHING on the system. It builds a full
 inventory of the machine's app/package surfaces and writes CSV + a readable
 report to the project folder for review.

 What it answers (per project brief):
   * Installed / running   vs   provisioned / staged-but-not-running
   * The four surfaces:
       - C:\Windows\SystemApps
       - C:\Windows\WinSxS  (via optional features / capabilities + store size)
       - C:\Windows\System32\AppLocker  (effective policy in force)
       - Settings > Apps > Installed apps  (Appx + Win32 uninstall registry)
   * Flags every "AI"-related surface (Copilot, Cortana, Power Automate,
     Recall, Web Experience/Widgets, and integrated AI apps).

 Target:  Windows 11 (tested on 25H2 and 26H2).  Windows PowerShell 5.1 (powershell.exe).
 Elevation: run as Administrator for the FULL picture. Without admin, the
            provisioned-package and effective-AppLocker scans are skipped
            (clearly marked in the report), everything else still runs.

 Usage:
   powershell -ExecutionPolicy Bypass -File .\Inventory.ps1
   powershell -ExecutionPolicy Bypass -File .\Inventory.ps1 -OutputRoot "D:\WHD"
   powershell -ExecutionPolicy Bypass -File .\Inventory.ps1 -Compare
       Compare the two newest scans - what appeared, disappeared or
       changed. Add -Old / -New <folder name> to pick specific scans.
   Every normal scan also compares itself with the previous scan and adds a
   "CHANGES SINCE LAST SCAN" section to REPORT.txt (+ DIFF-vs-*.txt/.csv).
================================================================================
#>

[CmdletBinding()]
param(
    # Where inventory output is written. Defaults to <script folder>\inventory\<timestamp>\
    [string]$OutputRoot,
    # Skip self-elevation (used when a launcher already elevated us).
    [switch]$NoElevate,
    # Compare two existing scans instead of scanning (read-only, no admin).
    [switch]$Compare,
    [string]$Old,
    [string]$New,
    # Project folder whose restore\ journals mark "CAME BACK" items
    # (the update guard runs this script from its protected copy).
    [string]$ProjectRoot
)

# Windows PowerShell 5.1 only - the Appx / DISM cmdlets used here do not behave the same in PowerShell 7.
if ($PSVersionTable.PSVersion.Major -ne 5) {
    Write-Host 'The inventory needs Windows PowerShell 5.1 - start it with powershell.exe, not pwsh.' -ForegroundColor Red
    exit 1
}

$ErrorActionPreference = 'Stop'
# NOTE: StrictMode is intentionally NOT enabled. Admin inventory cmdlets often
# return a single object (not an array), and StrictMode makes .Count on those
# throw. Collections are forced to arrays with @() instead (safe .Count).

# ---------------------------------------------------- self-elevation ----------
# Per project decision: relaunch elevated if not admin. Read-only, but admin is
# required to read provisioned packages and effective AppLocker policy.
function Test-AdminEarly {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not $NoElevate -and -not $Compare -and -not (Test-AdminEarly)) {
    Write-Host 'Not elevated - relaunching as Administrator (UAC prompt)...' -ForegroundColor Yellow
    $psExe = (Get-Process -Id $PID).Path              # same host (powershell.exe / pwsh.exe)
    $argList = @('-ExecutionPolicy','Bypass','-NoProfile','-File', "`"$($MyInvocation.MyCommand.Path)`"")
    if ($OutputRoot) { $argList += @('-OutputRoot', "`"$OutputRoot`"") }
    if ($ProjectRoot) { $argList += @('-ProjectRoot', "`"$ProjectRoot`"") }
    try {
        Start-Process -FilePath $psExe -Verb RunAs -ArgumentList $argList
    } catch {
        Write-Host "Elevation declined or failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Continuing UN-elevated (provisioned + AppLocker scans will be skipped).' -ForegroundColor Yellow
        $script:NoElevateFallback = $true
    }
    if (-not $script:NoElevateFallback) { return }    # elevated copy takes over
}

# ------------------------------------------------------------------ paths ----
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $OutputRoot) { $OutputRoot = Join-Path $ScriptDir 'inventory' }
if (-not $ProjectRoot) { $ProjectRoot = $ScriptDir }

# ===================================== PHASE 5 (A3): SNAPSHOT COMPARISON =======
# Read-only. Compares two inventory folders surface by surface and flags any
# package that WHD removed earlier (from restore\*\journal.jsonl) but is back.
function Get-WHDSnapshots([string]$Root) {
    @(Get-ChildItem -LiteralPath $Root -Directory -EA SilentlyContinue |
        Where-Object { (Test-Path -LiteralPath (Join-Path $_.FullName 'appx-packages.csv')) -and
                       (Test-Path -LiteralPath (Join-Path $_.FullName 'REPORT.txt')) } |
        Sort-Object Name)
}
function Import-WHDCsvSafe([string]$Dir, [string]$File) {
    $p = Join-Path $Dir $File
    if (Test-Path -LiteralPath $p) { return ,@(Import-Csv -LiteralPath $p) }
    return $null
}
# v1.1: only THIS PC's history counts (same rule as Common.ps1 Get-WHDSessionOwner):
# session machine.json / entry MachineId = this MachineGuid; untagged sessions
# older than this Windows install belong to another PC / an earlier install.
function Get-WHDInvMachineId {
    try { return "$((Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -EA Stop).MachineGuid)".ToLower() } catch { return "name:$env:COMPUTERNAME".ToLower() }
}
function Test-WHDInvSessionIsThisPC([string]$SessionDir, [string]$MachineId, $InstallDate) {
    $mf = Join-Path $SessionDir 'machine.json'
    if (Test-Path -LiteralPath $mf) {
        try { $m = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json; if ("$($m.MachineId)") { return ("$($m.MachineId)".ToLower() -eq $MachineId) } } catch {}
    }
    $stamp = $null
    try { $stamp = [datetime]::ParseExact((Split-Path $SessionDir -Leaf), 'yyyy-MM-dd_HHmmss', $null) } catch {}
    if ($InstallDate -and $stamp -and $stamp -lt $InstallDate) { return $false }
    return $true
}
function Get-WHDRemovedByJournal([string]$ProjectRoot) {
    $map = @{}
    $rr = Join-Path $ProjectRoot 'restore'
    $mid = Get-WHDInvMachineId
    $inst = $null
    try { $inst = ([datetime]'1970-01-01').AddSeconds([int64](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name InstallDate -EA Stop).InstallDate).ToLocalTime() } catch {}
    foreach ($j in @(Get-ChildItem -LiteralPath $rr -Filter 'journal.jsonl' -Recurse -File -EA SilentlyContinue)) {
        if (-not (Test-WHDInvSessionIsThisPC -SessionDir $j.DirectoryName -MachineId $mid -InstallDate $inst)) { continue }
        foreach ($line in @(Get-Content -LiteralPath $j.FullName -Encoding UTF8 -EA SilentlyContinue)) {
            if (-not $line.Trim()) { continue }
            try { $e = $line | ConvertFrom-Json } catch { continue }
            if ($e.MachineId -and "$($e.MachineId)".ToLower() -ne $mid) { continue }
            if ("$($e.Kind)" -in @('appx','provisioned') -and $e.Package) { $map["$($e.Package)".ToLower()] = "$($e.Time)" }
        }
    }
    $map
}
function Compare-WHDSurface {
    param($OldRows, $NewRows, [string]$Surface, [string]$Key, [string[]]$Fields, [hashtable]$Removed)
    if ($null -eq $OldRows -or $null -eq $NewRows) {
        return @([pscustomobject]@{ Surface=$Surface; Change='SKIPPED'; Item='(file missing in one of the scans)'; Old=''; New=''; Note='' })
    }
    $o = @{}; foreach ($r in $OldRows) { $k = "$($r.$Key)"; if ($k) { $o[$k] = $r } }
    $n = @{}; foreach ($r in $NewRows) { $k = "$($r.$Key)"; if ($k) { $n[$k] = $r } }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($k in @($n.Keys | Sort-Object)) {
        if (-not $o.ContainsKey($k)) {
            $desc = @($Fields | ForEach-Object { "$($n[$k].$_)" } | Where-Object { $_ }) -join ', '
            $note = ''
            if ($Removed -and $Removed.ContainsKey($k.ToLower())) { $note = "CAME BACK - removed by WHD on $($Removed[$k.ToLower()])" }
            $rows.Add([pscustomobject]@{ Surface=$Surface; Change='NEW'; Item=$k; Old=''; New=$desc; Note=$note })
        } else {
            $oldBits = @(); $newBits = @()
            foreach ($f in $Fields) {
                if ("$($o[$k].$f)" -ne "$($n[$k].$f)") { $oldBits += ("{0}={1}" -f $f, $o[$k].$f); $newBits += ("{0}={1}" -f $f, $n[$k].$f) }
            }
            if ($newBits.Count) { $rows.Add([pscustomobject]@{ Surface=$Surface; Change='CHANGED'; Item=$k; Old=($oldBits -join ', '); New=($newBits -join ', '); Note='' }) }
        }
    }
    foreach ($k in @($o.Keys | Sort-Object)) {
        if (-not $n.ContainsKey($k)) {
            $desc = @($Fields | ForEach-Object { "$($o[$k].$_)" } | Where-Object { $_ }) -join ', '
            $rows.Add([pscustomobject]@{ Surface=$Surface; Change='GONE'; Item=$k; Old=$desc; New=''; Note='' })
        }
    }
    return $rows.ToArray()
}
function Invoke-WHDInventoryDiff {
    param([string]$OldDir, [string]$NewDir, [string]$ProjectRoot)
    $removed = Get-WHDRemovedByJournal $ProjectRoot
    $surfaces = @(
        @{ S='Appx packages';      F='appx-packages.csv';     K='Name';        X=@('State','Version') }
        @{ S='Optional features';  F='optional-features.csv'; K='FeatureName'; X=@('State') }
        @{ S='Capabilities';       F='capabilities.csv';      K='Name';        X=@('State') }
        @{ S='Win32 programs';     F='win32-apps.csv';        K='DisplayName'; X=@('Version') }
        @{ S='SystemApps folders'; F='systemapps.csv';        K='Folder';      X=@() }
    )
    $all = New-Object System.Collections.Generic.List[object]
    $lines = New-Object System.Collections.Generic.List[string]
    $oldName = Split-Path $OldDir -Leaf; $newName = Split-Path $NewDir -Leaf
    $lines.Add(('  Compared: {0}  ->  {1}' -f $oldName, $newName))
    # A scan made without administrator rights has no optional features / capabilities / provisioned packages.
    $elev = @(foreach ($sd in @($OldDir, $NewDir)) {
        try { "$((Get-Content -LiteralPath (Join-Path $sd 'os-info.json') -Raw -EA Stop | ConvertFrom-Json).Elevated)" } catch { '' }
    })
    if ($elev[0] -and $elev[1] -and $elev[0] -ne $elev[1]) {
        $lines.Add('  WARN: One scan was made without administrator rights - Appx packages of other users, optional features and capabilities are missing from it, so differences in those sections are not real.')
    }
    foreach ($sf in $surfaces) {
        $rm = if ($sf.S -eq 'Appx packages') { $removed } else { $null }
        $rows = @(Compare-WHDSurface (Import-WHDCsvSafe $OldDir $sf.F) (Import-WHDCsvSafe $NewDir $sf.F) $sf.S $sf.K $sf.X $rm)
        foreach ($r in $rows) { $all.Add($r) }
        $cNew = @($rows | Where-Object { $_.Change -eq 'NEW' }).Count
        $cGone= @($rows | Where-Object { $_.Change -eq 'GONE' }).Count
        $cChg = @($rows | Where-Object { $_.Change -eq 'CHANGED' }).Count
        if (@($rows | Where-Object { $_.Change -eq 'SKIPPED' }).Count) { $lines.Add(('  {0,-20} skipped (file missing in one scan)' -f $sf.S)); continue }
        $lines.Add(('  {0,-20} {1} new, {2} gone, {3} changed' -f $sf.S, $cNew, $cGone, $cChg))
        foreach ($r in $rows) {
            $txt = switch ($r.Change) {
                'NEW'     { '      NEW      {0}  ({1})' -f $r.Item, $r.New }
                'GONE'    { '      GONE     {0}  ({1})' -f $r.Item, $r.Old }
                'CHANGED' { '      CHANGED  {0}  {1}  ->  {2}' -f $r.Item, $r.Old, $r.New }
            }
            if ($r.Note) { $txt += ('   <-- ' + $r.Note) }
            $lines.Add($txt)
        }
    }
    $back = @($all | Where-Object { $_.Note -like 'CAME BACK*' }).Count
    if ($back) { $lines.Add(('  !! {0} package(s) that WHD removed are back - see CAME BACK lines.' -f $back)) }
    if (-not @($all | Where-Object { $_.Change -in @('NEW','GONE','CHANGED') }).Count) { $lines.Add('  No differences.') }
    $base = Join-Path $NewDir ('DIFF-vs-' + $oldName)
    try {
        $all | Export-Csv ($base + '.csv') -NoTypeInformation -Encoding UTF8
        (@('INVENTORY COMPARISON (read-only)') + $lines.ToArray()) | Set-Content -Path ($base + '.txt') -Encoding UTF8
    } catch {}
    [pscustomobject]@{ Lines = $lines.ToArray(); Rows = $all.ToArray(); TextPath = ($base + '.txt') }
}

if ($Compare) {
    $snaps = Get-WHDSnapshots $OutputRoot
    function _pick([string]$v) {
        if (-not $v) { return $null }
        if (Test-Path -LiteralPath $v) { return (Get-Item -LiteralPath $v).FullName }
        $p = Join-Path $OutputRoot $v
        if (Test-Path -LiteralPath $p) { return $p }
        return $null
    }
    $newDir = _pick $New; $oldDir = _pick $Old
    if (-not $newDir) { if ($snaps.Count) { $newDir = $snaps[-1].FullName } }
    if (-not $oldDir) {
        $older = @($snaps | Where-Object { $_.FullName -ne $newDir -and $_.Name -lt (Split-Path $newDir -Leaf) })
        if ($older.Count) { $oldDir = $older[-1].FullName }
    }
    if (-not $newDir -or -not $oldDir) {
        Write-Output 'Need at least two complete inventory scans to compare (run the inventory again first).'
        return
    }
    $d = Invoke-WHDInventoryDiff -OldDir $oldDir -NewDir $newDir -ProjectRoot $ProjectRoot
    Write-Output 'INVENTORY COMPARISON (read-only)'
    foreach ($l in $d.Lines) { Write-Output $l }
    Write-Output ('  Saved: {0}' -f $d.TextPath)
    return
}

$Stamp   = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$OutDir  = Join-Path $OutputRoot $Stamp
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

# ---------------------------------------------------------------- helpers ----
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
$IsAdmin = Test-Admin

$Log = New-Object System.Collections.Generic.List[string]
function Say([string]$msg, [string]$level = 'INFO') {
    $line = "[{0}] {1,-5} {2}" -f (Get-Date -Format 'HH:mm:ss'), $level, $msg
    $Log.Add($line)
    switch ($level) {
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'ERR'  { Write-Host $line -ForegroundColor Red }
        'AI'   { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line }
    }
}

# ---- AI surface signatures (package-name patterns) --------------------------
# Curated for Win11 24H2/25H2. Matching is a FLAG, never an action.
$AiSignatures = [ordered]@{
    'Copilot'         = @('Microsoft.Copilot', 'MicrosoftWindows.Client.CoPilot', '*Copilot*')
    'M365 Copilot'    = @('Microsoft.MicrosoftOfficeHub')            # "Microsoft 365 Copilot" app
    'Cortana'         = @('Microsoft.549981C3F5F10')
    'Power Automate'  = @('Microsoft.PowerAutomateDesktop')
    # Phase 5 (A1): OS-level AI components (SystemApps, non-removable) - flagged only.
    'AI platform'     = @('MicrosoftWindows.Client.CoreAI', 'MicrosoftWindows.Client.AIX',
                          'Microsoft.AIFabric.CBS*', 'Microsoft.Windows.AugLoop.CBS')
    'AI agents/MCP'   = @('MdOdrMcpFilterPackage', '*McpFilter*')
    'Voice/captions'  = @('MicrosoftWindows.*.Voiess', 'MicrosoftWindows.*.Livtop', 'MicrosoftWindows.*.Speion')  # names inferred
    'Web Experience'  = @('MicrosoftWindows.Client.WebExperience', 'Microsoft.WidgetsPlatformRuntime')   # Widgets host
    'Bing Search'     = @('Microsoft.BingSearch', 'Microsoft.BingWeather', 'Microsoft.BingNews')
    'Notepad (AI)'    = @('Microsoft.WindowsNotepad')                # Rewrite feature
    'Paint (AI)'      = @('Microsoft.Paint')                         # Cocreator/Generative
    'Photos (AI)'     = @('Microsoft.Windows.Photos')                # Generative erase
    'Phone Link'      = @('Microsoft.YourPhone')
}
function Get-AiTag([string]$name) {
    if (-not $name) { return $null }
    # SystemApps folders carry a publisher-hash suffix (e.g. _cw5n1h2txyewy) - match both forms.
    $base = $name -replace '_[0-9a-z]{13}$', ''
    foreach ($k in $AiSignatures.Keys) {
        foreach ($pat in $AiSignatures[$k]) {
            if ($name -like $pat -or $base -like $pat) { return $k }
        }
    }
    return $null
}

Say ("WinHardenDebloat inventory  |  admin={0}  |  out={1}" -f $IsAdmin, $OutDir)
Say ("Host: {0}  PS {1}" -f $env:COMPUTERNAME, $PSVersionTable.PSVersion.ToString())
if (-not $IsAdmin) {
    Say 'Not elevated: provisioned-package and effective-AppLocker scans will be SKIPPED.' 'WARN'
}

# =============================================================== OS INFO ======
$os = Get-CimInstance Win32_OperatingSystem
$osInfo = [pscustomobject]@{
    Caption      = $os.Caption
    Version      = $os.Version
    BuildNumber  = $os.BuildNumber
    UBR          = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -EA SilentlyContinue).UBR
    DisplayVer   = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -EA SilentlyContinue).DisplayVersion
    Architecture = $os.OSArchitecture
    Elevated     = $IsAdmin
    ScannedUtc   = (Get-Date).ToUniversalTime().ToString('o')
}
$osInfo | ConvertTo-Json | Set-Content (Join-Path $OutDir 'os-info.json')
Say ("OS: {0}  {1} (build {2}.{3})" -f $osInfo.Caption, $osInfo.DisplayVer, $osInfo.BuildNumber, $osInfo.UBR)

# ===================================================== APPX CORRELATION =======
# The core question: installed/running  vs  provisioned/staged.
Say 'Scanning Appx packages (installed for all users)...'
$installed = @()
try {
    $scope = if ($IsAdmin) { Get-AppxPackage -AllUsers } else { Get-AppxPackage }
    $installed = @($scope)
} catch { Say "Get-AppxPackage failed: $($_.Exception.Message)" 'WARN' }

$provisioned = @()
if ($IsAdmin) {
    Say 'Scanning provisioned packages (staged for new users)...'
    try { $provisioned = @(Get-AppxProvisionedPackage -Online) } catch {
        Say "Get-AppxProvisionedPackage failed: $($_.Exception.Message)" 'WARN'
    }
}

# Build a name-keyed union.
$byName = @{}
function Ensure($name) {
    if (-not $byName.ContainsKey($name)) {
        $byName[$name] = [pscustomobject]@{
            Name            = $name
            DisplayName     = $name
            Publisher       = ''
            Version         = ''
            Installed       = $false      # registered to a real user profile
            Provisioned     = $false      # staged for new users
            InstallLocation = ''
            NonRemovable    = $false
            SignatureKind   = ''
            AiTag           = (Get-AiTag $name)
        }
    }
    return $byName[$name]
}

foreach ($p in $installed) {
    $o = Ensure $p.Name
    $o.Installed       = $true
    $o.Version         = "$($p.Version)"
    $o.Publisher       = "$($p.Publisher)"
    $o.InstallLocation = "$($p.InstallLocation)"
    try { $o.NonRemovable = [bool]$p.NonRemovable } catch {}
    try { $o.SignatureKind = "$($p.SignatureKind)" } catch {}
}
foreach ($p in $provisioned) {
    $o = Ensure $p.DisplayName
    $o.Provisioned = $true
    if (-not $o.Version) { $o.Version = "$($p.Version)" }
    if (-not $o.Publisher) { $o.Publisher = "$($p.PublisherId)" }
}

# State tag: both / installed-only / provisioned-only(staged) / (n/a)
$appxTable = @(foreach ($o in $byName.Values) {
    $state =
        if     ($o.Installed -and $o.Provisioned) { 'both' }
        elseif ($o.Installed)                     { 'installed-only' }
        elseif ($o.Provisioned)                   { 'staged-only' }
        else                                      { 'unknown' }
    $o | Add-Member -NotePropertyName State -NotePropertyValue $state -Force -PassThru
})
$appxTable | Sort-Object AiTag, Name |
    Select-Object AiTag, State, Installed, Provisioned, NonRemovable, Name, DisplayName, Version, Publisher, SignatureKind, InstallLocation |
    Export-Csv (Join-Path $OutDir 'appx-packages.csv') -NoTypeInformation -Encoding UTF8

$cInst  = @($appxTable | Where-Object Installed).Count
$cStage = @($appxTable | Where-Object { $_.State -eq 'staged-only' }).Count
$cBoth  = @($appxTable | Where-Object { $_.State -eq 'both' }).Count
Say ("Appx: {0} installed, {1} staged-only, {2} both  ({3} distinct)" -f $cInst, $cStage, $cBoth, $appxTable.Count)

$aiHits = @($appxTable | Where-Object AiTag | Sort-Object AiTag, Name)
foreach ($a in $aiHits) { Say ("AI package: {0,-16} {1,-14} {2}" -f $a.AiTag, $a.State, $a.Name) 'AI' }
$aiHits | Select-Object AiTag, State, Installed, Provisioned, NonRemovable, Name, Version |
    Export-Csv (Join-Path $OutDir 'ai-packages.csv') -NoTypeInformation -Encoding UTF8

# ============================================ SURFACE: SystemApps =============
Say 'Scanning C:\Windows\SystemApps ...'
$systemApps = @()
$sysAppsPath = Join-Path $env:WinDir 'SystemApps'
if (Test-Path $sysAppsPath) {
    $systemApps = @(Get-ChildItem $sysAppsPath -Directory -EA SilentlyContinue | ForEach-Object {
        [pscustomobject]@{
            Folder = $_.Name
            AiTag  = (Get-AiTag $_.Name)
            Path   = $_.FullName
        }
    })
    # Phase 5: side-by-side components live one level down in SystemApps\SxS.
    $sxs = Join-Path $sysAppsPath 'SxS'
    if (Test-Path $sxs) {
        $systemApps += @(Get-ChildItem $sxs -Directory -EA SilentlyContinue | ForEach-Object {
            [pscustomobject]@{ Folder = ('SxS\' + $_.Name); AiTag = (Get-AiTag $_.Name); Path = $_.FullName }
        })
    }
}
$systemApps | Export-Csv (Join-Path $OutDir 'systemapps.csv') -NoTypeInformation -Encoding UTF8
Say ("SystemApps: {0} component folders (these are usually non-removable per-user; flagged, not touched)" -f $systemApps.Count)

# ============================ SURFACE: WinSxS / optional features & caps =======
# WinSxS itself is the component store; the actionable, serviceable inventory is
# optional features + capabilities. Recall lives here as an optional feature.
$optFeatures = @(); $capabilities = @()
if ($IsAdmin) {
    Say 'Scanning optional features (incl. Recall) ...'
    try {
        $optFeatures = @(Get-WindowsOptionalFeature -Online |
            Select-Object FeatureName, State,
                @{n='AiTag';e={ if ($_.FeatureName -like '*Recall*') { 'Recall' } else { $null } }})
    } catch { Say "Get-WindowsOptionalFeature failed: $($_.Exception.Message)" 'WARN' }

    Say 'Scanning Windows capabilities ...'
    try {
        $capabilities = @(Get-WindowsCapability -Online |
            Select-Object Name, State)
    } catch { Say "Get-WindowsCapability failed: $($_.Exception.Message)" 'WARN' }
}
$optFeatures  | Export-Csv (Join-Path $OutDir 'optional-features.csv') -NoTypeInformation -Encoding UTF8
$capabilities | Export-Csv (Join-Path $OutDir 'capabilities.csv') -NoTypeInformation -Encoding UTF8

$recall = @($optFeatures | Where-Object { $_.FeatureName -like '*Recall*' })
if ($recall) { Say ("Recall optional feature: state = {0}" -f ($recall.State -join ',')) 'AI' }
else { Say 'Recall optional feature: not present (non-Copilot+ hardware or not exposed).' }

# WinSxS presence + rough store folder count (no enumeration of the whole tree).
$winsxs = Join-Path $env:WinDir 'WinSxS'
$winsxsInfo = [pscustomobject]@{
    Path          = $winsxs
    Exists        = (Test-Path $winsxs)
    ManifestCount = if (Test-Path (Join-Path $winsxs 'Manifests')) {
                        @(Get-ChildItem (Join-Path $winsxs 'Manifests') -File -EA SilentlyContinue).Count
                    } else { 0 }
}
$winsxsInfo | ConvertTo-Json | Set-Content (Join-Path $OutDir 'winsxs.json')
Say ("WinSxS: exists={0}, manifests={1}" -f $winsxsInfo.Exists, $winsxsInfo.ManifestCount)

# ================================ SURFACE: System32\AppLocker (effective) =====
Say 'Reading effective AppLocker policy ...'
$applockerDir = Join-Path $env:WinDir 'System32\AppLocker'
$appLockerCacheFiles = @()
if (Test-Path $applockerDir) {
    $appLockerCacheFiles = @(Get-ChildItem $applockerDir -File -EA SilentlyContinue |
        Select-Object Name, Length, LastWriteTime)
}
$appLockerCacheFiles | Export-Csv (Join-Path $OutDir 'applocker-cache-files.csv') -NoTypeInformation -Encoding UTF8

# Application Identity service (AppIDSvc) drives enforcement - report its state,
# because AppLocker rules are silently ignored when it is not running.
$appId = $null
try { $appId = Get-Service AppIDSvc -EA Stop } catch {}
$appIdStart = $null
try { $appIdStart = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\AppIDSvc' -EA Stop).Start } catch {}
$appLockerSvc = [pscustomobject]@{
    ServiceStatus   = if ($appId) { "$($appId.Status)" } else { 'unknown' }
    StartTypeReg    = switch ($appIdStart) { 2 {'Automatic'} 3 {'Manual'} 4 {'Disabled'} default {"$appIdStart"} }
    EnforcementLive = ($appId -and $appId.Status -eq 'Running')
}
$appLockerSvc | ConvertTo-Json | Set-Content (Join-Path $OutDir 'applocker-service.json')
if ($appLockerSvc.EnforcementLive) { Say ("AppIDSvc: {0} / {1}  (enforcement LIVE)" -f $appLockerSvc.ServiceStatus, $appLockerSvc.StartTypeReg) }
else { Say ("AppIDSvc: {0} / {1}  (AppLocker rules NOT enforced)" -f $appLockerSvc.ServiceStatus, $appLockerSvc.StartTypeReg) 'WARN' }

if ($IsAdmin -and -not (Get-Command Get-AppLockerPolicy -EA SilentlyContinue)) {
    Say 'AppLocker cmdlets are not included in this Windows edition (Home) - effective policy not readable; cache files listed instead.' 'INFO'
}
elseif ($IsAdmin) {
    try {
        $eff = Get-AppLockerPolicy -Effective -Xml
        Set-Content -Path (Join-Path $OutDir 'applocker-effective.xml') -Value $eff -Encoding UTF8
        $ruleCount = @(([xml]$eff).SelectNodes('//RuleCollection/*')).Count
        Say ("AppLocker effective policy exported ({0} rules across collections)" -f $ruleCount)
    } catch { Say "Get-AppLockerPolicy failed: $($_.Exception.Message)" 'WARN' }
}

# ============================== SURFACE: Installed apps (Win32 / uninstall) ===
Say 'Scanning Win32 installed apps (uninstall registry) ...'
$uninstPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$win32 = @(foreach ($rp in $uninstPaths) {
    Get-ItemProperty $rp -EA SilentlyContinue | Where-Object { $_.DisplayName } | ForEach-Object {
        [pscustomobject]@{
            DisplayName     = $_.DisplayName
            Version         = $_.DisplayVersion
            Publisher       = $_.Publisher
            InstallDate     = $_.InstallDate
            UninstallString = $_.UninstallString
            Hive            = ($rp -split ':')[0]
            AiTag           = (Get-AiTag $_.DisplayName)
        }
    }
})
$win32 = @($win32 | Sort-Object DisplayName -Unique)
$win32 | Export-Csv (Join-Path $OutDir 'win32-apps.csv') -NoTypeInformation -Encoding UTF8
Say ("Win32 apps: {0} entries" -f $win32.Count)

# ================================================= HUMAN-READABLE REPORT =======
$report = New-Object System.Collections.Generic.List[string]
$report.Add('================================================================')
$report.Add(' WinHardenDebloat  -  INVENTORY REPORT (read-only)')
$report.Add('================================================================')
$report.Add(('Scanned : {0}  (UTC {1})' -f $env:COMPUTERNAME, $osInfo.ScannedUtc))
$report.Add(('OS      : {0}  {1}  build {2}.{3}  {4}' -f $osInfo.Caption,$osInfo.DisplayVer,$osInfo.BuildNumber,$osInfo.UBR,$osInfo.Architecture))
$report.Add(('Elevated: {0}{1}' -f $IsAdmin, $(if(-not $IsAdmin){'   <-- limited scan: provisioned + AppLocker skipped'}else{''})))
$report.Add('')
$report.Add('-- APPX (installed vs staged) ----------------------------------')
$report.Add(('  installed for a user ........ {0}' -f $cInst))
$report.Add(('  staged only (new-user only) . {0}' -f $cStage))
$report.Add(('  both ........................ {0}' -f $cBoth))
$report.Add(('  distinct total .............. {0}' -f $appxTable.Count))
$report.Add('')
$report.Add('-- AI SURFACES DETECTED ----------------------------------------')
if ($aiHits) {
    foreach ($a in $aiHits) {
        $report.Add(('  [{0,-14}] {1,-14} removable={2,-5} {3}' -f $a.AiTag, $a.State, (-not $a.NonRemovable), $a.Name))
    }
} else { $report.Add('  (none matched the signature list)') }
if ($recall) { $report.Add(('  [Recall        ] optional-feature  state={0}' -f ($recall.State -join ','))) }
$sysAi = @($systemApps | Where-Object AiTag)
if ($sysAi) {
    $report.Add('  SystemApps folders tagged AI (OS components - flagged, not removable):')
    foreach ($s in $sysAi) { $report.Add(('    [{0,-14}] {1}' -f $s.AiTag, $s.Folder)) }
}
$report.Add('')

# ---- Phase 5 (A3): compare with the previous complete scan -------------------
$prevScan = @(Get-WHDSnapshots $OutputRoot | Where-Object { $_.Name -ne $Stamp -and $_.Name -lt $Stamp })
$report.Add('-- CHANGES SINCE LAST SCAN -------------------------------------')
if ($prevScan.Count) {
    try {
        $diff = Invoke-WHDInventoryDiff -OldDir $prevScan[-1].FullName -NewDir $OutDir -ProjectRoot $ProjectRoot
        foreach ($l in $diff.Lines) { $report.Add($l) }
    } catch { $report.Add(('  comparison failed: {0}' -f $_.Exception.Message)) }
} else { $report.Add('  (no earlier complete scan to compare with)') }
$report.Add('')
$report.Add('-- SURFACES ----------------------------------------------------')
$report.Add(('  SystemApps folders .......... {0}' -f $systemApps.Count))
$report.Add(('  Optional features ........... {0}' -f $optFeatures.Count))
$report.Add(('  Windows capabilities ........ {0}' -f $capabilities.Count))
$report.Add(('  WinSxS manifests ............ {0}' -f $winsxsInfo.ManifestCount))
$report.Add(('  Win32 uninstall entries ..... {0}' -f $win32.Count))
$report.Add('')
$report.Add('-- APPLOCKER (reinstall-blocking readiness) --------------------')
$report.Add(('  AppIDSvc status ............. {0}' -f $appLockerSvc.ServiceStatus))
$report.Add(('  AppIDSvc start type ......... {0}' -f $appLockerSvc.StartTypeReg))
$report.Add(('  Enforcement live ............ {0}' -f $appLockerSvc.EnforcementLive))
$report.Add(('  Cache files ................. {0}' -f $appLockerCacheFiles.Count))
$report.Add('')
$report.Add('-- OUTPUT FILES ------------------------------------------------')
Get-ChildItem $OutDir -File | ForEach-Object { $report.Add(('  {0}' -f $_.Name)) }
$report.Add('')
$report.Add('NOTE: This run made NO changes. It only reads and reports.')
$report.Add('================================================================')

$reportText = ($report -join [Environment]::NewLine)
Set-Content -Path (Join-Path $OutDir 'REPORT.txt') -Value $reportText -Encoding UTF8
$Log | Set-Content -Path (Join-Path $OutDir 'run.log') -Encoding UTF8

Write-Host ''
Write-Host $reportText
Write-Host ''
Say ("Done. Inventory written to: {0}" -f $OutDir)
