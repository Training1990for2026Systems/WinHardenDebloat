#requires -Version 5.1
<#
  Check-InstalledPc.ps1   (WHD USB Image)

  Run on the PC that was installed from the stick. It only READS and writes a report: what of the image
  and of the first sign-in script is in place on the running Windows, and what came back.
  It changes nothing on the PC.

  It reads the three lists next to it (remove-list.txt, image-settings.txt, first-signin\first-signin-list.txt)
  and compares them with the running Windows:
    1. Did Windows Setup start the first sign-in script? (its log - who started it, from where -, the
       answer file Setup kept)
    2. The registry values and services of image-settings.txt: still as the image set them?
    3. The apps and features of remove-list.txt: still gone, or back?
    4. What the first sign-in script set: Defender, password rules, NetBIOS, DNS, OneDrive, firewall, UAC.
       When WHD Classic or WHD Next has put its own firewall rules in place since, it says so and does
       not count the script's rules as missing.
    5. Other things worth knowing after an install: programs, devices without a driver, the devices on the
       deny list, C:\Windows.old.

  Rules it keeps:
    - Read-only on the PC. Only Windows PowerShell and commands built into Windows. No downloads, no web calls.
    - It writes only into its own folder: test-results\<date_time>\ (report.txt and copies of the logs).
      The report names this PC's hardware and programs: keep it private (.gitignore leaves it out of Git).
    - A part that cannot be read is reported and the script goes on.

  Run from an administrator Windows PowerShell (without administrator rights some parts are left out):
    powershell -ExecutionPolicy Bypass -File .\Check-InstalledPc.ps1
#>
param(
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'

$root     = $PSScriptRoot
$stamp    = Get-Date -Format 'yyyy-MM-dd_HHmmss'
if (-not $OutDir) { $OutDir = Join-Path (Join-Path $root 'test-results') $stamp }
$report   = Join-Path $OutDir 'report.txt'
$listFile = Join-Path $root 'remove-list.txt'
$setFile  = Join-Path $root 'image-settings.txt'
$fsList   = Join-Path (Join-Path $root 'first-signin') 'first-signin-list.txt'
$dataDir  = Join-Path $env:ProgramData 'WHD-Image'
$scriptsDir = Join-Path $env:SystemRoot 'Setup\Scripts'
$fwGroup  = 'WinHardenDebloat-AllowList'
# Rule groups of WHD Classic ("WinHardenDebloat-...") and WHD Next ("WinHardenDebloatNext-...").
$fwWhdPattern = '^WinHardenDebloat(Next)?-'

$script:asSet     = 0     # things that are as the image / the script set them
$script:different = 0     # things that are not
$script:cameBack  = 0     # removed apps that are there again
$script:problems  = 0     # parts that could not be read

function Say([string]$Text) {
    Write-Host $Text
    try { Add-Content -LiteralPath $report -Value $Text -Encoding Ascii -ErrorAction Stop } catch { }
}

function Good([string]$Text) { $script:asSet++;     Say "    ok        $Text" }
function Bad([string]$Text)  { $script:different++; Say "    DIFFERENT $Text" }
function Info([string]$Text) { Say "    $Text" }

# Runs one part of the report. A part that fails is noted and the next one runs.
function Invoke-Part([string]$PartTitle, [scriptblock]$PartBody) {
    Say ''
    Say "=== $PartTitle ==="
    try { & $PartBody }
    catch {
        $script:problems++
        Say ('    (this part stopped: {0})' -f $_.Exception.Message)
    }
}

function Invoke-Native([string]$Exe, [string[]]$ArgList) {
    $ErrorActionPreference = 'Continue'
    $out  = & $Exe @ArgList 2>&1
    $code = $LASTEXITCODE
    $text = @()
    foreach ($o in @($out)) { $text += [string]$o }
    return (New-Object PSObject -Property @{ Code = $code; Out = $text })
}

# One registry value. Returns Exists and Value.
function Get-Reg([string]$Path, [string]$Name) {
    try {
        $p = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return (New-Object PSObject -Property @{ Exists = $true; Value = $p.$Name })
    } catch {
        return (New-Object PSObject -Property @{ Exists = $false; Value = $null })
    }
}

function Copy-ToResults([string]$File, [string]$NewName) {
    try {
        Copy-Item -LiteralPath $File -Destination (Join-Path $OutDir $NewName) -Force -ErrorAction Stop
        Info "copied to the results folder: $NewName"
    } catch { Info ('could not copy {0}: {1}' -f $File, $_.Exception.Message) }
}

# ---- the three lists (read loosely: the build scripts are the ones that check them strictly) ----------
function Read-ImageSettings {
    $plan = New-Object PSObject -Property @{ Parts = @{}; Regs = @(); Services = @(); Found = $false }
    if (-not (Test-Path -LiteralPath $setFile)) { return $plan }
    $plan.Found = $true
    $group = ''; $on = $false
    foreach ($raw in (Get-Content -LiteralPath $setFile)) {
        $t = ([string]$raw).Trim()
        if ((-not $t) -or $t.StartsWith('#')) { continue }
        if ($t -match '^part:([a-z-]+)\s+(on|off)$') { $plan.Parts[$Matches[1]] = ($Matches[2] -eq 'on') }
        elseif ($t -match '^group:([a-z0-9-]+)\s+(on|off)$') { $group = $Matches[1]; $on = ($Matches[2] -eq 'on') }
        elseif ($t -match '^service-off:([A-Za-z0-9._-]+)$') { if ($on) { $plan.Services += (New-Object PSObject -Property @{ Name = $Matches[1]; Group = $group }) } }
        elseif ($t.StartsWith('reg:')) {
            $f = @($t.Substring(4) -split '\|')
            if (($f.Count -eq 5) -and $on) {
                $plan.Regs += (New-Object PSObject -Property @{ Group = $group; Hive = $f[0]; Key = $f[1]; Name = $f[2]; Type = $f[3]; Data = $f[4] })
            }
        }
    }
    return $plan
}

function Read-RemoveList {
    $plan = New-Object PSObject -Property @{ Apps = @(); Features = @(); Capabilities = @(); Services = @() }
    if (-not (Test-Path -LiteralPath $listFile)) { return $plan }
    foreach ($raw in (Get-Content -LiteralPath $listFile)) {
        $t = ([string]$raw).Trim()
        if ($t -match '^app:([A-Za-z0-9._-]+)$') { $plan.Apps += $Matches[1] }
        elseif ($t -match '^feature:([A-Za-z0-9._-]+)$') { $plan.Features += $Matches[1] }
        elseif ($t -match '^capability:([A-Za-z0-9._~-]+)$') { $plan.Capabilities += $Matches[1] }
        elseif ($t -match '^service-off:([A-Za-z0-9._-]+)$') { $plan.Services += $Matches[1] }
    }
    return $plan
}

function Read-FirstSignInList {
    $plan = New-Object PSObject -Property @{ Parts = @{}; Asr = @(); Dns = @(); Doh = ''; FwRules = @(); Found = $false }
    if (-not (Test-Path -LiteralPath $fsList)) { return $plan }
    $plan.Found = $true
    foreach ($raw in (Get-Content -LiteralPath $fsList)) {
        $t = ([string]$raw).Trim()
        if ((-not $t) -or $t.StartsWith('#')) { continue }
        if ($t -match '^part:([a-z-]+)\s+(on|off)$') { $plan.Parts[$Matches[1]] = ($Matches[2] -eq 'on') }
        elseif ($t -match '^asr:([0-9A-Fa-f-]{36})\|(block|audit|warn|off)\|(.+)$') {
            $code = 0
            $action = $Matches[2].ToLowerInvariant()
            $id = $Matches[1].ToLowerInvariant(); $name = $Matches[3].Trim()
            switch ($action) { 'block' { $code = 1 } 'audit' { $code = 2 } 'warn' { $code = 6 } }
            $plan.Asr += (New-Object PSObject -Property @{ Id = $id; Action = $action; Code = $code; Name = $name })
        }
        elseif ($t -match '^dns:(.+)$') { $plan.Dns += $Matches[1].Trim() }
        elseif ($t -match '^doh:(.+)$') { $plan.Doh = $Matches[1].Trim() }
        elseif ($t.StartsWith('fw-allow:')) {
            $f = @($t.Substring(9) -split '\|')
            if ($f.Count -eq 7) { $plan.FwRules += $f[0].Trim() }
        }
    }
    return $plan
}

# ---------------------------------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------------------------------
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
Say 'WHD USB Image - check of the installed PC (read-only)'
Say ('Written {0} by Check-InstalledPc.ps1. This report names hardware and programs of this PC: keep it private.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

$isAdmin = $false
try {
    $me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

$settings = Read-ImageSettings
$removes  = Read-RemoveList
$first    = Read-FirstSignInList

Invoke-Part 'THIS WINDOWS' {
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    Info ('edition {0}, version {1}, build {2}.{3}' -f $cv.EditionID, $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR)
    try { Info ('installed: {0}' -f ([DateTime]'1970-01-01').AddSeconds([double]$cv.InstallDate).ToLocalTime().ToString('yyyy-MM-dd HH:mm')) } catch { }
    Info ('PowerShell {0}; administrator window: {1}' -f $PSVersionTable.PSVersion, $isAdmin)
    if (-not $isAdmin) { Say '    NOTE: not an administrator window. Apps of all users, features and Setup logs cannot be read; those parts say so.' }
    Info ('lists read from: {0}' -f $root)
    if (-not $settings.Found) { Info 'image-settings.txt not found next to this script' }
    if (-not $first.Found) { Info 'first-signin\first-signin-list.txt not found next to this script' }
}

Invoke-Part '1. DID SETUP START THE FIRST SIGN-IN SCRIPT?' {
    $inImage = Join-Path $scriptsDir 'WHD-FirstSignIn.ps1'
    if (Test-Path -LiteralPath $inImage) { Info "the script is on this PC: $inImage (so this Windows came from the changed image)" }
    else { Info "the script is NOT at $inImage - this Windows did not come from an image with part first-signin" }

    $applied = Join-Path $scriptsDir 'WHD-Image-applied.txt'
    if (Test-Path -LiteralPath $applied) { Copy-ToResults $applied 'WHD-Image-applied.txt' } else { Info 'WHD-Image-applied.txt (the record of the image run) is not on this PC' }

    $fsLog = Join-Path $dataDir 'FirstSignIn.log'
    if (Test-Path -LiteralPath $fsLog) {
        Good "the first sign-in script ran: $fsLog exists"
        Copy-ToResults $fsLog 'FirstSignIn.log'
        $lines = @(Get-Content -LiteralPath $fsLog)
        foreach ($l in @($lines | Where-Object { $_ -match 'started|Started by|  List: |RESULT:|FAILED:|STOPPED' })) { Info ('    ' + ([string]$l).Trim()) }
        # Who started it? The answer file gives -FromSetup, and the script then writes that line.
        # A copy started from another folder than Windows\Setup\Scripts was started by hand.
        $bySetup = @($lines | Where-Object { $_ -match 'Started by Windows Setup' }).Count
        $fromImage = @($lines | Where-Object { ($_ -match '  List: ') -and ($_ -like ('*' + $scriptsDir + '*')) }).Count
        $starts = @($lines | Where-Object { $_ -match '=== WHD-FirstSignIn started' }).Count
        if ($bySetup -gt 0) { Good ('Windows Setup started the script itself: {0} of {1} start(s) in the log' -f $bySetup, $starts) }
        else { Info ('none of the {0} start(s) in the log was made by Windows Setup ({1} from {2}; the others from another folder, by hand)' -f $starts, $fromImage, $scriptsDir) }
        $skipped = @($lines | Where-Object { $_ -match '    skipped:' })
        if ($skipped.Count -gt 0) { Info ("    skipped lines in that log: {0} (see the copy)" -f $skipped.Count) }
    } else {
        Bad "the first sign-in script did NOT run: $fsLog is not there"
    }
    $doneFile = Join-Path $dataDir 'FirstSignIn.done'
    if (Test-Path -LiteralPath $doneFile) { Info ('FirstSignIn.done: ' + ((Get-Content -LiteralPath $doneFile) -join ' / ')) }

    # What Setup kept of the answer file.
    foreach ($cand in @((Join-Path $env:SystemRoot 'Panther\unattend.xml'), (Join-Path $env:SystemRoot 'Panther\Unattend\unattend.xml'), (Join-Path $env:SystemRoot 'System32\Sysprep\unattend.xml'))) {
        if (Test-Path -LiteralPath $cand) {
            $hit = $false
            try { $hit = [bool](Select-String -LiteralPath $cand -Pattern 'WHD-FirstSignIn' -SimpleMatch -Quiet -ErrorAction Stop) } catch { }
            Info ('Setup kept an answer file: {0} (names our script: {1})' -f $cand, $hit)
        } else { Info "no answer file at $cand" }
    }
    $found = 0
    foreach ($logFile in @((Join-Path $env:SystemRoot 'Panther\UnattendGC\setupact.log'), (Join-Path $env:SystemRoot 'Panther\setupact.log'))) {
        if (-not (Test-Path -LiteralPath $logFile)) { continue }
        try {
            $hits = @(Select-String -LiteralPath $logFile -Pattern 'FirstLogonCommands|WHD-FirstSignIn|Autounattend' -ErrorAction Stop | Select-Object -Last 15)
            foreach ($h in $hits) { $found++; Info ('    {0}: {1}' -f (Split-Path -Leaf (Split-Path -Parent $logFile)), ([string]$h.Line).Trim()) }
        } catch { Info ('could not read {0}: {1}' -f $logFile, $_.Exception.Message) }
    }
    if ($found -eq 0) { Info "Setup's own logs have no line about the first-logon command or the answer file (or they could not be read)" }
}

Invoke-Part '2. SETTINGS OF THE IMAGE (image-settings.txt) - STILL IN PLACE?' {
    if (-not $settings.Found) { Info 'image-settings.txt not found - part left out'; return }
    if (-not $settings.Parts['machine-settings']) { Info 'part machine-settings is off in image-settings.txt - nothing to compare'; return }
    $groups = @()
    foreach ($r in $settings.Regs) { if ($groups -notcontains $r.Group) { $groups += $r.Group } }
    foreach ($g in $groups) {
        $lines = @(); $okCount = 0
        $ops = @($settings.Regs | Where-Object { $_.Group -eq $g })
        foreach ($op in $ops) {
            if ($op.Hive -eq 'SYSTEM') { $path = 'HKLM:\SYSTEM\CurrentControlSet\' + $op.Key } else { $path = 'HKLM:\SOFTWARE\' + $op.Key }
            $have = Get-Reg $path $op.Name
            if (-not $have.Exists) { $lines += ('{0} : {1} is GONE (the image set {2})' -f $path, $op.Name, $op.Data); continue }
            $same = $false
            if ($op.Type -eq 'dword') { try { $same = ([int64]$have.Value -eq [int64]$op.Data) } catch { } } else { $same = ("$($have.Value)" -eq $op.Data) }
            if ($same) { $okCount++ } else { $lines += ('{0} : {1} is now {2} (the image set {3})' -f $path, $op.Name, $have.Value, $op.Data) }
        }
        if ($lines.Count -eq 0) { $script:asSet += $okCount; Say ('    ok        group {0}: all {1} value(s) as set' -f $g, $ops.Count) }
        else {
            $script:asSet += $okCount
            Say ('    DIFFERENT group {0}: {1} of {2} value(s) as set' -f $g, $okCount, $ops.Count)
            foreach ($l in $lines) { $script:different++; Say "                  $l" }
        }
    }
    Say ''
    Say '    services the image set to disabled:'
    $svcList = @()
    foreach ($s in $removes.Services) { $svcList += (New-Object PSObject -Property @{ Name = $s; Group = 'remove-list' }) }
    $svcList += $settings.Services
    foreach ($s in $svcList) {
        $start = Get-Reg ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $s.Name) 'Start'
        if (-not $start.Exists) { Info ('service {0} [{1}]: not on this PC' -f $s.Name, $s.Group); continue }
        $state = '?'
        try { $state = "$((Get-Service -Name $s.Name -ErrorAction Stop).Status)" } catch { }
        if ([int]$start.Value -eq 4) { Good ('service {0} [{1}]: disabled, {2}' -f $s.Name, $s.Group, $state) }
        else { Bad ('service {0} [{1}]: Start is now {2} (the image set 4), {3}' -f $s.Name, $s.Group, $start.Value, $state) }
    }
}

Invoke-Part '3. APPS AND FEATURES TAKEN OUT OF THE IMAGE (remove-list.txt) - STILL GONE?' {
    if ($removes.Apps.Count -eq 0) { Info 'remove-list.txt names no app (or was not found)' }
    $all = $null; $prov = $null
    if ($isAdmin) {
        try { $all = @(Get-AppxPackage -AllUsers -ErrorAction Stop) } catch { Info ('apps of all users could not be read: {0}' -f $_.Exception.Message) }
        try { $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop) } catch { Info ('the apps set up for new users could not be read: {0}' -f $_.Exception.Message) }
    } else {
        try { $all = @(Get-AppxPackage -ErrorAction Stop) } catch { }
        Info 'not an administrator window: only the apps of this user are looked at'
    }
    $markBase = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned'
    $marks = @()
    try { $marks = @(Get-ChildItem -LiteralPath $markBase -ErrorAction Stop | ForEach-Object { $_.PSChildName }) } catch { }
    Info ('"do not bring back" marks on this PC: {0}' -f $marks.Count)
    $gone = 0
    foreach ($a in $removes.Apps) {
        $inst = @(); $isProv = $false
        if ($null -ne $all)  { $inst = @($all | Where-Object { $_.Name -eq $a }) }
        if ($null -ne $prov) { $isProv = (@($prov | Where-Object { $_.DisplayName -eq $a }).Count -gt 0) }
        $hasMark = (@($marks | Where-Object { $_ -like ($a + '_*') }).Count -gt 0)
        if (($inst.Count -eq 0) -and (-not $isProv)) { $gone++; continue }
        $script:cameBack++
        $ver = ''
        if ($inst.Count -gt 0) { $ver = "$($inst[0].Version)" }
        Say ('    CAME BACK {0}   installed: {1} {2}   set up for new users: {3}   mark present: {4}' -f $a, ($inst.Count -gt 0), $ver, $isProv, $hasMark)
    }
    Say ('    still gone: {0} of {1} app(s)' -f $gone, $removes.Apps.Count)
    if ($null -ne $all) {
        $rows = @('Name;Version;SignatureKind;NonRemovable;PackageFamilyName')
        foreach ($p in @($all | Sort-Object Name)) { $rows += ('{0};{1};{2};{3};{4}' -f $p.Name, $p.Version, $p.SignatureKind, $p.NonRemovable, $p.PackageFamilyName) }
        Set-Content -LiteralPath (Join-Path $OutDir 'apps-installed.txt') -Value $rows -Encoding Ascii
        Info ('all {0} installed app package(s) listed in apps-installed.txt' -f $all.Count)
    }
    foreach ($f in $removes.Features) {
        if (-not $isAdmin) { Info "feature $f : needs an administrator window"; continue }
        try {
            $state = "$((Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction Stop).State)"
            if ($state -like 'Disabled*') { Good "feature $f : $state" } else { Bad "feature $f : $state (the image switched it off)" }
        } catch { Info ('feature {0} : could not be read ({1})' -f $f, $_.Exception.Message) }
    }
}

Invoke-Part '4a. FIRST SIGN-IN: MICROSOFT DEFENDER' {
    if (-not (Get-Command Get-MpPreference -ErrorAction SilentlyContinue)) { Info 'the Defender commands are not on this PC'; return }
    $st = Get-MpComputerStatus -ErrorAction Stop
    Info ('antivirus on: {0}, mode: {1}, real-time: {2}, tamper protection: {3}' -f $st.AntivirusEnabled, $st.AMRunningMode, $st.RealTimeProtectionEnabled, $st.IsTamperProtected)
    $mp = Get-MpPreference -ErrorAction Stop
    foreach ($pair in @(@('defender-pua', 'PUAProtection'), @('defender-network-protection', 'EnableNetworkProtection'), @('defender-folder-protection', 'EnableControlledFolderAccess'))) {
        $now = [int]$mp.($pair[1])
        if (-not $first.Parts[$pair[0]]) { Info ('{0} = {1} (part {2} is off in the list)' -f $pair[1], $now, $pair[0]); continue }
        if ($now -eq 1) { Good ('{0} = 1' -f $pair[1]) } else { Bad ('{0} = {1} (the script sets 1)' -f $pair[1], $now) }
    }
    if ($first.Parts['defender-asr']) {
        $map = @{}
        $ids = @($mp.AttackSurfaceReductionRules_Ids); $acts = @($mp.AttackSurfaceReductionRules_Actions)
        for ($i = 0; $i -lt $ids.Count; $i++) { if ($ids[$i]) { $map["$($ids[$i])".ToLowerInvariant()] = [int]$acts[$i] } }
        $okRules = 0
        foreach ($r in $first.Asr) {
            $now = 0
            if ($map.ContainsKey($r.Id)) { $now = [int]$map[$r.Id] }
            if ($now -eq $r.Code) { $okRules++; $script:asSet++ } else { Bad ('attack-surface rule is action {0}, list says {1} ({2}): {3}' -f $now, $r.Code, $r.Action, $r.Name) }
        }
        if ($okRules -eq $first.Asr.Count) { Say ('    ok        attack-surface rules as listed: {0} of {1}' -f $okRules, $first.Asr.Count) }
        else { Info ('attack-surface rules as listed: {0} of {1} (the others are the DIFFERENT lines above)' -f $okRules, $first.Asr.Count) }
    }
}

Invoke-Part '4b. FIRST SIGN-IN: PASSWORD RULES, NETBIOS, DNS, UAC' {
    $na = Invoke-Native 'net.exe' @('accounts')
    foreach ($l in $na.Out) { if (([string]$l).Trim()) { Info ('net accounts: ' + ([string]$l).Trim()) } }

    $base = 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces'
    $keys = @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'Tcpip_*' })
    $off = 0
    foreach ($k in $keys) { $v = Get-Reg $k.PSPath 'NetbiosOptions'; if ($v.Exists -and ([int]$v.Value -eq 2)) { $off++ } }
    if ($first.Parts['netbios-off']) {
        if (($keys.Count -gt 0) -and ($off -eq $keys.Count)) { Good ('NetBIOS off on all {0} adapter entry(ies)' -f $keys.Count) }
        else { Bad ('NetBIOS off on {0} of {1} adapter entry(ies)' -f $off, $keys.Count) }
    } else { Info ('NetBIOS off on {0} of {1} adapter entry(ies) (part is off in the list)' -f $off, $keys.Count) }

    foreach ($a in @(Get-NetAdapter -ErrorAction SilentlyContinue)) {
        $dns = ''
        try { $dns = ((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses -join ', ') } catch { }
        $line = 'adapter {0} ({1}): {2}, DNS: {3}' -f $a.Name, $a.InterfaceDescription, $a.Status, $dns
        if (("$($a.Status)" -eq 'Up') -and $first.Parts['dns']) {
            if ($dns -eq ($first.Dns -join ', ')) { Good $line } else { Bad ($line + ('   (the list says {0})' -f ($first.Dns -join ', '))) }
        } else { Info $line }
    }
    if (Get-Command Get-DnsClientDohServerAddress -ErrorAction SilentlyContinue) {
        foreach ($ip in $first.Dns) {
            $d = @(Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue)
            if ($d.Count -gt 0) { Info ('encrypted DNS for {0}: {1}, fall-back to plain: {2}, auto-upgrade: {3}' -f $ip, $d[0].DohTemplate, $d[0].AllowFallbackToUdp, $d[0].AutoUpgrade) }
            else { Info "encrypted DNS for $ip : not registered" }
        }
    }

    $uacKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $c = Get-Reg $uacKey 'ConsentPromptBehaviorAdmin'; $sd = Get-Reg $uacKey 'PromptOnSecureDesktop'; $lua = Get-Reg $uacKey 'EnableLUA'
    $uacText = 'UAC: EnableLUA {0}, ConsentPromptBehaviorAdmin {1}, PromptOnSecureDesktop {2}' -f $lua.Value, $c.Value, $sd.Value
    if ($first.Parts['uac-always-notify']) {
        if ($c.Exists -and ([int]$c.Value -eq 2) -and $sd.Exists -and ([int]$sd.Value -eq 1)) { Good ($uacText + ' = Always notify') } else { Bad ($uacText + ' (the script sets 2 and 1 = Always notify)') }
    } else { Info $uacText }
}

Invoke-Part '4c. FIRST SIGN-IN: ONEDRIVE' {
    $found = 0
    foreach ($base in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        foreach ($k in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
            $p = $null
            try { $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop } catch { }
            if ($p -and ("$($p.DisplayName)" -like '*OneDrive*')) { $found++; Info ('installed: {0} {1}   ({2})' -f $p.DisplayName, $p.DisplayVersion, $p.UninstallString) }
        }
    }
    $run = Get-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'OneDriveSetup'
    if ($run.Exists) { Info ('start entry of the OneDrive install for this user is there: {0}' -f $run.Value) } else { Info 'no start entry of the OneDrive install for this user' }
    if ($first.Parts['onedrive-remove']) {
        if (($found -eq 0) -and (-not $run.Exists)) { Good 'OneDrive is not installed and will not install for this user' } else { Bad 'OneDrive is installed, or its install entry is still there' }
    }
}

Invoke-Part '4d. FIRST SIGN-IN: FIREWALL' {
    foreach ($p in @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop)) { Info ('profile {0}: on = {1}, inbound = {2}, outbound = {3}' -f $p.Name, $p.Enabled, $p.DefaultInboundAction, $p.DefaultOutboundAction) }
    $backup = Join-Path $dataDir 'firewall-before-first-signin.wfw'
    Info ('backup of the firewall policy from before the wipe: {0} (there: {1})' -f $backup, (Test-Path -LiteralPath $backup))
    $rules = @(Get-NetFirewallRule -ErrorAction Stop)
    $ours  = @($rules | Where-Object { "$($_.Group)" -eq $fwGroup })
    $whd   = @($rules | Where-Object { ("$($_.Group)" -match $fwWhdPattern) -and ("$($_.Group)" -ne $fwGroup) })
    $other = @($rules | Where-Object { "$($_.Group)" -notmatch $fwWhdPattern })
    Info ('rules now: {0}   in group {1}: {2}   in other groups of WHD Classic / WHD Next: {3}   others (added by Windows and apps since the wipe): {4}' -f $rules.Count, $fwGroup, $ours.Count, $whd.Count, $other.Count)
    foreach ($g in @($whd | Group-Object Group | Sort-Object Name)) { Info ('    {0,3} x  group {1}' -f $g.Count, $g.Name) }
    if ($first.Parts['firewall']) {
        $present = @($first.FwRules | Where-Object { $n = $_; @($rules | Where-Object { $_.Name -eq $n }).Count -gt 0 })
        if (($present.Count -eq 0) -and ($whd.Count -gt 0)) {
            # WHD Classic or WHD Next wiped the rules and put its own there: that is their work, not a fault.
            Info ("the {0} allow rule(s) of the first sign-in script are not there any more: WHD Classic / WHD Next has put its own rules in place since ({1} rule(s), see the groups above). Not counted as different." -f $first.FwRules.Count, $whd.Count)
        } else {
            foreach ($n in $first.FwRules) {
                $r = @($rules | Where-Object { $_.Name -eq $n })
                if ($r.Count -gt 0) { Good ('allow rule {0}: there, enabled {1}' -f $n, $r[0].Enabled) } else { Bad "allow rule $n is missing" }
            }
        }
    }
    $rows = @('Direction;Action;Enabled;Group;Name;DisplayName')
    foreach ($r in @($rules | Sort-Object Direction, DisplayName)) { $rows += ('{0};{1};{2};{3};{4};{5}' -f $r.Direction, $r.Action, $r.Enabled, $r.Group, $r.Name, $r.DisplayName) }
    Set-Content -LiteralPath (Join-Path $OutDir 'firewall-rules.txt') -Value $rows -Encoding Ascii
    Info 'all rules listed in firewall-rules.txt'
    $in = @($other | Where-Object { "$($_.Direction)" -eq 'Inbound' })
    Info ('other rules: {0} inbound, {1} outbound. The first 40 by name:' -f $in.Count, ($other.Count - $in.Count))
    $names = @($other | Group-Object DisplayName | Sort-Object Count -Descending | Select-Object -First 40)
    foreach ($g in $names) { Info ('    {0,3} x  {1}' -f $g.Count, $g.Name) }
}

Invoke-Part '5a. PROGRAMS (not Store apps)' {
    $seen = @()
    foreach ($base in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall')) {
        foreach ($k in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
            $p = $null
            try { $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop } catch { }
            if ($p -and "$($p.DisplayName)".Trim() -and (-not $p.SystemComponent)) {
                $line = '{0}   {1}   ({2})' -f $p.DisplayName, $p.DisplayVersion, $p.Publisher
                if ($seen -notcontains $line) { $seen += $line }
            }
        }
    }
    foreach ($l in @($seen | Sort-Object)) { Info $l }
    if ($seen.Count -eq 0) { Info '(none)' }
}

Invoke-Part '5b. DEVICES' {
    $bad = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { "$($_.Status)" -ne 'OK' })
    Info ('devices that are present and not working (no driver, or disabled): {0}' -f $bad.Count)
    foreach ($d in @($bad | Sort-Object Class, FriendlyName)) {
        # A device without a driver has no class and often no name: say so instead of leaving it empty.
        $class = "$($d.Class)".Trim();        if (-not $class) { $class = 'no class' }
        $dname = "$($d.FriendlyName)".Trim(); if (-not $dname) { $dname = '(no name)' }
        Info ('    [{0}] {1}   status {2}, problem {3}   {4}' -f $class, $dname, $d.Status, $d.ConfigManagerErrorCode, $d.InstanceId)
    }
    # The devices the image's deny list names (image-settings.txt, DeviceInstall\Restrictions\DenyDeviceIDs).
    # Windows shows a blocked device as present with an error: that is the deny list at work.
    $denyIds = @()
    foreach ($r in $settings.Regs) {
        if (("$($r.Key)" -like '*DeviceInstall\Restrictions\DenyDeviceIDs') -and ("$($r.Name)" -match '^\d+$')) { $denyIds += "$($r.Data)".ToUpperInvariant() }
    }
    if ($denyIds.Count -eq 0) { Info 'the lists name no device deny list' }
    else {
        $hits = @()
        foreach ($d in @(Get-PnpDevice -ErrorAction SilentlyContinue)) {
            $inst = "$($d.InstanceId)".ToUpperInvariant()
            foreach ($id in $denyIds) { if ($inst.Contains($id)) { $hits += $d; break } }
        }
        Info ('devices of the deny list ({0} id(s)) that Windows knows on this PC: {1}' -f $denyIds.Count, $hits.Count)
        foreach ($d in @($hits | Sort-Object InstanceId)) {
            $dname = "$($d.FriendlyName)".Trim(); if (-not $dname) { $dname = '(no name)' }
            if ("$($d.Status)" -eq 'OK') { Bad ('device of the deny list is working: {0}   {1}' -f $dname, $d.InstanceId) }
            else { Info ('    blocked or not there: {0}   present {1}, status {2}   {3}' -f $dname, $d.Present, $d.Status, $d.InstanceId) }
        }
    }
}

Invoke-Part '5c. C:\Windows.old' {
    $old = Join-Path $env:SystemDrive 'Windows.old'
    if (-not (Test-Path -LiteralPath $old)) { Info "$old does not exist"; return }
    $it = Get-Item -LiteralPath $old -Force
    Info ('{0} exists, made {1}' -f $old, $it.CreationTime.ToString('yyyy-MM-dd HH:mm'))
    $top = @(Get-ChildItem -LiteralPath $old -Force -ErrorAction SilentlyContinue)
    Info ('entries at the top: {0}' -f $top.Count)
    foreach ($t in $top) { Info ('    {0}{1}' -f $t.Name, $(if ($t.PSIsContainer) { '\' } else { '   ' + $t.Length + ' bytes' })) }
    $files = @(Get-ChildItem -LiteralPath $old -Force -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 5000)
    $sum = [double]0
    foreach ($f in $files) { $sum += $f.Length }
    Info ('files inside (the first 5000 at most): {0}, together {1:N1} MB' -f $files.Count, ($sum / 1MB))
}

Say ''
Say ('RESULT: REPORT WRITTEN. As set: {0}   different: {1}   removed apps that came back: {2}   parts that could not be read: {3}' -f $script:asSet, $script:different, $script:cameBack, $script:problems)
Say ('Folder: {0}' -f $OutDir)
exit 0
