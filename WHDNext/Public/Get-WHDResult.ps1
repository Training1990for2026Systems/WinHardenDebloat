#requires -Version 7.6
<#
 WHD Next 3.0  -  Public/Get-WHDResult.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 Every planned / done / failed / skipped change of this session. Read-only.
#>
function Get-WHDResult {
    [CmdletBinding()]
    param()
    $script:WHDState.Results.ToArray()
}
