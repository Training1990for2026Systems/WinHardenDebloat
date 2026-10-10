> **WinHardenDebloat (WHD)** - by **Training1990for2026Systems** - contact: t90018273@gmail.com
> License: [MIT](LICENSE) - Security reports: see [SECURITY.md](SECURITY.md) - Built with Claude by Anthropic.

**Version: Classic 1.5** (2026-10-05, additions 2026-10-06; released 2026-10-10; live-tested 2026-10-06 and 2026-10-08 in the console menus - "v1.5 - live test" below says what was run and what was not) - runs on Windows PowerShell 5.1, which is built into Windows.

# WinHardenDebloat

Native, offline toolkit to debloat and harden a fresh **non-domain Windows 11** install.
No third-party APIs. Everything runs on Windows PowerShell 5.1, DISM and the registry (the inventory also reads the AppLocker policy).

## Read this before you run it

WHD changes Windows security, network, update and privacy settings and removes apps. It is released under the
[MIT License](LICENSE): **as is, with no warranty**. You run it at your own risk.

- **Tested on one PC only:** a Windows 11 Home laptop (versions 25H2 and 26H2). Other editions, versions, languages and
  hardware are untested.
- **Try it on a spare PC or a fresh install first**, and back up anything you cannot lose.
- **Start with a dry run.** WHD opens in DRY-RUN mode and only shows what it would do. Nothing changes until you switch to EXECUTE.
- **Read what a profile does before you apply it.** `profiles\standard.json` and `profiles\validated.json` are the strict setup of
  the one test PC, not a general default. Among other things they delete every Windows Firewall rule, turn off file sharing (SMB),
  the built-in VPN and dial-up, remove the WAN Miniport devices, turn off IPv6, set DNS to Cloudflare, switch ransomware folder
  protection and the attack-surface rules to BLOCK, set password and lockout rules, remove Paint and Photos, uninstall OneDrive, and
  stop automatic Windows, driver, Store and Edge updates. `profiles\lean.json` is the small starter profile.
- **If you turn off automatic updates, installing security updates is up to you.**
- **Not everything can be undone.** WHD tries to make a System Restore point before the first change and records every change, but:
  - removing a Store app removes it for all users and deletes that app's local data (for example notes that were never synced);
    undo means reinstalling the app;
  - uninstalled desktop programs, deleted scheduled tasks and autostart entries (Win32 menu **R**), DISM ResetBase and removed
    WAN Miniports do not come back through the Undo center;
  - most firewall changes are undone by restoring that session's firewall backup (Undo center **F**), not one by one;
    DNS and IPv6 are put back with Firewall **U** (DNS back to automatic) and Firewall **3** (re-enable IPv6);
  - if Windows cannot create the restore point, WHD warns and continues.
- **Keep the WHD folder outside Documents, Pictures, Videos, Music, Favorites and Desktop** (for example `C:\WHD`). Ransomware
  folder protection in BLOCK mode (Security+ **3B**; `standard.json` and `validated.json` switch it on) does not treat PowerShell as
  a trusted app, so WHD may then be unable to write its log, change history and backups in those folders. WHD warns when it sees this.
- **If you lose the network:** Firewall **8** (revert default-deny), Updates **O** (open the update gate), Undo center **F**
  (restore the firewall saved before that session), or in an administrator window `netsh advfirewall reset`.

Guides in `docs\`: `firewall-module.md`, `standard-reimage.md`, `radio-group-test.md`, `update-review-2026-09-29.md`.

---

## Phase 1 — Module 1: Inventory (read-only)

`Inventory.ps1` **changes nothing**. It reads the machine and writes a full inventory
(CSVs + a readable `REPORT.txt`) into a timestamped folder under `inventory\`.

### What it captures
- **Installed/running vs provisioned/staged** Appx packages, correlated and state-tagged
  (`both` / `installed-only` / `staged-only`).
- The four surfaces: `SystemApps`, `WinSxS` (via optional features + capabilities),
  `System32\AppLocker` (effective policy + AppIDSvc enforcement state), and the
  Installed-apps view (Win32 uninstall registry).
- Every **AI surface** flagged: Copilot, Cortana, Power Automate, Recall (optional feature),
  Web Experience/Widgets, and integrated AI apps (Notepad, Paint, Photos).

### Run it
Open **Windows PowerShell** (the script self-elevates via a UAC prompt if not already admin):

```powershell
cd "C:\path\to\WinHardenDebloat"   # the folder you unpacked or cloned
powershell -ExecutionPolicy Bypass -File .\Inventory.ps1
```

Admin is needed for the provisioned-package and effective-AppLocker reads. Without it the
script still runs and clearly marks those two sections as skipped.

### Output
`inventory\<timestamp>\` containing:
`REPORT.txt`, `appx-packages.csv`, `ai-packages.csv`, `systemapps.csv`,
`optional-features.csv`, `capabilities.csv`, `win32-apps.csv`,
`applocker-*.{csv,json,xml}`, `os-info.json`, `winsxs.json`, `run.log`.

---

## Safety model (all later modules)
- **Dry-run by default.** Destructive functions preview only; an explicit `-Execute` gate commits.
- **Capture before change.** Registry keys, package lists, and service states exported to
  `restore\` first, plus a System Restore point.
- **Per-module block strength.** Each module offers its own reinstall-block options at runtime.
- **Full transcript** of every run to `logs\`.

## Run the launcher (Phase 1)

**See the full plan without picking anything (recommended first):**
```powershell
cd "C:\path\to\WinHardenDebloat"   # the folder you unpacked or cloned
powershell -ExecutionPolicy Bypass -File .\WHD.ps1 -Plan
```
`-Plan` is non-interactive: it prints every feature-off / remove / suppression
action it *would* take for all AI surfaces, writes it to `logs\run_*.log`, and
exits. No menu, no selecting, nothing changed.

**Interactive menu (most reliable way):** open PowerShell **as Administrator
first**, so the menu runs in that same window and your keystrokes reach it:
1. Start menu → type `PowerShell` → right-click → **Run as administrator**.
2. Then:
```powershell
cd "C:\path\to\WinHardenDebloat"   # the folder you unpacked or cloned
powershell -ExecutionPolicy Bypass -File .\WHD.ps1
```
Opens the menu in **DRY-RUN** mode (nothing changes). If you run it from a
*non*-admin window, it will offer to open a separate elevated window — but that
separate window is easy to lose focus on, which is why running from an already-
elevated terminal is preferred. The elevated window is titled
"WinHardenDebloat (Administrator) - type here". Options: run inventory,
AI debloat (feature-off / remove per surface), toggle to EXECUTE mode. In
EXECUTE mode every action still asks y/N and a System Restore point is made
before the first change. `-Execute` starts in execute mode.

Environment note: Windows 11 Home has no AppLocker, so reinstall-blocking uses
registry keys + deprovision + Store suppression. WDAC is a deferred optional add-on.

## Status
- [x] Spec approved
- [x] Inventory module — verified on the test PC
- [x] Safety engine (`modules\Common.ps1`) — dry-run gate, restore point, backups, logging
- [x] AI debloat module (`modules\Debloat-AI.ps1`) — feature-off + app-remove per surface
- [x] Launcher (`WHD.ps1`) — menu-driven, self-elevating, `-Plan` non-interactive mode
- [x] General debloat module (`modules\Debloat-General.ps1`) — curated non-AI apps + privacy/telemetry hardening + DiagTrack
- [x] Permission profiles (`modules\Permissions.ps1`) — Lockdown / Balanced / Open / Custom via CapabilityAccessManager
- [x] Component store maintenance (`modules\Maintenance.ps1`) — DISM analyze / cleanup / ResetBase
- [x] Win32 program removal (`modules\Debloat-Win32.ps1`) — uninstall + find + block re-appearance
- [x] **Phase 2: engine/UI split + JSON profile runner** (`modules\Profiles.ps1`)
- [x] **Phase 3: WPF GUI** (`WHD-GUI.ps1`) over the engine
- [x] **Phase 5: groundwork** — change journal + Undo center (F20), verify-after-apply (F21),
      inventory comparison (A3), wider AI detection (A1)
- [x] **Phase 6: network** — blocked-connection viewer + program allow (D14), offline blocklist
      refresh (D15), time sync to time.cloudflare.com with UDP 123 pinned (see `docs\firewall-module.md`)
- [x] **Phase 7: privacy + AI switch-offs** — A1 policy switches, C11 usage history, C12 per-app (Store apps), C13 privacy settings
- [x] **Phase 8: Security+** (`modules\Security.ps1`, menu **S**, GUI tab **Security+**)
- [x] **Phase 9: update guard (alert only)** — Security+ **G / GR / GO / GX**, scheduled task at sign-in +10 min
- [ ] Phase 3b: packaging (MSI/MSIX/EXE) — optional
- [ ] WDAC optional add-on (deferred)

## GUI (Phase 3)
A native PowerShell + WPF window over the same engine — no compiler, offline.
```powershell
powershell -ExecutionPolicy Bypass -File .\WHD-GUI.ps1
```
Self-elevates. Opens in **DRY-RUN**; tick **EXECUTE (apply changes)** to make real
changes (each destructive action then asks Yes/No, restore point first). Tabs:
Firewall, Updates, Security+, AI, General, Permissions, Win32, Component store,
Profiles, Inventory / Undo. Live log pane at the bottom mirrors `logs\`.

## Phase 2 — profiles (reproduce on a fresh image)
The engine is separated from the UI: the confirm
strategy is injected by the caller and every action records a structured result,
so the menu, the profile runner and the GUI all drive the same functions.
Profiles are JSON in `profiles\`; a starter `lean.json` ships — edit to taste.
```powershell
# preview what a profile would do (no changes)
powershell -ExecutionPolicy Bypass -File .\WHD.ps1 -Apply profiles\lean.json
# apply it (one upfront y/N, restore point first)
powershell -ExecutionPolicy Bypass -File .\WHD.ps1 -Apply profiles\lean.json -Execute
# scripted / unattended (no prompt at all)
powershell -ExecutionPolicy Bypass -File .\WHD.ps1 -Apply profiles\lean.json -Execute -Yes
# write a fresh starter profile to edit
powershell -ExecutionPolicy Bypass -File .\WHD.ps1 -Export profiles\mine.json
```
In the menu: **P** applies a profile, **E** exports one.

## Phase 5 — Undo center, verify, inventory comparison
Every change made in EXECUTE mode is now recorded, one line per change, in
`restore\<session>\journal.jsonl`, with the value that was there **before**.

- **Undo center** (menu **U**, GUI tab **Inventory / Undo**): pick a session, then undo
  one change, several (`3,5,7`), or the whole session. Undo runs newest-first and is
  itself recorded; registry undos can be undone again.
  - `auto`: registry values (exact old value put back, or deleted if it did not exist),
    the DiagTrack service start type, and optional features (re-enable).
  - `manual`: removed apps (reinstall from the Store) and other actions. Use the
    session's backups: **F** restores the firewall saved before that session
    (replaces the whole policy), **H** restores the hosts file, **R** imports the `.reg`
    exports of older sessions (from before the journal existed).
- **Verify** (menu **V** = all sessions, or **V** inside a session): reads every recorded
  change back and reports `PASS`, `CHANGED` (Windows or something else reset it) or
  `RETURNED` (a removed app is back). Read-only, safe in any mode. Registry writes
  are also read back at the moment they are made, and a profile apply ends with a verify.
- **Inventory comparison** (menu **D**, GUI "Compare last two scans"): lists what
  appeared, disappeared or changed between two scans. Anything WHD removed that is
  back is marked `CAME BACK`. Every new scan also compares itself with the previous
  one in `REPORT.txt` and writes `DIFF-vs-<older scan>.txt/.csv`.
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\Inventory.ps1 -Compare
  powershell -ExecutionPolicy Bypass -File .\Inventory.ps1 -Compare -Old 2026-09-21_165914 -New 2026-09-22_185656
  ```
- **AI detection** now also flags OS AI components: CoreAI, AIX, AI Fabric, AugLoop,
  the agent/MCP package (`MdOdrMcpFilterPackage`), voice/caption packages in
  `SystemApps\SxS`, Widgets runtime and the Microsoft 365 Copilot app. These are
  flags only; the system ones cannot be uninstalled (switch-offs come in Phase 7).

## Phase 6 — firewall additions (menu 9)
- **M / O**: Windows Firewall log on/off (default file, dropped + allowed, 32,767 KB; v1.3).
- **V**: view blocked connections and allow a program on that port (outbound only; Windows
  services and inbound are refused). **G** removes all program allows.
- **T / N / S**: time sync to time.cloudflare.com (UDP 123 pinned **+ 1 h time-jump limit**, refused jumps alerted by the update guard) / Windows default (and default time settings) / status. NTS (authenticated time) is not included: the Windows Time service does not support it.
- **F**: refresh the IP blocklist from files in `profiles\incoming` (preview → merge or replace →
  optionally rebuild rules). GUI: Firewall tab, including a "Blocked connections" sub-tab.
- **Block lists are not included in this repository** (they are other people's data). Put your own list files in
  `profiles\incoming` (WHD creates the folder) and use **F**. Until you do, **9** (Block IP list) and **H** (Hosts sinkhole)
  report "not found" and change nothing.
All of it is recorded in the journal. The firewall log setting, program allows, the time-sync registry values and the blocklist
file undo automatically from the Undo center (menu **U**). Rules, default actions, DNS and IPv6 are listed there as manual:
use that session's firewall backup (**F** in the Undo center) and the reset options in the Firewall menu.

## Phase 7 — AI switch-offs, privacy, permissions
- **AI (menu 2 / GUI AI tab):** new policy switches — *Click to Do + Settings AI agent*,
  *Recall snapshots (extra lock)*, *Paint AI*, *Notepad AI*, *Edge: Copilot + sidebar*,
  *Edge: on-device AI model + AI themes*. The list shows each one as `on / partly / OFF(set)`.
  These are Microsoft policies documented for Pro/Enterprise; on Home they are best-effort, and Verify
  shows whether the values stuck. The OS AI platform (CoreAI, AI Fabric) still can't be removed.
- **More privacy settings (menu 3 → S / GUI General tab; from 1.5 several at once, see v1.5):** activity history, clipboard history + sync,
  ads/suggestions/account nags, online speech + inking/typing data, Edge background/startup/shopping,
  Edge diagnostics/personalization. Profile key: `"privacy": ["activity", ...]` (empty by default).
- **Usage history (menu 4 → 5 / GUI Permissions → Usage history):** which apps last used the camera,
  microphone or location and when, including "in use now". Read-only.
- **Per-app permissions (menu 4 → 6 / GUI Permissions → Per-app):** Store apps only, allow/deny per app
  (e.g. `3 d` or `1,4 a`). The global switch still wins.
Everything is journaled — Undo center (**U**) and Verify (**V**).

## Phase 8 — Security+ (menu S / GUI tab "Security+")
- **R. Security report (read-only):** Defender (real-time, tamper protection, signature age, PUA /
  network / folder protection, ASR counts), memory integrity, LSA protection, Secure Boot, UAC level,
  password + lockout policy (`net accounts`) and the four old protocols.
- **Defender:** 1 = block unwanted apps (PUA) ON · 2 = network protection AUDIT (2B = BLOCK) ·
  3 = ransomware folder protection AUDIT (3B = BLOCK). Each line shows the live setting `(now: ...)`.
- **Attack-surface rules (start in AUDIT):** 4 = Microsoft standard 3 · 5 = script + download (4) ·
  6 = Office / Adobe / email (7). **L** lists state, **E** shows what they caught (Defender log,
  7 days), **K** switches every audited rule to BLOCK. ASR works on Home (Microsoft Learn: "any
  edition of Windows that includes Microsoft Defender Antivirus (for example, Windows 11 Home)").
- **Old protocols (P1-P4, PA = all):** LLMNR, NetBIOS over TCP/IP (every adapter), WPAD, Remote Assistance.
- **U. UAC -> Always notify** (only if not already).
- **W. Password + lockout rules** (local accounts, via built-in `net accounts`): minimum length 14,
  remember 5 old passwords, never expire, lock after 3 wrong tries for 10 minutes, bad-try counter
  resets after 10 minutes. Only values that differ are changed; the current password keeps working
  (the minimum applies at the next change). Microsoft-account passwords are not affected.
Memory integrity and LSA protection are **report only** (user decision).
Every change is journaled (kinds `mppref`, `asr`, `reg`, `netacct`) — Undo center **U** / Verify **V**.
Profile key `"security"` (default all off; `"passwordPolicy": true` adds W) can apply the same set on a new machine.

## Phase 9 — Update guard (alert only; Security+ G / GR / GO / GX)
Checks after Windows updates that nothing WHD set or removed has quietly come back. **It never changes anything.**
- **G. Install / refresh:** copies `WHD.ps1`, `Inventory.ps1` and `modules\*.ps1` to
  `C:\ProgramData\WinHardenDebloat\guard` (owner Administrators; Administrators + SYSTEM full,
  Users read-only) and adds scheduled task `\WinHardenDebloat\UpdateGuard`: **10 minutes after you
  sign in**, runs as you with highest privileges, only while signed in. The copy is locked (standard users
  can only read it) to make it harder for a user-level program to edit the scripts the task runs. **Press G again after updating
  the tool** to refresh the copy. Undo (U) or **GX** removes the task and the copy.
- **Each check:**
  1. Skips if Windows is waiting for a restart; waits up to 30 min if updates are still installing.
  2. **Verify ALL**: every journaled WHD change, latest state per item.
  3. **Inventory scan only if Windows changed** (build/UBR or installed-update list; daily Defender
     signature updates don't count). Compares with the previous scan and flags **CAME BACK** apps.
     Keeps the last **5** guard-made scans (marked `.whd-guard`); your own scans are never touched.
- **Alert:** the report is always written to `restore\update-guard\guard_<time>.txt` (from 1.5: under
  `C:\ProgramData\WinHardenDebloat\guard-data` once the guard is installed, plus an alert window and an event log entry - see v1.5). It **opens in
  Notepad only if** a WHD change is CHANGED/RETURNED or a removed app CAME BACK. New apps from an
  update are listed but don't pop up. **GR** = run the check now, **GO** = open the last report.
- Profile key `"security": { "updateGuard": true }` (default off). Journal kind `schtask`.

## One-run setup - `profiles\validated.json` (2026-09-25)
> **2026-09-29:** `validated.json` now has exactly the same settings as `profiles\standard.json` (user decision, after radio test
> rounds 1-8 passed). The 2026-09-25 description below is kept for history; the current contents are in `docs\standard-reimage.md`
> and `docs\radio-group-test.md`. Either profile gives the same result.
Repeats everything live-tested on the test PC in **one run** (one yes/no, no menus):
AI feature-off (9) + AI remove (Copilot, Power Automate, Bing, Widgets, Phone Link - **Notepad, Paint, Photos kept**, their AI off),
Store suppression, 21 Store apps, privacy hardening + DiagTrack + 6 extra privacy settings, Security+ (PUA, network + folder
protection BLOCK, 14 ASR in Audit, LLMNR/NetBIOS/WPAD/Remote Assistance off, UAC Always notify, password rules), permissions
Balanced, **network** (time.cloudflare.com + 1 h jump limit, firewall baseline, Cloudflare DNS + DoH, blocked-connection logging),
component cleanup, and the **update guard last**.
**Not included:** default-deny outbound (turn on by hand after: Firewall 6, then 7), per-app microphone denials.
**Fresh install order:** Windows Update until done → copy the tool → Inventory (1) → `WHD.ps1 -Apply profiles\validated.json`
(dry run) → same with `-Execute` → restart (IPv6 change) → V (verify) → Inventory (1) again → Firewall 6 + 7 if wanted.
**On a PC that is already set up, start with the dry run** and read the list before adding `-Execute`.
New profile section `"network": { "timeSync", "firewallProfile", "dns", "connectionLogging" }`.

## v1.1 - per-PC history (2026-09-27)
Every recorded change now carries this PC's MachineGuid (a new one comes with every Windows install, and it survives a rename).
Verify, the update guard, the Undo center and the inventory's CAME BACK flags only use **this PC's** history, so a
project folder copied from another PC or an earlier install no longer causes false alerts.
- History made before v1.1 has no tag. It is sorted by date: sessions older than this Windows install are treated as
  another PC's and hidden.
- **Undo center H** (GUI: Inventory / Undo tab, "Archive other-PC history") moves those sessions to
  `archive\other-pcs\<date>\` (nothing is deleted) and tags this install's untagged sessions as this PC's.
- Writing the change history retries up to 8 times if the file is briefly locked (OneDrive, antivirus).

## v1.1 - Updates menu (W) / GUI tab "Updates": stop auto-installs (2026-09-27)
Why: on the re-imaged PC, Windows' separate background installers (Microsoft Store, Device Setup Manager with drivers +
manufacturer apps, Windows Update's services, app self-updaters) downloaded over HTTPS and installed things while Settings >
Windows Update still waited for you. The old allow-list keeps HTTPS open to **every** program, so "default-deny" didn't stop them.
- **Update gate - C close / O open.**
  - **Closed:** outbound default-deny. HTTP/HTTPS is allowed only for **Microsoft Defender** (WinDefend, WdNisSvc, MsMpEng /
    MpCmdRun in the current platform folder, MpCmdRun in Program Files, SmartScreen) and **DNS-over-HTTPS** (Dnscache ->
    1.1.1.2 / 1.0.0.2). The any-program HTTP/HTTPS rules **and every other enabled outbound allow rule** (Windows' built-in app
    rules too) are switched off and remembered. DNS, DHCP and NTP keep working.
  - **Offline while closed:** Windows Update, the Store, drivers, app updaters, browsers (Edge too) and every other app that needs the internet.
  - **Open:** everything the gate switched off comes back, and outbound goes back to what it was. It stays open until you close it.
  - **After Defender updates itself** (new platform folder), close the gate again; Status warns you.
- **Policies (1-4, A = all).** Microsoft documents these for Pro/Enterprise/Education. On Home they are *tried*, and Status shows
  the evidence:
  1. Windows Update `NoAutoUpdate=1`
  2. Drivers: Device Installation Settings = No (`SearchOrderConfig=0`, `PreventDeviceMetadataFromNetwork=1`)
  3. `ExcludeWUDriversInQualityUpdate=1`
  4. Store `AutoDownload=2`
- **E** Edge Update off (its tasks + services). **F** scans non-Windows scheduled tasks and services named update / updater /
  maintenance; you pick which to turn off. All journaled (Undo center, Verify, guard).
- **D** updates Defender definitions now (source MMPC). With the gate closed it worked in the 2026-10-04 test but failed in the
  2026-10-03 test (cause not known); if it fails, open the gate first (see "live test and known issues"). **S** Status: gate, policies, Windows Update
  installs (14 days), updaters.
- Firewall fixes:
  - a firewall profile never lowers outbound from Block to Allow
  - rebuilding the allow-list keeps HTTP/HTTPS off while the gate is closed
  - "revert default-deny" refuses while the gate is closed (use O)
- The update guard report shows the gate state (information only, not an alert).
- `validated.json` has `"updates"` (all four policies, Edge updater off). Both shipped profiles now leave the
  **update gate open** (`"gate": ""`); set `"gate": "closed"` in your own profile to close it as the last step.
  The profiles are meant to be run before the PC first goes online.

## v1.2 - network services off + permission Lock (2026-09-27; live-tested 2026-09-28/29, see `docs\radio-group-test.md`)

**Security+ N1-N6 / NA** (GUI: Security+ tab, "Network services"). Each group sets the services' registry
`Start` value to 4 (Disabled), stops them if running, and is journaled (Undo center + Verify). Restart afterwards.

| Key | Turns off |
|---|---|
| `fileshare` | Workstation (LanmanWorkstation) + Server (LanmanServer): no file/printer sharing, no mapped drives |
| `smb` | SMB1=0 + SMB2=0 (server), client drivers mrxsmb20/mrxsmb10, SMB1 optional feature if on |
| `dialvpn` | RasMan, RasAuto, SstpSvc, RemoteAccess, TapiSrv: Settings VPN / Dial-up stop working |
| `ipsec` | IKEEXT, PolicyAgent (built-in IPsec/IKEv2/L2TP VPN) |
| `proxy` | Settings > Proxy "Automatically detect settings" OFF (this user). The WinHTTP proxy service is **not** touched |
| `faxphone` | Fax (if present), PhoneSvc |

If networking misbehaves after a restart, undo `proxy` first, then `dialvpn`.

**Side effect of `fileshare`:** with the Workstation service off, Windows locks the buttons under Settings > System > About >
"Domain or workgroup" (System Properties, tab Computer Name): "Change..." (computer name, workgroup, domain) and
"Network ID...". Seen on the test PC; that the service is the cause was not confirmed there by switching it on again.
To use those buttons: undo `fileshare` (Undo center), restart, make the change, then apply `fileshare` again. On
Windows 11 Home the domain choice and "Network ID..." are not available in any case.

**Do not use N7** (WinHTTP proxy *service* off). It is a test-only item: on the test PC it stopped Windows Connection Manager and
WLAN AutoConfig from starting, so Wi-Fi showed "Dormant" with no internet (details in `docs\radio-group-test.md`). It is never
part of NA or a profile. If you did use it: Undo center, that session, then restart.

**Permissions L = Lock** (GUI: Permissions tab, "Lock"). Why: a plain registry Deny is not always what Settings
shows; Windows can write per-user values back to Allow. Lock sets every switch to Deny (user, PC-wide, and
"desktop apps" where it exists) and adds Windows' App Privacy policy **Force Deny** (value 2) under
`HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy` for 11 categories, so Settings shows them OFF and greyed.
Camera, microphone, radios and location: OFF but not locked (user's choice; location added 2026-09-29). Verify and
re-apply leave these four switches alone, so switching one on in Settings is never undone by WHD. Documents/Pictures/Videos/Cellular/File system have no
policy, so Deny only. Microsoft lists these policies for Pro and up; on Home they are tried; check Settings after a restart.

`profiles\validated.json` now uses `"permissions": "Lock"` and `security.servicesOff` (all six).

## v1.2 - Devices menu N / Security+ tab "Devices" (2026-09-27; live-tested 2026-09-28/29, see `docs\radio-group-test.md`)

| # | What | Why it's safe to lose |
|---|---|---|
| 1 | **Bluetooth network part only**: "Bluetooth Network Connection" (PAN) adapter: DHCP off + autoconfiguration (169.254.x.x) off, then the adapter disabled | Bluetooth mouse, keyboard and headset keep working; only networking over Bluetooth stops |
| 2 | **Wi-Fi Direct virtual adapters** ("Local Area Connection* N"): disabled; WFDSConMgrSvc + icssvc off; re-install blocked | Used only for Mobile hotspot, Miracast casting, Nearby sharing, Phone Link. Normal Wi-Fi is unaffected |
| 3 | **WAN Miniports** (IKEv2, IP, IPv6, L2TP, Network Monitor, PPPOE, PPTP, SSTP): re-install blocked FIRST, then removed with `pnputil /remove-device` | Only for dial-up, the built-in VPN and PPPoE; the ISP router does the connecting |

**Re-install block** = Windows Device Installation policy "Prevent installation of devices that match these device IDs"
(`HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions`, `DenyDeviceIDs=1` + ID list). Microsoft lists it for
Pro and up; on Home it is tried. After a restart, **Devices > S** shows whether anything came back.
WAN Miniports came back before because RasMan re-creates them; keep **Security+ N3** (dial-up/VPN off) on.
Undo: registry and device changes undo automatically. Removed WAN Miniports are a **manual** undo: remove the block
lines in the Undo center, turn RasMan back on, then use Settings > Network & internet > Advanced network settings > Network reset.
New journal kind `pnpdev` (device enable/disable; auto undo + Verify).

## v1.3 - standard re-image (2026-09-28)

- **`profiles\standard.json`** = the standard re-image (what was deployed on 2026-09-28, plus the user's choices). Details: `docs\standard-reimage.md`.
  Dry run: `powershell -ExecutionPolicy Bypass -File .\WHD.ps1 -Apply profiles\standard.json`; real run: add `-Execute`.
- **Radios** are now handled like camera and microphone in the Lock profile: OFF, not locked. A previous Lock on radios is removed.
- **Firewall log** (Firewall M / O, GUI "Firewall log ON"): Windows' own log, default file, dropped + allowed, 32,767 KB. Replaces the
  Security-log / 5157 method; the Blocked-connections view reads the firewall log (program shown when the process is still running).
- **Removed apps stay removed:** a Deprovisioned mark is written for every removed app (journal kind `deprov`); **V** offers to re-remove
  apps that came back; GUI "Re-remove apps that came back".
- **Update guard:** its protected copy is refreshed automatically at start when WHD's files changed (in any mode, dry run included); **GU** works in every menu; GUI top-bar button.
- **Profile option** `network.firewallWipeFirst` (delete all firewall rules before WHD adds its own).
- **One-key re-apply:** when Verify (V) or the guard finds a setting that changed back (any menu, P1-P4 included), V offers to put it
  back; GUI Inventory/Undo > "Re-apply settings that changed back". Note: NetBIOS is only re-applied on adapters WHD already changed -
  run P2 again after a new adapter appears.
- **Radio problem test plan:** `docs\radio-group-test.md` (one group at a time, Wi-Fi Direct first).
- **`tools\Diag-Radio.ps1`** (read-only): snapshots before/after switching a radio on, plus events, to find what turns it back off.

## v1.4 (Classic) - Time & region (2026-09-30; live-tested)

- **Main menu T** (also **Firewall Z**; GUI Firewall tab "Time zone + date/time"): the same settings as
  Settings > Time & language > Date & time.
  - **1. Pick time zone:** short list of US zones (Hawaii, Alaska, Pacific, Arizona, Mountain, Central, Eastern) or **S** to search
    every Windows time zone by city / country / name. Journal kind `tz`: Undo center puts the old zone back; **Verify / the update
    guard watch it and re-apply puts it back** if something changes it (user decision).
  - **2. Set date and time by hand** (`yyyy-MM-dd HH:mm`, local time). Automatic sync stays on (user decision). Under 1 hour off,
    sync corrects it back at the next sync; more than 1 hour off, WHD's 1 h jump limit keeps the typed time. Journaled as an action
    (the clock keeps running, so undo = set it again or Sync now).
  - **S. Status:** zone, local + UTC time, daylight saving, time source, last successful sync.
- No automatic time zone (it needs location on; user decision).

### v1.4 - Apps found on this PC (adaptability, 2026-09-30; menu listing live-tested)
- General debloat (menu 3, GUI General tab) now lists, under the fixed list, **every non-Microsoft app found on the PC WHD
  is running on** (frameworks, resource packs and non-removable parts left out), with its publisher and "staged" when it was
  also provisioned for new users (how driver/OEM apps arrive). Nothing is hard-coded per PC model - a different PC shows its own apps.
- Store/Appx apps only: classic desktop programs (for example Zoom) are in Win32 programs (menu 5).
- The four fixed OEM entries added 2026-09-29 (two audio apps, a microphone app and a graphics app from the PC maker) are gone; the user had already removed those apps,
  and their removals stay in the journal, so Verify / re-remove still covers them.
- Profiles: **`general.oem = "ask"`** (in standard.json and validated.json) lists the found apps during a profile run and asks
  which to remove (console only; GUI / `-Yes` runs list them and skip).

### v1.4 - Clean publish copy (2026-09-30; live-tested)
`powershell -ExecutionPolicy Bypass -File .\tools\Build-PublishCopy.ps1` (no admin) builds `publish\WinHardenDebloat_<date_time>\`
with code, WHD's own profiles, README, Run.txt, the general guides and the test write-ups. This PC's details are replaced
(computer name, user folder, MachineGuid, adapter GUIDs/MACs, serial/UUID, plus `-ExtraTerms`; in .md/.txt also e-mail
addresses and private IPs). A leak scan re-checks the output; `SHA256SUMS.txt` and a `PUBLISH-REPORT_<date_time>.txt` are
written. The working folder is only read. Left out on purpose: logs, inventory, restore, archive, block lists (other people's
data - check their licenses), planning docs.

## v1.4.1 - pre-release review fixes (2026-10-03; live-tested 2026-10-03 on a fresh Windows 11 Home 26H2 image - see "live test and known issues" below)

- **Default-deny outbound (Firewall 6):** the auto-rollback is now a one-time SYSTEM task with no script file. It works when the
  WHD folder path contains spaces, across midnight, and on battery. Default-deny is **not** switched on if the task cannot be armed
  or the DNS / DHCP allow rules are missing. "Confirm keep" (7) reports the real state.
- **Firewall menu:** every option that changes something asks y/N in EXECUTE mode (Wipe included). Wipe warns when outbound is
  Block. If the firewall backup cannot be taken, the change is not made. Rule names containing `* ? [ ]` are refused. The first
  hosts backup of a session is kept, and only plain host names are written to the hosts file.
- **Update gate:** refuses to close while a network adapter does not use the pinned DNS servers (set DNS first: Firewall D).
  Its state is saved before the change. Open does nothing unless the gate is closed.
- **Win32 programs:** uninstallers start with correct quoting and their exit code is checked (a failed uninstall is reported
  FAILED). See menu 5 below for R and X.
- **Engine:** registry writes use literal paths; a key's `.reg` backup is taken once per session (the state before WHD's first
  change); restoring a hosts backup no longer overwrites that backup; an error in a menu action returns to the main menu; a warning
  is shown when WHD was elevated with a different account than the signed-in user; WHD refuses to start in PowerShell 7.
- **Profiles:** the "This profile will ..." list is shown in the GUI log before the confirm; a run that stops on an error says
  ABORTED; the shipped profiles' descriptions say what they do and that they are provided as is.
- **Permissions:** Open and Balanced remove the Lock policy values, so the switches can be changed again. Running Lock again
  switches camera, microphone, radios and location off again (still not locked).
- **Updates / Devices / Component store:** "app updaters off" works with exactly one updater; pnputil's "restart needed" result
  counts as success; a failed DISM run is reported FAILED.
- **Update guard:** permissions already on a pre-existing `C:\ProgramData\WinHardenDebloat` folder are reset, a link (junction)
  there is refused, and the guard alerts when it finds no WHD change history (for example after the WHD folder was moved).
- **Wording:** texts that referred to the author's PC were made neutral. `.gitattributes` keeps files byte-for-byte, so
  `SHA256SUMS.txt` also matches for a Git clone. The 1.4 step in this branch's history still shows the earlier wording: one
  note in `modules\Updates.ps1` names two manufacturer apps from the test PC as examples of "manufacturer companion apps". That
  step is kept as it was first uploaded; the names are examples only and nothing in WHD depends on them.
- **Known limits (not changed):** devices and `net accounts` output are matched by their English names, so Devices (N) and the
  password rules (Security+ W) only work on English Windows. DNS pinning (Firewall D) only touches adapters that are up at that moment.

### v1.4.1 - live test and known issues (2026-10-03)

Run through the console menus in EXECUTE mode on a fresh Windows 11 Home 26H2 image (build 26300.9457, Windows PowerShell 5.1).
The run logs show these parts working: privacy and telemetry, AI features off, app removal, permissions, devices, Security+, the
firewall menu (wipe, allow-list, default-deny with its auto-rollback task, IPv6, DNS, firewall log), time sync, time zone, the
update gate and the update policies, inventory compare, Verify (202 of 202 items still in place) and the update guard.
**Not part of that test:** the GUI window, the one-run profile apply (`-Apply`) and undoing changes (Undo center).

Issues found in that test, and where they stand in 1.4.2:

- **OneDrive uninstall was reported FAILED although it worked - fixed in 1.4.2.** OneDrive's uninstaller ends with exit code
  -2147219813, and 1.4.1 counted every exit code except 0, 3010 and 1641 as a failure.
- **Ransomware folder protection in BLOCK mode (Security+ 3B) when WHD runs from a protected folder - warning added in 1.4.2,
  the cause itself is Windows behaviour.** In the test WHD ran from Documents. Right after the protection was switched on, WHD
  could no longer write its change history, the session log stopped, and two registry changes made after that point were not
  recorded (their `.reg` backup was). Microsoft's documentation says script engines like PowerShell are not trusted by this
  protection. In the 2026-10-04 test on the same PC, WHD again ran from Documents with BLOCK on and could write its files, so
  this does not happen every time. Keep the WHD folder outside the protected folders (for example `C:\WHD`).
- **Defender definitions update (Updates D) failed with the gate closed - did not happen again, cause not known.** On
  2026-10-03 it failed three times out of three ("definitions update was completed with errors"). On 2026-10-04, with the gate
  closed, it worked. 1.4.2 no longer promises that it works, logs more detail when it fails, and tells you to try with the gate
  open (Updates O).
- **Wipe all firewall rules (Firewall W) can take minutes - not changed:** about 7 minutes for 447 rules in the test. Let it finish.

## v1.4.2 - fixes from the live test (2026-10-04; checked with a PowerShell parser and simulated runs, **partly live-tested** - see the last point)

- **Win32 programs:** when an uninstaller ends with an unusual exit code, WHD now checks whether Windows still lists the program
  as installed (it waits up to 10 seconds). Gone = reported done and written to the change history. Still listed = FAILED, as
  before. The stray results table that could appear after an uninstall (menu 5, a number or **R**) is no longer printed; the same
  goes for "Disable DiagTrack".
- **Ransomware folder protection:** WHD warns when its own folder is inside a protected folder (Documents, Favorites, Music,
  Pictures, Videos, Desktop, or a folder you added in Windows Security). The warning comes before 3B switches the protection to
  BLOCK (console menu, GUI button and the "This profile will ..." list), and at start-up when the protection is already in BLOCK
  mode. It is a warning only; WHD still does what you confirm. Only the folders of the account WHD runs as are checked.
- **Defender definitions (Updates D):** the menu and log no longer say it works with the gate closed. On a failure WHD logs the
  gate state, the error id and Defender's own error details (event 2001, English Windows), and, when the gate is closed, tells
  you to try with the gate open.
- **Live test of 1.4.2 (2026-10-04, same PC, console menus, EXECUTE):** the Defender definitions update worked with the gate
  closed; the start-up folder-protection warning appeared when WHD ran from Documents; closing the gate, the Updates status,
  Verify and the permission Lock check ran without errors. **Not yet run on Windows:** the new uninstall check (OneDrive had
  already been removed from the test PC) and the warning shown before 3B switches the protection to BLOCK.

## v1.5 - improvements carried over from WHD Next (2026-10-05; checked with a PowerShell parser, simulated runs and two independent reviews, **live-tested 2026-10-06** - see "v1.5 - live test")

WHD Next is the PowerShell 7 line of this project. These parts of it were merged by hand into Classic. Classic stays on
Windows PowerShell 5.1 and still makes no web calls.

- **Several items at once (menu 2 AI, menu 3 General apps, menu 3 -> S More privacy settings; window: AI and General tabs).**
  Type a list instead of one number: `1,3,5`, a range `2-6`, or `*` for the recommended items (marked `*` on screen), also mixed
  (`*,7`). WHD shows one list of what will happen, with each item's own note, and asks **once** for the whole list.
  - AI menu: add the action letter - `1,3,5 r`, `2-6 f`, `* r`. Without a letter WHD asks r / f / c.
  - **`r` in the AI menu changed:** it now removes the app **and** sets its off-switch; an item that cannot be removed (Recall,
    Click to Do, the Edge and Paint / Notepad AI switches) is turned OFF instead. This also applies to a single item.
  - `*` never includes Notepad, Paint, Photos or the "found on this PC" apps. General `A` is the same as `*` and asks once.
  - Not accepted: `2 - 6` with spaces, numbers outside the list - the whole entry is refused, nothing is done.
  - Window: "Select recommended (*)" on the AI tab, "Select all" for privacy; the one question shows the list.
- **Update gate: third position PROGRAMS (Updates menu P; window button "PROGRAMS gate"; profile `"gate": "programs"`).**
  Like CLOSED - Windows Update, Store and everything else stay offline - but the programs you allowed in Firewall **V** keep
  working. A program you allow while the gate is CLOSED is saved **switched off** and comes on with PROGRAMS or OPEN.
  Two more Defender programs are let out while the gate is closed (network inspection and the Defender core service; the core
  service also sends Defender telemetry). The firewall screen and the Updates status show the gate position.
  After an upgrade from 1.4.2, allows made while the gate was closed are still on: the status says so; press C or P once.
- **Blocked connections (Firewall V; window: Firewall tab).** A program is named only if it was running before the logged
  line, so a reused process number no longer shows the wrong name. Names are remembered for 7 days
  (`restore\update-guard\blocked-programs.json`), so a program that has closed keeps its name. Each row says whether it can be
  allowed (already allowed, covered by the allow-list, Windows itself, inbound, closed program). Allow several rows at once:
  `1,3` or `1-3`, one question.
- **Firewall wipe (W)** shows a count while it deletes, says how many rules could not be deleted, and no longer says
  "Wipe complete" after a dry run.
- **Update guard.** Once the guard is installed or refreshed (**GU** / G), its reports, status and its own scans are kept in
  `C:\ProgramData\WinHardenDebloat\guard-data`, so ransomware folder protection on the WHD folder cannot stop it. Older guard
  files are copied there once; nothing is deleted from the WHD folder. If a report still cannot be saved, the guard says so and
  raises an alert instead of stopping silently. The guard status is tagged with the PC, so a copied WHD folder does not bring
  another PC's status along. **On an alert** a small window shows the result ("Open the report" / "Close") and a Warning is
  written to Windows Logs > Application (source `WinHardenDebloat`, event 1001).
  - The change history, `update-gate.json` and `blocked-programs.json` stay in the WHD folder.
  - Menu **D** (compare scans) no longer sees the guard's scans; the guard compares against its own.
  - **GX** removes the task, the protected copy and the event log source; `guard-data` is kept.
  - **The protected copy is locked more tightly.** A new `C:\ProgramData\WinHardenDebloat` folder is created already locked.
    On a refresh the lock is set again without first resetting it, and nothing is changed unless the folder and every folder
    inside it is WHD's own (owner Administrators / SYSTEM, nobody else may write, no link anywhere inside). If that is not
    so, **GU refuses** and says which folder and why: look at it, delete or rename it as administrator, press GU again.
    Hidden files in the script folder are removed on a refresh.
- **Security+ E** (what the attack-surface rules caught) prints each item on its own lines with the full program and path;
  identical events are grouped with a count.
- **Safety fixes found while merging:** "Enable default-deny" (Firewall 6) does nothing while the update gate is CLOSED or on
  PROGRAMS (before, its auto-rollback could set outbound back to Allow and so open the gate without a word); a JSON firewall
  import keeps the web rules off while the gate is closed; the gate is recorded "open" only when the change succeeded.
- **Window version:** every Yes / No question now has **No** as its default button (Cancel in the block-list question), so a
  stray Enter no longer confirms a change.
- **Small things:** no stray result tables in any menu; an error message also says which file and line; fewer error lines in
  the log when reading permission switches and the firewall log size.
- **Known limits of 1.5:** In the blocked-connections view, a second program with the same file name, protocol and port in
  another folder is shown as "allowed already". The guard's check of the permissions on `C:\ProgramData\WinHardenDebloat`,
  and creating that folder already locked, were built with stand-ins; in the live test the guard installed and refreshed
  its protected copy on a real PC. If the check misreads a real folder, GU refuses to install or refresh the guard and
  says why.

### v1.5 - added on 2026-10-06: rules WHD did not make, and the gate and firewall tools tell each other's changes (checked with a PowerShell parser, simulated runs and independent reviews, **partly live-tested 2026-10-06** - see "v1.5 - live test")

Found in the first run of 1.5 on a real PC (2026-10-06) and built the same day. The update
gate switches other outbound allow rules off only at the moment it is set. Windows and program installers write firewall
rules of their own afterwards - a Store rule came back after the wipe, and an installed desktop program brought wide allow
rules with it - and such a rule lets its program out through a CLOSED or PROGRAMS gate. Nothing reported it.

- **Rules WHD did not make (Firewall menu K, Updates menu K; window: Firewall tab > "Rules from others").** WHD looks for
  allow rules that are ON and that it did not make. It raises an alert for:
  - **outbound** rules while outbound is Block (gate CLOSED / PROGRAMS, or default-deny) - always. With outbound open, an
    outbound allow rule changes nothing and is not listed.
  - **inbound** rules - only after you switched their watch on (see "Inbound rules" below). Until then there is no alert
    for them: a Windows install has a few hundred inbound rules of its own. K says how many there are and lists them when
    you press `L`; the Firewall and Updates menus count them in a hint line when there is no alert.

  The alert shows when WHD starts, at the top of the Firewall and Updates menus, in the Updates status and in the update
  guard's report (alert window). When a rule is there that was not shown yet in this session, WHD opens the list and asks.
  Looking at the list changes and starts nothing. Per rule you choose - `1,3 o`, `2 r`, `* k`, `4 p`:
  - `o` **switch OFF** - the rule stays in Windows' rule list, switched off. The Undo center switches it on again; Verify
    and the update guard report it if something switches it back on (V re-applies it). The update gate does not put a
    rule you switched off here on its list, so opening the gate does not switch it back on.
  - `r` **remove** - the rule is deleted. WHD saves the firewall once per session, before the session's first firewall
    change; Undo center F puts that whole firewall back, with every later firewall change of that session reverted too.
    Windows or the program may write the rule again; WHD then reports it again.
  - `k` **keep** - the rule stays on and is not reported again. A kept outbound rule stays on through the gate; Status, the
    menu head lines and the guard report name the kept outbound rules that are ON while outbound is Block. WHD keeps a
    rule by its name: if the rule is changed later, or another rule gets that name, it still counts as kept. A rule you
    had switched off earlier and keep now is no longer held off by Verify / the guard.
  - `p` **one port only** - for an outbound rule that names one program file: WHD makes its own allow for that program (TCP,
    one remote port, 443 unless you type another - the same kind of rule Firewall V makes) and switches the wide rule off.
    The allow is tied to that exact file: when the program moves or updates into another folder, it is blocked again.
    Allowing the new file then moves the allow to it when the old file is gone. A Store-type app, a service or an "any program" rule has no program file: use o, r or k. Two
    programs with the same file name in different folders cannot both get a WHD allow on the same port (the rule name is
    built from the file name): while both files exist the second one is refused and left as it is. Firewall V goes by
    that rule name too, so it lists the second program as allowed already; undo the first allow (Undo center) to change it.
  - **Inbound rules: `S` in K (window: the button "Watch inbound rules...").** Only in EXECUTE, and only when you say so.
    WHD asks how to start: **N** = report only rules that appear from now on (the inbound rules present now count as
    kept), or **A** = list all present ones too, until you keep, switch off or remove each one (in the window: Yes = N,
    No = A with one more question, Cancel = do not start). A wipe, a reset, a `.wfw` import and a firewall restore (Undo
    center F) that was done also switch the watch on - their own question does not say so, the log line after it does:
    the **inbound** rules such a tool leaves behind count as kept. Not counted, so that you decide: a rule you had
    switched off or removed with WHD that the tool brought back on, and rules that were listed as not decided before the
    tool ran. Outbound rules are never counted as kept by a tool.
  - `F` in K (window: "Forget kept rules") forgets the rules **you** kept with `k`; they are listed again. The inbound
    rules that were counted as kept at a start stay counted. Everything is stored in
    `restore\update-guard\firewall-known.json` (this PC only); deleting that file puts it all back to the start (inbound
    rules not watched, nothing kept).
- **The gate names what it switches off.** Before its question, C and P list the outbound allow rules of other tools and
  programs the gate will switch off (the first 12, then a count), and say which rules stay on because you kept them (in
  the window version this list is written to the log pane; the question itself does not repeat it). After it was set, the
  gate names a rule that is still ON. O says which remembered rules no longer exist instead of counting them as put back.
- **The Firewall-menu tools say what they change of the gate** - in lines right before their question, and where the
  tool changes what gets out, in the question itself (the window version puts all these lines in the question):
  - **R** Reset: the gate will be OPEN afterwards (outbound back to Allow). Its record is put right.
  - **W** Wipe: the gate's own rules and your program allows are deleted too; outbound stays Block, so nothing gets out
    until the gate is set again. After a wipe that was done WHD asks whether to set the gate again. In a profile run there
    is no extra question: the profile's step list says it, and the gate is set again in the same position after the
    network steps (or by the profile's own last step, when it sets the gate; if the run stops before that, WHD still
    sets the gate again at the end). A gate that lost its rules is rebuilt even when an adapter is not on the pinned DNS
    servers - WHD says that its name lookups stay blocked until DNS is set. With plain default-deny (no gate) the wipe says that there is no network afterwards.
  - **I** import of a `.wfw` file, and **Undo center F** (restore the firewall backup): they replace every rule and the
    outbound setting. Afterwards WHD reads where the gate stands, puts its record right and, if the gate lost its rules,
    asks whether to set it again. If the file was saved while the gate was closed and the gate is open now, WHD says that
    outbound is Block again although the gate is recorded as OPEN; C or P then sets the gate properly, and O afterwards
    opens it (outbound Allow, web rules on - also when default-deny was set by hand before). Program allows that come in
    switched on while the gate is CLOSED, or switched off without being on the gate's list, are reported. Undo center F
    saves the current firewall first when this session has no firewall backup yet (one backup per session).
  - **U** DNS back to automatic while outbound is Block: name lookups stop (DNS is only allowed to the pinned servers).
  - **G** Remove program allows: on PROGRAMS these are the programs the gate lets out; on CLOSED they come off the gate's
    list.
  - A reset or import that Windows refuses (netsh reports an error) is reported as failed; nothing else is changed then.
- **Status tells when the gate is not what its record says** (top of the Firewall and Updates menus, Updates status, window
  status boxes, update guard): its own rules are gone or switched off, the DNS / DHCP allows are missing, the any-program web
  rules are on, program allows are on while the gate is CLOSED, Windows Firewall is switched off for a profile, something
  set outbound back to Allow behind the gate (Updates O then puts the record right), or the firewall is as a closed gate
  leaves it while the gate is recorded as OPEN.
- **Copilot off-switch (AI menu 1) also sets two Edge Update policies** - `Install{C50565E9-CCCF-44B4-BA15-5AC5C6569197}` = 0
  and `Update{...same ID...}` = 0 under `HKLM\SOFTWARE\Policies\Microsoft\EdgeUpdate` (Microsoft Learn: "Microsoft Copilot
  update policies for Windows"). Microsoft documents that the Copilot app can be installed and updated through Microsoft
  Edge Update, so an Edge update could bring a removed Copilot back. Documented as Edge Update policies; on Home they are
  tried. If the off-switch was applied with an earlier version, apply it once more to set the two values.
- **Limits:** WHD looks for such rules when it is used and in the guard (10 minutes after sign-in) - not all the time in
  between. A rule that is switched off is not reported. Block rules made by others are
  not reported (they only restrict). Decisions are tied to the rule's name: when Windows writes a rule again under a new
  name (it does that for some app rules), the new rule is reported as new.

### v1.5 - live test (2026-10-06 and 2026-10-08)

Fresh Windows 11 Home 26H2 image, console menus (`WHD.ps1`), Windows PowerShell 5.1, DRY-RUN and EXECUTE.

- **1.5 as of 2026-10-05** was run first in the console menus. It worked. The run showed the gap the additions of
  2026-10-06 close: rules that were written after the update gate had been set got through it.
- **The additions of 2026-10-06** were run the same evening, without errors in the logs:
  - the alert at WHD's start and in the Firewall and Updates menus, and the list that opens by itself;
  - the answers `r` (remove) and `k` (keep); `p` on a service rule was left out, as described;
  - a wipe with the gate on PROGRAMS: the note in the question, the gate's record put right, the gate's own question and
    the gate rebuilt;
  - a reset with the gate on PROGRAMS: the gate recorded as OPEN, Windows' own inbound rules counted as kept;
  - gate P and O, the Updates status, program allows from Firewall V;
  - the Copilot off-switch with the two Edge Update policy values;
  - the update guard: its protected copy refreshed itself with the changed files, and GU installed it again.
- **Second run, 2026-10-08,** on another fresh Windows 11 Home 26H2 install: four console sessions, the same files
  (no script changed since 2026-10-06), the update gate OPEN throughout.
  - AI menu (12 items at once, with the two Edge Update policy values), Store suppression, privacy settings, 20 general
    apps in two batches, component store clean-up;
  - two desktop programs uninstalled: both uninstallers ended with an unusual exit code, both programs were then found
    gone and counted as done (the "still installed" check of 1.4.2);
  - Security+: the 14 attack-surface rules (audit, then block), old protocols and network services off, password rules;
    Devices (N); Time & region (time zone, clock by hand); permission profile Lock;
  - Firewall: IPv6 off, allow-list, firewall log, time sync (T);
  - the update guard installed and refreshed; its check after a sign-in ran and reported OK;
  - **Verify: 85 of 85 items pass, later 114 of 114.**
  - Seen: one Defender definitions update failed ("The remote procedure call failed", gate open); the next one, 90
    minutes later, worked. Windows refused one value, the taskbar Widgets switch; WHD reported it as blocked and went on.
- **Run by the author, not in the kept logs:** the firewall policy export. The answers `o` (switch OFF), `p` on a
  program's rule, `S` (watch inbound rules) and `F` were stepped through once to see that they act; they were not kept
  in use, so **their results are still open**.
- **Not yet run on Windows:**
  - the window version (`WHD-GUI.ps1`) of the additions;
  - Undo, Verify and re-apply for a rule that was switched off;
  - the update guard's report with its new firewall section (the guard has not raised an alert yet);
  - `.wfw` import, Undo center F, DNS reset and "remove program allows" while the gate is set;
  - a profile run with a wipe while the gate is set.

## Menu
```
1. Run inventory (read-only)
2. AI debloat        (feature-off / remove, per surface)
3. General debloat   (non-AI Store apps + privacy/telemetry + DiagTrack)
4. App permissions   (Lockdown / Balanced / Open / Custom)
5. Win32 programs     (uninstall traditional apps + block re-appearance)
6. Component store    (WinSxS analyze / cleanup via DISM)
7. Create a System Restore point now
8. Toggle mode       (DRY-RUN <-> EXECUTE)
9. Firewall
P. Apply a profile      E. Export starter profile
D. Compare inventory scans (what changed)
U. Undo center (list / undo past changes)
V. Verify changes are still in place
S. Security+
W. Updates
N. Devices
T. Time & region  (time zone, set date and time)
Q. Quit
```

## Component store / WinSxS (menu 6)
NEVER hand-delete anything in `WinSxS` (Manifests, SettingsManifests, etc.) — it is
the servicing component store (mostly hard links; the size is inflated) and manual
deletion breaks Windows Update/repair. This menu uses DISM, the supported path:
- **A** = AnalyzeComponentStore (read-only): real reclaimable size + whether cleanup is recommended.
- **C** = StartComponentCleanup: removes superseded components. Safe; keeps update-uninstall.
- **R** = StartComponentCleanup /ResetBase: max space, but you lose the ability to uninstall
  previously-installed updates (a restore point does not undo that). Opt-in, flagged.

## Win32 programs (menu 5)
For traditional desktop apps (not Store/Appx) — e.g. Logi Download Assistant, Zoom:
- Pick a number to uninstall via the app's own (quiet) uninstaller.
- **F** = find an app by name across uninstall entries, Run/RunOnce autostarts, scheduled tasks, and Program Files (finds helpers with no uninstall entry).
- **R** = remove everything matching a name (uninstall + autostart + tasks). Task definitions are saved to `restore\<session>\task_*.xml` first; if an uninstall fails, autostarts and tasks are left in place. WHD's own tasks and the Edge update tasks are never removed.
- **X** = block an .exe from launching via Image File Execution Options (reversible) — stops a helper/updater bringing an app back. Only a plain file name is accepted; critical Windows programs are refused.
Note: Edge / WebView2 / Edge Update / servicing entries are protected and refused.

## Restore points
One per session, attempted automatically before the first change (if Windows cannot create it, WHD warns and continues). Menu **7** makes
one on demand. Inventory (read-only) never triggers one.

## About the creator

WinHardenDebloat is created and maintained by **Training1990for2026Systems**.
Questions and feedback: **t90018273@gmail.com**. Security problems: please follow [SECURITY.md](SECURITY.md).

Built with Claude by Anthropic. WHD is an independent project; it is not made, endorsed or supported by Anthropic or Microsoft.
Released under the [MIT License](LICENSE).
