<#
================================================================================
 WinHardenDebloat  -  modules\Maintenance.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Component store (WinSxS) maintenance - the SUPPORTED way to reclaim space.

 IMPORTANT: nothing here deletes files inside WinSxS by hand. Manual deletion
 of WinSxS / Manifests / SettingsManifests corrupts servicing and can make
 Windows unrepairable. All work goes through DISM, which removes only
 SUPERSEDED components:
   * AnalyzeComponentStore  - read-only; reports real reclaimable size.
   * StartComponentCleanup  - removes superseded components (safe, keeps the
                              ability to uninstall installed updates).
   * StartComponentCleanup /ResetBase - removes ALL superseded components for
                              maximum space, but you can no longer uninstall
                              previously-installed Windows updates. NOT undone
                              by a restore point. Opt-in only.

 Reuses Common.ps1.
================================================================================
#>

function _WHDRunDism {
    param([string[]]$DismArgs)
    Write-WHDLog ("DISM {0}" -f ($DismArgs -join ' ')) 'INFO'
    try {
        # local to this function: a line DISM writes to stderr is shown, not turned into a terminating error
        $ErrorActionPreference = 'Continue'
        & dism.exe @DismArgs 2>&1 | ForEach-Object { Write-Host ("    {0}" -f $_) }
        if ($LASTEXITCODE -ne 0) { throw "DISM exited with code $LASTEXITCODE" }
    } catch {
        Write-WHDLog ("DISM error: {0}" -f $_.Exception.Message) 'ERR'
        throw   # the caller (Invoke-WHDChange) must record a failed DISM run as FAILED, not done
    }
}

function Invoke-WHDComponentAnalyze {
    # Read-only: safe to run in any mode. Reports the ACTUAL reclaimable size
    # (not the inflated Explorer number) and whether cleanup is recommended.
    Write-WHDLog 'COMPONENT STORE ANALYSIS (read-only)' 'ACT'
    try { _WHDRunDism -DismArgs @('/Online','/Cleanup-Image','/AnalyzeComponentStore') } catch { }   # already logged by _WHDRunDism
}

function Invoke-WHDComponentCleanup {
    param([switch]$ResetBase)
    $dismArgs = @('/Online','/Cleanup-Image','/StartComponentCleanup')
    $label    = 'StartComponentCleanup'
    if ($ResetBase) { $dismArgs += '/ResetBase'; $label = 'StartComponentCleanup /ResetBase' }

    Write-WHDLog ("COMPONENT STORE CLEANUP: {0}" -f $label) 'ACT'
    if ($ResetBase) {
        Write-WHDRisk 'hard' 'ResetBase removes ALL superseded components. After this you CANNOT uninstall previously-installed Windows updates. A restore point does not undo that. Opt-in.'
    } else {
        Write-WHDRisk 'reversible' 'Removes only superseded components. Supported and safe; keeps the ability to uninstall installed updates.'
    }
    if (-not (Confirm-WHDProceed ("run DISM {0}" -f $label))) { Write-WHDLog 'skipped.' 'WARN'; return }
    $jr = @{ Kind = 'action' }
    if ($ResetBase) { $jr['Hint'] = 'cannot be undone - after ResetBase the Windows updates installed before it can no longer be uninstalled, and a restore point does not bring that back' }
    Invoke-WHDChange -Description ("DISM {0}" -f $label) -Force -Journal $jr -Action {
        _WHDRunDism -DismArgs $dismArgs
    }
}

function Show-WHDMaintenanceMenu {
    Write-Host ''
    Write-Host '  COMPONENT STORE (WinSxS) MAINTENANCE' -ForegroundColor White
    Write-Host '  ----------------------------------------------------------------'
    Write-Host '  Reclaims space the SUPPORTED way (DISM). Never hand-deletes WinSxS.'
    Write-Host ''
    Write-Host '   A. Analyze component store (read-only - real reclaimable size)'
    Write-Host '   C. Clean up superseded components (safe)'
    Write-Host '   R. Clean up + ResetBase (max space; removes update-uninstall)  [flagged]' -ForegroundColor Yellow
    Write-Host '   B. Back'
}

# ==============================================================================
# UPDATE GUARD (alert only; never changes anything)
# ------------------------------------------------------------------------------
# How it works:
#   * runs at sign-in, 10 minutes after logon (scheduled task, user account,
#     highest privileges, only while signed in)
#   * checks: Verify ALL (every journaled WHD change) + inventory compare
#   * inventory scan only when Windows changed (build/UBR or installed-update
#     list); Defender signature updates are not in that list
#   * alert = report file guard_<time>.txt, plus a small always-on-top window
#     and a Windows event log entry (Application log, source WinHardenDebloat)
#     ONLY when a WHD change was undone/returned or a removed app came back;
#     if the window cannot be shown the report is opened in Notepad instead
#   * the guard's own files (reports, status, its scans) are kept in
#     C:\ProgramData\WinHardenDebloat\guard-data once the guard is installed
#     (before that: restore\update-guard\ and inventory\ in the WHD folder)
#   * keeps the last 5 guard-made inventory scans (user scans never touched)
#   * scripts run from a PROTECTED copy in ProgramData (admins/SYSTEM write,
#     users read) so a user-level program cannot tamper with them to gain admin
# ==============================================================================
$script:WHDGuardTaskPath = '\WinHardenDebloat\'
$script:WHDGuardTaskName = 'UpdateGuard'
$script:WHDGuardBase     = Join-Path $env:ProgramData 'WinHardenDebloat'
$script:WHDGuardDir      = Join-Path $script:WHDGuardBase 'guard'
$script:WHDGuardKeep     = 5
$script:WHDGuardDelay    = 'PT10M'
$script:WHDGuardMarker   = '.whd-guard'

# ---- v1.5: the guard keeps its OWN files outside the WHD folder -----------------
# Why: with ransomware folder protection in BLOCK mode Windows PowerShell may not write into Documents,
# Desktop ... - a WHD folder there could not take the guard's report and status, and the check ended.
# The guard's reports, its status and its own scans are kept in
#     C:\ProgramData\WinHardenDebloat\guard-data      (same layout: restore\update-guard, inventory)
# The change history (journals) is still READ from the WHD folder, and the files the menus write
# (update-gate.json, blocked-programs.json ...) stay in the WHD folder.
# Safety - this folder sits next to the protected script copy that a scheduled task runs elevated:
#   * guard-data is made only by elevated WHD code, and only inside the base folder AFTER that was locked
#     (Administrators + SYSTEM full, Users read) - so it gets the same permissions. The base folder itself is
#     made and locked only by the guard install (_WHDGuardCopy), never by a check;
#   * it is used only while: it exists, no folder on the way is a link (reparse point), and both the base and
#     guard-data are owned by Administrators / SYSTEM with no write access for anyone else. If not, the guard
#     keeps using <WHD folder>\restore\update-guard as before and says why;
#   * nothing in guard-data is ever run - it holds reports, the status file and scan results only.
$script:WHDGuardDataName    = 'guard-data'
$script:WHDGuardTrustedSids = @('S-1-5-32-544', 'S-1-5-18')      # Administrators, SYSTEM (well-known SIDs, any language)
# File rights that let an account add, change, delete or re-permission: WriteData/CreateFiles 0x2,
# AppendData/CreateDirectories 0x4, WriteExtendedAttributes 0x10, DeleteSubdirectoriesAndFiles 0x40,
# WriteAttributes 0x100, Delete 0x10000, ChangePermissions 0x40000, TakeOwnership 0x80000,
# GENERIC_ALL 0x10000000, GENERIC_WRITE 0x40000000.
$script:WHDGuardWriteMask   = 0x500D0156
# Set (to the reason) when this session must not use guard-data, e.g. a check that runs without elevation.
if (-not (Get-Variable -Name WHDGuardDataOff -Scope Script -EA SilentlyContinue)) { $script:WHDGuardDataOff = '' }

function _WHDGuardDataFolders {
    # guard-data and the folders the guard uses inside it
    param([string]$Base)
    $whdGdf = Join-Path $Base $script:WHDGuardDataName
    @($whdGdf, (Join-Path $whdGdf 'restore'), (Join-Path $whdGdf 'restore\update-guard'), (Join-Path $whdGdf 'inventory'))
}
function _WHDGuardFirstLink {
    # The first of these paths that is a link (junction / symbolic link), or ''. A link there would send the
    # guard's files - and the permissions - somewhere else. (Get-Item -Force also sees a link whose target is gone.)
    param([string[]]$Paths)
    foreach ($whdLp in @($Paths)) {
        if (-not $whdLp) { continue }
        $whdLi = Get-Item -LiteralPath $whdLp -Force -EA SilentlyContinue
        if ($whdLi -and ($whdLi.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $whdLp }
    }
    return ''
}
function _WHDGuardAclInfo {
    # Owner + access rules of a folder as plain values (SIDs), read-only.
    param([string]$Path)
    $whdAcl  = Get-Acl -LiteralPath $Path -EA Stop
    $whdSidT = [System.Security.Principal.SecurityIdentifier]
    $whdRules = @(foreach ($whdAr in @($whdAcl.GetAccessRules($true, $true, $whdSidT))) {
        [pscustomobject]@{ Sid = "$($whdAr.IdentityReference.Value)"; Allow = ("$($whdAr.AccessControlType)" -eq 'Allow'); Rights = [int]$whdAr.FileSystemRights }
    })
    [pscustomobject]@{ Owner = "$($whdAcl.GetOwner($whdSidT).Value)"; Rules = $whdRules }
}
# '' when the folder is locked the way the guard install locks it (owner Administrators or SYSTEM, nobody
# else may write); otherwise what is wrong. A folder that cannot be read counts as not locked. Never throws.
function Get-WHDGuardFolderProblem {
    param([string]$Path)
    $whdAi = $null
    try { $whdAi = _WHDGuardAclInfo -Path $Path } catch { return ('its permissions could not be read ({0})' -f $_.Exception.Message) }
    if (-not $whdAi -or -not "$($whdAi.Owner)") { return 'its permissions could not be read' }
    if ($script:WHDGuardTrustedSids -notcontains "$($whdAi.Owner)") { return ('its owner is {0}, not Administrators or SYSTEM' -f $whdAi.Owner) }
    foreach ($whdAr in @($whdAi.Rules)) {
        if (-not $whdAr -or -not $whdAr.Allow) { continue }
        if ($script:WHDGuardTrustedSids -contains "$($whdAr.Sid)") { continue }
        if (([int]$whdAr.Rights -band $script:WHDGuardWriteMask) -ne 0) { return ('{0} may write there' -f $whdAr.Sid) }
    }
    return ''
}
# Is guard-data used? Use = yes/no; Why = the reason when it exists but is refused ('' when it is simply
# not there yet, or when it is used). Read-only, never throws, makes nothing.
function Get-WHDGuardDataCheck {
    $whdBase = $script:WHDGuardBase
    $whdGd   = Join-Path $whdBase $script:WHDGuardDataName
    $whdChk  = [ordered]@{ Use = $false; Root = $whdGd; Why = '' }
    try {
        if ("$($script:WHDGuardDataOff)") { $whdChk.Why = "$($script:WHDGuardDataOff)"; return [pscustomobject]$whdChk }
        if (-not (Test-Path -LiteralPath $whdBase)) { return [pscustomobject]$whdChk }      # guard never installed: nothing to look at
        $whdLink = _WHDGuardFirstLink -Paths (@($whdBase) + @(_WHDGuardDataFolders -Base $whdBase))
        if ($whdLink) { $whdChk.Why = ('{0} is a link (reparse point)' -f $whdLink); return [pscustomobject]$whdChk }
        if (-not (Test-Path -LiteralPath $whdGd)) { return [pscustomobject]$whdChk }
        if (-not (Test-Path -LiteralPath $whdGd -PathType Container)) { $whdChk.Why = ('{0} is not a folder' -f $whdGd); return [pscustomobject]$whdChk }
        foreach ($whdCf in @($whdBase, $whdGd)) {
            $whdProb = Get-WHDGuardFolderProblem -Path $whdCf
            if ($whdProb) { $whdChk.Why = ('{0}: {1}' -f $whdCf, $whdProb); return [pscustomobject]$whdChk }
        }
        $whdChk.Use = $true
    } catch { $whdChk.Use = $false; $whdChk.Why = ('{0} could not be checked: {1}' -f $whdGd, $_.Exception.Message) }
    return [pscustomobject]$whdChk
}
function Test-WHDGuardDataMoved { return [bool](Get-WHDGuardDataCheck).Use }
function Get-WHDGuardDataRoot {
    if (Test-WHDGuardDataMoved) { return (Join-Path $script:WHDGuardBase $script:WHDGuardDataName) }
    return $script:WHDRoot
}
function Get-WHDGuardDataDir       { Join-Path (Get-WHDGuardDataRoot) 'restore\update-guard' }
function Get-WHDGuardOldDataDir    { Join-Path $script:WHDRoot 'restore\update-guard' }      # where the guard's files were before v1.5
function Get-WHDGuardInventoryRoot { Join-Path (Get-WHDGuardDataRoot) 'inventory' }

# Makes guard-data and its folders. ONLY for callers that have just made sure the base folder is locked
# (then the new folders inherit: Administrators + SYSTEM full, Users read). Elevated sessions only.
function _WHDGuardDataMake {
    param([string]$Base)
    if (-not (Test-Path -LiteralPath $Base -PathType Container)) { throw 'the guard base folder is not there' }   # never made here
    $whdMk = @(_WHDGuardDataFolders -Base $Base)
    $whdMkNew = -not (Test-Path -LiteralPath $whdMk[0])
    foreach ($whdMd in $whdMk) { if (-not (Test-Path -LiteralPath $whdMd)) { New-Item -ItemType Directory -Path $whdMd -EA Stop | Out-Null } }
    # owner = Administrators whatever account made it (with UAC switched off the creator would be the owner)
    if ($whdMkNew) { _WHDIcacls @($whdMk[0], '/setowner', '*S-1-5-32-544', '/T', '/C', '/Q') }
}
# Called at the start of a check: makes guard-data when that is safe, and tells why when it is not used.
# Returns Ready (guard-data can be written by this session), Why ('' = nothing to say) and Alert (the
# reason is something to look at, not just information). Never throws.
#   * not elevated            -> never makes or writes there; this session uses the WHD folder as before
#   * base folder not there   -> the guard is not installed: nothing is made here (as before v1.5)
#   * a link, or not locked   -> refused, with the reason (Alert)
function _WHDGuardDataPrepare {
    $whdBase = $script:WHDGuardBase
    $whdPr = [ordered]@{ Ready = $false; Why = ''; Alert = $false }
    try {
        if (-not (Test-WHDAdmin)) {
            if (-not "$($script:WHDGuardDataOff)" -and (Get-WHDGuardDataCheck).Use) {
                $script:WHDGuardDataOff = 'this session is not elevated, and only an elevated session may write there'
            }
            $whdPr.Why = "$($script:WHDGuardDataOff)"      # '' when guard-data is not in use anyway
            return [pscustomobject]$whdPr
        }
        $whdChk = Get-WHDGuardDataCheck
        if ($whdChk.Use) {
            _WHDGuardDataMake -Base $whdBase       # only fills in a missing sub-folder
            $whdPr.Ready = $true; return [pscustomobject]$whdPr
        }
        if ($whdChk.Why) { $whdPr.Why = "$($whdChk.Why)"; $whdPr.Alert = $true; return [pscustomobject]$whdPr }
        # guard-data is not there yet
        if (-not (Test-Path -LiteralPath $whdBase -PathType Container)) { return [pscustomobject]$whdPr }
        $whdProb = Get-WHDGuardFolderProblem -Path $whdBase
        if ($whdProb) { $whdPr.Why = ('{0}: {1}' -f $whdBase, $whdProb); $whdPr.Alert = $true; return [pscustomobject]$whdPr }
        _WHDGuardDataMake -Base $whdBase
        $whdChk = Get-WHDGuardDataCheck
        if ($whdChk.Use) { $whdPr.Ready = $true } else { $whdPr.Why = "$($whdChk.Why)"; $whdPr.Alert = $true }
    } catch { $whdPr.Ready = $false; $whdPr.Alert = $true; $whdPr.Why = ('{0} could not be prepared: {1}' -f (Join-Path $whdBase $script:WHDGuardDataName), $_.Exception.Message) }
    return [pscustomobject]$whdPr
}

# The first time the guard uses guard-data, its older reports, its status and its own scans are COPIED there
# from the WHD folder. Nothing is removed from the WHD folder. Only when the old status belongs to this PC;
# files that already exist in the new place are kept; links in the WHD folder are not followed. A note file
# (copied-from.txt) marks that this was done, so it happens once. Returns $null when there was nothing to
# do, otherwise what was copied. Never throws.
function Copy-WHDGuardDataOnce {
    if (-not (Test-WHDGuardDataMoved)) { return $null }
    $newDir = Get-WHDGuardDataDir
    $mark   = Join-Path $newDir 'copied-from.txt'
    if (Test-Path -LiteralPath $mark) { return $null }
    $oldDir = Get-WHDGuardOldDataDir
    $r = [ordered]@{ From = "$($script:WHDRoot)"; Reports = 0; Scans = 0; State = $false; Failed = 0; Note = '' }
    $whdNoLink = { param($whdFi) -not ($whdFi.Attributes -band [IO.FileAttributes]::ReparsePoint) }
    try {
        if (-not (Test-Path -LiteralPath $newDir)) { New-Item -ItemType Directory -Path $newDir -Force -EA Stop | Out-Null }
        $oldStateFile = Join-Path $oldDir 'state.json'
        $oldState = $null
        if (Test-Path -LiteralPath $oldStateFile) { try { $oldState = Get-Content -LiteralPath $oldStateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $oldState = $null } }
        if (-not $oldState) { $r.Note = 'nothing copied: the WHD folder has no guard status' }
        elseif ((Get-Command Test-WHDGuardStateIsThisPC -EA SilentlyContinue) -and -not (Test-WHDGuardStateIsThisPC -State $oldState)) { $r.Note = 'nothing copied: the guard status in the WHD folder belongs to another PC or an earlier Windows install' }
        else {
            # reports (+ the error notes, if any)
            foreach ($f in @(Get-ChildItem -LiteralPath $oldDir -File -EA SilentlyContinue | Where-Object { ($_.Name -like 'guard_*.txt' -or $_.Name -eq 'guard-errors.txt') -and (& $whdNoLink $_) })) {
                $whdT = Join-Path $newDir $f.Name
                if (Test-Path -LiteralPath $whdT) { continue }
                try { Copy-Item -LiteralPath $f.FullName -Destination $whdT -EA Stop; if ($f.Name -like 'guard_*.txt') { $r.Reports++ } } catch { $r.Failed++ }
            }
            # the guard's own scans (folders carrying the marker); the user's scans stay where they are
            $oldInv = Join-Path $script:WHDRoot 'inventory'; $newInv = Get-WHDGuardInventoryRoot
            foreach ($d in @(Get-ChildItem -LiteralPath $oldInv -Directory -EA SilentlyContinue | Where-Object { (& $whdNoLink $_) -and (Test-Path -LiteralPath (Join-Path $_.FullName $script:WHDGuardMarker)) })) {
                $whdTd = Join-Path $newInv $d.Name
                if (Test-Path -LiteralPath $whdTd) { continue }
                try {
                    New-Item -ItemType Directory -Path $whdTd -Force -EA Stop | Out-Null
                    foreach ($sf in @(Get-ChildItem -LiteralPath $d.FullName -File -Force -EA SilentlyContinue | Where-Object { & $whdNoLink $_ })) { Copy-Item -LiteralPath $sf.FullName -Destination (Join-Path $whdTd $sf.Name) -EA Stop }
                    $r.Scans++
                } catch {
                    $r.Failed++
                    # a half-copied scan would later be compared as if it were complete: take the copy away again
                    # (made just above; the scan in the WHD folder is not touched) so it is tried again next time
                    try { Remove-Item -LiteralPath $whdTd -Recurse -Force -EA Stop } catch { }
                }
            }
            # the status: the known values only, as text; "last report" points at the copied report (or is empty)
            $newStateFile = Join-Path $newDir 'state.json'
            if (-not (Test-Path -LiteralPath $newStateFile)) {
                try {
                    $whdNs = [ordered]@{}
                    foreach ($whdSk in @('Fingerprint', 'Build', 'LastCheck', 'LastResult', 'MachineId', 'Computer')) {
                        if ($null -ne $oldState.$whdSk) { $whdNs[$whdSk] = "$($oldState.$whdSk)" }
                    }
                    $whdNs['LastReport'] = ''
                    if ("$($oldState.LastReport)") {
                        $whdLeaf = Split-Path -Leaf ("$($oldState.LastReport)" -replace '\\', '/')
                        if ($whdLeaf -like 'guard_*.txt' -and (Test-Path -LiteralPath (Join-Path $newDir $whdLeaf))) { $whdNs['LastReport'] = (Join-Path $newDir $whdLeaf) }
                    }
                    ($whdNs | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $newStateFile -Encoding UTF8 -EA Stop
                    $r.State = $true
                } catch { $r.Failed++ }
            }
            $r.Note = ('copied {0} report(s), {1} guard scan(s), status: {2}' -f $r.Reports, $r.Scans, $(if ($r.State) { 'yes' } else { 'no' }))
        }
        if ($r.Failed -eq 0) {
            @('WinHardenDebloat - update guard data',
              ('This folder holds the update guard''s reports, status and scans since {0}.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm')),
              ('WHD folder at that time : {0}' -f $r.From),
              ('Taken over from there   : {0}' -f $r.Note),
              'Nothing was removed from the WHD folder.') | Set-Content -LiteralPath $mark -Encoding ASCII -EA Stop
        } else { $r.Note = $r.Note + ('; {0} file(s) could not be copied - tried again at the next check' -f $r.Failed) }
    } catch { $r.Failed++; $r.Note = ('could not prepare {0}: {1}' -f $newDir, $_.Exception.Message) }
    return [pscustomobject]$r
}

function Get-WHDGuardCodeRoot {
    if ($script:WHDCodeRoot) { return $script:WHDCodeRoot }
    return $script:WHDRoot
}
function Get-WHDGuardTask {
    # SilentlyContinue (not Stop+catch) so a missing task leaves no TerminatingError line in the transcript.
    @(Get-ScheduledTask -TaskPath $script:WHDGuardTaskPath -EA SilentlyContinue | Where-Object { $_.TaskName -eq $script:WHDGuardTaskName })[0]
}
function Get-WHDGuardState {
    $p = Join-Path (Get-WHDGuardDataDir) 'state.json'
    if (-not (Test-Path -LiteralPath $p)) {
        # v1.5: until the first check in guard-data, the status in the WHD folder still counts (read only).
        $whdOldP = Join-Path (Get-WHDGuardOldDataDir) 'state.json'
        if ((Test-WHDGuardDataMoved) -and (Test-Path -LiteralPath $whdOldP)) { $p = $whdOldP } else { return $null }
    }
    $s = $null
    try { $s = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $s = $null }
    # v1.5: a status file that came along from another PC / an earlier Windows install is not this PC's status.
    try { if ($s -and (Get-Command Test-WHDGuardStateIsThisPC -EA SilentlyContinue) -and -not (Test-WHDGuardStateIsThisPC -State $s)) { return $null } } catch { }
    return $s
}
# Saves the status. Never throws and returns nothing: a status that cannot be saved (folder protection) must
# not end the check. $script:WHDGuardStateError is '' afterwards, or says why it was not saved.
#   -Dir = the folder to save to (the check passes the one it chose at its start); default: Get-WHDGuardDataDir.
function Save-WHDGuardState {
    param($State, [string]$Dir)
    $script:WHDGuardStateError = ''
    $d = $Dir
    try {
        if (-not $d) { $d = Get-WHDGuardDataDir }
        # tag the status with this PC, so a copied folder is recognised on another PC / Windows install
        if ($State -is [System.Collections.IDictionary]) { $State['MachineId'] = Get-WHDMachineId; $State['Computer'] = "$env:COMPUTERNAME" }
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force -EA Stop | Out-Null }
        ($State | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath (Join-Path $d 'state.json') -Encoding UTF8 -EA Stop
    } catch {
        $script:WHDGuardStateError = "$($_.Exception.Message)"
        if (-not $script:WHDGuardStateError) { $script:WHDGuardStateError = 'unknown error' }
        try { Write-WHDLog ("UPDATE GUARD: the status file could not be saved to {0}: {1}" -f $d, $script:WHDGuardStateError) 'ERR' } catch { }
    }
}
# Saves the guard report. When that fails (folder protection), says why and prints the report in the log
# instead of ending the check. Returns $true when the file was written. Never throws.
function Save-WHDGuardReport {
    param([string]$Path, [string[]]$Lines)
    try { $Lines | Set-Content -LiteralPath $Path -Encoding UTF8 -EA Stop; return $true }
    catch {
        try {
            Write-WHDLog ("UPDATE GUARD: the report could not be saved to {0}: {1}" -f $Path, $_.Exception.Message) 'ERR'
            if (Get-Command Write-WHDProtectedFolderWarning -EA SilentlyContinue) { Write-WHDProtectedFolderWarning }
            Write-WHDLog 'The report, shown here instead:' 'WARN'
            foreach ($l in @($Lines)) { Write-WHDLog ("  | {0}" -f $l) 'INFO' }
        } catch { }
        return $false
    }
}
function Get-WHDGuardStatus {
    $t = Get-WHDGuardTask
    $s = Get-WHDGuardState
    $txt = if (-not $t) { 'not installed' } else { "installed ($($t.State))" }
    if ($s -and $s.LastCheck) { $txt += (", last check {0}: {1}" -f $s.LastCheck, $s.LastResult) }
    elseif ($t) { $txt += ', no check yet' }
    [pscustomobject]@{ Installed = [bool]$t; State = $(if ($t) { "$($t.State)" } else { '' }); Last = $s; Text = $txt }
}

# Build + installed-update list. Cumulative/feature updates change these;
# Defender signature updates do not (they are not hotfixes).
function Get-WHDUpdateFingerprint {
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -EA SilentlyContinue
    $build = "{0}.{1}" -f $cv.CurrentBuild, $cv.UBR
    $hf = @()
    try { $hf = @(Get-HotFix -EA Stop | ForEach-Object { "$($_.HotFixID)" } | Where-Object { $_ } | Sort-Object -Unique) } catch {}
    [pscustomobject]@{ Build = $build; HotFixes = $hf; Text = ("{0}|{1}" -f $build, ($hf -join ',')) }
}

# Reasons to NOT check now (servicing unfinished). Empty = safe to check.
function Get-WHDServicingBusy {
    $why = @()
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $why += 'a Windows component update is waiting for a restart' }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $why += 'Windows Update is waiting for a restart' }
    if (@(Get-Process -Name 'TiWorker' -EA SilentlyContinue).Count) { $why += 'Windows is still installing updates (TiWorker running)' }
    @($why)
}

# Delete all but the newest N guard-made scans (folders carrying the marker).
# A folder that is a link (reparse point) is never counted or deleted.
function Remove-WHDOldGuardScans {
    param([string]$InvRoot, [int]$Keep = $script:WHDGuardKeep)
    $g = @(Get-ChildItem -LiteralPath $InvRoot -Directory -EA SilentlyContinue |
           Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and (Test-Path -LiteralPath (Join-Path $_.FullName $script:WHDGuardMarker)) } | Sort-Object Name)
    $gone = @()
    if ($g.Count -gt $Keep) {
        foreach ($d in $g[0..($g.Count - $Keep - 1)]) {
            try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -EA Stop; $gone += $d.Name } catch {}
        }
    }
    @($gone)
}

# The check itself. Read-only. Returns a summary object; writes the report.
function Invoke-WHDUpdateGuard {
    # -Now = run from the menu/GUI: never wait silently for Windows servicing;
    # say so on screen and stop (the scheduled run at sign-in does the waiting).
    param([switch]$NoPopup, [switch]$Now)
    # v1.5: where the guard keeps its own files for this check - guard-data under ProgramData when that is
    # there and safe, otherwise the WHD folder as before (see the notes above Get-WHDGuardDataCheck).
    # Decided once here; the paths below are used for the whole check.
    $whdGdPath = Join-Path $script:WHDGuardBase $script:WHDGuardDataName
    $whdPrep   = _WHDGuardDataPrepare
    $whdMoved  = Test-WHDGuardDataMoved
    $dataDir   = Join-Path $script:WHDRoot 'restore\update-guard'
    $whdGuardInv = Join-Path $script:WHDRoot 'inventory'
    if ($whdMoved) { $dataDir = Join-Path $whdGdPath 'restore\update-guard'; $whdGuardInv = Join-Path $whdGdPath 'inventory' }
    # A folder that cannot be made (folder protection) must not end the check - the saves below report it.
    try { if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force -EA Stop | Out-Null } }
    catch { Write-WHDLog ("UPDATE GUARD: the folder {0} could not be made: {1}" -f $dataDir, $_.Exception.Message) 'ERR' }
    if ($whdPrep.Why) { Write-WHDLog ("UPDATE GUARD: {0} is not used - {1}. The guard's files stay in {2}." -f $whdGdPath, $whdPrep.Why, $dataDir) 'WARN' }
    elseif (-not $whdMoved) { Write-WHDLog ("UPDATE GUARD: its files are kept in {0} ({1} is made when the guard is installed or refreshed - GU in any menu)." -f $dataDir, $whdGdPath) 'INFO' }
    # first use of guard-data -> take the older reports / status / guard scans over (copy, once)
    $whdTaken = $null
    if ($whdMoved) { $whdTaken = Copy-WHDGuardDataOnce }
    if ($whdTaken) { Write-WHDLog ("UPDATE GUARD: its files are now kept in {0} ({1})." -f $whdGdPath, $whdTaken.Note) $(if ($whdTaken.Failed) { 'WARN' } else { 'INFO' }) }
    $stamp  = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $report = Join-Path $dataDir ("guard_{0}.txt" -f $stamp)
    $rep    = New-Object System.Collections.Generic.List[string]
    $alert  = $false
    $state  = Get-WHDGuardState
    $rep.Add('WinHardenDebloat - UPDATE GUARD (alert only - nothing was changed)')
    $rep.Add(("Checked : {0}   on {1} as {2}\{3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME, $env:USERDOMAIN, $env:USERNAME))
    if ($whdMoved) {
        $rep.Add(("Files   : {0}  (the guard's reports + status: restore\update-guard, its own scans: inventory)" -f $whdGdPath))
        $rep.Add(("          WHD folder (the change history is read from there): {0}" -f $script:WHDRoot))
        if ($whdTaken) { $rep.Add(("          First check with this folder - from the WHD folder: {0}. Nothing was removed there." -f $whdTaken.Note)) }
    }
    # guard-data was refused (a link, or not locked any more) = something to look at;
    # a session that is not elevated only gets a note
    if ($whdPrep.Why -and $whdPrep.Alert) {
        $alert = $true
        $rep.Add(("!! The guard's own folder {0} is not used: {1}." -f $whdGdPath, $whdPrep.Why))
        $rep.Add(("   Its files are kept in {0} instead. Refresh the guard (GU in any menu); if this line stays, look at that folder." -f $dataDir))
    } elseif ($whdPrep.Why) {
        $rep.Add(("Files   : {0} for this check ({1} is not used: {2})." -f $dataDir, $whdGdPath, $whdPrep.Why))
    }
    $rep.Add('')
    Write-WHDLog 'UPDATE GUARD: checking (read-only)...' 'ACT'

    # 1) never check in the middle of servicing
    $busy = @(Get-WHDServicingBusy)
    if ($Now -and $busy.Count) {
        Write-WHDLog ("UPDATE GUARD: not checking now - {0}." -f ($busy -join '; ')) 'WARN'
        Write-WHDLog 'Try GR again when Windows finishes (or restart if one is pending). The sign-in check waits for this automatically.' 'INFO'
        return [pscustomobject]@{ Result = 'BUSY'; Alert = $false; Report = '' }
    }
    $waited = 0
    while ($busy.Count -and -not ($busy -match 'restart') -and $waited -lt 30) {
        Write-WHDLog ("waiting 5 min: {0}" -f ($busy -join '; ')) 'INFO'
        Start-Sleep -Seconds 300; $waited += 5
        $busy = @(Get-WHDServicingBusy)
    }
    if ($busy.Count) {
        $rep.Add('RESULT  : SKIPPED - ' + ($busy -join '; ') + '.')
        $rep.Add('          The guard will check again at your next sign-in (after the restart).')
        if (-not (Save-WHDGuardReport -Path $report -Lines $rep.ToArray())) { $report = '' }
        $ns = [ordered]@{ Fingerprint = $(if ($state) { $state.Fingerprint } else { '' }); Build = $(if ($state) { $state.Build } else { '' })
                          LastCheck = (Get-Date -Format 'yyyy-MM-dd HH:mm'); LastResult = 'skipped (servicing)'; LastReport = $report }
        Save-WHDGuardState -State $ns -Dir $dataDir
        Write-WHDLog ("UPDATE GUARD: skipped - {0}" -f ($busy -join '; ')) 'WARN'
        return [pscustomobject]@{ Result = 'SKIPPED'; Alert = $false; Report = $report }
    }

    # 2) Verify every journaled WHD change (latest state per item)
    $rep.Add('-- 1. WHD CHANGES STILL IN PLACE? (Verify ALL) -----------------------')
    $res = @()
    try { $res = @(Invoke-WHDVerify -All -Quiet) } catch { $rep.Add("  verify failed: $($_.Exception.Message)") }
    $bad = @($res | Where-Object { $_.Result -in @('CHANGED','RETURNED') })
    $rep.Add(("  {0} checked: {1} pass, {2} changed/returned" -f $res.Count, @($res | Where-Object { $_.Result -eq 'PASS' }).Count, $bad.Count))
    foreach ($b in $bad) { $rep.Add(("  !! {0,-8} {1}   now: {2}" -f $b.Result, $b.Target, $b.Now)) }
    # No journal at all under this data folder (e.g. the WHD folder was moved): "0 changed" would be a false OK.
    $jrnDirs = @(Get-ChildItem -LiteralPath (Get-WHDRestoreRoot) -Directory -EA SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'journal.jsonl') })
    if (-not $jrnDirs.Count) { $alert = $true; $rep.Add(("  !! No WHD change history found at {0} - if the WHD folder was moved, start WHD from its new location, switch to EXECUTE (main menu 8), then press GU." -f $script:WHDRoot)) }
    if ($bad.Count) { $alert = $true; $rep.Add('  -> Fix: WHD menu (re-apply the item) or Undo center; Verify (V) shows the same list.') }
    if (@($bad | Where-Object { $_.Result -eq 'CHANGED' }).Count) { $rep.Add('  -> Settings that changed back: WHD main menu V, answer y to re-apply them (GUI: Inventory/Undo > "Re-apply settings that changed back").') }
    if (@($bad | Where-Object { $_.Result -eq 'RETURNED' }).Count) { $rep.Add('  -> Apps that came back: WHD main menu V, answer y to re-remove them (GUI: Inventory/Undo > "Re-remove apps that came back").') }
    $rep.Add('')

    # 2b) Time: refused time jumps since the last check (Time-Service event 34).
    #     Alert (open the report) when there are any.
    if (Get-Command Get-WHDTimeJumpEvents -EA SilentlyContinue) {
        $rep.Add('-- 1b. TIME: REFUSED CLOCK JUMPS (1 h limit) -------------------------')
        $since = (Get-Date).AddDays(-7)
        if ($state -and $state.LastCheck) { try { $since = [datetime]::ParseExact("$($state.LastCheck)", 'yyyy-MM-dd HH:mm', $null) } catch {} }
        $tev = @(Get-WHDTimeJumpEvents -Since $since)
        if ($tev.Count) {
            $alert = $true
            $rep.Add(("  !! Windows refused {0} time correction(s) bigger than the limit since {1:yyyy-MM-dd HH:mm}:" -f $tev.Count, $since))
            foreach ($e in $tev) { $rep.Add(("     {0:yyyy-MM-dd HH:mm}  {1}" -f $e.Time, $e.Message)) }
            $rep.Add('  -> Check the clock. If it is really wrong: Settings > Time & language > Date & time - turn off ''Set time automatically'', set it by hand, turn it back on, then Sync now.')
            $rep.Add('     If the clock is right, something sent a wrong time - the limit blocked it.')
        } else { $rep.Add(("  none since {0:yyyy-MM-dd HH:mm}" -f $since)) }
        $rep.Add('')
    }

    # 2c) Update gate (info only - opening it is your choice, never an alert)
    if (Get-Command Get-WHDGateState -EA SilentlyContinue) {
        try { $gs = Get-WHDGateState; $rep.Add(("-- UPDATE GATE: {0}   (outbound {1})" -f $gs.Text, $gs.Outbound)); $rep.Add('') } catch {}
    }

    # 3) Inventory compare - only when Windows itself changed
    $rep.Add('-- 2. APPS / FEATURES AFTER WINDOWS UPDATES (inventory compare) ------')
    $fp = Get-WHDUpdateFingerprint
    $prevFp = if ($state) { "$($state.Fingerprint)" } else { '' }
    $newFp  = $prevFp
    $scanNote = ''
    if ($prevFp -and $prevFp -eq $fp.Text) {
        $rep.Add(("  No Windows update since the last check (build {0}) - scan not needed." -f $fp.Build))
    } else {
        if (-not $prevFp) { $rep.Add(("  First guard check - taking a baseline scan (build {0})." -f $fp.Build)) }
        else {
            $oldHf = @("$($state.Fingerprint)".Split('|')[1] -split ',' | Where-Object { $_ })
            $added = @($fp.HotFixes | Where-Object { $oldHf -notcontains $_ })
            $rep.Add(("  Windows changed: build {0} -> {1}{2}" -f $state.Build, $fp.Build, $(if ($added.Count) { "; new updates: " + ($added -join ', ') } else { '' })))
        }
        $invRoot = $whdGuardInv      # v1.5: under guard-data when that is used; the journal is still read from the WHD folder
        $invPs1  = Join-Path (Get-WHDGuardCodeRoot) 'Inventory.ps1'
        $before  = @(Get-ChildItem -LiteralPath $invRoot -Directory -EA SilentlyContinue | ForEach-Object { $_.Name })
        $psExe   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Write-WHDLog 'UPDATE GUARD: running inventory scan (1-3 min)...' 'INFO'
        $run = Invoke-WHDNative -Exe $psExe -ArgList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File', $invPs1, '-NoElevate', '-OutputRoot', $invRoot, '-ProjectRoot', $script:WHDRoot)
        $newDirs = @(Get-ChildItem -LiteralPath $invRoot -Directory -EA SilentlyContinue | Where-Object { $before -notcontains $_.Name } | Sort-Object Name)
        $scan = if ($newDirs.Count) { $newDirs[-1] } else { $null }
        if (-not $scan -or -not (Test-Path -LiteralPath (Join-Path $scan.FullName 'REPORT.txt'))) {
            $rep.Add(("  !! inventory scan did not finish (exit {0}) - will retry next sign-in." -f $run.Code))
            $scanNote = 'scan failed'
        } else {
            try { Set-Content -LiteralPath (Join-Path $scan.FullName $script:WHDGuardMarker) -Value ("made by update guard {0}" -f $stamp) -Encoding ASCII -EA Stop }
            catch { Write-WHDLog ("UPDATE GUARD: could not mark the scan folder: {0}" -f $_.Exception.Message) 'WARN' }
            $newFp = $fp.Text
            if ($whdMoved) { $rep.Add(("  Scan: {0}" -f $scan.FullName)) } else { $rep.Add(("  Scan: inventory\{0}" -f $scan.Name)) }
            $diffCsv = @(Get-ChildItem -LiteralPath $scan.FullName -Filter 'DIFF-vs-*.csv' -File -EA SilentlyContinue)
            $diffTxt = @(Get-ChildItem -LiteralPath $scan.FullName -Filter 'DIFF-vs-*.txt' -File -EA SilentlyContinue)
            if ($diffCsv.Count) {
                $rows = @(Import-Csv -LiteralPath $diffCsv[0].FullName -EA SilentlyContinue)
                $back = @($rows | Where-Object { "$($_.Note)" -like 'CAME BACK*' })
                if ($back.Count) {
                    $alert = $true
                    $rep.Add(("  !! {0} app(s) WHD removed CAME BACK:" -f $back.Count))
                    foreach ($b in $back) { $rep.Add(("     {0}   ({1})" -f $b.Item, $b.Note)) }
                }
                $rep.Add(("  Compared with the previous scan: {0} new, {1} gone, {2} changed (details below; info only)" -f
                    @($rows | Where-Object { $_.Change -eq 'NEW' }).Count, @($rows | Where-Object { $_.Change -eq 'GONE' }).Count, @($rows | Where-Object { $_.Change -eq 'CHANGED' }).Count))
            } else { $rep.Add('  (no earlier scan to compare with - this scan is the baseline)') }
            if ($diffTxt.Count) {
                $rep.Add('')
                foreach ($l in @(Get-Content -LiteralPath $diffTxt[0].FullName -Encoding UTF8 -EA SilentlyContinue | Select-Object -First 400)) { $rep.Add('  ' + $l) }
            }
            $gone = @(Remove-WHDOldGuardScans -InvRoot $invRoot)
            if ($gone.Count) { $rep.Add(''); $rep.Add(("  Removed {0} older guard scan(s) (keeping the last {1}): {2}" -f $gone.Count, $script:WHDGuardKeep, ($gone -join ', '))) }
        }
    }
    $rep.Add('')
    $result = if ($alert) { 'ALERT' } elseif ($scanNote) { 'OK (scan failed)' } else { 'OK' }
    $rep.Insert(2, ('RESULT  : ' + $(if ($alert) { 'ALERT - see the !! lines below' } else { 'OK - nothing WHD set or removed has changed' })))
    # v1.5: a report or a status that cannot be saved must not end the check, and is itself something to
    # look at - the result is then ALERT, never a plain OK. ($rep[2] is the RESULT line inserted above.)
    $whdGuHint = ''
    if (-not $whdMoved) { $whdGuHint = (' Once the guard is installed or refreshed (GU in any menu), it keeps its files in {0}, outside the protected folders.' -f $whdGdPath) }
    if (-not (Save-WHDGuardReport -Path $report -Lines $rep.ToArray())) {
        $rep.Add(('!! This report could not be saved to {0} (see the log).{1}' -f $dataDir, $whdGuHint))
        $rep[2] = 'RESULT  : ALERT - see the !! lines below'
        $alert = $true; $result = 'ALERT'; $report = ''
    }
    Save-WHDGuardState -Dir $dataDir -State ([ordered]@{ Fingerprint = $newFp; Build = $(if ($newFp) { $newFp.Split('|')[0] } else { '' })
                                    LastCheck = (Get-Date -Format 'yyyy-MM-dd HH:mm'); LastResult = $result; LastReport = $report })
    if ("$($script:WHDGuardStateError)") {
        # the status was NOT saved: the next check cannot know about this one
        $rep.Add(('!! The guard status could not be saved to {0}: {1}{2}' -f $dataDir, $script:WHDGuardStateError, $(if ($report) { $whdGuHint } else { '' })))
        $rep[2] = 'RESULT  : ALERT - see the !! lines below'
        $alert = $true; $result = 'ALERT'
        if ($report) { try { $rep.ToArray() | Set-Content -LiteralPath $report -Encoding UTF8 -EA Stop } catch { } }   # the saved report gets the new lines too
    }
    Write-WHDLog ("UPDATE GUARD: {0} - report: {1}" -f $result, $(if ($report) { $report } else { '(not saved - its text is in the lines above)' })) $(if ($alert) { 'WARN' } else { 'OK' })
    # v1.5: on an alert, write a Windows event log entry and show a small always-on-top window. Neither changes
    # a setting. The status was saved above, BEFORE the window opens (the window waits until it is closed).
    $whdAlertLines = @($rep | Where-Object { "$_" -like 'RESULT*' -or "$_" -match '^\s*!!' })
    if ($alert) {
        # Application log, source WinHardenDebloat - written only when the source was registered with the guard install.
        # When the report file could not be saved, the entry carries the whole report text instead of the !! lines.
        try {
            if (Get-Command Write-WHDEventLog -EA SilentlyContinue) {
                $whdEvBody = @($whdAlertLines)
                if (-not $report) { $whdEvBody = @($rep.ToArray()) }
                [void](Write-WHDEventLog -Type 'Warning' -EventId 1001 -Message ("WinHardenDebloat update guard: ALERT`r`n{0}`r`nReport: {1}" -f ($whdEvBody -join "`r`n"), $(if ($report) { $report } else { '(could not be saved - its text is above)' })))
            }
        } catch { }
    }
    if ($alert -and -not $NoPopup) {
        # The report opens from the window's "Open the report" button.
        $whdShown = $false
        try {
            if (Get-Command Show-WHDAlertWindow -EA SilentlyContinue) {
                $whdTail = 'Nothing was changed. "Open the report" shows the details and what to do.'
                if (-not $report) { $whdTail = 'Nothing was changed. The report could not be saved. To read it: start WHD, Security+ > GR (it is then shown on screen), or see the Windows event log (Application, source WinHardenDebloat).' }
                $whdShown = (@(Show-WHDAlertWindow -Title 'WinHardenDebloat - update guard' -Heading 'The update guard found something to look at' `
                        -Lines (@($whdAlertLines) + @('', $whdTail)) -ReportPath $report)[-1] -eq $true)
            }
        } catch { $whdShown = $false }
        # The window could not be shown: open the report directly, as before v1.5
        # (via the desktop shell so Notepad runs as a normal, non-admin window).
        if (-not $whdShown -and $report) { try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $report) } catch {} }
    }
    [pscustomobject]@{ Result = $result; Alert = $alert; Report = $report }
}

# ---- install / remove (journal kind 'schtask', auto undo = remove) ----------
function _WHDIcacls {
    param([string[]]$IcArgs)
    $r = Invoke-WHDNative -Exe 'icacls.exe' -ArgList $IcArgs
    if ($r.Code -ne 0) { throw ("icacls {0} failed ({1}): {2}" -f ($IcArgs -join ' '), $r.Code, (($r.Out | Where-Object { $_ }) -join ' ')) }
}
# Copy the scripts to ProgramData and lock them: Administrators + SYSTEM full,
# Users read/execute, owner = Administrators (well-known SIDs, any language).
function _WHDGuardCopy {
    param([string]$Src, [string]$Base, [string]$Dst)
    # A pre-made junction/symlink here would send the scripts (and the permissions) somewhere else.
    foreach ($d in @($Base, $Dst, (Join-Path $Dst 'modules'))) {
        if ((Test-Path -LiteralPath $d) -and ((Get-Item -LiteralPath $d -Force -EA Stop).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'the guard folder is a link (reparse point) - refusing to use it' }
    }
    # v1.5: the same for the guard's own data folder (guard-data) and the folders inside it
    # (this look also sees a link whose target is gone).
    if (_WHDGuardFirstLink -Paths (@($Base, $Dst, (Join-Path $Dst 'modules')) + @(_WHDGuardDataFolders -Base $Base))) { throw 'the guard folder is a link (reparse point) - refusing to use it' }
    # v1.5: a guard-data folder that is already there must have been made by WHD (owner Administrators / SYSTEM,
    # nobody else may write). The commands below would hand a folder made by someone else the same owner and
    # permissions - and its contents would then look like the guard's own. Checked BEFORE they run.
    $whdGdDir = Join-Path $Base $script:WHDGuardDataName
    $whdGdHad = Test-Path -LiteralPath $whdGdDir
    if ($whdGdHad) {
        $whdGdProb = ''
        if (-not (Test-Path -LiteralPath $whdGdDir -PathType Container)) { $whdGdProb = 'it is not a folder' } else { $whdGdProb = Get-WHDGuardFolderProblem -Path $whdGdDir }
        if ($whdGdProb) { throw ("the folder {0} was not made by WHD ({1}) - refusing to use it. Look at it, then delete or rename it and press GU again" -f $whdGdDir, $whdGdProb) }
    }
    foreach ($d in @($Base, $Dst, (Join-Path $Dst 'modules'))) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
    _WHDIcacls @($Base, '/setowner', '*S-1-5-32-544', '/T', '/C', '/Q')
    _WHDIcacls @($Base, '/reset', '/Q')
    _WHDIcacls @($Base, '/inheritance:r', '/grant:r', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX', '/Q')
    _WHDIcacls @((Join-Path $Base '*'), '/reset', '/T', '/C', '/Q')
    # v1.5: the base folder is locked now (only Administrators / SYSTEM can add anything) - make guard-data in it.
    # It was not there before the lock, so if it is there now someone slipped it in meanwhile: refuse.
    if (-not $whdGdHad -and (Test-Path -LiteralPath $whdGdDir)) { throw ("the folder {0} appeared while the guard folder was being locked - refusing to use it. Look at it, then delete or rename it and press GU again" -f $whdGdDir) }
    _WHDGuardDataMake -Base $Base
    Get-ChildItem -LiteralPath $Dst -Recurse -File -Force -EA SilentlyContinue | Remove-Item -Force -EA Stop
    Copy-Item -LiteralPath (Join-Path $Src 'WHD.ps1')       -Destination $Dst -Force
    Copy-Item -LiteralPath (Join-Path $Src 'Inventory.ps1') -Destination $Dst -Force
    Copy-Item -Path (Join-Path $Src 'modules\*.ps1') -Destination (Join-Path $Dst 'modules') -Force
}
function _WHDGuardRegister {
    param([string]$Dst, [string]$DataRoot)
    $user  = "$env:USERDOMAIN\$env:USERNAME"
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $taskArgs = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Guard -NoElevate -DataRoot "{1}"' -f (Join-Path $Dst 'WHD.ps1'), $DataRoot)
    $act  = New-ScheduledTaskAction -Execute $psExe -Argument $taskArgs -WorkingDirectory $Dst
    $trig = New-ScheduledTaskTrigger -AtLogOn -User $user
    $trig.Delay = $script:WHDGuardDelay
    $prin = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $set  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskPath $script:WHDGuardTaskPath -TaskName $script:WHDGuardTaskName -Action $act -Trigger $trig -Principal $prin -Settings $set `
        -Description 'WinHardenDebloat update guard (alert only): 10 min after sign-in checks that WHD changes are still in place; opens a report only if something changed.' -Force | Out-Null
}
function _WHDGuardRemove {
    if (Get-WHDGuardTask) { Unregister-ScheduledTask -TaskPath $script:WHDGuardTaskPath -TaskName $script:WHDGuardTaskName -Confirm:$false -EA Stop }
    if (Test-Path -LiteralPath $script:WHDGuardDir) { Remove-Item -LiteralPath $script:WHDGuardDir -Recurse -Force -EA Stop }
    # v1.5: the event log source that was registered with the guard goes with it (after task + copy are gone)
    try { if (Get-Command Unregister-WHDEventSource -EA SilentlyContinue) { Unregister-WHDEventSource } } catch { }
    if ((Test-Path -LiteralPath $script:WHDGuardBase) -and -not @(Get-ChildItem -LiteralPath $script:WHDGuardBase -Force -EA SilentlyContinue).Count) {
        Remove-Item -LiteralPath $script:WHDGuardBase -Force -EA SilentlyContinue
    }
}
function Install-WHDUpdateGuard {
    Write-WHDLog 'UPDATE GUARD: install / refresh (alert only)' 'ACT'
    $gSrc = Get-WHDGuardCodeRoot; $gDst = $script:WHDGuardDir; $gBase = $script:WHDGuardBase; $gData = $script:WHDRoot
    if ($gSrc -eq $gDst) { Write-WHDLog 'Running from the protected guard copy - install from the project folder instead.' 'ERR'; return }
    if (-not (Test-WHDAdmin)) { Write-WHDLog 'Needs an elevated (admin) session.' 'ERR'; return }
    $had = [bool](Get-WHDGuardTask)
    Write-WHDRisk 'reversible' ("Copies the scripts to {0} (admins/SYSTEM can change them, users read only) and adds scheduled task {1}{2}: 10 min after YOU sign in, run as you with highest privileges, only while signed in. It only reads and reports - never changes anything. Its reports, status and scans are then kept in {3} (same permissions; outside the WHD folder, so folder protection does not block them); older ones are copied there once, nothing is removed. Also registers the Windows event log source 'WinHardenDebloat' (Application log) for guard alerts. Re-run this after updating the tool to refresh the protected copy. Undo removes task + copy + event log source; the guard's reports and scans are kept." -f $gDst, $script:WHDGuardTaskPath, $script:WHDGuardTaskName, (Join-Path $gBase $script:WHDGuardDataName))
    if (-not (Confirm-WHDProceed $(if ($had) { 'refresh the update guard (copy + task)' } else { 'install the update guard' }))) { Write-WHDLog 'skipped.' 'WARN'; return }
    $jr = @{ Kind = 'schtask'; TaskPath = $script:WHDGuardTaskPath; TaskName = $script:WHDGuardTaskName; GuardDir = $gDst; Existed = $had }
    Invoke-WHDChange -Description ("update guard: protected copy in {0} + task {1}{2} (sign-in +10 min)" -f $gDst, $script:WHDGuardTaskPath, $script:WHDGuardTaskName) -Force -Journal $jr -Action {
        _WHDGuardCopy -Src $gSrc -Base $gBase -Dst $gDst
        _WHDGuardRegister -Dst $gDst -DataRoot $gData
        # v1.5: register the event log source the guard writes its alerts to (removed again with the guard)
        try { if (Get-Command Register-WHDEventSource -EA SilentlyContinue) { Register-WHDEventSource } }
        catch { Write-WHDLog ("event log source could not be registered (alerts still show the window and the report): {0}" -f $_.Exception.Message) 'WARN' }
        if (-not (Get-WHDGuardTask)) { throw 'read-back: scheduled task not found after registering' }
        $h1 = (Get-FileHash -LiteralPath (Join-Path $gSrc 'modules\Common.ps1')).Hash
        $h2 = (Get-FileHash -LiteralPath (Join-Path $gDst 'modules\Common.ps1')).Hash
        if ($h1 -ne $h2) { throw 'read-back: protected copy does not match the project files' }
    }
}
# ---- v1.3 (2026-09-28): keep the guard's protected copy current without menu hopping ----
# The copy only needs refreshing when WHD's own script files change (settings changes are
# read from the journals). Compare every script by hash.
function Get-WHDGuardStaleFiles {
    $src = Get-WHDGuardCodeRoot; $dst = $script:WHDGuardDir
    if (-not (Test-Path -LiteralPath $dst)) { return @() }
    $rel = @('WHD.ps1', 'Inventory.ps1') + @(Get-ChildItem -LiteralPath (Join-Path $src 'modules') -Filter *.ps1 -EA SilentlyContinue | ForEach-Object { "modules\$($_.Name)" })
    @(foreach ($r in $rel) {
        $a = Join-Path $src $r; $b = Join-Path $dst $r
        if (-not (Test-Path -LiteralPath $b)) { $r; continue }
        if ((Get-FileHash -LiteralPath $a).Hash -ne (Get-FileHash -LiteralPath $b).Hash) { $r }
    })
}
# Called when WHD / the GUI starts: refreshes the protected copy by itself if it is out of date.
# Not journaled - the guard's task + copy were journaled when it was installed; this only re-copies.
function Update-WHDGuardIfStale {
    try {
        if ((Get-WHDGuardCodeRoot) -eq $script:WHDGuardDir) { return }
        if (-not (Test-WHDAdmin) -or -not (Get-WHDGuardTask)) { return }
        $stale = @(Get-WHDGuardStaleFiles)
        if (-not $stale.Count) { return }
        _WHDGuardCopy -Src (Get-WHDGuardCodeRoot) -Base $script:WHDGuardBase -Dst $script:WHDGuardDir
        Write-WHDLog ("Update guard: protected copy refreshed automatically ({0} changed file(s): {1})" -f $stale.Count, ($stale -join ', ')) 'OK'
        # v1.5: this refresh only re-copies; the event log source for alerts is registered by GU (asks first, journaled)
        if ((Get-Command Test-WHDEventSource -EA SilentlyContinue) -and -not (Test-WHDEventSource)) {
            Write-WHDLog "Update guard: for alerts in the Windows event log too, press GU once (it registers the event log source 'WinHardenDebloat')." 'INFO'
        }
    } catch { Write-WHDLog ("Update guard auto-refresh failed: {0} - use GU in any menu." -f $_.Exception.Message) 'WARN' }
}
# 'GU' in ANY menu = refresh the update guard (copy + task). Returns $true when it handled the key.
function Invoke-WHDGuardHotkey {
    param([string]$Key)
    if ("$Key" -notmatch '^[Gg][Uu]$') { return $false }
    Install-WHDUpdateGuard
    return $true
}
function Uninstall-WHDUpdateGuard {
    Write-WHDLog 'UPDATE GUARD: remove' 'ACT'
    if (-not (Get-WHDGuardTask) -and -not (Test-Path -LiteralPath $script:WHDGuardDir)) { Write-WHDLog 'Not installed - nothing to remove.' 'OK'; return }
    Write-WHDRisk 'reversible' ("Removes the scheduled task, the protected copy and the Windows event log source 'WinHardenDebloat'. The guard's reports and scans are kept (in the project folder and in {0})." -f (Join-Path $script:WHDGuardBase $script:WHDGuardDataName))
    if (-not (Confirm-WHDProceed 'remove the update guard')) { Write-WHDLog 'skipped.' 'WARN'; return }
    $done0 = [int]$script:WHDCounts['done']
    Invoke-WHDChange -Description 'remove update guard (task + protected copy + event log source)' -Force -Action { _WHDGuardRemove } | Out-Null
    if ($script:WHDExecute -and [int]$script:WHDCounts['done'] -gt $done0) {
        # the install entries are no longer expected to verify
        foreach ($s in @(Get-WHDUndoSessions)) {
            foreach ($e in @(Get-WHDJournal -SessionPath $s.Path | Where-Object { "$($_.Kind)" -eq 'schtask' -and -not $_.Undone })) { _WHDMarkUndone $e }
        }
    }
}
