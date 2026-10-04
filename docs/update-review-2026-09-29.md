# Windows update review - 2026-09-29 (evening)

**Update:** Windows 11 Home 25H2 build 26200.9457 -> **26H2 build 26300.9457** (seen by the 20:44 inventory). Windows was still
installing (TiWorker) between 20:39 and 20:42; the guard waited for it, as designed.

## What WHD found

- **Update guard (20:41 and 20:43):** OK - 221 of 221 WHD changes still in place. No removed app came back.
- **Inventory compare (20:33, against the first scan of this install):** every app WHD removed is still GONE. The rest are updates
  or additions:
  - Updated by Windows/Store: Copilot app (0.25061 -> 1.25121), Camera, Calculator, Store, App Installer, codec extensions,
    Windows App Runtime 1.5, Start experiences.
  - New: two audio apps, a microphone noise-cancellation app and a graphics settings app from the PC / chip makers (all four
    "installed + staged", which is how hardware-support apps arrive with drivers), Windows App Runtime 1.8, UI.Xaml 2.5,
    Store Engagement, and the user's own Claude and Zoom.
  - Defender "default definitions" package now Disabled and DirectX configuration database not present: both normal after
    real Defender definitions are installed / the update ran. Definitions were updated to 1.459.480.0 at 20:29.
- **Radio diagnostic (20:25, before the build change):** Wi-Fi up, WLAN AutoConfig running, nothing flipped back.

## Two problems caused by WHD's own re-apply (V, 20:26)

1. **Radios permission switched back to Deny.** The user had turned radios on (Allow), which is allowed by design (radios are "off
   but not locked"). Verify reported it as CHANGED and re-apply set it to Deny. Camera and microphone have the same risk.
2. **Proxy "Automatically detect settings" switched back ON.** The latest journal entry for DefaultConnectionSettings was written by
   the round-4 **undo** (17:41: the Windows default, flags 0x09 = auto-detect on). Round 4b did not write that value again because it
   was already off, so Verify treated the undo value as the target and re-apply wrote it back. Right now the Settings switch is
   ON; WPAD itself stays off by policy (P3), so no proxy look-ups happen, but it is not what N5 intends.

Root cause in code: Verify/re-apply (a) treated the "kept" permissions like locked ones and (b) treated values written by an undo as
something WHD must protect.

## Fixes (user decision 2026-09-29: fix both, and add location to the exception)

- `modules\Common.ps1`: changes written by an undo are marked `ByUndo`; Verify skips an item whose latest write came from an undo
  (older journals: detected from `undo.jsonl` BySession + time). Camera, microphone, radios and location consent switches show as
  `n/a (your choice - off but not locked)` and re-apply never touches them.
- `modules\Permissions.ps1`: location joins the "off but not locked" list; the next Lock removes the old location policy lock.
- `modules\Debloat-General.ps1`: four new OEM entries in General debloat (not recommended, not in any profile):
  two audio apps, a microphone noise-cancellation app and a graphics settings app.
- Tested offline with a mock journal copying the round-4 case: the undo value is no longer verified, radios shows n/a,
  a normal WHD setting that changed still shows CHANGED.

## Steps on the PC (in this order)

1. S > **N5** - turns proxy auto-detect off again (its last WHD record is now the wrong 20:26 re-apply; N5 writes a new one).
2. 4 > **L** (Lock) - removes the old location policy lock.
3. 2 > remove **Copilot** (user decision: apply now).
4. S > **U** - UAC Always notify (user decision: apply now).
5. V - should report all pass; camera/mic/radios/location show n/a.

## Not applied on this PC yet (they are in standard.json for the next re-image)

- Copilot app removal (the app is still installed + staged; only Copilot feature-off policies are set here).
- UAC Always notify (Security+ shows "Default").

## Result of the steps (run 2026-09-29 21:00)

- N5: proxy auto-detect off again (DefaultConnectionSettings flags 0x01). Lock: the old location policy lock was removed;
  54 other values already right. Copilot app removed for all users (no staged copy was found). UAC set to Always notify.
- Verify: 222 of 223 pass. The one CHANGED was a **false alarm**: the Bluetooth PAN device showed "enabled (Unknown)" while
  Bluetooth was off and the device was not present. Running Devices 1 again then found it "already disabled", but its
  network-stack step failed because a disabled adapter has no IP interface.
- Fixed (Common.ps1, Devices.ps1): Verify treats a not-present device that WHD disabled as PASS (it is checked again when it comes
  back); Devices 1 skips the network-stack step for a Disabled / Not Present adapter (the registry values already cover it).
