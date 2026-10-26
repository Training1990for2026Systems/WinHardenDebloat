# WHD Next 3.0 - short guide

## 1. Before you start
- Windows 11 and an **administrator** account.
- **PowerShell 7.6** or a newer stable version, installed machine-wide. If it is missing, the starter offers
  to install Microsoft's version, and asks first.
- Put the WHD folder somewhere outside Documents / Desktop, for example `C:\WHD`. Windows' folder protection
  can block writing in those places.

## 2. Start
Double-click **`Start-WHD.cmd`**. The starter shows a short table:
- administrator rights;
- the Windows version;
- PowerShell 7;
- winget;
- folder protection;
- whether the program files are complete.

If everything is fine, it opens WHD. `Start-WHD.cmd -Gui` opens the window instead of the menu.

At the very first start on a PC that had WHD Next 2.0, WHD asks once how to take over 2.0's change history:
**C** copies it once, **R** reads it in place.

## 3. Dry-run first, then EXECUTE
- WHD starts in **dry-run**: every action only says what it *would* do (`would: ...`). Nothing changes.
- **X** turns **EXECUTE** on or off in every menu. With EXECUTE on, each change asks `Proceed with ...? y/N`.
  A System Restore point is made before the first change of the session.
- **S** turns **safe mode** on or off. In safe mode, only Undo, re-apply / re-remove and restore points can be
  real.
- **B** goes back; **Q** on the main menu quits.

## 4. The main menu
| Key | What it does |
|---|---|
| 1 / D | Inventory (read-only scan) / compare the two newest scans |
| 2 / 3 / M | AI debloat / other apps + telemetry / more privacy settings |
| 4 / 5 / 6 | App permissions / Win32 programs / component store |
| 9 / SE / W | Firewall / Security+ / Updates |
| N / T / TH | Devices / Time & region / Theme (optional) |
| 7 | A System Restore point now |
| U / V | Undo center / Verify (then re-apply or re-remove what came back) |
| G | The update guard |
| P | Profiles |

Each item explains what it changes and how risky it is before it asks.

## 5. Profiles
`profiles\minimum.json`, `average.json` and `strict.json` do many menu actions in one go:
- **minimum:** quiet and safe, removes nothing.
- **average:** the everyday hardened PC.
- **strict:** maximum; some features go away.

Press **P** and pick one:
- In dry-run it lists every step and what each would do.
- With EXECUTE on, it asks **once**, then runs every step. Each change is recorded.

Never part of a profile: closing the update gate, default-deny outbound, wiping the firewall, uninstalling
programs. You do these yourself in their menus.

You can edit the files, or copy one and give it your own `name`. It must keep `"kind": "whd-profile"`.

## 6. Undo and Verify
- **U, the Undo center**, lists every recorded change (also 2.0's) and undoes the ones you pick. An undo is
  itself recorded.
- **V, Verify**, checks that every recorded change is still in place, then offers to re-apply settings that
  changed back and to re-remove apps that came back.
- The change history is in `restore\`; the logs of every run are in `logs\`.

## 7. The update guard (G)
- **1** installs it: a locked copy of WHD in `ProgramData\WinHardenDebloatNext\guard3`, and a task that runs
  10 minutes after you sign in and daily at 16:30.
- It **only reads and reports**. On a problem you get an entry in Event Viewer (Application log, source
  "WHD Next 3.0") and a small window with "Open the report".
- It checks:
  - your recorded changes;
  - after a Windows update, whether removed apps came back;
  - refused clock jumps.
- **2** checks now, **3** opens the last report, **4** removes the guard.
- Reports are in `restore\update-guard\`.

## 8. If something goes wrong
- Undo the change in the Undo center, or use the System Restore point WHD made.
- The log of the run is in `logs\run_<time>.log`.
- See `SECURITY.md` for how to report a problem.
