<#
================================================================================
 WHD Next  -  tools\Build-PublishCopy.ps1   (from Classic 1.4; brought in line with Classic 1.4.2 on 2026-10-05)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Builds a CLEAN copy of WHD Next for publishing, with this PC's personal details removed.
 The working project folder is only READ - nothing in it is changed.

 User decisions 2026-09-30:
   - a separate publish copy (the working folder stays untouched)
   - contents: code + profiles, the theme pictures, README + general guides, the test write-ups.
     NOT included: logs, inventory scans, restore journals/backups, archive, planning docs
     (roadmap, release plan, NTS plan, architecture notes), private working notes,
     block lists (other people's data), PowerShell installer files in installers\.

 What is removed / replaced (found live on THIS PC, so it works on any PC):
   computer name            -> <PC-NAME>
   C:\Users\<you>           -> C:\Users\<USER>
   Windows MachineGuid      -> <MACHINE-ID>
   network adapter GUIDs    -> {ADAPTER-GUID}
   network adapter MACs     -> <MAC>
   PC serial number / UUID  -> <SERIAL> / <PC-UUID>
   -ExtraTerms you pass     -> <REDACTED>
   in .md/.txt only: e-mail addresses -> <EMAIL>, private IPv4 (10.x, 172.16-31.x, 192.168.x) -> <LAN-IP>,
   and the hardware rules in tools\publish-generalize.txt (maker, model, driver IDs -> generic words)
 Then a leak scan re-checks every output file and SHA256SUMS.txt is written.

 Run (no admin needed) in the project folder:
   powershell -ExecutionPolicy Bypass -File .\tools\Build-PublishCopy.ps1
   optional: -ExtraTerms 'word1','word2'    -Dest <folder>
 Output: <project>\publish\WHD-Next_<date_time>\ + PUBLISH-REPORT_<date_time>.txt
 The theme pictures are copied byte for byte (they are not text); everything else is read as text.
================================================================================
#>
[CmdletBinding()]
param(
    [string[]]$ExtraTerms = @(),
    [string]$Dest,
    # Public contact addresses that must stay in the published files (user decision 2026-09-30)
    [string[]]$AllowEmail = @('t90018273@gmail.com', '327739407+Training1990for2026Systems@users.noreply.github.com')
)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
if (-not $Dest) { $Dest = Join-Path $root ("publish\WHD-Next_{0}" -f $stamp) }
if (Test-Path -LiteralPath $Dest) { throw ("Destination already exists: {0} - pick another -Dest" -f $Dest) }

# ---- 1. what goes in (paths relative to the project folder) -----------------
$include = New-Object System.Collections.Generic.List[string]
foreach ($f in @('Start-WHD.cmd', 'Start-WHD.ps1', 'WHD.ps1', 'WHD-GUI.ps1', 'WHD-Placeholder.ps1', 'Inventory.ps1', 'README.md', 'Run.txt', 'LICENSE', 'SECURITY.md', '.gitignore', '.gitattributes')) { $include.Add($f) }
foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $root 'modules') -Filter *.ps1 -File)) { $include.Add("modules\$($f.Name)") }
foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $root 'tools') -Filter *.ps1 -File)) { $include.Add("tools\$($f.Name)") }
# profiles: WHD's own JSON profiles only (not the downloaded block lists - other people's data, check their licenses first)
foreach ($f in @('standard.json', 'validated.json', 'lean.json', 'firewall-baseline.json')) { $include.Add("profiles\$f") }
# docs: general guides + test write-ups
foreach ($f in @('firewall-module.md', 'standard-reimage.md', 'radio-group-test.md', 'update-review-2026-09-29.md', 'theme.md')) { $include.Add("docs\$f") }
# installers: only the note that explains the folder (never an installer file)
$include.Add('installers\README.txt')
# theme pictures (WHD Next's own, made by the project): copied byte for byte, never read as text
$binary = New-Object System.Collections.Generic.List[string]
$picDir = Join-Path $root 'theme\pictures'
if (Test-Path -LiteralPath $picDir) { foreach ($f in @(Get-ChildItem -LiteralPath $picDir -Filter *.jpg -File | Sort-Object Name)) { $binary.Add("theme\pictures\$($f.Name)") } }

# ---- 2. this PC's identifiers (read live) ----------------------------------
$terms = New-Object System.Collections.Generic.List[object]   # @{ Find; Repl; Label }
function Add-Term { param([string]$Find, [string]$Repl, [string]$Label) if ($Find -and $Find.Length -ge 3) { $terms.Add([pscustomobject]@{ Find = $Find; Repl = $Repl; Label = $Label }) } }
# A short or placeholder computer name / serial would be replaced as a plain piece of text in every file
# (code included) - those are skipped and listed in the report instead.
$tooGeneric = New-Object System.Collections.Generic.List[string]
function Add-IdTerm {
    param([string]$Find, [string]$Repl, [string]$Label)
    $v = "$Find".Trim()
    if (-not $v) { return }
    if ($v.Length -lt 5 -or $v -match '^(none|n/?a|default|unknown|system|to be filled.*|0+)$') { $tooGeneric.Add($Label); return }
    Add-Term $v $Repl $Label
}
Add-IdTerm $env:COMPUTERNAME '<PC-NAME>' 'computer name'
$prof = $env:USERPROFILE
if ($prof) {
    Add-Term $prof 'C:\Users\<USER>' 'user folder'
    Add-Term ($prof -replace '\\', '\\') 'C:\\Users\\<USER>' 'user folder (JSON)'
    Add-Term ($prof -replace '\\', '/') 'C:/Users/<USER>' 'user folder (/)'
}
try { Add-Term "$((Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -EA Stop).MachineGuid)" '<MACHINE-ID>' 'MachineGuid' } catch {}
try {
    foreach ($a in @(Get-NetAdapter -IncludeHidden -EA Stop)) {
        $g = "$($a.InterfaceGuid)".Trim('{}')
        Add-Term $g 'ADAPTER-GUID' ("adapter GUID ({0})" -f $a.Name)
        if ("$($a.MacAddress)" -match '^([0-9A-Fa-f]{2}[-:]){5}[0-9A-Fa-f]{2}$') {
            Add-Term "$($a.MacAddress)" '<MAC>' ("adapter MAC ({0})" -f $a.Name)
            Add-Term ("$($a.MacAddress)" -replace '-', ':') '<MAC>' ("adapter MAC ({0})" -f $a.Name)
        }
    }
} catch {}
# Every network interface Windows has a record of - including disabled / not-present adapters that
# Get-NetAdapter does not return (seen 2026-09-30: the disabled Bluetooth PAN adapter's GUID was missed).
foreach ($k in @(Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -EA SilentlyContinue)) {
    Add-Term ($k.PSChildName.Trim('{}')) 'ADAPTER-GUID' 'interface GUID (registry)'
}
# Shortened forms used in notes (e.g. "1A2B3C4D-..."): the first 8 characters of each adapter GUID.
foreach ($g in @($terms | Where-Object { $_.Repl -eq 'ADAPTER-GUID' } | ForEach-Object { $_.Find.Substring(0, 8) } | Select-Object -Unique)) {
    Add-Term ($g + '-') 'ADAPTER-GUID-' 'interface GUID (short form)'
}
try {
    $csp = Get-CimInstance Win32_ComputerSystemProduct -EA Stop
    if ("$($csp.IdentifyingNumber)" -notmatch '^(To be filled|Default|System Serial|0+$)') { Add-IdTerm "$($csp.IdentifyingNumber)" '<SERIAL>' 'serial number' }
    if ("$($csp.UUID)" -notmatch '^[0F-]+$') { Add-Term "$($csp.UUID)" '<PC-UUID>' 'PC UUID' }
} catch {}
foreach ($t in $ExtraTerms) { Add-Term $t '<REDACTED>' 'extra term' }
# longest first, so a path is replaced before a shorter term inside it
$terms = @($terms | Sort-Object { $_.Find.Length } -Descending)

# Hardware generalization rules for documents (user decision 2026-09-30): tools\publish-generalize.txt
$genRules = @()
$genFile = Join-Path $PSScriptRoot 'publish-generalize.txt'
$genFound = Test-Path -LiteralPath $genFile
$genMissingNote = 'No tools\publish-generalize.txt - hardware names in the documents are NOT generalized (that file is private to each PC and is not part of the published copy).'
if ($genFound) {
    foreach ($line in @(Get-Content -LiteralPath $genFile)) {
        if ($line -match '^\s*#' -or $line -notmatch ' => ') { continue }
        $parts = $line -split ' => ', 2
        $genRules += [pscustomobject]@{ Rx = $parts[0]; Repl = $parts[1] }
    }
}

$rxEmail = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
$rxLanIp = '\b(10\.\d{1,3}\.\d{1,3}\.\d{1,3}|172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3})\b'

function Read-TextKeepEncoding {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [Text.Encoding]::UTF8.GetString($bytes, $(if ($bom) { 3 } else { 0 }), $bytes.Length - $(if ($bom) { 3 } else { 0 }))
    [pscustomobject]@{ Text = $text; Bom = $bom }
}

# ---- 3. copy + scrub --------------------------------------------------------
$report = New-Object System.Collections.Generic.List[string]
$report.Add(("WHD Next - PUBLISH COPY   {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm')))
$report.Add(("Source (read only): <project folder>    Output: {0}" -f (Split-Path $Dest -Leaf)))
$report.Add(("Hardware generalization rules (docs): {0} from tools\publish-generalize.txt" -f $genRules.Count))
if (-not $genFound) { $report.Add('NOTE: ' + $genMissingNote) }
$report.Add(("Identifiers found on this PC: {0} ({1})" -f $terms.Count, ((@($terms | ForEach-Object { $_.Label } | Select-Object -Unique)) -join ', ')))
foreach ($tg in $tooGeneric) { $report.Add(("  {0}: skipped - too generic (NOT replaced - check the output for it by hand)" -f $tg)) }
$report.Add('')
$copied = 0; $missing = @()
foreach ($rel in $include) {
    $src = Join-Path $root $rel
    if (-not (Test-Path -LiteralPath $src)) { $missing += $rel; continue }
    $dst = Join-Path $Dest $rel
    $dd = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
    $r = Read-TextKeepEncoding -Path $src
    $t = $r.Text; $hits = 0
    foreach ($term in $terms) {
        $rx = [regex]::Escape($term.Find)
        $n = ([regex]::Matches($t, $rx, 'IgnoreCase')).Count
        if ($n) { $t = [regex]::Replace($t, $rx, $term.Repl.Replace('$', '$$'), 'IgnoreCase'); $hits += $n }
    }
    if ($rel -match '\.(md|txt)$') {
        $n = @([regex]::Matches($t, $rxEmail) | Where-Object { $AllowEmail -notcontains $_.Value }).Count
        if ($n) { $t = [regex]::Replace($t, $rxEmail, [Text.RegularExpressions.MatchEvaluator]{ param($m) if ($AllowEmail -contains $m.Value) { $m.Value } else { '<EMAIL>' } }); $hits += $n }
        $n = ([regex]::Matches($t, $rxLanIp)).Count; if ($n) { $t = [regex]::Replace($t, $rxLanIp, '<LAN-IP>'); $hits += $n }
        foreach ($g in $genRules) {
            $n = ([regex]::Matches($t, $g.Rx, 'IgnoreCase')).Count
            if ($n) { $t = [regex]::Replace($t, $g.Rx, $g.Repl.Replace('$', '$$'), 'IgnoreCase'); $hits += $n }
        }
    }
    $enc = New-Object System.Text.UTF8Encoding($r.Bom)
    [IO.File]::WriteAllText($dst, $t, $enc)
    $copied++
    $report.Add(("  {0,-48} {1}" -f $rel, $(if ($hits) { "$hits replacement(s)" } else { 'clean' })))
}
# pictures: byte-for-byte copy (reading a picture as text would damage it)
foreach ($rel in $binary) {
    $src = Join-Path $root $rel
    $dst = Join-Path $Dest $rel
    $dd = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
    Copy-Item -LiteralPath $src -Destination $dst
    $copied++
}
if ($binary.Count) { $report.Add(("  {0,-48} {1} picture(s) copied byte for byte" -f 'theme\pictures\*.jpg', $binary.Count)) }
foreach ($m in $missing) { $report.Add(("  {0,-48} NOT FOUND - skipped" -f $m)) }

# ---- 4. leak scan of the output ---------------------------------------------
$report.Add('')
$report.Add('LEAK SCAN (output folder):')
$leaks = 0
foreach ($f in @(Get-ChildItem -LiteralPath $Dest -Recurse -File)) {
    if ($f.Extension -eq '.jpg') { continue }   # pictures are not text; nothing from this PC is written into them here
    $t = (Read-TextKeepEncoding -Path $f.FullName).Text
    foreach ($term in $terms) { if ($t.IndexOf($term.Find, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $leaks++; $report.Add(("  LEAK {0}: {1}" -f $f.Name, $term.Label)) } }
    if ($f.Extension -in '.md', '.txt') {
        foreach ($m in [regex]::Matches($t, $rxEmail)) { if ($AllowEmail -notcontains $m.Value) { $leaks++; $report.Add(("  LEAK {0}: e-mail" -f $f.Name)) } }
        # Not counted as a leak, but listed for a human check: any other GUID left in a document.
        foreach ($m in [regex]::Matches($t, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}')) { $report.Add(("  CHECK {0}: GUID {1} (not this PC's adapter/machine ID - make sure it is not personal)" -f $f.Name, $m.Value)) }
    }
}
if (-not $leaks) { $report.Add('  none - no identifier of this PC was found in the output') }

# ---- 5. checksums -----------------------------------------------------------
$sums = @(foreach ($f in @(Get-ChildItem -LiteralPath $Dest -Recurse -File | Sort-Object FullName)) {
    $relOut = $f.FullName.Substring($Dest.Length).TrimStart('\')
    "{0}  {1}" -f (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower(), ($relOut -replace '\\', '/')
})
[IO.File]::WriteAllLines((Join-Path $Dest 'SHA256SUMS.txt'), [string[]]$sums, (New-Object System.Text.UTF8Encoding($false)))

$report.Add('')
$report.Add(("Files copied: {0}   missing: {1}   leaks: {2}   SHA256SUMS.txt written" -f $copied, $missing.Count, $leaks))
$report.Add('Not included on purpose: logs, inventory, restore, archive, publish, profiles\incoming, block lists, planning docs, private notes, installer files.')
$repPath = Join-Path (Split-Path -Parent $Dest) ("PUBLISH-REPORT_{0}.txt" -f $stamp)
[IO.File]::WriteAllLines($repPath, [string[]]$report, (New-Object System.Text.UTF8Encoding($false)))
$report | ForEach-Object { Write-Host $_ }
Write-Host ''
Write-Host (" Publish copy: {0}" -f $Dest) -ForegroundColor Green
Write-Host (" Report      : {0}" -f $repPath) -ForegroundColor Green
if ($leaks) { Write-Host ' LEAKS FOUND - check the report before publishing.' -ForegroundColor Red }
if (-not $genFound) { Write-Host (' ' + $genMissingNote) -ForegroundColor Yellow }
