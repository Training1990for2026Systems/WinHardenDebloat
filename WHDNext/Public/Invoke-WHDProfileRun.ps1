#requires -Version 7.6
<#
 WHD Next 3.0  -  Public/Invoke-WHDProfileRun.ps1   (the Profiles step, D97)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 WHD.ps1 -Profile <name>: applies one profile (minimum, average, strict, your
 own, or a .json path). Dry-run unless the session has EXECUTE on; then one
 question first (Features\Profiles.ps1).
#>
function Invoke-WHDProfileRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    Invoke-WHDProfile -Name $Name
}
