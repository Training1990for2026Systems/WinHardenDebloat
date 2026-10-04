# WinHardenDebloat — Firewall Module (`modules\Firewall.ps1`)

Native, offline hardening of **Windows Defender Firewall with Advanced Security**.
No third-party engine, no AppLocker/gpedit/secpol dependency (works on Windows 11 Home),
no internet required. Every change flows through the existing `Common.ps1` safety engine:
dry-run by default, per-session System Restore point, `.reg`/`.wfw`/hosts backups to `restore\`,
transcript logging, structured `planned/done/failed/skipped` results.

Load order in `WHD.ps1`: dot-sourced after `Common.ps1`. Menu entry: **9. Firewall**.

## Decisions locked (2026-09-21)
- **D1** Terminal module now (menu 9); WPF GUI is a later phase.
- **D2** IPv6 off via **adapter unbind + registry + firewall block rules**; loopback `::1` **kept** (blocking it is opt-in).
- **D3** Offline deploy exports **both** an editable JSON ruleset **and** a `netsh` `.wfw` blob.
- **D4** Module is **designed toward default-deny outbound**: the allow-list and the staged switch exist now; the flip stays OFF until you choose it.

## What each function does

| Function | Purpose | Risk |
|---|---|---|
| `Invoke-WHDDisableIPv6 [-BlockLoopback]` | Unbind `ms_tcpip6`, set `DisabledComponents=0xFF`, add IPv6/ICMPv6/multicast block rules. `-BlockLoopback` also blocks `::1`. | caution / hard |
| `Invoke-WHDEnableIPv6` | Full undo of the above. | reversible |
| `Show-WHDFirewallSummary` | Profile on/off + default actions, rule counts, WHD group counts. | read-only |
| `Get-WHDFirewallRules [-Detail] [-CustomOnly] [-EnabledOnly] [-Direction] [-Action]` | Clean, filterable rule listing (joins port/address/program filters with `-Detail`). | read-only |
| `Invoke-WHDFirewallReset [-ApplyBaseline]` | `netsh advfirewall reset` → enable all profiles, inbound Block / outbound Allow. Backs up first. | hard |
| `Export-WHDFirewallPolicy [-Path]` | Writes `<base>.wfw` (full policy) **and** `<base>.json` (WHD rules, editable). | reversible |
| `Import-WHDFirewallPolicy -Path -Mode Json\|Wfw` | Re-applies a JSON ruleset or imports a `.wfw` blob. | caution |
| `Invoke-WHDFirewallAllowList` | Outbound allow-list (DNS/DHCP/NTP/HTTP/S) — pre-stages default-deny. | reversible |
| `Enable-WHDDefaultDenyOutbound [-RollbackMinutes 10]` | Flips `DefaultOutboundAction=Block` **with an armed auto-rollback** scheduled task. | hard |
| `Confirm-WHDDefaultDenyKeep` / `Disable-WHDDefaultDenyOutbound` | Cancel the rollback (keep strict) / revert to permissive. | — |
| `Block-WHDIPList -Path` | IP/CIDR block rules from an offline list (chunked 1000/rule). | caution |
| `Block-WHDHostsList -Path` / `Remove-WHDBlacklist` | Domain sinkhole via hosts file (marked block) / remove all blacklist. | caution |
| `Invoke-WHDApplyFirewallProfile -Path` | Drives all of the above from one JSON file (`profiles\firewall-baseline.json`). | per-profile |

All created rules carry a group: `WinHardenDebloat-IPv6 / -AllowList / -Blacklist / -Baseline`, so they list and remove as a set and never mix with Microsoft's built-ins.

## Typical offline workflow on a fresh image
```
# elevated PowerShell in the project folder, DRY-RUN first
powershell -ExecutionPolicy Bypass -File .\WHD.ps1
#  9  -> Firewall menu -> 1 (IPv6 off), 5 (allow-list), X (export json+wfw)
# then toggle 8 -> EXECUTE, repeat to apply for real
```
Clone to another imaged machine (no internet):
`Import-WHDFirewallPolicy -Path .\restore\<stamp>\firewall-policy.wfw -Mode Wfw`
or apply the editable profile: menu **9 → A**.

## Going strict (long-term, deliberate)
1. `profiles\firewall-baseline.json` → set `"defaultDenyOutbound": true`.
2. Apply. Outbound flips to Block; an auto-rollback task reverts it in `rollbackMinutes`.
3. Verify the machine still does what it must, then `Confirm-WHDDefaultDenyKeep`.
   If anything broke, do nothing — it self-heals — then widen the allow-list and retry.

## Constraint to remember
Windows Firewall rules match **IP addresses, never domain names**. Domain blacklists go to the
hosts sinkhole; IP/CIDR blacklists go to firewall block rules. Closing the DoH-bypass gap on
domains is the long-long-term encrypted-DNS + hardware-router phase (native DoH via
`Set-DnsClientDohServerAddress`; gateway DoT/blocklists via pfSense/OpenWrt).

## Phase 6 additions (2026-09-23)

### Blocked-connection viewer (menu 9 → M / O / V / G, GUI Firewall → "Blocked connections")
- **M** turns logging on (v1.3, 2026-09-28): Windows Firewall's own log, default file
  (%SystemRoot%\System32\LogFiles\Firewall\pfirewall.log), dropped + allowed, 32,767 KB (maximum). Journal kind `fwlog`.
  The older Security-log / event 5157 method is replaced; its old journal lines still undo.
  **O** turns it off. The log has no program path; the viewer names the program from the logged pid when that process
  is still running.
- **V** lists blocked connections (default last 24 h, outbound) grouped by program + protocol + port,
  with a count, last-seen time and sample addresses. Device paths are translated to `C:\...` with `fltmc volumes`.
- One-click allow (**user decision: program + that port only**) creates
  `WHD-App-<exe>-<proto>-<port>` in group **`WinHardenDebloat-AppAllow`**: outbound, that program,
  that protocol + remote port, any destination. Journaled as `fwrule` (undo = remove rule).
  Refused: inbound rows (would open the PC) and Windows service traffic (`svchost.exe`, `System`) —
  a program rule for svchost would open every service. **G** removes all program allows.

### Time sync — Option 1 (menu 9 → T / N / S)
Windows' time service speaks NTP only (no NTS). **T** sets
`HKLM\SYSTEM\CurrentControlSet\Services\W32Time\Parameters` `NtpServer = time.cloudflare.com,0x8`,
`Type = NTP` (journaled registry writes), runs `w32tm /config /update` + `/resync /rediscover`, and pins the
allow rule `WHD-Allow-NTP` to Cloudflare's published NTP addresses **162.159.200.1, 162.159.200.123**
(IPv6 omitted — IPv6 is suppressed). `0x8` = client mode on Windows' normal poll interval (~17 min–9 h)
instead of `0x1`'s weekly interval. **N** goes back to `time.windows.com,0x9` and reopens UDP 123 to any.
**T** also sets the **Windows Time service to Automatic (delayed start)** and starts it (user decision
2026-09-23 after the live test showed it was trigger-start and not running, so the clock was never syncing);
journaled as a `service` change, so the Undo center restores the previous start type.
**S** shows the setting, the service state/start type, the source in use, last sync, a direct reachability
test (`w32tm /stripchart /computer:time.cloudflare.com /samples:2`, works even if the service is stopped)
and the NTP rule. The allow-list (menu 5) and the
baseline profile keep NTP pinned automatically while the time source is Cloudflare.

**Time-jump limit (Option 3-B, 2026-09-24).** Windows can't do NTS, so **T** also caps how far Windows Time may move
the clock on its own: `HKLM\SYSTEM\CurrentControlSet\Services\W32Time\Config` `MaxPosPhaseCorrection` and
`MaxNegPhaseCorrection` = **3600** (1 h; Windows default 54000 = 15 h; Microsoft Learn: stand-alone clients "3600 (1 hour)
or smaller"). A bigger correction, e.g. a forged NTP reply, is thrown out and logged as System log
`Microsoft-Windows-Time-Service` event **34**. The update guard alerts on it (report opens). Secure Time Seeding
(`UtilizeSslTimeData`) is left on. **N** puts 54000 back and turns Secure Time Seeding on if it was off. All writes are
journaled (auto undo + Verify). Summary and **S** show the limit, Secure Time Seeding and refused jumps (7 days).
If the clock is ever really more than 1 h off, set it by hand once (Settings > Time & language > Date & time), then Sync now.
Options 2 (router NTS via OpenWrt/chrony) and 3 (third-party NTS client) are planned, not built.

### Offline blocklist refresh (menu 9 → F, GUI "Refresh blocklist (incoming)")
Drop list files in **`profiles\incoming\`** (created on first use, with a README). Formats detected per line:
plain IP/CIDR (FireHOL `.netset`/`.ipset`), Spamhaus DROP classic (`cidr ; SBL...`), Spamhaus DROP JSON
(`drop_v4.json`), DShield `block.txt`. Every entry is normalized, de-duplicated (ranges inside bigger ranges are
dropped) and passed through the same safety guard as `Block-WHDIPList`; IPv6 entries are skipped.
1. A **preview** shows usable/skipped counts per file, what's new vs the current list, and the size after
   MERGE and after REPLACE (**user decision: show changes, then choose each time**).
2. Merge or replace → the old list is backed up to `restore\<session>\blacklist-ip.before.<time>.txt`,
   the new file is written (journaled `file`, undo restores the backup) and the processed files move to
   `incoming\done\<session>\`.
3. **Asks each time** whether to rebuild the block rules now (`Update-WHDBlocklistRules` removes the old
   chunks first, so a shorter list never leaves stale rules).
Safety: if the current list can't be read, the refresh aborts without changing anything; an empty result is refused.

### v1.1 - update gate (modules\Updates.ps1) and baseline fixes
- `Close-WHDUpdateGate` / `Open-WHDUpdateGate`. The group `WinHardenDebloat-UpdateGate` holds the Defender + DoH allows.
  The state is kept in `restore\update-guard\update-gate.json`: MachineId, Closed, PrevOutbound, and DisabledRules (every
  outbound allow rule the gate switched off, put back on open).
- "Closed" = the state file says closed on this PC **and** outbound is Block.
- `Invoke-WHDApplyFirewallProfile` never lowers outbound Block to Allow.
- `Invoke-WHDFirewallAllowList` and the profile allow-list keep `WHD-Allow-HTTPS` / `WHD-Allow-HTTP` off while the gate is
  closed. `Disable-WHDDefaultDenyOutbound` refuses while the gate is closed.

