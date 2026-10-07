<#
================================================================================
 WinHardenDebloat  -  modules\Updates.ps1   (v1.1: stop auto-installs)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Goal (user, 2026-09-27): a freshly re-imaged PC can go online WITHOUT Windows'
 background installers (Windows Update, Microsoft Store, Device Setup /
 drivers + manufacturer apps, app self-updaters) running. Updates come in only
 AFTER the baseline, when the owner opens the update gate.

 Parts (all user-chosen):
   1. UPDATE GATE (firewall), three positions:
      CLOSED   - outbound default-deny; HTTP/HTTPS only for Microsoft Defender
                 (engine, network inspection, core service, command-line
                 updater, SmartScreen) + DNS-over-HTTPS; the any-program
                 HTTP/HTTPS allows and every other enabled outbound ALLOW rule
                 (Windows' built-in app rules and the per-program allows
                 included) are switched off and remembered.
      PROGRAMS - like CLOSED, but the programs allowed in Firewall menu V
                 (group WinHardenDebloat-AppAllow) stay on. Windows Update and
                 the Store stay off.
      OPEN     - everything put back. Stays open until you change it.
      v1.5: before the question the gate names the rules of other tools and
      programs it will switch off; an outbound rule you chose to keep
      (Firewall K) stays on. The Firewall-menu tools that change what the
      gate set (reset, wipe, .wfw import, DNS reset, remove program allows)
      say so in their own question, and Status / the menus tell when the
      gate is not what its record says (Get-WHDGateHealth).
   2. Windows Update policy NoAutoUpdate=1 (Microsoft documents it for Pro+;
      tried on Home - Status shows evidence whether Windows obeys it).
   3. Drivers: Device Installation Settings = No (+ manufacturer apps/icons off)
      and the "don't include drivers" policy (Pro+, tried on Home).
   4. Store: auto-update policy AutoDownload=2 (Pro+, tried on Home).
   5. App self-updaters (Edge Update + others): scan -> you confirm -> the
      scheduled tasks are disabled / services set to Disabled (journaled).
 Every registry/service/task change is journaled (Undo center, Verify, guard).
================================================================================
#>

$script:WHDFwGroupGate   = 'WinHardenDebloat-UpdateGate'
$script:WHDGateStateName = 'update-gate.json'

# ---- gate state (project folder, per PC) -------------------------------------
function _WHDGateStateFile {
    # Reading the state does not create the folder (the firewall screen shows the gate position on every
    # draw, also in DRY-RUN); the folder is made when the state is saved (-Create).
    param([switch]$Create)
    $d = Join-Path $script:WHDRoot 'restore\update-guard'
    if ($Create -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Join-Path $d $script:WHDGateStateName
}
function Get-WHDGateState {
    $f = _WHDGateStateFile
    $s = $null
    if (Test-Path -LiteralPath $f) { try { $s = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    if ($s -and "$($s.MachineId)" -and "$($s.MachineId)" -ne (Get-WHDMachineId)) { $s = $null }   # another PC's file
    $out = @(Get-WHDFwProfiles | ForEach-Object { "$($_.DefaultOutboundAction)" }) -join ','
    # Closed = the gate recorded "closed" on THIS PC and outbound is still Block.
    # (Rule states are not used: rebuilding the allow-list briefly re-creates the
    # HTTPS rule, and it must still see the gate as closed to switch it off again.)
    $closed = [bool]($s -and $s.Closed) -and ($out -notmatch 'Allow|NotConfigured')
    # Mode: open | programs | closed. "Closed" stays true for PROGRAMS too (not open: the any-program
    # web rules stay off). A state file written before the PROGRAMS position existed has no Mode = closed.
    $mode = 'open'
    if ($closed) { if ("$($s.Mode)" -eq 'programs') { $mode = 'programs' } else { $mode = 'closed' } }
    # v1.5: what the saved file says, whatever outbound is now (open | programs | closed). When this is not
    # 'open' while Closed is $false, something else set outbound back to Allow (see Get-WHDGateHealth).
    $recorded = 'open'
    if ($s -and $s.Closed) { if ("$($s.Mode)" -eq 'programs') { $recorded = 'programs' } else { $recorded = 'closed' } }
    [pscustomobject]@{
        Closed   = $closed
        Mode     = $mode
        Recorded = $recorded
        Outbound = $out
        Since    = $(if ($s) { "$($s.Changed)" } else { '' })
        Disabled = @(if ($s -and $s.DisabledRules) { $s.DisabledRules })
        PrevOutbound = $(if ($s) { "$($s.PrevOutbound)" } else { 'Allow' })
        Text     = ($mode.ToUpper() + $(if ($s -and $s.Changed) { " since $($s.Changed)" } else { '' }))
    }
}
function Test-WHDGateClosed { (Get-WHDGateState).Closed }
function _WHDSaveGateState {
    param([bool]$Closed, [string[]]$DisabledRules, [string]$PrevOutbound, [string]$Mode, [string]$Changed)
    if (-not $Mode)    { if ($Closed) { $Mode = 'closed' } else { $Mode = 'open' } }
    if (-not $Changed) { $Changed = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
    $o = [ordered]@{ MachineId = (Get-WHDMachineId); Computer = $env:COMPUTERNAME; Closed = $Closed; Mode = $Mode
                     Changed = $Changed; PrevOutbound = $PrevOutbound; DisabledRules = @($DisabledRules) }
    ([pscustomobject]$o | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath (_WHDGateStateFile -Create) -Encoding UTF8
}
# Add rule names to the list the gate switches back on when it opens (used when a per-program allow is
# made while the gate is CLOSED). Keeps the position and its date. Does nothing while the gate is open.
function Add-WHDGateRemembered {
    param([string[]]$Names)
    $st = Get-WHDGateState
    if (-not $st.Closed) { return }
    $all = @(@($st.Disabled) + @($Names) | Where-Object { $_ } | Select-Object -Unique)
    _WHDSaveGateState -Closed $true -Mode $st.Mode -DisabledRules $all -PrevOutbound $st.PrevOutbound -Changed $st.Since
}

# Defender's current platform folder (changes when Defender updates itself).
function Get-WHDDefenderPlatformDir {
    try {
        $p = "$((Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows Defender' -Name InstallLocation -EA Stop).InstallLocation)"
        if ($p -and (Test-Path -LiteralPath (Join-Path $p 'MsMpEng.exe'))) { return $p.TrimEnd('\') }
    } catch {}
    $base = Join-Path $env:ProgramData 'Microsoft\Windows Defender\Platform'
    $d = @(Get-ChildItem -LiteralPath $base -Directory -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1)
    if ($d.Count) { return $d[0].FullName }
    return $null
}
# The only HTTP/HTTPS traffic allowed while the gate is closed.
function Get-WHDGateAllowSpecs {
    $plat = Get-WHDDefenderPlatformDir
    $specs = @(
        @{ n='WHD-Gate-Defender';      d='WHD Gate: Microsoft Defender engine (WinDefend)';          svc='WinDefend' }
        @{ n='WHD-Gate-DefenderNis';   d='WHD Gate: Defender network inspection (WdNisSvc)';         svc='WdNisSvc' }
        @{ n='WHD-Gate-MpCmdRun';      d='WHD Gate: Defender updater (MpCmdRun, Program Files)';      prog=(Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe') }
        @{ n='WHD-Gate-SmartScreen';   d='WHD Gate: SmartScreen';                                     prog=(Join-Path $env:SystemRoot 'System32\smartscreen.exe') }
        @{ n='WHD-Gate-DoH';           d='WHD Gate: DNS over HTTPS (Dnscache) to the pinned resolver'; svc='Dnscache'; raddr=$script:WHDDnsServers; ports=@('443') }
    )
    if ($plat) {
        $specs += @{ n='WHD-Gate-MsMpEng';    d='WHD Gate: Defender engine (platform folder)';  prog=(Join-Path $plat 'MsMpEng.exe') }
        $specs += @{ n='WHD-Gate-MpCmdRunP';  d='WHD Gate: Defender updater (platform folder)'; prog=(Join-Path $plat 'MpCmdRun.exe') }
        # Program rule next to the service rule (WdNisSvc) for the same Defender part.
        $specs += @{ n='WHD-Gate-NisSrv';     d='WHD Gate: Defender network inspection (NisSrv.exe, platform folder)'; prog=(Join-Path $plat 'NisSrv.exe') }
        # Defender core service. Microsoft Learn ("Microsoft Defender Core service overview"): it delivers
        # Defender fixes/configuration and also collects Defender telemetry (owner decision: allowed).
        $specs += @{ n='WHD-Gate-MpCore';     d='WHD Gate: Defender core service (MpDefenderCoreService.exe, platform folder)'; prog=(Join-Path $plat 'MpDefenderCoreService.exe') }
    }
    $specs
}

# Switch one rule on / off by its EXACT name. (Set-NetFirewallRule -Name reads * ? [ ] in a name as a pattern, and
# the rules the gate switches belong to other programs: such a name is found by comparing - Get-WHDFwRuleExact.)
function _WHDGateSwitchRule {
    param([string]$Name, [bool]$On)
    $gsVal = 'False'; if ($On) { $gsVal = 'True' }
    if (-not "$Name") { return }
    if (Get-Command Get-WHDFwRuleExact -EA SilentlyContinue) {
        foreach ($gsR in @(Get-WHDFwRuleExact -Name $Name)) { $gsR | Set-NetFirewallRule -Enabled $gsVal -EA SilentlyContinue }
    } else { Set-NetFirewallRule -Name $Name -Enabled $gsVal -EA SilentlyContinue }
}

# ---- 1. the gate ---------------------------------------------------------------
function Close-WHDUpdateGate {
    # -Mode closed   : Defender + DNS-over-HTTPS only
    # -Mode programs : the same, plus the per-program allows (group WinHardenDebloat-AppAllow, Firewall menu V)
    # -Why        : said at the start of the question (used when WHD itself proposes to set the gate again)
    param([ValidateSet('closed','programs')][string]$Mode = 'closed', [string]$Why = '')
    $whdGateProg = ($Mode -eq 'programs')
    $whdGateApps = @(Get-NetFirewallRule -Group $script:WHDFwGroupApp -EA SilentlyContinue)
    # v1.5: which rules of other tools / programs the gate will switch off - shown BEFORE the question (read-only)
    $whdGatePre = $null
    try { $whdGatePre = Get-WHDGateOffCandidates -Programs:$whdGateProg } catch { $whdGatePre = $null }
    $whdGateLead = ''; if ("$Why") { $whdGateLead = "$Why - " }
    # v1.5: recorded as OPEN, but a firewall policy saved while the gate was closed came in (import / restore): outbound is
    # Block and the any-program web rules are off BECAUSE OF THAT GATE. Without this, setting the gate now would note
    # "outbound was Block before" and not remember the web rules - and a later OPEN would leave the PC without web.
    # Read here, before anything is rebuilt. The rules that gate had switched off are taken to be: WHD's two web rules
    # and your program allows that are off.
    $whdGateUnrec = $false; $whdGateUnrecNames = @()
    try {
        if ((Get-WHDGateHealth).Unrecorded) {
            $whdGateUnrec = $true
            $whdGateUnrecNames = @(@('WHD-Allow-HTTPS', 'WHD-Allow-HTTP') | Where-Object { @(Get-NetFirewallRule -Name $_ -EA SilentlyContinue | Where-Object { "$($_.Enabled)" -ne 'True' }).Count })
            $whdGateUnrecNames = @($whdGateUnrecNames) + @($whdGateApps | Where-Object { "$($_.Enabled)" -ne 'True' } | ForEach-Object { "$($_.Name)" })
        }
    } catch { $whdGateUnrec = $false; $whdGateUnrecNames = @() }
    if ($whdGateUnrec) { $whdGateLead += 'the gate is recorded as OPEN although the firewall is as a closed gate leaves it; opening the gate later sets outbound to ALLOW - ' }
    if ($whdGateProg) {
        Write-WHDLog 'UPDATE GATE: PROGRAMS' 'ACT'
        Write-WHDRisk 'hard' ("Outbound becomes default-deny. Only Microsoft Defender (engine, network inspection, core service, updater, SmartScreen), DNS-over-HTTPS and the programs YOU allowed ({0} rule(s) now) may go out (the Defender core service also sends Defender telemetry). Windows Update, Microsoft Store, driver/manufacturer-app downloads, app updaters and every program that is not on your list are OFFLINE until you open the gate. DNS, DHCP and time (NTP) keep working. Allow a program: Firewall menu V (View blocked connections / allow a program). Every outbound allow rule the gate switches off is remembered and switched back on when you open it." -f $whdGateApps.Count)
        foreach ($whdGateApp in $whdGateApps) { Write-WHDLog ("  on your list: {0}" -f $whdGateApp.DisplayName) 'INFO' }
        if (-not $whdGateApps.Count) { Write-WHDLog '  Your program list is EMPTY - until you allow a program (Firewall menu V) this works the same as CLOSED.' 'WARN' }
        if ($whdGatePre) { Show-WHDGateOffPreview -Cand $whdGatePre }
        if ($whdGateUnrec) { Write-WHDLog ("  WHD has the gate recorded as OPEN, but the firewall is as a closed gate leaves it (an imported / restored policy). The gate is set on top of that: WHD takes outbound Allow as the setting to go back to, and remembers {0} rule(s) that are off now (the any-program web rules, your program allows) to switch on again." -f $whdGateUnrecNames.Count) 'WARN' }
        if (-not (Confirm-WHDProceed ($whdGateLead + 'set the update gate to PROGRAMS (outbound default-deny; Defender + DoH + your allowed programs)'))) { Write-WHDLog 'skipped.' 'WARN'; return }
    } else {
        Write-WHDLog 'UPDATE GATE: CLOSE' 'ACT'
        Write-WHDRisk 'hard' 'Outbound becomes default-deny. Only Microsoft Defender (engine, network inspection, core service, updater, SmartScreen) and DNS-over-HTTPS may use HTTP/HTTPS (the Defender core service also sends Defender telemetry). Windows Update, Microsoft Store, driver/manufacturer-app downloads, app updaters, browsers (Edge too), the programs you allowed and every other app are OFFLINE until you open the gate (or set it to PROGRAMS). DNS, DHCP and time (NTP) keep working. Every outbound allow rule the gate switches off is remembered and switched back on when you open it.'
        if ($whdGatePre) { Show-WHDGateOffPreview -Cand $whdGatePre }
        if ($whdGateUnrec) { Write-WHDLog ("  WHD has the gate recorded as OPEN, but the firewall is as a closed gate leaves it (an imported / restored policy). The gate is set on top of that: WHD takes outbound Allow as the setting to go back to, and remembers {0} rule(s) that are off now (the any-program web rules, your program allows) to switch on again." -f $whdGateUnrecNames.Count) 'WARN' }
        if (-not (Confirm-WHDProceed ($whdGateLead + 'close the update gate (outbound default-deny, Defender + DoH only)'))) { Write-WHDLog 'skipped.' 'WARN'; return }
    }
    # Wording for the messages below (the two positions share every check).
    $whdGateIs = 'closed';           if ($whdGateProg) { $whdGateIs = 'on PROGRAMS' }
    $whdGateDo = 'close the gate';   if ($whdGateProg) { $whdGateDo = 'set the gate to PROGRAMS' }
    # Read-only check before any change: with the gate closed, DNS is allowed only to the pinned servers, so an
    # adapter that still uses other DNS servers (the router's, for example) would lose every name lookup.
    $dnsBad = @()
    try {
        foreach ($na in @(Get-NetAdapter -EA Stop | Where-Object { $_.Status -eq 'Up' })) {
            $dnsNow = @(Get-DnsClientServerAddress -InterfaceIndex $na.ifIndex -AddressFamily IPv4 -EA SilentlyContinue | ForEach-Object { $_.ServerAddresses } | Where-Object { $_ })
            if (@($dnsNow | Where-Object { $script:WHDDnsServers -notcontains "$_" }).Count) { $dnsBad += ("{0} (DNS {1})" -f $na.Name, ($dnsNow -join ', ')) }
        }
    } catch { Write-WHDLog ("  could not check which DNS servers the network adapters use ({0}) - continuing without that check." -f $_.Exception.Message) 'WARN' }
    if ($dnsBad.Count) {
        $dnsOld = Get-WHDGateState
        $dnsWas = [bool]$dnsOld.Closed
        # v1.5: the gate is CLOSED / on PROGRAMS already and is without its rules (after a wipe, an import, a restore):
        # refusing would leave outbound Block with nothing allowed at all - not even DHCP or Microsoft Defender. The
        # rules are rebuilt; the name lookups of those adapters stay blocked until DNS is set (as they are right now).
        $dnsRepair = $false
        if ($dnsWas) { try { $dnsRepair = [bool](Get-WHDGateHealth).NeedsSet } catch { $dnsRepair = $false } }
        if ($script:WHDExecute -and $dnsRepair) {
            Write-WHDLog ("Adapter(s) not using the pinned DNS servers ({0}): {1}. Their name lookups are blocked while the gate is set - set DNS to the pinned servers (Firewall menu D). The gate's rules are rebuilt anyway: the gate is {2} already, and without its rules nothing gets out at all." -f ($script:WHDDnsServers -join ', '), ($dnsBad -join '; '), "$($dnsOld.Mode)".ToUpper()) 'WARN'
        } elseif ($script:WHDExecute) {
            $dnsLead = if ($dnsWas) { "Gate {0} refused - the gate stays {1} as it was, nothing was changed." -f $(if ("$($dnsOld.Mode)" -eq $Mode) { 'refresh' } else { 'change' }), "$($dnsOld.Mode)".ToUpper() }
                       else { "Gate NOT {0} - nothing was changed." -f $(if ($whdGateProg) { 'set to PROGRAMS' } else { 'closed' }) }
            Write-WHDLog ("{0} Adapter(s) not using the pinned DNS servers ({1}): {2}. With the gate {3} their name lookups stop. Set DNS to the pinned servers first (Firewall menu D), then {4}." -f $dnsLead, ($script:WHDDnsServers -join ', '), ($dnsBad -join '; '), $whdGateIs, $whdGateDo) 'ERR'
            New-WHDResult -Action $(if ($whdGateProg) { 'set the update gate to PROGRAMS' } else { 'close the update gate' }) -Status 'failed' -Detail 'adapter(s) not using the pinned DNS servers' | Out-Null
            return
        } else {
        Write-WHDLog ("  would refuse to {2} unless DNS is set to the pinned servers first ({0}; Firewall menu D, or network.dns = Cloudflare in a profile). Adapter(s) using other DNS now: {1}. Preview continues." -f ($script:WHDDnsServers -join ', '), ($dnsBad -join '; '), $whdGateDo) 'WARN'
        }
    }
    # essentials first: DNS / DHCP / NTP allow-list (also holds the any-program HTTP/HTTPS rules we switch off)
    if (Get-Command Test-WHDAllowListReady -EA SilentlyContinue) {
        if (-not (Test-WHDAllowListReady)) {
            $alCmd = Get-Command Invoke-WHDFirewallAllowList -EA SilentlyContinue
            if ($alCmd -and $alCmd.Parameters -and $alCmd.Parameters.ContainsKey('NoConfirm')) { Invoke-WHDFirewallAllowList -NoConfirm } else { Invoke-WHDFirewallAllowList }
        }
    } elseif (-not @(Get-NetFirewallRule -Group $script:WHDFwGroupAllow -EA SilentlyContinue).Count) { Invoke-WHDFirewallAllowList }
    # Defender + DoH allows (rebuilt each time so a Defender platform update is picked up)
    Remove-WHDFwGroup -Group $script:WHDFwGroupGate
    foreach ($g in @(Get-WHDGateAllowSpecs)) {
        $p = @{ Name=$g.n; DisplayName=$g.d; Group=$script:WHDFwGroupGate; Direction='Outbound'; Action='Allow'
                Enabled='True'; Profile='Any'; Protocol='TCP'; RemotePort=$(if ($g.ports) { $g.ports } else { @('443','80') }) }
        if ($g.svc)   { $p['Service'] = $g.svc }
        if ($g.prog)  { if (-not (Test-Path -LiteralPath $g.prog)) { Write-WHDLog ("  skipped (not on this PC): {0}" -f $g.prog) 'INFO'; continue }; $p['Program'] = $g.prog }
        if ($g.raddr) { $p['RemoteAddress'] = $g.raddr }
        New-WHDFwRule $p
    }
    # everything else that could let traffic out: enabled outbound ALLOW rules outside our essentials/gate groups
    # (PROGRAMS keeps the per-program allows as well)
    # v1.5: an outbound rule you chose to keep (Firewall K) is left on - Get-WHDGateOffCandidates leaves it out.
    $toOff = @((Get-WHDGateOffCandidates -Programs:$whdGateProg).Off | ForEach-Object { "$($_.Name)" })
    $anyWeb = @('WHD-Allow-HTTPS','WHD-Allow-HTTP') | Where-Object { @(Get-NetFirewallRule -Name $_ -EA SilentlyContinue | Where-Object { "$($_.Enabled)" -eq 'True' }).Count }
    $prevOut = (@(Get-WHDFwProfiles | ForEach-Object { "$($_.DefaultOutboundAction)" }) | Select-Object -First 1)
    if (-not $prevOut -or $prevOut -eq 'NotConfigured') { $prevOut = 'Allow' }
    if ($whdGateUnrec) { $prevOut = 'Allow' }      # (outbound is Block only because of the gate that was in the policy that came in)
    $old = Get-WHDGateState
    $whdGateOldDis = @($old.Disabled)
    if ($whdGateUnrec) { $whdGateOldDis = @($whdGateOldDis) + @($whdGateUnrecNames) }
    # A rule you switched OFF yourself (Rules WHD did not make, answer o) and that is on again: the gate switches it
    # off like the others, but does not put it on its list - opening the gate must not switch it back on.
    $whdGateHeld = @{}
    if (Get-Command Get-WHDFwOffLive -EA SilentlyContinue) { try { $whdGateHeld = Get-WHDFwOffLive } catch { $whdGateHeld = @{} } }
    # v1.5: when the gate is set AGAIN, the any-program web rules are off already because of the gate (the allow-list
    # keeps them off while it is closed). They stay on the list of rules to switch back on when the gate opens -
    # also when that list lost them (a wipe deleted the rules and the allow-list has just rebuilt them).
    $whdGateWebOff = @()
    if ($old.Closed) { $whdGateWebOff = @(@('WHD-Allow-HTTPS','WHD-Allow-HTTP') | Where-Object { @(Get-NetFirewallRule -Name $_ -EA SilentlyContinue).Count }) }
    $remember = @(@($whdGateOldDis) + $toOff + @($anyWeb) + @($whdGateWebOff) | Where-Object { $_ -and -not $whdGateHeld.ContainsKey("$_".ToLower()) } | Select-Object -Unique)
    # PROGRAMS: the per-program allows the gate switched off earlier (CLOSED) come back on now and leave the
    # remembered list. An allow that was switched off by hand is not in that list and stays off.
    $whdGateAppNames = @($whdGateApps | ForEach-Object { "$($_.Name)" })
    $gOn = @()
    $whdGateFinal = $remember
    if ($whdGateProg) {
        $gOn          = @($whdGateAppNames | Where-Object { @($whdGateOldDis) -contains $_ })
        $whdGateFinal = @($remember | Where-Object { $whdGateAppNames -notcontains $_ })
    }
    Write-WHDLog ("  switching off {0} other outbound allow rule(s) + {1} any-program web rule(s){2}" -f $toOff.Count, @($anyWeb).Count, $(if ($gOn.Count) { "; switching {0} of your program allow(s) back on" -f $gOn.Count } else { '' })) 'INFO'
    $gOff = @($toOff) + @($anyWeb)
    $whdGatePrev = $(if ($old.Closed) { $old.PrevOutbound } else { $prevOut })
    # Save the list of rules BEFORE the change, so it is not lost if the change is interrupted. (It still holds
    # the program allows that are about to come back on; the exact list is saved again after the change.)
    if ($script:WHDExecute) { _WHDSaveGateState -Closed $true -Mode $Mode -DisabledRules $remember -PrevOutbound $whdGatePrev }
    $whdGateDesc = if ($whdGateProg) { "gate PROGRAMS: disable {0} outbound allow rule(s), {1} program allow(s) back on, outbound default-deny on all profiles" -f $gOff.Count, $gOn.Count }
                   else              { "gate: disable {0} outbound allow rule(s), outbound default-deny on all profiles" -f $gOff.Count }
    $gRes = Invoke-WHDChange -Description $whdGateDesc -Force -Action {
        Backup-WHDFirewallOnce
        foreach ($rn in $gOff) { _WHDGateSwitchRule -Name $rn -On $false }
        foreach ($rn in $gOn)  { _WHDGateSwitchRule -Name $rn -On $true }
        Set-NetFirewallProfile -All -DefaultOutboundAction Block -Confirm:$false -EA Stop
    } | Select-Object -Last 1
    if ($script:WHDExecute) {
        if ("$($gRes.Status)" -ne 'done') {
            # failed or skipped. A gate that was already closed stays closed (outbound is still Block).
            if ($old.Closed) {
                if ("$($old.Mode)" -eq $Mode) { Write-WHDLog ("The update gate could not be {0} again (see the line above). It stays {1} as it was before." -f $(if ($whdGateProg) { 'set to PROGRAMS' } else { 'closed' }), $Mode.ToUpper()) 'ERR'; return }
                # A change of position (CLOSED <-> PROGRAMS) did not go through: put the per-program allows back
                # as the old position had them and record the old position again.
                if ($whdGateProg) {
                    foreach ($rn in $gOn) { _WHDGateSwitchRule -Name $rn -On $false }
                    _WHDSaveGateState -Closed $true -Mode "$($old.Mode)" -DisabledRules $remember -PrevOutbound $whdGatePrev -Changed $old.Since
                } else {
                    $whdGateBack = @($toOff | Where-Object { $whdGateAppNames -contains $_ })
                    foreach ($rn in $whdGateBack) { _WHDGateSwitchRule -Name $rn -On $true }
                    _WHDSaveGateState -Closed $true -Mode "$($old.Mode)" -DisabledRules @($remember | Where-Object { $whdGateBack -notcontains $_ }) -PrevOutbound $whdGatePrev -Changed $old.Since
                }
                Write-WHDLog ("The update gate could NOT be {0} (see the line above). It stays {1} as it was before." -f $(if ($whdGateProg) { 'set to PROGRAMS' } else { 'closed' }), "$($old.Mode)".ToUpper()) 'ERR'
                return
            }
            # Otherwise: put the rules from this attempt back as they were and record the gate as not closed.
            foreach ($rn in $gOff) { _WHDGateSwitchRule -Name $rn -On $true }
            foreach ($rn in $gOn)  { _WHDGateSwitchRule -Name $rn -On $false }
            _WHDSaveGateState -Closed $false -DisabledRules @($old.Disabled) -PrevOutbound $prevOut
            Write-WHDLog ("The update gate could NOT be {0} (see the line above). The rules it had switched off are switched back on; the gate is recorded as open." -f $(if ($whdGateProg) { 'set to PROGRAMS' } else { 'closed' })) 'ERR'
            return
        }
        Remove-WHDRollbackTask
        # read-back: an outbound allow rule that is still ON although the gate switched it off is named
        try {
            $whdGateStill = @((Get-WHDGateOffCandidates -Programs:$whdGateProg).Off)
            if ($whdGateStill.Count) { Write-WHDLog ("  {0} outbound allow rule(s) are still ON after the gate was set (they could not be switched off): {1}. Their programs get through - Firewall or Updates menu K lists them." -f $whdGateStill.Count, ((@($whdGateStill | Select-Object -First 6 | ForEach-Object { $whdGsN = "$($_.DisplayName)"; if (-not $whdGsN) { $whdGsN = "$($_.Name)" }; $whdGsN })) -join ', ')) 'WARN' }
        } catch { }
        if ($whdGateProg) {
            _WHDSaveGateState -Closed $true -Mode $Mode -DisabledRules $whdGateFinal -PrevOutbound $whdGatePrev
            Write-WHDLog 'Update gate on PROGRAMS. Allow a program: Firewall menu V. Updates: open the gate (Updates menu O).' 'OK'
        } else {
            Write-WHDLog 'Update gate CLOSED. Open it (Updates menu O) when you want updates.' 'OK'
        }
    }
}
function Open-WHDUpdateGate {
    Write-WHDLog 'UPDATE GATE: OPEN' 'ACT'
    $st = Get-WHDGateState
    # Nothing to open unless the gate is closed (or its saved state still lists rules it switched off): outbound
    # default-deny that was turned on separately (Firewall menu 6) is left alone.
    if (-not $st.Closed -and -not @($st.Disabled | Where-Object { $_ }).Count) {
        # v1.5: recorded as closed although outbound is open already (a firewall reset, an import or another program
        # opened it): nothing to switch back on - only the record is put right.
        if ("$($st.Recorded)" -ne 'open') {
            if ($script:WHDExecute) {
                _WHDSaveGateState -Closed $false -Mode 'open' -DisabledRules @() -PrevOutbound 'Allow'
                Write-WHDLog ("The update gate was recorded as {0}, but outbound is open already. Its record now says OPEN; no rule was changed." -f "$($st.Recorded)".ToUpper()) 'OK'
            } else { Write-WHDLog ("would: record the update gate as OPEN (it is recorded as {0}, but outbound is open already)" -f "$($st.Recorded)".ToUpper()) 'DRY' }
            return
        }
        if ("$($st.Outbound)" -match 'Block') {
            Write-WHDLog 'The update gate is not closed (WHD has it recorded as OPEN) - nothing for the gate to open. Outbound is Block for another reason: default-deny (Firewall 6) or an imported firewall policy. Firewall menu 8 sets outbound back to Allow; C or P here sets the gate.' 'WARN'; return
        }
        Write-WHDLog 'The update gate is not closed - nothing to open.' 'INFO'; return
    }
    # v1.5: rules the gate switched off that no longer exist (deleted since by a wipe, a reset, an uninstall) are named and left out
    $whdOpHave = @{}; foreach ($whdOpR in @(Get-NetFirewallRule -EA SilentlyContinue)) { $whdOpHave["$($whdOpR.Name)".ToLower()] = $true }
    $whdOpAll  = @($st.Disabled | Where-Object { $_ })
    $gOn       = @($whdOpAll | Where-Object { $whdOpHave.ContainsKey("$_".ToLower()) })
    $whdOpGone = @($whdOpAll | Where-Object { -not $whdOpHave.ContainsKey("$_".ToLower()) })
    if ("$($st.PrevOutbound)" -match 'Block') {
        Write-WHDRisk 'caution' ("Puts back the {0} outbound allow rule(s) the gate switched off. Outbound STAYS Block: default-deny outbound was on before the gate closed, and that is put back. What can go out afterwards is what the allow rules let out (with the any-program web rules on: Windows Update, Store, drivers and app updaters can download). To set outbound to Allow: Firewall menu 8." -f $gOn.Count)
    } else {
        Write-WHDRisk 'caution' ("Puts back the {0} outbound allow rule(s) the gate switched off and outbound '{1}' (as before the gate closed). Windows Update, Store, drivers and app updaters can then download - the Windows Update / driver / Store policies still apply. Stays open until you close it." -f $gOn.Count, $st.PrevOutbound)
    }
    if ($whdOpGone.Count) { Write-WHDLog ("  {0} rule(s) the gate had switched off no longer exist (deleted since - a wipe, a reset or an uninstall) and are left out: {1}{2}" -f $whdOpGone.Count, ((@($whdOpGone | Select-Object -First 6)) -join ', '), $(if ($whdOpGone.Count -gt 6) { ' ...' } else { '' })) 'INFO' }
    if (-not (Confirm-WHDProceed 'open the update gate')) { Write-WHDLog 'skipped.' 'WARN'; return }
    $gOut = if ($st.PrevOutbound) { $st.PrevOutbound } else { 'Allow' }
    $whdGateOpenRes = Invoke-WHDChange -Description ("gate: re-enable {0} rule(s), outbound {1}" -f $gOn.Count, $gOut) -Force -Action {
        foreach ($rn in $gOn) { _WHDGateSwitchRule -Name $rn -On $true }
        Set-NetFirewallProfile -All -DefaultOutboundAction $gOut -Confirm:$false -EA Stop
    } | Select-Object -Last 1
    if ($script:WHDExecute) {
        # The gate is recorded as open only when the change went through.
        if ("$($whdGateOpenRes.Status)" -ne 'done') {
            # A gate that was closed stays closed: the rules this attempt switched on are switched off again, so
            # the recorded position stays true. The saved state (position + remembered rules) is not touched.
            if ($st.Closed) {
                foreach ($rn in $gOn) { _WHDGateSwitchRule -Name $rn -On $false }
                Write-WHDLog ("The update gate could NOT be opened (see the line above). It stays {0} as it was before; the rules it had switched off stay remembered. Try O again." -f "$($st.Mode)".ToUpper()) 'ERR'
            } else {
                Write-WHDLog 'The update gate could NOT be opened (see the line above). The saved list of rules it had switched off is kept. Try O again.' 'ERR'
            }
            return
        }
        _WHDSaveGateState -Closed $false -Mode 'open' -DisabledRules @() -PrevOutbound $gOut
        Write-WHDLog 'Update gate OPEN. Close it again (Updates menu C, or P for PROGRAMS) when updates are done.' 'OK'
    }
}

# ---- v1.5: the update gate and the firewall tools tell each other's changes --------------
# (from the 2026-10-06 live test: a firewall reset / wipe / .wfw import, a DNS reset or "remove program allows"
# changed what the gate had set without a word, and the gate did not say which rules of others it switched off.)

# What a Firewall-menu tool is about to change of the update gate (or of default-deny outbound). Read-only.
# -> Lines: said before the tool's question.  Ask: added to the question itself.  Both empty = nothing to say.
function Get-WHDCrossToolNote {
    param([ValidateSet('reset','wipe','wfw','dnsreset','appclear')][string]$Tool)
    $ctLines = New-Object System.Collections.Generic.List[string]
    $ctAsk = ''
    $ctSt = Get-WHDGateState
    $ctMode = "$($ctSt.Mode)".ToUpper()
    $ctOutBlock = [bool]("$($ctSt.Outbound)" -match 'Block')
    $ctApps = @(Get-NetFirewallRule -Group $script:WHDFwGroupApp -EA SilentlyContinue).Count
    switch ($Tool) {
        'reset' {
            if ($ctSt.Closed) {
                $ctLines.Add(("The update gate is {0}. A reset sets outbound back to Allow and brings back Windows' own rules: the gate will be OPEN afterwards - Windows Update, the Store and every program can go out again. The gate's own rules and your {1} program allow(s) are deleted. To close it again afterwards: Updates menu C or P." -f $ctMode, $ctApps))
                $ctAsk = ' - this also OPENS the update gate'
            } elseif ($ctOutBlock) {
                $ctLines.Add('Default-deny outbound is on (Firewall 6). A reset sets outbound back to Allow.')
                $ctAsk = ' - this also ends default-deny outbound'
            }
            if (-not $ctSt.Closed -and $ctApps) { $ctLines.Add(("Your {0} program allow(s) (Firewall V) are deleted with it." -f $ctApps)) }
        }
        'wipe' {
            if ($ctSt.Closed) {
                $ctLines.Add(("The update gate is {0}. The wipe also deletes the gate's own rules (Microsoft Defender, DNS-over-HTTPS), the DNS / DHCP / time allows and your {1} program allow(s). Outbound stays Block, so afterwards NOTHING gets out - not even Defender - until the gate is set again - WHD offers that right after the wipe (a profile run does it as its step list says). Your program allows are not put back: allow those programs again in Firewall V." -f $ctMode, $ctApps))
                $ctAsk = " - this also deletes the update gate's own rules and your program allows"
            } elseif ($ctOutBlock) {
                $ctLines.Add('Outbound is Block (default-deny) now: the wipe also deletes the WHD allow rules, so there is NO network afterwards until the allow-list is applied again (Firewall 5, or the baseline right after the wipe) or default-deny is reverted (Firewall 8).')
                $ctAsk = ' - with default-deny on there is NO network afterwards'
                if ($ctApps) { $ctLines.Add(("Your {0} program allow(s) (Firewall V) are deleted with it." -f $ctApps)) }
            } elseif ($ctApps) { $ctLines.Add(("Your {0} program allow(s) (Firewall V) are deleted with it." -f $ctApps)) }
        }
        'wfw' {
            if ($ctSt.Closed) {
                $ctLines.Add(("The update gate is {0}. Importing a .wfw file replaces the WHOLE firewall policy - every rule and the outbound setting - with what was saved in that file. Afterwards WHD reads the real state, tells you where the gate stands and puts its record right." -f $ctMode))
                $ctAsk = " - this replaces the update gate's rules and may open the gate"
            } elseif ($ctOutBlock) {
                $ctLines.Add('Default-deny outbound is on (Firewall 6). A .wfw file replaces the whole firewall policy, the outbound setting included: the file decides whether default-deny stays.')
            } else {
                $ctLines.Add('A .wfw file replaces the WHOLE firewall policy, the outbound setting included. If the file was saved while the update gate was CLOSED / on PROGRAMS, outbound is Block again afterwards and the web is off, while WHD has the gate recorded as OPEN - WHD checks that after the import and says so.')
            }
        }
        'dnsreset' {
            if ($ctOutBlock) {
                $ctWhy = 'default-deny outbound'; if ($ctSt.Closed) { $ctWhy = ("update gate {0}" -f $ctMode) }
                $ctLines.Add(("Outbound is Block ({0}). DNS is then allowed only to the pinned servers ({1}). After a reset to automatic the PC asks the DNS server the router gives it, those lookups are blocked, and no program can look up a name - until DNS is set back (Firewall D), or the gate is opened / default-deny is reverted." -f $ctWhy, ($script:WHDDnsServers -join ', ')))
                $ctAsk = ' - name lookups will STOP while outbound is Block'
            }
        }
        'appclear' {
            if ($ctSt.Closed -and "$($ctSt.Mode)" -eq 'programs') {
                $ctLines.Add(("The update gate is on PROGRAMS: these {0} rule(s) are the programs it lets out. Without them the gate works like CLOSED - every program is offline (Microsoft Defender and DNS-over-HTTPS excepted)." -f $ctApps))
                $ctAsk = ' - every program the PROGRAMS gate lets out goes offline'
            } elseif ($ctSt.Closed) {
                $ctLines.Add('The update gate is CLOSED: it switched your program allows off and remembers them. They are deleted now and taken off the gate''s list, so a later PROGRAMS or OPEN does not bring them back.')
            }
        }
    }
    [pscustomobject]@{ Lines = @($ctLines.ToArray()); Ask = $ctAsk }
}

# Takes rule names off the list of rules the gate switched off (used when those rules are deleted on purpose).
function Remove-WHDGateRemembered {
    param([string[]]$Names)
    if (-not $script:WHDExecute) { return }
    $rgSt = Get-WHDGateState
    $rgGone = @($Names | Where-Object { $_ } | ForEach-Object { "$_".ToLower() })
    $rgAll = @($rgSt.Disabled | Where-Object { $_ })
    if (-not $rgAll.Count -or -not $rgGone.Count) { return }
    $rgLeft = @($rgAll | Where-Object { $rgGone -notcontains "$_".ToLower() })
    if ($rgLeft.Count -eq $rgAll.Count) { return }
    _WHDSaveGateState -Closed ("$($rgSt.Recorded)" -ne 'open') -Mode "$($rgSt.Recorded)" -DisabledRules $rgLeft -PrevOutbound $rgSt.PrevOutbound -Changed $rgSt.Since
}

# Is the gate what its record says? Read-only.
#   Problems : texts for the screen (empty = fine)
#   NeedsSet : the gate is CLOSED / on PROGRAMS but something it relies on is missing - setting it again repairs it
#   Stale    : it is recorded as closed, but outbound is open (the gate is open in fact)
#   Unrecorded : it is recorded as OPEN, but the firewall looks like a set gate (outbound Block, the gate's rules ON,
#                the any-program web rule off) - a policy saved while the gate was closed was imported / restored
function Get-WHDGateHealth {
    $ghSt = Get-WHDGateState
    $ghProb = New-Object System.Collections.Generic.List[string]
    $ghNeeds = $false; $ghStale = $false; $ghUnrec = $false
    if ("$($ghSt.Recorded)" -eq 'open' -and "$($ghSt.Outbound)" -match 'Block' -and "$($ghSt.Outbound)" -notmatch 'Allow|NotConfigured') {
        $ghGateOn = @(Get-NetFirewallRule -Group $script:WHDFwGroupGate -EA SilentlyContinue | Where-Object { "$($_.Enabled)" -eq 'True' }).Count
        # (the web rule has to be THERE and off: a closed gate switches it off, it does not delete it. A strict setup
        #  without any-program web rules + default-deny by hand is not this case.)
        $ghWebAll = @(Get-NetFirewallRule -Name 'WHD-Allow-HTTPS' -EA SilentlyContinue)
        $ghWebOn  = @($ghWebAll | Where-Object { "$($_.Enabled)" -eq 'True' }).Count
        if ($ghGateOn -and $ghWebAll.Count -and -not $ghWebOn) {
            $ghUnrec = $true
            $ghProb.Add("it is recorded as OPEN, but outbound is Block, the gate's own rules are ON and the any-program web rule is switched off - the firewall is as a closed gate leaves it (a firewall policy saved while the gate was CLOSED / on PROGRAMS was imported or restored). Programs without an allow rule of their own have no web. Updates menu: C or P sets the gate properly (O then opens it again: outbound Allow, web rules on); Firewall menu 8 only sets outbound back to Allow.")
        }
    }
    if ("$($ghSt.Recorded)" -ne 'open' -and -not $ghSt.Closed) {
        $ghStale = $true
        $ghProb.Add(("it is recorded as {0}, but outbound is '{1}' - a firewall reset, an import or another program set outbound back to Allow, so the gate is OPEN in fact. Updates menu: C or P closes it again, O puts its record right." -f "$($ghSt.Recorded)".ToUpper(), $ghSt.Outbound))
    }
    if ($ghSt.Closed) {
        $ghMode = "$($ghSt.Mode)".ToUpper()
        # a firewall profile that is switched off: no rule and no default action applies on that kind of network
        $ghProfOff = @(Get-WHDFwProfiles | Where-Object { "$($_.Enabled)" -eq 'False' } | ForEach-Object { "$($_.Name)" })
        if ($ghProfOff.Count) { $ghProb.Add(("it is {0}, but Windows Firewall is switched OFF for the profile(s) {1} - on such a network the gate (and every other firewall rule) does nothing. Switch the firewall back on in Windows Security > Firewall & network protection." -f $ghMode, ($ghProfOff -join ', '))) }
        $ghHave = @{}
        foreach ($ghR in @(Get-NetFirewallRule -Group $script:WHDFwGroupGate -EA SilentlyContinue)) { if ("$($ghR.Enabled)" -eq 'True') { $ghHave["$($ghR.Name)".ToLower()] = $true } }
        # the rules the gate makes on this PC (a program file that is not on this PC gets no rule)
        $ghWant = @(Get-WHDGateAllowSpecs | Where-Object { $_.svc -or ($_.prog -and (Test-Path -LiteralPath $_.prog)) })
        $ghMiss = @($ghWant | Where-Object { -not $ghHave.ContainsKey("$($_.n)".ToLower()) })
        if ($ghWant.Count -and $ghMiss.Count -eq $ghWant.Count) {
            $ghNeeds = $true
            $ghProb.Add(("it is {0}, but its own rules are gone (Microsoft Defender and DNS-over-HTTPS cannot get out). A wipe, a reset or an import deleted them. Set the gate again: Updates menu {1}." -f $ghMode, $(if ($ghMode -eq 'PROGRAMS') { 'P' } else { 'C' })))
        } elseif ($ghMiss.Count) {
            $ghNeeds = $true
            $ghProb.Add(("it is {0}, but {1} of its own rules are missing or switched off ({2}). Set the gate again: Updates menu {3}." -f $ghMode, $ghMiss.Count, ((@($ghMiss | ForEach-Object { "$($_.n)" }) | Select-Object -First 4) -join ', '), $(if ($ghMode -eq 'PROGRAMS') { 'P' } else { 'C' })))
        }
        if ((Get-Command Test-WHDAllowListReady -EA SilentlyContinue) -and -not (Test-WHDAllowListReady)) {
            $ghNeeds = $true
            $ghProb.Add(("it is {0}, but the DNS / DHCP allow rules are missing or switched off - nothing can look up a name. Set the gate again (Updates menu {1}) or apply the allow-list (Firewall 5)." -f $ghMode, $(if ($ghMode -eq 'PROGRAMS') { 'P' } else { 'C' })))
        }
        if ("$($ghSt.Mode)" -eq 'closed') {
            $ghApps = @(Get-NetFirewallRule -Group $script:WHDFwGroupApp -EA SilentlyContinue | Where-Object { "$($_.Enabled)" -eq 'True' })
            if ($ghApps.Count) {
                $ghNeeds = $true
                $ghProb.Add(("it is CLOSED, but {0} of your program allow(s) are switched ON (an imported or restored firewall policy, or switched on by hand): those programs get out: {1}. Updates menu: C sets the gate again - that switches them off and remembers them; P keeps them on." -f $ghApps.Count, ((@($ghApps | Select-Object -First 4 | ForEach-Object { "$($_.DisplayName)" })) -join ', ')))
            }
        }
        $ghWeb = @(@('WHD-Allow-HTTPS', 'WHD-Allow-HTTP') | Where-Object { @(Get-NetFirewallRule -Name $_ -EA SilentlyContinue | Where-Object { "$($_.Enabled)" -eq 'True' }).Count })
        if ($ghWeb.Count) {
            $ghNeeds = $true
            $ghProb.Add(("it is {0}, but the any-program web rule(s) {1} are switched ON - every program can use the web. Set the gate again: Updates menu {2}." -f $ghMode, ($ghWeb -join ' / '), $(if ($ghMode -eq 'PROGRAMS') { 'P' } else { 'C' })))
        }
    }
    [pscustomobject]@{ Closed = [bool]$ghSt.Closed; Mode = "$($ghSt.Mode)"; Recorded = "$($ghSt.Recorded)"; Problems = @($ghProb.ToArray()); NeedsSet = $ghNeeds; Stale = $ghStale; Unrecorded = $ghUnrec }
}

# After a firewall reset / wipe / .wfw import ran (EXECUTE): make the gate's record true again and say what happened.
# $Before = Get-WHDGateState from before the tool ran.
function Update-WHDGateAfterFirewallChange {
    param($Before, [string]$What)
    if (-not $script:WHDExecute -or -not $Before) { return }
    try {
        $ucNow = Get-WHDGateState
        if (-not $Before.Closed) {
            # the gate was open; only a leftover record needs putting right
            if ("$($ucNow.Recorded)" -ne 'open' -and -not $ucNow.Closed) { _WHDSaveGateState -Closed $false -Mode 'open' -DisabledRules @() -PrevOutbound 'Allow' }
            # (for example: a policy saved while the gate was closed came in - outbound is Block, the record says OPEN)
            $ucH = Get-WHDGateHealth
            foreach ($ucP in @($ucH.Problems)) { Write-WHDLog ("UPDATE GATE after {0}: {1}" -f $What, $ucP) 'WARN' }
            if (-not $ucH.Unrecorded -and "$($ucNow.Outbound)" -match 'Block' -and "$($Before.Outbound)" -notmatch 'Block') {
                Write-WHDLog ("Outbound is Block now: default-deny outbound came in with {0} (no rollback timer is running). Only what the allow rules let out gets out. Firewall menu 8 sets outbound back to Allow." -f $What) 'WARN'
            }
            return
        }
        if (-not $ucNow.Closed) {
            _WHDSaveGateState -Closed $false -Mode 'open' -DisabledRules @() -PrevOutbound 'Allow'
            Write-WHDLog ("UPDATE GATE: it is OPEN now - {0} set outbound back to Allow (it was {1}). Windows Update, the Store and every program can go out. To close it again: Updates menu C or P." -f $What, "$($Before.Mode)".ToUpper()) 'WARN'
            return
        }
        # still CLOSED / PROGRAMS: rules the gate remembered that no longer exist come off its list
        $ucHave = @{}; foreach ($ucR in @(Get-NetFirewallRule -EA SilentlyContinue)) { $ucHave["$($ucR.Name)".ToLower()] = $true }
        $ucAll  = @($ucNow.Disabled | Where-Object { $_ })
        # (WHD's two any-program web rules stay on the list: the allow-list brings them back switched off, and
        #  opening the gate has to switch them on again)
        $ucLeft = @($ucAll | Where-Object { $ucHave.ContainsKey("$_".ToLower()) -or (@('WHD-Allow-HTTPS', 'WHD-Allow-HTTP') -contains "$_") })
        if ($ucLeft.Count -ne $ucAll.Count) {
            _WHDSaveGateState -Closed $true -Mode "$($ucNow.Mode)" -DisabledRules $ucLeft -PrevOutbound $ucNow.PrevOutbound -Changed $ucNow.Since
            Write-WHDLog ("UPDATE GATE: {0} rule(s) it had switched off were deleted by {1} and are off its list." -f ($ucAll.Count - $ucLeft.Count), $What) 'INFO'
        }
        foreach ($ucP in @((Get-WHDGateHealth).Problems)) { Write-WHDLog ("UPDATE GATE: {0}" -f $ucP) 'WARN' }
        # program allows that are switched off in what came in and are not on the gate's list: nothing switches them on
        $ucRem = @{}; foreach ($ucN in @((Get-WHDGateState).Disabled)) { $ucRem["$ucN".ToLower()] = $true }
        $ucAppOff = @(Get-NetFirewallRule -Group $script:WHDFwGroupApp -EA SilentlyContinue | Where-Object { "$($_.Enabled)" -ne 'True' -and -not $ucRem.ContainsKey("$($_.Name)".ToLower()) })
        if ($ucAppOff.Count) {
            Write-WHDLog ("UPDATE GATE: {0} of your program allow(s) are switched OFF after {1} and are not on the gate's list, so neither PROGRAMS nor OPEN switches them on: {2}. Allow those programs again in Firewall V if they should get out." -f $ucAppOff.Count, $What, ((@($ucAppOff | Select-Object -First 6 | ForEach-Object { "$($_.DisplayName)" })) -join ', ')) 'WARN'
        }
    } catch { try { Write-WHDLog ("The update gate could not be checked after {0}: {1}" -f $What, $_.Exception.Message) 'WARN' } catch { } }
}

# The gate is CLOSED / on PROGRAMS but is not complete (after a wipe, an import or a restore that was DONE - the
# callers check that): ask whether to set it again. The question is the gate's own one. Returns nothing; does
# nothing when the gate is fine or open.
function Invoke-WHDGateRepairOffer {
    param([string]$After = 'the change')
    try {
        $roH = Get-WHDGateHealth
        if (-not $roH.Closed -or -not $roH.NeedsSet) { return }
        $roMode = "$($roH.Mode)"; if ($roMode -ne 'programs') { $roMode = 'closed' }
        Write-WHDLog ("The update gate is {0}, but after {1} it is not complete (see the UPDATE GATE lines above). Next question: set it to {0} again (that rebuilds its rules)." -f $roMode.ToUpper(), $After) 'WARN'
        Close-WHDUpdateGate -Mode $roMode -Why ("after {0} the update gate is not complete" -f $After)
    } catch { try { Write-WHDLog ("The update gate could not be set again: {0}" -f $_.Exception.Message) 'ERR' } catch { } }
}

# The outbound allow rules the gate switches off when it is set (enabled, outside WHD's own groups), and the ones
# it leaves on because you chose to keep them (Firewall K). Read-only.
function Get-WHDGateOffCandidates {
    param([switch]$Programs)
    $gcKeep = @($script:WHDFwGroupAllow, $script:WHDFwGroupGate, $script:WHDFwGroupIPv6, $script:WHDFwGroupBlock)
    if ($Programs) { $gcKeep += $script:WHDFwGroupApp }
    $gcKnown = @{}
    if (Get-Command Get-WHDFwKnown -EA SilentlyContinue) { foreach ($gcN in @((Get-WHDFwKnown).Names)) { $gcKnown["$gcN".ToLower()] = $true } }
    $gcOff = New-Object System.Collections.Generic.List[object]
    $gcKept = New-Object System.Collections.Generic.List[object]
    foreach ($gcR in @(Get-NetFirewallRule -Direction Outbound -Action Allow -Enabled True -EA SilentlyContinue)) {
        if ($gcKeep -contains "$($gcR.Group)") { continue }
        if ($gcKnown.ContainsKey("$($gcR.Name)".ToLower())) { $gcKept.Add($gcR); continue }
        $gcOff.Add($gcR)
    }
    [pscustomobject]@{ Off = @($gcOff.ToArray()); Kept = @($gcKept.ToArray()) }
}
function Show-WHDGateOffPreview {
    param($Cand)
    $gpAll  = @($Cand.Off | Where-Object { $_ })
    $gpKept = @($Cand.Kept | Where-Object { $_ })
    # your own program allows (Firewall V) are named apart: CLOSED switches them off too, PROGRAMS keeps them on
    $gpApps = @($gpAll | Where-Object { "$($_.Group)" -eq "$($script:WHDFwGroupApp)" })
    $gpOff  = @($gpAll | Where-Object { "$($_.Group)" -ne "$($script:WHDFwGroupApp)" })
    if ($gpApps.Count) {
        Write-WHDLog ("  CLOSED also switches OFF your {0} program allow(s) from Firewall V (they come back on with PROGRAMS or OPEN): {1}" -f $gpApps.Count, ((@($gpApps | ForEach-Object { "$($_.DisplayName)" }) | Select-Object -First 8) -join ', ')) 'WARN'
    }
    if ($gpOff.Count) {
        Write-WHDLog ("  The gate will switch OFF {0} outbound allow rule(s) that WHD did not make (Windows' own rules, rules of other programs, rules from other tools). They are remembered and switched back on when the gate opens:" -f $gpOff.Count) 'WARN'
        foreach ($gpR in @($gpOff | Select-Object -First 12)) {
            $gpName = "$($gpR.DisplayName)"; if (-not $gpName) { $gpName = "$($gpR.Name)" }
            $gpGrp = "$($gpR.DisplayGroup)"; if (-not $gpGrp) { $gpGrp = "$($gpR.Group)" }
            Write-WHDLog ("    - {0}{1}" -f $gpName, $(if ($gpGrp) { "   [$gpGrp]" } else { '' })) 'INFO'
        }
        if ($gpOff.Count -gt 12) { Write-WHDLog ("    ... and {0} more" -f ($gpOff.Count - 12)) 'INFO' }
    }
    if ($gpKept.Count) {
        $gpKnAll = @(@($gpKept | ForEach-Object { $gpKn = "$($_.DisplayName)"; if (-not $gpKn) { $gpKn = "$($_.Name)" }; $gpKn }) | Select-Object -Unique)
        Write-WHDLog ("  {0} outbound allow rule(s) stay ON because you chose to keep them (Firewall K) - their programs get through the gate: {1}{2}" -f $gpKept.Count, ((@($gpKnAll | Select-Object -First 8)) -join ', '), $(if ($gpKnAll.Count -gt 8) { (' and {0} more' -f ($gpKnAll.Count - 8)) } else { '' })) 'WARN'
    }
}

# ---- 2-4. policies (journaled registry, auto undo + Verify) --------------------
$script:WHDUpdatePolicies = @(
    [ordered]@{ Key='wu'; Name='Windows Update: no automatic updates (NoAutoUpdate)'
        Ops=@(@{ P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; N='NoAutoUpdate'; V=1; T='DWord' })
        Note='Group Policy "Configure Automatic Updates" = Disabled. Microsoft documents Windows Update policies for Pro/Enterprise/Education; on Home it is TRIED - Status shows whether updates still install while it is set. Updates remain available in Settings > Windows Update (you choose).' }
    [ordered]@{ Key='drivers'; Name='Drivers: Device Installation Settings = No (+ manufacturer apps/icons off)'
        Ops=@(@{ P='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching'; N='SearchOrderConfig'; V=0; T='DWord' }
              @{ P='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata'; N='PreventDeviceMetadataFromNetwork'; V=1; T='DWord' }
              @{ P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata'; N='PreventDeviceMetadataFromNetwork'; V=1; T='DWord' })
        Note='The Control Panel "Device installation settings" = No: Windows does not fetch drivers or manufacturer companion apps when hardware appears. A feature update can reset SearchOrderConfig - Verify / the update guard will flag it.' }
    [ordered]@{ Key='driverpolicy'; Name='Drivers: "Do not include drivers with Windows Updates" policy'
        Ops=@(@{ P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; N='ExcludeWUDriversInQualityUpdate'; V=1; T='DWord' })
        Note='Microsoft documents it for Pro/Enterprise/Education and it is reported not to work on Home - set as a second lock; harmless if ignored.' }
    [ordered]@{ Key='store'; Name='Microsoft Store: automatic app updates off (AutoDownload=2)'
        Ops=@(@{ P='HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'; N='AutoDownload'; V=2; T='DWord' })
        Note='Group Policy "Turn off Automatic Download and Install of updates". Documented for Pro+; on Home it is TRIED (the consumer Store otherwise only pauses 1-5 weeks). The update gate is the reliable block.' }
)
function Invoke-WHDUpdatePolicy {
    param([Parameter(Mandatory)]$Item)
    Write-WHDLog ("UPDATES: {0}" -f $Item.Name) 'ACT'
    Write-WHDRisk 'reversible' $Item.Note
    if ((Get-WHDRegOpsState -Ops $Item.Ops) -eq 'set') { Write-WHDLog 'Already set - nothing to change.' 'OK'; return }
    if (-not (Confirm-WHDProceed ("set: {0}" -f $Item.Name))) { Write-WHDLog 'skipped.' 'WARN'; return }
    foreach ($op in $Item.Ops) { Set-WHDRegistryValue -Path $op.P -Name $op.N -Value $op.V -Type $op.T }
}

# ---- 5. app self-updaters ------------------------------------------------------
# Non-Windows scheduled tasks and services whose name says update / updater /
# maintenance (Edge Update, OneDrive, Google, Zoom, Adobe, Mozilla ...).
# A disabled task whose instance is still running reports State=Running, so read Settings.Enabled.
function Test-WHDTaskEnabled {
    param($Task)
    try { if ($null -ne $Task.Settings -and $null -ne $Task.Settings.Enabled) { return [bool]$Task.Settings.Enabled } } catch { }
    return ("$($Task.State)" -ne 'Disabled')
}
function Get-WHDTaskStateText {
    param($Task)
    if (Test-WHDTaskEnabled -Task $Task) { return "$($Task.State)" }
    if ("$($Task.State)" -eq 'Running') { return 'Disabled, last run still finishing' }
    return 'Disabled'
}
function Find-WHDAppUpdaters {
    $rx = 'update|updater|maintenance'
    $out = New-Object System.Collections.Generic.List[object]
    # WHD's own tasks (\WinHardenDebloat\) are never offered.
    foreach ($t in @(Get-ScheduledTask -EA SilentlyContinue | Where-Object { $_.TaskPath -notlike '\Microsoft\Windows\*' -and $_.TaskPath -notlike '\WinHardenDebloat\*' -and ("$($_.TaskName)" -match $rx) })) {
        $isEdge = "$($t.TaskName)" -like 'MicrosoftEdgeUpdate*'
        $tState = Get-WHDTaskStateText -Task $t
        $out.Add([pscustomobject]@{ Kind='task'; Id=("{0}{1}" -f $t.TaskPath, $t.TaskName); TaskPath="$($t.TaskPath)"; TaskName="$($t.TaskName)"; Service=''
            Name="$($t.TaskName)"; State=$tState; Edge=$isEdge; Label=("[task]    {0}{1}   ({2})" -f $t.TaskPath, $t.TaskName, $tState) })
    }
    foreach ($s in @(Get-CimInstance Win32_Service -EA SilentlyContinue | Where-Object {
            ("$($_.Name) $($_.DisplayName)" -match $rx) -and "$($_.PathName)" -notmatch '(?i)\\Windows\\(System32|SysWOW64|servicing)\\' })) {
        $isEdge = "$($s.Name)" -like 'edgeupdate*'
        $out.Add([pscustomobject]@{ Kind='service'; Id=$s.Name; TaskPath=''; TaskName=''; Service="$($s.Name)"
            Name="$($s.DisplayName)"; State=("{0}/{1}" -f $s.State, $s.StartMode); Edge=$isEdge; Label=("[service] {0} ({1})   {2}/{3}" -f $s.DisplayName, $s.Name, $s.State, $s.StartMode) })
    }
    @($out.ToArray() | Sort-Object @{ e = { -not $_.Edge } }, Label)
}
function Disable-WHDAppUpdater {
    param([Parameter(Mandatory)]$Item)
    if ($Item.Kind -eq 'task') {
        $t = @(Get-ScheduledTask -TaskPath $Item.TaskPath -EA SilentlyContinue | Where-Object { $_.TaskName -eq $Item.TaskName })[0]
        if (-not $t) { Write-WHDLog ("task not found: {0}" -f $Item.Id) 'WARN'; return }
        if (-not (Test-WHDTaskEnabled -Task $t)) { Write-WHDLog ("already disabled: {0}" -f $Item.Id) 'OK'; return }
        $upPath = $Item.TaskPath; $upName = $Item.TaskName
        $jr = @{ Kind = 'task'; TaskPath = $upPath; TaskName = $upName; OldEnabled = $true; NewEnabled = $false }
        Invoke-WHDChange -Description ("stop + disable scheduled task {0}{1}" -f $upPath, $upName) -Force -Journal $jr -Action {
            Stop-ScheduledTask -TaskPath $upPath -TaskName $upName -EA SilentlyContinue
            Disable-ScheduledTask -TaskPath $upPath -TaskName $upName -EA Stop | Out-Null
        } | Out-Null
    } else {
        $svc = Get-Service -Name $Item.Service -EA SilentlyContinue
        if (-not $svc) { Write-WHDLog ("service not found: {0}" -f $Item.Service) 'WARN'; return }
        if ("$($svc.StartType)" -eq 'Disabled') { Write-WHDLog ("already disabled: {0}" -f $Item.Service) 'OK'; return }
        $upSvc = $Item.Service
        $jr = @{ Kind = 'service'; Service = $upSvc; OldStartType = "$($svc.StartType)"; NewStartType = 'Disabled' }
        Invoke-WHDChange -Description ("service {0}: stop + start type {1} -> Disabled" -f $upSvc, $svc.StartType) -Force -Journal $jr -Action {
            Stop-Service -Name $upSvc -Force -EA SilentlyContinue
            Set-Service -Name $upSvc -StartupType Disabled -EA Stop
        } | Out-Null
    }
}
function Invoke-WHDAppUpdatersOff {
    param([object[]]$Items, [switch]$EdgeOnly)
    $list = @(if ($Items) { $Items } else { Find-WHDAppUpdaters })
    if ($EdgeOnly) { $list = @($list | Where-Object { $_.Edge }) }
    Write-WHDLog ("APP UPDATERS OFF: {0} item(s)" -f $list.Count) 'ACT'
    if (-not $list.Count) { Write-WHDLog 'Nothing found.' 'INFO'; return }
    foreach ($i in $list) { Write-WHDLog ("  {0}" -f $i.Label) 'INFO' }
    Write-WHDRisk 'caution' 'These programs stop updating themselves (Edge: no automatic security fixes). Update them by hand, or undo in the Undo center. Journaled.'
    if (-not (Confirm-WHDProceed ("turn off {0} app updater(s)" -f $list.Count))) { Write-WHDLog 'skipped.' 'WARN'; return }
    foreach ($i in $list) { Disable-WHDAppUpdater -Item $i }
}

# ---- status ---------------------------------------------------------------------
function Show-WHDUpdatesStatus {
    Write-WHDLog '================ UPDATES STATUS (read-only) ================' 'ACT'
    $g = Get-WHDGateState
    Write-WHDLog ("Update gate          : {0}   (outbound: {1})" -f $g.Text, $g.Outbound) $(if ($g.Closed) { 'OK' } else { 'WARN' })
    if ($g.Mode -eq 'programs') {
        $apps = @(Get-NetFirewallRule -Group $script:WHDFwGroupApp -EA SilentlyContinue)
        Write-WHDLog ("  programs on your list: {0} rule(s){1}" -f $apps.Count, $(if ($apps.Count) { '' } else { ' - empty: works the same as CLOSED until you allow one (Firewall menu V)' })) $(if ($apps.Count) { 'INFO' } else { 'WARN' })
        foreach ($a in $apps) { Write-WHDLog ("    {0}  [{1}]" -f $a.DisplayName, $(if ("$($a.Enabled)" -eq 'True') { 'on' } else { 'off' })) 'INFO' }
    }
    # v1.5: is the gate what its record says, and is a rule ON that WHD did not make?
    try { foreach ($ghLine in @((Get-WHDGateHealth).Problems)) { Write-WHDLog ("  UPDATE GATE: {0}" -f $ghLine) 'WARN' } } catch { }
    if (Get-Command Get-WHDForeignSummary -EA SilentlyContinue) {
        try {
            $fsNow = Get-WHDForeignSummary
            if ($fsNow.Alert) {
                Write-WHDLog ("  {0} Decide: Firewall or Updates menu K (window version: Firewall tab, Rules from others)." -f $fsNow.Text) 'WARN'
                foreach ($fsRow in @($fsNow.Attention | Select-Object -First 15)) { Write-WHDLog ("    {0}" -f (Get-WHDForeignRowText -Row $fsRow)) 'INFO' }
                if (@($fsNow.Attention).Count -gt 15) { Write-WHDLog ("    ... and {0} more" -f (@($fsNow.Attention).Count - 15)) 'INFO' }
            } elseif ($fsNow.Text) { Write-WHDLog ("  {0}" -f $fsNow.Text) 'INFO' }
            else { Write-WHDLog '  rules WHD did not make: none that are ON and not kept by you' 'OK' }
            if ($fsNow.KeptOut) { Write-WHDLog ("  kept by you: {0}" -f $fsNow.KeptOut) 'WARN' }
        } catch { }
    }
    if ($g.Closed) {
        $plat = Get-WHDDefenderPlatformDir
        $rule = @(Get-NetFirewallRule -Name 'WHD-Gate-MsMpEng' -EA SilentlyContinue)
        if ($plat -and $rule.Count) {
            $pf = "$(@($rule[0] | Get-NetFirewallApplicationFilter -EA SilentlyContinue)[0].Program)"
            if ($pf -and $pf -ne (Join-Path $plat 'MsMpEng.exe')) { Write-WHDLog '  Defender updated its platform since the gate closed - set the gate again (C or P) to refresh its allow rules.' 'WARN' }
        }
    }
    foreach ($it in $script:WHDUpdatePolicies) {
        $s = Get-WHDRegOpsState -Ops $it.Ops
        Write-WHDLog ("{0,-20}: {1}" -f ($it.Key), $(if ($s -eq 'set') { 'set' } elseif ($s -eq 'partly') { 'partly set' } else { 'not set' })) $(if ($s -eq 'set') { 'OK' } else { 'INFO' })
    }
    # Evidence: what Windows Update installed recently (System log, WindowsUpdateClient event 19)
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 19; StartTime = (Get-Date).AddDays(-14) } -MaxEvents 15 -EA SilentlyContinue)
    Write-WHDLog ("Windows Update installs (14 days): {0}" -f $ev.Count) 'INFO'
    foreach ($e in $ev | Select-Object -First 8) {
        $t = (("$($e.Message)" -split "`r?`n")[0]) -replace '^Installation Successful: Windows successfully installed the following update: ', ''
        Write-WHDLog ("  {0:yyyy-MM-dd HH:mm}  {1}" -f $e.TimeCreated, $t) 'INFO'
    }
    $up = @(Find-WHDAppUpdaters)
    Write-WHDLog ("App updaters found   : {0}  ({1} still active)" -f $up.Count, @($up | Where-Object { $_.State -notmatch 'Disabled' }).Count) 'INFO'
    foreach ($u in $up) { Write-WHDLog ("  {0}" -f $u.Label) $(if ($u.State -match 'Disabled') { 'OK' } else { 'INFO' }) }
    Write-WHDLog '================ END ================' 'ACT'
}
# Defender definitions direct from Microsoft Malware Protection Center (MMPC). Meant to get through the closed
# gate, but in the 2026-10-03 live test it failed with the gate closed (cause not known yet), so the texts no
# longer promise that. On a failure the gate state and Defender's own error details are logged (read-only).
function Invoke-WHDDefenderUpdateTest {
    Write-WHDLog 'DEFENDER: update definitions now (source MMPC)' 'ACT'
    $duGate = $false
    try {
        $duSt = Get-WHDGateState
        $duGate = [bool]$duSt.Closed
        Write-WHDLog ("  update gate: {0}   outbound: {1}" -f $(if ($duGate) { "$($duSt.Mode)".ToUpper() } else { 'open' }), $duSt.Outbound) 'INFO'
    } catch {}
    try { $before = (Get-MpComputerStatus -EA Stop).AntivirusSignatureVersion } catch { $before = '?' }
    if (-not $script:WHDExecute) { Write-WHDLog ("would: Update-MpSignature -UpdateSource MMPC   (definitions now {0})" -f $before) 'DRY'; return }
    $duStart = Get-Date
    try {
        Update-MpSignature -UpdateSource MMPC -EA Stop
        $s = Get-MpComputerStatus -EA Stop
        Write-WHDLog ("Definitions {0} -> {1}  (age {2} day(s))" -f $before, $s.AntivirusSignatureVersion, $s.AntivirusSignatureAge) 'OK'
    } catch {
        $duErr = $_
        Write-WHDLog ("Defender update failed: {0}" -f $duErr.Exception.Message) 'ERR'
        try { Write-WHDLog ("  error id: {0}" -f $duErr.FullyQualifiedErrorId) 'INFO' } catch {}
        # Defender's own record of the failed update (event 2001): error code and the source it tried.
        try {
            $duEv = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = 2001; StartTime = $duStart.AddSeconds(-5) } -MaxEvents 1 -EA SilentlyContinue)
            if ($duEv.Count) {
                foreach ($duLine in @("$($duEv[0].Message)" -split "`r?`n" | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^(Error code|Error description|Update Source|Update Stage|Update Type|Source Path)\s*:' })) {
                    Write-WHDLog ("  Defender event 2001: {0}" -f $duLine) 'INFO'
                }
            }
        } catch {}
        if ($duGate) { Write-WHDLog 'The update gate is not open. Try again with the gate open (O), then set it back (C or P).' 'WARN' }
    }
}

# ---- menu ------------------------------------------------------------------------
function Show-WHDUpdatesMenu {
    Write-Host ''
    Write-Host '  ================= UPDATES (stop auto-installs) =================' -ForegroundColor White
    Write-Host ('   Gate now: {0}' -f (Get-WHDGateState).Text)
    if (Get-Command Show-WHDFwAttentionLines -EA SilentlyContinue) { Show-WHDFwAttentionLines }
    Write-Host '   C. CLOSE update gate      (only Defender + DNS-over-HTTPS may use the web)'
    Write-Host '   P. PROGRAMS update gate   (Defender + DNS-over-HTTPS + the programs you allowed; no Windows Update / Store)'
    Write-Host '   O. OPEN update gate       (let updates in; stays open until you change it)'
    $i = 0
    foreach ($it in $script:WHDUpdatePolicies) {
        $i++
        $st = Get-WHDRegOpsState -Ops $it.Ops
        Write-Host ('   {0}. {1,-74} [{2}]' -f $i, $it.Name, $(if ($st -eq 'set') { 'set' } elseif ($st -eq 'partly') { 'partly' } else { 'not set' }))
    }
    Write-Host '   A. All four policies above'
    Write-Host '   E. Edge Update off (tasks + services)'
    Write-Host '   F. Find other app updaters -> choose which to turn off'
    Write-Host '   D. Defender definitions: update now (if it fails with the gate closed, open the gate first)'
    Write-Host '   S. Status (gate, policies, recent Windows Update installs, updaters)'
    Write-Host '   K. Rules WHD did not make (allow rules that are ON: switch off / remove / keep / one port only)'
    Write-Host '   B. Back'
}
function Invoke-WHDUpdatesSubmenu {
    while ($true) {
        # v1.5: a rule that neither WHD nor you put in and that was not shown yet -> the list + question first
        if (Get-Command Invoke-WHDFwAttentionAsk -EA SilentlyContinue) { Invoke-WHDFwAttentionAsk }
        Show-WHDMode
        Show-WHDUpdatesMenu
        $c = (Read-Host '  Select').Trim()
        if (Invoke-WHDGuardHotkey $c) { continue }
        switch -regex ($c) {
            '^[Cc]$'    { Close-WHDUpdateGate }
            '^[Pp]$'    { Close-WHDUpdateGate -Mode programs }
            '^[Oo]$'    { Open-WHDUpdateGate }
            '^[1-4]$'   { Invoke-WHDUpdatePolicy -Item $script:WHDUpdatePolicies[[int]$c - 1] }
            '^[Aa]$'    { foreach ($it in $script:WHDUpdatePolicies) { Invoke-WHDUpdatePolicy -Item $it } }
            '^[Ee]$'    { Invoke-WHDAppUpdatersOff -EdgeOnly }
            '^[Ff]$'    {
                $all = @(Find-WHDAppUpdaters | Where-Object { $_.State -notmatch 'Disabled' })
                if (-not $all.Count) { Write-Host '  (no active app updaters found)' -ForegroundColor DarkGray; continue }
                $n = 0; foreach ($u in $all) { $n++; Write-Host ('  {0,3}. {1}' -f $n, $u.Label) }
                $pick = (Read-Host '  Numbers to turn off (e.g. 1,3,4), A = all, Enter = none').Trim()
                if (-not $pick) { continue }
                $sel = @(if ($pick -match '^[Aa]$') { $all } else { $pick -split '[,\s]+' | Where-Object { $_ -match '^\d{1,9}$' -and [int]$_ -ge 1 -and [int]$_ -le $all.Count } | ForEach-Object { $all[[int]$_ - 1] } | Where-Object { $_ } })
                if ($sel.Count) { Invoke-WHDAppUpdatersOff -Items $sel }
            }
            '^[Dd]$'    { Invoke-WHDDefenderUpdateTest }
            '^[Ss]$'    { Show-WHDUpdatesStatus }
            '^[Kk]$'    { if (Get-Command Invoke-WHDForeignRulesView -EA SilentlyContinue) { Invoke-WHDForeignRulesView } else { Write-WHDLog 'Firewall.ps1 not loaded.' 'ERR' } }
            '^[Bb]$'    { return }
            default     { Write-Host '  invalid.' -ForegroundColor Yellow }
        }
    }
}

Write-WHDLog 'Updates.ps1 loaded.' 'INFO'
