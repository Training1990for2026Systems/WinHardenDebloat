# Security policy

WHD USB Image changes a Windows install image and the files on an install USB stick, so problems in it matter.

## Reporting a problem

Please report security problems **privately by e-mail** to **t90018273@gmail.com** (maintainer:
Training1990for2026Systems), not in a public issue. Include:

- the WHD USB Image version (top of README.md) and the Windows edition / build of the image (`dism /Get-WimInfo`),
- which script you ran and what happened,
- the script's log (`Finish-HomeUsb.log` or `Apply-HomeImage.log`) with your own user name and folder names removed.

You will get an answer by e-mail. Please give a reasonable time to fix the problem before talking about it publicly.

## Scope

- In scope: the scripts in this branch (Finish-HomeUsb.ps1, List-HomeImage.ps1, Apply-HomeImage.ps1) and remove-list.txt.
- Out of scope: Windows itself, Windows Setup, DISM, and the Windows image files.

## Safe use

WHD USB Image is provided under the MIT License, without warranty. Keep the original image files from your stick,
try the stick on a spare PC first, and back up anything on the target PC you cannot lose: installing Windows from
the stick erases the drive you install to.
