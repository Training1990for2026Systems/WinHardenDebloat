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
#   * alert = report file in restore\update-guard\, opened in Notepad ONLY when
#     a WHD change was undone/returned or a removed app came back
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

function Get-WHDGuardDataDir { Join-Path $script:WHDRoot 'restore\update-guard' }
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
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null }
}
function Save-WHDGuardState {
    param($State)
    $d = Get-WHDGuardDataDir
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    ($State | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath (Join-Path $d 'state.json') -Encoding UTF8
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
    $stamp  = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $report = Join-Path $dataDir ("guard_{0}.txt" -f $stamp)
    $rep    = New-Object System.Collections.Generic.List[string]
    $alert  = $false
    $state  = Get-WHDGuardState
    $rep.Add('WinHardenDebloat - UPDATE GUARD (alert only - nothing was changed)')
    $rep.Add(("Checked : {0}   on {1} as {2}\{3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME, $env:USERDOMAIN, $env:USERNAME))
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
        $rep | Set-Content -LiteralPath $report -Encoding UTF8
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
        $invRoot = Join-Path $script:WHDRoot 'inventory'
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
            Set-Content -LiteralPath (Join-Path $scan.FullName $script:WHDGuardMarker) -Value ("made by update guard {0}" -f $stamp) -Encoding ASCII
            $newFp = $fp.Text
            $rep.Add(("  Scan: inventory\{0}" -f $scan.Name))
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
    $rep | Set-Content -LiteralPath $report -Encoding UTF8
    Save-WHDGuardState ([ordered]@{ Fingerprint = $newFp; Build = $(if ($newFp) { $newFp.Split('|')[0] } else { '' })
                                    LastCheck = (Get-Date -Format 'yyyy-MM-dd HH:mm'); LastResult = $result; LastReport = $report })
    Write-WHDLog ("UPDATE GUARD: {0} - report: {1}" -f $result, $report) $(if ($alert) { 'WARN' } else { 'OK' })
    # Open via the desktop shell so Notepad runs as a normal (non-admin) window.
    if ($alert -and -not $NoPopup) { try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $report) } catch {} }
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
    foreach ($d in @($Base, $Dst, (Join-Path $Dst 'modules'))) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
    _WHDIcacls @($Base, '/setowner', '*S-1-5-32-544', '/T', '/C', '/Q')
    _WHDIcacls @($Base, '/reset', '/Q')
    _WHDIcacls @($Base, '/inheritance:r', '/grant:r', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX', '/Q')
    _WHDIcacls @((Join-Path $Base '*'), '/reset', '/T', '/C', '/Q')
    Get-ChildItem -LiteralPath $Dst -Recurse -File -EA SilentlyContinue | Remove-Item -Force -EA Stop
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
    Write-WHDRisk 'reversible' ("Copies the scripts to {0} (admins/SYSTEM can change them, users read only) and adds scheduled task {1}{2}: 10 min after YOU sign in, run as you with highest privileges, only while signed in. It only reads and reports - never changes anything. Reports: restore\update-guard\. Re-run this after updating the tool to refresh the protected copy. Undo removes task + copy." -f $gDst, $script:WHDGuardTaskPath, $script:WHDGuardTaskName)
    if (-not (Confirm-WHDProceed $(if ($had) { 'refresh the update guard (copy + task)' } else { 'install the update guard' }))) { Write-WHDLog 'skipped.' 'WARN'; return }
    $jr = @{ Kind = 'schtask'; TaskPath = $script:WHDGuardTaskPath; TaskName = $script:WHDGuardTaskName; GuardDir = $gDst; Existed = $had }
    Invoke-WHDChange -Description ("update guard: protected copy in {0} + task {1}{2} (sign-in +10 min)" -f $gDst, $script:WHDGuardTaskPath, $script:WHDGuardTaskName) -Force -Journal $jr -Action {
        _WHDGuardCopy -Src $gSrc -Base $gBase -Dst $gDst
        _WHDGuardRegister -Dst $gDst -DataRoot $gData
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
    Write-WHDRisk 'reversible' 'Removes the scheduled task and the protected copy. Reports and scans in the project folder are kept.'
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
