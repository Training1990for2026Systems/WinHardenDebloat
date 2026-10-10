#requires -Version 5.1
<#
  WHD-FirstSignIn.ps1   (WHD USB Image)

  Runs ONCE on the freshly installed PC, at the first sign-in of the first user, and does the part of
  the hardening that needs a running Windows. What it does is named in first-signin-list.txt, which
  lies next to this script.

  How it gets there: the build script copies this script and the list into the image
  (C:\Windows\Setup\Scripts) and the answer file into the image as Windows\Panther\unattend.xml. That
  answer file tells Windows Setup to start this script once, with administrator rights, right after the
  first sign-in. If Setup does not start it, start it by hand (below) AFTER you have signed in with your
  own account. Started from a command window during setup it runs as Setup's temporary account
  (defaultuser0): the OneDrive part then works on that account, not on yours, and DNS is skipped while
  no network adapter is up.

  Parts (each one is switched on or off in first-signin-list.txt):
    defender-pua, defender-network-protection, defender-folder-protection, defender-asr
    password-rules      local password and lockout rules (net accounts)
    netbios-off         NetBIOS over TCP/IP off on every adapter
    dns                 DNS servers + encrypted DNS (DoH) on every adapter that is up
    onedrive-remove     stop the OneDrive install for this user / uninstall it
    firewall            back up the firewall policy, delete every rule, add the listed allow rules
    uac-always-notify   UAC "Always notify" (the last step)

  Rules it keeps:
    - Uses only Windows PowerShell and programs built into Windows. No downloads, no web calls.
    - A part that fails is reported and the script goes on with the next part.
    - The firewall part saves a backup first and does nothing without it. When an allow rule cannot be
      added afterwards, it puts the backup back.
    - Everything is written to C:\ProgramData\WHD-Image\FirstSignIn.log. It ends with a RESULT: line.
    - It runs once. A second start does nothing unless -Again is given.

  By hand, in an administrator Windows PowerShell:
    powershell -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\WHD-FirstSignIn.ps1

  Only show what it would do on this PC (changes nothing; the log goes next to the script):
    powershell -ExecutionPolicy Bypass -File .\WHD-FirstSignIn.ps1 -Preview

  Switches:
    -Preview          change nothing, only say what would be done
    -Again            run although it already ran on this PC
    -ListFile <file>  another list than first-signin-list.txt next to this script
    -LogDir <folder>  another folder for the log
    -CheckList        only read the list and say whether every line is understood (changes nothing,
                      writes no log; the build script uses this before it builds the image)
    -FromSetup        given by the answer file: the log then says that Windows Setup started this script
#>
param(
    [string]$ListFile = '',
    [string]$LogDir = '',
    [switch]$Preview,
    [switch]$Again,
    [switch]$CheckList,
    [switch]$FromSetup
)

$ErrorActionPreference = 'Stop'

$root     = $PSScriptRoot
$dataDir  = Join-Path $env:ProgramData 'WHD-Image'
if (-not $ListFile) { $ListFile = Join-Path $root 'first-signin-list.txt' }
if (-not $LogDir) { if ($Preview) { $LogDir = $root } else { $LogDir = $dataDir } }
$logName  = 'FirstSignIn.log'
if ($Preview) { $logName = 'FirstSignIn-preview.log' }
$log      = Join-Path $LogDir $logName
$doneFile = Join-Path $dataDir 'FirstSignIn.done'
$fwBackup = Join-Path $dataDir 'firewall-before-first-signin.wfw'
# WHD Classic's own group for its allow-list. Rules in this group are "WHD's own" for WHD Classic.
$fwGroup  = 'WinHardenDebloat-AllowList'
$partNames = @('defender-pua', 'defender-network-protection', 'defender-folder-protection', 'defender-asr',
               'password-rules', 'netbios-off', 'dns', 'onedrive-remove', 'firewall', 'uac-always-notify')

$script:done    = @()
$script:skipped = @()
$script:failed  = @()
$script:would   = @()
$script:logOk   = $true

function Say([string]$Text) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
    Write-Host $line
    if ($script:logOk) {
        try { Add-Content -LiteralPath $log -Value $line -Encoding Ascii }
        catch {
            $script:logOk = $false
            Write-Host ('WARNING: the log {0} cannot be written: {1}' -f $log, $_.Exception.Message)
        }
    }
}

function Stop-Run([string]$Why) {
    throw "STOPPED - $Why"
}

function Add-Skipped([string]$What) {
    $script:skipped += $What
    Say "    skipped: $What"
}

function Add-Failed([string]$What) {
    $script:failed += $What
    Say "    FAILED:  $What"
}

# Runs one change. In a preview it only says what would be done. Returns $true when the change was
# made (or would be made), $false when it failed.
function Invoke-Step([string]$StepText, [scriptblock]$StepAction) {
    if ($Preview) {
        $script:would += $StepText
        Say "    would:   $StepText"
        return $true
    }
    try {
        & $StepAction | Out-Null
        $script:done += $StepText
        Say "    done:    $StepText"
        return $true
    } catch {
        Add-Failed ('{0} - {1}' -f $StepText, $_.Exception.Message)
        return $false
    }
}

# Runs a program that is built into Windows and returns its exit code and its text.
# 'Continue' is set for this function only: with 'Stop', Windows PowerShell 5.1 would end the whole
# script at the first line a program writes to its error output.
function Invoke-Native([string]$Exe, [string[]]$ArgList) {
    $ErrorActionPreference = 'Continue'
    $out  = & $Exe @ArgList 2>&1
    $code = $LASTEXITCODE
    $text = @()
    foreach ($o in @($out)) { $text += [string]$o }
    return (New-Object PSObject -Property @{ Code = $code; Out = $text })
}

function Test-IPv4([string]$Text) {
    if ($Text -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    foreach ($o in ($Text -split '\.')) { if ([int]$o -gt 255) { return $false } }
    return $true
}

# Reads first-signin-list.txt. Stops on any line it does not understand, before anything is changed.
function Read-List {
    if (-not (Test-Path -LiteralPath $ListFile -PathType Leaf)) { Stop-Run "$ListFile not found" }
    $plan = New-Object PSObject -Property @{ Parts = @{}; Asr = @(); Password = @(); Dns = @(); Doh = ''; FwRules = @() }
    foreach ($p in $partNames) { $plan.Parts[$p] = $false }
    foreach ($raw in (Get-Content -LiteralPath $ListFile)) {
        $t = ([string]$raw).Trim()
        if ((-not $t) -or $t.StartsWith('#')) { continue }
        if ($t -match '^part:([a-z-]+)\s+(on|off)$') {
            $name = $Matches[1].ToLowerInvariant()
            $on   = ($Matches[2] -eq 'on')
            if ($partNames -notcontains $name) { Stop-Run "the list names a part this script does not have: $t" }
            $plan.Parts[$name] = $on
        }
        elseif ($t -match '^asr:([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\|(block|audit|warn|off)\|(.+)$') {
            $code = 0
            switch ($Matches[2].ToLowerInvariant()) { 'block' { $code = 1 } 'audit' { $code = 2 } 'warn' { $code = 6 } 'off' { $code = 0 } }
            $plan.Asr += (New-Object PSObject -Property @{ Id = $Matches[1].ToLowerInvariant(); Action = $Matches[2].ToLowerInvariant(); Code = $code; Name = $Matches[3].Trim() })
        }
        elseif ($t -match '^password:(minpwlen|uniquepw|maxpwage|lockoutthreshold|lockoutduration|lockoutwindow)\|(\d{1,5}|unlimited)$') {
            $setting = $Matches[1].ToLowerInvariant()
            $value   = $Matches[2].ToLowerInvariant()
            if (($value -eq 'unlimited') -and ($setting -ne 'maxpwage')) { Stop-Run "only maxpwage can be 'unlimited': $t" }
            $plan.Password = @($plan.Password | Where-Object { $_.Setting -ne $setting })
            $plan.Password += (New-Object PSObject -Property @{ Setting = $setting; Value = $value })
        }
        elseif ($t -match '^dns:(.+)$') {
            $ip = $Matches[1].Trim()
            if (-not (Test-IPv4 $ip)) { Stop-Run "this is not an IPv4 address: $t" }
            $plan.Dns += $ip
        }
        elseif ($t -match '^doh:(https://[A-Za-z0-9./_-]+)$') { $plan.Doh = $Matches[1] }
        elseif ($t.StartsWith('fw-allow:')) {
            $f = @($t.Substring(9) -split '\|')
            if ($f.Count -ne 7) { Stop-Run "a fw-allow: line needs 7 fields (name|display name|direction|protocol|local port|remote port|remote addresses): $t" }
            $rule = New-Object PSObject -Property @{ Name = $f[0].Trim(); Display = $f[1].Trim(); Direction = $f[2].Trim(); Protocol = $f[3].Trim().ToUpperInvariant()
                                                     LocalPort = $f[4].Trim(); RemotePort = $f[5].Trim(); Addresses = @() }
            if ($rule.Name -notmatch '^[A-Za-z0-9_-]+$') { Stop-Run "the rule name may only have letters, digits, - and _ : $t" }
            if ((-not $rule.Display) -or ($rule.Display -match '[\*\?\[\]]')) { Stop-Run "the display name is empty or has one of * ? [ ] in it: $t" }
            if (@('Inbound', 'Outbound') -notcontains $rule.Direction) { Stop-Run "the direction must be Inbound or Outbound: $t" }
            if (@('TCP', 'UDP') -notcontains $rule.Protocol) { Stop-Run "the protocol must be TCP or UDP: $t" }
            if (($rule.Direction -eq 'Inbound') -and (-not $rule.LocalPort)) { Stop-Run "an Inbound rule needs a local port (without one it would open every inbound port): $t" }
            foreach ($port in @($rule.LocalPort, $rule.RemotePort)) {
                if ($port -and (($port -notmatch '^\d{1,5}$') -or ([int]$port -lt 1) -or ([int]$port -gt 65535))) { Stop-Run "a port must be a number from 1 to 65535, or empty: $t" }
            }
            if ($f[6].Trim()) {
                foreach ($a in ($f[6] -split ',')) {
                    if (-not (Test-IPv4 $a.Trim())) { Stop-Run "this is not an IPv4 address: '$($a.Trim())' in: $t" }
                    $rule.Addresses += $a.Trim()
                }
            }
            if (@($plan.FwRules | Where-Object { $_.Name -eq $rule.Name }).Count -gt 0) { Stop-Run "the list names the rule '$($rule.Name)' twice" }
            $plan.FwRules += $rule
        }
        else { Stop-Run "the list has a line that is not understood: $t" }
    }
    if ($plan.Parts['defender-asr'] -and ($plan.Asr.Count -eq 0)) { Stop-Run 'part defender-asr is on, but the list has no asr: line' }
    if ($plan.Parts['password-rules'] -and ($plan.Password.Count -eq 0)) { Stop-Run 'part password-rules is on, but the list has no password: line' }
    if ($plan.Parts['dns'] -and ($plan.Dns.Count -eq 0)) { Stop-Run 'part dns is on, but the list has no dns: line' }
    if ($plan.Parts['firewall'] -and ($plan.FwRules.Count -eq 0)) { Stop-Run 'part firewall is on, but the list has no fw-allow: line. Without allow rules a wipe would leave the PC without its DHCP rule' }
    return $plan
}

# ---------------------------------------------------------------------------------------------------
# Microsoft Defender
# ---------------------------------------------------------------------------------------------------
# Empty text = Defender is ready. Otherwise the reason why not. Waits up to 2 minutes: right after the
# first sign-in Defender can still be starting.
function Wait-Defender {
    if (-not (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue)) { return 'the Defender commands are not on this PC' }
    $why = ''
    for ($i = 0; $i -lt 12; $i++) {
        try {
            $s = Get-MpComputerStatus -ErrorAction Stop
            if ($s.AntivirusEnabled -and ("$($s.AMRunningMode)" -match 'Normal')) { return '' }
            $why = 'Microsoft Defender Antivirus is not the active antivirus (mode: {0})' -f $s.AMRunningMode
        } catch { $why = 'the Defender status could not be read: {0}' -f $_.Exception.Message }
        if ($Preview) { break }
        Start-Sleep -Seconds 10
    }
    return $why
}

function Set-DefenderSetting([string]$Setting, [int]$Value, [string]$Label) {
    $old = $null
    try { $old = [int](Get-MpPreference -ErrorAction Stop).$Setting } catch { }
    if (($null -ne $old) -and ($old -eq $Value)) { Add-Skipped ('{0} (was already set)' -f $Label); return }
    $oldText = '?'
    if ($null -ne $old) { $oldText = "$old" }
    Invoke-Step ('{0} ({1} was {2}, now {3})' -f $Label, $Setting, $oldText, $Value) {
        $mp = @{ ErrorAction = 'Stop' }
        $mp[$Setting] = $Value
        Set-MpPreference @mp
        $now = [int](Get-MpPreference -ErrorAction Stop).$Setting
        if ($now -ne $Value) { throw ('it reads back as {0}; Tamper Protection or a policy may block it' -f $now) }
    } | Out-Null
}

function Get-AsrMap {
    $map = @{}
    try {
        $p    = Get-MpPreference -ErrorAction Stop
        $ids  = @($p.AttackSurfaceReductionRules_Ids)
        $acts = @($p.AttackSurfaceReductionRules_Actions)
        for ($i = 0; $i -lt $ids.Count; $i++) {
            if ($ids[$i]) { $map["$($ids[$i])".ToLowerInvariant()] = [int]$acts[$i] }
        }
    } catch { }
    return $map
}

function Invoke-AsrPart($Rules) {
    $map = Get-AsrMap
    foreach ($rule in $Rules) {
        $cur = 0
        if ($map.ContainsKey($rule.Id)) { $cur = [int]$map[$rule.Id] }
        if ($cur -eq $rule.Code) { Add-Skipped ('attack-surface rule already {0}: {1}' -f $rule.Action, $rule.Name); continue }
        $asrId = $rule.Id; $asrCode = $rule.Code
        Invoke-Step ('attack-surface rule -> {0}: {1}' -f $rule.Action, $rule.Name) {
            Add-MpPreference -AttackSurfaceReductionRules_Ids $asrId -AttackSurfaceReductionRules_Actions $asrCode -ErrorAction Stop
            $after = Get-AsrMap
            $now = 0
            if ($after.ContainsKey($asrId)) { $now = [int]$after[$asrId] }
            if ($now -ne $asrCode) { throw ('it reads back as action {0}' -f $now) }
        } | Out-Null
    }
}

# ---------------------------------------------------------------------------------------------------
# Password and lockout rules
# ---------------------------------------------------------------------------------------------------
function Invoke-PasswordPart($Settings) {
    # One call with every switch: Windows checks "counter reset <= lockout duration" on the pair,
    # so the two must arrive together.
    $netArgs = @('accounts')
    foreach ($s in $Settings) { $netArgs += ('/{0}:{1}' -f $s.Setting, $s.Value) }
    $ok = Invoke-Step ('password and lockout rules: net {0}' -f ($netArgs -join ' ')) {
        $r = Invoke-Native 'net.exe' $netArgs
        if ($r.Code -ne 0) { throw ('net accounts ended with code {0}: {1}' -f $r.Code, (($r.Out | Where-Object { $_ }) -join ' ')) }
    }
    if ($ok -and (-not $Preview)) {
        $now = Invoke-Native 'net.exe' @('accounts')
        foreach ($l in $now.Out) { if (([string]$l).Trim()) { Say ('        now: ' + ([string]$l).Trim()) } }
    }
}

# ---------------------------------------------------------------------------------------------------
# NetBIOS over TCP/IP
# ---------------------------------------------------------------------------------------------------
function Invoke-NetbiosPart {
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces'
    $keys = @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'Tcpip_*' })
    if ($keys.Count -eq 0) { Add-Skipped 'NetBIOS off (no adapter entry found)'; return }
    $already = 0
    foreach ($k in $keys) {
        $cur = $null
        try { $cur = (Get-ItemProperty -LiteralPath $k.PSPath -Name 'NetbiosOptions' -ErrorAction Stop).NetbiosOptions } catch { }
        if (($null -ne $cur) -and ([int]$cur -eq 2)) { $already++; continue }
        $nbPath = $k.PSPath
        Invoke-Step ('NetBIOS off on adapter entry {0}' -f $k.PSChildName) {
            Set-ItemProperty -LiteralPath $nbPath -Name 'NetbiosOptions' -Value 2 -Type DWord -ErrorAction Stop
        } | Out-Null
    }
    if ($already -gt 0) { Add-Skipped ('NetBIOS off on {0} adapter entry(ies) (was already set)' -f $already) }
}

# ---------------------------------------------------------------------------------------------------
# DNS
# ---------------------------------------------------------------------------------------------------
function Invoke-DnsPart($Servers, [string]$Template) {
    $ups = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { "$($_.Status)" -eq 'Up' })
    if ($ups.Count -eq 0) { Add-Skipped 'DNS (no network adapter is up; set it later with WHD Classic, Firewall D)'; return }
    if ($Template) {
        if (Get-Command Add-DnsClientDohServerAddress -ErrorAction SilentlyContinue) {
            foreach ($ip in $Servers) {
                $dohIp = $ip
                Invoke-Step ('encrypted DNS (DoH) registered for {0}: {1}' -f $ip, $Template) {
                    if (Get-DnsClientDohServerAddress -ServerAddress $dohIp -ErrorAction SilentlyContinue) {
                        Set-DnsClientDohServerAddress -ServerAddress $dohIp -DohTemplate $Template -AllowFallbackToUdp $false -AutoUpgrade $true -ErrorAction Stop
                    } else {
                        Add-DnsClientDohServerAddress -ServerAddress $dohIp -DohTemplate $Template -AllowFallbackToUdp $false -AutoUpgrade $true -ErrorAction Stop
                    }
                } | Out-Null
            }
        } else {
            Add-Skipped 'encrypted DNS (this Windows has no DoH commands; plain DNS only)'
        }
    }
    $names = @()
    foreach ($a in $ups) { $names += "$($a.Name)" }
    Invoke-Step ('DNS servers {0} on {1} adapter(s) that are up: {2}' -f ($Servers -join ', '), $ups.Count, ($names -join ', ')) {
        foreach ($a in $ups) { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $Servers -ErrorAction Stop }
    } | Out-Null
}

# ---------------------------------------------------------------------------------------------------
# OneDrive
# ---------------------------------------------------------------------------------------------------
function Get-OneDriveEntries {
    $found = @()
    foreach ($base in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
                        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        foreach ($k in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
            $p = $null
            try { $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop } catch { }
            if ($p -and ("$($p.DisplayName)" -eq 'Microsoft OneDrive') -and "$($p.UninstallString)".Trim()) {
                $found += (New-Object PSObject -Property @{ Path = $k.PSPath; Command = "$($p.UninstallString)".Trim() })
            }
        }
    }
    return ,@($found)
}

# An uninstall command whose program path has a space in it and no quotes around it would not start:
# put the quotes in (as WHD Classic does).
function Get-QuotedCommand([string]$Command) {
    $c = $Command.Trim()
    if ($c.StartsWith('"')) { return $c }
    if ($c -match '^(.+?\.exe)(\s.*)?$') {
        $program = [string]$Matches[1]
        $rest    = [string]$Matches[2]
        if ($program.Contains(' ')) { return ('"{0}"{1}' -f $program, $rest) }
    }
    return $c
}

function Invoke-OneDrivePart {
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $entry  = $null
    try { $entry = (Get-ItemProperty -LiteralPath $runKey -Name 'OneDriveSetup' -ErrorAction Stop).OneDriveSetup } catch { }
    if ($entry) {
        Invoke-Step ('OneDrive: start entry of its install taken away for this user (it was: {0})' -f $entry) {
            Remove-ItemProperty -LiteralPath $runKey -Name 'OneDriveSetup' -ErrorAction Stop
        } | Out-Null
    }
    $installed = Get-OneDriveEntries
    foreach ($od in $installed) {
        $odPath = $od.Path; $odCmd = Get-QuotedCommand $od.Command
        Invoke-Step ('OneDrive uninstalled with its own uninstaller: {0}' -f $od.Command) {
            $proc = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList ('/d /s /c "' + $odCmd + '"') -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
            # OneDrive's uninstaller can end with a code of its own although it removed the program:
            # what counts is whether the program is still listed as installed.
            for ($w = 0; ($w -lt 10) -and (Test-Path -LiteralPath $odPath); $w++) { Start-Sleep -Seconds 1 }
            if (Test-Path -LiteralPath $odPath) { throw ('it is still listed as installed (the uninstaller ended with code {0})' -f $proc.ExitCode) }
        } | Out-Null
    }
    if ((-not $entry) -and ($installed.Count -eq 0)) {
        Add-Skipped 'OneDrive (no install entry for this user and not installed at this moment; if it appears later, remove it with WHD Classic, Win32 programs)'
    }
}

# ---------------------------------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------------------------------
function Invoke-FirewallPart($Rules) {
    $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop)
    foreach ($p in $profiles) { Say ('    firewall profile {0}: on = {1}, inbound = {2}, outbound = {3}' -f $p.Name, $p.Enabled, $p.DefaultInboundAction, $p.DefaultOutboundAction) }
    if (@($profiles | Where-Object { "$($_.DefaultOutboundAction)" -eq 'Block' }).Count -gt 0) {
        Add-Skipped 'firewall (outbound is set to Block on this PC: deleting the rules now would cut the network. Use WHD Classic for the firewall)'
        return
    }
    $all = @(Get-NetFirewallRule -ErrorAction SilentlyContinue)
    $in  = @($all | Where-Object { "$($_.Direction)" -eq 'Inbound' }).Count
    Say ('    firewall rules now: {0} ({1} inbound, {2} outbound)' -f $all.Count, $in, ($all.Count - $in))
    if ($Preview) {
        $script:would += 'firewall'
        Say ('    would:   save the firewall policy to {0}' -f $fwBackup)
        Say ('    would:   delete all {0} firewall rule(s)' -f $all.Count)
        foreach ($rule in $Rules) { Say ('    would:   add allow rule {0} [{1} {2}]' -f $rule.Name, $rule.Direction, $rule.Protocol) }
        return
    }

    # 1. backup - nothing is deleted without it
    if (Test-Path -LiteralPath $fwBackup) {
        Say ('    a firewall backup from an earlier run is kept and used as the way back: {0}' -f $fwBackup)
    } else {
        $ex = Invoke-Native 'netsh.exe' @('advfirewall', 'export', $fwBackup)
        if (($ex.Code -ne 0) -or (-not (Test-Path -LiteralPath $fwBackup))) {
            Add-Failed ('firewall: the backup could not be saved (netsh ended with code {0}: {1}). No rule was deleted' -f $ex.Code, (($ex.Out | Where-Object { $_ }) -join ' '))
            return
        }
        Say ('    firewall policy saved: {0}' -f $fwBackup)
    }

    # 2. delete every rule, one by one (a rule that cannot be deleted is left and counted)
    Say ('    deleting {0} rule(s) one by one - this takes a few minutes ...' -f $all.Count)
    $n = 0; $kept = 0; $firstError = ''
    foreach ($r in $all) {
        $n++
        try { $r | Remove-NetFirewallRule -ErrorAction Stop }
        catch {
            $kept++
            if (-not $firstError) { $firstError = $_.Exception.Message }
        }
        if (($n % 50) -eq 0) { Say ('        {0} of {1}' -f $n, $all.Count) }
    }
    if (($all.Count -gt 0) -and ($kept -eq $all.Count)) {
        Add-Failed ('firewall: none of the {0} rule(s) could be deleted ({1}). No allow rule was added; the firewall is as it was' -f $all.Count, $firstError)
        return
    }

    # 3. the allow rules
    $bad = @()
    foreach ($rule in $Rules) {
        $fw = @{ Name = $rule.Name; DisplayName = $rule.Display; Group = $fwGroup; Direction = $rule.Direction
                 Action = 'Allow'; Enabled = 'True'; Profile = 'Any'; Protocol = $rule.Protocol; ErrorAction = 'Stop' }
        if ($rule.LocalPort)  { $fw['LocalPort']  = $rule.LocalPort }
        if ($rule.RemotePort) { $fw['RemotePort'] = $rule.RemotePort }
        if ($rule.Addresses.Count -gt 0) { $fw['RemoteAddress'] = $rule.Addresses }
        try {
            $same = @(Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue)
            if ($same.Count -gt 0) { $same | Remove-NetFirewallRule -ErrorAction SilentlyContinue }
            New-NetFirewallRule @fw | Out-Null
        } catch { $bad += ('{0} ({1})' -f $rule.Name, $_.Exception.Message) }
    }
    foreach ($rule in $Rules) {
        if (@(Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue).Count -eq 0) {
            if (@($bad | Where-Object { $_ -like ($rule.Name + ' (*') }).Count -eq 0) { $bad += ('{0} (not there after it was added)' -f $rule.Name) }
        }
    }

    # 4. an allow rule is missing: put the backup back, so the PC is not left without its DHCP rule
    if ($bad.Count -gt 0) {
        $im = Invoke-Native 'netsh.exe' @('advfirewall', 'import', $fwBackup)
        if ($im.Code -eq 0) {
            Add-Failed ('firewall: {0} allow rule(s) could not be added: {1}. The firewall was put back as it was before (backup imported)' -f $bad.Count, ($bad -join '; '))
        } else {
            Add-Failed ('firewall: {0} allow rule(s) could not be added: {1}. Putting the backup back FAILED too (netsh code {2}). Put it back by hand:  netsh advfirewall import "{3}"' -f $bad.Count, ($bad -join '; '), $im.Code, $fwBackup)
        }
        return
    }

    $leftText = ''
    if ($kept -gt 0) { $leftText = ' ({0} could not be deleted and were left; first reason: {1})' -f $kept, $firstError }
    $script:done += ('firewall: {0} rule(s) deleted{1}, {2} allow rule(s) added in group {3}' -f ($all.Count - $kept), $leftText, $Rules.Count, $fwGroup)
    Say ('    done:    ' + $script:done[$script:done.Count - 1])
    $after = @(Get-NetFirewallRule -ErrorAction SilentlyContinue)
    Say ('    firewall rules at the end: {0}' -f $after.Count)
}

# ---------------------------------------------------------------------------------------------------
# UAC "Always notify"
# ---------------------------------------------------------------------------------------------------
function Invoke-UacPart {
    $uacKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    # EnableLUA is only written when UAC is switched off altogether (as WHD Classic does).
    foreach ($v in @(@{ N = 'EnableLUA'; V = 1; OnlyIfNot = $true }, @{ N = 'ConsentPromptBehaviorAdmin'; V = 2 }, @{ N = 'PromptOnSecureDesktop'; V = 1 })) {
        $cur = $null
        try { $cur = (Get-ItemProperty -LiteralPath $uacKey -Name $v.N -ErrorAction Stop).($v.N) } catch { }
        if (($null -ne $cur) -and ([int]$cur -eq $v.V)) { Add-Skipped ('UAC {0} = {1} (was already set)' -f $v.N, $v.V); continue }
        if ($v.OnlyIfNot -and ($null -eq $cur)) { continue }
        $uacName = $v.N; $uacValue = $v.V
        $curText = 'not set'
        if ($null -ne $cur) { $curText = "$cur" }
        Invoke-Step ('UAC {0} = {1} (was: {2})' -f $v.N, $v.V, $curText) {
            Set-ItemProperty -LiteralPath $uacKey -Name $uacName -Value $uacValue -Type DWord -ErrorAction Stop
        } | Out-Null
    }
}

# ---------------------------------------------------------------------------------------------------
# -CheckList: read the list, say the result, end
# ---------------------------------------------------------------------------------------------------
if ($CheckList) {
    try {
        $checked = Read-List
        $onNames = @()
        foreach ($p in $partNames) { if ($checked.Parts[$p]) { $onNames += $p } }
        Write-Host ('LIST OK - {0} part(s) on: {1}' -f $onNames.Count, ($onNames -join ', '))
        exit 0
    } catch {
        Write-Host ('LIST NOT OK - {0}' -f $_.Exception.Message)
        exit 1
    }
}

# ---------------------------------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------------------------------
$exitCode = 0
try {
    foreach ($d in @($LogDir, $dataDir)) {
        if (($d -eq $dataDir) -and $Preview) { continue }
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    if ($Preview) { Say '=== WHD-FirstSignIn started - PREVIEW: nothing is changed ===' }
    else {
        Say '=== WHD-FirstSignIn started ==='
        Say 'This window works for several minutes. Leave it alone: do not close it and do not click in it. It closes by itself.'
    }
    $os = $null
    try { $os = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop } catch { }
    if ($os) { Say ('Windows version {0}, build {1}.{2}; PowerShell {3}; user {4}' -f $os.DisplayVersion, $os.CurrentBuild, $os.UBR, $PSVersionTable.PSVersion, $env:USERNAME) }
    if ($FromSetup) { Say 'Started by Windows Setup (the answer file in the image).' }
    else { Say 'Started by hand (not by Windows Setup).' }
    if ("$($env:USERNAME)" -ieq 'defaultuser0') {
        Say "NOTE: this is Windows Setup's temporary account (defaultuser0), not your own. The OneDrive part works on this account only, and DNS is skipped while no network adapter is up. For those two, run this script again with -Again after you have signed in with your own account."
    }

    $me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Stop-Run 'this window is not running as administrator. Nothing was changed'
    }

    $plan = Read-List
    $on = @(); $off = @()
    foreach ($p in $partNames) { if ($plan.Parts[$p]) { $on += $p } else { $off += $p } }
    Say ('List: {0}' -f $ListFile)
    Say ('    parts on ({0}): {1}' -f $on.Count, ($on -join ', '))
    Say ('    parts off ({0}): {1}' -f $off.Count, ($off -join ', '))

    if ((-not $Preview) -and (-not $Again) -and (Test-Path -LiteralPath $doneFile)) {
        Say ('RESULT: NOTHING DONE - this script already ran on this PC ({0}). To run it again, add -Again.' -f ((Get-Content -LiteralPath $doneFile | Select-Object -First 1)))
    }
    else {
        # --- Defender ---------------------------------------------------------------------------
        $defParts = @('defender-pua', 'defender-network-protection', 'defender-folder-protection', 'defender-asr')
        if (@($defParts | Where-Object { $plan.Parts[$_] }).Count -gt 0) {
            Say 'Microsoft Defender:'
            $why = Wait-Defender
            if ($why) {
                Add-Skipped ('Defender settings ({0})' -f $why)
            } else {
                try {
                    if ($plan.Parts['defender-pua'])                { Set-DefenderSetting 'PUAProtection' 1 'Block potentially unwanted apps' }
                    if ($plan.Parts['defender-network-protection']) { Set-DefenderSetting 'EnableNetworkProtection' 1 'Network protection = Block' }
                    if ($plan.Parts['defender-folder-protection'])  { Set-DefenderSetting 'EnableControlledFolderAccess' 1 'Ransomware folder protection = Block' }
                    if ($plan.Parts['defender-asr'])                { Invoke-AsrPart $plan.Asr }
                } catch { Add-Failed ('Defender part stopped: {0}' -f $_.Exception.Message) }
            }
        }

        # --- password rules ---------------------------------------------------------------------
        if ($plan.Parts['password-rules']) {
            Say 'Password and lockout rules:'
            try { Invoke-PasswordPart $plan.Password } catch { Add-Failed ('password part stopped: {0}' -f $_.Exception.Message) }
        }

        # --- NetBIOS ----------------------------------------------------------------------------
        if ($plan.Parts['netbios-off']) {
            Say 'NetBIOS over TCP/IP:'
            try { Invoke-NetbiosPart } catch { Add-Failed ('NetBIOS part stopped: {0}' -f $_.Exception.Message) }
        }

        # --- DNS --------------------------------------------------------------------------------
        if ($plan.Parts['dns']) {
            Say 'DNS:'
            try { Invoke-DnsPart $plan.Dns $plan.Doh } catch { Add-Failed ('DNS part stopped: {0}' -f $_.Exception.Message) }
        }

        # --- OneDrive ---------------------------------------------------------------------------
        if ($plan.Parts['onedrive-remove']) {
            Say 'OneDrive:'
            try { Invoke-OneDrivePart } catch { Add-Failed ('OneDrive part stopped: {0}' -f $_.Exception.Message) }
        }

        # --- firewall (last: it takes the longest) ------------------------------------------------
        if ($plan.Parts['firewall']) {
            Say 'Firewall:'
            try { Invoke-FirewallPart $plan.FwRules } catch { Add-Failed ('firewall part stopped: {0}' -f $_.Exception.Message) }
        }

        # --- UAC (the very last change) ---------------------------------------------------------
        if ($plan.Parts['uac-always-notify']) {
            Say 'User Account Control:'
            try { Invoke-UacPart } catch { Add-Failed ('UAC part stopped: {0}' -f $_.Exception.Message) }
        }

        # --- end --------------------------------------------------------------------------------
        if ($Preview) {
            Say ('RESULT: PREVIEW - nothing was changed. Would do: {0}   already as wanted or not possible: {1}   problems: {2}' -f $script:would.Count, $script:skipped.Count, $script:failed.Count)
        } else {
            Set-Content -LiteralPath $doneFile -Value @((Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), ('done {0}, skipped {1}, failed {2}' -f $script:done.Count, $script:skipped.Count, $script:failed.Count)) -Encoding Ascii
            if ($script:failed.Count -gt 0) {
                $exitCode = 1
                Say ('RESULT: DONE WITH {0} FAILED ITEM(S) - {1} change(s) made, {2} skipped. See the FAILED lines above.' -f $script:failed.Count, $script:done.Count, $script:skipped.Count)
            } else {
                Say ('RESULT: DONE - {0} change(s) made, {1} skipped.' -f $script:done.Count, $script:skipped.Count)
            }
            Say 'NOTE: restart the PC once, so that every setting is in use.'
        }
    }
}
catch {
    $exitCode = 1
    $msg = $_.Exception.Message
    if ($msg -notmatch '^STOPPED') { $msg = 'STOPPED - error: {0} (script line {1})' -f $msg, $_.InvocationInfo.ScriptLineNumber }
    try { Say "RESULT: $msg" } catch { Write-Host "RESULT: $msg" }
}
try { Say '=== WHD-FirstSignIn ended ===' } catch { }
exit $exitCode
