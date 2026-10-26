#requires -Version 7.6
<#
 WHD Next 3.0  -  Private/Verify.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 Verify: is each recorded change still in place? READ-ONLY - safe in every
 mode. Results: PASS | CHANGED | RETURNED (a removed app is back) | n/a.
 Same checks and the same rules as WHD Next 2.0, so both give the same answer
 on the same history (step 4 goal).
#>
$script:WHDDeprovKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned'
$script:WHDW32TimeTriggerKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TriggerInfo'
$script:WHDDefenderNs = 'root/Microsoft/Windows/Defender'
$script:WHDPrivacyLockKeep = @('webcam', 'microphone', 'radios', 'location')   # off but not locked - the user may switch them on

# ---- readers (read-only) -----------------------------------------------------
function Get-WHDMpPreference { [CmdletBinding()] param() Get-CimInstance -Namespace $script:WHDDefenderNs -ClassName 'MSFT_MpPreference' -ErrorAction Stop }

function Get-WHDAsrCode {
    # Current action of every attack-surface rule: id (lower case) -> 0 off, 1 block, 2 audit, 6 warn.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $map = @{}
    $p = Get-WHDMpPreference
    $ids = @($p.AttackSurfaceReductionRules_Ids); $acts = @($p.AttackSurfaceReductionRules_Actions)
    for ($i = 0; $i -lt $ids.Count; $i++) { if ($ids[$i]) { $map[([string]$ids[$i]).ToLowerInvariant()] = [int]$acts[$i] } }
    return $map
}

function Get-WHDAsrName {
    [CmdletBinding()]
    [OutputType([string])]
    param([int]$Code)
    switch ($Code) { 0 { 'off' } 1 { 'block' } 2 { 'audit' } 6 { 'warn' } default { 'code {0}' -f $Code } }
}

function Get-WHDTimeTriggerState {
    # Windows Time service start triggers: Active = in use now (sc.exe, one GUID line per trigger, any
    # language); Saved = trigger entries in the registry (used at the next start-up).
    [CmdletBinding()]
    param()
    $q = Invoke-WHDNative -Exe 'sc.exe' -ArgList @('qtriggerinfo', 'w32time')
    $guid = '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
    $lines = @($q.Out | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -and $_ -notmatch 'QueryServiceConfig2|SERVICE_NAME' })
    $active = @($lines | Where-Object { $_ -match $guid }).Count
    $saved = 0
    if (Test-Path -LiteralPath $script:WHDW32TimeTriggerKey) { $saved = @(Get-ChildItem -LiteralPath $script:WHDW32TimeTriggerKey -ErrorAction SilentlyContinue).Count }
    if (-not $active) { $lines = @() }
    [pscustomobject]@{ Active = [int]$active; Saved = [int]$saved; Lines = @($lines) }
}

function Get-WHDAuditSetting {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Guid)
    $r = Invoke-WHDNative -Exe 'auditpol.exe' -ArgList @('/get', ('/subcategory:{0}' -f $Guid), '/r')
    if ($r.Code -ne 0) { return $null }
    $row = @($r.Out | Where-Object { $_ -and $_.Trim() } | ConvertFrom-Csv -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (-not $row.Count) { return $null }
    $inc = [string]$row[0].'Inclusion Setting'
    [pscustomobject]@{ Success = ($inc -match 'Success'); Failure = ($inc -match 'Failure'); Text = $inc }
}

function Get-WHDEventLogConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LogName)
    try { $c = Get-WinEvent -ListLog $LogName -ErrorAction Stop } catch { return $null }
    [pscustomobject]@{ MaxBytes = [int64]$c.MaximumSizeInBytes; Mode = [string]$c.LogMode }
}

function Get-WHDPasswordPolicy {
    # net accounts (English Windows text, as in WHD Next 2.0). $null when the text is not understood.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $na = Invoke-WHDNative -Exe 'net.exe' -ArgList @('accounts')
    if ($na.Code -ne 0) { return $null }
    $map = [ordered]@{ MinLen = 'Minimum password length'; History = 'Length of password history'; MaxAge = 'Maximum password age'
                       Threshold = 'Lockout threshold'; Duration = 'Lockout duration'; Window = 'Lockout observation window' }
    $o = @{}
    foreach ($k in $map.Keys) {
        $line = @($na.Out | Where-Object { $_ -like ('{0}*' -f $map[$k]) })
        if (-not $line.Count) { return $null }
        $raw = (($line[0] -split ':', 2)[1]).Trim()
        if ($raw -match '^\d+$') { $o[$k] = [int]$raw } elseif ($raw -match '^(Never|None|Unlimited)$') { $o[$k] = 0 } else { return $null }
    }
    return $o
}

# ---- one item per target, and the "your choice" rule ---------------------------
function Get-WHDVerifyKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Entry)
    $e = $Entry
    $k = switch ([string]$e['Kind']) {
        'reg'         { 'reg|{0}|{1}' -f $e['Path'], $e['Name'] }
        'service'     { 'svc|{0}' -f $e['Service'] }
        'feature'     { 'feat|{0}' -f $e['Feature'] }
        'appx'        { 'appx|{0}' -f $e['Package'] }
        'provisioned' { 'prov|{0}' -f $e['Package'] }
        'auditpol'    { 'audit|{0}' -f $e['Guid'] }
        'eventlog'    { 'evt|{0}' -f $e['LogName'] }
        'fwrule'      { 'fw|{0}' -f $e['RuleName'] }
        'mppref'      { 'mp|{0}' -f $e['Setting'] }
        'asr'         { 'asr|{0}' -f $e['RuleId'] }
        'netacct'     { 'pw|{0}' -f $e['Setting'] }
        'schtask'     { 'task|{0}{1}' -f $e['TaskPath'], $e['TaskName'] }
        'task'        { 'utask|{0}{1}' -f $e['TaskPath'], $e['TaskName'] }
        'pnpdev'      { 'pnp|{0}' -f $e['InstanceId'] }
        'deprov'      { 'deprov|{0}' -f $e['Pfn'] }
        'fwlog'       { 'fwlog|{0}' -f $e['Profile'] }
        'tz'          { 'tz|system' }
        'svctrigger'  { 'svctrig|{0}' -f $e['Service'] }
        'file'        { 'file|{0}' -f $e['Path'] }
        default       { return ('act|{0}' -f $e['Id']) }
    }
    return $k.ToLowerInvariant()
}

function Test-WHDUserChoice {
    # Camera, microphone, radios, location: "off but not locked" - only the consent-store switch value counts.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][hashtable]$Entry)
    if ([string]$Entry['Kind'] -ne 'reg' -or [string]$Entry['Name'] -ne 'Value') { return $false }
    foreach ($cap in $script:WHDPrivacyLockKeep) {
        if ([string]$Entry['Path'] -match ('\\CapabilityAccessManager\\ConsentStore\\{0}(\\NonPackaged)?$' -f [regex]::Escape($cap))) { return $true }
    }
    return $false
}

# ---- the check of one entry ------------------------------------------------------
function Test-WHDJournalEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Entry)
    $e = $Entry
    $r = [ordered]@{ Result = 'n/a'; Now = ''; Target = ''; Kind = [string]$e['Kind']; Id = [string]$e['Id']; Session = [string]$e['Session']; Entry = $e }   # Entry: for re-apply / re-remove (step 6)
    try {
        switch ([string]$e['Kind']) {
            'reg' {
                $r.Target = '{0}\{1}' -f $e['Path'], $e['Name']
                $s = Get-WHDRegValueState -Path ([string]$e['Path']) -Name ([string]$e['Name'])
                $r.Now = if ($s.Exists) { [string]$s.Value } else { '(missing)' }
                if (-not $e['NewExists']) { $r.Result = if ($s.Exists) { 'CHANGED' } else { 'PASS' } }
                elseif (-not $s.Exists) { $r.Result = 'CHANGED' }
                else { $r.Result = if (Test-WHDRegValueEqual -A $s.Value -B $e['NewValue'] -Type ([string]$e['NewType'])) { 'PASS' } else { 'CHANGED' } }
            }
            'service' {
                $r.Target = 'service {0}' -f $e['Service']
                $svc = Get-Service -Name ([string]$e['Service']) -ErrorAction SilentlyContinue
                if (-not $svc) { $r.Now = '(not found)'; $r.Result = 'PASS' }
                else { $r.Now = [string]$svc.StartType; $r.Result = if ($r.Now -eq [string]$e['NewStartType']) { 'PASS' } else { 'CHANGED' } }
            }
            'svctrigger' {
                $r.Target = 'service {0}: Windows'' own start triggers' -f $e['Service']
                $ts = Get-WHDTimeTriggerState
                $r.Now = if ($ts.Active) { '{0} in use' -f $ts.Active } elseif ($ts.Saved) { 'none in use, {0} in the registry (count after a restart)' -f $ts.Saved } else { 'none' }
                $present = [bool]($ts.Active -or $ts.Saved)
                if ([string]$e['NewState'] -eq 'on') { $r.Result = if ($present) { 'PASS' } else { 'CHANGED' } }
                else { $r.Result = if ($present) { 'CHANGED' } else { 'PASS' } }
            }
            'feature' {
                $r.Target = 'feature {0}' -f $e['Feature']
                try { $f = Get-WindowsOptionalFeature -Online -FeatureName ([string]$e['Feature']) -ErrorAction Stop; $r.Now = [string]$f.State; $r.Result = if ($r.Now -eq 'Enabled') { 'CHANGED' } else { 'PASS' } }
                catch { $r.Now = '(not present)'; $r.Result = 'PASS' }
            }
            'appx' {
                $r.Target = 'app {0}' -f $e['Package']
                $n = @(Get-AppxPackage -AllUsers -Name ([string]$e['Package']) -ErrorAction SilentlyContinue).Count
                $r.Now = if ($n) { 'installed' } else { 'absent' }; $r.Result = if ($n) { 'RETURNED' } else { 'PASS' }
            }
            'provisioned' {
                $r.Target = 'provisioned {0}' -f $e['Package']
                $n = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq [string]$e['Package'] }).Count
                $r.Now = if ($n) { 'provisioned' } else { 'absent' }; $r.Result = if ($n) { 'RETURNED' } else { 'PASS' }
            }
            'auditpol' {
                $r.Target = 'audit {0}' -f $e['Subcategory']
                $a = Get-WHDAuditSetting -Guid ([string]$e['Guid'])
                if ($a) { $r.Now = 'success={0} failure={1}' -f $a.Success, $a.Failure; $r.Result = if ($a.Success -eq [bool]$e['NewSuccess'] -and $a.Failure -eq [bool]$e['NewFailure']) { 'PASS' } else { 'CHANGED' } }
                else { $r.Now = '(unreadable)' }
            }
            'eventlog' {
                $r.Target = 'event log {0}' -f $e['LogName']
                $c = Get-WHDEventLogConfig -LogName ([string]$e['LogName'])
                if ($c) { $r.Now = '{0:N0} MB, {1}' -f ($c.MaxBytes / 1MB), $c.Mode; $r.Result = if ($c.MaxBytes -eq [int64]$e['NewMaxBytes'] -and $c.Mode -eq [string]$e['NewMode']) { 'PASS' } else { 'CHANGED' } }
                else { $r.Now = '(unreadable)' }
            }
            'mppref' {
                $r.Target = 'Defender {0}' -f $e['Setting']
                $v = [int](Get-WHDMpPreference).([string]$e['Setting']); $r.Now = [string]$v
                $r.Result = if ($v -eq [int]$e['NewValue']) { 'PASS' } else { 'CHANGED' }
            }
            'asr' {
                $r.Target = 'ASR {0}' -f $e['RuleName']
                $map = Get-WHDAsrCode
                $code = 0; $id = ([string]$e['RuleId']).ToLowerInvariant(); if ($map.ContainsKey($id)) { $code = $map[$id] }
                $r.Now = Get-WHDAsrName -Code $code
                $r.Result = if ($code -eq [int]$e['NewAction']) { 'PASS' } else { 'CHANGED' }
            }
            'deprov' {
                $r.Target = 'deprovisioned mark {0}' -f $e['Pfn']
                $has = Test-Path -LiteralPath (Join-Path $script:WHDDeprovKey ([string]$e['Pfn']))
                $r.Now = if ($has) { 'present' } else { '(missing)' }; $r.Result = if ($has) { 'PASS' } else { 'CHANGED' }
            }
            'fwlog' {
                $r.Target = 'firewall log {0}' -f $e['Profile']
                $fp = (Get-NetFirewallProfile -Name ([string]$e['Profile']) -ErrorAction SilentlyContinue | Select-Object -First 1)
                if ($fp) {
                    $r.Now = 'allowed={0} blocked={1} size={2} KB' -f $fp.LogAllowed, $fp.LogBlocked, $fp.LogMaxSizeKilobytes
                    $ok = ([string]$fp.LogAllowed -eq [string]$e['NewAllowed']) -and ([string]$fp.LogBlocked -eq [string]$e['NewBlocked']) -and ([int64]$fp.LogMaxSizeKilobytes -eq [int64]$e['NewSizeKB'])
                    $r.Result = if ($ok) { 'PASS' } else { 'CHANGED' }
                } else { $r.Now = '(unreadable)' }
            }
            'tz' {
                $r.Target = 'time zone'
                $r.Now = [string](Get-TimeZone -ErrorAction SilentlyContinue).Id
                $r.Result = if ($r.Now -eq [string]$e['NewId']) { 'PASS' } else { 'CHANGED' }
            }
            'pnpdev' {
                $r.Target = 'device {0}' -f $e['Name']
                $d = (Get-PnpDevice -InstanceId ([string]$e['InstanceId']) -ErrorAction SilentlyContinue | Select-Object -First 1)
                $want = [bool]$e['NewEnabled']
                if (-not $d) { $r.Now = '(gone)'; $r.Result = if ($want) { 'CHANGED' } else { 'PASS' } }
                elseif (-not $d.Present -and -not $want) { $r.Now = 'not present (checked again when it comes back)'; $r.Result = 'PASS' }
                else {
                    $isOn = -not ([string]$d.ConfigManagerErrorCode -match 'DISABLED|^22$')
                    $r.Now = if ($isOn) { 'enabled ({0})' -f $d.Status } else { 'disabled' }
                    $r.Result = if ($isOn -eq $want) { 'PASS' } else { 'CHANGED' }
                }
            }
            'task' {
                $r.Target = 'task {0}{1}' -f $e['TaskPath'], $e['TaskName']
                $t = (Get-ScheduledTask -TaskPath ([string]$e['TaskPath']) -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -eq [string]$e['TaskName'] } | Select-Object -First 1)
                if (-not $t) { $r.Now = '(gone)'; $r.Result = 'PASS' }
                else {
                    $isOn = ([string]$t.State -ne 'Disabled')
                    if ($null -ne $t.Settings -and $null -ne $t.Settings.Enabled) { $isOn = [bool]$t.Settings.Enabled }
                    $r.Now = if ($isOn) { [string]$t.State } elseif ([string]$t.State -eq 'Running') { 'Disabled (last run finishing)' } else { 'Disabled' }
                    $r.Result = if ($isOn -eq [bool]$e['NewEnabled']) { 'PASS' } else { 'CHANGED' }
                }
            }
            'schtask' {
                $r.Target = 'scheduled task {0}{1}' -f $e['TaskPath'], $e['TaskName']
                $t = (Get-ScheduledTask -TaskPath ([string]$e['TaskPath']) -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -eq [string]$e['TaskName'] } | Select-Object -First 1)
                $copy = [bool]$e['GuardDir'] -and (Test-Path -LiteralPath (Join-Path ([string]$e['GuardDir']) 'WHD.ps1'))
                if (-not $t) { $r.Now = 'missing'; $r.Result = 'CHANGED' }
                else { $r.Now = [string]$t.State + $(if ($copy) { '' } else { ', protected copy missing' }); $r.Result = if ([string]$t.State -ne 'Disabled' -and $copy) { 'PASS' } else { 'CHANGED' } }
            }
            'netacct' {
                $r.Target = 'password policy {0}' -f $e['Setting']
                $pp = Get-WHDPasswordPolicy
                if ($pp) { $v = [int]$pp[[string]$e['Setting']]; $r.Now = [string]$v; $r.Result = if ($v -eq [int]$e['NewValue']) { 'PASS' } else { 'CHANGED' } }
                else { $r.Now = '(unreadable)' }
            }
            'fwrule' {
                $r.Target = 'firewall rule {0}' -f $e['RuleName']
                $n = @(Get-NetFirewallRule -Name ([string]$e['RuleName']) -ErrorAction SilentlyContinue).Count
                $r.Now = if ($n) { 'present' } else { 'missing' }; $r.Result = if ($n) { 'PASS' } else { 'CHANGED' }
            }
            'file' {
                $r.Target = 'file {0}' -f $e['Path']
                if (-not (Test-Path -LiteralPath ([string]$e['Path']))) { $r.Now = '(missing)'; $r.Result = 'CHANGED' }
                else { $h = (Get-FileHash -LiteralPath ([string]$e['Path']) -Algorithm SHA256).Hash; $r.Now = $h.Substring(0, 12); $r.Result = if ($h -eq [string]$e['NewHash']) { 'PASS' } else { 'CHANGED' } }
            }
            default { $r.Target = [string]$e['Description']; $r.Now = '-' }
        }
    } catch {
        $r.Now = '(could not be read: {0})' -f $_.Exception.Message; $r.Result = 'n/a'
    }
    return [pscustomobject]$r
}

function Select-WHDVerifyItem {
    # From many entries (oldest first) keep the LATEST state per target; drop undone entries, actions, and
    # targets whose latest write came from an undo (Windows' own value is back - nothing to protect).
    # Same rules as WHD Next 2.0 (including older journals without the ByUndo flag: undo.jsonl BySession).
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries)
    $undoWrites = @{}
    foreach ($sp in @($Entries | ForEach-Object { [string]$_['SessionPath'] } | Where-Object { $_ } | Select-Object -Unique)) {
        $marks = @(Read-WHDJsonl -File (Join-Path $sp 'undo.jsonl'))
        if (-not $marks.Count) { continue }
        $byId = @{}; foreach ($m in $marks) { $byId[[string]$m['Id']] = $m }
        foreach ($u in @($Entries | Where-Object { [string]$_['SessionPath'] -eq $sp -and $byId.ContainsKey([string]$_['Id']) })) {
            $k = Get-WHDVerifyKey -Entry $u
            if ($k -like 'act|*') { continue }
            $m = $byId[[string]$u['Id']]
            $uk = '{0}|{1}' -f $m['BySession'], $k
            if (-not $undoWrites.ContainsKey($uk) -or [string]$m['Time'] -gt $undoWrites[$uk]) { $undoWrites[$uk] = [string]$m['Time'] }
        }
    }
    $latest = [ordered]@{}
    foreach ($e in @($Entries | Where-Object { -not $_['Undone'] })) { $latest[(Get-WHDVerifyKey -Entry $e)] = $e }
    foreach ($k in @($latest.Keys)) {
        $le = $latest[$k]
        $uk = '{0}|{1}' -f $le['Session'], $k
        if ($le['ByUndo'] -or ($undoWrites.ContainsKey($uk) -and [string]$le['Time'] -le $undoWrites[$uk])) { $latest.Remove($k) }
    }
    return @($latest.Values | Where-Object { [string]$_['Kind'] -ne 'action' })
}
