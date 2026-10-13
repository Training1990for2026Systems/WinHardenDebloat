# Security policy

WHD Imaging Helper changes a Windows install image and erases and writes an install USB stick, so problems in it matter.

## Reporting a problem

Please report security problems **privately by e-mail** to **t90018273@gmail.com** (maintainer:
Training1990for2026Systems), not in a public issue. Include:

- the WHD Imaging Helper version (top of README.md) and the Windows edition / build of the image (`dism /Get-WimInfo`),
- which script or menu step you ran and what happened,
- the log (`WHD-ImageMenu.log`, or the log of the tool you ran) with your own user name and folder names removed.

You will get an answer by e-mail. Please give a reasonable time to fix the problem before talking about it publicly.

## Scope

- In scope: the scripts and lists in this branch (`WHD-ImageMenu.ps1`, `Check-InstalledPc.ps1`, `tools\`, `first-signin\`, `lists\`).
- Out of scope: Windows itself, Windows Setup, DISM, and the Windows image files.

## Safe use

WHD Imaging Helper is provided under the MIT License, without warranty. Keep your ISO file, try the stick on a spare
PC first, and back up anything on the target PC you cannot lose: installing Windows from the stick erases the drive
you install to. Step 5 of the menu (AI package removal) is not supported by Microsoft - see README.md.
