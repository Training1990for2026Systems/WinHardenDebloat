#requires -Version 7.6
<#
================================================================================
 WHD Next 3.0  -  Features/ThemeSound.ps1   (theme: the ship's sounds)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Build step 5.10a, second design (D64-D67). The owner wanted space / film-like
 sound with a spoken ship's computer: every one of the 20 sounds is a short
 score of effects - console tones (FM), drifting chords, sweeps of air, a low
 swell, shimmer, data chatter, warbles - then the ship's voice saying its line,
 in our own room echo, stereo 44.1 kHz 16-bit. All of it is our own arithmetic.
 The voice is Windows' own offline speech, the voice "Zira" (D66, D67): item 1
 records the 20 lines through Windows' speech component on this PC, then mixes
 them. No Zira on a PC = the sounds are made without a voice (D67). The pitch
 asked in item 1 moves the effects only; the voice is never pitched (D67).
 While the voice speaks the effects step back; the voice has its own light
 echo. Every sound is levelled as a small speaker plays it.
 Files: whd-<name>.wav. This file only records the voice into WHD's own folder,
 makes sample arrays and .wav bytes - no Windows setting.
================================================================================
#>

$script:WHDSynth = @{
    Rate = 44100; Pitch = 0.5; Loud = 0.24; Top = 0.94; Knee = 0.62
    CarryHz = 380.0; CarryMin = 0.25
}
$script:WHDSynthPitchMin = 0.25
$script:WHDSynthPitchMax = 1.0
$script:WHDThemeVoiceName = 'Zira'          # Windows' voice used for the lines (D67)

function ConvertTo-WHDSynthHz {
    [CmdletBinding()]
    [OutputType([double])]
    param([Parameter(Mandatory)]$Note)
    if ($Note -is [double] -or $Note -is [int]) { return [double]$Note }
    $t = [string]$Note
    if ($t -notmatch '^([A-Ga-g])([#b]?)(-?\d)$') { throw ('not a note: {0}' -f $t) }
    $step = @{ C = 0; D = 2; E = 4; F = 5; G = 7; A = 9; B = 11 }[$Matches[1].ToUpperInvariant()]
    if ($Matches[2] -eq '#') { $step++ } elseif ($Matches[2] -eq 'b') { $step-- }
    return 440.0 * [Math]::Pow(2.0, ((12 * ([int]$Matches[3] + 1) + $step) - 69) / 12.0)
}
function Get-WHDSynthN {
    [CmdletBinding()]
    [OutputType([int])]
    param([double]$Ms)
    return [int][Math]::Max(0, [Math]::Round($script:WHDSynth.Rate * $Ms / 1000.0))
}
function Get-WHDSynthTuned {
    # A note at the effects pitch (D67).
    [CmdletBinding()]
    [OutputType([double])]
    param($F)
    return (ConvertTo-WHDSynthHz $F) * $script:WHDSynth.Pitch
}

# Envelope: linear attack, then hold, then a smooth (cosine) release to zero at the end.
function Get-WHDSynthEnv {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([int]$N, [double]$AttackMs, [double]$RelMs, [double]$DecayMs = 0)
    $e = [double[]]::new($N)
    $a = [Math]::Max(1, (Get-WHDSynthN $AttackMs)); $r = [Math]::Max(1, (Get-WHDSynthN $RelMs))
    if ($a + $r -gt $N) { $a = [Math]::Max(1, [int]($N * 0.3)); $r = [Math]::Max(1, $N - $a) }
    $k = if ($DecayMs -gt 0) { 1.0 / ((Get-WHDSynthN $DecayMs) + 1) } else { 0.0 }
    for ($i = 0; $i -lt $N; $i++) {
        $v = if ($i -lt $a) { $i / [double]$a } else { if ($k -gt 0) { [Math]::Exp(-($i - $a) * $k) } else { 1.0 } }
        if ($i -ge $N - $r) { $v *= 0.5 + 0.5 * [Math]::Cos([Math]::PI * ($i - ($N - $r)) / [double]$r) }
        $e[$i] = $v
    }
    return , $e
}

# Equal-power pan of a mono part into L / R. Pan -1 (left) .. +1 (right); Pan2 = moving pan.
function ConvertTo-WHDSynthStereo {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([double[]]$Mono, [double]$Pan = 0, $Pan2)
    $n = $Mono.Length; $L = [double[]]::new($n); $R = [double[]]::new($n)
    $p2 = if ($null -ne $Pan2) { [double]$Pan2 } else { $Pan }
    for ($i = 0; $i -lt $n; $i++) {
        $p = $Pan + ($p2 - $Pan) * ($i / [double][Math]::Max(1, $n - 1))
        $ang = ($p + 1.0) * [Math]::PI / 4.0
        $L[$i] = $Mono[$i] * [Math]::Cos($ang); $R[$i] = $Mono[$i] * [Math]::Sin($ang)
    }
    return , @($L, $R)
}

# A console tone: two-operator FM (a carrier whose phase is pushed by a modulator). Index falls
# from I1 to I2: bright at the start, pure at the end - a bell or a chirp.
function Get-WHDSynthFm {
    [CmdletBinding()]
    [OutputType([object[]])]
    param($F, $F2, [double]$Ratio = 2.0, [double]$I1 = 2.0, [double]$I2 = 0.2, [double]$Ms = 300,
          [double]$AttackMs = 4, [double]$DecayMs = 180, [double]$RelMs = 60, [double]$Vol = 0.5, [double]$Pan = 0)
    $rate = $script:WHDSynth.Rate
    $n = [Math]::Max(2, (Get-WHDSynthN $Ms))
    $f1 = Get-WHDSynthTuned $F; $fe = if ($null -ne $F2) { Get-WHDSynthTuned $F2 } else { $f1 }
    $env = Get-WHDSynthEnv -N $n -AttackMs $AttackMs -RelMs $RelMs -DecayMs $DecayMs
    $buf = [double[]]::new($n); $pc = 0.0; $pm = 0.0; $w = 2.0 * [Math]::PI / $rate
    $carry = if ($f1 -lt $script:WHDSynth.CarryHz) { [Math]::Max($script:WHDSynth.CarryMin, ($f1 / $script:WHDSynth.CarryHz)) } else { 1.0 }
    for ($i = 0; $i -lt $n; $i++) {
        $t = $i / [double]$n
        $f = $f1 + ($fe - $f1) * $t
        $pc += $w * $f; $pm += $w * $f * $Ratio
        $idx = $I1 + ($I2 - $I1) * $t
        # a low carrier gets a little of its octave so a small speaker can follow it
        $buf[$i] = $Vol * $env[$i] * ([Math]::Sin($pc + $idx * [Math]::Sin($pm)) * $carry + (1.0 - $carry) * 0.6 * [Math]::Sin(2.0 * $pc + $idx * [Math]::Sin($pm)))
    }
    return , (ConvertTo-WHDSynthStereo -Mono $buf -Pan $Pan)
}

# A pad: several slightly detuned voices per note, spread left to right, each with a few
# overtones whose brightness opens and closes slowly - the drifting chord under a big moment.
function Get-WHDSynthPad {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([object[]]$Fs, [double]$Ms = 2000, [double]$AttackMs = 600, [double]$RelMs = 800, [double]$Vol = 0.4,
          [int]$Voices = 3, [double]$Cents = 9, [double]$Spread = 0.8, [double]$Bright = 0.5)
    $rate = $script:WHDSynth.Rate; $n = [Math]::Max(2, (Get-WHDSynthN $Ms))
    $env = Get-WHDSynthEnv -N $n -AttackMs $AttackMs -RelMs $RelMs
    $L = [double[]]::new($n); $R = [double[]]::new($n); $w = 2.0 * [Math]::PI / $rate
    $all = @(foreach ($fn in $Fs) { for ($v = 0; $v -lt $Voices; $v++) { , @((Get-WHDSynthTuned $fn), $v) } })
    $count = $all.Count; $j = 0
    foreach ($a in $all) {
        $fb = $a[0]; $v = $a[1]
        $det = if ($Voices -gt 1) { ($v / [double]($Voices - 1) - 0.5) * 2.0 * $Cents } else { 0.0 }
        $f = $fb * [Math]::Pow(2.0, $det / 1200.0)
        $p = if ($count -gt 1) { (($j / [double]($count - 1)) - 0.5) * 2.0 * $Spread } else { 0.0 }
        $ang = ($p + 1.0) * [Math]::PI / 4.0; $gl = [Math]::Cos($ang); $gr = [Math]::Sin($ang)
        $ph = ($j * 1.7) % (2 * [Math]::PI); $lfoW = $w * (0.13 + 0.07 * $j)
        $low = if ($f -lt $script:WHDSynth.CarryHz) { [Math]::Max($script:WHDSynth.CarryMin, $f / $script:WHDSynth.CarryHz) } else { 1.0 }
        for ($i = 0; $i -lt $n; $i++) {
            $ph += $w * $f
            $b = $Bright * (0.6 + 0.4 * [Math]::Sin($lfoW * $i))           # brightness drifts
            $s1 = [Math]::Sin($ph); $c = 2.0 * [Math]::Cos($ph)
            $s2 = $c * $s1; $s3 = $c * $s2 - $s1; $s4 = $c * $s3 - $s2
            $y = ($s1 * $low + 0.55 * $b * $s2 + 0.35 * $b * $b * $s3 + 0.2 * $b * $b * $s4) * $env[$i] * $Vol / $count
            $L[$i] += $y * $gl; $R[$i] += $y * $gr
        }
        $j++
    }
    return , @($L, $R)
}

# Air: our own noise through a resonant filter whose centre sweeps from F1 to F2 Hz, moving across
# the stereo field - the rush of something passing.
function Get-WHDSynthWhoosh {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([double]$Ms = 1200, [double]$F1 = 300, [double]$F2 = 3000, [double]$Q = 0.35, [double]$AttackMs = 400, [double]$RelMs = 500,
          [double]$Vol = 0.3, [double]$Pan = -0.7, [double]$Pan2 = 0.7, [int]$Seed = 1)
    $rate = $script:WHDSynth.Rate; $n = [Math]::Max(2, (Get-WHDSynthN $Ms))
    $env = Get-WHDSynthEnv -N $n -AttackMs $AttackMs -RelMs $RelMs
    $buf = [double[]]::new($n)
    [long]$x = 90001 + 7717 * $Seed; $low = 0.0; $band = 0.0
    for ($i = 0; $i -lt $n; $i++) {
        $x = ($x * 69069 + 1) % 4294967296
        $r = ($x / 2147483648.0) - 1.0
        $fc = $F1 * [Math]::Pow($F2 / $F1, $i / [double]$n)                 # even sweep to the ear
        $fq = 2.0 * [Math]::Sin([Math]::PI * [Math]::Min($fc, $rate * 0.2) / $rate)
        $low += $fq * $band; $high = $r - $low - $Q * $band; $band += $fq * $high
        $buf[$i] = $Vol * $env[$i] * $band * 0.5
    }
    return , (ConvertTo-WHDSynthStereo -Mono $buf -Pan $Pan -Pan2 $Pan2)
}

# The low swell: a deep tone gliding F -> F2, carried by its overtones so small speakers show it.
function Get-WHDSynthSub {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([double]$F = 45, [double]$F2 = 0, [double]$Ms = 2000, [double]$AttackMs = 700, [double]$RelMs = 900, [double]$Vol = 0.5)
    $rate = $script:WHDSynth.Rate; $n = [Math]::Max(2, (Get-WHDSynthN $Ms))
    if ($F2 -le 0) { $F2 = $F }
    $env = Get-WHDSynthEnv -N $n -AttackMs $AttackMs -RelMs $RelMs
    $buf = [double[]]::new($n); $ph = 0.0; $w = 2.0 * [Math]::PI / $rate
    for ($i = 0; $i -lt $n; $i++) {
        $ph += $w * ($F + ($F2 - $F) * ($i / [double]$n))
        $s1 = [Math]::Sin($ph); $c = 2.0 * [Math]::Cos($ph); $s2 = $c * $s1; $s3 = $c * $s2 - $s1; $s4 = $c * $s3 - $s2
        $buf[$i] = $Vol * $env[$i] * (0.35 * $s1 + 0.55 * $s2 + 0.45 * $s3 + 0.3 * $s4)
    }
    return , (ConvertTo-WHDSynthStereo -Mono $buf -Pan 0)
}

# Shimmer: high partials of a note, each flickering slowly on its own, spread wide - stars.
function Get-WHDSynthShimmer {
    [CmdletBinding()]
    [OutputType([object[]])]
    param($F, [double]$Ms = 1500, [double]$AttackMs = 500, [double]$RelMs = 700, [double]$Vol = 0.15, [int]$Seed = 3)
    $rate = $script:WHDSynth.Rate; $n = [Math]::Max(2, (Get-WHDSynthN $Ms))
    $f0 = Get-WHDSynthTuned $F
    $env = Get-WHDSynthEnv -N $n -AttackMs $AttackMs -RelMs $RelMs
    $L = [double[]]::new($n); $R = [double[]]::new($n); $w = 2.0 * [Math]::PI / $rate
    $mult = @(2.0, 3.0, 4.0, 5.04, 6.0, 8.02)
    [long]$x = 5003 + 311 * $Seed
    for ($k = 0; $k -lt $mult.Count; $k++) {
        $x = ($x * 69069 + 1) % 4294967296; $rnd = $x / 4294967296.0
        $f = $f0 * $mult[$k] * (1.0 + ($rnd - 0.5) * 0.004)
        if ($f -ge $rate * 0.45) { continue }
        $p = ((($k % 2) * 2) - 1) * (0.4 + 0.5 * $rnd)
        $ang = ($p + 1.0) * [Math]::PI / 4.0; $gl = [Math]::Cos($ang); $gr = [Math]::Sin($ang)
        $fl = $w * (1.3 + 2.9 * $rnd); $ph = 0.0; $g = $Vol / [Math]::Sqrt($k + 1.0)
        for ($i = 0; $i -lt $n; $i++) {
            $ph += $w * $f
            $y = $g * $env[$i] * [Math]::Sin($ph) * (0.55 + 0.45 * [Math]::Sin($fl * $i + $k))
            $L[$i] += $y * $gl; $R[$i] += $y * $gr
        }
    }
    return , @($L, $R)
}

# Data chatter: a quick run of short console blips at pitches picked by our own number sequence from a
# scale - the computer "thinking". Rise = the run climbs.
function Get-WHDSynthChatter {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([int]$Count = 7, [double]$StepMs = 42, [double]$BlipMs = 34, [double]$Vol = 0.3, [int]$Seed = 1, [switch]$Rise,
          [double]$Pan = -0.5, [double]$Pan2 = 0.5, [double]$Low = 1400, [double]$High = 3200)
    $rate = $script:WHDSynth.Rate; $fx = $script:WHDSynth.Pitch / 0.5; $Low *= $fx; $High *= $fx
    $n = (Get-WHDSynthN ($StepMs * ($Count - 1) + $BlipMs)) + 2
    $L = [double[]]::new($n); $R = [double[]]::new($n)
    [long]$x = 11939 + 4421 * $Seed
    for ($c = 0; $c -lt $Count; $c++) {
        $x = ($x * 69069 + 1) % 4294967296; $rnd = $x / 4294967296.0
        $q = if ($Rise) { ($c + 0.6 * $rnd) / [double]$Count } else { $rnd }
        $f = $Low * [Math]::Pow($High / $Low, $q)
        $f = 220.0 * [Math]::Pow(2.0, [Math]::Round(12.0 * [Math]::Log($f / 220.0, 2)) / 12.0)   # on the semitone grid
        $m = [Math]::Max(2, (Get-WHDSynthN $BlipMs)); $ph = 0.0; $pm = 0.0; $w = 2.0 * [Math]::PI / $rate
        $p = $Pan + ($Pan2 - $Pan) * ($c / [double][Math]::Max(1, $Count - 1)); $ang = ($p + 1.0) * [Math]::PI / 4.0
        $gl = [Math]::Cos($ang); $gr = [Math]::Sin($ang); $at = Get-WHDSynthN ($StepMs * $c)
        for ($i = 0; $i -lt $m; $i++) {
            $ph += $w * $f; $pm += $w * $f * 1.5
            $e = [Math]::Min(1.0, $i / 40.0) * [Math]::Pow(1.0 - $i / [double]$m, 1.6)
            $y = $Vol * $e * [Math]::Sin($ph + 0.8 * [Math]::Sin($pm))
            $L[$at + $i] += $y * $gl; $R[$at + $i] += $y * $gr
        }
    }
    return , @($L, $R)
}

# A warble: a tone whose pitch trills fast up and down while it glides - an electronic "attention".
function Get-WHDSynthWarble {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([double]$F = 1800, [double]$F2 = 0, [double]$Ms = 220, [double]$RateHz = 28, [double]$Depth = 0.12, [double]$Vol = 0.3, [double]$Pan = 0)
    $rate = $script:WHDSynth.Rate; $n = [Math]::Max(2, (Get-WHDSynthN $Ms)); if ($F2 -le 0) { $F2 = $F }
    $fx = $script:WHDSynth.Pitch / 0.5; $F *= $fx; $F2 *= $fx
    $env = Get-WHDSynthEnv -N $n -AttackMs 6 -RelMs ($Ms * 0.35)
    $buf = [double[]]::new($n); $ph = 0.0; $w = 2.0 * [Math]::PI / $rate
    for ($i = 0; $i -lt $n; $i++) {
        $f = ($F + ($F2 - $F) * $i / [double]$n) * (1.0 + $Depth * [Math]::Sin($w * $RateHz * $i))
        $ph += $w * $f
        $buf[$i] = $Vol * $env[$i] * ([Math]::Sin($ph) + 0.25 * [Math]::Sin(2 * $ph))
    }
    return , (ConvertTo-WHDSynthStereo -Mono $buf -Pan $Pan)
}

# A recorded line (a 16-bit mono .wav, e.g. Windows' own voice) placed in the mix: read, resampled to the
# mix rate with 4-point (cubic) interpolation; Lower < 1 plays it slower = deeper. Same clean speaker band.
function Get-WHDSynthSpeakFile {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string]$Path, [double]$Lower = 1.0, [double]$Vol = 0.9, [double]$Pan = 0)
    $b = [System.IO.File]::ReadAllBytes($Path)
    $srcRate = [BitConverter]::ToInt32($b, 24)
    $pos = 12; $dataAt = -1; $dataLen = 0
    while ($pos -lt $b.Length - 8) {
        $id = [System.Text.Encoding]::ASCII.GetString($b, $pos, 4); $sz = [BitConverter]::ToInt32($b, $pos + 4)
        if ($id -eq 'data') { $dataAt = $pos + 8; $dataLen = [Math]::Min($sz, $b.Length - $pos - 8); break }
        $pos += 8 + $sz + ($sz % 2)
    }
    if ($dataAt -lt 0) { throw 'no data block in the .wav' }
    $ns = [int]($dataLen / 2); $src = [double[]]::new($ns)
    for ($i = 0; $i -lt $ns; $i++) { $src[$i] = [BitConverter]::ToInt16($b, $dataAt + 2 * $i) / 32768.0 }
    # trim the silence Windows puts before and after the words (keep 15 ms)
    $pk0 = 0.0; foreach ($x in $src) { $a = [Math]::Abs($x); if ($a -gt $pk0) { $pk0 = $a } }
    $th = 0.02 * $pk0; $s0 = 0; while ($s0 -lt $ns - 1 -and [Math]::Abs($src[$s0]) -lt $th) { $s0++ }
    $s1 = $ns - 1; while ($s1 -gt $s0 -and [Math]::Abs($src[$s1]) -lt $th) { $s1-- }
    $keep = [int]($srcRate * 0.015); $s0 = [Math]::Max(0, $s0 - $keep); $s1 = [Math]::Min($ns - 1, $s1 + $keep)
    $src = $src[$s0..$s1]; $ns = $src.Length
    $rate = $script:WHDSynth.Rate
    $step = ($srcRate / [double]$rate) * $Lower
    $n = [int](($ns - 3) / $step); $v = [double[]]::new($n)
    for ($i = 0; $i -lt $n; $i++) {
        $t = 1.0 + $i * $step; $k = [int][Math]::Floor($t); $f = $t - $k
        $y0 = $src[$k - 1]; $y1 = $src[$k]; $y2 = $src[$k + 1]; $y3 = $src[[Math]::Min($ns - 1, $k + 2)]
        $v[$i] = $y1 + 0.5 * $f * ($y2 - $y0 + $f * (2 * $y0 - 5 * $y1 + 4 * $y2 - $y3 + $f * (3 * ($y1 - $y2) + $y3 - $y0)))
    }
    $pk = 0.0; foreach ($x in $v) { $a = [Math]::Abs($x); if ($a -gt $pk) { $pk = $a } }
    $hp = [Math]::Exp(-2 * [Math]::PI * 90 / $rate); $lpk = 1 - [Math]::Exp(-2 * [Math]::PI * 7500 / $rate)
    $px = 0.0; $py = 0.0; $lp = 0.0; $o = [double[]]::new($n)
    for ($i = 0; $i -lt $n; $i++) { $py = $v[$i] - $px + $hp * $py; $px = $v[$i]; $lp += $lpk * ($py - $lp); $o[$i] = $Vol * 0.9 * $lp / [Math]::Max(1e-9, $pk) }
    return , (ConvertTo-WHDSynthStereo -Mono $o -Pan $Pan)
}

# The room: our own reverberation - per side six feedback delay lines with a gentle treble loss
# (combs) and three diffusers (all-pass), different lengths left and right so the echo is wide.
function Add-WHDSynthRoom {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([double[]]$L, [double[]]$R, [double]$Size = 0.88, [double]$Damp = 0.3, [double]$Wet = 0.3, [double]$PreMs = 18)
    $scale = $script:WHDSynth.Rate / 44100.0
    $combs = @(1116, 1188, 1277, 1356, 1422, 1557); $alls = @(556, 441, 341)
    $pre = Get-WHDSynthN $PreMs
    $n = $L.Length
    $out = @(); $side = 0
    foreach ($src in @($L, $R)) {
        $offset = $side * 23
        $y = [double[]]::new($n)
        foreach ($cd in $combs) {
            $d = [int](($cd + $offset) * $scale); $line = [double[]]::new($d); $pos = 0; $lp = 0.0
            for ($i = 0; $i -lt $n; $i++) {
                $o = $line[$pos]
                $lp = $o * (1.0 - $Damp) + $lp * $Damp
                $in = if ($i -ge $pre) { $src[$i - $pre] } else { 0.0 }
                $line[$pos] = $in * 0.05 + $lp * $Size
                $y[$i] += $o
                $pos++; if ($pos -ge $d) { $pos = 0 }
            }
        }
        foreach ($ad in $alls) {
            $d = [int](($ad + $offset) * $scale); $line = [double[]]::new($d); $pos = 0
            for ($i = 0; $i -lt $n; $i++) {
                $b = $line[$pos]; $v = $y[$i]
                $line[$pos] = $v + $b * 0.5
                $y[$i] = $b - $v
                $pos++; if ($pos -ge $d) { $pos = 0 }
            }
        }
        $wetBuf = [double[]]::new($n)
        for ($i = 0; $i -lt $n; $i++) { $wetBuf[$i] = $src[$i] * (1.0 - $Wet * 0.5) + $y[$i] * $Wet }
        $out += , $wetBuf
        $side++
    }
    return , $out
}

# The mixer: parts placed by At (ms) or after the last one (+ Gap ms), then the room, then a tail.
function Invoke-WHDSynthScore {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([object[]]$Parts, [hashtable]$Room, [double]$TailMs = 800)
    $placed = [System.Collections.Generic.List[object]]::new(); $end = 0; $len = 0
    foreach ($p in $Parts) {
        $a = @{} + $p; $k = $a.K; [void]$a.Remove('K')
        $at = $null; if ($a.ContainsKey('At')) { $at = Get-WHDSynthN $a.At; [void]$a.Remove('At') }
        $gap = 0; if ($a.ContainsKey('Gap')) { $gap = [int][Math]::Round($script:WHDSynth.Rate * [double]$a.Gap / 1000.0); [void]$a.Remove('Gap') }
        $st = switch ($k) {
            'fm' { Get-WHDSynthFm @a } 'pad' { Get-WHDSynthPad @a } 'whoosh' { Get-WHDSynthWhoosh @a }
            'sub' { Get-WHDSynthSub @a } 'shimmer' { Get-WHDSynthShimmer @a }
            'chatter' { Get-WHDSynthChatter @a } 'warble' { Get-WHDSynthWarble @a } 'voice' { Get-WHDSynthSpeakFile @a }
            default { throw ('unknown part: {0}' -f $k) }
        }
        $pos = if ($null -ne $at) { $at } else { [Math]::Max(0, $end + $gap) }
        $placed.Add(@($pos, $st, $k)); $end = $pos + $st[0].Length; $len = [Math]::Max($len, $end)
    }
    $len += Get-WHDSynthN $TailMs
    $L = [double[]]::new($len); $R = [double[]]::new($len); $VL = [double[]]::new($len); $VR = [double[]]::new($len)
    $hasVoice = $false
    foreach ($pl in $placed) {
        $pos = $pl[0]; $sl = $pl[1][0]; $sr = $pl[1][1]
        if ($pl[2] -eq 'voice') { $hasVoice = $true; for ($i = 0; $i -lt $sl.Length; $i++) { $VL[$pos + $i] += $sl[$i]; $VR[$pos + $i] += $sr[$i] } }
        else { for ($i = 0; $i -lt $sl.Length; $i++) { $L[$pos + $i] += $sl[$i]; $R[$pos + $i] += $sr[$i] } }
    }
    if ($hasVoice) {
        # duck: while the voice speaks, the effects step back (up to -8 dB), smoothly
        $env = 0.0; $atk = 1 - [Math]::Exp(-1.0 / (0.02 * $script:WHDSynth.Rate)); $rel = 1 - [Math]::Exp(-1.0 / (0.35 * $script:WHDSynth.Rate))
        $vp = 0.0; for ($i = 0; $i -lt $len; $i++) { $a = [Math]::Abs($VL[$i]); if ($a -gt $vp) { $vp = $a } }
        for ($i = 0; $i -lt $len; $i++) {
            $a = [Math]::Min(1.0, 3.0 * [Math]::Abs($VL[$i]) / [Math]::Max(1e-9, $vp))
            $env += $(if ($a -gt $env) { $atk } else { $rel }) * ($a - $env)
            $g = 1.0 - 0.6 * $env; $L[$i] *= $g; $R[$i] *= $g
        }
    }
    if ($Room) { $LR = Add-WHDSynthRoom -L $L -R $R @Room; $L = $LR[0]; $R = $LR[1] }
    if ($hasVoice) {
        $VR2 = Add-WHDSynthRoom -L $VL -R $VR -Size 0.78 -Damp 0.45 -Wet 0.12 -PreMs 22
        for ($i = 0; $i -lt $len; $i++) { $L[$i] += $VR2[0][$i]; $R[$i] += $VR2[1][$i] }
    }
    return , @($L, $R)
}

# Level as a small speaker hears it (the middle of L + R with the lows taken away), peaks rounded
# off, both ends faded (the tail fades over its last 40 %).
function ConvertTo-WHDSynthLevel {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([object[]]$St, [double]$TailMs = 800)
    $L = $St[0]; $R = $St[1]; $n = $L.Length; $rate = $script:WHDSynth.Rate
    # remove any DC / sub-audio drift (a 20 Hz high-pass), so the speaker cone stays centred
    $kdc = [Math]::Exp(-2.0 * [Math]::PI * 20.0 / $rate)
    foreach ($ch in $L, $R) { $px = 0.0; $py = 0.0; for ($i = 0; $i -lt $n; $i++) { $xv = $ch[$i]; $py = $xv - $px + $kdc * $py; $px = $xv; $ch[$i] = $py } }
    $peak = 0.0; for ($i = 0; $i -lt $n; $i++) { $a = [Math]::Max([Math]::Abs($L[$i]), [Math]::Abs($R[$i])); if ($a -gt $peak) { $peak = $a } }
    if ($peak -le 0) { return , $St }
    $rc = 1.0 / (2.0 * [Math]::PI * 300.0); $al = $rc / ($rc + 1.0 / $rate)
    $h1 = 0.0; $h2 = 0.0; $x1 = 0.0; $y1 = 0.0; $sq = 0.0; $cnt = 0; $gate = 0.05 * $peak
    for ($i = 0; $i -lt $n; $i++) {
        $x = 0.5 * ($L[$i] + $R[$i])
        $h1 = $al * ($h1 + $x - $x1); $x1 = $x; $h2 = $al * ($h2 + $h1 - $y1); $y1 = $h1
        if ([Math]::Abs($x) -gt $gate) { $sq += $h2 * $h2; $cnt++ }
    }
    $heard = if ($cnt) { [Math]::Sqrt($sq / $cnt) } else { 0.0 }
    $g = if ($heard -gt 0) { [Math]::Min($script:WHDSynth.Loud / $heard, 1.6 / $peak) } else { 0.8 / $peak }
    $knee = $script:WHDSynth.Knee; $room = $script:WHDSynth.Top - $knee
    $fin = [Math]::Min([int]($rate * 0.004), [int]($n / 4))
    $tail = [Math]::Min($n - 1, [int]((Get-WHDSynthN $TailMs) * 0.4) + 1)
    $oL = [double[]]::new($n); $oR = [double[]]::new($n)
    for ($i = 0; $i -lt $n; $i++) {
        $f = 1.0
        if ($i -lt $fin) { $f = $i / [double]$fin } elseif ($i -ge $n - $tail) { $q = ($n - 1 - $i) / [double]$tail; $f = $q * $q }
        foreach ($side in 0, 1) {
            $v = if ($side) { $R[$i] * $g } else { $L[$i] * $g }
            $av = [Math]::Abs($v)
            if ($av -gt $knee) { $av = $knee + $room * [Math]::Tanh(($av - $knee) / $room); $v = if ($v -lt 0) { -$av } else { $av } }
            if ($side) { $oR[$i] = $v * $f } else { $oL[$i] = $v * $f }
        }
    }
    return , @($oL, $oR)
}

function ConvertTo-WHDWavData {
    # 16-bit stereo PCM .wav as bytes.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([object[]]$St)
    $L = $St[0]; $R = $St[1]; $rate = $script:WHDSynth.Rate; $data = $L.Length * 4
    $ms = [System.IO.MemoryStream]::new(44 + $data); $w = [System.IO.BinaryWriter]::new($ms)
    try {
        $ascii = [System.Text.Encoding]::ASCII
        $w.Write($ascii.GetBytes('RIFF')); $w.Write([int32](36 + $data)); $w.Write($ascii.GetBytes('WAVE'))
        $w.Write($ascii.GetBytes('fmt ')); $w.Write([int32]16); $w.Write([int16]1); $w.Write([int16]2)
        $w.Write([int32]$rate); $w.Write([int32]($rate * 4)); $w.Write([int16]4); $w.Write([int16]16)
        $w.Write($ascii.GetBytes('data')); $w.Write([int32]$data)
        for ($i = 0; $i -lt $L.Length; $i++) {
            foreach ($v in $L[$i], $R[$i]) { $c = [Math]::Max(-1.0, [Math]::Min(1.0, $v)); $w.Write([int16][Math]::Round($c * 32767.0)) }
        }
        $w.Flush(); return , $ms.ToArray()
    } finally { $w.Dispose(); $ms.Dispose() }
}

# ---- the 20 sounds (D64): effects, then the voice part (K = voice), then what follows it -------
# A part without At follows the one before it (+ Gap ms; a negative Gap overlaps).
$script:WHDRoomBig   = @{ Size = 0.92; Damp = 0.28; Wet = 0.26; PreMs = 28 }
$script:WHDRoomMid   = @{ Size = 0.88; Damp = 0.35; Wet = 0.22; PreMs = 18 }
$script:WHDRoomSmall = @{ Size = 0.84; Damp = 0.4;  Wet = 0.18; PreMs = 12 }
$script:WHDThemeSounds = @(
    @{ Name = 'signin'; For = 'you sign in  (power comes up, the ship answers)'; Events = @('task: sign-in'); Line = 'Main power online. All systems standing by. Welcome aboard.'
       Tail = 1500; Room = $script:WHDRoomBig; Score = @(
        @{ K = 'sub'; F = 38; F2 = 55; Ms = 3600; AttackMs = 1200; RelMs = 1600; Vol = 0.3; At = 0 }
        @{ K = 'whoosh'; Ms = 1600; F1 = 180; F2 = 4800; Q = 0.3; AttackMs = 1000; RelMs = 500; Vol = 0.26; Pan = -0.85; Pan2 = 0.85; At = 0 }
        @{ K = 'chatter'; Count = 12; StepMs = 45; Seed = 7; Rise = $true; Vol = 0.22; Pan = -0.7; Pan2 = 0.7; At = 500 }
        @{ K = 'warble'; F = 1200; F2 = 2400; Ms = 260; Vol = 0.2; At = 1050 }
        @{ K = 'pad'; Fs = @('D4', 'A4', 'E5'); Ms = 5600; AttackMs = 1500; RelMs = 2000; Vol = 0.18; Bright = 0.4; At = 900 }
        @{ K = 'voice'; At = 1350 } ) }
    @{ Name = 'signout'; For = 'you sign out'; Events = @('task: sign-out'); Line = 'Crew member signed off. Systems holding.'
       Tail = 1500; Room = $script:WHDRoomBig; Score = @(
        @{ K = 'chatter'; Count = 9; StepMs = 45; Seed = 8; Rise = $true; Low = 3200; High = 1300; Vol = 0.22; Pan = 0.7; Pan2 = -0.7; At = 0 }
        @{ K = 'warble'; F = 2300; F2 = 1100; Ms = 300; Vol = 0.2; At = 380 }
        @{ K = 'pad'; Fs = @('A4', 'E5', 'F#5'); Ms = 4200; AttackMs = 700; RelMs = 2200; Vol = 0.17; Bright = 0.35; At = 300 }
        @{ K = 'voice'; At = 650 }
        @{ K = 'sub'; F = 55; F2 = 36; Ms = 1600; AttackMs = 200; RelMs = 1200; Vol = 0.28; Gap = -300 } ) }
    @{ Name = 'shutdown'; For = 'the PC shuts down  (the ship winds down)'; Events = @('task: shut-down'); Line = 'Power-down sequence engaged. Ship going dark.'
       Tail = 1800; Room = $script:WHDRoomBig; Score = @(
        @{ K = 'warble'; F = 1800; F2 = 1500; Ms = 240; Vol = 0.2; At = 0 }
        @{ K = 'pad'; Fs = @('D4', 'A4', 'C5'); Ms = 3600; AttackMs = 500; RelMs = 2000; Vol = 0.16; Bright = 0.3; At = 150 }
        @{ K = 'voice'; At = 300 }
        @{ K = 'whoosh'; Ms = 2000; F1 = 4500; F2 = 140; Q = 0.3; AttackMs = 150; RelMs = 1400; Vol = 0.26; Pan = 0.8; Pan2 = -0.8; Gap = -200 }
        @{ K = 'chatter'; Count = 7; StepMs = 110; Seed = 9; Rise = $true; Low = 2600; High = 700; Vol = 0.16; Pan = 0.5; Pan2 = -0.5; Gap = -1900 }
        @{ K = 'sub'; F = 60; F2 = 28; Ms = 2400; AttackMs = 100; RelMs = 1700; Vol = 0.34; Gap = -900 }
        @{ K = 'fm'; F = 'A2'; Ratio = 1.0; I1 = 3.0; I2 = 0.0; Ms = 500; AttackMs = 3; DecayMs = 160; RelMs = 300; Vol = 0.35; Gap = -700 } ) }
    @{ Name = 'lock'; For = 'the screen locks'; Events = @('task: lock'); Line = 'Console secured.'
       Tail = 800; Room = $script:WHDRoomMid; Score = @(
        @{ K = 'fm'; F = 'A2'; Ratio = 1.0; I1 = 3.0; I2 = 0.0; Ms = 220; AttackMs = 2; DecayMs = 70; RelMs = 120; Vol = 0.35; At = 0 }
        @{ K = 'chatter'; Count = 3; StepMs = 50; Seed = 10; Rise = $true; Low = 2600; High = 1500; Vol = 0.22; At = 40 }
        @{ K = 'voice'; At = 260 } ) }
    @{ Name = 'unlock'; For = 'the screen unlocks'; Events = @('task: unlock'); Line = 'Access confirmed. Console active.'
       Tail = 800; Room = $script:WHDRoomMid; Score = @(
        @{ K = 'chatter'; Count = 4; StepMs = 45; Seed = 11; Rise = $true; Vol = 0.24; At = 0 }
        @{ K = 'warble'; F = 1400; F2 = 2200; Ms = 180; Vol = 0.2; At = 170 }
        @{ K = 'voice'; At = 380 } ) }
    @{ Name = 'notify'; For = 'a notification'; Events = @('Notification.Default', 'SystemNotification'); Line = 'Incoming notice.'
       Tail = 700; Room = $script:WHDRoomSmall; Score = @(
        @{ K = 'fm'; F = 'E6'; Ratio = 2.0; I1 = 1.8; I2 = 0.2; Ms = 200; AttackMs = 2; DecayMs = 70; RelMs = 90; Vol = 0.4; Pan = -0.25; At = 0 }
        @{ K = 'fm'; F = 'B6'; Ratio = 2.0; I1 = 1.5; I2 = 0.1; Ms = 260; AttackMs = 2; DecayMs = 100; RelMs = 120; Vol = 0.4; Pan = 0.25; At = 95 }
        @{ K = 'voice'; At = 300 } ) }
    @{ Name = 'message'; For = 'a chat or text message'; Events = @('Notification.IM', 'Notification.SMS', 'MessageNudge'); Line = 'Incoming message.'
       Tail = 700; Room = $script:WHDRoomSmall; Score = @(
        @{ K = 'chatter'; Count = 3; StepMs = 55; BlipMs = 40; Seed = 12; Low = 2200; High = 3400; Vol = 0.26; At = 0 }
        @{ K = 'voice'; At = 230 } ) }
    @{ Name = 'mail'; For = 'new e-mail'; Events = @('MailBeep', 'Notification.Mail', 'FaxBeep'); Line = 'Transmission received.'
       Tail = 700; Room = $script:WHDRoomSmall; Score = @(
        @{ K = 'whoosh'; Ms = 300; F1 = 600; F2 = 4000; Q = 0.4; AttackMs = 200; RelMs = 90; Vol = 0.16; Pan = -0.6; Pan2 = 0.3; At = 0 }
        @{ K = 'chatter'; Count = 5; StepMs = 40; Seed = 13; Rise = $true; Vol = 0.22; At = 120 }
        @{ K = 'voice'; At = 380 } ) }
    @{ Name = 'reminder'; For = 'a calendar reminder'; Events = @('Notification.Reminder'); Line = 'Scheduled event approaching.'
       Tail = 800; Room = $script:WHDRoomMid; Score = @(
        @{ K = 'warble'; F = 1500; Ms = 200; RateHz = 14; Depth = 0.08; Vol = 0.22; At = 0 }
        @{ K = 'warble'; F = 1900; Ms = 220; RateHz = 14; Depth = 0.08; Vol = 0.22; At = 240 }
        @{ K = 'voice'; At = 520 } ) }
    @{ Name = 'error'; For = 'an error (critical stop)'; Events = @('SystemHand'); Line = 'Operation failed. Fault detected.'
       Tail = 800; Room = $script:WHDRoomMid; Score = @(
        @{ K = 'fm'; F = 'A3'; Ratio = 1.007; I1 = 4.5; I2 = 2.5; Ms = 160; AttackMs = 4; DecayMs = 0; RelMs = 50; Vol = 0.35; At = 0 }
        @{ K = 'fm'; F = 'F3'; Ratio = 1.007; I1 = 4.5; I2 = 1.5; Ms = 220; AttackMs = 4; DecayMs = 0; RelMs = 120; Vol = 0.35; Gap = 50 }
        @{ K = 'voice'; At = 500 } ) }
    @{ Name = 'warning'; For = 'a warning (exclamation)'; Events = @('SystemExclamation'); Line = 'Caution.'
       Tail = 800; Room = $script:WHDRoomMid; Score = @(
        @{ K = 'warble'; F = 1600; Ms = 130; RateHz = 30; Vol = 0.22; At = 0 }
        @{ K = 'warble'; F = 1250; Ms = 130; RateHz = 30; Vol = 0.22; At = 150 }
        @{ K = 'warble'; F = 1600; Ms = 130; RateHz = 30; Vol = 0.22; At = 300 }
        @{ K = 'warble'; F = 1250; Ms = 160; RateHz = 30; Vol = 0.22; At = 450 }
        @{ K = 'voice'; At = 680 } ) }
    @{ Name = 'info'; For = 'an information box (asterisk)'; Events = @('SystemAsterisk'); Line = 'Information available.'
       Tail = 700; Room = $script:WHDRoomSmall; Score = @(
        @{ K = 'fm'; F = 'A6'; Ratio = 3.0; I1 = 1.4; I2 = 0.1; Ms = 300; AttackMs = 2; DecayMs = 110; RelMs = 150; Vol = 0.35; At = 0 }
        @{ K = 'shimmer'; F = 'A5'; Ms = 600; AttackMs = 40; RelMs = 450; Vol = 0.08; At = 0 }
        @{ K = 'voice'; At = 230 } ) }
    @{ Name = 'beep'; For = 'the plain beep'; Events = @('.Default'); Line = 'Acknowledged.'
       Tail = 600; Room = $script:WHDRoomSmall; Score = @(
        @{ K = 'fm'; F = 'E6'; Ratio = 2.0; I1 = 1.6; I2 = 0.2; Ms = 160; AttackMs = 2; DecayMs = 60; RelMs = 80; Vol = 0.38; At = 0 }
        @{ K = 'voice'; At = 170 } ) }
    @{ Name = 'connect'; For = 'a device is plugged in'; Events = @('DeviceConnect'); Line = 'Device linked.'
       Tail = 700; Room = $script:WHDRoomSmall; Score = @(
        @{ K = 'whoosh'; Ms = 260; F1 = 500; F2 = 4200; Q = 0.4; AttackMs = 180; RelMs = 70; Vol = 0.18; Pan = -0.6; Pan2 = 0.2; At = 0 }
        @{ K = 'chatter'; Count = 3; StepMs = 50; Seed = 14; Rise = $true; Vol = 0.24; At = 120 }
        @{ K = 'voice'; At = 340 } ) }
    @{ Name = 'disconnect'; For = 'a device is removed'; Events = @('DeviceDisconnect'); Line = 'Device released.'
       Tail = 700; Room = $script:WHDRoomSmall; Score = @(
        @{ K = 'whoosh'; Ms = 260; F1 = 4200; F2 = 500; Q = 0.4; AttackMs = 60; RelMs = 180; Vol = 0.18; Pan = 0.2; Pan2 = -0.6; At = 0 }
        @{ K = 'chatter'; Count = 3; StepMs = 50; Seed = 15; Rise = $true; Low = 3000; High = 1300; Vol = 0.24; At = 100 }
        @{ K = 'voice'; At = 330 } ) }
    @{ Name = 'devicefail'; For = 'a device failed to connect'; Events = @('DeviceFail'); Line = 'Device link failed.'
       Tail = 800; Room = $script:WHDRoomMid; Score = @(
        @{ K = 'fm'; F = 'E4'; Ratio = 1.007; I1 = 4.0; I2 = 2.0; Ms = 110; AttackMs = 4; DecayMs = 0; RelMs = 40; Vol = 0.32; At = 0 }
        @{ K = 'fm'; F = 'E4'; Ratio = 1.007; I1 = 4.0; I2 = 2.0; Ms = 110; AttackMs = 4; DecayMs = 0; RelMs = 40; Vol = 0.32; Gap = 50 }
        @{ K = 'fm'; F = 'E4'; F2 = 'B3'; Ratio = 1.007; I1 = 4.0; I2 = 1.0; Ms = 200; AttackMs = 4; DecayMs = 0; RelMs = 90; Vol = 0.32; Gap = 50 }
        @{ K = 'voice'; At = 560 } ) }
    @{ Name = 'uac'; For = 'Windows asks for administrator permission'; Events = @('WindowsUAC'); Line = 'Command authorization required.'
       Tail = 900; Room = $script:WHDRoomMid; Score = @(
        @{ K = 'chatter'; Count = 6; StepMs = 38; Seed = 4; Rise = $true; Vol = 0.28; At = 0 }
        @{ K = 'warble'; F = 1500; F2 = 2100; Ms = 200; Vol = 0.22; At = 250 }
        @{ K = 'voice'; At = 480 } ) }
    @{ Name = 'batterylow'; For = 'the battery is low'; Events = @('LowBatteryAlarm'); Line = 'Power reserves low.'
       Tail = 800; Room = $script:WHDRoomMid; Score = @(
        @{ K = 'warble'; F = 1400; F2 = 900; Ms = 380; RateHz = 9; Depth = 0.06; Vol = 0.22; At = 0 }
        @{ K = 'voice'; At = 420 } ) }
    @{ Name = 'batterycritical'; For = 'the battery is almost empty'; Events = @('CriticalBatteryAlarm'); Line = 'Warning. Power reserves critical.'
       Tail = 900; Room = $script:WHDRoomMid; Score = @(
        @{ K = 'warble'; F = 1700; Ms = 150; RateHz = 34; Depth = 0.14; Vol = 0.24; At = 0 }
        @{ K = 'warble'; F = 1700; Ms = 150; RateHz = 34; Depth = 0.14; Vol = 0.24; At = 200 }
        @{ K = 'warble'; F = 1700; F2 = 1100; Ms = 240; RateHz = 34; Depth = 0.14; Vol = 0.24; At = 400 }
        @{ K = 'sub'; F = 50; F2 = 40; Ms = 700; AttackMs = 20; RelMs = 450; Vol = 0.25; At = 0 }
        @{ K = 'voice'; At = 720 } ) }
    @{ Name = 'proximity'; For = 'a nearby device (tap / proximity)'; Events = @('Notification.Proximity', 'ProximityConnection'); Line = 'Contact in range.'
       Tail = 700; Room = $script:WHDRoomSmall; Score = @(
        @{ K = 'fm'; F = 840; F2 = 1680; Ratio = 2.0; I1 = 1.2; I2 = 0.3; Ms = 170; AttackMs = 4; DecayMs = 0; RelMs = 50; Vol = 0.32; Pan = -0.4; At = 0 }
        @{ K = 'fm'; F = 'F6'; Ratio = 2.0; I1 = 1.4; I2 = 0.1; Ms = 200; AttackMs = 2; DecayMs = 80; RelMs = 100; Vol = 0.35; Pan = 0.4; At = 200 }
        @{ K = 'voice'; At = 400 } ) }
)

# Windows sound event (app ".Default") -> our sound, and the 20 names in playing order (used by Theme.ps1).
$script:WHDThemeSoundEvents = [ordered]@{}
foreach ($snd in $script:WHDThemeSounds) { foreach ($ev in $snd.Events) { if ($ev -notlike 'task:*') { $script:WHDThemeSoundEvents[$ev] = $snd.Name } } }
$script:WHDThemeSoundNames = @($script:WHDThemeSounds | ForEach-Object { $_.Name })

# ---- the voice: Windows' own offline speech (SAPI), the voice Zira (D66, D67) ------------------------
function Get-WHDThemeVoiceToken {
    # The Windows speech voice whose name contains $script:WHDThemeVoiceName, or $null (none / no speech here).
    [CmdletBinding()]
    [OutputType([object])]
    param($Speaker)
    foreach ($t in @($Speaker.GetVoices())) { if ([string]$t.GetDescription() -match $script:WHDThemeVoiceName) { return $t } }
    return $null
}
function New-WHDThemeVoiceSpeaker {
    # Windows' speech component (COM "SAPI.SpVoice"); $null when this PC has none.
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object])]
    param()
    if (-not $PSCmdlet.ShouldProcess('SAPI.SpVoice', 'open Windows speech')) { return $null }
    try { return (New-Object -ComObject SAPI.SpVoice) } catch { return $null }
}
function Save-WHDThemeVoiceLine {
    # Records one line with the voice into a 22 kHz 16-bit mono .wav.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Speaker, [Parameter(Mandatory)]$Token, [Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Path)
    if (-not $PSCmdlet.ShouldProcess($Path, 'record the voice')) { return }
    $fs = New-Object -ComObject SAPI.SpFileStream
    try {
        try { $fmt = New-Object -ComObject SAPI.SpAudioFormat; $fmt.Type = 22; $fs.Format = $fmt } catch { Write-Verbose ('voice format left as the voice gives it: {0}' -f $_.Exception.Message) }
        $fs.Open($Path, 3, $false)                       # 3 = create for writing
        $Speaker.AudioOutputStream = $fs
        $Speaker.Voice = $Token
        $Speaker.Rate = 0
        [void]$Speaker.Speak($Text)
    } finally {
        try { $fs.Close() } catch { Write-Verbose ('close: {0}' -f $_.Exception.Message) }
        try { $Speaker.AudioOutputStream = $null } catch { Write-Verbose ('release: {0}' -f $_.Exception.Message) }
    }
}
function Invoke-WHDThemeVoiceRecord {
    # Records the 20 lines with Zira into $Dir. Returns @{ name = path } (empty when there is no Zira) and
    # the voice's full name in .Voice.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Dir)
    $out = @{ Voice = ''; Files = @{} }
    $sp = New-WHDThemeVoiceSpeaker -Confirm:$false
    if ($null -eq $sp) { return $out }
    $tok = Get-WHDThemeVoiceToken -Speaker $sp
    if ($null -eq $tok) { return $out }
    $out.Voice = [string]$tok.GetDescription()
    if (-not (Test-Path -LiteralPath $Dir)) { [void](New-Item -ItemType Directory -Path $Dir -Force -ErrorAction Stop) }
    foreach ($s in $script:WHDThemeSounds) {
        $p = [System.IO.Path]::Combine($Dir, ('{0}.wav' -f $s.Name))
        try { Save-WHDThemeVoiceLine -Speaker $sp -Token $tok -Text $s.Line -Path $p -Confirm:$false; if (Test-Path -LiteralPath $p) { $out.Files[$s.Name] = $p } }
        catch { Write-Verbose ('voice line {0} not recorded: {1}' -f $s.Name, $_.Exception.Message) }
    }
    return $out
}

function Get-WHDThemeSound {
    # One finished sound (stereo: @(L, R)) by name. Pitch moves the effects only; VoicePath = the recorded
    # line (none = the sound without its voice, D67).
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$Name, [double]$Pitch = 0.5, [string]$VoicePath)
    $s = @($script:WHDThemeSounds | Where-Object { $_.Name -eq $Name } | Select-Object -First 1)
    if (-not $s.Count) { throw ('unknown sound: {0}' -f $Name) }
    $keep = $script:WHDSynth.Pitch
    $script:WHDSynth.Pitch = $Pitch
    try {
        $parts = @(foreach ($p in $s[0].Score) {
            if ($p.K -ne 'voice') { $p; continue }
            if ($VoicePath -and (Test-Path -LiteralPath $VoicePath)) { $q = @{} + $p; $q.Path = $VoicePath; $q }
        })
        $st = Invoke-WHDSynthScore -Parts $parts -Room $s[0].Room -TailMs $s[0].Tail
        return , (ConvertTo-WHDSynthLevel -St $st -TailMs $s[0].Tail)
    } finally { $script:WHDSynth.Pitch = $keep }
}
