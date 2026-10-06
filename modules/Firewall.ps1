<#
================================================================================
 WHD Next  -  modules\Firewall.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Windows Defender Firewall with Advanced Security - native, offline hardening.
 Dot-sourced by WHD.ps1 AFTER Common.ps1 (uses that engine for every change).

 Contract honored (see modules\Common.ps1):
   * Nothing changes unless $script:WHDExecute is $true. Otherwise DRY-RUN.
   * Every mutation flows through Invoke-WHDChange -> restore point + log + result.
   * Firewall policy is exported to restore\ before the first firewall change.
   * No Read-Host in the engine functions; approval is the caller's job.

 Decisions locked with the user (2026-09-21):
   D1 terminal module now      D2 adapter+registry + firewall block rules (keep ::1)
   D3 export BOTH json + .wfw   D4 design toward default-deny outbound

 NetSecurity / NetAdapter cmdlets used here ship on Windows 11 Home; no
 AppLocker / gpedit / secpol dependency. All operations work with no internet.
================================================================================
#>

# All rules this module creates carry one of these groups, so they list and
# remove as a set and never get confused with Microsoft's built-in rules.
$script:WHDFwGroupIPv6   = 'WinHardenDebloatNext-IPv6'
$script:WHDFwGroupAllow  = 'WinHardenDebloatNext-AllowList'
$script:WHDFwGroupBlock  = 'WinHardenDebloatNext-Blacklist'
$script:WHDFwGroupBase   = 'WinHardenDebloatNext-Baseline'
$script:WHDFwGroupApp    = 'WinHardenDebloatNext-AppAllow'    # Phase 6: per-program allows from the blocked-connection viewer
$script:WHDFwRollbackTask = 'WHDN-DefaultDenyRollback'
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
# the WHD baseline suppresses IPv6).
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
    try {
        & netsh advfirewall export "$out" 1>$null 2>$null
        Write-WHDLog ("firewall policy backed up: {0}" -f $out) 'OK'
    } catch { Write-WHDLog "firewall export failed: $($_.Exception.Message)" 'WARN' }
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
    } | Out-Null      # WHD Next: no result row on the screen (no caller uses it)
}

# Create a rule idempotently (remove same-named first), routed through the engine.
function New-WHDFwRule {
    param([hashtable]$Params, [hashtable]$Journal)
    $name = $Params['Name']
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

# =============================================================================
#  1) IPv6 SUPPRESSION  (D2: adapter unbind + registry + firewall block rules)
# =============================================================================
function Invoke-WHDDisableIPv6 {
    param([switch]$BlockLoopback)   # off by default; strict + risky
    Write-Host ''
    Write-WHDLog 'IPv6 suppression (adapter binding + registry + firewall block rules)' 'ACT'
    Write-WHDRisk 'caution' 'Disables IPv6 on network adapters and blocks routable IPv6. Reversible.'
    if ($BlockLoopback) { Write-WHDRisk 'hard' 'ALSO blocking ::1 loopback - may break local apps that use IPv6 to talk to themselves.' }

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
        New-WHDFwRule @{ Name = "WHDN-IPv6-$dir"; DisplayName = "WHD Next Block IPv6 ($dir)";
            Group = $script:WHDFwGroupIPv6; Direction = $dir; Action = 'Block'; Enabled = 'True';
            Profile = 'Any'; RemoteAddress = $script:WHDIPv6Ranges }
        New-WHDFwRule @{ Name = "WHDN-ICMPv6-$dir"; DisplayName = "WHD Next Block ICMPv6 ($dir)";
            Group = $script:WHDFwGroupIPv6; Direction = $dir; Action = 'Block'; Enabled = 'True';
            Profile = 'Any'; Protocol = 'ICMPv6' }
    }

    if ($BlockLoopback) {
        foreach ($dir in @('Inbound','Outbound')) {
            New-WHDFwRule @{ Name = "WHDN-IPv6-Loopback-$dir"; DisplayName = "WHD Next Block IPv6 loopback ::1 ($dir)";
                Group = $script:WHDFwGroupIPv6; Direction = $dir; Action = 'Block'; Enabled = 'True';
                Profile = 'Any'; RemoteAddress = '::1' }
        }
    }
    Write-WHDLog 'IPv6 suppression planned/applied.' 'OK'
}

function Invoke-WHDEnableIPv6 {
    Write-WHDLog 'Re-enabling IPv6 (undo suppression).' 'ACT'
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
    foreach ($g in @($script:WHDFwGroupIPv6,$script:WHDFwGroupAllow,$script:WHDFwGroupBlock,$script:WHDFwGroupBase,$script:WHDFwGroupApp)) {
        $c = @(Get-NetFirewallRule -Group $g -EA SilentlyContinue).Count
        if ($c -gt 0) { Write-Host ('   {0,-28} {1} rule(s)' -f $g, $c) -ForegroundColor Cyan }
    }
    # WHD Next (2026-10-02): the update gate position and why the IP block list is in or out.
    if (Get-Command Get-WHDGateState -EA SilentlyContinue) {
        try { Write-Host ('   Update gate   : {0}' -f (Get-WHDGateState).Text) -ForegroundColor Gray } catch { }
    }
    try {
        $bl = Get-WHDBlocklistNeed
        $blCol = switch ("$($bl.Level)") { 'OK' { 'Green' } 'WARN' { 'Yellow' } default { 'DarkGray' } }
        Write-Host ('   IP block list : {0}{1}' -f $bl.Text, $(if ($bl.Hint) { "  ($($bl.Hint))" } else { '' })) -ForegroundColor $blCol
    } catch { }
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
    $ntpRule = @(Get-NetFirewallRule -Name 'WHDN-Allow-NTP' -EA SilentlyContinue)
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
    Invoke-WHDChange -Description 'netsh advfirewall reset (restore default policy)' -Action {
        Backup-WHDFirewallOnce
        & netsh advfirewall reset 1>$null 2>$null
    } | Out-Null
    Invoke-WHDChange -Description 'enable firewall on all profiles; inbound Block / outbound Allow' -Action {
        Set-NetFirewallProfile -All -Enabled True -DefaultInboundAction Block -DefaultOutboundAction Allow -Confirm:$false -EA Stop
    } | Out-Null
    if ($ApplyBaseline) { Invoke-WHDBlocklistHold { Invoke-WHDFirewallAllowList; Invoke-WHDDisableIPv6 } }
    Write-WHDLog 'Firewall reset complete.' 'OK'
    Sync-WHDBlocklist -AfterChange
}

# Empty slate: delete EVERY rule (Microsoft defaults included) so only what you
# add afterward exists. Firewall stays ON; default actions unchanged.
# This is different from RESET (which repopulates Windows' stock rules).
function Invoke-WHDFirewallWipe {
    param([switch]$ApplyBaseline)
    $all = @(Get-NetFirewallRule -EA SilentlyContinue)
    Write-WHDLog ('WIPE ALL firewall rules (empty slate) - {0} rule(s) present.' -f $all.Count) 'ACT'
    Write-WHDRisk 'hard' 'Deletes EVERY inbound/outbound rule, Windows defaults included. Firewall stays ON (inbound Block / outbound Allow). A .wfw backup is taken first; protected rules are skipped.'
    $whdWipeRes = Invoke-WHDChange -Description ("delete ALL {0} firewall rule(s) - empty slate" -f $all.Count) -Action {
        Backup-WHDFirewallOnce
        # WHD Next (user request 2026-10-02): show progress - deleting several hundred rules one by one takes minutes.
        $whdWipeRules = @(Get-NetFirewallRule -EA SilentlyContinue)
        $whdWipeN = 0; $whdWipeKept = 0
        if ($whdWipeRules.Count -gt 50) { Write-WHDLog ('  deleting {0} rule(s) one by one - this takes a few minutes (about half a second per rule); progress is shown' -f $whdWipeRules.Count) 'INFO' }
        foreach ($r in $whdWipeRules) {
            $whdWipeN++
            try { Remove-NetFirewallRule -Name $r.Name -EA Stop } catch { $whdWipeKept++ }
            Write-WHDProgressStep -Activity 'Deleting firewall rules' -Done $whdWipeN -Total $whdWipeRules.Count -Every 50
        }
        if ($whdWipeKept) { Write-WHDLog ('  {0} rule(s) could not be deleted (protected) and were left in place' -f $whdWipeKept) 'INFO' }
    }
    $whdWipeSynced = $false
    if ($ApplyBaseline) {
        $p = Join-Path $script:WHDRoot 'profiles\firewall-baseline.json'
        if (Test-Path $p) { Invoke-WHDApplyFirewallProfile -Path $p; $whdWipeSynced = $true }   # the profile re-checks the IP block list at its end
        else { Write-WHDLog 'firewall-baseline.json not found; wipe only.' 'WARN' }
    }
    # WHD Next (user decision 2026-10-02): a dry-run must not say the wipe happened.
    switch ("$($whdWipeRes.Status)") {
        'done'    { Write-WHDLog 'Wipe complete. Only rules you add from here exist.' 'OK' }
        'planned' { Write-WHDLog 'PREVIEW only (DRY-RUN): nothing was deleted. Switch EXECUTE on to wipe for real.' 'DRY' }
        default   { Write-WHDLog 'Wipe NOT done - see the lines above.' 'WARN' }
    }
    # The wipe took the IP block rules too; put them back if something is still wide open.
    if (-not $whdWipeSynced) { Sync-WHDBlocklist -AfterChange }
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
    if (-not (Test-Path $Path)) { Write-WHDLog ("import file not found: {0}" -f $Path) 'ERR'; return }
    if ($Mode -eq 'Wfw') {
        Invoke-WHDChange -Description ("import firewall policy blob: {0}" -f $Path) -Action {
            Backup-WHDFirewallOnce
            & netsh advfirewall import "$Path" 1>$null 2>$null
        } | Out-Null
        Sync-WHDBlocklist -AfterChange
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
    Write-WHDLog ("imported {0} rule(s) from {1}" -f @($doc.rules).Count, $Path) 'OK'
    Sync-WHDBlocklist -AfterChange
}

# =============================================================================
#  5) ALLOW-LIST + STAGED DEFAULT-DENY OUTBOUND  (D4: design toward strict)
# =============================================================================
# The allow-list is harmless while outbound default is Allow; it PRE-STAGES the
# rules so flipping to default-deny later does not lock the box out.
function Invoke-WHDFirewallAllowList {
    Write-WHDLog ('Applying essential ALLOW-list (DNS pinned to {0}).' -f ($script:WHDDnsServers -join ', ')) 'ACT'
    # Rebuild cleanly so re-applying is idempotent (re-adds are authoritative).
    Remove-WHDFwGroup -Group $script:WHDFwGroupAllow
    # DNS pinned to the chosen resolver; HTTP/HTTPS open to Any so browsing + WU work.
    # DHCP needs BOTH directions: out (client 68 -> server 67) AND in (server reply
    # back to 68). The inbound half is what Windows' stock "Core Networking DHCP-In"
    # provides and a full WIPE removes - without it a locked-down box can't renew its
    # lease. dir defaults to Outbound when omitted.
    $allow = @(
        @{ n='WHDN-Allow-DNS-UDP';  d='WHD Next Allow DNS (UDP 53)';                  proto='UDP'; rport=53;  raddr=$script:WHDDnsServers }
        @{ n='WHDN-Allow-DNS-TCP';  d='WHD Next Allow DNS (TCP 53)';                  proto='TCP'; rport=53;  raddr=$script:WHDDnsServers }
        @{ n='WHDN-Allow-DHCP-Out'; d='WHD Next Allow DHCP request (UDP out 68->67)'; proto='UDP'; lport=68; rport=67 }
        @{ n='WHDN-Allow-DHCP-In';  d='WHD Next Allow DHCP reply (UDP in <-67)';      dir='Inbound'; proto='UDP'; lport=68; rport=67 }
        @{ n='WHDN-Allow-NTP';      d='WHD Next Allow NTP (UDP 123)';                 proto='UDP'; rport=123; raddr=(Get-WHDNtpRemoteAddress) }
        @{ n='WHDN-Allow-HTTPS';    d='WHD Next Allow HTTPS (TCP 443)';               proto='TCP'; rport=443 }
        @{ n='WHDN-Allow-HTTP';     d='WHD Next Allow HTTP (TCP 80)';                 proto='TCP'; rport=80  }
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
        Invoke-WHDChange -Description ("update gate is {0}: keep WHDN-Allow-HTTPS / WHDN-Allow-HTTP switched off" -f $whdGateName) -Force -Action {
            foreach ($rn in @('WHDN-Allow-HTTPS','WHDN-Allow-HTTP')) { Set-NetFirewallRule -Name $rn -Enabled False -EA SilentlyContinue }
        } | Out-Null
        Write-WHDLog ("Allow-list applied (update gate {0}: the any-program HTTP/HTTPS rules stay off)." -f $whdGateName) 'OK'
        Sync-WHDBlocklist -AfterChange
        return
    }
    Write-WHDLog 'Allow-list applied. DHCP in+out, DNS pinned, HTTP/HTTPS open. Re-apply rebuilds this group.' 'OK'
    Sync-WHDBlocklist -AfterChange
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

function Enable-WHDDefaultDenyOutbound {
    param([int]$RollbackMinutes = 10)
    Write-Host ''
    Write-WHDLog 'Enable DEFAULT-DENY OUTBOUND (strict).' 'ACT'
    Write-WHDRisk 'hard' ("Sets DefaultOutboundAction=Block. Anything not in the allow-list is cut. Auto-rollback in {0} min unless you confirm keep." -f $RollbackMinutes)
    # make sure the allow-list exists first
    if (-not @(Get-NetFirewallRule -Group $script:WHDFwGroupAllow -EA SilentlyContinue)) { Invoke-WHDBlocklistHold { Invoke-WHDFirewallAllowList } }

    # arm the timed rollback BEFORE flipping, so a mistake self-heals
    if ($script:WHDExecute) {
        Initialize-WHDPaths
        $revert = Join-Path $script:WHDRestore 'defdeny-rollback.ps1'
        "Set-NetFirewallProfile -All -DefaultOutboundAction Allow -Confirm:`$false" | Set-Content -Path $revert -Encoding ASCII
        $when = (Get-Date).AddMinutes($RollbackMinutes).ToString('HH:mm')
        # Direct form (seen to create + fire in testing). Non-terminating via
        # local EAP + 2>&1 so a stderr write can't crash the app; capture exit code.
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & schtasks /create /tn $script:WHDFwRollbackTask /tr "powershell -NoProfile -ExecutionPolicy Bypass -File `"$revert`"" `
            /sc once /st $when /rl highest /ru SYSTEM /f 2>&1 | Out-Null
        $code = $LASTEXITCODE
        $ErrorActionPreference = $prev
        if ($code -eq 0) {
            Write-WHDLog ("armed auto-rollback task '{0}' for {1}" -f $script:WHDFwRollbackTask, $when) 'OK'
        } else {
            Write-WHDLog ("could NOT arm auto-rollback (schtasks exit {0}). Default-deny will NOT self-revert - keep this window and use option 8 to revert if the box loses connectivity." -f $code) 'WARN'
        }
    } else {
        Write-WHDLog ("would: arm auto-rollback scheduled task '{0}' (+{1} min)" -f $script:WHDFwRollbackTask, $RollbackMinutes) 'DRY'
    }

    Invoke-WHDChange -Description 'set DefaultOutboundAction = Block (all profiles)' -Action {
        Set-NetFirewallProfile -All -DefaultOutboundAction Block -Confirm:$false -EA Stop
    } | Out-Null
    Write-WHDLog 'Default-deny outbound engaged. Verify connectivity, then run Confirm-WHDDefaultDenyKeep to cancel rollback.' 'WARN'
    Sync-WHDBlocklist -AfterChange
}

function Confirm-WHDDefaultDenyKeep {
    if (-not $script:WHDExecute) { Write-WHDLog 'would: cancel the auto-rollback task (keep default-deny)' 'DRY'; return }
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
    Remove-WHDRollbackTask
    Invoke-WHDChange -Description 'set DefaultOutboundAction = Allow (revert to permissive)' -Action {
        Set-NetFirewallProfile -All -DefaultOutboundAction Allow -Confirm:$false -EA Stop
    } | Out-Null
    Write-WHDLog 'Reverted to default-allow outbound.' 'OK'
    Sync-WHDBlocklist -AfterChange
}

# =============================================================================
#  6) BLACKLIST  (long-term; IP/CIDR firewall rules + hosts sinkhole)
# =============================================================================
# NOTE: Windows Firewall rules match IPs, never domain names. Domains go to the
# hosts sinkhole; IPs/CIDRs go to firewall block rules.
function Block-WHDIPList {
    # -Directions: which half to create. WHD Next (2026-10-02): the block list follows the firewall
    # (section 6b) and passes only the directions that are needed; a direct call without
    # -Directions keeps the old inbound + outbound behaviour.
    param([Parameter(Mandatory)][string]$Path, [int]$ChunkSize = 1000,
          [ValidateSet('Inbound','Outbound')][string[]]$Directions = @('Inbound','Outbound'))
    if (-not (Test-Path -LiteralPath $Path)) { Write-WHDLog ("IP list not found: {0}" -f $Path) 'ERR'; return }
    $raw = @(Get-Content -LiteralPath $Path | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^\s*#' })
    if (-not $raw.Count) { Write-WHDLog 'IP list is empty.' 'WARN'; return }
    # SAFETY GUARD: drop any entry overlapping broadcast/multicast/private/reserved
    # ranges before it can ever become a block rule (see $script:WHDNeverBlock).
    $ips = @(); $skipped = @()
    foreach ($e in $raw) { if (Test-WHDNeverBlock $e) { $skipped += $e } else { $ips += $e } }
    if ($skipped.Count) {
        Write-WHDLog ("SAFETY: skipped {0} unroutable/broadcast/multicast/private entr(y/ies): {1}" -f $skipped.Count, (($skipped | Select-Object -First 5) -join ', ')) 'WARN'
    }
    if (-not $ips.Count) { Write-WHDLog 'IP list has no safe, routable entries after filtering.' 'WARN'; return }
    $whdBlDirs = @($Directions | Select-Object -Unique)
    Write-WHDLog ("Blacklisting {0} safe IP/CIDR entr(y/ies) as firewall block rules ({1})." -f $ips.Count, (($whdBlDirs -join ' + ').ToLower())) 'ACT'
    $i = 0; $chunk = 0
    while ($i -lt $ips.Count) {
        $slice = @($ips[$i..([Math]::Min($i+$ChunkSize-1, $ips.Count-1))])
        $chunk++
        foreach ($dir in $whdBlDirs) {
            New-WHDFwRule @{ Name=("WHDN-Blacklist-{0}-{1}" -f $dir,$chunk); DisplayName=("WHD Next Blacklist IPs {0} #{1}" -f $dir,$chunk);
                Group=$script:WHDFwGroupBlock; Direction=$dir; Action='Block'; Enabled='True'; Profile='Any';
                RemoteAddress=$slice }
        }
        $i += $ChunkSize
    }
    Write-WHDLog ("IP blacklist planned/applied: {0}, {1} rule(s)." -f (($whdBlDirs -join ' + ').ToLower()), ($chunk * $whdBlDirs.Count)) 'OK'
}

function Block-WHDHostsList {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { Write-WHDLog ("hosts blacklist not found: {0}" -f $Path) 'ERR'; return }
    $domains = @(Get-Content $Path | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^\s*#' })
    if (-not $domains.Count) { Write-WHDLog 'hosts blacklist is empty.' 'WARN'; return }
    $hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
    Write-WHDLog ("Sinkholing {0} domain(s) via hosts file." -f $domains.Count) 'ACT'
    Invoke-WHDChange -Description ("sinkhole {0} domain(s) in hosts (idempotent)" -f $domains.Count) -Action {
        Initialize-WHDPaths
        Copy-Item $hosts (Join-Path $script:WHDRestore 'hosts.bak') -Force -EA SilentlyContinue
        # Strip any PRIOR WHD block first so re-applying never stacks duplicates.
        $keep = @(); $skip = $false
        foreach ($l in @(Get-Content $hosts -EA SilentlyContinue)) {
            if ($l -match '^\s*# WHDN-BLACKLIST START') { $skip = $true; continue }
            if ($l -match '^\s*# WHDN-BLACKLIST END')   { $skip = $false; continue }
            if (-not $skip) { $keep += $l }
        }
        $block = @('# WHDN-BLACKLIST START') + ($domains | ForEach-Object { "0.0.0.0 $_" }) + @('# WHDN-BLACKLIST END')
        Set-Content -Path $hosts -Value ($keep + $block) -Encoding ASCII
    } | Out-Null
    Write-WHDLog 'hosts sinkhole planned/applied.' 'OK'
}

function Remove-WHDBlacklist {
    Remove-WHDFwGroup -Group $script:WHDFwGroupBlock
    $hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
    Invoke-WHDChange -Description 'remove WHDN-BLACKLIST block from hosts' -Action {
        $lines = Get-Content $hosts
        $keep = @(); $skip = $false
        foreach ($l in $lines) {
            if ($l -match '^\s*# WHDN-BLACKLIST START') { $skip = $true; continue }
            if ($l -match '^\s*# WHDN-BLACKLIST END')   { $skip = $false; continue }
            if (-not $skip) { $keep += $l }
        }
        Set-Content -Path $hosts -Value $keep -Encoding ASCII
    } | Out-Null
    # WHD Next (user decision 2026-10-02): cleared by hand = the IP block list stops
    # following the firewall until it is applied again (menu 9).
    if ($script:WHDExecute) {
        if (Set-WHDBlocklistState -Follow $false -ListFile (Get-WHDBlocklistState).ListFile) {
            Write-WHDLog 'IP block list: cleared by hand - it no longer follows the firewall. Firewall menu 9 switches that back on.' 'INFO'
        }
    } else {
        Write-WHDLog 'would: stop the IP block list following the firewall until it is applied again (menu 9)' 'DRY'
    }
}

# =============================================================================
#  6b) THE IP BLOCK LIST FOLLOWS THE FIREWALL  (user decision 2026-10-02)
# -----------------------------------------------------------------------------
#  Windows Firewall order (Microsoft Learn): a block rule beats an allow rule, and
#  the default action only applies when no rule matches. So a block list only does
#  work where something is WIDE OPEN:
#    outbound - the default outbound action is Allow, or an enabled outbound allow
#               rule is open to ANY address (the two any-program web rules, a
#               per-program allow, Windows' own rules after a reset);
#    inbound  - the default inbound action is Allow, or an enabled inbound allow
#               rule exists beyond the DHCP reply.
#  WHD puts the block rules in for exactly those directions and takes them out
#  again when nothing is wide open. Not counted as wide open: the update gate's
#  own rules (Microsoft Defender + DNS-over-HTTPS) and the DHCP request.
#  Clearing the list by hand (menu C) stops the following until the list is
#  applied again (menu 9). The setting is kept per PC in
#  restore\update-guard\blocklist.json. List file: profiles\blacklist-ip.txt
#  (or the file chosen at menu 9).
# =============================================================================
$script:WHDBlocklistStateName = 'blocklist.json'
$script:WHDBlocklistHold      = 0       # > 0: a bigger operation is running; it re-checks once at its end
$script:WHDBlocklistScanCap   = 25      # stop counting wide-open rules here (enough to know)

function Get-WHDBlocklistDefaultFile { Join-Path $script:WHDRoot 'profiles\blacklist-ip.txt' }
function _WHDBlocklistStateFile { Join-Path $script:WHDRoot ('restore\update-guard\' + $script:WHDBlocklistStateName) }
function Get-WHDBlocklistState {
    $whdBlF = _WHDBlocklistStateFile
    $s = $null
    if (Test-Path -LiteralPath $whdBlF) { try { $s = Get-Content -LiteralPath $whdBlF -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $s = $null } }
    if ($s -and "$($s.MachineId)" -and "$($s.MachineId)".ToLower() -ne (Get-WHDMachineId)) { $s = $null }   # another PC's file
    $follow = $true; $list = ''; $chg = ''
    if ($s) {
        if ($null -ne $s.Follow) { $follow = [bool]$s.Follow }
        $list = "$($s.ListFile)"; $chg = "$($s.Changed)"
    }
    [pscustomobject]@{ Follow = $follow; ListFile = $list; Changed = $chg }
}
# Returns $true when the setting was saved.
function Set-WHDBlocklistState {
    param([bool]$Follow, [string]$ListFile = '')
    $whdBlF = _WHDBlocklistStateFile
    try {
        $whdBlD = Split-Path -Parent $whdBlF
        if (-not (Test-Path -LiteralPath $whdBlD)) { New-Item -ItemType Directory -Path $whdBlD -Force -EA Stop | Out-Null }
        $o = [ordered]@{ MachineId = (Get-WHDMachineId); Computer = $env:COMPUTERNAME; Follow = $Follow; ListFile = $ListFile
                         Changed = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
        ([pscustomobject]$o | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath $whdBlF -Encoding UTF8 -EA Stop
        return $true
    } catch {
        Write-WHDLog ("could not save the IP block list setting ({0}): {1}" -f $whdBlF, $_.Exception.Message) 'WARN'
        return $false
    }
}
function Get-WHDBlocklistFile {
    $st = Get-WHDBlocklistState
    if ($st.ListFile) { return $st.ListFile }
    Get-WHDBlocklistDefaultFile
}

# Read-only: is the block list needed, for which direction(s), and is it in?
#   Needed / Want (directions) / Have (directions in now) / InStep / Why / Follow /
#   ListFile / ListPresent / Rules / Text (one status line) / Hint / Level (OK|WARN|INFO)
function Get-WHDBlocklistNeed {
    param([string]$Path, [switch]$AssumeFollow)
    $st = Get-WHDBlocklistState
    $whdBlList = if ($Path) { $Path } elseif ($st.ListFile) { $st.ListFile } else { Get-WHDBlocklistDefaultFile }
    $follow = ([bool]$st.Follow -or [bool]$AssumeFollow)
    $profs = @(Get-WHDFwProfiles)
    $outWhy = ''; $inWhy = ''
    # ---- outbound: default Allow, or an enabled allow rule open to any address
    if (-not $profs.Count -or @($profs | Where-Object { "$($_.DefaultOutboundAction)" -ne 'Block' }).Count) {
        $outWhy = 'outbound default is Allow'
    } else {
        $wide = 0; $capped = $false
        foreach ($r in @(Get-NetFirewallRule -Direction Outbound -Action Allow -Enabled True -EA SilentlyContinue)) {
            if ("$($r.Name)" -like 'WHDN-Gate-*' -or "$($r.Name)" -eq 'WHDN-Allow-DHCP-Out') { continue }
            $af = $r | Get-NetFirewallAddressFilter -EA SilentlyContinue
            $ra = @(@($af.RemoteAddress) | Where-Object { $null -ne $_ } | ForEach-Object { "$_" })
            if (-not $ra.Count -or ($ra -contains 'Any') -or ($ra -contains 'Internet')) {
                $wide++
                if ($wide -ge [int]$script:WHDBlocklistScanCap) { $capped = $true; break }
            }
        }
        if ($wide) { $outWhy = "{0}{1} wide-open outbound rule(s)" -f $wide, $(if ($capped) { ' or more' } else { '' }) }
    }
    # ---- inbound: default Allow, or an enabled allow rule beyond the DHCP reply
    if (@($profs | Where-Object { "$($_.DefaultInboundAction)" -eq 'Allow' }).Count) {
        $inWhy = 'inbound default is Allow'
    } else {
        $inN = @(Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True -EA SilentlyContinue | Where-Object { "$($_.Name)" -ne 'WHDN-Allow-DHCP-In' }).Count
        if ($inN) { $inWhy = "{0} inbound allow rule(s) beyond the DHCP reply" -f $inN }
    }
    $want = @(); if ($outWhy) { $want += 'Outbound' }; if ($inWhy) { $want += 'Inbound' }
    $rules = @(Get-NetFirewallRule -Group $script:WHDFwGroupBlock -EA SilentlyContinue)
    $have = @()
    foreach ($whdBlDir in @('Outbound','Inbound')) { if (@($rules | Where-Object { "$($_.Direction)" -eq $whdBlDir }).Count) { $have += $whdBlDir } }
    $inStep  = (($want -join ',') -eq ($have -join ','))
    $present = [bool](Test-Path -LiteralPath $whdBlList)
    $why     = (@($outWhy, $inWhy) | Where-Object { $_ }) -join ' + '
    $wantTxt = ($want -join ' + ').ToLower(); $haveTxt = ($have -join ' + ').ToLower()
    $fileTxt = if ($whdBlList -eq (Get-WHDBlocklistDefaultFile)) { 'profiles\blacklist-ip.txt' } else { $whdBlList }
    $text = ''; $hint = ''; $lvl = 'INFO'
    if (-not $follow) {
        if ($want.Count) { $text = "off (cleared by hand) - but needed: $why"; $lvl = 'WARN' }
        else             { $text = 'off (cleared by hand) - not needed now' }
        $hint = '9 switches it back on'
    } elseif ($want.Count -and $inStep) {
        $text = "needed: $why - applied ($haveTxt, $($rules.Count) rule(s))"; $lvl = 'OK'
    } elseif ($want.Count -and -not $present) {
        $text = "needed: $why - but no list file ($fileTxt)"; $lvl = 'WARN'
        $hint = 'copy your list there, then 9'
    } elseif ($want.Count -and $have.Count) {
        $text = "needed: $why - wanted $wantTxt, in now: $haveTxt"; $lvl = 'WARN'
        $hint = '9 brings it in line'
    } elseif ($want.Count) {
        $text = "needed: $why - NOT applied yet"; $lvl = 'WARN'
        $hint = '9 puts it in'
    } elseif ($have.Count) {
        $text = "not needed (nothing is wide open) - but $($rules.Count) block rule(s) are still in"; $lvl = 'WARN'
        $hint = '9 brings it in line'
    } else {
        $text = 'not needed, idle (nothing is wide open)'; $lvl = 'OK'
    }
    [pscustomobject]@{
        Follow = $follow; Needed = [bool]$want.Count; Want = @($want); Have = @($have); InStep = $inStep
        Why = $why; OutWhy = $outWhy; InWhy = $inWhy; ListFile = $whdBlList; ListPresent = $present
        Rules = $rules.Count; Text = $text; Hint = $hint; Level = $lvl
    }
}

# Run a block of work with the automatic re-check held back (the caller re-checks once at its end).
function Invoke-WHDBlocklistHold {
    param([Parameter(Mandatory)][scriptblock]$Do)
    $script:WHDBlocklistHold = [int]$script:WHDBlocklistHold + 1
    try { & $Do } finally { $script:WHDBlocklistHold = [int]$script:WHDBlocklistHold - 1 }
}

function Remove-WHDBlocklistDirection {
    param([Parameter(Mandatory)][ValidateSet('Inbound','Outbound')][string]$Direction, [string]$Why = 'nothing is wide open there')
    $whdBlNames = @(Get-NetFirewallRule -Group $script:WHDFwGroupBlock -EA SilentlyContinue | Where-Object { "$($_.Direction)" -eq $Direction } | ForEach-Object { "$($_.Name)" })
    if (-not $whdBlNames.Count) { return }
    Invoke-WHDChange -Description ("IP block list: remove {0} {1} block rule(s) ({2})" -f $whdBlNames.Count, $Direction.ToLower(), $Why) -Action {
        Backup-WHDFirewallOnce
        foreach ($whdBlN in $whdBlNames) { Remove-NetFirewallRule -Name $whdBlN -EA Stop }
    } | Out-Null
}

# Bring the block rules in line with what the firewall needs right now.
#   -AfterChange : called at the end of a firewall change (in DRY-RUN nothing changed, so only one line is shown)
#   -Rebuild     : re-create the wanted rules from the list file even when they are already in
#   -Apply       : the user applies by hand - act as "following" even if it was cleared before
#   -Path        : list file to use instead of the remembered one
function Sync-WHDBlocklist {
    param([switch]$AfterChange, [switch]$Rebuild, [switch]$Apply, [string]$Path)
    if ([int]$script:WHDBlocklistHold -gt 0) { return }
    if ($AfterChange -and -not $script:WHDExecute) {
        Write-WHDLog 'would: re-check the IP block list after this change (it follows the firewall: in where something is wide open, out where nothing is)' 'DRY'
        return
    }
    $need = if ($Path) { Get-WHDBlocklistNeed -Path $Path -AssumeFollow:$Apply } else { Get-WHDBlocklistNeed -AssumeFollow:$Apply }
    if (-not $need.Follow) {
        Write-WHDLog ("IP block list: {0}  ({1})" -f $need.Text, $need.Hint) $need.Level
        return
    }
    $whdBlWant = @($need.Want); $whdBlHave = @($need.Have); $whdBlWarned = $false
    $whdBlDrop = @($whdBlHave | Where-Object { $whdBlWant -notcontains $_ })
    $whdBlAdd  = @($whdBlWant | Where-Object { $whdBlHave -notcontains $_ })
    if ($Rebuild) { $whdBlAdd = $whdBlWant }
    if ($whdBlAdd.Count -and -not $need.ListPresent) {
        Write-WHDLog ("IP block list is needed ({0}) but the list file is missing: {1}" -f $need.Why, $need.ListFile) 'WARN'
        Write-WHDLog '  Copy your blacklist-ip.txt into the profiles folder, then firewall menu 9.' 'WARN'
        $whdBlAdd = @()                      # rules that are in stay in - they cannot be rebuilt without the file
        $whdBlWarned = $true
    } elseif ($Rebuild) { $whdBlDrop = $whdBlHave }
    if (-not $whdBlDrop.Count -and -not $whdBlAdd.Count) {
        if (-not $whdBlWarned) { Write-WHDLog ("IP block list: {0}" -f $need.Text) $need.Level }
        return
    }
    foreach ($whdBlD in $whdBlDrop) {
        $whdBlWhy = if ($whdBlWant -contains $whdBlD) { 'rebuild from the list file' } else { 'nothing is wide open ' + $whdBlD.ToLower() }
        Remove-WHDBlocklistDirection -Direction $whdBlD -Why $whdBlWhy
    }
    if ($whdBlAdd.Count) {
        Write-WHDLog ("IP block list is needed: {0}" -f $need.Why) 'INFO'
        Block-WHDIPList -Path $need.ListFile -Directions $whdBlAdd
    }
    if ($script:WHDExecute) {
        $now = Get-WHDBlocklistNeed -Path $need.ListFile -AssumeFollow:$Apply
        Write-WHDLog ("IP block list: {0}" -f $now.Text) $now.Level
    }
}

# Menu 9 / window button: apply by hand = follow the firewall again + rebuild from the list file.
function Invoke-WHDBlocklistApply {
    param([string]$Path)
    if (-not $Path) { $Path = Get-WHDBlocklistFile }
    Write-WHDLog 'IP BLOCK LIST: apply (it follows the firewall: in where something is wide open, out where nothing is)' 'ACT'
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-WHDLog ("IP list not found: {0}" -f $Path) 'ERR'
        Write-WHDLog '  Copy your blacklist-ip.txt into the profiles folder (or put list files into profiles\incoming and use F), then try again.' 'INFO'
        return
    }
    $whdBlStore = ''
    try {
        $whdBlFull = [System.IO.Path]::GetFullPath($Path)
        if ($whdBlFull -ne [System.IO.Path]::GetFullPath((Get-WHDBlocklistDefaultFile))) { $whdBlStore = $whdBlFull }
    } catch { $whdBlStore = $Path }
    $whdBlWas = Get-WHDBlocklistState
    if ($script:WHDExecute) { Set-WHDBlocklistState -Follow $true -ListFile $whdBlStore | Out-Null }
    elseif (-not $whdBlWas.Follow) { Write-WHDLog 'would: let the IP block list follow the firewall again' 'DRY' }
    Sync-WHDBlocklist -Apply -Rebuild -Path $Path
    $whdBlNow = Get-WHDBlocklistNeed -Path $Path -AssumeFollow
    if (-not $whdBlNow.Needed) {
        Write-WHDLog '  Nothing is wide open right now, so no block rules are needed. WHD puts the list in by itself as soon as something is opened (any-program web rules, a program allow, outbound default Allow).' 'INFO'
    }
}

# =============================================================================
#  7) JSON FIREWALL PROFILE APPLIER  (drives everything above from one file)
# =============================================================================
function Invoke-WHDApplyFirewallProfile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { Write-WHDLog ("firewall profile not found: {0}" -f $Path) 'ERR'; return }
    $cfg = Get-Content $Path -Raw | ConvertFrom-Json
    Write-WHDLog ("Applying firewall profile: {0}" -f $cfg.name) 'ACT'

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
        if ($cfg.ipv6.blockLoopback) { Invoke-WHDDisableIPv6 -BlockLoopback } else { Invoke-WHDDisableIPv6 }
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
            if ($a.name -eq 'WHDN-Allow-NTP' -and -not $p['RemoteAddress']) {
                $ntp = Get-WHDNtpRemoteAddress
                if ($ntp) { $p['RemoteAddress'] = $ntp; $p['DisplayName'] = 'WHD Next Allow NTP (UDP 123, time.cloudflare.com)' }
            }
            New-WHDFwRule $p
        }
    }
    if ($cfg.allowList -and (Get-Command Test-WHDGateClosed -EA SilentlyContinue) -and (Test-WHDGateClosed)) {
        Invoke-WHDChange -Description ("update gate is {0}: keep WHDN-Allow-HTTPS / WHDN-Allow-HTTP switched off" -f "$((Get-WHDGateState).Mode)".ToUpper()) -Force -Action {
            foreach ($rn in @('WHDN-Allow-HTTPS','WHDN-Allow-HTTP')) { Set-NetFirewallRule -Name $rn -Enabled False -EA SilentlyContinue }
        } | Out-Null
    }
    # WHD Next (2026-10-02): the IP block list is no longer applied here in both directions -
    # it follows the firewall and is brought in line ONCE, at the end of this profile.
    $whdBlProfileFile = ''
    if ($cfg.blacklist) {
        $base = Split-Path -Parent $Path
        if ($cfg.blacklist.ipFile) {
            $f = Join-Path $base $cfg.blacklist.ipFile
            if (Test-Path $f) { $whdBlProfileFile = $f }      # not there: the re-check below says so if the list is needed
        }
        if ($cfg.blacklist.hostsFile) {
            $f = Join-Path $base $cfg.blacklist.hostsFile; if (Test-Path $f) { Block-WHDHostsList -Path $f }
        }
    }
    if ($cfg.defaultDenyOutbound -eq $true) {
        $mins = if ($cfg.rollbackMinutes) { [int]$cfg.rollbackMinutes } else { 10 }
        Invoke-WHDBlocklistHold { Enable-WHDDefaultDenyOutbound -RollbackMinutes $mins }
    }
    if ($whdBlProfileFile) { Invoke-WHDBlocklistApply -Path $whdBlProfileFile }   # a profile that names a list = apply (following on)
    else                   { Sync-WHDBlocklist -AfterChange }
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
#  names the program if that process is still running.
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
                if (-not [datetime]::TryParse(("{0} {1}" -f $h['date'], $h['time']), [ref]$t)) { continue }
                if ($t -lt $Since) { continue }
                $h['when'] = $t
                $rows.Add([pscustomobject]$h)
            }
            $sr.Close(); $fs.Close()
        } catch { Write-WHDLog ("could not read {0}: {1}" -f $f, $_.Exception.Message) 'WARN' }
    }
    $rows.ToArray()
}
# ---- remembered program names (WHD Next 2026-10-02, after the first real PROGRAMS test) ----
# The firewall log only records a process id. While that process runs WHD can name it; once it has
# closed, the id means nothing - and Windows may give the same id to ANOTHER program later (seen
# after a restart: one program's old lines were shown as svchost.exe). So:
#   1. a running process is used only if it started BEFORE the log line was written;
#   2. every name WHD resolves is remembered for this PC (id + start time + path + when it was last
#      seen running), so the lines of a program that has closed since keep their name.
# File: restore\update-guard\blocked-programs.json (dates as text, read the same by 5.1 and 7.6).
$script:WHDFwNamesName = 'blocked-programs.json'
$script:WHDFwNamesKeepDays = 7
$script:WHDFwNamesMax = 400
function _WHDFwNamesPath { Join-Path $script:WHDRoot ('restore\update-guard\' + $script:WHDFwNamesName) }
function Read-WHDFwNames {
    $whdNf = _WHDFwNamesPath
    $out = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $whdNf)) { return @() }
    try {
        $j = Get-Content -LiteralPath $whdNf -Raw -Encoding UTF8 | ConvertFrom-Json
        if ("$($j.MachineId)".ToLower() -ne (Get-WHDMachineId)) { return @() }      # another PC's file
        foreach ($n in @($j.Names)) {
            $st = [datetime]::MinValue; $se = [datetime]::MinValue
            if (-not [datetime]::TryParseExact("$($n.Start)", 'yyyy-MM-dd HH:mm:ss', $null, [System.Globalization.DateTimeStyles]::None, [ref]$st)) { continue }
            if (-not [datetime]::TryParseExact("$($n.Seen)",  'yyyy-MM-dd HH:mm:ss', $null, [System.Globalization.DateTimeStyles]::None, [ref]$se)) { continue }
            if (-not "$($n.Path)") { continue }
            $out.Add([pscustomobject]@{ Pid = "$($n.Pid)"; Start = $st; Seen = $se; Path = "$($n.Path)"; Exe = "$($n.Exe)" })
        }
    } catch { return @() }
    return @($out.ToArray())
}
function Save-WHDFwNames {
    param([object[]]$Names)
    try {
        $whdNf = _WHDFwNamesPath
        $whdNd = Split-Path -Parent $whdNf
        if (-not (Test-Path -LiteralPath $whdNd)) { New-Item -ItemType Directory -Path $whdNd -Force -EA Stop | Out-Null }
        $rows = @($Names | ForEach-Object { [ordered]@{ Pid = "$($_.Pid)"; Start = $_.Start.ToString('yyyy-MM-dd HH:mm:ss'); Seen = $_.Seen.ToString('yyyy-MM-dd HH:mm:ss'); Path = "$($_.Path)"; Exe = "$($_.Exe)" } })
        $o = [ordered]@{ MachineId = (Get-WHDMachineId); Computer = $env:COMPUTERNAME; Names = $rows }
        ([pscustomobject]$o | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $whdNf -Encoding UTF8 -EA Stop
    } catch { }      # best effort: the view works without the memory
}
# Rule name of a per-program allow (one place, used by the allow and by the view).
function Get-WHDProgramAllowName {
    param([string]$Program, [string]$Protocol, [string]$RemotePort)
    $exe = if ($Program) { Split-Path $Program -Leaf } else { '' }
    $safe = ($exe -replace '[^A-Za-z0-9._-]', '_')
    "WHDN-App-{0}-{1}-{2}" -f $safe, $Protocol, $RemotePort
}

# What the WHD allow-list lets out for ANY program right now (enabled outbound rules of that group):
# protocol, remote ports, remote addresses. Used to mark old blocked lines that would pass today
# (example from the PC test: a program's DNS lines from the minutes when the firewall had no rules).
function Get-WHDAllowListCover {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in @(Get-NetFirewallRule -Group $script:WHDFwGroupAllow -EA SilentlyContinue | Where-Object { "$($_.Direction)" -eq 'Outbound' -and "$($_.Action)" -eq 'Allow' -and "$($_.Enabled)" -eq 'True' })) {
        $pf = $r | Get-NetFirewallPortFilter -EA SilentlyContinue
        $af = $r | Get-NetFirewallAddressFilter -EA SilentlyContinue
        if (-not $pf) { continue }
        if ("$($pf.LocalPort)" -and "$($pf.LocalPort)" -ne 'Any') { continue }                 # tied to a local port (DHCP): not a general allow
        $out.Add([pscustomobject]@{ Protocol = "$($pf.Protocol)"
            Ports = @(@($pf.RemotePort) | Where-Object { $null -ne $_ } | ForEach-Object { "$_" })
            Addrs = @(@($af.RemoteAddress) | Where-Object { $null -ne $_ } | ForEach-Object { "$_" }) })
    }
    return @($out.ToArray())
}
function Test-WHDAllowListCovers {
    param([object[]]$Cover, [string]$Protocol, [string]$Port, [string[]]$IPs)
    if (-not @($IPs).Count) { return $false }
    foreach ($c in @($Cover)) {
        if ($c.Protocol -ne 'Any' -and $c.Protocol -ne $Protocol) { continue }
        if (@($c.Ports).Count -and ($c.Ports -notcontains 'Any') -and ($c.Ports -notcontains $Port)) { continue }
        if (-not @($c.Addrs).Count -or ($c.Addrs -contains 'Any')) { return $true }
        $ranges = @($c.Addrs | ForEach-Object { ,(ConvertTo-WHDIpRange $_) } | Where-Object { $_ })
        $all = $true
        foreach ($ip in @($IPs)) {
            $a = ConvertTo-WHDIpRange $ip
            if (-not $a -or -not @($ranges | Where-Object { $a[0] -ge $_[0] -and $a[0] -le $_[1] }).Count) { $all = $false; break }
        }
        if ($all) { return $true }
    }
    return $false
}

# Blocked (DROP) connections, grouped by direction + program + protocol + port.
# Each row gets a State: can (can be allowed from here) | allowed | allowed-off (allow exists, gate CLOSED) |
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
        elseif ($pidv) {
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
        $keep = New-Object System.Collections.Generic.List[object]
        $done = @{}
        foreach ($k in @($seenNow.Keys)) {
            $lp = $seenNow[$k]
            if (-not $lp.Path -or -not $lp.Start) { continue }
            $keep.Add([pscustomobject]@{ Pid = "$k"; Start = $lp.Start; Seen = $now; Path = $lp.Path; Exe = $lp.Exe })
            $done["$k|" + $lp.Start.ToString('yyyy-MM-dd HH:mm:ss')] = $true
        }
        foreach ($n in $names) {
            if ($done.ContainsKey($n.Pid + '|' + $n.Start.ToString('yyyy-MM-dd HH:mm:ss'))) { continue }
            if ($n.Seen -lt $now.AddDays(-1 * [int]$script:WHDFwNamesKeepDays)) { continue }
            $keep.Add($n)
        }
        Save-WHDFwNames -Names @($keep.ToArray() | Sort-Object Seen -Descending | Select-Object -First ([int]$script:WHDFwNamesMax))
    }
    # what can be done with each row
    $appRules = @{}
    foreach ($r in @(Get-NetFirewallRule -Group $script:WHDFwGroupApp -EA SilentlyContinue)) { $appRules["$($r.Name)".ToLower()] = "$($r.Enabled)" }
    $cover = @(); try { $cover = @(Get-WHDAllowListCover) } catch { $cover = @() }
    $order = @{ 'can' = 1; 'allowed-off' = 2; 'allowed' = 3; 'covered' = 3; 'windows' = 4; 'inbound' = 5; 'ended' = 6 }
    $progMax = @{}
    $out = foreach ($g in $groups.Values) {
        $show = @($g.IPs | Select-Object -First 3) -join ', '
        if ($g.IPs.Count -gt 3) { $show += (" (+{0} more)" -f ($g.IPs.Count - 3)) }
        $g.Addresses = $show
        $leaf = if ($g.Program) { Split-Path $g.Program -Leaf } else { '' }
        if     ($g.Direction -eq 'Inbound')                                { $g.State = 'inbound';  $g.StateText = 'no - inbound' }
        elseif (-not $g.Program -and $g.Closed)                             { $g.State = 'ended';    $g.StateText = 'no - program has closed (start it again, then Load)' }
        elseif (-not $g.Program -or $g.Program -eq 'System' -or $leaf -ieq 'svchost.exe' -or $g.Program -notmatch '^[A-Za-z]:\\') { $g.State = 'windows'; $g.StateText = 'no - Windows service / System' }
        elseif ($g.Protocol -notin @('TCP','UDP') -or -not $g.RemotePort -or $g.RemotePort -eq '-') { $g.State = 'windows'; $g.StateText = 'no - not TCP/UDP' }
        else {
            $rn = (Get-WHDProgramAllowName -Program $g.Program -Protocol $g.Protocol -RemotePort $g.RemotePort).ToLower()
            if     ($appRules.ContainsKey($rn) -and $appRules[$rn] -eq 'True') { $g.State = 'allowed';     $g.StateText = 'allowed already (older lines)' }
            elseif ($appRules.ContainsKey($rn))                                { $g.State = 'allowed-off'; $g.StateText = 'allow exists, switched off (gate CLOSED)' }
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
                         @{ e = { $_.Count }; Descending = $true })
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
        Write-Host ('  NOTHING TO DO ({0}) - older lines; this traffic gets out now:' -f $done.Count) -ForegroundColor Green
        foreach ($b in $done) {
            $whdWhy = switch ($b.State) { 'allowed-off' { 'allow exists - switched off while the gate is CLOSED' } 'covered' { 'the allow-list lets this out now' } default { 'allowed already' } }
            Write-Host ($fmt -f '', $b.Count, $b.Last.ToString('MM-dd HH:mm:ss'), $b.Protocol, $b.RemotePort, $b.Exe, $whdWhy) -ForegroundColor DarkGray
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

# Menu V: view, then allow one or several rows (e.g. 1,3 or 1-3).
function Invoke-WHDBlockedView {
    $h = (Read-Host '  Hours to look back [24]').Trim(); if (-not ($h -match '^\d+$')) { $h = 24 }
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
        Write-WHDLog ("not allowed from here: {0} is INBOUND - allowing it would open this PC to the network. Add an inbound rule by hand if you really need it." -f $Item.Exe) 'WARN'; return
    }
    $exe = if ($Item.Program) { Split-Path $Item.Program -Leaf } else { '' }
    if (-not $Item.Program -or $Item.Program -eq 'System' -or $exe -ieq 'svchost.exe' -or $Item.Program -notmatch '^[A-Za-z]:\\') {
        Write-WHDLog ("not allowed from here: '{0}' is Windows service traffic (svchost/System). A program rule would open every service - add a port rule for the specific need instead." -f $Item.Exe) 'WARN'; return
    }
    if ($Item.Protocol -notin @('TCP','UDP') -or -not $Item.RemotePort) {
        Write-WHDLog ("not allowed from here: only TCP/UDP with a port can be allowed ({0} {1})." -f $Item.Protocol, $Item.RemotePort) 'WARN'; return
    }
    if (-not (Test-Path -LiteralPath $Item.Program)) { Write-WHDLog ("note: program path not found on disk (moved or updated?): {0}" -f $Item.Program) 'WARN' }
    $name = Get-WHDProgramAllowName -Program $Item.Program -Protocol $Item.Protocol -RemotePort $Item.RemotePort
    Write-WHDLog ("ALLOW PROGRAM: {0}  ({1} port {2}, outbound)" -f $Item.Program, $Item.Protocol, $Item.RemotePort) 'ACT'
    Write-WHDRisk 'caution' ("allows only this program, only {0} to remote port {1}, any destination. Removable in the Undo center or with 'remove program allows'." -f $Item.Protocol, $Item.RemotePort)
    if (-not (Confirm-WHDProceed ("allow {0} out on {1} {2}" -f $exe, $Item.Protocol, $Item.RemotePort))) { Write-WHDLog 'skipped.' 'WARN'; return }
    # WHD Next (2026-10-02): with the update gate CLOSED per-program allows are switched off.
    # A new allow is stored switched off and remembered, so PROGRAMS / OPEN switches it on.
    $whdGateMode = 'open'
    if (Get-Command Get-WHDGateState -EA SilentlyContinue) { try { $whdGateMode = "$((Get-WHDGateState).Mode)" } catch { $whdGateMode = 'open' } }
    $whdAppOn = if ($whdGateMode -eq 'closed') { 'False' } else { 'True' }
    New-WHDFwRule -Params @{ Name = $name; DisplayName = ("WHD Next Allow {0} ({1} {2})" -f $exe, $Item.Protocol, $Item.RemotePort)
        Group = $script:WHDFwGroupApp; Direction = 'Outbound'; Action = 'Allow'; Enabled = $whdAppOn; Profile = 'Any'
        Program = $Item.Program; Protocol = $Item.Protocol; RemotePort = $Item.RemotePort } `
        -Journal @{ Kind = 'fwrule'; RuleName = $name }
    if ($whdGateMode -eq 'closed') {
        if ($script:WHDExecute -and (Get-Command Add-WHDGateRemembered -EA SilentlyContinue)) { Add-WHDGateRemembered -Names @($name) }
        Write-WHDLog 'The update gate is CLOSED: the allow is stored but switched OFF. It starts working when you switch the gate to PROGRAMS (Updates menu P) or OPEN (O).' 'WARN'
    } elseif ($script:WHDExecute -and $whdGateMode -eq 'programs' -and [int]$script:WHDBlocklistHold -le 0) {
        Write-WHDLog $script:WHDAllowLiveText 'OK'
    }
    Sync-WHDBlocklist -AfterChange
}
$script:WHDAllowLiveText = 'Live now: the update gate is on PROGRAMS, so the allow works from this moment. No other step is needed - the gate does not have to be set again.'

# Several rows at once: one question, then every row; the IP block list is re-checked once at the end.
function Add-WHDProgramAllows {
    param([object[]]$Items)
    $whdAllowList = @($Items | Where-Object { $_ })
    if (-not $whdAllowList.Count) { return }
    if ($whdAllowList.Count -eq 1) { Add-WHDProgramAllow -Item $whdAllowList[0]; return }
    Write-WHDLog ("ALLOW {0} PROGRAM LINE(S) (each: that program, that protocol + port, outbound, any destination):" -f $whdAllowList.Count) 'ACT'
    foreach ($whdAl in $whdAllowList) { Write-WHDLog ("  {0}  {1} {2}" -f $whdAl.Exe, $whdAl.Protocol, $whdAl.RemotePort) 'INFO' }
    if (-not (Confirm-WHDProceed ("allow the {0} line(s) listed above" -f $whdAllowList.Count))) { Write-WHDLog 'skipped.' 'WARN'; return }
    $whdAlPrev = $script:WHDConfirm; $script:WHDConfirm = { param($m) $true }
    try { Invoke-WHDBlocklistHold { foreach ($whdAl in $whdAllowList) { Add-WHDProgramAllow -Item $whdAl } } }
    finally { $script:WHDConfirm = $whdAlPrev }
    if ($script:WHDExecute -and (Get-Command Get-WHDGateState -EA SilentlyContinue)) {
        try { if ("$((Get-WHDGateState).Mode)" -eq 'programs') { Write-WHDLog $script:WHDAllowLiveText 'OK' } } catch { }
    }
    Sync-WHDBlocklist -AfterChange
}

function Remove-WHDProgramAllows {
    Write-WHDLog 'REMOVE all per-program allow rules (group WinHardenDebloatNext-AppAllow)' 'ACT'
    if (-not (Confirm-WHDProceed 'remove all per-program allow rules')) { Write-WHDLog 'skipped.' 'WARN'; return }
    Remove-WHDFwGroup -Group $script:WHDFwGroupApp | Out-Null
    Sync-WHDBlocklist -AfterChange
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
    $p = @{ Name = 'WHDN-Allow-NTP'; Group = $script:WHDFwGroupAllow; Direction = 'Outbound'; Action = 'Allow'
            Enabled = 'True'; Profile = 'Any'; Protocol = 'UDP'; RemotePort = 123 }
    if ($raddr) { $p['RemoteAddress'] = $raddr; $p['DisplayName'] = 'WHD Next Allow NTP (UDP 123, time.cloudflare.com)' }
    else        { $p['DisplayName'] = 'WHD Next Allow NTP (UDP 123)' }
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
    $rule = @(Get-NetFirewallRule -Name 'WHDN-Allow-NTP' -EA SilentlyContinue)
    if ($rule) {
        $af = $rule[0] | Get-NetFirewallAddressFilter -EA SilentlyContinue
        Write-WHDLog ("Firewall NTP allow  : UDP 123 -> {0}" -f (@($af.RemoteAddress) -join ', ')) 'INFO'
    } else {
        Write-WHDLog 'Firewall NTP allow  : (no WHDN-Allow-NTP rule - fine while outbound is default-allow)' 'INFO'
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
        '# WHD Next - IP blocklist (offline). Refreshed by Invoke-WHDBlocklistRefresh.',
        ('# {0} on {1} from: {2}' -f $Mode, (Get-Date -Format 'yyyy-MM-dd HH:mm'), (($files | ForEach-Object Name) -join ', ')),
        '# SAFETY-FILTERED: no broadcast/multicast/private/reserved/CGNAT/loopback ranges.',
        ('# {0} ranges / {1:N0} addresses. Applied as BLOCK rules where the firewall is wide open (WHD follows the firewall).' -f $final.Count, $addrs),
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
    # WHD Next (2026-10-02): rebuild = apply by hand; only the directions the firewall needs are created.
    Invoke-WHDBlocklistApply -Path (Get-WHDBlocklistDefaultFile)
}

# =============================================================================
#  MENU
# =============================================================================
# One aligned menu row: key gutter (cyan) + label. Single column = never wraps.
function Write-WHDMenuItem {
    param([string]$Key, [string]$Label, [string]$Hint = '')
    # WHD Next: one screen line (see Write-WHDParts) so the log file keeps the menu readable under PowerShell 7.
    $whdParts = @(@(('    {0,-2}  ' -f $Key), 'Cyan'), $Label)
    if ($Hint) { $whdParts += ,@(("  $Hint"), 'DarkGray') }
    Write-WHDParts $whdParts
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
    Write-Host '  Blacklist  (the IP block list follows the firewall - see "IP block list" above)' -ForegroundColor DarkGray
    Write-WHDMenuItem '9' 'Block IP list: apply / bring in line' '(profiles\blacklist-ip.txt)'
    Write-WHDMenuItem 'H' 'Hosts sinkhole' '(profiles\blacklist-hosts.txt)'
    Write-WHDMenuItem 'C' 'Clear blacklist' '(the IP list then stops following until 9)'
    Write-WHDMenuItem 'F' 'Refresh blocklist from files' '(profiles\incoming)'
    Write-Host '  Blocked connections' -ForegroundColor DarkGray
    Write-WHDMenuItem 'M' 'Turn ON the Windows Firewall log' '(default file, dropped + allowed, 32,767 KB)'
    Write-WHDMenuItem 'O' 'Turn OFF the Windows Firewall log'
    Write-WHDMenuItem 'V' 'View blocked connections / allow a program'
    Write-WHDMenuItem 'G' 'Remove all per-program allows'
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
    Write-WHDMenuItem 'Q' 'Quit WHD Next'
    Write-Host ''
}

function Invoke-WHDFirewallSubmenu {
    $pdir = Join-Path $script:WHDRoot 'profiles'
    while ($true) {
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
            '^9$'   { $def=Get-WHDBlocklistFile;                  $f=(Read-Host ("  IP/CIDR list file [{0}]" -f $def)).Trim(); if(-not $f){$f=$def}; Invoke-WHDBlocklistApply -Path $f }
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
            '^[Tt]$'{ Invoke-WHDSetTimeSync -Mode Cloudflare }
            '^[Nn]$'{ Invoke-WHDSetTimeSync -Mode Windows }
            '^[Ss]$'{ Show-WHDTimeStatus; Show-WHDConnectionLoggingState }
            '^[Zz]$'{ if (Get-Command Invoke-WHDTimeRegionSubmenu -EA SilentlyContinue) { Invoke-WHDTimeRegionSubmenu } else { Write-WHDLog 'TimeRegion.ps1 not loaded.' 'ERR' } }
            '^[Xx]$'{ $f=(Read-Host '  Export base path [blank = restore\<timestamp>\firewall-policy]').Trim(); if($f){ Export-WHDFirewallPolicy -Path $f } else { Export-WHDFirewallPolicy } }
            '^[Ii]$'{ $f=(Read-Host '  Import file (.json or .wfw), blank to cancel').Trim(); if($f){ $mode= if($f -match '\.wfw$'){'Wfw'}else{'Json'}; Import-WHDFirewallPolicy -Path $f -Mode $mode } }
            '^[Rr]$'{ Invoke-WHDFirewallReset }
            '^[Ww]$'{ $yn=(Read-Host '  Apply the WHD baseline right after wiping? [y/N]').Trim(); if($yn -match '^[Yy]'){ Invoke-WHDFirewallWipe -ApplyBaseline } else { Invoke-WHDFirewallWipe } }
            '^[Aa]$'{ $def=Join-Path $pdir 'firewall-baseline.json'; $f=(Read-Host ("  Firewall profile [{0}]" -f $def)).Trim(); if(-not $f){$f=$def}; Invoke-WHDApplyFirewallProfile -Path $f }
            '^[Bb]$'{ return }
            '^[Qq]$'{ $script:WHDQuit = $true; return }
            default { Write-Host '  invalid.' -ForegroundColor Yellow }
        }
    }
}

Write-WHDLog 'Firewall.ps1 loaded.' 'INFO'
