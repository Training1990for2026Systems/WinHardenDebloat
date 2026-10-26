#requires -Version 7.6
<#
 WHD Next 3.0  -  Private/Invoke-WHDChange.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 THE change gate. Every change WHD makes goes through Invoke-WHDChange:
   * dry-run (EXECUTE off): prints "would: ..." and records it as planned
   * journal stop: after a failed journal write nothing else is changed
   * safe mode (D14): only an allowed operation (Invoke-WHDSafeAllowed:
     Undo, re-apply, re-remove, restore point) may pass
   * EXECUTE: restore point before the first change, run, journal, result
 It never asks - asking is the caller's job (Confirm-WHDProceed).
#>
function Invoke-WHDChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Action,
        [hashtable]$Journal          # what to record; omitted -> Kind 'action' (manual undo)
    )
    $s = $script:WHDState
    if ($s.JournalStop) {
        Write-WHDLog -Message ('STOPPED - not done (WHD cannot write its change history): {0}' -f $Description) -Level 'WARN'
        return (Add-WHDResult -Action $Description -Status 'skipped' -Detail 'stopped: change history could not be written')
    }
    if ($s.SafeMode -and $s.SafeAllow -le 0) {
        if ($s.Execute) {
            Write-WHDLog -Message ('SAFE MODE - not done (only Undo, re-apply, re-remove and restore points): {0}' -f $Description) -Level 'WARN'
            return (Add-WHDResult -Action $Description -Status 'skipped' -Detail 'safe mode')
        }
        Write-WHDLog -Message ('would (not in safe mode): {0}' -f $Description) -Level 'DRY'
        return (Add-WHDResult -Action $Description -Status 'planned')
    }
    if (-not $s.Execute) {
        Write-WHDLog -Message ('would: {0}' -f $Description) -Level 'DRY'
        return (Add-WHDResult -Action $Description -Status 'planned')
    }
    New-WHDRestorePoint
    $s.ChangeNote = $null           # an Action may set this when it finished but the result needs a check
    try {
        & $Action
    } catch {
        $msg = $_.Exception.Message
        if ($_.Exception -is [System.UnauthorizedAccessException] -or $msg -match 'unauthorized|access is denied') {
            Write-WHDLog -Message ('blocked (permissions / policy), skipped: {0}' -f $Description) -Level 'WARN'
            return (Add-WHDResult -Action $Description -Status 'skipped' -Detail $msg)
        }
        Write-WHDLog -Message ('FAILED: {0} :: {1}' -f $Description, $msg) -Level 'ERR'
        return (Add-WHDResult -Action $Description -Status 'failed' -Detail $msg)
    }
    $note = $s.ChangeNote
    $s.ChangeNote = $null
    if ($note) { Write-WHDLog -Message ('finished ({0}) - check it: {1}' -f $note, $Description) -Level 'WARN' }
    else { Write-WHDLog -Message ('done: {0}' -f $Description) -Level 'OK' }
    Add-WHDJournal -Description $Description -Data $Journal
    if ($note) { return (Add-WHDResult -Action $Description -Status 'done' -Detail $note) }
    return (Add-WHDResult -Action $Description -Status 'done')
}

function Invoke-WHDSafeAllowed {
    # Runs one operation that safe mode allows (Undo, re-apply, re-remove, restore point).
    # Outside safe mode it simply runs. In safe mode it opens the gate for this operation only.
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Do)
    $s = $script:WHDState
    if (-not $s.SafeMode) { & $Do; return }
    $s.SafeAllow++
    try { & $Do }
    finally { $s.SafeAllow = [Math]::Max(0, $s.SafeAllow - 1) }
}

function Confirm-WHDProceed {
    # Asks through the injected strategy. A dry-run always "proceeds" (to show the preview).
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$What)
    if (-not (Test-WHDRealChange)) { return $true }
    return [bool](& $script:WHDState.Confirm $What)
}
