#requires -Version 7.6
<#
 WHD Next 3.0  -  Public/Show-WHDWindow.ps1   (build step 6b, D82, D83; P51)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 The window (WHD.ps1 -Gui, Start-WHD.cmd -Gui): Windows' own WPF, no extra
 libraries, offline. Top: EXECUTE and safe mode switches, restore point. Tabs
 as WHD Next 2.0 (Features\Window.ps1 says what is in them). Bottom: the log of
 everything the actions write (also in logs\). Questions come up as Yes / No
 and input dialogs.
 Two threads (P51): the window runs on its own STA thread
 (Features\WindowView.ps1) and only draws; every action runs here, on the
 engine's thread. So the window stays alive during long actions, shows
 "WORKING", and its X waits until the action is done. The console window
 behind it stays open; close the window to end the session.
#>
function Show-WHDWindow {
    [CmdletBinding()]
    param()
    $info = Get-WHDEngineInfo
    $link = Initialize-WHDWindowLink
    $script:WHDWindowLinkNow = $link
    # questions inside actions go to the window and wait there for the answer
    $ask = {
        param([string]$Prompt)
        Send-WHDWindowView -Link $script:WHDWindowLinkNow -Type 'ask' -Data @{ Prompt = $Prompt }
        $a = Wait-WHDWindowAnswer -Link $script:WHDWindowLinkNow
        return $(if ($null -eq $a) { '' } else { [string]$a })
    }
    $confirm = {
        param($What)
        Send-WHDWindowView -Link $script:WHDWindowLinkNow -Type 'confirm' -Data @{ What = [string]$What }
        return [bool](Wait-WHDWindowAnswer -Link $script:WHDWindowLinkNow)
    }
    $saved = Enable-WHDWindowPrompt -Ask $ask -ConfirmWith $confirm -Confirm:$false
    $rs = $null; $ps = $null
    try {
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.ApartmentState = [System.Threading.ApartmentState]::STA          # WPF needs an STA thread
        $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('Link', $link)
        $rs.SessionStateProxy.SetVariable('Info', [pscustomobject]@{ Product = $info.Product; Version = $info.Version; PowerShell = $info.PowerShell })
        $rs.SessionStateProxy.SetVariable('Headers', [string[]]@($script:WHDWindowTabs | ForEach-Object { $_['Header'] }))
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($script:WHDWindowView.ToString())
        Send-WHDWindowView -Link $link -Type 'mode' -Data @{ Mode = (Get-WHDWindowMode) }
        Send-WHDWindowView -Link $link -Type 'line' -Data @{ Text = ('{0} {1} - PowerShell {2}. DRY-RUN until EXECUTE is ticked; each change still asks first.' -f $info.Product, $info.Version, $info.PowerShell); Color = '' }
        $handle = $ps.BeginInvoke()
        Write-WHDLog -Message 'Window opened.' -FileOnly
        Invoke-WHDWindowLoop -Link $link -Handle $handle
        try { [void]$ps.EndInvoke($handle) }
        catch { Write-WHDLog -Message ('The window stopped on an error: {0}' -f $_.Exception.Message) -Level 'ERR' }
        foreach ($er in @($ps.Streams.Error)) { Write-WHDLog -Message ('Window: {0}' -f $er) -Level 'ERR' }
    } catch {
        Write-WHDLog -Message ('The window could not be shown: {0}' -f $_.Exception.Message) -Level 'ERR'
    } finally {
        Disable-WHDWindowPrompt -Saved $saved -Confirm:$false
        if ($ps) { $ps.Dispose() }
        if ($rs) { $rs.Dispose() }
        $script:WHDWindowLinkNow = $null
        Write-WHDLog -Message 'Window closed.' -FileOnly
    }
}
