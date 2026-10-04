> **WinHardenDebloat (WHD)** - by **Training1990for2026Systems** - contact: t90018273@gmail.com
> License: [MIT](LICENSE) - Security reports: see [SECURITY.md](SECURITY.md) - Built with Claude by Anthropic.

# WinHardenDebloat

Native, offline toolkit to debloat and harden a fresh **non-domain Windows 11 24H2/25H2** install.
No third-party APIs. Everything runs on PowerShell, DISM, the registry, and AppLocker.

Full design: see `docs\architecture-spec.md` (or the interactive spec in Claude).

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
cd "$env:USERPROFILE\Documents\WinHardenDebloat"
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
cd "$env:USERPROFILE\Documents\WinHardenDebloat"
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
cd "$env:USERPROFILE\Documents\WinHardenDebloat"
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

Environment note: this machine is **Windows 11 Home** — reinstall-blocking uses
registry keys + deprovision + Store suppression (no AppLocker on Home). WDAC is
a deferred optional add-on.

## Status
- [x] Spec approved
- [x] Inventory module — verified against this machine
- [x] Safety engine (`modules\Common.ps1`) — dry-run gate, restore point, backups, logging
- [x] AI debloat module (`modules\Debloat-AI.ps1`) — feature-off + app-remove per surface
- [x] Launcher (`WHD.ps1`) — menu-driven, self-elevating, `-Plan` non-interactive mode
- [x] General debloat module (`modules\Debloat-General.ps1`) — curated non-AI apps + privacy/telemetry hardening + DiagTrack
- [x] Permission profiles (`modules\Permissions.ps1`) — Lockdown / Balanced / Open / Custom via CapabilityAccessManager
- [x] Component store maintenance (`modules\Maintenance.ps1`) — DISM analyze / cleanup / ResetBase
- [x] Win32 program removal (`modules\Debloat-Win32.ps1`) — uninstall + find + block re-appearance
- [x] **Phase 2: engine/UI split + JSON profile runner** (`modules\Profiles.ps1`, `docs\engine-contract.md`)
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
AI, General, Permissions, Win32, Component store, Profiles, Inventory. Live log
pane at the bottom mirrors `logs\`.

## Phase 2 — profiles (reproduce on a fresh image)
The engine is now separated from the UI (`docs\engine-contract.md`): the confirm
strategy is injected by the caller and every action records a structured result,
so the menu, the profile runner, and a future GUI all drive the same functions.
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
  itself recorded, so an undo can be undone.
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
- **T / N / S**: time sync to time.cloudflare.com (UDP 123 pinned **+ 1 h time-jump limit**, refused jumps alerted by the update guard) / Windows default (and default time settings) / status. See `docs\nts-option3-plan.md` for why NTS itself isn't possible on Windows yet.
- **F**: refresh the IP blocklist from files in `profiles\incoming` (preview → merge or replace →
  optionally rebuild rules). GUI: Firewall tab, including a "Blocked connections" sub-tab.
All of it is journaled, so the Undo center (menu **U**) can reverse it.

## Phase 7 — AI switch-offs, privacy, permissions
- **AI (menu 2 / GUI AI tab):** new policy switches — *Click to Do + Settings AI agent*,
  *Recall snapshots (extra lock)*, *Paint AI*, *Notepad AI*, *Edge: Copilot + sidebar*,
  *Edge: on-device AI model + AI themes*. The list shows each one as `on / partly / OFF(set)`.
  These are Microsoft policies documented for Pro/Enterprise; on Home they are best-effort, and Verify
  shows whether the values stuck. The OS AI platform (CoreAI, AI Fabric) still can't be removed.
- **More privacy settings (menu 3 → S / GUI General tab):** activity history, clipboard history + sync,
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
  sign in**, runs as you with highest privileges, only while signed in. The protected copy stops a
  user-level program from editing the scripts to get admin rights. **Press G again after updating
  the tool** to refresh the copy. Undo (U) or **GX** removes the task and the copy.
- **Each check:**
  1. Skips if Windows is waiting for a restart; waits up to 30 min if updates are still installing.
  2. **Verify ALL**: every journaled WHD change, latest state per item.
  3. **Inventory scan only if Windows changed** (build/UBR or installed-update list; daily Defender
     signature updates don't count). Compares with the previous scan and flags **CAME BACK** apps.
     Keeps the last **5** guard-made scans (marked `.whd-guard`); your own scans are never touched.
- **Alert:** the report is always written to `restore\update-guard\guard_<time>.txt`. It **opens in
  Notepad only if** a WHD change is CHANGED/RETURNED or a removed app CAME BACK. New apps from an
  update are listed but don't pop up. **GR** = run the check now, **GO** = open the last report.
- Profile key `"security": { "updateGuard": true }` (default off). Journal kind `schtask`.

## One-run setup - `profiles\validated.json` (2026-09-25)
> **2026-09-29:** `validated.json` now has exactly the same settings as `profiles\standard.json` (user decision, after radio test
> rounds 1-8 passed). The 2026-09-25 description below is kept for history; the current contents are in `docs\standard-reimage.md`
> and `docs\radio-group-test.md`. Either profile gives the same result.
Repeats everything live-tested on the original PC in **one run** (one yes/no, no menus):
AI feature-off (9) + AI remove (Copilot, Power Automate, Bing, Widgets, Phone Link - **Notepad, Paint, Photos kept**, their AI off),
Store suppression, 21 Store apps, privacy hardening + DiagTrack + 6 extra privacy settings, Security+ (PUA, network + folder
protection BLOCK, 14 ASR in Audit, LLMNR/NetBIOS/WPAD/Remote Assistance off, UAC Always notify, password rules), permissions
Balanced, **network** (time.cloudflare.com + 1 h jump limit, firewall baseline, Cloudflare DNS + DoH, blocked-connection logging),
component cleanup, and the **update guard last**.
**Not included:** default-deny outbound (turn on by hand after: Firewall 6, then 7), per-app microphone denials.
**Fresh install order:** Windows Update until done → copy the tool → Inventory (1) → `WHD.ps1 -Apply profiles\validated.json`
(dry run) → same with `-Execute` → restart (IPv6 change) → V (verify) → Inventory (1) again → Firewall 6 + 7 if wanted.
**On the original PC use the dry run only** (its firewall step would set outbound back to Allow).
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
  - **Offline while closed:** Windows Update, the Store, drivers, app updaters, browsers (Edge too) and the Claude desktop app.
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
- **D** updates Defender definitions now (source MMPC, works with the gate closed). **S** Status: gate, policies, Windows Update
  installs (14 days), updaters.
- Firewall fixes:
  - a firewall profile never lowers outbound from Block to Allow
  - rebuilding the allow-list keeps HTTP/HTTPS off while the gate is closed
  - "revert default-deny" refuses while the gate is closed (use O)
- The update guard report shows the gate state (information only, not an alert).
- `validated.json` now has `"updates"` (all four policies, Edge + OneDrive updaters off, `"gate": "closed"` as the LAST step).
  **Run it before first connecting to the internet.** Open the gate when you want updates.

## v1.2 - network services off + permission Lock (2026-09-27, not yet live-tested)

**Security+ N1-N6 / NA** (GUI: Security+ tab, "Network services"). Each group sets the services' registry
`Start` value to 4 (Disabled), stops them if running, and is journaled (Undo center + Verify). Restart afterwards.

| Key | Turns off |
|---|---|
| `fileshare` | Workstation (LanmanWorkstation) + Server (LanmanServer): no file/printer sharing, no mapped drives |
| `smb` | SMB1=0 + SMB2=0 (server), client drivers mrxsmb20/mrxsmb10, SMB1 optional feature if on |
| `dialvpn` | RasMan, RasAuto, SstpSvc, RemoteAccess, TapiSrv: Settings VPN / Dial-up stop working |
| `ipsec` | IKEEXT, PolicyAgent (built-in IPsec/IKEv2/L2TP VPN) |
| `proxy` | WinHttpAutoProxySvc + Settings > Proxy "Automatically detect settings" OFF (this user) |
| `faxphone` | Fax (if present), PhoneSvc |

If networking misbehaves after a restart, undo `proxy` first, then `dialvpn`.

**Permissions L = Lock** (GUI: Permissions tab, "Lock"). Why: a plain registry Deny is not always what Settings
shows; Windows can write per-user values back to Allow. Lock sets every switch to Deny (user, PC-wide, and
"desktop apps" where it exists) and adds Windows' App Privacy policy **Force Deny** (value 2) under
`HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy` for 11 categories, so Settings shows them OFF and greyed.
Camera, microphone, radios and location: OFF but not locked (user's choice; location added 2026-09-29). Verify and
re-apply leave these four switches alone, so switching one on in Settings is never undone by WHD. Documents/Pictures/Videos/Cellular/File system have no
policy, so Deny only. Microsoft lists these policies for Pro and up; on Home they are tried; check Settings after a restart.

`profiles\validated.json` now uses `"permissions": "Lock"` and `security.servicesOff` (all six).

## v1.2 - Devices menu N / Security+ tab "Devices" (2026-09-27, not yet live-tested)

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
- **Update guard:** refreshed automatically at start when WHD's files changed; **GU** works in every menu; GUI top-bar button.
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
- **R** = remove everything matching a name (uninstall + autostart + tasks).
- **X** = block an .exe from launching via Image File Execution Options (reversible) — stops a helper/updater bringing an app back.
Note: Edge / WebView2 / Edge Update / servicing entries are protected and refused.

## Restore points
One per session, created automatically before the first change. Menu **6** makes
one on demand. Inventory (read-only) never triggers one.

## About the creator

WinHardenDebloat is created and maintained by **Training1990for2026Systems**.
Questions and feedback: **t90018273@gmail.com**. Security problems: please follow [SECURITY.md](SECURITY.md).

Built with Claude by Anthropic. WHD is an independent project; it is not made, endorsed or supported by Anthropic or Microsoft.
Released under the [MIT License](LICENSE).
