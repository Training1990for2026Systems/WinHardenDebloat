#requires -Version 7.6
<#
 WHD Next 3.0  -  Public/Get-WHDEngineInfo.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 Shows which WHD Next and which PowerShell are running. Read-only.
#>
function Get-WHDEngineInfo {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'WHDNext.psd1')
    $label = $manifest.PrivateData.PSData['Prerelease']      # by key: a release has none (strict mode, D99)
    $check = Test-WHDEngine -Version $PSVersionTable.PSVersion -Edition $PSVersionTable.PSEdition
    [pscustomobject]@{
        Product       = 'WHD Next'
        Version       = if ($label) { '{0}-{1}' -f $manifest.ModuleVersion, $label } else { $manifest.ModuleVersion }
        PowerShell    = $PSVersionTable.PSVersion.ToString()
        Edition       = $PSVersionTable.PSEdition
        EngineAllowed = $check.Ok
    }
}
