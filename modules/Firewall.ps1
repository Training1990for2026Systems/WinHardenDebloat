<#
================================================================================
 WinHardenDebloat  -  modules\Firewall.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Windows Defender Firewall with Advanced Security - native, offline hardening.
 Dot-sourced by WHD.ps1 AFTER Common.ps1 (uses that engine for every change).

 Contract honored (see modules\Common.ps1):
   * Nothing changes unless $script:WHDExecute is $true. Otherwise DRY-RUN.
   * Every mutation flows through Invoke-WHDChange -> restore point + log + result.
   * Firewall policy is exported to restore\ before the first firewall change.
   * No Read-Host in the engine functions; approval goes through Confirm-WHDProceed
     (the caller supplies the strategy: terminal y/N, GUI dialog, profile run).

 Decisions locked with the user (2026-09-21):
   D1 terminal module now      D2 adapter+registry + firewall block rules (keep ::1)
   D3 export BOTH json + .wfw   D4 design toward default-deny outbound
 v1.5 (2026-10-06): the tools here say in their own question what they change of the
   update gate (Updates.ps1), and section 11 finds allow rules WHD did not make.

 NetSecurity / NetAdapter cmdlets used here ship on Windows 11 Home; no
 AppLocker / gpedit / secpol dependency. All operations work with no internet.
================================================================================
#>

# All rules this module creates carry one of these groups, so they list and
# remove as a set and never get confused with Microsoft's built-in rules.
$script:WHDFwGroupIPv6   = 'WinHardenDebloat-IPv6'
$script:WHDFwGroupAllow  = 'WinHardenDebloat-AllowList'
$script:WHDFwGroupBlock  = 'WinHardenDebloat-Blacklist'
$script:WHDFwGroupBase   = 'WinHardenDebloat-Baseline'
$script:WHDFwGroupApp    = 'WinHardenDebloat-AppAllow'    # Phase 6: per-program allows from the blocked-connection viewer
$script:WHDFwRollbackTask = 'WHD-DefaultDenyRollback'
$script:WHDFwBackupDone  = $false

# Routable / non-loopback IPv6 space. ::1/128 (loopback) and :: are deliberately
# left OUT so local software that talks to itself over ::1 keeps working.
$script:WHDIPv6Ranges = @('2000::/3','fc00::/7','fe80::/10','ff00::/8')

# Outbound DNS is pinned to Cloudflare's malware-filtering resolver (1.1.1.2/1.0.0.2),
# used over encrypted DoH. Edit both lines together to change resolver.
#   plain Cloudflare  1.1.1.1/1.0.0.1  -> https://cloudflare-dns.com/dns-query
#   malware           1.1.1.2/1.0.0.2  -> https://security.cloudflare-dns.com/dns-query
#   malware+adult     1.1.1.3/1.0.0.3  -> https://family.cloudflare-dns.com/dns-query
$script:WHDDnsServers  = @('1.1.1.2','1.0.0.2')
$script:WHDDohTemplate = 'https://security.cloudflare-dns.com/dns-query'

# Phase 6 time sync (Option 1): Windows Time -> Cloudflare over plain NTP (Windows
# has no NTS client). The firewall NTP allow rule is narrowed to these addresses,
# published at developers.cloudflare.com/time-services/ntp/usage/ (IPv6 omitted:
# WHD suppresses IPv6).
$script:WHDNtpServer   = 'time.cloudflare.com'
$script:WHDNtpIPs      = @('162.159.200.1','162.159.200.123')
$script:WHDW32TimeKey  = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
# Option 3-B (user decision 2026-09-24): cap how far Windows Time may move the
# clock on its own. Microsoft Learn: stand-alone clients "3600 (1 hour) or
# smaller"; Windows default 54000 s (15 h). A bigger correction is refused and
# logged (System log, Microsoft-Windows-Time-Service event 34) - the update guard
# alerts on it. Secure Time Seeding (UtilizeSslTimeData) is left ON (user choice);
# option N restores all three to Windows defaults.
$script:WHDW32TimeCfgKey   = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config'
$script:WHDTimeJumpLimit   = 3600
$script:WHDTimeJumpDefault = 54000

# Phase 6 blocked-connection logging: advanced-audit subcategory "Filtering
# Platform Connection" (by GUID so it works in any Windows language) -> event
# 5157 in the Security log. REPLACED 2026-09-28 by the Windows Firewall log (section 8).
$script:WHDAuditWfpGuid = '{0CCE9226-69AE-11D9-BED3-505054503030}'
$script:WHDSecLogBytes  = 125829120

# ---- IP blocklist SAFETY GUARD ---------------------------------------------
# Hard lesson: a blocklist that contains 224.0.0.0/3 (broadcast + all multicast)
# or a private/CGNAT range silently breaks DHCP/mDNS/LAN, because Windows applies
# BLOCK rules before ALLOW rules. These ranges must NEVER be turned into block
# rules, so every blocklist line is re-checked here at apply time and skipped if
# it overlaps any of them - no matter what list someone drops in.
$script:WHDNeverBlock = @(
    '0.0.0.0/8','10.0.0.0/8','100.64.0.0/10','127.0.0.0/8','169.254.0.0/16',
    '172.16.0.0/12','192.0.0.0/24','192.0.2.0/24','192.88.99.0/24','192.168.0.0/16',
    '198.18.0.0/15','198.51.100.0/24','203.0.113.0/24','224.0.0.0/4','240.0.0.0/4'
)
function ConvertTo-WHDIpRange {
    # IPv4 CIDR/IP -> @([uint64]start,[uint64]end); $null if not parseable IPv4.
    param([string]$Cidr)
    $ip = $Cidr; $len = 32
    if ($Cidr -match '/') { $parts = $Cidr -split '/', 2; $ip = $parts[0].Trim(); $len = [int]$parts[1] }
    if ($len -lt 0 -or $len -gt 32) { return $null }
    $out = $null
    if (-not [System.Net.IPAddress]::TryParse($ip, [ref]$out)) { return $null }
    if ($out.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $null }
    $b = $out.GetAddressBytes(); [Array]::Reverse($b)
    $base = [uint64]([System.BitConverter]::ToUInt32($b, 0))
    $size = [uint64][math]::Pow(2, 32 - $len)
    $start = $base - ($base % $size)
    return @($start, ($start + $size - 1))
}
function Test-WHDNeverBlock {
    # $true if this entry is unparseable/IPv6 or overlaps a must-never-block range.
    param([string]$Cidr)
    if (-not $script:WHDNeverBlockRanges) {
        $script:WHDNeverBlockRanges = @()
        foreach ($n in $script:WHDNeverBlock) { $r = ConvertTo-WHDIpRange $n; if ($r) { $script:WHDNeverBlockRanges += ,$r } }
    }
    $rng = ConvertTo-WHDIpRange $Cidr
    if (-not $rng) { return $true }
    foreach ($f in $script:WHDNeverBlockRanges) {
        if (($rng[0] -le $f[1]) -and ($rng[1] -ge $f[0])) { return $true }
    }
    return $false
}

# ---- one-time firewall backup (before first firewall change) ----------------
function Backup-WHDFirewallOnce {
    if ($script:WHDFwBackupDone) { return }
    if (-not $script:WHDExecute) { Write-WHDLog 'would: export current firewall policy to restore\ (.wfw)' 'DRY'; return }
    Initialize-WHDPaths
    $out = Join-Path $script:WHDRestore 'firewall-before.wfw'
    # netsh refuses to overwrite an existing file: keep the backup already taken.
    if (Test-Path -LiteralPath $out) {
        Write-WHDLog ("firewall policy backup already present, kept: {0}" -f $out) 'INFO'
        $script:WHDFwBackupDone = $true
        return
    }
    $ne = Invoke-WHDNative -Exe 'netsh.exe' -ArgList @('advfirewall', 'export', $out)
    if ($ne.Code -ne 0 -or -not (Test-Path -LiteralPath $out)) {
        Write-WHDLog ("firewall export failed (netsh exit {0}): {1}" -f $ne.Code, ((@($ne.Out) | Where-Object { $_ }) -join ' ')) 'ERR'
        throw ("firewall policy backup failed (netsh advfirewall export, exit {0}) - the firewall change was not made" -f $ne.Code)
    }
    Write-WHDLog ("firewall policy backed up: {0}" -f $out) 'OK'
    $script:WHDFwBackupDone = $true
}

# ---- small helpers ----------------------------------------------------------
function Get-WHDFwProfiles {
    @(Get-NetFirewallProfile -PolicyStore ActiveStore -EA SilentlyContinue |
        Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction)
}

function Remove-WHDFwGroup {
    param([Parameter(Mandatory)][string]$Group)
    $rules = @(Get-NetFirewallRule -Group $Group -EA SilentlyContinue)
    if (-not $rules) { Write-WHDLog ("no rules in group '{0}'" -f $Group) 'INFO'; return }
    Invoke-WHDChange -Description ("remove {0} firewall rule(s) in group '{1}'" -f $rules.Count, $Group) -Action {
        Backup-WHDFirewallOnce
        Get-NetFirewallRule -Group $Group -EA Stop | Remove-NetFirewallRule -EA Stop
    } | Out-Null      # no result row on the screen (no caller uses it)
}

# Create a rule idempotently (remove same-named first), routed through the engine.
function New-WHDFwRule {
    param([hashtable]$Params, [hashtable]$Journal)
    $name = $Params['Name']
    # A rule name is also used to remove the same-named rule first, and -Name accepts
    # wildcards: refuse an empty name or one containing * ? [ ] before anything is removed.
    if (-not "$name".Trim() -or "$name" -match '[\*\?\[\]]') {
        Write-WHDLog ("firewall rule refused: the rule name '{0}' is empty or contains a wildcard character (* ? [ ]). Nothing was changed for it." -f $name) 'ERR'
        if ($script:WHDExecute) { New-WHDResult -Action ("firewall rule: {0}" -f $name) -Status 'failed' -Detail 'rule name empty or contains a wildcard character' | Out-Null }
        return
    }
    $desc = "firewall rule: {0} [{1}/{2}]" -f $Params['DisplayName'], $Params['Direction'], $Params['Action']
    Invoke-WHDChange -Description $desc -Journal $Journal -Action {
        Backup-WHDFirewallOnce
        $existing = @(Get-NetFirewallRule -Name $name -EA SilentlyContinue)
        if ($existing) { $existing | Remove-NetFirewallRule -EA SilentlyContinue }
        $p = $Params.Clone()
        $p['Confirm']     = $false
        $p['ErrorAction'] = 'Stop'
        New-NetFirewallRule @p | Out-Null
    } | Out-Null
}

# v1.5: what a tool of this menu is about to change of the update gate (text from Updates.ps1; empty when
# that module is not loaded or there is nothing to say). The lines are logged here; Ask goes into the question.
function Write-WHDCrossToolNote {
    param([string]$Tool)
    $ctOut = [pscustomobject]@{ Ask = ''; Before = $null; Pending = @() }
    # (inbound rules listed as not decided now: a wipe / reset / import / restore must not count them as kept)
    try { if ((Get-Command Get-WHDFwKnown -EA SilentlyContinue) -and (Get-WHDFwKnown).Inbound) { $ctOut.Pending = @(Get-WHDForeignRules | Where-Object { -not $_.Leak } | ForEach-Object { "$($_.Name)" }) } } catch { }
    try {
        if (-not (Get-Command Get-WHDCrossToolNote -EA SilentlyContinue)) { return $ctOut }
        $ctOut.Before = Get-WHDGateState
        $ctN = Get-WHDCrossToolNote -Tool $Tool
        foreach ($ctL in @($ctN.Lines)) { Write-WHDLog $ctL 'WARN' }
        $ctOut.Ask = "$($ctN.Ask)"
    } catch { }
    return $ctOut
}

# =============================================================================
#  1) IPv6 SUPPRESSION  (D2: adapter unbind + registry + firewall block rules)
# =============================================================================
function Invoke-WHDDisableIPv6 {
    param([switch]$BlockLoopback,   # off by default; strict + risky
          [switch]$NoConfirm)       # set by WHD's own callers that already asked
    Write-Host ''
    Write-WHDLog 'IPv6 suppression (adapter binding + registry + firewall block rules)' 'ACT'
    Write-WHDRisk 'caution' 'Disables IPv6 on network adapters and blocks routable IPv6. Reversible.'
    if ($BlockLoopback) { Write-WHDRisk 'hard' 'ALSO blocking ::1 loopback - may break local apps that use IPv6 to talk to themselves.' }
    if (-not $NoConfirm -and -not (Confirm-WHDProceed 'suppress IPv6 (adapter binding + registry + firewall block rules)')) { Write-WHDLog 'skipped.' 'WARN'; return }

    # (a) unbind IPv6 from every adapter
    $bind = @(Get-NetAdapterBinding -ComponentID ms_tcpip6 -EA SilentlyContinue | Where-Object { $_.Enabled })
    if ($bind.Count -gt 0) {
        Invoke-WHDChange -Description ("unbind IPv6 (ms_tcpip6) from {0} adapter(s)" -f $bind.Count) -Action {
            Backup-WHDFirewallOnce
            Disable-NetAdapterBinding -Name '*' -ComponentID ms_tcpip6 -EA Stop
        } | Out-Null
    } else { Write-WHDLog 'IPv6 already unbound from all adapters.' 'INFO' }

    # (b) registry: 0xFF disables all IPv6 interfaces EXCEPT loopback, prefers IPv4
    Set-WHDRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' `
        -Name 'DisabledComponents' -Value 0xFF -Type DWord | Out-Null

    # (c) firewall block rules for routable IPv6 (belt-and-suspenders)
    foreach ($dir in @('Inbound','Outbound')) {
        New-WHDFwRule @{ Name = "WHD-IPv6-$dir"; DisplayName = "WHD Block IPv6 ($dir)";
            Group = $script:WHDFwGroupIPv6; Direction = $dir; Action = 'Block'; Enabled = 'True';
            Profile = 'Any'; RemoteAddress = $script:WHDIPv6Ranges }
        New-WHDFwRule @{ Name = "WHD-ICMPv6-$dir"; DisplayName = "WHD Block ICMPv6 ($dir)";
            Group = $script:WHDFwGroupIPv6; Direction = $dir; Action = 'Block'; Enabled = 'True';
            Profile = 'Any'; Protocol = 'ICMPv6' }
    }

    if ($BlockLoopback) {
        foreach ($dir in @('Inbound','Outbound')) {
            New-WHDFwRule @{ Name = "WHD-IPv6-Loopback-$dir"; DisplayName = "WHD Block IPv6 loopback ::1 ($dir)";
                Group = $script:WHDFwGroupIPv6; Direction = $dir; Action = 'Block'; Enabled = 'True';
                Profile = 'Any'; RemoteAddress = '::1' }
        }
    }
    Write-WHDLog 'IPv6 suppression planned/applied.' 'OK'
}

function Invoke-WHDEnableIPv6 {
    Write-WHDLog 'Re-enabling IPv6 (undo suppression).' 'ACT'
    if (-not (Confirm-WHDProceed 're-enable IPv6 (adapter binding + registry, remove the WHD IPv6 block rules)')) { Write-WHDLog 'skipped.' 'WARN'; return }
    $bind = @(Get-NetAdapterBinding -ComponentID ms_tcpip6 -EA SilentlyContinue | Where-Object { -not $_.Enabled })
    if ($bind.Count -gt 0) {
        Invoke-WHDChange -Description ("re-bind IPv6 to {0} adapter(s)" -f $bind.Count) -Action {
            Enable-NetAdapterBinding -Name '*' -ComponentID ms_tcpip6 -EA Stop
        } | Out-Null
    }
    Set-WHDRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' `
        -Name 'DisabledComponents' -Value 0x00 -Type DWord | Out-Null
    Remove-WHDFwGroup -Group $script:WHDFwGroupIPv6
    Write-WHDLog 'IPv6 re-enabled.' 'OK'
}

# =============================================================================
#  2) CLEANER RULE LISTING  (read-only)
# =============================================================================
function Show-WHDFirewallSummary {
    Write-Host ''
    Write-Host '  --- Firewall profiles ---' -ForegroundColor White
    $profs = Get-WHDFwProfiles
    foreach ($p in $profs) {
        $col = if ($p.Enabled) { 'Green' } else { 'Red' }
        Write-Host ('   {0,-8} on={1,-5} in={2,-6} out={3}' -f $p.Name, $p.Enabled, $p.DefaultInboundAction, $p.DefaultOutboundAction) -ForegroundColor $col
    }
    $all = @(Get-NetFirewallRule -EA SilentlyContinue)
    $en  = @($all | Where-Object { $_.Enabled -eq 'True' })
    Write-Host ''
    Write-Host ('  Rules: {0} total, {1} enabled' -f $all.Count, $en.Count) -ForegroundColor White
    Write-Host ('   inbound  {0,4}   |  allow {1,4}' -f @($all | ? {$_.Direction -eq 'Inbound'}).Count, @($all | ? {$_.Action -eq 'Allow'}).Count)
    Write-Host ('   outbound {0,4}   |  block {1,4}' -f @($all | ? {$_.Direction -eq 'Outbound'}).Count, @($all | ? {$_.Action -eq 'Block'}).Count)
    foreach ($g in @(Get-WHDFwOwnGroups)) {      # v1.5: the update gate's own rules are counted too
        $c = @(Get-NetFirewallRule -Group $g -EA SilentlyContinue).Count
        if ($c -gt 0) { Write-Host ('   {0,-28} {1} rule(s)' -f $g, $c) -ForegroundColor Cyan }
    }
    # The update gate position (read-only; reading it creates nothing).
    if (Get-Command Get-WHDGateState -EA SilentlyContinue) {
        try { Write-Host ('   Update gate   : {0}' -f (Get-WHDGateState).Text) -ForegroundColor Gray } catch { }
    }
    # v1.5: the gate is not what its record says / an allow rule that WHD did not make is ON (read-only)
    Show-WHDFwAttentionLines
    # Live DNS readout so you can confirm the adapter is on the pinned resolver.
    $dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 -EA SilentlyContinue | Where-Object { @($_.ServerAddresses).Count -gt 0 })
    if ($dns.Count) {
        Write-Host ''
        Write-Host '  --- DNS servers (per adapter, IPv4) ---' -ForegroundColor White
        foreach ($d in $dns) {
            $srv  = (@($d.ServerAddresses) -join ', ')
            $col  = if ($srv -match '(^|[ ,])1\.(1\.1|0\.0)\.') { 'Green' } else { 'Yellow' }
            Write-Host ('   {0,-24} {1}' -f $d.InterfaceAlias, $srv) -ForegroundColor $col
        }
        # encrypted-DNS (DoH) status for the pinned resolvers
        if (Get-Command Get-DnsClientDohServerAddress -EA SilentlyContinue) {
            $doh = @(Get-DnsClientDohServerAddress -EA SilentlyContinue | Where-Object { $script:WHDDnsServers -contains "$($_.ServerAddress)" })
            if ($doh.Count) { Write-Host ('   DoH encrypted           {0}' -f (@($doh | ForEach-Object { "$($_.ServerAddress)" }) -join ', ')) -ForegroundColor Green }
            else            { Write-Host '   DoH encrypted           (not configured)' -ForegroundColor DarkGray }
        }
        Write-Host '   (green = pinned Cloudflare resolver in use)' -ForegroundColor DarkGray
    }
    # Live time (NTP) readout, right under DNS, same style.
    Write-Host ''
    Write-Host '  --- Time sync (NTP) ---' -ForegroundColor White
    $ntpSet = Get-WHDRegValueState -Path $script:WHDW32TimeKey -Name 'NtpServer'
    $ntpTxt = if ($ntpSet.Exists) { "$($ntpSet.Value)" } else { '(not set)' }
    $ntpCol = if ($ntpTxt -match [regex]::Escape($script:WHDNtpServer)) { 'Green' } else { 'Yellow' }
    Write-Host ('   {0,-24} {1}' -f 'Time server', $ntpTxt) -ForegroundColor $ntpCol
    $tj = Get-WHDTimeJumpState
    Write-Host ('   {0,-24} {1}{2}' -f 'Time-jump limit', $tj.Text, $(if ($tj.Limited) { '' } else { '  (Windows default)' })) -ForegroundColor $(if ($tj.Limited) { 'Green' } else { 'Yellow' })
    Write-Host ('   {0,-24} {1}' -f 'Secure Time Seeding', $(if ($tj.Seeding) { 'on' } else { 'off' })) -ForegroundColor Gray
    $svc = Get-Service -Name w32time -EA SilentlyContinue
    if ($svc) {
        $dl = Get-WHDRegValueState -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time' -Name 'DelayedAutostart'
        $stTxt = "$($svc.StartType)"
        if ($stTxt -eq 'Automatic' -and $dl.Exists -and [int]$dl.Value -eq 1) { $stTxt = 'Automatic (delayed)' }
        $svcCol = if ($svc.Status -eq 'Running') { 'Green' } else { 'Yellow' }
        Write-Host ('   {0,-24} {1}, {2}' -f 'Windows Time service', $svc.Status, $stTxt) -ForegroundColor $svcCol
    }
    if ($svc -and $svc.Status -eq 'Running') {
        $src = Invoke-WHDNative -Exe 'w32tm.exe' -ArgList @('/query', '/source')
        $srcTxt = (@($src.Out | Where-Object { $_.Trim() }) -join ' ').Trim()
        $srcCol = if ($srcTxt -match [regex]::Escape($script:WHDNtpServer)) { 'Green' } else { 'Yellow' }
        Write-Host ('   {0,-24} {1}' -f 'Source in use', $srcTxt) -ForegroundColor $srcCol
    }
    $ntpRule = @(Get-NetFirewallRule -Name 'WHD-Allow-NTP' -EA SilentlyContinue)
    if ($ntpRule) {
        $af = $ntpRule[0] | Get-NetFirewallAddressFilter -EA SilentlyContinue
        $ra = (@($af.RemoteAddress) -join ', ')
        $raCol = if ($ra -eq ($script:WHDNtpIPs -join ', ')) { 'Green' } else { 'Yellow' }
        Write-Host ('   {0,-24} UDP 123 -> {1}' -f 'Firewall NTP allow', $ra) -ForegroundColor $raCol
    }
    Write-Host '   (green = time.cloudflare.com in use, 1 h jump limit, service running, UDP 123 pinned)' -ForegroundColor DarkGray
}

# Returns clean rule objects. -Detail joins port/address/program filters (slower).
function Get-WHDFirewallRules {
    param(
        [ValidateSet('Any','Inbound','Outbound')]$Direction = 'Any',
        [ValidateSet('Any','Allow','Block')]$Action = 'Any',
        [switch]$EnabledOnly,
        [switch]$CustomOnly,   # hide Microsoft store-signed built-ins
        [switch]$Detail
    )
    $rules = @(Get-NetFirewallRule -EA SilentlyContinue)
    if ($Direction -ne 'Any') { $rules = @($rules | Where-Object { $_.Direction -eq $Direction }) }
    if ($Action    -ne 'Any') { $rules = @($rules | Where-Object { $_.Action    -eq $Action }) }
    if ($EnabledOnly)         { $rules = @($rules | Where-Object { $_.Enabled -eq 'True' }) }
    # "custom" = not owned by a Store app (Owner empty) and not a built-in whose
    # group is an indirect string resource (DisplayGroup starting with '@').
    if ($CustomOnly)          { $rules = @($rules | Where-Object {
                                    [string]::IsNullOrEmpty($_.Owner) -and ($_.DisplayGroup -notlike '@*') }) }
    $out = foreach ($r in $rules) {
        $o = [ordered]@{ Name=$r.Name; DisplayName=$r.DisplayName; Group=$r.DisplayGroup;
            Dir=$r.Direction; Action=$r.Action; Enabled=$r.Enabled; Profile=$r.Profile }
        if ($Detail) {
            $pf = $r | Get-NetFirewallPortFilter -EA SilentlyContinue
            $af = $r | Get-NetFirewallAddressFilter -EA SilentlyContinue
            $ap = $r | Get-NetFirewallApplicationFilter -EA SilentlyContinue
            $o['Protocol']  = $pf.Protocol
            $o['LocalPort'] = ($pf.LocalPort  -join ',')
            $o['RemotePort']= ($pf.RemotePort -join ',')
            $o['RemoteIP']  = ($af.RemoteAddress -join ',')
            $o['Program']   = $ap.Program
        }
        [pscustomobject]$o
    }
    @($out)
}

# =============================================================================
#  3) RESET TO A CLEAN BASELINE
# =============================================================================
function Invoke-WHDFirewallReset {
    param([switch]$ApplyBaseline)
    Write-WHDLog 'Reset firewall to Windows defaults (clean slate).' 'ACT'
    Write-WHDRisk 'hard' 'netsh advfirewall reset - removes ALL custom rules; a .wfw backup is taken first.'
    $script:WHDFwToolStatus = 'skipped'
    $whdRsNote = Write-WHDCrossToolNote -Tool 'reset'      # v1.5: says what this does to the update gate / default-deny
    if (-not (Confirm-WHDProceed ('reset the firewall to Windows defaults (removes ALL custom rules)' + $whdRsNote.Ask))) { Write-WHDLog 'skipped.' 'WARN'; return }
    $whdRsRes = Invoke-WHDChange -Description 'netsh advfirewall reset (restore default policy)' -Action {
        Backup-WHDFirewallOnce
        $whdRsN = Invoke-WHDNative -Exe 'netsh.exe' -ArgList @('advfirewall', 'reset')
        if ($whdRsN.Code -ne 0) { throw ("netsh advfirewall reset failed (exit {0}): {1}" -f $whdRsN.Code, ((@($whdRsN.Out) | Where-Object { $_ }) -join ' ')) }
    } | Select-Object -Last 1
    $script:WHDFwToolStatus = "$($whdRsRes.Status)"
    if ($script:WHDExecute -and "$($whdRsRes.Status)" -ne 'done') { Write-WHDLog 'Firewall reset NOT done - see the line above. Nothing else was changed.' 'ERR'; return }
    Invoke-WHDChange -Description 'enable firewall on all profiles; inbound Block / outbound Allow' -Action {
        Set-NetFirewallProfile -All -Enabled True -DefaultInboundAction Block -DefaultOutboundAction Allow -Confirm:$false -EA Stop
    } | Out-Null
    if ($ApplyBaseline) { Invoke-WHDFirewallAllowList -NoConfirm; Invoke-WHDDisableIPv6 -NoConfirm }
    if ($script:WHDExecute -and "$($whdRsRes.Status)" -eq 'done') {
        # v1.5: the gate's record is put right (a reset opens the gate), and Windows' own rules count as put in by you
        if (Get-Command Update-WHDGateAfterFirewallChange -EA SilentlyContinue) { Update-WHDGateAfterFirewallChange -Before $whdRsNote.Before -What 'the firewall reset' }
        Set-WHDFwKnownFromNow -Why 'reset' -Pending $whdRsNote.Pending
    }
    if ($script:WHDExecute) { Write-WHDLog 'Firewall reset complete.' 'OK' } else { Write-WHDLog 'DRY-RUN: preview only - the firewall was not reset.' 'DRY' }
}

# Empty slate: delete EVERY rule (Microsoft defaults included) so only what you
# add afterward exists. Firewall stays ON; default actions unchanged.
# This is different from RESET (which repopulates Windows' stock rules).
function Invoke-WHDFirewallWipe {
    param([switch]$ApplyBaseline)
    $script:WHDFwToolStatus = 'skipped'
    $all = @(Get-NetFirewallRule -EA SilentlyContinue)
    Write-WHDLog ('WIPE ALL firewall rules (empty slate) - {0} rule(s) present.' -f $all.Count) 'ACT'
    Write-WHDRisk 'hard' 'Deletes EVERY inbound/outbound rule, Windows defaults included. The firewall stays ON and the default inbound/outbound actions are not changed. A .wfw backup is taken first; protected rules are skipped.'
    # (with the update gate CLOSED / on PROGRAMS the gate's own note below says this, and more)
    $whdWpGate = $false
    if (Get-Command Test-WHDGateClosed -EA SilentlyContinue) { try { $whdWpGate = [bool](Test-WHDGateClosed) } catch { $whdWpGate = $false } }
    if (-not $ApplyBaseline -and -not $whdWpGate -and -not (Get-Command Get-WHDCrossToolNote -EA SilentlyContinue) -and (@(Get-WHDFwProfiles | ForEach-Object { "$($_.DefaultOutboundAction)" }) -contains 'Block')) {
        Write-WHDLog 'Outbound is Block (default-deny) now: wiping also deletes the WHD allow rules, so there is NO network until the allow-list is applied again (Firewall 5) or default-deny is reverted (Firewall 8; Updates O if the update gate is closed).' 'WARN'
    }
    $whdWpNote = Write-WHDCrossToolNote -Tool 'wipe'       # v1.5: says what this does to the update gate and the program allows
    $what = if ($ApplyBaseline) { 'delete ALL firewall rules, then apply the WHD baseline' } else { 'delete ALL firewall rules (empty slate)' }
    $whdWpAsk = "$($whdWpNote.Ask)"
    if ($ApplyBaseline -and $whdWpAsk -match 'NO network') { $whdWpAsk = '' }      # (the baseline right after the wipe puts the allow-list back)
    if (-not (Confirm-WHDProceed ($what + $whdWpAsk))) { Write-WHDLog 'skipped.' 'WARN'; return }
    $script:WHDFwWipeKept = 0
    $whdWipeRes = Invoke-WHDChange -Description ("delete ALL {0} firewall rule(s) - empty slate" -f $all.Count) -Action {
        Backup-WHDFirewallOnce
        # Deleting several hundred rules one by one takes a while: show progress.
        $whdWipeRules = @(Get-NetFirewallRule -EA SilentlyContinue)
        $whdWipeN = 0; $whdWipeKept = 0
        if ($whdWipeRules.Count -gt 50) { Write-WHDLog ('  deleting {0} rule(s) one by one - this can take several minutes; progress is shown' -f $whdWipeRules.Count) 'INFO' }
        foreach ($r in $whdWipeRules) {
            $whdWipeN++
            try { $r | Remove-NetFirewallRule -EA Stop } catch { $whdWipeKept++ }      # (the rule itself, not its name: -Name would read * ? [ ] in a name as a pattern)
            try { Write-WHDProgressStep -Activity 'Deleting firewall rules' -Done $whdWipeN -Total $whdWipeRules.Count -Every 50 } catch { }
        }
        $script:WHDFwWipeKept = $whdWipeKept
        if ($whdWipeKept) { Write-WHDLog ('  {0} rule(s) could not be deleted and were left in place' -f $whdWipeKept) 'INFO' }
    } | Select-Object -Last 1
    $script:WHDFwToolStatus = "$($whdWipeRes.Status)"
    if ($ApplyBaseline) {
        $p = Join-Path $script:WHDRoot 'profiles\firewall-baseline.json'
        if (Test-Path $p) { Invoke-WHDApplyFirewallProfile -Path $p -NoConfirm }
        else { Write-WHDLog 'firewall-baseline.json not found; wipe only.' 'WARN' }
    }
    if ($script:WHDExecute -and "$($whdWipeRes.Status)" -eq 'done') {
        # v1.5: the gate's list of switched-off rules is brought in line (they are deleted), the gate says what it is
        # missing now, and the kept list starts fresh: what is left after a wipe is what you put in.
        # (The question "set the gate again" is asked by the caller: Invoke-WHDGateRepairOffer.)
        if (Get-Command Update-WHDGateAfterFirewallChange -EA SilentlyContinue) { Update-WHDGateAfterFirewallChange -Before $whdWpNote.Before -What 'the wipe' }
        Set-WHDFwKnownFromNow -Why 'wipe' -Pending $whdWpNote.Pending
    }
    # A dry run must not say the wipe happened; a wipe that left rules in place says so.
    switch ("$($whdWipeRes.Status)") {
        'done'    {
            if ([int]$script:WHDFwWipeKept -gt 0) { Write-WHDLog ('Wipe complete, except {0} rule(s) that could not be deleted and were left in place. Apart from those, only rules added after this exist.' -f $script:WHDFwWipeKept) 'OK' }
            else { Write-WHDLog 'Wipe complete. Only rules added after this exist.' 'OK' }
        }
        'planned' { Write-WHDLog 'DRY-RUN: preview only - nothing was deleted. Switch to EXECUTE to wipe for real.' 'DRY' }
        default   { Write-WHDLog 'Wipe NOT done - see the lines above.' 'WARN' }
    }
}

# =============================================================================
#  4) OFFLINE DEPLOY - EXPORT / IMPORT  (D3: BOTH json + .wfw)
# =============================================================================
function Export-WHDFirewallPolicy {
    param([string]$Path)   # base path; writes <base>.wfw and <base>.json
    if (-not $Path) { Initialize-WHDPaths; $Path = Join-Path $script:WHDRestore 'firewall-policy' }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $wfw = "$Path.wfw"; $json = "$Path.json"

    Invoke-WHDChange -Description ("export full firewall policy -> {0}" -f $wfw) -Action {
        & netsh advfirewall export "$wfw" 1>$null 2>$null
    } | Out-Null

    # JSON = only OUR groups, re-appliable and human-editable
    $groups = @($script:WHDFwGroupIPv6,$script:WHDFwGroupAllow,$script:WHDFwGroupBlock,$script:WHDFwGroupBase,$script:WHDFwGroupApp)
    $rules  = foreach ($g in $groups) {
        foreach ($r in @(Get-NetFirewallRule -Group $g -EA SilentlyContinue)) {
            $pf = $r | Get-NetFirewallPortFilter -EA SilentlyContinue
            $af = $r | Get-NetFirewallAddressFilter -EA SilentlyContinue
            $ap = $r | Get-NetFirewallApplicationFilter -EA SilentlyContinue
            [ordered]@{ name=$r.Name; displayName=$r.DisplayName; group=$r.DisplayGroup;
                direction="$($r.Direction)"; action="$($r.Action)"; enabled="$($r.Enabled)"; profile="$($r.Profile)";
                protocol="$($pf.Protocol)"; localPort=@($pf.LocalPort); remotePort=@($pf.RemotePort);
                remoteAddress=@($af.RemoteAddress); program=$ap.Program }
        }
    }
    $doc = [ordered]@{ generated=(Get-Date -Format 's'); host=$env:COMPUTERNAME; rules=@($rules) }
    if (-not $script:WHDExecute) { Write-WHDLog ("would: write {0} ({1} WHD rule(s))" -f $json, @($rules).Count) 'DRY' }
    else {
        $doc | ConvertTo-Json -Depth 6 | Set-Content -Path $json -Encoding UTF8
        Write-WHDLog ("wrote {0} ({1} WHD rule(s))" -f $json, @($rules).Count) 'OK'
    }
}

function Import-WHDFirewallPolicy {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Json','Wfw')]$Mode = 'Json'
    )
    $script:WHDFwToolStatus = 'skipped'
    if (-not (Test-Path $Path)) { Write-WHDLog ("import file not found: {0}" -f $Path) 'ERR'; return }
    $what = if ($Mode -eq 'Wfw') { "replace the ENTIRE firewall policy with {0}" -f $Path } else { "create or replace the firewall rules listed in {0}" -f $Path }
    $whdImNote = [pscustomobject]@{ Ask = ''; Before = $null; Pending = @() }
    if ($Mode -eq 'Wfw') { $whdImNote = Write-WHDCrossToolNote -Tool 'wfw' }      # v1.5: says what this does to the update gate
    if (-not (Confirm-WHDProceed ($what + $whdImNote.Ask))) { Write-WHDLog 'skipped.' 'WARN'; return }
    if ($Mode -eq 'Wfw') {
        $whdImRes = Invoke-WHDChange -Description ("import firewall policy blob: {0}" -f $Path) -Action {
            Backup-WHDFirewallOnce
            $whdImN = Invoke-WHDNative -Exe 'netsh.exe' -ArgList @('advfirewall', 'import', "$Path")
            if ($whdImN.Code -ne 0) { throw ("netsh advfirewall import failed (exit {0}): {1}" -f $whdImN.Code, ((@($whdImN.Out) | Where-Object { $_ }) -join ' ')) }
        } | Select-Object -Last 1
        $script:WHDFwToolStatus = "$($whdImRes.Status)"
        if ($script:WHDExecute -and "$($whdImRes.Status)" -ne 'done') { Write-WHDLog 'Import NOT done - see the line above. The firewall is as it was.' 'ERR' }
        if ($script:WHDExecute -and "$($whdImRes.Status)" -eq 'done') {
            # v1.5: read where the gate stands now and put its record right; the imported rules count as put in by you.
            # (The question "set the gate again" is asked by the caller: Invoke-WHDGateRepairOffer.)
            if (Get-Command Update-WHDGateAfterFirewallChange -EA SilentlyContinue) { Update-WHDGateAfterFirewallChange -Before $whdImNote.Before -What 'the import' }
            Set-WHDFwKnownFromNow -Why 'import' -Pending $whdImNote.Pending
        }
        return
    }
    $doc = Get-Content -Path $Path -Raw | ConvertFrom-Json
    foreach ($r in @($doc.rules)) {
        $p = @{ Name=$r.name; DisplayName=$r.displayName; Group=$r.group;
            Direction=$r.direction; Action=$r.action; Enabled=$r.enabled; Profile=$r.profile }
        if ($r.protocol)      { $p['Protocol']      = $r.protocol }
        if (@($r.localPort))  { $p['LocalPort']     = @($r.localPort) }
        if (@($r.remotePort)) { $p['RemotePort']    = @($r.remotePort) }
        if (@($r.remoteAddress) -and @($r.remoteAddress).Count){ $p['RemoteAddress'] = @($r.remoteAddress) }
        if ($r.program)       { $p['Program']       = $r.program }
        New-WHDFwRule $p
    }
    # v1.5: an imported file may switch on rules the update gate keeps off. Put that right, as the allow-list does.
    if ((Get-Command Test-WHDGateClosed -EA SilentlyContinue) -and (Test-WHDGateClosed)) {
        $whdImpMode = "$((Get-WHDGateState).Mode)"
        $whdImpApps = @()
        if ($whdImpMode -ne 'programs') {
            $whdImpApps = @(Get-NetFirewallRule -Group $script:WHDFwGroupApp -EA SilentlyContinue | Where-Object { "$($_.Enabled)" -eq 'True' } | ForEach-Object { "$($_.Name)" })
        }
        Invoke-WHDChange -Description ("update gate is {0}: keep WHD-Allow-HTTPS / WHD-Allow-HTTP switched off{1}" -f $whdImpMode.ToUpper(), $(if ($whdImpApps.Count) { " and switch off {0} imported program allow(s)" -f $whdImpApps.Count } else { '' })) -Force -Action {
            foreach ($rn in @('WHD-Allow-HTTPS','WHD-Allow-HTTP')) { Set-NetFirewallRule -Name $rn -Enabled False -EA SilentlyContinue }
            foreach ($rn in $whdImpApps) { Set-NetFirewallRule -Name $rn -Enabled False -EA SilentlyContinue }
            if ($whdImpApps.Count -and (Get-Command Add-WHDGateRemembered -EA SilentlyContinue)) { Add-WHDGateRemembered -Names $whdImpApps }
        } | Out-Null
    }
    Write-WHDLog ("imported {0} rule(s) from {1}" -f @($doc.rules).Count, $Path) 'OK'
}

# =============================================================================
#  5) ALLOW-LIST + STAGED DEFAULT-DENY OUTBOUND  (D4: design toward strict)
# =============================================================================
# The allow-list is harmless while outbound default is Allow; it PRE-STAGES the
# rules so flipping to default-deny later does not lock the box out.
function Invoke-WHDFirewallAllowList {
    param([switch]$NoConfirm)   # set by WHD's own callers that already asked
    Write-WHDLog ('Applying essential ALLOW-list (DNS pinned to {0}).' -f ($script:WHDDnsServers -join ', ')) 'ACT'
    if (-not $NoConfirm -and -not (Confirm-WHDProceed 'rebuild the WHD outbound allow-list (DNS, DHCP, NTP, HTTP/HTTPS)')) { Write-WHDLog 'skipped.' 'WARN'; return }
    # Rebuild cleanly so re-applying is idempotent (re-adds are authoritative).
    Remove-WHDFwGroup -Group $script:WHDFwGroupAllow
    # DNS pinned to the chosen resolver; HTTP/HTTPS open to Any so browsing + WU work.
    # DHCP needs BOTH directions: out (client 68 -> server 67) AND in (server reply
    # back to 68). The inbound half is what Windows' stock "Core Networking DHCP-In"
    # provides and a full WIPE removes - without it a locked-down box can't renew its
    # lease. dir defaults to Outbound when omitted.
    $allow = @(
        @{ n='WHD-Allow-DNS-UDP';  d='WHD Allow DNS (UDP 53)';                  proto='UDP'; rport=53;  raddr=$script:WHDDnsServers }
        @{ n='WHD-Allow-DNS-TCP';  d='WHD Allow DNS (TCP 53)';                  proto='TCP'; rport=53;  raddr=$script:WHDDnsServers }
        @{ n='WHD-Allow-DHCP-Out'; d='WHD Allow DHCP request (UDP out 68->67)'; proto='UDP'; lport=68; rport=67 }
        @{ n='WHD-Allow-DHCP-In';  d='WHD Allow DHCP reply (UDP in <-67)';      dir='Inbound'; proto='UDP'; lport=68; rport=67 }
        @{ n='WHD-Allow-NTP';      d='WHD Allow NTP (UDP 123)';                 proto='UDP'; rport=123; raddr=(Get-WHDNtpRemoteAddress) }
        @{ n='WHD-Allow-HTTPS';    d='WHD Allow HTTPS (TCP 443)';               proto='TCP'; rport=443 }
        @{ n='WHD-Allow-HTTP';     d='WHD Allow HTTP (TCP 80)';                 proto='TCP'; rport=80  }
    )
    foreach ($a in $allow) {
        $dir = if ($a.dir) { $a.dir } else { 'Outbound' }
        $p = @{ Name=$a.n; DisplayName=$a.d; Group=$script:WHDFwGroupAllow;
            Direction=$dir; Action='Allow'; Enabled='True'; Profile='Any'; Protocol=$a.proto }
        if ($a.rport) { $p['RemotePort'] = $a.rport }
        if ($a.lport) { $p['LocalPort']  = $a.lport }
        if ($a.raddr) { $p['RemoteAddress'] = $a.raddr }
        New-WHDFwRule $p
    }
    # v1.1: with the update gate CLOSED or on PROGRAMS, the any-program web rules stay OFF.
    if ((Get-Command Test-WHDGateClosed -EA SilentlyContinue) -and (Test-WHDGateClosed)) {
        $whdGateName = "$((Get-WHDGateState).Mode)".ToUpper()
        Invoke-WHDChange -Description ("update gate is {0}: keep WHD-Allow-HTTPS / WHD-Allow-HTTP switched off" -f $whdGateName) -Force -Action {
            foreach ($rn in @('WHD-Allow-HTTPS','WHD-Allow-HTTP')) { Set-NetFirewallRule -Name $rn -Enabled False -EA SilentlyContinue }
        } | Out-Null
        Write-WHDLog ("Allow-list applied (update gate {0}: the any-program HTTP/HTTPS rules stay off)." -f $whdGateName) 'OK'
        return
    }
    Write-WHDLog 'Allow-list applied. DHCP in+out, DNS pinned, HTTP/HTTPS open. Re-apply rebuilds this group.' 'OK'
}

function Invoke-WHDSetDns {
    # Point system DNS at the pinned resolver AND turn on encrypted DNS (DoH) so
    # lookups can't be read or tampered with on the wire. This also does the domain
    # reputation blocking (plan C) at the resolver instead of a host sinkhole.
    # -NoDoH sets plaintext DNS only. DoH rides on 443, which the allow-list permits.
    param([ValidateSet('Cloudflare','Reset')]$Mode = 'Cloudflare', [switch]$NoDoH)
    $adapters = @(Get-NetAdapter -EA SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
    if (-not $adapters.Count) { Write-WHDLog 'no up network adapters found.' 'WARN'; return }
    $hasDoH = [bool](Get-Command Add-DnsClientDohServerAddress -EA SilentlyContinue)
    $what = if ($Mode -eq 'Cloudflare') { "set system DNS to {0} on {1} up adapter(s)" -f ($script:WHDDnsServers -join ', '), $adapters.Count } else { "reset system DNS to automatic (DHCP) on {0} up adapter(s)" -f $adapters.Count }
    if ($Mode -eq 'Reset') { $what += (Write-WHDCrossToolNote -Tool 'dnsreset').Ask }      # v1.5: with outbound Block, name lookups stop
    if (-not (Confirm-WHDProceed $what)) { Write-WHDLog 'skipped.' 'WARN'; return }

    if ($Mode -eq 'Cloudflare') {
        if (-not $NoDoH -and $hasDoH) {
            foreach ($ip in $script:WHDDnsServers) {
                Invoke-WHDChange -Description ("register encrypted DNS (DoH) for {0}" -f $ip) -Action {
                    if (Get-DnsClientDohServerAddress -ServerAddress $ip -EA SilentlyContinue) {
                        Set-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $script:WHDDohTemplate -AllowFallbackToUdp $false -AutoUpgrade $true -EA Stop
                    } else {
                        Add-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $script:WHDDohTemplate -AllowFallbackToUdp $false -AutoUpgrade $true -EA Stop
                    }
                } | Out-Null
            }
        } elseif (-not $NoDoH) {
            Write-WHDLog 'DoH cmdlets not present on this build; setting plain DNS only.' 'WARN'
        }
        Invoke-WHDChange -Description ("set system DNS to {0} on {1} up adapter(s)" -f ($script:WHDDnsServers -join ','), $adapters.Count) -Action {
            foreach ($a in $adapters) { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $script:WHDDnsServers -EA Stop }
        } | Out-Null
        Write-WHDLog ('System DNS -> {0} (Cloudflare malware filter){1}.' -f ($script:WHDDnsServers -join ', '), $(if($hasDoH -and -not $NoDoH){' over encrypted DoH'}else{' (plaintext)'})) 'OK'
    } else {
        Invoke-WHDChange -Description ("reset system DNS to automatic (DHCP) on {0} up adapter(s)" -f $adapters.Count) -Action {
            foreach ($a in $adapters) { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -EA Stop }
        } | Out-Null
        if ($hasDoH) {
            foreach ($ip in $script:WHDDnsServers) {
                Invoke-WHDChange -Description ("remove DoH registration for {0}" -f $ip) -Action {
                    if (Get-DnsClientDohServerAddress -ServerAddress $ip -EA SilentlyContinue) {
                        Remove-DnsClientDohServerAddress -ServerAddress $ip -Confirm:$false -EA Stop
                    }
                } | Out-Null
            }
        }
        Write-WHDLog 'System DNS reset to automatic (DHCP); DoH registrations removed.' 'OK'
    }
}

# schtasks helpers. PS 5.1 + Start-Transcript + $ErrorActionPreference='Stop'
# turns a native stderr write (e.g. deleting a task that isn't there) into a
# TERMINATING error that crashes the app. These run schtasks non-terminating and
# return only its exit code, so a missing task is a no-op, never a crash.
function Invoke-WHDSchtasks {
    param([Parameter(Mandatory)][string[]]$TaskArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try   { $null = & schtasks.exe @TaskArgs 2>&1; return $LASTEXITCODE }
    catch { return 1 }
    finally { $ErrorActionPreference = $prev }
}
function Test-WHDRollbackTask {
    return ((Invoke-WHDSchtasks @('/query','/tn',$script:WHDFwRollbackTask)) -eq 0)
}
function Remove-WHDRollbackTask {
    if (Test-WHDRollbackTask) { [void](Invoke-WHDSchtasks @('/delete','/tn',$script:WHDFwRollbackTask,'/f')) }
}

# $true when the essential allow rules (DNS + DHCP request) exist and are enabled.
# An allow-list group that only holds e.g. WHD-Allow-NTP is NOT ready.
function Test-WHDAllowListReady {
    foreach ($rn in @('WHD-Allow-DNS-UDP', 'WHD-Allow-DNS-TCP', 'WHD-Allow-DHCP-Out')) {
        if (-not @(Get-NetFirewallRule -Name $rn -EA SilentlyContinue | Where-Object { "$($_.Enabled)" -eq 'True' }).Count) { return $false }
    }
    return $true
}

function Enable-WHDDefaultDenyOutbound {
    param([int]$RollbackMinutes = 10, [switch]$NoConfirm)
    Write-Host ''
    Write-WHDLog 'Enable DEFAULT-DENY OUTBOUND (strict).' 'ACT'
    if ($RollbackMinutes -lt 1 -or $RollbackMinutes -gt 720) {
        Write-WHDLog ("auto-rollback minutes must be 1 to 720 (got {0}) - using 10." -f $RollbackMinutes) 'WARN'
        $RollbackMinutes = 10
    }
    # v1.5: while the update gate is CLOSED or on PROGRAMS, outbound is already default-deny and the gate keeps it
    # that way. Arming the auto-rollback here would set outbound back to Allow after the minutes ran out and so
    # open the gate without a word. Nothing to do.
    if ((Get-Command Test-WHDGateClosed -EA SilentlyContinue) -and (Test-WHDGateClosed)) {
        Write-WHDLog ("The update gate is {0}: outbound is already default-deny and the gate keeps it that way. Nothing was changed and no auto-rollback was armed. To change it, use the Updates menu (O = open the gate)." -f "$((Get-WHDGateState).Mode)".ToUpper()) 'INFO'
        return
    }
    Write-WHDRisk 'hard' ("Sets DefaultOutboundAction=Block. Anything not in the allow-list is cut. Auto-rollback in {0} min unless you confirm keep." -f $RollbackMinutes)
    if (-not $NoConfirm -and -not (Confirm-WHDProceed ("enable default-deny outbound (auto-rollback in {0} min)" -f $RollbackMinutes))) { Write-WHDLog 'skipped.' 'WARN'; return }
    # make sure the essential allow rules (DNS + DHCP) exist and are enabled first
    # (an EMPTY allow group is built here, as before; a group that already holds rules is never rebuilt silently)
    if (-not (Test-WHDAllowListReady) -and -not @(Get-NetFirewallRule -Group $script:WHDFwGroupAllow -EA SilentlyContinue).Count) { Invoke-WHDFirewallAllowList -NoConfirm }
    if (-not (Test-WHDAllowListReady)) {
        $alMsg = 'the essential allow rules (WHD-Allow-DNS-UDP, WHD-Allow-DNS-TCP, WHD-Allow-DHCP-Out) are missing or switched off. Apply the allow-list (Firewall 5), then try again.'
        if ($script:WHDExecute) {
            Write-WHDLog ('Default-deny was NOT enabled: ' + $alMsg) 'ERR'
            New-WHDResult -Action 'enable default-deny outbound' -Status 'failed' -Detail 'essential allow rules missing' | Out-Null
            return
        }
        if (@(Get-NetFirewallRule -Group $script:WHDFwGroupAllow -EA SilentlyContinue).Count) { Write-WHDLog ('  would refuse to enable default-deny: ' + $alMsg) 'WARN' }
    }

    # arm the timed rollback BEFORE flipping, so a mistake self-heals. One-time
    # SYSTEM task with no script file: its action is the single revert command.
    # If it cannot be armed, outbound is NOT blocked.
    if ($script:WHDExecute) {
        $when = (Get-Date).AddMinutes($RollbackMinutes)
        try {
            $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $act  = New-ScheduledTaskAction -Execute $psExe -Argument '-NoProfile -ExecutionPolicy Bypass -Command "Set-NetFirewallProfile -All -DefaultOutboundAction Allow -Confirm:$false"' -EA Stop
            $trig = New-ScheduledTaskTrigger -Once -At $when -EA Stop
            $prin = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest -EA Stop
            $set  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -EA Stop
            Register-ScheduledTask -TaskPath '\' -TaskName $script:WHDFwRollbackTask -Action $act -Trigger $trig -Principal $prin -Settings $set -Force -EA Stop | Out-Null
        } catch {
            Write-WHDLog ("Default-deny was NOT enabled: the auto-rollback task '{0}' could not be armed ({1}). Outbound was left as it is." -f $script:WHDFwRollbackTask, $_.Exception.Message) 'ERR'
            New-WHDResult -Action 'enable default-deny outbound' -Status 'failed' -Detail 'auto-rollback task could not be armed' | Out-Null
            return
        }
        Write-WHDLog ("armed auto-rollback task '{0}' for {1}" -f $script:WHDFwRollbackTask, $when.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)) 'OK'
    } else {
        Write-WHDLog ("would: arm auto-rollback scheduled task '{0}' (+{1} min)" -f $script:WHDFwRollbackTask, $RollbackMinutes) 'DRY'
    }

    Invoke-WHDChange -Description 'set DefaultOutboundAction = Block (all profiles)' -Action {
        Set-NetFirewallProfile -All -DefaultOutboundAction Block -Confirm:$false -EA Stop
    } | Out-Null
    Write-WHDLog 'Default-deny outbound engaged. Verify connectivity, then run Confirm-WHDDefaultDenyKeep to cancel rollback.' 'WARN'
}

function Confirm-WHDDefaultDenyKeep {
    if (-not $script:WHDExecute) { Write-WHDLog 'would: cancel the auto-rollback task (keep default-deny)' 'DRY'; return }
    # Read the real state first: a one-time task still exists after it has fired.
    $outNow = @(Get-WHDFwProfiles | ForEach-Object { "$($_.DefaultOutboundAction)" })
    if ($outNow.Count -and ($outNow -notcontains 'Block')) {
        Write-WHDLog 'Outbound is already Allow - the auto-rollback already ran, or default-deny is not on. Nothing to keep; any leftover rollback task is removed.' 'INFO'
        Remove-WHDRollbackTask
        return
    }
    if (Test-WHDRollbackTask) {
        Remove-WHDRollbackTask
        Write-WHDLog 'Auto-rollback cancelled - default-deny outbound is now permanent until you revert it.' 'OK'
    } else {
        Write-WHDLog 'No pending auto-rollback task (already fired or none armed). Default-deny stands until you revert it (option 8).' 'INFO'
    }
}

function Disable-WHDDefaultDenyOutbound {
    if ((Get-Command Test-WHDGateClosed -EA SilentlyContinue) -and (Test-WHDGateClosed)) {
        Write-WHDLog ("The update gate is {0} - use Updates menu (W) -> O to open it; that also puts back the rules it switched off." -f "$((Get-WHDGateState).Mode)".ToUpper()) 'WARN'
        return
    }
    # v1.5: a policy saved while the gate was closed came in (the gate is recorded as OPEN): its any-program web rules are
    # off because of that gate. They are switched on again with this, or a later default-deny would have no web.
    $whdDdWeb = @()
    if (Get-Command Get-WHDGateHealth -EA SilentlyContinue) {
        try { if ((Get-WHDGateHealth).Unrecorded) { $whdDdWeb = @(@('WHD-Allow-HTTPS', 'WHD-Allow-HTTP') | Where-Object { @(Get-NetFirewallRule -Name $_ -EA SilentlyContinue | Where-Object { "$($_.Enabled)" -ne 'True' }).Count }) } } catch { $whdDdWeb = @() }
    }
    if ($whdDdWeb.Count) { Write-WHDLog ("The firewall is as a closed update gate leaves it (an imported / restored policy): the any-program web rule(s) {0} are switched off. They are switched ON again with this." -f ($whdDdWeb -join ' / ')) 'WARN' }
    if (-not (Confirm-WHDProceed ('revert default-deny (set outbound back to Allow on all profiles)' + $(if ($whdDdWeb.Count) { ' and switch the any-program web rules back on' } else { '' })))) { Write-WHDLog 'skipped.' 'WARN'; return }
    if ($script:WHDExecute) { Remove-WHDRollbackTask }
    Invoke-WHDChange -Description ('set DefaultOutboundAction = Allow (revert to permissive)' + $(if ($whdDdWeb.Count) { '; any-program web rules on' } else { '' })) -Action {
        Set-NetFirewallProfile -All -DefaultOutboundAction Allow -Confirm:$false -EA Stop
        foreach ($whdDdN in $whdDdWeb) { Set-NetFirewallRule -Name $whdDdN -Enabled True -EA SilentlyContinue }
    } | Out-Null
    Write-WHDLog 'Reverted to default-allow outbound.' 'OK'
}

# =============================================================================
#  6) BLACKLIST  (long-term; IP/CIDR firewall rules + hosts sinkhole)
# =============================================================================
# NOTE: Windows Firewall rules match IPs, never domain names. Domains go to the
# hosts sinkhole; IPs/CIDRs go to firewall block rules.
function Block-WHDIPList {
    param([Parameter(Mandatory)][string]$Path, [int]$ChunkSize = 1000, [switch]$NoConfirm)
    if (-not (Test-Path $Path)) { Write-WHDLog ("IP list not found: {0}" -f $Path) 'ERR'; return }
    $raw = @(Get-Content $Path | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^\s*#' })
    if (-not $raw.Count) { Write-WHDLog 'IP list is empty.' 'WARN'; return }
    # SAFETY GUARD: drop any entry overlapping broadcast/multicast/private/reserved
    # ranges before it can ever become a block rule (see $script:WHDNeverBlock).
    $ips = @(); $skipped = @()
    foreach ($e in $raw) { if (Test-WHDNeverBlock $e) { $skipped += $e } else { $ips += $e } }
    if ($skipped.Count) {
        Write-WHDLog ("SAFETY: skipped {0} unroutable/broadcast/multicast/private entr(y/ies): {1}" -f $skipped.Count, (($skipped | Select-Object -First 5) -join ', ')) 'WARN'
    }
    if (-not $ips.Count) { Write-WHDLog 'IP list has no safe, routable entries after filtering.' 'WARN'; return }
    Write-WHDLog ("Blacklisting {0} safe IP/CIDR entr(y/ies) as firewall block rules." -f $ips.Count) 'ACT'
    if (-not $NoConfirm -and -not (Confirm-WHDProceed ("add inbound + outbound block rules for {0} IP/CIDR entr(y/ies)" -f $ips.Count))) { Write-WHDLog 'skipped.' 'WARN'; return }
    $i = 0; $chunk = 0
    while ($i -lt $ips.Count) {
        $slice = @($ips[$i..([Math]::Min($i+$ChunkSize-1, $ips.Count-1))])
        $chunk++
        foreach ($dir in @('Inbound','Outbound')) {
            New-WHDFwRule @{ Name=("WHD-Blacklist-{0}-{1}" -f $dir,$chunk); DisplayName=("WHD Blacklist IPs {0} #{1}" -f $dir,$chunk);
                Group=$script:WHDFwGroupBlock; Direction=$dir; Action='Block'; Enabled='True'; Profile='Any';
                RemoteAddress=$slice }
        }
        $i += $ChunkSize
    }
    Write-WHDLog 'IP blacklist planned/applied.' 'OK'
}

function Block-WHDHostsList {
    param([Parameter(Mandatory)][string]$Path, [switch]$NoConfirm)
    if (-not (Test-Path $Path)) { Write-WHDLog ("hosts blacklist not found: {0}" -f $Path) 'ERR'; return }
    $raw = @(Get-Content $Path | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^\s*#' })
    if (-not $raw.Count) { Write-WHDLog 'hosts blacklist is empty.' 'WARN'; return }
    # Only plain host names are written. A leading address column (0.0.0.0 / 127.0.0.1 /
    # ::1 ...) is dropped, the first token is taken, and anything that is not a host
    # name - or is a localhost-type name - is skipped.
    $hostPat = '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'
    $list = New-Object System.Collections.Generic.List[string]; $badLines = 0
    foreach ($e in $raw) {
        $t   = $e -replace '^(\d{1,3}(\.\d{1,3}){3}|[0-9A-Fa-f:]*:[0-9A-Fa-f:.]*(%\S+)?)\s+', ''
        $tok = [string](@($t -split '\s+' | Where-Object { $_ })[0])
        if ($tok -notmatch $hostPat -or $tok -match '\.\d+$' -or $tok -match '^(localhost|localhost\.localdomain|broadcasthost|local|ip6-.*)$') { $badLines++; continue }
        $list.Add($tok)
    }
    $domains = @($list.ToArray())
    if ($badLines) { Write-WHDLog ("skipped {0} line(s) that are not a plain host name (or are a localhost-type name)." -f $badLines) 'WARN' }
    if (-not $domains.Count) { Write-WHDLog 'hosts blacklist has no usable host names.' 'WARN'; return }
    $hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
    Write-WHDLog ("Sinkholing {0} domain(s) via hosts file." -f $domains.Count) 'ACT'
    if (-not $NoConfirm -and -not (Confirm-WHDProceed ("add {0} domain(s) to the hosts file" -f $domains.Count))) { Write-WHDLog 'skipped.' 'WARN'; return }
    Invoke-WHDChange -Description ("sinkhole {0} domain(s) in hosts (idempotent)" -f $domains.Count) -Action {
        Initialize-WHDPaths
        # Keep the FIRST backup of the session; a second run must not overwrite it.
        $bak = Join-Path $script:WHDRestore 'hosts.bak'
        $cur = @()
        if (Test-Path -LiteralPath $hosts) {
            if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $hosts -Destination $bak -Force -EA Stop }
            # If hosts cannot be read it is NOT rewritten (that would drop its entries).
            try { $cur = @(Get-Content -LiteralPath $hosts -EA Stop) }
            catch { throw ("the hosts file could not be read, so it was not changed: {0}" -f $_.Exception.Message) }
        }
        # Strip any PRIOR WHD block first so re-applying never stacks duplicates.
        $keep = @(); $skip = $false
        foreach ($l in $cur) {
            if ($l -match '^\s*# WHD-BLACKLIST START') { $skip = $true; continue }
            if ($l -match '^\s*# WHD-BLACKLIST END')   { $skip = $false; continue }
            if (-not $skip) { $keep += $l }
        }
        $block = @('# WHD-BLACKLIST START') + ($domains | ForEach-Object { "0.0.0.0 $_" }) + @('# WHD-BLACKLIST END')
        Set-Content -Path $hosts -Value ($keep + $block) -Encoding ASCII
    } | Out-Null
    Write-WHDLog 'hosts sinkhole planned/applied.' 'OK'
}

function Remove-WHDBlacklist {
    if (-not (Confirm-WHDProceed 'remove the WHD IP block rules and the WHD block in the hosts file')) { Write-WHDLog 'skipped.' 'WARN'; return }
    Remove-WHDFwGroup -Group $script:WHDFwGroupBlock
    $hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
    Invoke-WHDChange -Description 'remove WHD-BLACKLIST block from hosts' -Action {
        Initialize-WHDPaths
        $bak = Join-Path $script:WHDRestore 'hosts.bak'
        if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $hosts -Destination $bak -Force -EA Stop }
        $lines = Get-Content $hosts
        $keep = @(); $skip = $false
        foreach ($l in $lines) {
            if ($l -match '^\s*# WHD-BLACKLIST START') { $skip = $true; continue }
            if ($l -match '^\s*# WHD-BLACKLIST END')   { $skip = $false; continue }
            if (-not $skip) { $keep += $l }
        }
        Set-Content -Path $hosts -Value $keep -Encoding ASCII
    } | Out-Null
}

# =============================================================================
#  7) JSON FIREWALL PROFILE APPLIER  (drives everything above from one file)
# =============================================================================
function Invoke-WHDApplyFirewallProfile {
    param([Parameter(Mandatory)][string]$Path, [switch]$NoConfirm)
    if (-not (Test-Path $Path)) { Write-WHDLog ("firewall profile not found: {0}" -f $Path) 'ERR'; return }
    $cfg = Get-Content $Path -Raw | ConvertFrom-Json
    Write-WHDLog ("Applying firewall profile: {0}" -f $cfg.name) 'ACT'
    $what = "apply firewall profile '{0}'" -f $cfg.name
    if ($cfg.defaultDenyOutbound -eq $true) { $what += ' (this also turns on default-deny outbound)' }
    if (-not $NoConfirm -and -not (Confirm-WHDProceed $what)) { Write-WHDLog 'skipped.' 'WARN'; return }

    if ($cfg.profileDefaults) {
        $inb = if ($cfg.profileDefaults.inbound)  { $cfg.profileDefaults.inbound }  else { 'Block' }
        $out = if ($cfg.profileDefaults.outbound) { $cfg.profileDefaults.outbound } else { 'Allow' }
        # v1.1: a profile never LOWERS outbound. If outbound is already Block
        # (default-deny or a closed update gate) it stays Block.
        $curOut = @(Get-WHDFwProfiles | ForEach-Object { "$($_.DefaultOutboundAction)" })
        if ($out -eq 'Allow' -and ($curOut -contains 'Block')) {
            Write-WHDLog 'Outbound is Block now (default-deny / update gate) - the profile keeps it Block instead of setting Allow.' 'INFO'
            $out = 'Block'
        }
        Invoke-WHDChange -Description ("firewall profile defaults: in={0} out={1}, enabled" -f $inb,$out) -Action {
            Set-NetFirewallProfile -All -Enabled True -DefaultInboundAction $inb -DefaultOutboundAction $out -Confirm:$false -EA Stop
        } | Out-Null
    }
    if ($cfg.ipv6 -and $cfg.ipv6.disable) {
        if ($cfg.ipv6.blockLoopback) { Invoke-WHDDisableIPv6 -BlockLoopback -NoConfirm } else { Invoke-WHDDisableIPv6 -NoConfirm }
    }
    if ($cfg.allowList) {
        foreach ($a in @($cfg.allowList)) {
            $p = @{ Name=$a.name; DisplayName=$a.displayName; Group=$script:WHDFwGroupAllow;
                Direction=$a.direction; Action='Allow'; Enabled='True'; Profile='Any' }
            if ($a.protocol)      { $p['Protocol']      = $a.protocol }
            if ($a.remotePort)    { $p['RemotePort']    = $a.remotePort }
            if ($a.localPort)     { $p['LocalPort']     = $a.localPort }
            if (@($a.remoteAddress) -and @($a.remoteAddress).Count) { $p['RemoteAddress'] = @($a.remoteAddress) }
            if ($a.program)       { $p['Program']       = $a.program }
            # Phase 6: keep NTP narrowed to Cloudflare when time sync points there.
            if ($a.name -eq 'WHD-Allow-NTP' -and -not $p['RemoteAddress']) {
                $ntp = Get-WHDNtpRemoteAddress
                if ($ntp) { $p['RemoteAddress'] = $ntp; $p['DisplayName'] = 'WHD Allow NTP (UDP 123, time.cloudflare.com)' }
            }
            New-WHDFwRule $p
        }
    }
    if ($cfg.allowList -and (Get-Command Test-WHDGateClosed -EA SilentlyContinue) -and (Test-WHDGateClosed)) {
        Invoke-WHDChange -Description ("update gate is {0}: keep WHD-Allow-HTTPS / WHD-Allow-HTTP switched off" -f "$((Get-WHDGateState).Mode)".ToUpper()) -Force -Action {
            foreach ($rn in @('WHD-Allow-HTTPS','WHD-Allow-HTTP')) { Set-NetFirewallRule -Name $rn -Enabled False -EA SilentlyContinue }
        } | Out-Null
    }
    if ($cfg.blacklist) {
        $base = Split-Path -Parent $Path
        if ($cfg.blacklist.ipFile) {
            $f = Join-Path $base $cfg.blacklist.ipFile
            if (Test-Path $f) { Block-WHDIPList -Path $f -NoConfirm }
            else { Write-WHDLog ("The IP list file named in the profile was not found ({0}), so no block list was applied. Block lists are not shipped; see Firewall F / profiles\incoming." -f $f) 'WARN' }
        }
        if ($cfg.blacklist.hostsFile) {
            $f = Join-Path $base $cfg.blacklist.hostsFile
            if (Test-Path $f) { Block-WHDHostsList -Path $f -NoConfirm }
            else { Write-WHDLog ("The hosts list file named in the profile was not found ({0}), so no hosts sinkhole was applied. Block lists are not shipped." -f $f) 'WARN' }
        }
    }
    if ($cfg.defaultDenyOutbound -eq $true) {
        $mins = if ($cfg.rollbackMinutes) { [int]$cfg.rollbackMinutes } else { 10 }
        Enable-WHDDefaultDenyOutbound -RollbackMinutes $mins -NoConfirm
    }
    Write-WHDLog 'Firewall profile applied. Review results and confirm before it becomes permanent.' 'OK'
}

# =============================================================================
#  8) CONNECTION LOGGING + BLOCKED-CONNECTION VIEWER  (rewritten 2026-09-28)
# -----------------------------------------------------------------------------
#  User decision 2026-09-28: use Windows Firewall's OWN log - its default file and
#  name (%SystemRoot%\System32\LogFiles\Firewall\pfirewall.log, left as Windows has
#  it), log DROPPED + ALLOWED connections, size = the largest Windows allows
#  (32,767 KB; Windows then starts a new file and keeps one .old). WHD's older
#  Security-log / event 5157 method is replaced (its old journal lines still undo).
#  The firewall log has no program path; where it records a process id (pid), WHD
#  names the program if that process is still running and started before the log
#  line, or from the names it remembered (see "remembered program names" below).
# =============================================================================
$script:WHDFwLogMaxKB = 32767
$script:WHDFwLogDefault = '%systemroot%\system32\LogFiles\Firewall\pfirewall.log'
function Get-WHDFirewallLogFile {
    $fp = @(Get-NetFirewallProfile -EA SilentlyContinue | Where-Object { "$($_.LogFileName)" -and "$($_.LogFileName)" -ne 'NotConfigured' })[0]
    $f = if ($fp) { "$($fp.LogFileName)" } else { $script:WHDFwLogDefault }
    [Environment]::ExpandEnvironmentVariables($f)
}
function Get-WHDConnectionLoggingState {
    $pr = @(Get-NetFirewallProfile -EA SilentlyContinue)
    $on = ($pr.Count -gt 0)
    foreach ($p in $pr) { if ("$($p.LogAllowed)" -ne 'True' -or "$($p.LogBlocked)" -ne 'True' -or [int64]$p.LogMaxSizeKilobytes -ne $script:WHDFwLogMaxKB) { $on = $false } }
    $file = Get-WHDFirewallLogFile
    # Test-Path first: a log file that does not exist yet must not leave a TerminatingError line in the transcript.
    $sz = $null; if (Test-Path -LiteralPath $file) { try { $sz = [math]::Round((Get-Item -LiteralPath $file -EA Stop).Length / 1KB) } catch { } }
    [pscustomobject]@{ On = $on; File = $file; UsedKB = $sz
        Profiles = @($pr | ForEach-Object { "{0}: allowed={1} dropped={2} {3} KB" -f $_.Name, $_.LogAllowed, $_.LogBlocked, $_.LogMaxSizeKilobytes }) }
}
function Show-WHDConnectionLoggingState {
    $s = Get-WHDConnectionLoggingState
    Write-WHDLog ("Firewall log: {0}   file {1} ({2} KB in use)" -f $(if ($s.On) { 'ON (dropped + allowed, 32,767 KB)' } else { 'not fully on' }), $s.File, $s.UsedKB) $(if ($s.On) { 'OK' } else { 'INFO' })
    foreach ($l in $s.Profiles) { Write-WHDLog ("  {0}" -f $l) 'INFO' }
}
function _WHDSetFwLog {
    param([bool]$On)
    $want = if ($On) { 'True' } else { 'False' }
    foreach ($p in @(Get-NetFirewallProfile -EA Stop)) {
        $size = if ($On) { $script:WHDFwLogMaxKB } else { [int64]$p.LogMaxSizeKilobytes }
        if ("$($p.LogAllowed)" -eq $want -and "$($p.LogBlocked)" -eq $want -and [int64]$p.LogMaxSizeKilobytes -eq $size) { continue }
        $flName = "$($p.Name)"
        $jr = @{ Kind = 'fwlog'; Profile = $flName; OldAllowed = "$($p.LogAllowed)"; OldBlocked = "$($p.LogBlocked)"; OldSizeKB = [int64]$p.LogMaxSizeKilobytes
                 NewAllowed = $want; NewBlocked = $want; NewSizeKB = [int64]$size }
        Invoke-WHDChange -Description ("firewall log ({0}): allowed + dropped = {1}, size {2} KB" -f $flName, $want, $size) -Force -Journal $jr -Action {
            Set-NetFirewallProfile -Name $flName -LogAllowed $want -LogBlocked $want -LogMaxSizeKilobytes $size -EA Stop
        } | Out-Null
    }
}
function Enable-WHDConnectionLogging {
    Write-WHDLog 'FIREWALL LOG: turn on (Windows default file, dropped + allowed, max size)' 'ACT'
    Write-WHDRisk 'reversible' ('Windows Firewall writes every dropped AND allowed connection to its own log ({0}), size 32,767 KB (the maximum; Windows then starts over and keeps one .old file). File name and folder stay as Windows has them. Journaled (Undo center).' -f (Get-WHDFirewallLogFile))
    if ((Get-WHDConnectionLoggingState).On) { Write-WHDLog 'Already on - nothing to change.' 'OK'; return }
    if (-not (Confirm-WHDProceed 'turn on the Windows Firewall log (dropped + allowed, 32,767 KB)')) { Write-WHDLog 'skipped.' 'WARN'; return }
    _WHDSetFwLog -On $true
}
function Disable-WHDConnectionLogging {
    Write-WHDLog 'FIREWALL LOG: turn off' 'ACT'
    Write-WHDRisk 'reversible' 'Windows Firewall stops writing dropped and allowed connections to its log. The file size setting is kept. Journaled.'
    if (-not (Confirm-WHDProceed 'turn off the Windows Firewall log')) { Write-WHDLog 'skipped.' 'WARN'; return }
    _WHDSetFwLog -On $false
}
# Reads pfirewall.log (+ .old) with shared access (the firewall keeps it open).
function Read-WHDFirewallLog {
    param([datetime]$Since)
    $file = Get-WHDFirewallLogFile
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($f in @("$file.old", $file)) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $fields = @('date', 'time', 'action', 'protocol', 'src-ip', 'dst-ip', 'src-port', 'dst-port')
        try {
            $fs = New-Object System.IO.FileStream($f, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr = New-Object System.IO.StreamReader($fs)
            while ($null -ne ($line = $sr.ReadLine())) {
                if ($line.StartsWith('#Fields:')) { $fields = @($line.Substring(8).Trim() -split '\s+'); continue }
                if (-not $line -or $line.StartsWith('#')) { continue }
                $v = $line -split '\s+'
                if ($v.Count -lt 8) { continue }
                $h = @{}; for ($i = 0; $i -lt [math]::Min($fields.Count, $v.Count); $i++) { $h[$fields[$i]] = $v[$i] }
                $t = [datetime]::MinValue
                if (-not [datetime]::TryParseExact(("{0} {1}" -f $h['date'], $h['time']), 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$t)) { continue }
                if ($t -lt $Since) { continue }
                $h['when'] = $t
                $rows.Add([pscustomobject]$h)
            }
            $sr.Close(); $fs.Close()
        } catch { Write-WHDLog ("could not read {0}: {1}" -f $f, $_.Exception.Message) 'WARN' }
    }
    $rows.ToArray()
}
# ---- remembered program names ----------------------------------------------------
# The firewall log only records a process id. While that process runs WHD can name it; once it has
# closed, the id means nothing - and Windows may give the same id to ANOTHER program later. So:
#   1. a running process is used only if it started BEFORE the log line was written;
#   2. every name WHD resolves is remembered for this PC (id + start time + path + when it was last
#      seen running), so the lines of a program that has closed since keep their name.
# File: restore\update-guard\blocked-programs.json - WHD's own cache (like a log), dates as invariant
# text. The view writes it in DRY-RUN too; when it cannot be written the view goes on without it.
$script:WHDFwNamesName = 'blocked-programs.json'
$script:WHDFwNamesKeepDays = 7
$script:WHDFwNamesMax = 400
$script:WHDFwNamesNoWrite = $false
function _WHDFwNamesPath { Join-Path $script:WHDRoot ('restore\update-guard\' + $script:WHDFwNamesName) }
function Read-WHDFwNames {
    $whdNf = _WHDFwNamesPath
    $out = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $whdNf)) { return @() }
    try {
        $j = Get-Content -LiteralPath $whdNf -Raw -Encoding UTF8 | ConvertFrom-Json
        if ("$($j.MachineId)".ToLower() -ne (Get-WHDMachineId)) { return @() }      # another PC's file
        $whdNi = [Globalization.CultureInfo]::InvariantCulture
        foreach ($n in @($j.Names)) {
            $st = [datetime]::MinValue; $se = [datetime]::MinValue
            if (-not [datetime]::TryParseExact("$($n.Start)", 'yyyy-MM-dd HH:mm:ss', $whdNi, [Globalization.DateTimeStyles]::None, [ref]$st)) { continue }
            if (-not [datetime]::TryParseExact("$($n.Seen)",  'yyyy-MM-dd HH:mm:ss', $whdNi, [Globalization.DateTimeStyles]::None, [ref]$se)) { continue }
            if (-not "$($n.Path)") { continue }
            $out.Add([pscustomobject]@{ Pid = "$($n.Pid)"; Start = $st; Seen = $se; Path = "$($n.Path)"; Exe = "$($n.Exe)" })
        }
    } catch { return @() }
    return @($out.ToArray())
}
function Save-WHDFwNames {
    param([object[]]$Names)
    if ($script:WHDFwNamesNoWrite) { return }      # it failed once in this session: do not try (and log) again
    try {
        $whdNf = _WHDFwNamesPath
        $whdNd = Split-Path -Parent $whdNf
        if (-not (Test-Path -LiteralPath $whdNd)) { New-Item -ItemType Directory -Path $whdNd -Force -EA Stop | Out-Null }
        $whdNi = [Globalization.CultureInfo]::InvariantCulture
        $rows = @($Names | ForEach-Object { [ordered]@{ Pid = "$($_.Pid)"; Start = $_.Start.ToString('yyyy-MM-dd HH:mm:ss', $whdNi); Seen = $_.Seen.ToString('yyyy-MM-dd HH:mm:ss', $whdNi); Path = "$($_.Path)"; Exe = "$($_.Exe)" } })
        $o = [ordered]@{ MachineId = (Get-WHDMachineId); Computer = $env:COMPUTERNAME; Names = $rows }
        ([pscustomobject]$o | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $whdNf -Encoding UTF8 -EA Stop
    } catch {
        # best effort: the view works without the memory (folder protection can refuse the write)
        $script:WHDFwNamesNoWrite = $true
        try { Write-WHDLog ("  note: the program names could not be saved ({0}). The view works; names of programs that close are not kept in this session." -f $_.Exception.Message) 'INFO' } catch { }
    }
}
# Rule name of a per-program allow (one place, used by the allow and by the view).
function Get-WHDProgramAllowName {
    param([string]$Program, [string]$Protocol, [string]$RemotePort)
    $exe = if ($Program) { Split-Path $Program -Leaf } else { '' }
    $safe = ($exe -replace '[^A-Za-z0-9._-]', '_')
    "WHD-App-{0}-{1}-{2}" -f $safe, $Protocol, $RemotePort
}

# What the WHD allow-list lets out for ANY program right now (enabled outbound rules of that group):
# protocol, remote ports, remote addresses. Used to mark old blocked lines that would pass today
# (example: a program's DNS lines from minutes when the firewall had no rules).
function Get-WHDAllowListCover {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in @(Get-NetFirewallRule -Group $script:WHDFwGroupAllow -EA SilentlyContinue | Where-Object { "$($_.Direction)" -eq 'Outbound' -and "$($_.Action)" -eq 'Allow' -and "$($_.Enabled)" -eq 'True' })) {
        $pf = $r | Get-NetFirewallPortFilter -EA SilentlyContinue
        $af = $r | Get-NetFirewallAddressFilter -EA SilentlyContinue
        if (-not $pf) { continue }
        if ("$($pf.LocalPort)" -and "$($pf.LocalPort)" -ne 'Any') { continue }                 # tied to a local port (DHCP): not a general allow
        $apf = $null; try { $apf = $r | Get-NetFirewallApplicationFilter -EA SilentlyContinue } catch { $apf = $null }
        if ($apf -and "$($apf.Program)" -and "$($apf.Program)" -ne 'Any') { continue }         # tied to one program: not a general allow
        $out.Add([pscustomobject]@{ Protocol = "$($pf.Protocol)"
            Ports = @(@($pf.RemotePort) | Where-Object { $null -ne $_ } | ForEach-Object { "$_" })
            Addrs = @(@($af.RemoteAddress) | Where-Object { $null -ne $_ } | ForEach-Object { "$_" }) })
    }
    return @($out.ToArray())
}
function Test-WHDAllowListCovers {
    param([object[]]$Cover, [string]$Protocol, [string]$Port, [string[]]$IPs)
    if (-not @($IPs).Count) { return $false }
    # Only plain IPv4 addresses / CIDR are compared; any other address form counts as "not covered".
    $whdCvPat = '^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$'
    foreach ($c in @($Cover)) {
        if ($c.Protocol -ne 'Any' -and $c.Protocol -ne $Protocol) { continue }
        if (@($c.Ports).Count -and ($c.Ports -notcontains 'Any') -and ($c.Ports -notcontains $Port)) { continue }
        if (-not @($c.Addrs).Count -or ($c.Addrs -contains 'Any')) { return $true }
        $all = $true
        try {
            $ranges = @($c.Addrs | Where-Object { $_ -match $whdCvPat } | ForEach-Object { ,(ConvertTo-WHDIpRange $_) } | Where-Object { $_ })
            foreach ($ip in @($IPs)) {
                $a = $null
                if ("$ip" -match $whdCvPat) { $a = ConvertTo-WHDIpRange $ip }
                if (-not $a -or -not @($ranges | Where-Object { $a[0] -ge $_[0] -and $a[0] -le $_[1] }).Count) { $all = $false; break }
            }
        } catch { $all = $false }
        if ($all) { return $true }
    }
    return $false
}

# Blocked (DROP) connections, grouped by direction + program + protocol + port.
# Each row gets a State: can (can be allowed from here) | allowed | allowed-off (allow exists, switched off) |
# covered (the allow-list lets it out now) | windows (service / System / not TCP-UDP) | inbound |
# ended (program closed, name not known).
function Get-WHDBlockedConnections {
    param([int]$Hours = 24, [ValidateSet('Outbound','Inbound','Any')]$Direction = 'Outbound', [ValidateSet('DROP','ALLOW')]$Action = 'DROP')
    $now = Get-Date
    $since = $now.AddHours(-1 * [math]::Abs($Hours))
    $local = @(Get-NetIPAddress -EA SilentlyContinue | ForEach-Object { "$($_.IPAddress)" })
    $procs = @{}
    foreach ($pp in @(Get-Process -EA SilentlyContinue)) {
        $whdPs = $null; try { $whdPs = $pp.StartTime } catch { $whdPs = $null }       # protected processes do not show it
        $whdPp = ''; try { $whdPp = "$($pp.Path)" } catch { $whdPp = '' }
        $procs["$($pp.Id)"] = [pscustomobject]@{ Path = $whdPp; Exe = "$($pp.ProcessName).exe"; Start = $whdPs }
    }
    $boot = $null; try { $boot = (Get-CimInstance -ClassName Win32_OperatingSystem -EA Stop).LastBootUpTime } catch { $boot = $null }
    $names = @(Read-WHDFwNames)
    $byPid = @{}; foreach ($n in $names) { if (-not $byPid.ContainsKey($n.Pid)) { $byPid[$n.Pid] = New-Object System.Collections.Generic.List[object] }; $byPid[$n.Pid].Add($n) }
    $seenNow = @{}
    $groups = @{}
    foreach ($e in @(Read-WHDFirewallLog -Since $since)) {
        if ("$($e.action)" -ne $Action) { continue }
        $dir = switch ("$($e.path)") { 'SEND' { 'Outbound' } 'RECEIVE' { 'Inbound' } default { if ($local -contains "$($e.'dst-ip')") { 'Inbound' } else { 'Outbound' } } }
        if ($Direction -ne 'Any' -and $dir -ne $Direction) { continue }
        $pidv = "$($e.pid)"; $prog = ''; $exe = '(unknown)'; $ended = $false
        if ($pidv -eq '4' -or $pidv -eq '0') { $prog = 'System'; $exe = 'System' }
        elseif ($pidv -and $pidv -ne '-') {
            $lp = $procs[$pidv]
            if ($lp -and (-not $lp.Start -or $lp.Start -le $e.when.AddSeconds(2))) {
                $prog = $lp.Path; $exe = $lp.Exe; $seenNow[$pidv] = $lp        # running, and it started before this line
            } else {
                $ended = $true; $exe = '(program has closed)'
                $hit = $null
                if ($byPid.ContainsKey($pidv)) {
                    foreach ($c in $byPid[$pidv]) {
                        if ($c.Start -gt $e.when.AddSeconds(2)) { continue }                         # started after the line
                        if ($e.when -gt $c.Seen.AddMinutes(30)) { continue }                        # long after it was last seen running
                        if ($boot -and $c.Start -lt $boot -and $e.when -gt $boot) { continue }      # a restart lies between
                        if (-not $hit -or $c.Start -gt $hit.Start) { $hit = $c }
                    }
                }
                if ($hit) { $prog = $hit.Path; $exe = $hit.Exe }
            }
        }
        $proto = "$($e.protocol)"
        $port  = "$($e.'dst-port')"
        $ip    = if ($dir -eq 'Inbound') { "$($e.'src-ip')" } else { "$($e.'dst-ip')" }
        $who   = if ($prog -and $prog -ne 'System') { $prog.ToLower() } else { $exe }
        $key   = "$dir|$who|$proto|$port"
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = [pscustomobject]@{ Count = 0; Last = $e.when; First = $e.when; Direction = $dir
                RawApp = $prog; Program = $prog; Exe = $exe; Protocol = $proto; RemotePort = $port
                IPs = (New-Object System.Collections.Generic.List[string]); Addresses = ''
                Closed = $ended; State = ''; StateText = ''; Sort = 0 }
        }
        $g = $groups[$key]
        $g.Count++
        if ($e.when -gt $g.Last)  { $g.Last  = $e.when }
        if ($e.when -lt $g.First) { $g.First = $e.when }
        if (-not $ended) { $g.Closed = $false }
        if ($ip -and -not $g.IPs.Contains($ip)) { $g.IPs.Add($ip) }
    }
    # remember the names resolved just now (running programs that appear in the log)
    if ($seenNow.Count) {
        $whdNi = [Globalization.CultureInfo]::InvariantCulture
        $keep = New-Object System.Collections.Generic.List[object]
        $done = @{}
        foreach ($k in @($seenNow.Keys)) {
            $lp = $seenNow[$k]
            if (-not $lp.Path -or -not $lp.Start) { continue }
            $keep.Add([pscustomobject]@{ Pid = "$k"; Start = $lp.Start; Seen = $now; Path = $lp.Path; Exe = $lp.Exe })
            $done["$k|" + $lp.Start.ToString('yyyy-MM-dd HH:mm:ss', $whdNi)] = $true
        }
        foreach ($n in $names) {
            if ($done.ContainsKey($n.Pid + '|' + $n.Start.ToString('yyyy-MM-dd HH:mm:ss', $whdNi))) { continue }
            if ($n.Seen -lt $now.AddDays(-1 * [int]$script:WHDFwNamesKeepDays)) { continue }
            $keep.Add($n)
        }
        if ($keep.Count) { Save-WHDFwNames -Names @($keep.ToArray() | Sort-Object Seen -Descending | Select-Object -First ([int]$script:WHDFwNamesMax)) }
    }
    if (-not $groups.Count) { return @() }
    # what can be done with each row
    $appRules = @{}
    foreach ($r in @(Get-NetFirewallRule -Group $script:WHDFwGroupApp -EA SilentlyContinue)) { $appRules["$($r.Name)".ToLower()] = "$($r.Enabled)" }
    $cover = @(); try { $cover = @(Get-WHDAllowListCover) } catch { $cover = @() }
    $whdBcGate = 'open'
    if (Get-Command Get-WHDGateState -EA SilentlyContinue) { try { $whdBcGate = "$((Get-WHDGateState).Mode)" } catch { $whdBcGate = 'open' } }
    $order = @{ 'can' = 1; 'allowed-off' = 2; 'allowed' = 3; 'covered' = 3; 'windows' = 4; 'inbound' = 5; 'ended' = 6 }
    $progMax = @{}
    $out = foreach ($g in $groups.Values) {
        $show = @($g.IPs | Select-Object -First 3) -join ', '
        if ($g.IPs.Count -gt 3) { $show += (" (+{0} more)" -f ($g.IPs.Count - 3)) }
        $g.Addresses = $show
        $leaf = if ($g.Program) { Split-Path $g.Program -Leaf } else { '' }
        if     ($g.Direction -eq 'Inbound')                                { $g.State = 'inbound';  $g.StateText = 'no - inbound' }
        elseif (-not $g.Program -and $g.Closed)                             { $g.State = 'ended';    $g.StateText = 'no - program has closed (start it again, then load again)' }
        elseif (-not $g.Program -and $g.Exe -eq '(unknown)')                { $g.State = 'windows';  $g.StateText = 'no - the log has no process id for it' }
        elseif (-not $g.Program -or $g.Program -eq 'System' -or $leaf -ieq 'svchost.exe' -or $g.Program -notmatch '^[A-Za-z]:\\') { $g.State = 'windows'; $g.StateText = 'no - Windows service / System' }
        elseif ($g.Protocol -notin @('TCP','UDP') -or -not $g.RemotePort -or $g.RemotePort -eq '-') { $g.State = 'windows'; $g.StateText = 'no - not TCP/UDP' }
        else {
            $rn = (Get-WHDProgramAllowName -Program $g.Program -Protocol $g.Protocol -RemotePort $g.RemotePort).ToLower()
            if     ($appRules.ContainsKey($rn) -and $appRules[$rn] -eq 'True') { $g.State = 'allowed';     $g.StateText = 'allowed already (older lines)' }
            elseif ($appRules.ContainsKey($rn))                                { $g.State = 'allowed-off'; $g.StateText = $(if ($whdBcGate -eq 'closed') { 'allow exists, switched off (gate CLOSED)' } else { 'allow exists, but it is switched off' }) }
            elseif (Test-WHDAllowListCovers -Cover $cover -Protocol $g.Protocol -Port $g.RemotePort -IPs @($g.IPs)) { $g.State = 'covered'; $g.StateText = 'no need - the allow-list lets this out now (older lines)' }
            else                                                              { $g.State = 'can';         $g.StateText = 'yes' }
        }
        $pk = if ($g.Program) { $g.Program.ToLower() } else { $g.Exe }
        if (-not $progMax.ContainsKey($pk) -or $g.Count -gt $progMax[$pk]) { $progMax[$pk] = $g.Count }
        $g
    }
    # order: what can be allowed first, rows of one program together (busiest program first)
    @($out | Sort-Object @{ e = { $order[$_.State] } },
                         @{ e = { $pk2 = if ($_.Program) { $_.Program.ToLower() } else { $_.Exe }; $progMax[$pk2] }; Descending = $true },
                         @{ e = { if ($_.Program) { $_.Program.ToLower() } else { $_.Exe } } },
                         @{ e = { $_.Count }; Descending = $true },
                         @{ e = { "$($_.Protocol)" } },
                         @{ e = { "$($_.RemotePort)".PadLeft(5, '0') } })      # last two: the same order (and numbers) on every load
}

# \device\harddiskvolumeN\... -> C:\...  (fltmc is a built-in tool; admin only)
function Get-WHDVolumeMap {
    if ($script:WHDVolMap) { return $script:WHDVolMap }
    $map = @{}
    $r = Invoke-WHDNative -Exe 'fltmc.exe' -ArgList @('volumes')
    foreach ($l in @($r.Out)) {
        if ($l -match '^\s*([A-Za-z]:)\s+(\\Device\\\S+)') { $map[$matches[2].ToLower()] = $matches[1].ToUpper() }
    }
    $script:WHDVolMap = $map
    return $map
}
function ConvertFrom-WHDDevicePath {
    param([string]$Path)
    if (-not $Path) { return '' }
    if ($Path -notmatch '^\\device\\') { return $Path }
    $map = Get-WHDVolumeMap
    $low = $Path.ToLower()
    foreach ($k in @($map.Keys)) {
        if ($low.StartsWith($k + '\')) { return ($map[$k] + $Path.Substring($k.Length)) }
    }
    return $Path
}

function Show-WHDBlockedConnections {
    # Numbers are given only to the rows that can be allowed from here; the rest is listed below them.
    param([object[]]$Items)
    if (-not @($Items).Count) { Write-Host '  (no blocked connections recorded in that window - is logging on? menu M)' -ForegroundColor DarkGray; return }
    $fmt = '  {0,3}  {1,6}  {2,-14} {3,-5} {4,-6} {5,-26} {6}'
    $can = @($Items | Where-Object { $_.State -eq 'can' })
    Write-Host ''
    Write-Host ('  CAN BE ALLOWED ({0}) - that program, that protocol + port, outbound:' -f $can.Count) -ForegroundColor White
    if ($can.Count) {
        Write-Host ($fmt -f '#','count','last seen','prot','port','program','addresses') -ForegroundColor DarkGray
        $i = 0
        foreach ($b in $can) {
            $i++
            Write-Host ($fmt -f $i, $b.Count, $b.Last.ToString('MM-dd HH:mm:ss'), $b.Protocol, $b.RemotePort, $(if ($b.Closed) { $b.Exe + ' (closed)' } else { $b.Exe }), $b.Addresses)
        }
    } else { Write-Host '       (nothing)' -ForegroundColor DarkGray }
    $done = @($Items | Where-Object { $_.State -in @('allowed','allowed-off','covered') })
    if ($done.Count) {
        Write-Host ('  NOTHING TO ALLOW ({0}) - older lines; an allow for it exists, or the allow-list lets it out:' -f $done.Count) -ForegroundColor Green
        foreach ($b in $done) {
            Write-Host ($fmt -f '', $b.Count, $b.Last.ToString('MM-dd HH:mm:ss'), $b.Protocol, $b.RemotePort, $b.Exe, $b.StateText) -ForegroundColor DarkGray
        }
    }
    $win = @($Items | Where-Object { $_.State -in @('windows','inbound') })
    if ($win.Count) {
        Write-Host ('  WINDOWS ITSELF ({0}) - services / System, cannot be allowed from here (open the gate for Windows Update / Store):' -f $win.Count) -ForegroundColor White
        foreach ($b in @($win | Select-Object -First 8)) { Write-Host ($fmt -f '', $b.Count, $b.Last.ToString('MM-dd HH:mm:ss'), $b.Protocol, $b.RemotePort, $b.Exe, $b.Addresses) -ForegroundColor DarkGray }
        if ($win.Count -gt 8) { Write-Host ('       ... and {0} more line(s)' -f ($win.Count - 8)) -ForegroundColor DarkGray }
    }
    $end = @($Items | Where-Object { $_.State -eq 'ended' })
    if ($end.Count) {
        $endN = 0; foreach ($b in $end) { $endN += $b.Count }
        Write-Host ('  PROGRAMS THAT HAVE CLOSED - name not known ({0} blocked connection(s)): {1}' -f $endN, ((@($end | Select-Object -First 6 | ForEach-Object { "$($_.Protocol) $($_.RemotePort)" }) -join ', '))) -ForegroundColor White
        Write-Host '       Start the program again and open this view while it runs - WHD then remembers its name.' -ForegroundColor DarkGray
    }
}

# Menu V: view, then allow one or several rows (e.g. 1,3 or 1-3) with one question.
function Invoke-WHDBlockedView {
    $h = (Read-Host '  Hours to look back [24]').Trim(); if (-not ($h -match '^[0-9]{1,4}$')) { $h = 24 }
    $items = @(Get-WHDBlockedConnections -Hours ([int]$h))
    Show-WHDBlockedConnections -Items $items
    $can = @($items | Where-Object { $_.State -eq 'can' })
    if (-not $can.Count) { return }
    $pick = (Read-Host '  Numbers to allow (e.g. 1,3 or 1-3), Enter = back').Trim()
    if (-not $pick) { return }
    $sel = ConvertFrom-WHDSelection -Text $pick -Max $can.Count
    if ($null -eq $sel -or -not @($sel).Count) { Write-Host '  invalid.' -ForegroundColor Yellow; return }
    Add-WHDProgramAllows -Items @($sel | ForEach-Object { $can[$_ - 1] })
}

# One-click allow: THAT program, THAT protocol + remote port, any destination
# (user decision 2026-09-23). Outbound only. Windows service traffic (svchost /
# System) is refused - a program rule for svchost would open every service.
function Add-WHDProgramAllow {
    param([Parameter(Mandatory)]$Item)
    if ($Item.Direction -ne 'Outbound') {
        Write-WHDLog ("not allowed from the viewer: {0} is INBOUND - allowing it would open the PC to the network. Add an inbound rule by hand if you really need it." -f $Item.Exe) 'WARN'; return
    }
    $exe = if ($Item.Program) { Split-Path $Item.Program -Leaf } else { '' }
    if (-not $Item.Program -or $Item.Program -eq 'System' -or $exe -ieq 'svchost.exe' -or $Item.Program -notmatch '^[A-Za-z]:\\') {
        Write-WHDLog ("not allowed from the viewer: '{0}' is Windows service traffic (svchost/System). A program rule would open every service - add a port rule for the specific need instead." -f $Item.Exe) 'WARN'; return
    }
    if ($Item.Protocol -notin @('TCP','UDP') -or -not $Item.RemotePort) {
        Write-WHDLog ("not allowed from the viewer: only TCP/UDP with a port can be allowed ({0} {1})." -f $Item.Protocol, $Item.RemotePort) 'WARN'; return
    }
    if (-not (Test-Path -LiteralPath $Item.Program)) { Write-WHDLog ("note: program path not found on disk (moved or updated?): {0}" -f $Item.Program) 'WARN' }
    $name = Get-WHDProgramAllowName -Program $Item.Program -Protocol $Item.Protocol -RemotePort $Item.RemotePort
    # v1.5: the rule name is built from the FILE name. An allow of that name for a program in another folder would be
    # replaced by this one (that program would lose its allow without a word): refuse instead.
    foreach ($whdPaEx in @(Get-NetFirewallRule -Name $name -EA SilentlyContinue)) {
        $whdPaProg = ''
        try { $whdPaProg = "$(@($whdPaEx | Get-NetFirewallApplicationFilter -EA SilentlyContinue)[0].Program)" } catch { $whdPaProg = '' }
        if ($whdPaProg) { try { $whdPaProg = [Environment]::ExpandEnvironmentVariables($whdPaProg) } catch { } }
        if ($whdPaProg -and $whdPaProg -ne 'Any' -and $whdPaProg.ToLower() -ne "$($Item.Program)".ToLower()) {
            if (-not (Test-Path -LiteralPath $whdPaProg)) {
                # the file the old allow was tied to is gone (the program updated into another folder): the allow moves to the new file
                Write-WHDLog ("note: the WHD allow of that name was tied to {0}, which is no longer on disk. It is replaced by one for {1}." -f $whdPaProg, $Item.Program) 'WARN'
            } else {
                Write-WHDLog ("not allowed: a WHD allow for another program with the same file name is there already ({0}, the file exists), and one rule name cannot serve both. Nothing was changed. Undo that allow first (Undo center) if this program should have it instead." -f $whdPaProg) 'ERR'
                if ($script:WHDExecute) { New-WHDResult -Action ("allow {0} out on {1} {2}" -f $exe, $Item.Protocol, $Item.RemotePort) -Status 'failed' -Detail 'an allow of that name exists for another program file' | Out-Null }
                $script:WHDFwAllowRefused = [int]$script:WHDFwAllowRefused + 1
                return
            }
        }
    }
    Write-WHDLog ("ALLOW PROGRAM: {0}  ({1} port {2}, outbound)" -f $Item.Program, $Item.Protocol, $Item.RemotePort) 'ACT'
    Write-WHDRisk 'caution' ("allows only this program, only {0} to remote port {1}, any destination. Removable in the Undo center or with 'remove program allows'." -f $Item.Protocol, $Item.RemotePort)
    if (-not (Confirm-WHDProceed ("allow {0} out on {1} {2}" -f $exe, $Item.Protocol, $Item.RemotePort))) { Write-WHDLog 'skipped.' 'WARN'; return }
    # With the update gate CLOSED the per-program allows are switched off. A new allow is saved switched off
    # and the gate remembers it, so setting the gate to PROGRAMS or OPEN switches it on.
    $whdGateMode = 'open'
    if (Get-Command Get-WHDGateState -EA SilentlyContinue) { try { $whdGateMode = "$((Get-WHDGateState).Mode)" } catch { $whdGateMode = 'open' } }
    $whdAppOn = 'True'; if ($whdGateMode -eq 'closed') { $whdAppOn = 'False' }
    New-WHDFwRule -Params @{ Name = $name; DisplayName = ("WHD Allow {0} ({1} {2})" -f $exe, $Item.Protocol, $Item.RemotePort)
        Group = $script:WHDFwGroupApp; Direction = 'Outbound'; Action = 'Allow'; Enabled = $whdAppOn; Profile = 'Any'
        Program = $Item.Program; Protocol = $Item.Protocol; RemotePort = $Item.RemotePort } `
        -Journal @{ Kind = 'fwrule'; RuleName = $name }
    if ($whdGateMode -eq 'closed') {
        if (-not $script:WHDExecute) {
            Write-WHDLog 'would: save this allow switched OFF, because the update gate is CLOSED - it starts working when the gate is set to PROGRAMS (Updates menu P) or OPEN (Updates menu O)' 'DRY'
        } elseif (@(Get-NetFirewallRule -Name $name -EA SilentlyContinue).Count) {
            $whdRemOk = $true
            if (Get-Command Add-WHDGateRemembered -EA SilentlyContinue) {
                try { Add-WHDGateRemembered -Names @($name) }
                catch { $whdRemOk = $false; Write-WHDLog ("The allow is saved switched OFF, but the update gate could not note it down ({0}). It will NOT come on by itself with PROGRAMS or OPEN: close the gate again (Updates menu C) and then set P or O, so the gate takes it into account." -f $_.Exception.Message) 'ERR' }
            }
            if ($whdRemOk) { Write-WHDLog 'The update gate is CLOSED: the allow is saved, but it is switched OFF until the gate is set to PROGRAMS (Updates menu P) or OPEN (Updates menu O).' 'WARN' }
        }
    } elseif ($script:WHDExecute -and $whdGateMode -eq 'programs' -and -not $script:WHDFwAllowBatch -and @(Get-NetFirewallRule -Name $name -EA SilentlyContinue).Count) {
        Write-WHDLog $script:WHDAllowLiveText 'OK'
    }
}
$script:WHDAllowLiveText = 'Live now: the update gate is on PROGRAMS, so the allow works from this moment. No other step is needed - the gate does not have to be set again.'
$script:WHDFwAllowBatch = $false
$script:WHDFwAllowRefused = 0      # allows refused in the running batch (a same-named allow of another program file)

# Several rows at once: the lines are listed, ONE question, then every row.
function Add-WHDProgramAllows {
    param([object[]]$Items)
    $whdAllowList = @($Items | Where-Object { $_ })
    if (-not $whdAllowList.Count) { return }
    if ($whdAllowList.Count -eq 1) { Add-WHDProgramAllow -Item $whdAllowList[0]; return }
    Write-WHDLog ("ALLOW {0} PROGRAM LINE(S) (each: that program, that protocol + port, outbound, any destination):" -f $whdAllowList.Count) 'ACT'
    foreach ($whdAl in $whdAllowList) { Write-WHDLog ("  {0}  {1} {2}   {3}" -f $whdAl.Exe, $whdAl.Protocol, $whdAl.RemotePort, $whdAl.Program) 'INFO' }
    if (-not (Confirm-WHDProceed ("allow the {0} line(s) listed above" -f $whdAllowList.Count))) { Write-WHDLog 'skipped.' 'WARN'; return }
    # The question above covers the whole batch: the single allows do not ask again.
    $whdAlPrev = $script:WHDConfirm; $whdAlPrevBatch = $script:WHDFwAllowBatch
    $script:WHDConfirm = { param($m) $true }; $script:WHDFwAllowBatch = $true
    $script:WHDFwAllowRefused = 0
    try { foreach ($whdAl in $whdAllowList) { Add-WHDProgramAllow -Item $whdAl } }
    finally { $script:WHDConfirm = $whdAlPrev; $script:WHDFwAllowBatch = $whdAlPrevBatch }
    if ($script:WHDExecute -and [int]$script:WHDFwAllowRefused -lt $whdAllowList.Count -and (Get-Command Get-WHDGateState -EA SilentlyContinue)) {
        try {
            if ("$((Get-WHDGateState).Mode)" -eq 'programs') {
                $whdAlMade = @($whdAllowList | Where-Object { $_.Program -and @(Get-NetFirewallRule -Name (Get-WHDProgramAllowName -Program $_.Program -Protocol $_.Protocol -RemotePort $_.RemotePort) -EA SilentlyContinue).Count })
                if ($whdAlMade.Count) { Write-WHDLog $script:WHDAllowLiveText 'OK' }
            }
        } catch { }
    }
}

function Remove-WHDProgramAllows {
    Write-WHDLog 'REMOVE all per-program allow rules (group WinHardenDebloat-AppAllow)' 'ACT'
    $whdPaNote  = Write-WHDCrossToolNote -Tool 'appclear'      # v1.5: on PROGRAMS these rules ARE what the gate lets out
    $whdPaNames = @(Get-NetFirewallRule -Group $script:WHDFwGroupApp -EA SilentlyContinue | ForEach-Object { "$($_.Name)" })
    if (-not (Confirm-WHDProceed ('remove all per-program allow rules' + $whdPaNote.Ask))) { Write-WHDLog 'skipped.' 'WARN'; return }
    Remove-WHDFwGroup -Group $script:WHDFwGroupApp | Out-Null
    # v1.5: deleted rules come off the gate's list of rules to switch back on
    if ($script:WHDExecute -and $whdPaNames.Count -and (Get-Command Remove-WHDGateRemembered -EA SilentlyContinue) -and -not @(Get-NetFirewallRule -Group $script:WHDFwGroupApp -EA SilentlyContinue).Count) {
        try { Remove-WHDGateRemembered -Names $whdPaNames } catch { }
    }
}

# =============================================================================
#  9) TIME SYNC  (Phase 6, Option 1: time.cloudflare.com over NTP, UDP 123 pinned)
# -----------------------------------------------------------------------------
#  Windows' time service only speaks NTP (no NTS). Option 1 = trusted source +
#  firewall pin. NtpServer/Type are set through the journaled registry helper,
#  so the Undo center can put the previous server back exactly.
#  Flag 0x8 = client mode, polled on Windows' normal min/max interval (about
#  every 17 min to 9 h) instead of 0x1's fixed weekly "special" interval.
# =============================================================================
function Get-WHDNtpRemoteAddress {
    # Cloudflare IPs when time sync points at Cloudflare, otherwise $null (= any).
    $st = Get-WHDRegValueState -Path $script:WHDW32TimeKey -Name 'NtpServer'
    if ($st.Exists -and "$($st.Value)" -match [regex]::Escape($script:WHDNtpServer)) { return $script:WHDNtpIPs }
    return $null
}

function Invoke-WHDSetTimeSync {
    param([ValidateSet('Cloudflare','Windows')]$Mode = 'Cloudflare')
    if ($Mode -eq 'Cloudflare') {
        $peer = "$($script:WHDNtpServer),0x8"; $raddr = $script:WHDNtpIPs
        Write-WHDLog ("TIME SYNC -> {0} (NTP; firewall UDP 123 pinned to {1})" -f $script:WHDNtpServer, ($raddr -join ', ')) 'ACT'
    } else {
        $peer = 'time.windows.com,0x9'; $raddr = $null
        Write-WHDLog 'TIME SYNC -> Windows default (time.windows.com); firewall UDP 123 open to any' 'ACT'
    }
    if ($Mode -eq 'Cloudflare') {
        Write-WHDRisk 'reversible' ("Changes the Windows Time server + the NTP allow rule, and limits automatic time jumps to {0} (Windows default 15 h): a bigger correction - e.g. a forged NTP reply - is refused and logged; the update guard alerts. If the clock is ever really that far off, set it by hand once (Settings > Time & language > Date & time), then Sync now. Registry values are journaled (Undo center)." -f (_WHDSecText $script:WHDTimeJumpLimit))
    } else {
        Write-WHDRisk 'reversible' 'Changes the Windows Time server + the NTP allow rule, and puts the time-jump limit (15 h) and Secure Time Seeding back to Windows defaults. Registry values are journaled (Undo center).'
    }
    if (-not (Confirm-WHDProceed ("set time source to {0}" -f $peer))) { Write-WHDLog 'skipped.' 'WARN'; return }
    Set-WHDRegistryValue -Path $script:WHDW32TimeKey -Name 'NtpServer' -Value $peer -Type String | Out-Null
    Set-WHDRegistryValue -Path $script:WHDW32TimeKey -Name 'Type' -Value 'NTP' -Type String | Out-Null
    $p = @{ Name = 'WHD-Allow-NTP'; Group = $script:WHDFwGroupAllow; Direction = 'Outbound'; Action = 'Allow'
            Enabled = 'True'; Profile = 'Any'; Protocol = 'UDP'; RemotePort = 123 }
    if ($raddr) { $p['RemoteAddress'] = $raddr; $p['DisplayName'] = 'WHD Allow NTP (UDP 123, time.cloudflare.com)' }
    else        { $p['DisplayName'] = 'WHD Allow NTP (UDP 123)' }
    New-WHDFwRule $p
    # User decision 2026-09-23: keep Windows Time running (Automatic, delayed start)
    # so it actually syncs; on a non-domain PC it is trigger-start and stops again.
    if ($Mode -eq 'Cloudflare') { Set-WHDTimeServiceAutomatic }
    if ($Mode -eq 'Cloudflare') { Set-WHDTimeJumpLimit -Seconds $script:WHDTimeJumpLimit }
    else { Set-WHDTimeJumpLimit -Seconds $script:WHDTimeJumpDefault -RestoreSeeding }
    Invoke-WHDChange -Description 'apply time settings (w32tm /config /update) and resync' -Force -Action {
        $svc = Get-Service -Name w32time -EA Stop
        if ($svc.Status -ne 'Running') { Start-Service -Name w32time -EA Stop }
        $u = Invoke-WHDNative -Exe 'w32tm.exe' -ArgList @('/config', '/update')
        if ($u.Code -ne 0) { throw ("w32tm /config /update exit {0}: {1}" -f $u.Code, ($u.Out -join ' ')) }
        $r = Invoke-WHDNative -Exe 'w32tm.exe' -ArgList @('/resync', '/rediscover')
        if ($r.Code -ne 0) { Write-WHDLog ("resync not completed yet ({0}) - Windows retries on its own schedule." -f (($r.Out | Where-Object { $_ }) -join ' ')) 'WARN' }
    } | Out-Null
    Show-WHDTimeStatus
}

# Windows Time -> Automatic (delayed start) + running. Journaled as a 'service'
# change, so the Undo center puts back the previous start type.
function Set-WHDTimeServiceAutomatic {
    $svc = Get-Service -Name w32time -EA SilentlyContinue
    if (-not $svc) { Write-WHDLog 'Windows Time service (w32time) not found.' 'ERR'; return }
    if ("$($svc.StartType)" -eq 'Automatic' -and $svc.Status -eq 'Running') {
        Write-WHDLog 'Windows Time service already Automatic and running.' 'INFO'; return
    }
    $jr = @{ Kind = 'service'; Service = 'W32Time'; OldStartType = "$($svc.StartType)"; NewStartType = 'Automatic' }
    Invoke-WHDChange -Description ("Windows Time service: start type {0} -> Automatic (delayed start), start it" -f $svc.StartType) -Force -Journal $jr -Action {
        $r = Invoke-WHDNative -Exe 'sc.exe' -ArgList @('config', 'w32time', 'start=', 'delayed-auto')
        if ($r.Code -ne 0) { throw ("sc config exit {0}: {1}" -f $r.Code, (($r.Out | Where-Object { $_ }) -join ' ')) }
        if ((Get-Service -Name w32time).Status -ne 'Running') { Start-Service -Name w32time -EA Stop }
    } | Out-Null
}

function _WHDSecText {
    param([int64]$Sec)
    if ($Sec -lt 0 -or $Sec -eq 4294967295) { return 'no limit' }
    if ($Sec -ge 3600 -and $Sec % 3600 -eq 0) { return ("{0} h" -f ($Sec / 3600)) }
    if ($Sec -ge 60 -and $Sec % 60 -eq 0) { return ("{0} min" -f ($Sec / 60)) }
    return ("{0} s" -f $Sec)
}
# Current jump limits + Secure Time Seeding (read-only).
function Get-WHDTimeJumpState {
    $p = Get-WHDRegValueState -Path $script:WHDW32TimeCfgKey -Name 'MaxPosPhaseCorrection'
    $n = Get-WHDRegValueState -Path $script:WHDW32TimeCfgKey -Name 'MaxNegPhaseCorrection'
    $t = Get-WHDRegValueState -Path $script:WHDW32TimeCfgKey -Name 'UtilizeSslTimeData'
    $pv = if ($p.Exists) { [int64]([uint32]([int64]$p.Value -band 0xFFFFFFFFL)) } else { [int64]$script:WHDTimeJumpDefault }
    $nv = if ($n.Exists) { [int64]([uint32]([int64]$n.Value -band 0xFFFFFFFFL)) } else { [int64]$script:WHDTimeJumpDefault }
    $seed = if ($t.Exists) { [int]$t.Value -ne 0 } else { $true }
    [pscustomobject]@{
        Pos = $pv; Neg = $nv; Seeding = $seed
        Limited = ($pv -le $script:WHDTimeJumpLimit -and $nv -le $script:WHDTimeJumpLimit)
        Text = $(if ($pv -eq $nv) { "+/- " + (_WHDSecText $pv) } else { "+" + (_WHDSecText $pv) + " / -" + (_WHDSecText $nv) })
    }
}
# Journaled (kind 'reg', auto undo + Verify). Writes only values that differ.
function Set-WHDTimeJumpLimit {
    param([Parameter(Mandatory)][int]$Seconds, [switch]$RestoreSeeding)
    foreach ($nm in @('MaxPosPhaseCorrection', 'MaxNegPhaseCorrection')) {
        $cur = Get-WHDRegValueState -Path $script:WHDW32TimeCfgKey -Name $nm
        if ($cur.Exists -and (Test-WHDRegValueEqual $cur.Value $Seconds 'DWord')) { continue }
        Set-WHDRegistryValue -Path $script:WHDW32TimeCfgKey -Name $nm -Value $Seconds -Type DWord | Out-Null
    }
    if ($RestoreSeeding) {
        $t = Get-WHDRegValueState -Path $script:WHDW32TimeCfgKey -Name 'UtilizeSslTimeData'
        if ($t.Exists -and [int]$t.Value -ne 1) { Set-WHDRegistryValue -Path $script:WHDW32TimeCfgKey -Name 'UtilizeSslTimeData' -Value 1 -Type DWord | Out-Null }
    }
}
# Refused corrections (System log, Time-Service event 34) since a given time.
function Get-WHDTimeJumpEvents {
    param([datetime]$Since = (Get-Date).AddDays(-7))
    @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Time-Service'; Id = 34; StartTime = $Since } -EA SilentlyContinue |
      ForEach-Object { [pscustomobject]@{ Time = $_.TimeCreated; Message = (("$($_.Message)" -split "`r?`n")[0]).Trim() } })
}

function Show-WHDTimeStatus {
    $st = Get-WHDRegValueState -Path $script:WHDW32TimeKey -Name 'NtpServer'
    Write-WHDLog ("Time server setting : {0}" -f $(if ($st.Exists) { $st.Value } else { '(not set)' })) 'INFO'
    $tj = Get-WHDTimeJumpState
    Write-WHDLog ("Time-jump limit     : {0}  (Windows default +/- 15 h; WHD target {1})" -f $tj.Text, (_WHDSecText $script:WHDTimeJumpLimit)) $(if ($tj.Limited) { 'OK' } else { 'INFO' })
    Write-WHDLog ("Secure Time Seeding : {0}" -f $(if ($tj.Seeding) { 'on (Windows default)' } else { 'off' })) 'INFO'
    $ev = @(Get-WHDTimeJumpEvents -Since (Get-Date).AddDays(-7))
    if ($ev.Count) { foreach ($e in $ev) { Write-WHDLog ("  REFUSED jump {0:yyyy-MM-dd HH:mm}: {1}" -f $e.Time, $e.Message) 'WARN' } }
    else { Write-WHDLog '  refused time jumps (7 days): none' 'INFO' }
    $svc = Get-Service -Name w32time -EA SilentlyContinue
    if ($svc) {
        $dl = (Get-WHDRegValueState -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time' -Name 'DelayedAutostart')
        $stTxt = "$($svc.StartType)"; if ($stTxt -eq 'Automatic' -and $dl.Exists -and [int]$dl.Value -eq 1) { $stTxt = 'Automatic (delayed start)' }
        $lvl = if ($svc.Status -eq 'Running') { 'OK' } else { 'WARN' }
        Write-WHDLog ("Windows Time service: {0}, start type {1}" -f $svc.Status, $stTxt) $lvl
        # Diagnostics (read-only): uptime - delayed start fires ~2 min after boot -
        # and the service's built-in start/stop triggers.
        try {
            $boot = (Get-CimInstance Win32_OperatingSystem -EA Stop).LastBootUpTime
            $up = (Get-Date) - $boot
            Write-WHDLog ("  PC up for            : {0:N0} min (since {1})" -f $up.TotalMinutes, $boot.ToString('HH:mm')) 'INFO'
        } catch {}
        $tr = Invoke-WHDNative -Exe 'sc.exe' -ArgList @('qtriggerinfo', 'w32time')
        $trLines = @($tr.Out | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch 'QueryServiceConfig2|SERVICE_NAME' })
        if ($trLines.Count) { foreach ($l in $trLines) { Write-WHDLog ("  trigger: {0}" -f $l) 'INFO' } }
        else { Write-WHDLog '  trigger: (none)' 'INFO' }
    }
    $src = Invoke-WHDNative -Exe 'w32tm.exe' -ArgList @('/query', '/source')
    Write-WHDLog ("Source in use       : {0}" -f (($src.Out | Where-Object { $_.Trim() }) -join ' ')) 'INFO'
    $q = Invoke-WHDNative -Exe 'w32tm.exe' -ArgList @('/query', '/status')
    foreach ($l in @($q.Out)) {
        if ($l -match '^(Last Successful Sync Time|Poll Interval|Stratum|Leap Indicator):') { Write-WHDLog ("  {0}" -f $l.Trim()) 'INFO' }
    }
    # Reachability test straight to the server (works even if the service is stopped).
    $sc = Invoke-WHDNative -Exe 'w32tm.exe' -ArgList @('/stripchart', "/computer:$($script:WHDNtpServer)", '/samples:2', '/dataonly')
    $samples = @($sc.Out | Where-Object { $_ -match '^\d{1,2}:\d{2}:\d{2}' })
    if ($samples.Count) { foreach ($l in $samples) { Write-WHDLog ("  reach {0}: {1}" -f $script:WHDNtpServer, $l.Trim()) 'INFO' } }
    else { Write-WHDLog ("  reach {0}: no answer ({1})" -f $script:WHDNtpServer, (($sc.Out | Where-Object { $_ }) | Select-Object -Last 1)) 'WARN' }
    $rule = @(Get-NetFirewallRule -Name 'WHD-Allow-NTP' -EA SilentlyContinue)
    if ($rule) {
        $af = $rule[0] | Get-NetFirewallAddressFilter -EA SilentlyContinue
        Write-WHDLog ("Firewall NTP allow  : UDP 123 -> {0}" -f (@($af.RemoteAddress) -join ', ')) 'INFO'
    } else {
        Write-WHDLog 'Firewall NTP allow  : (no WHD-Allow-NTP rule - fine while outbound is default-allow)' 'INFO'
    }
}

# =============================================================================
#  10) OFFLINE BLOCKLIST REFRESH  (Phase 6 / D15)
# -----------------------------------------------------------------------------
#  Drop list files into profiles\incoming\ (downloaded on any machine, carried
#  over offline). Understood formats, auto-detected per line:
#    * plain IP or CIDR per line (FireHOL .netset/.ipset, most lists)
#    * Spamhaus DROP classic   "1.2.3.0/24 ; SBL123"
#    * Spamhaus DROP JSON      {"cidr":"1.2.3.0/24","sblid":...}  (drop_v4.json)
#    * DShield block.txt       "start<TAB>end<TAB>prefix ..."
#  Every entry is normalized, de-duplicated, and passed through the SAME safety
#  guard as Block-WHDIPList. Preview first; then merge or replace (user choice
#  each time); the old list is backed up and the change is journaled.
# =============================================================================
function ConvertTo-WHDCidrString {
    param([uint64]$Start, [uint64]$End)
    $size = $End - $Start + 1
    $len = 32 - [int][math]::Round([math]::Log([double]$size, 2))
    $b = [System.BitConverter]::GetBytes([uint32]$Start); [Array]::Reverse($b)
    return ("{0}.{1}.{2}.{3}/{4}" -f $b[0], $b[1], $b[2], $b[3], $len)
}

function Read-WHDBlocklistFile {
    param([Parameter(Mandatory)][string]$Path)
    $res = [ordered]@{ Ranges = (New-Object System.Collections.Generic.List[object]); IPv6 = 0; Unreadable = 0; Guarded = 0; Lines = 0 }
    $ipv4 = '^\d{1,3}(\.\d{1,3}){3}$'
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#') -or $t.StartsWith(';') -or $t.StartsWith('//')) { continue }
        $res.Lines++
        $cand = $null
        if ($t.StartsWith('{')) {
            try { $j = $t | ConvertFrom-Json -EA Stop } catch { $res.Unreadable++; continue }
            if (-not $j.cidr) { $res.Lines--; continue }          # metadata line
            $cand = "$($j.cidr)"
        } else {
            $t2  = ($t -split '[;#]')[0].Trim()
            $tok = @($t2 -split '[\s,]+' | Where-Object { $_ })
            if (-not $tok.Count) { $res.Unreadable++; continue }
            if ($tok.Count -ge 3 -and $tok[0] -match $ipv4 -and $tok[1] -match $ipv4 -and $tok[2] -match '^\d{1,2}$') {
                $cand = "{0}/{1}" -f $tok[0], $tok[2]            # DShield start/end/prefix
            } else { $cand = $tok[0] }
        }
        if ($cand -match ':') { $res.IPv6++; continue }
        $rng = ConvertTo-WHDIpRange $cand
        if (-not $rng) { $res.Unreadable++; continue }
        if (Test-WHDNeverBlock $cand) { $res.Guarded++; continue }
        $res.Ranges.Add([pscustomobject]@{ Start = [uint64]$rng[0]; End = [uint64]$rng[1] })
    }
    [pscustomobject]$res
}

# Sort, drop duplicates and ranges already inside a bigger range.
function Compress-WHDRanges {
    param([object[]]$Ranges)
    $sorted = @($Ranges | Sort-Object @{ e = { $_.Start } }, @{ e = { $_.End }; Descending = $true })
    $out = New-Object System.Collections.Generic.List[object]
    $lastEnd = -1.0
    foreach ($r in $sorted) {
        if ([double]$r.End -le $lastEnd) { continue }      # contained in previous
        $out.Add($r)
        $lastEnd = [double]$r.End
    }
    return $out.ToArray()
}

function Get-WHDIncomingFolder {
    $inc = Join-Path $script:WHDRoot 'profiles\incoming'
    if (-not (Test-Path -LiteralPath $inc)) {
        New-Item -ItemType Directory -Path $inc -Force | Out-Null
        @('Drop IP blocklist files here (downloaded on any machine, copied over offline).',
          'Understood: plain IP/CIDR per line (FireHOL .netset/.ipset), Spamhaus DROP (classic or drop_v4.json), DShield block.txt.',
          'Then: WHD.ps1 -> 9 Firewall -> F  (or GUI Firewall tab -> "Refresh blocklist").',
          'Processed files are moved to incoming\done\<session>\ so nothing is used twice.',
          'IPv6 entries are skipped (IPv6 is suppressed); unsafe ranges (private, multicast, broadcast, CGNAT) are always skipped.') |
            Set-Content -LiteralPath (Join-Path $inc 'README.txt') -Encoding ASCII
    }
    return $inc
}

# -Mode Preview (read-only) | Merge | Replace. Returns a summary object.
function Invoke-WHDBlocklistRefresh {
    param([ValidateSet('Preview','Merge','Replace')]$Mode = 'Preview')
    $inc   = Get-WHDIncomingFolder
    $files = @(Get-ChildItem -LiteralPath $inc -File -EA SilentlyContinue | Where-Object { $_.Name -ne 'README.txt' })
    Write-WHDLog ("BLOCKLIST REFRESH ({0}) - {1} file(s) in {2}" -f $Mode, $files.Count, $inc) 'ACT'
    if (-not $files.Count) { Write-WHDLog 'Nothing to do: copy list files into profiles\incoming first (see README.txt there).' 'WARN'; return $null }

    $new = New-Object System.Collections.Generic.List[object]
    foreach ($f in $files) {
        $r = Read-WHDBlocklistFile -Path $f.FullName
        foreach ($x in $r.Ranges.ToArray()) { $new.Add($x) }
        Write-WHDLog ("  {0}: {1} usable, {2} IPv6 skipped, {3} unreadable, {4} unsafe (guarded)" -f $f.Name, $r.Ranges.Count, $r.IPv6, $r.Unreadable, $r.Guarded) 'INFO'
    }
    $target = Join-Path $script:WHDRoot 'profiles\blacklist-ip.txt'
    $cur = @()
    if (Test-Path -LiteralPath $target) {
        # SAFETY: if the current list cannot be read, stop - a merge/replace built on
        # an empty "current" would silently throw the existing list away.
        try {
            $curRead = Read-WHDBlocklistFile -Path $target
            $cur = $curRead.Ranges.ToArray()
        } catch {
            Write-WHDLog ("could not read the current list ({0}) - refresh aborted, nothing changed." -f $_.Exception.Message) 'ERR'
            return $null
        }
        if ($curRead.Lines -gt 0 -and -not $cur.Count) {
            Write-WHDLog 'the current list has entries but none could be read - refresh aborted, nothing changed.' 'ERR'
            return $null
        }
    }
    $newSet = @(Compress-WHDRanges $new.ToArray())
    $curSet = @(Compress-WHDRanges $cur)
    $curKeys = @{}; foreach ($r in $curSet) { $curKeys["$($r.Start)-$($r.End)"] = $true }
    $newKeys = @{}; foreach ($r in $newSet) { $newKeys["$($r.Start)-$($r.End)"] = $true }
    $added   = @($newSet | Where-Object { -not $curKeys.ContainsKey("$($_.Start)-$($_.End)") })
    $removed = @($curSet | Where-Object { -not $newKeys.ContainsKey("$($_.Start)-$($_.End)") })
    $merged  = @(Compress-WHDRanges (@($curSet) + @($newSet)))
    $sum = [pscustomobject]@{
        Files = $files.Count; Current = $curSet.Count; Incoming = $newSet.Count
        Added = $added.Count; Removed = $removed.Count; MergeTotal = $merged.Count; ReplaceTotal = $newSet.Count
    }
    Write-WHDLog ("Current list: {0} ranges   Incoming: {1} ranges" -f $sum.Current, $sum.Incoming) 'INFO'
    Write-WHDLog ("  new ranges not in current list ...... {0}" -f $sum.Added) 'INFO'
    Write-WHDLog ("  current ranges not in incoming ...... {0}" -f $sum.Removed) 'INFO'
    Write-WHDLog ("  MERGE   -> {0} ranges (keeps everything, adds the new)" -f $sum.MergeTotal) 'INFO'
    Write-WHDLog ("  REPLACE -> {0} ranges (incoming files become the whole list)" -f $sum.ReplaceTotal) 'INFO'
    foreach ($a in @($added | Select-Object -First 5))   { Write-WHDLog ("    + {0}" -f (ConvertTo-WHDCidrString $a.Start $a.End)) 'INFO' }
    foreach ($a in @($removed | Select-Object -First 5)) { Write-WHDLog ("    - {0}" -f (ConvertTo-WHDCidrString $a.Start $a.End)) 'INFO' }
    if ($Mode -eq 'Preview') { return $sum }

    $final = if ($Mode -eq 'Merge') { $merged } else { $newSet }
    if (-not $final.Count) { Write-WHDLog 'Result would be an EMPTY list - refusing.' 'ERR'; return $sum }
    if (-not (Confirm-WHDProceed ("{0} blocklist file -> {1} ranges" -f $Mode.ToLower(), $final.Count))) { Write-WHDLog 'skipped.' 'WARN'; return $sum }
    $addrs = [uint64]0; foreach ($r in $final) { $addrs += ($r.End - $r.Start + 1) }
    $lines = @(
        '# WinHardenDebloat - IP blocklist (offline). Refreshed by Invoke-WHDBlocklistRefresh.',
        ('# {0} on {1} from: {2}' -f $Mode, (Get-Date -Format 'yyyy-MM-dd HH:mm'), (($files | ForEach-Object Name) -join ', ')),
        '# SAFETY-FILTERED: no broadcast/multicast/private/reserved/CGNAT/loopback ranges.',
        ('# {0} ranges / {1:N0} addresses. Applied inbound+outbound BLOCK.' -f $final.Count, $addrs),
        '# The engine also re-checks every line at apply time and skips any unroutable range.',
        '#'
    ) + @($final | ForEach-Object { ConvertTo-WHDCidrString $_.Start $_.End })

    if (-not $script:WHDExecute) {
        Write-WHDLog ("would: back up and rewrite {0} with {1} ranges; move {2} file(s) to incoming\done" -f $target, $final.Count, $files.Count) 'DRY'
        return $sum
    }
    Initialize-WHDPaths
    $tag    = Get-Date -Format 'HHmmss'
    $tmp    = Join-Path $script:WHDRestore ("blacklist-ip.new.$tag.txt")
    $backup = Join-Path $script:WHDRestore ("blacklist-ip.before.$tag.txt")
    Set-Content -LiteralPath $tmp -Value $lines -Encoding ASCII
    $hash = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
    $done = Join-Path $inc ("done\" + $script:WHDStamp)
    $jr = @{ Kind = 'file'; Path = $target; Backup = $backup; NewHash = $hash }
    Invoke-WHDChange -Description ("{0} blocklist: {1} ranges (was {2}); old list backed up" -f $Mode.ToLower(), $final.Count, $sum.Current) -Force -Journal $jr -Action {
        if (Test-Path -LiteralPath $target) { Copy-Item -LiteralPath $target -Destination $backup -Force -EA Stop }
        else { Set-Content -LiteralPath $backup -Value '# (no previous list)' -Encoding ASCII }
        Copy-Item -LiteralPath $tmp -Destination $target -Force -EA Stop
        if (-not (Test-Path -LiteralPath $done)) { New-Item -ItemType Directory -Path $done -Force | Out-Null }
        foreach ($f in $files) { Move-Item -LiteralPath $f.FullName -Destination (Join-Path $done $f.Name) -Force -EA Stop }
    } | Out-Null
    return $sum
}

# Rebuild the block rules from the current list (removes old chunks first, so a
# shorter list never leaves stale rules behind). Hosts sinkhole is untouched.
function Update-WHDBlocklistRules {
    Write-WHDLog 'REBUILD IP block rules from profiles\blacklist-ip.txt' 'ACT'
    if (-not (Confirm-WHDProceed 'rebuild the IP block rules now')) { Write-WHDLog 'skipped.' 'WARN'; return }
    Remove-WHDFwGroup -Group $script:WHDFwGroupBlock | Out-Null
    Block-WHDIPList -Path (Join-Path $script:WHDRoot 'profiles\blacklist-ip.txt') -NoConfirm
}

# =============================================================================
#  11) RULES WHD DID NOT MAKE  (v1.5, from the 2026-10-06 live test)
# -----------------------------------------------------------------------------
#  Windows and program installers write firewall rules of their own - also after
#  WHD wiped the list, and also while the update gate is CLOSED / on PROGRAMS (the
#  gate switches other outbound allow rules off only at the moment it is set).
#  An outbound allow rule that appears later lets its program through the gate; an
#  inbound allow rule lets its program accept connections from outside.
#
#  What counts: a rule that is ON, is an ALLOW rule and is in none of WHD's groups -
#    * inbound : always;
#    * outbound: only while outbound is Block (gate CLOSED / PROGRAMS, or
#      default-deny). With outbound open, an outbound allow rule changes nothing.
#  WHD shows them (at its start, in the Firewall and Updates menus, in Status and in
#  the update guard) and asks. Per rule you choose:
#      o = switch OFF     r = remove     k = keep
#      p = (outbound rule that names one program file) make a WHD allow for that
#          program on ONE port and switch the wide rule off.
#
#  The rules you keep are listed in restore\update-guard\firewall-known.json (this PC
#  only). The same file says whether INBOUND rules are watched. Until that is switched
#  on WHD alerts only for the outbound leak - a stock Windows install has a few hundred
#  inbound rules of its own. The inbound watch starts only when you say so ("K", then
#  "S": WHD asks whether the rules present now count as kept or are listed too), or
#  with a wipe / reset / .wfw import / firewall restore (the inbound rules such a tool
#  leaves behind count as kept; a rule that appears later is reported).
# =============================================================================
$script:WHDFwKnownName   = 'firewall-known.json'
$script:WHDFwForeignSeen = @{}     # rule names already shown as an alert in this session
$script:WHDFwForeignMax  = 40      # rows shown on screen at once; "*" always means every row
# One look at the rule list serves the head lines and the check of one menu draw: the result is reused for a few
# seconds. Every change WHD makes (Invoke-WHDChange) and every save of the kept list throws it away at once.
$script:WHDFwScanCache   = $null
$script:WHDFwScanSeconds = 3
# How the last reset / wipe / .wfw import ended: done | planned (DRY-RUN) | failed | skipped. The callers offer to
# set the update gate again only after 'done'.
$script:WHDFwToolStatus  = ''

# The groups of the rules WHD makes itself (the update gate's group is defined in Updates.ps1).
function Get-WHDFwOwnGroups {
    $og = @($script:WHDFwGroupIPv6, $script:WHDFwGroupAllow, $script:WHDFwGroupBlock, $script:WHDFwGroupBase, $script:WHDFwGroupApp)
    if ("$($script:WHDFwGroupGate)") { $og += "$($script:WHDFwGroupGate)" } else { $og += 'WinHardenDebloat-UpdateGate' }
    @($og)
}
# One rule by its exact name. (-Name accepts wildcards, and a rule made by another program may carry
# * ? [ ] in its name: such a name is looked up by comparing, never as a pattern.)
function Get-WHDFwRuleExact {
    param([string]$Name)
    if (-not "$Name") { return @() }
    if ("$Name" -notmatch '[\*\?\[\]]') { return @(Get-NetFirewallRule -Name $Name -EA SilentlyContinue | Where-Object { "$($_.Name)" -eq "$Name" }) }
    return @(Get-NetFirewallRule -EA SilentlyContinue | Where-Object { "$($_.Name)" -eq "$Name" })
}

# ---- the list of rules you keep ------------------------------------------------
# The file holds: Names = the rules YOU kept (answer k);  Base = inbound rules that were counted as kept when the
# inbound watch started (S, N) or by a wipe / reset / import / restore;  Inbound = are inbound rules watched.
function _WHDFwKnownPath { Join-Path $script:WHDRoot ('restore\update-guard\' + $script:WHDFwKnownName) }
# -> Exists, Unreadable (the file is there but cannot be read: treated as empty, and said so), Inbound,
#    Own (kept by you), Base (counted as kept), Names (both together - what is left out of the list), Saved.
function Get-WHDFwKnown {
    $kn = [pscustomobject]@{ Exists = $false; Unreadable = $false; Inbound = $false; Own = @(); Base = @(); Names = @(); Saved = '' }
    $knFile = _WHDFwKnownPath
    if (-not (Test-Path -LiteralPath $knFile)) { return $kn }
    try {
        $knJ = Get-Content -LiteralPath $knFile -Raw -Encoding UTF8 -EA Stop | ConvertFrom-Json -EA Stop
        if (-not $knJ) { throw 'empty' }
        if ("$($knJ.MachineId)".ToLower() -ne (Get-WHDMachineId)) { return $kn }      # another PC's file
        $kn.Exists  = $true
        $kn.Inbound = [bool]("$($knJ.Inbound)" -eq 'True')      # are the inbound rules watched (see Start-WHDFwInboundWatch)
        $kn.Saved   = "$($knJ.Saved)"
        $kn.Own     = @(@($knJ.Names) | ForEach-Object { "$_" } | Where-Object { $_ })
        $kn.Base    = @(@($knJ.Base)  | ForEach-Object { "$_" } | Where-Object { $_ })
        $kn.Names   = @(@($kn.Own) + @($kn.Base) | Where-Object { $_ })
    } catch { $kn.Unreadable = $true }
    return $kn
}
# Writes the list (EXECUTE only). Returns $true when it was written.
#   -Names   : the rules you kept (always given: the whole new list)
#   -Base    : the inbound rules counted as kept; left out = as it is now
#   -Inbound : $true / $false sets whether the inbound rules are watched; left out = as it is now
# Written to a second file first and then moved over the old one, so a write that is cut short cannot leave half a file.
function Save-WHDFwKnown {
    param([string[]]$Names, $Base = $null, $Inbound = $null)
    if (-not $script:WHDExecute) { return $false }
    try {
        $knNow = Get-WHDFwKnown
        $knInb = $false
        if ($null -eq $Inbound) { $knInb = [bool]$knNow.Inbound } else { $knInb = [bool]("$Inbound" -eq 'True') }
        $knFile = _WHDFwKnownPath
        $knDir  = Split-Path -Parent $knFile
        if (-not (Test-Path -LiteralPath $knDir)) { New-Item -ItemType Directory -Path $knDir -Force -EA Stop | Out-Null }
        $knList = @(@($Names) | ForEach-Object { "$_" } | Where-Object { $_ } | Sort-Object -Unique)
        $knOwnSet = @{}; foreach ($knO in $knList) { $knOwnSet["$knO".ToLower()] = $true }
        $knBaseIn = @($knNow.Base); if ($null -ne $Base) { $knBaseIn = @($Base) }
        $knBase = @(@($knBaseIn) | ForEach-Object { "$_" } | Where-Object { $_ -and -not $knOwnSet.ContainsKey("$_".ToLower()) } | Sort-Object -Unique)
        $knObj  = [ordered]@{ MachineId = (Get-WHDMachineId); Computer = $env:COMPUTERNAME; Inbound = $knInb
                              Saved = (Get-Date).ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture); Names = $knList; Base = $knBase }
        if ($knNow.Unreadable) {
            try { Copy-Item -LiteralPath $knFile -Destination ($knFile + '.bad') -Force -EA Stop } catch { }
            Write-WHDLog ("The file with your kept rules could not be read and is written anew (a copy of the old one: {0}.bad). What it held is lost: the inbound rules are not watched, and only what is saved now counts as kept." -f $knFile) 'WARN'
        }
        $knTmp = $knFile + '.new'
        ([pscustomobject]$knObj | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath $knTmp -Encoding UTF8 -EA Stop
        if (Test-Path -LiteralPath $knFile) {
            # one step where the drive can do it (never a moment without the file); otherwise the plain move
            try { [System.IO.File]::Replace($knTmp, $knFile, [NullString]::Value) }
            catch { Move-Item -LiteralPath $knTmp -Destination $knFile -Force -EA Stop }
        } else { Move-Item -LiteralPath $knTmp -Destination $knFile -EA Stop }
        $script:WHDFwScanCache = $null
        return $true
    } catch {
        try { Write-WHDLog ("The list of kept firewall rules could not be saved ({0}). No firewall rule is affected; the list (and whether inbound rules are watched) stays as it was." -f $_.Exception.Message) 'WARN' } catch { }
        return $false
    }
}
# Rule names (lower case) WHD still holds switched OFF (journal kind 'fwoff'), and rule names you REMOVED (answer r).
# A rule on one of these lists that is ON again is never counted as kept by a tool or by "S, N": it is listed, you decide.
function _WHDFwDecidedAgainst {
    $daOut = @{}
    if (Get-Command Get-WHDFwOffLive -EA SilentlyContinue) { try { foreach ($daE in (Get-WHDFwOffLive).GetEnumerator()) { $daOut["$($daE.Key)"] = 'off' } } catch { } }
    if (Get-Command Get-WHDFwRemovedNames -EA SilentlyContinue) { try { foreach ($daE in (Get-WHDFwRemovedNames).GetEnumerator()) { if (-not $daOut.ContainsKey("$($daE.Key)")) { $daOut["$($daE.Key)"] = 'removed' } } } catch { } }
    return $daOut
}
# Switches the watch on the INBOUND rules on. Only on an explicit answer (console: K, then S; window: the
# button "Watch inbound rules..."); WHD never starts it by looking at the list. One question.
#   -CountPresent : the inbound allow rules that are ON now count as kept - only a rule that appears later is reported
#                   (left out: a rule you had switched off or removed that is ON again - it is listed).
#   without it    : every one of them is listed as not decided until you keep it, switch it off or remove it.
function Start-WHDFwInboundWatch {
    param([switch]$CountPresent)
    $swKn = Get-WHDFwKnown
    if ($swKn.Inbound) { Write-WHDLog 'The inbound rules are watched already.' 'INFO'; return }
    $swIn = @(Get-WHDForeignRules | Where-Object { -not $_.Leak })
    $swAgainst = @{}; if ($CountPresent) { $swAgainst = _WHDFwDecidedAgainst }
    $swTake = @($swIn | Where-Object { -not $swAgainst.ContainsKey("$($_.Name)".ToLower()) })
    $swLeft = $swIn.Count - $swTake.Count
    Write-WHDLog ("WATCH THE INBOUND RULES TOO - {0} inbound allow rule(s) that WHD did not make are ON now" -f $swIn.Count) 'ACT'
    $swAsk = ''
    if ($CountPresent) {
        Write-WHDRisk 'reversible' ("No firewall rule is changed. {0} inbound allow rule(s) that are ON now count as kept and are not reported{1}. From now on WHD reports every inbound allow rule that appears later - at its start, in the Firewall and Updates menus, in Status, and the update guard after sign-in." -f $swTake.Count, $(if ($swLeft) { " ($swLeft more that you had switched off or removed are ON again: those are listed)" } else { '' }))
        $swAsk = ("watch the inbound rules from now on ({0} present now count as kept)" -f $swTake.Count)
    } else {
        Write-WHDRisk 'caution' ("No firewall rule is changed. ALL {0} inbound allow rule(s) that are ON now are listed as not decided: WHD at its start, the Firewall and Updates menus, Status and the update guard after every sign-in report them until you keep, switch off or remove each one. Rules that appear later are reported too. On a Windows install with its own rules still in place that is a few hundred rules." -f $swIn.Count)
        $swAsk = ("watch the inbound rules and list ALL {0} present now as not decided (reported after every sign-in until you decide each one)" -f $swIn.Count)
    }
    if (-not (Confirm-WHDProceed $swAsk)) { Write-WHDLog 'skipped.' 'WARN'; return }
    $swBase = @($swKn.Base)
    if ($CountPresent) { $swBase = @($swBase) + @($swTake | ForEach-Object { "$($_.Name)" }) }
    Invoke-WHDChange -Description ("watch the inbound firewall rules ({0})" -f $(if ($CountPresent) { "$($swTake.Count) present now count as kept" } else { "the $($swIn.Count) present now are listed" })) -Force -Journal @{ Hint = 'to end the reports for a rule: keep it (Firewall menu K). To go back to the start: delete restore\update-guard\firewall-known.json (only the outbound leak is reported then).' } -Action {
        if (-not (Save-WHDFwKnown -Names @($swKn.Own) -Base $swBase -Inbound $true)) { throw 'the list could not be saved' }
    } | Out-Null
}
# After a wipe / reset / .wfw import / firewall restore: what the tool left behind is what you put in. The rules you
# kept that still exist stay kept; every inbound allow rule not made by WHD that is ON now counts as kept (Base);
# the inbound rules are watched from then on. NOT counted as kept, so that you decide:
#   - a rule you had switched OFF (journal kind 'fwoff') or REMOVED that such a tool brought back ON;
#   - -Pending: inbound rules that were listed as not decided before the tool ran (the watch was on already).
# (Outbound rules are never taken in here: a kept outbound rule stays on through the update gate.)
function Set-WHDFwKnownFromNow {
    param([string]$Why, [string[]]$Pending = @())
    if (-not $script:WHDExecute) { return }
    try {
        $kfOwn  = @(Get-WHDFwOwnGroups)
        $kfAll  = @(Get-NetFirewallRule -EA Stop)
        $kfHave = @{}; foreach ($kfR in $kfAll) { $kfHave["$($kfR.Name)".ToLower()] = $true }
        $kfOld  = Get-WHDFwKnown
        $kfKeep = @(@($kfOld.Own)  | Where-Object { $kfHave.ContainsKey("$_".ToLower()) })
        $kfBase = @(@($kfOld.Base) | Where-Object { $kfHave.ContainsKey("$_".ToLower()) })
        $kfNot  = _WHDFwDecidedAgainst
        $kfPend = @{}; foreach ($kfP in @($Pending | Where-Object { $_ })) { $kfPend["$kfP".ToLower()] = $true }
        $kfInAll = @($kfAll | Where-Object { ($kfOwn -notcontains "$($_.Group)") -and "$($_.Enabled)" -eq 'True' -and "$($_.Action)" -eq 'Allow' -and "$($_.Direction)" -eq 'Inbound' } | ForEach-Object { "$($_.Name)" })
        $kfIn    = @($kfInAll | Where-Object { -not $kfNot.ContainsKey("$_".ToLower()) -and -not $kfPend.ContainsKey("$_".ToLower()) })
        $kfBack  = @($kfInAll | Where-Object { $kfNot.ContainsKey("$_".ToLower()) })
        $kfStill = @($kfInAll | Where-Object { $kfPend.ContainsKey("$_".ToLower()) -and -not $kfNot.ContainsKey("$_".ToLower()) })
        $kfBase  = @(@($kfBase | Where-Object { -not $kfNot.ContainsKey("$_".ToLower()) }) + @($kfIn))
        if (Save-WHDFwKnown -Names $kfKeep -Base $kfBase -Inbound $true) {
            if ($kfIn.Count) { Write-WHDLog ("Rules WHD did not make: after the {0} the {1} inbound allow rule(s) that are there now count as kept (not reported). From now on an allow rule that appears is reported (inbound always; outbound while outbound is Block)." -f $Why, $kfIn.Count) 'INFO' }
            else { Write-WHDLog ("Rules WHD did not make: after the {0} no inbound allow rule was newly counted as kept. From now on an allow rule that appears is reported (inbound always; outbound while outbound is Block)." -f $Why) 'INFO' }
            if ($kfBack.Count) { Write-WHDLog ("Rules WHD did not make: {0} inbound rule(s) you had switched OFF or removed are ON again after the {1}. They do NOT count as kept and are listed (Firewall or Updates menu K)." -f $kfBack.Count, $Why) 'WARN' }
            if ($kfStill.Count) { Write-WHDLog ("Rules WHD did not make: {0} inbound rule(s) were listed as not decided before the {1} and still are." -f $kfStill.Count, $Why) 'INFO' }
        }
    } catch { try { Write-WHDLog ("The list of kept firewall rules could not be set after the {0}: {1}. It stays as it was (if inbound rules were not watched before, they still are not)." -f $Why, $_.Exception.Message) 'WARN' } catch { } }
}

# ---- finding them --------------------------------------------------------------
# Fills in protocol, ports and the program / app / service of one row (read-only; done only for rows that are shown).
function Add-WHDFwRuleDetail {
    param($Row)
    if (-not $Row -or $Row.Detail) { return $Row }
    $rdPf = $null; $rdAp = $null; $rdSf = $null
    try { $rdPf = @($Row.Rule | Get-NetFirewallPortFilter -EA SilentlyContinue)[0] } catch { }
    try { $rdAp = @($Row.Rule | Get-NetFirewallApplicationFilter -EA SilentlyContinue)[0] } catch { }
    try { $rdSf = @($Row.Rule | Get-NetFirewallServiceFilter -EA SilentlyContinue)[0] } catch { }
    $rdProg = "$($rdAp.Program)"; if ($rdProg -eq 'Any') { $rdProg = '' }
    if ($rdProg) { try { $rdProg = [Environment]::ExpandEnvironmentVariables($rdProg) } catch { } }
    $rdPkg = "$($rdAp.Package)"
    $rdSvc = "$($rdSf.Service)"; if ($rdSvc -eq 'Any') { $rdSvc = '' }
    $rdProto = "$($rdPf.Protocol)"; if (-not $rdProto) { $rdProto = 'Any' }
    $rdLp = (@($rdPf.LocalPort)  | Where-Object { $null -ne $_ -and "$_" }) -join ','; if (-not $rdLp) { $rdLp = 'Any' }
    $rdRp = (@($rdPf.RemotePort) | Where-Object { $null -ne $_ -and "$_" }) -join ','; if (-not $rdRp) { $rdRp = 'Any' }
    $rdWho = 'ANY program'
    if     ($rdProg -and $rdSvc) { $rdWho = "$rdProg (service $rdSvc)" }
    elseif ($rdProg)             { $rdWho = $rdProg }
    elseif ($rdPkg)              { $rdWho = 'Store-type app (package rule)' }
    elseif ($rdSvc)              { $rdWho = "service $rdSvc" }
    $rdLeaf = ''
    if ($rdProg) { try { $rdLeaf = "$(Split-Path $rdProg -Leaf)" } catch { $rdLeaf = '' } }
    $Row.Protocol   = $rdProto
    $Row.LocalPort  = $rdLp
    $Row.RemotePort = $rdRp
    $Row.Program    = $rdProg
    $Row.Who        = $rdWho
    # "one port only" works for an outbound rule that names one program file (as Firewall V does: never svchost / a service)
    $Row.CanPort    = [bool](("$($Row.Direction)" -eq 'Outbound') -and ($rdProg -match '^[A-Za-z]:\\') -and $rdLeaf -and ($rdLeaf -ine 'svchost.exe') -and (-not $rdSvc))
    $Row.Detail     = $true
    return $Row
}
# Every allow rule that is ON, was not made by WHD and is not on your kept list. Outbound rules only while
# outbound is Block. Rows the gate leaks through (outbound) come first. Read-only.
function Get-WHDForeignRules {
    $frC = $script:WHDFwScanCache
    if ($frC -and [int]$script:WHDFwScanSeconds -gt 0) {
        $frAge = ((Get-Date) - $frC.At).TotalSeconds      # (a clock that was set back gives a negative age: read again)
        if ($frAge -ge 0 -and $frAge -lt [int]$script:WHDFwScanSeconds) { return @($frC.Rows) }
    }
    $frOwn = @(Get-WHDFwOwnGroups)
    $frOutBlock = (@(Get-WHDFwProfiles | ForEach-Object { "$($_.DefaultOutboundAction)" }) -contains 'Block')
    $frKnown = @{}; foreach ($frN in @((Get-WHDFwKnown).Names)) { $frKnown["$frN".ToLower()] = $true }
    $frKeptOut = New-Object System.Collections.Generic.List[string]      # outbound rules you kept that are ON while outbound is Block
    $frRows = @(foreach ($frR in @(Get-NetFirewallRule -EA SilentlyContinue)) {
        if ($frOwn -contains "$($frR.Group)") { continue }
        if ("$($frR.Enabled)" -ne 'True' -or "$($frR.Action)" -ne 'Allow') { continue }
        $frDir = "$($frR.Direction)"
        if ($frDir -ne 'Inbound' -and -not $frOutBlock) { continue }
        $frDn = "$($frR.DisplayName)"; if (-not $frDn) { $frDn = "$($frR.Name)" }
        if ($frKnown.ContainsKey("$($frR.Name)".ToLower())) { if ($frDir -ne 'Inbound') { $frKeptOut.Add($frDn) }; continue }
        [pscustomobject]@{ Name = "$($frR.Name)"; DisplayName = $frDn; Direction = $frDir; Leak = [bool]($frDir -ne 'Inbound')
            Protocol = ''; LocalPort = ''; RemotePort = ''; Program = ''; Who = ''; CanPort = $false; Detail = $false; Rule = $frR }
    })
    $frSorted = @($frRows | Sort-Object @{ e = { if ($_.Leak) { 0 } else { 1 } } }, @{ e = { "$($_.DisplayName)" } }, @{ e = { "$($_.Name)" } })
    $script:WHDFwScanCache = [pscustomobject]@{ At = (Get-Date); Rows = $frSorted; KeptOut = @($frKeptOut.ToArray()) }
    return @($frSorted)
}
# The outbound allow rules you chose to keep that are ON while outbound is Block (display names): their programs
# get through the update gate / default-deny. Not an alert - WHD names them so that they are not forgotten.
function Get-WHDFwKeptOutNow {
    try { [void](Get-WHDForeignRules); return @(@($script:WHDFwScanCache.KeptOut) | Where-Object { $_ }) } catch { return @() }
}
function Get-WHDFwKeptOutText {
    $koAll = @(Get-WHDFwKeptOutNow)
    if (-not $koAll.Count) { return '' }
    $koUni = @($koAll | Select-Object -Unique)
    return ("{0} outbound allow rule(s) you chose to keep are ON and get through although outbound is Block: {1}{2}" -f $koAll.Count, ((@($koUni | Select-Object -First 8)) -join ', '), $(if ($koUni.Count -gt 8) { (' and {0} more' -f ($koUni.Count - 8)) } else { '' }))
}
# The rows WHD raises an alert for: the outbound leak always; the inbound rules once you switched their watch on.
function Get-WHDForeignAttention {
    param([object[]]$Rows)
    if ($null -eq $Rows) { $Rows = @(Get-WHDForeignRules) }
    if ((Get-WHDFwKnown).Inbound) { return @($Rows | Where-Object { $_ }) }
    return @($Rows | Where-Object { $_ -and $_.Leak })
}
# One line for the head of a screen. Alert = $true: something to decide; $false: a hint only; Text '' = nothing to say.
# Unwatched = number of inbound rules that are there but not watched (0 once the watch is on). KeptOut = see Get-WHDFwKeptOutText.
function Get-WHDForeignSummary {
    $fsRows = @(Get-WHDForeignRules)
    $fsAtt  = @(Get-WHDForeignAttention -Rows $fsRows)
    $fsOut  = @($fsRows | Where-Object { $_.Leak }).Count
    $fsIn   = $fsRows.Count - $fsOut
    $fsText = ''; $fsAlert = $false; $fsUnw = 0
    if (-not (Get-WHDFwKnown).Inbound) { $fsUnw = $fsIn }
    if ($fsAtt.Count) {
        $fsAlert = $true
        $fsAo = @($fsAtt | Where-Object { $_.Leak }).Count
        $fsAi = $fsAtt.Count - $fsAo
        $fsThrough = 'default-deny outbound'
        if ((Get-Command Test-WHDGateClosed -EA SilentlyContinue) -and (Test-WHDGateClosed)) { $fsThrough = ("the update gate ({0})" -f "$((Get-WHDGateState).Mode)".ToUpper()) }
        $fsBits = @()
        if ($fsAo) { $fsBits += ("{0} outbound - they get through {1}" -f $fsAo, $fsThrough) }
        if ($fsAi) { $fsBits += ("{0} inbound - their programs can be reached from outside" -f $fsAi) }
        $fsText = ("{0} allow rule(s) that WHD did not make are ON: {1}." -f $fsAtt.Count, ($fsBits -join '; '))
    } elseif ($fsUnw) {
        $fsText = ("{0} inbound allow rule(s) were not made by WHD. Inbound rules are not watched (console: K, then S starts that; window: 'Watch inbound rules...')." -f $fsUnw)
    }
    $fsBad = ''
    if ((Get-WHDFwKnown).Unreadable) { $fsBad = ("the file with your kept rules cannot be read ({0}). Until it is repaired or deleted WHD treats it as empty: kept rules are listed again and inbound rules are not watched." -f (_WHDFwKnownPath)) }
    [pscustomobject]@{ Text = $fsText; Alert = $fsAlert; Rows = $fsRows; Attention = $fsAtt; Unwatched = $fsUnw; KeptOut = (Get-WHDFwKeptOutText); FileProblem = $fsBad }
}

# ---- showing them ----------------------------------------------------------------
# -NoRead: do not read the rule's details now (three queries per rule); a row without them gets a short line.
function Get-WHDForeignRowText {
    param($Row, [switch]$NoRead)
    if (-not $NoRead) { [void](Add-WHDFwRuleDetail -Row $Row) }
    if (-not $Row.Detail) { return ('{0,-4} {1}   [{2}]' -f $(if ("$($Row.Direction)" -eq 'Inbound') { 'in' } else { 'out' }), "$($Row.DisplayName)", "$($Row.Name)") }
    $rtPort = if ("$($Row.Direction)" -eq 'Inbound') { "$($Row.LocalPort)" } else { "$($Row.RemotePort)" }      # the side that says what is open
    if ($rtPort -eq 'Any') { $rtPort = 'any' }
    if ($rtPort.Length -gt 11) { $rtPort = $rtPort.Substring(0, 9) + '..' }
    $rtName = "$($Row.DisplayName)"; if ($rtName.Length -gt 30) { $rtName = $rtName.Substring(0, 28) + '..' }
    $rtProto = "$($Row.Protocol)"; if ($rtProto -eq 'Any') { $rtProto = 'any' }
    ('{0,-4} {1,-6} {2,-11} {3,-30} {4}' -f $(if ("$($Row.Direction)" -eq 'Inbound') { 'in' } else { 'out' }), $rtProto, $rtPort, $rtName, "$($Row.Who)")
}
function Show-WHDForeignRules {
    param([object[]]$Rows, [switch]$All)
    $srList = @($Rows | Where-Object { $_ })
    $srMax = [int]$script:WHDFwForeignMax; if ($All) { $srMax = $srList.Count }
    Write-Host ('  {0,3}  {1,-4} {2,-6} {3,-11} {4,-30} {5}' -f '#', 'dir', 'prot', 'port', 'rule', 'program / app') -ForegroundColor DarkGray
    $srI = 0
    foreach ($srR in @($srList | Select-Object -First $srMax)) {
        $srI++
        Write-Host ('  {0,3}  {1}' -f $srI, (Get-WHDForeignRowText -Row $srR)) -ForegroundColor $(if ($srR.Leak) { 'Yellow' } else { 'Gray' })
    }
    if ($srList.Count -gt $srMax) { Write-Host ('       ... and {0} more (L lists every row; * means all {1})' -f ($srList.Count - $srMax), $srList.Count) -ForegroundColor DarkGray }
}

# ---- doing something about them ---------------------------------------------------
# Switch one rule off. Journaled as kind 'fwoff': the Undo center switches it on again, and Verify / the update
# guard report it when something switches it back on. Returns $true when it was done.
function _WHDFwForeignOff {
    param($Row)
    $foName = "$($Row.Name)"; $foDisp = "$($Row.DisplayName)"; $foDir = "$($Row.Direction)"
    $foJr = @{ Kind = 'fwoff'; RuleName = $foName; RuleDisplay = $foDisp; Direction = $foDir; OldEnabled = 'True'; NewEnabled = 'False' }
    $foRes = Invoke-WHDChange -Description ("switch OFF firewall rule not made by WHD: {0} [{1}]" -f $foDisp, $foDir) -Force -Journal $foJr -Action {
        Backup-WHDFirewallOnce
        $foRule = @(Get-WHDFwRuleExact -Name $foName)
        if (-not $foRule.Count) { throw 'the rule is no longer there' }
        $foRule | Set-NetFirewallRule -Enabled False -EA Stop
        if (@(Get-WHDFwRuleExact -Name $foName | Where-Object { "$($_.Enabled)" -eq 'True' }).Count) { throw 'read-back: the rule is still switched on' }
    } | Select-Object -Last 1
    $foDone = [bool]("$($foRes.Status)" -eq 'done')
    # You switched it off yourself: the update gate must not switch it back on when it opens.
    if ($foDone -and $script:WHDExecute -and (Get-Command Remove-WHDGateRemembered -EA SilentlyContinue)) { try { Remove-WHDGateRemembered -Names @($foName) } catch { } }
    return $foDone
}
function _WHDFwForeignRemove {
    param($Row)
    $frmName = "$($Row.Name)"; $frmDisp = "$($Row.DisplayName)"; $frmDir = "$($Row.Direction)"
    $frmJr = @{ RemovedRule = $frmName; Direction = $frmDir; Hint = 'restore the firewall saved at the start of that session (Undo center, F - that also reverts the other firewall changes of that session), or let the program that made the rule write it again' }
    Invoke-WHDChange -Description ("remove firewall rule not made by WHD: {0} [{1}]" -f $frmDisp, $frmDir) -Force -Journal $frmJr -Action {
        Backup-WHDFirewallOnce
        $frmRule = @(Get-WHDFwRuleExact -Name $frmName)
        if (-not $frmRule.Count) { return }      # gone already
        $frmRule | Remove-NetFirewallRule -EA Stop
        if (@(Get-WHDFwRuleExact -Name $frmName).Count) { throw 'read-back: the rule is still there' }
    } | Out-Null
}
# Several rules, ONE question. -Action off | remove | keep | port (port: -Port, TCP, outbound; one WHD allow per program file).
# No Read-Host here: the console view and the window version both call this.
function Invoke-WHDForeignRuleBatch {
    param([object[]]$Rows, [ValidateSet('off','remove','keep','port')][string]$Action, [int]$Port = 443)
    $fbList = @($Rows | Where-Object { $_ })
    if (-not $fbList.Count) { return }
    # Details (protocol, ports, program) cost three queries per rule: read them for "one port only" (it needs the
    # program) and for a list of up to 40 rows; a longer list is logged with direction + name.
    $fbRead = [bool]($Action -eq 'port' -or $fbList.Count -le 40)
    if ($fbRead) { foreach ($fbR in $fbList) { [void](Add-WHDFwRuleDetail -Row $fbR) } }
    if ($Action -eq 'port') {
        if ($Port -lt 1 -or $Port -gt 65535) { Write-WHDLog ("port {0} is not a port number (1 to 65535) - nothing was changed." -f $Port) 'ERR'; return }
        foreach ($fbR in @($fbList | Where-Object { -not $_.CanPort })) {
            Write-WHDLog ("  left out: '{0}' [{1}] - 'one port only' needs an OUTBOUND rule that names one program file (not a Store-type app, a service, or any program). Use switch off, remove or keep for it." -f $fbR.DisplayName, $fbR.Direction) 'WARN'
        }
        $fbList = @($fbList | Where-Object { $_.CanPort })
        if (-not $fbList.Count) { return }
    }
    $fbVerb = switch ($Action) { 'off' { 'switch OFF' } 'remove' { 'REMOVE' } 'keep' { 'KEEP as they are' } default { ("replace by a WHD allow on TCP port {0} only" -f $Port) } }
    Write-WHDLog ("RULES WHD DID NOT MAKE - {0}: {1} rule(s)" -f $fbVerb, $fbList.Count) 'ACT'
    foreach ($fbR in $fbList) { Write-WHDLog ("  {0}" -f (Get-WHDForeignRowText -Row $fbR -NoRead:(-not $fbRead))) 'INFO' }
    switch ($Action) {
        'off'    { Write-WHDRisk 'reversible' 'Each rule stays in Windows'' rule list, switched OFF. The Undo center switches it on again; Verify and the update guard report it if something switches it back on. A program that needs the internet is offline afterwards while outbound is Block - allow it on one port (Firewall V, or "one port only" here).' }
        'remove' { Write-WHDRisk 'caution' 'Each rule is deleted. WHD saves the firewall once per session, before that session''s first firewall change: Undo center F puts the WHOLE firewall back as it was then, so every later firewall change of that session (a gate change included) is reverted with it. Windows or the program that made a rule may write it again - WHD then reports it again.' }
        'keep'   { Write-WHDRisk 'caution' 'Each rule stays ON as it is and is not reported again. A kept OUTBOUND rule keeps its program online through the update gate (CLOSED / PROGRAMS): the gate leaves kept rules on; Status and the menu head lines name them while outbound is Block. WHD keeps a rule by its NAME: if the rule is changed later, or another rule gets that name, it still counts as kept. A rule you had switched off before and keep now is no longer held off (Verify, update guard). The rules you kept can be forgotten again (Firewall K, then F).' }
        default  { Write-WHDRisk 'caution' ("For each program: a WHD allow for that program file - TCP, remote port {0} only, outbound, any destination (the same kind of rule Firewall V makes; with the update gate CLOSED it is saved switched off until PROGRAMS or OPEN). Then the wide rule is switched OFF, not deleted. The allow is tied to that exact file: when the program moves or updates into another folder it is blocked again and shows in Firewall V." -f $Port) }
    }
    $fbAsk = switch ($Action) { 'off' { "switch OFF the {0} rule(s) listed above" } 'remove' { "REMOVE the {0} rule(s) listed above" } 'keep' { "keep the {0} rule(s) listed above ON as they are" } default { "replace the {0} rule(s) listed above by a WHD allow on TCP port $Port" } }
    if (-not (Confirm-WHDProceed ($fbAsk -f $fbList.Count))) { Write-WHDLog 'skipped.' 'WARN'; return }
    # The question above covers the whole list: the single steps do not ask again.
    $fbPrev = $script:WHDConfirm; $fbPrevBatch = $script:WHDFwAllowBatch
    $script:WHDConfirm = { param($m) $true }; $script:WHDFwAllowBatch = $true
    try {
        switch ($Action) {
            'off'    { foreach ($fbR in $fbList) { [void](_WHDFwForeignOff -Row $fbR) } }
            'remove' { foreach ($fbR in $fbList) { _WHDFwForeignRemove -Row $fbR } }
            'keep'   {
                $fbOld = @((Get-WHDFwKnown).Own)
                $fbAdd = @($fbList | ForEach-Object { "$($_.Name)" })
                $fbShow = (@($fbList | Select-Object -First 5 | ForEach-Object { "$($_.DisplayName)" }) -join ', '); if ($fbList.Count -gt 5) { $fbShow += (' and {0} more' -f ($fbList.Count - 5)) }
                Invoke-WHDChange -Description ("keep {0} firewall rule(s) not made by WHD as they are: {1}" -f $fbAdd.Count, $fbShow) -Force -Journal @{ Hint = 'Firewall menu K, then F: forgets the rules you kept (they are then listed again)' } -Action {
                    if (-not (Save-WHDFwKnown -Names (@($fbOld) + @($fbAdd)))) { throw 'the list of kept rules could not be saved' }
                } | Out-Null
                # A rule you switched OFF earlier and keep now: its 'switched off' entries no longer stand, or Verify and the
                # update guard would report it as changed back and re-apply would switch it off again.
                if ($script:WHDExecute -and (Get-Command Clear-WHDFwOffEntries -EA SilentlyContinue)) {
                    $fbKeptNow = @{}; foreach ($fbKn in @((Get-WHDFwKnown).Names)) { $fbKeptNow["$fbKn".ToLower()] = $true }
                    try {
                        $fbRet = [int](Clear-WHDFwOffEntries -Names @($fbAdd | Where-Object { $fbKeptNow.ContainsKey("$_".ToLower()) }))
                        if ($fbRet) { Write-WHDLog ("  {0} earlier 'switched OFF' record(s) of these rules no longer stand (you keep the rules ON now)." -f $fbRet) 'INFO' }
                    } catch { }
                }
            }
            default  {
                $fbProg = @{}      # program file -> $true when its WHD allow is there
                $fbNameOf = @{}    # WHD allow name -> the program file it was made for in this run
                foreach ($fbR in $fbList) {
                    $fbKey = "$($fbR.Program)".ToLower()
                    if (-not $fbProg.ContainsKey($fbKey)) {
                        $fbItem = [pscustomobject]@{ Direction = 'Outbound'; Program = "$($fbR.Program)"; Exe = "$(Split-Path "$($fbR.Program)" -Leaf)"; Protocol = 'TCP'; RemotePort = "$Port" }
                        $fbAllowName = Get-WHDProgramAllowName -Program $fbItem.Program -Protocol 'TCP' -RemotePort "$Port"
                        # The allow's rule name is built from the FILE name: two programs with the same file name in different
                        # folders would share one rule, and the second would replace the first. Refuse the second.
                        $fbClash = ''
                        if ($fbNameOf.ContainsKey($fbAllowName) -and "$($fbNameOf[$fbAllowName])".ToLower() -ne $fbKey) { $fbClash = "$($fbNameOf[$fbAllowName])" }
                        else {
                            foreach ($fbEx in @(Get-NetFirewallRule -Name $fbAllowName -EA SilentlyContinue)) {
                                $fbExProg = ''
                                try { $fbExProg = "$(@($fbEx | Get-NetFirewallApplicationFilter -EA SilentlyContinue)[0].Program)" } catch { $fbExProg = '' }
                                if ($fbExProg) { try { $fbExProg = [Environment]::ExpandEnvironmentVariables($fbExProg) } catch { } }
                                if ($fbExProg -and $fbExProg -ne 'Any' -and $fbExProg.ToLower() -ne $fbKey -and (Test-Path -LiteralPath $fbExProg)) { $fbClash = $fbExProg }
                            }
                        }
                        if ($fbClash) {
                            Write-WHDLog ("  not done for {0}: a WHD allow for another program with the same file name is there already ({1}), and one rule name cannot serve both. Nothing was changed for it - keep its rule, switch it off, or undo the other allow first (Undo center)." -f $fbItem.Program, $fbClash) 'ERR'
                            $fbProg[$fbKey] = $false
                        } else {
                            $fbNameOf[$fbAllowName] = "$($fbItem.Program)"
                            Add-WHDProgramAllow -Item $fbItem | Out-Null
                            $fbProg[$fbKey] = [bool]((-not $script:WHDExecute) -or @(Get-NetFirewallRule -Name $fbAllowName -EA SilentlyContinue).Count)
                        }
                    }
                    if ($fbProg[$fbKey]) { [void](_WHDFwForeignOff -Row $fbR) }
                    else { Write-WHDLog ("  the WHD allow for {0} could not be made, so its rule '{1}' was left as it is." -f $fbR.Program, $fbR.DisplayName) 'ERR' }
                }
                # other wide rules of the same program that were not selected keep it wide open: say so
                if ($script:WHDExecute) {
                    $fbLeft = @(Get-WHDForeignRules | Where-Object { $_.Leak } | ForEach-Object { Add-WHDFwRuleDetail -Row $_ } | Where-Object { $_.Program -and $fbProg.ContainsKey("$($_.Program)".ToLower()) })
                    if ($fbLeft.Count) { Write-WHDLog ("  {0} other outbound rule(s) of the same program(s) are still ON and keep them wide open: {1}. Select them too." -f $fbLeft.Count, ((@($fbLeft | ForEach-Object { "$($_.DisplayName)" }) | Select-Object -Unique) -join ', ')) 'WARN' }
                }
            }
        }
    } finally { $script:WHDConfirm = $fbPrev; $script:WHDFwAllowBatch = $fbPrevBatch }
    if ($script:WHDExecute) {
        $fbRest = @(Get-WHDForeignAttention)
        if ($fbRest.Count) { Write-WHDLog ("{0} allow rule(s) that WHD did not make are still ON." -f $fbRest.Count) 'WARN' }
        else { Write-WHDLog 'No allow rule that WHD did not make is left to decide.' 'OK' }
    }
}
# Forget the rules YOU kept (answer k). The rules themselves are not touched; they are listed again. The inbound rules
# that were counted as kept when the watch started (or by a wipe / reset / import / restore) stay as they are - emptying
# those too would put every inbound rule of Windows on the list at once.
function Clear-WHDFwKnown {
    $ckKn = Get-WHDFwKnown
    $ckN = @($ckKn.Own).Count
    Write-WHDLog ("FORGET the firewall rules you kept ({0} name(s))" -f $ckN) 'ACT'
    if (-not $ckN) { Write-WHDLog 'You have not kept any rule - nothing to forget.' 'INFO'; return }
    Write-WHDRisk 'reversible' ("No firewall rule is changed. The {0} rule(s) you kept are listed again (outbound ones while outbound is Block, inbound ones while the inbound rules are watched) and you decide again.{1}" -f $ckN, $(if (@($ckKn.Base).Count) { " The $(@($ckKn.Base).Count) inbound rule(s) that were counted as kept at a start stay counted." } else { '' }))
    if (-not (Confirm-WHDProceed ("forget the {0} firewall rule(s) you kept (they are listed again)" -f $ckN))) { Write-WHDLog 'skipped.' 'WARN'; return }
    Invoke-WHDChange -Description ("forget the {0} firewall rule(s) you kept" -f $ckN) -Force -Journal @{ Hint = 'keep the rules again (Firewall menu K)' } -Action {
        if (-not (Save-WHDFwKnown -Names @())) { throw 'the list could not be saved' }
    } | Out-Null
}

# Console: the list + one answer line (Firewall menu K, Updates menu K, and by itself when a new rule shows up).
# While the inbound rules are not watched only the outbound rows are listed and numbered ("*" = those); L lists
# and numbers every row, the inbound ones included.
function Invoke-WHDForeignRulesView {
    param([switch]$Alert)
    $fvAll = $false
    while ($true) {
        $fvEvery = @(Get-WHDForeignRules)
        $fvKn    = Get-WHDFwKnown
        $fvRows  = $fvEvery
        if (-not $fvKn.Inbound -and -not $fvAll) { $fvRows = @($fvEvery | Where-Object { $_.Leak }) }
        $fvHidden = $fvEvery.Count - $fvRows.Count
        foreach ($fvR in $fvRows) { $script:WHDFwForeignSeen["$($fvR.Name)".ToLower()] = $true }
        Write-Host ''
        Write-Host '  ---------- RULES WHD DID NOT MAKE (allow rules that are ON) ----------' -ForegroundColor White
        if ($Alert) { Write-Host '  WHD opened this list because a rule is there that neither WHD nor you put in.' -ForegroundColor Yellow }
        if ($fvKn.Unreadable) { Write-Host ("  !! the file with your kept rules cannot be read ({0}); WHD treats it as empty." -f (_WHDFwKnownPath)) -ForegroundColor Yellow }
        if (-not $fvRows.Count) {
            Write-Host '  none to decide.' -ForegroundColor Green
            if (-not @($fvKn.Own).Count -and $fvKn.Inbound) { return }
        } else {
            Show-WHDForeignRules -Rows $fvRows -All:$fvAll
            Write-Host '  yellow = outbound: gets out although outbound is Block.   gray = inbound: that program can be reached from outside.' -ForegroundColor DarkGray
            if (-not $script:WHDExecute) { Write-Host '  DRY-RUN: an answer is only previewed. Switch to EXECUTE (main menu 8) to change something.' -ForegroundColor Cyan }
            Write-Host '  Numbers + action, e.g.  1,3 o    2 r    * k    4 p    (one question for the list)'
            Write-Host '     o = switch OFF     r = remove     k = keep as it is     p = one port only (outbound rule of one program file)'
        }
        if ($fvHidden) { Write-Host ("  {0} inbound allow rule(s) not made by WHD are not listed here (inbound rules are not watched). L lists and numbers them too." -f $fvHidden) -ForegroundColor DarkGray }
        $fvKo = Get-WHDFwKeptOutText
        if ($fvKo) { Write-Host ("  kept: {0}" -f $fvKo) -ForegroundColor DarkYellow }
        if (-not $fvKn.Inbound) { Write-Host '  S = watch the INBOUND rules too (not watched now: WHD alerts only for the outbound ones; it asks how to start)' }
        if (@($fvKn.Own).Count) { Write-Host ('  F = forget the {0} rule(s) you kept (they are listed again)' -f @($fvKn.Own).Count) }
        $fvIn = (Read-Host '  Answer (L = list every row, Enter = leave for now)').Trim()
        if (-not $fvIn) { return }
        if ($fvIn -match '^[Ll]$') { $fvAll = $true; continue }
        if ($fvIn -match '^[Ff]$') { Clear-WHDFwKnown; if (-not $script:WHDExecute) { return }; continue }
        if ($fvIn -match '^[Ss]$') {
            if ($fvKn.Inbound) { Write-Host '  The inbound rules are watched already.' -ForegroundColor DarkGray; continue }
            $fvInN = @($fvEvery | Where-Object { -not $_.Leak }).Count
            Write-Host ("  {0} inbound allow rule(s) that WHD did not make are ON now. How to start:" -f $fvInN)
            Write-Host '     N = report only rules that appear from NOW on (the ones present now count as kept)'
            Write-Host '     A = list ALL of them too, until you keep, switch off or remove each one'
            $fvS = (Read-Host '  N, A, or Enter = do not start').Trim()
            if     ($fvS -match '^[Nn]$') { Start-WHDFwInboundWatch -CountPresent }
            elseif ($fvS -match '^[Aa]$') { Start-WHDFwInboundWatch }
            else   { Write-Host '  not started.' -ForegroundColor DarkGray }
            if (-not $script:WHDExecute) { return }
            continue
        }
        if ($fvRows.Count -and $fvIn -match '^([0-9,\s\-\*]+?)\s*([OoRrKkPp])$') {
            $fvSelText = $Matches[1]; $fvAct = "$($Matches[2])".ToLower()
            $fvSel = ConvertFrom-WHDSelection -Text $fvSelText -Max $fvRows.Count -Star @(1..$fvRows.Count)
            if ($null -eq $fvSel -or -not @($fvSel).Count) { Write-Host '  invalid.' -ForegroundColor Yellow; continue }
            $fvPick = @(foreach ($fvN in @($fvSel)) { $fvRows[$fvN - 1] })
            switch ($fvAct) {
                'o' { Invoke-WHDForeignRuleBatch -Rows $fvPick -Action off }
                'r' { Invoke-WHDForeignRuleBatch -Rows $fvPick -Action remove }
                'k' { Invoke-WHDForeignRuleBatch -Rows $fvPick -Action keep }
                'p' {
                    $fvPort = (Read-Host '  Remote TCP port for the WHD allow [443]').Trim(); if (-not $fvPort) { $fvPort = '443' }
                    if ($fvPort -notmatch '^[0-9]{1,5}$' -or [int]$fvPort -lt 1 -or [int]$fvPort -gt 65535) { Write-Host '  not a port number (1 to 65535).' -ForegroundColor Yellow; continue }
                    Invoke-WHDForeignRuleBatch -Rows $fvPick -Action port -Port ([int]$fvPort)
                }
            }
            if (-not $script:WHDExecute) { return }      # preview shown once; the same list would only come up again
            continue
        }
        Write-Host '  invalid.' -ForegroundColor Yellow
    }
}

# ---- for the update guard's report ---------------------------------------------------
# The lines of its firewall section and whether they are an alert. Read-only; never throws.
# An alert: an allow rule WHD did not make is ON (see Get-WHDForeignAttention), or the update gate is not
# what its record says (its own rules are gone, or something set outbound back to Allow).
function Get-WHDFirewallGuardReport {
    $grLines = New-Object System.Collections.Generic.List[string]
    $grAlert = $false
    try {
        $grAll = @(Get-WHDForeignRules)
        $grAtt = @(Get-WHDForeignAttention -Rows $grAll)
        if ($grAtt.Count) {
            $grAlert = $true
            $grLines.Add(("  !! {0} allow rule(s) that WHD did not make are ON ({1} outbound, {2} inbound):" -f $grAtt.Count, @($grAtt | Where-Object { $_.Leak }).Count, @($grAtt | Where-Object { -not $_.Leak }).Count))
            foreach ($grRow in @($grAtt | Select-Object -First 25)) { $grLines.Add(("     {0}" -f (Get-WHDForeignRowText -Row $grRow))) }
            if ($grAtt.Count -gt 25) { $grLines.Add(("     ... and {0} more" -f ($grAtt.Count - 25))) }
            $grLines.Add('  -> An outbound rule lets its program out although outbound is Block (update gate / default-deny); an inbound rule lets its program be reached from outside.')
            $grLines.Add('  -> Start WHD: it shows the list and asks (Firewall or Updates menu, K): switch off / remove / keep / one port only.')
        } elseif ($grAll.Count) {
            $grLines.Add(("  {0} inbound allow rule(s) were not made by WHD; inbound rules are not watched (WHD console: Firewall or Updates menu K, then S; window: Firewall tab, 'Watch inbound rules...')." -f $grAll.Count))
        } else { $grLines.Add('  rules WHD did not make: none that are ON and not kept by you') }
        $grKo = Get-WHDFwKeptOutText
        if ($grKo) { $grLines.Add(("  kept by you: {0}" -f $grKo)) }
        if ((Get-WHDFwKnown).Unreadable) { $grLines.Add(("  note: the file with your kept rules cannot be read ({0}); WHD treats it as empty." -f (_WHDFwKnownPath))) }
        if (Get-Command Get-WHDGateHealth -EA SilentlyContinue) {
            foreach ($grP in @((Get-WHDGateHealth).Problems)) { $grAlert = $true; $grLines.Add(("  !! UPDATE GATE: {0}" -f $grP)) }
        }
    } catch { $grLines.Add(("  check failed: {0}" -f $_.Exception.Message)) }
    [pscustomobject]@{ Lines = @($grLines.ToArray()); Alert = $grAlert }
}

# ---- the head lines of the Firewall and Updates menus (and of WHD's start) ------------
# Read-only. Says when the update gate is not what it is recorded as, and when rules WHD did not make are ON.
# -AtStart: printed before the main menu / at the end of -Apply, where K is not a key - say where K is.
function Show-WHDFwAttentionLines {
    param([switch]$AtStart)
    $alK = 'K'; if ($AtStart) { $alK = 'Firewall menu (9) or Updates menu (W), then K' }
    try {
        if (Get-Command Get-WHDGateHealth -EA SilentlyContinue) {
            foreach ($alP in @((Get-WHDGateHealth).Problems)) { Write-Host ("  !! UPDATE GATE: {0}" -f $alP) -ForegroundColor Yellow }
        }
        $alS = Get-WHDForeignSummary
        if ($alS.Alert) {
            Write-Host ("  !! {0}" -f $alS.Text) -ForegroundColor Red
            Write-Host ("     {0} = look at them and decide (switch off / remove / keep / one port only)" -f $alK) -ForegroundColor Red
        } elseif ($alS.Text -and -not $AtStart) { Write-Host ("  K: {0}" -f $alS.Text) -ForegroundColor DarkGray }
        if ($alS.KeptOut) { Write-Host ("  kept: {0}" -f $alS.KeptOut) -ForegroundColor DarkYellow }
        if ($alS.FileProblem) { Write-Host ("  !! {0}" -f $alS.FileProblem) -ForegroundColor Yellow }
    } catch { Write-Host ("  (the check for rules WHD did not make failed: {0})" -f $_.Exception.Message) -ForegroundColor DarkGray }
}
# Opens the list + question by itself when a rule is there that was not yet shown in this session (console only).
function Invoke-WHDFwAttentionAsk {
    try {
        $aaNew = @(Get-WHDForeignAttention | Where-Object { -not $script:WHDFwForeignSeen.ContainsKey("$($_.Name)".ToLower()) })
        if (-not $aaNew.Count) { return }
        Write-WHDLog ("ALERT: {0} allow rule(s) that WHD did not make are ON and were not shown before in this session." -f $aaNew.Count) 'WARN'
        Invoke-WHDForeignRulesView -Alert
    } catch { Write-WHDLog ("the check for rules WHD did not make failed: {0}" -f $_.Exception.Message) 'WARN' }
}

# =============================================================================
#  MENU
# =============================================================================
# One aligned menu row: key gutter (cyan) + label. Single column = never wraps.
function Write-WHDMenuItem {
    param([string]$Key, [string]$Label, [string]$Hint = '')
    Write-Host ('    {0,-2}  ' -f $Key) -ForegroundColor Cyan -NoNewline
    Write-Host $Label -NoNewline
    if ($Hint) { Write-Host ("  $Hint") -ForegroundColor DarkGray -NoNewline }
    Write-Host ''
}
function Show-WHDFirewallMenu {
    Write-Host ''
    Write-Host '  =============== Windows Firewall ===============' -ForegroundColor White
    Show-WHDFirewallSummary
    Write-Host ''
    Write-Host '  IPv6' -ForegroundColor DarkGray
    Write-WHDMenuItem '1' 'Suppress IPv6 (keep ::1 loopback)'
    Write-WHDMenuItem '2' 'Suppress IPv6 + block ::1 loopback' '[strict]'
    Write-WHDMenuItem '3' 'Re-enable IPv6'
    Write-Host '  Rules' -ForegroundColor DarkGray
    Write-WHDMenuItem '4' 'List rules (detailed)'
    Write-WHDMenuItem 'L' 'List custom rules only'
    Write-Host '  DNS' -ForegroundColor DarkGray
    Write-WHDMenuItem 'D' 'Set Cloudflare 1.1.1.2 + encrypted DoH'
    Write-WHDMenuItem 'U' 'Reset DNS to automatic (DHCP)'
    Write-Host '  Outbound / strict mode' -ForegroundColor DarkGray
    Write-WHDMenuItem '5' 'Apply outbound allow-list'
    Write-WHDMenuItem '6' 'Enable default-deny outbound'
    Write-WHDMenuItem '7' 'Confirm keep default-deny'
    Write-WHDMenuItem '8' 'Revert default-deny'
    Write-Host '  Blacklist' -ForegroundColor DarkGray
    Write-WHDMenuItem '9' 'Block IP list' '(profiles\blacklist-ip.txt)'
    Write-WHDMenuItem 'H' 'Hosts sinkhole' '(profiles\blacklist-hosts.txt)'
    Write-WHDMenuItem 'C' 'Clear blacklist'
    Write-WHDMenuItem 'F' 'Refresh blocklist from files' '(profiles\incoming)'
    Write-Host '  Blocked connections' -ForegroundColor DarkGray
    Write-WHDMenuItem 'M' 'Turn ON the Windows Firewall log' '(default file, dropped + allowed, 32,767 KB)'
    Write-WHDMenuItem 'O' 'Turn OFF the Windows Firewall log'
    Write-WHDMenuItem 'V' 'View blocked connections / allow a program' '(several at once: 1,3 or 1-3)'
    Write-WHDMenuItem 'G' 'Remove all per-program allows'
    Write-Host '  Rules from others' -ForegroundColor DarkGray
    Write-WHDMenuItem 'K' 'Rules WHD did not make' '(allow rules that are ON: switch off / remove / keep / one port only)'
    Write-Host '  Time sync' -ForegroundColor DarkGray
    Write-WHDMenuItem 'T' 'Use time.cloudflare.com' '(UDP 123 pinned + 1 h time-jump limit)'
    Write-WHDMenuItem 'N' 'Use Windows default time server' '(and default time settings)'
    Write-WHDMenuItem 'S' 'Time + logging status'
    Write-WHDMenuItem 'Z' 'Time zone + date/time' '(same as main menu T)'
    Write-Host '  Policy files' -ForegroundColor DarkGray
    Write-WHDMenuItem 'X' 'Export policy (json + .wfw)'
    Write-WHDMenuItem 'I' 'Import policy'
    Write-WHDMenuItem 'R' 'Reset to Windows defaults'
    Write-WHDMenuItem 'W' 'Wipe all rules (empty slate)'
    Write-WHDMenuItem 'A' 'Apply firewall profile'
    Write-Host ''
    Write-WHDMenuItem 'B' 'Back to main menu'
    Write-WHDMenuItem 'Q' 'Quit WinHardenDebloat'
    Write-Host ''
}

function Invoke-WHDFirewallSubmenu {
    $pdir = Join-Path $script:WHDRoot 'profiles'
    while ($true) {
        # v1.5: a rule that neither WHD nor you put in and that was not shown yet -> the list + question first
        Invoke-WHDFwAttentionAsk
        Show-WHDMode
        Show-WHDFirewallMenu
        $c = (Read-Host '  Select (Enter accepts the [default] file)').Trim()
        if (Invoke-WHDGuardHotkey $c) { continue }
        switch -regex ($c) {
            '^1$'   { Invoke-WHDDisableIPv6 }
            '^2$'   { Invoke-WHDDisableIPv6 -BlockLoopback }
            '^3$'   { Invoke-WHDEnableIPv6 }
            '^4$'   { Get-WHDFirewallRules -Detail | Format-Table Dir,Action,Enabled,Protocol,LocalPort,RemotePort,DisplayName -AutoSize -Wrap | Out-Host }
            '^[Ll]$'{ Get-WHDFirewallRules -CustomOnly -Detail | Format-Table Dir,Action,Enabled,Protocol,LocalPort,RemotePort,DisplayName -AutoSize -Wrap | Out-Host }
            '^[Dd]$'{ Invoke-WHDSetDns -Mode Cloudflare }
            '^[Uu]$'{ Invoke-WHDSetDns -Mode Reset }
            '^5$'   { Invoke-WHDFirewallAllowList }
            '^6$'   { $m=(Read-Host '  Auto-rollback minutes [10]').Trim(); if(-not $m){$m=10}; Enable-WHDDefaultDenyOutbound -RollbackMinutes ([int]$m) }
            '^7$'   { Confirm-WHDDefaultDenyKeep }
            '^8$'   { Disable-WHDDefaultDenyOutbound }
            '^9$'   { $def=Join-Path $pdir 'blacklist-ip.txt';    $f=(Read-Host ("  IP/CIDR list file [{0}]" -f $def)).Trim(); if(-not $f){$f=$def}; Block-WHDIPList -Path $f }
            '^[Hh]$'{ $def=Join-Path $pdir 'blacklist-hosts.txt'; $f=(Read-Host ("  Domain list file [{0}]" -f $def)).Trim(); if(-not $f){$f=$def}; Block-WHDHostsList -Path $f }
            '^[Cc]$'{ Remove-WHDBlacklist }
            '^[Ff]$'{
                $sum = Invoke-WHDBlocklistRefresh -Mode Preview
                if ($sum -and $script:WHDExecute) {
                    $a = (Read-Host '  M = merge,  R = replace,  Enter = cancel').Trim()
                    $mode = switch -regex ($a) { '^[Mm]$' { 'Merge' } '^[Rr]$' { 'Replace' } default { $null } }
                    if ($mode) {
                        Invoke-WHDBlocklistRefresh -Mode $mode | Out-Null
                        $yn = (Read-Host '  Rebuild the firewall block rules from the updated list now? [y/N]').Trim()
                        if ($yn -match '^[Yy]') { Update-WHDBlocklistRules }
                    } else { Write-Host '  cancelled.' -ForegroundColor DarkGray }
                } elseif ($sum) { Write-WHDLog 'DRY-RUN: preview only. Switch to EXECUTE (main menu 8) to merge or replace.' 'DRY' }
            }
            '^[Mm]$'{ Enable-WHDConnectionLogging }
            '^[Oo]$'{ Disable-WHDConnectionLogging }
            '^[Vv]$'{ Invoke-WHDBlockedView }
            '^[Gg]$'{ Remove-WHDProgramAllows }
            '^[Kk]$'{ Invoke-WHDForeignRulesView }
            '^[Tt]$'{ Invoke-WHDSetTimeSync -Mode Cloudflare }
            '^[Nn]$'{ Invoke-WHDSetTimeSync -Mode Windows }
            '^[Ss]$'{ Show-WHDTimeStatus; Show-WHDConnectionLoggingState }
            '^[Zz]$'{ if (Get-Command Invoke-WHDTimeRegionSubmenu -EA SilentlyContinue) { Invoke-WHDTimeRegionSubmenu } else { Write-WHDLog 'TimeRegion.ps1 not loaded.' 'ERR' } }
            '^[Xx]$'{ $f=(Read-Host '  Export base path [blank = restore\<timestamp>\firewall-policy]').Trim(); if($f){ Export-WHDFirewallPolicy -Path $f } else { Export-WHDFirewallPolicy } }
            '^[Ii]$'{ $f=(Read-Host '  Import file (.json or .wfw), blank to cancel').Trim(); if($f){ $mode= if($f -match '\.wfw$'){'Wfw'}else{'Json'}; Import-WHDFirewallPolicy -Path $f -Mode $mode; if ($mode -eq 'Wfw' -and "$($script:WHDFwToolStatus)" -eq 'done' -and (Get-Command Invoke-WHDGateRepairOffer -EA SilentlyContinue)) { Invoke-WHDGateRepairOffer -After 'the import' } } }
            '^[Rr]$'{ Invoke-WHDFirewallReset }
            '^[Ww]$'{ $yn=(Read-Host '  Apply the WHD baseline right after wiping? [y/N]').Trim(); if($yn -match '^[Yy]'){ Invoke-WHDFirewallWipe -ApplyBaseline } else { Invoke-WHDFirewallWipe }; if ("$($script:WHDFwToolStatus)" -eq 'done' -and (Get-Command Invoke-WHDGateRepairOffer -EA SilentlyContinue)) { Invoke-WHDGateRepairOffer -After 'the wipe' } }
            '^[Aa]$'{ $def=Join-Path $pdir 'firewall-baseline.json'; $f=(Read-Host ("  Firewall profile [{0}]" -f $def)).Trim(); if(-not $f){$f=$def}; Invoke-WHDApplyFirewallProfile -Path $f }
            '^[Bb]$'{ return }
            '^[Qq]$'{ $script:WHDQuit = $true; return }
            default { Write-Host '  invalid.' -ForegroundColor Yellow }
        }
    }
}

Write-WHDLog 'Firewall.ps1 loaded.' 'INFO'
