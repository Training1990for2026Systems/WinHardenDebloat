#requires -Version 7.6
<#
 WHD Next 3.0  -  Private/Test-WHDEngine.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 Decides whether this PowerShell may run WHD Next: version 7.6 or newer, no
 pre-release label (preview, rc, ...), Core edition. Read-only, changes nothing.
#>
function Test-WHDEngine {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Management.Automation.SemanticVersion]$Version,
        [Parameter(Mandatory)][string]$Edition
    )
    $minimum = [System.Management.Automation.SemanticVersion]::new(7, 6, 0)
    $reason = $null
    if ($Edition -ne 'Core') {
        $reason = 'this is Windows PowerShell ({0} edition); WHD Next 3.0 needs PowerShell 7.6 or newer. Start it with Start-WHD.cmd.' -f $Edition
    }
    elseif (-not [string]::IsNullOrEmpty($Version.PreReleaseLabel)) {
        $reason = 'PowerShell {0} is a pre-release build; WHD Next 3.0 runs only on a stable version (7.6 or newer).' -f $Version
    }
    elseif ($Version -lt $minimum) {
        $reason = 'PowerShell {0} is older than 7.6; WHD Next 3.0 needs 7.6 or newer.' -f $Version
    }
    [pscustomobject]@{
        Ok      = ($null -eq $reason)
        Version = $Version.ToString()
        Edition = $Edition
        Reason  = $reason
    }
}
