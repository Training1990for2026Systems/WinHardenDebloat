<#
================================================================================
 WHD Next  -  modules\TimeRegion.ps1   (Classic 1.4, 2026-09-30)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Time zone + date/time, the same settings as
   Settings > Time & language > Date & time  (Time zone / Set the date and time manually)

 User decisions 2026-09-30:
   - pick the time zone by hand: short list of US zones + search all Windows zones
   - set date/time by hand; automatic sync (time.cloudflare.com, 1 h jump limit) stays ON
   - reachable from the main menu (T) and from Firewall (Z)
   - Verify / update guard watch the time zone and re-apply puts it back (journal kind 'tz',
     engine function Set-WHDTimeZoneId in Common.ps1)
 No automatic time zone (that needs location on).
 Native only: Get-TimeZone / Set-TimeZone / Set-Date / w32tm. Reuses Common.ps1.
================================================================================
#>

# Short list (Windows time zone IDs). Hawaii has no daylight saving time.
$script:WHDTzShort = @(
    [ordered]@{ Id = 'Hawaiian Standard Time';  Name = 'Hawaii (Honolulu)' }
    [ordered]@{ Id = 'Alaskan Standard Time';   Name = 'Alaska (Anchorage)' }
    [ordered]@{ Id = 'Pacific Standard Time';   Name = 'Pacific (Los Angeles, Seattle)' }
    [ordered]@{ Id = 'US Mountain Standard Time'; Name = 'Arizona (Phoenix, no daylight saving)' }
    [ordered]@{ Id = 'Mountain Standard Time';  Name = 'Mountain (Denver)' }
    [ordered]@{ Id = 'Central Standard Time';   Name = 'Central (Chicago)' }
    [ordered]@{ Id = 'Eastern Standard Time';   Name = 'Eastern (New York)' }
)

function Get-WHDTimeSnapshot {
    $tz = Get-TimeZone
    $now = Get-Date
    [pscustomobject]@{
        ZoneId   = "$($tz.Id)"
        ZoneName = "$($tz.DisplayName)"
        Dst      = [bool]$tz.IsDaylightSavingTime($now)
        Local    = $now
        Utc      = $now.ToUniversalTime()
    }
}

function Show-WHDTimeRegionStatus {
    $s = Get-WHDTimeSnapshot
    Write-WHDLog ("Time zone   : {0}  ({1})" -f $s.ZoneId, $s.ZoneName) 'INFO'
    Write-WHDLog ("Local time  : {0:yyyy-MM-dd HH:mm:ss}{1}" -f $s.Local, $(if ($s.Dst) { '  (daylight saving time now)' } else { '' })) 'INFO'
    Write-WHDLog ("UTC time    : {0:yyyy-MM-dd HH:mm:ss}" -f $s.Utc) 'INFO'
    $src = Invoke-WHDNative -Exe 'w32tm.exe' -ArgList @('/query', '/source')
    Write-WHDLog ("Time source : {0}" -f (($src.Out | Where-Object { "$_".Trim() }) -join ' ')) 'INFO'
    $q = Invoke-WHDNative -Exe 'w32tm.exe' -ArgList @('/query', '/status')
    foreach ($l in @($q.Out | Where-Object { "$_" -match '^(Last Successful Sync Time|Source|Poll Interval):' })) { Write-WHDLog ("  {0}" -f "$l".Trim()) 'INFO' }
}

# Shows one numbered list of zones; returns the chosen ID or $null.
function _WHDPickFromZones {
    param([object[]]$Zones)
    if (-not $Zones.Count) { Write-Host '  no matching time zone.' -ForegroundColor Yellow; return $null }
    $i = 0
    foreach ($z in $Zones) { $i++; Write-Host ("  {0,3}. {1,-34} {2}" -f $i, $z.Id, $z.Label) }
    $a = (Read-Host '  Number (Enter = cancel)').Trim()
    if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $Zones.Count) { return "$($Zones[[int]$a - 1].Id)" }
    return $null
}

function Invoke-WHDPickTimeZone {
    Write-WHDLog 'TIME ZONE: pick by hand' 'ACT'
    $cur = Get-WHDTimeSnapshot
    Write-Host ("  Now: {0}  ({1:yyyy-MM-dd HH:mm})" -f $cur.ZoneId, $cur.Local)
    Write-Host ''
    $all = @(Get-TimeZone -ListAvailable)
    $short = @(foreach ($s in $script:WHDTzShort) {
        $z = @($all | Where-Object { $_.Id -eq $s.Id })[0]
        if ($z) { [pscustomobject]@{ Id = $z.Id; Label = ("{0}  {1}" -f $s.Name, $z.DisplayName.Split(')')[0] + ')') } }
    })
    Write-Host '  Common US time zones:'
    $i = 0
    foreach ($z in $short) { $i++; Write-Host ("  {0,3}. {1}" -f $i, $z.Label) }
    Write-Host '    S. Search all Windows time zones (city, country or name)'
    Write-Host '    B. Back'
    $a = (Read-Host '  Select').Trim()
    $pick = $null
    if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $short.Count) { $pick = $short[[int]$a - 1].Id }
    elseif ($a -match '^[Ss]$') {
        $q = (Read-Host '  Search text (e.g. Tokyo, London, Hawaii)').Trim()
        if (-not $q) { return }
        $hits = @($all | Where-Object { $_.Id -like "*$q*" -or $_.DisplayName -like "*$q*" -or $_.StandardName -like "*$q*" } |
                  ForEach-Object { [pscustomobject]@{ Id = $_.Id; Label = $_.DisplayName } })
        $pick = _WHDPickFromZones -Zones $hits
    }
    if (-not $pick) { Write-WHDLog 'no time zone chosen.' 'INFO'; return }
    if ($pick -eq $cur.ZoneId) { Write-WHDLog ("time zone already {0} - nothing to change." -f $pick) 'OK'; return }
    Write-WHDRisk 'reversible' ("Time zone {0} -> {1}. The clock shows the new local time at once; UTC does not change. Journaled: Undo center puts the old zone back, and Verify / the update guard put this one back if something changes it." -f $cur.ZoneId, $pick)
    if (-not (Confirm-WHDProceed ("set the time zone to {0}" -f $pick))) { Write-WHDLog 'skipped.' 'WARN'; return }
    Set-WHDTimeZoneId -Id $pick
    if ($script:WHDExecute) { Show-WHDTimeRegionStatus }
}

function Invoke-WHDSetDateTimeManual {
    Write-WHDLog 'DATE / TIME: set by hand' 'ACT'
    $cur = Get-WHDTimeSnapshot
    Write-Host ("  Now: {0:yyyy-MM-dd HH:mm:ss}  ({1})" -f $cur.Local, $cur.ZoneId)
    Write-Host '  Type the correct LOCAL date and time for this time zone.'
    $txt = (Read-Host '  New date/time as yyyy-MM-dd HH:mm (Enter = cancel)').Trim()
    if (-not $txt) { return }
    $dt = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($txt, 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dt)) {
        Write-Host '  not understood - use e.g. 2026-09-30 17:45' -ForegroundColor Yellow; return
    }
    Set-WHDDateTimeManual -Date $dt
}

# Core (console + GUI): explains the effect, asks once, journals as 'action' (manual undo - the clock keeps running).
function Set-WHDDateTimeManual {
    param([Parameter(Mandatory)][datetime]$Date)
    $cur = Get-WHDTimeSnapshot
    $dt = $Date
    $diff = $dt - (Get-Date)
    $absMin = [math]::Abs($diff.TotalMinutes)
    Write-WHDLog ("Clock change: {0}{1:N1} minutes" -f $(if ($diff.TotalMinutes -ge 0) { '+' } else { '-' }), $absMin) 'INFO'
    $note = if ($absMin -lt 60) {
        'Automatic time sync stays on: a difference of under 1 hour from the real time is corrected back at the next sync.'
    } else {
        'Automatic time sync stays on: if the clock is set further from the real time than the correction Windows allows (1 hour after WHD''s time-sync option, Firewall T; otherwise the Windows default of 15 hours), sync will NOT move it back and the time you type stays - make sure it is right.'
    }
    Write-WHDRisk 'caution' ("Sets the PC clock. {0} To return to network time: Firewall S shows the source; 'w32tm /resync' or Settings > Date & time > Sync now." -f $note)
    if (-not (Confirm-WHDProceed ("set the clock to {0:yyyy-MM-dd HH:mm}" -f $dt))) { Write-WHDLog 'skipped.' 'WARN'; return }
    $sdNew = $dt; $sdOld = $cur.Local
    $jr = @{ Kind = 'action'; OldTime = $sdOld.ToString('yyyy-MM-dd HH:mm:ss'); NewTime = $sdNew.ToString('yyyy-MM-dd HH:mm:ss')
             Hint = 'the clock keeps running - set it again by hand, or Settings > Date & time > Sync now' }
    Invoke-WHDChange -Description ("set date/time {0:yyyy-MM-dd HH:mm} -> {1:yyyy-MM-dd HH:mm}" -f $sdOld, $sdNew) -Force -Journal $jr -Action {
        Set-Date -Date $sdNew -EA Stop | Out-Null
    } | Out-Null
    if ($script:WHDExecute) { Show-WHDTimeRegionStatus }
}

# GUI list: the short US list first, then every Windows time zone. Items have Id + Label.
function Get-WHDTimeZoneChoices {
    $all = @(Get-TimeZone -ListAvailable)
    $short = @(foreach ($s in $script:WHDTzShort) {
        $z = @($all | Where-Object { $_.Id -eq $s.Id })[0]
        if ($z) { [pscustomobject]@{ Id = $z.Id; Label = ("* {0}" -f $s.Name) } }
    })
    $rest = @($all | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Label = $_.DisplayName } })
    @($short) + @($rest)
}

function Show-WHDTimeRegionMenu {
    $s = Get-WHDTimeSnapshot
    Write-Host ''
    Write-Host '  ================= TIME & REGION =================' -ForegroundColor White
    Write-Host ("  Time zone: {0}    Local: {1:yyyy-MM-dd HH:mm}    UTC: {2:HH:mm}" -f $s.ZoneId, $s.Local, $s.Utc) -ForegroundColor DarkGray
    Write-Host '   1. Pick time zone        (short list of US zones + search all)'
    Write-Host '   2. Set date and time by hand'
    Write-Host '   S. Status (zone, local/UTC time, time source, last sync)'
    Write-Host '   B. Back'
}

function Invoke-WHDTimeRegionSubmenu {
    while ($true) {
        Show-WHDMode
        Show-WHDTimeRegionMenu
        $c = (Read-Host '  Select').Trim()
        if (Invoke-WHDGuardHotkey $c) { continue }
        switch -regex ($c) {
            '^1$'    { Invoke-WHDPickTimeZone }
            '^2$'    { Invoke-WHDSetDateTimeManual }
            '^[Ss]$' { Show-WHDTimeRegionStatus }
            '^[Bb]$' { return }
            default  { Write-Host '  invalid.' -ForegroundColor Yellow }
        }
    }
}

Write-WHDLog 'TimeRegion.ps1 loaded.' 'INFO'
