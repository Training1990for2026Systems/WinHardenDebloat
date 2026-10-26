#requires -Version 7.6
<#
 WHD Next 3.0  -  Private/Undo.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 Undo of one recorded change. Each undo is itself a recorded change (ByUndo),
 so it can be undone again. A change counts as undone only when the undo was
 really done (EXECUTE). Undo marks:
   own sessions (incl. the copied WHD Next 2.0 ones)  -> <session>\undo.jsonl
   WHD Next 2.0 read in place                          -> restore\next2-undo.jsonl
 (WHD Next 2.0's folder is never written to, D12). Same format as Next 2.0:
 Id, Time, BySession (+ Session in next2-undo.jsonl).
#>
function ConvertTo-WHDRegValue {
    # A recorded value back to the exact type (DWORDs above 0x7FFFFFFF come back from JSON as large numbers).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'returns the type the target needs')]
    [CmdletBinding()]
    [OutputType([object])]
    param([AllowNull()]$Value, [string]$Type)
    switch ($Type) {
        'DWord'       { $v = [int64]$Value -band 0xFFFFFFFFL; if ($v -gt 2147483647L) { $v -= 4294967296L }; return [int32]$v }
        'QWord'       { return [int64]$Value }
        'MultiString' { return , ([string[]]@($Value)) }
        'Binary'      { return , ([byte[]]@($Value | ForEach-Object { [byte]$_ })) }
        default       { return [string]$Value }
    }
}

function Add-WHDUndoMark {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Entry)
    $st = $script:WHDState
    if ([string]$Entry['Source'] -eq 'next2') {
        $file = Join-Path (Join-Path $st.DataRoot 'restore') 'next2-undo.jsonl'
        $rec = [ordered]@{ Id = [string]$Entry['Id']; Session = [string]$Entry['Session']; Time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); BySession = $st.Stamp }
    } else {
        $file = Join-Path ([string]$Entry['SessionPath']) 'undo.jsonl'
        $rec = [ordered]@{ Id = [string]$Entry['Id']; Time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); BySession = $st.Stamp }
    }
    try {
        $dir = Split-Path $file -Parent
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop) }
        Add-WHDJournalLine -File $file -Line ([pscustomobject]$rec | ConvertTo-Json -Compress)
        $Entry['Undone'] = $true
    } catch {
        Register-WHDJournalStop -Description ('undo mark for: {0}' -f $Entry['Description']) -Reason $_.Exception.Message -File $file -Line ''
    }
}

function Invoke-WHDUndoEntry {
    # Undoes ONE entry (the caller asked first). Returns 'done' | 'planned' | 'manual' | 'later' | 'failed' | 'skipped'.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Entry)
    $e = $Entry
    $mode = Get-WHDUndoMode -Entry $e
    if ($mode -ne 'auto') {
        Write-WHDLog -Message ('{0} undo only: {1}  ({2})' -f $(if ($mode -eq 'later') { 'later -' } else { 'manual' }), $e['Description'], (Get-WHDUndoHint -Entry $e)) -Level 'WARN'
        return $mode
    }
    $before = $script:WHDState.Counts.done
    $failedBefore = $script:WHDState.Counts.failed + $script:WHDState.Counts.skipped
    switch ([string]$e['Kind']) {
        'reg' {
            if ($e['OldExists']) {
                Set-WHDRegistryValue -Path ([string]$e['Path']) -Name ([string]$e['Name']) -Value (ConvertTo-WHDRegValue -Value $e['OldValue'] -Type ([string]$e['OldType'])) -Type ([string]$e['OldType']) | Out-Null
            } else {
                Remove-WHDRegistryValue -Path ([string]$e['Path']) -Name ([string]$e['Name']) | Out-Null
                $ukPath = [string]$e['Path']
                if (-not $e['OldKeyExists'] -and (Test-WHDRealChange) -and (Test-Path -LiteralPath $ukPath)) {
                    $k = Get-Item -LiteralPath $ukPath -ErrorAction SilentlyContinue
                    if ($k -and $k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) {
                        Invoke-WHDChange -Description ('remove empty key created by WHD: {0}' -f $ukPath) -Journal @{ Kind = 'regkey'; Path = $ukPath } -Action { Remove-Item -LiteralPath $ukPath -ErrorAction Stop } | Out-Null
                    }
                }
            }
        }
        'regkey'   { $rkPath = [string]$e['Path']; Invoke-WHDChange -Description ('recreate empty key: {0}' -f $rkPath) -Action { if (-not (Test-Path -LiteralPath $rkPath)) { [void](New-Item -Path $rkPath -Force) } } | Out-Null }
        'service'  { Set-WHDServiceStartType -Service ([string]$e['Service']) -StartType ([string]$e['OldStartType']) | Out-Null }
        'auditpol' { Set-WHDAuditSetting -Guid ([string]$e['Guid']) -Name ([string]$e['Subcategory']) -Success ([bool]$e['OldSuccess']) -Failure ([bool]$e['OldFailure']) | Out-Null }
        'eventlog' { Set-WHDEventLogConfig -LogName ([string]$e['LogName']) -MaxBytes ([int64]$e['OldMaxBytes']) -Mode ([string]$e['OldMode']) | Out-Null }
        'fwrule'   { Remove-WHDFirewallRule -RuleName ([string]$e['RuleName']) | Out-Null }
        'mppref'   { Set-WHDMpPreference -Setting ([string]$e['Setting']) -Value $(if ($null -eq $e['OldValue']) { 0 } else { [int]$e['OldValue'] }) | Out-Null }
        'asr'      { Set-WHDAsrRule -Id ([string]$e['RuleId']) -Code ([int]$e['OldAction']) -Name ([string]$e['RuleName']) | Out-Null }
        'deprov'   { Remove-WHDDeprovisionMark -Pfn ([string]$e['Pfn']) | Out-Null }
        'fwlog'    { Set-WHDFirewallLog -FwProfile ([string]$e['Profile']) -Allowed ([string]$e['OldAllowed']) -Blocked ([string]$e['OldBlocked']) -SizeKB ([int64]$e['OldSizeKB']) | Out-Null }
        'tz'       { if (-not $e['OldId']) { Write-WHDLog -Message 'old time zone unknown, cannot undo' -Level 'ERR'; return 'failed' }; Set-WHDTimeZoneId -Id ([string]$e['OldId']) | Out-Null }
        'pnpdev'   { Set-WHDPnpDeviceEnabled -InstanceId ([string]$e['InstanceId']) -Name ([string]$e['Name']) -Enabled ([bool]$e['OldEnabled']) -WasEnabled ([bool]$e['NewEnabled']) | Out-Null }
        'task'     { Set-WHDScheduledTaskEnabled -TaskPath ([string]$e['TaskPath']) -TaskName ([string]$e['TaskName']) -Enabled ([bool]$e['OldEnabled']) -WasEnabled ([bool]$e['NewEnabled']) | Out-Null }
        'netacct'  { if ($null -eq $e['OldValue']) { Write-WHDLog -Message ('old value unknown, cannot undo: {0}' -f $e['Description']) -Level 'ERR'; return 'failed' }; Set-WHDPasswordSetting -Setting ([string]$e['Setting']) -Value ([int]$e['OldValue']) | Out-Null }
        'file'     { if (-not (Test-Path -LiteralPath ([string]$e['Backup']))) { Write-WHDLog -Message ('backup file missing, cannot undo: {0}' -f $e['Backup']) -Level 'ERR'; return 'failed' }; Restore-WHDFileFromBackup -Path ([string]$e['Path']) -Backup ([string]$e['Backup']) | Out-Null }
        'feature'  { Enable-WHDOptionalFeature -Feature ([string]$e['Feature']) | Out-Null }
        'schtask'  {
            # the update guard (3.0's, or 2.0's from its history): task, its copy and its event-log source
            $gP = [string]$e['TaskPath']; $gN = [string]$e['TaskName']; $gD = [string]$e['GuardDir']; $gS = [string]$e['EventSource']
            Invoke-WHDChange -Description ('remove update guard {0}{1} + its copy' -f $gP, $gN) -Journal @{ Kind = 'action'; Hint = 'main menu G > 1 installs the update guard again' } -Action { Remove-WHDGuardInstall -TaskPath $gP -TaskName $gN -CopyDir $gD -EventSource $gS -Confirm:$false } | Out-Null
        }
        'svctrigger' {
            # off -> put the saved copy back (its own file, else the same file in the copied session, else the newest);
            # on -> take them off again. Either way Windows reads the triggers at its next start-up.
            if ([string]$e['NewState'] -eq 'on') { [void](Remove-WHDTimeTrigger) }
            else {
                $tb = [string]$e['Backup']
                if (-not ($tb -and (Test-Path -LiteralPath $tb)) -and $e['SessionPath']) { $tb = Join-Path ([string]$e['SessionPath']) (([string]$e['Backup']) -replace '^.*[\\/]', '') }
                $tr = Restore-WHDTimeTrigger -Backup $tb
                if ($tr -eq 'nobackup') { return 'failed' }
            }
        }
    }
    if ($script:WHDState.Counts.done -gt $before) { Add-WHDUndoMark -Entry $e; return 'done' }
    if (($script:WHDState.Counts.failed + $script:WHDState.Counts.skipped) -gt $failedBefore) { return 'failed' }
    if (Test-WHDRealChange) {
        # Nothing to change (already back to the old state): it still counts as undone.
        Add-WHDUndoMark -Entry $e; return 'done'
    }
    return 'planned'
}
