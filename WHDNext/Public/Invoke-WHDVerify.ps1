#requires -Version 7.6
<#
 WHD Next 3.0  -  Public/Invoke-WHDVerify.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 Verify (read-only, every mode): are the recorded changes still in place?
   -All          every session of this PC (own + WHD Next 2.0's, D18), latest state per item
   -SessionPath  one session folder
 On screen only what is not PASS (and the summary); the log file gets every line.
#>
function Invoke-WHDVerify {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([switch]$All, [string]$SessionPath, [switch]$ShowAll)
    if ($All) {
        $sessions = @(Get-WHDHistorySession | Sort-Object Stamp)
        $entries = @(foreach ($s in $sessions) { Get-WHDHistoryEntry -SessionPath $s.Path -Source $s.Source })
        $label = 'all sessions of this PC ({0}; latest state per item)' -f $sessions.Count
        $hidden = @(Get-WHDHistorySession -IncludeOtherPCs | Where-Object { $_.Owner -in 'other', 'legacy-other' }).Count
        if ($hidden) { Write-WHDLog -Message ('{0} session(s) from another PC / an earlier Windows install are not checked.' -f $hidden) }
    } elseif ($SessionPath) {
        $entries = @(Get-WHDHistoryEntry -SessionPath $SessionPath)
        $label = Split-Path $SessionPath -Leaf
    } else { throw 'Invoke-WHDVerify: give -All or -SessionPath' }
    $items = @(Select-WHDVerifyItem -Entries $entries)
    Write-WHDLog -Message ('VERIFY: {0} - {1} item(s) to check' -f $label, $items.Count) -Level 'ACT'
    $res = foreach ($e in $items) {
        $r = Test-WHDJournalEntry -Entry $e
        if ($r.Result -ne 'PASS' -and (Test-WHDUserChoice -Entry $e)) { $r.Result = 'n/a'; $r.Now = '{0}  (your choice - off but not locked)' -f $r.Now }
        $lvl = switch ($r.Result) { 'PASS' { 'OK' } 'n/a' { 'INFO' } default { 'WARN' } }
        Write-WHDLog -Message ('{0,-8} {1}   now: {2}' -f $r.Result, $r.Target, $r.Now) -Level $lvl -FileOnly:($r.Result -eq 'PASS' -and -not $ShowAll)
        $r
    }
    $res = @($res)
    $pass = @($res | Where-Object Result -eq 'PASS').Count
    $bad = @($res | Where-Object { $_.Result -in 'CHANGED', 'RETURNED' }).Count
    $na = @($res | Where-Object Result -eq 'n/a').Count
    Write-WHDLog -Message ('VERIFY summary: {0} pass, {1} changed / returned since applied, {2} not checkable' -f $pass, $bad, $na) -Level $(if ($bad) { 'WARN' } else { 'OK' })
    return $res
}
