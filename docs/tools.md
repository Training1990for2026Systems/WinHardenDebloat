# The tools in `tools\`

They are the single-purpose scripts that came before the menu. Each one lies in `tools\` and works in the helper's
main folder above it: it reads `lists\` and `first-signin\` and writes its log and work files there. All run on
Windows PowerShell 5.1 in an administrator window (`Build-PublishCopy.ps1` needs no administrator).

## Build-HomeUsbFromIso.ps1 - the whole build in one run

```
powershell -ExecutionPolicy Bypass -File .\tools\Build-HomeUsbFromIso.ps1 -IsoFile <ISO> -NoStick
powershell -ExecutionPolicy Bypass -File .\tools\Build-HomeUsbFromIso.ps1 -IsoFile <ISO> -UsbDrive <letter>
powershell -ExecutionPolicy Bypass -File .\tools\Build-HomeUsbFromIso.ps1 -IsoFile <ISO> -UsbDrive <letter> -CheckOnly
```

The same as the menu's steps 1, 4, 6 and 7 without questions in between (the erase is confirmed at the start).
It needs `drivers-list.txt` (run `tools\Export-MyDrivers.ps1` or the menu's step 2 first). It does **not** do the
AI package step (step 5 of the menu). `-IsoSha256 <value>` compares the ISO file's checksum; `-WorkDir` puts the
work files elsewhere. Log: `Build-HomeUsbFromIso.log`.

## Apply-HomeImage.ps1 and Finish-HomeUsb.ps1 - the stick-based way

`Apply-HomeImage.ps1 -UsbDrive <letter>` takes the image off a fresh Windows stick (kept in `original`), applies
the lists to the Home edition and puts the changed pieces back on the same stick. `Finish-HomeUsb.ps1` puts the
plain Home-only pieces on the stick (`-ReplaceCustom` replaces a changed image). These came from WHD USB Image 1.0
and are kept as they were; they do not do the driver step or the AI step.

## List-HomeImage.ps1 and Inventory-AiPackages.ps1 - read-only

`List-HomeImage.ps1` opens `install.wim` read-only and writes the enabled features, installed capabilities and
bundled apps to `image-contents.txt`. `Inventory-AiPackages.ps1 -IsoFile <ISO>` (or `-After` for
`install-custom.wim`) writes where the AI system packages sit: provisioned app, servicing package, capability,
feature, component manifest, `SystemApps` folder, the image's registry. Neither changes an image.

## Export-MyDrivers.ps1

Copies the third-party driver packages of the running Windows into `drivers` (`dism /Online /Export-Driver`) and
writes `drivers-list.txt` with one on/off line per package: on = a device uses it now, or class Extension; off =
class SoftwareComponent (maker apps arrive through these) or not in use. `-Again` exports anew (the old export is
renamed). The menu's step 2 does the same and keeps your choices by package name.

## Build-PublishCopy.ps1

Makes a checked copy of the helper's main folder in `..\publish\<folder>_<date>_<time>`: only what `.gitignore`
lets through, no private word (from `private-words.txt`, the user name, the computer name), every `.ps1` readable
by Windows PowerShell 5.1 and ASCII only, every copy compared, a new `SHA256SUMS.txt`. `-ListOnly` checks only.
