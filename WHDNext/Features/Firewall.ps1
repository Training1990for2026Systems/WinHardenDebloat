#requires -Version 7.6
<#
================================================================================
 WHD Next 3.0  -  Features/Firewall.ps1   (Windows Defender Firewall)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Same features as WHD Next 2.0 (D8), rewritten for PowerShell 7.6, built in
 three parts (D24):
   5.2a  IPv6 off / on, firewall summary + rule list, reset, wipe, export / import
   5.2b  allow-list, DNS pin, default-deny outbound (rollback task runs netsh, D27),
         IP block list + hosts sinkhole (lists copied once from WHD Next 2.0, D26),
         profile file profiles\firewall-baseline.json
   5.2c  firewall log + blocked-connection viewer + program allows, time sync (with the
         time-service trigger undo), offline block-list refresh, TS
 Takes over from WHD Next 2.0 (D4): the same rule groups (WinHardenDebloatNext-*)
 and rule names (WHDN-*). Every change goes through the engine; the whole
 firewall policy is exported to the session's restore\ folder before the first
 firewall change (firewall-before.wfw - the Undo center can restore it).
 NetSecurity / NetAdapter cmdlets ship with Windows 11 Home; no AppLocker,
 gpedit or secpol needed; works without internet.
 Menu keys (D25): X / S stay EXECUTE / safe mode; export = E, time status = TS.
================================================================================
#>

# Every rule WHD makes carries one of these groups (they list and remove as a set).
$script:WHDFwGroupIPv6 = 'WinHardenDebloatNext-IPv6'
$script:WHDFwGroupAllow = 'WinHardenDebloatNext-AllowList'
$script:WHDFwGroupBlock = 'WinHardenDebloatNext-Blacklist'
$script:WHDFwGroupBase = 'WinHardenDebloatNext-Baseline'
$script:WHDFwGroupApp = 'WinHardenDebloatNext-AppAllow'
$script:WHDFwGroups = @($script:WHDFwGroupIPv6, $script:WHDFwGroupAllow, $script:WHDFwGroupBlock, $script:WHDFwGroupBase, $script:WHDFwGroupApp)
$script:WHDFwRollbackTask = 'WHDN-DefaultDenyRollback'

# Routable IPv6 space. ::1 (loopback) and :: stay OUT, so software that talks to itself over ::1 keeps working.
$script:WHDIPv6Ranges = @('2000::/3', 'fc00::/7', 'fe80::/10', 'ff00::/8')

# DNS pin: Cloudflare's malware-filtering resolver over encrypted DoH (developers.cloudflare.com).
$script:WHDDnsServers = @('1.1.1.2', '1.0.0.2')
$script:WHDDohTemplate = 'https://security.cloudflare-dns.com/dns-query'

# Time sync (part 5.2c): Windows Time -> time.cloudflare.com, UDP 123 pinned to its published addresses.
$script:WHDNtpServer = 'time.cloudflare.com'
$script:WHDNtpIPs = @('162.159.200.1', '162.159.200.123')
$script:WHDW32TimeKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'

# ---- IP block list SAFETY GUARD ------------------------------------------------------
# A block list that contains multicast or a private / CGNAT range silently breaks DHCP / mDNS / LAN,
# because Windows applies BLOCK rules before ALLOW rules. These ranges are NEVER turned into block rules.
$script:WHDNeverBlock = @(
    '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16',
    '172.16.0.0/12', '192.0.0.0/24', '192.0.2.0/24', '192.88.99.0/24', '192.168.0.0/16',
    '198.18.0.0/15', '198.51.100.0/24', '203.0.113.0/24', '224.0.0.0/4', '240.0.0.0/4'
)
$script:WHDNeverBlockRanges = $null

function ConvertTo-WHDIpRange {
    # IPv4 address or CIDR -> @(start, end) as [uint64]; $null when it is not IPv4.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string]$Cidr)
    $ip = $Cidr; $len = 32
    if ($Cidr -match '/') { $parts = $Cidr -split '/', 2; $ip = $parts[0].Trim(); if (-not [int]::TryParse($parts[1], [ref]$len)) { return $null } }
    if ($len -lt 0 -or $len -gt 32) { return $null }
    $addr = $null
    if (-not [System.Net.IPAddress]::TryParse($ip, [ref]$addr)) { return $null }
    if ($addr.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $null }
    $b = $addr.GetAddressBytes(); [Array]::Reverse($b)
    $base = [uint64][BitConverter]::ToUInt32($b, 0)
    $size = [uint64]1 -shl (32 - $len)
    $start = $base - ($base % $size)
    return @($start, ($start + $size - 1))
}

function Test-WHDNeverBlock {
    # $true when the entry is not IPv4 or overlaps a never-block range.
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Cidr)
    if ($null -eq $script:WHDNeverBlockRanges) {
        $script:WHDNeverBlockRanges = @(foreach ($n in $script:WHDNeverBlock) { , (ConvertTo-WHDIpRange -Cidr $n) })
    }
    $rng = ConvertTo-WHDIpRange -Cidr $Cidr
    if (-not $rng) { return $true }
    foreach ($f in $script:WHDNeverBlockRanges) { if ($rng[0] -le $f[1] -and $rng[1] -ge $f[0]) { return $true } }
    return $false
}

# ---- firewall backup once per session, small helpers -----------------------------------
function Backup-WHDFirewallOnce {
    # The whole policy -> restore\<session>\firewall-before.wfw, before the first real firewall change.
    [CmdletBinding()]
    param()
    $st = $script:WHDState
    if ($st.FwBackupDone) { return }
    if (-not (Test-WHDRealChange)) { return }
    $folder = Get-WHDRestoreFolder
    try {
        if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop) }
        $out = Join-Path $folder 'firewall-before.wfw'
        $r = Invoke-WHDNative -Exe 'netsh.exe' -ArgList @('advfirewall', 'export', $out)
        if ($r.Code -eq 0) { Write-WHDLog -Message ('firewall policy backed up: {0}' -f $out) -Level 'OK' }
        else { Write-WHDLog -Message ('firewall export failed (netsh exit {0}): {1}' -f $r.Code, ($r.Out -join ' ')) -Level 'WARN' }
    } catch { Write-WHDLog -Message ('firewall export failed: {0}' -f $_.Exception.Message) -Level 'WARN' }
    $st.FwBackupDone = $true
}

function Get-WHDFwProfile {
    [CmdletBinding()]
    param()
    Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction
}

function Remove-WHDFwGroup {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Group)
    $fgName = $Group
    $rules = @(Get-NetFirewallRule -Group $Group -ErrorAction SilentlyContinue)
    if (-not $rules.Count) { Write-WHDLog -Message ('no rules in group {0}' -f $Group); return }
    if (-not $PSCmdlet.ShouldProcess($Group, 'remove firewall rules')) { return }
    Invoke-WHDChange -Description ('remove {0} firewall rule(s) in group {1}' -f $rules.Count, $Group) -Action {
        Backup-WHDFirewallOnce
        Get-NetFirewallRule -Group $fgName -ErrorAction Stop | Remove-NetFirewallRule -ErrorAction Stop
    } | Out-Null
}

function New-WHDFwRule {
    # Creates a rule (a same-named one is replaced), through the gate.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][hashtable]$Params, [hashtable]$Journal)
    $frName = [string]$Params['Name']; $frParams = $Params
    $frDesc = 'firewall rule: {0} [{1}/{2}]' -f $Params['DisplayName'], $Params['Direction'], $Params['Action']
    if (-not $PSCmdlet.ShouldProcess($frName, 'create firewall rule')) { return }
    Invoke-WHDChange -Description $frDesc -Journal $Journal -Action {
        Backup-WHDFirewallOnce
        $existing = @(Get-NetFirewallRule -Name $frName -ErrorAction SilentlyContinue)
        if ($existing.Count) { $existing | Remove-NetFirewallRule -ErrorAction SilentlyContinue }
        $p = $frParams.Clone(); $p['Confirm'] = $false; $p['ErrorAction'] = 'Stop'
        [void](New-NetFirewallRule @p)
    } | Out-Null
}

# ---- profiles\ folder + the owner's list files (D26: copied once from WHD Next 2.0) -------
$script:WHDHostsFile = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\drivers\etc\hosts' } else { '/etc/hosts' }
$script:WHDListNames = @('blacklist-ip.txt', 'blacklist-hosts.txt')
$script:WHDListChecked = $false

function Get-WHDProfileFolder {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path $script:WHDState.DataRoot 'profiles'      # your lists: the WHD folder, also when the update guard runs from its locked copy (P54)
}

function Find-WHDNext2Profile {
    # WHD Next 2.0's profiles\ folder: beside its history source (settings.json), beside this folder, or its unlocked copy.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $nh = (Get-WHDSetting)['NextHistory']
    $cands = @(
        $(if ($nh -and $nh['Source']) { Join-Path (Split-Path ([string]$nh['Source']) -Parent) 'profiles' }),
        (Join-Path (Join-Path (Split-Path $script:WHDState.Root -Parent) 'WHD-Next') 'profiles'),
        $(if ($env:ProgramData) { Join-Path $env:ProgramData 'WinHardenDebloatNext\app\profiles' })
    ) | Where-Object { $_ }
    $own = [IO.Path]::GetFullPath((Get-WHDProfileFolder))
    foreach ($c in $cands) {
        if (-not (Test-Path -LiteralPath $c)) { continue }
        if ([IO.Path]::GetFullPath($c) -eq $own) { continue }
        foreach ($n in $script:WHDListNames) { if (Test-Path -LiteralPath (Join-Path $c $n)) { return $c } }
    }
    return $null
}

function Invoke-WHDListTakeover {
    # D26: the first time a list file is needed, WHD Next 2.0's block lists are copied ONCE into this
    # program's profiles\ and checked (SHA-256). WHD Next 2.0's folder is only read. Never asked again;
    # a list you delete later is not copied back. Copying files into this program's own folder is not a
    # change to Windows, so it also happens in dry-run (as the history copy does).
    [CmdletBinding()]
    param()
    if ($script:WHDListChecked) { return }
    $script:WHDListChecked = $true
    $set = Get-WHDSetting
    if ($set['NextLists']) { return }
    $dest = Get-WHDProfileFolder
    $missing = @($script:WHDListNames | Where-Object { -not (Test-Path -LiteralPath (Join-Path $dest $_)) })
    if (-not $missing.Count) { return }
    $src = Find-WHDNext2Profile
    if (-not $src) { return }
    $copied = [System.Collections.Generic.List[string]]::new()
    try {
        if (-not (Test-Path -LiteralPath $dest)) { [void](New-Item -ItemType Directory -Path $dest -Force -ErrorAction Stop) }
        foreach ($n in $missing) {
            $from = Join-Path $src $n
            if (-not (Test-Path -LiteralPath $from)) { continue }
            $to = Join-Path $dest $n
            Copy-Item -LiteralPath $from -Destination $to -ErrorAction Stop
            if ((Get-FileHash -LiteralPath $from -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $to -Algorithm SHA256).Hash) {
                Remove-Item -LiteralPath $to -Force -ErrorAction SilentlyContinue
                throw ('{0} differs after copying' -f $n)
            }
            $copied.Add($n)
        }
    } catch {
        Write-WHDLog -Message ('WHD Next 2.0 list files NOT copied ({0}). They will be tried again next start.' -f $_.Exception.Message) -Level 'WARN'
        return
    }
    if (-not $copied.Count) { return }
    $set['NextLists'] = @{ Source = $src; Copied = @($copied); Decided = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
    try { Save-WHDSetting -Setting $set } catch { Write-WHDLog -Message ('settings.json not written: {0}' -f $_.Exception.Message) -Level 'WARN' }
    Write-WHDLog -Message ('WHD Next 2.0 list file(s) copied once into {0}: {1} (checked).' -f $dest, ($copied -join ', ')) -Level 'OK'
}

# =====================================================================================
#  1) IPv6 SUPPRESSION  (adapter unbind + registry + firewall block rules)
# =====================================================================================
function Invoke-WHDDisableIPv6 {
    [CmdletBinding()]
    param([switch]$BlockLoopback)
    Write-WHDLog -Message 'IPv6 suppression (adapter binding + registry + firewall block rules)' -Level 'ACT'
    Write-WHDRisk -Tier 'caution' -Text 'Disables IPv6 on network adapters and blocks routable IPv6. Reversible.'
    if ($BlockLoopback) { Write-WHDRisk -Tier 'hard' -Text 'ALSO blocking ::1 loopback - may break local apps that use IPv6 to talk to themselves.' }
    if (-not (Confirm-WHDProceed -What $(if ($BlockLoopback) { 'suppress IPv6 and block ::1' } else { 'suppress IPv6 (keep ::1)' }))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    $bind = @(Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue | Where-Object Enabled)
    if ($bind.Count) {
        Invoke-WHDChange -Description ('unbind IPv6 (ms_tcpip6) from {0} adapter(s)' -f $bind.Count) -Action {
            Backup-WHDFirewallOnce
            Disable-NetAdapterBinding -Name '*' -ComponentID ms_tcpip6 -ErrorAction Stop
        } | Out-Null
    } else { Write-WHDLog -Message 'IPv6 already unbound from all adapters.' }
    # 0xFF disables every IPv6 interface except loopback and prefers IPv4.
    Set-WHDRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' -Name 'DisabledComponents' -Value 0xFF -Type 'DWord' | Out-Null
    foreach ($dir in 'Inbound', 'Outbound') {
        New-WHDFwRule -Params @{ Name = "WHDN-IPv6-$dir"; DisplayName = "WHD Next Block IPv6 ($dir)"; Group = $script:WHDFwGroupIPv6; Direction = $dir; Action = 'Block'; Enabled = 'True'; Profile = 'Any'; RemoteAddress = $script:WHDIPv6Ranges }
        New-WHDFwRule -Params @{ Name = "WHDN-ICMPv6-$dir"; DisplayName = "WHD Next Block ICMPv6 ($dir)"; Group = $script:WHDFwGroupIPv6; Direction = $dir; Action = 'Block'; Enabled = 'True'; Profile = 'Any'; Protocol = 'ICMPv6' }
        if ($BlockLoopback) { New-WHDFwRule -Params @{ Name = "WHDN-IPv6-Loopback-$dir"; DisplayName = "WHD Next Block IPv6 loopback ::1 ($dir)"; Group = $script:WHDFwGroupIPv6; Direction = $dir; Action = 'Block'; Enabled = 'True'; Profile = 'Any'; RemoteAddress = '::1' } }
    }
    Write-WHDLog -Message 'IPv6 suppression planned / applied.' -Level 'OK'
}

function Invoke-WHDEnableIPv6 {
    [CmdletBinding()]
    param()
    Write-WHDLog -Message 'Re-enabling IPv6 (undo suppression).' -Level 'ACT'
    if (-not (Confirm-WHDProceed -What 're-enable IPv6')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    $bind = @(Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue | Where-Object { -not $_.Enabled })
    if ($bind.Count) {
        Invoke-WHDChange -Description ('re-bind IPv6 to {0} adapter(s)' -f $bind.Count) -Action { Enable-NetAdapterBinding -Name '*' -ComponentID ms_tcpip6 -ErrorAction Stop } | Out-Null
    }
    Set-WHDRegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' -Name 'DisabledComponents' -Value 0 -Type 'DWord' | Out-Null
    Remove-WHDFwGroup -Group $script:WHDFwGroupIPv6
    Write-WHDLog -Message 'IPv6 re-enabled.' -Level 'OK'
}

# =====================================================================================
#  2) SUMMARY + RULE LISTING  (read-only)
# =====================================================================================
function Show-WHDFirewallSummary {
    # Every part is read-only; a part that cannot be read is reported and the rest is still shown.
    [CmdletBinding()]
    param()
    foreach ($part in 'Show-WHDFwProfileSummary', 'Show-WHDFwDnsSummary', 'Show-WHDFwTimeSummary') {
        try { & $part } catch { Write-Host ('   ({0} could not be read: {1})' -f ($part -replace '^Show-WHDFw|Summary$', ''), $_.Exception.Message) -ForegroundColor DarkGray }
    }
}

function Show-WHDFwProfileSummary {
    [CmdletBinding()]
    param()
    Write-Host ''
    Write-Host '  --- Firewall profiles ---' -ForegroundColor White
    foreach ($p in Get-WHDFwProfile) {
        Write-Host ('   {0,-8} on={1,-5} in={2,-6} out={3}' -f $p.Name, $p.Enabled, $p.DefaultInboundAction, $p.DefaultOutboundAction) -ForegroundColor $(if ($p.Enabled) { 'Green' } else { 'Red' })
    }
    $all = @(Get-NetFirewallRule -ErrorAction SilentlyContinue)
    Write-Host ''
    Write-Host ('  Rules: {0} total, {1} enabled' -f $all.Count, @($all | Where-Object Enabled -eq 'True').Count) -ForegroundColor White
    Write-Host ('   inbound  {0,4}   |  allow {1,4}' -f @($all | Where-Object Direction -eq 'Inbound').Count, @($all | Where-Object Action -eq 'Allow').Count)
    Write-Host ('   outbound {0,4}   |  block {1,4}' -f @($all | Where-Object Direction -eq 'Outbound').Count, @($all | Where-Object Action -eq 'Block').Count)
    foreach ($g in $script:WHDFwGroups) {
        $c = @(Get-NetFirewallRule -Group $g -ErrorAction SilentlyContinue).Count
        if ($c) { Write-Host ('   {0,-34} {1} rule(s)' -f $g, $c) -ForegroundColor Cyan }
    }
    if (Get-Command -Name Get-WHDBlocklistNeed -ErrorAction SilentlyContinue) {
        try { $bl = Get-WHDBlocklistNeed; Write-Host ('   IP block list : {0}{1}' -f $bl.Text, $(if ($bl.Hint) { '  ({0})' -f $bl.Hint } else { '' })) -ForegroundColor $(switch ([string]$bl.Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } default { 'DarkGray' } }) } catch { Write-Verbose 'block list state unreadable' }
    }
}

function Show-WHDFwDnsSummary {
    [CmdletBinding()]
    param()
    $dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { @($_.ServerAddresses).Count -gt 0 })
    if ($dns.Count) {
        Write-Host ''
        Write-Host '  --- DNS servers (per adapter, IPv4) ---' -ForegroundColor White
        foreach ($d in $dns) {
            $srv = @($d.ServerAddresses) -join ', '
            Write-Host ('   {0,-24} {1}' -f $d.InterfaceAlias, $srv) -ForegroundColor $(if ($srv -match '(^|[ ,])1\.(1\.1|0\.0)\.') { 'Green' } else { 'Yellow' })
        }
        $doh = @(Get-DnsClientDohServerAddress -ErrorAction SilentlyContinue | Where-Object { $script:WHDDnsServers -contains [string]$_.ServerAddress })
        if ($doh.Count) { Write-Host ('   DoH encrypted           {0}' -f (@($doh | ForEach-Object { [string]$_.ServerAddress }) -join ', ')) -ForegroundColor Green }
        else { Write-Host '   DoH encrypted           (not configured)' -ForegroundColor DarkGray }
        Write-Host '   (green = pinned Cloudflare resolver in use)' -ForegroundColor DarkGray
    }
}

function Show-WHDFwTimeSummary {
    [CmdletBinding()]
    param()
    Write-Host ''
    Write-Host '  --- Time sync (NTP) ---' -ForegroundColor White
    $ntpSet = Get-WHDRegValueState -Path $script:WHDW32TimeKey -Name 'NtpServer'
    $ntpTxt = if ($ntpSet.Exists) { [string]$ntpSet.Value } else { '(not set)' }
    Write-Host ('   {0,-24} {1}' -f 'Time server', $ntpTxt) -ForegroundColor $(if ($ntpTxt -match [regex]::Escape($script:WHDNtpServer)) { 'Green' } else { 'Yellow' })
    $svc = Get-Service -Name w32time -ErrorAction SilentlyContinue
    if ($svc) {
        $tts = Get-WHDTimeTriggerState
        $trTxt = if ($tts.Active) { '{0} Windows start trigger(s)' -f $tts.Active } elseif ($tts.Saved) { 'start triggers back after a restart' } else { 'no start triggers' }
        Write-Host ('   {0,-24} {1}, {2}, {3}' -f 'Windows Time service', $svc.Status, $svc.StartType, $trTxt) -ForegroundColor $(if ([string]$svc.Status -eq 'Running') { 'Green' } else { 'Yellow' })
    }
    $ntpRule = @(Get-NetFirewallRule -Name 'WHDN-Allow-NTP' -ErrorAction SilentlyContinue)
    if ($ntpRule.Count) {
        $ra = @(($ntpRule[0] | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue).RemoteAddress) -join ', '
        Write-Host ('   {0,-24} UDP 123 -> {1}' -f 'Firewall NTP allow', $ra) -ForegroundColor $(if ($ra -eq ($script:WHDNtpIPs -join ', ')) { 'Green' } else { 'Yellow' })
    }
    try { $tj = Get-WHDTimeJumpState; Write-Host ('   {0,-24} {1}' -f 'Time-jump limit', $tj.Text) -ForegroundColor $(if ($tj.Limited) { 'Green' } else { 'Yellow' }) } catch { Write-Verbose 'time-jump limit unreadable' }
}

function Get-WHDFirewallRule {
    # Clean rule objects. -Detail adds port / address / program (slower).
    [CmdletBinding()]
    param(
        [ValidateSet('Any', 'Inbound', 'Outbound')][string]$Direction = 'Any',
        [ValidateSet('Any', 'Allow', 'Block')][string]$Action = 'Any',
        [switch]$EnabledOnly,
        [switch]$CustomOnly,   # hide Store-app and built-in rules
        [switch]$Detail
    )
    $rules = @(Get-NetFirewallRule -ErrorAction SilentlyContinue)
    if ($Direction -ne 'Any') { $rules = @($rules | Where-Object { [string]$_.Direction -eq $Direction }) }
    if ($Action -ne 'Any') { $rules = @($rules | Where-Object { [string]$_.Action -eq $Action }) }
    if ($EnabledOnly) { $rules = @($rules | Where-Object { [string]$_.Enabled -eq 'True' }) }
    # custom = not owned by a Store app (Owner empty) and not a built-in (DisplayGroup is an '@' resource string)
    if ($CustomOnly) { $rules = @($rules | Where-Object { [string]::IsNullOrEmpty($_.Owner) -and ([string]$_.DisplayGroup -notlike '@*') }) }
    foreach ($r in $rules) {
        $o = [ordered]@{ Name = $r.Name; DisplayName = $r.DisplayName; Group = $r.DisplayGroup; Dir = $r.Direction; Action = $r.Action; Enabled = $r.Enabled; Profile = $r.Profile }
        if ($Detail) {
            $pf = $r | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            $af = $r | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
            $ap = $r | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
            $o['Protocol'] = $pf.Protocol; $o['LocalPort'] = @($pf.LocalPort) -join ','; $o['RemotePort'] = @($pf.RemotePort) -join ','
            $o['RemoteIP'] = @($af.RemoteAddress) -join ','; $o['Program'] = $ap.Program
        }
        [pscustomobject]$o
    }
}

# =====================================================================================
#  3) RESET + WIPE
# =====================================================================================
function Invoke-WHDFirewallReset {
    [CmdletBinding()]
    param([switch]$ApplyBaseline)
    Write-WHDLog -Message 'Reset firewall to Windows defaults (clean slate).' -Level 'ACT'
    Write-WHDRisk -Tier 'hard' -Text 'netsh advfirewall reset - removes ALL custom rules; a .wfw backup is taken first.'
    if (-not (Confirm-WHDProceed -What 'reset the firewall to Windows defaults')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    Invoke-WHDChange -Description 'netsh advfirewall reset (restore default policy)' -Action {
        Backup-WHDFirewallOnce
        $nr = Invoke-WHDNative -Exe 'netsh.exe' -ArgList @('advfirewall', 'reset')
        if ($nr.Code -ne 0) { throw ('netsh exit {0}: {1}' -f $nr.Code, ($nr.Out -join ' ')) }
    } | Out-Null
    Invoke-WHDChange -Description 'enable firewall on all profiles; inbound Block / outbound Allow' -Action {
        Set-NetFirewallProfile -All -Enabled True -DefaultInboundAction Block -DefaultOutboundAction Allow -Confirm:$false -ErrorAction Stop
    } | Out-Null
    if ($ApplyBaseline) {
        Invoke-WHDBlocklistHold -Do { Invoke-WHDFirewallAllowList; Invoke-WHDDisableIPv6 }
    }
    Write-WHDLog -Message 'Firewall reset complete.' -Level 'OK'
    Sync-WHDBlocklist -AfterChange
}

function Invoke-WHDFirewallWipe {
    # Empty slate: every rule deleted (Microsoft defaults too). Firewall stays ON, default actions unchanged.
    [CmdletBinding()]
    param([switch]$ApplyBaseline)
    $all = @(Get-NetFirewallRule -ErrorAction SilentlyContinue)
    Write-WHDLog -Message ('WIPE ALL firewall rules (empty slate) - {0} rule(s) present.' -f $all.Count) -Level 'ACT'
    Write-WHDRisk -Tier 'hard' -Text 'Deletes EVERY inbound/outbound rule, Windows defaults included. The firewall stays ON and its default actions (inbound / outbound) are not changed. A .wfw backup is taken first; protected rules are skipped.'
    if (-not (Confirm-WHDProceed -What ('delete ALL {0} firewall rule(s)' -f $all.Count))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    $res = Invoke-WHDChange -Description ('delete ALL {0} firewall rule(s) - empty slate' -f $all.Count) -Action {
        Backup-WHDFirewallOnce
        $wipeRules = @(Get-NetFirewallRule -ErrorAction SilentlyContinue)
        $wipeN = 0; $wipeKept = 0
        if ($wipeRules.Count -gt 50) { Write-WHDLog -Message ('  deleting {0} rule(s) one by one - this takes a few minutes; progress is shown' -f $wipeRules.Count) }
        foreach ($wr in $wipeRules) {
            $wipeN++
            try { Remove-NetFirewallRule -Name $wr.Name -ErrorAction Stop } catch { $wipeKept++ }
            Write-WHDProgressStep -Activity 'Deleting firewall rules' -Done $wipeN -Total $wipeRules.Count -Every 50
        }
        if ($wipeKept) { Write-WHDLog -Message ('  {0} rule(s) could not be deleted (protected) and were left in place' -f $wipeKept) }
    }
    $synced = $false
    if ($ApplyBaseline) {
        $bp = Join-Path (Get-WHDProfileFolder) 'firewall-baseline.json'
        if (Test-Path -LiteralPath $bp) { Invoke-WHDApplyFirewallProfile -Path $bp; $synced = $true }
        else { Write-WHDLog -Message 'firewall-baseline.json not found; wipe only.' -Level 'WARN' }
    }
    switch ([string]$res.Status) {
        'done' { Write-WHDLog -Message 'Wipe complete. Only rules you add from here exist.' -Level 'OK' }
        'planned' { Write-WHDLog -Message 'PREVIEW only (DRY-RUN): nothing was deleted. Switch EXECUTE on to wipe for real.' -Level 'DRY' }
        default { Write-WHDLog -Message 'Wipe NOT done - see the lines above.' -Level 'WARN' }
    }
    if (-not $synced) { Sync-WHDBlocklist -AfterChange }
}

# =====================================================================================
#  4) EXPORT / IMPORT  (json of WHD's own rules + the whole policy as .wfw)
# =====================================================================================
function Export-WHDFirewallPolicy {
    [CmdletBinding()]
    param([string]$Path)   # base path: writes <base>.wfw and <base>.json
    if (-not $Path) { $Path = Join-Path (Get-WHDRestoreFolder) 'firewall-policy' }
    $exWfw = '{0}.wfw' -f $Path; $exJson = '{0}.json' -f $Path; $exDir = Split-Path -Parent $Path
    Invoke-WHDChange -Description ('export full firewall policy -> {0}' -f $exWfw) -Action {
        if ($exDir -and -not (Test-Path -LiteralPath $exDir)) { [void](New-Item -ItemType Directory -Path $exDir -Force) }
        $nr = Invoke-WHDNative -Exe 'netsh.exe' -ArgList @('advfirewall', 'export', $exWfw)
        if ($nr.Code -ne 0) { throw ('netsh exit {0}: {1}' -f $nr.Code, ($nr.Out -join ' ')) }
    } | Out-Null
    $rules = foreach ($g in $script:WHDFwGroups) {
        foreach ($r in @(Get-NetFirewallRule -Group $g -ErrorAction SilentlyContinue)) {
            $pf = $r | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            $af = $r | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
            $ap = $r | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
            [ordered]@{ name = $r.Name; displayName = $r.DisplayName; group = $r.DisplayGroup; direction = [string]$r.Direction; action = [string]$r.Action; enabled = [string]$r.Enabled; profile = [string]$r.Profile
                        protocol = [string]$pf.Protocol; localPort = @($pf.LocalPort); remotePort = @($pf.RemotePort); remoteAddress = @($af.RemoteAddress); program = $ap.Program }
        }
    }
    $rules = @($rules)
    if (-not (Test-WHDRealChange)) { Write-WHDLog -Message ('would: write {0} ({1} WHD rule(s))' -f $exJson, $rules.Count) -Level 'DRY'; return }
    [ordered]@{ generated = (Get-Date -Format 's'); host = [Environment]::MachineName; rules = $rules } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $exJson -Encoding utf8
    Write-WHDLog -Message ('wrote {0} ({1} WHD rule(s))' -f $exJson, $rules.Count) -Level 'OK'
}

function ConvertTo-WHDFwRuleParam {
    # One rule of a WHD json export -> parameters for New-NetFirewallRule (pure).
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Rule)
    $p = @{ Name = $Rule['name']; DisplayName = $Rule['displayName']; Group = $Rule['group']; Direction = $Rule['direction']; Action = $Rule['action']; Enabled = $Rule['enabled']; Profile = $Rule['profile'] }
    if ($Rule['protocol']) { $p['Protocol'] = $Rule['protocol'] }
    foreach ($k in @(@('localPort', 'LocalPort'), @('remotePort', 'RemotePort'), @('remoteAddress', 'RemoteAddress'))) {
        $v = @($Rule[$k[0]] | Where-Object { $null -ne $_ -and [string]$_ -ne '' -and [string]$_ -ne 'Any' })
        if ($v.Count) { $p[$k[1]] = $v }
    }
    if ($Rule['program']) { $p['Program'] = $Rule['program'] }
    return $p
}

function Import-WHDFirewallPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [ValidateSet('Json', 'Wfw')][string]$Mode = 'Json')
    if (-not (Test-Path -LiteralPath $Path)) { Write-WHDLog -Message ('import file not found: {0}' -f $Path) -Level 'ERR'; return }
    $imPath = $Path
    if ($Mode -eq 'Wfw') {
        Write-WHDRisk -Tier 'hard' -Text 'Replaces the WHOLE firewall policy with the file. A .wfw backup is taken first.'
        if (-not (Confirm-WHDProceed -What ('import firewall policy {0}' -f $Path))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
        Invoke-WHDChange -Description ('import firewall policy blob: {0}' -f $Path) -Action {
            Backup-WHDFirewallOnce
            $nr = Invoke-WHDNative -Exe 'netsh.exe' -ArgList @('advfirewall', 'import', $imPath)
            if ($nr.Code -ne 0) { throw ('netsh exit {0}: {1}' -f $nr.Code, ($nr.Out -join ' ')) }
        } | Out-Null
        Sync-WHDBlocklist -AfterChange
        return
    }
    $doc = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $rules = @($doc['rules'])
    if (-not (Confirm-WHDProceed -What ('import {0} WHD rule(s) from {1}' -f $rules.Count, $Path))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    foreach ($r in $rules) { New-WHDFwRule -Params (ConvertTo-WHDFwRuleParam -Rule $r) }
    Write-WHDLog -Message ('imported {0} rule(s) from {1}' -f $rules.Count, $Path) -Level 'OK'
    Sync-WHDBlocklist -AfterChange
}

# =====================================================================================
#  5) ALLOW-LIST + DNS PIN + STAGED DEFAULT-DENY OUTBOUND
# =====================================================================================
function Get-WHDNtpRemoteAddress {
    # The Cloudflare time addresses when Windows Time points at time.cloudflare.com, otherwise $null (= any).
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $ntp = Get-WHDRegValueState -Path $script:WHDW32TimeKey -Name 'NtpServer'
    if ($ntp.Exists -and [string]$ntp.Value -match [regex]::Escape($script:WHDNtpServer)) { return $script:WHDNtpIPs }
    return $null
}

function Test-WHDGateClosedNow {
    # The update gate (Updates module, later in step 5) keeps the any-program web rules off. Until that module exists: open.
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not (Get-Command -Name Test-WHDGateClosed -ErrorAction SilentlyContinue)) { return $false }
    return [bool](Test-WHDGateClosed)
}

function Get-WHDAllowListRule {
    # The essential allow-list (pure): DNS pinned, DHCP both ways, NTP, HTTPS + HTTP open to any address.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string[]]$NtpAddress)
    $list = @(
        @{ Name = 'WHDN-Allow-DNS-UDP'; DisplayName = 'WHD Next Allow DNS (UDP 53)'; Direction = 'Outbound'; Protocol = 'UDP'; RemotePort = 53; RemoteAddress = $script:WHDDnsServers }
        @{ Name = 'WHDN-Allow-DNS-TCP'; DisplayName = 'WHD Next Allow DNS (TCP 53)'; Direction = 'Outbound'; Protocol = 'TCP'; RemotePort = 53; RemoteAddress = $script:WHDDnsServers }
        @{ Name = 'WHDN-Allow-DHCP-Out'; DisplayName = 'WHD Next Allow DHCP request (UDP out 68->67)'; Direction = 'Outbound'; Protocol = 'UDP'; LocalPort = 68; RemotePort = 67 }
        @{ Name = 'WHDN-Allow-DHCP-In'; DisplayName = 'WHD Next Allow DHCP reply (UDP in <-67)'; Direction = 'Inbound'; Protocol = 'UDP'; LocalPort = 68; RemotePort = 67 }
        @{ Name = 'WHDN-Allow-NTP'; DisplayName = 'WHD Next Allow NTP (UDP 123)'; Direction = 'Outbound'; Protocol = 'UDP'; RemotePort = 123 }
        @{ Name = 'WHDN-Allow-HTTPS'; DisplayName = 'WHD Next Allow HTTPS (TCP 443)'; Direction = 'Outbound'; Protocol = 'TCP'; RemotePort = 443 }
        @{ Name = 'WHDN-Allow-HTTP'; DisplayName = 'WHD Next Allow HTTP (TCP 80)'; Direction = 'Outbound'; Protocol = 'TCP'; RemotePort = 80 }
    )
    foreach ($r in $list) {
        $r['Group'] = $script:WHDFwGroupAllow; $r['Action'] = 'Allow'; $r['Enabled'] = 'True'; $r['Profile'] = 'Any'
        if ($r['Name'] -eq 'WHDN-Allow-NTP' -and $NtpAddress) { $r['RemoteAddress'] = @($NtpAddress); $r['DisplayName'] = 'WHD Next Allow NTP (UDP 123, time.cloudflare.com)' }
    }
    return $list
}

function Disable-WHDGateWebRule {
    # With the update gate closed the two any-program web rules stay switched off.
    [CmdletBinding()]
    param()
    Invoke-WHDChange -Description 'update gate is closed: keep WHDN-Allow-HTTPS / WHDN-Allow-HTTP switched off' -Action {
        foreach ($gwName in @('WHDN-Allow-HTTPS', 'WHDN-Allow-HTTP')) { Set-NetFirewallRule -Name $gwName -Enabled False -ErrorAction SilentlyContinue }
    } | Out-Null
}

function Invoke-WHDFirewallAllowList {
    # Harmless while outbound is Allow; it pre-stages the rules so default-deny later does not cut the PC off.
    [CmdletBinding()]
    param()
    Write-WHDLog -Message ('Applying the essential ALLOW-list (DNS pinned to {0}).' -f ($script:WHDDnsServers -join ', ')) -Level 'ACT'
    Remove-WHDFwGroup -Group $script:WHDFwGroupAllow          # rebuilt each time, so applying again is clean
    foreach ($r in Get-WHDAllowListRule -NtpAddress (Get-WHDNtpRemoteAddress)) { New-WHDFwRule -Params $r }
    if (Test-WHDGateClosedNow) {
        Disable-WHDGateWebRule
        Write-WHDLog -Message 'Allow-list applied (update gate closed: the any-program HTTP / HTTPS rules stay off).' -Level 'OK'
    } else {
        Write-WHDLog -Message 'Allow-list applied: DHCP in + out, DNS pinned, NTP, HTTP / HTTPS open. Applying again rebuilds this group.' -Level 'OK'
    }
    Sync-WHDBlocklist -AfterChange
}

function Invoke-WHDSetDns {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'DNS is not a plural; name kept from WHD Next 2.0.')]
    # Cloudflare: system DNS -> 1.1.1.2 / 1.0.0.2 plus encrypted DoH (domain blocking at the resolver).
    # Reset: DNS back to automatic (DHCP) and the DoH entries removed. -NoDoH = plain DNS only.
    [CmdletBinding()]
    param([ValidateSet('Cloudflare', 'Reset')][string]$Mode = 'Cloudflare', [switch]$NoDoH)
    $dnsUp = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { [string]$_.Status -eq 'Up' })
    if (-not $dnsUp.Count) { Write-WHDLog -Message 'no network adapter is up - DNS not changed.' -Level 'WARN'; return }
    $hasDoH = [bool](Get-Command -Name Add-DnsClientDohServerAddress -ErrorAction SilentlyContinue)
    $dnsList = $script:WHDDnsServers; $dohTpl = $script:WHDDohTemplate
    if ($Mode -eq 'Cloudflare') {
        Write-WHDLog -Message ('DNS -> Cloudflare {0} (malware filter){1}' -f ($dnsList -join ' / '), $(if ($hasDoH -and -not $NoDoH) { ' over encrypted DoH' } else { '' })) -Level 'ACT'
        if (-not $NoDoH -and $hasDoH) {
            foreach ($dohIp in $dnsList) {
                $dohOne = $dohIp
                Invoke-WHDChange -Description ('register encrypted DNS (DoH) for {0}' -f $dohOne) -Action {
                    if (Get-DnsClientDohServerAddress -ServerAddress $dohOne -ErrorAction SilentlyContinue) {
                        Set-DnsClientDohServerAddress -ServerAddress $dohOne -DohTemplate $dohTpl -AllowFallbackToUdp $false -AutoUpgrade $true -ErrorAction Stop | Out-Null
                    } else {
                        Add-DnsClientDohServerAddress -ServerAddress $dohOne -DohTemplate $dohTpl -AllowFallbackToUdp $false -AutoUpgrade $true -ErrorAction Stop | Out-Null
                    }
                } | Out-Null
            }
        } elseif (-not $NoDoH) { Write-WHDLog -Message 'The DoH commands are not on this Windows build - plain DNS only.' -Level 'WARN' }
        Invoke-WHDChange -Description ('set system DNS to {0} on {1} adapter(s) that are up' -f ($dnsList -join ','), $dnsUp.Count) -Action {
            foreach ($dnsA in $dnsUp) { Set-DnsClientServerAddress -InterfaceIndex $dnsA.ifIndex -ServerAddresses $dnsList -ErrorAction Stop }
        } | Out-Null
        Write-WHDLog -Message 'DNS pin planned / applied.' -Level 'OK'
        return
    }
    Write-WHDLog -Message 'DNS -> automatic (DHCP); DoH entries removed.' -Level 'ACT'
    Invoke-WHDChange -Description ('reset system DNS to automatic (DHCP) on {0} adapter(s) that are up' -f $dnsUp.Count) -Action {
        foreach ($dnsA in $dnsUp) { Set-DnsClientServerAddress -InterfaceIndex $dnsA.ifIndex -ResetServerAddresses -ErrorAction Stop }
    } | Out-Null
    if ($hasDoH) {
        foreach ($dohIp in $dnsList) {
            if (-not (Get-DnsClientDohServerAddress -ServerAddress $dohIp -ErrorAction SilentlyContinue)) { continue }
            $dohOne = $dohIp
            Invoke-WHDChange -Description ('remove the DoH entry for {0}' -f $dohOne) -Action { Remove-DnsClientDohServerAddress -ServerAddress $dohOne -Confirm:$false -ErrorAction Stop } | Out-Null
        }
    }
    Write-WHDLog -Message 'DNS reset planned / applied.' -Level 'OK'
}

# ---- default-deny rollback task (D27: Windows' own netsh, no script, no PowerShell) -------
function ConvertTo-WHDRollbackArgument {
    # One netsh argument line per firewall profile: outbound back to Allow, inbound kept as it is now (pure).
    [CmdletBinding()]
    [OutputType([object[]])]
    param([AllowEmptyCollection()][object[]]$Profiles)
    $map = @{ Domain = 'domainprofile'; Private = 'privateprofile'; Public = 'publicprofile' }
    $out = foreach ($p in @($Profiles)) {
        $pn = [string]$p.Name
        if (-not $map.ContainsKey($pn)) { continue }
        $inb = if ([string]$p.DefaultInboundAction -eq 'Allow') { 'allowinbound' } else { 'blockinbound' }
        'advfirewall set {0} firewallpolicy {1},allowoutbound' -f $map[$pn], $inb
    }
    $out = @($out)
    if (-not $out.Count) { $out = @('advfirewall set allprofiles firewallpolicy blockinbound,allowoutbound') }
    return $out
}

function Register-WHDRollbackTask {
    # Task WHDN-DefaultDenyRollback: runs once as SYSTEM at +N minutes (also right after the PC wakes if
    # that time was missed) and starts netsh.exe - one action per firewall profile.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][int]$Minutes, [Parameter(Mandatory)][string[]]$NetshArgument)
    if (-not $PSCmdlet.ShouldProcess($script:WHDFwRollbackTask, 'register scheduled task')) { return }
    $netsh = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\netsh.exe' } else { 'netsh.exe' }
    $acts = @(foreach ($a in $NetshArgument) { New-ScheduledTaskAction -Execute $netsh -Argument $a })
    $trig = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes($Minutes))
    $prin = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $sett = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $script:WHDFwRollbackTask -TaskPath '\' -Action $acts -Trigger $trig -Principal $prin -Settings $sett `
        -Description 'WHD Next: switches outbound back to Allow unless default-deny was confirmed (Firewall menu 7).' -Force -ErrorAction Stop | Out-Null
}

function Get-WHDRollbackTask {
    [CmdletBinding()]
    param()
    if (-not (Get-Command -Name Get-ScheduledTask -ErrorAction SilentlyContinue)) { return $null }
    Get-ScheduledTask -TaskName $script:WHDFwRollbackTask -TaskPath '\' -ErrorAction SilentlyContinue
}

function Unregister-WHDRollbackTask {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not (Get-WHDRollbackTask)) { return $false }
    if (-not $PSCmdlet.ShouldProcess($script:WHDFwRollbackTask, 'remove scheduled task')) { return $false }
    Unregister-ScheduledTask -TaskName $script:WHDFwRollbackTask -TaskPath '\' -Confirm:$false -ErrorAction Stop
    return $true
}

function Enable-WHDDefaultDenyOutbound {
    [CmdletBinding()]
    param([ValidateRange(1, 1440)][int]$RollbackMinutes = 10)
    Write-WHDLog -Message 'Enable DEFAULT-DENY OUTBOUND (strict).' -Level 'ACT'
    Write-WHDRisk -Tier 'hard' -Text ('Sets the default outbound action to Block: anything not on the allow-list is cut. Switches back by itself in {0} min unless you confirm (7).' -f $RollbackMinutes)
    if (-not (Confirm-WHDProceed -What ('block all outbound except the allow-list (auto-rollback in {0} min)' -f $RollbackMinutes))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    if (-not @(Get-NetFirewallRule -Group $script:WHDFwGroupAllow -ErrorAction SilentlyContinue).Count) { Invoke-WHDBlocklistHold -Do { Invoke-WHDFirewallAllowList } }
    # the rollback is armed BEFORE the switch, so a mistake heals itself
    $rbArgs = ConvertTo-WHDRollbackArgument -Profiles @(Get-WHDFwProfile)
    $rbMin = $RollbackMinutes
    $rbRes = Invoke-WHDChange -Description ('arm auto-rollback task {0} (+{1} min, runs netsh: outbound back to Allow)' -f $script:WHDFwRollbackTask, $rbMin) -Action {
        Register-WHDRollbackTask -Minutes $rbMin -NetshArgument $rbArgs
    }
    if ([string]$rbRes.Status -eq 'failed') {
        Write-WHDLog -Message 'The auto-rollback could NOT be armed - default-deny will NOT switch back by itself. Keep this window open; 8 reverts it.' -Level 'WARN'
    }
    Invoke-WHDChange -Description 'set DefaultOutboundAction = Block (all profiles)' -Action {
        Set-NetFirewallProfile -All -DefaultOutboundAction Block -Confirm:$false -ErrorAction Stop
    } | Out-Null
    Write-WHDLog -Message 'Default-deny outbound planned / engaged. Check that the PC still reaches what it needs, then 7 keeps it.' -Level 'WARN'
    Sync-WHDBlocklist -AfterChange
}

function Confirm-WHDDefaultDenyKeep {
    [CmdletBinding()]
    param()
    if (-not (Get-WHDRollbackTask)) {
        Write-WHDLog -Message 'No auto-rollback task is waiting (it already ran, or none was armed). Default-deny stays until you revert it (8).'
        return
    }
    $kr = Invoke-WHDChange -Description ('cancel the auto-rollback task {0} (keep default-deny)' -f $script:WHDFwRollbackTask) -Action { [void](Unregister-WHDRollbackTask) }
    if ([string]$kr.Status -eq 'done') { Write-WHDLog -Message 'Auto-rollback cancelled - default-deny outbound stays until you revert it (8).' -Level 'OK' }
}

function Disable-WHDDefaultDenyOutbound {
    [CmdletBinding()]
    param()
    if (Test-WHDGateClosedNow) {
        Write-WHDLog -Message 'The update gate is closed - open it in the Updates menu; that also puts back the rules it switched off.' -Level 'WARN'
        return
    }
    Write-WHDLog -Message 'Revert default-deny: outbound back to Allow.' -Level 'ACT'
    if (Get-WHDRollbackTask) {
        Invoke-WHDChange -Description ('remove the auto-rollback task {0}' -f $script:WHDFwRollbackTask) -Action { [void](Unregister-WHDRollbackTask) } | Out-Null
    }
    Invoke-WHDChange -Description 'set DefaultOutboundAction = Allow (all profiles)' -Action {
        Set-NetFirewallProfile -All -DefaultOutboundAction Allow -Confirm:$false -ErrorAction Stop
    } | Out-Null
    Write-WHDLog -Message 'Default-allow outbound planned / back.' -Level 'OK'
    Sync-WHDBlocklist -AfterChange
}

# =====================================================================================
#  6) BLACKLIST  (IP / CIDR -> firewall block rules; domains -> hosts sinkhole)
#     Windows Firewall rules match addresses, never names: domains go to the hosts file.
# =====================================================================================
function Read-WHDListFile {
    # Non-empty, non-comment lines of a list file.
    [CmdletBinding()]
    [OutputType([System.Array])]
    param([Parameter(Mandatory)][string]$Path)
    @(Get-Content -LiteralPath $Path -ErrorAction Stop | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^#' })
}

function Block-WHDIPList {
    # Block rules in chunks of 1000 addresses (WHDN-Blacklist-<direction>-<n>); never-block entries are skipped.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [ValidateRange(1, 10000)][int]$ChunkSize = 1000,
          [ValidateSet('Inbound', 'Outbound')][string[]]$Directions = @('Inbound', 'Outbound'))
    if (-not (Test-Path -LiteralPath $Path)) { Write-WHDLog -Message ('IP list not found: {0}' -f $Path) -Level 'ERR'; return }
    $raw = Read-WHDListFile -Path $Path
    if (-not $raw.Count) { Write-WHDLog -Message 'IP list is empty.' -Level 'WARN'; return }
    $ips = [System.Collections.Generic.List[string]]::new(); $skipped = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $raw) { if (Test-WHDNeverBlock -Cidr $e) { $skipped.Add($e) } else { $ips.Add($e) } }
    if ($skipped.Count) { Write-WHDLog -Message ('SAFETY: skipped {0} private / multicast / reserved / not-IPv4 entr(y/ies): {1}' -f $skipped.Count, (@($skipped | Select-Object -First 5) -join ', ')) -Level 'WARN' }
    if (-not $ips.Count) { Write-WHDLog -Message 'IP list has no safe, routable entries after the safety check.' -Level 'WARN'; return }
    $dirs = @($Directions | Select-Object -Unique)
    Write-WHDLog -Message ('Blocking {0} safe IP / CIDR entr(y/ies) as firewall rules ({1}).' -f $ips.Count, ($dirs -join ' + ').ToLowerInvariant()) -Level 'ACT'
    $chunk = 0
    for ($i = 0; $i -lt $ips.Count; $i += $ChunkSize) {
        $chunk++
        $slice = @($ips.GetRange($i, [Math]::Min($ChunkSize, $ips.Count - $i)))
        foreach ($dir in $dirs) {
            New-WHDFwRule -Params @{ Name = ('WHDN-Blacklist-{0}-{1}' -f $dir, $chunk); DisplayName = ('WHD Next Blacklist IPs {0} #{1}' -f $dir, $chunk)
                Group = $script:WHDFwGroupBlock; Direction = $dir; Action = 'Block'; Enabled = 'True'; Profile = 'Any'; RemoteAddress = $slice }
        }
    }
    Write-WHDLog -Message ('IP block list planned / applied: {0}, {1} rule(s).' -f ($dirs -join ' + ').ToLowerInvariant(), ($chunk * $dirs.Count)) -Level 'OK'
}

function Get-WHDHostsWithoutBlock {
    # The hosts lines outside WHD's own # WHDN-BLACKLIST START / END block (pure).
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowEmptyCollection()][string[]]$Lines)
    $keep = [System.Collections.Generic.List[string]]::new(); $inBlock = $false
    foreach ($l in @($Lines)) {
        if ($l -match '^\s*# WHDN-BLACKLIST START') { $inBlock = $true; continue }
        if ($l -match '^\s*# WHDN-BLACKLIST END') { $inBlock = $false; continue }
        if (-not $inBlock) { $keep.Add($l) }
    }
    return $keep.ToArray()
}

function Block-WHDHostsList {
    # Domains -> 0.0.0.0 in the hosts file, inside WHD's own block (applying again replaces it, never stacks).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { Write-WHDLog -Message ('domain list not found: {0}' -f $Path) -Level 'ERR'; return }
    $domains = Read-WHDListFile -Path $Path
    if (-not $domains.Count) { Write-WHDLog -Message 'domain list is empty.' -Level 'WARN'; return }
    Write-WHDLog -Message ('Hosts sinkhole: {0:N0} domain(s) -> 0.0.0.0.' -f $domains.Count) -Level 'ACT'
    Write-WHDRisk -Tier 'caution' -Text 'Rewrites WHD''s own block in the hosts file; a copy of the hosts file goes to restore\ first (Undo center: restore hosts).'
    if (-not (Confirm-WHDProceed -What ('sinkhole {0:N0} domain(s) in the hosts file' -f $domains.Count))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    $hf = $script:WHDHostsFile; $hbak = Join-Path (Get-WHDRestoreFolder) 'hosts.bak'; $hDomains = $domains
    Invoke-WHDChange -Description ('sinkhole {0:N0} domain(s) in the hosts file (WHD block replaced)' -f $domains.Count) -Action {
        $hd = Split-Path $hbak -Parent; if (-not (Test-Path -LiteralPath $hd)) { [void](New-Item -ItemType Directory -Path $hd -Force) }
        if (-not (Test-Path -LiteralPath $hbak)) { Copy-Item -LiteralPath $hf -Destination $hbak -ErrorAction Stop }
        $keep = Get-WHDHostsWithoutBlock -Lines @(Get-Content -LiteralPath $hf -ErrorAction Stop)
        $block = [System.Collections.Generic.List[string]]::new($keep.Count + $hDomains.Count + 2)
        $block.AddRange([string[]]$keep); $block.Add('# WHDN-BLACKLIST START')
        foreach ($dn in $hDomains) { $block.Add('0.0.0.0 ' + $dn) }
        $block.Add('# WHDN-BLACKLIST END')
        Set-Content -LiteralPath $hf -Value $block -Encoding ascii -ErrorAction Stop
    } | Out-Null
    Write-WHDLog -Message 'hosts sinkhole planned / applied.' -Level 'OK'
}

function Remove-WHDBlacklist {
    # Clears both: the IP block rules and WHD's block in the hosts file. Cleared by hand = the IP block
    # list stops following the firewall until it is applied again (9).
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-WHDLog -Message 'CLEAR blacklist (IP block rules + hosts sinkhole).' -Level 'ACT'
    if (-not $PSCmdlet.ShouldProcess('IP block rules + hosts block', 'clear')) { return }
    if (-not (Confirm-WHDProceed -What 'remove the IP block rules and WHD''s hosts block')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    Remove-WHDFwGroup -Group $script:WHDFwGroupBlock
    $hf = $script:WHDHostsFile; $hbak = Join-Path (Get-WHDRestoreFolder) 'hosts.bak'
    $hasBlock = (Test-Path -LiteralPath $hf) -and [bool](Select-String -LiteralPath $hf -Pattern '^\s*# WHDN-BLACKLIST START' -Quiet)
    if ($hasBlock) {
        Invoke-WHDChange -Description 'remove the WHDN-BLACKLIST block from the hosts file' -Action {
            $hd = Split-Path $hbak -Parent; if (-not (Test-Path -LiteralPath $hd)) { [void](New-Item -ItemType Directory -Path $hd -Force) }
            if (-not (Test-Path -LiteralPath $hbak)) { Copy-Item -LiteralPath $hf -Destination $hbak -ErrorAction Stop }
            Set-Content -LiteralPath $hf -Value (Get-WHDHostsWithoutBlock -Lines @(Get-Content -LiteralPath $hf -ErrorAction Stop)) -Encoding ascii -ErrorAction Stop
        } | Out-Null
    } else { Write-WHDLog -Message 'hosts file has no WHD block - nothing to remove there.' }
    if (Test-WHDRealChange) {
        if (Set-WHDBlocklistState -Follow $false -ListFile (Get-WHDBlocklistState).ListFile) {
            Write-WHDLog -Message 'IP block list: cleared by hand - it no longer follows the firewall. 9 switches that back on.'
        }
    } else { Write-WHDLog -Message 'would: stop the IP block list following the firewall until it is applied again (9)' -Level 'DRY' }
}

# =====================================================================================
#  6b) THE IP BLOCK LIST FOLLOWS THE FIREWALL  (as in WHD Next 2.0)
#  A block rule beats an allow rule and the default action only applies when no rule
#  matches (Microsoft Learn), so a block list only does work where something is WIDE OPEN:
#    outbound - default outbound Allow, or an enabled outbound allow rule open to any address
#               (not counted: the update gate's own WHDN-Gate-* rules and the DHCP request);
#    inbound  - default inbound Allow, or an enabled inbound allow rule beyond the DHCP reply.
#  WHD puts the block rules in for exactly those directions and takes them out where nothing
#  is wide open. Clearing by hand (C) stops the following until 9. Kept per PC in
#  restore\update-guard\blocklist.json (same name and fields as WHD Next 2.0).
# =====================================================================================
$script:WHDBlocklistHold = 0          # > 0: a bigger job runs; it re-checks once at its end
$script:WHDBlocklistScanCap = 25      # counting wide-open rules stops here (enough to know)

function Get-WHDBlocklistDefaultFile {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Invoke-WHDListTakeover
    Join-Path (Get-WHDProfileFolder) 'blacklist-ip.txt'
}

function Get-WHDBlocklistStateFile {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path (Join-Path (Join-Path $script:WHDState.DataRoot 'restore') 'update-guard') 'blocklist.json'
}

function Get-WHDBlocklistState {
    [CmdletBinding()]
    param()
    $f = Get-WHDBlocklistStateFile
    $bs = $null
    if (Test-Path -LiteralPath $f) { try { $bs = Get-Content -LiteralPath $f -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable } catch { $bs = $null } }
    if ($bs -and [string]$bs['MachineId'] -and ([string]$bs['MachineId']).ToLowerInvariant() -ne (Get-WHDMachineId)) { $bs = $null }   # another PC's file
    $follow = $true; $list = ''; $chg = ''
    if ($bs) {
        if ($bs.ContainsKey('Follow') -and $null -ne $bs['Follow']) { $follow = [bool]$bs['Follow'] }
        $list = [string]$bs['ListFile']; $chg = [string]$bs['Changed']
    }
    [pscustomobject]@{ Follow = $follow; ListFile = $list; Changed = $chg }
}

function Set-WHDBlocklistState {
    # $true when saved.
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([bool]$Follow, [string]$ListFile = '')
    $f = Get-WHDBlocklistStateFile
    if (-not $PSCmdlet.ShouldProcess($f, 'save IP block list setting')) { return $false }
    try {
        $d = Split-Path -Parent $f
        if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop) }
        [ordered]@{ MachineId = (Get-WHDMachineId); Computer = [Environment]::MachineName; Follow = $Follow; ListFile = $ListFile; Changed = (Get-Date).ToString('yyyy-MM-dd HH:mm') } |
            ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $f -Encoding utf8 -ErrorAction Stop
        return $true
    } catch {
        Write-WHDLog -Message ('could not save the IP block list setting ({0}): {1}' -f $f, $_.Exception.Message) -Level 'WARN'
        return $false
    }
}

function Get-WHDBlocklistFile {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $bst = Get-WHDBlocklistState
    if ($bst.ListFile) { return $bst.ListFile }
    Get-WHDBlocklistDefaultFile
}

function Get-WHDBlocklistNeed {
    # Read-only: is the block list needed, for which direction(s), and is it in?
    [CmdletBinding()]
    param([string]$Path, [switch]$AssumeFollow)
    $bst = Get-WHDBlocklistState
    $defFile = Get-WHDBlocklistDefaultFile
    $listFile = if ($Path) { $Path } elseif ($bst.ListFile) { $bst.ListFile } else { $defFile }
    $follow = ([bool]$bst.Follow -or [bool]$AssumeFollow)
    $profs = @(Get-WHDFwProfile)
    $outWhy = ''; $inWhy = ''
    if (-not $profs.Count -or @($profs | Where-Object { [string]$_.DefaultOutboundAction -ne 'Block' }).Count) {
        $outWhy = 'outbound default is Allow'
    } else {
        $wide = 0; $capped = $false
        foreach ($r in @(Get-NetFirewallRule -Direction Outbound -Action Allow -Enabled True -ErrorAction SilentlyContinue)) {
            if ([string]$r.Name -like 'WHDN-Gate-*' -or [string]$r.Name -eq 'WHDN-Allow-DHCP-Out') { continue }
            $ra = @(@(($r | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue).RemoteAddress) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
            if (-not $ra.Count -or ($ra -contains 'Any') -or ($ra -contains 'Internet')) {
                $wide++
                if ($wide -ge $script:WHDBlocklistScanCap) { $capped = $true; break }
            }
        }
        if ($wide) { $outWhy = '{0}{1} wide-open outbound rule(s)' -f $wide, $(if ($capped) { ' or more' } else { '' }) }
    }
    if (@($profs | Where-Object { [string]$_.DefaultInboundAction -eq 'Allow' }).Count) {
        $inWhy = 'inbound default is Allow'
    } else {
        $inN = @(Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True -ErrorAction SilentlyContinue | Where-Object { [string]$_.Name -ne 'WHDN-Allow-DHCP-In' }).Count
        if ($inN) { $inWhy = '{0} inbound allow rule(s) beyond the DHCP reply' -f $inN }
    }
    $want = @(); if ($outWhy) { $want += 'Outbound' }; if ($inWhy) { $want += 'Inbound' }
    $rules = @(Get-NetFirewallRule -Group $script:WHDFwGroupBlock -ErrorAction SilentlyContinue)
    $have = @(foreach ($d in 'Outbound', 'Inbound') { if (@($rules | Where-Object { [string]$_.Direction -eq $d }).Count) { $d } })
    $inStep = (($want -join ',') -eq ($have -join ','))
    $present = [bool](Test-Path -LiteralPath $listFile)
    $why = (@($outWhy, $inWhy) | Where-Object { $_ }) -join ' + '
    $wantTxt = ($want -join ' + ').ToLowerInvariant(); $haveTxt = ($have -join ' + ').ToLowerInvariant()
    $fileTxt = if ($listFile -eq $defFile) { 'profiles\blacklist-ip.txt' } else { $listFile }
    $text = ''; $hint = ''; $lvl = 'INFO'
    if (-not $follow) {
        if ($want.Count) { $text = 'off (cleared by hand) - but needed: {0}' -f $why; $lvl = 'WARN' } else { $text = 'off (cleared by hand) - not needed now' }
        $hint = '9 switches it back on'
    } elseif ($want.Count -and $inStep) { $text = 'needed: {0} - applied ({1}, {2} rule(s))' -f $why, $haveTxt, $rules.Count; $lvl = 'OK' }
    elseif ($want.Count -and -not $present) { $text = 'needed: {0} - but no list file ({1})' -f $why, $fileTxt; $lvl = 'WARN'; $hint = 'copy your list there, then 9' }
    elseif ($want.Count -and $have.Count) { $text = 'needed: {0} - wanted {1}, in now: {2}' -f $why, $wantTxt, $haveTxt; $lvl = 'WARN'; $hint = '9 brings it in line' }
    elseif ($want.Count) { $text = 'needed: {0} - NOT applied yet' -f $why; $lvl = 'WARN'; $hint = '9 puts it in' }
    elseif ($have.Count) { $text = 'not needed (nothing is wide open) - but {0} block rule(s) are still in' -f $rules.Count; $lvl = 'WARN'; $hint = '9 brings it in line' }
    else { $text = 'not needed, idle (nothing is wide open)'; $lvl = 'OK' }
    [pscustomobject]@{
        Follow = $follow; Needed = [bool]$want.Count; Want = @($want); Have = @($have); InStep = $inStep
        Why = $why; OutWhy = $outWhy; InWhy = $inWhy; ListFile = $listFile; ListPresent = $present
        Rules = $rules.Count; Text = $text; Hint = $hint; Level = $lvl
    }
}

function Invoke-WHDBlocklistHold {
    # Runs a bigger job with the automatic re-check held back (the caller re-checks once at its end).
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Do)
    $script:WHDBlocklistHold++
    try { & $Do } finally { $script:WHDBlocklistHold = [Math]::Max(0, $script:WHDBlocklistHold - 1) }
}

function Remove-WHDBlocklistDirection {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidateSet('Inbound', 'Outbound')][string]$Direction, [string]$Why = 'nothing is wide open there')
    $blNames = @(Get-NetFirewallRule -Group $script:WHDFwGroupBlock -ErrorAction SilentlyContinue | Where-Object { [string]$_.Direction -eq $Direction } | ForEach-Object { [string]$_.Name })
    if (-not $blNames.Count) { return }
    if (-not $PSCmdlet.ShouldProcess($Direction, 'remove IP block rules')) { return }
    Invoke-WHDChange -Description ('IP block list: remove {0} {1} block rule(s) ({2})' -f $blNames.Count, $Direction.ToLowerInvariant(), $Why) -Action {
        Backup-WHDFirewallOnce
        foreach ($bn in $blNames) { Remove-NetFirewallRule -Name $bn -ErrorAction Stop }
    } | Out-Null
}

function Sync-WHDBlocklist {
    # Brings the block rules in line with what the firewall needs now.
    #   -AfterChange  end of a firewall change (in dry-run nothing changed: one line only)
    #   -Rebuild      re-create the wanted rules from the list file even when they are in
    #   -Apply        applied by hand: act as "following" even if it was cleared before
    #   -Path         list file instead of the remembered one
    [CmdletBinding()]
    param([switch]$AfterChange, [switch]$Rebuild, [switch]$Apply, [string]$Path)
    if ($script:WHDBlocklistHold -gt 0) { return }
    if ($AfterChange -and -not (Test-WHDRealChange)) {
        Write-WHDLog -Message 'would: re-check the IP block list after this change (it follows the firewall: in where something is wide open, out where nothing is)' -Level 'DRY'
        return
    }
    try { $need = if ($Path) { Get-WHDBlocklistNeed -Path $Path -AssumeFollow:$Apply } else { Get-WHDBlocklistNeed -AssumeFollow:$Apply } }
    catch { Write-WHDLog -Message ('IP block list could not be checked ({0}) - nothing changed there; 9 tries again.' -f $_.Exception.Message) -Level 'WARN'; return }
    if (-not $need.Follow) { Write-WHDLog -Message ('IP block list: {0}  ({1})' -f $need.Text, $need.Hint) -Level $need.Level; return }
    $want = @($need.Want); $have = @($need.Have); $warned = $false
    $drop = @($have | Where-Object { $want -notcontains $_ })
    $add = @($want | Where-Object { $have -notcontains $_ })
    if ($Rebuild) { $add = $want }
    if ($add.Count -and -not $need.ListPresent) {
        Write-WHDLog -Message ('IP block list is needed ({0}) but the list file is missing: {1}' -f $need.Why, $need.ListFile) -Level 'WARN'
        Write-WHDLog -Message '  Copy your blacklist-ip.txt into the profiles folder, then 9.' -Level 'WARN'
        $add = @(); $warned = $true            # rules that are in stay in - they cannot be rebuilt without the file
    } elseif ($Rebuild) { $drop = $have }
    if (-not $drop.Count -and -not $add.Count) {
        if (-not $warned) { Write-WHDLog -Message ('IP block list: {0}' -f $need.Text) -Level $need.Level }
        return
    }
    foreach ($d in $drop) { Remove-WHDBlocklistDirection -Direction $d -Why $(if ($want -contains $d) { 'rebuild from the list file' } else { 'nothing is wide open ' + $d.ToLowerInvariant() }) }
    if ($add.Count) {
        Write-WHDLog -Message ('IP block list is needed: {0}' -f $need.Why)
        Block-WHDIPList -Path $need.ListFile -Directions $add
    }
    if (Test-WHDRealChange) {
        $now = Get-WHDBlocklistNeed -Path $need.ListFile -AssumeFollow:$Apply
        Write-WHDLog -Message ('IP block list: {0}' -f $now.Text) -Level $now.Level
    }
}

function Invoke-WHDBlocklistApply {
    # Menu 9: applied by hand = follow the firewall again + rebuild from the list file.
    [CmdletBinding()]
    param([string]$Path)
    if (-not $Path) { $Path = Get-WHDBlocklistFile }
    Write-WHDLog -Message 'IP BLOCK LIST: apply (it follows the firewall: in where something is wide open, out where nothing is)' -Level 'ACT'
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-WHDLog -Message ('IP list not found: {0}' -f $Path) -Level 'ERR'
        Write-WHDLog -Message '  Copy your blacklist-ip.txt into the profiles folder, then try again.'
        return
    }
    $store = ''
    try { $full = [IO.Path]::GetFullPath($Path); if ($full -ne [IO.Path]::GetFullPath((Get-WHDBlocklistDefaultFile))) { $store = $full } } catch { $store = $Path }
    $was = Get-WHDBlocklistState
    if (Test-WHDRealChange) { [void](Set-WHDBlocklistState -Follow $true -ListFile $store) }
    elseif (-not $was.Follow) { Write-WHDLog -Message 'would: let the IP block list follow the firewall again' -Level 'DRY' }
    Sync-WHDBlocklist -Apply -Rebuild -Path $Path
    if (-not (Get-WHDBlocklistNeed -Path $Path -AssumeFollow).Needed) {
        Write-WHDLog -Message '  Nothing is wide open right now, so no block rules are needed. WHD puts the list in by itself as soon as something is opened.'
    }
}

# =====================================================================================
#  7) FIREWALL PROFILE FILE  (profiles\firewall-baseline.json drives the parts above)
# =====================================================================================
function ConvertTo-WHDProfileRule {
    # One allowList entry of a profile file -> New-NetFirewallRule parameters (pure).
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Entry, [string[]]$NtpAddress)
    $p = @{ Name = [string]$Entry['name']; DisplayName = [string]$Entry['displayName']; Group = $script:WHDFwGroupAllow
            Direction = $(if ($Entry['direction']) { [string]$Entry['direction'] } else { 'Outbound' }); Action = 'Allow'; Enabled = 'True'; Profile = 'Any' }
    foreach ($k in @(@('protocol', 'Protocol'), @('remotePort', 'RemotePort'), @('localPort', 'LocalPort'), @('program', 'Program'))) { if ($Entry[$k[0]]) { $p[$k[1]] = $Entry[$k[0]] } }
    $ra = @($Entry['remoteAddress'] | Where-Object { $_ })
    if ($ra.Count) { $p['RemoteAddress'] = $ra }
    if ($p['Name'] -eq 'WHDN-Allow-NTP' -and -not $p.ContainsKey('RemoteAddress') -and $NtpAddress) {
        $p['RemoteAddress'] = @($NtpAddress); $p['DisplayName'] = 'WHD Next Allow NTP (UDP 123, time.cloudflare.com)'
    }
    return $p
}

function Invoke-WHDApplyFirewallProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { Write-WHDLog -Message ('firewall profile not found: {0}' -f $Path) -Level 'ERR'; return }
    $cfg = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    Write-WHDLog -Message ('Applying firewall profile: {0}' -f $cfg['name']) -Level 'ACT'
    if (-not (Confirm-WHDProceed -What ('apply firewall profile {0}' -f $cfg['name']))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    $pfBase = Split-Path -Parent $Path
    Invoke-WHDBlocklistHold -Do {
        $pd = $cfg['profileDefaults']
        if ($pd) {
            $pfIn = if ($pd['inbound']) { [string]$pd['inbound'] } else { 'Block' }
            $pfOut = if ($pd['outbound']) { [string]$pd['outbound'] } else { 'Allow' }
            # a profile never LOWERS outbound: Block (default-deny / closed update gate) stays Block
            if ($pfOut -eq 'Allow' -and (@(Get-WHDFwProfile | ForEach-Object { [string]$_.DefaultOutboundAction }) -contains 'Block')) {
                Write-WHDLog -Message 'Outbound is Block now (default-deny / update gate) - the profile keeps it Block instead of Allow.'
                $pfOut = 'Block'
            }
            Invoke-WHDChange -Description ('firewall profile defaults: in={0} out={1}, firewall on' -f $pfIn, $pfOut) -Action {
                Set-NetFirewallProfile -All -Enabled True -DefaultInboundAction $pfIn -DefaultOutboundAction $pfOut -Confirm:$false -ErrorAction Stop
            } | Out-Null
        }
        $v6 = $cfg['ipv6']
        if ($v6 -and $v6['disable']) { if ($v6['blockLoopback']) { Invoke-WHDDisableIPv6 -BlockLoopback } else { Invoke-WHDDisableIPv6 } }
        if ($cfg['allowList']) {
            $ntp = Get-WHDNtpRemoteAddress
            foreach ($a in @($cfg['allowList'])) { New-WHDFwRule -Params (ConvertTo-WHDProfileRule -Entry $a -NtpAddress $ntp) }
            if (Test-WHDGateClosedNow) { Disable-WHDGateWebRule }
        }
        $bl = $cfg['blacklist']
        if ($bl -and $bl['hostsFile']) {
            $hfile = Join-Path $pfBase ([string]$bl['hostsFile'])
            if (Test-Path -LiteralPath $hfile) { Block-WHDHostsList -Path $hfile } else { Write-WHDLog -Message ('hosts list named by the profile not found: {0}' -f $hfile) -Level 'WARN' }
        }
        if ($cfg['defaultDenyOutbound'] -eq $true) {
            Enable-WHDDefaultDenyOutbound -RollbackMinutes $(if ($cfg['rollbackMinutes']) { [int]$cfg['rollbackMinutes'] } else { 10 })
        }
    }
    # the IP block list is brought in line ONCE, at the end
    $ipFile = ''
    if ($cfg['blacklist'] -and $cfg['blacklist']['ipFile']) {
        $cand = Join-Path $pfBase ([string]$cfg['blacklist']['ipFile'])
        if (Test-Path -LiteralPath $cand) { $ipFile = $cand }
    }
    if ($ipFile) { Invoke-WHDBlocklistApply -Path $ipFile } else { Sync-WHDBlocklist -AfterChange }
    Write-WHDLog -Message 'Firewall profile planned / applied. Check the result before it becomes permanent.' -Level 'OK'
}

# =====================================================================================
#  8) CONNECTION LOG + BLOCKED-CONNECTION VIEWER  (Windows Firewall's own log, as in WHD Next 2.0)
#  Windows' default file and name (%SystemRoot%\System32\LogFiles\Firewall\pfirewall.log),
#  dropped + allowed connections, size 32,767 KB (the largest Windows allows; it then keeps
#  one .old file). The log has no program path; where it records a process id, WHD names
#  the program if that process still runs, and remembers names it has seen.
# =====================================================================================
$script:WHDFwLogMaxKB = 32767
$script:WHDFwLogDefault = '%systemroot%\system32\LogFiles\Firewall\pfirewall.log'
$script:WHDFwNamesKeepDays = 7
$script:WHDFwNamesMax = 400

function Get-WHDFirewallLogFile {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $fp = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { [string]$_.LogFileName -and [string]$_.LogFileName -ne 'NotConfigured' })
    $f = if ($fp.Count) { [string]$fp[0].LogFileName } else { $script:WHDFwLogDefault }
    [Environment]::ExpandEnvironmentVariables($f)
}

function Get-WHDConnectionLoggingState {
    [CmdletBinding()]
    param()
    $pr = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue)
    $on = ($pr.Count -gt 0)
    foreach ($p in $pr) { if ([string]$p.LogAllowed -ne 'True' -or [string]$p.LogBlocked -ne 'True' -or [int64]$p.LogMaxSizeKilobytes -ne $script:WHDFwLogMaxKB) { $on = $false } }
    $file = Get-WHDFirewallLogFile
    $kb = $null
    if (Test-Path -LiteralPath $file) { try { $kb = [math]::Round((Get-Item -LiteralPath $file -ErrorAction Stop).Length / 1KB) } catch { $kb = $null } }
    [pscustomobject]@{ On = $on; File = $file; UsedKB = $kb
        Profiles = @($pr | ForEach-Object { '{0}: allowed={1} dropped={2} {3} KB' -f $_.Name, $_.LogAllowed, $_.LogBlocked, $_.LogMaxSizeKilobytes }) }
}

function Show-WHDConnectionLoggingState {
    [CmdletBinding()]
    param()
    $ls = Get-WHDConnectionLoggingState
    Write-WHDLog -Message ('Firewall log: {0}   file {1} ({2} KB in use)' -f $(if ($ls.On) { 'ON (dropped + allowed, 32,767 KB)' } else { 'not fully on' }), $ls.File, $(if ($null -eq $ls.UsedKB) { 0 } else { $ls.UsedKB })) -Level $(if ($ls.On) { 'OK' } else { 'INFO' })
    foreach ($l in $ls.Profiles) { Write-WHDLog -Message ('  {0}' -f $l) }
}

function Set-WHDConnectionLogging {
    # Every profile that differs gets one journaled change (kind fwlog - Undo center + Verify).
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][bool]$On)
    $want = if ($On) { 'True' } else { 'False' }
    foreach ($p in @(Get-NetFirewallProfile -ErrorAction Stop)) {
        $size = if ($On) { [int64]$script:WHDFwLogMaxKB } else { [int64]$p.LogMaxSizeKilobytes }
        if ([string]$p.LogAllowed -eq $want -and [string]$p.LogBlocked -eq $want -and [int64]$p.LogMaxSizeKilobytes -eq $size) { continue }
        if (-not $PSCmdlet.ShouldProcess([string]$p.Name, 'firewall log')) { continue }
        Set-WHDFirewallLog -FwProfile ([string]$p.Name) -Allowed $want -Blocked $want -SizeKB $size | Out-Null
    }
}

function Enable-WHDConnectionLogging {
    [CmdletBinding()]
    param()
    Write-WHDLog -Message 'FIREWALL LOG: turn on (Windows default file, dropped + allowed, largest size)' -Level 'ACT'
    Write-WHDRisk -Tier 'reversible' -Text ('Windows Firewall writes every dropped AND allowed connection to its own log ({0}), 32,767 KB (then it starts over and keeps one .old file). Recorded (Undo center).' -f (Get-WHDFirewallLogFile))
    if ((Get-WHDConnectionLoggingState).On) { Write-WHDLog -Message 'Already on - nothing to change.' -Level 'OK'; return }
    if (-not (Confirm-WHDProceed -What 'turn on the Windows Firewall log (dropped + allowed, 32,767 KB)')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    Set-WHDConnectionLogging -On $true
}

function Disable-WHDConnectionLogging {
    [CmdletBinding()]
    param()
    Write-WHDLog -Message 'FIREWALL LOG: turn off' -Level 'ACT'
    Write-WHDRisk -Tier 'reversible' -Text 'Windows Firewall stops writing connections to its log; the size setting is kept. Recorded (Undo center).'
    if (-not (Confirm-WHDProceed -What 'turn off the Windows Firewall log')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    Set-WHDConnectionLogging -On $false
}

function ConvertFrom-WHDFirewallLogLine {
    # One pfirewall.log line -> hashtable by the file's #Fields: names, with 'when' added; $null for other lines (pure).
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$Line, [string[]]$Fields)
    if (-not $Line -or $Line.StartsWith('#')) { return $null }
    $v = $Line -split '\s+'
    if ($v.Count -lt 8) { return $null }
    $h = @{}
    for ($i = 0; $i -lt [math]::Min($Fields.Count, $v.Count); $i++) { $h[$Fields[$i]] = $v[$i] }
    $t = [datetime]::MinValue
    if (-not [datetime]::TryParseExact(('{0} {1}' -f $h['date'], $h['time']), 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$t)) { return $null }
    $h['when'] = $t
    return $h
}

function Read-WHDFirewallLog {
    # pfirewall.log (+ .old), read with shared access - the firewall keeps the file open.
    [CmdletBinding()]
    param([datetime]$Since = [datetime]::MinValue, [string]$File)
    if (-not $File) { $File = Get-WHDFirewallLogFile }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($f in @(('{0}.old' -f $File), $File)) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $fields = @('date', 'time', 'action', 'protocol', 'src-ip', 'dst-ip', 'src-port', 'dst-port')
        $fs = $null; $sr = $null
        try {
            $fs = [System.IO.FileStream]::new($f, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr = [System.IO.StreamReader]::new($fs)
            while ($null -ne ($line = $sr.ReadLine())) {
                if ($line.StartsWith('#Fields:')) { $fields = @($line.Substring(8).Trim() -split '\s+'); continue }
                $h = ConvertFrom-WHDFirewallLogLine -Line $line -Fields $fields
                if ($h -and $h['when'] -ge $Since) { $rows.Add([pscustomobject]$h) }
            }
        } catch { Write-WHDLog -Message ('could not read {0}: {1}' -f $f, $_.Exception.Message) -Level 'WARN' }
        finally { if ($sr) { $sr.Dispose() }; if ($fs) { $fs.Dispose() } }
    }
    return $rows.ToArray()
}

# ---- remembered program names (restore\update-guard\blocked-programs.json, as in WHD Next 2.0) ----
function Get-WHDFwNamesFile {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path (Join-Path (Join-Path $script:WHDState.DataRoot 'restore') 'update-guard') 'blocked-programs.json'
}

function Read-WHDFwName {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $f = Get-WHDFwNamesFile
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    $out = [System.Collections.Generic.List[object]]::new()
    try {
        $j = Get-Content -LiteralPath $f -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        if (([string]$j['MachineId']).ToLowerInvariant() -ne (Get-WHDMachineId)) { return @() }
        foreach ($n in @($j['Names'])) {
            $st = [datetime]::MinValue; $se = [datetime]::MinValue
            if (-not [datetime]::TryParseExact([string]$n['Start'], 'yyyy-MM-dd HH:mm:ss', $null, [Globalization.DateTimeStyles]::None, [ref]$st)) { continue }
            if (-not [datetime]::TryParseExact([string]$n['Seen'], 'yyyy-MM-dd HH:mm:ss', $null, [Globalization.DateTimeStyles]::None, [ref]$se)) { continue }
            if (-not [string]$n['Path']) { continue }
            $out.Add([pscustomobject]@{ Pid = [string]$n['Pid']; Start = $st; Seen = $se; Path = [string]$n['Path']; Exe = [string]$n['Exe'] })
        }
    } catch { return @() }
    return $out.ToArray()
}

function Save-WHDFwName {
    # Best effort: the view works without this memory.
    [CmdletBinding(SupportsShouldProcess)]
    param([object[]]$Names)
    $f = Get-WHDFwNamesFile
    if (-not $PSCmdlet.ShouldProcess($f, 'save program names')) { return }
    try {
        $d = Split-Path -Parent $f
        if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop) }
        $rows = @($Names | ForEach-Object { [ordered]@{ Pid = [string]$_.Pid; Start = $_.Start.ToString('yyyy-MM-dd HH:mm:ss'); Seen = $_.Seen.ToString('yyyy-MM-dd HH:mm:ss'); Path = [string]$_.Path; Exe = [string]$_.Exe } })
        [ordered]@{ MachineId = (Get-WHDMachineId); Computer = [Environment]::MachineName; Names = $rows } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $f -Encoding utf8 -ErrorAction Stop
    } catch { Write-Verbose ('program names not saved: {0}' -f $_.Exception.Message) }
}

function Get-WHDProgramAllowName {
    # Rule name of a per-program allow (pure): WHDN-App-<exe>-<protocol>-<port>.
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Program, [string]$Protocol, [string]$RemotePort)
    $exe = if ($Program) { Split-Path $Program -Leaf } else { '' }
    'WHDN-App-{0}-{1}-{2}' -f ($exe -replace '[^A-Za-z0-9._-]', '_'), $Protocol, $RemotePort
}

function Get-WHDAllowListCover {
    # What the WHD allow-list lets out for ANY program now: protocol, remote ports, remote addresses.
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @(Get-NetFirewallRule -Group $script:WHDFwGroupAllow -ErrorAction SilentlyContinue | Where-Object { [string]$_.Direction -eq 'Outbound' -and [string]$_.Action -eq 'Allow' -and [string]$_.Enabled -eq 'True' })) {
        $pf = $r | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
        $af = $r | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
        if (-not $pf) { continue }
        if ([string]$pf.LocalPort -and [string]$pf.LocalPort -ne 'Any') { continue }      # tied to a local port (DHCP)
        $out.Add([pscustomobject]@{ Protocol = [string]$pf.Protocol
            Ports = @(@($pf.RemotePort) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
            Addrs = @(@($af.RemoteAddress) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) })
    }
    return $out.ToArray()
}

function Test-WHDAllowListCover {
    # Would the allow-list let this protocol + port to all these addresses out now? (pure)
    [CmdletBinding()]
    [OutputType([bool])]
    param([object[]]$Cover, [string]$Protocol, [string]$Port, [string[]]$IPs)
    if (-not @($IPs).Count) { return $false }
    foreach ($c in @($Cover)) {
        if ($c.Protocol -ne 'Any' -and $c.Protocol -ne $Protocol) { continue }
        if (@($c.Ports).Count -and ($c.Ports -notcontains 'Any') -and ($c.Ports -notcontains $Port)) { continue }
        if (-not @($c.Addrs).Count -or ($c.Addrs -contains 'Any')) { return $true }
        $ranges = @(foreach ($a in $c.Addrs) { $rg = ConvertTo-WHDIpRange -Cidr $a; if ($rg) { , $rg } })
        $all = $true
        foreach ($ip in @($IPs)) {
            $a = ConvertTo-WHDIpRange -Cidr $ip
            if (-not $a -or -not @($ranges | Where-Object { $a[0] -ge $_[0] -and $a[0] -le $_[1] }).Count) { $all = $false; break }
        }
        if ($all) { return $true }
    }
    return $false
}

function Get-WHDBlockedConnection {
    # Blocked (DROP) lines grouped by direction + program + protocol + port, each with a State:
    # can | allowed | allowed-off (gate closed) | covered (allow-list lets it out now) | windows | inbound | ended.
    [CmdletBinding()]
    [OutputType([System.Array])]
    param([ValidateRange(1, 8760)][int]$Hours = 24, [ValidateSet('Outbound', 'Inbound', 'Any')][string]$Direction = 'Outbound', [ValidateSet('DROP', 'ALLOW')][string]$LogAction = 'DROP', [object[]]$Lines)
    $now = Get-Date
    if ($null -eq $Lines) { $Lines = @(Read-WHDFirewallLog -Since $now.AddHours(-1 * $Hours)) }
    $local = @(Get-NetIPAddress -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.IPAddress })
    $procs = @{}
    foreach ($pp in @(Get-Process -ErrorAction SilentlyContinue)) {
        $pst = $null; try { $pst = $pp.StartTime } catch { $pst = $null }          # protected processes do not show it
        $ppath = ''; try { $ppath = [string]$pp.Path } catch { $ppath = '' }
        $procs[[string]$pp.Id] = [pscustomobject]@{ Path = $ppath; Exe = '{0}.exe' -f $pp.ProcessName; Start = $pst }
    }
    $boot = $null; try { $boot = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch { $boot = $null }
    $names = @(Read-WHDFwName)
    $byPid = @{}; foreach ($n in $names) { if (-not $byPid.ContainsKey($n.Pid)) { $byPid[$n.Pid] = [System.Collections.Generic.List[object]]::new() }; $byPid[$n.Pid].Add($n) }
    $seenNow = @{}; $groups = @{}
    foreach ($e in @($Lines)) {
        if ([string]$e.action -ne $LogAction) { continue }
        $dir = switch ([string]$e.path) { 'SEND' { 'Outbound' } 'RECEIVE' { 'Inbound' } default { if ($local -contains [string]$e.'dst-ip') { 'Inbound' } else { 'Outbound' } } }
        if ($Direction -ne 'Any' -and $dir -ne $Direction) { continue }
        $pidv = if ($e.PSObject.Properties['pid']) { [string]$e.pid } else { '' }
        $prog = ''; $exe = '(unknown)'; $ended = $false
        if ($pidv -eq '4' -or $pidv -eq '0') { $prog = 'System'; $exe = 'System' }
        elseif ($pidv -and $pidv -ne '-') {
            $lp = $procs[$pidv]
            if ($lp -and (-not $lp.Start -or $lp.Start -le $e.when.AddSeconds(2))) { $prog = $lp.Path; $exe = $lp.Exe; $seenNow[$pidv] = $lp }
            else {
                $ended = $true; $exe = '(program has closed)'; $hit = $null
                if ($byPid.ContainsKey($pidv)) {
                    foreach ($c in $byPid[$pidv]) {
                        if ($c.Start -gt $e.when.AddSeconds(2)) { continue }                      # started after the line
                        if ($e.when -gt $c.Seen.AddMinutes(30)) { continue }                     # long after it was last seen
                        if ($boot -and $c.Start -lt $boot -and $e.when -gt $boot) { continue }   # a restart lies between
                        if (-not $hit -or $c.Start -gt $hit.Start) { $hit = $c }
                    }
                }
                if ($hit) { $prog = $hit.Path; $exe = $hit.Exe }
            }
        }
        $proto = [string]$e.protocol; $port = [string]$e.'dst-port'
        $ip = if ($dir -eq 'Inbound') { [string]$e.'src-ip' } else { [string]$e.'dst-ip' }
        $who = if ($prog -and $prog -ne 'System') { $prog.ToLowerInvariant() } else { $exe }
        $key = '{0}|{1}|{2}|{3}' -f $dir, $who, $proto, $port
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = [pscustomobject]@{ Count = 0; Last = $e.when; First = $e.when; Direction = $dir; Program = $prog; Exe = $exe; Protocol = $proto; RemotePort = $port
                IPs = [System.Collections.Generic.List[string]]::new(); Addresses = ''; Closed = $ended; State = ''; StateText = '' }
        }
        $g = $groups[$key]
        $g.Count++
        if ($e.when -gt $g.Last) { $g.Last = $e.when }
        if ($e.when -lt $g.First) { $g.First = $e.when }
        if (-not $ended) { $g.Closed = $false }
        if ($ip -and -not $g.IPs.Contains($ip)) { $g.IPs.Add($ip) }
    }
    if ($seenNow.Count) {
        $keep = [System.Collections.Generic.List[object]]::new(); $done = @{}
        foreach ($k in @($seenNow.Keys)) {
            $lp = $seenNow[$k]
            if (-not $lp.Path -or -not $lp.Start) { continue }
            $keep.Add([pscustomobject]@{ Pid = $k; Start = $lp.Start; Seen = $now; Path = $lp.Path; Exe = $lp.Exe })
            $done['{0}|{1}' -f $k, $lp.Start.ToString('yyyy-MM-dd HH:mm:ss')] = $true
        }
        foreach ($n in $names) {
            if ($done.ContainsKey(('{0}|{1}' -f $n.Pid, $n.Start.ToString('yyyy-MM-dd HH:mm:ss')))) { continue }
            if ($n.Seen -lt $now.AddDays(-1 * $script:WHDFwNamesKeepDays)) { continue }
            $keep.Add($n)
        }
        Save-WHDFwName -Names @($keep.ToArray() | Sort-Object Seen -Descending | Select-Object -First $script:WHDFwNamesMax)
    }
    $appRules = @{}
    foreach ($r in @(Get-NetFirewallRule -Group $script:WHDFwGroupApp -ErrorAction SilentlyContinue)) { $appRules[([string]$r.Name).ToLowerInvariant()] = [string]$r.Enabled }
    $cover = @(); try { $cover = @(Get-WHDAllowListCover) } catch { $cover = @() }
    $order = @{ 'can' = 1; 'allowed-off' = 2; 'allowed' = 3; 'covered' = 3; 'windows' = 4; 'inbound' = 5; 'ended' = 6 }
    $progMax = @{}
    $out = foreach ($g in $groups.Values) {
        $show = @($g.IPs | Select-Object -First 3) -join ', '
        if ($g.IPs.Count -gt 3) { $show += (' (+{0} more)' -f ($g.IPs.Count - 3)) }
        $g.Addresses = $show
        $leaf = if ($g.Program) { Split-Path $g.Program -Leaf } else { '' }
        if ($g.Direction -eq 'Inbound') { $g.State = 'inbound'; $g.StateText = 'no - inbound' }
        elseif (-not $g.Program -and $g.Closed) { $g.State = 'ended'; $g.StateText = 'no - program has closed (start it again, then look again)' }
        elseif (-not $g.Program -or $g.Program -eq 'System' -or $leaf -ieq 'svchost.exe' -or $g.Program -notmatch '^[A-Za-z]:\\') { $g.State = 'windows'; $g.StateText = 'no - Windows service / System' }
        elseif ($g.Protocol -notin @('TCP', 'UDP') -or -not $g.RemotePort -or $g.RemotePort -eq '-') { $g.State = 'windows'; $g.StateText = 'no - not TCP / UDP' }
        else {
            $rn = (Get-WHDProgramAllowName -Program $g.Program -Protocol $g.Protocol -RemotePort $g.RemotePort).ToLowerInvariant()
            if ($appRules.ContainsKey($rn) -and $appRules[$rn] -eq 'True') { $g.State = 'allowed'; $g.StateText = 'allowed already (older lines)' }
            elseif ($appRules.ContainsKey($rn)) { $g.State = 'allowed-off'; $g.StateText = 'allow exists, switched off (gate closed)' }
            elseif (Test-WHDAllowListCover -Cover $cover -Protocol $g.Protocol -Port $g.RemotePort -IPs @($g.IPs)) { $g.State = 'covered'; $g.StateText = 'no need - the allow-list lets this out now (older lines)' }
            else { $g.State = 'can'; $g.StateText = 'yes' }
        }
        $pk = if ($g.Program) { $g.Program.ToLowerInvariant() } else { $g.Exe }
        if (-not $progMax.ContainsKey($pk) -or $g.Count -gt $progMax[$pk]) { $progMax[$pk] = $g.Count }
        $g
    }
    @($out | Sort-Object @{ e = { $order[$_.State] } },
        @{ e = { $progMax[$(if ($_.Program) { $_.Program.ToLowerInvariant() } else { $_.Exe })] }; Descending = $true },
        @{ e = { if ($_.Program) { $_.Program.ToLowerInvariant() } else { $_.Exe } } },
        @{ e = { $_.Count }; Descending = $true })
}

function Show-WHDBlockedConnection {
    # Numbers only for the rows that can be allowed from here; the rest is listed below them.
    [CmdletBinding()]
    param([object[]]$Items)
    if (-not @($Items).Count) { Write-Host '  (no blocked connections recorded in that time - is the firewall log on? menu M)' -ForegroundColor DarkGray; return }
    $fmt = '  {0,3}  {1,6}  {2,-14} {3,-5} {4,-6} {5,-26} {6}'
    $can = @($Items | Where-Object State -eq 'can')
    Write-Host ''
    Write-Host ('  CAN BE ALLOWED ({0}) - that program, that protocol + port, outbound:' -f $can.Count) -ForegroundColor White
    if ($can.Count) {
        Write-Host ($fmt -f '#', 'count', 'last seen', 'prot', 'port', 'program', 'addresses') -ForegroundColor DarkGray
        for ($i = 0; $i -lt $can.Count; $i++) { $b = $can[$i]; Write-Host ($fmt -f ($i + 1), $b.Count, $b.Last.ToString('MM-dd HH:mm:ss'), $b.Protocol, $b.RemotePort, $(if ($b.Closed) { $b.Exe + ' (closed)' } else { $b.Exe }), $b.Addresses) }
    } else { Write-Host '       (nothing)' -ForegroundColor DarkGray }
    $done = @($Items | Where-Object { $_.State -in 'allowed', 'allowed-off', 'covered' })
    if ($done.Count) {
        Write-Host ('  NOTHING TO DO ({0}) - older lines; this traffic gets out now:' -f $done.Count) -ForegroundColor Green
        foreach ($b in $done) { Write-Host ($fmt -f '', $b.Count, $b.Last.ToString('MM-dd HH:mm:ss'), $b.Protocol, $b.RemotePort, $b.Exe, $b.StateText) -ForegroundColor DarkGray }
    }
    $win = @($Items | Where-Object { $_.State -in 'windows', 'inbound' })
    if ($win.Count) {
        Write-Host ('  WINDOWS ITSELF / INBOUND ({0}) - cannot be allowed from here:' -f $win.Count) -ForegroundColor White
        foreach ($b in @($win | Select-Object -First 8)) { Write-Host ($fmt -f '', $b.Count, $b.Last.ToString('MM-dd HH:mm:ss'), $b.Protocol, $b.RemotePort, $b.Exe, $b.Addresses) -ForegroundColor DarkGray }
        if ($win.Count -gt 8) { Write-Host ('       ... and {0} more line(s)' -f ($win.Count - 8)) -ForegroundColor DarkGray }
    }
    $end = @($Items | Where-Object State -eq 'ended')
    if ($end.Count) {
        $endN = ($end | Measure-Object Count -Sum).Sum
        Write-Host ('  PROGRAMS THAT HAVE CLOSED - name not known ({0} blocked connection(s)): {1}' -f $endN, (@($end | Select-Object -First 6 | ForEach-Object { '{0} {1}' -f $_.Protocol, $_.RemotePort }) -join ', ')) -ForegroundColor White
        Write-Host '       Start the program again and open this view while it runs - WHD then remembers its name.' -ForegroundColor DarkGray
    }
}

function Add-WHDProgramAllow {
    # THAT program, THAT protocol + remote port, any destination, outbound only. Windows service
    # traffic (svchost / System) is refused - a program rule for svchost would open every service.
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Items, [switch]$NoAsk)
    $list = @($Items | Where-Object { $_ })
    if (-not $list.Count) { return }
    $ok = [System.Collections.Generic.List[object]]::new()
    foreach ($it in $list) {
        $exe = if ($it.Program) { Split-Path $it.Program -Leaf } else { '' }
        if ($it.Direction -ne 'Outbound') { Write-WHDLog -Message ('not allowed from here: {0} is INBOUND - that would open this PC to the network.' -f $it.Exe) -Level 'WARN'; continue }
        if (-not $it.Program -or $it.Program -eq 'System' -or $exe -ieq 'svchost.exe' -or $it.Program -notmatch '^[A-Za-z]:\\') { Write-WHDLog -Message ('not allowed from here: {0} is Windows service traffic (svchost / System).' -f $it.Exe) -Level 'WARN'; continue }
        if ($it.Protocol -notin @('TCP', 'UDP') -or -not $it.RemotePort) { Write-WHDLog -Message ('not allowed from here: only TCP / UDP with a port ({0} {1}).' -f $it.Protocol, $it.RemotePort) -Level 'WARN'; continue }
        $ok.Add($it)
    }
    if (-not $ok.Count) { return }
    Write-WHDLog -Message ('ALLOW {0} PROGRAM LINE(S) (each: that program, that protocol + port, outbound, any destination):' -f $ok.Count) -Level 'ACT'
    foreach ($it in $ok) { Write-WHDLog -Message ('  {0}  {1} {2}  ({3})' -f $it.Exe, $it.Protocol, $it.RemotePort, $it.Program) }
    Write-WHDRisk -Tier 'caution' -Text 'Only these programs, only these protocols + ports. Removable in the Undo center or with G (remove all program allows).'
    if (-not $NoAsk -and -not (Confirm-WHDProceed -What ('allow the {0} line(s) listed above' -f $ok.Count))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    $gateMode = 'open'
    if (Get-Command -Name Get-WHDGateState -ErrorAction SilentlyContinue) { try { $gateMode = [string](Get-WHDGateState).Mode } catch { $gateMode = 'open' } }
    $appOn = if ($gateMode -eq 'closed') { 'False' } else { 'True' }
    foreach ($it in $ok) {
        if (-not (Test-Path -LiteralPath $it.Program)) { Write-WHDLog -Message ('note: program not found on disk (moved or updated?): {0}' -f $it.Program) -Level 'WARN' }
        $exe = Split-Path $it.Program -Leaf
        $rn = Get-WHDProgramAllowName -Program $it.Program -Protocol $it.Protocol -RemotePort $it.RemotePort
        New-WHDFwRule -Params @{ Name = $rn; DisplayName = ('WHD Next Allow {0} ({1} {2})' -f $exe, $it.Protocol, $it.RemotePort); Group = $script:WHDFwGroupApp
            Direction = 'Outbound'; Action = 'Allow'; Enabled = $appOn; Profile = 'Any'; Program = $it.Program; Protocol = $it.Protocol; RemotePort = $it.RemotePort } -Journal @{ Kind = 'fwrule'; RuleName = $rn }
    }
    if ($gateMode -eq 'closed') {
        if (Test-WHDRealChange) { Add-WHDGateRemembered -Names @($ok | ForEach-Object { Get-WHDProgramAllowName -Program $_.Program -Protocol $_.Protocol -RemotePort $_.RemotePort }) }
        Write-WHDLog -Message 'The update gate is closed: the allows are stored switched OFF; they work once the gate is set to programs or open.' -Level 'WARN'
    }
    Sync-WHDBlocklist -AfterChange
}

function Invoke-WHDBlockedView {
    # Menu V: view, then allow one or several rows (1,3 or 1-3).
    [CmdletBinding()]
    param([string[]]$Answer)
    $h = (Read-WHDMenuAnswer -Answer $Answer -Prompt '  Hours to look back [24]').Trim()
    if ($h -notmatch '^\d{1,4}$' -or [int]$h -lt 1) { $h = '24' }
    $items = @(Get-WHDBlockedConnection -Hours ([int]$h))
    Show-WHDBlockedConnection -Items $items
    $can = @($items | Where-Object State -eq 'can')
    if (-not $can.Count) { return }
    $pick = (Read-WHDMenuAnswer -Answer @($Answer | Select-Object -Skip 1) -Prompt '  Numbers to allow (e.g. 1,3 or 1-3), Enter = back').Trim()
    if (-not $pick) { return }
    $sel = ConvertFrom-WHDSelection -Text $pick -Max $can.Count
    if (-not $sel) { Write-Host '  invalid.' -ForegroundColor Yellow; return }
    Add-WHDProgramAllow -Items @($sel | ForEach-Object { $can[$_ - 1] })
}

function Remove-WHDProgramAllow {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-WHDLog -Message 'REMOVE all per-program allow rules (group WinHardenDebloatNext-AppAllow)' -Level 'ACT'
    if (-not (Confirm-WHDProceed -What 'remove all per-program allow rules')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    if (-not $PSCmdlet.ShouldProcess($script:WHDFwGroupApp, 'remove rules')) { return }
    Remove-WHDFwGroup -Group $script:WHDFwGroupApp
    Sync-WHDBlocklist -AfterChange
}

# =====================================================================================
#  9) TIME SYNC  (time.cloudflare.com over NTP, UDP 123 pinned; as in WHD Next 2.0)
#  Windows Time speaks NTP only. Flag 0x8 = client mode on Windows' normal poll interval.
#  T also: service Automatic (no delay), Windows' own start triggers off (Microsoft Learn,
#  "W32Time doesn't start on a workgroup computer", Method 1 - a copy is saved first), and the
#  automatic time-jump limit 1 h (Windows default 15 h; Microsoft Learn: stand-alone clients
#  3600 or smaller). N puts the server, the triggers and the limits back to Windows defaults.
# =====================================================================================
$script:WHDW32TimeCfgKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config'
$script:WHDW32TimeTriggerBak = 'W32Time-TriggerInfo.reg'
$script:WHDTimeJumpLimit = 3600
$script:WHDTimeJumpDefault = 54000

function ConvertTo-WHDSecText {
    [CmdletBinding()]
    [OutputType([string])]
    param([int64]$Sec)
    if ($Sec -lt 0 -or $Sec -eq 4294967295) { return 'no limit' }
    if ($Sec -ge 3600 -and $Sec % 3600 -eq 0) { return ('{0} h' -f ($Sec / 3600)) }
    if ($Sec -ge 60 -and $Sec % 60 -eq 0) { return ('{0} min' -f ($Sec / 60)) }
    return ('{0} s' -f $Sec)
}

function Get-WHDTimeJumpState {
    [CmdletBinding()]
    param()
    $pv = $script:WHDTimeJumpDefault; $nv = $script:WHDTimeJumpDefault
    $p = Get-WHDRegValueState -Path $script:WHDW32TimeCfgKey -Name 'MaxPosPhaseCorrection'
    $n = Get-WHDRegValueState -Path $script:WHDW32TimeCfgKey -Name 'MaxNegPhaseCorrection'
    $t = Get-WHDRegValueState -Path $script:WHDW32TimeCfgKey -Name 'UtilizeSslTimeData'
    if ($p.Exists) { $pv = [int64]([uint32]([int64]$p.Value -band 0xFFFFFFFFL)) }
    if ($n.Exists) { $nv = [int64]([uint32]([int64]$n.Value -band 0xFFFFFFFFL)) }
    $seed = if ($t.Exists) { [int]$t.Value -ne 0 } else { $true }
    [pscustomobject]@{ Pos = $pv; Neg = $nv; Seeding = $seed
        Limited = ($pv -le $script:WHDTimeJumpLimit -and $nv -le $script:WHDTimeJumpLimit)
        Text = $(if ($pv -eq $nv) { '+/- ' + (ConvertTo-WHDSecText -Sec $pv) } else { '+' + (ConvertTo-WHDSecText -Sec $pv) + ' / -' + (ConvertTo-WHDSecText -Sec $nv) }) }
}

function Set-WHDTimeJumpLimit {
    # Journaled registry values (kind reg: automatic undo + Verify); only values that differ are written.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][int]$Seconds, [switch]$RestoreSeeding)
    if (-not $PSCmdlet.ShouldProcess($script:WHDW32TimeCfgKey, 'time-jump limit')) { return }
    foreach ($nm in 'MaxPosPhaseCorrection', 'MaxNegPhaseCorrection') {
        $cur = Get-WHDRegValueState -Path $script:WHDW32TimeCfgKey -Name $nm
        if ($cur.Exists -and (Test-WHDRegValueEqual -A $cur.Value -B $Seconds -Type 'DWord')) { continue }
        Set-WHDRegistryValue -Path $script:WHDW32TimeCfgKey -Name $nm -Value $Seconds -Type 'DWord' | Out-Null
    }
    if ($RestoreSeeding) {
        $t = Get-WHDRegValueState -Path $script:WHDW32TimeCfgKey -Name 'UtilizeSslTimeData'
        if ($t.Exists -and [int]$t.Value -ne 1) { Set-WHDRegistryValue -Path $script:WHDW32TimeCfgKey -Name 'UtilizeSslTimeData' -Value 1 -Type 'DWord' | Out-Null }
    }
}

function Get-WHDTimeJumpEvent {
    # Refused corrections (System log, Time-Service event 34).
    [CmdletBinding()]
    [OutputType([System.Array])]
    param([datetime]$Since = (Get-Date).AddDays(-7))
    @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Time-Service'; Id = 34; StartTime = $Since } -ErrorAction SilentlyContinue |
        ForEach-Object { [pscustomobject]@{ Time = $_.TimeCreated; Message = (([string]$_.Message -split "`r?`n")[0]).Trim() } })
}

function Get-WHDTimeTriggerBackup {
    # Newest saved copy of the triggers in this PC's change history (restore\<session>\W32Time-TriggerInfo.reg).
    [CmdletBinding()]
    [OutputType([string])]
    param()
    foreach ($hs in @(Get-WHDHistorySession)) {
        $f = Join-Path $hs.Path $script:WHDW32TimeTriggerBak
        if (Test-Path -LiteralPath $f) { return $f }
    }
    return $null
}

function Remove-WHDTimeTrigger {
    # sc triggerinfo w32time delete - after the registry key that holds them is exported to restore\.
    # Kind svctrigger (Undo center: automatic; Verify: still off?). Returns the gate status or 'present'.
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param()
    $ts = Get-WHDTimeTriggerState
    if (-not $ts.Active -and -not $ts.Saved) { Write-WHDLog -Message 'Windows Time service: no start triggers on it - nothing to take off.'; return 'present' }
    if (-not $PSCmdlet.ShouldProcess('W32Time', 'remove start triggers')) { return 'skipped' }
    $tn = [Math]::Max($ts.Active, $ts.Saved)
    $tBak = Join-Path (Get-WHDRestoreFolder) $script:WHDW32TimeTriggerBak
    $tKey = $script:WHDW32TimeTriggerKey
    $jr = @{ Kind = 'svctrigger'; Service = 'W32Time'; NewState = 'off'; Backup = $tBak; OldCount = $tn; OldTriggers = @($ts.Lines) }
    $tr = Invoke-WHDChange -Description ('Windows Time service: take Windows'' own start triggers off ({0}; a copy is saved first)' -f $tn) -Journal $jr -Action {
        if (-not (Test-Path -LiteralPath $tKey)) { throw 'the registry key with the triggers was not found, so no copy can be saved - the triggers are left as they are' }
        $td = Split-Path $tBak -Parent; if (-not (Test-Path -LiteralPath $td)) { [void](New-Item -ItemType Directory -Path $td -Force) }
        $x = Invoke-WHDNative -Exe 'reg.exe' -ArgList @('export', ($tKey -replace '^HKLM:\\', 'HKLM\'), $tBak, '/y')
        $kept = 0
        if (Test-Path -LiteralPath $tBak) { $kept = @(Get-Content -LiteralPath $tBak -ErrorAction SilentlyContinue | Where-Object { $_ -match '\\TriggerInfo\\[^\]]+\]\s*$' }).Count }
        if ($x.Code -ne 0 -or $kept -lt 1) { throw ('no copy of the triggers could be saved (reg export exit {0}, {1} trigger(s) in the file) - they are left as they are' -f $x.Code, $kept) }
        $d = Invoke-WHDNative -Exe 'sc.exe' -ArgList @('triggerinfo', 'w32time', 'delete')
        if ($d.Code -ne 0) { throw ('sc triggerinfo w32time delete exit {0}: {1}' -f $d.Code, (($d.Out | Where-Object { $_ }) -join ' ')) }
        $after = Get-WHDTimeTriggerState
        # put back earlier and Windows not restarted since: none in use, the registry copy has to go too
        if (-not $after.Active -and $after.Saved) { Remove-Item -LiteralPath $tKey -Recurse -Force -ErrorAction Stop; $after = Get-WHDTimeTriggerState }
        if ($after.Active -or $after.Saved) { throw ('read-back mismatch: {0} trigger(s) still in use, {1} still in the registry' -f $after.Active, $after.Saved) }
    }
    return [string]$tr.Status
}

function Restore-WHDTimeTrigger {
    # reg import of the saved copy; Windows reads it at its next start-up. Returns the gate status, 'present' or 'nobackup'.
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param([string]$Backup, [switch]$NoBackupIsFine)
    $ts = Get-WHDTimeTriggerState
    if ($ts.Active) { Write-WHDLog -Message ('Windows Time service: its {0} start trigger(s) are in place - nothing to put back.' -f $ts.Active); return 'present' }
    if ($ts.Saved) { Write-WHDLog -Message ('Windows Time service: {0} start trigger(s) are back in the registry already - they count again after a restart.' -f $ts.Saved); return 'present' }
    if (-not $Backup -or -not (Test-Path -LiteralPath $Backup)) { $Backup = Get-WHDTimeTriggerBackup }
    if (-not $Backup) {
        Write-WHDLog -Message 'Windows Time service: no start triggers and no saved copy in WHD''s change history - nothing put back. By hand (administrator): sc triggerinfo w32time start/domainjoin' -Level $(if ($NoBackupIsFine) { 'INFO' } else { 'WARN' })
        return 'nobackup'
    }
    if (-not $PSCmdlet.ShouldProcess('W32Time', 'restore start triggers')) { return 'skipped' }
    $rBak = $Backup
    $rr = Invoke-WHDChange -Description ('Windows Time service: put Windows'' own start triggers back from {0}' -f $rBak) -Journal @{ Kind = 'svctrigger'; Service = 'W32Time'; NewState = 'on'; Backup = $rBak } -Action {
        $i = Invoke-WHDNative -Exe 'reg.exe' -ArgList @('import', $rBak)
        if ($i.Code -ne 0) { throw ('reg import exit {0}: {1}' -f $i.Code, (($i.Out | Where-Object { $_ }) -join ' ')) }
        $after = Get-WHDTimeTriggerState
        if (-not $after.Active -and -not $after.Saved) { throw 'read-back mismatch: the triggers are not in the registry' }
    }
    if ([string]$rr.Status -eq 'done') { Write-WHDLog -Message '  The triggers are back in the registry. Restart the PC for them to count.' -Level 'WARN' }
    return [string]$rr.Status
}

function Invoke-WHDSetTimeSync {
    [CmdletBinding()]
    param([ValidateSet('Cloudflare', 'Windows')][string]$Mode = 'Cloudflare')
    if ($Mode -eq 'Cloudflare') {
        $peer = '{0},0x8' -f $script:WHDNtpServer; $raddr = $script:WHDNtpIPs
        Write-WHDLog -Message ('TIME SYNC -> {0} (NTP; firewall UDP 123 pinned to {1})' -f $script:WHDNtpServer, ($raddr -join ', ')) -Level 'ACT'
        Write-WHDRisk -Tier 'reversible' -Text ('Time server + the NTP allow rule; automatic time jumps limited to {0} (Windows default 15 h - a bigger correction is refused and logged; then set the clock by hand once). Windows Time set to Automatic and Windows'' own start triggers taken off it (one is named DOMAIN JOINED - the PC is NOT joined to a domain by it); a copy is saved first. All recorded: Undo center or N puts it back.' -f (ConvertTo-WHDSecText -Sec $script:WHDTimeJumpLimit))
    } else {
        $peer = 'time.windows.com,0x9'; $raddr = $null
        Write-WHDLog -Message 'TIME SYNC -> Windows default (time.windows.com); firewall UDP 123 open to any' -Level 'ACT'
        Write-WHDRisk -Tier 'reversible' -Text 'Time server + the NTP allow rule; time-jump limit (15 h) and Secure Time Seeding back to Windows defaults; saved start triggers put back (they count after a restart). The service start type stays. All recorded.'
    }
    if (-not (Confirm-WHDProceed -What ('set the time source to {0}' -f $peer))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    foreach ($kv in @(@('NtpServer', $peer), @('Type', 'NTP'))) {
        $cur = Get-WHDRegValueState -Path $script:WHDW32TimeKey -Name $kv[0]
        if ($cur.Exists -and [string]$cur.Value -eq $kv[1]) { Write-WHDLog -Message ('  {0} already {1}' -f $kv[0], $kv[1]); continue }
        Set-WHDRegistryValue -Path $script:WHDW32TimeKey -Name $kv[0] -Value $kv[1] -Type 'String' | Out-Null
    }
    $np = @{ Name = 'WHDN-Allow-NTP'; Group = $script:WHDFwGroupAllow; Direction = 'Outbound'; Action = 'Allow'; Enabled = 'True'; Profile = 'Any'; Protocol = 'UDP'; RemotePort = 123 }
    if ($raddr) { $np['RemoteAddress'] = $raddr; $np['DisplayName'] = 'WHD Next Allow NTP (UDP 123, time.cloudflare.com)' } else { $np['DisplayName'] = 'WHD Next Allow NTP (UDP 123)' }
    New-WHDFwRule -Params $np
    if ($Mode -eq 'Cloudflare') {
        $svc = Get-Service -Name 'W32Time' -ErrorAction SilentlyContinue
        if (-not $svc) { Write-WHDLog -Message 'Windows Time service (W32Time) not found.' -Level 'ERR' }
        elseif ([string]$svc.StartType -ne 'Automatic') { Set-WHDServiceStartType -Service 'W32Time' -StartType 'Automatic' | Out-Null }
        else { Write-WHDLog -Message '  Windows Time service already Automatic.' }
        [void](Remove-WHDTimeTrigger)
        Set-WHDTimeJumpLimit -Seconds $script:WHDTimeJumpLimit
    } else {
        [void](Restore-WHDTimeTrigger -NoBackupIsFine)
        Set-WHDTimeJumpLimit -Seconds $script:WHDTimeJumpDefault -RestoreSeeding
    }
    Invoke-WHDChange -Description 'apply the time settings (w32tm /config /update) and resync' -Action {
        if ([string](Get-Service -Name 'W32Time' -ErrorAction Stop).Status -ne 'Running') { Start-Service -Name 'W32Time' -ErrorAction Stop }
        $u = Invoke-WHDNative -Exe 'w32tm.exe' -ArgList @('/config', '/update')
        if ($u.Code -ne 0) { throw ('w32tm /config /update exit {0}: {1}' -f $u.Code, ($u.Out -join ' ')) }
        $rs = Invoke-WHDNative -Exe 'w32tm.exe' -ArgList @('/resync', '/rediscover')
        if ($rs.Code -ne 0) { Write-WHDLog -Message ('resync not completed yet ({0}) - Windows retries on its own schedule.' -f (($rs.Out | Where-Object { $_ }) -join ' ')) -Level 'WARN' }
    } | Out-Null
    Show-WHDTimeStatus
}

function Show-WHDTimeStatus {
    # Read-only (TS). Every line goes to the log too.
    [CmdletBinding()]
    param()
    $st = Get-WHDRegValueState -Path $script:WHDW32TimeKey -Name 'NtpServer'
    Write-WHDLog -Message ('Time server setting : {0}' -f $(if ($st.Exists) { $st.Value } else { '(not set)' }))
    $tj = Get-WHDTimeJumpState
    Write-WHDLog -Message ('Time-jump limit     : {0}  (Windows default +/- 15 h; WHD target {1})' -f $tj.Text, (ConvertTo-WHDSecText -Sec $script:WHDTimeJumpLimit)) -Level $(if ($tj.Limited) { 'OK' } else { 'INFO' })
    Write-WHDLog -Message ('Secure Time Seeding : {0}' -f $(if ($tj.Seeding) { 'on (Windows default)' } else { 'off' }))
    $ev = @(Get-WHDTimeJumpEvent)
    if ($ev.Count) { foreach ($e in $ev) { Write-WHDLog -Message ('  REFUSED jump {0:yyyy-MM-dd HH:mm}: {1}' -f $e.Time, $e.Message) -Level 'WARN' } }
    else { Write-WHDLog -Message '  refused time jumps (7 days): none' }
    $svc = Get-Service -Name 'W32Time' -ErrorAction SilentlyContinue
    if ($svc) {
        Write-WHDLog -Message ('Windows Time service: {0}, start type {1}' -f $svc.Status, $svc.StartType) -Level $(if ([string]$svc.Status -eq 'Running') { 'OK' } else { 'WARN' })
        try { $boot = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime; Write-WHDLog -Message ('  PC up for            : {0:N0} min (since {1})' -f ((Get-Date) - $boot).TotalMinutes, $boot.ToString('HH:mm')) } catch { Write-Verbose 'uptime unreadable' }
        $tts = Get-WHDTimeTriggerState
        if ($tts.Active) {
            Write-WHDLog -Message ('  start triggers       : {0}, Windows'' own - the PC is not joined to a domain by them; T takes them off' -f $tts.Active)
            foreach ($l in $tts.Lines) { Write-WHDLog -Message ('    trigger: {0}' -f $l) }
        } elseif ($tts.Saved) { Write-WHDLog -Message ('  start triggers       : none in use now; {0} back in the registry (count after a restart)' -f $tts.Saved) }
        else { Write-WHDLog -Message '  start triggers       : none - the service starts with Windows, not on a trigger' -Level 'OK' }
    }
    $src = Invoke-WHDNative -Exe 'w32tm.exe' -ArgList @('/query', '/source')
    Write-WHDLog -Message ('Source in use       : {0}' -f (($src.Out | Where-Object { $_.Trim() }) -join ' '))
    $q = Invoke-WHDNative -Exe 'w32tm.exe' -ArgList @('/query', '/status')
    foreach ($l in @($q.Out)) { if ($l -match '^(Last Successful Sync Time|Poll Interval|Stratum|Leap Indicator):') { Write-WHDLog -Message ('  {0}' -f $l.Trim()) } }
    $sc = Invoke-WHDNative -Exe 'w32tm.exe' -ArgList @('/stripchart', ('/computer:{0}' -f $script:WHDNtpServer), '/samples:2', '/dataonly')
    $samples = @($sc.Out | Where-Object { $_ -match '^\d{1,2}:\d{2}:\d{2}' })
    if ($samples.Count) { foreach ($l in $samples) { Write-WHDLog -Message ('  reach {0}: {1}' -f $script:WHDNtpServer, $l.Trim()) } }
    else { Write-WHDLog -Message ('  reach {0}: no answer ({1})' -f $script:WHDNtpServer, (@($sc.Out | Where-Object { $_ }) | Select-Object -Last 1)) -Level 'WARN' }
    $rule = @(Get-NetFirewallRule -Name 'WHDN-Allow-NTP' -ErrorAction SilentlyContinue)
    if ($rule.Count) { Write-WHDLog -Message ('Firewall NTP allow  : UDP 123 -> {0}' -f (@(($rule[0] | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue).RemoteAddress) -join ', ')) }
    else { Write-WHDLog -Message 'Firewall NTP allow  : (no WHDN-Allow-NTP rule - fine while outbound is default-allow)' }
}

# =====================================================================================
#  10) OFFLINE BLOCK-LIST REFRESH  (F; files in profiles\incoming\)
#  Understood per line: plain IP / CIDR, Spamhaus DROP classic "1.2.3.0/24 ; SBL1",
#  Spamhaus DROP json {"cidr":...}, DShield "start <tab> end <tab> prefix". Every entry is
#  normalized, de-duplicated and passed through the never-block guard. Preview first, then
#  merge or replace; the old list is backed up and the change is recorded (kind file).
# =====================================================================================
function ConvertTo-WHDCidrString {
    [CmdletBinding()]
    [OutputType([string])]
    param([uint64]$Start, [uint64]$End)
    $len = 32 - [int][math]::Round([math]::Log([double]($End - $Start + 1), 2))
    $b = [BitConverter]::GetBytes([uint32]$Start); [Array]::Reverse($b)
    '{0}.{1}.{2}.{3}/{4}' -f $b[0], $b[1], $b[2], $b[3], $len
}

function Read-WHDBlocklistFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $res = [ordered]@{ Ranges = [System.Collections.Generic.List[object]]::new(); IPv6 = 0; Unreadable = 0; Guarded = 0; Lines = 0 }
    $ipv4 = '^\d{1,3}(\.\d{1,3}){3}$'
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#') -or $t.StartsWith(';') -or $t.StartsWith('//')) { continue }
        $res.Lines++
        $cand = $null
        if ($t.StartsWith('{')) {
            $j = $null; try { $j = $t | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $res.Unreadable++; continue }
            if (-not $j['cidr']) { $res.Lines--; continue }       # metadata line
            $cand = [string]$j['cidr']
        } else {
            $tok = @((($t -split '[;#]')[0].Trim()) -split '[\s,]+' | Where-Object { $_ })
            if (-not $tok.Count) { $res.Unreadable++; continue }
            if ($tok.Count -ge 3 -and $tok[0] -match $ipv4 -and $tok[1] -match $ipv4 -and $tok[2] -match '^\d{1,2}$') { $cand = '{0}/{1}' -f $tok[0], $tok[2] }
            else { $cand = $tok[0] }
        }
        if ($cand -match ':') { $res.IPv6++; continue }
        $rng = ConvertTo-WHDIpRange -Cidr $cand
        if (-not $rng) { $res.Unreadable++; continue }
        if (Test-WHDNeverBlock -Cidr $cand) { $res.Guarded++; continue }
        $res.Ranges.Add([pscustomobject]@{ Start = [uint64]$rng[0]; End = [uint64]$rng[1] })
    }
    [pscustomobject]$res
}

function Compress-WHDRange {
    # Sorted; duplicates and ranges inside a bigger one dropped (pure).
    [CmdletBinding()]
    [OutputType([object[]])]
    param([AllowEmptyCollection()][object[]]$Ranges)
    $out = [System.Collections.Generic.List[object]]::new()
    $lastEnd = -1.0
    foreach ($r in @($Ranges | Sort-Object @{ e = { $_.Start } }, @{ e = { $_.End }; Descending = $true })) {
        if ([double]$r.End -le $lastEnd) { continue }
        $out.Add($r); $lastEnd = [double]$r.End
    }
    return $out.ToArray()
}

function Get-WHDIncomingFolder {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $inc = Join-Path (Get-WHDProfileFolder) 'incoming'
    if (-not (Test-Path -LiteralPath $inc)) {
        [void](New-Item -ItemType Directory -Path $inc -Force)
        @('Put IP block-list files here (downloaded on any machine, copied over offline).',
          'Understood: plain IP / CIDR per line, Spamhaus DROP (classic or drop_v4.json), DShield block.txt.',
          'Then: Firewall menu F. Used files move to incoming\done\<session>\ so nothing is used twice.',
          'IPv6 entries are skipped; private, multicast, broadcast and reserved ranges are always skipped.') | Set-Content -LiteralPath (Join-Path $inc 'README.txt') -Encoding ascii
    }
    return $inc
}

function Invoke-WHDBlocklistRefresh {
    # -Mode Preview (read-only) | Merge | Replace. Returns a summary object.
    [CmdletBinding()]
    param([ValidateSet('Preview', 'Merge', 'Replace')][string]$Mode = 'Preview')
    $inc = Get-WHDIncomingFolder
    $files = @(Get-ChildItem -LiteralPath $inc -File -ErrorAction SilentlyContinue | Where-Object Name -ne 'README.txt')
    Write-WHDLog -Message ('BLOCK-LIST REFRESH ({0}) - {1} file(s) in {2}' -f $Mode, $files.Count, $inc) -Level 'ACT'
    if (-not $files.Count) { Write-WHDLog -Message 'Nothing to do: copy list files into profiles\incoming first (see README.txt there).' -Level 'WARN'; return $null }
    $new = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $files) {
        $r = Read-WHDBlocklistFile -Path $f.FullName
        $new.AddRange([object[]]$r.Ranges.ToArray())
        Write-WHDLog -Message ('  {0}: {1} usable, {2} IPv6 skipped, {3} unreadable, {4} unsafe (guarded)' -f $f.Name, $r.Ranges.Count, $r.IPv6, $r.Unreadable, $r.Guarded)
    }
    $target = Get-WHDBlocklistDefaultFile
    $cur = @()
    if (Test-Path -LiteralPath $target) {
        try { $curRead = Read-WHDBlocklistFile -Path $target; $cur = $curRead.Ranges.ToArray() }
        catch { Write-WHDLog -Message ('could not read the current list ({0}) - refresh stopped, nothing changed.' -f $_.Exception.Message) -Level 'ERR'; return $null }
        if ($curRead.Lines -gt 0 -and -not $cur.Count) { Write-WHDLog -Message 'the current list has entries but none could be read - refresh stopped, nothing changed.' -Level 'ERR'; return $null }
    }
    $newSet = @(Compress-WHDRange -Ranges $new.ToArray()); $curSet = @(Compress-WHDRange -Ranges $cur)
    $curKeys = @{}; foreach ($r in $curSet) { $curKeys['{0}-{1}' -f $r.Start, $r.End] = $true }
    $newKeys = @{}; foreach ($r in $newSet) { $newKeys['{0}-{1}' -f $r.Start, $r.End] = $true }
    $added = @($newSet | Where-Object { -not $curKeys.ContainsKey(('{0}-{1}' -f $_.Start, $_.End)) })
    $removed = @($curSet | Where-Object { -not $newKeys.ContainsKey(('{0}-{1}' -f $_.Start, $_.End)) })
    $merged = @(Compress-WHDRange -Ranges (@($curSet) + @($newSet)))
    $sum = [pscustomobject]@{ Files = $files.Count; Current = $curSet.Count; Incoming = $newSet.Count; Added = $added.Count; Removed = $removed.Count; MergeTotal = $merged.Count; ReplaceTotal = $newSet.Count }
    Write-WHDLog -Message ('Current list: {0} ranges   Incoming: {1} ranges' -f $sum.Current, $sum.Incoming)
    Write-WHDLog -Message ('  new ranges not in the current list ... {0}' -f $sum.Added)
    Write-WHDLog -Message ('  current ranges not in incoming ....... {0}' -f $sum.Removed)
    Write-WHDLog -Message ('  MERGE   -> {0} ranges (keeps everything, adds the new)' -f $sum.MergeTotal)
    Write-WHDLog -Message ('  REPLACE -> {0} ranges (incoming files become the whole list)' -f $sum.ReplaceTotal)
    foreach ($a in @($added | Select-Object -First 5)) { Write-WHDLog -Message ('    + {0}' -f (ConvertTo-WHDCidrString -Start $a.Start -End $a.End)) }
    foreach ($a in @($removed | Select-Object -First 5)) { Write-WHDLog -Message ('    - {0}' -f (ConvertTo-WHDCidrString -Start $a.Start -End $a.End)) }
    if ($Mode -eq 'Preview') { return $sum }
    $final = @(if ($Mode -eq 'Merge') { $merged } else { $newSet })
    if (-not $final.Count) { Write-WHDLog -Message 'The result would be an EMPTY list - refused.' -Level 'ERR'; return $sum }
    if (-not (Confirm-WHDProceed -What ('{0} the block-list file -> {1} ranges' -f $Mode.ToLowerInvariant(), $final.Count))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return $sum }
    $addrs = [uint64]0; foreach ($r in $final) { $addrs += ($r.End - $r.Start + 1) }
    $lines = @('# WHD Next - IP block list (offline). Refreshed by the Firewall menu F.',
        ('# {0} on {1} from: {2}' -f $Mode, (Get-Date -Format 'yyyy-MM-dd HH:mm'), (($files | ForEach-Object Name) -join ', ')),
        '# Safety-checked: no broadcast / multicast / private / reserved / CGNAT / loopback ranges.',
        ('# {0} ranges / {1:N0} addresses. Applied as block rules where the firewall is wide open.' -f $final.Count, $addrs), '#') +
        @($final | ForEach-Object { ConvertTo-WHDCidrString -Start $_.Start -End $_.End })
    if (-not (Test-WHDRealChange)) { Write-WHDLog -Message ('would: back up and rewrite {0} with {1} ranges; move {2} file(s) to incoming\done' -f $target, $final.Count, $files.Count) -Level 'DRY'; return $sum }
    $rf = Get-WHDRestoreFolder; if (-not (Test-Path -LiteralPath $rf)) { [void](New-Item -ItemType Directory -Path $rf -Force) }
    $tag = Get-Date -Format 'HHmmss'
    $tmp = Join-Path $rf ('blacklist-ip.new.{0}.txt' -f $tag); $bkp = Join-Path $rf ('blacklist-ip.before.{0}.txt' -f $tag)
    Set-Content -LiteralPath $tmp -Value $lines -Encoding ascii
    $hash = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
    $doneDir = Join-Path (Join-Path $inc 'done') $script:WHDState.Stamp
    $rfTarget = $target; $rfFiles = $files
    Invoke-WHDChange -Description ('{0} block list: {1} ranges (was {2}); old list backed up' -f $Mode.ToLowerInvariant(), $final.Count, $sum.Current) -Journal @{ Kind = 'file'; Path = $target; Backup = $bkp; NewHash = $hash } -Action {
        if (Test-Path -LiteralPath $rfTarget) { Copy-Item -LiteralPath $rfTarget -Destination $bkp -Force -ErrorAction Stop } else { Set-Content -LiteralPath $bkp -Value '# (no previous list)' -Encoding ascii }
        Copy-Item -LiteralPath $tmp -Destination $rfTarget -Force -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $doneDir)) { [void](New-Item -ItemType Directory -Path $doneDir -Force) }
        foreach ($f in $rfFiles) { Move-Item -LiteralPath $f.FullName -Destination (Join-Path $doneDir $f.Name) -Force -ErrorAction Stop }
    } | Out-Null
    return $sum
}

function Update-WHDBlocklistRule {
    # Rebuild = apply by hand from profiles\blacklist-ip.txt (only the directions the firewall needs).
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not $PSCmdlet.ShouldProcess('IP block rules', 'rebuild')) { return }
    Write-WHDLog -Message 'REBUILD the IP block rules from profiles\blacklist-ip.txt' -Level 'ACT'
    if (-not (Confirm-WHDProceed -What 'rebuild the IP block rules now')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    Invoke-WHDBlocklistApply -Path (Get-WHDBlocklistDefaultFile)
}

# =====================================================================================
#  MENU
# =====================================================================================
function Show-WHDFirewallMenu {
    [CmdletBinding()]
    param()
    Write-Host ''
    Write-Host '  =============== Windows Firewall ===============' -ForegroundColor White
    Show-WHDFirewallSummary
    Write-Host ''
    Write-Host '  IPv6' -ForegroundColor DarkGray
    Write-WHDMenuItem -Key '1' -Label 'Suppress IPv6 (keep ::1 loopback)'
    Write-WHDMenuItem -Key '2' -Label 'Suppress IPv6 + block ::1 loopback' -Hint '[strict]'
    Write-WHDMenuItem -Key '3' -Label 'Re-enable IPv6'
    Write-Host '  Rules' -ForegroundColor DarkGray
    Write-WHDMenuItem -Key '4' -Label 'List rules (detailed)'
    Write-WHDMenuItem -Key 'L' -Label 'List custom rules only'
    Write-Host '  DNS' -ForegroundColor DarkGray
    Write-WHDMenuItem -Key 'D' -Label 'Set Cloudflare 1.1.1.2 + encrypted DoH'
    Write-WHDMenuItem -Key 'U' -Label 'Reset DNS to automatic (DHCP)'
    Write-Host '  Outbound / strict mode, blacklist' -ForegroundColor DarkGray
    Write-WHDMenuItem -Key '5' -Label 'Apply outbound allow-list' -Hint '(harmless while outbound is Allow)'
    Write-WHDMenuItem -Key '6' -Label 'Enable default-deny outbound' -Hint '[strict, auto-rollback]'
    Write-WHDMenuItem -Key '7' -Label 'Confirm keep default-deny' -Hint $(if (Get-WHDRollbackTask) { '(rollback task is waiting)' } else { '' })
    Write-WHDMenuItem -Key '8' -Label 'Revert default-deny (outbound Allow)'
    Write-WHDMenuItem -Key '9' -Label 'Block IP list: apply / bring in line'
    Write-WHDMenuItem -Key 'H' -Label 'Hosts sinkhole (domain list)'
    Write-WHDMenuItem -Key 'C' -Label 'Clear blacklist (IP rules + hosts block)'
    Write-WHDMenuItem -Key 'A' -Label 'Apply firewall profile' -Hint '(profiles\firewall-baseline.json)'
    Write-Host '  Blocked connections, time sync, block-list refresh' -ForegroundColor DarkGray
    Write-WHDMenuItem -Key 'M' -Label 'Turn ON the Windows Firewall log' -Hint '(dropped + allowed, 32,767 KB)'
    Write-WHDMenuItem -Key 'O' -Label 'Turn OFF the Windows Firewall log'
    Write-WHDMenuItem -Key 'V' -Label 'View blocked connections / allow a program'
    Write-WHDMenuItem -Key 'G' -Label 'Remove all per-program allows'
    Write-WHDMenuItem -Key 'T' -Label 'Use time.cloudflare.com' -Hint '(NTP pinned, 1 h jump limit)'
    Write-WHDMenuItem -Key 'N' -Label 'Use Windows default time server'
    Write-WHDMenuItem -Key 'TS' -Label 'Time + logging status'
    Write-WHDMenuItem -Key 'Z' -Label 'Time zone / date and time (opens the TimeRegion menu)'
    Write-WHDMenuItem -Key 'F' -Label 'Refresh block list from files' -Hint '(profiles\incoming)'
    Write-Host '  Policy files' -ForegroundColor DarkGray
    Write-WHDMenuItem -Key 'E' -Label 'Export policy (json + .wfw)' -Hint '(was X in WHD Next 2.0)'
    Write-WHDMenuItem -Key 'I' -Label 'Import policy'
    Write-WHDMenuItem -Key 'R' -Label 'Reset to Windows defaults'
    Write-WHDMenuItem -Key 'W' -Label 'Wipe all rules (empty slate)'
    Write-WHDMenuCommonKey
}

function Read-WHDMenuAnswer {
    # A follow-up question in a menu; -Answer (tests, scripted runs) answers without asking.
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Prompt, [string[]]$Answer)
    if ($null -ne $Answer -and $Answer.Count) { return [string]$Answer[0] }
    return [string](Read-Host $Prompt)
}

function Invoke-WHDFirewallChoice {
    # One menu choice. Returns $false for B (back). -Answer feeds the follow-up questions (tests).
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Choice, [string[]]$Answer)
    $c = $Choice.Trim()
    if (Invoke-WHDMenuCommonKey -Choice $c) { return $true }
    switch -regex ($c) {
        '^1$' { Invoke-WHDDisableIPv6 }
        '^2$' { Invoke-WHDDisableIPv6 -BlockLoopback }
        '^3$' { Invoke-WHDEnableIPv6 }
        '^4$' { Get-WHDFirewallRule -Detail | Format-Table Dir, Action, Enabled, Protocol, LocalPort, RemotePort, DisplayName -AutoSize -Wrap | Out-Host }
        '^[Ll]$' { Get-WHDFirewallRule -CustomOnly -Detail | Format-Table Dir, Action, Enabled, Protocol, LocalPort, RemotePort, DisplayName -AutoSize -Wrap | Out-Host }
        '^[Ee]$' { $f = (Read-WHDMenuAnswer -Answer $Answer -Prompt '  Export base path [blank = restore\<session>\firewall-policy]').Trim(); if ($f) { Export-WHDFirewallPolicy -Path $f } else { Export-WHDFirewallPolicy } }
        '^[Ii]$' { $f = (Read-WHDMenuAnswer -Answer $Answer -Prompt '  Import file (.json or .wfw), blank to cancel').Trim(); if ($f) { Import-WHDFirewallPolicy -Path $f -Mode $(if ($f -match '\.wfw$') { 'Wfw' } else { 'Json' }) } }
        '^[Rr]$' { Invoke-WHDFirewallReset }
        '^[Ww]$' { $yn = (Read-WHDMenuAnswer -Answer $Answer -Prompt '  Apply the WHD baseline right after wiping? [y/N]').Trim(); if ($yn -match '^[Yy]') { Invoke-WHDFirewallWipe -ApplyBaseline } else { Invoke-WHDFirewallWipe } }
        '^[Dd]$' { Invoke-WHDSetDns -Mode Cloudflare }
        '^[Uu]$' { Invoke-WHDSetDns -Mode Reset }
        '^5$' { Invoke-WHDFirewallAllowList }
        '^6$' {
            $mn = (Read-WHDMenuAnswer -Answer $Answer -Prompt '  Auto-rollback minutes [10]').Trim()
            if (-not $mn) { $mn = '10' }
            if ($mn -match '^\d{1,4}$' -and [int]$mn -ge 1 -and [int]$mn -le 1440) { Enable-WHDDefaultDenyOutbound -RollbackMinutes ([int]$mn) }
            else { Write-Host '  minutes must be 1 - 1440; nothing done.' -ForegroundColor Yellow }
        }
        '^7$' { Confirm-WHDDefaultDenyKeep }
        '^8$' { Disable-WHDDefaultDenyOutbound }
        '^9$' { $def = Get-WHDBlocklistFile; $f = (Read-WHDMenuAnswer -Answer $Answer -Prompt ('  IP / CIDR list file [{0}]' -f $def)).Trim(); if (-not $f) { $f = $def }; Invoke-WHDBlocklistApply -Path $f }
        '^[Hh]$' { Invoke-WHDListTakeover; $def = Join-Path (Get-WHDProfileFolder) 'blacklist-hosts.txt'; $f = (Read-WHDMenuAnswer -Answer $Answer -Prompt ('  Domain list file [{0}]' -f $def)).Trim(); if (-not $f) { $f = $def }; Block-WHDHostsList -Path $f }
        '^[Cc]$' { Remove-WHDBlacklist }
        '^[Aa]$' { $def = Join-Path (Get-WHDProfileFolder) 'firewall-baseline.json'; $f = (Read-WHDMenuAnswer -Answer $Answer -Prompt ('  Firewall profile [{0}]' -f $def)).Trim(); if (-not $f) { $f = $def }; Invoke-WHDApplyFirewallProfile -Path $f }
        '^[Mm]$' { Enable-WHDConnectionLogging }
        '^[Oo]$' { Disable-WHDConnectionLogging }
        '^[Vv]$' { Invoke-WHDBlockedView -Answer $Answer }
        '^[Gg]$' { Remove-WHDProgramAllow }
        '^[Tt]$' { Invoke-WHDSetTimeSync -Mode Cloudflare }
        '^[Nn]$' { Invoke-WHDSetTimeSync -Mode Windows }
        '^[Tt][Ss]$' { Show-WHDTimeStatus; Show-WHDConnectionLoggingState }
        '^[Zz]$' { Invoke-WHDMenu -Name 'TimeRegion' }   # D53: as in WHD Next 2.0; B there comes back here
        '^[Ff]$' {
            $sum = Invoke-WHDBlocklistRefresh -Mode Preview
            if ($sum -and (Test-WHDRealChange)) {
                $a = (Read-WHDMenuAnswer -Answer $Answer -Prompt '  M = merge,  R = replace,  Enter = cancel').Trim()
                $mode = switch -regex ($a) { '^[Mm]$' { 'Merge' } '^[Rr]$' { 'Replace' } default { $null } }
                if ($mode) {
                    [void](Invoke-WHDBlocklistRefresh -Mode $mode)
                    $yn = (Read-WHDMenuAnswer -Answer @($Answer | Select-Object -Skip 1) -Prompt '  Rebuild the firewall block rules from the updated list now? [y/N]').Trim()
                    if ($yn -match '^[Yy]') { Update-WHDBlocklistRule }
                } else { Write-Host '  cancelled.' -ForegroundColor DarkGray }
            } elseif ($sum) { Write-WHDLog -Message 'DRY-RUN: preview only. Switch EXECUTE on (X) to merge or replace.' -Level 'DRY' }
        }
        '^[Bb]$' { return $false }
        default { Write-Host '  invalid.' -ForegroundColor Yellow }
    }
    return $true
}
