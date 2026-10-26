#requires -Version 7.6
<#
 WHD Next 3.0  -  Public/Restore-WHDSessionBackup.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 Undo center, whole-session backups (same as WHD Next 2.0):
   -Firewall   replace the WHOLE firewall policy with firewall-before.wfw of that session
   -Hosts      put that session's hosts.bak back as the hosts file
   -RegFiles   import that session's .reg backups (puts values back; does not
               delete values added later - recorded undo is more exact)
 Allowed in safe mode. Asks first; dry-run shows what it would do.
#>
function Restore-WHDSessionBackup {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Session, [switch]$Firewall, [switch]$Hosts, [switch]$RegFiles)
    $sess = (Get-WHDHistorySession | Where-Object Stamp -eq $Session | Select-Object -First 1)
    if (-not $sess) { Write-WHDLog -Message ('Session not found: {0}' -f $Session) -Level 'ERR'; return }
    if (-not ($Firewall -or $Hosts -or $RegFiles)) { throw 'Restore-WHDSessionBackup: give -Firewall, -Hosts or -RegFiles' }
    Invoke-WHDSafeAllowed -Do {
        if ($Firewall) {
            $wfw = Join-Path $sess.Path 'firewall-before.wfw'
            if (-not (Test-Path -LiteralPath $wfw)) { Write-WHDLog -Message 'This session has no firewall backup.' -Level 'WARN' }
            elseif ($PSCmdlet.ShouldProcess($wfw, 'replace the whole firewall policy')) {
                Write-WHDLog -Message ('RESTORE FIREWALL from {0} - replaces the ENTIRE firewall policy; later firewall changes are lost.' -f $wfw) -Level 'ACT'
                if (Confirm-WHDProceed -What 'replace the whole firewall policy with this backup') {
                    Invoke-WHDChange -Description ('netsh advfirewall import {0}' -f $wfw) -Action {
                        $ni = Invoke-WHDNative -Exe 'netsh.exe' -ArgList @('advfirewall', 'import', $wfw)
                        if ($ni.Code -ne 0) { throw ('netsh exit {0}: {1}' -f $ni.Code, ($ni.Out -join ' ')) }
                    } | Out-Null
                }
            }
        }
        if ($Hosts) {
            $bak = Join-Path $sess.Path 'hosts.bak'
            if (-not (Test-Path -LiteralPath $bak)) { Write-WHDLog -Message 'This session has no hosts backup.' -Level 'WARN' }
            elseif ($PSCmdlet.ShouldProcess($bak, 'replace the hosts file')) {
                $hostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
                Write-WHDLog -Message ('RESTORE HOSTS FILE from {0} ({1:N0} bytes)' -f $bak, (Get-Item -LiteralPath $bak).Length) -Level 'ACT'
                if (Confirm-WHDProceed -What 'replace the hosts file with this backup') {
                    $hostsNow = Join-Path (Get-WHDRestoreFolder) 'hosts.bak'
                    Invoke-WHDChange -Description ('restore hosts file from {0}' -f $bak) -Action {
                        $hd = Split-Path $hostsNow -Parent; if (-not (Test-Path -LiteralPath $hd)) { [void](New-Item -ItemType Directory -Path $hd -Force) }
                        Copy-Item -LiteralPath $hostsFile -Destination $hostsNow -Force -ErrorAction SilentlyContinue
                        Copy-Item -LiteralPath $bak -Destination $hostsFile -Force -ErrorAction Stop
                        [void](Invoke-WHDNative -Exe 'ipconfig.exe' -ArgList @('/flushdns'))
                    } | Out-Null
                }
            }
        }
        if ($RegFiles) {
            $files = @(Get-ChildItem -LiteralPath $sess.Path -Filter '*.reg' -File -ErrorAction SilentlyContinue)
            if (-not $files.Count) { Write-WHDLog -Message 'This session has no .reg backups.' -Level 'WARN' }
            elseif ($PSCmdlet.ShouldProcess($sess.Path, ('import {0} .reg file(s)' -f $files.Count))) {
                Write-WHDLog -Message ('IMPORT {0} .reg backup(s) from {1} - puts saved values back, does not delete values added later.' -f $files.Count, $sess.Path) -Level 'ACT'
                if (Confirm-WHDProceed -What ('import {0} .reg file(s)' -f $files.Count)) {
                    foreach ($rf in $files) {
                        $rfPath = $rf.FullName
                        Invoke-WHDChange -Description ('reg import {0}' -f $rf.Name) -Action {
                            $ri = Invoke-WHDNative -Exe 'reg.exe' -ArgList @('import', $rfPath)
                            if ($ri.Code -ne 0) { throw ('reg import exit {0}: {1}' -f $ri.Code, ($ri.Out -join ' ')) }
                        } | Out-Null
                    }
                }
            }
        }
    }
}
