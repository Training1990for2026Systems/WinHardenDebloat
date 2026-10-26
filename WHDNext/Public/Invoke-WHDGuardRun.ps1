#requires -Version 7.6
<#
 WHD Next 3.0  -  Public/Invoke-WHDGuardRun.ps1   (build step 7)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 WHD.ps1 -Guard: the update guard's scheduled check (read-only). $true = it
 ran (OK or ALERT); $false = it stopped on an error (written to
 restore\update-guard\guard-errors.txt) - the 5.1 front door then alerts.
#>
function Invoke-WHDGuardRun {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try {
        [void](Invoke-WHDGuardCheck)
        return $true
    } catch {
        $msg = $_.Exception.Message
        Write-WHDLog -Message ('UPDATE GUARD: the check stopped on an error: {0}' -f $msg) -Level 'ERR'
        try {
            $d = Get-WHDGuardDataDir
            if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop) }
            Add-Content -LiteralPath (Join-Path $d 'guard-errors.txt') -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding utf8 -ErrorAction Stop
        } catch { Write-Verbose $_.Exception.Message }
        return $false
    }
}
