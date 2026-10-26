#requires -Version 7.6
<#
================================================================================
 WHD Next 3.0  -  Features/ThemeLook.ps1   (theme part b: the look)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Build step 5.10b. Same features as WHD Next 2.0 (D8), written new for 7.6:
   5  use the look "WHD Next 3.0": the 24 new pictures of this project (D58,
      D70) as a desktop slide show (a new one every 30 minutes, shuffled),
      dark mode, accent colour sky blue - also on Start, the taskbar and
      title bars. One colour only (D69: no 5R). Your own pictures can join
      the slide show (a folder of your own, asked first).
   6  put back: ALWAYS Windows' own dark theme (D71).
 How (as 2.0, Windows' own way): WHD writes a theme file into the user's
 themes folder and has Windows open it; Windows lists it in Settings >
 Personalization > Themes and may wait for a click on it. The theme file is
 the theme in use now with only name, desktop pictures, slide show, dark
 mode and accent colour replaced. A theme change may reset sounds, so the
 sounds are written down first and put back after. Applying the look removes
 WHD Next 2.0's themes "WHD Next" / "WHD Next (red)" from the list (D71).
================================================================================
#>

$script:WHDLookFile    = 'WHD Next 3.0.theme'
$script:WHDLookName    = 'WHD Next 3.0'
$script:WHDLookId      = '{57484431-4E58-4C4F-4F4B-0000000030C1}'     # our own id: the theme is ours wherever Windows keeps it
$script:WHDLookAccent  = '40A4FF'                                     # sky blue (D69)
$script:WHDLookOld     = @('WHD Next.theme', 'WHD Next (red).theme')  # WHD Next 2.0's themes, removed on apply (D71)
$script:WHDLookSeconds = 1800                                         # a new picture every 30 minutes
$script:WHDLookPicExt  = @('.jpg', '.jpeg', '.png', '.bmp')
$script:WHDKeyThemes   = 'Software\Microsoft\Windows\CurrentVersion\Themes'
$script:WHDKeyPers     = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$script:WHDKeyDwm      = 'Software\Microsoft\Windows\DWM'
$script:WHDLookUserDirOverride = $null                                # tests only
$script:WHDLookWinDirOverride  = $null                                # tests only

# ---- places --------------------------------------------------------------------------------------------
function Get-WHDLookPictureSource {
    # The pictures shipped with WHD Next 3.0: <WHD folder>\theme\pictures.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return [System.IO.Path]::Combine($script:WHDState.Root, 'theme', 'pictures')
}
function Get-WHDLookDir {
    # slideshow = the pictures the slide show uses; own = the user's own pictures folder.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidateSet('slideshow', 'own')][string]$What)
    $b = Get-WHDThemeBase; if (-not $b) { return '' }
    return [System.IO.Path]::Combine($b, $(if ($What -eq 'own') { 'my-pictures' } else { 'pictures' }))
}
function Get-WHDLookUserThemeDir {
    # Where Windows keeps the user's own themes ("%LOCALAPPDATA%\Microsoft\Windows\Themes"). Written straight
    # there, Windows lists the theme once under one name (seen with WHD Next 2.0 on the owner's PC).
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($script:WHDLookUserDirOverride) { return $script:WHDLookUserDirOverride }
    if (-not $env:LOCALAPPDATA) { return '' }
    return [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Microsoft', 'Windows', 'Themes')
}
function Get-WHDLookWindowsDark {
    # Windows' own dark theme file (D71).
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $root = if ($script:WHDLookWinDirOverride) { $script:WHDLookWinDirOverride } else { $env:SystemRoot }
    if (-not $root) { return '' }
    return [System.IO.Path]::Combine($root, 'Resources', 'Themes', 'dark.theme')
}

# ---- the registry: named values under HKEY_CURRENT_USER (tests swap these three) ---------------------------
function Get-WHDLookRegValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SubKey, [Parameter(Mandatory)][string]$Name)
    $o = [pscustomobject]@{ Exists = $false; Value = $null }
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey)
    if ($null -eq $k) { return $o }
    try { if (@($k.GetValueNames()) -contains $Name) { $o.Exists = $true; $o.Value = $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } }
    finally { $k.Dispose() }
    return $o
}
function Set-WHDLookRegDword {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$SubKey, [Parameter(Mandatory)][string]$Name, [int]$Value)
    if (-not $PSCmdlet.ShouldProcess("HKCU\$SubKey", "set $Name")) { return }
    $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($SubKey)
    if ($null -eq $k) { throw ('registry key could not be opened for writing: HKCU\{0}' -f $SubKey) }
    try { $k.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]::DWord) } finally { $k.Dispose() }
}
function Get-WHDLookCurrentTheme {
    # The theme file Windows reports in use (expanded path), or ''.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $v = Get-WHDLookRegValue -SubKey $script:WHDKeyThemes -Name 'CurrentTheme'
    if (-not $v.Exists) { return '' }
    return [Environment]::ExpandEnvironmentVariables([string]$v.Value)
}

# ---- Windows itself (tests swap these) ---------------------------------------------------------------------
function Open-WHDLookFile {
    # Opening a .theme file is how Windows applies a theme. Handed to Explorer so it opens on the normal desktop
    # (from an administrator window Windows did not take it over - seen with 2.0 on the owner's PC).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $Path) -ErrorAction Stop
}
function Open-WHDLookFolder {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $Path) -ErrorAction Stop } catch { Write-Verbose $_.Exception.Message }
}
function Wait-WHDLook {
    [CmdletBinding()]
    param([int]$Ms)
    Start-Sleep -Milliseconds $Ms
}

# ---- theme files: .ini text, one byte per character ---------------------------------------------------------
function Read-WHDIniText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $b = [System.IO.File]::ReadAllBytes($Path)
    if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { return [System.Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2) }
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { return [System.Text.Encoding]::UTF8.GetString($b, 3, $b.Length - 3) }
    return [System.Text.Encoding]::Latin1.GetString($b)
}
function ConvertFrom-WHDIni {
    # Text -> ordered list of sections @{ Name; Lines }. Comments, blank lines and order are all kept.
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[object]], [object[]])]
    param([AllowEmptyString()][string]$Text)
    $secs = [System.Collections.Generic.List[object]]::new()
    $cur = [pscustomobject]@{ Name = ''; Lines = [System.Collections.Generic.List[string]]::new() }
    $secs.Add($cur)
    foreach ($ln in ($Text -split "`r?`n")) {
        if ($ln -match '^\s*\[(.+)\]\s*$') { $cur = [pscustomobject]@{ Name = $Matches[1]; Lines = [System.Collections.Generic.List[string]]::new() }; $secs.Add($cur) }
        else { $cur.Lines.Add($ln) }
    }
    return , $secs
}
function ConvertTo-WHDIniText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Ini)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $Ini) { if ($s.Name) { $out.Add(('[{0}]' -f $s.Name)) }; foreach ($l in $s.Lines) { $out.Add($l) } }
    $t = $out -join "`r`n"
    if (-not $t.EndsWith("`r`n")) { $t += "`r`n" }
    return $t
}
function Get-WHDIniSection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Ini, [Parameter(Mandatory)][string]$Name, [switch]$Create)
    foreach ($s in $Ini) { if ($s.Name -eq $Name) { return $s } }
    if (-not $Create) { return $null }
    $s = [pscustomobject]@{ Name = $Name; Lines = [System.Collections.Generic.List[string]]::new() }
    $Ini.Add($s)
    return $s
}
function Get-WHDIniValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Ini, [Parameter(Mandatory)][string]$Section, [Parameter(Mandatory)][string]$Key)
    $s = Get-WHDIniSection -Ini $Ini -Name $Section
    if ($null -eq $s) { return $null }
    $rx = '^\s*{0}\s*=(.*)$' -f [regex]::Escape($Key)
    foreach ($l in $s.Lines) { if ($l -match $rx) { return $Matches[1] } }
    return $null
}
function Set-WHDIniValue {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Ini, [Parameter(Mandatory)][string]$Section, [Parameter(Mandatory)][string]$Key, [AllowEmptyString()][string]$Value)
    if (-not $PSCmdlet.ShouldProcess("[$Section] $Key", 'set')) { return }
    $s = Get-WHDIniSection -Ini $Ini -Name $Section -Create
    $rx = '^\s*{0}\s*=' -f [regex]::Escape($Key)
    for ($i = 0; $i -lt $s.Lines.Count; $i++) { if ($s.Lines[$i] -match $rx) { $s.Lines[$i] = ('{0}={1}' -f $Key, $Value); return } }
    $at = $s.Lines.Count
    while ($at -gt 0 -and $s.Lines[$at - 1] -match '^\s*(;.*)?$') { $at-- }      # before the blank lines that end the section
    $s.Lines.Insert($at, ('{0}={1}' -f $Key, $Value))
}
function Remove-WHDIniKey {
    # One key, or every key of the section (Key = '*'). Comments and blank lines stay.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Ini, [Parameter(Mandatory)][string]$Section, [Parameter(Mandatory)][string]$Key)
    if (-not $PSCmdlet.ShouldProcess("[$Section] $Key", 'remove')) { return }
    $s = Get-WHDIniSection -Ini $Ini -Name $Section
    if ($null -eq $s) { return }
    $rx = if ($Key -eq '*') { '^\s*[^;=\s][^=]*=' } else { '^\s*{0}\s*=' -f [regex]::Escape($Key) }
    for ($i = $s.Lines.Count - 1; $i -ge 0; $i--) { if ($s.Lines[$i] -match $rx) { $s.Lines.RemoveAt($i) } }
}
function Get-WHDLookText {
    # The text of "WHD Next 3.0.theme": the base theme with only name, id, desktop pictures, slide show, dark mode and
    # accent colour replaced (and the sound scheme named, so the theme does not reset the sounds).
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$BaseText, [Parameter(Mandatory)][string[]]$Pictures, [Parameter(Mandatory)][string]$PictureDir, [string]$SoundScheme)
    if (-not $BaseText) {
        $BaseText = @('[Theme]', '[Control Panel\Desktop]', '[VisualStyles]', 'Path=%SystemRoot%\resources\themes\Aero\Aero.msstyles',
                      'ColorStyle=NormalColor', 'Size=NormalSize', 'VisualStyleVersion=10', '[MasterThemeSelector]', 'MTSM=RJSPBS', '') -join "`r`n"
    }
    $ini = ConvertFrom-WHDIni -Text $BaseText
    for ($i = $ini[0].Lines.Count - 1; $i -ge 0; $i--) { if ($ini[0].Lines[$i] -like ('; {0} - written by WHD Next 3.0*' -f $script:WHDLookName)) { $ini[0].Lines.RemoveAt($i) } }   # one note only (D77: the base may be a copy of ours)
    $ini[0].Lines.Insert(0, ('; {0} - written by WHD Next 3.0, {1:yyyy-MM-dd HH:mm}: the theme in use before, with name, desktop pictures, slide show, dark mode and accent colour replaced.' -f $script:WHDLookName, (Get-Date)))
    Set-WHDIniValue -Ini $ini -Section 'Theme' -Key 'DisplayName' -Value $script:WHDLookName -Confirm:$false
    Set-WHDIniValue -Ini $ini -Section 'Theme' -Key 'ThemeId' -Value $script:WHDLookId -Confirm:$false
    $d = 'Control Panel\Desktop'
    foreach ($kv in @(@('Wallpaper', $Pictures[0]), @('TileWallpaper', '0'), @('WallpaperStyle', '10'), @('PicturePosition', '4'), @('MultimonBackgrounds', '0'), @('WindowsSpotlight', '0'))) {
        Set-WHDIniValue -Ini $ini -Section $d -Key $kv[0] -Value $kv[1] -Confirm:$false
    }
    Remove-WHDIniKey -Ini $ini -Section $d -Key 'WallpaperWriteTime' -Confirm:$false
    Remove-WHDIniKey -Ini $ini -Section 'Slideshow' -Key '*' -Confirm:$false
    Set-WHDIniValue -Ini $ini -Section 'Slideshow' -Key 'Interval' -Value ([string]($script:WHDLookSeconds * 1000)) -Confirm:$false
    Set-WHDIniValue -Ini $ini -Section 'Slideshow' -Key 'Shuffle' -Value '1' -Confirm:$false
    Set-WHDIniValue -Ini $ini -Section 'Slideshow' -Key 'ImagesRootPath' -Value $PictureDir -Confirm:$false
    for ($i = 0; $i -lt $Pictures.Count; $i++) { Set-WHDIniValue -Ini $ini -Section 'Slideshow' -Key ('Item{0}Path' -f $i) -Value $Pictures[$i] -Confirm:$false }
    $v = 'VisualStyles'
    if ($null -eq (Get-WHDIniValue -Ini $ini -Section $v -Key 'Path')) { Set-WHDIniValue -Ini $ini -Section $v -Key 'Path' -Value '%SystemRoot%\resources\themes\Aero\Aero.msstyles' -Confirm:$false }
    foreach ($kv in @(@('AutoColorization', '0'), @('ColorizationColor', ('0XC4{0}' -f $script:WHDLookAccent)), @('SystemMode', 'Dark'), @('AppMode', 'Dark'))) {
        Set-WHDIniValue -Ini $ini -Section $v -Key $kv[0] -Value $kv[1] -Confirm:$false
    }
    if ($null -eq (Get-WHDIniValue -Ini $ini -Section 'MasterThemeSelector' -Key 'MTSM')) { Set-WHDIniValue -Ini $ini -Section 'MasterThemeSelector' -Key 'MTSM' -Value 'RJSPBS' -Confirm:$false }
    if ($SoundScheme) { Set-WHDIniValue -Ini $ini -Section 'Sounds' -Key 'SchemeName' -Value $SoundScheme -Confirm:$false }
    return (ConvertTo-WHDIniText -Ini $ini)
}

# ---- read-only state --------------------------------------------------------------------------------------
function Test-WHDLookOwn {
    # Is this theme file ours (3.0)? By its name, by our id inside it (Windows may keep its own copy), or by its
    # content (D77): a theme the user saved under another name in Settings still counts when it shows the WHD
    # pictures folder and the sky-blue accent.
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][string]$Path)
    if (-not $Path) { return $false }
    if ([System.IO.Path]::GetFileName($Path) -eq $script:WHDLookFile) { return $true }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $ini = ConvertFrom-WHDIni -Text (Read-WHDIniText -Path $Path)
        if (([string](Get-WHDIniValue -Ini $ini -Section 'Theme' -Key 'ThemeId')).Trim() -eq $script:WHDLookId) { return $true }
        return (Test-WHDLookContent -Ini $ini)
    } catch { return $false }
}
function Test-WHDLookContent {
    # The WHD look by content (D77): the sky-blue accent AND pictures from the WHD pictures folder - its slide-show
    # folder, one of its slide-show pictures, or the desktop picture (Windows may keep only some of these when the
    # user saves the theme under a new name in Settings).
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Ini)
    $dir = Get-WHDLookDir -What slideshow
    if (-not $dir) { return $false }
    $dir = $dir.TrimEnd('\', '/')
    $color = ([string](Get-WHDIniValue -Ini $Ini -Section 'VisualStyles' -Key 'ColorizationColor')).Trim()
    if ($color -notmatch ('(?i){0}$' -f $script:WHDLookAccent)) { return $false }
    $paths = [System.Collections.Generic.List[string]]::new()
    $paths.Add([string](Get-WHDIniValue -Ini $Ini -Section 'Slideshow' -Key 'ImagesRootPath'))
    $paths.Add([string](Get-WHDIniValue -Ini $Ini -Section 'Control Panel\Desktop' -Key 'Wallpaper'))
    $sec = Get-WHDIniSection -Ini $Ini -Name 'Slideshow'
    if ($sec) { foreach ($l in $sec.Lines) { if ($l -match '^\s*Item\d+Path\s*=(.*)$') { $paths.Add($Matches[1]) } } }
    foreach ($p in $paths) {
        $x = [Environment]::ExpandEnvironmentVariables(([string]$p).Trim()).TrimEnd('\', '/')
        if (-not $x) { continue }
        if ([string]::Equals($x, $dir, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($x.StartsWith($dir + '\', [StringComparison]::OrdinalIgnoreCase) -or $x.StartsWith($dir + '/', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}
function Get-WHDLookPictureList {
    # Picture files of one folder (not its sub-folders), by name.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([AllowEmptyString()][string]$Dir, [string]$Filter = '*')
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return , @() }
    return , @(Get-ChildItem -LiteralPath $Dir -Filter $Filter -File -ErrorAction SilentlyContinue | Where-Object { $script:WHDLookPicExt -contains $_.Extension.ToLowerInvariant() } | Sort-Object Name)
}
function Get-WHDLookState {
    [CmdletBinding()]
    param()
    $o = [ordered]@{ Readable = $true; ThemePath = ''; ThemeName = ''; InUse = $false; Dark = $false; Ours = 0; Own = 0; Text = ''; PicText = '' }
    try {
        $o.ThemePath = Get-WHDLookCurrentTheme
        $o.ThemeName = if ($o.ThemePath) { [System.IO.Path]::GetFileNameWithoutExtension($o.ThemePath) } else { '(none)' }
        if ($o.ThemePath -and (Test-Path -LiteralPath $o.ThemePath)) {
            try { $dn = ([string](Get-WHDIniValue -Ini (ConvertFrom-WHDIni -Text (Read-WHDIniText -Path $o.ThemePath)) -Section 'Theme' -Key 'DisplayName')).Trim(); if ($dn -and $dn -notmatch '^@') { $o.ThemeName = $dn } }
            catch { Write-Verbose $_.Exception.Message }
        }
        $o.InUse = Test-WHDLookOwn -Path $o.ThemePath
        $a = Get-WHDLookRegValue -SubKey $script:WHDKeyPers -Name 'AppsUseLightTheme'; $s = Get-WHDLookRegValue -SubKey $script:WHDKeyPers -Name 'SystemUsesLightTheme'
        $o.Dark = ($a.Exists -and [int]$a.Value -eq 0 -and $s.Exists -and [int]$s.Value -eq 0)
        $o.Text = if ($o.InUse) { 'in use' } else { 'not in use - theme in use: {0}' -f $o.ThemeName }
    } catch { $o.Readable = $false; $o.Text = ('not readable: {0}' -f $_.Exception.Message) }
    $o.Ours = (Get-WHDLookPictureList -Dir (Get-WHDLookPictureSource) -Filter 'whd-*').Count
    $o.Own = (Get-WHDLookPictureList -Dir (Get-WHDLookDir -What own)).Count
    $o.PicText = '{0} WHD pictures, {1} of your own' -f $o.Ours, $o.Own
    return [pscustomobject]$o
}

# ---- your own pictures (asked before the folder is made) ----------------------------------------------------
function Set-WHDLookFolderGrant {
    # The signed-in user may change this ONE folder (and what is in it). Nothing else is opened up.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Dir)
    if (-not $PSCmdlet.ShouldProcess($Dir, 'grant the signed-in user modify')) { return }
    $r = Invoke-WHDNative -Exe 'icacls.exe' -ArgList @($Dir, '/grant', ('{0}\{1}:(OI)(CI)M' -f $env:USERDOMAIN, $env:USERNAME), '/Q')
    if ($r.Code -ne 0) { throw ('icacls exit {0}: {1}' -f $r.Code, ($r.Out -join ' ')) }
}
function Invoke-WHDLookOwnPicture {
    # Offers the folder for your own pictures (made only after a yes), opens it, waits for Enter.
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Ask)
    $dir = Get-WHDLookDir -What own
    if (-not $dir) { return }
    if (-not (Test-Path -LiteralPath $dir)) {
        Write-Host ''
        Write-Host '  Your own pictures can be part of the slide show.' -ForegroundColor Cyan
        Write-Host ('  For that WHD would make this folder: {0}' -f $dir)
        if (([string](& $Ask '  Make the folder for your own pictures? [y/N]')).Trim() -notmatch '^[Yy]') { Write-WHDLog -Message 'Own pictures: no folder made - the slide show uses the WHD pictures.'; return }
        try { [void](New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop) }
        catch { Write-WHDLog -Message ('The folder could not be made: {0}' -f $_.Exception.Message) -Level 'ERR'; return }
        Write-WHDLog -Message ('Own pictures: folder made - {0}' -f $dir) -Level 'OK'
    }
    if ((Get-Item -LiteralPath $dir -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) { Write-WHDLog -Message ('Own pictures: {0} is a link to another place, not a plain folder - not used.' -f $dir) -Level 'WARN'; return }
    try { Set-WHDLookFolderGrant -Dir $dir -Confirm:$false; Write-WHDLog -Message ('Own pictures: your account ({0}) may put files into this ONE folder without the administrator prompt.' -f $env:USERNAME) -Level 'OK' }
    catch { Write-WHDLog -Message ('Own pictures: the folder permission could not be set ({0}) - copying into it asks for administrator permission.' -f $_.Exception.Message) -Level 'WARN' }
    Write-Host ('  Your own pictures go here: {0}' -f $dir) -ForegroundColor Cyan
    Write-Host ('  In it now: {0} picture(s). Kinds: .jpg .jpeg .png .bmp - names in plain English letters, digits, spaces, - and _ .' -f (Get-WHDLookPictureList -Dir $dir).Count)
    Write-Host '  WHD copies them into its slide-show folder; your files stay where you put them.' -ForegroundColor DarkGray
    Open-WHDLookFolder -Path $dir
    [void](& $Ask '  Put your pictures in now, then press Enter (or Enter right away to go on without)')
}

# ---- 5. use the look --------------------------------------------------------------------------------------
function Copy-WHDLookPicture {
    # Copies when the target is missing or different. Returns $true when it copied.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To)
    if ((Test-Path -LiteralPath $To) -and (Get-Item -LiteralPath $From).Length -eq (Get-Item -LiteralPath $To).Length -and
        (Get-FileHash -LiteralPath $From).Hash -eq (Get-FileHash -LiteralPath $To).Hash) { return $false }
    Copy-Item -LiteralPath $From -Destination $To -Force -ErrorAction Stop
    return $true
}
function Sync-WHDLookPicture {
    # Brings the slide-show folder up to date; returns the pictures the slide show uses. Inside the change gate only.
    [CmdletBinding()]
    param()
    $dst = Get-WHDLookDir -What slideshow
    if (-not (Test-Path -LiteralPath $dst)) { [void](New-Item -ItemType Directory -Path $dst -Force -ErrorAction Stop) }
    $list = [System.Collections.Generic.List[string]]::new(); $skipped = [System.Collections.Generic.List[string]]::new(); $same = 0
    $seen = @{}; $copied = 0; $whd = 0; $own = 0
    foreach ($f in (Get-WHDLookPictureList -Dir (Get-WHDLookPictureSource) -Filter 'whd-*')) {
        $to = [System.IO.Path]::Combine($dst, $f.Name)
        if (Copy-WHDLookPicture -From $f.FullName -To $to) { $copied++ }
        $list.Add($to); $whd++; $seen[(Get-FileHash -LiteralPath $f.FullName).Hash] = $f.Name
    }
    $ownDir = Get-WHDLookDir -What own
    $ownOk = $ownDir -and (Test-Path -LiteralPath $ownDir) -and -not ((Get-Item -LiteralPath $ownDir -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    foreach ($f in $(if ($ownOk) { Get-WHDLookPictureList -Dir $ownDir } else { @() })) {
        if ($f.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { $skipped.Add($f.Name + ' (a link)'); continue }
        if ($f.Name -match '[^\x20-\x7E]' -or $f.Name -match '%') { $skipped.Add($f.Name); continue }       # a theme file holds one byte per character; % starts a variable
        $h = (Get-FileHash -LiteralPath $f.FullName).Hash
        if ($seen.ContainsKey($h)) { $same++; continue }
        $seen[$h] = $f.Name
        $to = [System.IO.Path]::Combine($dst, 'my-' + $f.Name)
        if (Copy-WHDLookPicture -From $f.FullName -To $to) { $copied++ }
        $list.Add($to); $own++
    }
    [pscustomobject]@{ List = $list.ToArray(); Whd = $whd; Own = $own; Copied = $copied; Skipped = $skipped.ToArray(); Same = $same; Dir = $dst }
}
function Get-WHDLookSoundSnapshot {
    # Every sound in use now, so a theme change cannot quietly change them.
    [CmdletBinding()]
    param()
    $rows = @(foreach ($e in Get-WHDThemeEventList) { $k = '{0}\.Current' -f $e.Key; $c = Get-WHDThemeRegDefault -SubKey $k; [pscustomobject]@{ Key = $k; Exists = $c.Exists; Value = [string]$c.Value; Kind = $c.Kind } })
    [pscustomobject]@{ Scheme = [string](Get-WHDThemeRegDefault -SubKey $script:WHDThemeSchemesKey).Value; Rows = $rows }
}
function Restore-WHDLookSoundSnapshot {
    # Puts back every sound that differs; returns how many. Inside the change gate only.
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param([Parameter(Mandatory)]$Snap)
    if (-not $PSCmdlet.ShouldProcess('sounds', 'put back what the theme changed')) { return 0 }
    $n = 0
    foreach ($r in $Snap.Rows) {
        $c = Get-WHDThemeRegDefault -SubKey $r.Key
        if ($c.Exists -eq $r.Exists -and [string]$c.Value -eq $r.Value) { continue }
        # Windows writes the same file with %ALLUSERSPROFILE% etc. when a theme is applied: not a change
        if ($c.Exists -and $r.Exists -and [string]::Equals([Environment]::ExpandEnvironmentVariables([string]$c.Value), [Environment]::ExpandEnvironmentVariables($r.Value), [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not $r.Exists) { Remove-WHDThemeRegKey -SubKey $r.Key -Confirm:$false } else { Set-WHDThemeRegDefault -SubKey $r.Key -Value $r.Value -Kind $r.Kind }
        $n++
    }
    if ($Snap.Scheme -and [string](Get-WHDThemeRegDefault -SubKey $script:WHDThemeSchemesKey).Value -ne $Snap.Scheme) { Set-WHDThemeRegDefault -SubKey $script:WHDThemeSchemesKey -Value $Snap.Scheme; $n++ }
    return $n
}
function Wait-WHDLookSoundSettle {
    # Windows may change the sounds a little AFTER a theme is applied (owner's run 2026-10-20: the scheme went back
    # to Windows Default after the first check). Looks again a few times and puts back what changed. Returns how many.
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)]$Snap, [int]$Tries = 6)
    $n = 0
    for ($i = 0; $i -lt $Tries; $i++) {
        Wait-WHDLook -Ms 1000
        $n += Restore-WHDLookSoundSnapshot -Snap $Snap -Confirm:$false
    }
    return $n
}
function Set-WHDLookColorUse {
    # "Accent colour on Start and taskbar" and "... on title bars": 1 = on, 0 = off (Windows' own default).
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidateSet(0, 1)][int]$Value)
    if (-not $PSCmdlet.ShouldProcess('accent colour use', "set $Value")) { return }
    Set-WHDLookRegDword -SubKey $script:WHDKeyPers -Name 'ColorPrevalence' -Value $Value -Confirm:$false
    Set-WHDLookRegDword -SubKey $script:WHDKeyDwm -Name 'ColorPrevalence' -Value $Value -Confirm:$false
}
function Wait-WHDLookSwitch {
    # Half a second per try until Windows reports the wanted theme: -Ours = ours; otherwise any theme that is not ours.
    [CmdletBinding()]
    [OutputType([bool])]
    param([switch]$Ours, [int]$Tries = 12)
    for ($i = 0; $i -lt $Tries; $i++) {
        $p = Get-WHDLookCurrentTheme
        $is = Test-WHDLookOwn -Path $p
        if (($Ours -and $is) -or (-not $Ours -and $p -and -not $is)) { return $true }
        Wait-WHDLook -Ms 500
    }
    return $false
}
function Invoke-WHDLookByHand {
    # Windows 11 may list the theme and wait for a click on it (seen with 2.0 on the owner's PC). Names it, waits for Enter.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name, [switch]$Ours, [Parameter(Mandatory)][scriptblock]$Ask)
    Write-WHDLog -Message ('Windows waits for a click on the theme "{0}" in Settings > Personalization > Themes.' -f $Name)
    Write-Host '    1. Settings shows Personalization > Themes  (if not open: Settings > Personalization > Themes).' -ForegroundColor Yellow
    Write-Host ('    2. Click the theme named:  {0}' -f $Name) -ForegroundColor Cyan
    Write-Host '    3. Come back to this window and press Enter.' -ForegroundColor Yellow
    [void](& $Ask '  Press Enter after the click (or Enter right away to give up)')
    $ok = Wait-WHDLookSwitch -Ours:$Ours -Tries 20
    if ($ok) { Write-WHDLog -Message 'The theme was chosen by hand in Settings.' }
    return $ok
}
function Invoke-WHDLookApply {
    # 5: use the look "WHD Next 3.0". -Answer feeds the questions (tests). -NoOwnAsk: own pictures as they are (A).
    [CmdletBinding()]
    param([string[]]$Answer, [switch]$NoOwnAsk)
    $ask = Get-WHDAnswerReader -Answer $Answer
    Write-WHDLog -Message ('THEME 5: the look "{0}" - pictures, dark mode, sky blue' -f $script:WHDLookName) -Level 'ACT'
    if (-not (Get-WHDThemeBase) -or -not (Get-WHDLookUserThemeDir)) { Write-WHDLog -Message 'No ProgramData / user themes folder on this PC - the look has no place.' -Level 'ERR'; return }
    $st = Get-WHDLookState
    if (-not $st.Ours) { Write-WHDLog -Message ('The WHD pictures were not found in {0}.' -f (Get-WHDLookPictureSource)) -Level 'ERR'; return }
    if (-not $script:WHDState.IsAdmin) { Write-WHDLog -Message ('Needs an administrator window: the pictures go into {0}.' -f (Get-WHDThemeBase)) -Level 'WARN'; return }
    if (-not $st.Readable) { Write-WHDLog -Message ('The theme of this user could not be read: {0}' -f $st.Text) -Level 'ERR'; return }
    $themeFile = [System.IO.Path]::Combine((Get-WHDLookUserThemeDir), $script:WHDLookFile)
    $old = @($script:WHDLookOld | ForEach-Object { [System.IO.Path]::Combine((Get-WHDLookUserThemeDir), $_) } | Where-Object { Test-Path -LiteralPath $_ })
    Write-WHDRisk -Tier 'reversible' -Text ('Sets the look "{0}" for this user ({1}): the desktop pictures as a slide show ({2}; a new one every 30 minutes, shuffled), dark mode for Windows and apps, accent colour sky blue - also on Start, the taskbar and title bars. WHD writes {3} and has Windows open it; Settings may show the theme list and wait for your click on "{0}". Mouse pointers, desktop icons and the sounds stay as they are. Theme in use now: {4}.{5} Theme menu > 6 puts back Windows'' own dark theme.' -f $script:WHDLookName, $env:USERNAME, $st.PicText, $themeFile, $st.ThemeName, $(if ($old.Count) { (' WHD Next 2.0''s theme(s) {0} are removed from the list (D71).' -f (($old | ForEach-Object { '"' + [System.IO.Path]::GetFileNameWithoutExtension($_) + '"' }) -join ', ')) } else { '' }))
    if (-not (Confirm-WHDProceed -What ('use the look "{0}"' -f $script:WHDLookName))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    if ((Test-WHDRealChange) -and -not $NoOwnAsk) { Invoke-WHDLookOwnPicture -Ask $ask }
    Invoke-WHDChange -Description ('theme: look "{0}" (slide show, dark mode, sky blue; before: {1})' -f $script:WHDLookName, $st.ThemeName) -Journal @{ Kind = 'action'; Hint = 'Theme menu > 6 puts back Windows'' own dark theme (or pick a theme in Settings > Personalization > Themes)' } -Action {
        $snd = Get-WHDLookSoundSnapshot
        $pics = Sync-WHDLookPicture
        if (-not $pics.List.Count) { throw 'no pictures for the slide show' }
        foreach ($n in $pics.Skipped) { Write-WHDLog -Message ('Own picture left out (a letter or sign a theme file cannot hold - rename it): {0}' -f $n) -Level 'WARN' }
        if ($pics.Same) { Write-WHDLog -Message ('{0} own picture(s) left out: the slide show already has the same picture.' -f $pics.Same) }
        # the base: the theme in use now - never our own file, never 2.0's (a copy the user saved under a new name is
        # used: it keeps their own changes, D77)
        $base = ''
        $cur = $st.ThemePath
        $curName = if ($cur) { [System.IO.Path]::GetFileName($cur) } else { '' }
        if ($cur -and (Test-Path -LiteralPath $cur) -and $curName -ne $script:WHDLookFile -and ($script:WHDLookOld -notcontains $curName)) { try { $base = Read-WHDIniText -Path $cur } catch { $base = '' } }
        $scheme = if ((Get-WHDThemeSchemeState).InUse) { $script:WHDThemeSchemeName } else { '' }
        $dir = Split-Path -Parent $themeFile
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop) }
        [System.IO.File]::WriteAllBytes($themeFile, [System.Text.Encoding]::Latin1.GetBytes((Get-WHDLookText -BaseText $base -Pictures $pics.List -PictureDir $pics.Dir -SoundScheme $scheme)))
        Set-WHDLookColorUse -Value 1 -Confirm:$false
        $ok = $false
        try { Open-WHDLookFile -Path $themeFile; $ok = Wait-WHDLookSwitch -Ours -Tries 12 }      # a look already ours by content counts (D77)
        catch { Write-WHDLog -Message ('Opening the theme file failed: {0}' -f $_.Exception.Message) -Level 'WARN' }
        if (-not $ok) { $ok = Invoke-WHDLookByHand -Name $script:WHDLookName -Ours -Ask $ask }
        if (-not $ok) { throw ('read-back: Windows did not switch to the theme "{0}" (theme in use: {1})' -f $script:WHDLookName, (Get-WHDLookState).ThemeName) }
        foreach ($f in $old) { Remove-Item -LiteralPath $f -Force -ErrorAction Stop; Write-WHDLog -Message ('WHD Next 2.0''s theme removed from the list: {0}' -f [System.IO.Path]::GetFileNameWithoutExtension($f)) }
        Wait-WHDLook -Ms 3000                                    # let Windows finish applying before checking what it did
        $p1 = Get-WHDLookRegValue -SubKey $script:WHDKeyPers -Name 'ColorPrevalence'; $p2 = Get-WHDLookRegValue -SubKey $script:WHDKeyDwm -Name 'ColorPrevalence'
        if (-not ($p1.Exists -and [int]$p1.Value -eq 1 -and $p2.Exists -and [int]$p2.Value -eq 1)) {
            Set-WHDLookColorUse -Value 1 -Confirm:$false
            Write-WHDLog -Message 'Windows switched "accent colour on Start, taskbar and title bars" off while applying - set again (may show after signing out and in).' -Level 'WARN'
        }
        $fixed = Restore-WHDLookSoundSnapshot -Snap $snd -Confirm:$false
        $fixed += Wait-WHDLookSoundSettle -Snap $snd
        if ($fixed) { Write-WHDLog -Message ('Windows changed {0} sound setting(s) with the theme - put back.' -f $fixed) }
        if (-not (Get-WHDLookState).Dark) { Write-WHDLog -Message 'Dark mode did not come on from the theme file - Settings > Personalization > Colors > "Choose your mode" sets it.' -Level 'WARN' }
        Write-WHDLog -Message ('Slide show: {0} WHD pictures + {1} of your own, from {2}.' -f $pics.Whd, $pics.Own, $pics.Dir)
    } | Out-Null
}

# ---- 6. put back: always Windows' own dark theme (D71) -------------------------------------------------------
function Invoke-WHDLookRemove {
    [CmdletBinding()]
    param([string[]]$Answer)
    $ask = Get-WHDAnswerReader -Answer $Answer
    Write-WHDLog -Message 'THEME 6: put back Windows'' own dark theme' -Level 'ACT'
    $st = Get-WHDLookState
    if (-not $st.Readable) { Write-WHDLog -Message ('The theme of this user could not be read: {0}' -f $st.Text) -Level 'ERR'; return }
    $isOld = $script:WHDLookOld -contains [System.IO.Path]::GetFileName($st.ThemePath)
    if (-not $st.InUse -and -not $isOld) { Write-WHDLog -Message ('Neither "{0}" nor WHD Next 2.0''s look is in use - nothing to put back. Theme in use: {1}.' -f $script:WHDLookName, $st.ThemeName) -Level 'OK'; return }
    $dark = Get-WHDLookWindowsDark
    if (-not $dark -or -not (Test-Path -LiteralPath $dark)) { Write-WHDLog -Message 'Windows'' own dark theme file was not found - pick a theme in Settings > Personalization > Themes.' -Level 'ERR'; return }
    Write-WHDRisk -Tier 'reversible' -Text ('Puts the look of this user ({0}) back to Windows'' own dark theme (D71): WHD has Windows open {1} (Settings may wait for your click on "Windows (dark)"), and "accent colour on Start, taskbar and title bars" goes back off (Windows'' default). The sounds stay as they are. The pictures and the WHD theme file stay; choose 5 to use them again.' -f $env:USERNAME, $dark)
    if (-not (Confirm-WHDProceed -What 'put back Windows'' own dark theme')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    Invoke-WHDChange -Description ('theme: look back to Windows (dark) (before: {0})' -f $st.ThemeName) -Journal @{ Kind = 'action'; Hint = 'Theme menu > 5 uses the WHD look again' } -Action {
        $snd = Get-WHDLookSoundSnapshot
        Set-WHDLookColorUse -Value 0 -Confirm:$false
        $ok = $false
        try { Open-WHDLookFile -Path $dark; $ok = Wait-WHDLookSwitch -Tries 12 } catch { Write-WHDLog -Message ('Opening the theme file failed: {0}' -f $_.Exception.Message) -Level 'WARN' }
        if (-not $ok) { $ok = Invoke-WHDLookByHand -Name 'Windows (dark)' -Ask $ask }
        if (-not $ok) { throw ('read-back: Windows did not leave the theme "{0}"' -f $st.ThemeName) }
        Wait-WHDLook -Ms 3000
        Set-WHDLookColorUse -Value 0 -Confirm:$false
        $fixed = Restore-WHDLookSoundSnapshot -Snap $snd -Confirm:$false
        $fixed += Wait-WHDLookSoundSettle -Snap $snd
        if ($fixed) { Write-WHDLog -Message ('Windows changed {0} sound setting(s) with the theme - put back.' -f $fixed) }
    } | Out-Null
}
