#requires -Version 7.6
<#
 WHD Next 3.0  -  Public/Invoke-WHDHistoryTakeover.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 D4 + D18: at the first start, ask once how to take over WHD Next 2.0's change
 history - C = copy it once into this program's restore\, R = read it in place
 (read-only) every time. WHD Next 2.0's folder is never changed (D12). The
 answer is kept in settings.json; later starts do not ask again.
 -Choice Copy|InPlace and -Source answer without asking (tests, scripted runs).
#>
function Invoke-WHDHistoryTakeover {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([ValidateSet('Copy', 'InPlace')][string]$Choice, [string]$Source)
    $set = Get-WHDSetting
    if ($set['NextHistory']) {
        $nh = $set['NextHistory']
        Write-WHDLog -Message ('WHD Next 2.0 history: {0} ({1}, decided {2})' -f $(if ($nh['Mode'] -eq 'copy') { 'copied' } else { 'read in place' }), $nh['Source'], $nh['Decided']) -FileOnly
        return $nh
    }
    $found = @(Find-WHDNext2History)
    if ($Source) { $found = @($found | Where-Object { [IO.Path]::GetFullPath($_.Path) -eq [IO.Path]::GetFullPath($Source) }) }
    if (-not $found.Count) { Write-WHDLog -Message 'No WHD Next 2.0 change history found - nothing to take over.'; return $null }

    Write-Host ''
    Write-Host '  WHD Next 2.0 change history found' -ForegroundColor Cyan
    for ($i = 0; $i -lt $found.Count; $i++) { Write-Host ('   {0}. {1}   ({2} sessions, {3} changes)' -f ($i + 1), $found[$i].Path, $found[$i].Sessions, $found[$i].Entries) }
    $pick = $found[0]
    if ($found.Count -gt 1 -and -not $Source) {
        do { $n = [string](Read-Host ('  Which one is WHD Next 2.0''s history? 1-{0}' -f $found.Count)) } until ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $found.Count)
        $pick = $found[[int]$n - 1]
    }
    if (-not $Choice) {
        Write-Host ''
        Write-Host '  WHD Next 3.0 takes over this history, so Verify and Undo know the changes WHD Next 2.0 made.' -ForegroundColor Gray
        Write-Host '  WHD Next 2.0''s folder is only read, never changed. You are asked this once.' -ForegroundColor Gray
        Write-Host '   C = copy it once into this program (changes Next 2.0 makes later are not seen)' -ForegroundColor White
        Write-Host '   R = read it in place every time (Next 2.0''s folder must stay where it is)' -ForegroundColor White
        do { $a = ([string](Read-Host '  Choice C / R')).Trim().ToUpperInvariant() } until ($a -in 'C', 'R')
        $Choice = if ($a -eq 'C') { 'Copy' } else { 'InPlace' }
    }
    $rec = @{ Mode = $(if ($Choice -eq 'Copy') { 'copy' } else { 'inplace' }); Source = $pick.Path; Decided = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Sessions = $pick.Sessions; Entries = $pick.Entries }
    if ($Choice -eq 'Copy') {
        if (-not $PSCmdlet.ShouldProcess($pick.Path, 'copy WHD Next 2.0 history')) { return $null }
        try {
            $c = Copy-WHDNext2History -Source $pick.Path
            $rec['Copied'] = $c.Copied; $rec['AlreadyHere'] = $c.AlreadyHere
            # check: every copied session has the same files with the same sizes as the source
            $bad = 0
            foreach ($d in Get-ChildItem -LiteralPath $pick.Path -Directory | Where-Object { $_.Name -match $script:WHDSessionPattern }) {
                $to = Join-Path (Join-Path $script:WHDState.DataRoot 'restore') $d.Name
                foreach ($f in Get-ChildItem -LiteralPath $d.FullName -File -Recurse) {
                    $t = Join-Path $to ([IO.Path]::GetRelativePath($d.FullName, $f.FullName))
                    if (-not (Test-Path -LiteralPath $t) -or (Get-Item -LiteralPath $t).Length -ne $f.Length) { $bad++ }
                }
            }
            if ($bad) { throw ('{0} file(s) differ after copying' -f $bad) }
            Write-WHDLog -Message ('WHD Next 2.0 history copied: {0} session(s) copied, {1} already here, all files checked.' -f $c.Copied, $c.AlreadyHere) -Level 'OK'
        } catch {
            Write-WHDLog -Message ('Copying WHD Next 2.0 history failed: {0} - nothing is saved, you are asked again next time.' -f $_.Exception.Message) -Level 'ERR'
            return $null
        }
    } else {
        Write-WHDLog -Message ('WHD Next 2.0 history will be read in place: {0}' -f $pick.Path) -Level 'OK'
    }
    $set['NextHistory'] = $rec
    Save-WHDSetting -Setting $set
    return $rec
}
