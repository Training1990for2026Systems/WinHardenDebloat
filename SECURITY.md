# Security policy

WHD USB Image (ISO build) changes a Windows install image and ERASES and rewrites an install USB stick, so problems
in it matter.

## Reporting a problem

Please report security problems **privately by e-mail** to **t90018273@gmail.com** (maintainer:
Training1990for2026Systems), not in a public issue. Include:

- the WHD USB Image version (top of README.md) and the Windows edition / build of the image (`dism /Get-WimInfo`),
- which script you ran and what happened,
- the script's log (`Build-HomeUsbFromIso.log`) with your own user name and folder names removed.

You will get an answer by e-mail. Please give a reasonable time to fix the problem before talking about it publicly.

## Scope

- In scope: the scripts in this folder (Build-HomeUsbFromIso.ps1, List-HomeImage.ps1, Check-InstalledPc.ps1,
  first-signin\WHD-FirstSignIn.ps1) and the three lists.
- Out of scope: Windows itself, Windows Setup, DISM, and the Windows image files.

## Safe use

WHD USB Image is provided under the MIT License, without warranty. Keep the ISO file you downloaded, use a stick
with nothing on it that you need, try the stick on a spare PC first, and back up anything on the target PC you cannot lose: installing Windows from
the stick erases the drive you install to.
