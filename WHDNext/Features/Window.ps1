#requires -Version 7.6
<#
================================================================================
 WHD Next 3.0  -  Features/Window.ps1   (build step 6b, D82, D83)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 What the window shows and does - kept apart from the WPF code
 (Public\Show-WHDWindow.ps1) so it can be tested without a screen.
   Tabs           the same as WHD Next 2.0's window (D82), plus Devices and
                  Time & region (their own tabs in 3.0); Profiles comes in the
                  Profiles step.
   Each tab (D83) one button per menu item - the SAME items, labels and groups
                  as the console menu, read from the menu itself, so the two
                  can never differ - the module's status text beside them
                  (read again after each action) and a box for list choices
                  (AI "1,3 r", Win32 "5", Undo center "2" ...).
   Actions        run the console menu's own choice (one code path for both);
                  their screen text goes to the window's log pane; questions
                  come up as Yes / No or input dialogs.
================================================================================
#>

# key -> another tab instead of the console's nested menu
$script:WHDWindowTabs = @(
    @{ Header = 'Firewall';        Show = { Show-WHDFirewallMenu };    Do = { param($c) Invoke-WHDFirewallChoice -Choice $c };    Jump = @{ 'Z' = 'Time & region' } }
    @{ Header = 'Updates';         Show = { Show-WHDUpdatesMenu };     Do = { param($c) Invoke-WHDUpdatesChoice -Choice $c } }
    @{ Header = 'Security+';       Show = { Show-WHDSecurityMenu };    Do = { param($c) Invoke-WHDSecurityChoice -Choice $c };    Items = 'Security' }
    @{ Header = 'AI';              Show = { Show-WHDAiMenu };          Do = { param($c) Invoke-WHDAiChoice -Choice $c } }
    @{ Header = 'General';         Show = { Show-WHDGeneralMenu };     Do = { param($c) Invoke-WHDGeneralChoice -Choice $c };     Jump = @{ 'M' = 'Privacy' } }
    @{ Header = 'Privacy';         Show = { Show-WHDPrivacyMenu };     Do = { param($c) Invoke-WHDPrivacyChoice -Choice $c };     Items = 'Privacy' }
    @{ Header = 'Permissions';     Show = { Show-WHDPermissionsMenu }; Do = { param($c) Invoke-WHDPermissionsChoice -Choice $c } }
    @{ Header = 'Win32';           Show = { Show-WHDWin32Menu };       Do = { param($c) Invoke-WHDWin32Choice -Choice $c } }
    @{ Header = 'Devices';         Show = { Show-WHDDevicesMenu };     Do = { param($c) Invoke-WHDDevicesChoice -Choice $c } }
    @{ Header = 'Time & region';   Show = { Show-WHDTimeRegionMenu };  Do = { param($c) Invoke-WHDTimeRegionChoice -Choice $c } }
    @{ Header = 'Component store'; Show = { Show-WHDMaintenanceMenu }; Do = { param($c) Invoke-WHDMaintenanceChoice -Choice $c } }
    @{ Header = 'Theme';           Show = { Show-WHDThemeMenu };       Do = { param($c) Invoke-WHDThemeChoice -Choice $c } }
    @{ Header = 'Profiles';        Show = { Show-WHDProfilesMenu };    Do = { param($c) Invoke-WHDProfilesChoice -Choice $c } }
    @{ Header = 'Inventory / Undo'; Show = { Show-WHDUndoCenterMenu }; Do = { param($c) Invoke-WHDUndoCenterChoice -Choice $c }; Items = 'Tools' }
)

# Buttons for the menus that are not drawn with Write-WHDMenuItem (same keys and words as their screens).
$script:WHDWindowItems = @{
    'Security' = @(
        @{ Group = 'Report'; Key = 'R'; Label = 'Security report (read-only)' }
        @{ Group = 'Defender'; Key = '1'; Label = 'Block unwanted apps (PUA) -> ON' }
        @{ Group = 'Defender'; Key = '2'; Label = 'Network protection -> AUDIT' }
        @{ Group = 'Defender'; Key = '2B'; Label = 'Network protection -> BLOCK' }
        @{ Group = 'Defender'; Key = '3'; Label = 'Ransomware folder protection -> AUDIT' }
        @{ Group = 'Defender'; Key = '3B'; Label = 'Ransomware folder protection -> BLOCK' }
        @{ Group = 'Attack-surface rules (start in AUDIT)'; Key = '4'; Label = 'Microsoft standard 3' }
        @{ Group = 'Attack-surface rules (start in AUDIT)'; Key = '5'; Label = 'Script + download' }
        @{ Group = 'Attack-surface rules (start in AUDIT)'; Key = '6'; Label = 'Office / Adobe / email' }
        @{ Group = 'Attack-surface rules (start in AUDIT)'; Key = 'L'; Label = 'List ASR rules + state' }
        @{ Group = 'Attack-surface rules (start in AUDIT)'; Key = 'E'; Label = 'What they caught (events, 7 days)' }
        @{ Group = 'Attack-surface rules (start in AUDIT)'; Key = 'K'; Label = 'Switch all audited ASR rules to BLOCK' }
        @{ Group = 'Old network protocols (turn off)'; Key = 'P1'; Label = 'LLMNR (link-local name lookup)' }
        @{ Group = 'Old network protocols (turn off)'; Key = 'P2'; Label = 'NetBIOS over TCP/IP (all adapters)' }
        @{ Group = 'Old network protocols (turn off)'; Key = 'P3'; Label = 'WPAD proxy auto-discovery' }
        @{ Group = 'Old network protocols (turn off)'; Key = 'P4'; Label = 'Remote Assistance' }
        @{ Group = 'Old network protocols (turn off)'; Key = 'PA'; Label = 'All four' }
        @{ Group = 'Network services (turn off; restart after)'; Key = 'N1'; Label = 'Workstation + Server (file / printer sharing)' }
        @{ Group = 'Network services (turn off; restart after)'; Key = 'N2'; Label = 'SMB 1/2/3 protocol (server + client)' }
        @{ Group = 'Network services (turn off; restart after)'; Key = 'N3'; Label = 'Dial-up + built-in VPN (RAS, SSTP, Telephony)' }
        @{ Group = 'Network services (turn off; restart after)'; Key = 'N4'; Label = 'IPsec VPN keying (IKEEXT, PolicyAgent)' }
        @{ Group = 'Network services (turn off; restart after)'; Key = 'N5'; Label = 'Proxy auto-detect: Settings switch only' }
        @{ Group = 'Network services (turn off; restart after)'; Key = 'N6'; Label = 'Fax + Phone service' }
        @{ Group = 'Network services (turn off; restart after)'; Key = 'N7'; Label = 'WinHTTP proxy SERVICE off - TEST ONLY' }
        @{ Group = 'Network services (turn off; restart after)'; Key = 'NA'; Label = 'All safe ones (N1-N6; N7 never included)' }
        @{ Group = 'Account'; Key = 'U'; Label = 'UAC -> Always notify' }
        @{ Group = 'Account'; Key = 'W'; Label = 'Password + lockout rules' }
        @{ Group = 'PowerShell'; Key = 'T'; Label = 'PowerShell 7 telemetry off (machine-wide; watched)' }
    )
    'Privacy' = @(
        @{ Group = 'More privacy settings'; Key = 'A'; Label = 'Apply all' }
    )
    'Tools' = @(
        @{ Group = 'Inventory (read-only)'; Key = 'M:1'; Label = 'Run the inventory' }
        @{ Group = 'Inventory (read-only)'; Key = 'M:D'; Label = 'Compare the two newest scans' }
        @{ Group = 'Check and protect'; Key = 'M:V'; Label = 'Verify every recorded change (then re-apply / re-remove)' }
        @{ Group = 'Check and protect'; Key = 'PLAN'; Label = 'Full dry-run plan of everything (changes nothing)' }
        @{ Group = 'Update guard (alert only)'; Key = 'G:1'; Label = 'Install / refresh the guard' }
        @{ Group = 'Update guard (alert only)'; Key = 'G:2'; Label = 'Check now (read-only)' }
        @{ Group = 'Update guard (alert only)'; Key = 'G:3'; Label = 'Open the last report' }
        @{ Group = 'Update guard (alert only)'; Key = 'G:4'; Label = 'Remove the guard' }
    )
}

# ---- reading a menu screen ------------------------------------------------------------------------------------------
function ConvertFrom-WHDWindowRecord {
    # Information records of one menu screen -> text lines (with colour) and items, in order. Write-Host pieces written
    # with -NoNewline are joined into one line.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([AllowEmptyCollection()][object[]]$Records)
    $out = [System.Collections.Generic.List[object]]::new()
    $buf = ''; $col = ''
    foreach ($r in $Records) {
        $d = if ($r -is [System.Management.Automation.InformationRecord]) { $r.MessageData } else { $r }
        if ($d -is [pscustomobject] -and $d.PSObject.Properties['WHDItem']) {
            if ($buf) { $out.Add([pscustomobject]@{ Type = 'text'; Text = $buf; Color = $col }); $buf = '' }
            $out.Add([pscustomobject]@{ Type = 'item'; Key = [string]$d.Key; Label = [string]$d.Label; Hint = [string]$d.Hint; Later = [bool]$d.Later })
            continue
        }
        if ($d -is [System.Management.Automation.HostInformationMessage]) {
            if (-not $buf) { $col = [string]$d.ForegroundColor }
            $buf += [string]$d.Message
            if (-not $d.NoNewLine) { $out.Add([pscustomobject]@{ Type = 'text'; Text = $buf; Color = $col }); $buf = '' }
            continue
        }
        if ($buf) { $out.Add([pscustomobject]@{ Type = 'text'; Text = $buf; Color = $col }); $buf = '' }
        $out.Add([pscustomobject]@{ Type = 'text'; Text = [string]$d; Color = '' })
    }
    if ($buf) { $out.Add([pscustomobject]@{ Type = 'text'; Text = $buf; Color = $col }) }
    return , $out.ToArray()
}
function Get-WHDWindowModel {
    # One tab: Status (text lines), Groups (title + buttons). Read-only: only draws the menu screen.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Tab)
    $prev = $script:WHDMenuCapture
    $script:WHDMenuCapture = $true
    $recs = [System.Collections.Generic.List[object]]::new()
    $failed = ''
    try { & $Tab['Show'] 6>&1 | ForEach-Object { $recs.Add($_) } }      # streamed: what was drawn before an error is kept
    catch { $failed = $_.Exception.Message }
    finally { $script:WHDMenuCapture = $prev }
    [object[]]$rows = ConvertFrom-WHDWindowRecord -Records $recs.ToArray()      # an array already (no @(): it would nest it)
    if ($failed) { $rows += [pscustomobject]@{ Type = 'text'; Text = ('(the screen could not be read completely: {0})' -f $failed); Color = 'Yellow' } }
    $status = [System.Collections.Generic.List[string]]::new()
    $groups = [System.Collections.Generic.List[object]]::new()
    $title = ''
    foreach ($row in $rows) {
        if ($row.Type -eq 'item') {
            if (-not $groups.Count -or $groups[$groups.Count - 1].Title -ne $title) { $groups.Add([pscustomobject]@{ Title = $title; Items = [System.Collections.Generic.List[object]]::new() }) }
            $groups[$groups.Count - 1].Items.Add($row)
            continue
        }
        $t = $row.Text.TrimEnd()
        if ($row.Color -eq 'DarkGray' -and $t -match '^\s{2}\S' -and $t.Trim().Length -le 90) { $title = $t.Trim() }
        if ($t -match '^\s*=+.*=+\s*$') { continue }                     # the screen's own title bar
        $status.Add($t)
    }
    if ($Tab['Items']) {
        foreach ($it in $script:WHDWindowItems[$Tab['Items']]) {
            $g = $groups | Where-Object Title -eq $it['Group'] | Select-Object -First 1
            if (-not $g) { $g = [pscustomobject]@{ Title = $it['Group']; Items = [System.Collections.Generic.List[object]]::new() }; $groups.Add($g) }
            $g.Items.Add([pscustomobject]@{ Type = 'item'; Key = $it['Key']; Label = $it['Label']; Hint = ''; Later = $false })
        }
    }
    while ($status.Count -and -not $status[0].Trim()) { $status.RemoveAt(0) }
    [pscustomobject]@{ Header = $Tab['Header']; Status = $status.ToArray(); Groups = $groups.ToArray() }
}

# ---- running one action ------------------------------------------------------------------------------------------------
function Invoke-WHDWindowAction {
    # Runs one menu key of a tab (or a main-menu key "M:x", or PLAN). Every screen line goes to $Sink (param $text, $color).
    # Returns 'done', 'jump:<tab>' (the window switches tab), or 'later'.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Tab, [Parameter(Mandatory)][AllowEmptyString()][string]$Key, [Parameter(Mandatory)][scriptblock]$Sink)
    $k = $Key.Trim()
    if (-not $k) { return 'done' }
    if ($Tab['Jump']) { foreach ($j in $Tab['Jump'].Keys) { if ($k -ieq $j) { return ('jump:{0}' -f $Tab['Jump'][$j]) } } }
    $do = $Tab['Do']
    & $Sink ('> {0}  {1}' -f $Tab['Header'], $k) 'Cyan'
    Write-WHDLog -Message ('Window: {0} -> {1}' -f $Tab['Header'], $k) -FileOnly
    $buf = ''; $col = ''
    try {
        & { param($kk, $dd) if ($kk -like 'M:*') { Invoke-WHDMainChoice -Choice $kk.Substring(2) } elseif ($kk -like 'G:*') { Invoke-WHDGuardChoice -Choice $kk.Substring(2) } elseif ($kk -eq 'PLAN') { Invoke-WHDPlan } else { & $dd $kk } } $k $do 6>&1 | ForEach-Object {
            $d = if ($_ -is [System.Management.Automation.InformationRecord]) { $_.MessageData } else { $_ }
            if ($d -is [System.Management.Automation.HostInformationMessage]) {
                if (-not $buf) { $col = [string]$d.ForegroundColor }
                $buf += [string]$d.Message
                if (-not $d.NoNewLine) { & $Sink $buf $col; $buf = '' }
            } elseif ($d -isnot [bool]) { & $Sink ([string]$d) '' }
        }
    } catch {
        & $Sink ('ERROR: {0}' -f $_.Exception.Message) 'Red'
        Write-WHDLog -Message ('Window: "{0}" in {1} stopped on an error: {2}' -f $k, $Tab['Header'], $_.Exception.Message) -Level 'ERR' -FileOnly
    }
    if ($buf) { & $Sink $buf $col }
    return 'done'
}

# ---- the link between the window (its own thread) and the engine (this thread) (P51) -------------------------------
# The window only draws; all work stays on the engine thread, so a long action never freezes the window. They talk
# through thread-safe queues of plain data - no code crosses between the threads.
$script:WHDWindowLinkNow = $null     # the open window's link (questions and action lines use it)
function Initialize-WHDWindowLink {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    [pscustomobject]@{
        ToEngine = [System.Collections.Concurrent.BlockingCollection[object]]::new()     # requests from the window
        ToView   = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()        # lines, tab contents, questions
        Answers  = [System.Collections.Concurrent.BlockingCollection[object]]::new()     # answers to the questions
        Flags    = [hashtable]::Synchronized(@{ Busy = $false; ViewGone = $false })
    }
}
function Send-WHDWindowView {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Link, [Parameter(Mandatory)][string]$Type, [hashtable]$Data = @{})
    $m = [ordered]@{ Type = $Type }
    foreach ($k in $Data.Keys) { $m[$k] = $Data[$k] }
    $Link.ToView.Enqueue([pscustomobject]$m)
}
function Get-WHDWindowMode {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $s = Get-WHDSession
    [pscustomobject]@{
        Text = ('{0}   |   administrator: {1}   |   restore point: {2}' -f $s.Mode, $(if ($s.IsAdmin) { 'yes' } else { 'NO - nothing can be changed' }), $(if ($s.RestoreDone) { 'made' } else { 'not yet' }))
        Exec = [bool]$script:WHDState.Execute
        Safe = [bool]$script:WHDState.SafeMode
    }
}
function Wait-WHDWindowAnswer {
    # The answer to the question just sent; $null when the window is gone.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Link)
    while ($true) {
        $a = $null
        if ($Link.Answers.TryTake([ref]$a, 300)) { return $a }
        if ($Link.Flags['ViewGone']) { return $null }
    }
}
function Invoke-WHDWindowCapture {
    # Runs engine code; its screen lines go to the window's log pane.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Link, [Parameter(Mandatory)][scriptblock]$Do)
    & $Do 6>&1 | ForEach-Object {
        $d = if ($_ -is [System.Management.Automation.InformationRecord]) { $_.MessageData } else { $_ }
        if ($d -is [System.Management.Automation.HostInformationMessage] -and -not $d.NoNewLine) { Send-WHDWindowView -Link $Link -Type 'line' -Data @{ Text = [string]$d.Message; Color = [string]$d.ForegroundColor } }
    }
}
function Invoke-WHDWindowRequest {
    # One request from the window. Every request except 'log' and 'close' ends with 'mode' and 'done'.
    # Returns $false for 'close'.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Link, [Parameter(Mandatory)][hashtable]$Request)
    $type = [string]$Request['Type']
    if ($type -eq 'close') { return $false }
    if ($type -eq 'log') { Write-WHDLog -Message ([string]$Request['Message']) -Level 'ERR' -FileOnly; return $true }
    $select = -1
    try {
        switch ($type) {
            'model' {
                $i = [int]$Request['Index']
                Send-WHDWindowView -Link $Link -Type 'model' -Data @{ Index = $i; Model = (Get-WHDWindowModel -Tab $script:WHDWindowTabs[$i]) }
            }
            'action' {
                $i = [int]$Request['Index']
                $sink = { param($t, $c) Send-WHDWindowView -Link $script:WHDWindowLinkNow -Type 'line' -Data @{ Text = [string]$t; Color = [string]$c } }
                $script:WHDWindowLinkNow = $Link
                $r = Invoke-WHDWindowAction -Tab $script:WHDWindowTabs[$i] -Key ([string]$Request['Key']) -Sink $sink
                if ($r -like 'jump:*') {
                    $to = $r.Substring(5)
                    for ($j = 0; $j -lt $script:WHDWindowTabs.Count; $j++) { if ($script:WHDWindowTabs[$j]['Header'] -eq $to) { $select = $j } }
                    if ($select -ge 0) { $i = $select }
                }
                Send-WHDWindowView -Link $Link -Type 'model' -Data @{ Index = $i; Model = (Get-WHDWindowModel -Tab $script:WHDWindowTabs[$i]) }
            }
            'exec' { Invoke-WHDWindowCapture -Link $Link -Do { [void](Set-WHDMode -Execute ([bool]$Request['On'])) } }
            'safe' { Invoke-WHDWindowCapture -Link $Link -Do { [void](Set-WHDMode -SafeMode ([bool]$Request['On'])) } }
            'rp' { Invoke-WHDWindowCapture -Link $Link -Do { New-WHDCheckpoint } }
            default { Send-WHDWindowView -Link $Link -Type 'line' -Data @{ Text = ('(unknown request "{0}")' -f $type); Color = 'Yellow' } }
        }
    } catch {
        Send-WHDWindowView -Link $Link -Type 'line' -Data @{ Text = ('ERROR: {0}' -f $_.Exception.Message); Color = 'Red' }
        Write-WHDLog -Message ('Window request "{0}" stopped on an error: {1}' -f $type, $_.Exception.Message) -Level 'ERR' -FileOnly
    }
    Send-WHDWindowView -Link $Link -Type 'mode' -Data @{ Mode = (Get-WHDWindowMode) }
    Send-WHDWindowView -Link $Link -Type 'done' -Data @{ Select = $select }
    return $true
}
function Invoke-WHDWindowLoop {
    # The engine side while the window is open: takes the window's requests one by one until it closes.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Link, $Handle)
    while ($true) {
        $req = $null
        if ($Link.ToEngine.TryTake([ref]$req, 250)) {
            if (-not (Invoke-WHDWindowRequest -Link $Link -Request $req)) { break }
            continue
        }
        if ($Link.Flags['ViewGone'] -or ($null -ne $Handle -and $Handle.IsCompleted)) { break }
    }
}

# ---- questions inside actions: dialogs instead of the console --------------------------------------------------------
function Enable-WHDWindowPrompt {
    # While the window is open, module code that asks with Read-Host gets $Ask (a dialog) instead, and the y / N
    # question of the change gate gets $ConfirmWith. Returns what to put back with Disable-WHDWindowPrompt.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][scriptblock]$Ask, [Parameter(Mandatory)][scriptblock]$ConfirmWith)
    if (-not $PSCmdlet.ShouldProcess('questions', 'route to the window')) { return $null }
    $saved = [pscustomobject]@{ Confirm = $script:WHDState.Confirm }
    $script:WHDState.Confirm = $ConfirmWith
    # global, so that every Read-Host of the module - also inside closures made with GetNewClosure, which do not see
    # the module's own functions - reaches the dialog. Removed again when the window closes.
    $global:WHDWindowAsk = $Ask
    Set-Item -Path function:global:Read-Host -Value {
        param([Parameter(Position = 0)]$Prompt, [switch]$AsSecureString)
        [void]$AsSecureString
        return [string](& $global:WHDWindowAsk ([string]$Prompt))
    }
    return $saved
}
function Disable-WHDWindowPrompt {
    [CmdletBinding(SupportsShouldProcess)]
    param($Saved)
    if (-not $PSCmdlet.ShouldProcess('questions', 'back to the console')) { return }
    while (Get-Command -Name Read-Host -CommandType Function -ErrorAction SilentlyContinue) { Remove-Item -Path function:Read-Host }   # function:global:... would not remove it
    Remove-Variable -Name WHDWindowAsk -Scope Global -ErrorAction SilentlyContinue
    if ($Saved) { $script:WHDState.Confirm = $Saved.Confirm }
}
