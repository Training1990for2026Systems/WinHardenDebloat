# Security

WHD Next 3.0 changes Windows security settings, so problems in it matter. Thank you for reporting them.

## Reporting a problem

- **A security problem** (WHD weakens something, lets something in, leaks data, or a change it makes can be
  misused): e-mail **t90018273@gmail.com** with what you saw, the steps, and the WHD version
  (`WHD.ps1` shows it at start). Please do not open a public issue for it first.
- **Any other bug:** open an issue on GitHub (Training1990for2026Systems/WinHardenDebloat).

Attach the log of the run if you can: `logs\run_<time>.log` (and `logs\guard_<time>.log` or
`restore\update-guard\guard_<time>.txt` for the update guard). Look through it first - it contains your
computer name and paths.

## What WHD does and does not do

- It only changes this PC, only in an administrator window, only with EXECUTE on, and each change asks first
  (a profile asks once). Dry-run is the default.
- Every change is written to the change history (`restore\`) before the next one; the Undo center can undo it.
  A System Restore point is made before the first change of a session.
- It sends nothing anywhere and uses no web service. It never installs anything without your yes (the
  starter offers Microsoft's PowerShell 7 installer only).
- The update guard is alert only: it reads and reports, it never changes a setting.

## Supported versions

Only the newest published WHD Next 3.0 gets fixes. It runs on PowerShell 7.6 or a newer stable version.
