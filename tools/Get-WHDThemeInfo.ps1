<#
================================================================================
 WHD Next  -  tools\Get-WHDThemeInfo.ps1   (development tool, READ-ONLY)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Build step 12a helper (theme). Several things the theme needs are not described
 in Microsoft's documentation for Windows Home, so this reads the facts from
 THIS PC instead:
   * screen size
   * the theme in use, and which keys Windows itself writes into theme files
   * dark mode and accent colour values
   * desktop picture / slideshow state
   * the sound scheme and its events
   * the start-up sound switch
   * whether the lock screen call can be reached (Windows PowerShell 5.1)
   * which scheduled-task triggers exist
   * sound devices

 It CHANGES NOTHING: no setting is written, no sound is played, no task is made.
 It writes one text report:
   C:\ProgramData\WinHardenDebloatNext\app\reports\themeinfo_<date_time>_<engine>.txt
 (the unlocked copy, when it exists and this window is administrator), otherwise
 next\reports\ - and never into a folder that Windows folder protection blocks.

 Run it once, in an administrator terminal, as the user whose desktop is meant:
   powershell -ExecutionPolicy Bypass -File "<...>\next\tools\Get-WHDThemeInfo.ps1"
 It then runs itself once more on the other PowerShell (5.1 <-> 7), so both
 reports exist. -NoOther = this engine only.

 Written for Windows PowerShell 5.1 and PowerShell 7. File is ASCII on purpose.
================================================================================
#>
[CmdletBinding()]
param(
    [string]$ReportRoot,     # folder for the report (default: see above)
    [switch]$NoOther         # do not start the other PowerShell afterwards
)

$ErrorActionPreference = 'Continue'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$nextDir  = Split-Path -Parent $toolsDir
$out = New-Object System.Collections.Generic.List[string]
function Add-Line { param([string]$Text = '') $out.Add($Text) }
function Add-Head { param([string]$Text) Add-Line ''; Add-Line ('== {0} ' -f $Text).PadRight(78, '=') }

function Format-WHDValue {
    # One registry value as text: numbers also in hex, byte arrays as hex, lists joined.
    param($Value)
    if ($null -eq $Value) { return '(not set)' }
    if ($Value -is [byte[]]) {
        $hex = @(foreach ($b in @($Value | Select-Object -First 64)) { '{0:X2}' -f $b }) -join ' '
        if (@($Value).Count -gt 64) { $hex = $hex + (' ... ({0} bytes)' -f @($Value).Count) }
        return ('[bytes] {0}' -f $hex)
    }
    if ($Value -is [array]) { return ('[list] {0}' -f (@($Value) -join ' | ')) }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [uint32]) {
        $n = [long]$Value
        if ($n -lt 0) { $n = $n + 4294967296 }
        return ('{0}  (0x{1:X8})' -f $Value, $n)
    }
    return ('{0}' -f $Value)
}
function Add-RegValue {
    param([string]$Path, [string]$Name)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { Add-Line ('  {0,-34} (key not there)' -f $Name); return }
        $p = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        Add-Line ('  {0,-34} {1}' -f $Name, (Format-WHDValue $p.$Name))
    } catch { Add-Line ('  {0,-34} (not set)' -f $Name) }
}
function Add-RegKey {
    # Every value of one key (at most $Max).
    param([string]$Path, [int]$Max = 60)
    Add-Line (' {0}' -f $Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { Add-Line '  (key not there)'; return }
        $k = Get-Item -LiteralPath $Path -ErrorAction Stop
        $names = @($k.GetValueNames())
        if (-not $names.Count) { Add-Line '  (no values)'; return }
        $i = 0
        foreach ($n in ($names | Sort-Object)) {
            $i++; if ($i -gt $Max) { Add-Line ('  ... {0} more value(s)' -f ($names.Count - $Max)); break }
            $shown = $n; if (-not $shown) { $shown = '(default)' }
            Add-Line ('  {0,-34} {1}' -f $shown, (Format-WHDValue $k.GetValue($n, $null, 'DoNotExpandEnvironmentNames')))
        }
    } catch { Add-Line ('  not readable: {0}' -f $_.Exception.Message) }
}
function Get-WHDIniSection {
    # Lines of one [section] of an .ini / .theme file (without the header line).
    param([string[]]$Lines, [string]$Section)
    $res = New-Object System.Collections.Generic.List[string]
    $in = $false
    foreach ($l in @($Lines)) {
        $t = "$l".Trim()
        if ($t -match '^\[(.+)\]$') { $in = ($Matches[1] -eq $Section); continue }
        if ($in -and $t -and -not $t.StartsWith(';')) { $res.Add($t) }
    }
    return @($res.ToArray())
}
function Test-WHDInfoAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}
function Test-WHDInfoUnder {
    param([string]$Path, [string[]]$Folders)
    if (-not $Path) { return $false }
    $p = ($Path -replace '/', '\').TrimEnd('\') + '\'
    foreach ($f in @($Folders)) {
        if (-not $f) { continue }
        $ff = ($f -replace '/', '\').TrimEnd('\') + '\'
        if ($p.StartsWith($ff, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}
function Get-WHDInfoReportFolder {
    # Where the report may be written. '' = nowhere (screen only). Never a folder that folder protection blocks.
    param([string]$Wanted, [string]$NextDir, [bool]$IsAdmin)
    if ($Wanted) { return $Wanted }
    $copy = ''
    if ($env:ProgramData) { $copy = Join-Path (Join-Path $env:ProgramData 'WinHardenDebloatNext') 'app' }
    if ($copy -and $IsAdmin -and (Test-Path -LiteralPath (Join-Path $copy 'Start-WHD.ps1'))) { return (Join-Path $copy 'reports') }
    $cand = Join-Path $NextDir 'reports'
    try {
        $mp = Get-CimInstance -Namespace 'root/Microsoft/Windows/Defender' -ClassName 'MSFT_MpPreference' -ErrorAction Stop
        if ([int]$mp.EnableControlledFolderAccess -eq 1) {
            $prot = New-Object System.Collections.Generic.List[string]
            foreach ($sf in @('MyDocuments', 'MyPictures', 'MyVideos', 'MyMusic', 'DesktopDirectory', 'Favorites')) {
                try { $fp = [Environment]::GetFolderPath($sf); if ($fp) { $prot.Add($fp) } } catch { }
            }
            if ($env:PUBLIC) { foreach ($sub in @('Documents', 'Pictures', 'Videos', 'Music', 'Desktop')) { $prot.Add((Join-Path $env:PUBLIC $sub)) } }
            foreach ($e in @($mp.ControlledFolderAccessProtectedFolders)) { if ($e) { $prot.Add([string]$e) } }
            if (Test-WHDInfoUnder -Path $cand -Folders $prot.ToArray()) { return '' }
        }
    } catch { }
    return $cand
}

$isAdmin = Test-WHDInfoAdmin
$engine  = ('{0} {1}' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
$is51    = ($PSVersionTable.PSEdition -ne 'Core')

Add-Line 'WHD Next - theme facts from this PC (read-only)'
Add-Line ('Created  : {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Add-Line ('Engine   : {0}' -f $engine)
Add-Line ('User     : {0}\{1}   administrator window: {2}' -f $env:USERDOMAIN, $env:USERNAME, $isAdmin)
Add-Line ('Computer : {0}' -f $env:COMPUTERNAME)
try {
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    Add-Line ('Windows  : {0} | edition id {1} | {2} | build {3}.{4}' -f $cv.ProductName, $cv.EditionID, $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR)
} catch { Add-Line ('Windows  : not readable: {0}' -f $_.Exception.Message) }

# ---- 1. screen ----------------------------------------------------------------
Add-Head '1. SCREEN'
try {
    foreach ($v in @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)) {
        Add-Line ('  adapter : {0}   {1} x {2}   {3} Hz' -f $v.Name, $v.CurrentHorizontalResolution, $v.CurrentVerticalResolution, $v.CurrentRefreshRate)
    }
} catch { Add-Line ('  adapters not readable: {0}' -f $_.Exception.Message) }
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    foreach ($s in @([System.Windows.Forms.Screen]::AllScreens)) {
        Add-Line ('  screen  : {0}   {1} x {2} at {3},{4}   primary: {5}   (size as this program sees it; scaling can make it smaller)' -f $s.DeviceName, $s.Bounds.Width, $s.Bounds.Height, $s.Bounds.X, $s.Bounds.Y, $s.Primary)
    }
} catch { Add-Line ('  screens not readable: {0}' -f $_.Exception.Message) }
Add-RegValue 'HKCU:\Control Panel\Desktop\WindowMetrics' 'AppliedDPI'
Add-RegValue 'HKCU:\Control Panel\Desktop' 'LogPixels'

# ---- 2. theme -------------------------------------------------------------------
Add-Head '2. THEME IN USE'
Add-RegKey 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes'
$curTheme = ''
try { $curTheme = [string](Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes' -Name 'CurrentTheme' -ErrorAction Stop).CurrentTheme } catch { }
if ($curTheme -and (Test-Path -LiteralPath $curTheme)) {
    Add-Line (' the current theme file, as Windows wrote it ({0}):' -f $curTheme)
    try {
        $tl = @(Get-Content -LiteralPath $curTheme -ErrorAction Stop)
        $shown = 0
        foreach ($l in $tl) { if ("$l".Trim()) { $shown++; if ($shown -le 220) { Add-Line ('  | {0}' -f $l) } } }
        if ($shown -gt 220) { Add-Line ('  | ... {0} more line(s)' -f ($shown - 220)) }
    } catch { Add-Line ('  not readable: {0}' -f $_.Exception.Message) }
} else { Add-Line (' current theme file: {0}' -f $(if ($curTheme) { $curTheme + ' (file not found)' } else { '(no CurrentTheme value)' })) }

Add-Line ' theme files Windows ships (only the [VisualStyles] and [Sounds] lines - they show which keys Windows uses):'
try {
    $sysThemes = Join-Path $env:WinDir 'Resources\Themes'
    foreach ($f in @(Get-ChildItem -LiteralPath $sysThemes -Filter '*.theme' -File -ErrorAction Stop | Sort-Object Name)) {
        Add-Line ('  {0}' -f $f.Name)
        $fl = @(Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue)
        foreach ($sec in @('VisualStyles', 'Sounds')) { foreach ($l in @(Get-WHDIniSection -Lines $fl -Section $sec)) { Add-Line ('      [{0}] {1}' -f $sec, $l) } }
    }
} catch { Add-Line ('  not readable: {0}' -f $_.Exception.Message) }
Add-Line ' the user''s own theme files:'
try {
    $userThemes = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Themes'
    $uf = @(Get-ChildItem -LiteralPath $userThemes -Recurse -Filter '*.theme' -File -ErrorAction Stop)
    if (-not $uf.Count) { Add-Line '  (none)' }
    foreach ($f in $uf) { Add-Line ('  {0}   {1} bytes   {2}' -f $f.FullName, $f.Length, $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')) }
} catch { Add-Line ('  not readable: {0}' -f $_.Exception.Message) }

# ---- 3. dark mode ----------------------------------------------------------------
Add-Head '3. DARK / LIGHT MODE'
Add-RegKey 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'

# ---- 4. accent colour --------------------------------------------------------------
Add-Head '4. ACCENT COLOUR'
Add-RegKey 'HKCU:\Software\Microsoft\Windows\DWM'
Add-RegKey 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'
Add-Line ' HKCU:\Control Panel\Desktop / Colors'
Add-RegValue 'HKCU:\Control Panel\Desktop' 'AutoColorization'
Add-RegValue 'HKCU:\Control Panel\Colors' 'Hilight'
Add-RegValue 'HKCU:\Control Panel\Colors' 'HotTrackingColor'

# ---- 5. desktop picture ---------------------------------------------------------------
Add-Head '5. DESKTOP PICTURE / SLIDESHOW'
Add-Line ' HKCU:\Control Panel\Desktop'
foreach ($n in @('Wallpaper', 'WallpaperStyle', 'TileWallpaper')) { Add-RegValue 'HKCU:\Control Panel\Desktop' $n }
Add-RegKey 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers' 20
Add-Line ' files in %APPDATA%\Microsoft\Windows\Themes:'
try {
    $at = Join-Path $env:APPDATA 'Microsoft\Windows\Themes'
    $af = @(Get-ChildItem -LiteralPath $at -Force -ErrorAction Stop)
    if (-not $af.Count) { Add-Line '  (none)' }
    foreach ($f in $af) { Add-Line ('  {0,-28} {1}' -f $f.Name, $(if ($f.PSIsContainer) { '<folder>' } else { ('{0} bytes   {1}' -f $f.Length, $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')) })) }
} catch { Add-Line ('  not readable: {0}' -f $_.Exception.Message) }

# ---- 6. sounds --------------------------------------------------------------------------
Add-Head '6. SOUND SCHEME'
try { Add-Line ('  scheme in use (HKCU:\AppEvents\Schemes, default value): {0}' -f (Get-Item -LiteralPath 'HKCU:\AppEvents\Schemes' -ErrorAction Stop).GetValue('')) }
catch { Add-Line ('  scheme in use: not readable: {0}' -f $_.Exception.Message) }
Add-Line '  schemes that exist (HKCU:\AppEvents\Schemes\Names):'
try {
    foreach ($k in @(Get-ChildItem -LiteralPath 'HKCU:\AppEvents\Schemes\Names' -ErrorAction Stop)) { Add-Line ('    {0,-14} {1}' -f $k.PSChildName, $k.GetValue('')) }
} catch { Add-Line ('    not readable: {0}' -f $_.Exception.Message) }
foreach ($app in @('.Default', 'Explorer')) {
    Add-Line ('  events of "{0}"  (name | shown in the Sound window | file in use now)' -f $app)
    try {
        foreach ($k in @(Get-ChildItem -LiteralPath ('HKCU:\AppEvents\Schemes\Apps\{0}' -f $app) -ErrorAction Stop | Sort-Object PSChildName)) {
            $ev = $k.PSChildName
            $cur = '(no .Current key)'
            try { $ck = Get-Item -LiteralPath (Join-Path $k.PSPath '.Current') -ErrorAction Stop; $cur = [string]$ck.GetValue(''); if (-not $cur) { $cur = '(silent)' } } catch { }
            $hidden = ''
            try {
                $lk = Get-Item -LiteralPath ('HKCU:\AppEvents\EventLabels\{0}' -f $ev) -ErrorAction Stop
                if ($null -ne $lk.GetValue('ExcludeFromCPL', $null)) { $hidden = ('hidden (ExcludeFromCPL={0})' -f $lk.GetValue('ExcludeFromCPL')) } else { $hidden = 'shown' }
            } catch { $hidden = 'no label' }
            Add-Line ('    {0,-34} | {1,-28} | {2}' -f $ev, $hidden, $cur)
        }
    } catch { Add-Line ('    not readable: {0}' -f $_.Exception.Message) }
}
try { Add-Line ('  .wav files in {0}: {1}' -f (Join-Path $env:WinDir 'Media'), @(Get-ChildItem -LiteralPath (Join-Path $env:WinDir 'Media') -Filter '*.wav' -File -ErrorAction Stop).Count) }
catch { Add-Line ('  Windows Media folder not readable: {0}' -f $_.Exception.Message) }

# ---- 7. start-up sound --------------------------------------------------------------------
Add-Head '7. START-UP SOUND SWITCH'
Add-Line ' HKLM ...\Authentication\LogonUI\BootAnimation'
Add-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\BootAnimation' 'DisableStartupSound'
Add-Line ' HKLM ...\Policies\System'
Add-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'DisableStartupSound'
Add-Line ' HKLM ...\EditionOverrides'
Add-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\EditionOverrides' 'UserSetting_DisableStartupSound'

# ---- 8. lock screen ---------------------------------------------------------------------
Add-Head '8. LOCK SCREEN'
if ($is51) {
    try {
        $null = [Windows.System.UserProfile.LockScreen, Windows.System.UserProfile, ContentType = WindowsRuntime]
        Add-Line '  lock screen call (Windows.System.UserProfile.LockScreen): the type loads in this PowerShell'
        try { Add-Line ('  picture in use now (read only): {0}' -f [Windows.System.UserProfile.LockScreen]::OriginalImageFile) }
        catch { Add-Line ('  picture in use now: not readable: {0}' -f $_.Exception.Message) }
    } catch { Add-Line ('  lock screen call: the type does NOT load: {0}' -f $_.Exception.Message) }
    try {
        $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
        Add-Line '  file helper (Windows.Storage.StorageFile): loads'
    } catch { Add-Line ('  file helper (Windows.Storage.StorageFile): does NOT load: {0}' -f $_.Exception.Message) }
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
        $m = @([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' }).Count
        Add-Line ('  wait helper (System.Runtime.WindowsRuntime, AsTask): loads, {0} form(s)' -f $m)
    } catch { Add-Line ('  wait helper (System.Runtime.WindowsRuntime): does NOT load: {0}' -f $_.Exception.Message) }
} else {
    Add-Line '  lock screen call: not tried here - PowerShell 7 cannot use it (expected); see the Windows PowerShell 5.1 report'
}
Add-RegKey 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lock Screen' 25
Add-Line ' HKCU ...\ContentDeliveryManager (Windows spotlight on the lock screen)'
foreach ($n in @('RotatingLockScreenEnabled', 'RotatingLockScreenOverlayEnabled')) { Add-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' $n }
Add-RegKey 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' 12
Add-RegKey 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' 12

# ---- 9. scheduled-task triggers -----------------------------------------------------------------
Add-Head '9. SCHEDULED-TASK TRIGGERS'
foreach ($c in @('MSFT_TaskSessionStateChangeTrigger', 'MSFT_TaskEventTrigger', 'MSFT_TaskLogonTrigger', 'MSFT_TaskTimeTrigger')) {
    try {
        $cls = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName $c -ErrorAction Stop
        Add-Line ('  {0}: exists; properties: {1}' -f $c, (@($cls.CimClassProperties | ForEach-Object { '{0} ({1})' -f $_.Name, $_.CimType }) -join ', '))
    } catch { Add-Line ('  {0}: NOT found: {1}' -f $c, $_.Exception.Message) }
}
Add-Line '  WHD tasks on this PC:'
foreach ($tp in @('\WinHardenDebloatNext\', '\WinHardenDebloat\')) {
    try {
        $ts = @(Get-ScheduledTask -TaskPath $tp -ErrorAction SilentlyContinue)
        if (-not $ts.Count) { Add-Line ('    {0} (none)' -f $tp) }
        foreach ($t in $ts) { Add-Line ('    {0}{1}   {2}' -f $t.TaskPath, $t.TaskName, $t.State) }
    } catch { Add-Line ('    {0} not readable: {1}' -f $tp, $_.Exception.Message) }
}

# ---- 10. sound devices ---------------------------------------------------------------------------
Add-Head '10. SOUND OUTPUT'
try {
    $sd = @(Get-CimInstance -ClassName Win32_SoundDevice -ErrorAction Stop)
    if (-not $sd.Count) { Add-Line '  (no sound device found)' }
    foreach ($d in $sd) { Add-Line ('  device : {0}   status: {1}' -f $d.Name, $d.Status) }
} catch { Add-Line ('  devices not readable: {0}' -f $_.Exception.Message) }
try { $sv = Get-Service -Name 'Audiosrv' -ErrorAction Stop; Add-Line ('  Windows Audio service: {0} ({1})' -f $sv.Status, $sv.StartType) }
catch { Add-Line ('  Windows Audio service: not readable: {0}' -f $_.Exception.Message) }
try { $null = [System.Media.SoundPlayer]; Add-Line '  .wav player (System.Media.SoundPlayer): the type loads in this PowerShell (nothing was played)' }
catch { Add-Line ('  .wav player (System.Media.SoundPlayer): does NOT load: {0}' -f $_.Exception.Message) }

# ---- 11. folders ------------------------------------------------------------------------------------
Add-Head '11. FOLDERS'
try {
    $base = ''
    if ($env:ProgramData) { $base = Join-Path $env:ProgramData 'WinHardenDebloatNext' }
    foreach ($d in @($base, $(if ($base) { Join-Path $base 'app' }), $(if ($base) { Join-Path $base 'theme' }))) {
        if ($d) { Add-Line ('  {0,-52} {1}' -f $d, $(if (Test-Path -LiteralPath $d) { 'exists' } else { 'not there' })) }
    }
    $drv = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $env:SystemDrive) -ErrorAction Stop
    Add-Line ('  free space on {0} {1:N1} GB' -f $env:SystemDrive, ($drv.FreeSpace / 1GB))
} catch { Add-Line ('  not readable: {0}' -f $_.Exception.Message) }

Add-Line ''
Add-Line 'End of report. Nothing was changed.'

# ---- show + save ---------------------------------------------------------------------------------------
$out | ForEach-Object { Write-Host $_ }
$folder = Get-WHDInfoReportFolder -Wanted $ReportRoot -NextDir $nextDir -IsAdmin $isAdmin
if (-not $folder) {
    Write-Host ''
    Write-Host ' Report NOT saved: the only place left is protected by Windows folder protection. Copy the text above instead,' -ForegroundColor Yellow
    Write-Host ' or run this in an administrator window (the report then goes to the unlocked copy).' -ForegroundColor Yellow
} else {
    try {
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null }
        $tag  = 'ps7'; if ($is51) { $tag = 'ps51' }
        $file = Join-Path $folder ('themeinfo_{0}_{1}.txt' -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'), $tag)
        $out | Set-Content -LiteralPath $file -Encoding ASCII -ErrorAction Stop
        Write-Host ''
        Write-Host (' Report saved: {0}' -f $file) -ForegroundColor Green
    } catch {
        Write-Host ''
        Write-Host (' Report NOT saved ({0}). Copy the text above instead.' -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

# ---- once more on the other PowerShell ---------------------------------------------------------------------
if (-not $NoOther) {
    $other = ''
    if ($is51) { if ($env:ProgramFiles) { $other = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe' } }
    else       { if ($env:SystemRoot)   { $other = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' } }
    if ($other -and (Test-Path -LiteralPath $other)) {
        Write-Host ''
        Write-Host (' Running the same read-only check on the other PowerShell ({0}) ...' -f $other) -ForegroundColor Cyan
        $otherArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MyInvocation.MyCommand.Path, '-NoOther')
        if ($ReportRoot) { $otherArgs += @('-ReportRoot', $ReportRoot) }
        try { & $other @otherArgs } catch { Write-Host (' could not be started: {0}' -f $_.Exception.Message) -ForegroundColor Yellow }
    } else {
        Write-Host ''
        Write-Host ' The other PowerShell was not found on this PC, so there is one report only.' -ForegroundColor DarkGray
    }
}
