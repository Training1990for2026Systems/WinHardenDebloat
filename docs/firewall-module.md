# WinHardenDebloat — Firewall Module (`modules\Firewall.ps1`)

Native, offline hardening of **Windows Defender Firewall with Advanced Security**.
No third-party engine, no AppLocker/gpedit/secpol dependency (works on Windows 11 Home),
no internet required. Every change flows through the existing `Common.ps1` safety engine:
dry-run by default, per-session System Restore point, `.reg`/`.wfw`/hosts backups to `restore\`,
transcript logging, structured `planned/done/failed/skipped` results.

Load order in `WHD.ps1`: dot-sourced after `Common.ps1`. Menu entry: **9. Firewall**. GUI: `WHD-GUI.ps1`, Firewall tab.

In EXECUTE mode every action that changes the system asks **y/N** first in the terminal menu (the GUI asks once per
button; a profile run asks once up front). In DRY-RUN nothing is asked and nothing changes.

**Block lists are not included.** WHD ships no IP or domain block list (they are other people's data). Menu **9** (Block
IP list), **H** (Hosts sinkhole) and the baseline profile only do something once you put your own
`profiles\blacklist-ip.txt` / `profiles\blacklist-hosts.txt` there (see "Offline blocklist refresh" below).

## Decisions locked (2026-09-21)
- **D1** Terminal module (menu 9); the GUI (`WHD-GUI.ps1`, Firewall tab) offers the same actions.
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
| `Invoke-WHDFirewallReset [-ApplyBaseline]` | `netsh advfirewall reset` → enable all profiles, inbound Block / outbound Allow. Backs up first. Menu **R**. | hard |
| `Invoke-WHDFirewallWipe [-ApplyBaseline]` | Deletes **every** rule, Windows' own included (empty slate). The firewall stays on; the default actions are not changed. Backs up first. Menu **W**. | hard |
| `Export-WHDFirewallPolicy [-Path]` | Writes `<base>.wfw` (full policy) **and** `<base>.json` (WHD rules, editable). | reversible |
| `Import-WHDFirewallPolicy -Path -Mode Json\|Wfw` | Re-applies a JSON ruleset or imports a `.wfw` blob. | caution |
| `Invoke-WHDFirewallAllowList` | Outbound allow-list (DNS/DHCP/NTP/HTTP/S) — pre-stages default-deny. | reversible |
| `Invoke-WHDSetDns -Mode Cloudflare\|Reset [-NoDoH]` | Menu **D**: system DNS → Cloudflare 1.1.1.2 / 1.0.0.2 with encrypted DNS (DoH). Menu **U**: back to automatic (DHCP), DoH registrations removed. | reversible |
| `Enable-WHDDefaultDenyOutbound [-RollbackMinutes 10]` | Flips `DefaultOutboundAction=Block` **with an armed auto-rollback** scheduled task (1–720 min). Not enabled if the essential allow rules are missing or the task cannot be armed. | hard |
| `Confirm-WHDDefaultDenyKeep` / `Disable-WHDDefaultDenyOutbound` | Cancel the rollback (keep strict) / revert to permissive. | — |
| `Block-WHDIPList -Path` | IP/CIDR block rules from your own offline list (chunked 1000/rule). | caution |
| `Block-WHDHostsList -Path` / `Remove-WHDBlacklist` | Domain sinkhole via hosts file (marked block; only plain host names are written) / remove all blacklist. | caution |
| `Invoke-WHDApplyFirewallProfile -Path` | Drives all of the above from one JSON file (`profiles\firewall-baseline.json`). | per-profile |

All created rules carry a group: `WinHardenDebloat-IPv6 / -AllowList / -Blacklist / -AppAllow` (and `-UpdateGate` from `modules\Updates.ps1`), so they list and remove as a set and never mix with Microsoft's built-ins.

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
2. Apply (or use menu **6** without editing the file). WHD first checks that the essential allow rules
   (`WHD-Allow-DNS-UDP`, `WHD-Allow-DNS-TCP`, `WHD-Allow-DHCP-Out`) exist and are enabled. An empty
   allow-list is built first; if rules exist but those three are missing or off, default-deny is refused and you apply
   the allow-list yourself (Firewall **5**). Then it arms the auto-rollback: a one-time scheduled task `WHD-DefaultDenyRollback` that runs as SYSTEM
   after `rollbackMinutes` (1–720) and sets outbound back to Allow. The task holds that one command itself (no script
   file) and may start on battery or late if the PC was off or asleep at the time. **If the task cannot be armed,
   default-deny is not enabled.** Only then does outbound flip to Block.
3. Verify the machine still does what it must, then `Confirm-WHDDefaultDenyKeep` (menu **7**) removes the task.
   If anything broke, wait for the rollback time (or use menu **8** to revert at once), then widen the allow-list and
   retry. After the task has run, menu **7** reports that outbound is already Allow and removes the leftover task.

## Constraint to remember
Windows Firewall rules match **IP addresses, never domain names**. Domain blacklists go to the
hosts sinkhole; IP/CIDR blacklists go to firewall block rules. Domain filtering is otherwise done at the
resolver: menu **D** points system DNS at Cloudflare 1.1.1.2 / 1.0.0.2 (malware filter) and registers native
encrypted DNS (DoH) for it; menu **U** undoes both. Filtering at the router (pfSense / OpenWrt) is outside WHD.

## If you lose the network
- Firewall **8** — revert default-deny (outbound back to Allow).
- Updates **O** — open the update gate (Firewall 8 refuses while the gate is closed).
- Firewall **5** — re-apply the allow-list (needed after a wipe while outbound is Block).
- Undo center **F** — restore the firewall saved before that session.
- Or, in an administrator window: `netsh advfirewall reset`.

## Phase 6 additions (2026-09-23)

### Blocked-connection viewer (menu 9 → M / O / V / G, GUI Firewall → "Blocked connections")
- **M** turns logging on (v1.3, 2026-09-28): Windows Firewall's own log, default file
  (%SystemRoot%\System32\LogFiles\Firewall\pfirewall.log), dropped + allowed, 32,767 KB (maximum). Journal kind `fwlog`.
  The older Security-log / event 5157 method is replaced; its old journal lines still undo.
  **O** turns it off. The log has no program path; the viewer names the program from the logged pid when that process
  is still running.
- **V** lists blocked connections (default last 24 h, outbound) grouped by program + protocol + port,
  with a count, last-seen time and sample addresses.
- One-click allow (**program + that port only**) creates
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
**T** also sets the **Windows Time service to Automatic (delayed start)** and starts it (on a non-domain PC the
service is trigger-start and usually not running, so the clock would not sync);
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
NTS (authenticated time) is not included: the Windows Time service does not support it.

### Offline blocklist refresh (menu 9 → F, GUI "Refresh blocklist (incoming)")
Block lists are not included: download the lists you want yourself (on any machine) and drop the files in
**`profiles\incoming\`** (created on first use, with a README). Formats detected per line:
plain IP/CIDR (FireHOL `.netset`/`.ipset`), Spamhaus DROP classic (`cidr ; SBL...`), Spamhaus DROP JSON
(`drop_v4.json`), DShield `block.txt`. Every entry is normalized, de-duplicated (ranges inside bigger ranges are
dropped) and passed through the same safety guard as `Block-WHDIPList`; IPv6 entries are skipped.
1. A **preview** shows usable/skipped counts per file, what's new vs the current list, and the size after
   MERGE and after REPLACE (changes are shown first; you choose each time).
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
- "Closed" = the state file says closed for the current PC **and** outbound is Block.
- `Invoke-WHDApplyFirewallProfile` never lowers outbound Block to Allow.
- `Invoke-WHDFirewallAllowList` and the profile allow-list keep `WHD-Allow-HTTPS` / `WHD-Allow-HTTP` off while the gate is
  closed. `Disable-WHDDefaultDenyOutbound` refuses while the gate is closed.

## Safety behaviour of the firewall functions
- The firewall backup (`restore\<session>\firewall-before.wfw`) is taken once per session, before the first firewall
  change. If the export fails, the change that needed it is reported FAILED and is not made.
- Rule names: a name that is empty or contains `*`, `?`, `[` or `]` is refused (in the JSON import and in firewall
  profiles too), because a wildcard name would match — and replace — other rules.
- Hosts file: the first `hosts.bak` of a session is kept (later runs do not overwrite it); a hosts file that cannot be
  read is not rewritten; list lines that are not plain host names (and localhost-type names) are skipped and counted.
- A firewall profile that names an IP or hosts list file that is not there logs a warning and applies no block list.
- A wipe (**W**) while outbound is Block warns first: it also deletes WHD's allow rules, so there is no network until
  the allow-list is applied again (Firewall **5**) or default-deny is reverted (Firewall **8**).
