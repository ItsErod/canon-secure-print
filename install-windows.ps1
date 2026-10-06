# Remax Secure Printer — Windows installer outline.
# Not implemented. The supported path is install-mac.sh.
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

Write-Host @"
Remax Secure Printer — Windows installer is not built yet.

Use the Mac installer. From an admin Terminal on the agent Mac:

  curl -fsSL https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-mac.sh | sudo bash

A future Windows script would need to land the same queue, without a GUI:

  Queue name:  RemaxSecure
  Port / URI:  lpd://172.16.105.21/RemaxSecure
  Driver:      Canon iR-ADV C5235/5240 PS (CNMCIRAC5235S2)
  Hardware:    Cassette Feeding Unit ON
               Output options = Inner Finisher E1
               One-sided
  User info:   Enter Name = the print username (not Log-in name)

Do not treat a successful-looking Windows print dialog as proof. There is
no Windows implementation in this repo yet.
"@

exit 1
