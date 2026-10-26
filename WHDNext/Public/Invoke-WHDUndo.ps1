#requires -Version 7.6
<#
 WHD Next 3.0  -  Public/Invoke-WHDUndo.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 Undo center: undo recorded changes, newest first, with ONE question for the
 whole batch. Allowed in safe mode (D14). Dry-run: shows what each undo would
 do and changes nothing.
   -Id <id,...>        these changes
   -Session <stamp>    every change of one session
   -All                every change of this PC (the full history)
 Manual / later entries are listed with their hint, never changed.
#>
function Invoke-WHDUndo {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([string[]]$Id, [string]$Session, [switch]$All)
    if (-not ($Id -or $Session -or $All)) { throw 'Invoke-WHDUndo: give -Id, -Session or -All' }
    $sessions = @(Get-WHDHistorySession | Where-Object { $All -or $Id -or $_.Stamp -eq $Session })
    $todo = @(foreach ($s in $sessions) { Get-WHDHistoryEntry -SessionPath $s.Path -Source $s.Source }) |
        Where-Object { -not $_['Undone'] -and (-not $Id -or $Id -contains [string]$_['Id']) } |
        Sort-Object @{ e = { [string]$_['Session'] }; Descending = $true }, @{ e = { [int]$_['Seq'] }; Descending = $true }
    $todo = @($todo)
    $sum = [ordered]@{ Selected = $todo.Count; Done = 0; Planned = 0; Manual = 0; Later = 0; Failed = 0 }
    if (-not $todo.Count) { Write-WHDLog -Message 'Nothing to undo (already undone or nothing selected).'; return [pscustomobject]$sum }
    $auto = @($todo | Where-Object { $_['UndoMode'] -eq 'auto' }).Count
    Write-WHDLog -Message ('UNDO: {0} change(s) selected, {1} can be undone automatically' -f $todo.Count, $auto) -Level 'ACT'
    if (-not $PSCmdlet.ShouldProcess(('{0} change(s)' -f $todo.Count), 'undo')) { return [pscustomobject]$sum }
    Invoke-WHDSafeAllowed -Do {
        if (-not (Confirm-WHDProceed -What ('undo {0} change(s) ({1} automatic)' -f $todo.Count, $auto))) { Write-WHDLog -Message 'Undo not confirmed - nothing changed.' -Level 'WARN'; return }
        $script:WHDState.Undoing = $true
        try {
            foreach ($e in $todo) {
                if ($script:WHDState.JournalStop) { break }
                try { $one = Invoke-WHDUndoEntry -Entry $e }
                catch {
                    # one entry that cannot even be read (e.g. Defender not active) must not stop the rest
                    Write-WHDLog -Message ('FAILED: undo of {0} :: {1}' -f $e['Description'], $_.Exception.Message) -Level 'ERR'
                    $one = 'failed'
                }
                switch ($one) { 'done' { $sum.Done++ } 'planned' { $sum.Planned++ } 'manual' { $sum.Manual++ } 'later' { $sum.Later++ } default { $sum.Failed++ } }
            }
        } finally { $script:WHDState.Undoing = $false }
    }
    Write-WHDLog -Message ('UNDO summary: {0} undone, {1} would be undone (dry-run), {2} manual, {3} after step 5, {4} failed / blocked' -f $sum.Done, $sum.Planned, $sum.Manual, $sum.Later, $sum.Failed) -Level $(if ($sum.Failed) { 'WARN' } else { 'OK' })
    return [pscustomobject]$sum
}
