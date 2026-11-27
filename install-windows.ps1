#Requires -Version 5.1
# Remax Secure Printer - Windows installer 1.2.12
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
#             x64 (Setup.exe file version 30.0.0.1). If that driver is missing,
#             the script downloads Canon-PS3-v30.00-x64.zip from the public
#             GitHub release, checks SHA256, and installs x64/Driver/CNS30UA64.INF
#             with pnputil /add-driver and Add-PrinterDriver. REMAX_CANON_PKG_URL
#             replaces that URL. Canon Driver Information Assist Service is not
#             required.
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
#   confirmed. The primary Device Settings path is a PrintUI /Sr restore of
#   the published remaxsecure-device-settings.dat (d g r). UI clicks for
#   Cassette Feeding Unit and Output Options run only if that restore fails
#   or the readback shows them unset. The print username is applied after
#   the restore so it replaces the name stored in the file.

$script:Version = '1.2.12'
$script:IngestUrl = 'https://tickets.rmxofficetools.com/api/public/printer-installs'
$script:IngestKey = '7ff1e139019beaf03fbacc4dfcd4c3c78b87cb6fb991923e'
$script:CanonPkgUrl = 'https://github.com/ItsErod/canon-secure-print/releases/download/driver-v30/Canon-PS3-v30.00-x64.zip'
$script:CanonPkgSha256 = '4db0d69d0b6417c39ed285698f9dc23dc5a90c6e3372c8f04da68b1d19b678da'
$script:CanonPkgBytes = 26722033
$script:DeviceDatUrl = 'https://github.com/ItsErod/canon-secure-print/releases/download/driver-v30/remaxsecure-device-settings.dat'
$script:DeviceDatSha256 = 'a206124cad61263c4843a560765a389da3cb2d3ddb70011abbbbf54499f96279'
$script:DeviceDatBytes = 44692
$script:ExportedPrintUser = 'tsiogase'
$script:CanonInfLeaf = 'CNS30UA64.INF'
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
    if ($script:CaptureReport -and $script:ReportLines) {
        [void]$script:ReportLines.Add($Line)
    }
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
    if (-not $script:ReportSent -and ($script:Mode -eq 'install' -or $script:Mode -eq 'verify')) {
        $script:ReportSent = $true
        try { Send-RemaxInstallReport -ExitCode $Code } catch {
            Write-RemaxLine ("REPORTED:     FAIL  " + $_.Exception.Message)
        }
    }
    $global:RemaxExitCode = $Code
    $global:LASTEXITCODE = $Code
    if (-not $script:RanAsFile) {
        $ErrorActionPreference = $script:PreviousErrorAction
    }
    if ($script:Completing) {
        if ($script:RanAsFile) { exit $Code }
        return
    }
    $script:Completing = $true
    if ($script:RanAsFile) { exit $Code }
    $finish = Get-IexFinishMessage $Code
    if ($finish) { Write-RemaxLine $finish }
}

function Get-IexFinishMessage {
    param([int]$Code)
    if ($Code -eq 0) { return '' }
    if ($Code -eq 2) {
        return 'Exit code 2 (RESULT PARTIAL). MANUAL lines were not verified. The queue install is not a failure, and this window stays open.'
    }
    return 'Exit code 1 (RESULT FAIL). The report above is the result. This window stays open.'
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
                         When unset, the built-in Canon-PS3-v30.00-x64.zip
                         release is downloaded and its SHA256 is checked.
                         A Canon setup .exe is not launched.
  REMAX_PRINTER_URI      Default lpd://172.16.105.21/RemaxSecure
                         The Standard TCP/IP port is named after the host.
  REMAX_LPR_BYTE_COUNT   Default on. Set to 0 to disable LPR byte counting.
  REMAX_MODE             Set to verify for irm | iex read-only mode.
  REMAX_DEVICE_UI        Set to 0 to skip Printer properties automation.
  REMAX_DEVICE_DAT       Optional PrintUI file. A local path or an https URL.
                         When unset, the built-in remaxsecure-device-settings.dat
                         release is downloaded and its size and SHA256 are
                         checked. Restored with /Sr d g r before the username.
  REMAX_SKIP_CLEANUP     Set to 1 to keep an existing queue, port, and driver.
  REMAX_SKIP_FIREWALL    Set to 1 to skip the firewall rule and AV note.
  REMAX_PS_OUTPUT        Optional PS Output from Application value.
                         Unset leaves that combo unchanged.
  REMAX_NO_INPUT_LOCK    Set to 1 to leave the keyboard and mouse unlocked.
  REMAX_NO_REPORT        Set to 1 to skip the install report upload.
  REMAX_INGEST_KEY       Overrides the built-in install report key.

Exit codes: 0 every line PASS, 2 queue installed and MANUAL lines remain, 1 failed.
Exit code 1 and exit code 2 do not throw when the script is run with irm | iex.
LASTEXITCODE is set to that code and the window stays open.
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
        if ($state -eq 'MANUAL' -or $state -eq 'PARTIAL') { $sawManual = $true }
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

function Test-VersionAtLeast {
    param([string]$Have, [string]$Want)
    if ([string]::IsNullOrWhiteSpace($Have)) { return $false }
    if ([string]::IsNullOrWhiteSpace($Want)) { return $true }
    $a = @($Have.Split('.'))
    $b = @($Want.Split('.'))
    $n = $a.Count
    if ($b.Count -gt $n) { $n = $b.Count }
    for ($i = 0; $i -lt $n; $i++) {
        $av = 0
        $bv = 0
        if ($i -lt $a.Count) { [void][int]::TryParse([string]$a[$i], [ref]$av) }
        if ($i -lt $b.Count) { [void][int]::TryParse([string]$b[$i], [ref]$bv) }
        if ($av -gt $bv) { return $true }
        if ($av -lt $bv) { return $false }
    }
    return $true
}

function Get-ScriptVersionFromText {
    param([string]$Text)
    if ($Text -match '\$script:Version\s*=\s*''([^'']+)''') { return [string]$Matches[1] }
    return ''
}

function Get-MainCommitSha {
    $sha = ''
    try {
        $request = [System.Net.HttpWebRequest]::Create('https://api.github.com/repos/ItsErod/canon-secure-print/commits/main')
        $request.Method = 'GET'
        $request.Accept = 'application/vnd.github.sha'
        $request.UserAgent = 'RemaxSecurePrinter'
        $request.Timeout = 10000
        $request.Headers.Add('Cache-Control', 'no-cache')
        $request.Headers.Add('Pragma', 'no-cache')
        $response = $request.GetResponse()
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
        try { $sha = $reader.ReadToEnd().Trim() } finally {
            $reader.Close()
            $response.Close()
        }
    } catch {
        return ''
    }
    if ($sha -match '^[0-9a-fA-F]{40}$') { return $sha.ToLowerInvariant() }
    return ''
}

function Get-ElevatedScriptUrl {
    param([string]$CommitSha)
    if ($CommitSha -match '^[0-9a-fA-F]{40}$') {
        return 'https://raw.githubusercontent.com/ItsErod/canon-secure-print/' + $CommitSha.ToLowerInvariant() + '/install-windows.ps1'
    }
    $nonce = [guid]::NewGuid().ToString('n')
    return $script:RawUrl + '?nocache=' + $nonce
}

function Get-ElevatedDownloadScript {
    param([string]$ScriptUrl, [string]$LaunchVersion)
    $safeUrl = ([string]$ScriptUrl).Replace("'", "''")
    $safeVer = ([string]$LaunchVersion).Replace("'", "''")
    $body = @'
$launchVersion = '__VER__'
$url = '__URL__'
$req = [System.Net.HttpWebRequest]::Create($url)
$req.Method = 'GET'
$req.UserAgent = 'RemaxSecurePrinter'
$req.Timeout = 60000
$req.Headers.Add('Cache-Control', 'no-cache')
$req.Headers.Add('Pragma', 'no-cache')
$resp = $req.GetResponse()
$reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
$text = $reader.ReadToEnd()
$reader.Close()
$resp.Close()
$got = ''
if ($text -match '\$script:Version\s*=\s*''([^'']+)''') { $got = $Matches[1] }
$older = $false
if ($got) {
    $a = @($got.Split('.'))
    $b = @($launchVersion.Split('.'))
    $n = $a.Count
    if ($b.Count -gt $n) { $n = $b.Count }
    for ($i = 0; $i -lt $n; $i++) {
        $av = 0
        $bv = 0
        if ($i -lt $a.Count) { [void][int]::TryParse($a[$i], [ref]$av) }
        if ($i -lt $b.Count) { [void][int]::TryParse($b[$i], [ref]$bv) }
        if ($av -lt $bv) { $older = $true; break }
        if ($av -gt $bv) { break }
    }
}
if ($older) {
    Write-Host ('Warning: downloaded installer ' + $got + ' is older than launcher ' + $launchVersion + '. The elevated window may still be running a stale script.')
}
Invoke-Expression $text
'@
    return $body.Replace('__VER__', $safeVer).Replace('__URL__', $safeUrl)
}

function Get-ElevatedInstallCommand {
    param([string]$ScriptUrl)
    if ([string]::IsNullOrWhiteSpace($ScriptUrl)) { $ScriptUrl = Get-ElevatedScriptUrl -CommitSha '' }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($item in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'REMAX_*' })) {
        if ($item.Name -eq 'REMAX_LAUNCH_VERSION') { continue }
        $value = ([string]$item.Value).Replace("'", "''")
        [void]$lines.Add('$' + 'env:' + $item.Name + " = '" + $value + "'")
    }
    if ($script:Mode -eq 'verify' -and -not $env:REMAX_MODE) {
        [void]$lines.Add('$' + "env:REMAX_MODE = 'verify'")
    }
    $safeVersion = ([string]$script:Version).Replace("'", "''")
    [void]$lines.Add('$' + "env:REMAX_LAUNCH_VERSION = '" + $safeVersion + "'")
    [void]$lines.Add((Get-ElevatedDownloadScript -ScriptUrl $ScriptUrl -LaunchVersion $script:Version))
    return ($lines -join "`r`n")
}

function Write-StaleLaunchWarning {
    $want = [string]$env:REMAX_LAUNCH_VERSION
    if ([string]::IsNullOrWhiteSpace($want)) { return }
    if (Test-VersionAtLeast -Have $script:Version -Want $want) { return }
    Write-RemaxLine ("Warning: this installer is " + $script:Version + ", older than the launcher " + $want + ". The elevated window may still be running a stale script.")
}

function Start-RemaxElevatedRelaunch {
    if (-not (Test-WindowsHost)) { return $false }
    if ($script:Mode -eq 'selftest' -or $script:Mode -eq 'help' -or $script:Mode -eq 'usage-error') { return $false }
    if (Test-RemaxAdmin) { return $false }
    $sha = Get-MainCommitSha
    $url = Get-ElevatedScriptUrl -CommitSha $sha
    if ($sha) {
        Write-RemaxLine ("Elevated install will download main at " + $sha)
    } else {
        Write-RemaxLine "Could not resolve main. Elevated install will download main with a cache buster."
    }
    $command = Get-ElevatedInstallCommand -ScriptUrl $url
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($command)
    $encoded = [Convert]::ToBase64String($bytes)
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershell)) { $powershell = 'powershell.exe' }
    $arg = '-NoExit -NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
    try {
        Start-Process -FilePath $powershell -Verb RunAs -ArgumentList $arg | Out-Null
    } catch {
        Write-RemaxLine "Elevation was declined. This installer needs an administrator PowerShell window. No changes were made."
        exit 1
    }
    Write-RemaxLine "An elevated PowerShell window is opening. Finish the install there. This window will close."
    exit 0
}

function Test-SkipInstallReport {
    return ($env:REMAX_NO_REPORT -eq '1')
}

function Get-ReportTail {
    param([string]$Text, [int]$MaxBytes)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($MaxBytes -lt 1) { return '' }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    if ($bytes.Length -le $MaxBytes) { return $Text }
    $start = $bytes.Length - $MaxBytes
    return [System.Text.Encoding]::UTF8.GetString($bytes, $start, $MaxBytes)
}

function Get-RemaxOsCaption {
    $caption = ''
    $display = ''
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        if ($os) { $caption = [string]$os.Caption }
    } catch { }
    $caption = $caption -replace '^Microsoft ', ''
    try {
        $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        if ($cv.DisplayVersion) { $display = [string]$cv.DisplayVersion }
    } catch { }
    if ($display) { return ($caption.Trim() + ' ' + $display).Trim() }
    return $caption.Trim()
}

function Get-PrimaryAdapter {
    $ip = ''
    $mac = ''
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object -Property RouteMetric | Select-Object -First 1
        if ($route) {
            $addr = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -and $_.IPAddress -notlike '127.*' } |
                Select-Object -First 1
            if ($addr) { $ip = [string]$addr.IPAddress }
            $nic = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction Stop
            if ($nic -and $nic.MacAddress) { $mac = [string]$nic.MacAddress }
        }
    } catch { }
    if (-not $ip) {
        try {
            $cfg = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True')
            foreach ($row in @($cfg)) {
                foreach ($candidate in @($row.IPAddress)) {
                    $text = [string]$candidate
                    if ($text -match '^\d+\.\d+\.\d+\.\d+$' -and $text -notlike '127.*') {
                        $ip = $text
                        $mac = [string]$row.MACAddress
                        break
                    }
                }
                if ($ip) { break }
            }
        } catch { }
    }
    return @{ Ip = $ip; Mac = $mac }
}

function Get-RemaxReportNetwork {
    try {
        $status = Get-RemaxNetworkStatus
        if ($status -and $status.OnRemax) { return 'REMAX' }
    } catch { }
    return 'OTHER'
}

function Send-RemaxInstallReport {
    param([int]$ExitCode)
    if (Test-SkipInstallReport) {
        Write-RemaxLine 'REPORTED:     SKIP  REMAX_NO_REPORT=1'
        return
    }
    $key = $script:IngestKey
    if (-not [string]::IsNullOrWhiteSpace($env:REMAX_INGEST_KEY)) { $key = $env:REMAX_INGEST_KEY.Trim() }
    $result = [string]$script:LastResult
    if (-not $result) {
        if ($ExitCode -eq 0) { $result = 'PASS' }
        elseif ($ExitCode -eq 2) { $result = 'PARTIAL' }
        else { $result = 'FAIL' }
    }
    $steps = New-Object PSObject
    foreach ($label in @(Get-StatusLabels)) {
        $state = 'not checked'
        if ($script:LastStatus -and $script:LastStatus.ContainsKey($label)) {
            $state = [string]$script:LastStatus[$label].State
        }
        $steps | Add-Member -NotePropertyName $label -NotePropertyValue $state -Force
    }
    $adapter = Get-PrimaryAdapter
    $osUser = ''
    try { $osUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { $osUser = [string]$env:USERNAME }
    $logText = ''
    if ($script:LogFile -and (Test-Path -LiteralPath $script:LogFile)) {
        try { $logText = [System.IO.File]::ReadAllText($script:LogFile) } catch { $logText = '' }
    }
    $logText = Get-ReportTail -Text $logText -MaxBytes 409600
    $body = @{
        print_username = [string]$script:LastPrintUser
        computer_name  = [string]$env:COMPUTERNAME
        os              = (Get-RemaxOsCaption)
        overall_result  = $result
        steps           = $steps
        os_user         = $osUser
        ip_address      = [string]$adapter.Ip
        mac_address     = [string]$adapter.Mac
        network         = (Get-RemaxReportNetwork)
        script_version  = [string]$script:Version
        report_text     = [string]$script:ReportText
        log_text        = $logText
    }
    $json = $body | ConvertTo-Json -Depth 6 -Compress
    $payload = [System.Text.Encoding]::UTF8.GetBytes($json)
    $status = 0
    $detail = ''
    try {
        $request = [System.Net.HttpWebRequest]::Create($script:IngestUrl)
        $request.Method = 'POST'
        $request.ContentType = 'application/json; charset=utf-8'
        $request.Timeout = 10000
        $request.ReadWriteTimeout = 10000
        $request.Headers.Add('Authorization', 'Bearer ' + $key)
        $request.ContentLength = $payload.Length
        $stream = $request.GetRequestStream()
        try { $stream.Write($payload, 0, $payload.Length) } finally { $stream.Close() }
        $response = $request.GetResponse()
        try { $status = [int]$response.StatusCode } finally { $response.Close() }
    } catch {
        $web = $_.Exception
        if ($web.Response) {
            try { $status = [int]$web.Response.StatusCode } catch { $status = 0 }
            try { $web.Response.Close() } catch { }
        }
        $detail = $_.Exception.Message
    }
    Write-Remax ("Install report HTTP status " + $status)
    if ($detail) { Write-Remax ("Install report error: " + $detail) }
    if ($status -eq 201) {
        Write-RemaxLine 'REPORTED:     PASS'
    } else {
        $suffix = ''
        if ($status -gt 0) { $suffix = ' HTTP ' + $status }
        Write-RemaxLine ('REPORTED:     FAIL' + $suffix)
    }
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

function Get-CanonInfPickScore {
    param([string]$Path, [string]$Model)
    $rank = Get-DriverRank $Model
    if ($rank -lt 1) { return -1 }
    $norm = ''
    if ($Path) { $norm = $Path.Replace('/', '\') }
    if ($norm -match '(?i)NullDriver|lasernull') { return -1 }
    $score = ($rank * 1000) + (Get-InfArchitectureScore $Path)
    $leaf = [string]$Path
    $slash = $leaf.LastIndexOf('\')
    $fwd = $leaf.LastIndexOf('/')
    $cut = $slash
    if ($fwd -gt $cut) { $cut = $fwd }
    if ($cut -ge 0 -and $cut -lt ($leaf.Length - 1)) {
        $leaf = $leaf.Substring($cut + 1)
    }
    if ($leaf -and ($leaf.ToLowerInvariant() -eq $script:CanonInfLeaf.ToLowerInvariant())) {
        $score = $score + 500
    }
    return $score
}

function Format-Sha256Bytes {
    param([byte[]]$Bytes)
    $builder = New-Object System.Text.StringBuilder
    foreach ($b in @($Bytes)) {
        [void]$builder.Append($b.ToString('x2'))
    }
    return $builder.ToString()
}

function Get-BytesSha256 {
    param([byte[]]$Data)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (Format-Sha256Bytes ($sha.ComputeHash($Data)))
    } finally {
        $sha.Dispose()
    }
}

function Get-FileSha256 {
    param([string]$Path)
    $sha = $null
    $stream = $null
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        return (Format-Sha256Bytes ($sha.ComputeHash($stream)))
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($sha) { $sha.Dispose() }
    }
}

function Resolve-CanonPackageUrl {
    if (-not [string]::IsNullOrWhiteSpace($env:REMAX_CANON_PKG_URL)) {
        return $env:REMAX_CANON_PKG_URL.Trim()
    }
    return $script:CanonPkgUrl
}

function Test-PinnedCanonDownload {
    param([string]$Url, [string]$Hash, [long]$Length)
    if ($Url -ne $script:CanonPkgUrl) {
        return @{
            Ok     = $true
            Pinned = $false
            Detail = 'REMAX_CANON_PKG_URL is not the built-in package, so the pinned SHA256 is not applied.'
        }
    }
    $problems = New-Object System.Collections.Generic.List[string]
    if ($Length -ne [long]$script:CanonPkgBytes) {
        [void]$problems.Add("size " + $Length + " (expected " + $script:CanonPkgBytes + ")")
    }
    $got = ''
    if ($Hash) { $got = $Hash.Trim().ToLowerInvariant() }
    if ($got -ne $script:CanonPkgSha256) {
        [void]$problems.Add("SHA256 " + $got + " (expected " + $script:CanonPkgSha256 + ")")
    }
    if ($problems.Count -gt 0) {
        $detail = "Canon driver download failed verification for " + $Url + ". " + ($problems -join '. ') + ". The file was not installed."
        return @{ Ok = $false; Pinned = $true; Detail = $detail }
    }
    return @{ Ok = $true; Pinned = $true; Detail = ("SHA256 " + $script:CanonPkgSha256) }
}

function Get-PackageKindFromLeaf {
    param([string]$Leaf)
    if ([string]::IsNullOrWhiteSpace($Leaf)) { return '' }
    $lower = $Leaf.ToLowerInvariant()
    if ($lower.EndsWith('.zip')) { return 'zip' }
    if ($lower.EndsWith('.cab')) { return 'cab' }
    if ($lower.EndsWith('.inf')) { return 'inf' }
    if ($lower.EndsWith('.exe')) { return 'exe' }
    return ''
}

function Get-ArchiveKindFromHeader {
    param([byte[]]$Header)
    if ($null -eq $Header -or $Header.Length -lt 2) { return '' }
    if ($Header[0] -eq 0x50 -and $Header[1] -eq 0x4B) { return 'zip' }
    if ($Header.Length -ge 4 -and $Header[0] -eq 0x4D -and $Header[1] -eq 0x53 -and $Header[2] -eq 0x43 -and $Header[3] -eq 0x46) {
        return 'cab'
    }
    if ($Header[0] -eq 0x4D -and $Header[1] -eq 0x5A) { return 'exe' }
    return ''
}

function Resolve-PackageKind {
    param([string]$Leaf, [byte[]]$Header)
    $fromHeader = Get-ArchiveKindFromHeader $Header
    if ($fromHeader -eq 'zip') { return 'zip' }
    $fromName = Get-PackageKindFromLeaf $Leaf
    if ($fromName) { return $fromName }
    if ($fromHeader) { return $fromHeader }
    return ''
}

function Get-DownloadFileName {
    param([string]$Url, [string]$Kind)
    if (-not $Kind) {
        $leaf = ''
        try {
            $leaf = [System.IO.Path]::GetFileName(([Uri]$Url).AbsolutePath)
        } catch {
            $leaf = ''
        }
        $Kind = Get-PackageKindFromLeaf $leaf
    }
    if (-not $Kind) { return '' }
    return ('download.' + $Kind)
}

function Read-FileHeader {
    param([string]$Path, [int]$Count)
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $buf = New-Object byte[] $Count
        $read = $stream.Read($buf, 0, $Count)
        if ($read -le 0) { return , (New-Object byte[] 0) }
        if ($read -lt $Count) {
            $short = New-Object byte[] $read
            [System.Array]::Copy($buf, $short, $read)
            return , $short
        }
        return , $buf
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Move-DownloadToKind {
    param([string]$Path, [string]$Kind)
    $name = Get-DownloadFileName -Kind $Kind
    if (-not $name) { return $Path }
    $dest = Join-Path (Split-Path -Parent $Path) $name
    if ($dest -eq $Path) { return $Path }
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Force
    }
    Move-Item -LiteralPath $Path -Destination $dest -Force
    return $dest
}

function Expand-RemaxZip {
    param([string]$ZipPath, [string]$Destination)
    $named = Move-DownloadToKind -Path $ZipPath -Kind 'zip'
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    $loaded = $false
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $loaded = $true
    } catch {
        $loaded = $false
    }
    if ($loaded) {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($named, $Destination)
        return
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Expand-Archive -LiteralPath $named -DestinationPath $Destination -Force
}

function Save-RemaxDownload {
    param([string]$Url, [string]$Destination)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch {
    }
    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -MaximumRedirection 5
    } finally {
        $ProgressPreference = $previousProgress
    }
}

function ConvertTo-ExitCode {
    param($Value)
    $last = $null
    foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }
        $parsed = 0
        $isNumber = $false
        if ($item -is [byte] -or $item -is [int] -or $item -is [long] -or $item -is [decimal]) {
            $parsed = [int]$item
            $isNumber = $true
        } else {
            $text = [string]$item
            $isNumber = [int]::TryParse($text, [ref]$parsed)
        }
        if ($isNumber) { $last = [int]$parsed }
    }
    if ($null -eq $last) { return 1 }
    return [int]$last
}

function Invoke-LoggedProcess {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList
    )
    $shown = $FilePath
    if ($ArgumentList -and $ArgumentList.Count -gt 0) {
        $shown = $shown + ' ' + ($ArgumentList -join ' ')
    }
    Write-Remax $shown
    $lines = New-Object System.Collections.Generic.List[string]
    $code = 1
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $FilePath @ArgumentList 2>&1)
        if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }
        foreach ($item in @($output)) {
            if ($null -eq $item) { continue }
            $text = [string]$item
            [void]$lines.Add($text)
            Write-Remax $text
        }
    } catch {
        $text = $_.Exception.Message
        [void]$lines.Add($text)
        Write-Remax $text
        $code = 1
    } finally {
        $ErrorActionPreference = $previous
    }
    Write-Remax ("Exit code " + $code)
    $result = @{
        Code  = [int]$code
        Lines = @($lines.ToArray())
    }
    return , $result
}

function Test-PnputilSuccess {
    param($Code)
    $n = ConvertTo-ExitCode $Code
    if ($n -eq 0) { return $true }
    if ($n -eq 259) { return $true }
    if ($n -eq 3010) { return $true }
    return $false
}

function Get-PnputilPublishedName {
    param([string[]]$Lines)
    foreach ($line in @($Lines)) {
        if ([string]$line -match '(?i)Published Name:\s*(oem\d+\.inf)') {
            return $Matches[1]
        }
    }
    return ''
}

function Get-InfExactModel {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $want = $script:ExactDriverName
    $fallback = ''
    $normalized = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    foreach ($raw in ($normalized -split "`n")) {
        $line = (Remove-InfComment $raw).Trim()
        if ($line -notmatch '^"([^"]*)"\s*=') { continue }
        $model = $Matches[1]
        if ($model -ceq $want) { return $model }
        if ($model -match 'C5235' -and $model -match '5240' -and $model -match 'PS3') {
            if (-not $fallback) { $fallback = $model }
        }
    }
    return $fallback
}

function Get-PathLeafAny {
    param([string]$Path)
    $leaf = [string]$Path
    $slash = $leaf.LastIndexOf('\')
    $fwd = $leaf.LastIndexOf('/')
    $cut = $slash
    if ($fwd -gt $cut) { $cut = $fwd }
    if ($cut -ge 0 -and $cut -lt ($leaf.Length - 1)) {
        return $leaf.Substring($cut + 1)
    }
    return $leaf
}

function Find-DriverStoreInf {
    param([string]$PublishedName, [string]$Leaf)
    $leaf = $Leaf
    if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = $script:CanonInfLeaf }
    $leafLower = $leaf.ToLowerInvariant()
    try {
        $drivers = @(Get-WindowsDriver -Online -ErrorAction Stop)
        foreach ($driver in $drivers) {
            $published = ''
            $original = ''
            try { $published = [string]$driver.Driver } catch { $published = '' }
            try { $original = [string]$driver.OriginalFileName } catch { $original = '' }
            $nameHit = $false
            if ($PublishedName -and $published -and ($published -eq $PublishedName)) { $nameHit = $true }
            $leafHit = $false
            if ($original -and ((Get-PathLeafAny $original).ToLowerInvariant() -eq $leafLower)) { $leafHit = $true }
            if (($nameHit -or $leafHit) -and $original -and (Test-Path -LiteralPath $original)) {
                Write-Remax ("Driver store INF from Get-WindowsDriver: " + $original)
                return $original
            }
        }
    } catch {
        Write-Remax ("Get-WindowsDriver was not available: " + $_.Exception.Message)
    }
    try {
        $signed = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop)
        foreach ($item in $signed) {
            $infName = ''
            try { $infName = [string]$item.InfName } catch { $infName = '' }
            if ($PublishedName -and $infName -eq $PublishedName) {
                Write-Remax ("Win32_PnPSignedDriver lists " + $infName + " (" + [string]$item.DeviceName + ")")
            }
        }
    } catch {
        Write-Remax ("Win32_PnPSignedDriver was not available: " + $_.Exception.Message)
    }
    $root = Join-Path $env:windir 'System32\DriverStore\FileRepository'
    if (-not (Test-Path -LiteralPath $root)) {
        Write-Remax ("Driver store was not found: " + $root)
        return ''
    }
    $dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like 'cns30ua64.inf_amd64_*'
        })
    foreach ($dir in $dirs) {
        $files = @(Get-ChildItem -LiteralPath $dir.FullName -File -ErrorAction SilentlyContinue | Where-Object {
                $_.Name.ToLowerInvariant() -eq $leafLower
            })
        if ($files.Count -gt 0) {
            Write-Remax ("Driver store INF from FileRepository: " + $files[0].FullName)
            return [string]$files[0].FullName
        }
    }
    Write-Remax ("No " + $leaf + " under " + $root + "\cns30ua64.inf_amd64_*")
    return ''
}

function Test-PrinterDriverPresent {
    param([string]$Name)
    try {
        $rows = @(Get-PrinterDriver -Name $Name -ErrorAction Stop)
        foreach ($row in $rows) {
            if ([string]$row.Name -eq $Name) { return $true }
        }
    } catch { }
    return $false
}

function Get-PrintUiExePath {
    $sixtyFourOs = $false
    $sixtyFourProc = $true
    try { $sixtyFourOs = [bool][Environment]::Is64BitOperatingSystem } catch { $sixtyFourOs = $false }
    try { $sixtyFourProc = [bool][Environment]::Is64BitProcess } catch { $sixtyFourProc = $true }
    if ($sixtyFourOs -and -not $sixtyFourProc) {
        $native = Join-Path $env:SystemRoot 'Sysnative\printui.exe'
        if (Test-Path -LiteralPath $native) { return $native }
    }
    $path = Join-Path $env:SystemRoot 'System32\printui.exe'
    if (Test-Path -LiteralPath $path) { return $path }
    return ''
}

function Register-CanonPrinterDriver {
    param(
        [string]$Model,
        [string]$StoreInf
    )
    Write-Remax ("Add-PrinterDriver -Name '" + $Model + "'")
    try {
        Add-PrinterDriver -Name $Model -ErrorAction Stop | Out-Null
        if (Test-PrinterDriverPresent $Model) {
            Write-Remax ("Registered " + $Model + " without InfPath.")
            return $true
        }
        Write-Remax "Add-PrinterDriver without InfPath did not list the driver."
    } catch {
        Write-Remax ("Add-PrinterDriver without InfPath failed: " + $_.Exception.Message)
    }
    if ([string]::IsNullOrWhiteSpace($StoreInf)) {
        Write-Remax "Driver store INF was not found. The temporary download INF is not passed to Add-PrinterDriver."
        return $false
    }
    Write-Remax ("Add-PrinterDriver -Name '" + $Model + "' -InfPath '" + $StoreInf + "'")
    try {
        Add-PrinterDriver -Name $Model -InfPath $StoreInf -ErrorAction Stop | Out-Null
        if (Test-PrinterDriverPresent $Model) {
            Write-Remax ("Registered " + $Model + " from the driver store INF.")
            return $true
        }
        Write-Remax "Add-PrinterDriver with the driver store INF did not list the driver."
    } catch {
        Write-Remax ("Add-PrinterDriver with the driver store INF failed: " + $_.Exception.Message)
    }
    $printui = Get-PrintUiExePath
    if ($printui) {
        $attempt = Invoke-LoggedProcess -FilePath $printui -ArgumentList @('/ia', '/m', $Model, '/f', $StoreInf)
        if (Test-PrinterDriverPresent $Model) {
            Write-Remax ("printui.exe /ia registered " + $Model)
            return $true
        }
        Write-Remax ("printui.exe /ia did not register " + $Model + " (exit " + $attempt.Code + ").")
    } else {
        Write-Remax "printui.exe was not found."
    }
    $rundll = Get-RemaxRundllPath
    $entry = 'printui.dll,PrintUIEntry /ia /m "' + $Model + '" /h x64 /v 3 /f "' + $StoreInf + '"'
    $fallback = Invoke-LoggedProcess -FilePath $rundll -ArgumentList @($entry)
    if (Test-PrinterDriverPresent $Model) {
        Write-Remax ("PrintUIEntry /ia registered " + $Model)
        return $true
    }
    Write-Remax ("PrintUIEntry /ia did not register " + $Model + " (exit " + $fallback.Code + ").")
    return $false
}

function Install-DriverFromInf {
    param(
        [string]$InfPath,
        [string]$Model
    )
    $model = $Model
    $text = ''
    try { $text = Read-AllText $InfPath } catch { $text = '' }
    if ($text) {
        $exact = Get-InfExactModel $text
        if ($exact -and ($exact -cne $model)) {
            Write-Remax ("INF model string is '" + $exact + "'. Using that instead of '" + $model + "'.")
            $model = $exact
        } elseif ($exact) {
            Write-Remax ("INF model string matches '" + $exact + "'.")
            $model = $exact
        }
    }
    $pnputil = Join-Path $env:windir 'System32\pnputil.exe'
    if (-not (Test-Path -LiteralPath $pnputil)) { $pnputil = 'pnputil.exe' }
    $added = Invoke-LoggedProcess -FilePath $pnputil -ArgumentList @('/add-driver', $InfPath, '/install')
    if (-not (Test-PnputilSuccess $added.Code)) {
        Write-Remax "pnputil /add-driver /install was not accepted. Trying pnputil -i -a."
        $added = Invoke-LoggedProcess -FilePath $pnputil -ArgumentList @('-i', '-a', $InfPath)
    }
    if (Test-PnputilSuccess $added.Code) {
        if ([int]$added.Code -eq 259) {
            Write-Remax "pnputil exit 259: the driver package is already present."
        } elseif ([int]$added.Code -eq 3010) {
            Write-Remax "pnputil exit 3010: the driver package was staged. A restart may be required."
        }
    } else {
        Write-Remax ("pnputil did not stage the driver (exit " + $added.Code + "). Still trying to register it from the driver store.")
    }
    $published = Get-PnputilPublishedName -Lines $added.Lines
    if ($published) {
        Write-Remax ("pnputil published name " + $published)
    } else {
        Write-Remax "pnputil output had no Published Name."
    }
    $leaf = Get-PathLeafAny $InfPath
    $store = Find-DriverStoreInf -PublishedName $published -Leaf $leaf
    if (-not $store) {
        $store = Find-DriverStoreInf -PublishedName $published -Leaf $script:CanonInfLeaf
    }
    $ok = Register-CanonPrinterDriver -Model $model -StoreInf $store
    if (-not $ok) {
        Write-Remax ("Could not register printer driver " + $model)
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
    $urlKind = Get-PackageKindFromLeaf $leaf
    if (-not $urlKind) {
        throw "REMAX_CANON_PKG_URL must end in .zip, .cab, .inf, or .exe. This script only extracts an INF. It does not run a Canon setup EXE unless 7-Zip can unpack it."
    }
    $work = Join-Path $env:TEMP ("remax-canon-" + [Guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $download = Join-Path $work (Get-DownloadFileName -Kind $urlKind)
        Write-Remax ("Downloading Canon driver package from " + $Url)
        Write-Remax ("Saving the download as " + (Split-Path -Leaf $download))
        Save-RemaxDownload -Url $Url -Destination $download
        $length = (Get-Item -LiteralPath $download).Length
        if ($length -gt 250MB) {
            throw "Downloaded file is larger than 250 MB. Refusing to continue."
        }
        if ($length -lt 64) {
            throw "Downloaded file is too small to be a Canon driver package."
        }
        $hash = Get-FileSha256 $download
        $check = Test-PinnedCanonDownload -Url $Url -Hash $hash -Length ([long]$length)
        if (-not $check.Ok) {
            throw [string]$check.Detail
        }
        Write-Remax ([string]$check.Detail)
        $header = Read-FileHeader -Path $download -Count 4
        $kind = Resolve-PackageKind -Leaf $leaf -Header $header
        if (-not $kind) {
            throw "Downloaded file is not a .zip, .cab, .inf, or .exe."
        }
        if ($kind -ne $urlKind) {
            Write-Remax ("Download contents are " + $kind + ", not " + $urlKind + ". Using " + $kind + ".")
            $download = Move-DownloadToKind -Path $download -Kind $kind
        }
        $extract = Join-Path $work 'extract'
        New-Item -ItemType Directory -Path $extract -Force | Out-Null
        if ($kind -eq 'inf') {
            Copy-Item -LiteralPath $download -Destination (Join-Path $extract $leaf) -Force
        } elseif ($kind -eq 'zip') {
            Expand-RemaxZip -ZipPath $download -Destination $extract
        } elseif ($kind -eq 'cab') {
            $expanded = Invoke-LoggedProcess -FilePath 'expand.exe' -ArgumentList @($download, '-F:*', $extract)
            if ([int]$expanded.Code -ne 0) { throw ("expand.exe could not unpack the cab (exit " + $expanded.Code + ").") }
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
            $unpacked = Invoke-LoggedProcess -FilePath $seven -ArgumentList @('x', '-y', ('-o' + $extract), $download)
            if ([int]$unpacked.Code -ne 0) {
                throw "7-Zip could not unpack the EXE. Point REMAX_CANON_PKG_URL at a .zip of the extracted Driver folder."
            }
        }
        $bestInf = $null
        $bestModel = $null
        $bestScore = -1
        $arch = Get-DriverArchitecture
        foreach ($inf in @(Get-ChildItem -LiteralPath $extract -Filter *.inf -Recurse -File -ErrorAction SilentlyContinue)) {
            $models = @(Get-InfDriverModels -Text (Read-AllText $inf.FullName) -Architecture $arch)
            $choice = Select-BestDriverName -Names $models
            $score = Get-CanonInfPickScore -Path $inf.FullName -Model $choice
            Write-Remax ("INF " + $inf.FullName + " selected model '" + $choice + "' score " + $score)
            if ($score -gt $bestScore) {
                $bestScore = $score
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
    $bestScore = -1
    foreach ($dir in $dirs) {
        foreach ($inf in @(Get-ChildItem -LiteralPath $dir.FullName -Filter *.inf -Recurse -File -ErrorAction SilentlyContinue)) {
            $text = ''
            try { $text = Read-AllText $inf.FullName } catch { continue }
            if ($text -notmatch 'C5235' -and $text -notmatch 'Generic Plus PS3') { continue }
            if ($inf.FullName -match '(?i)NullDriver|lasernull') { continue }
            $models = @(Get-InfDriverModels -Text $text -Architecture $arch)
            $choice = Select-BestDriverName -Names $models
            $score = Get-CanonInfPickScore -Path $inf.FullName -Model $choice
            if ($score -gt $bestScore) {
                $bestScore = $score
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

The installer already tried the built-in package when REMAX_CANON_PKG_URL
was not set:

  $script:CanonPkgUrl
  SHA256 $script:CanonPkgSha256
  $script:CanonPkgBytes bytes

That zip's printer driver is x64\Driver\$script:CanonInfLeaf. It is installed
with pnputil /add-driver and Add-PrinterDriver -Name '$script:ExactDriverName'.
The zip also contains x64\misc\NullDriver\lasernull.inf. That USB null driver
is not installed.
Canon Driver Information Assist Service is not required. If the package
installs it, that is fine. This script does not start or install that service.
Do not use the UFR II or PCL driver for this queue.
The Mac PPD CNMCIRAC5235S2.ppd.gz is not a Windows driver package.

If that download failed, fix the network or set REMAX_CANON_PKG_URL to an
https URL ending in .zip, .cab, or .inf. A Canon setup .exe is not launched.
If 7-Zip is installed, an .exe URL is unpacked and the x64 INF inside is
added with pnputil.

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
    New-ItemProperty -LiteralPath $path -Name 'HostName' -PropertyType String -Value $Target.Host -Force | Out-Null
    New-ItemProperty -LiteralPath $path -Name 'IPAddress' -PropertyType String -Value $Target.Host -Force | Out-Null
    New-ItemProperty -LiteralPath $path -Name 'PortNumber' -PropertyType DWord -Value 515 -Force | Out-Null
    return $true
}

function Get-WritablePortPropertyNames {
    return @('Queue', 'Protocol', 'ByteCount', 'SNMPEnabled')
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
    $byteKnown = $false
    $snmp = $false
    $snmpKnown = $false
    if ($port) {
        $hostName = [string]$port.HostAddress
        $queue = [string]$port.Queue
        $protocol = [int]$port.Protocol
        $portNumber = [int]$port.PortNumber
        if ($port.PSObject.Properties.Name -contains 'ByteCount' -and $null -ne $port.ByteCount) {
            $byteCount = (ConvertTo-FlagEnabled $port.ByteCount)
            $byteKnown = $true
        }
        if ($port.PSObject.Properties.Name -contains 'SNMPEnabled' -and $null -ne $port.SNMPEnabled) {
            $snmp = (ConvertTo-FlagEnabled $port.SNMPEnabled)
            $snmpKnown = $true
        }
    }
    if ($cmdlet) {
        if (-not $hostName -and $cmdlet.PrinterHostAddress) { $hostName = [string]$cmdlet.PrinterHostAddress }
        if ($cmdlet.PSObject.Properties.Name -contains 'SNMPEnabled' -and $null -ne $cmdlet.SNMPEnabled) {
            $snmp = (ConvertTo-FlagEnabled $cmdlet.SNMPEnabled)
            $snmpKnown = $true
        }
    }
    if ($registry) {
        if ($null -ne $registry.Queue -and $registry.Queue -ne '') { $queue = [string]$registry.Queue }
        if ($null -ne $registry.Protocol) { $protocol = [int]$registry.Protocol }
        if ($null -ne $registry.ByteCount) {
            $byteCount = ([int]$registry.ByteCount -ne 0)
            $byteKnown = $true
        }
        if ($null -ne $registry.Snmp) {
            $snmp = ([int]$registry.Snmp -ne 0)
            $snmpKnown = $true
        }
    }
    return @{
        Name            = $Name
        Host            = $hostName
        Queue           = $queue
        Protocol        = $protocol
        PortNumber      = $portNumber
        ByteCount       = $byteCount
        ByteCountKnown  = $byteKnown
        SnmpEnabled     = $snmp
        SnmpKnown       = $snmpKnown
        Cim             = $port
        Registry        = $registry
        Cmdlet          = $cmdlet
    }
}

function ConvertTo-FlagEnabled {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return [bool]$Value }
    $text = ([string]$Value).Trim()
    $lower = $text.ToLowerInvariant()
    if ($lower -eq '' -or $lower -eq '0' -or $lower -eq 'false' -or $lower -eq 'off' -or $lower -eq 'no') { return $false }
    if ($lower -eq '1' -or $lower -eq 'true' -or $lower -eq 'on' -or $lower -eq 'yes') { return $true }
    $parsed = 0
    if ([int]::TryParse($text, [ref]$parsed)) { return ($parsed -ne 0) }
    return $false
}

function Test-PortMatches {
    param($Snapshot, $Target)
    if (-not $Snapshot) { return $false }
    if ($Snapshot.Name -and $Target.PortName -and $Snapshot.Name -ne $Target.PortName -and $Snapshot.Name -ne $script:PortName) { return $false }
    if ($Snapshot.Host -ne $Target.Host) { return $false }
    if ($Snapshot.Queue -ne $Target.Queue) { return $false }
    if ([int]$Snapshot.Protocol -ne 2) { return $false }
    if ($Snapshot.PortNumber -and [int]$Snapshot.PortNumber -ne 0 -and [int]$Snapshot.PortNumber -ne 515) { return $false }
    if ($Snapshot.ByteCountKnown -and ((ConvertTo-FlagEnabled $Snapshot.ByteCount) -ne [bool]$Target.ByteCount)) { return $false }
    if ($Snapshot.SnmpKnown -and (ConvertTo-FlagEnabled $Snapshot.SnmpEnabled)) { return $false }
    if ($Snapshot.Registry) {
        if ($null -ne $Snapshot.Registry.Protocol -and [int]$Snapshot.Registry.Protocol -ne 2) { return $false }
        if ($null -ne $Snapshot.Registry.Queue -and [string]$Snapshot.Registry.Queue -ne '' -and [string]$Snapshot.Registry.Queue -ne [string]$Target.Queue) { return $false }
        if ($null -ne $Snapshot.Registry.ByteCount) {
            $wantByte = 0
            if ($Target.ByteCount) { $wantByte = 1 }
            if ([int]$Snapshot.Registry.ByteCount -ne $wantByte) { return $false }
        }
        if ($null -ne $Snapshot.Registry.Snmp -and [int]$Snapshot.Registry.Snmp -ne 0) { return $false }
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
        $present = @($port.PSObject.Properties.Name)
        foreach ($prop in @(Get-WritablePortPropertyNames)) {
            if ($present -notcontains $prop) { continue }
            if ($prop -eq 'Queue') { $port.Queue = $Target.Queue }
            elseif ($prop -eq 'Protocol') { $port.Protocol = [uint32]2 }
            elseif ($prop -eq 'ByteCount') { $port.ByteCount = [bool]$Target.ByteCount }
            elseif ($prop -eq 'SNMPEnabled') { $port.SNMPEnabled = $false }
        }
        try {
            Set-CimInstance -InputObject $port | Out-Null
        } catch {
            Write-Remax ("CIM port update failed. HostAddress is left unchanged: " + $_.Exception.Message)
        }
    }
    $name = $script:PortName
    if ($Snapshot.Name) { $name = [string]$Snapshot.Name }
    try {
        [void](Set-PortRegistry -Name $name -Target $Target)
    } catch {
        Write-Remax ("Port registry update failed: " + $_.Exception.Message)
    }
}

function Add-LprPort {
    param($Target)
    $created = $false
    try {
        if ($Target.ByteCount) {
            Add-PrinterPort -Name $script:PortName -LprHostAddress $Target.Host -LprQueueName $Target.Queue -LprByteCounting | Out-Null
        } else {
            Add-PrinterPort -Name $script:PortName -LprHostAddress $Target.Host -LprQueueName $Target.Queue | Out-Null
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
    if (-not $vbs) {
        Write-Remax ("Could not create LPR port " + $script:PortName + " and prnport.vbs was not found.")
        return
    }
    Write-Remax ("Creating the port with " + $vbs)
    $prnArgs = @(
        '//nologo', $vbs, '-a', '-r', $script:PortName,
        '-h', $Target.Host, '-o', 'lpr', '-q', $Target.Queue, '-n', '515'
    )
    $ported = Invoke-LoggedProcess -FilePath 'cscript.exe' -ArgumentList $prnArgs
    if ([int]$ported.Code -ne 0) {
        Write-Remax ("prnport.vbs failed with exit " + $ported.Code)
    }
}

function Restart-PrintSpooler {
    Write-Remax "Restarting the Print Spooler service."
    try {
        Restart-Service -Name Spooler -Force -ErrorAction Stop
    } catch {
        Write-Remax ("Restart-Service Spooler failed: " + $_.Exception.Message)
        return $false
    }
    $deadline = (Get-Date).AddSeconds(30)
    do {
        try {
            $svc = Get-Service -Name Spooler -ErrorAction Stop
            if ($svc.Status -eq 'Running') {
                Write-Remax "Print Spooler is running."
                return $true
            }
        } catch { }
        Start-Sleep -Milliseconds 400
    } while ((Get-Date) -lt $deadline)
    Write-Remax "Print Spooler did not return to Running."
    return $false
}

function Test-PortInUse {
    param([string]$Name)
    try {
        foreach ($printer in @(Get-Printer -ErrorAction SilentlyContinue)) {
            if ([string]$printer.PortName -eq $Name) { return $true }
        }
    } catch { }
    return $false
}

function Remove-PortRegistryKey {
    param([string]$Name)
    $path = Get-PortMonitorKey $Name
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
    Write-Remax ("Removed port registry key " + $path)
    return $true
}

function Update-ExistingLprPort {
    param($Snapshot, $Target)
    Write-Remax "Updating writable LPR settings (queue, protocol, byte counting, SNMP) and the port registry. HostAddress is not written on the CIM object."
    try { Set-PortFields -Snapshot $Snapshot -Target $Target } catch {
        Write-Remax ("Port update failed: " + $_.Exception.Message)
    }
    $fresh = $null
    try { $fresh = Get-PortSnapshot $script:PortName } catch { $fresh = $null }
    if ($fresh -and (Test-PortMatches $fresh $Target)) { return $fresh }
    Write-Remax "Port readback still does not match. Restarting the Print Spooler so registry LPR settings load."
    [void](Restart-PrintSpooler)
    try { $fresh = Get-PortSnapshot $script:PortName } catch { $fresh = $null }
    return $fresh
}

function Ensure-LprPort {
    param($Target)
    $manual = @{ State = 'MANUAL'; Detail = ''; Snapshot = $null }
    try { Import-PrintModule } catch {
        $manual.Detail = "PrintManagement module is not available: " + $_.Exception.Message
        return $manual
    }
    $snapshot = $null
    try {
        $snapshot = Get-PortSnapshot $script:PortName
    } catch {
        $manual.Detail = "Could not read the port: " + $_.Exception.Message
        return $manual
    }
    if (-not $snapshot) {
        Add-LprPort $Target
        try { $snapshot = Get-PortSnapshot $script:PortName } catch { $snapshot = $null }
    }
    if (-not $snapshot) {
        $manual.Detail = "Port " + $script:PortName + " was not created. The queue install will still be attempted."
        return $manual
    }
    if (-not (Test-PortMatches $snapshot $Target)) {
        $snapshot = Update-ExistingLprPort -Snapshot $snapshot -Target $Target
    }
    if ($snapshot -and -not (Test-PortMatches $snapshot $Target) -and -not (Test-PortInUse $script:PortName)) {
        Write-Remax ("No queue is using " + $script:PortName + ". Removing it and creating the LPR port again.")
        try {
            Remove-PrinterPort -Name $script:PortName -ErrorAction Stop
        } catch {
            Write-Remax ("Remove-PrinterPort failed: " + $_.Exception.Message)
            [void](Restart-PrintSpooler)
            try { Remove-PrinterPort -Name $script:PortName -ErrorAction Stop } catch {
                Write-Remax ("Remove-PrinterPort after the spooler restart failed: " + $_.Exception.Message)
                try { [void](Remove-PortRegistryKey $script:PortName) } catch {
                    Write-Remax ("Port registry cleanup failed: " + $_.Exception.Message)
                }
                [void](Restart-PrintSpooler)
            }
        }
        Add-LprPort $Target
        try { $snapshot = Get-PortSnapshot $script:PortName } catch { $snapshot = $null }
        if ($snapshot -and -not (Test-PortMatches $snapshot $Target)) {
            $snapshot = Update-ExistingLprPort -Snapshot $snapshot -Target $Target
        }
    }
    if ($snapshot -and (Test-PortMatches $snapshot $Target)) {
        return @{ State = 'PASS'; Detail = (Format-PortDetail -Snapshot $snapshot -Target $Target); Snapshot = $snapshot }
    }
    $snmp = ''
    $hostShown = ''
    $queueShown = ''
    $protocolShown = ''
    if ($snapshot) {
        $snmp = [string]$snapshot.SnmpEnabled
        $hostShown = [string]$snapshot.Host
        $queueShown = [string]$snapshot.Queue
        $protocolShown = [string]$snapshot.Protocol
    }
    $manual.Snapshot = $snapshot
    $manual.Detail = "Port " + $script:PortName + " is not confirmed as LPR to " + $Target.Uri + " with SNMP off. Host=" + $hostShown + " Queue=" + $queueShown + " Protocol=" + $protocolShown + " SNMP=" + $snmp + ". The queue install continues."
    Write-Remax $manual.Detail
    return $manual
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
    $paperCheck = Select-LabeledControl -Elements $Elements -Labels @('Cassette Feeding Unit') -ControlType 'CheckBox'
    $paper = Find-CanonComboByLabel -Elements $Elements -Labels @('Paper Source Options')
    $output = Find-CanonComboByLabel -Elements $Elements -Labels @('Output Options')
    $psOutput = Find-CanonComboByLabel -Elements $Elements -Labels @('PS Output from Application')
    $user = Select-LabeledControl -Elements $Elements -Labels @('Set User Information') -ControlType 'CheckBox'
    $settings = $null
    if ($user) {
        $settings = Select-RowControl -Elements $Elements -Anchor $user -ControlType 'Button' -LabelEquals 'Settings' -ToTheRight
    }
    $profile = Find-CanonComboByLabel -Elements $Elements -Labels @('Config. Profile', 'Configuration Profile', 'Config Profile')
    return @{
        PaperCheck   = $paperCheck
        PaperCombo   = $paper
        OutputCombo  = $output
        PsOutput     = $psOutput
        UserInfo     = $user
        UserSettings = $settings
        Profile      = $profile
    }
}

function Get-PsOutputChoice {
    if ([string]::IsNullOrWhiteSpace($env:REMAX_PS_OUTPUT)) { return '' }
    return $env:REMAX_PS_OUTPUT.Trim()
}

function Find-ListedIndex {
    param([string[]]$Labels, [string]$Want)
    $index = 0
    foreach ($label in @($Labels)) {
        if (Test-CanonLabelEquals $label $Want) { return $index }
        $index = $index + 1
    }
    return -1
}

function Resolve-ConfirmButtonLabel {
    param([string[]]$Labels)
    foreach ($want in @('Yes', 'OK')) {
        $found = Resolve-CanonChoiceLabel -Labels $Labels -Accept @($want)
        if ($found) { return $found }
    }
    return $null
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

function ConvertTo-LooseLabel {
    param([string]$Name)
    $text = ConvertTo-CanonLabel $Name
    if (-not $text) { return '' }
    $text = $text.Replace('-', ' ')
    $text = $text -replace '\s+', ' '
    return $text.Trim()
}

function Test-LooseLabelEquals {
    param([string]$Left, [string]$Right)
    $a = (ConvertTo-LooseLabel $Left).ToLowerInvariant()
    $b = (ConvertTo-LooseLabel $Right).ToLowerInvariant()
    if (-not $a -or -not $b) { return $false }
    return ($a -eq $b)
}

function Resolve-FinisherLabel {
    param([string[]]$Labels)
    $exact = Resolve-CanonChoiceLabel -Labels $Labels -Accept @('Inner Finisher E1', 'Inner Finisher-E1')
    if ($exact) { return $exact }
    foreach ($label in @($Labels)) {
        $norm = (ConvertTo-LooseLabel $label).ToLowerInvariant()
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

function Get-RemaxUiReferencePaths {
    foreach ($name in @('UIAutomationClient', 'UIAutomationTypes', 'WindowsBase')) {
        try { Add-Type -AssemblyName $name -ErrorAction Stop } catch { }
    }
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($typeName in @('System.Windows.Automation.AutomationElement', 'System.Windows.Automation.AutomationPattern', 'System.Windows.Point')) {
        $type = $typeName -as [type]
        if (-not $type) { continue }
        $location = ''
        try { $location = [string]$type.Assembly.Location } catch { $location = '' }
        if ($location -and -not $paths.Contains($location)) { [void]$paths.Add($location) }
    }
    return @($paths.ToArray())
}

function Get-RemaxUiaSource {
    return @'
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
}

function Test-RemaxUiaHelperCompile {
    $result = @{ Ran = $false; Ok = $false; Detail = '' }
    $client = $false
    $types = $false
    try { Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop; $client = $true } catch { $client = $false }
    try { Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop; $types = $true } catch { $types = $false }
    if (-not $client -or -not $types) {
        $result.Ok = $true
        $result.Detail = 'UIAutomation assemblies are not on this host. The helper source was not compiled.'
        return $result
    }
    $result.Ran = $true
    if ('RemaxUia' -as [type]) {
        $result.Ok = $true
        $result.Detail = 'RemaxUia is already compiled.'
        return $result
    }
    $refs = @(Get-RemaxUiReferencePaths)
    if ($refs.Count -lt 2) {
        $result.Detail = 'UIAutomationClient and UIAutomationTypes were loaded but their paths were not found.'
        return $result
    }
    try {
        Add-Type -TypeDefinition (Get-RemaxUiaSource) -ReferencedAssemblies $refs -Language CSharp -ErrorAction Stop
        $result.Ok = ($null -ne ('RemaxUia' -as [type]))
        if (-not $result.Ok) { $result.Detail = 'Add-Type finished without defining RemaxUia.' }
        else { $result.Detail = 'RemaxUia compiled with UIAutomationClient and UIAutomationTypes.' }
    } catch {
        $result.Detail = $_.Exception.Message
    }
    return $result
}

function Test-CalledHelpersDefined {
    $path = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
        return @{ Ok = $true; Detail = 'script path is not available under irm | iex' }
    }
    $lines = @(Get-Content -LiteralPath $path)
    $defs = @{}
    foreach ($line in $lines) {
        if ($line -match 'function ([A-Za-z][A-Za-z0-9-]*)') {
            $defs[$Matches[1]] = $true
        }
    }
    $known = @{}
    foreach ($cmd in @(Get-Command -CommandType Cmdlet, Alias -ErrorAction SilentlyContinue)) {
        $known[[string]$cmd.Name] = $true
    }
    foreach ($cmd in @(
        'Get-Printer', 'Get-PrinterDriver', 'Get-PrinterPort', 'Get-PrinterProperty', 'Get-PrintConfiguration',
        'Add-Printer', 'Add-PrinterDriver', 'Add-PrinterPort', 'Set-Printer', 'Set-PrinterProperty', 'Set-PrintConfiguration',
        'Remove-Printer', 'Remove-PrinterDriver', 'Remove-PrinterPort',
        'Get-Service', 'Start-Service', 'Restart-Service', 'Get-CimInstance', 'Set-CimInstance', 'Invoke-CimMethod',
        'Get-WindowsDriver', 'Expand-Archive',
        'Get-NetFirewallProfile', 'Get-NetFirewallRule', 'New-NetFirewallRule', 'Remove-NetFirewallRule',
        'Get-NetConnectionProfile', 'Get-NetRoute', 'Get-NetIPAddress', 'Get-NetAdapter', 'Test-NetConnection'
    )) {
        $known[$cmd] = $true
    }
    $missing = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $pattern = '\b((?:Get|Set|Add|Remove|New|Test|Invoke|Write|Read|Show|Select|Find|Resolve|Format|Convert|Update|Start|Stop|Wait|Open|Close|Enter|Exit|Copy|Move|Import|Export|Expand|Save|Ensure|Apply|Protect|Complete|Suspend|Resume|Dismiss|Restart)-[A-Za-z][A-Za-z0-9-]*)\b'
    foreach ($line in $lines) {
        $trim = $line.Trim()
        if ($trim.StartsWith('#')) { continue }
        foreach ($match in @([regex]::Matches($line, $pattern))) {
            $name = [string]$match.Groups[1].Value
            if ($defs.ContainsKey($name)) { continue }
            if ($known.ContainsKey($name)) { continue }
            if (-not $seen.ContainsKey($name)) {
                [void]$missing.Add($name)
                $seen[$name] = $true
            }
        }
    }
    if (-not $defs.ContainsKey('Select-UiaTab')) {
        return @{ Ok = $false; Detail = 'Select-UiaTab is not defined' }
    }
    $tabDef = 0
    $tabUse = 0
    $lineNo = 0
    foreach ($line in $lines) {
        $lineNo = $lineNo + 1
        if ($tabDef -eq 0 -and $line -match '^function Select-UiaTab\b') { $tabDef = $lineNo }
        if ($tabUse -eq 0 -and $line -match 'Select-UiaTab\s+-') { $tabUse = $lineNo }
    }
    if ($tabDef -eq 0 -or ($tabUse -gt 0 -and $tabDef -gt $tabUse)) {
        return @{ Ok = $false; Detail = 'Select-UiaTab must be defined at script scope before it is used' }
    }
    if ($missing.Count -gt 0) {
        return @{ Ok = $false; Detail = ('missing helpers: ' + ($missing -join ', ')) }
    }
    return @{ Ok = $true; Detail = 'called helpers are defined' }
}

function Initialize-RemaxUi {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    try { Add-Type -AssemblyName WindowsBase -ErrorAction Stop } catch { }
    if (-not ('RemaxWin1210' -as [type])) {
        $win32 = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class RemaxWin1210 {
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
    [DllImport("user32.dll", EntryPoint="SendMessageTimeoutW", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr SendMessageTimeoutText(IntPtr hWnd, uint msg, IntPtr wParam, string text, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll", EntryPoint="SendMessageTimeoutW", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr SendMessageTimeoutGetText(IntPtr hWnd, uint msg, IntPtr wParam, StringBuilder text, uint flags, uint timeout, out IntPtr result);
    public static void SetWindowText(IntPtr hwnd, string text) {
        SendMessageText(hwnd, 0x000C, IntPtr.Zero, text);
    }
    public static bool SetWindowTextTimed(IntPtr hwnd, string text) {
        IntPtr result;
        IntPtr ret = SendMessageTimeoutText(hwnd, 0x000C, IntPtr.Zero, text ?? "", 0x0002, 2000, out result);
        return ret != IntPtr.Zero;
    }
    public static string WindowTextTimed(IntPtr hwnd) {
        StringBuilder sb = new StringBuilder(512);
        IntPtr result;
        SendMessageTimeoutGetText(hwnd, 0x000D, new IntPtr(512), sb, 0x0002, 2000, out result);
        return sb.ToString();
    }
    public static void NotifyEditChange(IntPtr edit) {
        IntPtr parent = GetParent(edit);
        int id = GetDlgCtrlID(edit);
        int wparam = (id & 0xFFFF) | (0x0300 << 16);
        PostMessagePtr(parent, 0x0111, new IntPtr(wparam), edit);
    }
    public static void CloseWindow(IntPtr hwnd) {
        PostMessagePtr(hwnd, 0x0010, IntPtr.Zero, IntPtr.Zero);
    }
    public static void SelectAllKeys() {
        keybd_event(0x11, 0, 0, UIntPtr.Zero);
        keybd_event(0x41, 0, 0, UIntPtr.Zero);
        keybd_event(0x41, 0, 2, UIntPtr.Zero);
        keybd_event(0x11, 0, 2, UIntPtr.Zero);
    }
    public static void TapEscape() {
        keybd_event(0x1B, 0, 0, UIntPtr.Zero);
        keybd_event(0x1B, 0, 2, UIntPtr.Zero);
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
    [DllImport("user32.dll")]
    public static extern IntPtr GetParent(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern int GetDlgCtrlID(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool BlockInput(bool fBlockIt);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    public static bool TryBlockInput(bool block, out int error) {
        error = 0;
        uint fgThread = 0;
        uint fgPid = 0;
        IntPtr fg = GetForegroundWindow();
        if (fg != IntPtr.Zero) {
            fgThread = GetWindowThreadProcessId(fg, out fgPid);
        }
        uint mine = GetCurrentThreadId();
        bool attached = false;
        if (fgThread != 0) {
            if (fgThread != mine) {
                attached = AttachThreadInput(mine, fgThread, true);
            }
        }
        bool ok = BlockInput(block);
        if (!ok) {
            error = Marshal.GetLastWin32Error();
        }
        if (attached) {
            AttachThreadInput(mine, fgThread, false);
        }
        return ok;
    }
    [DllImport("user32.dll")]
    public static extern IntPtr SetFocus(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    public static int ComboFindExact(IntPtr combo, string text) {
        return (int)SendMessageText(combo, 0x0158, new IntPtr(-1), text);
    }
    public static int ComboSetCurSel(IntPtr combo, int index) {
        return (int)SendMessagePtr(combo, 0x014E, new IntPtr(index), IntPtr.Zero);
    }
    public static int ComboGetCurSel(IntPtr combo) {
        return (int)SendMessagePtr(combo, 0x0147, IntPtr.Zero, IntPtr.Zero);
    }
    public static int ComboGetCount(IntPtr combo) {
        return (int)SendMessagePtr(combo, 0x0146, IntPtr.Zero, IntPtr.Zero);
    }
    public static string ComboGetLbText(IntPtr combo, int index) {
        StringBuilder sb = new StringBuilder(512);
        SendMessageGetText(combo, 0x0148, new IntPtr(index), sb);
        return sb.ToString();
    }
    public static void NotifySelChange(IntPtr combo) {
        IntPtr parent = GetParent(combo);
        int id = GetDlgCtrlID(combo);
        int wparam = (id & 0xFFFF) | (1 << 16);
        PostMessagePtr(parent, 0x0111, new IntPtr(wparam), combo);
    }
    public static void TapKey(byte vk) {
        keybd_event(vk, 0, 0, UIntPtr.Zero);
        keybd_event(vk, 0, 2, UIntPtr.Zero);
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct HARDWAREINPUT {
        public uint uMsg;
        public ushort wParamL;
        public ushort wParamH;
    }
    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT {
        public uint type;
        public INPUTUNION u;
    }
    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    static EnumWindowsProc EnumProc;
    public static System.Collections.Generic.List<IntPtr> Hwnds = new System.Collections.Generic.List<IntPtr>();
    public static bool CollectHwnd(IntPtr hWnd, IntPtr lParam) {
        Hwnds.Add(hWnd);
        return true;
    }
    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool EnumThreadWindows(uint dwThreadId, EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr childAfter, string className, string windowName);
    [DllImport("user32.dll")]
    public static extern IntPtr GetDlgItem(IntPtr hDlg, int nIDDlgItem);
    public static string WindowTitle(IntPtr hwnd) {
        StringBuilder sb = new StringBuilder(512);
        GetWindowText(hwnd, sb, 512);
        return sb.ToString();
    }
    public static string WindowClass(IntPtr hwnd) {
        StringBuilder sb = new StringBuilder(256);
        GetClassName(hwnd, sb, 256);
        return sb.ToString();
    }
    public static uint WindowPid(IntPtr hwnd) {
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        return pid;
    }
    static void EnsureEnumProc() {
        if (EnumProc == null) EnumProc = CollectHwnd;
    }
    public static IntPtr[] EnumTopLevel() {
        Hwnds = new System.Collections.Generic.List<IntPtr>();
        EnsureEnumProc();
        EnumWindows(EnumProc, IntPtr.Zero);
        return Hwnds.ToArray();
    }
    public static IntPtr[] EnumThread(IntPtr hwnd) {
        Hwnds = new System.Collections.Generic.List<IntPtr>();
        EnsureEnumProc();
        uint pid;
        uint thread = GetWindowThreadProcessId(hwnd, out pid);
        if (thread != 0) EnumThreadWindows(thread, EnumProc, IntPtr.Zero);
        return Hwnds.ToArray();
    }
    public static IntPtr[] ChildEdits(IntPtr parent) {
        System.Collections.Generic.List<IntPtr> edits = new System.Collections.Generic.List<IntPtr>();
        IntPtr child = IntPtr.Zero;
        while (true) {
            child = FindWindowEx(parent, child, null, null);
            if (child == IntPtr.Zero) break;
            string cls = WindowClass(child);
            if (cls != null) {
                if (cls.IndexOf("Edit", System.StringComparison.OrdinalIgnoreCase) >= 0) {
                    edits.Add(child);
                }
            }
            IntPtr nested = IntPtr.Zero;
            while (true) {
                nested = FindWindowEx(child, nested, null, null);
                if (nested == IntPtr.Zero) break;
                string ncls = WindowClass(nested);
                if (ncls != null) {
                    if (ncls.IndexOf("Edit", System.StringComparison.OrdinalIgnoreCase) >= 0) {
                        edits.Add(nested);
                    }
                }
            }
        }
        return edits.ToArray();
    }
    public static IntPtr TopEdit(IntPtr parent) {
        IntPtr[] edits = ChildEdits(parent);
        IntPtr best = IntPtr.Zero;
        int bestTop = int.MaxValue;
        foreach (IntPtr edit in edits) {
            RECT rect;
            if (!GetWindowRect(edit, out rect)) continue;
            if (rect.Top < bestTop) {
                bestTop = rect.Top;
                best = edit;
            }
        }
        return best;
    }
    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool OpenPrinter(string pPrinterName, out IntPtr phPrinter, IntPtr pDefault);
    [DllImport("winspool.drv", SetLastError = true)]
    public static extern bool ClosePrinter(IntPtr hPrinter);
    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool GetPrinter(IntPtr hPrinter, uint Level, IntPtr pPrinter, uint cbBuf, out uint pcbNeeded);
    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetPrinter(IntPtr hPrinter, uint Level, IntPtr pPrinter, uint Command);
    public static int ApplyDevMode(string printer, byte[] devmode, uint level) {
        IntPtr handle;
        if (!OpenPrinter(printer, out handle, IntPtr.Zero)) return Marshal.GetLastWin32Error();
        IntPtr raw = Marshal.AllocHGlobal(devmode.Length);
        Marshal.Copy(devmode, 0, raw, devmode.Length);
        try {
            if (level == 8) {
                IntPtr info8 = Marshal.AllocHGlobal(IntPtr.Size);
                Marshal.WriteIntPtr(info8, raw);
                bool ok8 = SetPrinter(handle, 8, info8, 0);
                int err8 = ok8 ? 0 : Marshal.GetLastWin32Error();
                Marshal.FreeHGlobal(info8);
                return err8;
            }
            if (level == 9) {
                IntPtr info = Marshal.AllocHGlobal(IntPtr.Size);
                Marshal.WriteIntPtr(info, raw);
                bool ok = SetPrinter(handle, level, info, 0);
                int err = ok ? 0 : Marshal.GetLastWin32Error();
                Marshal.FreeHGlobal(info);
                return err;
            }
            if (level == 2) {
                uint needed;
                GetPrinter(handle, 2, IntPtr.Zero, 0, out needed);
                if (needed == 0) return Marshal.GetLastWin32Error();
                IntPtr buf = Marshal.AllocHGlobal((int)needed);
                uint got;
                if (!GetPrinter(handle, 2, buf, needed, out got)) {
                    int err = Marshal.GetLastWin32Error();
                    Marshal.FreeHGlobal(buf);
                    return err;
                }
                Marshal.WriteIntPtr(buf, 7 * IntPtr.Size, raw);
                bool ok2 = SetPrinter(handle, 2, buf, 0);
                int err2 = ok2 ? 0 : Marshal.GetLastWin32Error();
                Marshal.FreeHGlobal(buf);
                return err2;
            }
            return 87;
        } finally {
            ClosePrinter(handle);
            Marshal.FreeHGlobal(raw);
        }
    }
    public static void TypeUnicode(string text) {
        if (string.IsNullOrEmpty(text)) return;
        INPUT[] inputs = new INPUT[text.Length * 2];
        for (int i = 0; i < text.Length; i++) {
            ushort scan = text[i];
            INPUT down = new INPUT();
            down.type = 1;
            down.u.ki.wScan = scan;
            down.u.ki.dwFlags = 4;
            INPUT up = new INPUT();
            up.type = 1;
            up.u.ki.wScan = scan;
            up.u.ki.dwFlags = 4 | 2;
            inputs[i * 2] = down;
            inputs[i * 2 + 1] = up;
        }
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
    }
}
'@
        Add-Type -TypeDefinition $win32 -Language CSharp
    }
    if (-not ('RemaxUia' -as [type])) {
        $uia = Get-RemaxUiaSource
        $refs = @(Get-RemaxUiReferencePaths)
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
                $state = [RemaxWin1210]::ButtonCheck($hwnd)
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
            if ($hwnd -ne [IntPtr]::Zero) { $value = [RemaxWin1210]::WindowText($hwnd) }
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
        [string[]]$TitleAny,
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
            if ($TitleAny -and @($TitleAny).Count -gt 0) {
                $titleOk = $false
                foreach ($pat in @($TitleAny)) {
                    if ($name -like [string]$pat) { $titleOk = $true }
                }
                if (-not $titleOk) { continue }
            } elseif ($TitleLike -and $name -notlike $TitleLike) { continue }
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
            [void][RemaxWin1210]::ShowWindow($hwnd, 9)
            [void][RemaxWin1210]::SetForegroundWindow($hwnd)
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
        [RemaxWin1210]::ClickScreen($x, $y)
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
        return [bool][RemaxWin1210]::ClickHwnd($hwnd)
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
    if ($Snapshot.Element) {
        try {
            $toggle = $null
            if ($Snapshot.Element.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$toggle)) {
                $tries = 0
                while ($tries -lt 3) {
                    $state = [string]$toggle.Current.ToggleState
                    if ($state -eq $want) { return $true }
                    $toggle.Toggle()
                    Start-Sleep -Milliseconds 200
                    $tries = $tries + 1
                }
                $state = [string]$toggle.Current.ToggleState
                if ($state -eq $want) { return $true }
            }
        } catch {
            Write-Remax ("TogglePattern failed: " + $_.Exception.Message)
        }
    }
    $current = [string]$Snapshot.Toggle
    if (-not $current -and $Snapshot.Element) {
        try {
            $hwnd = [IntPtr]$Snapshot.Element.Current.NativeWindowHandle
            if ($hwnd -ne [IntPtr]::Zero) {
                $state = [RemaxWin1210]::ButtonCheck($hwnd)
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
                $state = [RemaxWin1210]::ButtonCheck($hwnd)
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
    if ([string]::IsNullOrEmpty($Text)) {
        if (-not $Snapshot -or -not $Snapshot.Element) { return $false }
        try {
            $pattern = $null
            if ($Snapshot.Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
                if (-not $pattern.Current.IsReadOnly) { $pattern.SetValue('') }
            }
        } catch { }
        try {
            $hwnd = [IntPtr]$Snapshot.Element.Current.NativeWindowHandle
            if ($hwnd -ne [IntPtr]::Zero -and ('RemaxWin1210' -as [type])) {
                [void][RemaxWin1210]::SetWindowTextTimed($hwnd, '')
            }
        } catch { }
        return $true
    }
    $wrote = Set-UserNameEditText -Snapshot $Snapshot -Text $Text
    return [bool]$wrote.Ok
}

function Get-EditChangeWParam {
    param([int]$ControlId)
    $id = $ControlId -band 65535
    return ($id -bor (768 -shl 16))
}

function Read-LiveEditText {
    param($Element)
    $patternText = ''
    $windowText = ''
    if ($Element) {
        try {
            $pattern = $null
            if ($Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
                $patternText = [string]$pattern.Current.Value
            }
        } catch { }
        try {
            $hwnd = [IntPtr]$Element.Current.NativeWindowHandle
            if ($hwnd -ne [IntPtr]::Zero -and ('RemaxWin1210' -as [type])) {
                $windowText = [string][RemaxWin1210]::WindowTextTimed($hwnd)
            }
        } catch { }
    }
    $value = $patternText
    if ([string]::IsNullOrWhiteSpace($value)) { $value = $windowText }
    return @{ Pattern = $patternText; Window = $windowText; Value = $value }
}

function Set-UserNameEditText {
    param($Snapshot, [string]$Text)
    $result = @{ Ok = $false; Method = 'none'; Value = '' }
    if (-not $Snapshot -or -not $Snapshot.Element) { return $result }
    $element = $Snapshot.Element
    $hwnd = [IntPtr]::Zero
    try { $hwnd = [IntPtr]$element.Current.NativeWindowHandle } catch { $hwnd = [IntPtr]::Zero }
    try {
        $pattern = $null
        if ($element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
            if (-not $pattern.Current.IsReadOnly) {
                $pattern.SetValue($Text)
                Start-Sleep -Milliseconds 150
                $read = Read-LiveEditText $element
                Write-Remax ("User Name method ValuePattern.SetValue read-back pattern='" + $read.Pattern + "' window='" + $read.Window + "'")
                if (Test-UserNameMatch $read.Value $Text) {
                    $result.Ok = $true
                    $result.Method = 'ValuePattern.SetValue'
                    $result.Value = [string]$read.Value
                    return $result
                }
            }
        }
    } catch {
        Write-Remax ("User Name ValuePattern.SetValue failed: " + $_.Exception.Message)
    }
    if ($hwnd -ne [IntPtr]::Zero -and ('RemaxWin1210' -as [type])) {
        $posted = $false
        try { $posted = [bool][RemaxWin1210]::SetWindowTextTimed($hwnd, $Text) } catch { $posted = $false }
        try { [RemaxWin1210]::NotifyEditChange($hwnd) } catch { }
        Start-Sleep -Milliseconds 150
        $read = Read-LiveEditText $element
        Write-Remax ("User Name method WM_SETTEXT posted=" + $posted + " read-back pattern='" + $read.Pattern + "' window='" + $read.Window + "'")
        if (Test-UserNameMatch $read.Value $Text) {
            $result.Ok = $true
            $result.Method = 'WM_SETTEXT'
            $result.Value = [string]$read.Value
            return $result
        }
        $paused = $false
        try { $paused = Suspend-InputLock } catch { $paused = $false }
        try {
            Write-Remax "Input lock released so User Name keystrokes are not swallowed."
            [void][RemaxWin1210]::SetFocus($hwnd)
            Start-Sleep -Milliseconds 100
            [RemaxWin1210]::SelectAllKeys
            Start-Sleep -Milliseconds 80
            [RemaxWin1210]::TypeUnicode($Text)
            Start-Sleep -Milliseconds 200
        } catch {
            Write-Remax ("User Name SendInput failed: " + $_.Exception.Message)
        } finally {
            if ($paused) {
                try { Resume-InputLock } catch { }
            }
        }
        $read = Read-LiveEditText $element
        Write-Remax ("User Name method SendInput read-back pattern='" + $read.Pattern + "' window='" + $read.Window + "'")
        if (Test-UserNameMatch $read.Value $Text) {
            $result.Ok = $true
            $result.Method = 'SendInput'
            $result.Value = [string]$read.Value
            return $result
        }
        $result.Value = [string]$read.Value
    }
    Write-Remax ("User Name write did not stick. Last read-back '" + $result.Value + "'.")
    return $result
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
                $keep = [IntPtr]::Zero
                try { $keep = [IntPtr]$Session.Window.Current.NativeWindowHandle } catch { $keep = [IntPtr]::Zero }
                try { [void](Dismiss-CanonPrompt -ProcessId $proc.Id -Keep $keep) } catch { }
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
        try { $alive = [bool][RemaxWin1210]::IsWindow($Handle) } catch { $alive = $false }
        if (-not $alive) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Open-ChildDialog {
    param($Button, [int]$ProcessId, $Exclude, [string]$TitleLike, [string[]]$TitleAny)
    if (-not $Button) { return $null }
    [void](Invoke-CanonButton -Snapshot $Button -How post)
    $dlg = Wait-UiaTopWindow -ProcessId $ProcessId -Exclude $Exclude -TimeoutMs 8000 -SkipProperties -TitleLike $TitleLike -TitleAny $TitleAny
    if ($dlg) { return $dlg }
    [void](Invoke-CanonButton -Snapshot $Button -How mouse)
    $dlg = Wait-UiaTopWindow -ProcessId $ProcessId -Exclude $Exclude -TimeoutMs 4000 -SkipProperties -TitleLike $TitleLike -TitleAny $TitleAny
    if ($dlg) { return $dlg }
    [void](Invoke-CanonButton -Snapshot $Button -How invoke)
    return (Wait-UiaTopWindow -ProcessId $ProcessId -Exclude $Exclude -TimeoutMs 4000 -SkipProperties -TitleLike $TitleLike -TitleAny $TitleAny)
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
    $nameOk = $false
    if ($targets.NameEdit) {
        $wrote = Set-UserNameEditText -Snapshot $targets.NameEdit -Text $PrintUser
        $nameOk = [bool]$wrote.Ok
        Write-Remax ("Default Value Settings User Name method " + $wrote.Method + " read-back '" + $wrote.Value + "'")
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
    return ($radioOk -and $nameOk)
}

function Test-UserInformationTitle {
    param([string]$Title)
    if ([string]::IsNullOrWhiteSpace($Title)) { return $false }
    return [bool]($Title -like '*User Information Settings*')
}

function Test-UserNameMatch {
    param([string]$Actual, [string]$Expected)
    if ([string]::IsNullOrWhiteSpace($Expected)) { return $false }
    if ($Actual -eq $Expected) { return $true }
    return (Test-CanonLabelEquals $Actual $Expected)
}

function Get-UserNameBytePatterns {
    param([string]$Name)
    $ascii = [System.Text.Encoding]::ASCII.GetBytes($Name)
    $utf16 = [System.Text.Encoding]::Unicode.GetBytes($Name)
    return @(
        @{ Encoding = 'ASCII'; Bytes = $ascii }
        @{ Encoding = 'UTF-16'; Bytes = $utf16 }
    )
}

function Find-UserNameOffsets {
    param([byte[]]$Data, [byte[]]$Needle)
    $hits = New-Object System.Collections.Generic.List[int]
    if ($null -eq $Data -or $null -eq $Needle) { return @() }
    if ($Needle.Length -eq 0 -or $Data.Length -lt $Needle.Length) { return @() }
    $limit = $Data.Length - $Needle.Length
    for ($i = 0; $i -le $limit; $i++) {
        $match = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) {
            if ($Data[$i + $j] -ne $Needle[$j]) {
                $match = $false
                break
            }
        }
        if ($match) {
            [void]$hits.Add($i)
            $i = $i + $Needle.Length - 1
        }
    }
    return @($hits.ToArray())
}

function Find-UserNameHits {
    param([byte[]]$Data, [string]$Name)
    $hits = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Data -or [string]::IsNullOrWhiteSpace($Name)) { return @() }
    $want = $Name.ToLowerInvariant()
    $limit = $Data.Length - $want.Length
    for ($i = 0; $i -le $limit; $i++) {
        $ok = $true
        for ($j = 0; $j -lt $want.Length; $j++) {
            $b = [int]$Data[$i + $j]
            if ($b -ge 65 -and $b -le 90) { $b = $b + 32 }
            if ($b -ne [int][char]$want[$j]) { $ok = $false; break }
        }
        if (-not $ok) { continue }
        $field = $want.Length
        while ($field -lt 32 -and ($i + $field) -lt $Data.Length -and $Data[$i + $field] -eq 0) { $field = $field + 1 }
        [void]$hits.Add(@{ Offset = $i; Encoding = 'ASCII'; FieldChars = $field })
        $i = $i + $want.Length - 1
    }
    $chars = $want.Length
    $need = $chars * 2
    $limit16 = $Data.Length - $need
    for ($i = 0; $i -le $limit16; $i++) {
        $ok = $true
        for ($j = 0; $j -lt $chars; $j++) {
            $lo = [int]$Data[$i + ($j * 2)]
            $hi = [int]$Data[$i + ($j * 2) + 1]
            if ($hi -ne 0) { $ok = $false; break }
            if ($lo -ge 65 -and $lo -le 90) { $lo = $lo + 32 }
            if ($lo -ne [int][char]$want[$j]) { $ok = $false; break }
        }
        if (-not $ok) { continue }
        $field = $chars
        while ($field -lt 32 -and ($i + ($field * 2) + 1) -lt $Data.Length -and $Data[$i + ($field * 2)] -eq 0 -and $Data[$i + ($field * 2) + 1] -eq 0) {
            $field = $field + 1
        }
        [void]$hits.Add(@{ Offset = $i; Encoding = 'UTF-16'; FieldChars = $field })
        $i = $i + $need - 1
    }
    return @($hits.ToArray())
}

function Write-NameIntoField {
    param([byte[]]$Data, $Hit, [string]$NewName)
    $copy = New-Object byte[] $Data.Length
    [System.Array]::Copy($Data, $copy, $Data.Length)
    $field = [int]$Hit.FieldChars
    if ($field -gt 32) { $field = 32 }
    if ($NewName.Length -gt $field) { return @{ Bytes = $copy; Ok = $false } }
    $offset = [int]$Hit.Offset
    if ($Hit.Encoding -eq 'UTF-16') {
        $span = $field * 2
        for ($j = 0; $j -lt $span; $j++) { $copy[$offset + $j] = 0 }
        $raw = [System.Text.Encoding]::Unicode.GetBytes($NewName)
        [System.Array]::Copy($raw, 0, $copy, $offset, $raw.Length)
    } else {
        for ($j = 0; $j -lt $field; $j++) { $copy[$offset + $j] = 0 }
        $raw = [System.Text.Encoding]::ASCII.GetBytes($NewName)
        [System.Array]::Copy($raw, 0, $copy, $offset, $raw.Length)
    }
    return @{ Bytes = $copy; Ok = $true }
}

function Replace-UserNameBytes {
    param([byte[]]$Data, [string]$OldName, [string]$NewName)
    $copy = New-Object byte[] $Data.Length
    [System.Array]::Copy($Data, $copy, $Data.Length)
    $count = 0
    $skipped = 0
    $hits = @(Find-UserNameHits -Data $copy -Name $OldName)
    foreach ($hit in @($hits)) {
        $next = Write-NameIntoField -Data $copy -Hit $hit -NewName $NewName
        if (-not $next.Ok) {
            $skipped = $skipped + 1
            continue
        }
        $copy = $next.Bytes
        $count = $count + 1
    }
    return @{ Bytes = $copy; Count = $count; Skipped = $skipped; Hits = @($hits) }
}

function Get-UserNameRegistryRoots {
    return @(
        ('HKLM:\SYSTEM\CurrentControlSet\Control\Print\Printers\' + $script:PrinterName),
        'HKCU:\Printers\DevModePerUser',
        'HKCU:\Printers\DevModes2'
    )
}

function Get-UserNameProbeTargets {
    $computer = ''
    try { $computer = [string][Environment]::MachineName } catch { $computer = '' }
    if ([string]::IsNullOrWhiteSpace($computer)) { $computer = [string]$env:COMPUTERNAME }
    $printerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Printers\' + $script:PrinterName
    $perUser = 'HKCU:\Printers\DevModePerUser'
    $targets = @(
        @{ Path = $printerKey; Value = 'Default DevMode' }
        @{ Path = $perUser; Value = $script:PrinterName }
    )
    if (-not [string]::IsNullOrWhiteSpace($computer)) {
        $targets += @{ Path = $perUser; Value = ('\\' + $computer + '\' + $script:PrinterName) }
    }
    return $targets
}

function Write-UserNameProbe {
    param([string]$OldName)
    foreach ($target in @(Get-UserNameProbeTargets)) {
        $where = $target.Path + ' value ' + $target.Value
        if (-not (Test-Path -LiteralPath $target.Path)) {
            Write-Remax ("User name probe not present: " + $where)
            continue
        }
        $item = $null
        try { $item = Get-Item -LiteralPath $target.Path } catch { $item = $null }
        $names = @()
        if ($item) {
            try { $names = @($item.GetValueNames()) } catch { $names = @() }
        }
        $found = $false
        foreach ($name in @($names)) {
            if ([string]$name -eq [string]$target.Value) { $found = $true }
        }
        if (-not $found) {
            Write-Remax ("User name probe not present: " + $where)
            continue
        }
        $raw = $null
        try { $raw = $item.GetValue($target.Value) } catch { $raw = $null }
        $bytes = $raw -as [byte[]]
        $asciiHits = 0
        $utfHits = 0
        $length = 0
        if ($null -ne $bytes) {
            $length = $bytes.Length
            if ($OldName) {
                foreach ($hit in @(Find-UserNameHits -Data $bytes -Name $OldName)) {
                    if ($hit.Encoding -eq 'ASCII') { $asciiHits = $asciiHits + 1 }
                    if ($hit.Encoding -eq 'UTF-16') { $utfHits = $utfHits + 1 }
                    Write-Remax ("User name probe hit " + $hit.Encoding + " offset " + $hit.Offset + " field " + $hit.FieldChars + " in " + $where)
                }
            }
        } elseif ($raw -is [string]) {
            $length = ([string]$raw).Length
            if ($OldName -and ([string]$raw).ToLowerInvariant().Contains($OldName.ToLowerInvariant())) { $asciiHits = 1 }
        }
        Write-Remax ("User name probe " + $where + ": " + $length + " bytes, ASCII hits " + $asciiHits + ", UTF-16 hits " + $utfHits)
    }
}

function Write-UserNameRegistryHits {
    param([string]$OldName, [string]$NewName, [switch]$Write)
    $hits = 0
    $replaced = 0
    try { Write-UserNameProbe -OldName $OldName } catch {
        Write-Remax ("User name probe failed: " + $_.Exception.Message)
    }
    if ([string]::IsNullOrWhiteSpace($OldName)) {
        return @{ Hits = 0; Replaced = 0 }
    }
    foreach ($root in @(Get-UserNameRegistryRoots)) {
        if (-not (Test-Path -LiteralPath $root)) {
            Write-Remax ("User name registry key is not present: " + $root)
            continue
        }
        $items = New-Object System.Collections.Generic.List[object]
        try { [void]$items.Add((Get-Item -LiteralPath $root)) } catch { }
        try {
            foreach ($child in @(Get-ChildItem -LiteralPath $root -Recurse -ErrorAction SilentlyContinue)) {
                if ($child) { [void]$items.Add($child) }
            }
        } catch { }
        foreach ($item in @($items.ToArray())) {
            $names = @()
            try { $names = @($item.GetValueNames()) } catch { $names = @() }
            foreach ($valueName in @($names)) {
                $label = [string]$valueName
                if ([string]::IsNullOrEmpty($label)) { $label = '(default)' }
                $raw = $null
                try { $raw = $item.GetValue($valueName) } catch { $raw = $null }
                $where = $item.PSPath + ' value ' + $label
                if ($raw -is [string]) {
                    if ($raw.ToLowerInvariant().Contains($OldName.ToLowerInvariant())) {
                        $hits = $hits + 1
                        Write-Remax ("Registry string contains '" + $OldName + "' ignoring case: " + $where)
                        if ($Write -and $NewName) {
                            $updated = [regex]::Replace($raw, [regex]::Escape($OldName), $NewName, 'IgnoreCase')
                            try {
                                $item.SetValue($valueName, $updated)
                                $replaced = $replaced + 1
                                Write-Remax ("Replaced string '" + $OldName + "' with '" + $NewName + "' in " + $where)
                            } catch {
                                Write-Remax ("Could not write " + $where + ": " + $_.Exception.Message)
                            }
                        }
                    }
                    continue
                }
                $bytes = $raw -as [byte[]]
                if ($null -eq $bytes -or $bytes.Length -eq 0) { continue }
                $foundHits = @(Find-UserNameHits -Data $bytes -Name $OldName)
                foreach ($hit in @($foundHits)) {
                    $hits = $hits + 1
                    Write-Remax ("Registry value contains " + $hit.Encoding + " name at offset " + $hit.Offset + " field " + $hit.FieldChars + " chars in " + $where)
                }
                if ($Write -and $NewName) {
                    $swap = Replace-UserNameBytes -Data $bytes -OldName $OldName -NewName $NewName
                    if ($swap.Skipped -gt 0) {
                        Write-Remax ("'" + $NewName + "' is longer than '" + $OldName + "' in " + $where + ". That occurrence was left unchanged.")
                    }
                    if ($swap.Count -gt 0) {
                        try {
                            $item.SetValue($valueName, [byte[]]$swap.Bytes, [Microsoft.Win32.RegistryValueKind]::Binary)
                            $replaced = $replaced + $swap.Count
                            Write-Remax ("Wrote '" + $NewName + "' over '" + $OldName + "' in " + $where)
                            $bytes = $swap.Bytes
                        } catch {
                            Write-Remax ("Could not write " + $where + ": " + $_.Exception.Message)
                        }
                    }
                }
            }
        }
    }
    if ($hits -eq 0) {
        Write-Remax ("No PrinterDriverData or DevMode value contained ASCII or UTF-16 '" + $OldName + "'.")
    }
    return @{ Hits = $hits; Replaced = $replaced }
}

function Invoke-UserNameDevModePatch {
    param([string]$PrintUser)
    if (-not ('RemaxWin1210' -as [type])) {
        Write-Remax "SetPrinter skipped. Win32 helper is not loaded."
        return $false
    }
    $blobs = New-Object System.Collections.Generic.List[byte[]]
    foreach ($target in @(Get-UserNameProbeTargets)) {
        if (-not (Test-Path -LiteralPath $target.Path)) { continue }
        $item = $null
        try { $item = Get-Item -LiteralPath $target.Path } catch { $item = $null }
        if (-not $item) { continue }
        $raw = $null
        try { $raw = $item.GetValue($target.Value) } catch { $raw = $null }
        $bytes = $raw -as [byte[]]
        if ($bytes -and $bytes.Length -gt 0) { [void]$blobs.Add($bytes) }
    }
    if ($blobs.Count -eq 0) {
        Write-Remax "SetPrinter skipped. No Default DevMode or per-user DevMode blob was readable."
        return $false
    }
    $devmode = $blobs[0]
    foreach ($level in @(8, 9, 2)) {
        try {
            $err = [int][RemaxWin1210]::ApplyDevMode($script:PrinterName, [byte[]]$devmode, [uint32]$level)
            Write-Remax ("SetPrinter level " + $level + " GetLastError " + $err)
        } catch {
            Write-Remax ("SetPrinter level " + $level + " failed: " + $_.Exception.Message)
        }
    }
    $check = @(Find-UserNameHits -Data $devmode -Name $PrintUser)
    if ($check.Count -gt 0) {
        Write-Remax ("DevMode patch verified. '" + $PrintUser + "' is in the blob at offset " + $check[0].Offset + " " + $check[0].Encoding)
        return $true
    }
    Write-Remax ("DevMode patch was sent. '" + $PrintUser + "' was not found in the blob afterwards, so the dialog remains the check.")
    return $false
}

function Read-UserNameEditValue {
    param($Elements)
    $edit = Find-CanonEditByLabel -Elements $Elements -Labels @('User Name')
    if (-not $edit) { return '' }
    return [string]$edit.Value
}

function Get-UserNameWaitMs {
    param([int]$Cap)
    if ($Cap -gt 10000) { $Cap = 10000 }
    if ($Cap -lt 200) { $Cap = 200 }
    if (-not $script:UserNameDeadline) { return $Cap }
    $left = [int]([TimeSpan]($script:UserNameDeadline - [DateTime]::UtcNow)).TotalMilliseconds
    if ($left -lt 200) { return 200 }
    if ($left -gt $Cap) { return $Cap }
    return $left
}

function Test-UserNameBudget {
    if (-not $script:UserNameDeadline) { return $true }
    return ([DateTime]::UtcNow -lt $script:UserNameDeadline)
}

function Write-WindowCandidate {
    param([IntPtr]$Hwnd)
    if ($Hwnd -eq [IntPtr]::Zero) { return '' }
    if (-not ('RemaxWin1210' -as [type])) { return '' }
    $title = ''
    $class = ''
    $pid = 0
    try { $title = [string][RemaxWin1210]::WindowTitle($Hwnd) } catch { $title = '' }
    try { $class = [string][RemaxWin1210]::WindowClass($Hwnd) } catch { $class = '' }
    try { $pid = [int][RemaxWin1210]::WindowPid($Hwnd) } catch { $pid = 0 }
    if ([string]::IsNullOrWhiteSpace($title)) { return '' }
    $proc = ''
    if ($pid -gt 0) {
        try { $proc = [string](Get-Process -Id $pid -ErrorAction Stop).ProcessName } catch { $proc = '' }
    }
    Write-Remax ("Window hwnd=" + $Hwnd + " pid=" + $pid + " process=" + $proc + " class=" + $class + " title='" + $title + "'")
    return $title
}

function Test-WindowTitleMatch {
    param([string]$Title, [string]$TitleLike, [string[]]$TitleAny)
    if ([string]::IsNullOrWhiteSpace($Title)) { return $false }
    if ($TitleAny -and @($TitleAny).Count -gt 0) {
        foreach ($pat in @($TitleAny)) {
            if ($Title -like [string]$pat) { return $true }
        }
        return $false
    }
    if ($TitleLike) { return ($Title -like $TitleLike) }
    return $false
}

function Find-TitledWindow {
    param([IntPtr]$PropsHwnd, [string]$TitleLike, [string[]]$TitleAny, [int]$TimeoutMs)
    if (-not ('RemaxWin1210' -as [type])) { return $null }
    if ($TimeoutMs -gt 10000) { $TimeoutMs = 10000 }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    $seen = @{}
    while ([DateTime]::UtcNow -lt $deadline) {
        $hwnds = New-Object System.Collections.Generic.List[IntPtr]
        try {
            foreach ($hwnd in @([RemaxWin1210]::EnumTopLevel())) {
                if ($hwnd -ne [IntPtr]::Zero) { [void]$hwnds.Add($hwnd) }
            }
        } catch { }
        if ($PropsHwnd -ne [IntPtr]::Zero) {
            try {
                $popup = [RemaxWin1210]::GetWindow($PropsHwnd, 6)
                if ($popup -ne [IntPtr]::Zero) { [void]$hwnds.Add($popup) }
            } catch { }
            try {
                foreach ($hwnd in @([RemaxWin1210]::EnumThread($PropsHwnd))) {
                    if ($hwnd -ne [IntPtr]::Zero) { [void]$hwnds.Add($hwnd) }
                }
            } catch { }
        }
        foreach ($hwnd in @($hwnds.ToArray())) {
            $key = [string]$hwnd
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $title = Write-WindowCandidate $hwnd
            if (Test-WindowTitleMatch -Title $title -TitleLike $TitleLike -TitleAny $TitleAny) {
                return @{ Hwnd = $hwnd; Title = $title }
            }
        }
        try {
            $root = [System.Windows.Automation.AutomationElement]::RootElement
            $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
            foreach ($window in @($windows)) {
                if (-not $window) { continue }
                $hwnd = [IntPtr]::Zero
                try { $hwnd = [IntPtr]$window.Current.NativeWindowHandle } catch { $hwnd = [IntPtr]::Zero }
                if ($hwnd -eq [IntPtr]::Zero) { continue }
                $key = [string]$hwnd
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true
                $title = Write-WindowCandidate $hwnd
                if (Test-WindowTitleMatch -Title $title -TitleLike $TitleLike -TitleAny $TitleAny) {
                    return @{ Hwnd = $hwnd; Title = $title }
                }
            }
        } catch { }
        if ($PropsHwnd -ne [IntPtr]::Zero) {
            try {
                $props = [System.Windows.Automation.AutomationElement]::FromHandle($PropsHwnd)
                $desc = $props.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
                foreach ($node in @($desc)) {
                    if (-not $node) { continue }
                    $name = ''
                    try { $name = [string]$node.Current.Name } catch { $name = '' }
                    if (-not (Test-WindowTitleMatch -Title $name -TitleLike $TitleLike -TitleAny $TitleAny)) { continue }
                    $hwnd = [IntPtr]::Zero
                    try { $hwnd = [IntPtr]$node.Current.NativeWindowHandle } catch { $hwnd = [IntPtr]::Zero }
                    if ($hwnd -eq [IntPtr]::Zero) { continue }
                    Write-Remax ("Descendant match hwnd=" + $hwnd + " title='" + $name + "'")
                    return @{ Hwnd = $hwnd; Title = $name }
                }
            } catch { }
        }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Open-ChildDialogFast {
    param($Button, [int]$ProcessId, $Exclude, [string]$TitleLike, [string[]]$TitleAny)
    if (-not $Button) { return $null }
    if (-not (Test-UserNameBudget)) {
        Write-Remax "Username stage exceeded 60 seconds before opening a dialog."
        return $null
    }
    $props = [IntPtr]::Zero
    if ($Exclude) {
        foreach ($item in @($Exclude)) {
            try { $props = [IntPtr]$item } catch { $props = [IntPtr]::Zero }
            if ($props -ne [IntPtr]::Zero) { break }
        }
    }
    [void](Invoke-CanonButton -Snapshot $Button -How post)
    $found = Find-TitledWindow -PropsHwnd $props -TitleLike $TitleLike -TitleAny $TitleAny -TimeoutMs (Get-UserNameWaitMs 10000)
    if ($found) {
        try { return [System.Windows.Automation.AutomationElement]::FromHandle($found.Hwnd) } catch { return $null }
    }
    if (-not (Test-UserNameBudget)) { return $null }
    Write-Remax "Dialog did not open after BM_CLICK. Trying a background invoke."
    [void](Invoke-CanonButton -Snapshot $Button -How invoke)
    $found = Find-TitledWindow -PropsHwnd $props -TitleLike $TitleLike -TitleAny $TitleAny -TimeoutMs (Get-UserNameWaitMs 10000)
    if (-not $found) { return $null }
    try { return [System.Windows.Automation.AutomationElement]::FromHandle($found.Hwnd) } catch { return $null }
}

function Close-UserDialog {
    param($Window, [switch]$Save)
    $handle = [IntPtr]::Zero
    try { $handle = [IntPtr]$Window.Current.NativeWindowHandle } catch { $handle = [IntPtr]::Zero }
    if (-not $Window) { return }
    $labels = @('Cancel', 'Close')
    if ($Save) { $labels = @('OK') }
    $elements = @()
    try { $elements = Get-UiaDescendants $Window } catch { $elements = @() }
    $button = Select-LabeledControl -Elements $elements -Labels $labels -ControlType 'Button'
    if ($button) {
        [void](Invoke-CanonButton -Snapshot $button -How post)
    } else {
        Write-Remax ("Dialog button " + ($labels -join '/') + " was not found.")
    }
    if ($handle -eq [IntPtr]::Zero) { return }
    if (Wait-WindowClosed -Handle $handle -TimeoutMs (Get-UserNameWaitMs 10000)) { return }
    Write-Remax "Dialog did not close within 10 seconds. Sending WM_CLOSE."
    if ('RemaxWin1210' -as [type]) {
        try { [RemaxWin1210]::CloseWindow($handle) } catch { }
    }
    if (Wait-WindowClosed -Handle $handle -TimeoutMs (Get-UserNameWaitMs 2000)) { return }
    Write-Remax "Dialog still open. Sending Escape."
    $paused = $false
    try { $paused = Suspend-InputLock } catch { $paused = $false }
    try {
        if ('RemaxWin1210' -as [type]) {
            [void][RemaxWin1210]::SetFocus($handle)
            [RemaxWin1210]::TapEscape
        }
    } catch { }
    finally {
        if ($paused) {
            try { Resume-InputLock } catch { }
        }
    }
    if (-not (Wait-WindowClosed -Handle $handle -TimeoutMs (Get-UserNameWaitMs 2000))) {
        Write-Remax "Dialog remained open after WM_CLOSE and Escape."
    }
}

function Update-DefaultValueDialog {
    param($Window, $Button, [string]$PrintUser, [int]$ProcessId, [switch]$ReadOnly)
    $result = @{ Opened = $false; Read = $null }
    $props = [IntPtr]::Zero
    try { $props = [IntPtr]$Window.Current.NativeWindowHandle } catch { $props = [IntPtr]::Zero }
    $dlg = Open-ChildDialogFast -Button $Button -ProcessId $ProcessId -Exclude @($props) -TitleAny @('*User Information Settings*', '*Default Value Settings*')
    if (-not $dlg) {
        Write-Remax "User Information Settings did not open from Settings..."
        return $result
    }
    $title = ''
    try { $title = [string]$dlg.Current.Name } catch { $title = '' }
    $result.Opened = $true
    Show-CanonWindow $dlg
    Write-Remax ("Settings dialog opened (" + $title + ").")
    if (Test-UserInformationTitle $title) {
        $elements = @()
        try { $elements = Get-UiaDescendants $dlg } catch { $elements = @() }
        Write-UiaSummary $elements
        if (-not $ReadOnly) {
            $edit = Find-CanonEditByLabel -Elements $elements -Labels @('User Name')
            if (-not $edit -and ('RemaxWin1210' -as [type])) {
                $dlgHwnd = [IntPtr]::Zero
                try { $dlgHwnd = [IntPtr]$dlg.Current.NativeWindowHandle } catch { $dlgHwnd = [IntPtr]::Zero }
                $editHwnd = [IntPtr]::Zero
                if ($dlgHwnd -ne [IntPtr]::Zero) {
                    try { $editHwnd = [RemaxWin1210]::TopEdit($dlgHwnd) } catch { $editHwnd = [IntPtr]::Zero }
                }
                if ($editHwnd -ne [IntPtr]::Zero) {
                    Write-Remax ("User Name edit located by FindWindowEx hwnd=" + $editHwnd)
                    try {
                        $editEl = [System.Windows.Automation.AutomationElement]::FromHandle($editHwnd)
                        $edit = Get-UiaSnapshot $editEl
                    } catch {
                        Write-Remax ("User Name edit handle could not be wrapped: " + $_.Exception.Message)
                    }
                }
            }
            if ($edit) {
                $wrote = Set-UserNameEditText -Snapshot $edit -Text $PrintUser
                Write-Remax ("User Information Settings User Name method " + $wrote.Method + " read-back '" + $wrote.Value + "'")
                $elements = @()
                try { $elements = Get-UiaDescendants $dlg } catch { $elements = @() }
            } else {
                Write-Remax "User Information Settings had no User Name text box."
            }
            if (-not (Test-UserNameBudget)) {
                Write-Remax "Username stage exceeded 60 seconds. Closing User Information Settings."
                Close-UserDialog -Window $dlg
                return $result
            }
            $defaults = Select-LabeledControl -Elements $elements -Labels @('Default Value Settings') -ControlType 'Button'
            if ($defaults) {
                $nested = Open-ChildDialogFast -Button $defaults -ProcessId $ProcessId -Exclude @($props) -TitleLike '*Default Value Settings*'
                $nestedTitle = ''
                if ($nested) {
                    try { $nestedTitle = [string]$nested.Current.Name } catch { $nestedTitle = '' }
                }
                if ($nested -and (Test-DefaultValueTitle $nestedTitle)) {
                    Write-Remax "Default Value Settings opened from User Information Settings."
                    [void](Set-DefaultValueOnWindow -Window $nested -PrintUser $PrintUser)
                    Close-UserDialog -Window $nested -Save
                } else {
                    Write-Remax "Default Value Settings button did not open that dialog."
                    if ($nested) { Close-UserDialog -Window $nested }
                }
            } else {
                Write-Remax "User Information Settings had no Default Value Settings button."
            }
        }
        $elements = @()
        try { $elements = Get-UiaDescendants $dlg } catch { $elements = @() }
        $direct = Read-UserNameEditValue $elements
        $result.Read = Read-DefaultValueFromElements -Elements $elements -PrintUser $PrintUser
        if (-not [string]::IsNullOrWhiteSpace($direct)) {
            $result.Read.Name = $direct
            $result.Read.NameSeen = $true
        }
        if ($ReadOnly) {
            Close-UserDialog -Window $dlg
        } else {
            Close-UserDialog -Window $dlg -Save
        }
        return $result
    }
    if (-not (Test-DefaultValueTitle $title)) {
        Write-Remax ("Opened window '" + $title + "' is not User Information Settings. Closing it.")
        Close-UserDialog -Window $dlg
        $result.Opened = $false
        return $result
    }
    if (-not $ReadOnly) {
        [void](Set-DefaultValueOnWindow -Window $dlg -PrintUser $PrintUser)
    }
    $elements = @()
    try { $elements = Get-UiaDescendants $dlg } catch { $elements = @() }
    Write-UiaSummary $elements
    $result.Read = Read-DefaultValueFromElements -Elements $elements -PrintUser $PrintUser
    if ($ReadOnly) {
        Close-UserDialog -Window $dlg
    } else {
        Close-UserDialog -Window $dlg -Save
    }
    return $result
}

function Dismiss-CanonPrompt {
    param([int]$ProcessId, [IntPtr]$Keep)
    if ($ProcessId -le 0) { return $false }
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
        $ProcessId
    )
    $windows = $null
    try { $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond) } catch { return $false }
    foreach ($window in @($windows)) {
        if (-not $window) { continue }
        $handle = [IntPtr]::Zero
        try { $handle = [IntPtr]$window.Current.NativeWindowHandle } catch { $handle = [IntPtr]::Zero }
        if ($Keep -ne [IntPtr]::Zero -and $handle -eq $Keep) { continue }
        $name = ''
        try { $name = [string]$window.Current.Name } catch { $name = '' }
        if ($name -like '*Properties*') { continue }
        $elements = @()
        try { $elements = Get-UiaDescendants $window } catch { $elements = @() }
        $labels = @()
        foreach ($el in @(Get-CanonElements $elements)) {
            if ($el -and $el.ControlType -eq 'Button') { $labels += [string]$el.Name }
        }
        $pick = Resolve-ConfirmButtonLabel -Labels $labels
        if (-not $pick) { continue }
        $button = Select-LabeledControl -Elements $elements -Labels @($pick) -ControlType 'Button'
        if (-not $button) { continue }
        Write-Remax ("Confirmation '" + $name + "' clicking " + $pick)
        Show-CanonWindow $window
        [void](Invoke-CanonButton -Snapshot $button -How post)
        Start-Sleep -Milliseconds 300
        return $true
    }
    return $false
}

function Test-ComboTextMatches {
    param([string]$Text, [string]$Want)
    if ([string]::IsNullOrWhiteSpace($Text) -or [string]::IsNullOrWhiteSpace($Want)) { return $false }
    if (Test-CanonLabelEquals $Text $Want) { return $true }
    if (Test-LooseLabelEquals $Text $Want) { return $true }
    $wantFinisher = Resolve-FinisherLabel -Labels @($Want)
    $textFinisher = Resolve-FinisherLabel -Labels @($Text)
    if ($wantFinisher -and $textFinisher) { return $true }
    return $false
}

function Set-Win32ComboValue {
    param($Snapshot, [string]$Want)
    if (-not $Snapshot -or -not $Snapshot.Element) { return $false }
    if (-not ('RemaxWin1210' -as [type])) { return $false }
    $hwnd = [IntPtr]::Zero
    try { $hwnd = [IntPtr]$Snapshot.Element.Current.NativeWindowHandle } catch { $hwnd = [IntPtr]::Zero }
    if ($hwnd -eq [IntPtr]::Zero) { return $false }
    $index = [RemaxWin1210]::ComboFindExact($hwnd, $Want)
    if ($index -lt 0 -and (Test-LooseLabelEquals $Want 'Inner Finisher E1')) {
        $index = [RemaxWin1210]::ComboFindExact($hwnd, 'Inner Finisher-E1')
        if ($index -lt 0) { $index = [RemaxWin1210]::ComboFindExact($hwnd, 'Inner Finisher E1') }
    }
    if ($index -ge 0) {
        [void][RemaxWin1210]::ComboSetCurSel($hwnd, $index)
        [RemaxWin1210]::NotifySelChange($hwnd)
        Start-Sleep -Milliseconds 250
        $shown = [RemaxWin1210]::ComboGetLbText($hwnd, $index)
        if (-not $shown) { $shown = [RemaxWin1210]::WindowText($hwnd) }
        Write-Remax ("CB_SETCURSEL " + $index + " text '" + $shown + "'")
        if (Test-ComboTextMatches $shown $Want) { return $true }
        if (Test-CanonLabelEquals $shown $Want) { return $true }
    }
    Write-Remax "Combo list text was not exposed. Sending Home and Down until the value matches."
    $paused = Suspend-InputLock
    $landed = $false
    try {
        [void][RemaxWin1210]::SetFocus($hwnd)
        Start-Sleep -Milliseconds 150
        [RemaxWin1210]::TapKey(0x24)
        Start-Sleep -Milliseconds 150
        $step = 0
        while ($step -lt 24) {
            $cur = [RemaxWin1210]::ComboGetCurSel($hwnd)
            $shown = ''
            if ($cur -ge 0) { $shown = [RemaxWin1210]::ComboGetLbText($hwnd, $cur) }
            if (-not $shown) { $shown = [RemaxWin1210]::WindowText($hwnd) }
            if (Test-ComboTextMatches $shown $Want) {
                [RemaxWin1210]::NotifySelChange($hwnd)
                Write-Remax ("Key selection landed on '" + $shown + "'")
                $landed = $true
                break
            }
            [RemaxWin1210]::TapKey(0x28)
            Start-Sleep -Milliseconds 120
            $step = $step + 1
        }
        if (-not $landed) { [RemaxWin1210]::NotifySelChange($hwnd) }
    } finally {
        if ($paused) { Resume-InputLock }
    }
    return $landed
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

function Select-UiaTab {
    param($Window, [string]$TabName)
    if (-not $Window -or [string]::IsNullOrWhiteSpace($TabName)) { return $false }
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::TabItem
    )
    $tabs = $null
    try {
        $tabs = $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
    } catch {
        Write-Remax ("Tab search failed: " + $_.Exception.Message)
        return $false
    }
    foreach ($tab in @($tabs)) {
        if (-not $tab) { continue }
        $name = ''
        try { $name = [string]$tab.Current.Name } catch { $name = '' }
        if (-not (Test-CanonLabelEquals $name $TabName)) { continue }
        $pattern = $null
        try {
            if ($tab.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) {
                $pattern.Select()
                Write-Remax ("Selected tab " + $name)
                return $true
            }
        } catch {
            Write-Remax ("Tab select failed: " + $_.Exception.Message)
        }
        $pattern = $null
        try {
            if ($tab.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
                $pattern.Invoke()
                Write-Remax ("Invoked tab " + $name)
                return $true
            }
        } catch {
            Write-Remax ("Tab invoke failed: " + $_.Exception.Message)
        }
        Write-Remax ("Tab '" + $name + "' had no selection pattern.")
        return $false
    }
    Write-Remax ("Tab '" + $TabName + "' was not found.")
    return $false
}

function Set-CanonDeviceOnWindow {
    param($Window, [string]$PrintUser, [int]$ProcessId, [string]$Scope)
    if ([string]::IsNullOrWhiteSpace($Scope)) { $Scope = 'all' }
    $doHardware = ($Scope -eq 'all' -or $Scope -eq 'hardware')
    $doUser = ($Scope -eq 'all' -or $Scope -eq 'user')
    Show-CanonWindow $Window
    $tabOk = Select-UiaTab -Window $Window -TabName 'Device Settings'
    if (-not $tabOk) { return }
    Start-Sleep -Milliseconds 500
    $elements = Get-UiaDescendants $Window
    Write-UiaSummary $elements
    $targets = Find-CanonDeviceTargets $elements
    if ($doHardware -and $targets.Profile) {
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
    $keep = [IntPtr]::Zero
    try { $keep = [IntPtr]$Window.Current.NativeWindowHandle } catch { $keep = [IntPtr]::Zero }
    if ($doHardware -and $targets.PaperCheck) {
        $ok = Set-CanonCheck -Snapshot $targets.PaperCheck -On $true
        Write-Remax ("Cassette Feeding Unit checkbox set On: " + $ok)
        Start-Sleep -Milliseconds 300
        [void](Dismiss-CanonPrompt -ProcessId $ProcessId -Keep $keep)
        $elements = Get-UiaDescendants $Window
        $targets = Find-CanonDeviceTargets $elements
    } elseif ($doHardware -and $targets.PaperCombo) {
        $ok = Set-CanonComboToLabel -Combo $targets.PaperCombo -Kind 'paper'
        Write-Remax ("Paper Source Options combo set to Cassette Feeding Unit: " + $ok)
        Start-Sleep -Milliseconds 300
        [void](Dismiss-CanonPrompt -ProcessId $ProcessId -Keep $keep)
        $elements = Get-UiaDescendants $Window
        $targets = Find-CanonDeviceTargets $elements
    } elseif ($doHardware) {
        Write-Remax "Cassette Feeding Unit checkbox and Paper Source Options combo were not found."
    }
    if ($doHardware -and $targets.OutputCombo) {
        $ok = Set-CanonComboToLabel -Combo $targets.OutputCombo -Kind 'output'
        if (-not $ok) {
            $ok = Set-Win32ComboValue -Snapshot $targets.OutputCombo -Want 'Inner Finisher E1'
        }
        Write-Remax ("Output Options set to Inner Finisher E1: " + $ok)
        Start-Sleep -Milliseconds 300
        [void](Dismiss-CanonPrompt -ProcessId $ProcessId -Keep $keep)
        $elements = Get-UiaDescendants $Window
        $targets = Find-CanonDeviceTargets $elements
    } elseif ($doHardware) {
        Write-Remax "Output Options combo was not found."
    }
    $psChoice = Get-PsOutputChoice
    if ($doHardware -and $psChoice -and $targets.PsOutput) {
        Write-Remax ("REMAX_PS_OUTPUT is '" + $psChoice + "'.")
        $opened = Get-CanonComboChoices $targets.PsOutput
        $pick = Resolve-CanonChoiceLabel -Labels $opened.Labels -Accept @($psChoice)
        if ($pick) {
            [void](Select-ListedComboItem -Items $opened.Items -Label $pick -Combo $targets.PsOutput)
        } else {
            Collapse-CanonCombo $targets.PsOutput
            [void](Set-Win32ComboValue -Snapshot $targets.PsOutput -Want $psChoice)
        }
    } elseif ($doHardware) {
        Write-Remax "PS Output from Application left unchanged."
    }
    if ($doHardware) {
        $elements = Get-UiaDescendants $Window
        $apply = Select-LabeledControl -Elements $elements -Labels @('Apply') -ControlType 'Button'
        if ($apply -and $apply.Enabled) {
            Write-Remax "Apply after Paper Source and Output Options."
            [void](Invoke-CanonButton -Snapshot $apply -How post)
            Start-Sleep -Milliseconds 400
            [void](Dismiss-CanonPrompt -ProcessId $ProcessId -Keep $keep)
        }
        $elements = Get-UiaDescendants $Window
        $targets = Find-CanonDeviceTargets $elements
    }
    if (-not $doUser) { return }
    if ($targets.UserInfo -and $targets.UserInfo.Toggle -ne 'On') {
        [void](Set-CanonCheck -Snapshot $targets.UserInfo -On $true)
        Start-Sleep -Milliseconds 300
        $elements = Get-UiaDescendants $Window
        $targets = Find-CanonDeviceTargets $elements
    } elseif ($targets.UserInfo) {
        Write-Remax "Set User Information is already on. The print username is still written."
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
    param($Window, [string]$PrintUser, [int]$ProcessId, [switch]$DeviceOnly)
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
    if ($targets.PaperCheck) {
        $read.PaperSeen = $true
        if ($targets.PaperCheck.Toggle -eq 'On') {
            $read.PaperValue = 'Cassette Feeding Unit'
        } else {
            $read.PaperValue = 'Off'
        }
    }
    if ($targets.PaperCombo) {
        $comboValue = Get-ComboDisplay $targets.PaperCombo
        if ($comboValue -and ($read.PaperValue -ne 'Cassette Feeding Unit')) {
            $read.PaperSeen = $true
            $read.PaperValue = $comboValue
        } elseif (-not $read.PaperSeen) {
            $read.PaperSeen = $true
            $read.PaperValue = $comboValue
        }
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
    if ((-not $DeviceOnly) -and $targets.UserSettings) {
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
        $result.PaperDetail = 'Device Settings had no Cassette Feeding Unit checkbox and no Paper Source Options combo.'
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
    if (-not $who) { $who = 'blank' }
    $shown = [string]$Read.UserNameValue
    if (-not $shown) { $shown = 'blank' }
    $userOk = $false
    if ($Read.NameSeen -and $PrintUser -and (Test-UserNameMatch $Read.UserNameValue $PrintUser)) {
        $userOk = $true
    }
    if ($userOk) {
        $result.UserNameState = 'PASS'
        $result.UserNameDetail = 'User Name readback is ' + $Read.UserNameValue
    } elseif ($Read.NameSeen -and $PrintUser) {
        $result.UserNameState = 'FAIL'
        $result.UserNameDetail = 'User Name readback is ' + $shown + '. Expected ' + $who + '.'
    } elseif (-not $Read.UserDialog) {
        $result.UserNameDetail = 'User Information Settings did not open from Settings...'
    } else {
        $result.UserNameState = $wrongState
        $result.UserNameDetail = 'User Name readback is ' + $shown + '. Expected ' + $who + '.'
    }
    if ($Read.ProfileValue) {
        $result.ProfileDetail = 'Config. Profile read back as ' + $Read.ProfileValue + '.'
    }
    return $result
}

function Get-PrintUiRestoreArgument {
    param([string]$Path)
    return ('printui.dll,PrintUIEntry /Sr /n "' + $script:PrinterName + '" /a "' + $Path + '" d g r')
}

function Resolve-DeviceDatRequest {
    $raw = ''
    if ($env:REMAX_DEVICE_DAT) { $raw = $env:REMAX_DEVICE_DAT.Trim() }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{ Kind = 'url'; Location = $script:DeviceDatUrl; Pinned = $true }
    }
    if ($raw -match '^(?i)https?://') {
        $pinned = ($raw -eq $script:DeviceDatUrl)
        return @{ Kind = 'url'; Location = $raw; Pinned = $pinned }
    }
    return @{ Kind = 'file'; Location = $raw; Pinned = $false }
}

function Test-PinnedDeviceDat {
    param([string]$Hash, [long]$Length)
    $problems = New-Object System.Collections.Generic.List[string]
    if ($Length -ne [long]$script:DeviceDatBytes) {
        [void]$problems.Add("size " + $Length + " (expected " + $script:DeviceDatBytes + ")")
    }
    $got = ''
    if ($Hash) { $got = $Hash.Trim().ToLowerInvariant() }
    if ($got -ne $script:DeviceDatSha256) {
        [void]$problems.Add("SHA256 " + $got + " (expected " + $script:DeviceDatSha256 + ")")
    }
    if ($problems.Count -gt 0) {
        $detail = "Device Settings download failed verification. " + ($problems -join '. ') + ". The file was not restored."
        return @{ Ok = $false; Detail = $detail }
    }
    return @{ Ok = $true; Detail = ("SHA256 " + $script:DeviceDatSha256) }
}

function Get-DeviceDatFile {
    $request = Resolve-DeviceDatRequest
    if ($request.Location.Contains('"') -or $request.Location.Contains("'")) {
        return @{ Ok = $false; Detail = 'REMAX_DEVICE_DAT contains a quote. Restore skipped.' }
    }
    if ($request.Kind -eq 'file') {
        if (-not (Test-Path -LiteralPath $request.Location)) {
            return @{ Ok = $false; Detail = ('REMAX_DEVICE_DAT was not found: ' + $request.Location) }
        }
        Write-Remax ("Using local Device Settings file " + $request.Location)
        return @{ Ok = $true; Path = $request.Location; Pinned = $false; Detail = 'local file' }
    }
    $destDir = $script:SupportDir
    if ([string]::IsNullOrWhiteSpace($destDir)) { $destDir = [System.IO.Path]::GetTempPath() }
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    $dest = Join-Path $destDir 'remaxsecure-device-settings.dat'
    Write-Remax ("Downloading Device Settings " + $request.Location)
    try {
        Save-RemaxDownload -Url $request.Location -Destination $dest
    } catch {
        return @{ Ok = $false; Detail = ("Device Settings download failed: " + $_.Exception.Message) }
    }
    $length = [long](Get-Item -LiteralPath $dest).Length
    $hash = Get-FileSha256 $dest
    Write-Remax ("Device Settings file size " + $length + ", SHA256 " + $hash)
    if ($request.Pinned) {
        $check = Test-PinnedDeviceDat -Hash $hash -Length $length
        if (-not $check.Ok) {
            Write-Remax $check.Detail
            return @{ Ok = $false; Detail = $check.Detail; Path = $dest }
        }
        Write-Remax $check.Detail
    } else {
        Write-Remax "REMAX_DEVICE_DAT is not the built-in file, so the pinned SHA256 is not applied."
    }
    return @{ Ok = $true; Path = $dest; Pinned = [bool]$request.Pinned; Detail = $hash }
}

function Invoke-PrintUiRestore {
    param([string]$Path)
    $rundll = Get-RemaxRundllPath
    $arg = Get-PrintUiRestoreArgument $Path
    Write-Remax ("Restoring Device Settings from " + $Path)
    Write-Remax ($rundll + ' ' + $arg)
    $global:LASTEXITCODE = 0
    $proc = $null
    try {
        $proc = Start-Process -FilePath $rundll -ArgumentList @(
            'printui.dll,PrintUIEntry',
            '/Sr',
            '/n',
            $script:PrinterName,
            '/a',
            $Path,
            'd',
            'g',
            'r'
        ) -Wait -PassThru -WindowStyle Hidden
    } catch {
        $detail = "PrintUI restore did not start: " + $_.Exception.Message
        Write-Remax $detail
        return @{ Ok = $false; ExitCode = 1; LastExitCode = $global:LASTEXITCODE; Detail = $detail }
    }
    $code = 1
    if ($proc -and $null -ne $proc.ExitCode) { $code = [int]$proc.ExitCode }
    $last = $global:LASTEXITCODE
    Write-Remax ("PrintUI /Sr process exit " + $code)
    Write-Remax ("LASTEXITCODE after PrintUI /Sr: " + $last)
    $ok = ($code -eq 0)
    if ($null -ne $last -and ([int]$last) -ne 0) {
        Write-Remax "LASTEXITCODE is not 0. Treating the PrintUI restore as failed."
        $ok = $false
    }
    $global:LASTEXITCODE = $code
    return @{ Ok = $ok; ExitCode = $code; LastExitCode = $last; Detail = ("PrintUI /Sr exit " + $code + ", LASTEXITCODE " + $last) }
}

function Restore-CanonDeviceDat {
    param([string]$Path)
    $result = Invoke-PrintUiRestore -Path $Path
    return [bool]$result.Ok
}

function Get-PrinterDriverDataPath {
    return ('HKLM:\SYSTEM\CurrentControlSet\Control\Print\Printers\' + $script:PrinterName + '\PrinterDriverData')
}

function Format-DriverDataValue {
    param($Raw, [string]$Kind)
    if ($null -eq $Raw) { return ($Kind + ':') }
    if ($Raw -is [byte[]]) {
        $hash = ''
        try { $hash = Get-BytesSha256 -Data $Raw } catch { $hash = 'unread' }
        return ('bytes:' + $Raw.Length + ':' + $hash)
    }
    $text = [string]$Raw
    if ($text.Length -gt 180) { $text = $text.Substring(0, 180) + '...(len ' + $text.Length + ')' }
    return ($Kind + ':' + $text)
}

function Get-PrinterDriverDataSnapshot {
    $path = Get-PrinterDriverDataPath
    $map = @{}
    if (-not (Test-Path -LiteralPath $path)) { return $map }
    try {
        $key = Get-Item -LiteralPath $path
        foreach ($name in @($key.GetValueNames())) {
            $label = [string]$name
            if ([string]::IsNullOrEmpty($label)) { $label = '(default)' }
            $raw = $null
            $kind = ''
            try { $raw = $key.GetValue($name) } catch { $raw = $null }
            try { $kind = [string]$key.GetValueKind($name) } catch { $kind = '' }
            $map[$label] = Format-DriverDataValue -Raw $raw -Kind $kind
        }
    } catch {
        Write-Remax ("PrinterDriverData snapshot failed: " + $_.Exception.Message)
    }
    return $map
}

function Get-DriverDataChangeCount {
    param($Before, $After)
    if (-not $Before) { $Before = @{} }
    if (-not $After) { $After = @{} }
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($Before.Keys)) {
        $text = [string]$name
        if (-not $names.Contains($text)) { [void]$names.Add($text) }
    }
    foreach ($name in @($After.Keys)) {
        $text = [string]$name
        if (-not $names.Contains($text)) { [void]$names.Add($text) }
    }
    $changed = 0
    foreach ($name in $names) {
        $left = ''
        $right = ''
        if ($Before.Contains($name)) { $left = [string]$Before[$name] }
        if ($After.Contains($name)) { $right = [string]$After[$name] }
        if ($left -ne $right) { $changed = $changed + 1 }
    }
    return $changed
}

function Write-PrinterDriverDataDiff {
    param($Before, $After)
    if (-not $Before) { $Before = @{} }
    if (-not $After) { $After = @{} }
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($Before.Keys)) {
        $text = [string]$name
        if (-not $names.Contains($text)) { [void]$names.Add($text) }
    }
    foreach ($name in @($After.Keys)) {
        $text = [string]$name
        if (-not $names.Contains($text)) { [void]$names.Add($text) }
    }
    $changed = 0
    foreach ($name in $names) {
        $left = ''
        $right = ''
        if ($Before.Contains($name)) { $left = [string]$Before[$name] }
        if ($After.Contains($name)) { $right = [string]$After[$name] }
        if ($left -ne $right) {
            $changed = $changed + 1
            Write-Remax ("PrinterDriverData changed " + $name + " from [" + $left + "] to [" + $right + "]")
        }
    }
    Write-Remax ("PrinterDriverData values changed: " + $changed)
    return $changed
}

function Test-PaperSourceUnset {
    param($Read)
    if (-not $Read -or -not $Read.PaperSeen) { return $false }
    $match = Resolve-PaperSourceLabel -Labels @([string]$Read.PaperValue)
    if ($match) { return $false }
    return $true
}

function Test-OutputOptionsUnset {
    param($Read)
    if (-not $Read -or -not $Read.OutputSeen) { return $false }
    $match = Resolve-FinisherLabel -Labels @([string]$Read.OutputValue)
    if ($match) { return $false }
    return $true
}

function Test-DatRestoreConfirmed {
    param([bool]$RestoreOk, [bool]$PaperUnset, [bool]$OutputUnset, [bool]$PaperSeen, [bool]$OutputSeen, [int]$Changed)
    if (-not $RestoreOk) { return $false }
    if ($PaperUnset -or $OutputUnset) { return $false }
    if ($PaperSeen -and $OutputSeen) { return $true }
    if ($Changed -gt 0) { return $true }
    return $false
}

function Protect-QueueIdentity {
    $printer = Get-PrinterOrNull $script:PrinterName
    if (-not $printer) {
        Write-Remax "RemaxSecure was missing after the PrintUI restore."
        return $false
    }
    $port = ''
    $name = ''
    try { $port = [string]$printer.PortName } catch { $port = '' }
    try { $name = [string]$printer.Name } catch { $name = '' }
    Write-Remax ("Queue after PrintUI restore: name " + $name + ", port " + $port)
    if ($name -and $name -ne $script:PrinterName) {
        Write-Remax ("Printer name changed to " + $name + ".")
        return $false
    }
    if ($port -and $port -ne $script:PortName) {
        Write-Remax ("Port changed to " + $port + ". Setting it back to " + $script:PortName + ".")
        try {
            Set-Printer -Name $script:PrinterName -PortName $script:PortName
            Write-Remax ("Port is " + $script:PortName + " again.")
        } catch {
            Write-Remax ("Could not restore the port name: " + $_.Exception.Message)
            return $false
        }
    }
    return $true
}

function Invoke-DeviceSettingsReadOnly {
    $result = @{
        Opened      = $false
        PaperSeen   = $false
        PaperValue  = ''
        OutputSeen  = $false
        OutputValue = ''
        Error       = ''
    }
    $skip = Get-DeviceUiSkipReason
    if ($skip) {
        $result.Error = $skip
        Write-Remax ("Device Settings readback skipped: " + $skip)
        return $result
    }
    try {
        Initialize-RemaxUi
    } catch {
        $result.Error = $_.Exception.Message
        Write-Remax ("UI Automation could not load for readback: " + $result.Error)
        return $result
    }
    Enter-InputLock
    $session = $null
    try {
        $session = Open-RemaxProperties
        if (-not $session.Window) {
            $result.Error = [string]$session.Error
            Write-Remax ("Device Settings readback did not open: " + $result.Error)
            return $result
        }
        $read = Read-CanonDeviceFromWindow -Window $session.Window -PrintUser '' -ProcessId $session.Process.Id -DeviceOnly
        $result.Opened = [bool]$read.Opened
        $result.PaperSeen = [bool]$read.PaperSeen
        $result.PaperValue = [string]$read.PaperValue
        $result.OutputSeen = [bool]$read.OutputSeen
        $result.OutputValue = [string]$read.OutputValue
        $result.Error = [string]$read.Error
        Write-Remax ("Device Settings readback Cassette Feeding Unit='" + $result.PaperValue + "' seen=" + $result.PaperSeen + " Output Options='" + $result.OutputValue + "' seen=" + $result.OutputSeen)
        Close-RemaxProperties -Session $session
    } catch {
        $result.Error = $_.Exception.Message
        Write-Remax ("Device Settings readback failed: " + $result.Error)
    } finally {
        Exit-InputLock
        if ($session -and $session.Process) { Stop-RemaxUiProcess $session.Process }
    }
    return $result
}

function Restart-SpoolerForReadback {
    Write-Remax "Device Settings readback did not confirm the restore. Restarting the Print Spooler and reading again."
    try {
        Restart-Service Spooler -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        Write-Remax "Print Spooler restarted."
    } catch {
        Write-Remax ("Restart-Service Spooler failed: " + $_.Exception.Message)
    }
}

function Invoke-RemaxDeviceSettings {
    param([string]$PrintUser)
    Show-RemaxProgress 'Device Settings'
    try {
        $rows = @(Get-PrinterProperty -PrinterName $script:PrinterName -ErrorAction Stop)
        Write-PrinterPropertyInventory $rows
    } catch {
        Write-Remax ("Get-PrinterProperty failed: " + $_.Exception.Message)
    }
    $before = Get-PrinterDriverDataSnapshot
    Write-Remax ("PrinterDriverData values before restore: " + @($before.Keys).Count)
    $file = Get-DeviceDatFile
    $restore = @{ Ok = $false; ExitCode = 1; LastExitCode = 1; Detail = [string]$file.Detail }
    if ($file.Ok) {
        try {
            $restore = Invoke-PrintUiRestore -Path $file.Path
        } catch {
            $restore = @{ Ok = $false; ExitCode = 1; LastExitCode = $global:LASTEXITCODE; Detail = $_.Exception.Message }
            Write-Remax ("PrintUI restore failed: " + $_.Exception.Message)
        }
    } else {
        Write-Remax $file.Detail
    }
    try {
        $mode = Set-OneSided
        Write-Remax ("DuplexingMode readback after PrintUI restore: " + $mode)
    } catch {
        Write-Remax ("One-sided setting failed after PrintUI restore: " + $_.Exception.Message)
    }
    [void](Protect-QueueIdentity)
    Start-Sleep -Seconds 1
    $after = Get-PrinterDriverDataSnapshot
    $changed = Write-PrinterDriverDataDiff -Before $before -After $after
    $read = Invoke-DeviceSettingsReadOnly
    $paperUnset = Test-PaperSourceUnset $read
    $outputUnset = Test-OutputOptionsUnset $read
    $confirmed = Test-DatRestoreConfirmed -RestoreOk ([bool]$restore.Ok) -PaperUnset $paperUnset -OutputUnset $outputUnset -PaperSeen ([bool]$read.PaperSeen) -OutputSeen ([bool]$read.OutputSeen) -Changed $changed
    if (-not $confirmed -and $restore.Ok) {
        Restart-SpoolerForReadback
        [void](Protect-QueueIdentity)
        try {
            $mode = Set-OneSided
            Write-Remax ("DuplexingMode readback after spooler restart: " + $mode)
        } catch {
            Write-Remax ("One-sided setting failed after spooler restart: " + $_.Exception.Message)
        }
        $after = Get-PrinterDriverDataSnapshot
        $changed = Write-PrinterDriverDataDiff -Before $before -After $after
        $read = Invoke-DeviceSettingsReadOnly
        $paperUnset = Test-PaperSourceUnset $read
        $outputUnset = Test-OutputOptionsUnset $read
        $confirmed = Test-DatRestoreConfirmed -RestoreOk ([bool]$restore.Ok) -PaperUnset $paperUnset -OutputUnset $outputUnset -PaperSeen ([bool]$read.PaperSeen) -OutputSeen ([bool]$read.OutputSeen) -Changed $changed
    }
    $ui = $null
    if ($confirmed) {
        Write-Remax "Device Settings restored from the PrintUI file. Skipping Paper Source and Output Options clicks."
        $ui = New-DeviceUiResult
        $ui.PaperState = 'PASS'
        $ui.PaperDetail = 'Cassette Feeding Unit (source: dat)'
        $ui.OutputState = 'PASS'
        $ui.OutputDetail = 'Inner Finisher E1 (source: dat)'
    } else {
        Write-Remax "PrintUI restore did not confirm Cassette Feeding Unit and Inner Finisher E1. Falling back to UI Automation clicks."
        try {
            $ui = Invoke-CanonDeviceAutomation -PrintUser $PrintUser -Action 'apply' -Scope 'hardware'
        } catch {
            Write-Remax ("Paper Source and Output Options click fallback failed: " + $_.Exception.Message)
            $ui = New-DeviceUiResult
            $ui.Attempted = $true
            $ui.PaperDetail = $_.Exception.Message
            $ui.OutputDetail = $_.Exception.Message
        }
    }
    $nameBefore = Get-PrinterDriverDataSnapshot
    Write-Remax ("Looking for exported print username '" + $script:ExportedPrintUser + "' in PrinterDriverData and per-user DevMode.")
    try {
        [void](Write-UserNameRegistryHits -OldName $script:ExportedPrintUser -NewName $PrintUser -Write)
        try { [void](Invoke-UserNameDevModePatch -PrintUser $PrintUser) } catch {
            Write-Remax ("SetPrinter DevMode patch failed: " + $_.Exception.Message)
        }
    } catch {
        Write-Remax ("Registry user name replace failed: " + $_.Exception.Message)
    }
    $named = Invoke-PrintUserName -PrintUser $PrintUser
    $nameAfter = Get-PrinterDriverDataSnapshot
    [void](Write-PrinterDriverDataDiff -Before $nameBefore -After $nameAfter)
    try { [void](Write-UserNameRegistryHits -OldName $script:ExportedPrintUser -NewName '') } catch { }
    if (-not $ui) { $ui = New-DeviceUiResult }
    if ($named) {
        $ui.Attempted = $true
        $ui.UserInfoState = [string]$named.UserInfoState
        $ui.UserInfoDetail = [string]$named.UserInfoDetail
        $ui.UserNameState = [string]$named.UserNameState
        $ui.UserNameDetail = [string]$named.UserNameDetail
        if ($named.ProfileDetail) { $ui.ProfileDetail = [string]$named.ProfileDetail }
    }
    return $ui
}

function Start-UserNameWatchdog {
    Stop-UserNameWatchdog
    $script:UserNameDeadline = [DateTime]::UtcNow.AddSeconds(60)
    $runner = [powershell]::Create()
    $null = $runner.AddScript({
        Start-Sleep -Seconds 60
        $definition = @"
using System;
using System.Runtime.InteropServices;
public static class RemaxUserNameWatch {
    [DllImport("user32.dll")]
    public static extern bool BlockInput(bool fBlockIt);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
}
"@
        try { Add-Type -TypeDefinition $definition -Language CSharp } catch { }
        try { [void][RemaxUserNameWatch]::BlockInput($false) } catch { }
        try {
            $hwnd = [RemaxUserNameWatch]::GetForegroundWindow()
            $title = ''
            if ($hwnd -ne [IntPtr]::Zero) {
                $sb = New-Object System.Text.StringBuilder 512
                [void][RemaxUserNameWatch]::GetWindowText($hwnd, $sb, 512)
                $title = $sb.ToString()
            }
            $keep = $false
            if ($title -like '*User Information Settings*') { $keep = $true }
            if ($title -like '*Default Value Settings*') { $keep = $true }
            if ($title -like '*Properties*') { $keep = $true }
            if (-not $keep -and $hwnd -ne [IntPtr]::Zero) {
                [void][RemaxUserNameWatch]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
            }
        } catch { }
    })
    $script:UserNameWatch = $runner
    $script:UserNameWatchHandle = $runner.BeginInvoke()
}

function Stop-UserNameWatchdog {
    $runner = $script:UserNameWatch
    $script:UserNameDeadline = $null
    if (-not $runner) { return }
    try { $runner.Stop() } catch { }
    try {
        if ($script:UserNameWatchHandle) { $runner.EndInvoke($script:UserNameWatchHandle) }
    } catch { }
    try { $runner.Dispose() } catch { }
    $script:UserNameWatch = $null
    $script:UserNameWatchHandle = $null
}

function Invoke-PrintUserName {
    param([string]$PrintUser)
    Start-UserNameWatchdog
    $last = $null
    try {
        $attempt = 1
        while ($attempt -le 2) {
            if (-not (Test-UserNameBudget)) {
                Write-Remax "Username stage exceeded 60 seconds."
                break
            }
            Write-Remax ("Setting print username '" + $PrintUser + "' after the Device Settings restore (attempt " + $attempt + ").")
            try {
                $last = Invoke-CanonDeviceAutomation -PrintUser $PrintUser -Action 'apply' -Scope 'user'
            } catch {
                Write-Remax ("Print username automation failed: " + $_.Exception.Message)
                $last = New-DeviceUiResult
                $last.Attempted = $true
                $last.UserNameState = 'FAIL'
                $last.UserNameDetail = "User Name was not set: " + $_.Exception.Message
            }
            if ($last -and [string]$last.UserNameState -eq 'PASS') { return $last }
            $shown = ''
            if ($last) { $shown = [string]$last.UserNameDetail }
            Write-Remax ("User Name attempt " + $attempt + " did not read back '" + $PrintUser + "'. " + $shown)
            $attempt = $attempt + 1
        }
    } finally {
        Stop-UserNameWatchdog
    }
    if (-not $last) { $last = New-DeviceUiResult }
    $last.Attempted = $true
    if ([string]$last.UserNameState -ne 'FAIL') {
        $last.UserNameState = 'FAIL'
    }
    if ([string]::IsNullOrWhiteSpace([string]$last.UserNameDetail)) {
        $last.UserNameDetail = "User Name readback is not " + $PrintUser + "."
    }
    return $last
}

function Test-SkipInputLock {
    return ($env:REMAX_NO_INPUT_LOCK -eq '1')
}

function Get-RemaxProgressPlan {
    return @(
        @{ Stage = 'Cleanup'; Percent = 10 }
        @{ Stage = 'Firewall'; Percent = 20 }
        @{ Stage = 'Download driver'; Percent = 30 }
        @{ Stage = 'Install driver'; Percent = 40 }
        @{ Stage = 'Port'; Percent = 50 }
        @{ Stage = 'Printer'; Percent = 60 }
        @{ Stage = 'Defaults'; Percent = 70 }
        @{ Stage = 'Device Settings'; Percent = 80 }
        @{ Stage = 'Verify'; Percent = 90 }
        @{ Stage = 'Report'; Percent = 100 }
    )
}

function Show-RemaxProgress {
    param([string]$Stage)
    $percent = 0
    foreach ($item in @(Get-RemaxProgressPlan)) {
        if ([string]$item.Stage -eq $Stage) { $percent = [int]$item.Percent }
    }
    try {
        Write-Progress -Activity 'Remax Secure Printer' -Status $Stage -PercentComplete $percent
    } catch { }
    Write-Remax ("Stage: " + $Stage)
}

function Complete-RemaxProgress {
    try {
        Write-Progress -Activity 'Remax Secure Printer' -Completed
    } catch { }
}

function Start-InputUnlockWatchdog {
    Stop-InputUnlockWatchdog
    $runner = [powershell]::Create()
    $null = $runner.AddScript({
        Start-Sleep -Seconds 120
        $definition = @"
using System;
using System.Runtime.InteropServices;
public static class RemaxInputUnlock {
    [DllImport("user32.dll")]
    public static extern bool BlockInput(bool fBlockIt);
}
"@
        try { Add-Type -TypeDefinition $definition -Language CSharp } catch { }
        try { [void][RemaxInputUnlock]::BlockInput($false) } catch { }
    })
    $script:InputLockRunspace = $runner
    $script:InputLockHandle = $runner.BeginInvoke()
}

function Stop-InputUnlockWatchdog {
    $runner = $script:InputLockRunspace
    if (-not $runner) { return }
    try { $runner.Stop() } catch { }
    try {
        if ($script:InputLockHandle) { $runner.EndInvoke($script:InputLockHandle) }
    } catch { }
    try { $runner.Dispose() } catch { }
    $script:InputLockRunspace = $null
    $script:InputLockHandle = $null
}

function Exit-InputLock {
    Stop-InputUnlockWatchdog
    if (-not $script:InputLocked) { return }
    $script:InputLocked = $false
    $script:InputLockSuspended = $false
    if (-not ('RemaxWin1210' -as [type])) { return }
    try { [void][RemaxWin1210]::BlockInput($false) } catch { }
}

function Enter-InputLock {
    if ($script:InputLocked) { return }
    if (Test-SkipInputLock) {
        $script:InputLock = @{ State = 'PASS'; Detail = 'skipped (REMAX_NO_INPUT_LOCK=1)' }
        Write-Remax 'REMAX_NO_INPUT_LOCK=1. Keyboard and mouse stay unlocked.'
        return
    }
    Write-RemaxLine 'Keyboard and mouse are locked for up to 2 minutes while printer settings are applied. Press Ctrl+Alt+Delete to unlock if needed.'
    Start-InputUnlockWatchdog
    $locked = $false
    $lockError = 0
    if ('RemaxWin1210' -as [type]) {
        try {
            $locked = [bool][RemaxWin1210]::TryBlockInput($true, [ref]$lockError)
        } catch {
            $locked = $false
        }
    }
    $script:InputLocked = $locked
    if ($locked) {
        $script:InputLock = @{ State = 'PASS'; Detail = 'Keyboard and mouse were locked during Device Settings, then unlocked.' }
        Write-Remax 'BlockInput returned true.'
    } else {
        $script:InputLock = @{ State = 'PASS'; Detail = ('BlockInput returned false. GetLastError ' + $lockError + '. Input was not locked. The install continued.') }
        Write-Remax ('BlockInput returned false. GetLastError ' + $lockError + '. Input was not locked. The install continued.')
    }
}

function Suspend-InputLock {
    if (-not $script:InputLocked) { return $false }
    if (-not ('RemaxWin1210' -as [type])) { return $false }
    try {
        [void][RemaxWin1210]::BlockInput($false)
        $script:InputLockSuspended = $true
        Write-Remax 'Input lock paused so combo keystrokes can be sent.'
        return $true
    } catch {
        return $false
    }
}

function Resume-InputLock {
    if (-not $script:InputLockSuspended) { return }
    $script:InputLockSuspended = $false
    if (-not ('RemaxWin1210' -as [type])) { return }
    try {
        $lockError = 0
        $locked = [bool][RemaxWin1210]::TryBlockInput($true, [ref]$lockError)
        $script:InputLocked = $locked
        if (-not $locked) {
            Write-Remax ('BlockInput returned false while restoring the input lock. GetLastError ' + $lockError + '.')
        }
    } catch { }
}

function Invoke-CanonDeviceAutomation {
    param([string]$PrintUser, [string]$Action, [string]$Scope)
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
    if ([string]::IsNullOrWhiteSpace($Scope)) { $Scope = 'all' }
    Show-RemaxProgress 'Device Settings'
    Enter-InputLock
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
                    Set-CanonDeviceOnWindow -Window $session.Window -PrintUser $PrintUser -ProcessId $session.Process.Id -Scope $Scope
                } catch {
                    Write-Remax ("Device Settings edit failed: " + $_.Exception.Message)
                }
                Close-RemaxProperties -Session $session -Save
                Start-Sleep -Milliseconds 700
            }
        }
        if (-not $openError) {
            Show-RemaxProgress 'Verify'
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
        Exit-InputLock
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
    Write-Remax ("Get-PrinterProperty inventory for " + $script:PrinterName + " (" + $count + " properties).")
    foreach ($row in @($Rows)) {
        $name = Get-PropertyRowName $row
        $value = Get-PropertyRowValue $row
        if ($value.Length -gt 800) { $value = $value.Substring(0, 800) + '...(len ' + $value.Length + ')' }
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
    return @('CLEANUP', 'DRIVER', 'PORT', 'PRINTER', 'SIDES', 'PAPER SOURCE', 'OUTPUT', 'USER INFO', 'USER NAME', 'FIREWALL', 'REACHABLE', 'INPUT LOCK', 'STALE QUEUE')
}

function Get-ResultLabels {
    $labels = New-Object System.Collections.Generic.List[string]
    foreach ($label in @(Get-StatusLabels)) {
        if ($label -eq 'REACHABLE' -or $label -eq 'INPUT LOCK') { continue }
        [void]$labels.Add($label)
    }
    return @($labels.ToArray())
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
MANUAL means that item was not confirmed. CLEANUP PARTIAL means a removal step failed and the install continued. FIREWALL MANUAL means a third-party product, often Bitdefender, must allow spoolsv.exe to the printer. REACHABLE does not change the exit code. Re-running the installer tries again.
Exit code 2 is not a failed install. When this script is started with irm | iex, exit code 1 and exit code 2 do not throw. LASTEXITCODE is set and this window stays open.
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
    Set-ExtraReportLines $Status
    Show-RemaxProgress 'Report'
    $script:ReportLines = New-Object System.Collections.Generic.List[string]
    $script:CaptureReport = $true
    $order = @(Get-StatusLabels)
    $states = @()
    foreach ($label in @(Get-ResultLabels)) { $states += [string]$Status[$label].State }
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
            'CLEANUP' { 'CLEANUP:      ' }
            'DRIVER' { 'DRIVER:       ' }
            'PORT' { 'PORT:         ' }
            'PRINTER' { 'PRINTER:      ' }
            'SIDES' { 'SIDES:        ' }
            'PAPER SOURCE' { 'PAPER SOURCE: ' }
            'OUTPUT' { 'OUTPUT:       ' }
            'USER INFO' { 'USER INFO:    ' }
            'USER NAME' { 'USER NAME:    ' }
            'FIREWALL' { 'FIREWALL:     ' }
            'REACHABLE' { 'REACHABLE:    ' }
            'INPUT LOCK' { 'INPUT LOCK:   ' }
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
    $script:CaptureReport = $false
    if ($script:ReportLines) { $script:ReportText = ($script:ReportLines -join "`r`n") }
    $script:LastResult = $result
    $script:LastPrintUser = $PrintUser
    $script:LastStatus = $Status
    Complete-RemaxProgress
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
        $driverReport = Get-StandaloneDriverStatus
        $status['DRIVER'].State = [string]$driverReport.State
        $status['DRIVER'].Detail = [string]$driverReport.Detail
        $portSnap = $null
        try { $portSnap = Get-PortSnapshot $script:PortName } catch { $portSnap = $null }
        if ($portSnap -and (Test-PortMatches $portSnap $Target)) {
            $status['PORT'].State = 'PASS'
            $status['PORT'].Detail = Format-PortDetail -Snapshot $portSnap -Target $Target
        } elseif ($portSnap) {
            $status['PORT'].State = 'MANUAL'
            $status['PORT'].Detail = "Port " + $script:PortName + " exists but is not confirmed as LPR to " + $Target.Uri + " with SNMP off. " + (Format-PortDetail -Snapshot $portSnap -Target $Target)
        } else {
            $status['PORT'].Detail = ("expected Standard TCP/IP port " + $script:PortName + " for " + $Target.Uri)
        }
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
                $status['PORT'].State = 'MANUAL'
                $status['PORT'].Detail = ("expected " + $Target.Uri + "; could not read the port (" + $portError + ")")
            } elseif ($snapshot) {
                $status['PORT'].State = 'MANUAL'
                $status['PORT'].Detail = "Port settings are not confirmed. " + (Format-PortDetail -Snapshot $snapshot -Target $Target)
            } else {
                $status['PORT'].Detail = ("expected LPR queue " + $Target.Queue + ", byte counting on, SNMP off; port was not readable")
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
    Set-ExtraReportLines $status
    return $status
}

function Get-StandaloneDriverStatus {
    $selected = $null
    try { $selected = Find-SelectedInstalledDriver } catch { $selected = $null }
    if (-not $selected) {
        return @{ State = 'FAIL'; Detail = ($script:ExactDriverName + ' is not installed') }
    }
    return (Get-DriverReport $selected)
}

function Set-ExtraReportLines {
    param($Status)
    if ($script:Cleanup) {
        $Status['CLEANUP'].State = [string]$script:Cleanup.State
        $Status['CLEANUP'].Detail = [string]$script:Cleanup.Detail
    } else {
        $Status['CLEANUP'].State = 'PASS'
        $Status['CLEANUP'].Detail = 'not run'
    }
    if ($script:Firewall) {
        $Status['FIREWALL'].State = [string]$script:Firewall.State
        $Status['FIREWALL'].Detail = [string]$script:Firewall.Detail
    } else {
        $Status['FIREWALL'].State = 'PASS'
        $Status['FIREWALL'].Detail = 'not run'
    }
    if ($script:Reachable) {
        $Status['REACHABLE'].State = [string]$script:Reachable.State
        $Status['REACHABLE'].Detail = [string]$script:Reachable.Detail
    } else {
        $Status['REACHABLE'].State = 'PASS'
        $Status['REACHABLE'].Detail = 'not run (does not change the exit code)'
    }
    if ($script:InputLock) {
        $Status['INPUT LOCK'].State = [string]$script:InputLock.State
        $Status['INPUT LOCK'].Detail = [string]$script:InputLock.Detail
    } else {
        $Status['INPUT LOCK'].State = 'PASS'
        $Status['INPUT LOCK'].Detail = 'not run (does not change the exit code)'
    }
    if ($script:PortNote -and [string]$script:PortNote.State -ne 'PASS') {
        if ([string]$Status['PORT'].State -ne 'PASS') {
            $Status['PORT'].State = 'MANUAL'
            if ($script:PortNote.Detail) { $Status['PORT'].Detail = [string]$script:PortNote.Detail }
        }
    }
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

function Test-SkipCleanup {
    return ($env:REMAX_SKIP_CLEANUP -eq '1')
}

function Test-SkipFirewall {
    return ($env:REMAX_SKIP_FIREWALL -eq '1')
}

function Test-CleanupPrinter {
    param([string]$Name, [string]$PortName, [string[]]$Names, [string[]]$Ports)
    foreach ($item in @($Names)) {
        if ($Name -eq $item) { return $true }
    }
    foreach ($item in @($Ports)) {
        if ($PortName -eq $item) { return $true }
    }
    return $false
}

function Get-CleanupReport {
    param([bool]$Skipped, [string[]]$Done, [string[]]$Failed, [string]$Note)
    if ($Skipped) {
        return @{ State = 'PASS'; Detail = 'skipped (REMAX_SKIP_CLEANUP=1)' }
    }
    $doneText = ''
    $failText = ''
    if ($Done) { $doneText = ($Done -join '; ') }
    if ($Failed) { $failText = ($Failed -join '; ') }
    if ($failText) {
        $detail = 'Partial cleanup. Failed: ' + $failText
        if ($doneText) { $detail = $detail + '. Removed: ' + $doneText }
        if ($Note) { $detail = $detail + '. ' + $Note }
        return @{ State = 'PARTIAL'; Detail = $detail }
    }
    if (-not $doneText) {
        $detail = 'nothing to remove'
        if ($Note) { $detail = $detail + '. ' + $Note }
        return @{ State = 'PASS'; Detail = $detail }
    }
    $detail = 'Removed ' + $doneText
    if ($Note) { $detail = $detail + '. ' + $Note }
    return @{ State = 'PASS'; Detail = $detail }
}

function Get-PnputilPublishedForOriginal {
    param([string[]]$Lines, [string]$OriginalLeaf)
    $published = ''
    $leaf = $OriginalLeaf.ToLowerInvariant()
    foreach ($line in @($Lines)) {
        $text = [string]$line
        if ($text -match '(?i)Published Name:\s*(oem\d+\.inf)') {
            $published = $Matches[1]
            continue
        }
        if ($text -match '(?i)Original Name:\s*(.+)$') {
            $original = $Matches[1].Trim().ToLowerInvariant()
            $originalLeaf = $original
            $slash = $original.LastIndexOf('\')
            $fwd = $original.LastIndexOf('/')
            $cut = $slash
            if ($fwd -gt $cut) { $cut = $fwd }
            if ($cut -ge 0 -and $cut -lt ($original.Length - 1)) {
                $originalLeaf = $original.Substring($cut + 1)
            }
            if ($published -and ($originalLeaf -eq $leaf)) { return $published }
        }
    }
    return ''
}

function Get-BitdefenderKind {
    param([string[]]$Names, [string[]]$Services)
    $seen = $false
    $gravity = $false
    foreach ($service in @($Services)) {
        if ($service -eq 'VSSERV' -or $service -eq 'bdservicehost' -or $service -eq 'EPSecurityService') { $seen = $true }
        if ($service -eq 'EPSecurityService') { $gravity = $true }
    }
    foreach ($name in @($Names)) {
        if ($name -match 'Bitdefender') { $seen = $true }
        if ($name -match 'Endpoint Security') { $gravity = $true; $seen = $true }
    }
    if (-not $seen) { return '' }
    if ($gravity) { return 'gravityzone' }
    return 'consumer'
}

function Get-BitdefenderGuidance {
    param([string]$Kind, [string]$HostAddress)
    $steps = "Bitdefender: Protection > Firewall > Rules > Add rule: allow C:\Windows\System32\spoolsv.exe, TCP, remote " + $HostAddress + " port 515 (or set spoolsv.exe to Allow). Also Firewall > Settings/Network adapters: set the office network to Home/Office (Trusted), not Public."
    if ($Kind -eq 'gravityzone') {
        return "Bitdefender GravityZone (Endpoint Security). " + $steps + " If managed by GravityZone, add the rule in the GravityZone firewall policy."
    }
    return "Consumer Bitdefender, not GravityZone Endpoint Security. " + $steps + " If managed by GravityZone, add the rule in the GravityZone firewall policy."
}

function Test-ThirdPartySecurityProduct {
    param([string]$DisplayName)
    if ([string]::IsNullOrWhiteSpace($DisplayName)) { return $false }
    if ($DisplayName -match 'Windows Defender') { return $false }
    if ($DisplayName -match 'Microsoft Defender') { return $false }
    return $true
}

function Get-RemaxFirewallRule {
    param($Target)
    $root = $env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($root)) { $root = 'C:\Windows' }
    $root = $root.TrimEnd('\')
    $program = $root + '\System32\spoolsv.exe'
    return @{
        Name          = 'RemaxSecure Print (spoolsv)'
        DisplayName   = 'RemaxSecure Print (spoolsv)'
        Direction     = 'Outbound'
        Action        = 'Allow'
        Program       = $program
        Protocol      = 'TCP'
        RemoteAddress = [string]$Target.Host
        RemotePort    = '515'
        LocalPort     = '721-731'
        Profile       = 'Any'
    }
}

function Test-FirewallRuleScoped {
    param($Rule)
    if (-not $Rule) { return $false }
    if ([string]$Rule.RemoteAddress -eq 'Any') { return $false }
    if ([string]$Rule.RemoteAddress -eq '*') { return $false }
    if ([string]$Rule.Program -notmatch 'spoolsv\.exe$') { return $false }
    if ([string]$Rule.RemotePort -ne '515') { return $false }
    if ([string]$Rule.LocalPort -ne '721-731') { return $false }
    if ([string]$Rule.Direction -ne 'Outbound') { return $false }
    if ([string]$Rule.Action -ne 'Allow') { return $false }
    if ([string]$Rule.DisplayName -match 'File and Printer Sharing') { return $false }
    return $true
}

function Get-ReachableDetail {
    param([bool]$Ok, [bool]$Bitdefender, [string]$HostAddress, [string]$ErrorText)
    if ($Ok) {
        return ("TCP " + $HostAddress + " port 515 accepted a connection.")
    }
    $detail = "TCP " + $HostAddress + " port 515 did not connect."
    if ($ErrorText) { $detail = $detail + " " + $ErrorText }
    if ($Bitdefender) {
        $detail = $detail + " Bitdefender is present and is the likely cause. Allow spoolsv.exe to " + $HostAddress + " port 515 in Bitdefender."
    }
    return $detail
}

function Remove-CleanupPrinters {
    param([string[]]$Names, [string[]]$Ports, $Done, $Failed)
    $targets = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($printer in @(Get-Printer -ErrorAction SilentlyContinue)) {
            $name = [string]$printer.Name
            $port = [string]$printer.PortName
            if (Test-CleanupPrinter -Name $name -PortName $port -Names $Names -Ports $Ports) {
                if (-not $targets.Contains($name)) { [void]$targets.Add($name) }
            }
        }
    } catch {
        Write-Remax ("Could not list printers for cleanup: " + $_.Exception.Message)
        [void]$Failed.Add("list printers: " + $_.Exception.Message)
        return
    }
    if ($targets.Count -eq 0) {
        Write-Remax "Cleanup: no RemaxSecure or target-port queues to remove."
        return
    }
    foreach ($name in @($targets.ToArray())) {
        Write-Remax ("Remove-Printer -Name '" + $name + "'")
        try {
            Remove-Printer -Name $name -ErrorAction Stop
            Write-Remax ("Removed printer " + $name)
            [void]$Done.Add("printer " + $name)
        } catch {
            Write-Remax ("Remove-Printer " + $name + " failed: " + $_.Exception.Message)
            [void]$Failed.Add("printer " + $name + ": " + $_.Exception.Message)
        }
    }
}

function Remove-CleanupPort {
    param([string]$Name, $Done, $Failed)
    $exists = $false
    try {
        $snapshot = Get-PortSnapshot $Name
        if ($snapshot) { $exists = $true }
    } catch { }
    if (-not $exists) {
        $key = Get-PortMonitorKey $Name
        if (Test-Path -LiteralPath $key) { $exists = $true }
    }
    if (-not $exists) {
        Write-Remax ("Cleanup: port " + $Name + " is not present.")
        return
    }
    Write-Remax ("Remove-PrinterPort -Name '" + $Name + "'")
    $removed = $false
    try {
        Remove-PrinterPort -Name $Name -ErrorAction Stop
        $removed = $true
    } catch {
        Write-Remax ("Remove-PrinterPort " + $Name + " failed: " + $_.Exception.Message + ". Restarting the Print Spooler and retrying.")
        [void](Restart-PrintSpooler)
        try {
            Remove-PrinterPort -Name $Name -ErrorAction Stop
            $removed = $true
        } catch {
            Write-Remax ("Remove-PrinterPort " + $Name + " failed again: " + $_.Exception.Message)
        }
    }
    if (-not $removed) {
        try {
            if (Remove-PortRegistryKey $Name) {
                [void](Restart-PrintSpooler)
                $removed = $true
            }
        } catch {
            Write-Remax ("Port registry cleanup for " + $Name + " failed: " + $_.Exception.Message)
            [void]$Failed.Add("port " + $Name + ": " + $_.Exception.Message)
            return
        }
    }
    if ($removed) {
        Write-Remax ("Removed port " + $Name)
        [void]$Done.Add("port " + $Name)
    } else {
        [void]$Failed.Add("port " + $Name + " could not be removed")
    }
}

function Remove-CleanupDriver {
    param($Done, $Failed)
    $name = $script:ExactDriverName
    $busy = ''
    try {
        foreach ($printer in @(Get-Printer -ErrorAction SilentlyContinue)) {
            if ([string]$printer.DriverName -eq $name) { $busy = [string]$printer.Name }
        }
    } catch { }
    if ($busy) {
        $note = "driver left installed because " + $busy + " still uses it"
        Write-Remax ("Cleanup: " + $note)
        return $note
    }
    $instances = @()
    try { $instances = @(Get-PrinterDriver -Name $name -ErrorAction Stop) } catch { $instances = @() }
    if ($instances.Count -eq 0) {
        Write-Remax ("Cleanup: printer driver " + $name + " is not installed.")
    }
    foreach ($inst in @($instances)) {
        $envName = ''
        try { $envName = [string]$inst.PrinterEnvironment } catch { $envName = '' }
        Write-Remax ("Remove-PrinterDriver -Name '" + $name + "' -RemoveFromDriverStore")
        try {
            if ($envName) {
                Remove-PrinterDriver -Name $name -PrinterEnvironment $envName -RemoveFromDriverStore -ErrorAction Stop
            } else {
                Remove-PrinterDriver -Name $name -RemoveFromDriverStore -ErrorAction Stop
            }
            Write-Remax ("Removed printer driver " + $name)
            [void]$Done.Add("driver " + $name)
        } catch {
            Write-Remax ("Remove-PrinterDriver -RemoveFromDriverStore failed: " + $_.Exception.Message)
            try {
                if ($envName) {
                    Remove-PrinterDriver -Name $name -PrinterEnvironment $envName -ErrorAction Stop
                } else {
                    Remove-PrinterDriver -Name $name -ErrorAction Stop
                }
                Write-Remax ("Removed printer driver " + $name + " without deleting the store package yet.")
                [void]$Done.Add("driver " + $name)
            } catch {
                Write-Remax ("Remove-PrinterDriver failed: " + $_.Exception.Message)
                [void]$Failed.Add("driver " + $name + ": " + $_.Exception.Message)
            }
        }
    }
    $oem = ''
    $pnputil = Join-Path $env:windir 'System32\pnputil.exe'
    if (-not (Test-Path -LiteralPath $pnputil)) { $pnputil = 'pnputil.exe' }
    try {
        $enum = Invoke-LoggedProcess -FilePath $pnputil -ArgumentList @('/enum-drivers')
        $oem = Get-PnputilPublishedForOriginal -Lines $enum.Lines -OriginalLeaf 'cns30ua64.inf'
    } catch {
        Write-Remax ("pnputil /enum-drivers failed: " + $_.Exception.Message)
    }
    if (-not $oem) {
        try {
            $drivers = @(Get-WindowsDriver -Online -ErrorAction Stop)
            foreach ($driver in $drivers) {
                $original = ''
                try { $original = [string]$driver.OriginalFileName } catch { $original = '' }
                if ($original -and ((Get-PathLeafAny $original).ToLowerInvariant() -eq 'cns30ua64.inf')) {
                    try { $oem = [string]$driver.Driver } catch { $oem = '' }
                    if ($oem) { break }
                }
            }
        } catch {
            Write-Remax ("Get-WindowsDriver during cleanup failed: " + $_.Exception.Message)
        }
    }
    if ($oem) {
        Write-Remax ("pnputil /delete-driver " + $oem + " /uninstall /force")
        $deleted = Invoke-LoggedProcess -FilePath $pnputil -ArgumentList @('/delete-driver', $oem, '/uninstall', '/force')
        if (Test-PnputilSuccess $deleted.Code) {
            [void]$Done.Add("driver package " + $oem)
        } else {
            [void]$Failed.Add("pnputil /delete-driver " + $oem + " exit " + $deleted.Code)
        }
    }
    return ''
}

function Invoke-RemaxCleanup {
    param($Target)
    if (Test-SkipCleanup) {
        Write-Remax "REMAX_SKIP_CLEANUP=1. Leaving the existing queue, port, and driver."
        return (Get-CleanupReport -Skipped $true -Done @() -Failed @() -Note '')
    }
    Write-Remax "Clean slate: removing the RemaxSecure queue, its ports, then the Canon PS3 driver."
    $done = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]
    $names = @($script:PrinterName, $script:StaleName, 'RemaxSecure_LPR')
    $ports = @($script:PortName, $script:LegacyPortName, $script:DefaultHost)
    if ($Target -and $Target.Host) {
        $withHost = New-Object System.Collections.Generic.List[string]
        foreach ($port in $ports) { if ($port -and -not $withHost.Contains($port)) { [void]$withHost.Add($port) } }
        if (-not $withHost.Contains([string]$Target.Host)) { [void]$withHost.Add([string]$Target.Host) }
        $ports = @($withHost.ToArray())
    }
    Remove-CleanupPrinters -Names $names -Ports $ports -Done $done -Failed $failed
    foreach ($port in @($ports)) {
        Remove-CleanupPort -Name $port -Done $done -Failed $failed
    }
    $note = Remove-CleanupDriver -Done $done -Failed $failed
    return (Get-CleanupReport -Skipped $false -Done @($done.ToArray()) -Failed @($failed.ToArray()) -Note $note)
}

function Write-SecurityCenterProducts {
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($className in @('AntiVirusProduct', 'FirewallProduct')) {
        try {
            $rows = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName $className -ErrorAction Stop)
            if ($rows.Count -eq 0) {
                Write-Remax ($className + " returned no products.")
            }
            foreach ($row in $rows) {
                $display = ''
                $state = ''
                try { $display = [string]$row.displayName } catch { $display = '' }
                try { $state = [string]$row.productState } catch { $state = '' }
                Write-Remax ($className + " displayName='" + $display + "' productState=" + $state)
                if ($display) { [void]$names.Add($display) }
            }
        } catch {
            Write-Remax ($className + " was not readable: " + $_.Exception.Message)
        }
    }
    return @($names.ToArray())
}

function Write-FirewallProfiles {
    try {
        $profiles = @(Get-NetFirewallProfile -ErrorAction Stop)
        foreach ($profile in $profiles) {
            Write-Remax ("Firewall profile " + $profile.Name + " enabled=" + $profile.Enabled)
        }
    } catch {
        Write-Remax ("Get-NetFirewallProfile failed: " + $_.Exception.Message)
    }
}

function Get-PresentServiceNames {
    param([string[]]$Names)
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($Names)) {
        try {
            $svc = Get-Service -Name $name -ErrorAction Stop
            if ($svc) {
                [void]$found.Add($name)
                Write-Remax ("Service " + $name + " status=" + $svc.Status)
            }
        } catch { }
    }
    return @($found.ToArray())
}

function Remove-RemaxFirewallRule {
    param([string]$Name)
    foreach ($mode in @('Name', 'DisplayName')) {
        try {
            $rules = @()
            if ($mode -eq 'Name') {
                $rules = @(Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue)
            } else {
                $rules = @(Get-NetFirewallRule -DisplayName $Name -ErrorAction SilentlyContinue)
            }
            foreach ($rule in $rules) {
                if (-not $rule) { continue }
                Remove-NetFirewallRule -InputObject $rule -ErrorAction Stop
                Write-Remax ("Removed firewall rule (" + $mode + ") " + $Name)
            }
        } catch {
            Write-Remax ("Removing firewall rule by " + $mode + " failed: " + $_.Exception.Message)
        }
    }
}

function Add-RemaxFirewallRule {
    param($Target)
    $rule = Get-RemaxFirewallRule $Target
    if (-not (Test-FirewallRuleScoped $rule)) {
        Write-Remax "Refusing to add a firewall rule that is not limited to spoolsv.exe and the printer."
        return $false
    }
    Remove-RemaxFirewallRule -Name $rule.Name
    Write-Remax ("New-NetFirewallRule " + $rule.DisplayName + " program=" + $rule.Program + " TCP remote " + $rule.RemoteAddress + ":" + $rule.RemotePort + " local " + $rule.LocalPort)
    try {
        New-NetFirewallRule -Name $rule.Name -DisplayName $rule.DisplayName -Direction Outbound -Action Allow -Program $rule.Program -Protocol TCP -RemoteAddress $rule.RemoteAddress -RemotePort $rule.RemotePort -LocalPort $rule.LocalPort -Profile Any -Enabled True -ErrorAction Stop | Out-Null
        Write-Remax ("Added Windows Firewall outbound rule " + $rule.DisplayName)
        return $true
    } catch {
        Write-Remax ("New-NetFirewallRule failed: " + $_.Exception.Message)
        return $false
    }
}

function Invoke-RemaxFirewall {
    param($Target)
    if (Test-SkipFirewall) {
        Write-Remax "REMAX_SKIP_FIREWALL=1. Not adding a firewall rule."
        $script:Firewall = @{ State = 'PASS'; Detail = 'skipped (REMAX_SKIP_FIREWALL=1)' }
        $script:BitdefenderKind = ''
        return
    }
    $productNames = @(Write-SecurityCenterProducts)
    Write-FirewallProfiles
    $services = @(Get-PresentServiceNames -Names @('VSSERV', 'bdservicehost', 'EPSecurityService'))
    $kind = Get-BitdefenderKind -Names $productNames -Services $services
    $script:BitdefenderKind = $kind
    $thirdParty = $false
    $thirdNames = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($productNames)) {
        if (Test-ThirdPartySecurityProduct $name) {
            $thirdParty = $true
            [void]$thirdNames.Add($name)
        }
    }
    if ($kind) { $thirdParty = $true }
    $added = Add-RemaxFirewallRule -Target $Target
    if ($kind) {
        $detail = Get-BitdefenderGuidance -Kind $kind -HostAddress $Target.Host
        if ($added) {
            $detail = "Windows Firewall outbound rule RemaxSecure Print (spoolsv) was added. Bitdefender is not modified by this script. " + $detail
        }
        $script:Firewall = @{ State = 'MANUAL'; Detail = $detail }
        Write-Remax $detail
        return
    }
    if ($thirdParty) {
        $shown = 'a third-party security product'
        if ($thirdNames.Count -gt 0) { $shown = ($thirdNames -join ', ') }
        $detail = $shown + " is installed. This script does not change that product. Allow C:\Windows\System32\spoolsv.exe to " + $Target.Host + ":515 TCP in that product."
        if ($added) {
            $detail = "Windows Firewall outbound rule RemaxSecure Print (spoolsv) was added. " + $detail
        }
        $script:Firewall = @{ State = 'MANUAL'; Detail = $detail }
        Write-Remax $detail
        return
    }
    if ($added) {
        $script:Firewall = @{ State = 'PASS'; Detail = "Windows Firewall outbound rule RemaxSecure Print (spoolsv): spoolsv.exe TCP to " + $Target.Host + " port 515, local ports 721-731, all profiles." }
        return
    }
    $script:Firewall = @{ State = 'MANUAL'; Detail = "Windows Firewall rule RemaxSecure Print (spoolsv) was not added. Allow spoolsv.exe to " + $Target.Host + " port 515 TCP." }
}

function Test-RemaxNetworkName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    return ($Name.Trim().ToLowerInvariant() -eq 'remax')
}

function Get-WlanSsidFromLines {
    param([string[]]$Lines)
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($Lines)) {
        $text = [string]$line
        if ($text -notmatch '^\s*SSID\s*:\s*(.*)$') { continue }
        if ($text -match 'BSSID') { continue }
        $ssid = [string]$Matches[1]
        $ssid = $ssid.Trim()
        if ($ssid -and -not $names.Contains($ssid)) { [void]$names.Add($ssid) }
    }
    return @($names.ToArray())
}

function Get-WlanSsids {
    $lines = @()
    try { $lines = @(netsh wlan show interfaces) } catch { $lines = @() }
    return @(Get-WlanSsidFromLines -Lines $lines)
}

function Get-ConnectionProfileNames {
    $names = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($profile in @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)) {
            if (-not $profile) { continue }
            $name = [string]$profile.Name
            if ($name -and -not $names.Contains($name)) { [void]$names.Add($name) }
        }
    } catch { }
    return @($names.ToArray())
}

function Get-RemaxNetworkStatus {
    $ssids = @(Get-WlanSsids)
    $profiles = @(Get-ConnectionProfileNames)
    if ($ssids.Count -eq 0) { Write-Remax 'Detected Wi-Fi SSID: none' }
    foreach ($ssid in $ssids) { Write-Remax ("Detected Wi-Fi SSID: " + $ssid) }
    if ($profiles.Count -eq 0) { Write-Remax 'Detected connection profile: none' }
    foreach ($profile in $profiles) { Write-Remax ("Detected connection profile: " + $profile) }
    $on = $false
    $matched = ''
    foreach ($ssid in $ssids) {
        if (Test-RemaxNetworkName $ssid) { $on = $true; $matched = $ssid }
    }
    foreach ($profile in $profiles) {
        if (Test-RemaxNetworkName $profile) { $on = $true; if (-not $matched) { $matched = $profile } }
    }
    $current = 'none'
    if ($on) {
        $current = $matched
    } else {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($ssid in $ssids) { if (-not $parts.Contains($ssid)) { [void]$parts.Add($ssid) } }
        foreach ($profile in $profiles) { if (-not $parts.Contains($profile)) { [void]$parts.Add($profile) } }
        if ($parts.Count -gt 0) { $current = ($parts -join ', ') }
    }
    return @{ OnRemax = $on; Current = $current }
}

function Invoke-RemaxReachability {
    param($Target)
    $network = Get-RemaxNetworkStatus
    if (-not $network.OnRemax) {
        $script:Reachable = @{
            State  = 'SKIP'
            Detail = ('not on REMAX network (current: ' + $network.Current + ')')
        }
        Write-Remax ("REACHABLE SKIP " + $script:Reachable.Detail)
        return
    }
    Write-Remax ("Office network REMAX detected (" + $network.Current + "). Testing TCP 515.")
    $bitdefender = $false
    if ($script:BitdefenderKind) { $bitdefender = $true }
    try {
        $test = Test-NetConnection -ComputerName $Target.Host -Port 515 -WarningAction SilentlyContinue
        $ok = $false
        if ($test -and $test.TcpTestSucceeded) { $ok = $true }
        $detail = Get-ReachableDetail -Ok $ok -Bitdefender $bitdefender -HostAddress $Target.Host -ErrorText ''
        $state = 'FAIL'
        if ($ok) { $state = 'PASS' }
        $script:Reachable = @{ State = $state; Detail = $detail }
    } catch {
        $script:Reachable = @{
            State  = 'FAIL'
            Detail = (Get-ReachableDetail -Ok $false -Bitdefender $bitdefender -HostAddress $Target.Host -ErrorText $_.Exception.Message)
        }
    }
    Write-Remax ("REACHABLE " + $script:Reachable.State + " " + $script:Reachable.Detail)
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
    Show-RemaxProgress 'Cleanup'
    $script:Cleanup = Invoke-RemaxCleanup -Target $target
    Show-RemaxProgress 'Firewall'
    try { Invoke-RemaxFirewall -Target $target } catch {
        Write-Remax ("Firewall step failed: " + $_.Exception.Message)
        $script:Firewall = @{ State = 'MANUAL'; Detail = $_.Exception.Message }
    }
    $status = New-StatusMap
    $staleOk = $true
    if (-not (Test-SkipCleanup)) {
        $staleOk = Remove-StaleQueue
    }
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
    Show-RemaxProgress 'Download driver'
    if (-not $selected) {
        $pkgUrl = Resolve-CanonPackageUrl
        if (-not [string]::IsNullOrWhiteSpace($env:REMAX_CANON_PKG_URL)) {
            Write-Remax ("REMAX_CANON_PKG_URL overrides the built-in driver package: " + $pkgUrl)
        } else {
            Write-Remax ("Driver is not installed. Downloading the built-in package " + $pkgUrl)
        }
        try {
            Install-CanonPackageFromUrl $pkgUrl
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
    Show-RemaxProgress 'Install driver'
    $driverName = [string]$selected.Name
    Write-Remax ("Using driver " + $driverName)
    try { Write-AssistServiceNote } catch { }
    Show-RemaxProgress 'Port'
    $portResult = $null
    try {
        $portResult = Ensure-LprPort $target
    } catch {
        Write-Remax ("Port setup failed: " + $_.Exception.Message)
        $portResult = @{ State = 'MANUAL'; Detail = $_.Exception.Message; Snapshot = $null }
    }
    if ($portResult) { $script:PortNote = $portResult }
    try { Invoke-RemaxReachability -Target $target } catch {
        Write-Remax ("Reachability test failed: " + $_.Exception.Message)
        $script:Reachable = @{ State = 'FAIL'; Detail = $_.Exception.Message }
    }
    Show-RemaxProgress 'Printer'
    try {
        Ensure-PrinterQueue -DriverName $driverName -Target $target
    } catch {
        Write-Remax ("Queue setup failed: " + $_.Exception.Message + ". Continuing to the report.")
        $status = Get-QueueStatus $target
        if ($status['PRINTER'].State -eq 'FAIL') {
            $status['PRINTER'].Detail = ("setup failed: " + $_.Exception.Message)
        }
        $code = Write-StatusReport -Kind 'install' -Verify $false -Status $status -PrintUser $printUser -Target $target
        Copy-RemaxLog -Result 'FAIL' -PrintUser $printUser -Target $target
        return $code
    }
    Show-RemaxProgress 'Defaults'
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
        $ui = Invoke-RemaxDeviceSettings -PrintUser $printUser
        Apply-DeviceUiResult -Status $status -Ui $ui -Property $null -PrintUser $printUser
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
    foreach ($label in @(Get-ResultLabels)) {
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
    Assert-Remax ($script:Version -eq '1.2.12') 'version string is 1.2.12'
    Assert-Remax (Test-VersionAtLeast -Have '1.2.12' -Want '1.2.11') '1.2.12 is at least 1.2.11'
    Assert-Remax (Test-VersionAtLeast -Have '1.2.12' -Want '1.2.12') 'the same version is new enough'
    Assert-Remax (-not (Test-VersionAtLeast -Have '1.2.10' -Want '1.2.12')) '1.2.10 is older than 1.2.12'
    Assert-Remax (Test-VersionAtLeast -Have '1.10' -Want '1.9') 'version parts compare as numbers'
    $versionText = "`$script:Version = '1.2.12'"
    Assert-Remax ((Get-ScriptVersionFromText $versionText) -eq '1.2.12') 'script version can be read from downloaded text'
    $shaUrl = Get-ElevatedScriptUrl -CommitSha '0123456789abcdef0123456789abcdef01234567'
    Assert-Remax ($shaUrl -eq 'https://raw.githubusercontent.com/ItsErod/canon-secure-print/0123456789abcdef0123456789abcdef01234567/install-windows.ps1') 'a resolved main SHA is used in the raw URL'
    $bustUrl = Get-ElevatedScriptUrl -CommitSha ''
    Assert-Remax ($bustUrl.StartsWith($script:RawUrl + '?nocache=')) 'a failed SHA lookup uses a cache buster'
    Assert-Remax (-not [string]::IsNullOrWhiteSpace($script:IngestKey)) 'install report key is set'
    Assert-Remax ($script:IngestUrl -eq 'https://tickets.rmxofficetools.com/api/public/printer-installs') 'install report URL is set'
    $savedReport = $env:REMAX_NO_REPORT
    $env:REMAX_NO_REPORT = '1'
    Assert-Remax (Test-SkipInstallReport) 'REMAX_NO_REPORT=1 skips the install report'
    if ($null -eq $savedReport) { Remove-Item Env:REMAX_NO_REPORT -ErrorAction SilentlyContinue } else { $env:REMAX_NO_REPORT = $savedReport }
    $savedUser = $env:REMAX_PRINT_USER
    $env:REMAX_PRINT_USER = "jo'hns"
    $elevated = Get-ElevatedInstallCommand
    Assert-Remax ($elevated.Contains("REMAX_PRINT_USER = 'jo''hns'")) 'elevated relaunch keeps REMAX_PRINT_USER'
    Assert-Remax ($elevated.Contains('Cache-Control')) 'elevated download sends no-cache headers'
    Assert-Remax ($elevated.Contains('nocache=')) 'elevated download without a SHA uses a cache buster'
    Assert-Remax ($elevated.Contains("REMAX_LAUNCH_VERSION = '" + $script:Version + "'")) 'elevated relaunch records the launcher version'
    if ($null -eq $savedUser) { Remove-Item Env:REMAX_PRINT_USER -ErrorAction SilentlyContinue } else { $env:REMAX_PRINT_USER = $savedUser }
    Assert-Remax ((Get-ReportTail -Text ('abcde') -MaxBytes 3) -eq 'cde') 'report log tail keeps the last bytes'
    $mixedName = [byte[]](84, 115, 105, 111, 103, 97, 115, 101, 0, 0)
    $mixedHits = @(Find-UserNameHits -Data $mixedName -Name 'tsiogase')
    Assert-Remax ($mixedHits.Count -ge 1 -and $mixedHits[0].Encoding -eq 'ASCII' -and [int]$mixedHits[0].Offset -eq 0) 'Tsiogase matches a lowercase probe'
    $mixedWrite = Write-NameIntoField -Data $mixedName -Hit $mixedHits[0] -NewName 'johns'
    Assert-Remax ($mixedWrite.Ok -and $mixedWrite.Bytes[0] -eq 106 -and $mixedWrite.Bytes[5] -eq 0) 'johns is written and the rest of the field is zero'
    $utfName = [System.Text.Encoding]::Unicode.GetBytes('Tsiogase')
    $utfHits = @(Find-UserNameHits -Data $utfName -Name 'tsiogase')
    $utfHit = $null
    foreach ($hit in @($utfHits)) { if ($hit.Encoding -eq 'UTF-16') { $utfHit = $hit } }
    Assert-Remax ($null -ne $utfHit) 'UTF-16 Tsiogase matches a lowercase probe'
    Assert-Remax ((Resolve-FinisherLabel -Labels @('None', 'Inner Finisher-E1')) -eq 'Inner Finisher-E1') 'Inner Finisher-E1 matches Inner Finisher E1'
    Assert-Remax (Test-LooseLabelEquals 'Inner Finisher-E1' 'Inner Finisher E1') 'hyphen and space are the same finisher label'
    Assert-Remax ((Get-EditChangeWParam 1001) -eq 50332649) 'EN_CHANGE notice includes the control id'
    Assert-Remax (Test-UserNameMatch 'Tsiogase' 'tsiogase') 'user name read-back ignores case'
    Assert-Remax (-not (Test-UserNameMatch 'Tsiogase' 'johns')) 'Tsiogase is not johns'
    Assert-Remax ($null -ne (Get-Command Select-UiaTab -ErrorAction SilentlyContinue)) 'Select-UiaTab is defined at script scope'
    $uiaCompile = Test-RemaxUiaHelperCompile
    Assert-Remax ($uiaCompile.Ok) ('UI helper compile: ' + $uiaCompile.Detail)
    $helpers = Test-CalledHelpersDefined
    Assert-Remax ($helpers.Ok) $helpers.Detail
    $source = Get-RemaxUiaSource
    Assert-Remax ($source.Contains('InvokePattern')) 'UI helper source uses InvokePattern'
    Assert-Remax ((Get-RemaxUiReferencePaths).Count -ge 0) 'UI reference lookup runs'
    Assert-Remax (Test-RemaxNetworkName 'REMAX') 'REMAX matches the office network'
    Assert-Remax (Test-RemaxNetworkName 'remax') 'remax matches ignoring case'
    Assert-Remax (-not (Test-RemaxNetworkName 'REMAX-Guest')) 'a longer network name is not REMAX'
    Assert-Remax (-not (Test-RemaxNetworkName '')) 'a blank network name is not REMAX'
    $sampleWlan = @(
        '    Name                   : Wi-Fi',
        '    SSID                   : REMAX',
        '    BSSID                  : aa:bb:cc:dd:ee:ff',
        '    SSID                   : remax'
    )
    $parsedSsids = @(Get-WlanSsidFromLines -Lines $sampleWlan)
    Assert-Remax ($parsedSsids.Count -eq 2 -and $parsedSsids[0] -eq 'REMAX' -and $parsedSsids[1] -eq 'remax') 'SSID lines are read and BSSID is ignored'
    Assert-Remax ((Get-ResultLabel @('PASS', 'SKIP')) -eq 'PASS') 'SKIP does not change RESULT'
    $portTarget = @{ Host = '172.16.105.21'; Queue = 'RemaxSecure'; PortName = '172.16.105.21'; Uri = 'lpd://172.16.105.21/RemaxSecure'; ByteCount = $true }
    $unreadPort = @{
        Name = '172.16.105.21'; Host = '172.16.105.21'; Queue = 'RemaxSecure'; Protocol = 2; PortNumber = 515
        ByteCount = $false; ByteCountKnown = $false; SnmpEnabled = $false; SnmpKnown = $false; Registry = $null
    }
    Assert-Remax (Test-PortMatches $unreadPort $portTarget) 'LPR host queue protocol 2 and SNMP false pass when byte count was not read'
    $snmpString = @{
        Name = '172.16.105.21'; Host = '172.16.105.21'; Queue = 'RemaxSecure'; Protocol = 2; PortNumber = 0
        ByteCount = $true; ByteCountKnown = $true; SnmpEnabled = 'False'; SnmpKnown = $true
        Registry = @{ Protocol = 2; Queue = 'RemaxSecure'; ByteCount = $null; Snmp = 0 }
    }
    Assert-Remax (Test-PortMatches $snmpString $portTarget) 'SNMP string False is off'
    Assert-Remax (-not (Test-PortMatches @{ Name = '172.16.105.21'; Host = '172.16.105.21'; Queue = 'RemaxSecure'; Protocol = 2; PortNumber = 515; ByteCount = $false; ByteCountKnown = $true; SnmpEnabled = $false; SnmpKnown = $true; Registry = $null } $portTarget)) 'a read byte count of off fails'
    Assert-Remax (-not (ConvertTo-FlagEnabled 'False')) 'the string False is not enabled'
    Assert-Remax (ConvertTo-FlagEnabled 'True') 'the string True is enabled'
    $probes = @(Get-UserNameProbeTargets)
    $sawDefault = $false
    $sawPlain = $false
    $sawUnc = $false
    foreach ($probe in $probes) {
        if ($probe.Value -eq 'Default DevMode') { $sawDefault = $true }
        if ($probe.Value -eq 'RemaxSecure') { $sawPlain = $true }
        if ([string]$probe.Value -like '\\*\RemaxSecure') { $sawUnc = $true }
    }
    Assert-Remax ($sawDefault -and $sawPlain -and $sawUnc) 'Default DevMode and per-user RemaxSecure values are probed'
    Assert-Remax ($script:ExportedPrintUser -eq 'tsiogase') 'exported print username to replace is tsiogase'
    Assert-Remax (Test-UserInformationTitle 'User Information Settings') 'User Information Settings title is accepted'
    Assert-Remax (-not (Test-UserInformationTitle 'RemaxSecure Properties')) 'printer properties is not the user dialog'
    Assert-Remax (Test-UserNameMatch 'johns' 'johns') 'typed username matches readback'
    Assert-Remax (-not (Test-UserNameMatch 'tsiogase' 'johns')) 'exported username does not match the typed name'
    $roots = @(Get-UserNameRegistryRoots)
    Assert-Remax ($roots -contains 'HKCU:\Printers\DevModePerUser') 'per-user DevMode is included'
    Assert-Remax ($roots -contains 'HKCU:\Printers\DevModes2') 'per-user DevModes2 is included'
    Assert-Remax ($roots[0] -like '*\Printers\RemaxSecure') 'global printer key is included'
    $asciiOld = [System.Text.Encoding]::ASCII.GetBytes('xxxtsiogaseyyy')
    $asciiSwap = Replace-UserNameBytes -Data $asciiOld -OldName 'tsiogase' -NewName 'johns'
    Assert-Remax ($asciiSwap.Count -eq 1 -and $asciiSwap.Bytes.Length -eq $asciiOld.Length) 'ASCII username replace keeps the field width'
    Assert-Remax ([System.Text.Encoding]::ASCII.GetString($asciiSwap.Bytes).StartsWith('xxxjohns')) 'ASCII tsiogase becomes johns'
    Assert-Remax ($asciiSwap.Bytes[8] -eq 0 -and $asciiSwap.Bytes[10] -eq 0 -and $asciiSwap.Bytes[11] -eq 121) 'shorter ASCII name is padded with zeros'
    $utfOld = [System.Text.Encoding]::Unicode.GetBytes('tsiogase')
    $utfPad = New-Object byte[] ($utfOld.Length + 2)
    [System.Array]::Copy($utfOld, $utfPad, $utfOld.Length)
    $utfSwap = Replace-UserNameBytes -Data $utfPad -OldName 'tsiogase' -NewName 'johns'
    Assert-Remax ($utfSwap.Count -eq 1) 'UTF-16 username is replaced'
    $utfShown = [System.Text.Encoding]::Unicode.GetString($utfSwap.Bytes, 0, 10)
    Assert-Remax ($utfShown -eq 'johns') 'UTF-16 tsiogase becomes johns'
    $tooLong = Replace-UserNameBytes -Data ([System.Text.Encoding]::ASCII.GetBytes('tsiogase')) -OldName 'tsiogase' -NewName 'longername'
    Assert-Remax ($tooLong.Count -eq 0 -and $tooLong.Skipped -eq 1) 'a longer username does not overwrite the next bytes'
    Assert-Remax ($script:DeviceDatBytes -eq 44692) 'device settings file is 44692 bytes'
    Assert-Remax ($script:DeviceDatSha256 -eq 'a206124cad61263c4843a560765a389da3cb2d3ddb70011abbbbf54499f96279') 'device settings SHA256 is pinned'
    Assert-Remax ($script:DeviceDatUrl -eq 'https://github.com/ItsErod/canon-secure-print/releases/download/driver-v30/remaxsecure-device-settings.dat') 'device settings URL is the release asset'
    $savedDat = $env:REMAX_DEVICE_DAT
    Remove-Item Env:REMAX_DEVICE_DAT -ErrorAction SilentlyContinue
    $defaultDat = Resolve-DeviceDatRequest
    Assert-Remax ($defaultDat.Kind -eq 'url' -and $defaultDat.Pinned -and $defaultDat.Location -eq $script:DeviceDatUrl) 'unset REMAX_DEVICE_DAT uses the pinned release'
    $env:REMAX_DEVICE_DAT = 'https://example.test/other.dat'
    $otherDat = Resolve-DeviceDatRequest
    Assert-Remax ($otherDat.Kind -eq 'url' -and -not $otherDat.Pinned) 'an https override is downloaded without the pinned hash'
    $env:REMAX_DEVICE_DAT = 'C:\Settings\remaxsecure.dat'
    $localDat = Resolve-DeviceDatRequest
    Assert-Remax ($localDat.Kind -eq 'file' -and $localDat.Location -eq 'C:\Settings\remaxsecure.dat') 'a local REMAX_DEVICE_DAT path is used as a file'
    if ($null -eq $savedDat) { Remove-Item Env:REMAX_DEVICE_DAT -ErrorAction SilentlyContinue } else { $env:REMAX_DEVICE_DAT = $savedDat }
    $pinnedDat = Test-PinnedDeviceDat -Hash $script:DeviceDatSha256 -Length $script:DeviceDatBytes
    Assert-Remax ($pinnedDat.Ok) 'matching device settings size and SHA256 pass'
    $badDat = Test-PinnedDeviceDat -Hash 'aa' -Length 4
    Assert-Remax ((-not $badDat.Ok) -and ($badDat.Detail -match 'SHA256')) 'device settings SHA256 mismatch is a clear failure'
    $restoreArg = Get-PrintUiRestoreArgument 'C:\Settings\remaxsecure.dat'
    Assert-Remax ($restoreArg -eq 'printui.dll,PrintUIEntry /Sr /n "RemaxSecure" /a "C:\Settings\remaxsecure.dat" d g r') 'PrintUI restore uses /Sr d g r'
    $beforeMap = @{ Alpha = 'bytes:1:aa'; Beta = 'DWord:1' }
    $afterMap = @{ Alpha = 'bytes:2:bb'; Beta = 'DWord:1'; Gamma = 'String:x' }
    Assert-Remax ((Get-DriverDataChangeCount -Before $beforeMap -After $afterMap) -eq 2) 'registry diff counts changed and added values'
    $setRead = @{ PaperSeen = $true; PaperValue = 'Cassette Feeding Unit'; OutputSeen = $true; OutputValue = 'Inner Finisher E1' }
    Assert-Remax (-not (Test-PaperSourceUnset $setRead)) 'Cassette Feeding Unit readback is set'
    Assert-Remax (-not (Test-OutputOptionsUnset $setRead)) 'Inner Finisher E1 readback is set'
    Assert-Remax (Test-DatRestoreConfirmed -RestoreOk $true -PaperUnset $false -OutputUnset $false -PaperSeen $true -OutputSeen $true -Changed 0) 'UIA readback confirms the dat restore'
    $unsetRead = @{ PaperSeen = $true; PaperValue = 'Off'; OutputSeen = $true; OutputValue = 'None' }
    Assert-Remax (Test-PaperSourceUnset $unsetRead) 'an off checkbox is unset'
    Assert-Remax (Test-OutputOptionsUnset $unsetRead) 'None is unset'
    Assert-Remax (-not (Test-DatRestoreConfirmed -RestoreOk $true -PaperUnset $true -OutputUnset $false -PaperSeen $true -OutputSeen $true -Changed 3)) 'unset readback does not confirm the dat'
    Assert-Remax (Test-DatRestoreConfirmed -RestoreOk $true -PaperUnset $false -OutputUnset $false -PaperSeen $false -OutputSeen $false -Changed 2) 'a registry change confirms the dat when the dialog was not read'
    Assert-Remax (-not (Test-DatRestoreConfirmed -RestoreOk $true -PaperUnset $false -OutputUnset $false -PaperSeen $false -OutputSeen $false -Changed 0)) 'a silent PrintUI restore with no registry change is not confirmed'
    Assert-Remax (-not (Test-DatRestoreConfirmed -RestoreOk $false -PaperUnset $false -OutputUnset $false -PaperSeen $true -OutputSeen $true -Changed 4)) 'a non-zero PrintUI exit is not confirmed'
    $plan = @(Get-RemaxProgressPlan)
    Assert-Remax ($plan.Count -eq 10) 'progress plan has ten stages'
    Assert-Remax ([string]$plan[0].Stage -eq 'Cleanup' -and [int]$plan[0].Percent -eq 10) 'progress starts at Cleanup 10'
    Assert-Remax ([string]$plan[1].Stage -eq 'Firewall' -and [int]$plan[1].Percent -eq 20) 'progress Firewall is 20'
    Assert-Remax ([string]$plan[9].Stage -eq 'Report' -and [int]$plan[9].Percent -eq 100) 'progress ends at Report 100'
    $savedLock = $env:REMAX_NO_INPUT_LOCK
    $env:REMAX_NO_INPUT_LOCK = '1'
    Assert-Remax (Test-SkipInputLock) 'REMAX_NO_INPUT_LOCK=1 skips the input lock'
    if ($null -eq $savedLock) { Remove-Item Env:REMAX_NO_INPUT_LOCK -ErrorAction SilentlyContinue } else { $env:REMAX_NO_INPUT_LOCK = $savedLock }
    $resultLabels = @(Get-ResultLabels)
    Assert-Remax ($resultLabels -notcontains 'REACHABLE') 'REACHABLE does not change the exit code'
    Assert-Remax ($resultLabels -notcontains 'INPUT LOCK') 'INPUT LOCK does not change the exit code'
    Assert-Remax ((Get-PsOutputChoice) -eq '') 'PS Output from Application stays unchanged when REMAX_PS_OUTPUT is unset'
    $savedPs = $env:REMAX_PS_OUTPUT
    $env:REMAX_PS_OUTPUT = 'Auto'
    Assert-Remax ((Get-PsOutputChoice) -eq 'Auto') 'REMAX_PS_OUTPUT selects the PS Output value'
    if ($null -eq $savedPs) { Remove-Item Env:REMAX_PS_OUTPUT -ErrorAction SilentlyContinue } else { $env:REMAX_PS_OUTPUT = $savedPs }
    Assert-Remax ((Find-ListedIndex -Labels @('None', 'Inner Finisher E1') -Want 'Inner Finisher E1') -eq 1) 'Inner Finisher E1 is the second combo item'
    Assert-Remax ((Resolve-ConfirmButtonLabel -Labels @('Cancel', 'Yes')) -eq 'Yes') 'a confirmation dialog uses Yes'
    Assert-Remax ((Resolve-ConfirmButtonLabel -Labels @('Help', 'OK')) -eq 'OK') 'a confirmation dialog uses OK'
    $writable = @(Get-WritablePortPropertyNames)
    $sawHost = $false
    foreach ($propName in $writable) { if ($propName -eq 'HostAddress') { $sawHost = $true } }
    Assert-Remax (-not $sawHost) 'CIM port update does not include HostAddress'
    Assert-Remax (($writable -join ',') -eq 'Queue,Protocol,ByteCount,SNMPEnabled') 'only writable port properties are queued'
    Assert-Remax (Test-CleanupPrinter -Name 'RemaxSecure' -PortName 'Other' -Names @('RemaxSecure', 'RemaxSecure_COLOUR', 'RemaxSecure_LPR') -Ports @('172.16.105.21', 'RemaxSecure_LPR')) 'RemaxSecure queue is removed'
    Assert-Remax (Test-CleanupPrinter -Name 'Office' -PortName '172.16.105.21' -Names @('RemaxSecure') -Ports @('172.16.105.21', 'RemaxSecure_LPR')) 'a queue on the printer port is removed'
    Assert-Remax (-not (Test-CleanupPrinter -Name 'Office' -PortName 'USB001' -Names @('RemaxSecure', 'RemaxSecure_COLOUR', 'RemaxSecure_LPR') -Ports @('172.16.105.21', 'RemaxSecure_LPR'))) 'an unrelated queue is kept'
    $cleanSkip = Get-CleanupReport -Skipped $true -Done @() -Failed @() -Note ''
    Assert-Remax ($cleanSkip.State -eq 'PASS') 'REMAX_SKIP_CLEANUP is a passing cleanup line'
    $cleanFail = Get-CleanupReport -Skipped $false -Done @('printer RemaxSecure') -Failed @('port 172.16.105.21') -Note ''
    Assert-Remax ($cleanFail.State -eq 'PARTIAL') 'a failed cleanup step is PARTIAL'
    $cleanOk = Get-CleanupReport -Skipped $false -Done @() -Failed @() -Note ''
    Assert-Remax ($cleanOk.State -eq 'PASS' -and $cleanOk.Detail -eq 'nothing to remove') 'empty cleanup passes'
    Assert-Remax ((Get-ResultLabel @('PASS', 'PARTIAL')) -eq 'PARTIAL') 'PARTIAL line makes the result PARTIAL'
    Assert-Remax ((Get-ResultLabel @('PASS', 'FAIL')) -eq 'FAIL') 'FAIL still wins over other lines'
    $enumSample = @(
        'Published Name:     oem93.inf',
        'Original Name:      cns30ua64.inf',
        'Class Name:         Printers',
        'Published Name:     oem10.inf',
        'Original Name:      other.inf'
    )
    Assert-Remax ((Get-PnputilPublishedForOriginal -Lines $enumSample -OriginalLeaf 'cns30ua64.inf') -eq 'oem93.inf') 'oem inf for cns30ua64.inf is selected'
    Assert-Remax ((Get-BitdefenderKind -Names @('Bitdefender Antivirus') -Services @()) -eq 'consumer') 'Bitdefender name is consumer'
    Assert-Remax ((Get-BitdefenderKind -Names @('Bitdefender Endpoint Security') -Services @()) -eq 'gravityzone') 'Endpoint Security is GravityZone'
    Assert-Remax ((Get-BitdefenderKind -Names @() -Services @('EPSecurityService')) -eq 'gravityzone') 'EPSecurityService is GravityZone'
    Assert-Remax ((Get-BitdefenderKind -Names @() -Services @('VSSERV')) -eq 'consumer') 'VSSERV without Endpoint Security is consumer'
    Assert-Remax ((Get-BitdefenderKind -Names @('Windows Defender') -Services @()) -eq '') 'Defender alone is not Bitdefender'
    $bdText = Get-BitdefenderGuidance -Kind 'gravityzone' -HostAddress '172.16.105.21'
    Assert-Remax ($bdText -match 'GravityZone firewall policy') 'GravityZone steps name the policy'
    Assert-Remax ($bdText -match 'spoolsv.exe') 'Bitdefender steps name spoolsv.exe'
    Assert-Remax ($bdText -match 'Home/Office') 'Bitdefender steps name the trusted network'
    $consumerText = Get-BitdefenderGuidance -Kind 'consumer' -HostAddress '172.16.105.21'
    Assert-Remax ($consumerText -match 'Consumer Bitdefender') 'consumer Bitdefender is labeled'
    Assert-Remax (-not (Test-ThirdPartySecurityProduct 'Microsoft Defender Antivirus')) 'Microsoft Defender is not third party'
    Assert-Remax (Test-ThirdPartySecurityProduct 'Bitdefender Antivirus') 'Bitdefender is third party'
    $fw = Get-RemaxFirewallRule @{ Host = '172.16.105.21' }
    Assert-Remax (Test-FirewallRuleScoped $fw) 'firewall rule is limited to spoolsv.exe and the printer'
    Assert-Remax ($fw.LocalPort -eq '721-731') 'LPR source ports 721-731 are included'
    Assert-Remax ($fw.DisplayName -eq 'RemaxSecure Print (spoolsv)') 'firewall rule name is stable'
    $reachBd = Get-ReachableDetail -Ok $false -Bitdefender $true -HostAddress '172.16.105.21' -ErrorText ''
    Assert-Remax ($reachBd -match 'likely cause') 'a failed 515 test names Bitdefender when it is present'
    $savedSkipClean = $env:REMAX_SKIP_CLEANUP
    $env:REMAX_SKIP_CLEANUP = '1'
    Assert-Remax (Test-SkipCleanup) 'REMAX_SKIP_CLEANUP=1 skips cleanup'
    if ($null -eq $savedSkipClean) { Remove-Item Env:REMAX_SKIP_CLEANUP -ErrorAction SilentlyContinue } else { $env:REMAX_SKIP_CLEANUP = $savedSkipClean }
    $savedSkipFw = $env:REMAX_SKIP_FIREWALL
    $env:REMAX_SKIP_FIREWALL = '1'
    Assert-Remax (Test-SkipFirewall) 'REMAX_SKIP_FIREWALL=1 skips the firewall rule'
    if ($null -eq $savedSkipFw) { Remove-Item Env:REMAX_SKIP_FIREWALL -ErrorAction SilentlyContinue } else { $env:REMAX_SKIP_FIREWALL = $savedSkipFw }
    Assert-Remax (Test-PnputilSuccess 0) 'pnputil exit 0 is success'
    Assert-Remax (Test-PnputilSuccess 259) 'pnputil exit 259 means the package is already present'
    Assert-Remax (Test-PnputilSuccess 3010) 'pnputil exit 3010 is success with a restart'
    Assert-Remax (-not (Test-PnputilSuccess 5)) 'pnputil exit 5 is a failure'
    $publishedSample = @(
        'Microsoft PnP Utility',
        'Adding driver package:  CNS30UA64.INF',
        'Driver package added successfully.',
        'Published Name:         oem42.inf',
        'Total driver packages:  1',
        'Added driver packages:  1'
    )
    Assert-Remax ((Get-PnputilPublishedName $publishedSample) -eq 'oem42.inf') 'pnputil Published Name is parsed'
    Assert-Remax ((ConvertTo-ExitCode @('Published Name: oem42.inf', 'Added driver packages:  1', 2)) -eq 2) 'exit code uses the last integer, not earlier text'
    Assert-Remax ((ConvertTo-ExitCode 0) -eq 0) 'exit code 0 stays 0'
    $modelInf = @"
[Manufacturer]
"Canon" = Canon,NTamd64

[Canon.NTamd64]
"Canon iR-ADV C5235/5240 PS3" = ADVC5240,USBPRINT\CanoniR-ADV_C5235/520173
"@
    Assert-Remax ((Get-InfExactModel $modelInf) -ceq 'Canon iR-ADV C5235/5240 PS3') 'quoted INF model matches character for character'
    if ($env:REMAX_SELFTEST_INF -and (Test-Path -LiteralPath $env:REMAX_SELFTEST_INF)) {
        $realText = Read-AllText $env:REMAX_SELFTEST_INF
        $realModel = Get-InfExactModel $realText
        Assert-Remax ($realModel -ceq 'Canon iR-ADV C5235/5240 PS3') 'release CNS30UA64.INF model matches exactly'
        $realPick = Select-BestDriverName -Names @(Get-InfDriverModels -Text $realText -Architecture 'amd64')
        Assert-Remax ($realPick -ceq 'Canon iR-ADV C5235/5240 PS3') 'release INF selection is the PS3 model'
    }
    $shell = Join-Path $PSHOME 'pwsh'
    if (-not (Test-Path -LiteralPath $shell)) { $shell = Join-Path $PSHOME 'powershell.exe' }
    if (Test-Path -LiteralPath $shell) {
        $probe = @(Invoke-LoggedProcess -FilePath $shell -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', 'Write-Output "published-line"; exit 7'))
        Assert-Remax ($probe.Count -eq 1) 'logged process output does not leak into the pipeline'
        Assert-Remax ([int]$probe[0].Code -eq 7) 'logged process keeps its exit code'
        Assert-Remax (($probe[0].Lines -join "`n") -match 'published-line') 'logged process output is captured'
    }
    Assert-Remax ((Get-DownloadFileName $script:CanonPkgUrl) -eq 'download.zip') 'built-in package is saved as download.zip'
    Assert-Remax ((Get-DownloadFileName 'https://example.invalid/driver.cab') -eq 'download.cab') 'cab URL is saved as download.cab'
    Assert-Remax ((Get-DownloadFileName 'https://example.invalid/driver.inf') -eq 'download.inf') 'inf URL is saved as download.inf'
    Assert-Remax ((Get-DownloadFileName 'https://example.invalid/Setup.exe') -eq 'download.exe') 'exe URL is saved as download.exe'
    Assert-Remax ((Get-PackageKindFromLeaf 'Canon-PS3-v30.00-x64.zip') -eq 'zip') 'zip leaf is a zip'
    Assert-Remax ((Resolve-PackageKind -Leaf 'file.bin' -Header ([byte[]](0x50, 0x4B, 3, 4))) -eq 'zip') 'PK header is a zip even without a .zip name'
    Assert-Remax ((Get-ArchiveKindFromHeader ([byte[]](0x4D, 0x53, 0x43, 0x46))) -eq 'cab') 'MSCF header is a cab'
    $tempRoot = $env:TEMP
    if ([string]::IsNullOrWhiteSpace($tempRoot)) { $tempRoot = [System.IO.Path]::GetTempPath() }
    $zipRoot = Join-Path $tempRoot ('remax-zip-' + [Guid]::NewGuid().ToString('n'))
    $zipSrc = Join-Path $zipRoot 'src'
    $zipOut = Join-Path $zipRoot 'out'
    New-Item -ItemType Directory -Path $zipSrc -Force | Out-Null
    New-Item -ItemType Directory -Path $zipOut -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $zipSrc 'CNS30UA64.INF') -Value 'model' -Encoding ASCII
    $zipBin = Join-Path $zipRoot 'payload.bin'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($zipSrc, $zipBin)
    $pkFile = Join-Path $zipRoot 'pk.bin'
    [System.IO.File]::WriteAllBytes($pkFile, [byte[]](0x50, 0x4B, 3, 4))
    $pkHeader = Read-FileHeader -Path $pkFile -Count 4
    Assert-Remax ((Get-ArchiveKindFromHeader $pkHeader) -eq 'zip') 'a PK file header is read back as zip'
    Expand-RemaxZip -ZipPath $zipBin -Destination $zipOut
    Assert-Remax (Test-Path -LiteralPath (Join-Path $zipOut 'CNS30UA64.INF')) 'a zip saved without a .zip name still extracts'
    Remove-Item -LiteralPath $zipRoot -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Remax ($script:CanonPkgUrl -eq 'https://github.com/ItsErod/canon-secure-print/releases/download/driver-v30/Canon-PS3-v30.00-x64.zip') 'built-in driver URL is the public release asset'
    Assert-Remax ($script:CanonPkgSha256 -eq '4db0d69d0b6417c39ed285698f9dc23dc5a90c6e3372c8f04da68b1d19b678da') 'built-in driver SHA256 is pinned'
    Assert-Remax ($script:CanonPkgBytes -eq 26722033) 'built-in driver size is pinned'
    Assert-Remax ((Get-BytesSha256 -Data ([byte[]](97))) -eq 'ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb') 'SHA256 of the byte a is correct'
    $pinnedOk = Test-PinnedCanonDownload -Url $script:CanonPkgUrl -Hash $script:CanonPkgSha256 -Length $script:CanonPkgBytes
    Assert-Remax ($pinnedOk.Ok -and $pinnedOk.Pinned) 'matching size and SHA256 pass'
    $pinnedBad = Test-PinnedCanonDownload -Url $script:CanonPkgUrl -Hash 'deadbeef' -Length $script:CanonPkgBytes
    Assert-Remax ((-not $pinnedBad.Ok) -and ($pinnedBad.Detail -match 'SHA256')) 'SHA256 mismatch is a clear failure'
    $overridePkg = Test-PinnedCanonDownload -Url 'https://example.invalid/other.zip' -Hash 'deadbeef' -Length 4
    Assert-Remax ($overridePkg.Ok -and (-not $overridePkg.Pinned)) 'a different URL is not checked against the pinned hash'
    $savedPkg = $env:REMAX_CANON_PKG_URL
    Remove-Item Env:REMAX_CANON_PKG_URL -ErrorAction SilentlyContinue
    Assert-Remax ((Resolve-CanonPackageUrl) -eq $script:CanonPkgUrl) 'missing REMAX_CANON_PKG_URL uses the built-in zip'
    $env:REMAX_CANON_PKG_URL = 'https://example.invalid/custom.zip'
    Assert-Remax ((Resolve-CanonPackageUrl) -eq 'https://example.invalid/custom.zip') 'REMAX_CANON_PKG_URL overrides the built-in zip'
    if ($null -eq $savedPkg) {
        Remove-Item Env:REMAX_CANON_PKG_URL -ErrorAction SilentlyContinue
    } else {
        $env:REMAX_CANON_PKG_URL = $savedPkg
    }
    $cnsScore = Get-CanonInfPickScore -Path 'C:\pkg\x64\Driver\CNS30UA64.INF' -Model 'Canon iR-ADV C5235/5240 PS3'
    $otherScore = Get-CanonInfPickScore -Path 'C:\pkg\x64\Driver\Other.inf' -Model 'Canon iR-ADV C5235/5240 PS3'
    $nullScore = Get-CanonInfPickScore -Path 'C:\pkg\x64\misc\NullDriver\lasernull.inf' -Model 'Canon Laser Null Driver'
    Assert-Remax ($cnsScore -gt $otherScore) 'CNS30UA64.INF outranks another PS3 INF'
    Assert-Remax ($nullScore -lt 0) 'lasernull.inf is not a printer driver candidate'
    $miniInf = @"
[Manufacturer]
"Canon" = Canon,NTamd64,NTamd64.6.0

[Canon.NTamd64]
"Canon iR-ADV C5235/5240 PS3" = ADVC5240,USBPRINT\CanoniR-ADV_C5235/520173
"Canon Laser Null Driver" = NULL,USB\NULL

[Canon.NTamd64.6.0]
"Canon iR-ADV C5235/5240 PS3" = ADVC5240_AWARE,USBPRINT\CanoniR-ADV_C5235/520173
"@
    $miniModels = @(Get-InfDriverModels -Text $miniInf -Architecture 'amd64')
    Assert-Remax ((Select-BestDriverName -Names $miniModels) -eq 'Canon iR-ADV C5235/5240 PS3') 'CNS30UA64-style INF selects the PS3 model'
    Assert-Remax ((Get-IexFinishMessage 0) -eq '') 'exit code 0 has no failure message'
    Assert-Remax ((Get-IexFinishMessage 2) -match 'RESULT PARTIAL') 'exit code 2 stays a partial message'
    $failFinish = Get-IexFinishMessage 1
    Assert-Remax (($failFinish -match 'RESULT FAIL') -and ($failFinish -notmatch 'throw')) 'exit code 1 is reported without throwing'
    Assert-Remax ((Get-PrintUserPromptText) -eq 'Print username (last name + first initial, lowercase, for example tsiogase)') 'prompt shows the tsiogase example'
    Assert-Remax ((Get-DriverRank 'Canon iR-ADV C5235/5240 PS3') -gt (Get-DriverRank 'Canon iR-ADV C5235/5240 PS')) 'exact PS3 outranks the older PS name'
    Assert-Remax ((Get-InfArchitectureScore 'C:\drv\x64\cn.inf') -gt (Get-InfArchitectureScore 'C:\drv\x86\cn.inf')) 'x64 INF outranks x86'
    Assert-Remax ((Test-CanonPackageVersionText '30.0.0.1') -eq $true) 'file version 30.0.0.1 is the recorded package'
    Assert-Remax ((Test-CanonPackageVersionText 'V30.00') -eq $true) 'package text 30.00 is accepted'
    Assert-Remax ((Test-CanonPackageVersionText '30.00.0.0') -eq $true) 'INF DriverVer 30.00.0.0 is package 30.00'
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
    $boxes = New-Object System.Collections.Generic.List[object]
    [void]$boxes.Add((New-FakeEl 'Paper Source Options:' 'Text' 30 40 180 18 '' ''))
    [void]$boxes.Add((New-FakeEl 'Cassette Feeding Unit' 'CheckBox' 40 70 200 18 '' 'Off'))
    [void]$boxes.Add((New-FakeEl 'Paper Deck Unit' 'CheckBox' 40 96 180 18 '' 'Off'))
    [void]$boxes.Add((New-FakeEl 'Envelope Feeder Attachment' 'CheckBox' 40 122 220 18 '' 'Off'))
    [void]$boxes.Add((New-FakeEl 'Output Options:' 'Text' 30 160 140 18 '' ''))
    [void]$boxes.Add((New-FakeEl '' 'ComboBox' 420 158 220 22 'None' ''))
    [void]$boxes.Add((New-FakeEl 'Copy Tray' 'CheckBox' 40 190 140 18 '' 'Off'))
    [void]$boxes.Add((New-FakeEl 'Inner Finisher Additional Tray' 'CheckBox' 40 216 220 18 '' 'Off'))
    [void]$boxes.Add((New-FakeEl 'PS Output from Application:' 'Text' 30 260 200 18 '' ''))
    [void]$boxes.Add((New-FakeEl '' 'ComboBox' 420 258 220 22 'Auto' ''))
    $boxTargets = Find-CanonDeviceTargets $boxes
    Assert-Remax ($boxTargets.PaperCheck -and (Test-CanonLabelEquals $boxTargets.PaperCheck.Name 'Cassette Feeding Unit')) 'paper source is the Cassette Feeding Unit checkbox'
    Assert-Remax ($null -eq $boxTargets.PaperCombo) 'checkbox layout has no paper source combo'
    Assert-Remax ($boxTargets.OutputCombo -and ($boxTargets.OutputCombo.Top -eq 158)) 'output combo stays on the Output Options row'
    Assert-Remax ($boxTargets.PsOutput -and ($boxTargets.PsOutput.Top -eq 258)) 'PS Output combo is found but not changed by default'
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
    trap {
        Exit-InputLock
        Complete-RemaxProgress
        break
    }
    Start-RemaxElevatedRelaunch | Out-Null
    Write-StaleLaunchWarning
    switch ($script:Mode) {
        'help' { Show-Usage; Invoke-Complete 0 }
        'usage-error' {
            Write-RemaxLine $script:UsageError
            Show-Usage
            Invoke-Complete 1
        }
        'selftest' { Invoke-Complete (ConvertTo-ExitCode (Invoke-SelfTest)) }
        'verify' { Invoke-Complete (ConvertTo-ExitCode (Invoke-Verify)) }
        default { Invoke-Complete (ConvertTo-ExitCode (Invoke-Install)) }
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
        $script:LastResult = 'FAIL'
        $script:ReportText = "RESULT: FAIL`r`n" + $message
    }
    Invoke-Complete 1
} finally {
    Exit-InputLock
    Complete-RemaxProgress
    if (-not $script:RanAsFile) {
        $ErrorActionPreference = $script:PreviousErrorAction
    }
}
