# WinHardenDebloat (WHD)

Debloat and harden a newly installed, non-domain Windows 11 PC - offline, native PowerShell, every change journaled; most changes can be undone from the Undo center (see the README for what cannot).

by **Training1990for2026Systems** - contact: t90018273@gmail.com - License: [MIT](https://opensource.org/license/mit) - Built with Claude by Anthropic.

## Versions (one branch each)

| Branch | Version | Runs on | Status |
|---|---|---|---|
| [`classic`](../../tree/classic) | **WHD Classic 1.x** | Windows PowerShell 5.1 (built into every Windows) | current - start here |
| [`next`](../../tree/next) | **WHD Next 2.0** | PowerShell 7.6 LTS | 2.0 (2026-10-10) - does not have all of Classic's fixes yet: see "Known problems in this version" in its README |
| [`WHD-Imaging-helper`](../../tree/WHD-Imaging-helper) | **WHD Imaging Helper 1.5** | PowerShell 7 (the menu) + Windows PowerShell 5.1 + DISM (built into every Windows) | preview (1.5 preview 1, 2026-10-12) - prepares a Windows 11 Home install USB stick before the install, in one terminal menu: Home edition from an ISO file or a Windows stick, inventory, your choices, the building PC's drivers, settings and a first sign-in script into the image, optional AI system package removal (not supported by Microsoft - see its README), and the stick itself; a check of the installed PC afterwards. Used for one install. Replaces the former branches `usb-image` and `usb-image-iso` |
| `deploy` | WHD Deploy 1.x | Windows Setup (answer file) + Classic / Next | planned |

Switch to a branch (GitHub: the branch menu above the file list) to see its code, README, license and security policy.

WHD is an independent project; it is not made, endorsed or supported by Anthropic or Microsoft.
