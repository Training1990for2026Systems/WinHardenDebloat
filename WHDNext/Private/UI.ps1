#requires -Version 7.6
<#
 WHD Next 3.0  -  Private/UI.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 Small screen helpers shared by every menu: the risk label, the mode line,
 the common menu keys (X = EXECUTE on/off, S = safe mode on/off, D14) and a
 "state of a group of registry values" reader.
#>
$script:WHDMenuCapture = $false      # $true while the window reads a menu screen (build step 6b)

function Write-WHDRisk {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('reversible', 'caution', 'hard')][string]$Tier, [Parameter(Mandatory)][string]$Text)
    $color = @{ reversible = 'Green'; caution = 'Yellow'; hard = 'Red' }[$Tier]
    Write-Host ('    [{0}] ' -f $Tier.ToUpperInvariant()) -ForegroundColor $color -NoNewline
    Write-Host $Text
    Write-WHDLog -Message ('    [{0}] {1}' -f $Tier.ToUpperInvariant(), $Text) -FileOnly
}

function Show-WHDMode {
    [CmdletBinding()]
    param()
    $st = $script:WHDState
    Write-Host ''
    if ($st.SafeMode) {
        Write-Host ('  ### {0} ###' -f (Get-WHDModeText)) -ForegroundColor Yellow
        if ($st.Execute) { Write-Host '  *** EXECUTE is ON for Undo / re-apply / re-remove / restore points only. New changes stay previews. ***' -ForegroundColor Red }
        else { Write-Host '  --- DRY-RUN - nothing changes; actions are only previewed. ---' -ForegroundColor Cyan }
    } elseif ($st.Execute) {
        Write-Host '  *** EXECUTE MODE - changes WILL be applied (each one asks first; restore point before the first) ***' -ForegroundColor Red
    } else {
        Write-Host '  --- DRY-RUN MODE - nothing changes; actions are only previewed ---' -ForegroundColor Cyan
    }
    if ($st.JournalStop) { Write-Host '  !!! STOPPED: the change history could not be written. No changes until WHD is started again. !!!' -ForegroundColor Red }
}

function Write-WHDMenuCommonKey {
    [CmdletBinding()]
    param()
    if ($script:WHDMenuCapture) { return }        # the window has its own switches
    $st = $script:WHDState
    Write-Host ('   X. EXECUTE {0}    S. Safe mode {1}    B. Back' -f $(if ($st.Execute) { 'OFF (back to dry-run)' } else { 'ON' }), $(if ($st.SafeMode) { 'OFF' } else { 'ON' })) -ForegroundColor DarkGray
}

function Invoke-WHDMenuCommonKey {
    # Handles X and S in any menu. Returns $true when the key was one of them.
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Choice)
    switch -regex ($Choice) {
        '^[Xx]$' { [void](Set-WHDMode -Execute (-not $script:WHDState.Execute)); return $true }
        '^[Ss]$' { [void](Set-WHDMode -SafeMode (-not $script:WHDState.SafeMode)); return $true }
    }
    return $false
}

function Write-WHDProgressStep {
    # Progress for long jobs (e.g. deleting hundreds of firewall rules): bar on screen, a log line every N.
    [CmdletBinding()]
    param([string]$Activity, [int]$Done, [int]$Total, [int]$Every = 25)
    Write-Progress -Activity $Activity -Status ('{0} of {1}' -f $Done, $Total) -PercentComplete ([math]::Min(100, [int](100 * $Done / [math]::Max(1, $Total))))
    if ($Done -ge $Total) { Write-Progress -Activity $Activity -Completed }
    if ($Done -ge $Total -or ($Every -gt 0 -and ($Done % $Every) -eq 0)) { Write-WHDLog -Message ('  {0}: {1} of {2}' -f $Activity, $Done, $Total) }
}

function Write-WHDMenuItem {
    # One aligned menu row: key (cyan) + label (+ grey hint).
    [CmdletBinding()]
    param([string]$Key, [string]$Label, [string]$Hint = '', [switch]$Later)
    if ($script:WHDMenuCapture) {
        # the window (build step 6b) reads the menu: the item goes out as one record, in order with the text
        Write-Information -MessageData ([pscustomobject]@{ WHDItem = $true; Key = $Key; Label = $Label; Hint = $Hint; Later = [bool]$Later }) -InformationAction Continue
        return
    }
    if ($Later) { Write-Host ('    {0,-3} {1}  {2}' -f $Key, $Label, $(if ($Hint) { $Hint } else { '(later part of build step 5)' })) -ForegroundColor DarkGray; return }
    Write-Host ('    {0,-3} ' -f $Key) -ForegroundColor Cyan -NoNewline
    Write-Host $Label -NoNewline
    if ($Hint) { Write-Host ('  {0}' -f $Hint) -ForegroundColor DarkGray } else { Write-Host '' }
}

function Get-WHDRegOpsState {
    # A group of registry values (@{P;N;V;T}): 'set' (all as wanted) | 'partly' | 'not set' | 'n/a'. Read-only.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyCollection()][object[]]$Ops)
    $ops = @($Ops | Where-Object { $_ })
    if (-not $ops.Count) { return 'n/a' }
    $hit = 0
    foreach ($op in $ops) {
        $t = if ($op.T) { [string]$op.T } else { 'DWord' }
        $rs = Get-WHDRegValueState -Path ([string]$op.P) -Name ([string]$op.N)
        if ($rs.Exists -and (Test-WHDRegValueEqual -A $rs.Value -B $op.V -Type $t)) { $hit++ }
    }
    if ($hit -eq $ops.Count) { return 'set' }
    if ($hit -gt 0) { return 'partly' }
    return 'not set'
}

function ConvertFrom-WHDSelection {
    # "1,3 5-7" -> sorted unique numbers within 1..Max; * = the recommended set (-Star);
    # $null when the text is not understood (pure).
    [CmdletBinding()]
    [OutputType([int[]], [object[]])]
    param([string]$Text, [Parameter(Mandatory)][int]$Max, [int[]]$Star = @())
    $t = ([string]$Text).Trim()
    if (-not $t) { return $null }
    $set = [System.Collections.Generic.SortedSet[int]]::new()
    foreach ($tok in @($t -split '[,\s]+' | Where-Object { $_ })) {
        if ($tok -match '^(\d+)-(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            if ($a -gt $b) { $a, $b = $b, $a }
            if ($a -lt 1 -or $b -gt $Max) { return $null }
            for ($n = $a; $n -le $b; $n++) { [void]$set.Add($n) }
        } elseif ($tok -eq '*') { foreach ($st in $Star) { if ($st -ge 1 -and $st -le $Max) { [void]$set.Add($st) } }
        } elseif ($tok -match '^\d+$' -and [int]$tok -ge 1 -and [int]$tok -le $Max) { [void]$set.Add([int]$tok) }
        else { return $null }
    }
    return , [int[]]@($set)   # always an array, also for one number
}

function Write-WHDParts {
    # One screen line in several colors: plain strings and @('text', 'Color') pairs.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'It writes several parts of one line.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Parts)
    foreach ($p in $Parts) {
        if ($p -is [array]) { Write-Host ([string]$p[0]) -ForegroundColor ([string]$p[1]) -NoNewline }
        else { Write-Host ([string]$p) -NoNewline }
    }
    Write-Host ''
}
