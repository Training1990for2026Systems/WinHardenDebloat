#requires -Version 7.6
<#
 WHD Next 3.0  -  Public/Update-WHDGuardRefresh.ps1   (build step 7, D90)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 When WHD starts (administrator, guard installed, not safe mode): refreshes
 the guard's locked copy by itself if WHD's files changed. Not recorded -
 the install was. Never stops WHD.
#>
function Update-WHDGuardRefresh {
    [CmdletBinding()]
    param()
    Update-WHDGuardIfStale
}
