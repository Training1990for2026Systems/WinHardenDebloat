WHD Next - installers folder (optional)

Normally the launcher installs PowerShell 7.6 through winget. On a PC without
winget, or without internet, you can install from a file instead:

 1. On any PC, download the PowerShell 7.6 MSI from Microsoft
    (Microsoft Learn: "Install PowerShell on Windows" > MSI), for example
        PowerShell-7.6.6-win-x64.msi
 2. Put the file in this folder.
 3. Start the launcher (Start-WHD.cmd). It checks that the file carries a valid
    Microsoft signature, and then offers:  [M] install PowerShell from the file.

Nothing in this folder is used unless you choose [M] and answer yes.
