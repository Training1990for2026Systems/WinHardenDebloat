#requires -Version 7.6
<#
================================================================================
 WHD Next 3.0  -  Features/Profiles.ps1   (the Profiles step, D55, D56, D94-D97)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 A profile = many menu actions in one go. The profiles are JSON files in
 profiles\ (D95): minimum.json, average.json, strict.json (written new for
 3.0, D55) and any other file there with "kind": "whd-profile".
   Main menu P, the window's Profiles tab, WHD.ps1 -Profile <name> (D97).
   Applying (D96): a summary of every step; in EXECUTE ONE question
   "apply this profile?", then every step runs without asking again (a restore
   point comes first, as always); in dry-run every step shows what it would
   do. Each change still goes through the change gate and is recorded, so the
   Undo center can undo it. Verify of everything recorded runs at the end.
 Order: AI -> apps -> privacy -> Security+ -> devices -> permissions ->
 network (time, firewall profile, DNS, log) -> updates -> component store ->
 the update guard LAST (its first check sees the finished PC).
 Never in a profile (each needs your own answer): default-deny outbound,
 firewall wipe, Win32 uninstalls, "ask about non-Microsoft apps", closing the
 update gate. Written new for 3.0 - WHD Next 2.0's Profiles.ps1 read for
 reference, not copied.
================================================================================
#>

$script:WHDProfileKind = 'whd-profile'
$script:WHDProfileKeys = @('kind', 'name', 'title', 'description', 'ai', 'storeSuppression', 'general', 'privacyHardening', 'diagTrackOff', 'privacy', 'security', 'permissions', 'devices', 'network', 'updates', 'componentCleanup', 'updateGuard')
$script:WHDProfileOrder = @('minimum', 'average', 'strict')

# ---- the files ------------------------------------------------------------------------------------------------------
function Get-WHDProfileList {
    # The profiles in profiles\: the three shipped first, then your own (by name).
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $dir = Get-WHDProfileFolder
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $out = foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        try { $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable } catch { continue }
        if (-not ($j -is [System.Collections.IDictionary]) -or [string]$j['kind'] -ne $script:WHDProfileKind) { continue }
        $n = if ([string]$j['name']) { [string]$j['name'] } else { $f.BaseName }
        $rank = [array]::IndexOf($script:WHDProfileOrder, $n.ToLowerInvariant())
        [pscustomobject]@{ Name = $n; Title = $(if ($j['title']) { [string]$j['title'] } else { $n }); Path = $f.FullName; Rank = $(if ($rank -ge 0) { $rank } else { 100 }) }
    }
    return @($out | Sort-Object Rank, Name)
}
function Read-WHDProfile {
    # A profile file -> hashtable. $null with a message when it cannot be read.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { Write-WHDLog -Message ('Profile not found: {0}' -f $Path) -Level 'ERR'; return $null }
    try { $p = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable }
    catch { Write-WHDLog -Message ('The profile could not be read (JSON): {0}' -f $_.Exception.Message) -Level 'ERR'; return $null }
    if (-not ($p -is [System.Collections.IDictionary]) -or [string]$p['kind'] -ne $script:WHDProfileKind) { Write-WHDLog -Message ('Not a WHD profile (needs "kind": "{0}"): {1}' -f $script:WHDProfileKind, $Path) -Level 'ERR'; return $null }
    return $p
}
function Resolve-WHDProfile {
    # A name (minimum, average, ...) or a path -> the file's path; '' when there is none.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    if (Test-Path -LiteralPath $Name -PathType Leaf) { return (Get-Item -LiteralPath $Name).FullName }
    $m = @(Get-WHDProfileList | Where-Object { $_.Name -ieq $Name -or [IO.Path]::GetFileNameWithoutExtension($_.Path) -ieq $Name })
    if ($m.Count) { return $m[0].Path }
    return ''
}

# ---- the plan: one step per action, with its words ---------------------------------------------------------------------
function Get-WHDProfileSection {
    [CmdletBinding()]
    param($Data, [Parameter(Mandatory)][string]$Key)
    $v = $Data[$Key]
    if ($v -is [System.Collections.IDictionary]) { return $v }
    return @{}
}
function Get-WHDProfileStep {
    # The profile -> ordered steps: Text (what it does) + Do (the menu's own action). Unknown keys give a Warn line.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Data)
    $steps = [System.Collections.Generic.List[object]]::new()
    $warn = [System.Collections.Generic.List[string]]::new()
    # a step = the menu's own function by name + its arguments (no closures: they would not see the module's functions)
    $add = { param([string]$Text, [string]$Fn, [hashtable]$Arg = @{}) $steps.Add([pscustomobject]@{ Text = $Text; Do = $Fn; Arg = $Arg }) }
    foreach ($k in $Data.Keys) { if ($script:WHDProfileKeys -notcontains [string]$k) { $warn.Add(('unknown setting "{0}" - ignored' -f $k)) } }

    $ai = Get-WHDProfileSection -Data $Data -Key 'ai'
    foreach ($k in @($ai['featureOff'] | Where-Object { $_ })) {
        $mod = @($script:WHDAiModules | Where-Object { $_['Key'] -eq [string]$k })
        if ($mod.Count) { $mm = $mod[0]; & $add ('AI off: {0}' -f $mm['Name']) 'Invoke-WHDAiFeatureOff' @{ Module = $mm } } else { $warn.Add(('unknown AI key "{0}"' -f $k)) }
    }
    foreach ($k in @($ai['remove'] | Where-Object { $_ })) {
        $mod = @($script:WHDAiModules | Where-Object { $_['Key'] -eq [string]$k -and $_['CanRemove'] })
        if ($mod.Count) { $mm = $mod[0]; & $add ('AI app removed: {0}' -f $mm['Name']) 'Invoke-WHDAiRemove' @{ Module = $mm } } else { $warn.Add(('unknown or not removable AI key "{0}"' -f $k)) }
    }
    if ($Data['storeSuppression']) { & $add 'Store / silent-reinstall suppression' 'Invoke-WHDStoreSuppression' }

    $gen = Get-WHDProfileSection -Data $Data -Key 'general'
    $apps = [System.Collections.Generic.List[object]]::new()
    if ($gen['removeRecommended']) { foreach ($e in @($script:WHDGeneralApps | Where-Object { $_['Rec'] })) { $apps.Add($e) } }
    foreach ($k in @($gen['remove'] | Where-Object { $_ })) {
        $e = @($script:WHDGeneralApps | Where-Object { $_['Key'] -eq [string]$k })
        if ($e.Count) { if (-not ($apps | Where-Object { $_['Key'] -eq [string]$k })) { $apps.Add($e[0]) } } else { $warn.Add(('unknown app key "{0}"' -f $k)) }
    }
    if ($apps.Count) { $al = $apps.ToArray(); & $add ('Apps removed: {0}' -f (@($al | ForEach-Object { $_['Name'] }) -join ', ')) 'Invoke-WHDGeneralBatch' @{ Entries = $al } }

    if ($Data['privacyHardening']) { & $add 'Privacy / telemetry policies' 'Invoke-WHDPrivacyHardening' }
    if ($Data['diagTrackOff']) { & $add 'Telemetry service DiagTrack off' 'Disable-WHDDiagTrack' }
    foreach ($k in @($Data['privacy'] | Where-Object { $_ })) {
        $it = @($script:WHDPrivacyItems | Where-Object { $_['Key'] -eq [string]$k })
        if ($it.Count) { $ii = $it[0]; & $add ('Privacy: {0}' -f $ii['Name']) 'Invoke-WHDPrivacyItem' @{ Item = $ii } } else { $warn.Add(('unknown privacy key "{0}"' -f $k)) }
    }

    $sec = Get-WHDProfileSection -Data $Data -Key 'security'
    if ($sec['pua']) { & $add 'Defender: block unwanted apps (PUA)' 'Invoke-WHDDefenderProtection' @{ Which = 'PUA'; Mode = 'On' } }
    $np = [string]$sec['networkProtection']
    if ($np) {
        $npm = switch ($np) { 'Block' { 'On' } 'Audit' { 'Audit' } default { '' } }
        if ($npm) { & $add ('Defender: network protection {0}' -f $np.ToUpperInvariant()) 'Invoke-WHDDefenderProtection' @{ Which = 'Network'; Mode = $npm } } else { $warn.Add(('networkProtection "{0}" - use Audit or Block' -f $np)) }
    }
    $fp = [string]$sec['folderProtection']
    if ($fp) {
        $fpm = switch ($fp) { 'Block' { 'On' } 'Audit' { 'Audit' } default { '' } }
        if ($fpm) { & $add ('Defender: ransomware folder protection {0}' -f $fp.ToUpperInvariant()) 'Invoke-WHDDefenderProtection' @{ Which = 'Folders'; Mode = $fpm } } else { $warn.Add(('folderProtection "{0}" - use Audit or Block' -f $fp)) }
    }
    $grp = @($sec['asrGroups'] | Where-Object { $_ } | ForEach-Object { [string]$_ })
    if ($grp.Count) {
        $bad = @($grp | Where-Object { $_ -notin 'standard', 'scripts', 'office' })
        foreach ($b in $bad) { $warn.Add(('unknown ASR group "{0}"' -f $b)) }
        $ok = @($grp | Where-Object { $_ -in 'standard', 'scripts', 'office' })
        $am = if ([string]$sec['asrMode'] -eq 'Block') { 'Block' } else { 'Audit' }
        if ($ok.Count) { & $add ('Attack-surface rules {0} ({1})' -f ($ok -join ', '), $am.ToUpperInvariant()) 'Invoke-WHDAsrGroup' @{ Groups = [string[]]$ok; Mode = $am } }
    }
    foreach ($k in @($sec['protocolsOff'] | Where-Object { $_ })) {
        $it = @($script:WHDProtocols | Where-Object { $_.Key -eq [string]$k })
        if ($it.Count) { $ii = $it[0]; & $add ('Protocol off: {0}' -f $ii.Name) 'Invoke-WHDProtocolOff' @{ Item = $ii } } else { $warn.Add(('unknown protocol key "{0}"' -f $k)) }
    }
    foreach ($k in @($sec['servicesOff'] | Where-Object { $_ })) {
        $it = @($script:WHDNetServiceGroups | Where-Object { $_.Key -eq [string]$k })
        if (-not $it.Count) { $warn.Add(('unknown network service key "{0}"' -f $k)); continue }
        if ($it[0].NotInAll) { $warn.Add(('network service "{0}" is never part of a profile (test only)' -f $k)); continue }
        $ii = $it[0]; & $add ('Network service off: {0}' -f $ii.Name) 'Invoke-WHDNetServiceOff' @{ Item = $ii }
    }
    if ($sec['uacAlwaysNotify']) { & $add 'UAC -> Always notify' 'Set-WHDUacAlwaysNotify' }
    if ($sec['passwordPolicy']) { & $add 'Password + lockout rules (14 chars, remember 5, never expire, 3 tries / 10 min)' 'Invoke-WHDPasswordPolicy' }
    if ($sec['psTelemetryOff']) { & $add 'PowerShell 7 telemetry off (machine-wide; watched) (D56)' 'Invoke-WHDPsTelemetryOff' }

    $dev = Get-WHDProfileSection -Data $Data -Key 'devices'
    if ($dev['btNetworkOff']) { & $add 'Devices: Bluetooth network part off' 'Invoke-WHDBtNetworkOff' @{ NoAsk = $true } }
    if ($dev['wifiDirectOff']) { & $add 'Devices: Wi-Fi Direct off' 'Invoke-WHDWifiDirectOff' @{ NoAsk = $true } }
    if ($dev['wanMiniportsOff']) { & $add 'Devices: WAN Miniports off' 'Invoke-WHDWanMiniportsOff' @{ NoAsk = $true } }

    $perm = [string]$Data['permissions']
    if ($perm) {
        if ($perm -in 'Lockdown', 'Balanced', 'Open') { & $add ('App permissions: {0}' -f $perm) 'Invoke-WHDPermissionProfile' @{ ProfileName = $perm } } else { $warn.Add(('permissions "{0}" - use Lockdown, Balanced or Open' -f $perm)) }
    }

    $net = Get-WHDProfileSection -Data $Data -Key 'network'
    $ts = [string]$net['timeSync']
    if ($ts) { if ($ts -in 'Cloudflare', 'Windows') { & $add ('Time sync: {0}{1}' -f $ts, $(if ($ts -eq 'Cloudflare') { ' (1 h jump limit)' } else { '' })) 'Invoke-WHDSetTimeSync' @{ Mode = $ts } } else { $warn.Add(('timeSync "{0}" - use Cloudflare or Windows' -f $ts)) } }
    $fw = [string]$net['firewallProfile']
    if ($fw) {
        $fwp = if ([IO.Path]::IsPathRooted($fw)) { $fw } else { Join-Path (Get-WHDProfileFolder) $fw }
        & $add ('Firewall profile: {0}' -f (Split-Path $fwp -Leaf)) 'Invoke-WHDApplyFirewallProfile' @{ Path = $fwp }
    }
    $dns = [string]$net['dns']
    if ($dns) { if ($dns -in 'Cloudflare', 'Reset') { & $add ('DNS: {0}' -f $(if ($dns -eq 'Cloudflare') { 'Cloudflare 1.1.1.2 + encrypted DoH' } else { 'back to automatic' })) 'Invoke-WHDSetDns' @{ Mode = $dns } } else { $warn.Add(('dns "{0}" - use Cloudflare or Reset' -f $dns)) } }
    if ($net['connectionLogging']) { & $add 'Firewall log on (dropped + allowed)' 'Enable-WHDConnectionLogging' }

    $upd = Get-WHDProfileSection -Data $Data -Key 'updates'
    foreach ($k in @($upd['policies'] | Where-Object { $_ })) {
        $it = @($script:WHDUpdatePolicies | Where-Object { $_['Key'] -eq [string]$k })
        if ($it.Count) { $ii = $it[0]; & $add ('Updates: {0}' -f $ii['Name']) 'Invoke-WHDUpdatePolicy' @{ Item = $ii } } else { $warn.Add(('unknown update policy key "{0}"' -f $k)) }
    }
    if ($upd['edgeUpdaterOff']) { & $add 'Updates: Edge updater off' 'Disable-WHDAppUpdaterSet' @{ EdgeOnly = $true } }
    if ($Data['componentCleanup']) { & $add 'Component store cleanup (no ResetBase)' 'Invoke-WHDComponentCleanup' }
    if ($Data['updateGuard']) { & $add 'Update guard: install / refresh (old guard tasks of 2.0 / Classic switched off if on)' 'Install-WHDGuard' }
    foreach ($w in $warn) { $steps.Insert(0, [pscustomobject]@{ Text = ('!! ' + $w); Do = ''; Arg = @{} }) }
    return $steps.ToArray()
}

# ---- apply ---------------------------------------------------------------------------------------------------------------
function Invoke-WHDProfile {
    # -Name minimum / average / strict / your own, or a path.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $path = Resolve-WHDProfile -Name $Name
    if (-not $path) { Write-WHDLog -Message ('No profile "{0}" in {1}.' -f $Name, (Get-WHDProfileFolder)) -Level 'ERR'; return }
    $p = Read-WHDProfile -Path $path
    if (-not $p) { return }
    $pname = if ($p['name']) { [string]$p['name'] } else { [IO.Path]::GetFileNameWithoutExtension($path) }
    $steps = @(Get-WHDProfileStep -Data $p)
    $real = Test-WHDRealChange
    Write-WHDLog -Message ('================ PROFILE: {0} ================' -f $(if ($p['title']) { $p['title'] } else { $pname })) -Level 'ACT'
    Write-WHDLog -Message ('File: {0}' -f $path)
    if ($p['description']) { Write-WHDLog -Message ([string]$p['description']) }
    Write-WHDLog -Message ('{0} step(s), in this order:' -f @($steps | Where-Object Do).Count)
    $n = 0
    foreach ($s in $steps) {
        if ($s.Do) { $n++; Write-WHDLog -Message ('  {0,2}. {1}' -f $n, $s.Text) } else { Write-WHDLog -Message ('      {0}' -f $s.Text) -Level 'WARN' }
    }
    if (-not @($steps | Where-Object Do).Count) { Write-WHDLog -Message 'Nothing to do in this profile.' -Level 'WARN'; return }
    if ($real) {
        Write-WHDRisk -Tier 'caution' -Text ('Applies all {0} steps above, one after the other, without asking again. Each change is recorded: the Undo center can undo any of them. A System Restore point is made before the first change.' -f $n)
        if (-not (Confirm-WHDProceed -What ('apply the profile "{0}" ({1} steps)' -f $pname, $n))) { Write-WHDLog -Message 'Profile not applied.' -Level 'WARN'; return }
    } else {
        Write-WHDLog -Message 'DRY-RUN: every step shows what it would do; nothing is changed. Turn EXECUTE on to apply it.' -Level 'DRY'
    }
    $c0 = @{ done = $script:WHDState.Counts.done; failed = $script:WHDState.Counts.failed; skipped = $script:WHDState.Counts.skipped; planned = $script:WHDState.Counts.planned }
    $prev = $script:WHDState.Confirm
    $script:WHDState.Confirm = { param($w) [void]$w; $true }
    $i = 0
    try {
        foreach ($s in @($steps | Where-Object Do)) {
            $i++
            if ($script:WHDState.JournalStop) { Write-WHDLog -Message 'STOPPED: the change history cannot be written - the rest of the profile is not done.' -Level 'ERR'; break }
            Write-WHDLog -Message ('---- {0}/{1}  {2}' -f $i, $n, $s.Text) -Level 'ACT'
            $sa = $s.Arg
            try { & $s.Do @sa | Out-Null } catch { Write-WHDLog -Message ('That step stopped on an error: {0} - going on with the next one.' -f $_.Exception.Message) -Level 'ERR' }
        }
    } finally { $script:WHDState.Confirm = $prev }
    $c = $script:WHDState.Counts
    Write-WHDLog -Message ('PROFILE "{0}" finished: {1} done, {2} planned (dry-run), {3} failed, {4} skipped.' -f $pname, ($c.done - $c0.done), ($c.planned - $c0.planned), ($c.failed - $c0.failed), ($c.skipped - $c0.skipped)) -Level $(if ($c.failed -gt $c0.failed) { 'WARN' } else { 'OK' })
    if ($real -and $c.done -gt $c0.done) { try { [void](Invoke-WHDVerify -All) } catch { Write-WHDLog -Message ('Verify could not run: {0}' -f $_.Exception.Message) -Level 'WARN' } }
}

# ---- the menu (main menu P) ---------------------------------------------------------------------------------------------
function Show-WHDProfilesMenu {
    [CmdletBinding()]
    param()
    Write-Host ''
    Write-Host '  ======= PROFILES (many menu actions in one go) =======' -ForegroundColor White
    Write-Host ('  Folder: {0}  (edit the .json files, or add your own with "kind": "whd-profile")' -f (Get-WHDProfileFolder)) -ForegroundColor Gray
    Write-Host '  Dry-run shows every step; with EXECUTE on, one question and then all steps. Everything is recorded (Undo center).' -ForegroundColor Gray
    Write-Host '  Profiles' -ForegroundColor DarkGray
    $list = @(Get-WHDProfileList)
    if (-not $list.Count) { Write-Host '  (no profile files found)' -ForegroundColor Yellow }
    for ($k = 0; $k -lt $list.Count; $k++) { Write-WHDMenuItem -Key ([string]($k + 1)) -Label $list[$k].Title -Hint ('[{0}]' -f (Split-Path $list[$k].Path -Leaf)) }
    Write-WHDMenuCommonKey
}
function Invoke-WHDProfilesChoice {
    # One menu choice. Returns $false for B (back).
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Choice)
    $c = $Choice.Trim()
    if (Invoke-WHDMenuCommonKey -Choice $c) { return $true }
    if ($c -match '^[Bb]$') { return $false }
    if (-not $c) { return $true }
    $list = @(Get-WHDProfileList)
    if ($c -match '^\d+$' -and [int]$c -ge 1 -and [int]$c -le $list.Count) { Invoke-WHDProfile -Name $list[[int]$c - 1].Path; return $true }
    Write-Host '  invalid.' -ForegroundColor Yellow
    return $true
}
