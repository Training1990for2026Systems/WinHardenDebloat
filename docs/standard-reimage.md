# Standard re-image baseline

Recorded 2026-09-28 from the logs and journals of the re-image on **<PC-NAME>**
(Windows 11 Home 25H2, build 26200.9457, installed via menus, sessions 17:53 to 19:05).
**User decision (2026-09-28): what was deployed on this PC is how a standard re-image should look.**
Privacy / app permissions are the exception: see "Permissions" below.

Status: **built** as `profiles\standard.json` (2026-09-28). Dry run first:
`powershell -ExecutionPolicy Bypass -File .\WHD.ps1 -Apply profiles\standard.json`, then add `-Execute`.

## What was deployed (in the order it was run)

| Area | Deployed |
|---|---|
| Defender | Ransomware folder protection ON; PUA blocking ON; Network protection ON |
| Attack-surface rules | all 14 (standard 3 + script/download 4 + Office/Adobe/email 7), first Audit, then **switched to BLOCK** |
| Old protocols off | LLMNR, NetBIOS (all adapters), WPAD, Remote Assistance |
| Network services off | **Workstation + Server only** (N1). SMB, dial-up/VPN, IPsec, proxy and fax/phone were **not** applied |
| Password rules | 14 characters, remember 5, never expire, lock after 3 bad tries / 10 min |
| Update policies | NoAutoUpdate; Device Installation = No (+ metadata off); no drivers in quality updates; Store AutoDownload = 2 |
| App updaters | Edge Update services (edgeupdate, edgeupdatem) + both Edge Update tasks disabled |
| Store suppression | silent installs, pre-installed/OEM apps, content delivery, consumer features off |
| General apps removed | Clipchamp, Solitaire, Feedback Hub, Get Help, Dev Home, Teams (the "recommended" set); To Do, Sticky Notes, Quick Assist, Family, new Outlook, Cross Device, Clock/Alarms, Sound Recorder, Media Player, Xbox app, Game Bar, Xbox speech-to-text, Xbox TCUI, Xbox Identity Provider. **Camera app kept** |
| AI | Feature-off: Copilot, Recall, Click to Do + Settings agent, Recall snapshots, Paint AI, Notepad AI, Edge Copilot + sidebar, Edge on-device AI. Removed: Power Automate, Bing (Search/News/Weather), Widgets (Web Experience), **Paint, Photos**, Phone Link |
| Privacy | telemetry hardening + DiagTrack disabled; Activity history; Clipboard history + cross-device; ads/suggestions/nags; online speech + inking/typing; Edge background/startup boost/shopping; Edge diagnostic data |
| Win32 | **Microsoft OneDrive uninstalled** |
| Firewall | **All 457 default rules wiped (empty slate)**, then WHD allow-list (DNS 1.1.1.2/1.0.0.2, DHCP, NTP, HTTP/HTTPS), IP blocklist (1,875 entries), gate rules |
| IPv6 | off (registry DisabledComponents = 255, unbound from the adapter) |
| DNS | 1.1.1.2 / 1.0.0.2 with encrypted DNS-over-HTTPS |
| Time | time.cloudflare.com, UDP 123 pinned, 1 h jump limit, W32Time Automatic (delayed) |
| Update guard | installed (sign-in + 10 min) |
| Update gate | closed at 18:26, **opened at 18:40 and still open** |
| Component store | StartComponentCleanup (no ResetBase) |

Guard report 19:15: 135 of 136 checks pass. **Dev Home came back** (Microsoft.Windows.DevHome installed again).

## Permissions (the exception)

The user wants the privacy / app-permission switches set the WHD **Lock** way, but with **radios** handled
like the camera and microphone: OFF at first, but not locked. The user can switch them on in Settings.
Built into `modules\Permissions.ps1` on 2026-09-28. If an older Lock had put a policy lock on radios,
the next Lock run removes it.

**2026-09-29 (user decision):** **location** is handled the same way (OFF, not locked). The next Lock run removes
the old location policy lock. Verify and one-key re-apply now leave all four switches (camera, microphone, radios,
location) alone, so switching one on in Settings is never reversed by WHD.

## Radio "on but dormant" problem (being diagnosed)

Symptom: the radio is switched on in Settings and shows available, but it does not work ("dormant").
After 1 to 2 minutes, or after reopening Settings, it is locked again.
None of today's WHD sessions touched app permissions, radios, Bluetooth, Wi-Fi Direct, WAN Miniports,
dial-up/VPN, IPsec or proxy. The journals have no such entries, so on this PC those settings were not
changed by WHD. The read-only tool `tools\Diag-Radio.ps1` records the state before and after the radio is
switched on, plus every event in between. It shows what turns the radio back off.

## User decisions 2026-09-28 (built into standard.json)

1. Firewall: **wipe all rules first** (network.firewallWipeFirst), then WHD's baseline.
2. Update gate: **left open** at the end (updates.gate = "").
3. Services beyond Workstation + Server, and the Devices items: **decided after the radio diagnostic** (not in standard.json yet).
4. Added: **UAC Always notify**, **Bing search-box policy** (AI feature-off "bing"), **Copilot app removed**.
5. Logging: **Windows Firewall log**, default file and name, **dropped + allowed**, size **32,767 KB** (the maximum). Replaces WHD's
   Security-log / event 5157 method. The Blocked-connections view now reads the firewall log.
6. General apps: **all removed except Camera and Calculator** (the recommended set included).
7. Removed apps must not come back: every removal now writes Microsoft's **Deprovisioned** mark
   (HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\<PackageFamilyName>). If one still returns,
   Verify (V) and the guard report list it, and **V** offers a one-key re-remove (GUI: Inventory/Undo > "Re-remove apps that came back").
8. Update guard: refreshes itself automatically when WHD or the GUI starts, if WHD's files changed, and **GU** refreshes it from every menu
   (GUI: "Refresh update guard" button in the top bar).

## 2026-09-28 20:00 - radio diagnostic + next step

- The diagnostic ran with every radio permission set to Allow. The radio stayed on for 3 minutes and nothing flipped back.
  The unlocked state works.
- User decision: find the culprit **one group at a time** (see `docs\radio-group-test.md`, Wi-Fi Direct first). Each group goes into
  standard.json only after it passes.
- NetBIOS / P1-P4 coming back: the user chose **one-key re-apply** (V / GUI button). The extra locks (NetBIOS policy, P-node) and the
  every-adapter check were not chosen for now.
- Bluetooth: the hardware is present but its driver is not installed yet, so no Bluetooth device shows up.
