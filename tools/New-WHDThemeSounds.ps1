<#
================================================================================
 WHD Next  -  tools\New-WHDThemeSounds.ps1   (theme: sound generator)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Build step 12b (theme, part 1, third version). Makes the WHD Next theme
 sounds. The character asked for (2026-10-03): "an older space ship, held
 together by the crew and its AI" - so: low notes, a hollow slightly worn
 tone, a little wobble, relay clunks, a hum under the long ones.
 Third version: the user tried -Pitch by ear and liked 0.5 best, "but the lows
 were too soft on speakers". So the notes now sit at that half pitch, and every
 low note is built mostly from its overtones: a small speaker cannot play a
 130 Hz note, but it can play 260, 390 and 520 Hz - and the ear still hears the
 low note from those. The machinery (hum, clunks, wind-up) keeps its own pitch.
 Every sound is worked out here by plain arithmetic (sine waves, overtones,
 fades, a home-made noise for the clunks) and written as a .wav file. Nothing is
 copied from anywhere, and no sound from a film or series is imitated.

 It only WRITES .wav FILES into its output folder and, when asked, PLAYS them.
 It changes no Windows setting: the sound scheme and the sign-in / lock tasks are
 a later step.

   output folder (default): C:\ProgramData\WinHardenDebloatNext\theme\sounds
                            (needs an administrator window)

   make all sounds, then play them one by one with their names:
     pwsh -ExecutionPolicy Bypass -File "<...>\next\tools\New-WHDThemeSounds.ps1" -Play
   lower or higher, to try by ear:   -Pitch 0.85   (1 = as designed, 0.85 = lower, 1.3 = the "0.65" of the second version)
   list the sounds and what each is for (writes nothing):   -List
   only some:                                              -Only lock,unlock
   play again without making them again:                   -PlayOnly
   another folder:                                         -OutDir <folder>

 Works on Windows PowerShell 5.1 and PowerShell 7. File is ASCII on purpose.
================================================================================
#>
[CmdletBinding()]
param(
    [string]$OutDir,          # where the .wav files go
    [string[]]$Only,          # names of the sounds to make / play (default: all)
    [switch]$Play,            # play each sound after making it
    [switch]$PlayOnly,        # play existing files, make nothing
    [switch]$List,            # print the list, write nothing
    [double]$Pitch = 1.0,     # every note times this (0.5 .. 2): below 1 = lower, above 1 = higher
    [int]$PauseMs = 500       # pause between two sounds when playing
)

$ErrorActionPreference = 'Stop'
$script:WHDSndRate  = 22050      # samples per second, one channel, 16 bit
$script:WHDSndPeak  = 0.80       # used only for a sound with nothing a small speaker can play
$script:WHDSndLoud  = 0.26       # strength of every finished sound as a small speaker plays it
$script:WHDSndTop   = 0.94       # no sample goes above this (1.0 = full scale)
$script:WHDSndBase  = 0.5        # the user's choice by ear, 2026-10-03: half the pitch of the second version
$script:WHDSndPitch = $script:WHDSndBase * $Pitch
$script:WHDSndCarryHz  = 400.0   # below this a small speaker gives little: such parts are turned down ...
$script:WHDSndCarryMin = 0.22    # ... to this share at the lowest, and overtones are added up to ...
$script:WHDSndCarryTop = 1300.0  # ... about here, so a low note is carried by what the speaker can play
if ($Pitch -lt 0.5 -or $Pitch -gt 2.0) { Write-Host ' -Pitch must be between 0.5 and 2.' -ForegroundColor Red; exit 2 }

# ---- notes used below (Hz) ---------------------------------------------------
$G2 = 98.00;  $A2 = 110.00; $D3 = 146.83; $E3 = 164.81; $G3 = 196.00; $A3 = 220.00; $B3 = 246.94
$C4 = 261.63; $D4 = 293.66; $Eb4 = 311.13; $E4 = 329.63; $G4 = 392.00; $A4 = 440.00; $B4 = 493.88
$C5 = 523.25; $D5 = 587.33; $E5 = 659.25

# =============================================================================
#  building blocks - each returns an array of samples (-1 .. 1)
# =============================================================================
function New-WHDSndTone {
    # One tone, or a glide from F1 to F2.
    #   Harm   = strength of the tone itself and its overtones
    #   Detune = a second, slightly off copy (0.004 = 0.4 % higher): the slow beating of worn equipment
    #   Sag    = the note sinks by this share over its length (0.03 = 3 %)
    #   VibHz / VibDepth = wobble
    #   NoPitch = machinery: it does not follow the tune (-Pitch)
    #   NoCarry = leave the tone as given (no added overtones)      MaxHarm = most overtones that may be added
    param([double]$F1, [double]$F2 = 0, [int]$Ms = 200, [double]$Vol = 0.6, [int]$AttackMs = 6, [int]$ReleaseMs = 40,
          [double[]]$Harm = @(1.0), [double]$Curve = 1.0, [double]$VibHz = 0, [double]$VibDepth = 0, [double]$Detune = 0, [double]$Sag = 0,
          [switch]$NoPitch, [switch]$NoCarry, [int]$MaxHarm = 16)
    $rate = $script:WHDSndRate
    $n = [int][Math]::Round($rate * $Ms / 1000.0)
    if ($n -lt 2) { $n = 2 }
    $buf = New-Object double[] $n
    if ($F2 -le 0) { $F2 = $F1 }
    if (-not $NoPitch) { $F1 = $F1 * $script:WHDSndPitch; $F2 = $F2 * $script:WHDSndPitch }
    # Low notes on small speakers: add overtones (each a little weaker than the one before) until they reach
    # the range a small speaker plays, so the ear can still follow the low note.
    $fLow = [Math]::Min($F1, $F2)
    if (-not $NoCarry -and $fLow -gt 0 -and ($Harm.Length * $fLow) -lt $script:WHDSndCarryTop) {
        $need = [Math]::Min($MaxHarm, [int][Math]::Ceiling($script:WHDSndCarryTop / $fLow))
        if ($need -gt $Harm.Length) {
            $last = 0.0; foreach ($hv in $Harm) { if ($hv -ne 0) { $last = [Math]::Abs($hv) } }
            if ($last -le 0) { $last = 0.3 }
            $hollow = ($Harm.Length -ge 2 -and $Harm[1] -eq 0)      # a hollow tone stays hollow: the even overtones stay weak
            $ext = New-Object double[] $need
            [Array]::Copy($Harm, 0, $ext, 0, $Harm.Length)
            for ($k = $Harm.Length; $k -lt $need; $k++) {
                $last = $last * 0.84
                if ($hollow -and (($k + 1) % 2) -eq 0) { $ext[$k] = $last * 0.35 } else { $ext[$k] = $last }
            }
            $Harm = $ext
        }
    }
    $twoPi = 2.0 * [Math]::PI
    $att = [Math]::Max(1, [int]($rate * $AttackMs / 1000.0))
    $rel = [Math]::Max(1, [int]($rate * $ReleaseMs / 1000.0))
    if ($att + $rel -gt $n) { $att = [Math]::Max(1, [int]($n * 0.2)); $rel = [Math]::Max(1, $n - $att - 1) }
    $hn = $Harm.Length
    $hsum = 0.0; foreach ($hv in $Harm) { $hsum += [Math]::Abs($hv) }
    if ($hsum -le 0) { $hsum = 1.0 }
    $nyq = $rate * 0.45
    $phase = 0.0; $phase2 = 0.0
    $glide = ($F2 -ne $F1)
    $two = ($Detune -ne 0)
    $carryHz = $script:WHDSndCarryHz; $carryMin = $script:WHDSndCarryMin
    if ($NoCarry) { $carryHz = 0.0 }
    for ($i = 0; $i -lt $n; $i++) {
        $t = $i / [double]$n
        $f = $F1
        if ($glide) { $f = $F1 + ($F2 - $F1) * [Math]::Pow($t, $Curve) }
        if ($Sag -ne 0) { $f = $f * (1.0 - $Sag * $t) }
        if ($VibHz -gt 0) { $f = $f * (1.0 + $VibDepth * [Math]::Sin($twoPi * $VibHz * $i / $rate)) }
        $phase += $twoPi * $f / $rate
        if ($two) { $phase2 += $twoPi * $f * (1.0 + $Detune) / $rate }
        $s = 0.0
        for ($h = 0; $h -lt $hn; $h++) {
            $fh = $f * ($h + 1)
            if ($Harm[$h] -ne 0 -and $fh -lt $nyq) {
                $w = $Harm[$h]
                if ($fh -lt $carryHz) { $c = $fh / $carryHz; $c = $c * $c; if ($c -lt $carryMin) { $c = $carryMin }; $w = $w * $c }
                $s += $w * [Math]::Sin($phase * ($h + 1))
                if ($two) { $s += $w * [Math]::Sin($phase2 * ($h + 1)) }
            }
        }
        if ($two) { $s = $s * 0.5 }
        $e = 1.0
        if ($i -lt $att) { $e = $i / [double]$att }
        elseif ($i -ge ($n - $rel)) { $e = ($n - 1 - $i) / [double]$rel }
        $buf[$i] = $Vol * $e * $s / $hsum
    }
    return , $buf
}
function New-WHDSndNoise {
    # A short burst of dull noise that dies away - worked out with a small number sequence of our own,
    # always the same for the same Seed (so the files come out identical every time).
    param([int]$Ms = 30, [double]$Vol = 0.5, [double]$Smooth = 0.12, [int]$Seed = 1)
    $n = [int][Math]::Round($script:WHDSndRate * $Ms / 1000.0)
    if ($n -lt 2) { $n = 2 }
    $buf = New-Object double[] $n
    [long]$x = 12345 + 7919 * $Seed
    $y = 0.0; $y2 = 0.0
    $gain = 1.0 / [Math]::Sqrt($Smooth)      # smoothing makes the noise quieter; bring it back up
    for ($i = 0; $i -lt $n; $i++) {
        $x = ($x * 1103515245 + 12345) % 2147483648
        $r = ($x / 1073741824.0) - 1.0
        $y  += $Smooth * ($r - $y)            # smoothed twice: dull, like a latch behind a panel
        $y2 += $Smooth * ($y - $y2)
        $d = 1.0 - ($i / [double]$n)
        $buf[$i] = $Vol * $gain * $y2 * $d * $d
    }
    return , $buf
}
function New-WHDSndClunk {
    # A relay or a latch: a dull tick and a short low thump.
    param([double]$Vol = 0.5, [int]$Seed = 1)
    $tick  = New-WHDSndNoise -Ms 34 -Vol $Vol -Smooth 0.12 -Seed $Seed
    $thump = New-WHDSndTone -F1 $script:WHDSndClunkHz -F2 ($script:WHDSndClunkHz * 0.6) -Ms 85 -Vol $Vol -AttackMs 2 -ReleaseMs 65 -Harm @(1.0, 0.3) -NoPitch -NoCarry
    return , (Merge-WHDSnd -Base $thump -Add $tick -AtMs 0)
}
$script:WHDSndClunkHz = 150.0    # the thump does not follow -Pitch (a relay sounds the same whatever the tune)
function New-WHDSndGap {
    param([int]$Ms)
    $n = [int][Math]::Round($script:WHDSndRate * $Ms / 1000.0)
    if ($n -lt 0) { $n = 0 }
    return , (New-Object double[] $n)
}
function Join-WHDSnd {
    # One after the other.
    param([object[]]$Parts)
    $total = 0; foreach ($p in $Parts) { $total += $p.Length }
    $buf = New-Object double[] $total
    $at = 0
    foreach ($p in $Parts) { [Array]::Copy($p, 0, $buf, $at, $p.Length); $at += $p.Length }
    return , $buf
}
function Merge-WHDSnd {
    # $Add is laid over $Base, starting $AtMs after its beginning (the result grows if needed).
    param([double[]]$Base, [double[]]$Add, [int]$AtMs = 0)
    $off = [int][Math]::Round($script:WHDSndRate * $AtMs / 1000.0)
    $len = [Math]::Max($Base.Length, $off + $Add.Length)
    $buf = New-Object double[] $len
    [Array]::Copy($Base, 0, $buf, 0, $Base.Length)
    for ($i = 0; $i -lt $Add.Length; $i++) { $buf[$off + $i] += $Add[$i] }
    return , $buf
}
function Add-WHDSndEcho {
    # A quieter copy a little later - a metal corridor.
    param([double[]]$Snd, [int]$DelayMs = 160, [double]$Gain = 0.25)
    $copy = New-Object double[] $Snd.Length
    for ($i = 0; $i -lt $Snd.Length; $i++) { $copy[$i] = $Snd[$i] * $Gain }
    return , (Merge-WHDSnd -Base $Snd -Add $copy -AtMs $DelayMs)
}
function Set-WHDSndLevel {
    # Every sound equally loud AS A SMALL SPEAKER PLAYS IT, and a short fade at both ends (no click).
    # How: measure the sound with everything below about 300 Hz taken away (that is what a small speaker
    # does), bring that to one fixed strength, and round off any peak that would go over the top instead of
    # cutting it. So a low sound is not quieter than a high one, and nothing is harshly clipped.
    param([double[]]$Snd)
    $n = $Snd.Length
    $peak = 0.0
    for ($i = 0; $i -lt $n; $i++) { $a = [Math]::Abs($Snd[$i]); if ($a -gt $peak) { $peak = $a } }
    if ($peak -le 0) { return , $Snd }
    $rate = $script:WHDSndRate
    $rc = 1.0 / (2.0 * [Math]::PI * 300.0); $dt = 1.0 / $rate; $al = $rc / ($rc + $dt)
    $y1 = 0.0; $y2 = 0.0; $x1 = 0.0; $p1 = 0.0
    $sum = 0.0; $cnt = 0; $gate = 0.02 * $peak
    for ($i = 0; $i -lt $n; $i++) {
        $x = $Snd[$i]
        $y1 = $al * ($y1 + $x - $x1); $x1 = $x          # twice the same simple filter
        $y2 = $al * ($y2 + $y1 - $p1); $p1 = $y1
        if ([Math]::Abs($x) -gt $gate) { $sum += $y2 * $y2; $cnt++ }      # pauses inside a sound do not count
    }
    $heard = 0.0
    if ($cnt -gt 0) { $heard = [Math]::Sqrt($sum / $cnt) }
    $k = $script:WHDSndPeak / $peak
    if ($heard -gt 0) {
        $k = $script:WHDSndLoud / $heard
        if (($peak * $k) -gt 1.8) { $k = 1.8 / $peak }                     # never push a peak more than this far over
    }
    $knee = 0.60; $room = $script:WHDSndTop - $knee
    $fade = [Math]::Min([int]($rate * 0.004), [int]($n / 4))
    for ($i = 0; $i -lt $n; $i++) {
        $v = $Snd[$i] * $k
        $av = [Math]::Abs($v)
        if ($av -gt $knee) {                                                # round off instead of cutting
            $av = $knee + $room * [Math]::Tanh(($av - $knee) / $room)
            if ($v -lt 0) { $v = -$av } else { $v = $av }
        }
        if ($fade -gt 0) {
            if ($i -lt $fade) { $v = $v * ($i / [double]$fade) }
            elseif ($i -ge ($n - $fade)) { $v = $v * (($n - 1 - $i) / [double]$fade) }
        }
        $Snd[$i] = $v
    }
    return , $Snd
}
function Write-WHDSndWav {
    # 16-bit, one channel, uncompressed .wav.
    param([string]$Path, [double[]]$Snd)
    $rate = $script:WHDSndRate
    $n = $Snd.Length
    $dataBytes = $n * 2
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    try {
        $bw = New-Object System.IO.BinaryWriter($fs)
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('RIFF'))
        $bw.Write([int32](36 + $dataBytes))
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('WAVE'))
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('fmt '))
        $bw.Write([int32]16)            # size of the format block
        $bw.Write([int16]1)             # 1 = uncompressed
        $bw.Write([int16]1)             # channels
        $bw.Write([int32]$rate)
        $bw.Write([int32]($rate * 2))   # bytes per second
        $bw.Write([int16]2)             # bytes per sample
        $bw.Write([int16]16)            # bits per sample
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('data'))
        $bw.Write([int32]$dataBytes)
        for ($i = 0; $i -lt $n; $i++) {
            $v = $Snd[$i]
            if ($v -gt 1.0) { $v = 1.0 } elseif ($v -lt -1.0) { $v = -1.0 }
            $bw.Write([int16][Math]::Round($v * 32767.0))
        }
        $bw.Flush()
    } finally { $fs.Dispose() }
}

# =============================================================================
#  the voice of the old ship
# =============================================================================
$old   = @(1.0, 0.0, 0.38, 0.0, 0.14)              # hollow, like a small worn speaker
$drive = @(0.5, 1.0, 0.8, 0.5, 0.3)                # machinery winding up or down (overtones carry it on small speakers)
$warm  = @(1.0, 0.50, 0.28, 0.12)                  # the AI: rounder
$rough = @(1.0, 0.85, 0.70, 0.55, 0.45, 0.35, 0.25) # a fault
$humH  = @(0.6, 1.0, 0.7, 0.4)                    # the hum of the power lines (overtones stronger than the base, so small speakers carry it)
# a console note: hollow tone, slightly off-tune pair, a little wobble, sinking a touch
function New-WHDSndNote {
    param([double]$F, [int]$Ms, [int]$ReleaseMs = 60, [double]$Vol = 0.6)
    return , (New-WHDSndTone -F1 $F -Ms $Ms -Vol $Vol -AttackMs 8 -ReleaseMs $ReleaseMs -Harm $old -Detune 0.005 -VibHz 6.0 -VibDepth 0.004 -Sag 0.012)
}
# the AI answering: rounder, with a slow voice-like wobble
function New-WHDSndVoice {
    param([double]$F, [int]$Ms, [int]$ReleaseMs = 120, [double]$Vol = 0.6)
    return , (New-WHDSndTone -F1 $F -Ms $Ms -Vol $Vol -AttackMs 25 -ReleaseMs $ReleaseMs -Harm $warm -Detune 0.003 -VibHz 5.2 -VibDepth 0.010)
}

# =============================================================================
#  the sounds. Name, what it is for (shown by -List and when playing), and how it is made.
#  "Events" = the Windows sound events it will be used for in the scheme (a later step);
#  "task" = played by a scheduled task of WHD Next (a later step).
# =============================================================================
$script:WHDSndList = @(
    @{ Name = 'signin';   For = 'you sign in  (power comes up, the ship answers)'; Events = @('task: sign-in')
       Make = { $a = New-WHDSndTone -F1 65 -Ms 2300 -Vol 0.22 -AttackMs 500 -ReleaseMs 700 -Harm $humH -VibHz 0.9 -VibDepth 0.010 -NoPitch -MaxHarm 7
                $a = Merge-WHDSnd $a (New-WHDSndClunk -Vol 0.40 -Seed 1) 40
                $a = Merge-WHDSnd $a (New-WHDSndTone -F1 62 -F2 150 -Ms 430 -Vol 0.34 -AttackMs 40 -ReleaseMs 200 -Harm $drive -Curve 1.4 -VibHz 9 -VibDepth 0.02 -NoPitch -MaxHarm 8) 120
                $a = Merge-WHDSnd $a (New-WHDSndTone -F1 58 -F2 235 -Ms 720 -Vol 0.40 -AttackMs 40 -ReleaseMs 260 -Harm $drive -Curve 1.7 -VibHz 8 -VibDepth 0.012 -NoPitch -MaxHarm 8) 560
                $a = Merge-WHDSnd $a (New-WHDSndClunk -Vol 0.36 -Seed 2) 1230
                $a = Merge-WHDSnd $a (New-WHDSndNote -F $C4 -Ms 220 -ReleaseMs 110 -Vol 0.50) 1330
                $a = Merge-WHDSnd $a (New-WHDSndNote -F $G4 -Ms 220 -ReleaseMs 110 -Vol 0.50) 1550
                $a = Merge-WHDSnd $a (New-WHDSndVoice -F $C5 -Ms 640 -ReleaseMs 480 -Vol 0.55) 1770
                Add-WHDSndEcho $a 180 0.20 } },
    @{ Name = 'signout';  For = 'you sign out'; Events = @('task: sign-out')
       Make = { $a = Join-WHDSnd @((New-WHDSndNote -F $C5 -Ms 200 -ReleaseMs 110), (New-WHDSndNote -F $G4 -Ms 200 -ReleaseMs 110), (New-WHDSndVoice -F $C4 -Ms 560 -ReleaseMs 420))
                $a = Merge-WHDSnd $a (New-WHDSndClunk -Vol 0.34 -Seed 3) 900
                Add-WHDSndEcho $a 180 0.20 } },
    @{ Name = 'shutdown'; For = 'the PC shuts down  (power winds down)'; Events = @('task: shut-down')
       Make = { $a = New-WHDSndTone -F1 250 -F2 48 -Ms 1750 -Vol 0.50 -AttackMs 30 -ReleaseMs 700 -Harm $drive -Curve 0.75 -VibHz 7 -VibDepth 0.015 -NoPitch -MaxHarm 9
                $a = Merge-WHDSnd $a (New-WHDSndTone -F1 65 -Ms 2100 -Vol 0.22 -AttackMs 80 -ReleaseMs 1300 -Harm $humH -Sag 0.20 -NoPitch -MaxHarm 7) 0
                $a = Merge-WHDSnd $a (New-WHDSndClunk -Vol 0.36 -Seed 4) 1380
                $a = Merge-WHDSnd $a (New-WHDSndClunk -Vol 0.42 -Seed 5) 1830
                Add-WHDSndEcho $a 200 0.16 } },
    @{ Name = 'lock';     For = 'the screen locks  (a latch, two notes down)'; Events = @('task: lock')
       Make = { $a = Join-WHDSnd @((New-WHDSndNote -F $G4 -Ms 120 -ReleaseMs 50), (New-WHDSndNote -F $C4 -Ms 260 -ReleaseMs 190))
                Merge-WHDSnd (New-WHDSndClunk -Vol 0.38 -Seed 6) $a 60 } },
    @{ Name = 'unlock';   For = 'the screen unlocks  (a latch, three notes up)'; Events = @('task: unlock')
       Make = { $a = Join-WHDSnd @((New-WHDSndNote -F $C4 -Ms 110 -ReleaseMs 45), (New-WHDSndNote -F $G4 -Ms 110 -ReleaseMs 45), (New-WHDSndVoice -F $C5 -Ms 280 -ReleaseMs 200))
                Merge-WHDSnd (New-WHDSndClunk -Vol 0.38 -Seed 7) $a 60 } },
    @{ Name = 'notify';   For = 'a notification'; Events = @('Notification.Default', 'SystemNotification')
       Make = { Join-WHDSnd @((New-WHDSndNote -F $A4 -Ms 95 -ReleaseMs 45 -Vol 0.5), (New-WHDSndGap 40), (New-WHDSndVoice -F $D5 -Ms 230 -ReleaseMs 170 -Vol 0.5)) } },
    @{ Name = 'message';  For = 'a chat or text message'; Events = @('Notification.IM', 'Notification.SMS', 'MessageNudge')
       Make = { $b = New-WHDSndNote -F $A4 -Ms 80 -ReleaseMs 35
                Join-WHDSnd @($b, (New-WHDSndGap 55), $b, (New-WHDSndGap 55), (New-WHDSndNote -F $A4 -Ms 160 -ReleaseMs 115)) } },
    @{ Name = 'mail';     For = 'new e-mail'; Events = @('MailBeep', 'Notification.Mail', 'FaxBeep')
       Make = { Join-WHDSnd @((New-WHDSndNote -F $C4 -Ms 105 -ReleaseMs 40), (New-WHDSndNote -F $E4 -Ms 105 -ReleaseMs 40), (New-WHDSndNote -F $G4 -Ms 105 -ReleaseMs 40), (New-WHDSndVoice -F $C5 -Ms 320 -ReleaseMs 240)) } },
    @{ Name = 'reminder'; For = 'a calendar reminder'; Events = @('Notification.Reminder')
       Make = { Join-WHDSnd @((New-WHDSndVoice -F $A4 -Ms 270 -ReleaseMs 210), (New-WHDSndGap 140), (New-WHDSndVoice -F $A4 -Ms 400 -ReleaseMs 330)) } },
    @{ Name = 'error';    For = 'an error (critical stop)'; Events = @('SystemHand')
       Make = { Join-WHDSnd @((New-WHDSndTone -F1 $A3 -Ms 200 -ReleaseMs 30 -Harm $rough -VibHz 22 -VibDepth 0.03), (New-WHDSndGap 70), (New-WHDSndTone -F1 $A3 -F2 $G3 -Ms 300 -ReleaseMs 70 -Harm $rough -VibHz 22 -VibDepth 0.03)) } },
    @{ Name = 'warning';  For = 'a warning (exclamation)'; Events = @('SystemExclamation')
       Make = { $hi = New-WHDSndNote -F $G4 -Ms 130 -ReleaseMs 30; $lo = New-WHDSndNote -F $Eb4 -Ms 130 -ReleaseMs 30
                Join-WHDSnd @($hi, $lo, $hi, $lo, $hi, (New-WHDSndNote -F $Eb4 -Ms 210 -ReleaseMs 140)) } },
    @{ Name = 'info';     For = 'an information box (asterisk)'; Events = @('SystemAsterisk')
       Make = { New-WHDSndVoice -F $D5 -Ms 340 -ReleaseMs 270 } },
    @{ Name = 'beep';     For = 'the plain beep'; Events = @('.Default')
       Make = { New-WHDSndNote -F $G4 -Ms 140 -ReleaseMs 75 } },
    @{ Name = 'connect';  For = 'a device is plugged in'; Events = @('DeviceConnect')
       Make = { $a = Join-WHDSnd @((New-WHDSndNote -F $D4 -Ms 130 -ReleaseMs 50), (New-WHDSndNote -F $A4 -Ms 230 -ReleaseMs 165))
                Merge-WHDSnd (New-WHDSndClunk -Vol 0.36 -Seed 8) $a 55 } },
    @{ Name = 'disconnect'; For = 'a device is removed'; Events = @('DeviceDisconnect')
       Make = { $a = Join-WHDSnd @((New-WHDSndNote -F $A4 -Ms 130 -ReleaseMs 50), (New-WHDSndNote -F $D4 -Ms 230 -ReleaseMs 165))
                Merge-WHDSnd $a (New-WHDSndClunk -Vol 0.36 -Seed 9) 330 } },
    @{ Name = 'devicefail'; For = 'a device failed to connect'; Events = @('DeviceFail')
       Make = { $b = New-WHDSndTone -F1 $D4 -Ms 115 -ReleaseMs 35 -Harm $rough -VibHz 18 -VibDepth 0.02
                Join-WHDSnd @($b, (New-WHDSndGap 60), $b, (New-WHDSndGap 60), (New-WHDSndTone -F1 $D4 -F2 $A3 -Ms 230 -ReleaseMs 100 -Harm $rough -VibHz 18 -VibDepth 0.02)) } },
    @{ Name = 'uac';      For = 'Windows asks for administrator permission'; Events = @('WindowsUAC')
       Make = { $c1 = Merge-WHDSnd (New-WHDSndVoice -F $C4 -Ms 260 -Vol 0.4 -ReleaseMs 90) (New-WHDSndVoice -F $G4 -Ms 260 -Vol 0.4 -ReleaseMs 90) 0
                $c2 = Merge-WHDSnd (New-WHDSndVoice -F $E4 -Ms 340 -Vol 0.4 -ReleaseMs 230) (New-WHDSndVoice -F $B4 -Ms 340 -Vol 0.4 -ReleaseMs 230) 0
                Join-WHDSnd @($c1, (New-WHDSndGap 60), $c2) } },
    @{ Name = 'batterylow'; For = 'the battery is low  (tired)'; Events = @('LowBatteryAlarm')
       Make = { $b = New-WHDSndTone -F1 $C4 -Ms 270 -ReleaseMs 130 -Harm $old -Detune 0.006 -Sag 0.06
                Join-WHDSnd @($b, (New-WHDSndGap 210), $b) } },
    @{ Name = 'batterycritical'; For = 'the battery is almost empty'; Events = @('CriticalBatteryAlarm')
       Make = { $b = New-WHDSndNote -F $E4 -Ms 125 -ReleaseMs 40
                Join-WHDSnd @($b, (New-WHDSndGap 90), $b, (New-WHDSndGap 90), $b, (New-WHDSndGap 90), (New-WHDSndTone -F1 $E4 -F2 $B3 -Ms 260 -ReleaseMs 140 -Harm $old -Detune 0.006)) } },
    @{ Name = 'proximity'; For = 'a nearby device (tap / proximity)'; Events = @('Notification.Proximity', 'ProximityConnection')
       Make = { Join-WHDSnd @((New-WHDSndTone -F1 420 -F2 840 -Ms 160 -Vol 0.5 -ReleaseMs 40 -Harm $warm), (New-WHDSndGap 30), (New-WHDSndNote -F $E5 -Ms 120 -ReleaseMs 85 -Vol 0.5)) } }
)

function Get-WHDSndFileName { param([string]$Name) return ('whd-{0}.wav' -f $Name) }

# ---- which sounds ---------------------------------------------------------------
$all = @($script:WHDSndList)
$chosen = $all
if ($Only) {
    $want = @($Only | ForEach-Object { "$_".Split(',') } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
    $known = @($all | ForEach-Object { $_.Name })
    $bad = @($want | Where-Object { $known -notcontains $_ })
    if ($bad.Count) { Write-Host (' Unknown sound name(s): {0}' -f ($bad -join ', ')) -ForegroundColor Red; Write-Host (' Names: {0}' -f ($known -join ', ')); exit 2 }
    $chosen = @($all | Where-Object { $want -contains $_.Name })
}

if ($List) {
    Write-Host ''
    Write-Host ' WHD Next theme sounds (nothing is written by -List)' -ForegroundColor Cyan
    foreach ($s in $chosen) { Write-Host ('   {0,-16} {1,-52} {2}' -f $s.Name, $s.For, ($s.Events -join ', ')) }
    Write-Host ''
    exit 0
}

if (-not $OutDir) {
    if (-not $env:ProgramData) { Write-Host ' No ProgramData folder on this PC - give a folder with -OutDir.' -ForegroundColor Red; exit 2 }
    $OutDir = Join-Path (Join-Path (Join-Path $env:ProgramData 'WinHardenDebloatNext') 'theme') 'sounds'
}

# ---- make ----------------------------------------------------------------------
if (-not $PlayOnly) {
    try {
        if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force -ErrorAction Stop | Out-Null }
        if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) { throw 'the folder is not there after the attempt to create it' }
    } catch {
        Write-Host (' The folder could not be created: {0}' -f $OutDir) -ForegroundColor Red
        Write-Host (' {0}' -f $_.Exception.Message) -ForegroundColor Red
        Write-Host ' That folder can only be changed in an administrator window. Open one and run this again, or give another folder with -OutDir.' -ForegroundColor Yellow
        exit 3
    }
    Write-Host ''
    Write-Host (' Making {0} sound(s) in {1}{2}' -f $chosen.Count, $OutDir, $(if ($Pitch -ne 1.0) { ('   (pitch x {0})' -f $Pitch) } else { '' })) -ForegroundColor Cyan
    Write-Host ' (low notes take a little longer to work out)' -ForegroundColor DarkGray
    $made = 0; $failed = 0
    foreach ($s in $chosen) {
        $file = Join-Path $OutDir (Get-WHDSndFileName $s.Name)
        try {
            $snd = & $s.Make
            $snd = Set-WHDSndLevel $snd
            Write-WHDSndWav -Path $file -Snd $snd
            $made++
            Write-Host ('   made  {0,-16} {1,5:N2} s   {2}' -f $s.Name, ($snd.Length / [double]$script:WHDSndRate), $s.For)
        } catch {
            $failed++
            Write-Host ('   FAILED {0}: {1}' -f $s.Name, $_.Exception.Message) -ForegroundColor Red
        }
    }
    Write-Host (' Done: {0} made, {1} failed. No Windows setting was changed.' -f $made, $failed) -ForegroundColor $(if ($failed) { 'Yellow' } else { 'Green' })
    if ($failed) {
        $script:WHDSndExit = 1
        Write-Host ' If the lines above say "access ... denied": that folder can only be changed in an administrator window.' -ForegroundColor Yellow
    }
}

# ---- play -------------------------------------------------------------------------
if ($Play -or $PlayOnly) {
    $player = $null
    try { $player = New-Object System.Media.SoundPlayer } catch { $player = $null }
    if ($null -eq $player) {
        Write-Host ' The sounds cannot be played in this PowerShell (no .wav player here). The files are in the folder above.' -ForegroundColor Yellow
    } else {
        Write-Host ''
        Write-Host ' Playing - listen for each name:' -ForegroundColor Cyan
        $i = 0
        foreach ($s in $chosen) {
            $i++
            $file = Join-Path $OutDir (Get-WHDSndFileName $s.Name)
            if (-not (Test-Path -LiteralPath $file)) { Write-Host ('   {0,2}. {1,-16} (file not found - make the sounds first)' -f $i, $s.Name) -ForegroundColor Yellow; continue }
            Write-Host ('   {0,2}. {1,-16} {2}' -f $i, $s.Name, $s.For)
            try { $player.SoundLocation = $file; $player.Load(); $player.PlaySync() }
            catch { Write-Host ('       could not be played: {0}' -f $_.Exception.Message) -ForegroundColor Yellow }
            Start-Sleep -Milliseconds $PauseMs
        }
        try { $player.Dispose() } catch { }
        Write-Host ' That was the last one.' -ForegroundColor Cyan
    }
}
if ($script:WHDSndExit) { exit $script:WHDSndExit }
exit 0
