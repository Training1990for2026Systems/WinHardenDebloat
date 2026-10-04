# Radio problem: one-group-at-a-time test (user decision 2026-09-28)

**Goal:** find which WHD group makes a radio "on but dormant", flip back after 1-2 minutes, or make the PC feel sluggish.
**Baseline (done 2026-09-28 19:54):** with no groups applied and every radio permission set to Allow, the radio stayed on for 3 minutes.
Nothing flipped back.

**Main suspect: Wi-Fi Direct (Devices 2).** When the radio is switched on, Windows starts the Wi-Fi Direct (WFDSConMgrSvc) and
Mobile Hotspot (icssvc) services. WHD's option disables both, and it also blocks the Intel Wi-Fi driver from re-creating its Wi-Fi
Direct adapter. The driver would keep retrying, which would fit both "dormant" and "sluggish".

## Each round

1. Run WHD in EXECUTE mode and apply **one** group (the list is below). Each run of WHD is its own Undo-center session.
2. Restart the PC.
3. Switch the radio on in Settings, then run the diagnostic (admin PowerShell, project folder):
   `powershell -ExecutionPolicy Bypass -File .\tools\Diag-Radio.ps1`
4. Send the report from `logs\diag-radio_*.txt`.
5. **User decision 2026-09-28: each group that passes goes into `profiles\standard.json` right away.**
6. If the radio broke or the PC is sluggish: Undo center, then that session, then **A** (undo all). Restart. That group stays out of the standard.

## Order

The easiest to undo come first. WAN Miniports come last because removed devices come back only through Network reset.

| Round | Group | Menu |
|---|---|---|
| 1 | Wi-Fi Direct off + install block (main suspect) | N > 2 |
| 2 | Dial-up + built-in VPN (RasMan, RasAuto, SstpSvc, RemoteAccess, TapiSrv) | S > N3 |
| 3 | IPsec VPN keying (IKEEXT, PolicyAgent) | S > N4 |
| 4 | Proxy auto-detect (WinHTTP service + Settings switch) | S > N5 |
| 5 | Fax + Phone service | S > N6 |
| 6 | SMB 1/2/3 | S > N2 |
| 7 | WAN Miniports: block + remove | N > 3 |
| - | Bluetooth network part | skipped. There is no Bluetooth adapter until its driver is installed |

The diagnostic also shows the busiest processes and the device-install attempts in the last 24 hours, so it catches the "sluggish"
case even when the radio itself looks fine.

## Results

| Round | Date | Radio OK? | Sluggish? | Kept in standard? |
|---|---|---|---|---|
| 1 Wi-Fi Direct | 2026-09-28 20:24 | yes: Wi-Fi off/on, reconnected in 4 s, nothing flipped back (wait was cut to 31 s) | no: normal CPU, no failed device installs | **yes** (added 2026-09-28) |
| 2 Dial-up/VPN | 2026-09-28 20:32 | yes: reconnected in 3 s; WAN Miniports stay "not present" now that RasMan is off (wait was cut to 21 s) | no | **yes** (added 2026-09-28) |
| 3 IPsec | 2026-09-29 17:27 | yes: **full 3-min wait**. The Lock profile was on, radios started as Deny (off, not locked); switching on set radios = Allow and it stayed Allow. Bluetooth + Wi-Fi both came up | no: Defender scanning (MsMpEng) is the top CPU user, which is normal | **yes** (added 2026-09-29) |
| 4 Proxy | 2026-09-29 17:36 | **NO - this is the culprit.** With the WinHTTP proxy service disabled, WLAN AutoConfig (WlanSvc) and IP Helper (iphlpsvc) did not start after the restart. Wi-Fi showed **"Dormant"** (status 5) after switching on - the original symptom | - | **NO** - undone by the user 17:41 (journal undo worked); after the undo Wi-Fi was Up/Connected and WlanSvc was running again (diag 17:44) |
| 4b Proxy (Settings switch only, N5) | 2026-09-29 18:23 | yes: **full 3-min wait**. WinHTTP service Running/Manual, WlanSvc + iphlpsvc running; radio on 18:24:05 -> connected 18:24:10 (5 s); nothing flipped back; time sync with Cloudflare OK | no: Defender scanning (MsMpEng) is the top CPU user, which is normal | **yes** (added 2026-09-29) |
| 5 Fax/Phone | 2026-09-29 18:42 | yes: **full 3-min wait**. PhoneSvc Start=4 (Fax is not installed on Home); radio on 18:43:18 -> connected 18:43:23 (5 s); nothing flipped back; time sync with Cloudflare OK | no: System + Defender are the top CPU users, which is normal | **yes** (added 2026-09-29) |
| 6 SMB 1/2/3 | 2026-09-29 18:51 | yes: **full 3-min wait**. Server SMB1=0 + SMB2=0, client mrxsmb20 Start=4 (the SMB1 client driver is not installed); radio on 18:51:36 -> connected 18:51:40 (4 s); nothing flipped back; time sync with Cloudflare OK | no: Defender + System are the top CPU users, which is normal | **yes** (added 2026-09-29) |
| 7 WAN Miniports | 2026-09-29 18:58 | yes: **full 3-min wait**. 8 install-block IDs added (DenyDeviceIDs 2-9), all 8 miniports removed and gone after the restart (not even listed as "not present"); no install retries; radio on 18:59:06 -> connected 18:59:10 (4 s); nothing flipped back; time sync OK | no: Defender + System are the top CPU users, which is normal | **yes** (added 2026-09-29) |
| 8 Bluetooth network part | 2026-09-29 19:08 | yes: **full 3-min wait**. PAN adapter {ADAPTER-GUID-...} EnableDHCP=0 + IPAutoconfigurationEnabled=0, device disabled and still disabled after the restart; the Bluetooth radio, RFCOMM and LE enumerator stayed OK; Wi-Fi radio on 19:08:48 -> connected 19:08:53 (5 s); nothing flipped back; time sync OK | no: Defender, the display compositor (dwm) and System lead CPU, no install retries | **yes** (added 2026-09-29) |

## Notes from round 1 (2026-09-28 20:20-20:25)

- The block works on Home: after the restart, Wi-Fi Direct adapter #2 is gone ("not present") and #1 stays disabled. No
  device-install retries were logged.
- WHD bug fixed: disabling adapter #1 made Windows drop #2, and WHD then reported "Generic failure" for #2. WHD now re-reads each
  device first.
- Switching the radio on started RasMan + SstpSvc, and the 8 WAN Miniports came back (they were "not present" after the restart).
  This is round 2's group.
- Drivers not installed, because Device Installation = No: Intel Bluetooth (USB device), fingerprint reader, the PC maker's ACPI devices (power and hotkeys), Intel thermal (Dynamic Tuning), Intel chipset
  (SM Bus, serial/GPIO, signal processing). Missing Intel thermal/chipset drivers can make a laptop run slower or hotter. This
  could explain some of the "sluggish" feel.

## Notes from round 3 (2026-09-29 17:23-17:30)

- **The radio fix is confirmed:** the Lock profile is on (12 categories locked by policy), and radios are off but not locked. Switching
  the radio on in Settings changed radios Deny -> Allow, and it stayed that way for the full 3 minutes. Nothing flipped back.
- Drivers restored by the user: Intel Bluetooth now works (the Bluetooth stack, RFCOMM, the LE enumerator and the Bluetooth Network
  Connection adapter all appear when Bluetooth is on). Also installed now: fingerprint, Intel thermal, the PC maker's hotkeys.
  Still without a driver: three ACPI devices (two from the PC maker, one Intel) and four Intel chipset parts (one is the SM Bus).
- NetBIOS came back on a **new** adapter (P2 showed "partly"; Tcpip_{ADAPTER-GUID-...}). The user ran P2 again. This is the
  new-adapter case the re-apply note describes.
- BTHUSB event 18 ("cannot store link keys on the adapter") is harmless. The one time-sync DNS error happened while Wi-Fi was off.
- Bluetooth Network Connection (PAN) now exists, so the Devices 1 "Bluetooth network part" option can be tested (optional round).

## Round 4 finding (2026-09-29 17:33-17:48) - the cause of "on but dormant"

- Applied: S > N5 (WinHttpAutoProxySvc Start=4 + Settings "Automatically detect settings" off). Stopping the service right away
  was refused by Windows (protected service), so the change only took effect after the restart.
- After the restart: **WlanSvc Stopped (start type Automatic), iphlpsvc Stopped (Automatic), WinHttpAutoProxySvc Stopped/Disabled.**
  Switching Wi-Fi on gave the adapter status **Dormant** (5) and media "Connected", with no WLAN connect events. There were
  time-sync DNS errors, because there was no working network. This is exactly the "on, available, but dormant" state from the earlier images.
- Undo (Undo center > session 2026-09-29_173332 > 1,2,3) put Start=3 back and restored the two Settings values. After the restart,
  WlanSvc and iphlpsvc were running, Wi-Fi was Up/Connected and radio off/on reconnected in 3 s (diag 17:44).
- Conclusion: **do not disable WinHttpAutoProxySvc** on this PC. The proxy group stays out of the standard.
- WHD bug found and fixed during the undo: "Import .reg backups" (R) reported "FAILED ... The operation completed successfully",
  because reg.exe writes its success text to stderr. It now runs through Invoke-WHDNative and checks only the exit code (same fix for
  the firewall restore F).

## After round 4: user decision 2026-09-29 ("option 1 + 3")

- **N5** now = proxy auto-detect **Settings switch only**. It never touches the WinHTTP proxy service; WPAD itself is already off by P3.
  It goes in as its own test round (4b).
- **N7** = the old WinHTTP proxy **service** switch-off, kept with a red "breaks Wi-Fi here" warning. **Never** part of NA, and profiles
  refuse it (servicesOff 'proxysvc' is logged and skipped). The GUI has a separate red button for it.
- The user wants the exact cause of the Wi-Fi failure: `tools\Diag-ServiceDeps.ps1` (read-only) lists which services need
  WinHttpAutoProxySvc, the dependency chains of WlanSvc / iphlpsvc / Wcmsvc / Dhcp / Dnscache / NlaSvc, and the Service Control
  Manager start errors from the last 3 days. The round-4 restart is still in the log, so nothing has to be broken again.

## Exact cause, proven by diag-svcdeps_2026-09-29_180930.txt

Windows services can declare **hard dependencies** (registry `DependOnService`, shown by `sc qc` as DEPENDENCIES). The Service
Control Manager refuses to start a service while any service it depends on is disabled. On this PC:

| Service | Configured dependencies (sc qc) |
|---|---|
| WlanSvc (WLAN AutoConfig) | nativewifip, RpcSs, Ndisuio, **wcmsvc** |
| Wcmsvc (Windows Connection Manager) | RpcSs, NSI, **WinHttpAutoProxySvc** |
| iphlpsvc (IP Helper) | RpcSS, tcpip, nsi, **WinHttpAutoProxySvc** |
| WinHttpAutoProxySvc | Dhcp, DNSCache (Manual start, no triggers) |

The chain: WinHTTP proxy service disabled -> **Windows Connection Manager cannot start** -> **WLAN AutoConfig cannot start** ->
the Wi-Fi adapter has no service managing it, so it shows "on" but **Dormant**. IP Helper fails as well, and it pulls down
Network Connectivity Assistant (NcaSvc). Mobile Hotspot (icssvc) also hangs off Wcmsvc; WHD already has it off by choice.

The log records it exactly (restart at 17:35 in round 4):
- 17:35:04  7001  Wcmsvc depends on WinHttpAutoProxySvc, which failed to start because it is disabled.
- 17:35:05  7001  WlanSvc depends on Wcmsvc, which failed to start.
- 17:35:05  7001  iphlpsvc depends on WinHttpAutoProxySvc, which failed to start because it is disabled.

**Why the new N5 still keeps the intent:** the "proxy" in the name is misleading. The service does nothing unless something asks for
automatic proxy discovery (WPAD). WHD already turns WPAD off (P3), and N5 turns off the Settings "Automatically detect settings"
switch. With both off, the service stays Manual, and its only job is to be "present" so that Wcmsvc and iphlpsvc are allowed to
start. No proxy lookup happens, and internet access keeps working.

Unrelated items in the same report (not WHD-caused, for the record): netprofm 7023 "device not ready" (09-28 14:39, during a
re-image restart), Camera Frame Server Monitor 7023, SysMain 7023 "parameter is incorrect" (twice).

## Note from round 5 (2026-09-29 18:42-18:46)

- HAL event 21 ("hardware real-time clock was not set ... ACPI Time and Alarm Device method failed") appeared when the time service
  corrected the clock by about 1 second. Not caused by WHD. It fits the ACPI devices that still have no driver (one Intel and two PC-maker ACPI devices). Windows keeps the correct time through Cloudflare NTP either way.

## Result of all rounds (2026-09-29 19:03)

Every group passed except turning off the WinHTTP proxy **service** (round 4), which is the one cause of "on but dormant" Wi-Fi.
The standard (`profiles\standard.json`) now holds: Wi-Fi Direct off + block, WAN Miniports block + remove, and the network
services fileshare, dialvpn, ipsec, proxy (Settings switch only), faxphone and smb. Round 8 (2026-09-29 19:08) then tested the Bluetooth
network part (Devices 1): it passed and is now in the standard too (devices.btNetworkOff = true).

## Note from round 8

- The Bluetooth PAN adapter's interface is **{ADAPTER-GUID}**: the same "new adapter" on which NetBIOS came back in
  round 3. While the adapter is disabled it carries no traffic, so NetBIOS on it can do nothing. P2 may still read its saved setting and
  show "partly"; running P2 once more (or the one-key re-apply) sets it to off as well.
