#requires -Version 7.6
<#
 WHD Next 3.0  -  Public/Set-WHDMode.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 Switches EXECUTE (real changes) and safe mode (D14) on or off.
 EXECUTE needs an administrator window and stays off after a journal stop.
#>
function Set-WHDMode {
    [CmdletBinding(SupportsShouldProcess)]
    param([Nullable[bool]]$Execute, [Nullable[bool]]$SafeMode)
    $s = $script:WHDState
    if ($null -ne $SafeMode -and $PSCmdlet.ShouldProcess('safe mode', [string]$SafeMode)) {
        $s.SafeMode = [bool]$SafeMode
        Write-WHDLog -Message ('Safe mode {0}' -f $(if ($s.SafeMode) { 'ON - only Undo, re-apply, re-remove and restore points can be real' } else { 'OFF' }))
    }
    if ($null -ne $Execute -and $PSCmdlet.ShouldProcess('EXECUTE', [string]$Execute)) {
        if ($Execute -and -not $s.IsAdmin) { Write-WHDLog -Message 'EXECUTE needs an administrator window - staying in dry-run.' -Level 'WARN' }
        elseif ($Execute -and $s.JournalStop) { Write-WHDLog -Message 'EXECUTE stays off: the change history could not be written in this run. Start WHD again.' -Level 'WARN' }
        else {
            $s.Execute = [bool]$Execute
            Write-WHDLog -Message ('EXECUTE {0}' -f $(if ($s.Execute) { 'ON - changes are real (each one asks first)' } else { 'OFF - dry-run, nothing is changed' })) -Level $(if ($s.Execute) { 'ACT' } else { 'INFO' })
        }
    }
    return (Get-WHDSession)
}
