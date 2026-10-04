# Security policy

WinHardenDebloat (WHD) changes Windows security and privacy settings, so problems in it matter.

## Reporting a problem

Please report security problems **privately by e-mail** to **t90018273@gmail.com** (maintainer:
Training1990for2026Systems), not in a public issue. Include:

- the WHD version (top of README.md) and Windows edition / build (`winver`),
- what you ran (menu option or profile) and what happened,
- the run log from `logs\` with your own computer name, user name and network details removed.

You will get an answer by e-mail. Please give a reasonable time to fix the problem before talking about it publicly.

## Scope

- In scope: the scripts in this repository (WHD.ps1, WHD-GUI.ps1, Inventory.ps1, modules\, tools\) and its profiles.
- Out of scope: Windows itself, Microsoft Defender, and third-party block lists.

## Safe use

WHD is provided under the MIT License, without warranty. Test on a spare PC first, keep the restore point WHD creates
before the first change, and use a dry run (the default mode) before EXECUTE.
