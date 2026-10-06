<#
================================================================================
 WHD Next  -  tools\Test-WHDCompat.ps1   (compatibility test, READ-ONLY)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Checks how the WHD Classic code and the Windows features it uses behave under
 BOTH engines on this PC:
     Windows PowerShell 5.1   (safe-mode path in WHD Next, decision D6 / Option C)
     PowerShell 7.6           (full path in WHD Next)

 It CHANGES NOTHING on the PC. It only:
   * parses the Classic .ps1 files (syntax check, no execution),
   * loads the Classic modules into a throw-away child process in DRY-RUN
     (they only define functions/variables when loaded),
   * runs Get-/query-style commands and counts what comes back
     (no names, no personal data are stored - counts and status only),
   * writes its report files under  next\reports\compat_<date_time>\ .

 Run from an ELEVATED terminal (some reads need admin), either engine:
   powershell -ExecutionPolicy Bypass -File .\next\tools\Test-WHDCompat.ps1
 The script starts one child run per engine, waits, and merges the results.

 File is ASCII and uses Windows PowerShell 5.1-compatible syntax on purpose.
================================================================================
#>
[CmdletBinding()]
param(
    [string]$ClassicRoot,          # default: <WHD-Next>\source-classic
    [string]$ReportRoot,           # default: <WHD-Next>\next\reports
    [int]$ChildTimeoutSec = 900,   # per engine
    # ---- internal (used when this script starts itself as a child) ----
    [switch]$Child,
    [string]$OutFile
)

$ErrorActionPreference = 'Continue'
$cxScriptPath = $MyInvocation.MyCommand.Path
$cxToolsDir   = Split-Path -Parent $cxScriptPath          # ...\next\tools
$cxNextDir    = Split-Path -Parent $cxToolsDir            # ...\next
$cxProjectDir = Split-Path -Parent $cxNextDir             # ...\WHD-Next
if (-not $ClassicRoot) { $ClassicRoot = Join-Path $cxProjectDir 'source-classic' }
if (-not $ReportRoot)  { $ReportRoot  = Join-Path $cxNextDir 'reports' }

function Test-CxAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# =============================================================================
#  CHILD MODE  -  runs inside ONE engine, writes a JSON result file
# =============================================================================
if ($Child) {
    $cxIsCore  = ($PSVersionTable.PSEdition -eq 'Core')
    $cxIsAdmin = Test-CxAdmin
    $cxResult  = [ordered]@{
        Engine      = $PSVersionTable.PSEdition
        Version     = $PSVersionTable.PSVersion.ToString()
        PSHome      = $PSHOME
        IsAdmin     = $cxIsAdmin
        Apartment   = [System.Threading.Thread]::CurrentThread.GetApartmentState().ToString()
        Started     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        ParseErrors = New-Object System.Collections.Generic.List[object]
        ModuleLoads = New-Object System.Collections.Generic.List[object]
        Commands    = New-Object System.Collections.Generic.List[object]
        Probes      = New-Object System.Collections.Generic.List[object]
    }

    # ---- 1) parse every Classic script (no execution) -----------------------
    $cxFiles = @(Get-ChildItem -LiteralPath $ClassicRoot -Recurse -Filter '*.ps1' -File)
    $cxUsed  = @{}
    $cxDefined = @{}
    foreach ($f in $cxFiles) {
        $tok = $null; $err = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tok, [ref]$err)
        $rel = $f.FullName.Substring($ClassicRoot.Length).TrimStart('\')
        foreach ($e in @($err)) {
            if ($e) {
                $cxResult.ParseErrors.Add([pscustomobject][ordered]@{ File = $rel; Line = $e.Extent.StartLineNumber; Message = $e.Message })
            }
        }
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        foreach ($d in @($fn)) { if ($d) { $cxDefined[$d.Name.ToLower()] = $true } }
        $ca = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        foreach ($c in @($ca)) {
            if (-not $c) { continue }
            $nm = $c.GetCommandName()
            if (-not $nm) { continue }
            $k = $nm.ToLower()
            if (-not $cxUsed.ContainsKey($k)) { $cxUsed[$k] = New-Object System.Collections.Generic.List[string] }
            if (-not $cxUsed[$k].Contains($rel)) { $cxUsed[$k].Add($rel) }
        }
    }

    # ---- 2) is every outside command Classic calls available here? ----------
    foreach ($k in ($cxUsed.Keys | Sort-Object)) {
        if ($cxDefined.ContainsKey($k)) { continue }          # Classic's own function
        $gc = Get-Command -Name $k -ErrorAction SilentlyContinue | Select-Object -First 1
        $type = ''; $src = ''
        if ($gc) {
            $type = $gc.CommandType.ToString(); $src = [string]$gc.Source
            if ($gc.CommandType -eq 'Function' -and $gc.Module -and $gc.Module.PrivateData -and $gc.Module.PrivateData.ImplicitRemoting) {
                $type = 'Function (5.1 helper proxy)'
            }
        }
        $cxResult.Commands.Add([pscustomobject][ordered]@{
            Name  = $k
            Found = [bool]$gc
            Type  = $type
            Module = $src
            UsedIn = (@($cxUsed[$k]) -join ', ')
        })
    }

    # ---- 3) load the Classic modules in DRY-RUN into this throw-away process -
    $cxSandbox = Join-Path (Split-Path -Parent $OutFile) ('sandbox-' + $PSVersionTable.PSEdition)
    if (-not (Test-Path -LiteralPath $cxSandbox)) { New-Item -ItemType Directory -Path $cxSandbox -Force | Out-Null }
    $script:WHDExecute  = $false        # Classic engine: dry-run
    $script:WHDRoot     = $cxSandbox    # anything Classic would write goes here, not the real project
    $script:WHDCodeRoot = $ClassicRoot
    $cxModOrder = @('Common','Debloat-AI','Debloat-General','Permissions','Debloat-Win32','Maintenance',
                    'Firewall','Security','Updates','Devices','TimeRegion','Profiles')
    foreach ($m in $cxModOrder) {
        $p = Join-Path $ClassicRoot ("modules\{0}.ps1" -f $m)
        $row = [ordered]@{ Module = $m; Loaded = $false; Error = '' }
        try {
            $null = . $p 6>$null       # stream 6 = Write-Host lines from the module; not needed
            $row.Loaded = $true
        } catch { $row.Error = $_.Exception.Message }
        $cxResult.ModuleLoads.Add([pscustomobject]$row)
    }

    # ---- 4) read-only probes of the Windows features Classic uses -----------
    $cxImported = @{}
    function Invoke-CxProbe {
        param([string]$Area, [string]$Name, [string]$Cmd, [scriptblock]$Do, [switch]$NeedsAdmin)
        $r = [ordered]@{ Area = $Area; Name = $Name; Command = $Cmd; Module = ''; Status = ''; Via = ''; Count = ''; Ms = 0; Note = '' }
        if ($NeedsAdmin -and -not $cxIsAdmin) { $r.Status = 'SKIP-ADMIN'; return $r }
        $gc = Get-Command -Name $Cmd -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $gc) { $r.Status = 'MISSING'; $r.Note = 'command not available in this engine'; return $r }
        $r.Module = [string]$gc.Source
        $r.Via = 'native'
        # In PowerShell 7, find out whether the module loads natively or through
        # the automatic Windows PowerShell 5.1 helper (WinPSCompatSession).
        if ($cxIsCore -and $gc.CommandType -ne 'Application' -and $gc.ModuleName -and -not $cxImported.ContainsKey($gc.ModuleName)) {
            $wv = $null
            try {
                Import-Module -Name $gc.ModuleName -ErrorAction Stop -WarningVariable wv -WarningAction SilentlyContinue
                if (@($wv | Where-Object { "$_" -match 'WinPSCompatSession|Windows PowerShell' }).Count -gt 0) { $cxImported[$gc.ModuleName] = 'helper(auto)' }
                else { $cxImported[$gc.ModuleName] = 'native' }
            } catch {
                try {
                    Import-Module -Name $gc.ModuleName -UseWindowsPowerShell -ErrorAction Stop -WarningAction SilentlyContinue
                    $cxImported[$gc.ModuleName] = 'helper(explicit)'
                } catch { $cxImported[$gc.ModuleName] = 'import-failed: ' + $_.Exception.Message }
            }
        }
        if ($cxIsCore -and $gc.ModuleName -and $cxImported.ContainsKey($gc.ModuleName)) { $r.Via = $cxImported[$gc.ModuleName] }
        # A command can also arrive later as a proxy function from the 5.1 helper
        # (implicit remoting), even when its module name was already loaded natively.
        if ($cxIsCore) {
            $gc2 = Get-Command -Name $Cmd -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($gc2 -and $gc2.CommandType -eq 'Function' -and $gc2.Module -and $gc2.Module.PrivateData -and
                $gc2.Module.PrivateData.ImplicitRemoting) { $r.Via = 'helper(proxy)' }
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $global:LASTEXITCODE = 0
            $out = & $Do
            $sw.Stop()
            if ($gc.CommandType -eq 'Application' -and $LASTEXITCODE -ne 0) {
                $r.Status = 'FAIL'; $r.Note = 'exit code ' + $LASTEXITCODE
            } else {
                $r.Status = 'OK'
                if ($r.Via -like 'helper*') { $r.Status = 'OK-HELPER' }
                $r.Count = @($out).Count
            }
        } catch {
            $sw.Stop()
            $r.Status = 'FAIL'
            $r.Note = ($_.Exception.Message -replace '\s+', ' ')
            if ($r.Note.Length -gt 220) { $r.Note = $r.Note.Substring(0, 220) + '...' }
        }
        $r.Ms = [int]$sw.ElapsedMilliseconds
        return $r
    }

    $cxProbes = @(
        # Area, Name, Command, Script, NeedsAdmin
        @('Apps',     'Installed apps, all users',          'Get-AppxPackage',              { Get-AppxPackage -AllUsers -ErrorAction Stop }, $true),
        @('Apps',     'Installed apps, current user',       'Get-AppxPackage',              { Get-AppxPackage -ErrorAction Stop }, $false),
        @('Apps',     'Provisioned apps (new users)',       'Get-AppxProvisionedPackage',   { Get-AppxProvisionedPackage -Online -ErrorAction Stop }, $true),
        @('Features', 'Optional features list',             'Get-WindowsOptionalFeature',   { Get-WindowsOptionalFeature -Online -ErrorAction Stop }, $true),
        @('Features', 'Capability OpenSSH.Server',          'Get-WindowsCapability',        { Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction Stop }, $true),
        @('Network',  'Network adapters',                   'Get-NetAdapter',               { Get-NetAdapter -ErrorAction Stop }, $false),
        @('Network',  'Adapter bindings',                   'Get-NetAdapterBinding',        { Get-NetAdapterBinding -ErrorAction Stop }, $false),
        @('Network',  'IP addresses',                       'Get-NetIPAddress',             { Get-NetIPAddress -ErrorAction Stop }, $false),
        @('Network',  'DNS server addresses',               'Get-DnsClientServerAddress',   { Get-DnsClientServerAddress -ErrorAction Stop }, $false),
        @('Network',  'DNS-over-HTTPS servers',             'Get-DnsClientDohServerAddress',{ Get-DnsClientDohServerAddress -ErrorAction Stop }, $false),
        @('Firewall', 'Firewall profiles',                  'Get-NetFirewallProfile',       { Get-NetFirewallProfile -ErrorAction Stop }, $false),
        @('Firewall', 'Firewall rules (WHD groups)',        'Get-NetFirewallRule',          { Get-NetFirewallRule -Group 'WinHardenDebloat-*' -ErrorAction SilentlyContinue }, $false),
        @('Firewall', 'Rule address filters (first 20)',    'Get-NetFirewallAddressFilter', { Get-NetFirewallRule -ErrorAction Stop | Select-Object -First 20 | Get-NetFirewallAddressFilter -ErrorAction Stop }, $false),
        @('Firewall', 'Rule app filters (first 20)',        'Get-NetFirewallApplicationFilter', { Get-NetFirewallRule -ErrorAction Stop | Select-Object -First 20 | Get-NetFirewallApplicationFilter -ErrorAction Stop }, $false),
        @('Firewall', 'Rule port filters (first 20)',       'Get-NetFirewallPortFilter',    { Get-NetFirewallRule -ErrorAction Stop | Select-Object -First 20 | Get-NetFirewallPortFilter -ErrorAction Stop }, $false),
        @('Defender', 'Defender preferences',               'Get-MpPreference',             { Get-MpPreference -ErrorAction Stop }, $true),
        @('Defender', 'Defender status',                    'Get-MpComputerStatus',         { Get-MpComputerStatus -ErrorAction Stop }, $true),
        @('Tasks',    'Scheduled tasks (WHD folder)',       'Get-ScheduledTask',            { Get-ScheduledTask -TaskPath '\WinHardenDebloat\' -ErrorAction SilentlyContinue }, $false),
        @('Tasks',    'Scheduled tasks (all)',              'Get-ScheduledTask',            { Get-ScheduledTask -ErrorAction Stop }, $false),
        @('Devices',  'Plug-and-play devices (present)',    'Get-PnpDevice',                { Get-PnpDevice -PresentOnly -ErrorAction Stop }, $false),
        @('Devices',  'Device property (first device)',     'Get-PnpDeviceProperty',        { Get-PnpDevice -PresentOnly -ErrorAction Stop | Select-Object -First 1 | Get-PnpDeviceProperty -ErrorAction Stop }, $false),
        @('System',   'CIM: operating system',              'Get-CimInstance',              { Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop }, $false),
        @('System',   'Event log read (System, 5)',         'Get-WinEvent',                 { Get-WinEvent -LogName System -MaxEvents 5 -ErrorAction Stop }, $false),
        @('System',   'Services list',                      'Get-Service',                  { Get-Service -ErrorAction Stop }, $false),
        @('System',   'Hotfixes',                           'Get-HotFix',                   { Get-HotFix -ErrorAction Stop }, $false),
        @('System',   'Restore points (read)',              'Get-ComputerRestorePoint',     { Get-ComputerRestorePoint -ErrorAction Stop }, $true),
        @('System',   'Restore point create cmdlet exists', 'Checkpoint-Computer',          { Get-Command Checkpoint-Computer -ErrorAction Stop }, $false),
        @('System',   'Registry read (HKLM)',               'Get-ItemProperty',             { Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop }, $false),
        @('System',   'AppLocker effective policy',         'Get-AppLockerPolicy',          { Get-AppLockerPolicy -Effective -ErrorAction Stop }, $true),
        @('System',   'Secure Boot state',                  'Confirm-SecureBootUEFI',       { Confirm-SecureBootUEFI -ErrorAction Stop }, $true),
        @('Time',     'Time zone',                          'Get-TimeZone',                 { Get-TimeZone -ErrorAction Stop }, $false),
        @('Time',     'Time zone list',                     'Get-TimeZone',                 { Get-TimeZone -ListAvailable -ErrorAction Stop }, $false),
        # ---- CIM route (decided 2026-10-01): Defender + restore points without the 5.1 helper. All read-only.
        @('CIM',      'Defender settings via CIM',          'Get-CimInstance',              { Get-CimInstance -Namespace 'root/Microsoft/Windows/Defender' -ClassName 'MSFT_MpPreference' -ErrorAction Stop }, $true),
        @('CIM',      'Defender status via CIM',            'Get-CimInstance',              { Get-CimInstance -Namespace 'root/Microsoft/Windows/Defender' -ClassName 'MSFT_MpComputerStatus' -ErrorAction Stop }, $true),
        @('CIM',      'Defender class has Set/Add/Remove',  'Get-CimClass',                 {
            $cxC = Get-CimClass -Namespace 'root/Microsoft/Windows/Defender' -ClassName 'MSFT_MpPreference' -ErrorAction Stop
            $cxHave = @($cxC.CimClassMethods | ForEach-Object { $_.Name })
            foreach ($cxN in @('Set', 'Add', 'Remove')) { if ($cxHave -notcontains $cxN) { throw ('method missing: ' + $cxN) } }
            $cxHave }, $true),
        @('CIM',      'CIM values match Defender cmdlet',   'Get-CimInstance',              {
            $cxA = Get-CimInstance -Namespace 'root/Microsoft/Windows/Defender' -ClassName 'MSFT_MpPreference' -ErrorAction Stop
            $cxB = Get-MpPreference -ErrorAction Stop
            $cxOk = @()
            foreach ($cxN in @('EnableControlledFolderAccess', 'PUAProtection', 'EnableNetworkProtection', 'DisableRealtimeMonitoring', 'MAPSReporting', 'SubmitSamplesConsent')) {
                if (("" + $cxA.$cxN) -ne ("" + $cxB.$cxN)) { throw ('value differs: ' + $cxN) }
                $cxOk += $cxN
            }
            if (@($cxA.AttackSurfaceReductionRules_Ids).Count -ne @($cxB.AttackSurfaceReductionRules_Ids).Count) { throw 'value differs: ASR rule count' }
            $cxOk += 'AttackSurfaceReductionRules_Ids'
            $cxOk }, $true),
        @('CIM',      'System Restore class + methods',     'Get-CimClass',                 {
            $cxC = Get-CimClass -Namespace 'root/default' -ClassName 'SystemRestore' -ErrorAction Stop
            $cxHave = @($cxC.CimClassMethods | ForEach-Object { $_.Name })
            foreach ($cxN in @('CreateRestorePoint', 'Enable')) { if ($cxHave -notcontains $cxN) { throw ('method missing: ' + $cxN) } }
            $cxHave }, $true),
        @('CIM',      'Restore points via CIM (read)',      'Get-CimInstance',              { Get-CimInstance -Namespace 'root/default' -ClassName 'SystemRestore' -ErrorAction Stop }, $true),
        @('Native',   'reg.exe query',                      'reg.exe',                      { & reg.exe query 'HKLM\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' 2>$null }, $false),
        @('Native',   'netsh firewall profiles',            'netsh.exe',                    { & netsh.exe advfirewall show allprofiles state 2>$null }, $false),
        @('Native',   'auditpol (Filtering Platform)',      'auditpol.exe',                 { & auditpol.exe /get '/subcategory:{0CCE9226-69AE-11D9-BED3-505054503030}' 2>$null }, $true),
        @('Native',   'w32tm configuration',                'w32tm.exe',                    { & w32tm.exe /query /configuration 2>$null }, $true),
        @('Native',   'schtasks query',                     'schtasks.exe',                 { & schtasks.exe /query /fo csv 2>$null }, $false),
        @('Native',   'sc.exe service config',              'sc.exe',                       { & sc.exe qc W32Time 2>$null }, $false),
        @('Native',   'net accounts (password policy)',     'net.exe',                      { & net.exe accounts 2>$null }, $false),
        @('Native',   'pnputil enumerate devices',          'pnputil.exe',                  { & pnputil.exe /enum-devices /connected 2>$null }, $true),
        @('Native',   'winget present',                     'winget.exe',                   { & winget.exe --version 2>$null }, $false)
    )
    foreach ($pd in $cxProbes) {
        $cxResult.Probes.Add([pscustomobject](Invoke-CxProbe -Area $pd[0] -Name $pd[1] -Cmd $pd[2] -Do $pd[3] -NeedsAdmin:([bool]$pd[4])))
    }

    # ---- GUI + pop-up probes (no window is shown) ---------------------------
    $g = [ordered]@{ Area = 'GUI'; Name = 'WPF window from XAML (not shown)'; Command = 'Add-Type PresentationFramework'; Module = ''; Status = ''; Via = 'native'; Count = ''; Ms = 0; Note = '' }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        $xaml = '<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="WHD compat" Width="10" Height="10"><TextBlock Text="x"/></Window>'
        $w = [System.Windows.Markup.XamlReader]::Parse($xaml)
        if ($w) { $g.Status = 'OK'; $w.Close() } else { $g.Status = 'FAIL'; $g.Note = 'XamlReader returned nothing' }
    } catch { $g.Status = 'FAIL'; $g.Note = ($_.Exception.Message -replace '\s+', ' ') }
    $sw.Stop(); $g.Ms = [int]$sw.ElapsedMilliseconds
    $g.Note = ($g.Note + ' apartment=' + $cxResult.Apartment).Trim()
    $cxResult.Probes.Add([pscustomobject]$g)

    $t = [ordered]@{ Area = 'GUI'; Name = 'WinRT toast type (pop-ups)'; Command = 'WinRT'; Module = ''; Status = ''; Via = 'native'; Count = ''; Ms = 0; Note = '' }
    try {
        $tt = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        if ($tt) { $t.Status = 'OK' } else { $t.Status = 'FAIL' }
    } catch { $t.Status = 'FAIL'; $t.Note = ($_.Exception.Message -replace '\s+', ' ') }
    $cxResult.Probes.Add([pscustomobject]$t)

    $cxResult.Finished = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $cxResult | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutFile -Encoding ASCII
    exit 0
}

# =============================================================================
#  PARENT MODE  -  starts one child per engine, merges into a report
# =============================================================================
Write-Host ''
Write-Host ' WHD Next - compatibility test (read-only)' -ForegroundColor Cyan
Write-Host ' ----------------------------------------' -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath (Join-Path $ClassicRoot 'modules\Common.ps1'))) {
    Write-Host (" Classic source not found at: {0}" -f $ClassicRoot) -ForegroundColor Red
    Write-Host ' Pass -ClassicRoot <folder> or check the folder layout.' -ForegroundColor Red
    return
}
if (-not (Test-CxAdmin)) {
    Write-Host ' Not elevated: admin-only reads will be marked SKIP-ADMIN.' -ForegroundColor Yellow
    Write-Host ' For a full result, re-run from a terminal opened with "Run as administrator".' -ForegroundColor Yellow
}

$stamp  = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$outDir = Join-Path $ReportRoot ("compat_{0}" -f $stamp)
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$engines = @()
$ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (Test-Path -LiteralPath $ps51) { $engines += [pscustomobject]@{ Label = '5.1'; Exe = $ps51 } }
$ps7 = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
if (-not (Test-Path -LiteralPath $ps7)) {
    $pc = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pc) { $ps7 = $pc.Source } else { $ps7 = $null }
}
if ($ps7) { $engines += [pscustomobject]@{ Label = '7'; Exe = $ps7 } }
else { Write-Host ' PowerShell 7 not found - only the 5.1 run will happen.' -ForegroundColor Yellow }

$results = @{}
foreach ($e in $engines) {
    $json = Join-Path $outDir ("result-{0}.json" -f $e.Label)
    $log  = Join-Path $outDir ("console-{0}.txt" -f $e.Label)
    $elog = Join-Path $outDir ("errors-{0}.txt" -f $e.Label)
    Write-Host (" Running under PowerShell {0} ... (can take a few minutes)" -f $e.Label) -ForegroundColor White
    $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $cxScriptPath),
                 '-Child', '-OutFile', ('"{0}"' -f $json), '-ClassicRoot', ('"{0}"' -f $ClassicRoot))
    $p = Start-Process -FilePath $e.Exe -ArgumentList $argList -NoNewWindow -PassThru `
                       -RedirectStandardOutput $log -RedirectStandardError $elog
    $null = $p.Handle   # keeps ExitCode readable in 5.1
    if (-not $p.WaitForExit($ChildTimeoutSec * 1000)) {
        try { $p.Kill() } catch {}
        Write-Host ("   timed out after {0} s" -f $ChildTimeoutSec) -ForegroundColor Red
    }
    if (Test-Path -LiteralPath $json) {
        $results[$e.Label] = Get-Content -LiteralPath $json -Raw | ConvertFrom-Json
        Write-Host '   done.' -ForegroundColor Green
    } else {
        Write-Host ("   no result file - see {0}" -f $elog) -ForegroundColor Red
    }
}

# ---- merge into a readable report -------------------------------------------
$labels = @($engines | ForEach-Object { $_.Label } | Where-Object { $results.ContainsKey($_) })
if ($labels.Count -eq 0) {
    Write-Host (' No engine produced a result. See the errors-*.txt files in {0}' -f $outDir) -ForegroundColor Red
    return
}
$rep = New-Object System.Collections.Generic.List[string]
$rep.Add('WHD Next - compatibility report (read-only test)')
$rep.Add(('Created: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
$rep.Add(('Classic source: {0}' -f $ClassicRoot))
$rep.Add('')
foreach ($l in $labels) {
    $r = $results[$l]
    $rep.Add(('Engine {0}: {1} {2}  admin={3}  apartment={4}  home={5}' -f $l, $r.Engine, $r.Version, $r.IsAdmin, $r.Apartment, $r.PSHome))
}
$rep.Add('')
$rep.Add('Status key: OK = works natively | OK-HELPER = works through the 5.1 helper inside PowerShell 7 |')
$rep.Add('            FAIL = error | MISSING = command does not exist in that engine | SKIP-ADMIN = needs elevation')

$rep.Add('')
$rep.Add('== 1. Syntax check of Classic files (parse only) ==')
foreach ($l in $labels) {
    $pe = @($results[$l].ParseErrors)
    if ($pe.Count -eq 0) { $rep.Add(('  {0}: no parse errors' -f $l)) }
    else { foreach ($x in $pe) { $rep.Add(('  {0}: {1} line {2}: {3}' -f $l, $x.File, $x.Line, $x.Message)) } }
}

$rep.Add('')
$rep.Add('== 2. Loading the Classic modules (dry-run, throw-away process) ==')
foreach ($l in $labels) {
    foreach ($m in @($results[$l].ModuleLoads)) {
        $s = 'loaded'; if (-not $m.Loaded) { $s = 'FAILED: ' + $m.Error }
        $rep.Add(('  {0}  {1,-16} {2}' -f $l, $m.Module, $s))
    }
}

$rep.Add('')
$rep.Add('== 3. Windows features Classic uses (read-only probes) ==')
$hdr = '  {0,-9} {1,-36}' -f 'Area', 'Probe'
foreach ($l in $labels) { $hdr += (' {0,-11}' -f ('PS ' + $l)) }
$rep.Add($hdr + ' Notes')
$first = $results[$labels[0]]
for ($i = 0; $i -lt @($first.Probes).Count; $i++) {
    $pr = @($first.Probes)[$i]
    $line = '  {0,-9} {1,-36}' -f $pr.Area, $pr.Name
    $notes = @()
    foreach ($l in $labels) {
        $q = @($results[$l].Probes)[$i]
        $line += (' {0,-11}' -f $q.Status)
        if ($q.Note) { $notes += ('[{0}] {1}' -f $l, $q.Note) }
        if ($q.Via -and $q.Via -ne 'native') { $notes += ('[{0}] via {1}' -f $l, $q.Via) }
    }
    $rep.Add($line + ' ' + ($notes -join ' | '))
}

$rep.Add('')
$rep.Add('== 4. Outside commands Classic calls that an engine does NOT have ==')
$anyMissing = $false
foreach ($l in $labels) {
    $miss = @($results[$l].Commands | Where-Object { -not $_.Found })
    foreach ($c in $miss) { $anyMissing = $true; $rep.Add(('  {0}: {1,-34} used in: {2}' -f $l, $c.Name, $c.UsedIn)) }
}
if (-not $anyMissing) { $rep.Add('  none') }
$rep.Add('')
$rep.Add('== 4b. Outside commands that only work through the 5.1 helper (PowerShell 7) ==')
$anyProxy = $false
foreach ($l in $labels) {
    $px = @($results[$l].Commands | Where-Object { $_.Type -like '*helper proxy*' })
    foreach ($c in $px) { $anyProxy = $true; $rep.Add(('  {0}: {1,-34} used in: {2}' -f $l, $c.Name, $c.UsedIn)) }
}
if (-not $anyProxy) { $rep.Add('  none') }

$rep.Add('')
$rep.Add('== 5. Summary ==')
foreach ($l in $labels) {
    $pp = @($results[$l].Probes)
    $rep.Add(('  PS {0}: OK={1}  OK-HELPER={2}  FAIL={3}  MISSING={4}  SKIP-ADMIN={5}  modules loaded={6}/{7}' -f $l,
        @($pp | Where-Object { $_.Status -eq 'OK' }).Count,
        @($pp | Where-Object { $_.Status -eq 'OK-HELPER' }).Count,
        @($pp | Where-Object { $_.Status -eq 'FAIL' }).Count,
        @($pp | Where-Object { $_.Status -eq 'MISSING' }).Count,
        @($pp | Where-Object { $_.Status -eq 'SKIP-ADMIN' }).Count,
        @($results[$l].ModuleLoads | Where-Object { $_.Loaded }).Count,
        @($results[$l].ModuleLoads).Count))
}

$repFile = Join-Path $outDir 'compat-report.txt'
$rep | Set-Content -LiteralPath $repFile -Encoding ASCII
Write-Host ''
$rep | Select-Object -Last 4 | ForEach-Object { Write-Host $_ }
Write-Host ''
Write-Host (' Report: {0}' -f $repFile) -ForegroundColor Cyan
Write-Host ' Nothing on this PC was changed.' -ForegroundColor Green
