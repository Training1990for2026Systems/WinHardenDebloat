<#
================================================================================
 WinHardenDebloat  -  modules\Profiles.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Profile-driven, non-interactive runner. Reads a JSON profile and drives the
 SAME engine functions the interactive menu and the GUI use.

 It does not own any UI: it injects an auto-approve confirm strategy (after one
 upfront gate, unless -Yes) and reads back structured results from the engine
 (Get-WHDResults). The GUI (WHD-GUI.ps1) drives the identical functions the same way.

 Profile schema (JSON) - every section optional:
 {
   "name": "lean",
   "description": "...",
   "ai":   { "featureOff": ["copilot","bing","webexp","recall"],
             "remove":     ["copilot","powerautomate","phonelink"] },
   "storeSuppression": true,
   "general": { "removeRecommended": true, "remove": ["xboxapp","todos"], "oem": "ask" },
   (general.oem = "ask": list the installed non-Microsoft apps and ask which to remove; console only)
   "privacyHardening": true,
   "disableDiagTrack": true,
   "permissions": "Balanced",                         // Lock | Lockdown | Balanced | Open
   (security also takes "servicesOff": ["fileshare","smb","dialvpn","ipsec","proxy","faxphone"])
   "devices": { "btNetworkOff": true, "wifiDirectOff": true, "wanMiniportsOff": true },
   "win32": { "uninstall": ["Zoom Workplace"],
              "removeEverywhere": ["Logi"],
              "blockExe": ["LogiDownloadAssistant.exe"] },
   "componentCleanup": { "run": true, "resetBase": false },
   "network": { "firewallWipeFirst": false,              // true = delete ALL firewall rules first (standard.json)
                "timeSync": "Cloudflare",                   // Cloudflare (+1 h jump limit) | Windows
                "firewallProfile": "profiles\\firewall-baseline.json",
                "dns": "Cloudflare",                           // 1.1.1.2 + encrypted DoH
                "connectionLogging": true },                  // Windows Firewall log: default file, dropped + allowed, 32,767 KB
   "updates": { "windowsUpdatePolicy": true, "drivers": true, "driverPolicy": true,
                "storePolicy": true, "edgeUpdaterOff": true,
                "updatersOff": ["OneDrive"],                   // name matches from the updater scan
                "gate": "closed" }                             // "closed" or "programs", set LAST (after the update guard); "" = leave as is
 }
 Order: apps/AI -> privacy -> Security+ (incl. services off) -> devices -> permissions -> win32 -> network
 (time, firewall, DNS, logging) -> updates policies + app updaters -> component
 cleanup -> update guard -> update gate close (LAST).
 AI/general keys are the module .Key values (copilot, recall, powerautomate,
 bing, webexp, notepad, paint, photos, phonelink; general: see Debloat-General).

 Reuses Common.ps1 + all action modules.
================================================================================
#>

function _WHDAiByKey  { param($Key) @($script:WHDAiModules   | Where-Object { $_.Key -eq $Key })[0] }
function _WHDGenByKey { param($Key) @($script:WHDGeneralApps | Where-Object { $_.Key -eq $Key })[0] }
# Profile summary lines: the GUI only shows Write-WHDLog output (its console is hidden), the terminal keeps its colours.
function _WHDProfSay { param([string]$Text, [string]$Color) if ($script:WHDGuiMode) { Write-WHDLog $Text 'INFO' } elseif ($Color) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text } }

function Invoke-WHDApplyProfile {
    param([Parameter(Mandatory)][string]$Path)

    # Resolve a relative path against the project root (a self-elevated window's
    # working directory is system32, not the project folder). A path pasted with
    # surrounding double quotes is accepted (IsPathRooted throws on a quote).
    $Path = $Path.Trim().Trim('"')
    if (-not [System.IO.Path]::IsPathRooted($Path)) { $Path = Join-Path $script:WHDRoot $Path }
    if (-not (Test-Path -LiteralPath $Path)) { Write-WHDLog ("profile not found: {0}" -f $Path) 'ERR'; return }
    try { $p = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch {
        Write-WHDLog ("profile parse error: {0}" -f $_.Exception.Message) 'ERR'; return
    }
    Reset-WHDResults
    $pname = if ($p.name) { $p.name } else { Split-Path $Path -Leaf }
    Write-WHDLog ("================ APPLY PROFILE: {0} ================" -f $pname) 'ACT'
    if ($p.description) { _WHDProfSay ("  {0}" -f $p.description) 'DarkGray' }

    # ---- summary of intended actions --------------------------------------
    Write-Host ''
    _WHDProfSay '  This profile will (in the current mode):' 'White'
    if ($p.ai.featureOff)          { _WHDProfSay ("   - AI feature-off : {0}" -f (@($p.ai.featureOff) -join ', ')) }
    if ($p.ai.remove)              { _WHDProfSay ("   - AI remove      : {0}" -f (@($p.ai.remove) -join ', ')) }
    if ($p.storeSuppression)       { _WHDProfSay '   - Store / silent-reinstall suppression' }
    if ($p.general.removeRecommended) { _WHDProfSay '   - General: remove ALL recommended apps' }
    if ($p.general.remove)         { _WHDProfSay ("   - General remove : {0}" -f (@($p.general.remove) -join ', ')) }
    if ("$($p.general.oem)" -eq 'ask') { _WHDProfSay '   - General: list the installed non-Microsoft apps and ask which to remove' }
    if ($p.privacyHardening)       { _WHDProfSay '   - Privacy / telemetry hardening' }
    if ($p.disableDiagTrack)       { _WHDProfSay '   - Disable DiagTrack service' }
    if ($p.privacy)                { _WHDProfSay ("   - More privacy settings : {0}" -f (@($p.privacy) -join ', ')) }
    if ($p.security) {
        $sx = $p.security
        if ($sx.pua)               { _WHDProfSay '   - Security+: block unwanted apps (PUA)' }
        if ($sx.networkProtection) { _WHDProfSay ("   - Security+: network protection {0}" -f $sx.networkProtection) }
        if ($sx.folderProtection)  { _WHDProfSay ("   - Security+: folder protection {0}" -f $sx.folderProtection) }
        if ("$($sx.folderProtection)" -eq 'On') {
            $ppDir = ''
            try { $ppDir = Get-WHDProtectedFolderOfRoot } catch {}
            if ($ppDir) { _WHDProfSay ("     WARNING: WHD runs from inside the protected folder '{0}'. Once folder protection is in BLOCK mode, WHD's log may stop and the steps after it may not be recorded for undo. Better: do not run the profile now. Move the WHD folder outside the protected folders (for example C:\WHD) and start it from there." -f $ppDir) 'Yellow' }
        }
        if ($sx.asrGroups)         { _WHDProfSay ("   - Security+: ASR {0} ({1})" -f (@($sx.asrGroups) -join ', '), $(if ($sx.asrMode) { $sx.asrMode } else { 'Audit' })) }
        if ($sx.protocolsOff)      { _WHDProfSay ("   - Security+: protocols off: {0}" -f (@($sx.protocolsOff) -join ', ')) }
        if ($sx.servicesOff)       { _WHDProfSay ("   - Security+: network services off: {0}" -f (@($sx.servicesOff) -join ', ')) }
        if ($sx.uacAlwaysNotify)   { _WHDProfSay '   - Security+: UAC Always notify' }
        if ($sx.passwordPolicy)    { _WHDProfSay '   - Security+: password + lockout rules (14 chars, remember 5, never expire, 3 tries / 10 min)' }
        if ($sx.updateGuard)       { _WHDProfSay '   - Security+: update guard (alert only, sign-in +10 min)' }
    }
    if ($p.devices) {
        if ($p.devices.btNetworkOff)    { _WHDProfSay '   - Devices: Bluetooth network part off (DHCP + autoconfig off, adapter off)' }
        if ($p.devices.wifiDirectOff)   { _WHDProfSay '   - Devices: Wi-Fi Direct adapters off + install block' }
        if ($p.devices.wanMiniportsOff) { _WHDProfSay '   - Devices: WAN Miniports install block + remove' }
    }
    if ($p.permissions)            { _WHDProfSay ("   - App-permission profile : {0}" -f $p.permissions) }
    if ($p.win32.uninstall)        { _WHDProfSay ("   - Win32 uninstall : {0}" -f (@($p.win32.uninstall) -join ', ')) }
    if ($p.win32.removeEverywhere) { _WHDProfSay ("   - Win32 remove-everywhere : {0}" -f (@($p.win32.removeEverywhere) -join ', ')) }
    if ($p.win32.blockExe)         { _WHDProfSay ("   - Win32 block exe : {0}" -f (@($p.win32.blockExe) -join ', ')) }
    if ($p.network) {
        $nx = $p.network
        if ($nx.firewallWipeFirst) { _WHDProfSay '   - Network: WIPE ALL firewall rules first (Windows defaults included; .wfw backup taken)' }
        if ($nx.timeSync)          { _WHDProfSay ("   - Network: time sync {0}{1}" -f $nx.timeSync, $(if ($nx.timeSync -eq 'Cloudflare') { ' (UDP 123 pinned, 1 h jump limit)' } else { '' })) }
        if ($nx.firewallProfile)   { _WHDProfSay ("   - Network: firewall profile {0}" -f $nx.firewallProfile) }
        if ($nx.dns)               { _WHDProfSay ("   - Network: DNS {0}" -f $(if ($nx.dns -eq 'Cloudflare') { 'Cloudflare 1.1.1.2 + encrypted DoH' } else { $nx.dns })) }
        if ($nx.connectionLogging) { _WHDProfSay '   - Network: Windows Firewall log ON (default file, dropped + allowed, 32,767 KB)' }
    }
    if ($p.updates) {
        $ux = $p.updates
        $pl = @(); if ($ux.windowsUpdatePolicy) { $pl += 'Windows Update' }; if ($ux.drivers) { $pl += 'drivers (Device Installation = No)' }
        if ($ux.driverPolicy) { $pl += 'driver policy' }; if ($ux.storePolicy) { $pl += 'Store auto-update' }
        if ($pl.Count)             { _WHDProfSay ("   - Updates: policies -> {0}" -f ($pl -join ', ')) }
        if ($ux.edgeUpdaterOff)    { _WHDProfSay '   - Updates: Edge Update off' }
        if ($ux.updatersOff)       { _WHDProfSay ("   - Updates: app updaters off matching: {0}" -f (@($ux.updatersOff) -join ', ')) }
    }
    if ($p.componentCleanup.run)   { _WHDProfSay ("   - Component store cleanup{0}" -f $(if($p.componentCleanup.resetBase){' + ResetBase'}else{''})) }
    if ($p.security -and $p.security.updateGuard) { _WHDProfSay '   - then: install the update guard' }
    if ($p.updates -and "$($p.updates.gate)" -eq 'closed') { _WHDProfSay '   - LAST: CLOSE the update gate (only Defender + DNS-over-HTTPS may use the web)' }
    if ($p.updates -and "$($p.updates.gate)" -eq 'programs') { _WHDProfSay '   - LAST: set the update gate to PROGRAMS (Defender + DNS-over-HTTPS + the programs you allowed)' }
    Write-Host ''

    # ---- one upfront gate in EXECUTE mode (unless -Yes) -------------------
    if ($script:WHDExecute -and -not $script:WHDYes) {
        # Same confirm strategy as every other action: y/N in the terminal, a Yes/No dialog in the GUI
        # (a Read-Host here would wait on the hidden console behind the GUI window).
        _WHDProfSay '  *** EXECUTE MODE - this will change the system. ***' 'Red'
        if (-not (Confirm-WHDProceed ("EXECUTE MODE: apply profile '{0}' now (every step above)" -f $pname))) { Write-WHDLog 'Profile apply cancelled at gate.' 'WARN'; return }
    }

    # From here, per-action approval is automatic - the gate above (or -Yes,
    # or dry-run) is the decision. Save/restore the injected strategy.
    $prevConfirm = $script:WHDConfirm
    $script:WHDConfirm = { param($Msg) $true }
    $applyAborted = $false
    try {
        # Action functions return result objects (recorded in WHDResults). Run
        # them inside a scriptblock piped to Out-Null so those objects don't leak
        # into the console (Write-Host logging still shows). This also keeps the
        # host's auto-formatter out of the picture entirely.
        & {
            foreach ($k in @($p.ai.featureOff | Where-Object { $_ })) { $m = _WHDAiByKey $k; if ($m) { Invoke-WHDAiFeatureOff -Module $m } else { Write-WHDLog "unknown AI key '$k'" 'WARN' } }
            foreach ($k in @($p.ai.remove     | Where-Object { $_ })) { $m = _WHDAiByKey $k; if ($m) { Invoke-WHDAiRemove     -Module $m } else { Write-WHDLog "unknown AI key '$k'" 'WARN' } }
            if ($p.storeSuppression)          { Invoke-WHDStoreSuppression }
            if ($p.general.removeRecommended) { Invoke-WHDRemoveRecommended }
            foreach ($k in @($p.general.remove | Where-Object { $_ })) { $e = _WHDGenByKey $k; if ($e) { Invoke-WHDGeneralRemove -Entry $e } else { Write-WHDLog "unknown general key '$k'" 'WARN' } }
            if ("$($p.general.oem)" -eq 'ask') { Invoke-WHDFoundAppsAsk }
            if ($p.privacyHardening)          { Invoke-WHDPrivacyHardening }
            if ($p.disableDiagTrack)          { Invoke-WHDDisableDiagTrack }
            if ($p.security -and (Get-Command Invoke-WHDDefenderProtection -EA SilentlyContinue)) {
                $sx = $p.security
                if ($sx.pua) { Invoke-WHDDefenderProtection -Which PUA -Mode On }
                if ($sx.networkProtection) { Invoke-WHDDefenderProtection -Which Network -Mode $sx.networkProtection }
                if ($sx.folderProtection)  { Invoke-WHDDefenderProtection -Which Folders -Mode $sx.folderProtection }
                if ($sx.asrGroups) { Invoke-WHDAsrGroups -Groups @($sx.asrGroups) -Mode $(if ($sx.asrMode) { $sx.asrMode } else { 'Audit' }) }
                foreach ($k in @($sx.protocolsOff | Where-Object { $_ })) {
                    $it = @($script:WHDProtocols | Where-Object { $_.Key -eq $k })[0]
                    if ($it) { Invoke-WHDProtocolOff -Item $it } else { Write-WHDLog "unknown protocol key '$k'" 'WARN' }
                }
                foreach ($k in @($sx.servicesOff | Where-Object { $_ })) {
                    $it = @($script:WHDNetServiceGroups | Where-Object { $_.Key -eq $k })[0]
                    if ($it -and $it.NotInAll) { Write-WHDLog ("servicesOff '{0}' refused in a profile: {1}" -f $k, $it.Name) 'WARN' }
                    elseif ($it) { Invoke-WHDNetServiceOff -Item $it } else { Write-WHDLog "unknown servicesOff key '$k'" 'WARN' }
                }
                if ($sx.uacAlwaysNotify) { Set-WHDUacAlwaysNotify }
                if ($sx.passwordPolicy)  { Invoke-WHDPasswordPolicy }
            }
            foreach ($k in @($p.privacy | Where-Object { $_ })) {
                $it = @($script:WHDPrivacyItems | Where-Object { $_.Key -eq $k })[0]
                if ($it) { Invoke-WHDPrivacyItem -Item $it } else { Write-WHDLog "unknown privacy key '$k'" 'WARN' }
            }
            if ($p.devices -and (Get-Command Invoke-WHDBtNetworkOff -EA SilentlyContinue)) {
                if ($p.devices.btNetworkOff)    { Invoke-WHDBtNetworkOff }
                if ($p.devices.wifiDirectOff)   { Invoke-WHDWifiDirectOff }
                if ($p.devices.wanMiniportsOff) { Invoke-WHDWanMiniportsOff }
            }
            if ("$($p.permissions)" -eq 'Lock') { Invoke-WHDPrivacyLock }
            elseif ($p.permissions)           { Invoke-WHDPermissionProfile -Profile $p.permissions }
            if ($p.win32.uninstall -or $p.win32.removeEverywhere -or $p.win32.blockExe) {
                $all = Get-WHDWin32Apps
                foreach ($nm in @($p.win32.uninstall | Where-Object { $_ })) {
                    $app = @($all | Where-Object { $_.DisplayName -like "*$nm*" })[0]
                    if ($app) { Invoke-WHDWin32Uninstall -App $app | Out-Null } else { Write-WHDLog "win32 uninstall: no match for '$nm'" 'WARN' }
                }
                foreach ($nm in @($p.win32.removeEverywhere | Where-Object { $_ })) { Remove-WHDAppEverywhere -Name $nm }
                foreach ($exe in @($p.win32.blockExe | Where-Object { $_ }))        { Block-WHDExecutable -ExeName $exe }
            }
            if ($p.network -and (Get-Command Invoke-WHDSetTimeSync -EA SilentlyContinue)) {
                $nx = $p.network
                # Time first, so the firewall profile keeps NTP pinned to Cloudflare.
                if ($nx.firewallWipeFirst) { Invoke-WHDFirewallWipe }   # empty slate BEFORE any WHD rule is added
                if ($nx.timeSync) { Invoke-WHDSetTimeSync -Mode $nx.timeSync }
                if ($nx.firewallProfile) {
                    $fp = "$($nx.firewallProfile)"
                    if (-not [System.IO.Path]::IsPathRooted($fp)) { $fp = Join-Path $script:WHDRoot $fp }
                    Invoke-WHDApplyFirewallProfile -Path $fp
                }
                if ($nx.dns -eq 'Cloudflare') { Invoke-WHDSetDns -Mode Cloudflare }
                elseif ($nx.dns -eq 'Reset')  { Invoke-WHDSetDns -Mode Reset }
                if ($nx.connectionLogging)    { Enable-WHDConnectionLogging }
            }
            if ($p.updates -and (Get-Command Invoke-WHDUpdatePolicy -EA SilentlyContinue)) {
                $ux = $p.updates
                $map = @{ wu = [bool]$ux.windowsUpdatePolicy; drivers = [bool]$ux.drivers; driverpolicy = [bool]$ux.driverPolicy; store = [bool]$ux.storePolicy }
                foreach ($it in $script:WHDUpdatePolicies) { if ($map[$it.Key]) { Invoke-WHDUpdatePolicy -Item $it } }
                if ($ux.edgeUpdaterOff -or $ux.updatersOff) {
                    $found = @(Find-WHDAppUpdaters | Where-Object { $_.State -notmatch 'Disabled' })
                    $pick = @($found | Where-Object {
                        $u = $_
                        ($ux.edgeUpdaterOff -and $u.Edge) -or (@($ux.updatersOff | Where-Object { $_ -and ("$($u.Label)" -like "*$_*") }).Count -gt 0) })
                    if ($pick.Count) { Invoke-WHDAppUpdatersOff -Items $pick } else { Write-WHDLog 'Updates: no matching active app updaters found.' 'INFO' }
                }
            }
            if ($p.componentCleanup.run) {
                if ([bool]$p.componentCleanup.resetBase) { Invoke-WHDComponentCleanup -ResetBase }
                else                                     { Invoke-WHDComponentCleanup }
            }
            # Update guard LAST, so its first check sees the finished system.
            if ($p.security -and $p.security.updateGuard -and (Get-Command Install-WHDUpdateGuard -EA SilentlyContinue)) { Install-WHDUpdateGuard }
            # Update gate LAST: after this only Defender + DoH (and, on PROGRAMS, the programs you allowed) may use the web.
            if ($p.updates -and (Get-Command Close-WHDUpdateGate -EA SilentlyContinue)) {
                if     ("$($p.updates.gate)" -eq 'closed')   { Close-WHDUpdateGate }
                elseif ("$($p.updates.gate)" -eq 'programs') { Close-WHDUpdateGate -Mode programs }
            }
        } | Out-Null
    }
    catch   { $applyAborted = $true; Write-WHDLog ("apply error: {0}" -f $_.Exception.Message) 'ERR' }
    finally { $script:WHDConfirm = $prevConfirm }

    # ---- results summary: read the engine's running counters (no iteration) --
    try {
        $c = Get-WHDCounts
        Write-Host ''
        $sumTxt = "" + [int]$c.done + " done, " + [int]$c.planned + " planned (dry-run), " + [int]$c.failed + " failed, " + [int]$c.skipped + " skipped"
        if ($applyAborted) { Write-WHDLog ("PROFILE '" + $pname + "' ABORTED after an error - the remaining steps were NOT applied - " + $sumTxt) 'ERR' }
        else               { Write-WHDLog ("PROFILE '" + $pname + "' complete - " + $sumTxt) 'ACT' }
        if ([int]$c.failed -gt 0) {
            foreach ($r in @(Get-WHDResults)) {
                if ("$($r.Status)" -eq 'failed') { Write-WHDLog ("  FAILED: " + $r.Action + " :: " + $r.Detail) 'ERR' }
            }
        }
    } catch {
        Write-WHDLog ("summary note: " + $_.Exception.Message) 'WARN'
    }

    # ---- F21: read every journaled change of this session back ---------------
    if ($script:WHDExecute) {
        try { Invoke-WHDVerify -Quiet | Out-Null } catch { Write-WHDLog ("verify note: " + $_.Exception.Message) 'WARN' }
    }
}

# Write a starter profile (the curated lean setup) the user can edit.
function Export-WHDProfile {
    param([Parameter(Mandatory)][string]$Path)
    $Path = $Path.Trim().Trim('"')
    if (-not [System.IO.Path]::IsPathRooted($Path)) { $Path = Join-Path $script:WHDRoot $Path }
    $lean = [ordered]@{
        name             = 'lean'
        description      = 'Curated lean debloat for a fresh Windows 11 Home install (edit to taste).'
        ai               = [ordered]@{ featureOff = @('copilot','bing','recall'); remove = @('copilot','powerautomate','phonelink','webexp') }
        storeSuppression = $true
        general          = [ordered]@{ removeRecommended = $true; remove = @('xboxapp','todos','sticky'); oem = 'ask' }
        privacyHardening = $true
        disableDiagTrack = $true
        # Phase 7 keys (default OFF until validated): activity, clipboard, suggestions, speech, edgebg, edgediag
        privacy          = @()
        # Phase 8 (default OFF until validated). Example:
        # pua=$true; networkProtection='Audit'; folderProtection='Audit'; asrGroups=@('standard','scripts','office');
        # asrMode='Audit'; protocolsOff=@('llmnr','netbios','wpad','remoteassist'); servicesOff=@('fileshare','smb','dialvpn','ipsec','proxy','faxphone'); uacAlwaysNotify=$true; passwordPolicy=$true; updateGuard=$true
        security         = [ordered]@{ pua = $false; networkProtection = ''; folderProtection = ''; asrGroups = @(); asrMode = 'Audit'; protocolsOff = @(); servicesOff = @(); uacAlwaysNotify = $false; passwordPolicy = $false; updateGuard = $false }
        permissions      = 'Balanced'
        devices          = [ordered]@{ btNetworkOff = $false; wifiDirectOff = $false; wanMiniportsOff = $false }
        win32            = [ordered]@{ uninstall = @(); removeEverywhere = @(); blockExe = @() }
        componentCleanup = [ordered]@{ run = $true; resetBase = $false }
        # Network (default OFF). Example: timeSync='Cloudflare'; firewallProfile='profiles\firewall-baseline.json'; dns='Cloudflare'; connectionLogging=$true
        network          = [ordered]@{ firewallWipeFirst = $false; timeSync = ''; firewallProfile = ''; dns = ''; connectionLogging = $false }
        # Updates (default OFF). Example: windowsUpdatePolicy=$true; drivers=$true; driverPolicy=$true; storePolicy=$true; edgeUpdaterOff=$true; updatersOff=@('OneDrive'); gate='closed' (or 'programs')
        updates          = [ordered]@{ windowsUpdatePolicy = $false; drivers = $false; driverPolicy = $false; storePolicy = $false; edgeUpdaterOff = $false; updatersOff = @(); gate = '' }
    }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # Keep a copy of any profile about to be overwritten (it may hold your edits).
    if (Test-Path -LiteralPath $Path) {
        if (-not $script:WHDRestore) { Initialize-WHDPaths }
        $bak = Join-Path $script:WHDRestore ((Split-Path $Path -Leaf) + '.before-export')
        Copy-Item -LiteralPath $Path -Destination $bak -Force -EA SilentlyContinue
        Write-WHDLog ("previous profile saved to {0}" -f $bak) 'INFO'
    }
    ($lean | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Path -Encoding UTF8
    Write-WHDLog ("Starter profile written: {0}" -f $Path) 'OK'
}
