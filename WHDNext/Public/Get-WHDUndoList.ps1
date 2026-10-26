#requires -Version 7.6
<#
 WHD Next 3.0  -  Public/Get-WHDUndoList.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 The recorded changes that can be looked at in the Undo center (read-only).
   -Session <stamp>   one session (default: every session of this PC)
   -IncludeUndone     also the ones already undone
 UndoMode: auto | manual (with a hint) | later (comes with a step 5 module).
#>
function Get-WHDUndoList {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string]$Session, [switch]$IncludeUndone)
    $sessions = @(Get-WHDHistorySession | Where-Object { -not $Session -or $_.Stamp -eq $Session })
    $out = foreach ($s in $sessions) {
        foreach ($e in Get-WHDHistoryEntry -SessionPath $s.Path -Source $s.Source) {
            if ($e['Undone'] -and -not $IncludeUndone) { continue }
            [pscustomobject]@{
                Session = [string]$e['Session']; Seq = [int]$e['Seq']; Id = [string]$e['Id']; Kind = [string]$e['Kind']
                UndoMode = [string]$e['UndoMode']; Undone = [bool]$e['Undone']; Description = [string]$e['Description']
                Hint = $(if ($e['UndoMode'] -ne 'auto') { Get-WHDUndoHint -Entry $e } else { '' }); Source = [string]$e['Source']
            }
        }
    }
    return @($out | Sort-Object Session, Seq -Descending)
}
