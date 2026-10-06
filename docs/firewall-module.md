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
  **O** turns it off. The log has no program path; the viewer names the program from the logged pid (1.5: only when
  that process started before the log line, or from the names WHD remembered - see "1.5 - blocked-connections view").
- **V** lists blocked connections (default last 24 h, outbound) grouped by program + protocol + port,
  with a count, last-seen time and sample addresses.
- One-click allow (**program + that port only**) creates
  `WHD-App-<exe>-<proto>-<port>` in group **`WinHardenDebloat-AppAllow`**: outbound, that program,
  that protocol + remote port, any destination. Journaled as `fwrule` (undo = remove rule).
  Refused: inbound rows (would open the PC) and Windows service traffic (`svchost.exe`, `System`) —
  a program rule for svchost would open every service. **G** removes all program allows.
  1.5: several rows can be allowed at once, and an allow made while the update gate is CLOSED is saved switched off
  (see the two 1.5 sections below).

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

### 1.5 - update gate position PROGRAMS, two more Defender rules, gate line on the firewall screen
- **Update gate, three positions** (`restore\update-guard\update-gate.json` now also holds `Mode`; a file written by an
  older version has no `Mode` and is read as closed):
  - **OPEN** as before.
  - **PROGRAMS** (`Close-WHDUpdateGate -Mode programs`, Updates menu **P**) = outbound default-deny; Defender + DoH + the
    per-program allows (group `WinHardenDebloat-AppAllow`, made in Firewall menu **V**) stay on; the any-program web rules
    and every other outbound allow rule are switched off and remembered. Windows Update and the Store stay off.
  - **CLOSED** (`Close-WHDUpdateGate`, Updates menu **C**) as before: the per-program allows are switched off and
    remembered too.
- `Get-WHDGateState` returns `Mode` (`open` / `programs` / `closed`) and `Text` (`OPEN` / `PROGRAMS` / `CLOSED` + since
  when). `Closed` and `Test-WHDGateClosed` are true for PROGRAMS and CLOSED. Reading the state creates no folder; the
  folder is made when the state is saved.
- CLOSED -> PROGRAMS switches on only the per-program allows the gate itself had switched off; an allow that was switched
  off by hand stays off. PROGRAMS -> CLOSED switches them off and remembers them again.
- **A program allowed in Firewall V while the gate is CLOSED is saved switched off** and added to the gate's remembered
  list (`Add-WHDGateRemembered`); it comes on when the gate is set to PROGRAMS or OPEN. (Before 1.5 it was created
  switched on and switched off at the next close.) With the gate on PROGRAMS a new allow works at once - WHD says so.
- Everything the gate checked before still applies to both positions: the DNS-pin check (refuses when an adapter does
  not use the pinned DNS servers; DRY-RUN only warns), the allow-list check, the state saved before the change, and the
  roll-back when the change fails. A failed change of position (CLOSED <-> PROGRAMS) puts the per-program allows back and
  records the old position again.
- `Open-WHDUpdateGate`: the gate is recorded as open only when the change went through. If it fails, the rules it had
  just switched on are switched off again and the saved state is not touched. "Nothing to open" is unchanged: a
  default-deny that was turned on separately (Firewall **6**) is left alone.
- **Two more gate rules** (created only when the program file exists in Defender's platform folder):
  `WHD-Gate-NisSrv` (`NisSrv.exe`, Defender network inspection - a program rule next to the service rule) and
  `WHD-Gate-MpCore` (`MpDefenderCoreService.exe`, the Defender core service). Microsoft Learn ("Microsoft Defender Core
  service overview"): the core service delivers Defender fixes and configuration and also sends Defender telemetry; the
  close-gate text says so.
- The firewall screen (`Show-WHDFirewallSummary`) shows one line `Update gate   : OPEN / PROGRAMS / CLOSED since ...`.
- `Invoke-WHDFirewallAllowList`, the profile allow-list and `Disable-WHDDefaultDenyOutbound` name the real position
  (CLOSED or PROGRAMS) in their messages; their behaviour is unchanged.
- Profile key `updates.gate` accepts `"closed"` or `"programs"` (`modules\Profiles.ps1`).
- `Enable-WHDDefaultDenyOutbound` (Firewall **6**) does nothing while the gate is CLOSED or on PROGRAMS: outbound is already
  default-deny, and arming the auto-rollback there would set outbound back to Allow when the minutes ran out.
- `Import-WHDFirewallPolicy -Mode Json` keeps `WHD-Allow-HTTPS` / `WHD-Allow-HTTP` off while the gate is CLOSED or on PROGRAMS;
  on CLOSED it also switches imported per-program allows off and adds them to the gate's remembered list.

### 1.5 - blocked-connections view (menu 9 -> V), allow several at once
- The firewall log only has a process id. A running process is used for a log line only if it **started before** that
  line, so a restart or a reused id no longer puts the wrong program name on old lines.
- Names WHD resolves are remembered per PC in `restore\update-guard\blocked-programs.json` (id, start time, path, last
  time seen running; 7 days, 400 entries), so lines of a program that has closed since keep their name and can still be
  allowed. A remembered name is used only inside the time that program was known to run (not after a restart, not more
  than 30 minutes after it was last seen). This file is WHD's own cache; the view writes it in DRY-RUN too. If it cannot
  be written (folder protection, for example) the view still works and says so once.
- Every row gets a `State`: `can` / `allowed` / `allowed-off` (an allow exists but is switched off, e.g. gate CLOSED) /
  `covered` (the allow-list lets it out now) / `windows` (service, System, not TCP-UDP, or no process id) / `inbound` /
  `ended` (program closed, name not known). `StateText` holds the same in words. Rows that can be allowed come first, one
  program's rows together; only they get a number. Programs that closed without ever being seen are merged per
  protocol + port.
- Menu **V**: several rows at once (`1,3` or `1-3`). The lines are listed, then there is **one** question
  (`Add-WHDProgramAllows -Items <rows>`); a single row still goes through `Add-WHDProgramAllow`. The refusals are
  unchanged: inbound rows, Windows service traffic (`svchost.exe`, `System`) and rows that are not TCP/UDP.
- `Get-WHDProgramAllowName` gives the rule name `WHD-App-<exe>-<proto>-<port>` in one place (the allow and the view).

### 1.5 - wipe (menu 9 -> W) shows progress and an honest result
- Rules are deleted one by one; the wipe shows a progress count (`Write-WHDProgressStep`, a log line every 50 rules).
- It says how many rules could not be deleted and were left in place, in the log and in the final line.
- After a DRY-RUN it says "preview only - nothing was deleted" (no "Wipe complete"); if the wipe did not run (the
  firewall backup failed, for example) it says "Wipe NOT done".
- Unchanged: the question before the wipe, the warning when outbound is Block, and the baseline option.
- Small fixes: `Remove-WHDFwGroup` prints no result row; the firewall log size is read only when the log file exists.

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
