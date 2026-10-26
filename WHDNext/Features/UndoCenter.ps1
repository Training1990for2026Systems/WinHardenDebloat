#requires -Version 7.6
<#
================================================================================
 WHD Next 3.0  -  Features/UndoCenter.ps1   (build step 6a)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 The Undo center screen (main menu U) and Verify with re-apply / re-remove
 (main menu V) - the same features as WHD Next 2.0 (D8), written new for 7.6
 on top of the step 4 engine (Invoke-WHDUndo, Invoke-WHDVerify,
 Restore-WHDSessionBackup).
   Session list   # open a session, V verify everything, H history from other
                  PCs / earlier Windows installs -> archive\other-pcs\ (moved,
                  never deleted) and untagged sessions of this install tagged
   One session    # undo one or more changes (3 or 3,5,7), A every automatic
                  change of the session, F firewall backup, H hosts backup,
                  R the .reg backups, V verify this session, B back
   Re-apply       settings Verify reports CHANGED are set again to what WHD set
                  (the recorded new value); re-remove: apps Verify reports
                  RETURNED are removed again. One question each; recorded;
                  allowed in safe mode (D14).
================================================================================
#>

$script:WHDUndoOpen = $null          # the stamp of the session open in the Undo center (none = the list)
$script:WHDReApplyKinds = @('reg', 'service', 'task', 'pnpdev', 'deprov', 'fwlog', 'mppref', 'asr', 'tz', 'svctrigger', 'auditpol', 'eventlog', 'netacct')

# ---- the list ----------------------------------------------------------------------------------------------
function Get-WHDUndoCenterSession {
    # This PC's sessions with changes or backups, newest first (the numbers on screen).
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return , @(Get-WHDHistorySession)
}
function Get-WHDUndoSessionLabel {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Session)
    $bits = [System.Collections.Generic.List[string]]::new()
    $bits.Add(('{0} change(s)' -f $Session.Entries))
    if ($Session.Undone) { $bits.Add(('{0} undone' -f $Session.Undone)) }
    if ($Session.HasWfw) { $bits.Add('firewall backup') }
    if ($Session.HasHosts) { $bits.Add('hosts backup') }
    if ($Session.RegFiles) { $bits.Add(('{0} .reg backup(s)' -f $Session.RegFiles)) }
    if ($Session.Source -eq 'next2') { $bits.Add('WHD Next 2.0, read in place') }
    return ('{0}   {1}' -f $Session.Stamp, ($bits -join ', '))
}
function Get-WHDOtherPcScan {
    # Inventory scans made on another PC / an earlier Windows install (main menu 1 writes them; build step 6a).
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $root = Join-Path $script:WHDState.DataRoot 'inventory'
    if (-not (Test-Path -LiteralPath $root)) { return , @() }
    $me = Get-WHDMachineId
    return , @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object {
        $f = Join-Path $_.FullName 'os-info.json'
        if (-not (Test-Path -LiteralPath $f)) { return $false }
        try { $o = Get-Content -LiteralPath $f -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable } catch { return $false }
        [string]$o['MachineId'] -and ([string]$o['MachineId']).ToLowerInvariant() -ne $me
    })
}
function Show-WHDUndoCenterMenu {
    [CmdletBinding()]
    param()
    if ($script:WHDUndoOpen) { Show-WHDUndoSessionView; return }
    $sessions = Get-WHDUndoCenterSession
    Write-Host ''
    Write-Host '  ================= UNDO CENTER =================' -ForegroundColor White
    Write-Host '  Sessions of this PC with recorded changes or backups (newest first)' -ForegroundColor DarkGray
    if (-not $sessions.Count) { Write-Host '  (nothing recorded yet)' }
    $i = 0
    foreach ($s in $sessions) { $i++; Write-Host ('  {0,3}. {1}' -f $i, (Get-WHDUndoSessionLabel -Session $s)) }
    $other = @(Get-WHDHistorySession -IncludeOtherPCs | Where-Object { $_.Owner -in 'other', 'legacy-other' }).Count
    $scans = (Get-WHDOtherPcScan).Count
    Write-Host ''
    Write-WHDMenuItem -Key '#' -Label 'Open a session'
    Write-WHDMenuItem -Key 'V' -Label 'Verify every recorded change, then offer re-apply / re-remove'
    Write-WHDMenuItem -Key 'H' -Label ('History from other PCs / earlier Windows installs: {0} session(s), {1} inventory scan(s)' -f $other, $scans) -Hint '[moved to archive\other-pcs\, never deleted]'
    Write-WHDMenuCommonKey
}
function Show-WHDUndoSessionView {
    [CmdletBinding()]
    param()
    $sess = Get-WHDHistorySession | Where-Object Stamp -eq $script:WHDUndoOpen | Select-Object -First 1
    if (-not $sess) { $script:WHDUndoOpen = $null; Write-Host '  That session is not there any more.' -ForegroundColor Yellow; return }
    $entries = @(Get-WHDHistoryEntry -SessionPath $sess.Path -Source $sess.Source)
    Write-Host ''
    Write-Host ('  SESSION {0}' -f $sess.Stamp) -ForegroundColor White
    Write-Host '  [auto] = undone by WHD   [manual] = see the hint   [later] = comes with a later step   [undone] = already undone' -ForegroundColor DarkGray
    if (-not $entries.Count) { Write-Host '  (no change list - use this session''s backups below)' }
    $i = 0
    foreach ($e in $entries) {
        $i++
        $tag = if ($e['Undone']) { 'undone' } else { [string]$e['UndoMode'] }
        $col = switch ($tag) { 'auto' { 'Gray' } 'undone' { 'DarkGray' } default { 'Yellow' } }
        Write-Host ('  {0,3}. [{1,-6}] {2}' -f $i, $tag, $e['Description']) -ForegroundColor $col
        if ($tag -in 'manual', 'later') { Write-Host ('            {0}' -f (Get-WHDUndoHint -Entry $e)) -ForegroundColor DarkGray }
    }
    Write-Host ''
    Write-WHDMenuItem -Key '#' -Label 'Undo one or more changes (3, or 3,5,7)'
    Write-WHDMenuItem -Key 'A' -Label 'Undo every automatic change of this session (newest first)'
    if ($sess.HasWfw) { Write-WHDMenuItem -Key 'F' -Label 'Put back the firewall saved before this session (the WHOLE policy)' }
    if ($sess.HasHosts) { Write-WHDMenuItem -Key 'H' -Label 'Put back the hosts file saved before this session' }
    if ($sess.RegFiles) { Write-WHDMenuItem -Key 'R' -Label ('Import this session''s {0} .reg backup(s)' -f $sess.RegFiles) }
    Write-WHDMenuItem -Key 'V' -Label 'Verify this session''s changes'
    Write-WHDMenuCommonKey
}

function Invoke-WHDUndoCenterChoice {
    # One choice. Returns $false when the Undo center closes (B on the list).
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Choice)
    $c = $Choice.Trim()
    if (Invoke-WHDMenuCommonKey -Choice $c) { return $true }
    if ($script:WHDUndoOpen) {
        $sess = Get-WHDHistorySession | Where-Object Stamp -eq $script:WHDUndoOpen | Select-Object -First 1
        if (-not $sess -or $c -match '^([Bb])?$') { $script:WHDUndoOpen = $null; return $true }
        switch -regex ($c) {
            '^[Aa]$' { [void](Invoke-WHDUndo -Session $sess.Stamp) }
            '^[Ff]$' { if ($sess.HasWfw) { Restore-WHDSessionBackup -Session $sess.Stamp -Firewall } else { Write-Host '  invalid.' -ForegroundColor Yellow } }
            '^[Hh]$' { if ($sess.HasHosts) { Restore-WHDSessionBackup -Session $sess.Stamp -Hosts } else { Write-Host '  invalid.' -ForegroundColor Yellow } }
            '^[Rr]$' { if ($sess.RegFiles) { Restore-WHDSessionBackup -Session $sess.Stamp -RegFiles } else { Write-Host '  invalid.' -ForegroundColor Yellow } }
            '^[Vv]$' { [void](Invoke-WHDVerify -SessionPath $sess.Path) }
            '^[\d,\s]+$' {
                $entries = @(Get-WHDHistoryEntry -SessionPath $sess.Path -Source $sess.Source)
                $ids = @($c -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } |
                    Where-Object { $_ -ge 1 -and $_ -le $entries.Count } | ForEach-Object { [string]$entries[$_ - 1]['Id'] })
                if ($ids.Count) { [void](Invoke-WHDUndo -Id $ids) } else { Write-Host '  invalid.' -ForegroundColor Yellow }
            }
            default { Write-Host '  invalid.' -ForegroundColor Yellow }
        }
        return $true
    }
    switch -regex ($c) {
        '^([Bb])?$' { return $false }
        '^[Hh]$' { Invoke-WHDArchiveOtherHistory }
        '^[Vv]$' { Invoke-WHDVerifyAndRepair }
        '^\d+$' {
            $sessions = Get-WHDUndoCenterSession
            $n = [int]$c
            if ($n -ge 1 -and $n -le $sessions.Count) { $script:WHDUndoOpen = $sessions[$n - 1].Stamp } else { Write-Host '  invalid.' -ForegroundColor Yellow }
        }
        default { Write-Host '  invalid.' -ForegroundColor Yellow }
    }
    return $true
}

# ---- H: history from other PCs / earlier Windows installs ----------------------------------------------------
function Set-WHDSessionMachine {
    # Tags one session folder as this PC's (machine.json). Inside the archive step only.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$SessionPath)
    if (-not $PSCmdlet.ShouldProcess($SessionPath, 'tag as this PC')) { return }
    [pscustomobject][ordered]@{ MachineId = (Get-WHDMachineId); Computer = [Environment]::MachineName; Claimed = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } |
        ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $SessionPath 'machine.json') -Encoding utf8 -ErrorAction Stop
}
function Invoke-WHDArchiveOtherHistory {
    # Moves other PCs' sessions and inventory scans to archive\other-pcs\<time>\ (nothing deleted) and tags this
    # install's untagged sessions. WHD's own project files only: allowed in safe mode (as 2.0).
    [CmdletBinding()]
    param()
    Write-WHDLog -Message 'UNDO CENTER H: history from other PCs / earlier Windows installs' -Level 'ACT'
    $all = @(Get-WHDHistorySession -IncludeOtherPCs | Where-Object Source -eq 'own')
    $other = @($all | Where-Object { $_.Owner -in 'other', 'legacy-other' })
    $claim = @($all | Where-Object { $_.Owner -eq 'legacy-this' })
    $scans = Get-WHDOtherPcScan
    $inst = Get-WHDWindowsInstallDate
    Write-WHDLog -Message ('This PC: {0}   (Windows installed {1})' -f [Environment]::MachineName, $(if ($inst) { $inst.ToString('yyyy-MM-dd HH:mm') } else { 'unknown' }))
    Write-WHDLog -Message ('  {0} session(s) of another PC / an earlier install -> archive\other-pcs\' -f $other.Count)
    foreach ($o in $other) { Write-WHDLog -Message ('     {0}' -f (Get-WHDUndoSessionLabel -Session $o)) }
    Write-WHDLog -Message ('  {0} untagged session(s) of this install -> tagged as this PC' -f $claim.Count)
    Write-WHDLog -Message ('  {0} inventory scan(s) of another PC / an earlier install -> archive\other-pcs\...\inventory\' -f $scans.Count)
    if (-not ($other.Count + $claim.Count + $scans.Count)) { Write-WHDLog -Message 'Nothing to do - all history belongs to this PC and is tagged.' -Level 'OK'; return }
    Write-WHDRisk -Tier 'reversible' -Text 'Nothing is deleted: the folders are moved to archive\other-pcs\ (move them back to use them again). Verify, the Undo center and the inventory compare then show only this PC''s history.'
    Invoke-WHDSafeAllowed -Do {
        if (-not (Confirm-WHDProceed -What 'archive the history of other PCs and tag this PC''s sessions')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
        if (-not (Test-WHDRealChange)) {
            foreach ($o in $other) { Write-WHDLog -Message ('would: move restore\{0} -> archive\other-pcs\' -f $o.Stamp) -Level 'DRY' }
            foreach ($c in $claim) { Write-WHDLog -Message ('would: tag {0} as this PC' -f $c.Stamp) -Level 'DRY' }
            foreach ($sc in $scans) { Write-WHDLog -Message ('would: move inventory\{0} -> archive\other-pcs\' -f $sc.Name) -Level 'DRY' }
            return
        }
        $dest = [System.IO.Path]::Combine($script:WHDState.DataRoot, 'archive', 'other-pcs', (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
        $moved = 0; $tagged = 0; $mScans = 0; $bad = 0
        foreach ($o in $other) {
            try { if (-not (Test-Path -LiteralPath $dest)) { [void](New-Item -ItemType Directory -Path $dest -Force -ErrorAction Stop) }; Move-Item -LiteralPath $o.Path -Destination (Join-Path $dest $o.Stamp) -ErrorAction Stop; $moved++ }
            catch { $bad++; Write-WHDLog -Message ('could not move {0}: {1}' -f $o.Stamp, $_.Exception.Message) -Level 'ERR' }
        }
        foreach ($c in $claim) { try { Set-WHDSessionMachine -SessionPath $c.Path -Confirm:$false; $tagged++ } catch { $bad++; Write-WHDLog -Message ('could not tag {0}: {1}' -f $c.Stamp, $_.Exception.Message) -Level 'ERR' } }
        foreach ($sc in $scans) {
            try { $di = Join-Path $dest 'inventory'; if (-not (Test-Path -LiteralPath $di)) { [void](New-Item -ItemType Directory -Path $di -Force -ErrorAction Stop) }; Move-Item -LiteralPath $sc.FullName -Destination (Join-Path $di $sc.Name) -ErrorAction Stop; $mScans++ }
            catch { $bad++; Write-WHDLog -Message ('could not move inventory\{0}: {1}' -f $sc.Name, $_.Exception.Message) -Level 'ERR' }
        }
        Write-WHDLog -Message ('History: {0} session(s) and {1} inventory scan(s) moved to {2}; {3} session(s) tagged as this PC{4}.' -f $moved, $mScans, $dest, $tagged, $(if ($bad) { ('; {0} could not be done' -f $bad) } else { '' })) -Level $(if ($bad) { 'WARN' } else { 'OK' })
    }
}

# ---- V: verify, then re-apply / re-remove ---------------------------------------------------------------------
function Invoke-WHDVerifyAndRepair {
    # Main menu V / Undo center V: Verify everything; then re-remove apps that came back and re-apply settings that
    # changed back - one question each (as 2.0).
    [CmdletBinding()]
    param()
    $res = @(Invoke-WHDVerify -All)
    if (@($res | Where-Object { $_.Result -eq 'RETURNED' -and $_.Kind -in 'appx', 'provisioned' }).Count) { Invoke-WHDReRemove -Results $res }
    if (@($res | Where-Object Result -eq 'CHANGED').Count) { Invoke-WHDReApply -Results $res }
}
function Invoke-WHDReApplyEntry {
    # Sets ONE recorded change again to its recorded new value (the caller asked first).
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Entry)
    $e = $Entry
    switch ([string]$e['Kind']) {
        'reg' {
            if ($e['NewExists']) { Set-WHDRegistryValue -Path ([string]$e['Path']) -Name ([string]$e['Name']) -Value (ConvertTo-WHDRegValue -Value $e['NewValue'] -Type ([string]$e['NewType'])) -Type ([string]$e['NewType']) | Out-Null }
            else { Remove-WHDRegistryValue -Path ([string]$e['Path']) -Name ([string]$e['Name']) | Out-Null }
        }
        'service'  { Set-WHDServiceStartType -Service ([string]$e['Service']) -StartType ([string]$e['NewStartType']) | Out-Null }
        'task'     { Set-WHDScheduledTaskEnabled -TaskPath ([string]$e['TaskPath']) -TaskName ([string]$e['TaskName']) -Enabled ([bool]$e['NewEnabled']) -WasEnabled (-not [bool]$e['NewEnabled']) | Out-Null }
        'pnpdev'   { Set-WHDPnpDeviceEnabled -InstanceId ([string]$e['InstanceId']) -Name ([string]$e['Name']) -Enabled ([bool]$e['NewEnabled']) -WasEnabled (-not [bool]$e['NewEnabled']) | Out-Null }
        'deprov'   { Add-WHDDeprovisionMark -Pfn ([string]$e['Pfn']) }
        'fwlog'    { Set-WHDFirewallLog -FwProfile ([string]$e['Profile']) -Allowed ([string]$e['NewAllowed']) -Blocked ([string]$e['NewBlocked']) -SizeKB ([int64]$e['NewSizeKB']) | Out-Null }
        'mppref'   { Set-WHDMpPreference -Setting ([string]$e['Setting']) -Value ([int]$e['NewValue']) | Out-Null }
        'asr'      { Set-WHDAsrRule -Id ([string]$e['RuleId']) -Code ([int]$e['NewAction']) -Name ([string]$e['RuleName']) | Out-Null }
        'tz'       { Set-WHDTimeZoneId -Id ([string]$e['NewId']) | Out-Null }
        'auditpol' { Set-WHDAuditSetting -Guid ([string]$e['Guid']) -Name ([string]$e['Subcategory']) -Success ([bool]$e['NewSuccess']) -Failure ([bool]$e['NewFailure']) | Out-Null }
        'eventlog' { Set-WHDEventLogConfig -LogName ([string]$e['LogName']) -MaxBytes ([int64]$e['NewMaxBytes']) -Mode ([string]$e['NewMode']) | Out-Null }
        'netacct'  { Set-WHDPasswordSetting -Setting ([string]$e['Setting']) -Value ([int]$e['NewValue']) | Out-Null }
        'svctrigger' {
            if ([string]$e['NewState'] -eq 'off') { [void](Remove-WHDTimeTrigger) }
            elseif ([string]$e['Backup'] -and (Test-Path -LiteralPath ([string]$e['Backup']))) { [void](Restore-WHDTimeTrigger -Backup ([string]$e['Backup'])) }
            else { Write-WHDLog -Message 're-apply by hand (Firewall menu, time sync): the Windows Time start triggers - the saved copy is missing' -Level 'WARN' }
        }
        default { Write-WHDLog -Message ('re-apply by hand (its menu): {0}' -f $e['Description']) -Level 'WARN' }
    }
}
function Invoke-WHDReApply {
    # Settings Verify reports CHANGED: set again to what WHD set. Allowed in safe mode (D14).
    [CmdletBinding()]
    param([object[]]$Results)
    if (-not $Results) { $Results = @(Invoke-WHDVerify -All) }
    $bad = @($Results | Where-Object Result -eq 'CHANGED')
    $todo = @($bad | Where-Object { $script:WHDReApplyKinds -contains $_.Kind -and $_.Entry })
    $hand = @($bad | Where-Object { $script:WHDReApplyKinds -notcontains $_.Kind -or -not $_.Entry })
    foreach ($h in $hand) { Write-WHDLog -Message ('re-apply by hand (its menu): {0}' -f $h.Target) -Level 'WARN' }
    if (-not $todo.Count) { if (-not $hand.Count) { Write-WHDLog -Message 'No changed settings - nothing to re-apply.' -Level 'OK' }; return }
    Write-WHDLog -Message ('RE-APPLY {0} setting(s) that changed back:' -f $todo.Count) -Level 'ACT'
    foreach ($t in $todo) { Write-WHDLog -Message ('  {0}   now: {1}' -f $t.Target, $t.Now) }
    Write-WHDRisk -Tier 'reversible' -Text 'Puts back exactly what WHD set before (the recorded new value). Recorded again, so the Undo center can reverse it.'
    Invoke-WHDSafeAllowed -Do {
        if (-not (Confirm-WHDProceed -What ('re-apply {0} changed setting(s)' -f $todo.Count))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
        Invoke-WHDConfirmOnce -Do {
            foreach ($t in $todo) {
                try { Invoke-WHDReApplyEntry -Entry $t.Entry }
                catch { Write-WHDLog -Message ('FAILED: re-apply {0} :: {1}' -f $t.Target, $_.Exception.Message) -Level 'ERR' }
            }
        }
    }
}
function Invoke-WHDReRemove {
    # Apps Verify reports RETURNED: remove again for all users + the staged copy + the Deprovisioned mark. Safe mode ok.
    [CmdletBinding()]
    param([object[]]$Results)
    if (-not $Results) { $Results = @(Invoke-WHDVerify -All) }
    $pk = @($Results | Where-Object { $_.Result -eq 'RETURNED' -and $_.Kind -in 'appx', 'provisioned' -and $_.Entry } |
        ForEach-Object { [string]$_.Entry['Package'] } | Where-Object { $_ } | Select-Object -Unique)
    if (-not $pk.Count) { Write-WHDLog -Message 'No removed apps have come back - nothing to re-remove.' -Level 'OK'; return }
    Write-WHDLog -Message ('RE-REMOVE {0} app(s) that came back: {1}' -f $pk.Count, ($pk -join ', ')) -Level 'ACT'
    Write-WHDRisk -Tier 'reversible' -Text 'Removes them again for all users, removes the staged copy and writes the Deprovisioned mark so Windows updates leave them out. Recorded.'
    Invoke-WHDSafeAllowed -Do {
        if (-not (Confirm-WHDProceed -What ('re-remove {0} returned app(s)' -f $pk.Count))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
        Invoke-WHDConfirmOnce -Do {
            foreach ($n in $pk) {
                try { Remove-WHDAppxAllUser -NameLike $n; Remove-WHDProvisioned -NameLike $n }
                catch { Write-WHDLog -Message ('FAILED: re-remove {0} :: {1}' -f $n, $_.Exception.Message) -Level 'ERR' }
            }
        }
    }
}
