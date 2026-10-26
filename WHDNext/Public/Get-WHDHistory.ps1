#requires -Version 7.6
<#
 WHD Next 3.0  -  Public/Get-WHDHistory.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 The sessions of the change history (newest first), read-only.
 Source: own = this program, next2 = WHD Next 2.0 read in place (D18).
#>
function Get-WHDHistory {
    [CmdletBinding()]
    param([switch]$IncludeOtherPCs)
    Get-WHDHistorySession -IncludeOtherPCs:$IncludeOtherPCs
}
