#requires -Version 7.6
<#
 WHD Next 3.0  -  Public/Get-WHDSession.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 Read-only view of the running session (mode, counts, files, journal stop).
#>
function Get-WHDSession {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $s = $script:WHDState
    [pscustomobject]@{
        Stamp = $s.Stamp; Mode = (Get-WHDModeText); Execute = $s.Execute; SafeMode = $s.SafeMode; IsAdmin = $s.IsAdmin
        RestoreDone = $s.RestoreDone; Stopped = [bool]$s.JournalStop
        Planned = $s.Counts.planned; Done = $s.Counts.done; Failed = $s.Counts.failed; Skipped = $s.Counts.skipped
        LogFile = $s.LogFile; RestoreFolder = (Get-WHDRestoreFolder)
    }
}
