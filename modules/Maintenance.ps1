<#
================================================================================
 WHD Next  -  modules\Maintenance.ps1
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
        & dism.exe @DismArgs 2>&1 | ForEach-Object { Write-Host ("    {0}" -f $_) }
        if ($LASTEXITCODE -ne 0) { throw "DISM exited with code $LASTEXITCODE" }
    } catch {
        Write-WHDLog ("DISM error: {0}" -f $_.Exception.Message) 'ERR'
    }
}

function Invoke-WHDComponentAnalyze {
    # Read-only: safe to run in any mode. Reports the ACTUAL reclaimable size
    # (not the inflated Explorer number) and whether cleanup is recommended.
    Write-WHDLog 'COMPONENT STORE ANALYSIS (read-only)' 'ACT'
    _WHDRunDism -DismArgs @('/Online','/Cleanup-Image','/AnalyzeComponentStore')
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
    Invoke-WHDChange -Description ("DISM {0}" -f $label) -Force -Action {
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
# Phase 9 - A2 UPDATE GUARD (alert only; never changes anything)
# ------------------------------------------------------------------------------
# User choices (2026-09-24):
#   * runs at sign-in, 10 minutes after logon (scheduled task, user account,
#     highest privileges, only while signed in)
#   * checks: Verify ALL (every journaled WHD change) + inventory compare
#   * inventory scan only when Windows changed (build/UBR or installed-update
#     list); Defender signature updates are not in that list
#   * alert = report file in restore\update-guard\, opened in Notepad ONLY when
#     a WHD change was undone/returned or a removed app came back
#   * keeps the last 5 guard-made inventory scans (user scans never touched)
#   * scripts run from a PROTECTED copy in ProgramData (admins/SYSTEM write,
#     users read) so a user-level program cannot tamper with them to gain admin
# ==============================================================================
$script:WHDGuardTaskPath = '\WinHardenDebloatNext\'
$script:WHDGuardTaskName = 'UpdateGuard'
$script:WHDGuardBase     = Join-Path $env:ProgramData 'WinHardenDebloatNext'
$script:WHDGuardDir      = Join-Path $script:WHDGuardBase 'guard'
$script:WHDGuardKeep     = 5
$script:WHDGuardDelay    = 'PT10M'
$script:WHDGuardMarker   = '.whd-guard'

# ---- build step 11b (user decisions 2026-10-03, guard questions A and B) ------
# A: the guard keeps its OWN files (reports, status, its scans, the launcher log of its runs) under
#    ProgramData, never in a protected folder:
#      * WHD Next runs from a folder under C:\ProgramData\WinHardenDebloatNext (the unlocked copy "app")
#        -> the guard's files stay in that folder, exactly as before;
#      * WHD Next runs from anywhere else (Documents, a USB stick ...) -> C:\ProgramData\WinHardenDebloatNext\guard-data
#        with the same layout (restore\update-guard, inventory, logs).
#    The guard still READS the change journal from the WHD folder. The files the menus write
#    (update-gate.json, blocklist.json, blocked-programs.json) stay in the WHD folder.
$script:WHDGuardDataName = 'guard-data'
function Test-WHDGuardPathUnder {
    # Is $Path the folder $Folder or inside it? (letter case and / vs \ do not matter)
    param([string]$Path, [string]$Folder)
    if (-not $Path -or -not $Folder) { return $false }
    $whdP = ($Path -replace '/', '\').TrimEnd('\') + '\'
    $whdF = ($Folder -replace '/', '\').TrimEnd('\') + '\'
    return $whdP.StartsWith($whdF, [System.StringComparison]::OrdinalIgnoreCase)
}
function Get-WHDGuardDataRoot {
    if (Test-WHDGuardPathUnder -Path $script:WHDRoot -Folder $script:WHDGuardBase) { return $script:WHDRoot }
    return (Join-Path $script:WHDGuardBase $script:WHDGuardDataName)
}
function Test-WHDGuardDataMoved { return (-not (Test-WHDGuardPathUnder -Path $script:WHDRoot -Folder $script:WHDGuardBase)) }
function Get-WHDGuardDataDir    { Join-Path (Get-WHDGuardDataRoot) 'restore\update-guard' }
function Get-WHDGuardOldDataDir { Join-Path $script:WHDRoot 'restore\update-guard' }      # where the guard's files were before step 11b
function Get-WHDGuardInventoryRoot { Join-Path (Get-WHDGuardDataRoot) 'inventory' }

# A2 (user: "B" = copy them over once): the first time the guard uses guard-data, its older reports, its
# status and its own scans are COPIED there from the WHD folder. Nothing is removed from the WHD folder.
# Only when the old status belongs to this PC; files that already exist in the new place are kept.
# A note file (copied-from.txt) marks that this was done, so it happens once. Returns $null when there was
# nothing to do, otherwise what was copied.
function Copy-WHDGuardDataOnce {
    if (-not (Test-WHDGuardDataMoved)) { return $null }
    $newDir = Get-WHDGuardDataDir
    $mark   = Join-Path $newDir 'copied-from.txt'
    if (Test-Path -LiteralPath $mark) { return $null }
    $oldDir = Get-WHDGuardOldDataDir
    $r = [ordered]@{ From = "$($script:WHDRoot)"; Reports = 0; Scans = 0; State = $false; Failed = 0; Note = '' }
    try {
        if (-not (Test-Path -LiteralPath $newDir)) { New-Item -ItemType Directory -Path $newDir -Force -EA Stop | Out-Null }
        $oldStateFile = Join-Path $oldDir 'state.json'
        $oldState = $null
        if (Test-Path -LiteralPath $oldStateFile) { try { $oldState = Get-Content -LiteralPath $oldStateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $oldState = $null } }
        if (-not $oldState) { $r.Note = 'nothing copied: the WHD folder has no guard status' }
        elseif ((Get-Command Test-WHDGuardStateIsThisPC -EA SilentlyContinue) -and -not (Test-WHDGuardStateIsThisPC -State $oldState)) { $r.Note = 'nothing copied: the guard status in the WHD folder belongs to another PC or an earlier Windows install' }
        else {
            # reports (+ the error notes, if any)
            foreach ($f in @(Get-ChildItem -LiteralPath $oldDir -File -EA SilentlyContinue | Where-Object { $_.Name -like 'guard_*.txt' -or $_.Name -eq 'guard-errors.txt' })) {
                $whdT = Join-Path $newDir $f.Name
                if (Test-Path -LiteralPath $whdT) { continue }
                try { Copy-Item -LiteralPath $f.FullName -Destination $whdT -EA Stop; if ($f.Name -like 'guard_*.txt') { $r.Reports++ } } catch { $r.Failed++ }
            }
            # the guard's own scans (folders carrying the marker); the user's scans stay where they are
            $oldInv = Join-Path $script:WHDRoot 'inventory'; $newInv = Get-WHDGuardInventoryRoot
            foreach ($d in @(Get-ChildItem -LiteralPath $oldInv -Directory -EA SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName $script:WHDGuardMarker) })) {
                $whdTd = Join-Path $newInv $d.Name
                if (Test-Path -LiteralPath $whdTd) { continue }
                try {
                    New-Item -ItemType Directory -Path $whdTd -Force -EA Stop | Out-Null
                    foreach ($sf in @(Get-ChildItem -LiteralPath $d.FullName -File -Force -EA SilentlyContinue)) { Copy-Item -LiteralPath $sf.FullName -Destination (Join-Path $whdTd $sf.Name) -EA Stop }
                    $r.Scans++
                } catch { $r.Failed++ }
            }
            # the status, with "last report" pointing at the copied report
            $newStateFile = Join-Path $newDir 'state.json'
            if (-not (Test-Path -LiteralPath $newStateFile)) {
                try {
                    $whdNs = [ordered]@{}
                    foreach ($pr in @($oldState.PSObject.Properties)) { $whdNs[$pr.Name] = $pr.Value }
                    if ("$($whdNs['LastReport'])") {
                        $whdLeaf = Split-Path -Leaf ("$($whdNs['LastReport'])" -replace '\\', '/')
                        if ($whdLeaf -and (Test-Path -LiteralPath (Join-Path $newDir $whdLeaf))) { $whdNs['LastReport'] = (Join-Path $newDir $whdLeaf) }
                    }
                    ($whdNs | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $newStateFile -Encoding UTF8 -EA Stop
                    $r.State = $true
                } catch { $r.Failed++ }
            }
            $r.Note = ('copied {0} report(s), {1} guard scan(s), status: {2}' -f $r.Reports, $r.Scans, $(if ($r.State) { 'yes' } else { 'no' }))
        }
        if ($r.Failed -eq 0) {
            @('WHD Next - update guard data',
              ('This folder holds the update guard''s reports, status and scans since {0}.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm')),
              ('WHD folder at that time : {0}' -f $r.From),
              ('Taken over from there   : {0}' -f $r.Note),
              'Nothing was removed from the WHD folder.') | Set-Content -LiteralPath $mark -Encoding ASCII -EA Stop
        } else { $r.Note = $r.Note + ('; {0} file(s) could not be copied - tried again at the next check' -f $r.Failed) }
    } catch { $r.Failed++; $r.Note = ('could not prepare {0}: {1}' -f $newDir, $_.Exception.Message) }
    return [pscustomobject]$r
}

# B: WHD Classic's update guard task on the same PC. Read-only status + a journaled switch-off.
#    Nothing of WHD Classic is changed or removed: the task is only disabled (journal kind 'task', so the
#    Undo center switches it on again, and Verify / the guard report it when it comes back on).
$script:WHDClassicGuardTaskPath = '\WinHardenDebloat\'
$script:WHDClassicGuardTaskName = 'UpdateGuard'
function Get-WHDClassicGuardTask {
    @(Get-ScheduledTask -TaskPath $script:WHDClassicGuardTaskPath -EA SilentlyContinue | Where-Object { $_.TaskName -eq $script:WHDClassicGuardTaskName })[0]
}
function Get-WHDClassicGuardStatus {
    $t = Get-WHDClassicGuardTask
    $o = [ordered]@{ Found = [bool]$t; Enabled = $false; State = ''; Id = ('{0}{1}' -f $script:WHDClassicGuardTaskPath, $script:WHDClassicGuardTaskName); Text = 'not installed' }
    if ($t) {
        $o.State = "$($t.State)"
        $whdOn = ("$($t.State)" -ne 'Disabled')
        try { if ($null -ne $t.Settings -and $null -ne $t.Settings.Enabled) { $whdOn = [bool]$t.Settings.Enabled } } catch { }
        $o.Enabled = $whdOn
        if ($whdOn) { $o.Text = ('ON ({0}) - it also runs after every sign-in' -f $o.State) } else { $o.Text = 'off' }
    }
    [pscustomobject]$o
}
function Disable-WHDClassicGuardTask {
    Write-WHDLog 'WHD CLASSIC''S UPDATE GUARD TASK: switch off' 'ACT'
    $cg = Get-WHDClassicGuardStatus
    if (-not $cg.Found)   { Write-WHDLog ('WHD Classic''s guard task ({0}) is not on this PC - nothing to do.' -f $cg.Id) 'OK'; return }
    if (-not $cg.Enabled) { Write-WHDLog ('WHD Classic''s guard task ({0}) is already switched off.' -f $cg.Id) 'OK'; return }
    Write-WHDRisk 'reversible' ("Switches off the scheduled task {0} (WHD Classic's update guard). Nothing of WHD Classic is removed or changed - its files, its reports and the task itself stay; the task is only disabled. Why: with both guards on, two checks run after every sign-in, and Classic's check runs on Windows PowerShell 5.1, which folder protection blocks when it writes its report into Classic's folder (the 'folder block' notices). The Undo center switches the task on again. Afterwards Verify and WHD Next's guard report it when the task comes back on." -f $cg.Id)
    if (-not (Confirm-WHDProceed 'switch off WHD Classic''s update guard task')) { Write-WHDLog 'skipped.' 'WARN'; return }
    $cgPath = $script:WHDClassicGuardTaskPath; $cgName = $script:WHDClassicGuardTaskName
    $jr = @{ Kind = 'task'; TaskPath = $cgPath; TaskName = $cgName; OldEnabled = $true; NewEnabled = $false }
    Invoke-WHDChange -Description ("stop + disable scheduled task {0}{1} (WHD Classic's update guard)" -f $cgPath, $cgName) -Force -Journal $jr -Action {
        Stop-ScheduledTask -TaskPath $cgPath -TaskName $cgName -EA SilentlyContinue
        Disable-ScheduledTask -TaskPath $cgPath -TaskName $cgName -EA Stop | Out-Null
    } | Out-Null
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
        # Step 11b: until the first check in guard-data, the status in the WHD folder still counts (read only).
        $whdOldP = Join-Path (Get-WHDGuardOldDataDir) 'state.json'
        if ((Test-WHDGuardDataMoved) -and (Test-Path -LiteralPath $whdOldP)) { $p = $whdOldP } else { return $null }
    }
    $s = $null
    try { $s = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $s = $null }
    # WHD Next (gap G13): a status file that came along from another PC / an earlier Windows install is not
    # this PC's status - ignore it (Undo center H moves it to the archive).
    if ($s -and (Get-Command Test-WHDGuardStateIsThisPC -EA SilentlyContinue) -and -not (Test-WHDGuardStateIsThisPC -State $s)) { return $null }
    return $s
}
function Save-WHDGuardState {
    param($State)
    $d = Get-WHDGuardDataDir
    # WHD Next (gap G13): tag the status with this PC, so a copied folder is recognised on another install.
    if ($State -is [System.Collections.IDictionary]) { $State['MachineId'] = Get-WHDMachineId; $State['Computer'] = "$env:COMPUTERNAME" }
    # WHD Next (gap G11): a status that cannot be saved must not end the run - say why and go on.
    try {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force -EA Stop | Out-Null }
        ($State | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath (Join-Path $d 'state.json') -Encoding UTF8 -EA Stop
    } catch {
        Write-WHDLog ("UPDATE GUARD: the status file could not be saved: {0}" -f $_.Exception.Message) 'ERR'
    }
}
# WHD Next (gap G11, user decision 2026-10-02): save the guard report; when that fails (folder protection),
# explain it and show the report on screen instead of ending the run. Returns $true when the file was written.
function Save-WHDGuardReport {
    param([Parameter(Mandatory)][string]$Path, [string[]]$Lines)
    try { $Lines | Set-Content -LiteralPath $Path -Encoding UTF8 -EA Stop; return $true }
    catch {
        Write-WHDLog ("UPDATE GUARD: the report could not be saved to {0}: {1}" -f $Path, $_.Exception.Message) 'ERR'
        Show-WHDWriteBlockedHelp
        Write-WHDLog 'The report, shown here instead:' 'WARN'
        foreach ($l in @($Lines)) { Write-WHDLog ("  | {0}" -f $l) 'INFO' }
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
function Remove-WHDOldGuardScans {
    param([string]$InvRoot, [int]$Keep = $script:WHDGuardKeep)
    $g = @(Get-ChildItem -LiteralPath $InvRoot -Directory -EA SilentlyContinue |
           Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName $script:WHDGuardMarker) } | Sort-Object Name)
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
    $dataDir = Get-WHDGuardDataDir
    if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
    # Step 11b: first use of guard-data -> take the older reports / status / guard scans over (copy, once).
    $whdTaken = Copy-WHDGuardDataOnce
    if ($whdTaken) { Write-WHDLog ("UPDATE GUARD: its files are now kept in {0} ({1})." -f (Get-WHDGuardDataRoot), $whdTaken.Note) $(if ($whdTaken.Failed) { 'WARN' } else { 'INFO' }) }
    $stamp  = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $report = Join-Path $dataDir ("guard_{0}.txt" -f $stamp)
    $rep    = New-Object System.Collections.Generic.List[string]
    $alert  = $false
    $state  = Get-WHDGuardState
    $rep.Add('WHD Next - UPDATE GUARD (alert only - nothing was changed)')
    $rep.Add(("Checked : {0}   on {1} as {2}\{3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME, $env:USERDOMAIN, $env:USERNAME))
    $rep.Add(("Engine  : {0}" -f (Get-WHDModeText)))
    # WHD Next (decided 2026-09-30): a scheduled check that could not use PowerShell 7.6 still runs
    # (SAFE mode, Windows PowerShell 5.1) and raises an alert - it never installs or changes anything.
    if ($script:WHDSafeMode -and -not $Now) {
        $alert = $true
        $rep.Add('!! PowerShell 7.6 could not be used for this check (not installed, too old, or blocked by folder protection).')
        $rep.Add('   The check below still ran, in SAFE MODE. Start WHD Next (Start-WHD) to see why and to fix it.')
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
        Save-WHDGuardState $ns
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
    if ($bad.Count) { $alert = $true; $rep.Add('  -> Fix: WHD menu (re-apply the item) or Undo center; Verify (V) shows the same list.') }
    if (@($bad | Where-Object { $_.Result -eq 'CHANGED' }).Count) { $rep.Add('  -> Settings that changed back: WHD main menu V, answer y to re-apply them (GUI: Inventory/Undo > "Re-apply settings that changed back").') }
    if (@($bad | Where-Object { $_.Result -eq 'RETURNED' }).Count) { $rep.Add('  -> Apps that came back: WHD main menu V, answer y to re-remove them (GUI: Inventory/Undo > "Re-remove apps that came back").') }
    $rep.Add('')

    # 2b) Time: refused time jumps since the last check (Time-Service event 34).
    #     User decision 2026-09-24: alert (open the report) when there are any.
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
        try { $gs = Get-WHDGateState; $rep.Add(("-- UPDATE GATE: {0}   (outbound {1})" -f $gs.Text, $gs.Outbound)) } catch {}
        # IP block list (info only): it follows the firewall - in where something is wide open, out where nothing is.
        if (Get-Command Get-WHDBlocklistNeed -EA SilentlyContinue) {
            try { $bln = Get-WHDBlocklistNeed; $rep.Add(("-- IP BLOCK LIST: {0}" -f $bln.Text)) } catch {}
        }
        $rep.Add('')
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
        $invRoot = Get-WHDGuardInventoryRoot      # step 11b: under ProgramData; the journal is still read from the WHD folder
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
            if (Test-WHDGuardDataMoved) { $rep.Add(("  Scan: {0}" -f $scan.FullName)) } else { $rep.Add(("  Scan: inventory\{0}" -f $scan.Name)) }
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
    # WHD Next (gap G11): a report that cannot be saved is itself something to look at.
    if (-not (Save-WHDGuardReport -Path $report -Lines $rep.ToArray())) {
        $rep.Add('!! This report could not be saved to the WHD folder (see the log).')
        for ($whdRi = 0; $whdRi -lt $rep.Count; $whdRi++) { if ("$($rep[$whdRi])" -like 'RESULT*') { $rep[$whdRi] = 'RESULT  : ALERT - see the !! lines below' } }
        $alert = $true; $result = 'ALERT'; $report = ''
    }
    Save-WHDGuardState ([ordered]@{ Fingerprint = $newFp; Build = $(if ($newFp) { $newFp.Split('|')[0] } else { '' })
                                    LastCheck = (Get-Date -Format 'yyyy-MM-dd HH:mm'); LastResult = $result; LastReport = $report })
    Write-WHDLog ("UPDATE GUARD: {0} - report: {1}" -f $result, $report) $(if ($alert) { 'WARN' } else { 'OK' })
    # Open via the desktop shell so Notepad runs as a normal (non-admin) window.
    # WHD Next (decided 2026-09-30 / 2026-10-01): on an alert, write a Windows event log entry and show a
    # small window. Neither changes any setting.
    $whdAlertLines = @($rep | Where-Object { "$_" -like 'RESULT*' -or "$_" -match '^\s*!!' })
    if ($alert) {
        [void](Write-WHDEventLog -Type 'Warning' -EventId 1001 -Message ("WHD Next update guard: ALERT`r`n{0}`r`nReport: {1}" -f ($whdAlertLines -join "`r`n"), $report))
    }
    if ($alert -and -not $NoPopup) {
        # User decision 2026-10-01: WINDOW ONLY - the report opens from the window's "Open the report" button.
        # If the window cannot be shown, fall back to opening the report directly (as Classic did).
        $whdShown = Show-WHDAlertWindow -Title 'WHD Next - update guard' -Heading 'The update guard found something to look at' `
                -Lines (@($whdAlertLines) + @('', 'Nothing was changed. "Open the report" shows the details and what to do.')) -ReportPath $report
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
    foreach ($d in @($Base, $Dst, (Join-Path $Dst 'modules'))) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
    _WHDIcacls @($Base, '/setowner', '*S-1-5-32-544', '/T', '/C', '/Q')
    _WHDIcacls @($Base, '/inheritance:r', '/grant:r', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX', '/Q')
    _WHDIcacls @((Join-Path $Base '*'), '/reset', '/T', '/C', '/Q')
    Get-ChildItem -LiteralPath $Dst -Recurse -File -EA SilentlyContinue | Remove-Item -Force -EA Stop
    Copy-Item -LiteralPath (Join-Path $Src 'WHD.ps1')       -Destination $Dst -Force
    Copy-Item -LiteralPath (Join-Path $Src 'Start-WHD.ps1') -Destination $Dst -Force   # WHD Next: the task starts the launcher, which picks the engine
    Copy-Item -LiteralPath (Join-Path $Src 'Inventory.ps1') -Destination $Dst -Force
    Copy-Item -Path (Join-Path $Src 'modules\*.ps1') -Destination (Join-Path $Dst 'modules') -Force
}
function _WHDGuardRegister {
    param([string]$Dst, [string]$DataRoot)
    $user  = "$env:USERDOMAIN\$env:USERNAME"
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # WHD Next: the task always starts Windows PowerShell 5.1 (present on every PC) with the LAUNCHER.
    # -NoPrompt = never ask, never install: PowerShell 7.6 if usable, otherwise SAFE mode on 5.1.
    $taskArgs = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -NoPrompt -Guard -DataRoot "{1}"' -f (Join-Path $Dst 'Start-WHD.ps1'), $DataRoot)
    $act  = New-ScheduledTaskAction -Execute $psExe -Argument $taskArgs -WorkingDirectory $Dst
    $trig = New-ScheduledTaskTrigger -AtLogOn -User $user
    $trig.Delay = $script:WHDGuardDelay
    $prin = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $set  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskPath $script:WHDGuardTaskPath -TaskName $script:WHDGuardTaskName -Action $act -Trigger $trig -Principal $prin -Settings $set `
        -Description 'WHD Next update guard (alert only): 10 min after sign-in checks that WHD changes are still in place; opens a report only if something changed.' -Force | Out-Null
}
function _WHDGuardRemove {
    try { Unregister-WHDEventSource } catch { }      # WHD Next: the guard's event log source
    if (Get-WHDGuardTask) { Unregister-ScheduledTask -TaskPath $script:WHDGuardTaskPath -TaskName $script:WHDGuardTaskName -Confirm:$false -EA Stop }
    if (Test-Path -LiteralPath $script:WHDGuardDir) { Remove-Item -LiteralPath $script:WHDGuardDir -Recurse -Force -EA Stop }
    if ((Test-Path -LiteralPath $script:WHDGuardBase) -and -not @(Get-ChildItem -LiteralPath $script:WHDGuardBase -Force -EA SilentlyContinue).Count) {
        Remove-Item -LiteralPath $script:WHDGuardBase -Force -EA SilentlyContinue
    }
}
# Build step 11c (user decision 2026-10-03, question B5): when the guard is installed or refreshed and WHD
# Classic's guard task is still on, ask right then whether to switch that task off.
# Build step 11d (user decision 2026-10-03 15:01, choice C): the question about Classic's task comes FIRST,
# before the install / refresh question, and does not depend on the answer to that one.
#   -Ask  = a real question can be asked (the terminal menu: Security+ G, hotkey GU). The question is the
#           one in Disable-WHDClassicGuardTask (explains first, default answer is No, journaled).
#   no -Ask (profile apply, window version - their answers are given once up front and then automatic) =
#           nothing is switched off; one line says where it can be done.
function Invoke-WHDClassicGuardOffer {
    param([switch]$Ask)
    if ($script:WHDSafeMode) { return }
    $cg = Get-WHDClassicGuardStatus
    if (-not $cg.Found -or -not $cg.Enabled) { return }
    if (-not $Ask) {
        Write-WHDLog ("WHD Classic's update guard task ({0}) is also switched on. It is left as it is here; in the menu version Security+ > GC switches it off." -f $cg.Id) 'WARN'
        return
    }
    Write-WHDLog ("FIRST: WHD Classic's update guard task ({0}) is also switched on - both guards would run after every sign-in. The question about WHD Next's own guard comes after this one." -f $cg.Id) 'WARN'
    Disable-WHDClassicGuardTask
}
function Install-WHDUpdateGuard {
    param([switch]$AskClassic)      # step 11c: see Invoke-WHDClassicGuardOffer
    Write-WHDLog 'UPDATE GUARD: install / refresh (alert only)' 'ACT'
    $gSrc = Get-WHDGuardCodeRoot; $gDst = $script:WHDGuardDir; $gBase = $script:WHDGuardBase; $gData = $script:WHDRoot
    if ($gSrc -eq $gDst) { Write-WHDLog 'Running from the protected guard copy - install from the project folder instead.' 'ERR'; return }
    if (-not (Test-WHDAdmin)) { Write-WHDLog 'Needs an elevated (admin) session.' 'ERR'; return }
    Invoke-WHDClassicGuardOffer -Ask:$AskClassic      # step 11d: Classic's guard task first, then this guard
    $had = [bool](Get-WHDGuardTask)
    Write-WHDRisk 'reversible' ("Copies the scripts to {0} (admins/SYSTEM can change them, users read only) and adds scheduled task {1}{2}: 10 min after YOU sign in, run as you with highest privileges, only while signed in. It only reads and reports - never changes anything. Reports: {3}. Also registers the Windows event log source 'WHD Next' (Application log) for guard alerts. Re-run this after updating the tool to refresh the protected copy. Undo removes task + copy." -f $gDst, $script:WHDGuardTaskPath, $script:WHDGuardTaskName, (Get-WHDGuardDataDir))
    if (-not (Confirm-WHDProceed $(if ($had) { 'refresh the update guard (copy + task)' } else { 'install the update guard' }))) { Write-WHDLog 'skipped.' 'WARN'; return }
    $jr = @{ Kind = 'schtask'; TaskPath = $script:WHDGuardTaskPath; TaskName = $script:WHDGuardTaskName; GuardDir = $gDst; Existed = $had }
    Invoke-WHDChange -Description ("update guard: protected copy in {0} + task {1}{2} (sign-in +10 min)" -f $gDst, $script:WHDGuardTaskPath, $script:WHDGuardTaskName) -Force -Journal $jr -Action {
        _WHDGuardCopy -Src $gSrc -Base $gBase -Dst $gDst
        _WHDGuardRegister -Dst $gDst -DataRoot $gData
        # WHD Next: register the event log source the guard writes its alerts to (removed again with the guard).
        try { Register-WHDEventSource } catch { Write-WHDLog ("event log source could not be registered (alerts still open the report and the window): {0}" -f $_.Exception.Message) 'WARN' }
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
    $rel = @('WHD.ps1', 'Start-WHD.ps1', 'Inventory.ps1') + @(Get-ChildItem -LiteralPath (Join-Path $src 'modules') -Filter *.ps1 -EA SilentlyContinue | ForEach-Object { "modules\$($_.Name)" })
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
        # WHD Next (unlocked copy, plan point 6): when WHD Next runs from the unlocked copy, the guard keeps its
        # reports and reads the journal there too. The task is pointed at the copy (the protected program copy
        # and the guard's own files are not changed by this).
        try {
            $whdUnlocked = Join-Path $script:WHDGuardBase 'app'
            $whdHere = "$($script:WHDRoot)".TrimEnd('\')
            if ([string]::Equals($whdHere, $whdUnlocked, [System.StringComparison]::OrdinalIgnoreCase) -and -not $script:WHDSafeMode) {
                $whdTask = Get-WHDGuardTask
                $whdTaskArgs = "$(@($whdTask.Actions)[0].Arguments)"
                if ($whdTaskArgs -and $whdTaskArgs.IndexOf(('-DataRoot "{0}"' -f $whdHere), [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                    _WHDGuardRegister -Dst $script:WHDGuardDir -DataRoot $whdHere
                    Write-WHDLog ("Update guard: now keeps its reports in the unlocked copy ({0})." -f $whdHere) 'OK'
                }
            }
        } catch { Write-WHDLog ("Update guard: could not point the task at the unlocked copy: {0} - use GU in any menu." -f $_.Exception.Message) 'WARN' }
        $stale = @(Get-WHDGuardStaleFiles)
        if (-not $stale.Count) { return }
        if ($script:WHDSafeMode) {   # WHD Next: updating the guard is a change -> FULL mode only
            Write-WHDLog ("Update guard: the protected copy is out of date ({0} file(s)); it is refreshed the next time WHD Next runs in FULL mode." -f $stale.Count) 'INFO'
            return
        }
        _WHDGuardCopy -Src (Get-WHDGuardCodeRoot) -Base $script:WHDGuardBase -Dst $script:WHDGuardDir
        Write-WHDLog ("Update guard: protected copy refreshed automatically ({0} changed file(s): {1})" -f $stale.Count, ($stale -join ', ')) 'OK'
    } catch { Write-WHDLog ("Update guard auto-refresh failed: {0} - use GU in any menu." -f $_.Exception.Message) 'WARN' }
}
# 'GU' in ANY menu = refresh the update guard (copy + task). Returns $true when it handled the key.
function Invoke-WHDGuardHotkey {
    param([string]$Key)
    if ("$Key" -notmatch '^[Gg][Uu]$') { return $false }
    Install-WHDUpdateGuard -AskClassic
    return $true
}
function Uninstall-WHDUpdateGuard {
    Write-WHDLog 'UPDATE GUARD: remove' 'ACT'
    if (-not (Get-WHDGuardTask) -and -not (Test-Path -LiteralPath $script:WHDGuardDir)) { Write-WHDLog 'Not installed - nothing to remove.' 'OK'; return }
    Write-WHDRisk 'reversible' 'Removes the scheduled task and the protected copy. The guard''s reports and scans are kept.'
    if (-not (Confirm-WHDProceed 'remove the update guard')) { Write-WHDLog 'skipped.' 'WARN'; return }
    $done0 = [int]$script:WHDCounts['done']
    Invoke-WHDChange -Description 'remove update guard (task + protected copy)' -Force -Action { _WHDGuardRemove } | Out-Null
    if ($script:WHDExecute -and [int]$script:WHDCounts['done'] -gt $done0) {
        # the install entries are no longer expected to verify
        foreach ($s in @(Get-WHDUndoSessions)) {
            foreach ($e in @(Get-WHDJournal -SessionPath $s.Path | Where-Object { "$($_.Kind)" -eq 'schtask' -and -not $_.Undone })) { _WHDMarkUndone $e }
        }
    }
}
