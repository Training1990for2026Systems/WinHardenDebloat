#requires -Version 7.6
<#
 WHD Next 3.0  -  Private/History.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 Reads the change history: this program's own restore\<session>\ folders and,
 when the owner chose "read in place" (D18), WHD Next 2.0's restore\ folder
 (read-only - that folder is never written to, D12). Entries are read as
 hashtables and always used with ['Name'], so a field an older entry does not
 have is simply empty.
   Session owner: 'this' | 'other' | 'legacy-this' | 'legacy-other'
   (machine.json, else the first entry's MachineId, else the session date
   against the Windows install date - same rules as WHD Next 2.0).
#>
$script:WHDSessionPattern = '^\d{4}-\d{2}-\d{2}_\d{6}$'

function Read-WHDJsonl {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$File)
    if (-not (Test-Path -LiteralPath $File)) { return @() }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($l in Get-Content -LiteralPath $File -Encoding utf8 -ErrorAction SilentlyContinue) {
        if (-not $l.Trim()) { continue }
        try { $out.Add(($l | ConvertFrom-Json -AsHashtable)) } catch { Write-Verbose ('skipped an unreadable line in {0}' -f $File) }
    }
    return $out.ToArray()
}

function Get-WHDWindowsInstallDate {
    [CmdletBinding()]
    param()
    try {
        $v = [int64](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name InstallDate -ErrorAction Stop).InstallDate
        return [DateTimeOffset]::FromUnixTimeSeconds($v).LocalDateTime
    } catch { return $null }
}

function Get-WHDSessionOwner {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$SessionPath)
    $me = Get-WHDMachineId
    $mf = Join-Path $SessionPath 'machine.json'
    if (Test-Path -LiteralPath $mf) {
        try { $m = Get-Content -LiteralPath $mf -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable } catch { $m = $null }
        if ($m -and $m['MachineId']) { return $(if (([string]$m['MachineId']).ToLowerInvariant() -eq $me) { 'this' } else { 'other' }) }
    }
    $first = @(Read-WHDJsonl -File (Join-Path $SessionPath 'journal.jsonl') | Where-Object { $_['MachineId'] } | Select-Object -First 1)
    if ($first.Count) { return $(if (([string]$first[0]['MachineId']).ToLowerInvariant() -eq $me) { 'this' } else { 'other' }) }
    $inst = Get-WHDWindowsInstallDate
    $stamp = $null
    try { $stamp = [datetime]::ParseExact((Split-Path $SessionPath -Leaf), 'yyyy-MM-dd_HHmmss', [cultureinfo]::InvariantCulture) } catch { $stamp = $null }
    if ($inst -and $stamp -and $stamp -lt $inst) { return 'legacy-other' }
    return 'legacy-this'
}

function Get-WHDHistoryRoot {
    # Every restore\ folder whose sessions belong to the history: own + Next 2.0 in place (D18).
    [CmdletBinding()]
    param()
    $roots = [System.Collections.Generic.List[object]]::new()
    $roots.Add([pscustomobject]@{ Path = (Join-Path $script:WHDState.DataRoot 'restore'); Source = 'own' })
    $set = Get-WHDSetting
    $nh = $set['NextHistory']
    if ($nh -and $nh['Mode'] -eq 'inplace' -and $nh['Source']) { $roots.Add([pscustomobject]@{ Path = [string]$nh['Source']; Source = 'next2' }) }
    return $roots.ToArray()
}

function Get-WHDUndoneMark {
    # Ids already undone: the session's own undo.jsonl, plus (for WHD Next 2.0's sessions read in place)
    # restore\next2-undo.jsonl of this program - Next 2.0's folder itself is never written to.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$SessionPath)
    $ids = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($m in Read-WHDJsonl -File (Join-Path $SessionPath 'undo.jsonl')) { [void]$ids.Add([string]$m['Id']) }
    $own = Join-Path (Join-Path $script:WHDState.DataRoot 'restore') 'next2-undo.jsonl'
    $stamp = Split-Path $SessionPath -Leaf
    foreach ($m in Read-WHDJsonl -File $own) { if ([string]$m['Session'] -eq $stamp) { [void]$ids.Add([string]$m['Id']) } }
    return , $ids
}

function Get-WHDUndoMode {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Entry)
    switch ([string]$Entry['Kind']) {
        'reg'        { if ($Entry['OldExists'] -and -not $Entry['OldType']) { return 'manual' } return 'auto' }
        'schtask'    { if ($Entry['Existed']) { return 'manual' } return 'auto' }    # update guard (step 7): undo removes task + copy + source
        { $_ -in 'service', 'feature', 'regkey', 'auditpol', 'eventlog', 'fwrule', 'file', 'mppref', 'asr', 'netacct', 'task', 'pnpdev', 'tz', 'deprov', 'fwlog', 'svctrigger' } { return 'auto' }
        default      { return 'manual' }
    }
}

function Get-WHDUndoHint {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Entry)
    switch ([string]$Entry['Kind']) {
        'appx'        { 'reinstall it from the Microsoft Store if you want it back' }
        'provisioned' { 'new user accounts will not get it; reinstall from the Store per user if needed' }
        'action'      { if ($Entry['Hint']) { [string]$Entry['Hint'] } else { 'use this session''s firewall backup, a restore point, or redo it by hand' } }
        'schtask'     { if ($Entry['Existed']) { 'it was a refresh - remove the update guard with main menu G > 4' } else { 'automatic' } }
        default       { 'automatic' }
    }
}

function Get-WHDHistorySession {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([switch]$IncludeOtherPCs)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($root in Get-WHDHistoryRoot) {
        if (-not (Test-Path -LiteralPath $root.Path)) {
            if ($root.Source -eq 'next2') { Write-WHDLog -Message ('WHD Next 2.0 history folder not found: {0}' -f $root.Path) -Level 'WARN' }
            continue
        }
        foreach ($d in Get-ChildItem -LiteralPath $root.Path -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $script:WHDSessionPattern }) {
            $jn = @(Read-WHDJsonl -File (Join-Path $d.FullName 'journal.jsonl')).Count
            $regs = @(Get-ChildItem -LiteralPath $d.FullName -Filter '*.reg' -File -ErrorAction SilentlyContinue).Count
            $wfw = Test-Path -LiteralPath (Join-Path $d.FullName 'firewall-before.wfw')
            $hosts = Test-Path -LiteralPath (Join-Path $d.FullName 'hosts.bak')
            if (($jn + $regs) -eq 0 -and -not $wfw -and -not $hosts) { continue }
            $owner = Get-WHDSessionOwner -SessionPath $d.FullName
            if (-not $IncludeOtherPCs -and $owner -in 'other', 'legacy-other') { continue }
            $out.Add([pscustomobject]@{
                Stamp = $d.Name; Path = $d.FullName; Source = $root.Source; Owner = $owner
                Entries = $jn; Undone = (Get-WHDUndoneMark -SessionPath $d.FullName).Count; RegFiles = $regs; HasWfw = $wfw; HasHosts = $hosts
            })
        }
    }
    return @($out | Sort-Object Stamp -Descending)
}

function Get-WHDHistoryEntry {
    # The entries of one session, oldest first, with Seq, UndoMode, Undone, SessionPath and Source added.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath, [string]$Source = 'own')
    $undone = Get-WHDUndoneMark -SessionPath $SessionPath
    $seq = 0
    foreach ($e in Read-WHDJsonl -File (Join-Path $SessionPath 'journal.jsonl')) {
        $seq++
        $e['Seq'] = $seq
        $e['UndoMode'] = Get-WHDUndoMode -Entry $e
        $e['Undone'] = $undone.Contains([string]$e['Id'])
        $e['SessionPath'] = $SessionPath
        $e['Source'] = $Source
        $e
    }
}

function Find-WHDNext2History {
    # Where WHD Next 2.0 keeps its history: the WHD-Next folder next to this one, and its unlocked copy.
    [CmdletBinding()]
    param()
    $cands = @(
        (Join-Path (Join-Path (Split-Path $script:WHDState.Root -Parent) 'WHD-Next') 'restore'),
        $(if ($env:ProgramData) { Join-Path $env:ProgramData 'WinHardenDebloatNext\app\restore' })
    ) | Where-Object { $_ }
    $own = [IO.Path]::GetFullPath((Join-Path $script:WHDState.DataRoot 'restore'))
    $found = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $cands) {
        if (-not (Test-Path -LiteralPath $c)) { continue }
        if ([IO.Path]::GetFullPath($c) -eq $own) { continue }
        $sessions = @(Get-ChildItem -LiteralPath $c -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $script:WHDSessionPattern -and (Test-Path -LiteralPath (Join-Path $_.FullName 'journal.jsonl')) })
        if (-not $sessions.Count) { continue }
        $n = 0; foreach ($s in $sessions) { $n += @(Read-WHDJsonl -File (Join-Path $s.FullName 'journal.jsonl')).Count }
        $found.Add([pscustomobject]@{ Path = $c; Sessions = $sessions.Count; Entries = $n })
    }
    return $found.ToArray()
}

function Copy-WHDNext2History {
    # Copies WHD Next 2.0's session folders once into this program's restore\ (D18 "copy").
    # Reads the source only; a session that is already here is left as it is.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Source)
    $dest = Join-Path $script:WHDState.DataRoot 'restore'
    if (-not (Test-Path -LiteralPath $dest)) { [void](New-Item -ItemType Directory -Path $dest -Force -ErrorAction Stop) }
    $copied = 0; $kept = 0
    foreach ($d in Get-ChildItem -LiteralPath $Source -Directory -ErrorAction Stop | Where-Object { $_.Name -match $script:WHDSessionPattern }) {
        $to = Join-Path $dest $d.Name
        if (Test-Path -LiteralPath $to) { $kept++; continue }
        if (-not $PSCmdlet.ShouldProcess($d.FullName, 'copy session')) { continue }
        Copy-Item -LiteralPath $d.FullName -Destination $to -Recurse -ErrorAction Stop
        $copied++
    }
    return [pscustomobject]@{ Copied = $copied; AlreadyHere = $kept }
}
