#!/usr/bin/env python3
"""Static checks for install-windows.ps1.

PowerShell is not required. This does not replace a Windows smoke test.
"""

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "install-windows.ps1"
VERIFY = ROOT / "verify-windows.ps1"
README = ROOT / "README.md"


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def strip_powershell(text: str) -> str:
    """Return text with strings and comments replaced by spaces.

    Balance checks then see braces without counting them inside messages.
    """
    out = []
    i = 0
    n = len(text)
    while i < n:
        if text.startswith("<#", i):
            end = text.find("#>", i + 2)
            if end < 0:
                fail("unclosed <# comment #>")
            out.append(" " * (end + 2 - i))
            i = end + 2
            continue
        if text.startswith("@'", i) or text.startswith('@"', i):
            quote = text[i + 1]
            line_end = text.find("\n", i)
            if line_end < 0:
                fail("unclosed here-string")
            end = text.find("\n" + quote + "@", line_end)
            if end < 0:
                fail("unclosed here-string")
            out.append(" " * (end + 3 - i))
            i = end + 3
            continue
        ch = text[i]
        if ch == "#":
            end = text.find("\n", i)
            if end < 0:
                end = n
            out.append(" " * (end - i))
            i = end
            continue
        if ch in ("'", '"'):
            j = i + 1
            while j < n:
                if text[j] == ch:
                    if ch == "'" and j + 1 < n and text[j + 1] == "'":
                        j += 2
                        continue
                    if ch == '"' and text[j - 1] == "`":
                        j += 1
                        continue
                    break
                j += 1
            if j >= n:
                fail(f"unclosed string starting at index {i}")
            out.append(" " * (j + 1 - i))
            i = j + 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def check_balance(text: str) -> None:
    stripped = strip_powershell(text)
    pairs = {")": "(", "]": "[", "}": "{"}
    stack = []
    line = 1
    for ch in stripped:
        if ch == "\n":
            line += 1
            continue
        if ch in "([{":
            stack.append((ch, line))
        elif ch in ")]}":
            if not stack or stack[-1][0] != pairs[ch]:
                fail(f"unbalanced {ch} near line {line}")
            stack.pop()
    if stack:
        ch, opened = stack[-1]
        fail(f"unclosed {ch} from line {opened}")


def main() -> int:
    installer = INSTALLER.read_text(encoding="utf-8")
    verify = VERIFY.read_text(encoding="utf-8")
    readme = README.read_text(encoding="utf-8")
    if any(ord(ch) > 127 for ch in installer):
        fail("install-windows.ps1 must stay ASCII so Windows PowerShell 5.1 parses it")
    if any(ord(ch) > 127 for ch in verify):
        fail("verify-windows.ps1 must stay ASCII")
    check_balance(installer)
    check_balance(verify)
    required = [
        "1.2.13",
        "application/vnd.github.sha",
        "Cache-Control",
        "REMAX_INGEST_KEY",
        "REMAX_NO_REPORT",
        "printer-installs",
        "EncodedCommand",
        "RemaxWin1210",
        "Find-TitledWindow",
        "ApplyDevMode",
        "TypeUnicode",
        "NotifyEditChange",
        "SendMessageTimeout",
        "Select-UiaTab",
        "UIAutomationTypes",
        "GetLastWin32Error",
        "Default DevMode",
        "not on REMAX network",
        "User Information Settings",
        "tsiogase",
        "remaxsecure-device-settings.dat",
        "a206124cad61263c4843a560765a389da3cb2d3ddb70011abbbbf54499f96279",
        "44692",
        "source: dat",
        "Start-Process",
        "REMAX_PS_OUTPUT",
        "REMAX_NO_INPUT_LOCK",
        "Write-Progress",
        "BlockInput",
        "INPUT LOCK",
        "Ctrl+Alt+Delete",
        "ComboFindExact",
        "NotifySelChange",
        "REMAX_SKIP_CLEANUP",
        "REMAX_SKIP_FIREWALL",
        "Get-WritablePortPropertyNames",
        "Bitdefender",
        "spoolsv.exe",
        "721-731",
        "ConvertTo-ExitCode",
        "Test-PnputilSuccess",
        "Get-PnputilPublishedName",
        "printui.exe",
        "Get-DownloadFileName",
        "Expand-RemaxZip",
        "Resolve-PackageKind",
        "https://github.com/ItsErod/canon-secure-print/releases/download/driver-v30/Canon-PS3-v30.00-x64.zip",
        "4db0d69d0b6417c39ed285698f9dc23dc5a90c6e3372c8f04da68b1d19b678da",
        "CNS30UA64.INF",
        "UseBasicParsing",
        "Tls12",
        "MaximumRedirection",
        "LASTEXITCODE",
        "Get-IexFinishMessage",
        "PrintUIEntry",
        "UIAutomationClient",
        "REMAX_DEVICE_DAT",
        "REMAX_DEVICE_UI",
        "Default Value Settings",
        "Name to Set for User Information",
        "Paper Source Options",
        "Find-CanonDeviceTargets",
        "Invoke-CanonDeviceAutomation",
        "Get-PrinterProperty",
        "Set-PrinterProperty",
        "PrinterDriverData",
        "Read-PrintUserPrompt",
        "last name + first initial",
        "for example tsiogase",
        "RemaxSecure",
        "RemaxSecure_COLOUR",
        "RemaxSecure_LPR",
        "lpd://172.16.105.21/RemaxSecure",
        "172.16.105.21",
        "Win32_TCPIPPrinterPort",
        "Add-PrinterPort",
        "-LprHostAddress",
        "-LprQueueName",
        "-LprByteCounting",
        "SNMP Enabled",
        "Byte Count",
        "OneSided",
        "Set-PrintConfiguration",
        "OptCas2",
        "IFINE1",
        "Cassette Feeding Unit",
        "Inner Finisher E1",
        "Set User Information",
        "Settings...",
        "Get Device Information",
        "Canon iR-ADV C5235/5240 PS3",
        "30.0.0.1",
        "30.00",
        "Canon Driver Information Assist Service",
        "not shared",
        "REMAX_PRINT_USER",
        "REMAX_CANON_PKG_URL",
        "REMAX_PRINTER_URI",
        "Canon Generic Plus PS3",
        "CNMCIRAC5235S2",
        "pnputil.exe",
        "INSTALL REPORT",
        "VERIFY REPORT",
        "MANUAL",
        "PARTIAL",
        "RESULT:",
        "-SelfTest",
        "-Verify",
        "https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-windows.ps1",
    ]
    for token in required:
        if token not in installer:
            fail(f"install-windows.ps1 is missing {token}")
    if "reg.exe" in installer:
        fail("install-windows.ps1 contains unsupported store write reg.exe")
    search_fn = installer.split("function Search-RegistryTreeForUserName", 1)[1].split("function Write-UserNameRegistryHits", 1)[0]
    if "SetValue" in search_fn or "Set-ItemProperty" in search_fn or "New-ItemProperty" in search_fn:
        fail("the wider Canon user-name search must only read")
    if "Set-ItemProperty" in installer:
        fail("Set-ItemProperty is not used. Port monitor values use New-ItemProperty in Set-PortRegistry.")
    name_fn = installer.split("function Write-UserNameRegistryHits", 1)[1].split("function ", 1)[0]
    if "SetValue" not in name_fn:
        fail("Write-UserNameRegistryHits must write the typed username over tsiogase")
    port_fn = installer.split("function Set-PortRegistry", 1)[1].split("function ", 1)[0]
    if port_fn.count("New-ItemProperty") != 7:
        fail("Set-PortRegistry must be the only writer, with seven New-ItemProperty calls")
    if installer.count("New-ItemProperty") != 7:
        fail("New-ItemProperty is only allowed for the Standard TCP/IP port monitor")
    if ".HostAddress =" in installer or "HostAddress =" in installer:
        fail("HostAddress is read-only and must not be assigned")
    for token in ("HostName", "IPAddress", "SNMP Enabled", "Byte Count"):
        if token not in port_fn:
            fail(f"Set-PortRegistry is missing {token}")
    for line in installer.splitlines():
        if "PrinterDriverData" in line and (
            "New-ItemProperty" in line or "Set-ItemProperty" in line or "SetValue" in line
        ):
            fail("PrinterDriverData is inventoried by name and must not be written")
    if "\u2014" in installer or "\u2014" in readme or "\u2014" in verify:
        fail("em dash is not allowed")
    if "&&" in installer or "||" in installer:
        fail("install-windows.ps1 uses && or ||, which Windows PowerShell 5.1 will not run")
    if not installer.startswith("#Requires -Version 5.1\n"):
        fail("install-windows.ps1 must start with #Requires -Version 5.1")
    if "param(" in installer.split("function", 1)[0]:
        fail("script-level param() breaks irm | iex")
    if "install-windows.ps1" not in verify or "-Verify" not in verify:
        fail("verify-windows.ps1 must delegate to install-windows.ps1 -Verify")
    raw = "https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-windows.ps1"
    if raw not in readme:
        fail("README is missing the Windows raw installer URL")
    if "irm " not in readme and "Invoke-RestMethod" not in readme:
        fail("README is missing a Windows download one-liner")
    mac = "curl -fsSL https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-mac.sh | sudo bash"
    if mac not in readme:
        fail("README lost the Mac one-liner")
    if "REMAX_PRINT_USER='tsiogase' bash" not in readme:
        fail("README lost the Mac REMAX_PRINT_USER one-liner")
    bare = "irm https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-windows.ps1 | iex"
    if bare not in readme:
        fail("README is missing the prompt-style Windows one-liner")
    complete = installer.split("function Invoke-Complete", 1)[1].split("function ", 1)[0]
    if "throw " in complete:
        fail("Invoke-Complete must not throw when the script is run with irm | iex")
    if "LASTEXITCODE" not in complete:
        fail("Invoke-Complete must set LASTEXITCODE")
    if "Get-IexFinishMessage" not in complete:
        fail("Invoke-Complete must print the non-throwing finish message")
    release = "https://github.com/ItsErod/canon-secure-print/releases/download/driver-v30/Canon-PS3-v30.00-x64.zip"
    if release not in readme:
        fail("README is missing the built-in Canon driver release URL")
    if "4db0d69d0b6417c39ed285698f9dc23dc5a90c6e3372c8f04da68b1d19b678da" not in readme:
        fail("README is missing the Canon driver SHA256")
    print("check-windows-installer: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
