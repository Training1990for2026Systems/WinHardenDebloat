#requires -Version 7.6
<#
 WHD Next 3.0  -  Private/Journal.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 The change history. SAME FORMAT AS WHD NEXT 2.0 (D4 - takes over its history):
   restore\<session>\journal.jsonl   one JSON line per change
   restore\<session>\machine.json    which PC the session belongs to
 Fields: Id, Time, Session, Kind, Description, MachineId, Computer, then the
 change's own data (e.g. Kind 'reg': Path, Name, OldKeyExists, OldExists,
 OldValue, OldType, NewExists, NewValue, NewType). A change that cannot be
 recorded has no Undo and no Verify, so the first failed write stops the run.
#>
$script:WHDMachineIdCache = $null

function Get-WHDMachineId {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($script:WHDMachineIdCache) { return $script:WHDMachineIdCache }
    $g = $null
    try { $g = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid } catch { $g = $null }
    if (-not $g) { $g = 'name:{0}' -f [Environment]::MachineName }
    $script:WHDMachineIdCache = $g.ToLowerInvariant()
    return $script:WHDMachineIdCache
}

function Add-WHDJournalLine {
    # Appends one line; a file held for a moment by antivirus / sync is tried again.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][string]$Line)
    $last = $null
    for ($i = 1; $i -le 8; $i++) {
        try { Add-Content -LiteralPath $File -Value $Line -Encoding utf8 -ErrorAction Stop; return }
        catch { $last = $_; Start-Sleep -Milliseconds (150 * $i) }
    }
    throw $last
}

function Add-WHDJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Description, [hashtable]$Data)
    $s = $script:WHDState
    $folder = Get-WHDRestoreFolder
    $file = Join-Path $folder 'journal.jsonl'
    $line = ''
    try {
        if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop) }
        $rec = [ordered]@{
            Id = [guid]::NewGuid().ToString('N').Substring(0, 10); Time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            Session = $s.Stamp; Kind = 'action'; Description = $Description
            MachineId = (Get-WHDMachineId); Computer = [Environment]::MachineName
        }
        if ($Data) { foreach ($k in $Data.Keys) { $rec[$k] = $Data[$k] } }
        if ($s.Undoing) { $rec['ByUndo'] = $true }
        foreach ($k in 'OldValue', 'NewValue') { if ($rec.Contains($k) -and $rec[$k] -is [byte[]]) { $rec[$k] = @($rec[$k] | ForEach-Object { [int]$_ }) } }
        $line = [pscustomobject]$rec | ConvertTo-Json -Compress -Depth 4
        $mf = Join-Path $folder 'machine.json'
        if (-not (Test-Path -LiteralPath $mf)) {
            [pscustomobject][ordered]@{ MachineId = (Get-WHDMachineId); Computer = [Environment]::MachineName; Claimed = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } |
                ConvertTo-Json -Compress | Set-Content -LiteralPath $mf -Encoding utf8 -ErrorAction Stop
        }
        Add-WHDJournalLine -File $file -Line $line
    } catch {
        Register-WHDJournalStop -Description $Description -Reason $_.Exception.Message -File $file -Line $line
    }
}

function Register-WHDJournalStop {
    [CmdletBinding()]
    param([string]$Description, [string]$Reason, [string]$File, [string]$Line)
    $s = $script:WHDState
    if ($s.JournalStop) { return }
    $s.JournalStop = [pscustomobject]@{ Time = (Get-Date); Description = $Description; Reason = $Reason; File = $File; Line = $Line }
    $s.Execute = $false
    Write-WHDLog -Message 'STOPPED - the change history could not be written. EXECUTE is now OFF; nothing else is changed in this run.' -Level 'ERR'
    Write-WHDLog -Message ('  change that WAS made but is not recorded: {0}' -f $Description) -Level 'ERR'
    Write-WHDLog -Message ('  reason: {0}' -f $Reason) -Level 'ERR'
    Write-WHDLog -Message ('  file: {0}' -f $File) -Level 'ERR'
    if ($Line) { Write-WHDLog -Message ('  the record (keep it to undo by hand): {0}' -f $Line) -Level 'ERR' }
}
