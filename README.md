# Remax Secure Printer

Terminal installer for the RE/MAX Escarpment Canon secure queue. Mac agents run one command in Terminal. Windows agents run `install-windows.ps1` from an elevated PowerShell window. There is no `.app` and nothing clicks the Canon utility.

After a successful install the queue matches all of these:

| Setting | Value |
| --- | --- |
| Queue | `RemaxSecure` |
| URI | `lpd://172.16.105.21/RemaxSecure` |
| Driver | Canon iR-ADV C5235/5240 PS (`CNMCIRAC5235S2`) |
| Cassette Feeding Unit | On (`*DefaultCNSrcOption: OptCas2`) |
| Output Options | Inner Finisher E1 (`*DefaultCNFinisher: IFINE1`) |
| Sides | One-sided (`*DefaultCNDuplex: None`, "1-sided Printing") |
| User Information | **Enter Name** = the print username |

Enter Name is stored in the queue PPD as Canon-native `*%INFO_PrPr` lines (colon, not `=`). The Canon CUPS PS Printer Utility reads that block. The installer does not automate the Utility.

## One-liner to email agents

Send agents this command:

```bash
curl -fsSL https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-mac.sh | sudo bash
```

Terminal asks for the Mac admin password, then asks for the print username (the name that should appear on the copier). Progress is printed in the window. The script ends with an **INSTALL REPORT**. Every required line must say `PASS`. If any line says `FAIL`, the script exits non-zero.

To set the username in the command and skip the prompt, put the variable on `sudo`. A normal `export` is dropped by `sudo`:

```bash
curl -fsSL https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-mac.sh | sudo REMAX_PRINT_USER='tsiogase' bash
```

`tsiogase` is the example from the October 2026 capture. Use the agent's own print username.

Review the script before running it, if you want to:

```bash
curl -fsSL https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-mac.sh -o /tmp/install-mac.sh
sudo REMAX_PRINT_USER='tsiogase' bash /tmp/install-mac.sh
```

Do not use `sudo bash <(curl …)`. The process substitution is opened by your user, and root often cannot read it. The pipe into `sudo bash` is the command to send.

## What the agent should see in the Utility

1. Run the one-liner and wait for `RESULT: PASS`.
2. Open **Canon CUPS PS Printer Utility**.
3. Select **RemaxSecure**.
4. Open **User Information**.

**Enter Name** should be selected, and the name should be the username they typed. Quit the Utility with Command-Q and open it again if it was already running when the installer finished; it will re-read the queue PPD.

No AppleScript or clicking is involved. If the Utility shows **Log-in name** instead of **Enter Name**, the PPD is wrong (`name_set_index` 2). Run `verify-mac.sh` below. A passing Enter Name check means the PPD has `name_set_index` 1 in the colon-form block the utility actually reads.

## Check a Mac without changing it

IT, from the agent Mac:

```bash
curl -fsSL https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/verify-mac.sh | bash
```

If the PPD is not readable:

```bash
curl -fsSL https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/verify-mac.sh | sudo bash
```

To require a specific print username:

```bash
curl -fsSL https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/verify-mac.sh | sudo REMAX_PRINT_USER='tsiogase' bash
```

The report is titled **VERIFY REPORT** and the first line is `No changes made.`

## Publish this on GitHub (raw.githubusercontent.com)

Agents do not clone the repo. `curl` fetches one file, so the repository has to be reachable without a login.

The public repository is [ItsErod/canon-secure-print](https://github.com/ItsErod/canon-secure-print). It must stay **public**. Private raw URLs need a token, agents will not have one, and the one-liner will fail with a 404.

1. Default branch is `main`. The one-liner points at `/main/`.
2. `install-mac.sh`, `verify-mac.sh`, `install-windows.ps1`, `verify-windows.ps1`, and `README.md` must be on that branch. `lib/canon_ppd.pl` is the same Perl helper already embedded inside the two Mac scripts, so a lone `curl` of `install-mac.sh` still runs. The Windows one-liner downloads `install-windows.ps1` by itself.
3. In a browser, open `https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-mac.sh`. You should see the script, starting with `#!/bin/bash`, not a GitHub HTML page and not a 404.
4. Optional: pin a commit so a later push cannot change what agents run. Use the full commit SHA in place of `main`:

```bash
curl -fsSL https://raw.githubusercontent.com/ItsErod/canon-secure-print/COMMIT_SHA/install-mac.sh | sudo bash
```

Before you push, on any machine with bash, Perl (macOS includes it), and Python 3:

```bash
bash tests/simulate-install.sh
```

That fakes `lpadmin` and checks the PPD bytes. It does **not** replace one install on a Mac that already has the Canon C5235/5240 PS driver. Do that once and confirm the Utility shows Enter Name.

On a Mac, this checks the encoder without touching printers:

```bash
bash install-mac.sh --self-test
```

## If the Canon driver is not installed

The usual fleet Mac already has the driver. The installer looks for:

```text
/Library/Printers/PPDs/Contents/Resources/CNMCIRAC5235S2.ppd.gz
```

or the same file without `.gz`. If NickName and ModelName both contain `C5235` and `5240`, it uses that PPD and does not install a package. A "Japanese Paper" media type inside the PPD is normal and is not treated as the wrong driver.

If the file is missing, the script prints where it should be and exits. It does not download Canon software unless you set a URL:

```bash
curl -fsSL https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-mac.sh | sudo \
  REMAX_CANON_PKG_URL='https://your-host.example/Canon-iR-ADV-C5235-PS.pkg' \
  REMAX_PRINT_USER='tsiogase' bash
```

The URL may be a flat `.pkg`, a `.dmg` that contains a `.pkg`, or a `.zip` that contains a `.pkg`. There is no URL built into the script.

## Logs

| Path | What |
| --- | --- |
| `/tmp/RemaxSecurePrinterSetup-mac.log` | Full log of the last install |
| `/Library/Application Support/RemaxSecurePrinter/` | Copy of that log, plus `last-install.txt` |
| `/tmp/RemaxSecurePrinterVerify-mac.log` | Last read-only verify |

## Gatekeeper

Not applicable. This is a shell script, not an application bundle. There is nothing to notarize and no `com.apple.quarantine` app for the agent to right-click. Piping `curl` into `bash` does not create a `.app`. Do not wrap this in an app.

## Running it again

The installer is safe to re-run. It updates `RemaxSecure` in place with `lpadmin -P` (it does not hand-edit `/etc/cups/ppd` and it does not `kickstart` CUPS). It deletes a leftover queue named `RemaxSecure_COLOUR` when that queue exists. Each run starts from the Canon driver PPD and reapplies cassette, finisher, one-sided, and Enter Name, so other options you changed in the UI go back to the driver defaults.

## How Enter Name is written

The utility reads only the colon lines near the top of the PPD, immediately after `*PPD-Adobe`:

```text
*%INFO_PrPr1: <base64>
*%INFO_PrPr2: <base64>
*%INFO_PrPr3: END_<uncompressed byte length>
```

The payload is UTF-8 XML, zlib-compressed, then standard base64 in 200-character chunks. Canon encoding of a name is the bitwise NOT of each UTF-8 byte, then base64:

| Text | Encoded |
| --- | --- |
| `tsiogase` | `i4yWkJiejJo=` |
| `erod` | `mo2Qmw==` |
| `0` | `zw==` |

`user_name` is the print username. `owner` is the console Mac user (the person logged in on the desktop, not root). `name_set_index` is `1`, which is Enter Name. The captured October 2026 block for `tsiogase` / `erod` is reproduced byte for byte, including `END_598`.

Any older `*%INFO_PrPr` block that uses `=` is removed. That form is not what the utility reads. Preference XML under `~/Library/Application Support/Canon` is left alone for the same reason.

## Troubleshooting

**The report says the driver is missing.** Install the Canon iR-ADV C5235/5240 PS package that is already on the rest of the fleet, or set `REMAX_CANON_PKG_URL`. Then run the one-liner again.

**`sudo` did not see `REMAX_PRINT_USER`.** Write `sudo REMAX_PRINT_USER='name' bash`, not `REMAX_PRINT_USER='name' sudo bash`.

**Enter Name is blank or shows Log-in name.** Run `verify-mac.sh`. If Enter Name is `FAIL`, run the installer again. If it is `PASS`, quit the Utility with Command-Q and reopen it.

**The username was wrong.** Run the installer again with the right `REMAX_PRINT_USER`. That replaces the PPD block.

**The Mac is not on the office network.** The queue can still be installed. Jobs will not reach `172.16.105.21` until the Mac can route to that address.

**Could not detect the console user.** Log in on the desktop first. The owner field is that account. For a rare SSH install where the GUI user is known, add `REMAX_CONSOLE_USER='shortname'` next to `REMAX_PRINT_USER` on the `sudo` command.

**Installer says it must run as an administrator.** The pipe has to be `curl … | sudo bash`.

## Windows

Windows installer **1.0.0**. It creates the same queue name and LPR target as the Mac script. Open **Windows PowerShell** with **Run as administrator**. Set `REMAX_PRINT_USER` in that elevated window. A variable set in a normal window is dropped when User Account Control starts the elevated one.

```powershell
Set-ExecutionPolicy -Scope Process Bypass
$env:REMAX_PRINT_USER = 'tsiogase'
$s = Join-Path $env:TEMP 'remax-install-windows.ps1'
Invoke-RestMethod https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-windows.ps1 -OutFile $s
& $s
```

Shorter form in the same elevated window. `irm` is `Invoke-RestMethod`. `iex` is `Invoke-Expression`. Execution policy does not apply to `iex`. On a failure the script throws instead of closing the window, and the report is already on screen:

```powershell
$env:REMAX_PRINT_USER = 'tsiogase'
irm https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-windows.ps1 | iex
```

`tsiogase` is the example from the October 2026 capture. Use the agent's own print username. The script prompts when `REMAX_PRINT_USER` is unset and a console is attached. It does not substitute the Windows logon name.

Read-only check, from the repo or from the downloaded file:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\verify-windows.ps1
```

```powershell
$s = Join-Path $env:TEMP 'remax-install-windows.ps1'
Invoke-RestMethod https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-windows.ps1 -OutFile $s
powershell -NoProfile -ExecutionPolicy Bypass -File $s -Verify
```

The Windows port is a Standard TCP/IP port named `RemaxSecure_LPR`, protocol LPR, TCP port 515, queue name `RemaxSecure`, host `172.16.105.21`. That is `lpd://172.16.105.21/RemaxSecure`. It does not need the optional LPR Port Monitor feature. LPR byte counting is on unless `REMAX_LPR_BYTE_COUNT` is `0`. Re-running the script updates `RemaxSecure` in place and removes a leftover queue named `RemaxSecure_COLOUR`.

| Check | What the script can do |
| --- | --- |
| Queue, LPR port, driver | `Add-Printer` / `Add-PrinterPort`. Driver name must be Canon iR-ADV C5235/5240 PS or PS3. `Canon Generic Plus PS3` is accepted, and Device Settings **Config. Profile** must then be `iR-ADV C5235/5240`. UFR II and PCL are not used. |
| One-sided | `Set-PrintConfiguration -DuplexingMode OneSided` |
| Cassette Feeding Unit, Inner Finisher E1 | Set only when that driver publishes print-ticket options `OptCas2` and `IFINE1`. Otherwise the line is `MANUAL`. |
| Enter Name | `MANUAL`. The Windows Canon PS driver does not read the Mac `*%INFO_PrPr` block, and there is no documented PrintManagement field for it. |

`RESULT: PASS` and exit code 0 mean every line passed. `RESULT: PARTIAL` and exit code 2 mean the queue is installed and the `MANUAL` lines are still Canon **Printer properties → Device Settings**. That is the expected first run on the fleet driver. Exit code 1 means the queue, port, or driver did not install.

When the report says `MANUAL`, on the agent PC:

1. **Printer properties** for **RemaxSecure**, **Device Settings**.
2. If the driver is **Canon Generic Plus PS3**, set **Config. Profile** to **iR-ADV C5235/5240**.
3. **Cassette Feeding Unit** = On.
4. **Output Options** = **Inner Finisher E1**.
5. **Set User Information** → **Settings** → **User Name** = the print username.
6. **Default Value Settings** → **Name to Set for User Name** = that entered name. Canon documents this separately from the Windows logon name.
7. Close Printer properties and open them again if they were already open.

The script does not click the Canon utility. Do not treat a successful-looking Windows print dialog as proof that Enter Name is set. Read the **INSTALL REPORT**.

If the Canon PS driver is missing, the report names what to install and lists the drivers already on the PC. Optional download, only when you host the package:

```powershell
$env:REMAX_CANON_PKG_URL = 'https://your-host.example/Canon-PS-driver.zip'
$env:REMAX_PRINT_USER = 'tsiogase'
irm https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-windows.ps1 | iex
```

The URL must be https and end in `.zip`, `.cab`, or `.inf` (a zip of the extracted Driver folder). A Canon setup `.exe` is not launched. If 7-Zip is installed, an `.exe` URL is unpacked and the INF inside is added with `pnputil`. There is no Canon URL built into the script. The Mac file `CNMCIRAC5235S2.ppd.gz` is not a Windows driver.

Logs:

| Path | What |
| --- | --- |
| `%TEMP%\RemaxSecurePrinterSetup-windows.log` | Full log of the last install |
| `%TEMP%\RemaxSecurePrinterVerify-windows.log` | Last read-only verify |
| `C:\ProgramData\RemaxSecurePrinter\` | Copy of the log, `last-install.txt`, and `requested-print-user.txt` |

### Re-test on a Windows agent PC

Ethan, after this is on `main`:

1. On a Windows agent PC that can route to `172.16.105.21`, open elevated PowerShell.
2. Run the one-liner above with that agent's `REMAX_PRINT_USER`.
3. Expect **RESULT: PARTIAL**, exit code 2, and **PASS** on QUEUE, URI, DRIVER, SIDES, and STALE QUEUE when the Canon PS driver is already installed. CASSETTE, FINISHER, and ENTER NAME stay **MANUAL** unless the driver keeps `OptCas2` and `IFINE1` on the print ticket.
4. Do the Device Settings steps in the report. Print one secure job only if you want to confirm the copier shows that Enter Name.
5. Run `-Verify`. It does not change the queue.
6. Run the installer a second time. It must update `RemaxSecure` and not create a second queue.
7. Logic only, no printers: `powershell -NoProfile -ExecutionPolicy Bypass -File .\install-windows.ps1 -SelfTest`

On a machine with Python 3, before pushing:

```bash
python3 tests/check-windows-installer.py
bash tests/simulate-install.sh
```

`check-windows-installer.py` does not run PowerShell. The self-test and one real Windows PC are the checks that execute the script.

## Layout

| File | Role |
| --- | --- |
| `install-mac.sh` | Installer Mac agents run |
| `verify-mac.sh` | Read-only check for a Mac |
| `lib/canon_ppd.pl` | Encoder and PPD patcher (also embedded in the two Mac scripts) |
| `install-windows.ps1` | Windows installer 1.0.0 (`-Verify`, `-SelfTest`) |
| `verify-windows.ps1` | Read-only Windows check (calls `install-windows.ps1 -Verify`) |
| `tests/simulate-install.sh` | Fake-CUPS test of the Mac install and verify flow |
| `tests/check-windows-installer.py` | Static check of the Windows script and README one-liners |
