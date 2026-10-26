#requires -Version 7.6
<#
 WHD Next 3.0  -  Public/New-WHDCheckpoint.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 A System Restore point on request. Allowed in safe mode (it only protects).
 Dry-run: says what it would do.
#>
function New-WHDCheckpoint {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not $PSCmdlet.ShouldProcess('System Restore point')) { return }
    Invoke-WHDSafeAllowed -Do {
        if (-not (Test-WHDRealChange)) { Write-WHDLog -Message 'would: create a System Restore point now' -Level 'DRY'; return }
        New-WHDRestorePoint -Again
    }
}
