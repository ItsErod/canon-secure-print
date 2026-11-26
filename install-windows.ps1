#Requires -Version 5.1
# Remax Secure Printer - Windows installer 1.2.0
# RE/MAX Escarpment IT. Ground truth is the recorded Windows 11 setup.
#
# Elevated PowerShell (Run as administrator). The script asks for the print
# username in that window (last name + first initial, lowercase, for example
# tsiogase). An elevated process does not see variables from a normal window.
# To skip the prompt:
#
#   $env:REMAX_PRINT_USER = 'tsiogase'
#   irm https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-windows.ps1 | iex
#
# Agent one-liner (prompts for the print username, not the Windows logon):
#
#   irm https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-windows.ps1 | iex
#
# Same window, file form:
#
#   Set-ExecutionPolicy -Scope Process Bypass
#   $s = Join-Path $env:TEMP 'remax-install-windows.ps1'
#   Invoke-RestMethod https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-windows.ps1 -OutFile $s
#   & $s
#
# Read-only check (opens Printer properties, reads Device Settings, clicks Cancel):
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-windows.ps1 -Verify
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\verify-windows.ps1
#
# Logic checks, no printer changes:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-windows.ps1 -SelfTest
#
# Recorded queue:
#   Name:     RemaxSecure, not shared, not the default printer.
#   URI:      lpd://172.16.105.21/RemaxSecure
#   Port:     Standard TCP/IP port named 172.16.105.21 (the host).
#             Protocol LPR (registry Protocol=2), queue RemaxSecure,
#             LPR byte counting on (Byte Count=1), SNMP off (SNMP Enabled=0).
#             Older installs used port RemaxSecure_LPR. The queue is moved
#             onto the host-named port.
#   Driver:   Canon iR-ADV C5235/5240 PS3, Canon PS3 Printer Driver Ver. 30.00,
#             x64 (Setup.exe file version 30.0.0.1). Canon Driver Information
#             Assist Service is not required.
#   Sides:    Set-PrintConfiguration -DuplexingMode OneSided (1-sided Printing).
#   Device Settings, tried first through Get-PrinterProperty / Set-PrinterProperty
#   when the driver publishes a matching Config:* property and the readback
#   matches. PrinterDriverData and Default DevMode are listed by value name
#   only. Their binary layout is not published for this driver, so it is not
#   written. UI Automation is the fallback, and it follows the recorded
#   controls:
#     Paper Source Options: = Cassette Feeding Unit
#     Output Options: = Inner Finisher E1
#     Set User Information checked, then the Settings... button on that row
#     Dialog title Default Value Settings
#     Name to Set for User Information: radio User Name (not Logon Name)
#     and the text box under that radio
#     Always Confirm User Information When Performing Secured Print stays on
#     Confirm User Name When Printing stays off, PIN stays blank
#     Get Device Information is not changed
#   PASS on those lines requires a property readback or a dialog readback
#   after Printer properties is reopened. MANUAL means that item was not
#   confirmed. Optional REMAX_DEVICE_DAT restores printer-specific data and
#   the global DEVMODE (PrintUI /Sr d g) before the dialog runs.

$script:Version = '1.2.0'
$script:RawUrl = 'https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-windows.ps1'
$script:PrinterName = 'RemaxSecure'
$script:StaleName = 'RemaxSecure_COLOUR'
$script:DefaultHost = '172.16.105.21'
$script:DefaultQueue = 'RemaxSecure'
$script:LegacyPortName = 'RemaxSecure_LPR'
$script:PortName = '172.16.105.21'
$script:ExactDriverName = 'Canon iR-ADV C5235/5240 PS3'
$script:DriverPackageVersion = '30.00'
$script:DriverFileVersion = '30.0.0.1'
$script:PsfNamespace = 'http://schemas.microsoft.com/windows/2003/08/printing/printschemaframework'
$script:LogFile = $null
$script:SupportDir = $null
$script:ReportDone = $false
$script:Completing = $false
$script:RanAsFile = -not [string]::IsNullOrEmpty($PSCommandPath)
$script:PreviousErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Stop'

$script:Mode = 'install'
$script:UserArg = ''
$script:UsageError = ''
foreach ($argument in @($args)) {
    $text = [string]$argument
    switch ($text) {
        '-Verify' { $script:Mode = 'verify' }
        '-SelfTest' { $script:Mode = 'selftest' }
        '--self-test' { $script:Mode = 'selftest' }
        '-Help' { $script:Mode = 'help' }
        '--help' { $script:Mode = 'help' }
        '-h' { $script:Mode = 'help' }
        default {
            if ($text.StartsWith('-')) {
                $script:Mode = 'usage-error'
                $script:UsageError = "Unknown option: $text"
            } else {
                $script:UserArg = $text
            }
        }
    }
}
if ($env:REMAX_MODE -eq 'verify' -and $script:Mode -eq 'install') {
    $script:Mode = 'verify'
}

function Write-RemaxLine {
    param([string]$Line)
    try {
        [Console]::Out.WriteLine($Line)
    } catch {
        Write-Host $Line
    }
    if ($script:LogFile) {
        try {
            Add-Content -LiteralPath $script:LogFile -Value $Line -Encoding UTF8
        } catch {
        }
    }
}

function Write-Remax {
    param([string]$Message)
    Write-RemaxLine ("[RemaxSecure] " + $Message)
}

function Test-WindowsHost {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return [bool]$IsWindows
    }
    return $true
}

function Invoke-Complete {
    param([int]$Code)
    $global:RemaxExitCode = $Code
    if (-not $script:RanAsFile) {
        $ErrorActionPreference = $script:PreviousErrorAction
    }
    if ($script:Completing) {
        if ($script:RanAsFile) { exit $Code }
        return
    }
    $script:Completing = $true
    if ($script:RanAsFile) { exit $Code }
    if ($Code -eq 2) {
        Write-RemaxLine "Exit code 2 (RESULT PARTIAL). MANUAL lines were not verified. The queue install is not a failure, and this window stays open."
        return
    }
    if ($Code -ne 0) {
        throw "Remax Secure Printer finished with exit code $Code."
    }
}

function Show-Usage {
    Write-RemaxLine @"
Remax Secure Printer installer $script:Version (Windows)

  irm $script:RawUrl | iex

  `$env:REMAX_PRINT_USER = 'tsiogase'
  irm $script:RawUrl | iex

  powershell -NoProfile -ExecutionPolicy Bypass -File install-windows.ps1 -Verify
  powershell -NoProfile -ExecutionPolicy Bypass -File install-windows.ps1 -SelfTest

Environment (set them in the elevated PowerShell window):
  REMAX_PRINT_USER       Print username (last name + first initial, lowercase,
                         for example tsiogase). Prompted when unset.
  REMAX_CANON_PKG_URL    Optional https URL of a .zip, .cab, or .inf driver.
                         A Canon setup .exe is not launched. Prefer the
                         x64 folder of Canon PS3 Printer Driver Ver. 30.00.
  REMAX_PRINTER_URI      Default lpd://172.16.105.21/RemaxSecure
                         The Standard TCP/IP port is named after the host.
  REMAX_LPR_BYTE_COUNT   Default on. Set to 0 to disable LPR byte counting.
  REMAX_MODE             Set to verify for irm | iex read-only mode.
  REMAX_DEVICE_UI        Set to 0 to skip Printer properties automation.
  REMAX_DEVICE_DAT       Optional PrintUI file. Restored with /Sr d g r
                         before Device Settings automation.

Exit codes: 0 every line PASS, 2 queue installed and MANUAL lines remain, 1 failed.
Exit code 2 does not throw when the script is run with irm | iex.
"@
}

function Test-ModelSpecificPsDriver {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name -notmatch 'C5235') { return $false }
    if ($Name -notmatch '5240') { return $false }
    if ($Name -match 'UFR|PCL|LIPS|FAX|\bXPS\b') { return $false }
    if ($Name -notmatch 'PS|PostScript') { return $false }
    return $true
}

function Test-ExactPs3Driver {
    param([string]$Name)
    return ($Name -eq $script:ExactDriverName)
}

function Test-GenericPlusPs3 {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name -match 'UFR|PCL|LIPS|FAX') { return $false }
    return [bool]($Name -match 'Canon Generic Plus PS3')
}

function Get-DriverRank {
    param([string]$Name)
    if (Test-ExactPs3Driver $Name) { return 3 }
    if (Test-ModelSpecificPsDriver $Name) { return 2 }
    if (Test-GenericPlusPs3 $Name) { return 1 }
    return 0
}

function Test-CanonPackageVersionText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $trim = $Text.Trim()
    if ($trim -eq $script:DriverFileVersion) { return $true }
    if ($trim.StartsWith($script:DriverFileVersion)) { return $true }
    if ($trim -match '(?i)(^|[^0-9])30\.00([^0-9]|$)') { return $true }
    return $false
}

function Get-InfArchitectureScore {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return 1 }
    $norm = $Path.Replace('/', '\')
    if ($norm -match '(?i)\\(x64|amd64|win64)\\') { return 2 }
    if ($norm -match '(?i)NTamd64') { return 2 }
    if ($norm -match '(?i)\\(x86|win32|32bit)\\') { return 0 }
    return 1
}

function Select-BestDriverName {
    param([string[]]$Names)
    $best = $null
    $bestRank = 0
    foreach ($name in @($Names)) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $rank = Get-DriverRank $name
        if ($rank -gt $bestRank) {
            $bestRank = $rank
            $best = $name
        }
    }
    return $best
}

function Test-PrintUserName {
    param([string]$Name)
    return [bool]($Name -match '^[A-Za-z0-9._-]{1,64}$')
}

function Resolve-PrinterTarget {
    $hostName = $script:DefaultHost
    $queue = $script:DefaultQueue
    if (-not [string]::IsNullOrWhiteSpace($env:REMAX_PRINTER_HOST)) {
        $hostName = $env:REMAX_PRINTER_HOST.Trim()
    }
    if (-not [string]::IsNullOrWhiteSpace($env:REMAX_LPR_QUEUE)) {
        $queue = $env:REMAX_LPR_QUEUE.Trim()
    }
    if (-not [string]::IsNullOrWhiteSpace($env:REMAX_PRINTER_URI)) {
        $uri = $env:REMAX_PRINTER_URI.Trim()
        if ($uri -notmatch '^lpd://([^/]+)/([^/\s]+)$') {
            throw "REMAX_PRINTER_URI must look like lpd://172.16.105.21/RemaxSecure (got $uri)"
        }
        $hostName = $Matches[1]
        $queue = $Matches[2]
    }
    if ($hostName -notmatch '^[A-Za-z0-9.-]{1,253}$') {
        throw "Printer host is not a hostname or IPv4 address: $hostName"
    }
    if ($queue -notmatch '^[A-Za-z0-9._-]{1,64}$') {
        throw "LPR queue name must be 1-64 letters, digits, dot, underscore, or hyphen."
    }
    $script:PortName = $hostName
    return @{
        Host       = $hostName
        Queue      = $queue
        Uri        = ("lpd://{0}/{1}" -f $hostName, $queue)
        PortName   = $hostName
        ByteCount  = -not ($env:REMAX_LPR_BYTE_COUNT -eq '0')
    }
}

function Get-PrintUserPromptText {
    return 'Print username (last name + first initial, lowercase, for example tsiogase)'
}

function Remove-InfComment {
    param([string]$Line)
    $inQuote = $false
    $builder = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $ch = $Line[$i]
        if ($ch -eq [char]'"') { $inQuote = -not $inQuote }
        if (($ch -eq [char]';') -and -not $inQuote) { break }
        [void]$builder.Append($ch)
    }
    return $builder.ToString()
}

function Get-InfDriverModels {
    param(
        [string]$Text,
        [string]$Architecture
    )
    if ([string]::IsNullOrWhiteSpace($Architecture)) { $Architecture = 'amd64' }
    $normalized = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    $sections = @{}
    $current = ''
    foreach ($rawLine in ($normalized -split "`n")) {
        $line = (Remove-InfComment $rawLine).Trim()
        if ($line.Length -eq 0) { continue }
        if ($line -match '^\[(.+)\]$') {
            $current = $Matches[1].Trim()
            if (-not $sections.ContainsKey($current)) {
                $sections[$current] = New-Object System.Collections.Generic.List[string]
            }
            continue
        }
        if ($current -and $sections.ContainsKey($current)) {
            $sections[$current].Add($line)
        }
    }
    $strings = @{}
    if ($sections.ContainsKey('Strings')) {
        foreach ($line in $sections['Strings']) {
            $eq = $line.IndexOf('=')
            if ($eq -lt 1) { continue }
            $key = $line.Substring(0, $eq).Trim()
            $val = $line.Substring($eq + 1).Trim()
            if ($val.Length -ge 2 -and $val.StartsWith('"') -and $val.EndsWith('"')) {
                $val = $val.Substring(1, $val.Length - 2)
            }
            $strings[$key] = $val
        }
    }
    if (-not $sections.ContainsKey('Manufacturer')) { return @() }
    $preferred = New-Object System.Collections.Generic.List[string]
    $fallback = New-Object System.Collections.Generic.List[string]
    foreach ($line in $sections['Manufacturer']) {
        $comma = $line.Split(',')
        $eq = $comma[0].IndexOf('=')
        if ($eq -lt 0) { continue }
        $base = $comma[0].Substring($eq + 1).Trim()
        if ($base.Length -eq 0) { continue }
        $fallback.Add($base)
        for ($i = 1; $i -lt $comma.Length; $i++) {
            $decoration = $comma[$i].Trim()
            if ($decoration.Length -eq 0) { continue }
            $sectionName = "$base.$decoration"
            $archOk = $false
            if ($Architecture -eq 'amd64' -and $decoration -match '(?i)^NTamd64($|\.)') { $archOk = $true }
            if ($Architecture -eq 'x86' -and $decoration -match '(?i)^NTx86($|\.)') { $archOk = $true }
            if ($archOk) { $preferred.Add($sectionName) }
        }
    }
    $use = New-Object System.Collections.Generic.List[string]
    foreach ($name in $preferred) {
        if ($sections.ContainsKey($name)) { $use.Add($name) }
    }
    if ($use.Count -eq 0) {
        foreach ($name in $fallback) {
            if ($sections.ContainsKey($name)) { $use.Add($name) }
        }
    }
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($sectionName in $use) {
        foreach ($line in $sections[$sectionName]) {
            $model = $null
            if ($line -match '^"([^"]+)"\s*=') {
                $model = $Matches[1]
            } elseif ($line -match '^%([^%]+)%\s*=') {
                $key = $Matches[1]
                if ($strings.ContainsKey($key)) { $model = [string]$strings[$key] }
            }
            if (-not [string]::IsNullOrWhiteSpace($model)) {
                $found.Add($model.Trim())
            }
        }
    }
    return @($found.ToArray())
}

function Get-XmlLocalName {
    param([string]$Qualified)
    if ([string]::IsNullOrWhiteSpace($Qualified)) { return '' }
    $colon = $Qualified.LastIndexOf(':')
    if ($colon -ge 0 -and $colon -lt ($Qualified.Length - 1)) {
        return $Qualified.Substring($colon + 1)
    }
    return $Qualified
}

function Get-ElementDisplayName {
    param($Element)
    foreach ($child in @($Element.ChildNodes)) {
        if ($child.LocalName -ne 'Property') { continue }
        if ((Get-XmlLocalName $child.GetAttribute('name')) -ne 'DisplayName') { continue }
        foreach ($grand in @($child.ChildNodes)) {
            if ($grand.LocalName -eq 'Value') { return ([string]$grand.InnerText).Trim() }
        }
    }
    return ''
}

function Find-PrintFeatureOption {
    param(
        [string]$CapabilitiesXml,
        [string]$OptionLocalName,
        [string]$FeatureDisplay,
        [string]$OptionDisplay
    )
    if ([string]::IsNullOrWhiteSpace($CapabilitiesXml)) { return $null }
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.LoadXml($CapabilitiesXml)
    $fallback = $null
    foreach ($feature in @($doc.GetElementsByTagName('*'))) {
        if ($feature.LocalName -ne 'Feature') { continue }
        $featureName = $feature.GetAttribute('name')
        $featureLabel = Get-ElementDisplayName $feature
        foreach ($option in @($feature.ChildNodes)) {
            if ($option.LocalName -ne 'Option') { continue }
            $optionName = $option.GetAttribute('name')
            $optionLocal = Get-XmlLocalName $optionName
            $optionLabel = Get-ElementDisplayName $option
            if ($OptionLocalName -and $optionLocal -eq $OptionLocalName) {
                return @{
                    Feature = $featureName
                    Option  = $optionName
                    How     = "option $optionLocal"
                }
            }
            $displayHit = $false
            if ($OptionDisplay -and $optionLabel -eq $OptionDisplay) {
                if ([string]::IsNullOrWhiteSpace($FeatureDisplay) -or $featureLabel -eq $FeatureDisplay) {
                    $displayHit = $true
                }
            }
            if ($displayHit -and -not $fallback) {
                $fallback = @{
                    Feature = $featureName
                    Option  = $optionName
                    How     = "display $featureLabel / $optionLabel"
                }
            }
        }
    }
    return $fallback
}

function Update-PrintTicketXml {
    param(
        [string]$TicketXml,
        [string]$FeatureName,
        [string]$OptionName
    )
    if ([string]::IsNullOrWhiteSpace($TicketXml)) {
        $TicketXml = @"
<?xml version="1.0"?>
<psf:PrintTicket version="1" xmlns:psf="$($script:PsfNamespace)"></psf:PrintTicket>
"@
    }
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.LoadXml($TicketXml)
    $target = $null
    foreach ($node in @($doc.GetElementsByTagName('*'))) {
        if ($node.LocalName -eq 'Feature' -and $node.GetAttribute('name') -eq $FeatureName) {
            $target = $node
            break
        }
    }
    if (-not $target) {
        $target = $doc.CreateElement('psf', 'Feature', $script:PsfNamespace)
        [void]$target.SetAttribute('name', $FeatureName)
        [void]$doc.DocumentElement.AppendChild($target)
    }
    $remove = @()
    foreach ($child in @($target.ChildNodes)) {
        if ($child.LocalName -eq 'Option') { $remove += $child }
    }
    foreach ($child in @($remove)) {
        [void]$target.RemoveChild($child)
    }
    $option = $doc.CreateElement('psf', 'Option', $script:PsfNamespace)
    [void]$option.SetAttribute('name', $OptionName)
    [void]$target.AppendChild($option)
    return $doc.OuterXml
}

function Test-TicketHasOption {
    param(
        [string]$TicketXml,
        [string]$OptionLocalName
    )
    if ([string]::IsNullOrWhiteSpace($TicketXml)) { return $false }
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($TicketXml)
    foreach ($node in @($doc.GetElementsByTagName('*'))) {
        if ($node.LocalName -ne 'Option') { continue }
        if ((Get-XmlLocalName $node.GetAttribute('name')) -eq $OptionLocalName) { return $true }
    }
    return $false
}

function Get-ResultLabel {
    param([string[]]$States)
    $sawManual = $false
    foreach ($state in @($States)) {
        if ($state -eq 'FAIL') { return 'FAIL' }
        if ($state -eq 'MANUAL') { $sawManual = $true }
    }
    if ($sawManual) { return 'PARTIAL' }
    return 'PASS'
}

function Get-ExitCodeForResult {
    param([string]$Result)
    switch ($Result) {
        'PASS' { return 0 }
        'PARTIAL' { return 2 }
        default { return 1 }
    }
}

function Read-StreamText {
    param($Stream)
    if (-not $Stream) { return '' }
    $reader = New-Object System.IO.StreamReader($Stream)
    try {
        return $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
    }
}

function Read-AllText {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254) {
        return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 254 -and $bytes[1] -eq 255) {
        return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
        return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Get-DriverArchitecture {
    if ([Environment]::Is64BitOperatingSystem) { return 'amd64' }
    return 'x86'
}

function Initialize-RemaxLog {
    param([string]$Kind)
    if ($env:REMAX_SUPPORT_DIR) {
        $script:SupportDir = $env:REMAX_SUPPORT_DIR
    } elseif ($env:ProgramData) {
        $script:SupportDir = Join-Path $env:ProgramData 'RemaxSecurePrinter'
    } else {
        $script:SupportDir = Join-Path $env:TEMP 'RemaxSecurePrinter'
    }
    if ($env:REMAX_LOG) {
        $script:LogFile = $env:REMAX_LOG
    } else {
        $name = "RemaxSecurePrinterSetup-windows.log"
        if ($Kind -eq 'verify') { $name = "RemaxSecurePrinterVerify-windows.log" }
        $script:LogFile = Join-Path $env:TEMP $name
    }
    $parent = Split-Path -Parent $script:LogFile
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $header = @(
        "Remax Secure Printer Windows $Kind $script:Version"
        ("date: " + (Get-Date).ToString('o'))
        ("os: " + [Environment]::OSVersion.VersionString)
    )
    Set-Content -LiteralPath $script:LogFile -Value $header -Encoding UTF8
}

function Copy-RemaxLog {
    param([string]$Result, [string]$PrintUser, $Target)
    if (-not $script:LogFile -or -not (Test-Path -LiteralPath $script:LogFile)) { return }
    try {
        if (-not (Test-Path -LiteralPath $script:SupportDir)) {
            New-Item -ItemType Directory -Path $script:SupportDir -Force | Out-Null
        }
        $leaf = Split-Path -Leaf $script:LogFile
        Copy-Item -LiteralPath $script:LogFile -Destination (Join-Path $script:SupportDir $leaf) -Force
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $stamped = $leaf -replace '\.log$', ("-" + $stamp + ".log")
        Copy-Item -LiteralPath $script:LogFile -Destination (Join-Path $script:SupportDir $stamped) -Force
        if ($Result) {
            $summary = @(
                ("date=" + (Get-Date).ToString('o'))
                ("version=" + $script:Version)
                ("result=" + $Result)
                ("print_user=" + $PrintUser)
                ("queue=" + $script:PrinterName)
                ("uri=" + $Target.Uri)
                ("port=" + $script:PortName)
            )
            Set-Content -LiteralPath (Join-Path $script:SupportDir 'last-install.txt') -Value $summary -Encoding ASCII
            if ($PrintUser) {
                Set-Content -LiteralPath (Join-Path $script:SupportDir 'requested-print-user.txt') -Value $PrintUser -Encoding ASCII
            }
        }
    } catch {
        Write-Remax ("Could not copy the log to " + $script:SupportDir + ": " + $_.Exception.Message)
    }
}

function Test-RemaxAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Show-AdminHelp {
    Write-RemaxLine @"
This installer must run in an elevated PowerShell window (Run as administrator).

Set REMAX_PRINT_USER in that elevated window. A variable from a normal window
is not visible after User Account Control elevates:

  Set-ExecutionPolicy -Scope Process Bypass
  `$env:REMAX_PRINT_USER = 'tsiogase'
  `$s = Join-Path `$env:TEMP 'remax-install-windows.ps1'
  Invoke-RestMethod $script:RawUrl -OutFile `$s
  & `$s
"@
}

function Read-PrintUserPrompt {
    $prompt = Get-PrintUserPromptText
    $redirected = $true
    try {
        $redirected = [bool][Console]::IsInputRedirected
    } catch {
        $redirected = $true
    }
    if (-not $redirected) {
        $typed = Read-Host $prompt
        if ($null -eq $typed) { return '' }
        return ([string]$typed).Trim()
    }
    Write-RemaxLine ($prompt + ': ')
    $stream = $null
    $reader = $null
    try {
        $stream = [System.IO.File]::Open(
            'CONIN$',
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        $reader = New-Object System.IO.StreamReader($stream)
        $stream = $null
        $typed = $reader.ReadLine()
        if ($null -eq $typed) { return '' }
        return ([string]$typed).Trim()
    } catch {
        return ''
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
}

function Resolve-PrintUserName {
    param([string]$Argument)
    $user = ''
    if (-not [string]::IsNullOrWhiteSpace($env:REMAX_PRINT_USER)) {
        $user = $env:REMAX_PRINT_USER.Trim()
    } elseif (-not [string]::IsNullOrWhiteSpace($Argument)) {
        $user = $Argument.Trim()
    } else {
        $interactive = $false
        try {
            $interactive = [bool][Environment]::UserInteractive
        } catch {
            $interactive = $false
        }
        if ($interactive) {
            $user = Read-PrintUserPrompt
            if ($null -eq $user) { $user = '' }
            $user = $user.Trim()
        }
    }
    if (-not (Test-PrintUserName $user)) {
        throw @"
Print username must be 1-64 characters: letters, digits, dot, underscore, hyphen.
Format is last name + first initial, lowercase, for example tsiogase.
The Windows logon name is not used. Set it in the elevated window:

  `$env:REMAX_PRINT_USER = 'tsiogase'
  irm $script:RawUrl | iex
"@
    }
    return $user
}

function Import-PrintModule {
    Import-Module PrintManagement -ErrorAction Stop
}

function Get-InstalledDriverNames {
    Import-PrintModule
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($driver in @(Get-PrinterDriver)) {
        if ($driver.Name) { $names.Add([string]$driver.Name) }
    }
    return @($names.ToArray())
}

function Test-FileStartsWithPpdAdobe {
    param([string]$Path)
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $buf = New-Object byte[] 64
        $read = $stream.Read($buf, 0, 64)
        if ($read -lt 8) { return $false }
        $text = [System.Text.Encoding]::ASCII.GetString($buf, 0, $read)
        return [bool]($text -match '\*PPD-Adobe:')
    } catch {
        return $false
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Test-DriverPpdAcceptable {
    param($Driver)
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($prop in @('DataFile', 'ConfigFile')) {
        $value = [string]$Driver.$prop
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        if ([System.IO.Path]::IsPathRooted($value)) {
            $candidates.Add($value)
        } elseif ($Driver.InfPath) {
            $candidates.Add((Join-Path (Split-Path -Parent ([string]$Driver.InfPath)) $value))
        }
    }
    $sawPpd = $false
    foreach ($path in @($candidates.ToArray())) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $leaf = [System.IO.Path]::GetFileName($path)
        $isPpd = $leaf -match '(?i)\.ppd$'
        if (-not $isPpd) { $isPpd = Test-FileStartsWithPpdAdobe $path }
        if (-not $isPpd) { continue }
        $sawPpd = $true
        $text = Read-AllText $path
        $nick = $null
        $model = $null
        foreach ($line in ($text -split "`n")) {
            $trim = $line.Trim("`r")
            if (-not $nick -and $trim -match '^\*NickName:') { $nick = $trim }
            if (-not $model -and $trim -match '^\*ModelName:') { $model = $trim }
        }
        $ok = $nick -and $model -and ($nick -match 'C5235') -and ($nick -match '5240') -and ($model -match 'C5235') -and ($model -match '5240')
        if (-not $ok) {
            Write-Remax ("Skipping " + $Driver.Name + " because its PPD NickName/ModelName are not C5235 and 5240 (" + $path + ")")
            return $false
        }
        Write-Remax ("Driver PPD matches C5235/5240: " + $path)
        return $true
    }
    if (-not $sawPpd) {
        Write-Remax ("Driver " + $Driver.Name + " has no PPD data file. Accepting it from the driver name.")
    }
    return $true
}

function Get-FileVersionOrEmpty {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        if ($info.FileVersion) { return [string]$info.FileVersion }
    } catch { }
    return ''
}

function Get-DriverFileVersionText {
    param($Driver)
    if (-not $Driver) { return '' }
    $primary = New-Object System.Collections.Generic.List[string]
    $extra = New-Object System.Collections.Generic.List[string]
    foreach ($prop in @('ConfigFile', 'DataFile', 'DriverPath')) {
        $value = ''
        try { $value = [string]$Driver.$prop } catch { $value = '' }
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        if ([System.IO.Path]::IsPathRooted($value)) { [void]$primary.Add($value) }
    }
    try {
        foreach ($file in @($Driver.DependentFiles)) {
            if ([string]::IsNullOrWhiteSpace([string]$file)) { continue }
            if ([System.IO.Path]::IsPathRooted([string]$file)) { [void]$extra.Add([string]$file) }
        }
    } catch { }
    foreach ($path in @($primary.ToArray() + $extra.ToArray())) {
        $version = Get-FileVersionOrEmpty $path
        if ((Test-CanonPackageVersionText $version) -eq $true) { return $version }
    }
    foreach ($path in @($primary.ToArray())) {
        $version = Get-FileVersionOrEmpty $path
        if ($version) { return $version }
    }
    return ''
}

function Get-DriverReport {
    param($Driver, [string]$VersionText)
    $name = ''
    $environment = ''
    if ($Driver) {
        try { $name = [string]$Driver.Name } catch { $name = '' }
        try { $environment = [string]$Driver.PrinterEnvironment } catch { $environment = '' }
    }
    if (-not (Test-ExactPs3Driver $name)) {
        $shown = $name
        if (-not $shown) { $shown = 'unknown' }
        return @{
            State  = 'MANUAL'
            Detail = ("installed driver '" + $shown + "' is not " + $script:ExactDriverName)
        }
    }
    if ($null -eq $VersionText -or $VersionText -eq '') {
        if ($Driver -and -not $PSBoundParameters.ContainsKey('VersionText')) {
            $VersionText = Get-DriverFileVersionText $Driver
        }
    }
    $versionState = Test-CanonPackageVersionText $VersionText
    $nativeX64 = $false
    try { $nativeX64 = [bool][Environment]::Is64BitOperatingSystem } catch { $nativeX64 = $true }
    $archOk = $true
    if ($environment) {
        if ($nativeX64) { $archOk = [bool]($environment -match 'x64') }
        else { $archOk = [bool]($environment -match 'x86|32') }
    }
    $problems = @()
    if (-not $archOk) {
        $problems += ("environment '" + $environment + "' is not the x64 package")
    }
    if ($versionState -eq $false) {
        $problems += ("file version '" + $VersionText + "' is not " + $script:DriverFileVersion + " (package " + $script:DriverPackageVersion + ")")
    }
    if ($problems.Count -gt 0) {
        return @{
            State  = 'MANUAL'
            Detail = ($name + ". " + ($problems -join '. '))
        }
    }
    $detail = $name + " (PS3 Printer Driver Ver. " + $script:DriverPackageVersion
    if ($environment) { $detail = $detail + ", " + $environment }
    if ($VersionText) { $detail = $detail + ", file version " + $VersionText }
    else { $detail = $detail + ", package version was not exposed by the spooler" }
    $detail = $detail + ")"
    return @{ State = 'PASS'; Detail = $detail }
}

function Find-SelectedInstalledDriver {
    Import-PrintModule
    $best = $null
    $bestScore = 0
    $nativeX64 = [Environment]::Is64BitOperatingSystem
    foreach ($driver in @(Get-PrinterDriver)) {
        $rank = Get-DriverRank ([string]$driver.Name)
        if ($rank -lt 1) { continue }
        if (-not (Test-DriverPpdAcceptable $driver)) { continue }
        $environment = [string]$driver.PrinterEnvironment
        $archBonus = 0
        if ($nativeX64 -and $environment -match 'x64') { $archBonus = 2 }
        if ((-not $nativeX64) -and $environment -match 'x86') { $archBonus = 2 }
        $versionBonus = 0
        $versionText = Get-DriverFileVersionText $driver
        if ((Test-CanonPackageVersionText $versionText) -eq $true) { $versionBonus = 1 }
        $score = ($rank * 10) + $archBonus + $versionBonus
        if ($score -gt $bestScore) {
            $bestScore = $score
            $best = $driver
        }
    }
    if ($best) { return $best }
    return $null
}

function Install-DriverFromInf {
    param(
        [string]$InfPath,
        [string]$Model
    )
    Write-Remax ("Adding driver package " + $InfPath)
    & pnputil.exe /add-driver $InfPath /install
    if ($LASTEXITCODE -ne 0) {
        Write-Remax ("pnputil /add-driver exited " + $LASTEXITCODE + ". Trying pnputil -i -a.")
        & pnputil.exe -i -a $InfPath
        if ($LASTEXITCODE -ne 0) {
            Write-Remax ("pnputil -i -a exited " + $LASTEXITCODE + ". Still trying Add-PrinterDriver.")
        }
    }
    try {
        Add-PrinterDriver -Name $Model -InfPath $InfPath
        Write-Remax ("Registered printer driver " + $Model)
    } catch {
        Write-Remax ("Add-PrinterDriver for " + $Model + ": " + $_.Exception.Message)
    }
}

function Install-CanonPackageFromUrl {
    param([string]$Url)
    if ($Url -notmatch '^https://') {
        throw "REMAX_CANON_PKG_URL must be an https URL of a .zip, .cab, or .inf."
    }
    $leaf = ''
    try {
        $leaf = [System.IO.Path]::GetFileName(([Uri]$Url).AbsolutePath)
    } catch {
        throw "REMAX_CANON_PKG_URL is not a valid URL."
    }
    $lower = $leaf.ToLowerInvariant()
    $kind = ''
    if ($lower.EndsWith('.zip')) { $kind = 'zip' }
    elseif ($lower.EndsWith('.cab')) { $kind = 'cab' }
    elseif ($lower.EndsWith('.inf')) { $kind = 'inf' }
    elseif ($lower.EndsWith('.exe')) { $kind = 'exe' }
    else {
        throw "REMAX_CANON_PKG_URL must end in .zip, .cab, .inf, or .exe. This script only extracts an INF. It does not run a Canon setup EXE unless 7-Zip can unpack it."
    }
    $work = Join-Path $env:TEMP ("remax-canon-" + [Guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $download = Join-Path $work 'download.bin'
        Write-Remax ("Downloading Canon driver description from " + $Url)
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch {
        }
        Invoke-WebRequest -Uri $Url -OutFile $download -UseBasicParsing
        $length = (Get-Item -LiteralPath $download).Length
        if ($length -gt 250MB) {
            throw "Downloaded file is larger than 250 MB. Refusing to continue."
        }
        if ($length -lt 64) {
            throw "Downloaded file is too small to be a Canon driver package."
        }
        $extract = Join-Path $work 'extract'
        New-Item -ItemType Directory -Path $extract -Force | Out-Null
        if ($kind -eq 'inf') {
            Copy-Item -LiteralPath $download -Destination (Join-Path $extract $leaf) -Force
        } elseif ($kind -eq 'zip') {
            Expand-Archive -LiteralPath $download -DestinationPath $extract -Force
        } elseif ($kind -eq 'cab') {
            & expand.exe $download -F:* $extract
            if ($LASTEXITCODE -ne 0) { throw "expand.exe could not unpack the cab." }
        } else {
            $seven = $null
            foreach ($candidate in @(
                    '7z'
                    (Join-Path $env:ProgramFiles '7-Zip\7z.exe')
                    (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe')
                )) {
                if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
                if ($candidate -eq '7z') {
                    $cmd = Get-Command 7z -ErrorAction SilentlyContinue
                    if ($cmd) { $seven = $cmd.Source }
                } elseif (Test-Path -LiteralPath $candidate) {
                    $seven = $candidate
                }
                if ($seven) { break }
            }
            if (-not $seven) {
                throw "The URL is an .exe. This script does not launch Canon setup (it opens a GUI, and the silent switches are not stable). Install 7-Zip so the EXE can be unpacked, or point REMAX_CANON_PKG_URL at a .zip of the extracted Driver folder that contains the INF."
            }
            Write-Remax ("Unpacking EXE with 7-Zip, not executing it: " + $seven)
            & $seven x -y ("-o" + $extract) $download
            if ($LASTEXITCODE -ne 0) {
                throw "7-Zip could not unpack the EXE. Point REMAX_CANON_PKG_URL at a .zip of the extracted Driver folder."
            }
        }
        $bestInf = $null
        $bestModel = $null
        $bestRank = 0
        $bestPathScore = -1
        $arch = Get-DriverArchitecture
        foreach ($inf in @(Get-ChildItem -LiteralPath $extract -Filter *.inf -Recurse -File -ErrorAction SilentlyContinue)) {
            $models = @(Get-InfDriverModels -Text (Read-AllText $inf.FullName) -Architecture $arch)
            $choice = Select-BestDriverName -Names $models
            $rank = Get-DriverRank $choice
            $pathScore = Get-InfArchitectureScore $inf.FullName
            Write-Remax ("INF " + $inf.FullName + " selected model '" + $choice + "' rank " + $rank + " path " + $pathScore)
            $better = $false
            if ($rank -gt $bestRank) { $better = $true }
            elseif ($rank -eq $bestRank -and $rank -gt 0 -and $pathScore -gt $bestPathScore) { $better = $true }
            if ($better) {
                $bestRank = $rank
                $bestPathScore = $pathScore
                $bestInf = $inf.FullName
                $bestModel = $choice
            }
        }
        if (-not $bestInf) {
            throw ("The package does not contain an INF model for " + $script:ExactDriverName + ".")
        }
        Install-DriverFromInf -InfPath $bestInf -Model $bestModel
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Search-DriverStore {
    $root = Join-Path $env:windir 'System32\DriverStore\FileRepository'
    if (-not (Test-Path -LiteralPath $root)) { return }
    Write-Remax ("Searching driver store under " + $root)
    $dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match '(?i)canon|cns3|cns30|cnlb|gplus|ps3|iradv|ir-adv'
        })
    $arch = Get-DriverArchitecture
    $bestInf = $null
    $bestModel = $null
    $bestRank = 0
    $bestPathScore = -1
    foreach ($dir in $dirs) {
        foreach ($inf in @(Get-ChildItem -LiteralPath $dir.FullName -Filter *.inf -Recurse -File -ErrorAction SilentlyContinue)) {
            $text = ''
            try { $text = Read-AllText $inf.FullName } catch { continue }
            if ($text -notmatch 'C5235' -and $text -notmatch 'Generic Plus PS3') { continue }
            $models = @(Get-InfDriverModels -Text $text -Architecture $arch)
            $choice = Select-BestDriverName -Names $models
            $rank = Get-DriverRank $choice
            $pathScore = Get-InfArchitectureScore $inf.FullName
            $better = $false
            if ($rank -gt $bestRank) { $better = $true }
            elseif ($rank -eq $bestRank -and $rank -gt 0 -and $pathScore -gt $bestPathScore) { $better = $true }
            if ($better) {
                $bestRank = $rank
                $bestPathScore = $pathScore
                $bestInf = $inf.FullName
                $bestModel = $choice
            }
        }
    }
    if ($bestInf) {
        Write-Remax ("Driver store has " + $bestModel + " in " + $bestInf)
        Install-DriverFromInf -InfPath $bestInf -Model $bestModel
    } else {
        Write-Remax "Driver store has no C5235/5240 PS or Generic Plus PS3 INF."
    }
}

function Show-MissingDriverHelp {
    param([string[]]$Installed)
    Write-RemaxLine ("The driver " + $script:ExactDriverName + " is not installed.")
    Write-RemaxLine "Installed printer drivers:"
    if (@($Installed).Count -eq 0) {
        Write-RemaxLine "  (none)"
    } else {
        foreach ($name in @($Installed)) { Write-RemaxLine ("  " + $name) }
    }
    Write-RemaxLine @"

Install Canon PS3 Printer Driver Ver. $script:DriverPackageVersion (x64).
The recorded package is PS_Driver_V3000_32_64_EN_05.exe. Setup.exe in the
x64 folder has file version $script:DriverFileVersion. The driver name after
install is $script:ExactDriverName.
Canon publishes that package on the imageRUNNER ADVANCE C5235 support page.
The download is a click-through, so this script has no built-in URL.
Canon Driver Information Assist Service is not required. If the package
installs it, that is fine. This script does not start or install that service.
Do not use the UFR II or PCL driver for this queue.
The Mac PPD CNMCIRAC5235S2.ppd.gz is not a Windows driver package.
A different Canon PS name can still create the queue, and the report marks
DRIVER as MANUAL until the name is exactly $script:ExactDriverName.

To install from a package you host, set REMAX_CANON_PKG_URL to an https
URL ending in .zip, .cab, or .inf (a zip of the extracted x64 Driver folder).
A Canon setup .exe is not launched, because that opens a GUI. If 7-Zip is
installed, an .exe URL is unpacked and the x64 INF inside is added with pnputil.

  `$env:REMAX_CANON_PKG_URL = 'https://your-host.example/Canon-PS3-v30.zip'
  `$env:REMAX_PRINT_USER = 'tsiogase'
  irm $script:RawUrl | iex
"@
}

function Write-AssistServiceNote {
    $found = $null
    try {
        foreach ($svc in @(Get-Service -ErrorAction SilentlyContinue)) {
            $display = [string]$svc.DisplayName
            $name = [string]$svc.Name
            if ($display -match 'Driver Information Assist' -or $name -match 'Driver Information Assist') {
                $found = $display
                if (-not $found) { $found = $name }
                break
            }
        }
    } catch { }
    if ($found) {
        Write-Remax ("Canon Driver Information Assist Service is present (" + $found + "). The queue does not require it.")
    } else {
        Write-Remax "Canon Driver Information Assist Service is not installed. The queue does not require it."
    }
}

function Get-PortMonitorKey {
    param([string]$Name)
    return (Join-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\Standard TCP/IP Port\Ports' $Name)
}

function Read-PortRegistry {
    param([string]$Name)
    $path = Get-PortMonitorKey $Name
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $item = Get-ItemProperty -LiteralPath $path
    $names = @($item.PSObject.Properties.Name)
    $protocol = $null
    $queue = $null
    $byte = $null
    $snmp = $null
    if ($names -contains 'Protocol') { $protocol = [int]$item.Protocol }
    if ($names -contains 'Queue') { $queue = [string]$item.Queue }
    if ($names -contains 'Byte Count') { $byte = [int]$item.'Byte Count' }
    if ($names -contains 'SNMP Enabled') { $snmp = [int]$item.'SNMP Enabled' }
    return @{
        Protocol  = $protocol
        Queue     = $queue
        ByteCount = $byte
        Snmp      = $snmp
        Present   = $true
    }
}

function Test-RecordedPortValues {
    param($Protocol, $Queue, $ByteCount, $Snmp, [string]$ExpectedQueue, [bool]$ExpectByte)
    if ($null -eq $Protocol -or [int]$Protocol -ne 2) { return $false }
    if ([string]$Queue -ne $ExpectedQueue) { return $false }
    $wantByte = 0
    if ($ExpectByte) { $wantByte = 1 }
    if ($null -eq $ByteCount -or [int]$ByteCount -ne $wantByte) { return $false }
    if ($null -eq $Snmp -or [int]$Snmp -ne 0) { return $false }
    return $true
}

function Set-PortRegistry {
    param([string]$Name, $Target)
    $path = Get-PortMonitorKey $Name
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Remax ("Standard TCP/IP port registry key is not present yet: " + $path)
        return $false
    }
    $byte = 0
    if ($Target.ByteCount) { $byte = 1 }
    New-ItemProperty -LiteralPath $path -Name 'Protocol' -PropertyType DWord -Value 2 -Force | Out-Null
    New-ItemProperty -LiteralPath $path -Name 'Queue' -PropertyType String -Value $Target.Queue -Force | Out-Null
    New-ItemProperty -LiteralPath $path -Name 'Byte Count' -PropertyType DWord -Value $byte -Force | Out-Null
    New-ItemProperty -LiteralPath $path -Name 'SNMP Enabled' -PropertyType DWord -Value 0 -Force | Out-Null
    return $true
}

function Get-PortSnapshot {
    param([string]$Name)
    $safe = $Name.Replace("'", "''")
    $port = Get-CimInstance -ClassName Win32_TCPIPPrinterPort -Filter ("Name='" + $safe + "'")
    $registry = $null
    try { $registry = Read-PortRegistry $Name } catch { $registry = $null }
    $cmdlet = $null
    try { $cmdlet = Get-PrinterPort -Name $Name -ErrorAction Stop } catch { $cmdlet = $null }
    if (-not $port -and -not $registry -and -not $cmdlet) { return $null }
    $hostName = ''
    $queue = ''
    $protocol = 0
    $portNumber = 0
    $byteCount = $false
    $snmp = $false
    $snmpKnown = $false
    if ($port) {
        $hostName = [string]$port.HostAddress
        $queue = [string]$port.Queue
        $protocol = [int]$port.Protocol
        $portNumber = [int]$port.PortNumber
        $byteCount = [bool]$port.ByteCount
        if ($port.PSObject.Properties.Name -contains 'SNMPEnabled') {
            $snmp = [bool]$port.SNMPEnabled
            $snmpKnown = $true
        }
    }
    if ($cmdlet) {
        if (-not $hostName -and $cmdlet.PrinterHostAddress) { $hostName = [string]$cmdlet.PrinterHostAddress }
        if ($cmdlet.PSObject.Properties.Name -contains 'SNMPEnabled') {
            $snmp = [bool]$cmdlet.SNMPEnabled
            $snmpKnown = $true
        }
    }
    if ($registry) {
        if ($null -ne $registry.Queue -and $registry.Queue -ne '') { $queue = [string]$registry.Queue }
        if ($null -ne $registry.Protocol) { $protocol = [int]$registry.Protocol }
        if ($null -ne $registry.ByteCount) { $byteCount = ([int]$registry.ByteCount -ne 0) }
        if ($null -ne $registry.Snmp) {
            $snmp = ([int]$registry.Snmp -ne 0)
            $snmpKnown = $true
        }
    }
    return @{
        Name        = $Name
        Host        = $hostName
        Queue       = $queue
        Protocol    = $protocol
        PortNumber  = $portNumber
        ByteCount   = $byteCount
        SnmpEnabled = $snmp
        SnmpKnown   = $snmpKnown
        Cim         = $port
        Registry    = $registry
        Cmdlet      = $cmdlet
    }
}

function Test-PortMatches {
    param($Snapshot, $Target)
    if (-not $Snapshot) { return $false }
    if ($Snapshot.Name -and $Target.PortName -and $Snapshot.Name -ne $Target.PortName -and $Snapshot.Name -ne $script:PortName) { return $false }
    if ($Snapshot.Host -ne $Target.Host) { return $false }
    if ($Snapshot.Queue -ne $Target.Queue) { return $false }
    if ([int]$Snapshot.Protocol -ne 2) { return $false }
    if ($Snapshot.PortNumber -and [int]$Snapshot.PortNumber -ne 515) { return $false }
    if ([bool]$Snapshot.ByteCount -ne [bool]$Target.ByteCount) { return $false }
    if (-not $Snapshot.SnmpKnown) { return $false }
    if ([bool]$Snapshot.SnmpEnabled) { return $false }
    if ($Snapshot.Registry) {
        $regOk = Test-RecordedPortValues -Protocol $Snapshot.Registry.Protocol -Queue $Snapshot.Registry.Queue -ByteCount $Snapshot.Registry.ByteCount -Snmp $Snapshot.Registry.Snmp -ExpectedQueue $Target.Queue -ExpectByte ([bool]$Target.ByteCount)
        if (-not $regOk) { return $false }
    }
    return $true
}

function Format-PortDetail {
    param($Snapshot, $Target)
    $byte = 'off'
    if ($Target.ByteCount) { $byte = 'on' }
    $snmp = 'off'
    if ($Snapshot -and $Snapshot.SnmpEnabled) { $snmp = 'on' }
    $name = $script:PortName
    if ($Snapshot -and $Snapshot.Name) { $name = [string]$Snapshot.Name }
    $detail = "Standard TCP/IP port " + $name + ", protocol LPR, queue " + $Target.Queue + ", byte counting " + $byte + ", SNMP " + $snmp
    if ($Snapshot -and $Snapshot.Registry) {
        $detail = $detail + " (registry Protocol=" + $Snapshot.Registry.Protocol + ", Queue=" + $Snapshot.Registry.Queue + ", Byte Count=" + $Snapshot.Registry.ByteCount + ", SNMP Enabled=" + $Snapshot.Registry.Snmp + ")"
    } elseif ($Snapshot) {
        $detail = $detail + " (port registry key was not readable)"
    }
    return $detail
}

function Set-PortFields {
    param($Snapshot, $Target)
    $port = $Snapshot.Cim
    if ($port) {
        $port.HostAddress = $Target.Host
        $port.Queue = $Target.Queue
        $port.Protocol = [uint32]2
        $port.PortNumber = [uint32]515
        $port.ByteCount = [bool]$Target.ByteCount
        if ($port.PSObject.Properties.Name -contains 'SNMPEnabled') {
            $port.SNMPEnabled = $false
        }
        Set-CimInstance -InputObject $port | Out-Null
    }
    $name = $script:PortName
    if ($Snapshot.Name) { $name = [string]$Snapshot.Name }
    [void](Set-PortRegistry -Name $name -Target $Target)
}

function Add-LprPort {
    param($Target)
    $created = $false
    try {
        if ($Target.ByteCount) {
            Add-PrinterPort -Name $script:PortName -LprHostAddress $Target.Host -LprQueueName $Target.Queue -LprByteCounting
        } else {
            Add-PrinterPort -Name $script:PortName -LprHostAddress $Target.Host -LprQueueName $Target.Queue
        }
        $created = $true
        Write-Remax ("Created Standard TCP/IP LPR port " + $script:PortName)
    } catch {
        Write-Remax ("Add-PrinterPort failed: " + $_.Exception.Message)
    }
    if ($created) { return }
    $vbs = $null
    $root = Join-Path $env:windir 'System32\Printing_Admin_Scripts'
    if (Test-Path -LiteralPath $root) {
        $found = @(Get-ChildItem -LiteralPath $root -Filter prnport.vbs -Recurse -File -ErrorAction SilentlyContinue)
        if ($found.Count -gt 0) { $vbs = $found[0].FullName }
    }
    if (-not $vbs) { throw "Could not create LPR port $script:PortName and prnport.vbs was not found." }
    Write-Remax ("Creating the port with " + $vbs)
    $prnArgs = @(
        '//nologo', $vbs, '-a', '-r', $script:PortName,
        '-h', $Target.Host, '-o', 'lpr', '-q', $Target.Queue, '-n', '515'
    )
    & cscript.exe @prnArgs
    if ($LASTEXITCODE -ne 0) {
        throw ("prnport.vbs failed with exit " + $LASTEXITCODE)
    }
}

function Ensure-LprPort {
    param($Target)
    Import-PrintModule
    $snapshot = $null
    try {
        $snapshot = Get-PortSnapshot $script:PortName
    } catch {
        throw ("Could not read Win32_TCPIPPrinterPort: " + $_.Exception.Message)
    }
    if (-not $snapshot) {
        Add-LprPort $Target
        $snapshot = Get-PortSnapshot $script:PortName
    }
    if (-not $snapshot) {
        throw "Port $script:PortName was not created as a Standard TCP/IP port."
    }
    if (-not (Test-PortMatches $snapshot $Target)) {
        Write-Remax "Updating LPR host, queue, protocol 2, port 515, byte counting, and SNMP off on the existing port."
        Set-PortFields $snapshot $Target
        $snapshot = Get-PortSnapshot $script:PortName
    }
    if (-not (Test-PortMatches $snapshot $Target)) {
        $snmp = ''
        if ($snapshot) { $snmp = [string]$snapshot.SnmpEnabled }
        throw ("Port " + $script:PortName + " is still not LPR to " + $Target.Uri + " with SNMP off. Host=" + $snapshot.Host + " Queue=" + $snapshot.Queue + " Protocol=" + $snapshot.Protocol + " PortNumber=" + $snapshot.PortNumber + " SNMP=" + $snmp)
    }
    return $snapshot
}

function Remove-LegacyPortIfUnused {
    if ($script:LegacyPortName -eq $script:PortName) { return }
    $busy = $false
    try {
        foreach ($printer in @(Get-Printer -ErrorAction SilentlyContinue)) {
            if ([string]$printer.PortName -eq $script:LegacyPortName) { $busy = $true }
        }
    } catch { }
    if ($busy) {
        Write-Remax ("Legacy port " + $script:LegacyPortName + " is still used by another queue. Leaving it.")
        return
    }
    $exists = $null
    try { $exists = Get-PortSnapshot $script:LegacyPortName } catch { $exists = $null }
    if (-not $exists) { return }
    try {
        Remove-PrinterPort -Name $script:LegacyPortName
        Write-Remax ("Removed legacy port " + $script:LegacyPortName)
    } catch {
        Write-Remax ("Could not remove legacy port " + $script:LegacyPortName + ": " + $_.Exception.Message)
    }
}

function Get-DefaultPrinterName {
    try {
        $printer = Get-CimInstance -ClassName Win32_Printer -Filter 'Default=True'
        if ($printer) { return [string]$printer.Name }
    } catch { }
    return ''
}

function Set-DefaultPrinterByName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $safe = $Name.Replace("'", "''")
    try {
        $printer = Get-CimInstance -ClassName Win32_Printer -Filter ("Name='" + $safe + "'")
        if (-not $printer) { return $false }
        $result = Invoke-CimMethod -InputObject $printer -MethodName SetDefaultPrinter
        if ($result -and $null -ne $result.ReturnValue) {
            return ([int]$result.ReturnValue -eq 0)
        }
        return $true
    } catch {
        Write-Remax ("Could not set default printer " + $Name + ": " + $_.Exception.Message)
        return $false
    }
}

function Get-FallbackDefaultPrinter {
    $names = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($printer in @(Get-Printer -ErrorAction SilentlyContinue)) {
            $name = [string]$printer.Name
            if ($name -and $name -ne $script:PrinterName) { [void]$names.Add($name) }
        }
    } catch { }
    foreach ($prefer in @('Microsoft Print to PDF', 'Microsoft XPS Document Writer')) {
        foreach ($name in @($names.ToArray())) {
            if ($name -eq $prefer) { return $name }
        }
    }
    if ($names.Count -gt 0) { return $names[0] }
    return ''
}

function Get-PrinterOrNull {
    param([string]$Name)
    Import-PrintModule
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        return Get-Printer -Name $Name
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Remove-StaleQueue {
    $stale = Get-PrinterOrNull $script:StaleName
    if (-not $stale) {
        Write-Remax ("No stale queue " + $script:StaleName)
        return $true
    }
    Write-Remax ("Removing stale queue " + $script:StaleName)
    try {
        Remove-Printer -Name $script:StaleName
    } catch {
        Write-Remax ("Could not remove " + $script:StaleName + ": " + $_.Exception.Message)
        return $false
    }
    $still = Get-PrinterOrNull $script:StaleName
    return (-not $still)
}

function Ensure-PrinterQueue {
    param(
        [string]$DriverName,
        $Target
    )
    $previousDefault = Get-DefaultPrinterName
    $existing = Get-PrinterOrNull $script:PrinterName
    if (-not $existing) {
        Write-Remax ("Creating queue " + $script:PrinterName + " on port " + $script:PortName)
        Add-Printer -Name $script:PrinterName -DriverName $DriverName -PortName $script:PortName
    } else {
        $oldPort = [string]$existing.PortName
        if ($oldPort -and $oldPort -ne $script:PortName) {
            Write-Remax ("Moving queue " + $script:PrinterName + " from port " + $oldPort + " to " + $script:PortName)
        } else {
            Write-Remax ("Updating existing queue " + $script:PrinterName)
        }
        Set-Printer -Name $script:PrinterName -DriverName $DriverName -PortName $script:PortName
    }
    try {
        Set-Printer -Name $script:PrinterName -Shared $false -Comment 'RE/MAX Secure Printer' -Location 'RE/MAX Escarpment'
    } catch {
        Write-Remax ("Sharing, comment, or location was not set: " + $_.Exception.Message)
        try { Set-Printer -Name $script:PrinterName -Shared $false } catch {
            Write-Remax ("Could not clear sharing: " + $_.Exception.Message)
        }
    }
    $currentDefault = Get-DefaultPrinterName
    if ($currentDefault -eq $script:PrinterName) {
        $restore = ''
        if ($previousDefault -and $previousDefault -ne $script:PrinterName) {
            $restore = $previousDefault
        } else {
            $restore = Get-FallbackDefaultPrinter
        }
        if ($restore) {
            Write-Remax ("Restoring default printer " + $restore + " so " + $script:PrinterName + " is not the default.")
            [void](Set-DefaultPrinterByName $restore)
        } else {
            Write-Remax ($script:PrinterName + " is the only printer, so Windows keeps it as the default.")
        }
    }
    try {
        $printer = Get-CimInstance -ClassName Win32_Printer -Filter ("Name='" + $script:PrinterName.Replace("'", "''") + "'")
        if ($printer) {
            Invoke-CimMethod -InputObject $printer -MethodName Resume | Out-Null
        }
    } catch {
        Write-Remax ("Resume printer skipped: " + $_.Exception.Message)
    }
    Remove-LegacyPortIfUnused
}

function Set-OneSided {
    Set-PrintConfiguration -PrinterName $script:PrinterName -DuplexingMode OneSided
    $config = Get-PrintConfiguration -PrinterName $script:PrinterName
    $mode = ''
    if ($config -and $config.DuplexingMode) { $mode = [string]$config.DuplexingMode }
    return $mode
}

function Get-PrintServerQueue {
    param([switch]$WriteAccess)
    Add-Type -AssemblyName System.Printing | Out-Null
    if ($WriteAccess) {
        $server = New-Object System.Printing.LocalPrintServer ([System.Printing.PrintSystemDesiredAccess]::AdministrateServer)
        return New-Object System.Printing.PrintQueue(
            $server,
            $script:PrinterName,
            [System.Printing.PrintSystemDesiredAccess]::AdministratePrinter
        )
    }
    $serverRead = New-Object System.Printing.LocalPrintServer
    return $serverRead.GetPrintQueue($script:PrinterName)
}

function Get-QueueXml {
    param(
        [switch]$Capabilities,
        [switch]$WriteAccess
    )
    $queue = Get-PrintServerQueue -WriteAccess:$WriteAccess
    try {
        if ($Capabilities) {
            return (Read-StreamText $queue.GetPrintCapabilities().XmlStream)
        }
        return (Read-StreamText $queue.DefaultPrintTicket.GetXmlStream())
    } finally {
        $queue.Dispose()
    }
}

function Set-QueueTicketXml {
    param([string]$Xml)
    $queue = Get-PrintServerQueue -WriteAccess
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Xml)
        $stream = New-Object System.IO.MemoryStream(,$bytes)
        try {
            $ticket = New-Object System.Printing.PrintTicket($stream)
            $queue.DefaultPrintTicket = $ticket
            $queue.Commit()
        } finally {
            $stream.Dispose()
        }
    } finally {
        $queue.Dispose()
    }
}

function Get-HardwareChoice {
    param(
        [string]$CapabilitiesXml,
        [string]$Kind
    )
    if ($Kind -eq 'cassette') {
        $byToken = Find-PrintFeatureOption -CapabilitiesXml $CapabilitiesXml -OptionLocalName 'OptCas2' -FeatureDisplay 'Paper Source Options' -OptionDisplay 'Cassette Feeding Unit'
        if ($byToken) { return $byToken }
        return Find-PrintFeatureOption -CapabilitiesXml $CapabilitiesXml -OptionLocalName '' -FeatureDisplay 'Paper Source Options' -OptionDisplay 'Cassette Feeding Unit'
    }
    $byToken = Find-PrintFeatureOption -CapabilitiesXml $CapabilitiesXml -OptionLocalName 'IFINE1' -FeatureDisplay 'Output Options' -OptionDisplay 'Inner Finisher E1'
    if ($byToken) { return $byToken }
    return Find-PrintFeatureOption -CapabilitiesXml $CapabilitiesXml -OptionLocalName '' -FeatureDisplay 'Output Options' -OptionDisplay 'Inner Finisher E1'
}

function ConvertTo-CanonLabel {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $text = $Name.Replace('&', '')
    $text = $text -replace '\(&[A-Za-z0-9]\)', ''
    $text = $text -replace '\([A-Za-z0-9]\)', ''
    $text = $text.Trim()
    $text = $text.TrimEnd('.').Trim()
    $text = $text.TrimEnd(':').Trim()
    return $text
}

function Test-CanonLabelEquals {
    param([string]$Left, [string]$Right)
    $a = (ConvertTo-CanonLabel $Left).ToLowerInvariant()
    $b = (ConvertTo-CanonLabel $Right).ToLowerInvariant()
    if (-not $a -or -not $b) { return $false }
    return ($a -eq $b)
}

function Test-LabelInSet {
    param([string]$Label, [string[]]$Set)
    foreach ($item in @($Set)) {
        if (Test-CanonLabelEquals $Label $item) { return $true }
    }
    return $false
}

function Get-CanonElements {
    param($Elements)
    if ($null -eq $Elements) { return }
    if ($Elements -is [System.Collections.IDictionary]) {
        , $Elements
        return
    }
    if ($Elements -is [System.Collections.IEnumerable] -and -not ($Elements -is [string])) {
        foreach ($item in $Elements) {
            if ($null -ne $item) { , $item }
        }
        return
    }
    , $Elements
}

function Test-ElementOffscreen {
    param($Element)
    if (-not $Element) { return $true }
    if ($Element.ContainsKey('Offscreen') -and $Element['Offscreen']) { return $true }
    return $false
}

function Test-SameRow {
    param($Left, $Right)
    if (-not $Left -or -not $Right) { return $false }
    $aMid = ([double]$Left.Top + [double]$Left.Bottom) / 2.0
    $bMid = ([double]$Right.Top + [double]$Right.Bottom) / 2.0
    $limit = 8.0
    $aH = [double]$Left.Bottom - [double]$Left.Top
    $bH = [double]$Right.Bottom - [double]$Right.Top
    if ($aH -gt $limit) { $limit = $aH }
    if ($bH -gt $limit) { $limit = $bH }
    $allow = ($limit / 2.0) + 4.0
    if ([Math]::Abs($aMid - $bMid) -le $allow) { return $true }
    return $false
}

function Select-LabeledControl {
    param($Elements, [string[]]$Labels, [string]$ControlType)
    foreach ($label in @($Labels)) {
        foreach ($el in @(Get-CanonElements $Elements)) {
            if (-not $el) { continue }
            if (Test-ElementOffscreen $el) { continue }
            if ($ControlType -and $el.ControlType -ne $ControlType) { continue }
            if (Test-CanonLabelEquals $el.Name $label) { return $el }
        }
    }
    return $null
}

function Select-RowControl {
    param($Elements, $Anchor, [string]$ControlType, [string]$LabelEquals, [switch]$ToTheRight)
    if (-not $Anchor) { return $null }
    $best = $null
    $bestDx = [double]::MaxValue
    foreach ($el in @(Get-CanonElements $Elements)) {
        if (-not $el) { continue }
        if (Test-ElementOffscreen $el) { continue }
        if ($ControlType -and $el.ControlType -ne $ControlType) { continue }
        if ($LabelEquals -and -not (Test-CanonLabelEquals $el.Name $LabelEquals)) { continue }
        if (-not (Test-SameRow $Anchor $el)) { continue }
        if ($ToTheRight -and ([double]$el.Left -lt ([double]$Anchor.Left + 20))) { continue }
        $dx = [double]$el.Left - [double]$Anchor.Right
        if ($dx -lt 0) { $dx = 0 }
        if ($dx -lt $bestDx) {
            $bestDx = $dx
            $best = $el
        }
    }
    return $best
}

function Find-CanonComboByLabel {
    param($Elements, [string[]]$Labels)
    $anchors = @()
    foreach ($el in @(Get-CanonElements $Elements)) {
        if (-not $el) { continue }
        if (Test-ElementOffscreen $el) { continue }
        $match = $false
        foreach ($label in @($Labels)) {
            if (Test-CanonLabelEquals $el.Name $label) { $match = $true }
        }
        if (-not $match) { continue }
        if ($el.ControlType -eq 'ComboBox') { return $el }
        $anchors += $el
    }
    foreach ($anchor in @($anchors)) {
        $combo = Select-RowControl -Elements $Elements -Anchor $anchor -ControlType 'ComboBox' -ToTheRight
        if ($combo) { return $combo }
    }
    return $null
}

function Find-CanonEditByLabel {
    param($Elements, [string[]]$Labels)
    $anchors = @()
    foreach ($el in @(Get-CanonElements $Elements)) {
        if (-not $el) { continue }
        if (Test-ElementOffscreen $el) { continue }
        $match = $false
        foreach ($label in @($Labels)) {
            if (Test-CanonLabelEquals $el.Name $label) { $match = $true }
        }
        if (-not $match) { continue }
        if ($el.ControlType -eq 'Edit') { return $el }
        $anchors += $el
    }
    foreach ($anchor in @($anchors)) {
        $edit = Select-RowControl -Elements $Elements -Anchor $anchor -ControlType 'Edit' -ToTheRight
        if ($edit) { return $edit }
    }
    return $null
}

function Select-ControlBelow {
    param($Elements, $Anchor, [string]$ControlType)
    if (-not $Anchor) { return $null }
    $best = $null
    $bestDy = [double]::MaxValue
    $anchorLeft = [double]$Anchor.Left
    $anchorBottom = [double]$Anchor.Bottom
    foreach ($el in @(Get-CanonElements $Elements)) {
        if (-not $el) { continue }
        if (Test-ElementOffscreen $el) { continue }
        if ($ControlType -and $el.ControlType -ne $ControlType) { continue }
        if ([double]$el.Top -lt ([double]$Anchor.Top + 8)) { continue }
        $elLeft = [double]$el.Left
        if ($elLeft -lt ($anchorLeft - 10)) { continue }
        if ($elLeft -gt ($anchorLeft + 220)) { continue }
        $dy = [double]$el.Top - $anchorBottom
        if ($dy -lt -4) { continue }
        if ($dy -lt $bestDy) {
            $bestDy = $dy
            $best = $el
        }
    }
    return $best
}

function Find-CanonDeviceTargets {
    param($Elements)
    $paper = Find-CanonComboByLabel -Elements $Elements -Labels @('Paper Source Options')
    $output = Find-CanonComboByLabel -Elements $Elements -Labels @('Output Options')
    $user = Select-LabeledControl -Elements $Elements -Labels @('Set User Information') -ControlType 'CheckBox'
    $settings = $null
    if ($user) {
        $settings = Select-RowControl -Elements $Elements -Anchor $user -ControlType 'Button' -LabelEquals 'Settings' -ToTheRight
    }
    $profile = Find-CanonComboByLabel -Elements $Elements -Labels @('Config. Profile', 'Configuration Profile', 'Config Profile')
    return @{
        PaperCombo   = $paper
        OutputCombo  = $output
        UserInfo     = $user
        UserSettings = $settings
        Profile      = $profile
    }
}

function Find-CanonDefaultValueTargets {
    param($Elements)
    $userRadio = $null
    $logonRadio = $null
    foreach ($el in @(Get-CanonElements $Elements)) {
        if (-not $el) { continue }
        if (Test-ElementOffscreen $el) { continue }
        if ($el.ControlType -ne 'RadioButton') { continue }
        if (Test-CanonLabelEquals $el.Name 'User Name') { $userRadio = $el }
        if (Test-CanonLabelEquals $el.Name 'Logon Name') { $logonRadio = $el }
    }
    $nameEdit = Select-ControlBelow -Elements $Elements -Anchor $userRadio -ControlType 'Edit'
    $always = Select-LabeledControl -Elements $Elements -Labels @('Always Confirm User Information When Performing Secured Print') -ControlType 'CheckBox'
    $confirm = Select-LabeledControl -Elements $Elements -Labels @('Confirm User Name When Printing') -ControlType 'CheckBox'
    $pinEdit = Find-CanonEditByLabel -Elements $Elements -Labels @('PIN', 'PIN for Secured Print', 'Password for Secured Print')
    if ($pinEdit -and $nameEdit -and ($pinEdit.Top -eq $nameEdit.Top) -and ($pinEdit.Left -eq $nameEdit.Left)) {
        $pinEdit = $null
    }
    return @{
        UserNameRadio    = $userRadio
        LogonRadio       = $logonRadio
        NameEdit         = $nameEdit
        AlwaysConfirm    = $always
        ConfirmPrinting  = $confirm
        PinEdit          = $pinEdit
    }
}

function Test-DefaultValueTitle {
    param([string]$Title)
    if ([string]::IsNullOrWhiteSpace($Title)) { return $false }
    return [bool]($Title -like '*Default Value Settings*')
}

function Resolve-CanonChoiceLabel {
    param([string[]]$Labels, [string[]]$Accept)
    foreach ($want in @($Accept)) {
        if ([string]::IsNullOrWhiteSpace($want)) { continue }
        foreach ($label in @($Labels)) {
            if (Test-CanonLabelEquals $label $want) { return $label }
        }
    }
    return $null
}

function Resolve-FinisherLabel {
    param([string[]]$Labels)
    $exact = Resolve-CanonChoiceLabel -Labels $Labels -Accept @('Inner Finisher E1')
    if ($exact) { return $exact }
    foreach ($label in @($Labels)) {
        $norm = (ConvertTo-CanonLabel $label).ToLowerInvariant()
        if ($norm.Contains('inner finisher e1')) { return $label }
    }
    return $null
}

function Resolve-PaperSourceLabel {
    param([string[]]$Labels)
    $exact = Resolve-CanonChoiceLabel -Labels $Labels -Accept @('Cassette Feeding Unit')
    if ($exact) { return $exact }
    foreach ($label in @($Labels)) {
        $norm = (ConvertTo-CanonLabel $label).ToLowerInvariant()
        if ($norm.Contains('cassette feeding unit')) { return $label }
    }
    return $null
}

function Resolve-ProfileLabel {
    param([string[]]$Labels)
    foreach ($label in @($Labels)) {
        $norm = ConvertTo-CanonLabel $label
        if ($norm -match 'C5235' -and $norm -match '5240') { return $label }
    }
    return $null
}

function Merge-DeviceLine {
    param(
        [string]$TicketState,
        [string]$TicketDetail,
        [string]$PropertyState,
        [string]$PropertyDetail,
        [string]$UiState,
        [string]$UiDetail,
        [bool]$Attempted
    )
    if ($UiState -eq 'PASS') {
        return @{ State = 'PASS'; Detail = $UiDetail }
    }
    if ($UiState -eq 'FAIL') {
        return @{ State = 'FAIL'; Detail = $UiDetail }
    }
    if ($PropertyState -eq 'PASS') {
        return @{ State = 'PASS'; Detail = $PropertyDetail }
    }
    if ($TicketState -eq 'PASS' -and -not $Attempted) {
        return @{ State = 'PASS'; Detail = $TicketDetail }
    }
    if ($Attempted -and $UiState) {
        $detail = $UiDetail
        if (-not $detail) { $detail = $PropertyDetail }
        if (-not $detail) { $detail = $TicketDetail }
        return @{ State = $UiState; Detail = $detail }
    }
    if ($TicketState -eq 'PASS') {
        return @{ State = 'PASS'; Detail = $TicketDetail }
    }
    $detail = $PropertyDetail
    if (-not $detail) { $detail = $TicketDetail }
    $state = 'MANUAL'
    if ($TicketState) { $state = $TicketState }
    return @{ State = $state; Detail = $detail }
}

function New-DeviceUiResult {
    return @{
        Attempted        = $false
        SkipReason       = ''
        PaperState       = 'MANUAL'
        PaperDetail      = ''
        OutputState      = 'MANUAL'
        OutputDetail     = ''
        UserInfoState    = 'MANUAL'
        UserInfoDetail   = ''
        UserNameState    = 'MANUAL'
        UserNameDetail   = ''
        ProfileDetail    = ''
    }
}

function New-CanonRead {
    return @{
        Opened          = $false
        Error           = ''
        PaperSeen       = $false
        PaperValue      = ''
        OutputSeen      = $false
        OutputValue     = ''
        ProfileValue    = ''
        UserInfoSeen    = $false
        UserInfoOn      = $false
        UserDialog      = $false
        UserNameRadio   = $false
        UserNameValue   = ''
        AlwaysConfirm   = $false
        ConfirmPrinting = $false
        PinBlank        = $true
        PinSeen         = $false
    }
}

function Read-DefaultValueFromElements {
    param($Elements, [string]$PrintUser)
    $targets = Find-CanonDefaultValueTargets $Elements
    $radioOn = $false
    if ($targets.UserNameRadio -and (($targets.UserNameRadio.Toggle -eq 'On') -or $targets.UserNameRadio.Selected)) {
        $radioOn = $true
    }
    $name = ''
    $nameSeen = $false
    if ($targets.NameEdit) {
        $nameSeen = $true
        $name = [string]$targets.NameEdit.Value
    }
    $alwaysSeen = [bool]$targets.AlwaysConfirm
    $always = $false
    if ($targets.AlwaysConfirm -and $targets.AlwaysConfirm.Toggle -eq 'On') { $always = $true }
    $confirmSeen = [bool]$targets.ConfirmPrinting
    $confirm = $false
    if ($targets.ConfirmPrinting -and $targets.ConfirmPrinting.Toggle -eq 'On') { $confirm = $true }
    $pinSeen = [bool]$targets.PinEdit
    $pin = ''
    if ($targets.PinEdit) { $pin = [string]$targets.PinEdit.Value }
    $pinBlank = $true
    if ($pinSeen -and -not [string]::IsNullOrEmpty($pin)) { $pinBlank = $false }
    $nameOk = $false
    if ($PrintUser) { $nameOk = (Test-CanonLabelEquals $name $PrintUser) }
    elseif (-not [string]::IsNullOrWhiteSpace($name)) { $nameOk = $true }
    $ok = $radioOn -and $nameSeen -and $nameOk -and $alwaysSeen -and $always -and $confirmSeen -and (-not $confirm) -and $pinBlank
    return @{
        Ok              = [bool]$ok
        Radio           = [bool]$radioOn
        NameSeen        = [bool]$nameSeen
        Name            = [string]$name
        AlwaysSeen      = [bool]$alwaysSeen
        Always          = [bool]$always
        ConfirmSeen     = [bool]$confirmSeen
        ConfirmPrinting = [bool]$confirm
        PinSeen         = [bool]$pinSeen
        PinBlank        = [bool]$pinBlank
        Pin             = [string]$pin
    }
}

function Get-DeviceUiSkipReason {
    if ($env:REMAX_DEVICE_UI -eq '0') { return 'REMAX_DEVICE_UI=0' }
    $interactive = $false
    try { $interactive = [bool][Environment]::UserInteractive } catch { $interactive = $false }
    if (-not $interactive) { return 'no interactive desktop' }
    return ''
}

function Initialize-RemaxUi {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    if (-not ('RemaxWin32' -as [type])) {
        $win32 = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class RemaxWin32 {
    [DllImport("user32.dll", EntryPoint="SendMessageW", CharSet=CharSet.Unicode)]
    public static extern IntPtr SendMessageText(IntPtr hWnd, uint msg, IntPtr wParam, string text);
    [DllImport("user32.dll", EntryPoint="SendMessageW", CharSet=CharSet.Unicode)]
    public static extern int SendMessageGetText(IntPtr hWnd, uint msg, IntPtr wParam, StringBuilder text);
    [DllImport("user32.dll", EntryPoint="SendMessageW")]
    public static extern IntPtr SendMessagePtr(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", EntryPoint="PostMessageW")]
    public static extern bool PostMessagePtr(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
    public static string WindowText(IntPtr hwnd) {
        StringBuilder sb = new StringBuilder(512);
        SendMessageGetText(hwnd, 0x000D, new IntPtr(512), sb);
        return sb.ToString();
    }
    public static void SetWindowText(IntPtr hwnd, string text) {
        SendMessageText(hwnd, 0x000C, IntPtr.Zero, text);
    }
    public static int ButtonCheck(IntPtr hwnd) {
        return (int)SendMessagePtr(hwnd, 0x00F0, IntPtr.Zero, IntPtr.Zero);
    }
    public static bool ClickHwnd(IntPtr hwnd) {
        return PostMessagePtr(hwnd, 0x00F5, IntPtr.Zero, IntPtr.Zero);
    }
    public static void ClickScreen(int x, int y) {
        SetCursorPos(x, y);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
    }
}
'@
        Add-Type -TypeDefinition $win32 -Language CSharp
    }
    if (-not ('RemaxUia' -as [type])) {
        $uia = @'
using System;
public static class RemaxUia {
    public static string LastError = "";
    public static void BeginInvoke(System.Windows.Automation.AutomationElement element) {
        LastError = "";
        System.Threading.Thread thread = new System.Threading.Thread(
            delegate () {
                try {
                    object pattern;
                    bool found = element.TryGetCurrentPattern(System.Windows.Automation.InvokePattern.Pattern, out pattern);
                    if (found) {
                        System.Windows.Automation.InvokePattern invoke = (System.Windows.Automation.InvokePattern)pattern;
                        invoke.Invoke();
                    } else {
                        LastError = "no invoke pattern";
                    }
                } catch (System.Exception ex) {
                    LastError = ex.Message;
                }
            }
        );
        thread.SetApartmentState(System.Threading.ApartmentState.STA);
        thread.IsBackground = true;
        thread.Start();
    }
}
'@
        $refs = @([System.Windows.Automation.AutomationElement].Assembly.Location)
        try {
            Add-Type -TypeDefinition $uia -ReferencedAssemblies $refs -Language CSharp
        } catch {
            Write-Remax ("UI invoke helper was not compiled: " + $_.Exception.Message)
        }
    }
}

function Get-UiaSnapshot {
    param($Element)
    $name = ''
    $ctype = ''
    $off = $false
    $left = 0
    $top = 0
    $right = 0
    $bottom = 0
    $enabled = $true
    $selected = $false
    try { $name = [string]$Element.Current.Name } catch { $name = '' }
    try {
        $program = [string]$Element.Current.ControlType.ProgrammaticName
        if ($program.StartsWith('ControlType.')) {
            $ctype = $program.Substring(12)
        } else {
            $ctype = $program
        }
    } catch { $ctype = '' }
    try { $off = [bool]$Element.Current.IsOffscreen } catch { $off = $false }
    try { $enabled = [bool]$Element.Current.IsEnabled } catch { $enabled = $true }
    try {
        $rect = $Element.Current.BoundingRectangle
        $left = [int]$rect.Left
        $top = [int]$rect.Top
        $right = [int]$rect.Right
        $bottom = [int]$rect.Bottom
    } catch {
        $left = 0
        $top = 0
        $right = 0
        $bottom = 0
    }
    $value = ''
    $toggle = ''
    $pattern = $null
    try {
        if ($Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
            $value = [string]$pattern.Current.Value
        }
    } catch { }
    $pattern = $null
    try {
        if ($Element.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$pattern)) {
            $toggle = [string]$pattern.Current.ToggleState
        }
    } catch { }
    $pattern = $null
    try {
        if ($Element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) {
            $selected = [bool]$pattern.Current.IsSelected
        }
    } catch { }
    if (-not $toggle -and $ctype -eq 'CheckBox') {
        try {
            $hwnd = [IntPtr]$Element.Current.NativeWindowHandle
            if ($hwnd -ne [IntPtr]::Zero) {
                $state = [RemaxWin32]::ButtonCheck($hwnd)
                if ($state -eq 1) { $toggle = 'On' } else { $toggle = 'Off' }
            }
        } catch { }
    }
    if (-not $value -and $ctype -eq 'ComboBox') {
        try {
            $sel = $null
            if ($Element.TryGetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern, [ref]$sel)) {
                foreach ($item in @($sel.Current.GetSelection())) {
                    $value = [string]$item.Current.Name
                    break
                }
            }
        } catch { }
    }
    if (-not $value -and $ctype -eq 'Edit') {
        try {
            $hwnd = [IntPtr]$Element.Current.NativeWindowHandle
            if ($hwnd -ne [IntPtr]::Zero) { $value = [RemaxWin32]::WindowText($hwnd) }
        } catch { }
    }
    return @{
        Name        = $name
        ControlType = $ctype
        Offscreen   = $off
        Left        = $left
        Top         = $top
        Right       = $right
        Bottom      = $bottom
        Enabled     = $enabled
        Value       = $value
        Toggle      = $toggle
        Selected    = $selected
        Element     = $Element
    }
}

function Get-UiaDescendants {
    param($Root)
    $list = New-Object System.Collections.Generic.List[object]
    $all = $Root.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition
    )
    foreach ($item in @($all)) {
        if (-not $item) { continue }
        $list.Add((Get-UiaSnapshot $item))
        if ($list.Count -ge 400) { break }
    }
    return @($list.ToArray())
}

function Write-UiaSummary {
    param($Elements)
    $count = 0
    foreach ($el in @(Get-CanonElements $Elements)) {
        if (-not $el) { continue }
        $count++
        if ($count -gt 70) { break }
        $name = [string]$el.Name
        if ($name.Length -gt 80) { $name = $name.Substring(0, 80) }
        Write-Remax ("UI " + $el.ControlType + " '" + $name + "' value='" + $el.Value + "' toggle=" + $el.Toggle)
    }
}

function Get-ComboDisplay {
    param($Snapshot)
    if (-not $Snapshot) { return '' }
    if ($Snapshot.Value) { return [string]$Snapshot.Value }
    $label = ConvertTo-CanonLabel $Snapshot.Name
    if (-not $label) { return '' }
    $blocked = @(
        'Output Options', 'Paper Source Options', 'Config. Profile', 'Configuration Profile', 'Config Profile',
        'External Puncher', 'PS Output from Application',
        'Name to Set for User Information', 'Name to Set for User Name'
    )
    if (Test-LabelInSet $label $blocked) { return '' }
    return [string]$Snapshot.Name
}

function Test-HandleExcluded {
    param([IntPtr]$Handle, $Exclude)
    foreach ($item in @($Exclude)) {
        if ($null -eq $item) { continue }
        if (([IntPtr]$item) -eq $Handle) { return $true }
    }
    return $false
}

function Wait-UiaTopWindow {
    param(
        [int]$ProcessId,
        [string]$TitleLike,
        $Exclude,
        [int]$TimeoutMs,
        [switch]$SkipProperties
    )
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
        $ProcessId
    )
    while ([DateTime]::UtcNow -lt $deadline) {
        $windows = $null
        try { $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond) } catch { $windows = $null }
        foreach ($window in @($windows)) {
            if (-not $window) { continue }
            $name = ''
            try { $name = [string]$window.Current.Name } catch { $name = '' }
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($SkipProperties -and $name -like '*Properties*') { continue }
            if ($TitleLike -and $name -notlike $TitleLike) { continue }
            $handle = [IntPtr]::Zero
            try { $handle = [IntPtr]$window.Current.NativeWindowHandle } catch { $handle = [IntPtr]::Zero }
            if (Test-HandleExcluded -Handle $handle -Exclude $Exclude) { continue }
            $off = $false
            try { $off = [bool]$window.Current.IsOffscreen } catch { $off = $false }
            if ($off) { continue }
            return $window
        }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Show-CanonWindow {
    param($Window)
    if (-not $Window) { return }
    try {
        $hwnd = [IntPtr]$Window.Current.NativeWindowHandle
        if ($hwnd -ne [IntPtr]::Zero) {
            [void][RemaxWin32]::ShowWindow($hwnd, 9)
            [void][RemaxWin32]::SetForegroundWindow($hwnd)
        }
    } catch { }
}

function Invoke-CanonButton {
    param($Snapshot, [string]$How)
    if (-not $Snapshot) { return $false }
    if (-not $How) { $How = 'post' }
    $element = $Snapshot.Element
    if ($How -eq 'mouse') {
        if ([int]$Snapshot.Right -le [int]$Snapshot.Left) { return $false }
        if ([int]$Snapshot.Bottom -le [int]$Snapshot.Top) { return $false }
        $x = [int](([int]$Snapshot.Left + [int]$Snapshot.Right) / 2)
        $y = [int](([int]$Snapshot.Top + [int]$Snapshot.Bottom) / 2)
        [RemaxWin32]::ClickScreen($x, $y)
        return $true
    }
    if ($How -eq 'invoke') {
        if (-not $element) { return $false }
        if (-not ('RemaxUia' -as [type])) { return $false }
        [RemaxUia]::BeginInvoke($element)
        return $true
    }
    $hwnd = [IntPtr]::Zero
    if ($element) {
        try { $hwnd = [IntPtr]$element.Current.NativeWindowHandle } catch { $hwnd = [IntPtr]::Zero }
    }
    if ($hwnd -ne [IntPtr]::Zero) {
        return [bool][RemaxWin32]::ClickHwnd($hwnd)
    }
    if ($element -and ('RemaxUia' -as [type])) {
        [RemaxUia]::BeginInvoke($element)
        return $true
    }
    return $false
}

function Set-CanonCheck {
    param($Snapshot, [bool]$On)
    if (-not $Snapshot) { return $false }
    $want = 'Off'
    if ($On) { $want = 'On' }
    $current = [string]$Snapshot.Toggle
    if (-not $current -and $Snapshot.Element) {
        try {
            $hwnd = [IntPtr]$Snapshot.Element.Current.NativeWindowHandle
            if ($hwnd -ne [IntPtr]::Zero) {
                $state = [RemaxWin32]::ButtonCheck($hwnd)
                if ($state -eq 1) { $current = 'On' } else { $current = 'Off' }
            }
        } catch { }
    }
    if (-not $current) { return $false }
    if ($current -eq $want) { return $true }
    $clicked = Invoke-CanonButton -Snapshot $Snapshot -How post
    if (-not $clicked) { return $false }
    Start-Sleep -Milliseconds 250
    if ($Snapshot.Element) {
        try {
            $hwnd = [IntPtr]$Snapshot.Element.Current.NativeWindowHandle
            if ($hwnd -ne [IntPtr]::Zero) {
                $state = [RemaxWin32]::ButtonCheck($hwnd)
                $got = 'Off'
                if ($state -eq 1) { $got = 'On' }
                return ($got -eq $want)
            }
        } catch { }
    }
    return $true
}

function Set-CanonEdit {
    param($Snapshot, [string]$Text)
    if (-not $Snapshot -or -not $Snapshot.Element) { return $false }
    $element = $Snapshot.Element
    try {
        $pattern = $null
        if ($element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
            if (-not $pattern.Current.IsReadOnly) {
                $pattern.SetValue($Text)
                Start-Sleep -Milliseconds 150
                $got = [string]$pattern.Current.Value
                if ($got -eq $Text) { return $true }
            }
        }
    } catch {
        Write-Remax ("Edit value pattern failed: " + $_.Exception.Message)
    }
    $hwnd = [IntPtr]::Zero
    try { $hwnd = [IntPtr]$element.Current.NativeWindowHandle } catch { $hwnd = [IntPtr]::Zero }
    if ($hwnd -eq [IntPtr]::Zero) { return $false }
    [RemaxWin32]::SetWindowText($hwnd, $Text)
    Start-Sleep -Milliseconds 150
    $got = [RemaxWin32]::WindowText($hwnd)
    return ($got -eq $Text)
}

function Collapse-CanonCombo {
    param($Snapshot)
    if (-not $Snapshot -or -not $Snapshot.Element) { return }
    try {
        $pattern = $null
        if ($Snapshot.Element.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$pattern)) {
            if ([string]$pattern.Current.ExpandCollapseState -eq 'Expanded') {
                $pattern.Collapse()
            }
        }
    } catch { }
}

function Test-PopupNearCombo {
    param($Combo, $Item)
    if (-not $Combo -or -not $Item) { return $false }
    if ([int]$Item.Right -lt [int]$Combo.Left) { return $false }
    if ([int]$Item.Left -gt [int]$Combo.Right) { return $false }
    if ([int]$Item.Bottom -lt ([int]$Combo.Top - 8)) { return $false }
    return $true
}

function Get-CanonComboChoices {
    param($Snapshot)
    $empty = @{ Labels = @(); Items = @() }
    if (-not $Snapshot -or -not $Snapshot.Element) { return $empty }
    $element = $Snapshot.Element
    try {
        $expand = $null
        if ($element.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$expand)) {
            $expand.Expand()
            Start-Sleep -Milliseconds 250
        }
    } catch {
        Write-Remax ("Combo expand failed: " + $_.Exception.Message)
    }
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::ListItem
    )
    $scoped = New-Object System.Collections.Generic.List[object]
    try {
        $rawScoped = $element.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
        foreach ($item in @($rawScoped)) {
            if ($item) { [void]$scoped.Add($item) }
        }
    } catch { }
    $pool = @()
    $nearOnly = $false
    if ($scoped.Count -gt 0) {
        $pool = @($scoped.ToArray())
    } else {
        $nearOnly = $true
        try {
            $root = [System.Windows.Automation.AutomationElement]::RootElement
            $pid = [int]$element.Current.ProcessId
            $condPid = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
                $pid
            )
            $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $condPid)
            foreach ($window in @($windows)) {
                if (-not $window) { continue }
                $inner = @($window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond))
                foreach ($item in @($inner)) { $pool += $item }
            }
        } catch { }
    }
    $labels = New-Object System.Collections.Generic.List[string]
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($pool)) {
        if (-not $item) { continue }
        $name = ''
        try { $name = [string]$item.Current.Name } catch { continue }
        if (-not $name) { continue }
        $left = 0
        $top = 0
        $right = 0
        $bottom = 0
        try {
            $rect = $item.Current.BoundingRectangle
            $left = [int]$rect.Left
            $top = [int]$rect.Top
            $right = [int]$rect.Right
            $bottom = [int]$rect.Bottom
        } catch { }
        $row = @{ Name = $name; Element = $item; Left = $left; Top = $top; Right = $right; Bottom = $bottom }
        if ($nearOnly -and -not (Test-PopupNearCombo -Combo $Snapshot -Item $row)) { continue }
        [void]$labels.Add($name)
        [void]$items.Add($row)
    }
    if ($nearOnly -and $items.Count -eq 0) {
        foreach ($item in @($pool)) {
            if (-not $item) { continue }
            $name = ''
            try { $name = [string]$item.Current.Name } catch { continue }
            if (-not $name) { continue }
            [void]$labels.Add($name)
            [void]$items.Add(@{ Name = $name; Element = $item; Left = 0; Top = 0; Right = 0; Bottom = 0 })
        }
    }
    return @{ Labels = @($labels.ToArray()); Items = @($items.ToArray()) }
}

function Select-ListedComboItem {
    param($Items, [string]$Label, $Combo)
    foreach ($item in @($Items)) {
        if (-not $item) { continue }
        if (-not (Test-CanonLabelEquals $item.Name $Label)) { continue }
        try {
            $sel = $null
            if ($item.Element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$sel)) {
                $sel.Select()
                Start-Sleep -Milliseconds 200
                Collapse-CanonCombo $Combo
                return $true
            }
        } catch {
            Write-Remax ("Selecting '" + $Label + "' failed: " + $_.Exception.Message)
        }
    }
    Collapse-CanonCombo $Combo
    return $false
}

function Select-CanonRadio {
    param($Radios, [string]$Label)
    foreach ($radio in @($Radios)) {
        if (-not $radio) { continue }
        if (-not (Test-CanonLabelEquals $radio.Name $Label)) { continue }
        if ($radio.Toggle -eq 'On' -or $radio.Selected) { return $true }
        if ($radio.Element) {
            try {
                $sel = $null
                if ($radio.Element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$sel)) {
                    $sel.Select()
                    return $true
                }
            } catch { }
        }
        return (Set-CanonCheck -Snapshot $radio -On $true)
    }
    return $false
}

function Get-RemaxRundllPath {
    $rundll = Join-Path $env:SystemRoot 'System32\rundll32.exe'
    $sixtyFourOs = $false
    $sixtyFourProc = $true
    try { $sixtyFourOs = [bool][Environment]::Is64BitOperatingSystem } catch { $sixtyFourOs = $false }
    try { $sixtyFourProc = [bool][Environment]::Is64BitProcess } catch { $sixtyFourProc = $true }
    if ($sixtyFourOs -and -not $sixtyFourProc) {
        $native = Join-Path $env:SystemRoot 'Sysnative\rundll32.exe'
        if (Test-Path -LiteralPath $native) { return $native }
    }
    return $rundll
}

function Stop-RemaxUiProcess {
    param($Process)
    if (-not $Process) { return }
    try {
        if ($Process.HasExited) { return }
    } catch { return }
    try {
        if (-not $Process.WaitForExit(1500)) {
            $Process.Kill()
        }
    } catch { }
}

function Open-RemaxProperties {
    $session = @{
        Process = $null
        Window  = $null
        Handle  = [IntPtr]::Zero
        Error   = ''
    }
    $rundll = Get-RemaxRundllPath
    $arg = 'printui.dll,PrintUIEntry /p /n "' + $script:PrinterName + '"'
    Write-Remax ("Opening Printer properties. Leave that window alone until it closes.")
    Write-Remax ($rundll + ' ' + $arg)
    try {
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo.FileName = $rundll
        $proc.StartInfo.Arguments = $arg
        $proc.StartInfo.UseShellExecute = $true
        [void]$proc.Start()
        $session.Process = $proc
    } catch {
        $session.Error = "Printer properties did not start: " + $_.Exception.Message
        return $session
    }
    $title = '*' + $script:PrinterName + '*Properties*'
    $window = Wait-UiaTopWindow -ProcessId $session.Process.Id -TitleLike $title -Exclude @() -TimeoutMs 20000
    if (-not $window) {
        $session.Error = "Printer properties did not open for " + $script:PrinterName + "."
        Stop-RemaxUiProcess $session.Process
        return $session
    }
    $session.Window = $window
    try { $session.Handle = [IntPtr]$window.Current.NativeWindowHandle } catch { $session.Handle = [IntPtr]::Zero }
    Show-CanonWindow $window
    return $session
}

function Click-DialogButton {
    param($Window, [string[]]$Labels, [IntPtr]$CloseHandle)
    if (-not $Window) { return $false }
    $elements = @()
    try { $elements = Get-UiaDescendants $Window } catch { return $false }
    $button = Select-LabeledControl -Elements $elements -Labels $Labels -ControlType 'Button'
    if (-not $button) { return $false }
    $posted = [bool](Invoke-CanonButton -Snapshot $button -How post)
    $mustClose = ($CloseHandle -and $CloseHandle -ne [IntPtr]::Zero)
    if (-not $mustClose) { return $posted }
    if (Wait-WindowClosed -Handle $CloseHandle -TimeoutMs 1200) { return $true }
    try { $elements = Get-UiaDescendants $Window } catch { $elements = @() }
    $button = Select-LabeledControl -Elements $elements -Labels $Labels -ControlType 'Button'
    if ($button) {
        Show-CanonWindow $Window
        [void](Invoke-CanonButton -Snapshot $button -How mouse)
        if (Wait-WindowClosed -Handle $CloseHandle -TimeoutMs 1500) { return $true }
        [void](Invoke-CanonButton -Snapshot $button -How invoke)
    }
    return $posted
}

function Close-RemaxProperties {
    param($Session, [switch]$Save)
    if (-not $Session -or -not $Session.Process) { return }
    $proc = $Session.Process
    try {
        if ($proc.HasExited) { return }
    } catch { return }
    if ($Session.Window) {
        try {
            Show-CanonWindow $Session.Window
            if ($Save) {
                $elements = Get-UiaDescendants $Session.Window
                $apply = Select-LabeledControl -Elements $elements -Labels @('Apply') -ControlType 'Button'
                if ($apply -and $apply.Enabled) {
                    [void](Invoke-CanonButton -Snapshot $apply -How post)
                    Start-Sleep -Milliseconds 400
                    try { $elements = Get-UiaDescendants $Session.Window } catch { $elements = @() }
                    $apply = Select-LabeledControl -Elements $elements -Labels @('Apply') -ControlType 'Button'
                    if ($apply -and $apply.Enabled) {
                        [void](Invoke-CanonButton -Snapshot $apply -How mouse)
                        Start-Sleep -Milliseconds 400
                    }
                }
                [void](Click-DialogButton -Window $Session.Window -Labels @('Close', 'OK') -CloseHandle $Session.Handle)
            } else {
                $clicked = Click-DialogButton -Window $Session.Window -Labels @('Cancel') -CloseHandle $Session.Handle
                if (-not $clicked) {
                    [void](Click-DialogButton -Window $Session.Window -Labels @('Close') -CloseHandle $Session.Handle)
                }
            }
        } catch {
            Write-Remax ("Closing Printer properties: " + $_.Exception.Message)
        }
    }
    try {
        if (-not $proc.WaitForExit(8000)) {
            Write-Remax "Printer properties was still open. Closing it."
            $proc.Kill()
        }
    } catch { }
}

function Wait-WindowClosed {
    param([IntPtr]$Handle, [int]$TimeoutMs)
    if ($Handle -eq [IntPtr]::Zero) { return $true }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $alive = $false
        try { $alive = [bool][RemaxWin32]::IsWindow($Handle) } catch { $alive = $false }
        if (-not $alive) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Open-ChildDialog {
    param($Button, [int]$ProcessId, $Exclude, [string]$TitleLike)
    if (-not $Button) { return $null }
    [void](Invoke-CanonButton -Snapshot $Button -How post)
    $dlg = Wait-UiaTopWindow -ProcessId $ProcessId -Exclude $Exclude -TimeoutMs 8000 -SkipProperties -TitleLike $TitleLike
    if ($dlg) { return $dlg }
    [void](Invoke-CanonButton -Snapshot $Button -How mouse)
    $dlg = Wait-UiaTopWindow -ProcessId $ProcessId -Exclude $Exclude -TimeoutMs 4000 -SkipProperties -TitleLike $TitleLike
    if ($dlg) { return $dlg }
    [void](Invoke-CanonButton -Snapshot $Button -How invoke)
    return (Wait-UiaTopWindow -ProcessId $ProcessId -Exclude $Exclude -TimeoutMs 4000 -SkipProperties -TitleLike $TitleLike)
}

function Set-DefaultValueOnWindow {
    param($Window, [string]$PrintUser)
    $elements = Get-UiaDescendants $Window
    Write-UiaSummary $elements
    $targets = Find-CanonDefaultValueTargets $elements
    $radioOk = $false
    if ($targets.UserNameRadio) {
        $radioOk = Select-CanonRadio -Radios @($targets.UserNameRadio) -Label 'User Name'
        Write-Remax ("User Name radio selected: " + $radioOk)
    } else {
        Write-Remax "User Name radio was not found under Name to Set for User Information."
    }
    Start-Sleep -Milliseconds 250
    $elements = Get-UiaDescendants $Window
    $targets = Find-CanonDefaultValueTargets $elements
    $wrote = $false
    if ($targets.NameEdit) {
        $wrote = Set-CanonEdit -Snapshot $targets.NameEdit -Text $PrintUser
        Write-Remax ("User Name text box set: " + $wrote)
    } else {
        Write-Remax "Text box under the User Name radio was not found."
    }
    $elements = Get-UiaDescendants $Window
    $targets = Find-CanonDefaultValueTargets $elements
    if ($targets.AlwaysConfirm -and $targets.AlwaysConfirm.Toggle -ne 'On') {
        [void](Set-CanonCheck -Snapshot $targets.AlwaysConfirm -On $true)
        Write-Remax "Checked Always Confirm User Information When Performing Secured Print."
    }
    if ($targets.ConfirmPrinting -and $targets.ConfirmPrinting.Toggle -eq 'On') {
        [void](Set-CanonCheck -Snapshot $targets.ConfirmPrinting -On $false)
        Write-Remax "Cleared Confirm User Name When Printing."
    }
    if ($targets.PinEdit -and -not [string]::IsNullOrEmpty([string]$targets.PinEdit.Value)) {
        [void](Set-CanonEdit -Snapshot $targets.PinEdit -Text '')
        Write-Remax "Cleared the secured print PIN."
    }
    return ($radioOk -and $wrote)
}

function Update-DefaultValueDialog {
    param($Window, $Button, [string]$PrintUser, [int]$ProcessId, [switch]$ReadOnly)
    $result = @{ Opened = $false; Read = $null }
    $props = [IntPtr]::Zero
    try { $props = [IntPtr]$Window.Current.NativeWindowHandle } catch { $props = [IntPtr]::Zero }
    $dlg = Open-ChildDialog -Button $Button -ProcessId $ProcessId -Exclude @($props) -TitleLike '*Default Value Settings*'
    if (-not $dlg) {
        Write-Remax "Default Value Settings dialog did not open from Settings..."
        return $result
    }
    $title = ''
    try { $title = [string]$dlg.Current.Name } catch { $title = '' }
    if (-not (Test-DefaultValueTitle $title)) {
        Write-Remax ("Opened window '" + $title + "' is not Default Value Settings. Closing it.")
        $handle = [IntPtr]::Zero
        try { $handle = [IntPtr]$dlg.Current.NativeWindowHandle } catch { $handle = [IntPtr]::Zero }
        [void](Click-DialogButton -Window $dlg -Labels @('Cancel', 'Close') -CloseHandle $handle)
        return $result
    }
    $result.Opened = $true
    Show-CanonWindow $dlg
    $handle = [IntPtr]::Zero
    try { $handle = [IntPtr]$dlg.Current.NativeWindowHandle } catch { $handle = [IntPtr]::Zero }
    Write-Remax ("Default Value Settings opened (" + $title + ").")
    if (-not $ReadOnly) {
        [void](Set-DefaultValueOnWindow -Window $dlg -PrintUser $PrintUser)
    }
    $elements = @()
    try { $elements = Get-UiaDescendants $dlg } catch { $elements = @() }
    Write-UiaSummary $elements
    $result.Read = Read-DefaultValueFromElements -Elements $elements -PrintUser $PrintUser
    if ($ReadOnly) {
        [void](Click-DialogButton -Window $dlg -Labels @('Cancel', 'Close') -CloseHandle $handle)
    } else {
        [void](Click-DialogButton -Window $dlg -Labels @('OK') -CloseHandle $handle)
    }
    [void](Wait-WindowClosed -Handle $handle -TimeoutMs 5000)
    return $result
}

function Set-CanonComboToLabel {
    param($Combo, [string]$Kind)
    if (-not $Combo) { return $false }
    $want = 'Inner Finisher E1'
    if ($Kind -eq 'paper') { $want = 'Cassette Feeding Unit' }
    $current = Get-ComboDisplay $Combo
    if ($current) {
        $already = $null
        if ($Kind -eq 'paper') { $already = Resolve-PaperSourceLabel -Labels @($current) }
        else { $already = Resolve-FinisherLabel -Labels @($current) }
        if ($already) { return $true }
    }
    $opened = Get-CanonComboChoices $Combo
    $pick = $null
    if ($Kind -eq 'paper') { $pick = Resolve-PaperSourceLabel -Labels $opened.Labels }
    else { $pick = Resolve-FinisherLabel -Labels $opened.Labels }
    if (-not $pick) {
        $listed = ''
        if ($opened.Labels) { $listed = ($opened.Labels -join ' | ') }
        Write-Remax ("Combo has no '" + $want + "'. Choices: " + $listed)
        Collapse-CanonCombo $Combo
        return $false
    }
    $ok = Select-ListedComboItem -Items $opened.Items -Label $pick -Combo $Combo
    Write-Remax ("Selected '" + $pick + "': " + $ok)
    return [bool]$ok
}

function Set-CanonDeviceOnWindow {
    param($Window, [string]$PrintUser, [int]$ProcessId)
    Show-CanonWindow $Window
    $tabOk = Select-UiaTab -Window $Window -TabName 'Device Settings'
    if (-not $tabOk) { return }
    Start-Sleep -Milliseconds 500
    $elements = Get-UiaDescendants $Window
    Write-UiaSummary $elements
    $targets = Find-CanonDeviceTargets $elements
    if ($targets.Profile) {
        $opened = Get-CanonComboChoices $targets.Profile
        $pick = Resolve-ProfileLabel $opened.Labels
        if ($pick) {
            [void](Select-ListedComboItem -Items $opened.Items -Label $pick -Combo $targets.Profile)
            Write-Remax ("Config. Profile choice: " + $pick)
            Start-Sleep -Milliseconds 600
            $elements = Get-UiaDescendants $Window
            $targets = Find-CanonDeviceTargets $elements
        } else {
            Collapse-CanonCombo $targets.Profile
            Write-Remax "Config. Profile list had no iR-ADV C5235/5240 entry."
        }
    }
    if ($targets.PaperCombo) {
        $ok = Set-CanonComboToLabel -Combo $targets.PaperCombo -Kind 'paper'
        Write-Remax ("Paper Source Options set to Cassette Feeding Unit: " + $ok)
        Start-Sleep -Milliseconds 300
        $elements = Get-UiaDescendants $Window
        $targets = Find-CanonDeviceTargets $elements
    } else {
        Write-Remax "Paper Source Options combo was not found."
    }
    if ($targets.OutputCombo) {
        $ok = Set-CanonComboToLabel -Combo $targets.OutputCombo -Kind 'output'
        Write-Remax ("Output Options set to Inner Finisher E1: " + $ok)
    } else {
        Write-Remax "Output Options combo was not found."
    }
    $elements = Get-UiaDescendants $Window
    $targets = Find-CanonDeviceTargets $elements
    if ($targets.UserInfo -and $targets.UserInfo.Toggle -ne 'On') {
        [void](Set-CanonCheck -Snapshot $targets.UserInfo -On $true)
        Start-Sleep -Milliseconds 300
        $elements = Get-UiaDescendants $Window
        $targets = Find-CanonDeviceTargets $elements
    }
    if (-not $targets.UserInfo) {
        Write-Remax "Set User Information checkbox was not found."
    }
    if ($targets.UserSettings) {
        [void](Update-DefaultValueDialog -Window $Window -Button $targets.UserSettings -PrintUser $PrintUser -ProcessId $ProcessId)
    } else {
        Write-Remax "Settings... button beside Set User Information was not found."
    }
}

function Read-CanonDeviceFromWindow {
    param($Window, [string]$PrintUser, [int]$ProcessId)
    $read = New-CanonRead
    $read.Opened = $true
    Show-CanonWindow $Window
    $tabOk = Select-UiaTab -Window $Window -TabName 'Device Settings'
    if (-not $tabOk) {
        $read.Error = 'Device Settings tab was not found.'
        return $read
    }
    Start-Sleep -Milliseconds 400
    $elements = @()
    try { $elements = Get-UiaDescendants $Window } catch { $elements = @() }
    Write-UiaSummary $elements
    $targets = Find-CanonDeviceTargets $elements
    if ($targets.PaperCombo) {
        $read.PaperSeen = $true
        $read.PaperValue = Get-ComboDisplay $targets.PaperCombo
    }
    if ($targets.OutputCombo) {
        $read.OutputSeen = $true
        $read.OutputValue = Get-ComboDisplay $targets.OutputCombo
    }
    if ($targets.Profile) {
        $read.ProfileValue = Get-ComboDisplay $targets.Profile
    }
    if ($targets.UserInfo) {
        $read.UserInfoSeen = $true
        $read.UserInfoOn = ($targets.UserInfo.Toggle -eq 'On')
    }
    if ($targets.UserSettings) {
        $info = Update-DefaultValueDialog -Window $Window -Button $targets.UserSettings -PrintUser $PrintUser -ProcessId $ProcessId -ReadOnly
        $read.UserDialog = [bool]$info.Opened
        if ($info.Read) {
            $read.UserNameRadio = [bool]$info.Read.Radio
            $read.UserNameValue = [string]$info.Read.Name
            $read.AlwaysConfirm = [bool]$info.Read.Always
            $read.ConfirmPrinting = [bool]$info.Read.ConfirmPrinting
            $read.PinBlank = [bool]$info.Read.PinBlank
            $read.PinSeen = [bool]$info.Read.PinSeen
            $read.NameSeen = [bool]$info.Read.NameSeen
            $read.AlwaysSeen = [bool]$info.Read.AlwaysSeen
            $read.ConfirmSeen = [bool]$info.Read.ConfirmSeen
        }
    }
    return $read
}

function Convert-CanonReadToResult {
    param($Read, [string]$PrintUser, [string]$Action, [string]$OpenError)
    $result = New-DeviceUiResult
    $result.Attempted = $true
    $wrongState = 'MANUAL'
    if ($Action -eq 'read') { $wrongState = 'FAIL' }
    if ($OpenError -or -not $Read -or -not $Read.Opened) {
        $msg = $OpenError
        if (-not $msg -and $Read) { $msg = [string]$Read.Error }
        if (-not $msg) { $msg = 'Printer properties did not open.' }
        $result.PaperDetail = $msg
        $result.OutputDetail = $msg
        $result.UserInfoDetail = $msg
        $result.UserNameDetail = $msg
        return $result
    }
    if ($Read.Error -and -not $Read.PaperSeen -and -not $Read.OutputSeen) {
        $result.PaperDetail = [string]$Read.Error
        $result.OutputDetail = [string]$Read.Error
        $result.UserInfoDetail = [string]$Read.Error
        $result.UserNameDetail = [string]$Read.Error
        return $result
    }
    $paperOk = $false
    if ($Read.PaperValue) {
        $match = Resolve-PaperSourceLabel -Labels @([string]$Read.PaperValue)
        if ($match) { $paperOk = $true }
    }
    if ($Read.PaperSeen -and $paperOk) {
        $result.PaperState = 'PASS'
        $result.PaperDetail = 'Device Settings readback: Paper Source Options is Cassette Feeding Unit.'
    } elseif ($Read.PaperSeen) {
        $result.PaperState = $wrongState
        $shown = [string]$Read.PaperValue
        if (-not $shown) { $shown = 'blank' }
        $result.PaperDetail = 'Device Settings readback: Paper Source Options is ' + $shown + '.'
    } else {
        $result.PaperDetail = 'Device Settings dialog had no Paper Source Options combo.'
    }
    $outputOk = $false
    if ($Read.OutputValue) {
        $match = Resolve-FinisherLabel -Labels @([string]$Read.OutputValue)
        if ($match) { $outputOk = $true }
    }
    if ($Read.OutputSeen -and $outputOk) {
        $result.OutputState = 'PASS'
        $result.OutputDetail = 'Device Settings readback: Output Options is Inner Finisher E1.'
    } elseif ($Read.OutputSeen) {
        $result.OutputState = $wrongState
        $shown = [string]$Read.OutputValue
        if (-not $shown) { $shown = 'blank' }
        $result.OutputDetail = 'Device Settings readback: Output Options is ' + $shown + '.'
    } else {
        $result.OutputDetail = 'Device Settings dialog had no Output Options combo.'
    }
    if ($Read.UserInfoSeen -and $Read.UserInfoOn) {
        $result.UserInfoState = 'PASS'
        $result.UserInfoDetail = 'Device Settings readback: Set User Information is on.'
    } elseif ($Read.UserInfoSeen) {
        $result.UserInfoState = $wrongState
        $result.UserInfoDetail = 'Device Settings readback: Set User Information is off.'
    } else {
        $result.UserInfoDetail = 'Device Settings dialog had no Set User Information checkbox.'
    }
    $who = [string]$PrintUser
    if (-not $who) { $who = [string]$Read.UserNameValue }
    if (-not $who) { $who = 'blank' }
    $userOk = $false
    if ($Read.UserDialog -and $Read.UserNameRadio -and $Read.NameSeen -and $Read.AlwaysSeen -and $Read.AlwaysConfirm -and $Read.ConfirmSeen -and (-not $Read.ConfirmPrinting) -and $Read.PinBlank) {
        if ($PrintUser) {
            if (Test-CanonLabelEquals $Read.UserNameValue $PrintUser) { $userOk = $true }
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$Read.UserNameValue)) {
            $userOk = $true
        }
    }
    if ($userOk) {
        $result.UserNameState = 'PASS'
        $result.UserNameDetail = 'Device Settings readback: User Name = ' + $Read.UserNameValue
    } elseif (-not $Read.UserDialog) {
        $result.UserNameDetail = 'Default Value Settings did not open from Settings...'
    } else {
        $result.UserNameState = $wrongState
        $shown = [string]$Read.UserNameValue
        if (-not $shown) { $shown = 'blank' }
        $radio = 'off'
        if ($Read.UserNameRadio) { $radio = 'on' }
        $result.UserNameDetail = 'Device Settings readback: User Name radio ' + $radio + ', text ' + $shown + '. Expected User Name = ' + $who + ' (Always Confirm on, Confirm User Name When Printing off, PIN blank).'
    }
    if ($Read.ProfileValue) {
        $result.ProfileDetail = 'Config. Profile read back as ' + $Read.ProfileValue + '.'
    }
    return $result
}

function Restore-CanonDeviceDat {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $trim = $Path.Trim()
    if ($trim.Contains('"') -or $trim.Contains("'")) {
        Write-Remax "REMAX_DEVICE_DAT contains a quote. Restore skipped."
        return $false
    }
    if (-not (Test-Path -LiteralPath $trim)) {
        Write-Remax ("REMAX_DEVICE_DAT was not found: " + $trim)
        return $false
    }
    $rundll = Get-RemaxRundllPath
    $arg = 'printui.dll,PrintUIEntry /Sr /n "' + $script:PrinterName + '" /a "' + $trim + '" d g r'
    Write-Remax ("Restoring printer-specific data and global DEVMODE from " + $trim)
    Write-Remax ($rundll + ' ' + $arg)
    $proc = $null
    try {
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo.FileName = $rundll
        $proc.StartInfo.Arguments = $arg
        $proc.StartInfo.UseShellExecute = $false
        $proc.StartInfo.CreateNoWindow = $true
        [void]$proc.Start()
    } catch {
        Write-Remax ("PrintUI restore did not start: " + $_.Exception.Message)
        return $false
    }
    if (-not $proc.WaitForExit(20000)) {
        Write-Remax "PrintUI restore timed out."
        try { $proc.Kill() } catch { }
        return $false
    }
    Write-Remax ("PrintUI restore exit " + $proc.ExitCode)
    return ($proc.ExitCode -eq 0)
}

function Invoke-CanonDeviceAutomation {
    param([string]$PrintUser, [string]$Action)
    $result = New-DeviceUiResult
    $skip = Get-DeviceUiSkipReason
    if ($skip) {
        $result.SkipReason = $skip
        return $result
    }
    try {
        Initialize-RemaxUi
    } catch {
        $result.Attempted = $true
        $msg = "UI Automation could not load: " + $_.Exception.Message
        $result.PaperDetail = $msg
        $result.OutputDetail = $msg
        $result.UserInfoDetail = $msg
        $result.UserNameDetail = $msg
        return $result
    }
    if ($Action -eq 'apply' -and $env:REMAX_DEVICE_DAT) {
        try { [void](Restore-CanonDeviceDat $env:REMAX_DEVICE_DAT.Trim()) } catch {
            Write-Remax ("PrintUI restore failed: " + $_.Exception.Message)
        }
    }
    $sessions = New-Object System.Collections.Generic.List[object]
    $read = $null
    $openError = ''
    try {
        if ($Action -eq 'apply') {
            $session = Open-RemaxProperties
            [void]$sessions.Add($session)
            if (-not $session.Window) {
                $openError = [string]$session.Error
            } else {
                try {
                    Set-CanonDeviceOnWindow -Window $session.Window -PrintUser $PrintUser -ProcessId $session.Process.Id
                } catch {
                    Write-Remax ("Device Settings edit failed: " + $_.Exception.Message)
                }
                Close-RemaxProperties -Session $session -Save
                Start-Sleep -Milliseconds 700
            }
        }
        if (-not $openError) {
            $verifySession = Open-RemaxProperties
            [void]$sessions.Add($verifySession)
            if (-not $verifySession.Window) {
                $openError = [string]$verifySession.Error
                if ($Action -eq 'apply' -and -not $openError) {
                    $openError = 'Device Settings were edited but Printer properties did not reopen for readback.'
                }
            } else {
                try {
                    $read = Read-CanonDeviceFromWindow -Window $verifySession.Window -PrintUser $PrintUser -ProcessId $verifySession.Process.Id
                } catch {
                    $openError = "Device Settings readback failed: " + $_.Exception.Message
                }
                Close-RemaxProperties -Session $verifySession
            }
        }
    } catch {
        $openError = "Device Settings automation failed: " + $_.Exception.Message
        Write-Remax $openError
    } finally {
        foreach ($session in $sessions) {
            if ($session -and $session.Process) { Stop-RemaxUiProcess $session.Process }
        }
    }
    if ($openError -and -not $read) {
        return (Convert-CanonReadToResult -Read (New-CanonRead) -PrintUser $PrintUser -Action $Action -OpenError $openError)
    }
    return (Convert-CanonReadToResult -Read $read -PrintUser $PrintUser -Action $Action -OpenError $openError)
}

function Get-PropertyRowName {
    param($Row)
    if ($null -eq $Row) { return '' }
    if ($Row -is [System.Collections.IDictionary]) {
        if ($Row.Contains('PropertyName')) { return [string]$Row['PropertyName'] }
        if ($Row.Contains('Name')) { return [string]$Row['Name'] }
        return ''
    }
    try { return [string]$Row.PropertyName } catch { return '' }
}

function Get-PropertyRowValue {
    param($Row)
    if ($null -eq $Row) { return '' }
    if ($Row -is [System.Collections.IDictionary]) {
        if ($Row.Contains('Value')) { return [string]$Row['Value'] }
        return ''
    }
    try {
        if ($null -eq $Row.Value) { return '' }
        return [string]$Row.Value
    } catch { return '' }
}

function Find-NamedPrinterProperty {
    param($Rows, [string[]]$Names)
    foreach ($want in @($Names)) {
        foreach ($row in @($Rows)) {
            if ((Get-PropertyRowName $row) -eq $want) { return $row }
        }
    }
    return $null
}

function Test-PropertyReadback {
    param([string]$Value, [string[]]$Accept)
    foreach ($item in @($Accept)) {
        if ([string]::IsNullOrWhiteSpace([string]$item)) { continue }
        if ($Value -eq [string]$item) { return $true }
        if (Test-CanonLabelEquals $Value ([string]$item)) { return $true }
    }
    return $false
}

function Write-PrinterPropertyInventory {
    param($Rows)
    $count = @($Rows).Count
    if ($count -eq 0) {
        Write-Remax "Get-PrinterProperty returned no properties. UI Automation is the fallback for device options."
        return
    }
    Write-Remax ("Get-PrinterProperty returned " + $count + " properties.")
    foreach ($row in @($Rows)) {
        $name = Get-PropertyRowName $row
        $value = Get-PropertyRowValue $row
        if ($value.Length -gt 160) { $value = $value.Substring(0, 160) + '...' }
        Write-Remax ("PrinterProperty " + $name + " = " + $value)
    }
}

function Write-PrinterDriverDataInventory {
    $root = Join-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Printers' $script:PrinterName
    $data = Join-Path $root 'PrinterDriverData'
    if (Test-Path -LiteralPath $data) {
        try {
            $key = Get-Item -LiteralPath $data
            $names = @($key.GetValueNames())
            Write-Remax ("PrinterDriverData value names (read only, not written): " + ($names -join ', '))
        } catch {
            Write-Remax ("PrinterDriverData could not be listed: " + $_.Exception.Message)
        }
    } else {
        Write-Remax ("PrinterDriverData key is not present: " + $data)
    }
    if (Test-Path -LiteralPath $root) {
        try {
            $printerKey = Get-Item -LiteralPath $root
            $listed = @()
            foreach ($value in @($printerKey.GetValueNames())) {
                if ($value -match 'DevMode') { $listed += [string]$value }
            }
            if ($listed.Count -gt 0) {
                Write-Remax ("Printer key DevMode value names (read only, not written): " + ($listed -join ', '))
            } else {
                Write-Remax "Printer key has no DevMode value name to list."
            }
        } catch {
            Write-Remax ("Printer key could not be listed: " + $_.Exception.Message)
        }
    }
}

function Read-OnePrinterProperty {
    param([string]$Name)
    try {
        $row = Get-PrinterProperty -PrinterName $script:PrinterName -PropertyName $Name -ErrorAction Stop
        return (Get-PropertyRowValue $row)
    } catch {
        return $null
    }
}

function Try-ApplyPrinterProperty {
    param($Row, [string[]]$Accept, [string]$Action)
    $name = Get-PropertyRowName $Row
    $current = Get-PropertyRowValue $Row
    if (Test-PropertyReadback -Value $current -Accept $Accept) {
        return @{ Ok = $true; Value = $current; Detail = ("Get-PrinterProperty " + $name + " read back '" + $current + "'.") }
    }
    if ($Action -ne 'apply') {
        return @{ Ok = $false; Value = $current; Detail = ("Get-PrinterProperty " + $name + " is '" + $current + "'. UI Automation is the fallback.") }
    }
    foreach ($candidate in @($Accept)) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
        try {
            Set-PrinterProperty -PrinterName $script:PrinterName -PropertyName $name -Value $candidate -ErrorAction Stop
        } catch {
            Write-Remax ("Set-PrinterProperty " + $name + " = " + $candidate + " failed: " + $_.Exception.Message)
            continue
        }
        $read = Read-OnePrinterProperty $name
        if ($null -ne $read -and (Test-PropertyReadback -Value ([string]$read) -Accept @($candidate))) {
            return @{ Ok = $true; Value = [string]$read; Detail = ("Set-PrinterProperty " + $name + " read back '" + $read + "'.") }
        }
        Write-Remax ("Set-PrinterProperty " + $name + " = " + $candidate + " did not read back.")
    }
    try {
        Set-PrinterProperty -PrinterName $script:PrinterName -PropertyName $name -Value $current -ErrorAction Stop
        Write-Remax ("Restored " + $name + " to '" + $current + "'.")
    } catch {
        Write-Remax ("Could not restore " + $name + ": " + $_.Exception.Message)
    }
    return @{ Ok = $false; Value = $current; Detail = ("Get-PrinterProperty " + $name + " did not keep a recorded value. UI Automation is the fallback.") }
}

function New-PropertyResult {
    $miss = 'Get-PrinterProperty did not expose this setting. UI Automation is the fallback.'
    return @{
        PaperState     = 'MANUAL'
        PaperDetail    = $miss
        OutputState    = 'MANUAL'
        OutputDetail   = $miss
        UserInfoState  = 'MANUAL'
        UserInfoDetail = $miss
        UserNameState  = 'MANUAL'
        UserNameDetail = $miss
    }
}

function Invoke-CanonPropertySettings {
    param([string]$PrintUser, [string]$Action)
    $result = New-PropertyResult
    $rows = @()
    try {
        $rows = @(Get-PrinterProperty -PrinterName $script:PrinterName -ErrorAction Stop)
    } catch {
        Write-Remax ("Get-PrinterProperty failed: " + $_.Exception.Message)
        $result.PaperDetail = "Get-PrinterProperty failed: " + $_.Exception.Message
        $result.OutputDetail = $result.PaperDetail
        $result.UserInfoDetail = $result.PaperDetail
        $result.UserNameDetail = $result.PaperDetail
        try { Write-PrinterDriverDataInventory } catch { }
        return $result
    }
    Write-PrinterPropertyInventory $rows
    try { Write-PrinterDriverDataInventory } catch {
        Write-Remax ("Driver data inventory failed: " + $_.Exception.Message)
    }
    $paperNames = @('Config:CNSrcOption', 'Config:PaperSourceOptions', 'Config:CNPaperSource', 'Config:PaperSource')
    $outputNames = @('Config:CNFinisher', 'Config:OutputOptions', 'Config:CNOutputOption')
    $userInfoNames = @('Config:CNSetUserInfo', 'Config:SetUserInformation', 'Config:CNUserInformation')
    $userNameNames = @('Config:CNUserName', 'Config:UserName', 'Config:CNSecureUserName')
    $paperValues = @('Cassette Feeding Unit', 'OptCas2')
    $outputValues = @('Inner Finisher E1', 'IFINE1')
    $userInfoValues = @('True', '1', 'On')
    $paper = Find-NamedPrinterProperty -Rows $rows -Names $paperNames
    if ($paper) {
        $applied = Try-ApplyPrinterProperty -Row $paper -Accept $paperValues -Action $Action
        if ($applied.Ok) {
            $result.PaperState = 'PASS'
            $result.PaperDetail = 'Paper Source Options via ' + $applied.Detail
        } else {
            $result.PaperDetail = $applied.Detail
        }
    } else {
        $result.PaperDetail = 'Get-PrinterProperty has no Paper Source Options property (' + ($paperNames -join ', ') + '). UI Automation is the fallback.'
    }
    $output = Find-NamedPrinterProperty -Rows $rows -Names $outputNames
    if ($output) {
        $applied = Try-ApplyPrinterProperty -Row $output -Accept $outputValues -Action $Action
        if ($applied.Ok) {
            $result.OutputState = 'PASS'
            $result.OutputDetail = 'Output Options via ' + $applied.Detail
        } else {
            $result.OutputDetail = $applied.Detail
        }
    } else {
        $result.OutputDetail = 'Get-PrinterProperty has no Output Options property (' + ($outputNames -join ', ') + '). UI Automation is the fallback.'
    }
    $userInfo = Find-NamedPrinterProperty -Rows $rows -Names $userInfoNames
    if ($userInfo) {
        $applied = Try-ApplyPrinterProperty -Row $userInfo -Accept $userInfoValues -Action $Action
        if ($applied.Ok) {
            $result.UserInfoState = 'PASS'
            $result.UserInfoDetail = 'Set User Information via ' + $applied.Detail
        } else {
            $result.UserInfoDetail = $applied.Detail
        }
    } else {
        $result.UserInfoDetail = 'Get-PrinterProperty has no Set User Information property (' + ($userInfoNames -join ', ') + '). UI Automation is the fallback.'
    }
    $userName = Find-NamedPrinterProperty -Rows $rows -Names $userNameNames
    if ($userName -and $PrintUser) {
        $applied = Try-ApplyPrinterProperty -Row $userName -Accept @($PrintUser) -Action $Action
        if ($applied.Ok) {
            $result.UserNameState = 'PASS'
            $result.UserNameDetail = 'User Name = ' + $applied.Value
        } else {
            $result.UserNameDetail = $applied.Detail
        }
    } elseif (-not $PrintUser) {
        $result.UserNameDetail = 'No print username to compare with Get-PrinterProperty.'
    } else {
        $result.UserNameDetail = 'Get-PrinterProperty has no User Name property (' + ($userNameNames -join ', ') + '). UI Automation is the fallback.'
    }
    return $result
}

function Test-PropertyResultComplete {
    param($Property)
    if (-not $Property) { return $false }
    if ($Property.PaperState -ne 'PASS') { return $false }
    if ($Property.OutputState -ne 'PASS') { return $false }
    if ($Property.UserInfoState -ne 'PASS') { return $false }
    if ($Property.UserNameState -ne 'PASS') { return $false }
    return $true
}

function Apply-DeviceUiResult {
    param($Status, $Ui, $Property, [string]$PrintUser)
    $rows = @(
        @{ Label = 'PAPER SOURCE'; PropState = ''; PropDetail = ''; UiState = ''; UiDetail = '' }
        @{ Label = 'OUTPUT'; PropState = ''; PropDetail = ''; UiState = ''; UiDetail = '' }
        @{ Label = 'USER INFO'; PropState = ''; PropDetail = ''; UiState = ''; UiDetail = '' }
        @{ Label = 'USER NAME'; PropState = ''; PropDetail = ''; UiState = ''; UiDetail = '' }
    )
    if ($Property) {
        $rows[0].PropState = [string]$Property.PaperState
        $rows[0].PropDetail = [string]$Property.PaperDetail
        $rows[1].PropState = [string]$Property.OutputState
        $rows[1].PropDetail = [string]$Property.OutputDetail
        $rows[2].PropState = [string]$Property.UserInfoState
        $rows[2].PropDetail = [string]$Property.UserInfoDetail
        $rows[3].PropState = [string]$Property.UserNameState
        $rows[3].PropDetail = [string]$Property.UserNameDetail
    }
    if ($Ui) {
        $rows[0].UiState = [string]$Ui.PaperState
        $rows[0].UiDetail = [string]$Ui.PaperDetail
        $rows[1].UiState = [string]$Ui.OutputState
        $rows[1].UiDetail = [string]$Ui.OutputDetail
        $rows[2].UiState = [string]$Ui.UserInfoState
        $rows[2].UiDetail = [string]$Ui.UserInfoDetail
        $rows[3].UiState = [string]$Ui.UserNameState
        $rows[3].UiDetail = [string]$Ui.UserNameDetail
    }
    $attempted = $false
    if ($Ui) { $attempted = [bool]$Ui.Attempted }
    foreach ($row in $rows) {
        if (-not $Status.ContainsKey($row.Label)) { continue }
        $merged = Merge-DeviceLine -TicketState $Status[$row.Label].State -TicketDetail $Status[$row.Label].Detail -PropertyState $row.PropState -PropertyDetail $row.PropDetail -UiState $row.UiState -UiDetail $row.UiDetail -Attempted $attempted
        if ($Ui -and $Ui.SkipReason -and $merged.State -ne 'PASS' -and -not $attempted) {
            $merged.Detail = $merged.Detail + " Device Settings automation skipped (" + $Ui.SkipReason + ")."
        }
        $Status[$row.Label].State = $merged.State
        $Status[$row.Label].Detail = $merged.Detail
    }
    if ($Ui -and $Ui.ProfileDetail -and $Status['DRIVER'].State -eq 'PASS') {
        $Status['DRIVER'].Detail = $Status['DRIVER'].Detail + " " + $Ui.ProfileDetail
    }
}


function Apply-PublishedHardware {
    $result = @{
        CassetteState  = 'MANUAL'
        CassetteDetail = 'Paper Source Options = Cassette Feeding Unit. This driver did not publish print-ticket option OptCas2. Set it in Printer properties, Device Settings.'
        FinisherState  = 'MANUAL'
        FinisherDetail = 'Output Options = Inner Finisher E1. This driver did not publish print-ticket option IFINE1. Set it in Printer properties, Device Settings.'
    }
    $caps = ''
    try {
        $caps = Get-QueueXml -Capabilities -WriteAccess
    } catch {
        Write-Remax ("Print capabilities were not readable: " + $_.Exception.Message)
        $result.CassetteDetail = 'Paper Source Options = Cassette Feeding Unit. Print capabilities could not be read. Set Device Settings by hand.'
        $result.FinisherDetail = 'Output Options = Inner Finisher E1. Print capabilities could not be read. Set Device Settings by hand.'
        return $result
    }
    $cassette = Get-HardwareChoice -CapabilitiesXml $caps -Kind 'cassette'
    $finisher = Get-HardwareChoice -CapabilitiesXml $caps -Kind 'finisher'
    if (-not $cassette -and -not $finisher) {
        Write-Remax "Driver print capabilities do not list OptCas2 or IFINE1. Leaving cassette and finisher for Device Settings."
        return $result
    }
    $ticket = ''
    try {
        $ticket = Get-QueueXml -WriteAccess
    } catch {
        $ticket = ''
    }
    try {
        if ($cassette) {
            Write-Remax ("Setting cassette from driver capabilities (" + $cassette.How + ") feature " + $cassette.Feature)
            $ticket = Update-PrintTicketXml -TicketXml $ticket -FeatureName $cassette.Feature -OptionName $cassette.Option
        }
        if ($finisher) {
            Write-Remax ("Setting finisher from driver capabilities (" + $finisher.How + ") feature " + $finisher.Feature)
            $ticket = Update-PrintTicketXml -TicketXml $ticket -FeatureName $finisher.Feature -OptionName $finisher.Option
        }
        Set-QueueTicketXml $ticket
    } catch {
        Write-Remax ("Could not write the default print ticket: " + $_.Exception.Message)
        return $result
    }
    $readback = ''
    try { $readback = Get-QueueXml -WriteAccess } catch { $readback = '' }
    $cassetteLocal = ''
    if ($cassette) { $cassetteLocal = Get-XmlLocalName $cassette.Option }
    if ($cassette -and $cassetteLocal -and (Test-TicketHasOption -TicketXml $readback -OptionLocalName $cassetteLocal)) {
        $result.CassetteState = 'PASS'
        $result.CassetteDetail = "Default print ticket option " + (Get-XmlLocalName $cassette.Option) + " (Paper Source Options = Cassette Feeding Unit), " + $cassette.How
    } elseif ($cassette) {
        $result.CassetteDetail = 'Driver published a paper-source option but the default print ticket did not keep it. Set Paper Source Options = Cassette Feeding Unit in Device Settings.'
    }
    $finisherLocal = ''
    if ($finisher) { $finisherLocal = Get-XmlLocalName $finisher.Option }
    if ($finisher -and $finisherLocal -and (Test-TicketHasOption -TicketXml $readback -OptionLocalName $finisherLocal)) {
        $result.FinisherState = 'PASS'
        $result.FinisherDetail = "Default print ticket option " + $finisherLocal + " (Inner Finisher E1), " + $finisher.How
    } elseif ($finisher) {
        $result.FinisherDetail = 'Driver published IFINE1 but the default print ticket did not keep it. Set Output Options = Inner Finisher E1 in Device Settings.'
    }
    return $result
}

function Read-HardwareFromTicket {
    $result = @{
        CassetteState  = 'MANUAL'
        CassetteDetail = 'Paper Source Options = Cassette Feeding Unit is not on the default print ticket. Check Printer properties, Device Settings.'
        FinisherState  = 'MANUAL'
        FinisherDetail = 'Inner Finisher E1 is not on the default print ticket. Check Printer properties, Device Settings.'
    }
    $ticket = ''
    try {
        $ticket = Get-QueueXml
    } catch {
        $result.CassetteDetail = 'Could not read the default print ticket. Check Device Settings for Paper Source Options = Cassette Feeding Unit.'
        $result.FinisherDetail = 'Could not read the default print ticket. Check Device Settings for Output Options = Inner Finisher E1.'
        return $result
    }
    if (Test-TicketHasOption -TicketXml $ticket -OptionLocalName 'OptCas2') {
        $result.CassetteState = 'PASS'
        $result.CassetteDetail = 'Default print ticket contains option OptCas2 (Paper Source Options = Cassette Feeding Unit)'
    }
    if (Test-TicketHasOption -TicketXml $ticket -OptionLocalName 'IFINE1') {
        $result.FinisherState = 'PASS'
        $result.FinisherDetail = 'Default print ticket contains option IFINE1 (Inner Finisher E1)'
    }
    return $result
}

function Get-StatusLabels {
    return @('DRIVER', 'PORT', 'PRINTER', 'SIDES', 'PAPER SOURCE', 'OUTPUT', 'USER INFO', 'USER NAME', 'STALE QUEUE')
}

function Get-UserNameDetail {
    param([string]$PrintUser)
    $name = $PrintUser
    if ([string]::IsNullOrWhiteSpace($name) -and $script:SupportDir) {
        $saved = Join-Path $script:SupportDir 'requested-print-user.txt'
        if (Test-Path -LiteralPath $saved) {
            $name = (Get-Content -LiteralPath $saved -Raw).Trim()
        }
    }
    $who = 'the print username'
    if (-not [string]::IsNullOrWhiteSpace($name)) { $who = $name }
    return ("Printer properties, Device Settings, check Set User Information, click Settings..., dialog Default Value Settings, radio User Name, text " + $who + ". Leave Always Confirm User Information When Performing Secured Print checked, Confirm User Name When Printing unchecked, and PIN blank. Do not change Get Device Information.")
}

function Get-ReportFooter {
    param(
        [string]$Result,
        [string]$PrintUser,
        [bool]$Verify
    )
    if ($Verify) {
        return "No queue changes were saved. Verify reads Get-PrinterProperty, then opens Printer properties, reads Device Settings, and clicks Cancel. PASS means Paper Source Options, Output Options, Set User Information, or User Name was read back. MANUAL means that item could not be read. FAIL on those lines means the value was read and does not match. PASS on SIDES is 1-sided Printing."
    }
    if ($Result -eq 'PASS') {
        return "Driver, port, printer, 1-sided Printing, Cassette Feeding Unit, Inner Finisher E1, Set User Information, and User Name were confirmed. Close and reopen Printer properties if that window was already open during the install."
    }
    if ($Result -eq 'PARTIAL') {
        $user = $PrintUser
        if ([string]::IsNullOrWhiteSpace($user)) { $user = 'the print username' }
        return @"
RESULT PARTIAL means the RemaxSecure queue is installed and any PASS lines were read back.
MANUAL means that item was not confirmed. Re-running the installer tries again.
Exit code 2 is not a failed install. When this script is started with irm | iex, exit code 2 does not throw.
1. Printer properties for $script:PrinterName, Device Settings.
2. Paper Source Options = Cassette Feeding Unit.
3. Output Options = Inner Finisher E1.
4. Check Set User Information. Click the Settings... button on that row.
5. In Default Value Settings, under Name to Set for User Information, select User Name (not Logon Name) and type $user in the box under that radio.
6. Leave Always Confirm User Information When Performing Secured Print checked. Leave Confirm User Name When Printing unchecked. Leave PIN blank. Do not change Get Device Information.
7. Apply, OK. When SIDES is PASS, 1-sided Printing is already the spooler default.
Leave the Printer properties window alone while the script is driving it.
"@.Trim()
    }
    return "Install is incomplete. Fix the FAIL lines and run the installer again. Full log: $script:LogFile"
}

function Write-StatusReport {
    param(
        [string]$Kind,
        [bool]$Verify,
        [hashtable]$Status,
        [string]$PrintUser,
        $Target
    )
    $order = @(Get-StatusLabels)
    $states = @()
    foreach ($label in $order) { $states += [string]$Status[$label].State }
    $result = Get-ResultLabel $states
    $code = Get-ExitCodeForResult $result
    $title = 'INSTALL REPORT'
    if ($Verify) { $title = 'VERIFY REPORT' }
    Write-RemaxLine ("======== Remax Secure Printer " + $title + " ========")
    if ($Verify) { Write-RemaxLine "No changes made." }
    Write-RemaxLine ("Version:      " + $script:Version)
    foreach ($label in $order) {
        $row = $Status[$label]
        $prefix = switch ($label) {
            'DRIVER' { 'DRIVER:       ' }
            'PORT' { 'PORT:         ' }
            'PRINTER' { 'PRINTER:      ' }
            'SIDES' { 'SIDES:        ' }
            'PAPER SOURCE' { 'PAPER SOURCE: ' }
            'OUTPUT' { 'OUTPUT:       ' }
            'USER INFO' { 'USER INFO:    ' }
            'USER NAME' { 'USER NAME:    ' }
            'STALE QUEUE' { 'STALE QUEUE:  ' }
        }
        Write-RemaxLine ($prefix + $row.State + "  " + $row.Detail)
    }
    Write-RemaxLine ("RESULT:       " + $result)
    Write-RemaxLine ("ExitCode:     " + $code)
    if ($PrintUser) { Write-RemaxLine ("Print user:   " + $PrintUser) }
    try {
        $account = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        Write-RemaxLine ("Windows account: " + $account + " (logon name, not used as the print username)")
    } catch {
    }
    Write-RemaxLine ("Log:          " + $script:LogFile)
    if ($script:SupportDir) { Write-RemaxLine ("Copy:         " + $script:SupportDir) }
    Write-RemaxLine "======================================================"
    Write-RemaxLine (Get-ReportFooter -Result $result -PrintUser $PrintUser -Verify $Verify)
    $script:ReportDone = $true
    return $code
}

function New-StatusMap {
    $map = @{}
    foreach ($label in @(Get-StatusLabels)) {
        $map[$label] = @{ State = 'FAIL'; Detail = 'not checked' }
    }
    return $map
}

function Get-MatchingDriverObject {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $rows = @()
    try { $rows = @(Get-PrinterDriver -Name $Name -ErrorAction Stop) } catch { return $null }
    $best = $null
    $bestScore = -1
    $nativeX64 = $true
    try { $nativeX64 = [bool][Environment]::Is64BitOperatingSystem } catch { $nativeX64 = $true }
    foreach ($row in @($rows)) {
        if (-not $row) { continue }
        $environment = [string]$row.PrinterEnvironment
        $score = 0
        if ($nativeX64 -and $environment -match 'x64') { $score = 2 }
        elseif ((-not $nativeX64) -and $environment -match 'x86') { $score = 2 }
        if ($score -gt $bestScore) {
            $bestScore = $score
            $best = $row
        }
    }
    if ($best) { return $best }
    if ($rows.Count -gt 0) { return $rows[0] }
    return $null
}

function Get-QueueStatus {
    param($Target)
    $status = New-StatusMap
    $printer = Get-PrinterOrNull $script:PrinterName
    if (-not $printer) {
        $status['PRINTER'].Detail = ($script:PrinterName + " is not installed")
        $status['PORT'].Detail = ("expected Standard TCP/IP port " + $script:PortName + " for " + $Target.Uri)
        $status['DRIVER'].Detail = "queue not installed"
        $status['PAPER SOURCE'].Detail = "queue not installed"
        $status['OUTPUT'].Detail = "queue not installed"
        $status['SIDES'].Detail = "queue not installed"
        $status['USER INFO'].Detail = "queue not installed"
        $status['USER NAME'].Detail = "queue not installed"
    } else {
        $shared = $false
        try { $shared = [bool]$printer.Shared } catch { $shared = $false }
        $defaultName = ''
        try { $defaultName = Get-DefaultPrinterName } catch { $defaultName = '' }
        $isDefault = ($defaultName -eq $script:PrinterName)
        $otherCount = 0
        try {
            foreach ($other in @(Get-Printer -ErrorAction SilentlyContinue)) {
                if ([string]$other.Name -and [string]$other.Name -ne $script:PrinterName) { $otherCount++ }
            }
        } catch { }
        if ((-not $shared) -and (-not $isDefault)) {
            $status['PRINTER'].State = 'PASS'
            $status['PRINTER'].Detail = ($script:PrinterName + ", not shared, not default")
        } elseif ($shared) {
            $status['PRINTER'].State = 'FAIL'
            $status['PRINTER'].Detail = ($script:PrinterName + " is shared. The recorded queue is not shared.")
        } elseif ($otherCount -eq 0) {
            $status['PRINTER'].State = 'MANUAL'
            $status['PRINTER'].Detail = ($script:PrinterName + " is not shared. It is the only printer, so Windows keeps it as the default.")
        } else {
            $status['PRINTER'].State = 'MANUAL'
            $status['PRINTER'].Detail = ($script:PrinterName + " is not shared, but it is still the default printer.")
        }
        $snapshot = $null
        $portError = ''
        $portName = [string]$printer.PortName
        if ($portName -ne $script:PortName) {
            $status['PORT'].Detail = ("queue is on port " + $portName + "; expected Standard TCP/IP port " + $script:PortName + " (LPR, queue " + $Target.Queue + ", byte counting on, SNMP off)")
        } else {
            try { $snapshot = Get-PortSnapshot $portName } catch { $portError = $_.Exception.Message }
            if ($snapshot -and (Test-PortMatches $snapshot $Target)) {
                $status['PORT'].State = 'PASS'
                $status['PORT'].Detail = Format-PortDetail -Snapshot $snapshot -Target $Target
            } elseif ($portError) {
                $status['PORT'].Detail = ("expected " + $Target.Uri + "; could not read the port (" + $portError + ")")
            } else {
                $got = 'missing'
                if ($snapshot) {
                    $snmp = 'off'
                    if ($snapshot.SnmpEnabled) { $snmp = 'on' }
                    $got = ("host " + $snapshot.Host + " queue " + $snapshot.Queue + " protocol " + $snapshot.Protocol + " port " + $snapshot.PortNumber + " byte counting " + $snapshot.ByteCount + " SNMP " + $snmp)
                }
                $status['PORT'].Detail = ("expected LPR queue " + $Target.Queue + ", byte counting on, SNMP off; found " + $got)
            }
        }
        $driverName = [string]$printer.DriverName
        $rank = Get-DriverRank $driverName
        if ($rank -ge 1) {
            $driverObj = $null
            try { $driverObj = Get-MatchingDriverObject $driverName } catch { $driverObj = $null }
            if (-not $driverObj) { $driverObj = @{ Name = $driverName; PrinterEnvironment = '' } }
            $report = Get-DriverReport $driverObj
            $status['DRIVER'].State = [string]$report.State
            $status['DRIVER'].Detail = [string]$report.Detail
        } else {
            $status['DRIVER'].State = 'FAIL'
            $status['DRIVER'].Detail = ("installed driver '" + $driverName + "' is not " + $script:ExactDriverName)
            $status['PAPER SOURCE'].Detail = 'not checked because the queue driver is not the Canon PS driver'
            $status['OUTPUT'].Detail = 'not checked because the queue driver is not the Canon PS driver'
            $status['USER INFO'].Detail = 'not checked because the queue driver is not the Canon PS driver'
            $status['USER NAME'].Detail = 'not checked because the queue driver is not the Canon PS driver'
        }
        try {
            $config = Get-PrintConfiguration -PrinterName $script:PrinterName
            $mode = ''
            if ($config -and $null -ne $config.DuplexingMode) { $mode = [string]$config.DuplexingMode }
            if ($mode -eq 'OneSided') {
                $status['SIDES'].State = 'PASS'
                $status['SIDES'].Detail = '1-sided Printing (DuplexingMode OneSided)'
            } else {
                $status['SIDES'].Detail = ("1-sided Printing expected, found " + $(if ($mode) { $mode } else { 'blank' }))
            }
        } catch {
            $status['SIDES'].Detail = ("Get-PrintConfiguration failed: " + $_.Exception.Message)
        }
        if ($rank -ge 1) {
            $hardware = Read-HardwareFromTicket
            $status['PAPER SOURCE'].State = $hardware.CassetteState
            $status['PAPER SOURCE'].Detail = $hardware.CassetteDetail
            $status['OUTPUT'].State = $hardware.FinisherState
            $status['OUTPUT'].Detail = $hardware.FinisherDetail
            $status['USER INFO'].State = 'MANUAL'
            $status['USER INFO'].Detail = 'Set User Information on. Not on the print ticket. Device Settings readback is required.'
            $status['USER NAME'].State = 'MANUAL'
            $status['USER NAME'].Detail = Get-UserNameDetail ''
        }
    }
    $stale = Get-PrinterOrNull $script:StaleName
    if ($stale) {
        $status['STALE QUEUE'].Detail = ($script:StaleName + " is still installed")
    } else {
        $status['STALE QUEUE'].State = 'PASS'
        $status['STALE QUEUE'].Detail = 'absent'
    }
    return $status
}

function Invoke-Verify {
    if (-not (Test-WindowsHost)) {
        Write-RemaxLine "This verifier is for Windows."
        return 1
    }
    Initialize-RemaxLog 'verify'
    Write-Remax ("Remax Secure Printer verifier " + $script:Version + " (read only)")
    $target = Resolve-PrinterTarget
    try { Import-PrintModule } catch {
        Write-RemaxLine ("PrintManagement module is not available: " + $_.Exception.Message)
        return 1
    }
    $status = Get-QueueStatus $target
    $user = ''
    if ($env:REMAX_PRINT_USER) { $user = $env:REMAX_PRINT_USER.Trim() }
    if (-not $user -and $script:SupportDir) {
        $savedUser = Join-Path $script:SupportDir 'requested-print-user.txt'
        if (Test-Path -LiteralPath $savedUser) {
            $user = (Get-Content -LiteralPath $savedUser -Raw).Trim()
        }
    }
    $installed = Get-PrinterOrNull $script:PrinterName
    $rank = 0
    if ($installed) { $rank = Get-DriverRank ([string]$installed.DriverName) }
    if ($installed -and $rank -ge 1) {
        $property = $null
        try {
            $property = Invoke-CanonPropertySettings -PrintUser $user -Action 'read'
        } catch {
            Write-Remax ("Get-PrinterProperty path failed: " + $_.Exception.Message)
            $property = New-PropertyResult
        }
        $ui = $null
        if (Test-PropertyResultComplete $property) {
            Write-Remax "Verify read Paper Source Options, Output Options, Set User Information, and User Name from Get-PrinterProperty. Skipping UI Automation."
        } else {
            try {
                $ui = Invoke-CanonDeviceAutomation -PrintUser $user -Action 'read'
            } catch {
                Write-Remax ("Device Settings read failed: " + $_.Exception.Message)
                $ui = New-DeviceUiResult
                $ui.Attempted = $true
                $ui.PaperDetail = $_.Exception.Message
                $ui.OutputDetail = $_.Exception.Message
                $ui.UserInfoDetail = $_.Exception.Message
                $ui.UserNameDetail = $_.Exception.Message
            }
        }
        Apply-DeviceUiResult -Status $status -Ui $ui -Property $property -PrintUser $user
    }
    $code = Write-StatusReport -Kind 'verify' -Verify $true -Status $status -PrintUser $user -Target $target
    try {
        if (-not (Test-Path -LiteralPath $script:SupportDir)) {
            New-Item -ItemType Directory -Path $script:SupportDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $script:LogFile -Destination (Join-Path $script:SupportDir 'RemaxSecurePrinterVerify-windows.log') -Force
    } catch {
    }
    return $code
}

function Invoke-Install {
    if (-not (Test-WindowsHost)) {
        Write-RemaxLine "This installer is for Windows."
        return 1
    }
    Initialize-RemaxLog 'install'
    Write-Remax ("Remax Secure Printer installer " + $script:Version)
    if (-not (Test-RemaxAdmin)) {
        Show-AdminHelp
        return 1
    }
    $printUser = Resolve-PrintUserName $script:UserArg
    $target = Resolve-PrinterTarget
    Write-Remax ("Print username: " + $printUser)
    Write-Remax ("Queue: " + $script:PrinterName)
    Write-Remax ("URI: " + $target.Uri)
    Write-Remax ("Port name: " + $script:PortName)
    try {
        $svc = Get-Service -Name Spooler
        if ($svc.Status -ne 'Running') {
            Write-Remax "Starting the Print Spooler service"
            Start-Service Spooler
        }
    } catch {
        Write-Remax ("Print Spooler check failed: " + $_.Exception.Message)
    }
    try { Import-PrintModule } catch {
        Write-RemaxLine ("PrintManagement module is not available: " + $_.Exception.Message)
        return 1
    }
    $status = New-StatusMap
    $staleOk = Remove-StaleQueue
    if ($staleOk) {
        $status['STALE QUEUE'].State = 'PASS'
        $status['STALE QUEUE'].Detail = 'absent'
    } else {
        $status['STALE QUEUE'].Detail = ($script:StaleName + " is still installed")
    }
    $selected = $null
    try { $selected = Find-SelectedInstalledDriver } catch {
        Write-Remax ("Driver query failed: " + $_.Exception.Message)
    }
    if (-not $selected) {
        try { Search-DriverStore } catch {
            Write-Remax ("Driver store search failed: " + $_.Exception.Message)
        }
        try { $selected = Find-SelectedInstalledDriver } catch { $selected = $null }
    }
    if (-not $selected -and $env:REMAX_CANON_PKG_URL) {
        try {
            Install-CanonPackageFromUrl $env:REMAX_CANON_PKG_URL.Trim()
        } catch {
            Write-Remax ("Driver package failed: " + $_.Exception.Message)
            Write-RemaxLine $_.Exception.Message
        }
        try { $selected = Find-SelectedInstalledDriver } catch { $selected = $null }
    }
    if (-not $selected) {
        $installed = @()
        try { $installed = @(Get-InstalledDriverNames) } catch { $installed = @() }
        Show-MissingDriverHelp $installed
        $status['DRIVER'].Detail = ($script:ExactDriverName + ' is not installed')
        $status['PRINTER'].Detail = ($script:PrinterName + ' was not created')
        $status['PORT'].Detail = ('port not created; expected ' + $target.Uri)
        $code = Write-StatusReport -Kind 'install' -Verify $false -Status $status -PrintUser $printUser -Target $target
        Copy-RemaxLog -Result 'FAIL' -PrintUser $printUser -Target $target
        return $code
    }
    $driverName = [string]$selected.Name
    Write-Remax ("Using driver " + $driverName)
    try { Write-AssistServiceNote } catch { }
    try {
        Ensure-LprPort $target | Out-Null
        Ensure-PrinterQueue -DriverName $driverName -Target $target
    } catch {
        Write-Remax ("Queue setup failed: " + $_.Exception.Message)
        $status = Get-QueueStatus $target
        if ($status['PRINTER'].State -eq 'FAIL') {
            $status['PRINTER'].Detail = ("setup failed: " + $_.Exception.Message)
        }
        $code = Write-StatusReport -Kind 'install' -Verify $false -Status $status -PrintUser $printUser -Target $target
        Copy-RemaxLog -Result 'FAIL' -PrintUser $printUser -Target $target
        return $code
    }
    $duplexError = ''
    try {
        $mode = Set-OneSided
        Write-Remax ("DuplexingMode readback before device options: " + $mode)
    } catch {
        $duplexError = $_.Exception.Message
        Write-Remax ("One-sided setting failed: " + $duplexError)
    }
    $hardware = Apply-PublishedHardware
    try {
        $mode = Set-OneSided
        Write-Remax ("DuplexingMode readback after device options: " + $mode)
    } catch {
        if (-not $duplexError) { $duplexError = $_.Exception.Message }
        Write-Remax ("One-sided setting failed after device options: " + $_.Exception.Message)
    }
    $status = Get-QueueStatus $target
    $queueRank = 0
    $live = Get-PrinterOrNull $script:PrinterName
    if ($live) { $queueRank = Get-DriverRank ([string]$live.DriverName) }
    if ($queueRank -ge 1 -and $status['PAPER SOURCE'].State -ne 'PASS') {
        $status['PAPER SOURCE'].State = 'MANUAL'
        if ($hardware.CassetteState -eq 'PASS') {
            $status['PAPER SOURCE'].Detail = 'A paper-source option was written but did not remain on the default print ticket. Set Paper Source Options = Cassette Feeding Unit in Device Settings.'
        } else {
            $status['PAPER SOURCE'].Detail = $hardware.CassetteDetail
        }
    }
    if ($queueRank -ge 1 -and $status['OUTPUT'].State -ne 'PASS') {
        $status['OUTPUT'].State = 'MANUAL'
        if ($hardware.FinisherState -eq 'PASS') {
            $status['OUTPUT'].Detail = 'A finisher option was written but did not remain on the default print ticket. Set Output Options = Inner Finisher E1 in Device Settings.'
        } else {
            $status['OUTPUT'].Detail = $hardware.FinisherDetail
        }
    }
    if ($duplexError -and $status['SIDES'].State -ne 'PASS') {
        $status['SIDES'].State = 'FAIL'
        $status['SIDES'].Detail = ("Set-PrintConfiguration OneSided failed: " + $duplexError)
    }
    if ($queueRank -ge 1) {
        $property = $null
        try {
            $property = Invoke-CanonPropertySettings -PrintUser $printUser -Action 'apply'
        } catch {
            Write-Remax ("Get-PrinterProperty path failed: " + $_.Exception.Message)
            $property = New-PropertyResult
        }
        $ui = $null
        if (Test-PropertyResultComplete $property) {
            Write-Remax "Paper Source Options, Output Options, Set User Information, and User Name were confirmed with Get-PrinterProperty. Skipping UI Automation."
        } else {
            try {
                $ui = Invoke-CanonDeviceAutomation -PrintUser $printUser -Action 'apply'
            } catch {
                Write-Remax ("Device Settings automation failed: " + $_.Exception.Message)
                $ui = New-DeviceUiResult
                $ui.Attempted = $true
                $ui.PaperDetail = $_.Exception.Message
                $ui.OutputDetail = $_.Exception.Message
                $ui.UserInfoDetail = $_.Exception.Message
                $ui.UserNameDetail = $_.Exception.Message
            }
        }
        Apply-DeviceUiResult -Status $status -Ui $ui -Property $property -PrintUser $printUser
        $mode = ''
        try {
            $mode = Set-OneSided
            Write-Remax ("DuplexingMode readback after Device Settings: " + $mode)
        } catch {
            Write-Remax ("One-sided setting failed after Device Settings: " + $_.Exception.Message)
            try {
                $config = Get-PrintConfiguration -PrinterName $script:PrinterName
                if ($config -and $null -ne $config.DuplexingMode) { $mode = [string]$config.DuplexingMode }
            } catch { }
        }
        if ($mode -eq 'OneSided') {
            $status['SIDES'].State = 'PASS'
            $status['SIDES'].Detail = '1-sided Printing (DuplexingMode OneSided)'
        } elseif ($mode) {
            $status['SIDES'].State = 'FAIL'
            $status['SIDES'].Detail = ("DuplexingMode expected OneSided, found " + $mode)
        }
    }
    $states = @()
    foreach ($label in @(Get-StatusLabels)) {
        $states += [string]$status[$label].State
    }
    $result = Get-ResultLabel $states
    $code = Write-StatusReport -Kind 'install' -Verify $false -Status $status -PrintUser $printUser -Target $target
    Copy-RemaxLog -Result $result -PrintUser $printUser -Target $target
    return $code
}

function Invoke-SelfTest {
    $script:Checks = 0
    $script:Fails = 0
    function Assert-Remax {
        param($Condition, [string]$Message)
        $script:Checks++
        if (-not $Condition) {
            $script:Fails++
            Write-RemaxLine ("FAIL " + $Message)
        }
    }
    Assert-Remax (Test-PrintUserName 'tsiogase') 'tsiogase is a valid print username'
    Assert-Remax (Test-PrintUserName 'erod') 'erod is a valid print username'
    Assert-Remax (-not (Test-PrintUserName '')) 'empty username is rejected'
    Assert-Remax (-not (Test-PrintUserName 'DOMAIN\erod')) 'logon name with a backslash is rejected'
    Assert-Remax (-not (Test-PrintUserName 'has space')) 'spaces are rejected'
    Assert-Remax (Test-ModelSpecificPsDriver 'Canon iR-ADV C5235/5240 PS') 'PS model name accepted'
    Assert-Remax (Test-ModelSpecificPsDriver 'Canon iR-ADV C5235/5240 PS3') 'PS3 model name accepted'
    Assert-Remax (-not (Test-ModelSpecificPsDriver 'Canon iR-ADV C5235/5240 UFR II')) 'UFR rejected'
    Assert-Remax (-not (Test-ModelSpecificPsDriver 'Canon iR-ADV C5235/5240 PCL6')) 'PCL rejected'
    Assert-Remax (-not (Test-ModelSpecificPsDriver 'Japanese Paper')) 'Japanese Paper is not the driver'
    Assert-Remax (Test-GenericPlusPs3 'Canon Generic Plus PS3') 'Generic Plus PS3 accepted'
    Assert-Remax (-not (Test-GenericPlusPs3 'Canon Generic Plus UFR II')) 'Generic Plus UFR rejected'
    Assert-Remax (-not (Test-ModelSpecificPsDriver 'Canon Generic Plus PS3')) 'Generic Plus is not the model-specific driver'
    $picked = Select-BestDriverName -Names @(
        'Canon Generic Plus PS3',
        'Canon iR-ADV C5235/5240 UFR II',
        'Canon iR-ADV C5235/5240 PS3'
    )
    Assert-Remax ($picked -eq 'Canon iR-ADV C5235/5240 PS3') 'model-specific PS wins over Generic Plus and UFR'
    $inf = @"
[Manufacturer]
Canon=Canon,NTamd64,NTx86

[Canon.NTamd64]
"Canon iR-ADV C5235/5240 UFR II" = UFR,USB\UFR
"Canon iR-ADV C5235/5240 PS3" = PS,USB\PS
"Canon Generic Plus PS3" = GP,USB\GP

[Canon.NTx86]
"Canon iR-ADV C5235/5240 PS3" = PS,USB\PS

[Strings]
"@
    $models = @(Get-InfDriverModels -Text $inf -Architecture 'amd64')
    $fromInf = Select-BestDriverName -Names $models
    Assert-Remax ($fromInf -eq 'Canon iR-ADV C5235/5240 PS3') 'INF parser prefers the amd64 PS3 model'
    $tokenInf = @"
[Manufacturer]
%Canon% = Models,NTamd64

[Models.NTamd64]
%C5235.PS% = PS,USB\PS
%C5235.UFR% = UFR,USB\UFR

[Strings]
Canon = "Canon"
C5235.PS = "Canon iR-ADV C5235/5240 PS"
C5235.UFR = "Canon iR-ADV C5235/5240 UFR II"
"@
    $tokenPick = Select-BestDriverName -Names @(Get-InfDriverModels -Text $tokenInf -Architecture 'amd64')
    Assert-Remax ($tokenPick -eq 'Canon iR-ADV C5235/5240 PS') 'INF string tokens resolve to the PS model'
    $savedUri = $env:REMAX_PRINTER_URI
    $savedHost = $env:REMAX_PRINTER_HOST
    $savedQueue = $env:REMAX_LPR_QUEUE
    $savedByte = $env:REMAX_LPR_BYTE_COUNT
    Remove-Item Env:REMAX_PRINTER_URI -ErrorAction SilentlyContinue
    Remove-Item Env:REMAX_PRINTER_HOST -ErrorAction SilentlyContinue
    Remove-Item Env:REMAX_LPR_QUEUE -ErrorAction SilentlyContinue
    Remove-Item Env:REMAX_LPR_BYTE_COUNT -ErrorAction SilentlyContinue
    $target = Resolve-PrinterTarget
    Assert-Remax ($target.Uri -eq 'lpd://172.16.105.21/RemaxSecure') 'default URI matches the Mac queue'
    Assert-Remax ($target.PortName -eq '172.16.105.21') 'default port is named after the host'
    Assert-Remax ($script:PortName -eq '172.16.105.21') 'script port name follows the host'
    Assert-Remax ($script:LegacyPortName -eq 'RemaxSecure_LPR') 'legacy port name is remembered'
    Assert-Remax ($target.ByteCount) 'LPR byte counting defaults on'
    $env:REMAX_PRINTER_URI = 'lpd://10.1.2.3/OtherQueue'
    $over = Resolve-PrinterTarget
    Assert-Remax ($over.Host -eq '10.1.2.3' -and $over.Queue -eq 'OtherQueue') 'REMAX_PRINTER_URI overrides host and queue'
    Assert-Remax ($over.PortName -eq '10.1.2.3') 'port name follows an overridden host'
    if ($null -eq $savedUri) {
        Remove-Item Env:REMAX_PRINTER_URI -ErrorAction SilentlyContinue
    } else {
        $env:REMAX_PRINTER_URI = $savedUri
    }
    if ($null -ne $savedHost) { $env:REMAX_PRINTER_HOST = $savedHost }
    if ($null -ne $savedQueue) { $env:REMAX_LPR_QUEUE = $savedQueue }
    if ($null -ne $savedByte) { $env:REMAX_LPR_BYTE_COUNT = $savedByte }
    [void](Resolve-PrinterTarget)
    $caps = @"
<?xml version="1.0"?>
<psf:PrintCapabilities xmlns:psf="http://schemas.microsoft.com/windows/2003/08/printing/printschemaframework" xmlns:psk="http://schemas.microsoft.com/windows/2003/08/printing/printschemakeywords" xmlns:ns0000="http://example/canon">
  <psf:Feature name="ns0000:CNSrcOption">
    <psf:Property name="psk:DisplayName"><psf:Value>Cassette Feeding Unit</psf:Value></psf:Property>
    <psf:Option name="ns0000:None"><psf:Property name="psk:DisplayName"><psf:Value>Off</psf:Value></psf:Property></psf:Option>
    <psf:Option name="ns0000:OptCas2"><psf:Property name="psk:DisplayName"><psf:Value>On</psf:Value></psf:Property></psf:Option>
  </psf:Feature>
  <psf:Feature name="ns0000:CNFinisher">
    <psf:Property name="psk:DisplayName"><psf:Value>Output Options</psf:Value></psf:Property>
    <psf:Option name="ns0000:IFINE1"><psf:Property name="psk:DisplayName"><psf:Value>Inner Finisher E1</psf:Value></psf:Property></psf:Option>
  </psf:Feature>
</psf:PrintCapabilities>
"@
    $cas = Find-PrintFeatureOption -CapabilitiesXml $caps -OptionLocalName 'OptCas2' -FeatureDisplay 'Cassette Feeding Unit' -OptionDisplay 'On'
    $fin = Find-PrintFeatureOption -CapabilitiesXml $caps -OptionLocalName 'IFINE1' -FeatureDisplay '' -OptionDisplay 'Inner Finisher E1'
    Assert-Remax ($cas -and $cas.Feature -eq 'ns0000:CNSrcOption' -and $cas.Option -eq 'ns0000:OptCas2') 'capabilities select OptCas2'
    Assert-Remax ($fin -and $fin.Option -eq 'ns0000:IFINE1') 'capabilities select IFINE1'
    $empty = Find-PrintFeatureOption -CapabilitiesXml '<psf:PrintCapabilities xmlns:psf="http://schemas.microsoft.com/windows/2003/08/printing/printschemaframework"/>' -OptionLocalName 'OptCas2' -FeatureDisplay 'Cassette Feeding Unit' -OptionDisplay 'On'
    Assert-Remax ($null -eq $empty) 'missing options stay unset'
    $ticket = Update-PrintTicketXml -TicketXml '' -FeatureName $cas.Feature -OptionName $cas.Option
    $ticket = Update-PrintTicketXml -TicketXml $ticket -FeatureName $fin.Feature -OptionName $fin.Option
    Assert-Remax (Test-TicketHasOption -TicketXml $ticket -OptionLocalName 'OptCas2') 'ticket keeps OptCas2'
    Assert-Remax (Test-TicketHasOption -TicketXml $ticket -OptionLocalName 'IFINE1') 'ticket keeps IFINE1'
    Assert-Remax ((Get-ResultLabel @('PASS', 'PASS')) -eq 'PASS') 'all PASS'
    Assert-Remax ((Get-ResultLabel @('PASS', 'MANUAL')) -eq 'PARTIAL') 'MANUAL becomes PARTIAL'
    Assert-Remax ((Get-ResultLabel @('PASS', 'FAIL', 'MANUAL')) -eq 'FAIL') 'FAIL wins'
    Assert-Remax ((Get-ExitCodeForResult 'PASS') -eq 0) 'PASS exits 0'
    Assert-Remax ((Get-ExitCodeForResult 'PARTIAL') -eq 2) 'PARTIAL exits 2'
    Assert-Remax ((Get-ExitCodeForResult 'FAIL') -eq 1) 'FAIL exits 1'
    Assert-Remax ($script:Version -eq '1.2.0') 'version string is 1.2.0'
    Assert-Remax ((Get-PrintUserPromptText) -eq 'Print username (last name + first initial, lowercase, for example tsiogase)') 'prompt shows the tsiogase example'
    Assert-Remax ((Get-DriverRank 'Canon iR-ADV C5235/5240 PS3') -gt (Get-DriverRank 'Canon iR-ADV C5235/5240 PS')) 'exact PS3 outranks the older PS name'
    Assert-Remax ((Get-InfArchitectureScore 'C:\drv\x64\cn.inf') -gt (Get-InfArchitectureScore 'C:\drv\x86\cn.inf')) 'x64 INF outranks x86'
    Assert-Remax ((Test-CanonPackageVersionText '30.0.0.1') -eq $true) 'file version 30.0.0.1 is the recorded package'
    Assert-Remax ((Test-CanonPackageVersionText 'V30.00') -eq $true) 'package text 30.00 is accepted'
    Assert-Remax ((Test-CanonPackageVersionText '30.02') -eq $false) '30.02 is not the recorded package'
    Assert-Remax ($null -eq (Test-CanonPackageVersionText '')) 'blank version is unknown, not a mismatch'
    $exactReport = Get-DriverReport -Driver @{ Name = 'Canon iR-ADV C5235/5240 PS3'; PrinterEnvironment = 'Windows x64' } -VersionText '30.0.0.1'
    Assert-Remax ($exactReport.State -eq 'PASS') 'exact PS3 30.0.0.1 x64 is PASS'
    $wrongVer = Get-DriverReport -Driver @{ Name = 'Canon iR-ADV C5235/5240 PS3'; PrinterEnvironment = 'Windows x64' } -VersionText '21.85.0.0'
    Assert-Remax ($wrongVer.State -eq 'MANUAL') 'a different file version is MANUAL'
    $genericReport = Get-DriverReport -Driver @{ Name = 'Canon Generic Plus PS3'; PrinterEnvironment = 'Windows x64' } -VersionText ''
    Assert-Remax ($genericReport.State -eq 'MANUAL') 'Generic Plus PS3 is not the recorded driver name'
    Assert-Remax (Test-RecordedPortValues -Protocol 2 -Queue 'RemaxSecure' -ByteCount 1 -Snmp 0 -ExpectedQueue 'RemaxSecure' -ExpectByte $true) 'recorded port registry values pass'
    Assert-Remax (-not (Test-RecordedPortValues -Protocol 1 -Queue 'RemaxSecure' -ByteCount 1 -Snmp 0 -ExpectedQueue 'RemaxSecure' -ExpectByte $true)) 'RAW protocol fails the port check'
    Assert-Remax (-not (Test-RecordedPortValues -Protocol 2 -Queue 'RemaxSecure' -ByteCount 1 -Snmp 1 -ExpectedQueue 'RemaxSecure' -ExpectByte $true)) 'SNMP on fails the port check'
    Assert-Remax (Test-DefaultValueTitle 'Default Value Settings') 'dialog title matches'
    Assert-Remax (-not (Test-DefaultValueTitle 'User Information Settings')) 'older dialog title is not Default Value Settings'
    $propRows = @(
        @{ PropertyName = 'Config:PaperSourceOptions'; Value = 'Cassette Feeding Unit' }
        @{ PropertyName = 'Config:CNFinisher'; Value = 'None' }
    )
    $paperProp = Find-NamedPrinterProperty -Rows $propRows -Names @('Config:CNSrcOption', 'Config:PaperSourceOptions')
    Assert-Remax ((Get-PropertyRowName $paperProp) -eq 'Config:PaperSourceOptions') 'paper property name is found'
    Assert-Remax (Test-PropertyReadback -Value 'Cassette Feeding Unit' -Accept @('Cassette Feeding Unit', 'OptCas2')) 'paper value readback matches'
    Assert-Remax (Test-PropertyReadback -Value 'Inner Finisher E1' -Accept @('Inner Finisher E1', 'IFINE1')) 'finisher value readback matches'
    Assert-Remax (Test-PropertyReadback -Value 'tsiogase' -Accept @('tsiogase')) 'user name property readback matches'
    Assert-Remax (-not (Test-PropertyReadback -Value 'Logon Name' -Accept @('tsiogase'))) 'logon name is not the print username'
    Assert-Remax ((ConvertTo-CanonLabel 'Set User Information(L)') -eq 'Set User Information') 'accelerator stripped from Set User Information'
    Assert-Remax ((ConvertTo-CanonLabel 'Settings(W)...') -eq 'Settings') 'settings button label normalized'
    Assert-Remax ((ConvertTo-CanonLabel 'Output Options:') -eq 'Output Options') 'output label normalized'
    Assert-Remax (Test-CanonLabelEquals 'Settings(W)...' 'Settings') 'settings label matches'
    function New-FakeEl {
        param([string]$Name, [string]$Type, [int]$Left, [int]$Top, [int]$Width, [int]$Height, [string]$Value, [string]$Toggle)
        return @{
            Name = $Name
            ControlType = $Type
            Left = $Left
            Top = $Top
            Right = ($Left + $Width)
            Bottom = ($Top + $Height)
            Value = $Value
            Toggle = $Toggle
            Offscreen = $false
            Enabled = $true
        }
    }
    $page = New-Object System.Collections.Generic.List[object]
    [void]$page.Add((New-FakeEl 'Paper Source Options:' 'Text' 30 70 180 18 '' ''))
    [void]$page.Add((New-FakeEl '' 'ComboBox' 420 68 220 22 'None' ''))
    [void]$page.Add((New-FakeEl 'Output Options:' 'Text' 30 110 140 18 '' ''))
    [void]$page.Add((New-FakeEl '' 'ComboBox' 420 108 220 22 'None' ''))
    [void]$page.Add((New-FakeEl 'Get Device Information' 'CheckBox' 30 150 220 18 '' 'Off'))
    [void]$page.Add((New-FakeEl 'Settings...' 'Button' 520 148 120 22 '' ''))
    [void]$page.Add((New-FakeEl 'Set User Information' 'CheckBox' 30 190 220 18 '' 'Off'))
    [void]$page.Add((New-FakeEl 'Settings...' 'Button' 520 188 120 22 '' ''))
    $targets = Find-CanonDeviceTargets $page
    Assert-Remax ($targets.PaperCombo -and ($targets.PaperCombo.Top -eq 68)) 'paper combo is the Paper Source Options row'
    Assert-Remax ($targets.OutputCombo -and ($targets.OutputCombo.Top -eq 108)) 'output combo is the Output Options row'
    Assert-Remax ($targets.UserInfo -and (Test-CanonLabelEquals $targets.UserInfo.Name 'Set User Information')) 'Set User Information checkbox found'
    Assert-Remax ($targets.UserSettings -and ($targets.UserSettings.Top -eq 188)) 'Settings... is the button beside Set User Information'
    Assert-Remax ($null -eq $targets.Profile) 'recorded page has no config profile combo'
    $dialog = New-Object System.Collections.Generic.List[object]
    [void]$dialog.Add((New-FakeEl 'Name to Set for User Information:' 'Text' 20 20 280 18 '' ''))
    [void]$dialog.Add((New-FakeEl 'Logon Name' 'RadioButton' 30 50 160 18 '' 'Off'))
    [void]$dialog.Add((New-FakeEl 'User Name' 'RadioButton' 30 80 160 18 '' 'On'))
    [void]$dialog.Add((New-FakeEl '' 'Edit' 50 108 200 22 'tsiogase' ''))
    [void]$dialog.Add((New-FakeEl 'Always Confirm User Information When Performing Secured Print' 'CheckBox' 30 150 420 18 '' 'On'))
    [void]$dialog.Add((New-FakeEl 'Confirm User Name When Printing' 'CheckBox' 30 180 280 18 '' 'Off'))
    [void]$dialog.Add((New-FakeEl 'PIN:' 'Text' 30 220 40 18 '' ''))
    [void]$dialog.Add((New-FakeEl '' 'Edit' 80 218 80 22 '' ''))
    $readOk = Read-DefaultValueFromElements -Elements $dialog -PrintUser 'tsiogase'
    Assert-Remax ($readOk.Ok) 'User Name radio, text, confirm, and blank PIN read back'
    Assert-Remax ($readOk.Name -eq 'tsiogase') 'text under the User Name radio is the print username'
    $dialog[2].Toggle = 'Off'
    $dialog[1].Toggle = 'On'
    $dialog[3].Value = ''
    $readLogon = Read-DefaultValueFromElements -Elements $dialog -PrintUser 'tsiogase'
    Assert-Remax (-not $readLogon.Ok) 'Logon Name is not a passing User Name readback'
    $namedCombos = New-Object System.Collections.Generic.List[object]
    [void]$namedCombos.Add((New-FakeEl 'Output Options:' 'ComboBox' 420 148 220 22 'None' ''))
    [void]$namedCombos.Add((New-FakeEl 'External Puncher:' 'ComboBox' 420 208 220 22 'None' ''))
    $namedPick = Find-CanonComboByLabel -Elements $namedCombos -Labels @('Output Options')
    Assert-Remax ($namedPick -and ($namedPick.Top -eq 148)) 'combo named Output Options is selected'
    $paperPick = Resolve-PaperSourceLabel -Labels @('None', 'Cassette Feeding Unit')
    Assert-Remax ($paperPick -eq 'Cassette Feeding Unit') 'paper source choice'
    $finisherPick = Resolve-FinisherLabel -Labels @('None', 'Inner Finisher E1', 'Staple Finisher')
    Assert-Remax ($finisherPick -eq 'Inner Finisher E1') 'finisher choice'
    $profilePick = Resolve-ProfileLabel -Labels @('Auto', 'Canon iR-ADV C5235/5240')
    Assert-Remax ($profilePick -eq 'Canon iR-ADV C5235/5240') 'profile choice'
    $keepTicket = Merge-DeviceLine -TicketState 'PASS' -TicketDetail 'ticket' -PropertyState '' -PropertyDetail '' -UiState 'MANUAL' -UiDetail 'ui' -Attempted $false
    Assert-Remax ($keepTicket.State -eq 'PASS' -and $keepTicket.Detail -eq 'ticket') 'ticket PASS stands when UI did not run'
    $uiWin = Merge-DeviceLine -TicketState 'MANUAL' -TicketDetail 'ticket' -PropertyState '' -PropertyDetail '' -UiState 'PASS' -UiDetail 'readback' -Attempted $true
    Assert-Remax ($uiWin.State -eq 'PASS' -and $uiWin.Detail -eq 'readback') 'UI readback PASS wins'
    $propWin = Merge-DeviceLine -TicketState 'MANUAL' -TicketDetail 'ticket' -PropertyState 'PASS' -PropertyDetail 'property' -UiState 'MANUAL' -UiDetail 'ui' -Attempted $true
    Assert-Remax ($propWin.State -eq 'PASS' -and $propWin.Detail -eq 'property') 'property readback stands when UI cannot see the control'
    $uiFail = Merge-DeviceLine -TicketState 'PASS' -TicketDetail 'ticket' -PropertyState 'PASS' -PropertyDetail 'property' -UiState 'FAIL' -UiDetail 'off' -Attempted $true
    Assert-Remax ($uiFail.State -eq 'FAIL' -and $uiFail.Detail -eq 'off') 'verified mismatch beats a property readback'
    $mergeMap = New-StatusMap
    $mergeMap['DRIVER'].State = 'PASS'
    $mergeMap['DRIVER'].Detail = 'driver'
    $mergeProp = New-PropertyResult
    $mergeProp.PaperState = 'PASS'
    $mergeProp.PaperDetail = 'property paper'
    $mergeUi = New-DeviceUiResult
    $mergeUi.Attempted = $true
    $mergeUi.PaperState = 'MANUAL'
    $mergeUi.PaperDetail = 'ui missed paper'
    $mergeUi.OutputState = 'PASS'
    $mergeUi.OutputDetail = 'ui output'
    $mergeUi.UserInfoState = 'PASS'
    $mergeUi.UserInfoDetail = 'Set User Information is on.'
    $mergeUi.UserNameState = 'PASS'
    $mergeUi.UserNameDetail = 'User Name = tsiogase'
    Apply-DeviceUiResult -Status $mergeMap -Ui $mergeUi -Property $mergeProp -PrintUser 'tsiogase'
    Assert-Remax ($mergeMap['PAPER SOURCE'].State -eq 'PASS' -and $mergeMap['PAPER SOURCE'].Detail -eq 'property paper') 'property PASS remains when the dialog misses that control'
    Assert-Remax ($mergeMap['OUTPUT'].State -eq 'PASS' -and $mergeMap['OUTPUT'].Detail -eq 'ui output') 'dialog PASS wins over a missing property'
    Assert-Remax ($mergeMap['USER NAME'].Detail -eq 'User Name = tsiogase') 'user name line keeps the readback'
    $savedDeviceUi = $env:REMAX_DEVICE_UI
    $env:REMAX_DEVICE_UI = '0'
    Assert-Remax ((Get-DeviceUiSkipReason) -eq 'REMAX_DEVICE_UI=0') 'REMAX_DEVICE_UI=0 skips the dialog'
    if ($null -eq $savedDeviceUi) {
        Remove-Item Env:REMAX_DEVICE_UI -ErrorAction SilentlyContinue
    } else {
        $env:REMAX_DEVICE_UI = $savedDeviceUi
    }
    if ($script:Fails) {
        Write-RemaxLine ("SELF-TEST FAIL (" + $script:Fails + " of " + $script:Checks + ")")
        return 1
    }
    Write-RemaxLine ("SELF-TEST PASS (" + $script:Checks + " checks)")
    return 0
}

try {
    switch ($script:Mode) {
        'help' { Show-Usage; Invoke-Complete 0 }
        'usage-error' {
            Write-RemaxLine $script:UsageError
            Show-Usage
            Invoke-Complete 1
        }
        'selftest' { Invoke-Complete (Invoke-SelfTest) }
        'verify' { Invoke-Complete (Invoke-Verify) }
        default { Invoke-Complete (Invoke-Install) }
    }
} catch {
    if ($script:Completing) { throw }
    $message = $_.Exception.Message
    if ($_.ScriptStackTrace) { $message = $message + "`n" + $_.ScriptStackTrace }
    if ($script:LogFile) { Write-Remax $message } else { Write-RemaxLine $message }
    if (-not $script:ReportDone -and $script:Mode -eq 'install') {
        Write-RemaxLine "======== Remax Secure Printer INSTALL REPORT ========"
        Write-RemaxLine ("Version:     " + $script:Version)
        Write-RemaxLine "RESULT:      FAIL"
        Write-RemaxLine "ExitCode:    1"
        Write-RemaxLine ("FAIL  " + $message)
        Write-RemaxLine "======================================================"
    }
    Invoke-Complete 1
} finally {
    if (-not $script:RanAsFile) {
        $ErrorActionPreference = $script:PreviousErrorAction
    }
}
