#requires -Version 7.6
<#
================================================================================
 WHD Next 3.0  -  WHDNext.psm1   (module loader)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Loads the module parts. Refuses to load on anything that is not PowerShell 7.6
 or a newer STABLE version of the Core edition (preview / release-candidate
 builds are refused). Folders: Private (engine), Public (commands the menus
 call), Features (the hardening areas). Only Public commands are exported.
================================================================================
#>
Set-StrictMode -Version 3.0

# 1. The engine check comes first, before anything else is loaded.
. (Join-Path $PSScriptRoot 'Private/Test-WHDEngine.ps1')
$engineCheck = Test-WHDEngine -Version $PSVersionTable.PSVersion -Edition $PSVersionTable.PSEdition
if (-not $engineCheck.Ok) {
    throw ('WHD Next 3.0 cannot load: {0}' -f $engineCheck.Reason)
}

# 2. Load every part. Private and Features stay inside the module.
$publicNames = [System.Collections.Generic.List[string]]::new()
foreach ($folder in 'Private', 'Features', 'Public') {
    $path = Join-Path $PSScriptRoot $folder
    if (-not (Test-Path -LiteralPath $path)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $path -Filter '*.ps1' -File | Sort-Object Name) {
        if ($file.Name -eq 'Test-WHDEngine.ps1') { continue }   # already loaded above
        . $file.FullName
        if ($folder -eq 'Public') { $publicNames.Add($file.BaseName) }
    }
}

# 3. A fresh session state (dry-run) until Initialize-WHDSession is called.
Initialize-WHDState

# 4. Export only the Public commands (one command per file, file name = command name).
Export-ModuleMember -Function $publicNames
