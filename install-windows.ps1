#Requires -Version 5.1
# Remax Secure Printer - Windows installer 1.1.0
# RE/MAX Escarpment IT.
#
# Elevated PowerShell (Run as administrator). The script asks for the print
# username in that window. An elevated process does not see variables from a
# normal window. To skip the prompt:
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
# Queue (same target as install-mac.sh):
#   Name:     RemaxSecure
#   URI:      lpd://172.16.105.21/RemaxSecure
#   Port:     Standard TCP/IP port RemaxSecure_LPR, protocol LPR, port 515,
#             queue name RemaxSecure. That is the Windows spooler form of the
#             lpd:// URI. It does not need the optional LPR Port Monitor feature.
#   Driver:   Canon iR-ADV C5235/5240 PS or PS3, else Canon Generic Plus PS3.
#   Sides:    Set-PrintConfiguration -DuplexingMode OneSided
#   Cassette / finisher:
#             Tried on the print ticket when the driver publishes OptCas2 or
#             IFINE1. The fleet driver does not. The script then opens
#             Printer properties and sets Device Settings: Cassette Feeding
#             Unit = On, Output Options = Inner Finisher E1.
#   Enter Name:
#             Set User Information, User Name = the print username, and
#             Default Value Settings, Name to Set for User Name = that name
#             (Enter Name, not the Windows logon). The Mac *%INFO_PrPr block
#             is not read by the Windows driver.
#   PASS on those lines requires a readback. MANUAL means the dialog could
#   not be driven or the readback did not match. Optional REMAX_DEVICE_DAT
#   restores printer-specific data and the global DEVMODE (PrintUI /Sr d g)
#   before the dialog runs. This script does not invent Canon registry values.

$script:Version = '1.1.0'
$script:RawUrl = 'https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-windows.ps1'
$script:PrinterName = 'RemaxSecure'
$script:StaleName = 'RemaxSecure_COLOUR'
$script:DefaultHost = '172.16.105.21'
$script:DefaultQueue = 'RemaxSecure'
$script:PortName = 'RemaxSecure_LPR'
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
  REMAX_PRINT_USER       Print username (Enter Name). Prompted when unset.
  REMAX_CANON_PKG_URL    Optional https URL of a .zip, .cab, or .inf driver.
                         A Canon setup .exe is not launched.
  REMAX_PRINTER_URI      Default lpd://172.16.105.21/RemaxSecure
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

function Test-GenericPlusPs3 {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name -match 'UFR|PCL|LIPS|FAX') { return $false }
    return [bool]($Name -match 'Canon Generic Plus PS3')
}

function Get-DriverRank {
    param([string]$Name)
    if (Test-ModelSpecificPsDriver $Name) { return 2 }
    if (Test-GenericPlusPs3 $Name) { return 1 }
    return 0
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
    return @{
        Host       = $hostName
        Queue      = $queue
        Uri        = ("lpd://{0}/{1}" -f $hostName, $queue)
        ByteCount  = -not ($env:REMAX_LPR_BYTE_COUNT -eq '0')
    }
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
    $prompt = 'Print username (Enter Name, the name on the copier)'
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
        if ($nativeX64 -and $environment -match 'x64') { $archBonus = 1 }
        if ((-not $nativeX64) -and $environment -match 'x86') { $archBonus = 1 }
        $score = ($rank * 10) + $archBonus
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
        $arch = Get-DriverArchitecture
        foreach ($inf in @(Get-ChildItem -LiteralPath $extract -Filter *.inf -Recurse -File -ErrorAction SilentlyContinue)) {
            $models = @(Get-InfDriverModels -Text (Read-AllText $inf.FullName) -Architecture $arch)
            $choice = Select-BestDriverName -Names $models
            $rank = Get-DriverRank $choice
            Write-Remax ("INF " + $inf.FullName + " selected model '" + $choice + "' rank " + $rank)
            if ($rank -gt $bestRank) {
                $bestRank = $rank
                $bestInf = $inf.FullName
                $bestModel = $choice
            }
        }
        if (-not $bestInf) {
            throw "The package does not contain an INF model for Canon iR-ADV C5235/5240 PS or Canon Generic Plus PS3."
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
    foreach ($dir in $dirs) {
        foreach ($inf in @(Get-ChildItem -LiteralPath $dir.FullName -Filter *.inf -Recurse -File -ErrorAction SilentlyContinue)) {
            $text = ''
            try { $text = Read-AllText $inf.FullName } catch { continue }
            if ($text -notmatch 'C5235' -and $text -notmatch 'Generic Plus PS3') { continue }
            $models = @(Get-InfDriverModels -Text $text -Architecture $arch)
            $choice = Select-BestDriverName -Names $models
            $rank = Get-DriverRank $choice
            if ($rank -gt $bestRank) {
                $bestRank = $rank
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
    Write-RemaxLine "The Canon PS driver for iR-ADV C5235/5240 is not installed."
    Write-RemaxLine "Installed printer drivers:"
    if (@($Installed).Count -eq 0) {
        Write-RemaxLine "  (none)"
    } else {
        foreach ($name in @($Installed)) { Write-RemaxLine ("  " + $name) }
    }
    Write-RemaxLine @"

Install a Windows PostScript driver, then run this installer again.

Accepted driver names:
  Canon iR-ADV C5235/5240 PS
  Canon iR-ADV C5235/5240 PS3
  Canon Generic Plus PS3

For Generic Plus PS3, Device Settings configuration profile must be
iR-ADV C5235/5240. PrintManagement cannot read that profile.
Do not use the UFR II or PCL driver for this queue.
The Mac PPD CNMCIRAC5235S2.ppd.gz is not a Windows driver package.
Canon publishes the PostScript 3 driver and Generic Plus PS3 on the
imageRUNNER ADVANCE C5235 support page. This script has no built-in download.

To install from a package you host, set REMAX_CANON_PKG_URL to an https
URL ending in .zip, .cab, or .inf (a zip of the extracted Driver folder).
A Canon setup .exe is not launched, because that opens a GUI. If 7-Zip is
installed, an .exe URL is unpacked and the INF inside is added with pnputil.

  `$env:REMAX_CANON_PKG_URL = 'https://your-host.example/Canon-PS-driver.zip'
  `$env:REMAX_PRINT_USER = 'tsiogase'
  irm $script:RawUrl | iex
"@
}

function Get-PortSnapshot {
    param([string]$Name)
    $safe = $Name.Replace("'", "''")
    $port = Get-CimInstance -ClassName Win32_TCPIPPrinterPort -Filter ("Name='" + $safe + "'")
    if (-not $port) { return $null }
    return @{
        Name       = [string]$port.Name
        Host       = [string]$port.HostAddress
        Queue      = [string]$port.Queue
        Protocol   = [int]$port.Protocol
        PortNumber = [int]$port.PortNumber
        ByteCount  = [bool]$port.ByteCount
        Cim        = $port
    }
}

function Test-PortMatches {
    param($Snapshot, $Target)
    if (-not $Snapshot) { return $false }
    if ($Snapshot.Host -ne $Target.Host) { return $false }
    if ($Snapshot.Queue -ne $Target.Queue) { return $false }
    if ($Snapshot.Protocol -ne 2) { return $false }
    if ($Snapshot.PortNumber -ne 515) { return $false }
    if ([bool]$Snapshot.ByteCount -ne [bool]$Target.ByteCount) { return $false }
    return $true
}

function Set-PortFields {
    param($Snapshot, $Target)
    $port = $Snapshot.Cim
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
        Write-Remax "Updating LPR host, queue, protocol 2, port 515, and byte counting on the existing port."
        Set-PortFields $snapshot $Target
        $snapshot = Get-PortSnapshot $script:PortName
    }
    if (-not (Test-PortMatches $snapshot $Target)) {
        throw ("Port " + $script:PortName + " is still not LPR to " + $Target.Uri + ". Host=" + $snapshot.Host + " Queue=" + $snapshot.Queue + " Protocol=" + $snapshot.Protocol + " PortNumber=" + $snapshot.PortNumber)
    }
    return $snapshot
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
    $existing = Get-PrinterOrNull $script:PrinterName
    if (-not $existing) {
        Write-Remax ("Creating queue " + $script:PrinterName)
        Add-Printer -Name $script:PrinterName -DriverName $DriverName -PortName $script:PortName
    } else {
        Write-Remax ("Updating existing queue " + $script:PrinterName)
        Set-Printer -Name $script:PrinterName -DriverName $DriverName -PortName $script:PortName
    }
    try {
        Set-Printer -Name $script:PrinterName -Comment 'RE/MAX Secure Printer' -Location 'RE/MAX Escarpment'
    } catch {
        Write-Remax ("Comment and location were not set: " + $_.Exception.Message)
    }
    try {
        $printer = Get-CimInstance -ClassName Win32_Printer -Filter ("Name='" + $script:PrinterName.Replace("'", "''") + "'")
        if ($printer) {
            Invoke-CimMethod -InputObject $printer -MethodName Resume | Out-Null
        }
    } catch {
        Write-Remax ("Resume printer skipped: " + $_.Exception.Message)
    }
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
        return Find-PrintFeatureOption -CapabilitiesXml $CapabilitiesXml -OptionLocalName 'OptCas2' -FeatureDisplay 'Cassette Feeding Unit' -OptionDisplay 'On'
    }
    return Find-PrintFeatureOption -CapabilitiesXml $CapabilitiesXml -OptionLocalName 'IFINE1' -FeatureDisplay '' -OptionDisplay 'Inner Finisher E1'
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

function Test-LogonModeLabel {
    param([string]$Label)
    return (Test-LabelInSet $Label @(
        'Logon Name', 'Logon', 'Log-in name', 'Log in name', 'Login name', 'Login',
        'Computer name', 'Computer', 'Domain name', 'Windows logon name',
        'User Account Name', 'User Account Display Name', 'User Principal Name'
    ))
}

function Test-EnterModeLabel {
    param([string]$Label, [string]$PrintUser)
    if (Test-LogonModeLabel $Label) { return $false }
    $norm = (ConvertTo-CanonLabel $Label).ToLowerInvariant()
    if (-not $norm) { return $false }
    if ($PrintUser -and (Test-CanonLabelEquals $Label $PrintUser)) { return $true }
    return (Test-LabelInSet $Label @(
        'Enter Name', 'Entered Name', 'Name entered', 'Any desired name', 'Desired name',
        'Specify name', 'Custom name', 'Custom', 'Input name', 'Set name', 'Any name',
        'Enter a name'
    ))
}

function Test-EnterNameConfigured {
    param(
        [string]$UserField,
        [string]$NameToSet,
        [string]$PrintUser,
        [bool]$SawNameToSet
    )
    if (-not $SawNameToSet) { return $false }
    if (Test-LogonModeLabel $NameToSet) { return $false }
    if ($PrintUser) {
        if (-not (Test-CanonLabelEquals $UserField $PrintUser)) { return $false }
    } elseif ([string]::IsNullOrWhiteSpace($UserField)) {
        return $false
    }
    if (Test-EnterModeLabel $NameToSet $PrintUser) { return $true }
    if ($UserField -and (Test-CanonLabelEquals $NameToSet $UserField)) { return $true }
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

function Find-CanonDeviceTargets {
    param($Elements)
    $cassette = Select-LabeledControl -Elements $Elements -Labels @('Cassette Feeding Unit') -ControlType 'CheckBox'
    $output = Find-CanonComboByLabel -Elements $Elements -Labels @('Output Options')
    $user = Select-LabeledControl -Elements $Elements -Labels @('Set User Information') -ControlType 'CheckBox'
    $settings = $null
    if ($user) {
        $settings = Select-RowControl -Elements $Elements -Anchor $user -ControlType 'Button' -LabelEquals 'Settings' -ToTheRight
    }
    $profile = Find-CanonComboByLabel -Elements $Elements -Labels @('Config. Profile', 'Configuration Profile', 'Config Profile')
    return @{
        Cassette     = $cassette
        OutputCombo  = $output
        UserInfo     = $user
        UserSettings = $settings
        Profile      = $profile
    }
}

function Find-CanonUserDialogTargets {
    param($Elements)
    $edit = Find-CanonEditByLabel -Elements $Elements -Labels @('User Name')
    $button = Select-LabeledControl -Elements $Elements -Labels @('Default Value Settings', 'User Name Management') -ControlType 'Button'
    return @{ UserNameEdit = $edit; DefaultButton = $button }
}

function Find-CanonDefaultTargets {
    param($Elements)
    $combo = Find-CanonComboByLabel -Elements $Elements -Labels @('Name to Set for User Name', 'Name Set for User Name')
    $edit = Find-CanonEditByLabel -Elements $Elements -Labels @('Name to Set for User Name', 'Name Set for User Name')
    $radios = @()
    foreach ($el in @(Get-CanonElements $Elements)) {
        if (-not $el) { continue }
        if (Test-ElementOffscreen $el) { continue }
        if ($el.ControlType -eq 'RadioButton') { $radios += $el }
    }
    return @{ Combo = $combo; Edit = $edit; Radios = @($radios) }
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

function Resolve-NameToSetLabel {
    param([string[]]$Labels, [string]$PrintUser, [switch]$KnownOnly)
    $modes = @(
        'Enter Name', 'Entered Name', 'Name entered', 'Any desired name',
        'Desired name', 'Specify name', 'Custom name', 'Custom', 'Input name',
        'Set name', 'Any name', 'Enter a name'
    )
    $exact = Resolve-CanonChoiceLabel -Labels $Labels -Accept $modes
    if ($exact) { return $exact }
    if ($PrintUser) {
        $named = Resolve-CanonChoiceLabel -Labels $Labels -Accept @($PrintUser)
        if ($named) { return $named }
    }
    if ($KnownOnly) { return $null }
    $candidates = @()
    foreach ($label in @($Labels)) {
        if ([string]::IsNullOrWhiteSpace($label)) { continue }
        if (Test-LogonModeLabel $label) { continue }
        $candidates += $label
    }
    if (@($candidates).Count -eq 1) { return $candidates[0] }
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
        [string]$UiState,
        [string]$UiDetail,
        [bool]$Attempted
    )
    if ($UiState -eq 'PASS') {
        return @{ State = 'PASS'; Detail = $UiDetail }
    }
    if ($TicketState -eq 'PASS' -and $UiState -ne 'FAIL') {
        return @{ State = 'PASS'; Detail = $TicketDetail }
    }
    if ($Attempted -and $UiState) {
        $detail = $UiDetail
        if (-not $detail) { $detail = $TicketDetail }
        return @{ State = $UiState; Detail = $detail }
    }
    return @{ State = $TicketState; Detail = $TicketDetail }
}

function New-DeviceUiResult {
    return @{
        Attempted       = $false
        SkipReason      = ''
        CassetteState   = 'MANUAL'
        CassetteDetail  = ''
        FinisherState   = 'MANUAL'
        FinisherDetail  = ''
        EnterState      = 'MANUAL'
        EnterDetail     = ''
        ProfileDetail   = ''
    }
}

function New-CanonRead {
    return @{
        Opened         = $false
        Error          = ''
        CassetteSeen   = $false
        CassetteOn     = $false
        FinisherSeen   = $false
        FinisherValue  = ''
        ProfileValue   = ''
        UserDialog     = $false
        UserField      = ''
        NameToSetSeen  = $false
        NameToSet      = ''
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
        'Output Options', 'Config. Profile', 'Configuration Profile', 'Config Profile',
        'External Puncher', 'PS Output from Application',
        'Name to Set for User Name', 'Name Set for User Name'
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
    param($Button, [int]$ProcessId, $Exclude)
    if (-not $Button) { return $null }
    [void](Invoke-CanonButton -Snapshot $Button -How post)
    $dlg = Wait-UiaTopWindow -ProcessId $ProcessId -Exclude $Exclude -TimeoutMs 8000 -SkipProperties
    if ($dlg) { return $dlg }
    [void](Invoke-CanonButton -Snapshot $Button -How mouse)
    $dlg = Wait-UiaTopWindow -ProcessId $ProcessId -Exclude $Exclude -TimeoutMs 4000 -SkipProperties
    if ($dlg) { return $dlg }
    [void](Invoke-CanonButton -Snapshot $Button -How invoke)
    return (Wait-UiaTopWindow -ProcessId $ProcessId -Exclude $Exclude -TimeoutMs 4000 -SkipProperties)
}

function Read-CanonNameToSet {
    param($Elements)
    $targets = Find-CanonDefaultTargets $Elements
    $seen = $false
    $value = ''
    if ($targets.Combo) {
        $seen = $true
        $value = Get-ComboDisplay $targets.Combo
    }
    if (-not $value) {
        foreach ($radio in @($targets.Radios)) {
            if ($radio.Toggle -eq 'On' -or $radio.Selected) {
                $seen = $true
                $value = [string]$radio.Name
                break
            }
        }
    }
    if (-not $value -and $targets.Edit) {
        $seen = $true
        $value = [string]$targets.Edit.Value
    } elseif ($targets.Edit -and -not $seen) {
        $seen = $true
    }
    return @{ Seen = [bool]$seen; Value = [string]$value }
}

function Disable-UserNameLock {
    param($Elements)
    $lock = Select-LabeledControl -Elements $Elements -Labels @('Do Not Allow User Name Changes') -ControlType 'CheckBox'
    if ($lock -and $lock.Toggle -eq 'On') {
        Write-Remax "Clearing Do Not Allow User Name Changes so the print username can be written."
        [void](Set-CanonCheck -Snapshot $lock -On $false)
    }
}

function Set-NameToSetOnWindow {
    param($Window, [string]$PrintUser)
    $elements = Get-UiaDescendants $Window
    Disable-UserNameLock $elements
    $elements = Get-UiaDescendants $Window
    $targets = Find-CanonDefaultTargets $elements
    $picked = $false
    $pickLabel = ''
    if ($targets.Combo) {
        $opened = Get-CanonComboChoices $targets.Combo
        $pickLabel = Resolve-NameToSetLabel -Labels $opened.Labels -PrintUser $PrintUser
        if ($pickLabel) {
            $picked = Select-ListedComboItem -Items $opened.Items -Label $pickLabel -Combo $targets.Combo
            Write-Remax ("Name to Set for User Name choice: " + $pickLabel)
        } else {
            $listed = ''
            if ($opened.Labels) { $listed = ($opened.Labels -join ' | ') }
            Write-Remax ("Name to Set list had no Enter Name choice: " + $listed)
            Collapse-CanonCombo $targets.Combo
        }
    }
    if (-not $picked) {
        $names = @()
        foreach ($radio in @($targets.Radios)) { $names += [string]$radio.Name }
        if (@($names).Count -gt 0) {
            $pickLabel = Resolve-NameToSetLabel -Labels $names -PrintUser $PrintUser -KnownOnly
            if ($pickLabel) {
                $picked = Select-CanonRadio -Radios $targets.Radios -Label $pickLabel
                Write-Remax ("Name to Set radio: " + $pickLabel)
            }
        }
    }
    $elements = Get-UiaDescendants $Window
    $targets = Find-CanonDefaultTargets $elements
    if ($targets.Edit) {
        $wrote = Set-CanonEdit -Snapshot $targets.Edit -Text $PrintUser
        if ($wrote) { $picked = $true }
    } elseif ($pickLabel) {
        $chosen = $null
        foreach ($radio in @($targets.Radios)) {
            if (Test-CanonLabelEquals $radio.Name $pickLabel) { $chosen = $radio }
        }
        if ($chosen) {
            $edit = Select-RowControl -Elements $elements -Anchor $chosen -ControlType 'Edit' -ToTheRight
            if ($edit) {
                $wrote = Set-CanonEdit -Snapshot $edit -Text $PrintUser
                if ($wrote) { $picked = $true }
            }
        }
    }
    return $picked
}

function Update-CanonUserDialogs {
    param($Window, $Button, [string]$PrintUser, [int]$ProcessId, [switch]$ReadOnly)
    $result = @{ Opened = $false; UserField = ''; NameToSet = ''; NameToSetSeen = $false }
    $props = [IntPtr]::Zero
    try { $props = [IntPtr]$Window.Current.NativeWindowHandle } catch { $props = [IntPtr]::Zero }
    $userDlg = Open-ChildDialog -Button $Button -ProcessId $ProcessId -Exclude @($props)
    if (-not $userDlg) {
        Write-Remax "Set User Information dialog did not open."
        return $result
    }
    $result.Opened = $true
    Show-CanonWindow $userDlg
    $userHandle = [IntPtr]::Zero
    try { $userHandle = [IntPtr]$userDlg.Current.NativeWindowHandle } catch { $userHandle = [IntPtr]::Zero }
    $elements = @()
    try { $elements = Get-UiaDescendants $userDlg } catch { $elements = @() }
    Write-UiaSummary $elements
    $userTargets = Find-CanonUserDialogTargets $elements
    $nestedHandle = [IntPtr]::Zero
    $openedDefault = $false
    if ($userTargets.DefaultButton) {
        $nested = Open-ChildDialog -Button $userTargets.DefaultButton -ProcessId $ProcessId -Exclude @($props, $userHandle)
            if ($nested) {
            $openedDefault = $true
            Show-CanonWindow $nested
            try { $nestedHandle = [IntPtr]$nested.Current.NativeWindowHandle } catch { $nestedHandle = [IntPtr]::Zero }
            if ($ReadOnly) {
                $nestedElements = @()
                try { $nestedElements = Get-UiaDescendants $nested } catch { $nestedElements = @() }
                Write-UiaSummary $nestedElements
                $info = Read-CanonNameToSet $nestedElements
                $result.NameToSetSeen = [bool]$info.Seen
                $result.NameToSet = [string]$info.Value
                [void](Click-DialogButton -Window $nested -Labels @('Cancel', 'Close') -CloseHandle $nestedHandle)
            } else {
                $picked = Set-NameToSetOnWindow -Window $nested -PrintUser $PrintUser
                if ($picked) {
                    [void](Click-DialogButton -Window $nested -Labels @('OK') -CloseHandle $nestedHandle)
                } else {
                    [void](Click-DialogButton -Window $nested -Labels @('Cancel', 'Close') -CloseHandle $nestedHandle)
                }
            }
            [void](Wait-WindowClosed -Handle $nestedHandle -TimeoutMs 5000)
        } else {
            Write-Remax "Default Value Settings dialog did not open."
        }
    }
    try { $elements = Get-UiaDescendants $userDlg } catch { $elements = @() }
    if (-not $ReadOnly) {
        Disable-UserNameLock $elements
        if (-not $openedDefault) {
            $inlinePicked = Set-NameToSetOnWindow -Window $userDlg -PrintUser $PrintUser
            if ($inlinePicked) { Write-Remax "Name to Set controls on the user dialog were written." }
        }
        try { $elements = Get-UiaDescendants $userDlg } catch { $elements = @() }
    }
    $inline = Read-CanonNameToSet $elements
    if ($inline.Seen -and -not $result.NameToSetSeen) {
        $result.NameToSetSeen = $true
        $result.NameToSet = [string]$inline.Value
    }
    $userTargets = Find-CanonUserDialogTargets $elements
    if ($userTargets.UserNameEdit) {
        if (-not $ReadOnly) {
            [void](Set-CanonEdit -Snapshot $userTargets.UserNameEdit -Text $PrintUser)
            try { $elements = Get-UiaDescendants $userDlg } catch { $elements = @() }
            $userTargets = Find-CanonUserDialogTargets $elements
        }
        if ($userTargets.UserNameEdit) { $result.UserField = [string]$userTargets.UserNameEdit.Value }
    } else {
        Write-Remax "User Name field was not found."
    }
    if ($ReadOnly) {
        [void](Click-DialogButton -Window $userDlg -Labels @('Cancel', 'Close') -CloseHandle $userHandle)
    } else {
        [void](Click-DialogButton -Window $userDlg -Labels @('OK') -CloseHandle $userHandle)
    }
    [void](Wait-WindowClosed -Handle $userHandle -TimeoutMs 5000)
    return $result
}

function Select-UiaTab {
    param($Window, [string]$TabName)
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::TabItem
    )
    $tabs = $null
    try { $tabs = $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond) } catch { return $false }
    $names = @()
    foreach ($tab in @($tabs)) {
        if (-not $tab) { continue }
        $name = ''
        try { $name = [string]$tab.Current.Name } catch { $name = '' }
        $names += $name
        if (-not (Test-CanonLabelEquals $name $TabName)) { continue }
        try {
            $pattern = $null
            if ($tab.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) {
                $pattern.Select()
                return $true
            }
        } catch {
            Write-Remax ("Device Settings tab select failed: " + $_.Exception.Message)
        }
    }
    Write-Remax ("Tabs seen: " + ($names -join ' | '))
    return $false
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
    if ($targets.Cassette) {
        $ok = Set-CanonCheck -Snapshot $targets.Cassette -On $true
        Write-Remax ("Cassette Feeding Unit set On: " + $ok)
        Start-Sleep -Milliseconds 300
        $elements = Get-UiaDescendants $Window
        $targets = Find-CanonDeviceTargets $elements
    } else {
        Write-Remax "Cassette Feeding Unit checkbox was not found."
    }
    if ($targets.OutputCombo) {
        $opened = Get-CanonComboChoices $targets.OutputCombo
        $pick = Resolve-FinisherLabel $opened.Labels
        if ($pick) {
            $ok = Select-ListedComboItem -Items $opened.Items -Label $pick -Combo $targets.OutputCombo
            Write-Remax ("Output Options set to " + $pick + ": " + $ok)
        } else {
            $listed = ''
            if ($opened.Labels) { $listed = ($opened.Labels -join ' | ') }
            Write-Remax ("Output Options has no Inner Finisher E1. Choices: " + $listed)
            Collapse-CanonCombo $targets.OutputCombo
        }
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
    if ($targets.UserSettings) {
        [void](Update-CanonUserDialogs -Window $Window -Button $targets.UserSettings -PrintUser $PrintUser -ProcessId $ProcessId)
    } else {
        Write-Remax "Set User Information Settings button was not found."
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
    if ($targets.Cassette) {
        $read.CassetteSeen = $true
        $read.CassetteOn = ($targets.Cassette.Toggle -eq 'On')
    }
    if ($targets.OutputCombo) {
        $read.FinisherSeen = $true
        $read.FinisherValue = Get-ComboDisplay $targets.OutputCombo
    }
    if ($targets.Profile) {
        $read.ProfileValue = Get-ComboDisplay $targets.Profile
    }
    if ($targets.UserSettings) {
        $info = Update-CanonUserDialogs -Window $Window -Button $targets.UserSettings -PrintUser $PrintUser -ProcessId $ProcessId -ReadOnly
        $read.UserDialog = [bool]$info.Opened
        $read.UserField = [string]$info.UserField
        $read.NameToSetSeen = [bool]$info.NameToSetSeen
        $read.NameToSet = [string]$info.NameToSet
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
        $result.CassetteDetail = $msg
        $result.FinisherDetail = $msg
        $result.EnterDetail = $msg
        return $result
    }
    if ($Read.Error -and -not $Read.CassetteSeen -and -not $Read.FinisherSeen) {
        $result.CassetteDetail = [string]$Read.Error
        $result.FinisherDetail = [string]$Read.Error
        $result.EnterDetail = [string]$Read.Error
        return $result
    }
    if ($Read.CassetteSeen -and $Read.CassetteOn) {
        $result.CassetteState = 'PASS'
        $result.CassetteDetail = 'Device Settings readback: Cassette Feeding Unit is On.'
    } elseif ($Read.CassetteSeen) {
        $result.CassetteState = $wrongState
        $result.CassetteDetail = 'Device Settings readback: Cassette Feeding Unit is Off.'
    } else {
        $result.CassetteDetail = 'Device Settings dialog had no Cassette Feeding Unit checkbox.'
    }
    $finisherOk = $false
    if ($Read.FinisherValue) {
        $match = Resolve-FinisherLabel -Labels @([string]$Read.FinisherValue)
        if ($match) { $finisherOk = $true }
    }
    if ($Read.FinisherSeen -and $finisherOk) {
        $result.FinisherState = 'PASS'
        $result.FinisherDetail = 'Device Settings readback: Output Options is Inner Finisher E1.'
    } elseif ($Read.FinisherSeen) {
        $result.FinisherState = $wrongState
        $shown = [string]$Read.FinisherValue
        if (-not $shown) { $shown = 'blank' }
        $result.FinisherDetail = 'Device Settings readback: Output Options is ' + $shown + '.'
    } else {
        $result.FinisherDetail = 'Device Settings dialog had no Output Options combo.'
    }
    $enterOk = Test-EnterNameConfigured -UserField $Read.UserField -NameToSet $Read.NameToSet -PrintUser $PrintUser -SawNameToSet $Read.NameToSetSeen
    if ($enterOk) {
        $result.EnterState = 'PASS'
        $who = [string]$Read.UserField
        $mode = ConvertTo-CanonLabel $Read.NameToSet
        $result.EnterDetail = 'Device Settings readback: User Name is ' + $who + ' and Name to Set for User Name is ' + $mode + '.'
    } elseif (-not $Read.UserDialog) {
        $result.EnterDetail = 'Set User Information dialog did not open.'
    } elseif (-not $Read.NameToSetSeen) {
        $result.EnterDetail = 'Default Value Settings did not show Name to Set for User Name.'
    } else {
        $result.EnterState = $wrongState
        $who = [string]$Read.UserField
        if (-not $who) { $who = 'blank' }
        $mode = ConvertTo-CanonLabel $Read.NameToSet
        if (-not $mode) { $mode = 'blank' }
        $result.EnterDetail = 'Device Settings readback: User Name is ' + $who + ' and Name to Set for User Name is ' + $mode + '.'
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
        $result.CassetteDetail = $msg
        $result.FinisherDetail = $msg
        $result.EnterDetail = $msg
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

function Apply-DeviceUiResult {
    param($Status, $Ui, [string]$PrintUser)
    if (-not $Ui) { return }
    $pairs = New-Object System.Collections.Generic.List[object]
    [void]$pairs.Add((@{ Label = 'CASSETTE'; UiState = [string]$Ui.CassetteState; UiDetail = [string]$Ui.CassetteDetail }))
    [void]$pairs.Add((@{ Label = 'FINISHER'; UiState = [string]$Ui.FinisherState; UiDetail = [string]$Ui.FinisherDetail }))
    foreach ($pair in $pairs) {
        $merged = Merge-DeviceLine -TicketState $Status[$pair.Label].State -TicketDetail $Status[$pair.Label].Detail -UiState $pair.UiState -UiDetail $pair.UiDetail -Attempted ([bool]$Ui.Attempted)
        if ($Ui.SkipReason -and $merged.State -ne 'PASS' -and -not $Ui.Attempted) {
            $merged.Detail = $merged.Detail + " Device Settings automation skipped (" + $Ui.SkipReason + ")."
        }
        $Status[$pair.Label].State = $merged.State
        $Status[$pair.Label].Detail = $merged.Detail
    }
    if ($Ui.EnterState -eq 'PASS') {
        $Status['ENTER NAME'].State = 'PASS'
        $Status['ENTER NAME'].Detail = [string]$Ui.EnterDetail
    } elseif ($Ui.Attempted) {
        $Status['ENTER NAME'].State = [string]$Ui.EnterState
        $detail = [string]$Ui.EnterDetail
        if (-not $detail) { $detail = Get-EnterNameDetail $PrintUser }
        $Status['ENTER NAME'].Detail = $detail
    } else {
        $Status['ENTER NAME'].State = 'MANUAL'
        $why = ''
        if ($Ui.SkipReason) { $why = "Device Settings automation skipped (" + $Ui.SkipReason + "). " }
        $Status['ENTER NAME'].Detail = $why + (Get-EnterNameDetail $PrintUser)
    }
    if ($Ui.ProfileDetail -and $Status['DRIVER'].State -eq 'PASS') {
        $Status['DRIVER'].Detail = $Status['DRIVER'].Detail + " " + $Ui.ProfileDetail
    }
}


function Apply-PublishedHardware {
    $result = @{
        CassetteState  = 'MANUAL'
        CassetteDetail = 'Cassette Feeding Unit = On. This driver did not publish print-ticket option OptCas2. Set it in Printer properties, Device Settings.'
        FinisherState  = 'MANUAL'
        FinisherDetail = 'Output Options = Inner Finisher E1. This driver did not publish print-ticket option IFINE1. Set it in Printer properties, Device Settings.'
    }
    $caps = ''
    try {
        $caps = Get-QueueXml -Capabilities -WriteAccess
    } catch {
        Write-Remax ("Print capabilities were not readable: " + $_.Exception.Message)
        $result.CassetteDetail = 'Cassette Feeding Unit = On. Print capabilities could not be read. Set Device Settings by hand.'
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
    if ($cassette -and (Test-TicketHasOption -TicketXml $readback -OptionLocalName 'OptCas2')) {
        $result.CassetteState = 'PASS'
        $result.CassetteDetail = "Default print ticket option OptCas2 (Cassette Feeding Unit ON), " + $cassette.How
    } elseif ($cassette) {
        $result.CassetteDetail = 'Driver published OptCas2 but the default print ticket did not keep it. Set Cassette Feeding Unit = On in Device Settings.'
    }
    if ($finisher -and (Test-TicketHasOption -TicketXml $readback -OptionLocalName 'IFINE1')) {
        $result.FinisherState = 'PASS'
        $result.FinisherDetail = "Default print ticket option IFINE1 (Inner Finisher E1), " + $finisher.How
    } elseif ($finisher) {
        $result.FinisherDetail = 'Driver published IFINE1 but the default print ticket did not keep it. Set Output Options = Inner Finisher E1 in Device Settings.'
    }
    return $result
}

function Read-HardwareFromTicket {
    $result = @{
        CassetteState  = 'MANUAL'
        CassetteDetail = 'Cassette Feeding Unit = On is not on the default print ticket. Check Printer properties, Device Settings.'
        FinisherState  = 'MANUAL'
        FinisherDetail = 'Inner Finisher E1 is not on the default print ticket. Check Printer properties, Device Settings.'
    }
    $ticket = ''
    try {
        $ticket = Get-QueueXml
    } catch {
        $result.CassetteDetail = 'Could not read the default print ticket. Check Device Settings for Cassette Feeding Unit = On.'
        $result.FinisherDetail = 'Could not read the default print ticket. Check Device Settings for Output Options = Inner Finisher E1.'
        return $result
    }
    if (Test-TicketHasOption -TicketXml $ticket -OptionLocalName 'OptCas2') {
        $result.CassetteState = 'PASS'
        $result.CassetteDetail = 'Default print ticket contains option OptCas2 (Cassette Feeding Unit ON)'
    }
    if (Test-TicketHasOption -TicketXml $ticket -OptionLocalName 'IFINE1') {
        $result.FinisherState = 'PASS'
        $result.FinisherDetail = 'Default print ticket contains option IFINE1 (Inner Finisher E1)'
    }
    return $result
}

function Get-EnterNameDetail {
    param([string]$PrintUser)
    $name = $PrintUser
    if ([string]::IsNullOrWhiteSpace($name)) {
        $saved = Join-Path $script:SupportDir 'requested-print-user.txt'
        if (Test-Path -LiteralPath $saved) {
            $name = (Get-Content -LiteralPath $saved -Raw).Trim()
        }
    }
    $who = 'the print username'
    if (-not [string]::IsNullOrWhiteSpace($name)) { $who = $name }
    return @"
Printer properties, Device Settings, Set User Information, Settings: User Name = $who. In Default Value Settings set Name to Set for User Name to that entered name. Canon documents this separately from the Windows logon name. The Windows driver does not read the Mac PPD *%INFO_PrPr block.
"@.Trim()
}

function Get-ReportFooter {
    param(
        [string]$Result,
        [string]$PrintUser,
        [bool]$Verify
    )
    if ($Verify) {
        return "No queue changes were saved. Verify opens Printer properties, reads Device Settings, and clicks Cancel. PASS on cassette, finisher, or Enter Name means that control was read back. MANUAL means it could not be read. FAIL on those lines means the value was read and does not match. PASS on SIDES is DuplexingMode OneSided."
    }
    if ($Result -eq 'PASS') {
        return "Cassette Feeding Unit, Output Options, and Enter Name were read back from Printer properties. One-sided is the spooler default. Close and reopen Printer properties if that window was already open during the install."
    }
    if ($Result -eq 'PARTIAL') {
        $user = $PrintUser
        if ([string]::IsNullOrWhiteSpace($user)) { $user = 'the print username' }
        return @"
RESULT PARTIAL means the RemaxSecure queue, LPR port, driver, and any PASS lines are in place.
MANUAL means Device Settings automation did not verify that line. Re-running the installer tries the dialog again.
Exit code 2 is not a failed install. When this script is started with irm | iex, exit code 2 does not throw.
1. Printer properties for $script:PrinterName, Device Settings.
2. If the driver is Canon Generic Plus PS3, set Config. Profile to iR-ADV C5235/5240.
3. Cassette Feeding Unit = On.
4. Output Options = Inner Finisher E1.
5. Set User Information, Settings, User Name = $user.
   Default Value Settings, Name to Set for User Name = that entered name (not the Windows logon name).
6. When SIDES is PASS, one-sided is already the spooler default. Close and reopen Printer properties if they were open during the install.
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
    $order = @(
        'QUEUE', 'URI', 'DRIVER', 'CASSETTE', 'FINISHER', 'SIDES', 'ENTER NAME', 'STALE QUEUE'
    )
    $states = @()
    foreach ($label in $order) { $states += [string]$Status[$label].State }
    $result = Get-ResultLabel $states
    $code = Get-ExitCodeForResult $result
    $title = 'INSTALL REPORT'
    if ($Verify) { $title = 'VERIFY REPORT' }
    Write-RemaxLine ("======== Remax Secure Printer " + $title + " ========")
    if ($Verify) { Write-RemaxLine "No changes made." }
    Write-RemaxLine ("Version:     " + $script:Version)
    Write-RemaxLine ("RESULT:      " + $result)
    Write-RemaxLine ("ExitCode:    " + $code)
    foreach ($label in $order) {
        $row = $Status[$label]
        $prefix = switch ($label) {
            'QUEUE' { 'QUEUE:       ' }
            'URI' { 'URI:         ' }
            'DRIVER' { 'DRIVER:      ' }
            'CASSETTE' { 'CASSETTE:    ' }
            'FINISHER' { 'FINISHER:    ' }
            'SIDES' { 'SIDES:       ' }
            'ENTER NAME' { 'ENTER NAME:  ' }
            'STALE QUEUE' { 'STALE QUEUE: ' }
        }
        Write-RemaxLine ($prefix + $row.State + "  " + $row.Detail)
    }
    if ($PrintUser) { Write-RemaxLine ("Print user:  " + $PrintUser) }
    try {
        $account = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        Write-RemaxLine ("Windows account: " + $account + " (logon name, not written as Enter Name)")
    } catch {
    }
    Write-RemaxLine ("Log:         " + $script:LogFile)
    if ($script:SupportDir) { Write-RemaxLine ("Copy:        " + $script:SupportDir) }
    Write-RemaxLine "======================================================"
    Write-RemaxLine (Get-ReportFooter -Result $result -PrintUser $PrintUser -Verify $Verify)
    $script:ReportDone = $true
    return $code
}

function New-StatusMap {
    $map = @{}
    foreach ($label in @('QUEUE', 'URI', 'DRIVER', 'CASSETTE', 'FINISHER', 'SIDES', 'ENTER NAME', 'STALE QUEUE')) {
        $map[$label] = @{ State = 'FAIL'; Detail = 'not checked' }
    }
    return $map
}

function Get-QueueStatus {
    param($Target)
    $status = New-StatusMap
    $printer = Get-PrinterOrNull $script:PrinterName
    if (-not $printer) {
        $status['QUEUE'].Detail = ($script:PrinterName + " is not installed")
        $status['URI'].Detail = "expected " + $Target.Uri
        $status['DRIVER'].Detail = "queue not installed"
        $status['CASSETTE'].Detail = "queue not installed"
        $status['FINISHER'].Detail = "queue not installed"
        $status['SIDES'].Detail = "queue not installed"
        $status['ENTER NAME'].Detail = "queue not installed"
    } else {
        $status['QUEUE'].State = 'PASS'
        $status['QUEUE'].Detail = ($script:PrinterName + " is installed on port " + $printer.PortName + " with driver " + $printer.DriverName)
        $snapshot = $null
        $portError = ''
        try {
            $snapshot = Get-PortSnapshot ([string]$printer.PortName)
        } catch {
            $portError = $_.Exception.Message
        }
        if ($snapshot -and (Test-PortMatches $snapshot $Target)) {
            $status['URI'].State = 'PASS'
            $status['URI'].Detail = ($Target.Uri + " (Standard TCP/IP port " + $snapshot.Name + ", protocol LPR, queue " + $snapshot.Queue + ", port 515)")
        } elseif ($portError) {
            $status['URI'].Detail = ("expected " + $Target.Uri + "; could not read Win32_TCPIPPrinterPort (" + $portError + ")")
        } else {
            $got = 'missing'
            if ($snapshot) {
                $got = ("host " + $snapshot.Host + " queue " + $snapshot.Queue + " protocol " + $snapshot.Protocol + " port " + $snapshot.PortNumber)
            }
            $status['URI'].Detail = ("expected " + $Target.Uri + " protocol LPR port 515; found " + $got)
        }
        $driverName = [string]$printer.DriverName
        $rank = Get-DriverRank $driverName
        if ($rank -ge 2) {
            $status['DRIVER'].State = 'PASS'
            $status['DRIVER'].Detail = $driverName
        } elseif ($rank -eq 1) {
            $status['DRIVER'].State = 'PASS'
            $status['DRIVER'].Detail = ($driverName + ". Config. Profile is not readable from PrintManagement. Set it to iR-ADV C5235/5240 in Device Settings.")
        } else {
            $status['DRIVER'].Detail = ("installed driver '" + $driverName + "' is not Canon iR-ADV C5235/5240 PS or Canon Generic Plus PS3")
            $status['ENTER NAME'].Detail = 'Enter Name was not checked because the queue driver is not the Canon PS driver'
            $status['CASSETTE'].Detail = 'not checked because the queue driver is not the Canon PS driver'
            $status['FINISHER'].Detail = 'not checked because the queue driver is not the Canon PS driver'
        }
        try {
            $config = Get-PrintConfiguration -PrinterName $script:PrinterName
            $mode = ''
            if ($config -and $null -ne $config.DuplexingMode) { $mode = [string]$config.DuplexingMode }
            if ($mode -eq 'OneSided') {
                $status['SIDES'].State = 'PASS'
                $status['SIDES'].Detail = 'DuplexingMode OneSided (1-sided Printing)'
            } else {
                $status['SIDES'].Detail = ("DuplexingMode expected OneSided, found " + $(if ($mode) { $mode } else { 'blank' }))
            }
        } catch {
            $status['SIDES'].Detail = ("Get-PrintConfiguration failed: " + $_.Exception.Message)
        }
        if ($status['DRIVER'].State -eq 'PASS') {
            $hardware = Read-HardwareFromTicket
            $status['CASSETTE'].State = $hardware.CassetteState
            $status['CASSETTE'].Detail = $hardware.CassetteDetail
            $status['FINISHER'].State = $hardware.FinisherState
            $status['FINISHER'].Detail = $hardware.FinisherDetail
            $status['ENTER NAME'].State = 'MANUAL'
            $status['ENTER NAME'].Detail = Get-EnterNameDetail ''
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
    if ($status['QUEUE'].State -eq 'PASS' -and $status['DRIVER'].State -eq 'PASS') {
        $ui = Invoke-CanonDeviceAutomation -PrintUser $user -Action 'read'
        Apply-DeviceUiResult -Status $status -Ui $ui -PrintUser $user
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
        $status['DRIVER'].Detail = 'Canon iR-ADV C5235/5240 PS (or Canon Generic Plus PS3) is not installed'
        $status['QUEUE'].Detail = ($script:PrinterName + ' was not created')
        $status['URI'].Detail = ('port not created; expected ' + $target.Uri)
        $code = Write-StatusReport -Kind 'install' -Verify $false -Status $status -PrintUser $printUser -Target $target
        Copy-RemaxLog -Result 'FAIL' -PrintUser $printUser -Target $target
        return $code
    }
    $driverName = [string]$selected.Name
    Write-Remax ("Using driver " + $driverName)
    try {
        Ensure-LprPort $target | Out-Null
        Ensure-PrinterQueue -DriverName $driverName -Target $target
    } catch {
        Write-Remax ("Queue setup failed: " + $_.Exception.Message)
        $status = Get-QueueStatus $target
        if ($status['QUEUE'].State -ne 'PASS') {
            $status['QUEUE'].Detail = ("setup failed: " + $_.Exception.Message)
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
    if ($status['DRIVER'].State -eq 'PASS' -and $status['CASSETTE'].State -ne 'PASS') {
        $status['CASSETTE'].State = 'MANUAL'
        if ($hardware.CassetteState -eq 'PASS') {
            $status['CASSETTE'].Detail = 'OptCas2 was written but did not remain on the default print ticket. Set Cassette Feeding Unit = On in Device Settings.'
        } else {
            $status['CASSETTE'].Detail = $hardware.CassetteDetail
        }
    }
    if ($status['DRIVER'].State -eq 'PASS' -and $status['FINISHER'].State -ne 'PASS') {
        $status['FINISHER'].State = 'MANUAL'
        if ($hardware.FinisherState -eq 'PASS') {
            $status['FINISHER'].Detail = 'IFINE1 was written but did not remain on the default print ticket. Set Output Options = Inner Finisher E1 in Device Settings.'
        } else {
            $status['FINISHER'].Detail = $hardware.FinisherDetail
        }
    }
    if ($duplexError -and $status['SIDES'].State -ne 'PASS') {
        $status['SIDES'].State = 'FAIL'
        $status['SIDES'].Detail = ("Set-PrintConfiguration OneSided failed: " + $duplexError)
    }
    if ($status['DRIVER'].State -eq 'PASS') {
        $ui = $null
        try {
            $ui = Invoke-CanonDeviceAutomation -PrintUser $printUser -Action 'apply'
        } catch {
            Write-Remax ("Device Settings automation failed: " + $_.Exception.Message)
            $ui = New-DeviceUiResult
            $ui.Attempted = $true
            $ui.CassetteDetail = $_.Exception.Message
            $ui.FinisherDetail = $_.Exception.Message
            $ui.EnterDetail = $_.Exception.Message
        }
        Apply-DeviceUiResult -Status $status -Ui $ui -PrintUser $printUser
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
            $status['SIDES'].Detail = 'DuplexingMode OneSided (1-sided Printing)'
        } elseif ($mode) {
            $status['SIDES'].State = 'FAIL'
            $status['SIDES'].Detail = ("DuplexingMode expected OneSided, found " + $mode)
        }
    }
    $states = @()
    foreach ($label in @('QUEUE', 'URI', 'DRIVER', 'CASSETTE', 'FINISHER', 'SIDES', 'ENTER NAME', 'STALE QUEUE')) {
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
    Assert-Remax ($target.ByteCount) 'LPR byte counting defaults on'
    $env:REMAX_PRINTER_URI = 'lpd://10.1.2.3/OtherQueue'
    $over = Resolve-PrinterTarget
    Assert-Remax ($over.Host -eq '10.1.2.3' -and $over.Queue -eq 'OtherQueue') 'REMAX_PRINTER_URI overrides host and queue'
    if ($null -eq $savedUri) {
        Remove-Item Env:REMAX_PRINTER_URI -ErrorAction SilentlyContinue
    } else {
        $env:REMAX_PRINTER_URI = $savedUri
    }
    if ($null -ne $savedHost) { $env:REMAX_PRINTER_HOST = $savedHost }
    if ($null -ne $savedQueue) { $env:REMAX_LPR_QUEUE = $savedQueue }
    if ($null -ne $savedByte) { $env:REMAX_LPR_BYTE_COUNT = $savedByte }
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
    Assert-Remax ($script:Version -eq '1.1.0') 'version string is 1.1.0'
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
    [void]$page.Add((New-FakeEl 'Cassette Feeding Unit' 'CheckBox' 420 70 180 18 '' 'Off'))
    [void]$page.Add((New-FakeEl 'Paper Deck Unit' 'CheckBox' 420 96 160 18 '' 'Off'))
    [void]$page.Add((New-FakeEl 'Output Options:' 'Text' 30 150 140 18 '' ''))
    [void]$page.Add((New-FakeEl '' 'ComboBox' 420 148 220 22 'None' ''))
    [void]$page.Add((New-FakeEl 'External Puncher:' 'Text' 30 210 140 18 '' ''))
    [void]$page.Add((New-FakeEl '' 'ComboBox' 420 208 220 22 'None' ''))
    [void]$page.Add((New-FakeEl 'PS Output from Application:' 'Text' 30 270 200 18 '' ''))
    [void]$page.Add((New-FakeEl '' 'ComboBox' 420 268 220 22 'Auto' ''))
    [void]$page.Add((New-FakeEl 'Use Department ID Management(J)' 'CheckBox' 30 320 260 18 '' 'Off'))
    [void]$page.Add((New-FakeEl 'Settings...' 'Button' 520 316 120 22 '' ''))
    [void]$page.Add((New-FakeEl 'Set User Information(L)' 'CheckBox' 30 352 220 18 '' 'On'))
    [void]$page.Add((New-FakeEl 'Settings(W)...' 'Button' 520 348 120 22 '' ''))
    $targets = Find-CanonDeviceTargets $page
    Assert-Remax ($targets.Cassette -and (Test-CanonLabelEquals $targets.Cassette.Name 'Cassette Feeding Unit')) 'cassette checkbox found'
    Assert-Remax ($targets.OutputCombo -and ($targets.OutputCombo.Top -eq 148)) 'output combo is the Output Options row'
    Assert-Remax ($targets.UserSettings -and ($targets.UserSettings.Name -eq 'Settings(W)...')) 'user information settings button'
    Assert-Remax ($null -eq $targets.Profile) 'screenshot page has no config profile combo'
    $namedCombos = New-Object System.Collections.Generic.List[object]
    [void]$namedCombos.Add((New-FakeEl 'Output Options:' 'ComboBox' 420 148 220 22 'None' ''))
    [void]$namedCombos.Add((New-FakeEl 'External Puncher:' 'ComboBox' 420 208 220 22 'None' ''))
    $namedPick = Find-CanonComboByLabel -Elements $namedCombos -Labels @('Output Options')
    Assert-Remax ($namedPick -and ($namedPick.Top -eq 148)) 'combo named Output Options is selected'
    $mode = Resolve-NameToSetLabel -Labels @('Logon name', 'Computer name', 'Enter name') -PrintUser 'tsiogase'
    Assert-Remax ($mode -eq 'Enter name') 'enter name wins over logon'
    $onlyLogon = Resolve-NameToSetLabel -Labels @('Logon name', 'User Account Name') -PrintUser 'tsiogase'
    Assert-Remax ($null -eq $onlyLogon) 'logon subtypes are not Enter Name'
    $unknownRadio = Resolve-NameToSetLabel -Labels @('Some other choice') -PrintUser 'tsiogase' -KnownOnly
    Assert-Remax ($null -eq $unknownRadio) 'unknown radio is not selected'
    $finisherPick = Resolve-FinisherLabel -Labels @('None', 'Inner Finisher E1', 'Staple Finisher')
    Assert-Remax ($finisherPick -eq 'Inner Finisher E1') 'finisher choice'
    $profilePick = Resolve-ProfileLabel -Labels @('Auto', 'Canon iR-ADV C5235/5240')
    Assert-Remax ($profilePick -eq 'Canon iR-ADV C5235/5240') 'profile choice'
    Assert-Remax (Test-EnterNameConfigured -UserField 'tsiogase' -NameToSet 'Enter name' -PrintUser 'tsiogase' -SawNameToSet $true) 'enter name readback passes'
    Assert-Remax (-not (Test-EnterNameConfigured -UserField 'tsiogase' -NameToSet 'Logon name' -PrintUser 'tsiogase' -SawNameToSet $true)) 'logon name readback fails'
    Assert-Remax (Test-EnterNameConfigured -UserField 'tsiogase' -NameToSet 'tsiogase' -PrintUser 'tsiogase' -SawNameToSet $true) 'username stored in name-to-set passes'
    Assert-Remax (-not (Test-EnterNameConfigured -UserField 'tsiogase' -NameToSet 'Enter name' -PrintUser 'tsiogase' -SawNameToSet $false)) 'missing name-to-set control fails'
    $keepTicket = Merge-DeviceLine -TicketState 'PASS' -TicketDetail 'ticket' -UiState 'MANUAL' -UiDetail 'ui' -Attempted $false
    Assert-Remax ($keepTicket.State -eq 'PASS' -and $keepTicket.Detail -eq 'ticket') 'ticket PASS stands when UI did not run'
    $uiWin = Merge-DeviceLine -TicketState 'MANUAL' -TicketDetail 'ticket' -UiState 'PASS' -UiDetail 'readback' -Attempted $true
    Assert-Remax ($uiWin.State -eq 'PASS' -and $uiWin.Detail -eq 'readback') 'UI readback PASS wins'
    $uiFail = Merge-DeviceLine -TicketState 'PASS' -TicketDetail 'ticket' -UiState 'FAIL' -UiDetail 'off' -Attempted $true
    Assert-Remax ($uiFail.State -eq 'FAIL' -and $uiFail.Detail -eq 'off') 'verified mismatch beats a print ticket'
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
