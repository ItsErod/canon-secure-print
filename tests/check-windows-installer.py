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
        "1.0.0",
        "RemaxSecure",
        "RemaxSecure_COLOUR",
        "RemaxSecure_LPR",
        "lpd://172.16.105.21/RemaxSecure",
        "172.16.105.21",
        "Win32_TCPIPPrinterPort",
        "Add-PrinterPort",
        "-LprHostAddress",
        "-LprQueueName",
        "OneSided",
        "Set-PrintConfiguration",
        "OptCas2",
        "IFINE1",
        "Cassette Feeding Unit",
        "Inner Finisher E1",
        "Set User Information",
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
        "-SelfTest",
        "-Verify",
        "https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-windows.ps1",
    ]
    for token in required:
        if token not in installer:
            fail(f"install-windows.ps1 is missing {token}")
    forbidden = [
        "Set-ItemProperty",
        "New-ItemProperty",
        "reg.exe",
        "HKCU:\\Software\\Canon",
        "HKLM:\\SOFTWARE\\Canon",
        "PrinterDriverData",
    ]
    for token in forbidden:
        if token in installer:
            fail(f"install-windows.ps1 contains unsupported store write {token}")
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
    print("check-windows-installer: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
