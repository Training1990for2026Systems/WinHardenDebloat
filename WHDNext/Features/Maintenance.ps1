#requires -Version 7.6
<#
================================================================================
 WHD Next 3.0  -  Features/Maintenance.ps1   (component store / WinSxS)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Same features as WHD Next 2.0 (D8), rewritten for PowerShell 7.6. Build step
 5.7. Keys as 2.0 (D48): A analyze (read-only), C cleanup, R cleanup + ResetBase.
 Reclaims space only the SUPPORTED way - Windows' own DISM. Nothing here ever
 deletes files inside WinSxS by hand (that breaks Windows servicing).
   A  /AnalyzeComponentStore           read-only: the real reclaimable size
   C  /StartComponentCleanup           removes superseded components; installed
                                       updates can still be uninstalled
   R  /StartComponentCleanup /ResetBase removes ALL superseded components; installed
                                       updates can NEVER be uninstalled again and a
                                       restore point does not undo it - the word
                                       RESETBASE must be typed (D49)
 DISM output is shown live; its text lines go to the log (progress bars only on
 screen). The update guard from 2.0's Maintenance file is build step 7 (D48).
================================================================================
#>

function Invoke-WHDDism {
    # Runs dism.exe, shows its output live, logs the text lines (not the progress bars). Returns the exit code.
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string[]]$ArgList)
    Write-WHDLog -Message ('DISM {0}' -f ($ArgList -join ' '))
    $code = 0
    try {
        & dism.exe @ArgList 2>&1 | ForEach-Object {
            $line = ([string]$_).TrimEnd()
            if (-not $line) { return }
            if ($line -match '^\s*\[[=\s\d.%]*\]\s*$') { Write-Host ('    {0}' -f $line.Trim()) -ForegroundColor DarkGray; return }   # progress bar
            Write-WHDLog -Message ('    {0}' -f $line.Trim())
        }
        $code = $LASTEXITCODE
    } catch {
        Write-WHDLog -Message ('DISM could not run: {0}' -f $_.Exception.Message) -Level 'ERR'
        $code = 1
    }
    return [int]$code
}

function Invoke-WHDComponentAnalyze {
    # A: read-only - runs in dry-run and safe mode too.
    [CmdletBinding()]
    param()
    Write-WHDLog -Message 'MAINTENANCE A: component store analysis (read-only)' -Level 'ACT'
    if (-not $script:WHDState.IsAdmin) { Write-WHDLog -Message 'DISM needs an administrator window - start WHD as administrator.' -Level 'WARN'; return }
    $code = Invoke-WHDDism -ArgList @('/Online', '/Cleanup-Image', '/AnalyzeComponentStore')
    if ($code -ne 0) { Write-WHDLog -Message ('DISM ended with code {0}.' -f $code) -Level 'WARN' }
    else { Write-WHDLog -Message 'Analysis done. "Component Store Cleanup Recommended : Yes" means C would free space.' -Level 'OK' }
}

function Invoke-WHDComponentCleanup {
    # C (and R with -ResetBase). R needs RESETBASE typed when the run is real (D49). -Answer feeds that word (tests).
    [CmdletBinding()]
    param([switch]$ResetBase, [string[]]$Answer)
    $mcArgs = @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
    $label = 'StartComponentCleanup'
    if ($ResetBase) { $mcArgs += '/ResetBase'; $label = 'StartComponentCleanup /ResetBase' }
    Write-WHDLog -Message ('MAINTENANCE {0}: {1}' -f $(if ($ResetBase) { 'R' } else { 'C' }), $label) -Level 'ACT'
    if ($ResetBase) {
        Write-WHDRisk -Tier 'hard' -Text 'ResetBase removes ALL superseded components. After this, the Windows updates already installed can NEVER be uninstalled, and a restore point does not undo it. Use A first to see what C alone would free.'
    } else {
        Write-WHDRisk -Tier 'reversible' -Text 'Removes only superseded components - Windows'' supported cleanup. Installed updates can still be uninstalled. Can take several minutes.'
    }
    if (-not $script:WHDState.IsAdmin) { Write-WHDLog -Message 'DISM needs an administrator window - start WHD as administrator.' -Level 'WARN'; return }
    if ($ResetBase -and (Test-WHDRealChange)) {
        $word = ([string](Read-WHDMenuAnswer -Answer $Answer -Prompt '  Type RESETBASE to go ahead (anything else cancels)')).Trim()
        if ($word -cne 'RESETBASE') { Write-WHDLog -Message 'skipped (RESETBASE was not typed).' -Level 'WARN'; return }
    } elseif (-not (Confirm-WHDProceed -What ('run DISM {0}' -f $label))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    $mcHint = if ($ResetBase) { 'cannot be undone: superseded components are gone and installed updates can no longer be uninstalled' } else { 'nothing to undo: only superseded components were removed (installed updates can still be uninstalled)' }
    Invoke-WHDChange -Description ('DISM {0}' -f $label) -Journal @{ Kind = 'action'; Hint = $mcHint } -Action {
        $mcCode = Invoke-WHDDism -ArgList $mcArgs
        if ($mcCode -eq 3010) { Write-WHDLog -Message '  DISM asks for a restart to finish.' -Level 'WARN' }
        elseif ($mcCode -ne 0) { throw ('DISM exit {0}' -f $mcCode) }
    } | Out-Null
}

# ---- menu -----------------------------------------------------------------------------------------
function Show-WHDMaintenanceMenu {
    [CmdletBinding()]
    param()
    Write-Host ''
    Write-Host '  =============== MAINTENANCE - component store (WinSxS) ===============' -ForegroundColor White
    Write-Host '  Reclaims space the supported way (Windows'' DISM). Never deletes WinSxS files by hand.' -ForegroundColor DarkGray
    Write-WHDMenuItem -Key 'A' -Label 'Analyze the component store (read-only - real reclaimable size)'
    Write-WHDMenuItem -Key 'C' -Label 'Clean up superseded components (safe; updates stay uninstallable)'
    Write-WHDMenuItem -Key 'R' -Label 'Clean up + ResetBase (most space; updates can NEVER be uninstalled)' -Hint '[type RESETBASE]'
    Write-WHDMenuCommonKey
}

function Invoke-WHDMaintenanceChoice {
    # One menu choice. Returns $false for B (back). -Answer feeds the RESETBASE question (tests).
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Choice, [string[]]$Answer)
    $c = $Choice.Trim()
    if (Invoke-WHDMenuCommonKey -Choice $c) { return $true }
    switch -regex ($c) {
        '^[Bb]$' { return $false }
        '^[Aa]$' { Invoke-WHDComponentAnalyze }
        '^[Cc]$' { Invoke-WHDComponentCleanup }
        '^[Rr]$' { Invoke-WHDComponentCleanup -ResetBase -Answer $Answer }
        default { Write-Host '  invalid.' -ForegroundColor Yellow }
    }
    return $true
}
