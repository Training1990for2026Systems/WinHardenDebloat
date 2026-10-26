#requires -Version 7.6
<#
 WHD Next 3.0  -  Private/Appx.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 Store (Appx) app removal, the same three steps as WHD Next 2.0 and in this order:
   1. remove the installed package for ALL users          (kind appx)
   2. remove the staged copy new user accounts would get   (kind provisioned)
   3. write Microsoft's Deprovisioned mark so a Windows update does not bring it
      back (Microsoft Learn: "remove provisioned apps during update")  (kind deprov)
 Each step goes through the change gate and is recorded; appx / provisioned are
 manual undo (reinstall from the Store), the mark is automatic undo.
#>
$script:WHDDeprovKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned'

function Add-WHDDeprovisionMark {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Pfn)
    $dpPath = '{0}\{1}' -f $script:WHDDeprovKey, $Pfn
    if (Test-Path -LiteralPath $dpPath) { return }
    if (-not $PSCmdlet.ShouldProcess($Pfn, 'write Deprovisioned mark')) { return }
    Invoke-WHDChange -Description ('mark as deprovisioned (Windows updates must not bring it back): {0}' -f $Pfn) -Journal @{ Kind = 'deprov'; Pfn = $Pfn } -Action {
        [void](New-Item -Path $dpPath -Force -ErrorAction Stop)
    } | Out-Null
}

function Remove-WHDAppxAllUser {
    # Every installed package matching the name (wildcards allowed), for all users, then its mark.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$NameLike)
    $pkgs = @(Get-AppxPackage -AllUsers -Name $NameLike -ErrorAction SilentlyContinue)
    if (-not $pkgs.Count) { Write-WHDLog -Message ('no installed package matches {0}' -f $NameLike); return }
    foreach ($p in $pkgs) {
        $axFull = [string]$p.PackageFullName
        if (-not $PSCmdlet.ShouldProcess($axFull, 'remove Appx package')) { continue }
        Invoke-WHDChange -Description ('remove Appx (all users): {0}' -f $axFull) -Journal @{ Kind = 'appx'; Package = [string]$p.Name; FullName = $axFull } -Action {
            Remove-AppxPackage -Package $axFull -AllUsers -ErrorAction Stop
        } | Out-Null
        if ([string]$p.PackageFamilyName) { Add-WHDDeprovisionMark -Pfn ([string]$p.PackageFamilyName) }
    }
}

function Remove-WHDProvisioned {
    # The staged copy (new user accounts), then its mark.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$NameLike)
    $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { [string]$_.DisplayName -like $NameLike })
    if (-not $prov.Count) { Write-WHDLog -Message ('no provisioned package matches {0}' -f $NameLike); return }
    foreach ($p in $prov) {
        $pvName = [string]$p.PackageName
        if (-not $PSCmdlet.ShouldProcess($pvName, 'remove provisioned package')) { continue }
        Invoke-WHDChange -Description ('deprovision (new users will not get it): {0}' -f $pvName) -Journal @{ Kind = 'provisioned'; Package = [string]$p.DisplayName; FullName = $pvName } -Action {
            [void](Remove-AppxProvisionedPackage -Online -PackageName $pvName -AllUsers -ErrorAction Stop)
        } | Out-Null
        if ([string]$p.DisplayName -and [string]$p.PublisherId) { Add-WHDDeprovisionMark -Pfn ('{0}_{1}' -f $p.DisplayName, $p.PublisherId) }
    }
}

function Invoke-WHDConfirmOnce {
    # Runs a batch after ONE question: every step inside it goes ahead without asking again.
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Do)
    $prev = $script:WHDState.Confirm
    $script:WHDState.Confirm = { param($What) [void]$What; $true }
    try { & $Do } finally { $script:WHDState.Confirm = $prev }
}
