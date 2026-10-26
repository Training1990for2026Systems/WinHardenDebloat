#requires -Version 7.6
<#
================================================================================
 WHD Next 3.0  -  Features/TimeRegion.ps1   (time zone, date and time)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Same features as WHD Next 2.0 (D8), rewritten for PowerShell 7.6. Build step
 5.8. The settings of Settings > Time & language > Date & time:
   1  pick the time zone by hand - short list of US zones (Hawaii first) or
      search every Windows zone; recorded as kind 'tz' (Undo puts the old zone
      back; Verify / the update guard watch it)
   2  set the date and time by hand - automatic time sync stays ON
      (time.cloudflare.com with the 1 h jump limit after Firewall T)
   ST status - zone, local / UTC time, time source, last sync (D52; S = safe mode)
 Reached with WHD.ps1 -Menu TimeRegion and from Z in the Firewall menu (D53).
 No automatic time zone (that needs location on). Windows' own commands only:
 Get-TimeZone, Set-TimeZone (engine Set-WHDTimeZoneId), Set-Date, w32tm.
================================================================================
#>

# Short list (Windows time zone IDs). Hawaii has no daylight saving time.
$script:WHDTzShort = @(
    [pscustomobject]@{ Id = 'Hawaiian Standard Time'; Name = 'Hawaii (Honolulu)' }
    [pscustomobject]@{ Id = 'Alaskan Standard Time'; Name = 'Alaska (Anchorage)' }
    [pscustomobject]@{ Id = 'Pacific Standard Time'; Name = 'Pacific (Los Angeles, Seattle)' }
    [pscustomobject]@{ Id = 'US Mountain Standard Time'; Name = 'Arizona (Phoenix, no daylight saving)' }
    [pscustomobject]@{ Id = 'Mountain Standard Time'; Name = 'Mountain (Denver)' }
    [pscustomobject]@{ Id = 'Central Standard Time'; Name = 'Central (Chicago)' }
    [pscustomobject]@{ Id = 'Eastern Standard Time'; Name = 'Eastern (New York)' }
)

function Get-WHDTimeSnapshot {
    [CmdletBinding()]
    param()
    $tz = Get-TimeZone
    $now = Get-Date
    return [pscustomobject]@{ ZoneId = [string]$tz.Id; ZoneName = [string]$tz.DisplayName; Dst = [bool]$tz.IsDaylightSavingTime($now); Local = $now; Utc = $now.ToUniversalTime() }
}

function Get-WHDTimeZoneList {
    # Every Windows time zone (thin wrapper - tests replace it).
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return @(Get-TimeZone -ListAvailable)
}

function Show-WHDTimeRegionStatus {
    [CmdletBinding()]
    param()
    $s = Get-WHDTimeSnapshot
    Write-WHDLog -Message ('Time zone   : {0}  ({1})' -f $s.ZoneId, $s.ZoneName)
    Write-WHDLog -Message ('Local time  : {0:yyyy-MM-dd HH:mm:ss}{1}' -f $s.Local, $(if ($s.Dst) { '  (daylight saving time now)' } else { '' }))
    Write-WHDLog -Message ('UTC time    : {0:yyyy-MM-dd HH:mm:ss}' -f $s.Utc)
    $src = Invoke-WHDNative -Exe 'w32tm.exe' -ArgList @('/query', '/source')
    Write-WHDLog -Message ('Time source : {0}' -f ((@($src.Out | Where-Object { ([string]$_).Trim() }) -join ' ').Trim()))
    $q = Invoke-WHDNative -Exe 'w32tm.exe' -ArgList @('/query', '/status')
    foreach ($l in @($q.Out | Where-Object { [string]$_ -match '^(Last Successful Sync Time|Source|Poll Interval):' })) { Write-WHDLog -Message ('  {0}' -f ([string]$l).Trim()) }
}

function Get-WHDAnswerReader {
    # The follow-up answers of one menu item: -Answer (tests, scripted runs) or Read-Host.
    [CmdletBinding()]
    param([string[]]$Answer)
    $q = [System.Collections.Generic.Queue[string]]::new()
    foreach ($a in @($Answer)) { if ($null -ne $a) { $q.Enqueue([string]$a) } }
    $scripted = $null -ne $Answer
    return { param($prompt) if ($scripted) { if ($q.Count) { return $q.Dequeue() }; return '' }; return [string](Read-Host $prompt) }.GetNewClosure()
}

function Invoke-WHDPickTimeZone {
    # 1: short list or search; one question; engine Set-WHDTimeZoneId records kind 'tz'.
    [CmdletBinding()]
    param([string[]]$Answer)
    $ask = Get-WHDAnswerReader -Answer $Answer
    Write-WHDLog -Message 'TIME ZONE: pick by hand' -Level 'ACT'
    $cur = Get-WHDTimeSnapshot
    Write-Host ('  Now: {0}  ({1:yyyy-MM-dd HH:mm})' -f $cur.ZoneId, $cur.Local)
    $all = @(Get-WHDTimeZoneList)
    $short = @(foreach ($s in $script:WHDTzShort) {
            $z = $all | Where-Object { $_.Id -eq $s.Id } | Select-Object -First 1   # a zone this Windows does not have is left out
            if ($z) { [pscustomobject]@{ Id = [string]$z.Id; Label = ('{0}  {1}' -f $s.Name, ([string]$z.DisplayName).Split(')')[0] + ')') } }
        })
    Write-Host '  Common US time zones:'
    for ($i = 0; $i -lt $short.Count; $i++) { Write-Host ('  {0,3}. {1}' -f ($i + 1), $short[$i].Label) }
    Write-Host '    S. Search all Windows time zones (city, country or name)'
    Write-Host '    B. Back'
    $a = ([string](& $ask '  Select')).Trim()
    $pick = $null
    if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $short.Count) { $pick = $short[[int]$a - 1].Id }
    elseif ($a -match '^[Ss]$') {
        $q = ([string](& $ask '  Search text (e.g. Tokyo, London, Hawaii)')).Trim()
        if (-not $q) { return }
        $hits = @($all | Where-Object { [string]$_.Id -like "*$q*" -or [string]$_.DisplayName -like "*$q*" -or [string]$_.StandardName -like "*$q*" })
        if (-not $hits.Count) { Write-Host '  no matching time zone.' -ForegroundColor Yellow; return }
        for ($i = 0; $i -lt $hits.Count; $i++) { Write-Host ('  {0,3}. {1,-34} {2}' -f ($i + 1), $hits[$i].Id, $hits[$i].DisplayName) }
        $n = ([string](& $ask '  Number (Enter = cancel)')).Trim()
        if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $hits.Count) { $pick = [string]$hits[[int]$n - 1].Id }
    }
    if (-not $pick) { Write-WHDLog -Message 'no time zone chosen.'; return }
    if ($pick -eq $cur.ZoneId) { Write-WHDLog -Message ('time zone already {0} - nothing to change.' -f $pick) -Level 'OK'; return }
    Write-WHDRisk -Tier 'reversible' -Text ('Time zone {0} -> {1}. The clock shows the new local time at once; UTC does not change. Recorded: the Undo center puts the old zone back, and Verify / the update guard report it if something changes it.' -f $cur.ZoneId, $pick)
    if (-not (Confirm-WHDProceed -What ('set the time zone to {0}' -f $pick))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    Set-WHDTimeZoneId -Id $pick | Out-Null
    if (Test-WHDRealChange) { Show-WHDTimeRegionStatus }
}

function Set-WHDDateTimeManual {
    # Explains the effect, asks once, records as 'action' (manual undo - the clock keeps running).
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][datetime]$Date)
    $cur = Get-WHDTimeSnapshot
    $diff = $Date - $cur.Local
    $absMin = [math]::Abs($diff.TotalMinutes)
    Write-WHDLog -Message ('Clock change: {0}{1:N1} minutes' -f $(if ($diff.TotalMinutes -ge 0) { '+' } else { '-' }), $absMin)
    $note = if ($absMin -lt 60) { 'Automatic time sync stays on: a difference of under 1 hour from the real time is corrected back at the next sync.' }
    else { 'Automatic time sync stays on: if the clock is set further from the real time than Windows allows it to correct (1 hour after Firewall T; otherwise Windows'' default of 15 hours), sync will NOT move it back and the time you type stays - make sure it is right.' }
    Write-WHDRisk -Tier 'caution' -Text ('Sets the PC clock. {0} Back to network time: ''w32tm /resync'' or Settings > Date & time > Sync now (Firewall TS shows the source).' -f $note)
    if (-not $PSCmdlet.ShouldProcess($Date.ToString('yyyy-MM-dd HH:mm'), 'set clock')) { return }
    if (-not (Confirm-WHDProceed -What ('set the clock to {0:yyyy-MM-dd HH:mm}' -f $Date))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    $sdNew = $Date; $sdOld = $cur.Local
    $jr = @{ Kind = 'action'; OldTime = $sdOld.ToString('yyyy-MM-dd HH:mm:ss'); NewTime = $sdNew.ToString('yyyy-MM-dd HH:mm:ss')
             Hint = 'the clock keeps running - set it again by hand, or Settings > Date & time > Sync now' }
    Invoke-WHDChange -Description ('set date/time {0:yyyy-MM-dd HH:mm} -> {1:yyyy-MM-dd HH:mm}' -f $sdOld, $sdNew) -Journal $jr -Action {
        Set-Date -Date $sdNew -ErrorAction Stop | Out-Null
    } | Out-Null
    if (Test-WHDRealChange) { Show-WHDTimeRegionStatus }
}

function Invoke-WHDSetDateTimeManual {
    [CmdletBinding()]
    param([string[]]$Answer)
    $ask = Get-WHDAnswerReader -Answer $Answer
    Write-WHDLog -Message 'DATE / TIME: set by hand' -Level 'ACT'
    $cur = Get-WHDTimeSnapshot
    Write-Host ('  Now: {0:yyyy-MM-dd HH:mm:ss}  ({1})' -f $cur.Local, $cur.ZoneId)
    Write-Host '  Type the correct LOCAL date and time for this time zone.'
    $txt = ([string](& $ask '  New date/time as yyyy-MM-dd HH:mm (Enter = cancel)')).Trim()
    if (-not $txt) { return }
    $dt = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($txt, 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dt)) {
        Write-Host '  not understood - use e.g. 2026-10-16 17:45' -ForegroundColor Yellow; return
    }
    Set-WHDDateTimeManual -Date $dt
}

# ---- menu -------------------------------------------------------------------------------------------
function Show-WHDTimeRegionMenu {
    [CmdletBinding()]
    param()
    $s = Get-WHDTimeSnapshot
    Write-Host ''
    Write-Host '  =============== TIME & REGION ===============' -ForegroundColor White
    Write-Host ('  Time zone: {0}    Local: {1:yyyy-MM-dd HH:mm}    UTC: {2:HH:mm}' -f $s.ZoneId, $s.Local, $s.Utc) -ForegroundColor DarkGray
    Write-WHDMenuItem -Key '1' -Label 'Pick time zone (short list of US zones + search all)'
    Write-WHDMenuItem -Key '2' -Label 'Set date and time by hand (automatic sync stays on)'
    Write-WHDMenuItem -Key 'ST' -Label 'Status (zone, local / UTC time, time source, last sync)' -Hint '(was S in WHD Next 2.0)'
    Write-WHDMenuCommonKey
}

function Invoke-WHDTimeRegionChoice {
    # One menu choice. Returns $false for B (back). -Answer feeds the follow-up questions (tests).
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Choice, [string[]]$Answer)
    $c = $Choice.Trim()
    if (Invoke-WHDMenuCommonKey -Choice $c) { return $true }
    switch -regex ($c) {
        '^[Bb]$' { return $false }
        '^1$' { Invoke-WHDPickTimeZone -Answer $Answer }
        '^2$' { Invoke-WHDSetDateTimeManual -Answer $Answer }
        '^[Ss][Tt]$' { Show-WHDTimeRegionStatus }
        default { Write-Host '  invalid.' -ForegroundColor Yellow }
    }
    return $true
}
