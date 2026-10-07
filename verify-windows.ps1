#Requires -Version 5.1
# Read-only check of the RemaxSecure queue. Does not change the spooler.
# The checks live in install-windows.ps1 so a one-file download stays in sync.
#
# From this repo (PowerShell):
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\verify-windows.ps1
#
# One file from GitHub, in any PowerShell window:
#   $s = Join-Path $env:TEMP 'remax-install-windows.ps1'
#   Invoke-RestMethod https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-windows.ps1 -OutFile $s
#   powershell -NoProfile -ExecutionPolicy Bypass -File $s -Verify

$ErrorActionPreference = 'Stop'
$installer = $null
if (-not [string]::IsNullOrEmpty($PSScriptRoot)) {
    $installer = Join-Path $PSScriptRoot 'install-windows.ps1'
}
if (-not $installer -or -not (Test-Path -LiteralPath $installer)) {
    Write-Host @'
verify-windows.ps1 runs beside install-windows.ps1.

From PowerShell, download the installer and pass -Verify:

  $s = Join-Path $env:TEMP 'remax-install-windows.ps1'
  Invoke-RestMethod https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-windows.ps1 -OutFile $s
  powershell -NoProfile -ExecutionPolicy Bypass -File $s -Verify

Optional: $env:REMAX_PRINT_USER = 'tsiogase' before that command.
Verify opens Printer properties, reads Device Settings, and clicks Cancel.
PASS on Enter Name means User Name and Name to Set for User Name were read back.
'@
    if ($PSCommandPath) { exit 1 }
    throw 'verify-windows.ps1 could not find install-windows.ps1'
}

& $installer -Verify
if ($null -eq $global:RemaxExitCode) { $global:RemaxExitCode = 1 }
if ($PSCommandPath) { exit ([int]$global:RemaxExitCode) }
if ([int]$global:RemaxExitCode -ne 0) {
    throw ("Remax Secure Printer verify finished with exit code " + $global:RemaxExitCode)
}
