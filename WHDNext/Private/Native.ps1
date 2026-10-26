#requires -Version 7.6
<#
 WHD Next 3.0  -  Private/Native.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 Runs a Windows program (sc.exe, auditpol.exe, net.exe, netsh.exe, reg.exe) and
 returns its exit code and output lines. Programs that write success text to
 the error stream (reg.exe does) are judged by the exit code only.
#>
function Invoke-WHDNative {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Exe, [string[]]$ArgList = @())
    try {
        $out = @(& $Exe @ArgList 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
    } catch {
        return [pscustomobject]@{ Code = 1; Out = @([string]$_.Exception.Message) }
    }
}
