#requires -Version 7.6
<#
 WHD Next 3.0  -  Private/Settings.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 Small settings file settings.json in the data folder (PC-specific, never
 published). Holds the owner's answer to the first-start question about
 WHD Next 2.0's change history (D18).
#>
function Get-WHDSetting {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $f = Join-Path $script:WHDState.DataRoot 'settings.json'
    if (-not (Test-Path -LiteralPath $f)) { return @{} }
    try { return (Get-Content -LiteralPath $f -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable) } catch { return @{} }
}

function Save-WHDSetting {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Setting)
    $f = Join-Path $script:WHDState.DataRoot 'settings.json'
    $Setting | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $f -Encoding utf8 -ErrorAction Stop
}
