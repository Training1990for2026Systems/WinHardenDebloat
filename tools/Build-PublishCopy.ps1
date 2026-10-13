#requires -Version 5.1
<#
  Build-PublishCopy.ps1   (WHD Imaging Helper 1.5 preview 1 - tools)

  Makes a clean, checked copy of the helper's main folder (the folder above tools\): the files that are meant to be
  published, nothing else. The copy goes into a new folder next to the build folders:

      ..\publish\<folder name>_<date>_<time>

  What it does, in this order:
    1. Makes the list of files to copy. It leaves out what the folder's .gitignore names (Windows
       image files, logs, test results, work folders), SHA256SUMS.txt (made again in step 5) and
       private-words.txt. In a private folder (one that holds PRIVATE-NOT-FOR-GITHUB.txt) it uses
       its own list instead, because there the .gitignore keeps out every file: see $privateLeaveOut.
       Links to other folders are named and not followed.
    2. Private words: reads private-words.txt (one word or text per line) and adds the Windows user
       name and the computer name this script runs under. Every file on the list is searched for
       them (upper and lower case alike). One hit stops the run, with file, line and word named.
    3. Checks every .ps1 file on the list: Windows PowerShell 5.1 must read it without a parser
       error (this also catches syntax that only PowerShell 7 knows), and it must hold ASCII only.
       One problem stops the run.
    4. Only when steps 2 and 3 found nothing: makes the new folder and copies the files, then reads
       every copy back and compares it with its source by SHA-256.
    5. Writes SHA256SUMS.txt in the copy: one line per file, "<sha-256>  <path>", sorted.

  Rules it keeps:
    - Uses only Windows PowerShell 5.1. No downloads, no web calls.
    - The build folder is only read; the one file written there is the log.
    - Nothing is deleted or overwritten: a publish folder of the same name stops the run.
    - Nothing is written outside the new publish folder and the log.
    - Everything is written to Build-PublishCopy.log in the helper's main folder.

  Run from a Windows PowerShell window (no administrator needed), in the helper's main folder:
    powershell -ExecutionPolicy Bypass -File .\tools\Build-PublishCopy.ps1

  Show the list and run the checks only, copy nothing:
    powershell -ExecutionPolicy Bypass -File .\tools\Build-PublishCopy.ps1 -ListOnly

  Switches:
    -ListOnly            show what would be copied and left out, run the checks, write no copy
    -OutRoot <folder>    where the publish folders go (default: the folder "publish" next to this
                         build folder)
#>
param(
    [string]$OutRoot = '',
    [switch]$ListOnly
)

$ErrorActionPreference = 'Stop'

# This script lies in tools\ ; lists, logs and work files are in the helper's main folder above it.
$root      = Split-Path -Parent $PSScriptRoot
$log       = Join-Path $root 'Build-PublishCopy.log'
$wordsFile = Join-Path $root 'private-words.txt'
$sumsName  = 'SHA256SUMS.txt'
$stamp     = Get-Date -Format 'yyyy-MM-dd_HHmm'
$isPrivate = Test-Path -LiteralPath (Join-Path $root 'PRIVATE-NOT-FOR-GITHUB.txt')

# Always left out, in every folder: the private words themselves and the old checksum list.
$alwaysLeaveOut = @('private-words.txt', $sumsName)

# What a private folder leaves out (its .gitignore keeps out every file, so it cannot be used).
# A name ending in / is a folder name, anything else a file name; * stands for any text.
$privateLeaveOut = @(
    '*.iso', '*.wim', '*.swm', '*.esd',
    '*.log',
    'install-source.txt', 'image-contents.txt',
    'drivers/', 'drivers_old_*/',
    'drivers-list.txt', 'drivers-list_old_*.txt',
    'usb-custom/', 'usb-custom_old_*/',
    'mount/', 'mount_*/',
    'test-results/',
    'from-usb_*/'
)

# Writes a line to the screen and to the log. It never stops the run: when the log cannot be written
# (a moment's lock on the file), it tries twice more and then goes on with the screen only.
function Say([string]$Text) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
    Write-Host $line
    for ($i = 0; $i -lt 3; $i++) {
        try { Add-Content -LiteralPath $log -Value $line -Encoding Ascii -ErrorAction Stop; return }
        catch { Start-Sleep -Milliseconds 300 }
    }
    Write-Host '    (that line could not be written to the log file)'
}

function Stop-Run([string]$Why) {
    throw "STOPPED - $Why"
}

# The path of a file below the build folder, with / between the parts (as in SHA256SUMS.txt).
function Get-RelPath([string]$Full) {
    $r = $Full.Substring($root.Length).TrimStart('\', '/')
    return ($r -replace '\\', '/')
}

# Reads the leave-out rules: from .gitignore in a public folder, from $privateLeaveOut in a private one.
function Get-LeaveOutRules {
    if ($isPrivate) { return $privateLeaveOut }
    $gi = Join-Path $root '.gitignore'
    if (-not (Test-Path -LiteralPath $gi)) { Stop-Run 'this folder has no .gitignore, so it is not known what stays out' }
    $rules = @()
    foreach ($l in (Get-Content -LiteralPath $gi)) {
        $t = ([string]$l).Trim()
        if ((-not $t) -or $t.StartsWith('#')) { continue }
        if ($t.StartsWith('!')) { Stop-Run ".gitignore has a line that starts with ! ($t). This script does not read such lines; take it out or copy by hand" }
        $rules += $t.TrimStart('/')
    }
    return $rules
}

function Test-FolderLeftOut([string]$Name, [string[]]$Rules) {
    foreach ($r in $Rules) {
        if ($r.EndsWith('/') -and ($Name -like $r.TrimEnd('/'))) { return $r }
    }
    return ''
}

function Test-FileLeftOut([string]$Name, [string[]]$Rules) {
    foreach ($r in $alwaysLeaveOut) { if ($Name -eq $r) { return $r } }
    foreach ($r in $Rules) {
        if ((-not $r.EndsWith('/')) -and ($Name -like $r)) { return $r }
    }
    return ''
}

# Walks the folder. Fills $script:take (files to copy), $script:skipped (what was left out and why)
# and $script:links (links to other places, not followed).
function Read-Folder([string]$Dir, [string[]]$Rules) {
    foreach ($item in (Get-ChildItem -LiteralPath $Dir -Force | Sort-Object Name)) {
        $rel = Get-RelPath $item.FullName
        $isLink = (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        if ($item.PSIsContainer) {
            if ($item.Name -eq '.git') { $script:skipped += "$rel/  (Git's own folder)"; continue }
            $why = Test-FolderLeftOut $item.Name $Rules
            if ($why) { $script:skipped += "$rel/  (rule $why)"; continue }
            if ($isLink) { $script:links += "$rel/"; continue }
            Read-Folder $item.FullName $Rules
        }
        else {
            $why = Test-FileLeftOut $item.Name $Rules
            if ($why) { $script:skipped += "$rel  (rule $why)"; continue }
            if ($isLink) { $script:links += $rel; continue }
            $script:take += $item
        }
    }
}

function Get-Sha([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# ==================================================================================================
$result = 'NOT DONE'
try {
    Say '=================================================================='
    Say ("Build-PublishCopy.ps1 started. Folder: $root" + $(if ($ListOnly) { '  (-ListOnly: no copy is written)' } else { '' }))

    # Windows PowerShell 5.1 only: its parser is the check that the scripts run there.
    if (($PSVersionTable.PSEdition -ne 'Desktop') -or ($PSVersionTable.PSVersion.Major -ne 5)) {
        Stop-Run ('this script runs in Windows PowerShell 5.1 only (this is PowerShell {0}). Start it with: powershell -ExecutionPolicy Bypass -File .\tools\Build-PublishCopy.ps1' -f $PSVersionTable.PSVersion)
    }

    $name = Split-Path -Leaf $root
    if (-not $OutRoot) { $OutRoot = Join-Path (Split-Path -Parent $root) 'publish' }
    $target = Join-Path $OutRoot ("{0}_{1}" -f $name, $stamp)
    Say ("Kind of folder: " + $(if ($isPrivate) { 'PRIVATE (PRIVATE-NOT-FOR-GITHUB.txt is here) - the copy is for your own use, not for GitHub' } else { 'public - the leave-out rules come from .gitignore' }))

    # The copy must not land inside the folder it copies.
    $fullRoot = [IO.Path]::GetFullPath($root).TrimEnd('\', '/')
    $fullOut  = [IO.Path]::GetFullPath($OutRoot).TrimEnd('\', '/')
    if (($fullOut -eq $fullRoot) -or $fullOut.StartsWith($fullRoot + '\') -or $fullOut.StartsWith($fullRoot + '/')) {
        Stop-Run "the publish folder ($OutRoot) lies inside the folder that is copied. Give another -OutRoot"
    }

    # --- 1. the list ----------------------------------------------------------------------------
    $rules = @(Get-LeaveOutRules)
    $script:take = @(); $script:skipped = @(); $script:links = @()
    Read-Folder $root $rules
    if ($script:take.Count -eq 0) { Stop-Run 'there is no file to copy' }
    $bytes = 0; foreach ($f in $script:take) { $bytes += $f.Length }
    Say ("Files to copy: {0} ({1:N0} bytes)" -f $script:take.Count, $bytes)
    foreach ($f in $script:take) { Say ('    ' + (Get-RelPath $f.FullName)) }
    Say ("Left out: {0}" -f $script:skipped.Count)
    foreach ($s in $script:skipped) { Say ('    ' + $s) }
    foreach ($l in $script:links) { Say ("    $l  (a link to another place - not followed, not copied)") }

    $problems = @()

    # --- 2. private words -----------------------------------------------------------------------
    if (-not (Test-Path -LiteralPath $wordsFile)) {
        Stop-Run "private-words.txt is missing in this folder. Make it (one word per line; lines that start with # are comments) - without it nothing can be checked"
    }
    # Each word keeps where it came from (its line in private-words.txt, or this PC), so a hit can
    # be named without writing the word itself into the log.
    $words = @(); $wordFrom = @(); $n = 0
    foreach ($l in (Get-Content -LiteralPath $wordsFile)) {
        $n++
        $t = ([string]$l).Trim()
        if ($t -and (-not $t.StartsWith('#'))) { $words += $t; $wordFrom += "line $n of private-words.txt" }
    }
    $fromFile = $words.Count
    # A generic account name (for example "user" or "admin") is an ordinary word in every text here and says
    # nothing about this PC: it is not searched for. Put it in private-words.txt if you want it searched.
    $genericNames = @('user', 'users', 'admin', 'administrator', 'owner', 'guest', 'defaultuser0', 'default', 'public')
    if ($env:USERNAME -and ($genericNames -contains $env:USERNAME.ToLowerInvariant())) {
        Say ("NOTE: the Windows user name is a generic account name; it is not searched for (add it to private-words.txt to search for it).")
    }
    elseif ($env:USERNAME -and ($env:USERNAME.Length -ge 3) -and ($words -notcontains $env:USERNAME)) { $words += $env:USERNAME; $wordFrom += 'the Windows user name' }
    if ($env:COMPUTERNAME -and ($env:COMPUTERNAME.Length -ge 3) -and ($words -notcontains $env:COMPUTERNAME)) { $words += $env:COMPUTERNAME; $wordFrom += 'the computer name' }
    if ($words.Count -eq 0) { Stop-Run 'private-words.txt has no word in it and the user and computer name are not known. Nothing could be checked' }
    Say ("Private words: {0} from private-words.txt, {1} from this PC (user name, computer name). The words are not written to this log." -f $fromFile, ($words.Count - $fromFile))
    foreach ($f in $script:take) {
        $rel = Get-RelPath $f.FullName
        for ($k = 0; $k -lt $words.Count; $k++) {
            $hits = @(Select-String -LiteralPath $f.FullName -Pattern $words[$k] -SimpleMatch -ErrorAction SilentlyContinue)
            foreach ($h in $hits) {
                $problems += ("private word in {0}, line {1} (word from {2})" -f $rel, $h.LineNumber, $wordFrom[$k])
            }
        }
    }

    # --- 3. the .ps1 files ----------------------------------------------------------------------
    $ps1 = @($script:take | Where-Object { $_.Extension -eq '.ps1' })
    foreach ($f in $ps1) {
        $rel = Get-RelPath $f.FullName
        $tokens = $null; $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
        foreach ($e in $errs) {
            $problems += ("{0}, line {1}: Windows PowerShell 5.1 cannot read it - {2}" -f $rel, $e.Extent.StartLineNumber, $e.Message)
        }
        $b = [IO.File]::ReadAllBytes($f.FullName)
        $line = 1; $bad = 0
        for ($i = 0; $i -lt $b.Length; $i++) {
            if ($b[$i] -eq 10) { $line++; continue }
            if ($b[$i] -gt 127) {
                if ($bad -lt 5) { $problems += ("{0}, line {1}: a character that is not ASCII (byte {2})" -f $rel, $line, $b[$i]) }
                $bad++
            }
        }
        if ($bad -gt 5) { $problems += ("{0}: {1} more characters that are not ASCII" -f $rel, ($bad - 5)) }
    }
    Say ("Checked {0} .ps1 file(s): parser of Windows PowerShell 5.1, ASCII only." -f $ps1.Count)

    if ($problems.Count -gt 0) {
        Say ("Problems found: {0}" -f $problems.Count)
        foreach ($p in $problems) { Say ('    ' + $p) }
        Stop-Run 'the checks found the problems above. Nothing was copied. Fix them in this folder and run again'
    }
    Say 'Checks: no private word, every .ps1 file reads in Windows PowerShell 5.1 and is ASCII.'

    if ($ListOnly) {
        $result = 'DONE - list and checks only, no copy written'
    }
    else {
        # --- 4. the copy ------------------------------------------------------------------------
        if (Test-Path -LiteralPath $target) { Stop-Run "$target is there already. Nothing was changed; wait a minute and run again" }
        if (-not (Test-Path -LiteralPath $OutRoot)) {
            New-Item -ItemType Directory -Path $OutRoot | Out-Null
            Say "Made the folder $OutRoot"
        }
        New-Item -ItemType Directory -Path $target | Out-Null
        Say "Copying into $target"
        $sums = @()
        foreach ($f in $script:take) {
            $rel = Get-RelPath $f.FullName
            $dest = Join-Path $target ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
            $destDir = Split-Path -Parent $dest
            if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir | Out-Null }
            Copy-Item -LiteralPath $f.FullName -Destination $dest
            $a = Get-Sha $f.FullName
            $c = Get-Sha $dest
            if ($a -ne $c) {
                Say "    copy of $rel differs from its source - copying once more"
                Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
                $c = Get-Sha $dest
                if ($a -ne $c) { Stop-Run "the copy of $rel differs from its source twice. The publish folder is NOT complete: $target" }
            }
            $sums += [pscustomobject]@{ Path = $rel; Sha = $a }
        }
        Say ("Copied {0} file(s); every copy matches its source by SHA-256." -f $sums.Count)

        # --- 5. SHA256SUMS.txt (sorted by path, byte order; Unix line ends, as in the published builds)
        $sorted = [string[]]@($sums | ForEach-Object { $_.Path })
        [Array]::Sort($sorted, [StringComparer]::Ordinal)
        $text = ''
        foreach ($p in $sorted) {
            $s = ($sums | Where-Object { $_.Path -eq $p } | Select-Object -First 1).Sha
            $text += ("{0}  {1}`n" -f $s, $p)
        }
        $sumFile = Join-Path $target $sumsName
        [IO.File]::WriteAllBytes($sumFile, [Text.Encoding]::ASCII.GetBytes($text))
        Say ("Wrote $sumsName with {0} line(s)." -f $sorted.Count)
        if ($isPrivate) { Say 'This copy is PRIVATE: it holds PRIVATE-NOT-FOR-GITHUB.txt. Do not upload it.' }
        $result = "DONE - publish copy in $target"
    }
}
catch {
    Say ([string]$_.Exception.Message)
    $result = 'NOT DONE - see the lines above'
}
Say "RESULT: $result"
if ($result -notlike 'DONE*') { exit 1 }
