# Remax Secure Printer

Terminal installer for the RE/MAX Escarpment Canon secure queue. Mac agents run one command in Terminal. Windows agents run one command in an elevated PowerShell window, type their print username, and the queue is installed. There is no `.app`. The Mac installer does not click the Canon utility. The Windows installer sets the recorded Device Settings, using printer properties when the driver exposes them and Printer properties UI Automation when it does not.

After a successful Mac install the queue matches all of these:

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

If `CNMCIRAC5235S2.ppd.gz` is already on the Mac, the command does not download a driver. If it is missing, the same command installs the Canon iR-ADV C5235/5240 PS package, checks that the PPD appeared, then creates `RemaxSecure`.

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

### Re-test the one-liner

On a Mac that already has the driver, run:

```bash
curl -fsSL https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-mac.sh | sudo REMAX_PRINT_USER='tsiogase' bash
```

The log should say the Canon driver is already installed. It should not download a package. The report should be `RESULT: PASS`.

On a Mac without `CNMCIRAC5235S2.ppd.gz`, run the same command (installer 1.1.0 or later). The log should say the driver is not installed, download the Canon zip, install `Canon_PS_Installer.pkg`, re-check `CNMCIRAC5235S2.ppd.gz`, then create `RemaxSecure` and end with `RESULT: PASS`.

Until this version is on `main`, replace `main` with the commit SHA. The publish section above explains that pin.

Without a Mac:

```bash
bash tests/simulate-install.sh
```

That covers the missing-driver path with a fake package in the same zip → disk image → nested disk image → `Canon_PS_Installer.pkg` shape. It does not download from Canon.

## If the Canon driver is not installed

The usual fleet Mac already has the driver. The installer looks for:

```text
/Library/Printers/PPDs/Contents/Resources/CNMCIRAC5235S2.ppd.gz
```

or the same file without `.gz`. If that file is present and NickName and ModelName both contain `C5235` and `5240`, the script uses it and does not download anything. A "Japanese Paper" media type inside the PPD is normal and is not treated as the wrong driver.

If the file is missing, the same one-liner downloads and installs the Canon PS driver, checks that `CNMCIRAC5235S2.ppd.gz` (or `.ppd`) is now on disk, then creates `RemaxSecure`.

Default package (override with `REMAX_CANON_PKG_URL`):

```text
https://downloads.canon.com/sss2025/drivers/PS_v4.17.22_mac.zip
```

That zip contains `PS_v4.17.22_mac.dmg`, which contains `mac-ps-v41722-00.dmg`, which contains `Canon_PS_Installer.pkg` (Canon iR-ADV C5235/5240 PS, model `CNMCIRAC5235S2`). The script runs `installer -pkg … -target /` as root. A flat `.pkg`, a `.dmg` that contains a `.pkg`, or a `.zip` that contains either, are all accepted. When several packages are present, a PS package is chosen over a UFR package. `REMAX_CANON_PKG_URL` replaces the default for one run. Export `CANON_PKG_URL_DEFAULT` (or edit that assignment in `install-mac.sh`) to change the built-in URL. The Canon package is not stored in this repo.

```bash
curl -fsSL https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-mac.sh | sudo \
  REMAX_CANON_PKG_URL='https://your-host.example/Canon-iR-ADV-C5235-PS.pkg' \
  REMAX_PRINT_USER='tsiogase' bash
```

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

**The report says the driver is missing.** The installer tried the Canon iR-ADV C5235/5240 PS package (`Canon_PS_Installer.pkg` from `PS_v4.17.22_mac.zip`) and `CNMCIRAC5235S2.ppd.gz` is still absent. Read the log for the download or `installer` error. Point `REMAX_CANON_PKG_URL` at another `.pkg`, `.dmg`, or `.zip` and run the one-liner again.

**`sudo` did not see `REMAX_PRINT_USER`.** Write `sudo REMAX_PRINT_USER='name' bash`, not `REMAX_PRINT_USER='name' sudo bash`.

**Enter Name is blank or shows Log-in name.** Run `verify-mac.sh`. If Enter Name is `FAIL`, run the installer again. If it is `PASS`, quit the Utility with Command-Q and reopen it.

**The username was wrong.** Run the installer again with the right `REMAX_PRINT_USER`. That replaces the PPD block.

**The Mac is not on the office network.** The queue can still be installed. Jobs will not reach `172.16.105.21` until the Mac can route to that address.

**Could not detect the console user.** Log in on the desktop first. The owner field is that account. For a rare SSH install where the GUI user is known, add `REMAX_CONSOLE_USER='shortname'` next to `REMAX_PRINT_USER` on the `sudo` command.

**Installer says it must run as an administrator.** The pipe has to be `curl … | sudo bash`.

## Windows

Windows installer **1.2.5**. It follows the recorded Windows 11 setup: Canon PS3 driver 30.00, a Standard TCP/IP port named after the printer host, queue `RemaxSecure` (not shared, not the default), 1-sided printing, and the Device Settings below. Open **Windows PowerShell** (the 64-bit one) with **Run as administrator** and run:

```powershell
irm https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-windows.ps1 | iex
```

`irm` is `Invoke-RestMethod`. `iex` is `Invoke-Expression`. Execution policy does not apply to `iex`. The window asks for the print username. The format is last name + first initial, lowercase, for example `tsiogase` (the name on the copier, not the Windows logon). Leave the Printer properties window alone while it is open. The script closes it. The report is **INSTALL REPORT**.

To skip the prompt, set the name in that same elevated window. A variable set in a normal window is dropped when User Account Control starts the elevated one:

```powershell
$env:REMAX_PRINT_USER = 'tsiogase'
irm https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-windows.ps1 | iex
```

`tsiogase` is the example from the October 2026 capture. Use the agent's own print username. The script does not substitute the Windows logon name.

Review the file before running it, if you want to:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
$s = Join-Path $env:TEMP 'remax-install-windows.ps1'
Invoke-RestMethod https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-windows.ps1 -OutFile $s
& $s
```

Read-only check, from the repo or from the downloaded file:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\verify-windows.ps1
```

```powershell
$s = Join-Path $env:TEMP 'remax-install-windows.ps1'
Invoke-RestMethod https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-windows.ps1 -OutFile $s
powershell -NoProfile -ExecutionPolicy Bypass -File $s -Verify
```

Every install starts with a clean slate unless `REMAX_SKIP_CLEANUP=1`. It removes queues named `RemaxSecure`, `RemaxSecure_COLOUR`, and `RemaxSecure_LPR`, plus any other queue on port `172.16.105.21` or `RemaxSecure_LPR`, then those ports, then the driver `Canon iR-ADV C5235/5240 PS3` when no remaining queue uses it. A locked port is retried after a Print Spooler restart, and the Standard TCP/IP port registry key is removed only if `Remove-PrinterPort` still fails. Cleanup never stops the run. The report line is `CLEANUP` `PASS` or `PARTIAL`.

The Windows port is a Standard TCP/IP port named `172.16.105.21` (the host address), protocol LPR, TCP port 515, queue name `RemaxSecure`, LPR byte counting on, SNMP off. `Add-PrinterPort` creates it with `-LprHostAddress`, `-LprQueueName`, and `-LprByteCounting`. `HostAddress` is not written afterwards, because that CIM property is read-only. SNMP, queue, protocol, and byte counting are written as writable CIM properties and as registry values `Protocol`, `Queue`, `Byte Count`, `SNMP Enabled`, `HostName`, `IPAddress`, and `PortNumber`. If the existing port still does not match, and no queue is using it, the script removes it and creates it again. A port tweak that still does not match is `PORT` `MANUAL` and the queue install continues. The `DRIVER` line is the installed Canon driver even when the queue was not created. That is `lpd://172.16.105.21/RemaxSecure`. It does not need the optional LPR Port Monitor feature. The recorded check is `Add-PrinterPort -Name 172.16.105.21 -LprHostAddress 172.16.105.21 -LprQueueName RemaxSecure -LprByteCounting`, then SNMP disabled. Readback uses `Get-PrinterPort` and the port monitor key `HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\Standard TCP/IP Port\Ports\172.16.105.21` (`Protocol=2`, `Queue=RemaxSecure`, `Byte Count=1`, `SNMP Enabled=0`). Installer 1.1.0 used a port named `RemaxSecure_LPR`. Re-running this installer moves `RemaxSecure` onto the host-named port and removes `RemaxSecure_LPR` when no other queue uses it. LPR byte counting stays on unless `REMAX_LPR_BYTE_COUNT` is `0`. Re-running the script updates `RemaxSecure` in place, leaves it not shared and not the default, and removes a leftover queue named `RemaxSecure_COLOUR`.

After the port exists, the script reads Security Center antivirus and firewall products (`displayName` and `productState`) and whether each Windows Defender Firewall profile is enabled. Unless `REMAX_SKIP_FIREWALL=1`, it removes and re-adds one outbound Windows Firewall rule named `RemaxSecure Print (spoolsv)`: program `%SystemRoot%\System32\spoolsv.exe`, TCP, remote address `172.16.105.21`, remote port `515`, local ports `721-731`, all profiles. It does not enable File and Printer Sharing and it does not allow every address. If Security Center or the services `VSSERV`, `bdservicehost`, or `EPSecurityService` show Bitdefender, the script does not change Bitdefender. `FIREWALL` is `MANUAL` and the log prints the steps: Protection, Firewall, Rules, allow `C:\Windows\System32\spoolsv.exe` to that printer, and set the office adapter to Home/Office (Trusted), not Public. `EPSecurityService` or the name Endpoint Security is called out as GravityZone, where the rule belongs in the GravityZone firewall policy. Any other third-party product is also `MANUAL`, naming that product. `FIREWALL` is `PASS` only when no third-party product is present and the Windows rule was added. `Test-NetConnection 172.16.105.21 -Port 515` is reported as `REACHABLE` `PASS` or `FAIL` and does not change the exit code. If that test fails while Bitdefender is present, the line says Bitdefender is the likely cause.

| Check | What the script can do |
| --- | --- |
| Driver | Name must be exactly `Canon iR-ADV C5235/5240 PS3`, the x64 build of Canon PS3 Printer Driver Ver. 30.00 (Setup.exe file version 30.0.0.1). `PASS` when that name is installed and any file version the spooler exposes is 30.0.0.1 or 30.00. A different Canon PS name can still create the queue, and the line stays `MANUAL`. UFR II and PCL are not used. Canon Driver Information Assist Service is not required. |
| Cleanup | Removes the old RemaxSecure queue, port, and Canon PS3 driver before install, unless `REMAX_SKIP_CLEANUP=1`. `PARTIAL` if a removal step fails. |
| Port | Standard TCP/IP port named `172.16.105.21`, LPR, queue `RemaxSecure`, byte counting on, SNMP off. A mismatch after the writable update is `MANUAL`. |
| Firewall | Windows Firewall rule for `spoolsv.exe` to `172.16.105.21:515`. Third-party products, including Bitdefender, stay `MANUAL`. |
| Reachable | `Test-NetConnection` to port 515. Informational. Does not change the exit code. |
| Printer | `RemaxSecure`, not shared, not the default. |
| 1-sided | `Set-PrintConfiguration -DuplexingMode OneSided` (1-sided Printing), including again after Device Settings. |
| Cassette Feeding Unit | Checkbox **Cassette Feeding Unit** under **Paper Source Options** (this driver's layout). A combo of the same name is also accepted. |
| Inner Finisher E1 | **Output Options** = **Inner Finisher E1**. |
| Set User Information | Checkbox **Set User Information** on. **Get Device Information** is left alone. |
| User Name | **Settings...** on that row opens **Default Value Settings**. Under **Name to Set for User Information:**, the **User Name** radio (not **Logon Name**) and the text box under it. **Always Confirm User Information When Performing Secured Print** stays checked. **Confirm User Name When Printing** stays unchecked. PIN stays blank. |

On this Canon PS3 driver, **Paper Source Options** is a group of checkboxes. The installer checks **Cassette Feeding Unit**. **Output Options** is a combo that starts at None. The script selects **Inner Finisher E1** from the list, and if the list is owner-drawn it uses `CB_FINDSTRINGEXACT` / `CB_SETCURSEL` plus a selection-change notice, then Home and Down until the value reads Inner Finisher E1. A confirmation dialog is answered with Yes or OK. Apply is clicked, then Printer properties is closed and opened again for readback. Every `Get-PrinterProperty` name and value is written to the log. `REMAX_PS_OUTPUT` sets **PS Output from Application** when you supply a value. When it is unset, that combo is left alone.

`RESULT: PASS` and exit code 0 mean every line passed. `RESULT: PARTIAL` and exit code 2 mean the queue is installed and a `MANUAL` line could not be verified. `RESULT: FAIL` and exit code 1 mean the queue, port, or driver did not install, or `-Verify` read a Device Settings value that is wrong. When the script is run with `irm | iex`, exit code 1 and exit code 2 do not throw. The report is printed, `LASTEXITCODE` is set, and the window stays open.

`-Verify` reads printer properties, then opens Printer properties, reads Device Settings, and clicks Cancel. It does not save changes. `REMAX_DEVICE_UI=0` skips that dialog. The property read still runs.

When the report says `MANUAL`, the property readback and the dialog readback did not confirm that line. On the agent PC:

1. **Printer properties** for **RemaxSecure**, **Device Settings**.
2. **Paper Source Options** = **Cassette Feeding Unit**.
3. **Output Options** = **Inner Finisher E1**.
4. Check **Set User Information**. Click the **Settings...** button on that row (not the one beside **Get Device Information**).
5. The dialog title is **Default Value Settings**. Under **Name to Set for User Information:**, select **User Name** and type the print username in the box under that radio.
6. Leave **Always Confirm User Information When Performing Secured Print** checked, **Confirm User Name When Printing** unchecked, and PIN blank. Click OK, then Apply, OK.
7. Close Printer properties and open them again if they were already open.

A secure-print PIN is not set. Do not treat a Windows print dialog as proof that the username is set. Read the **INSTALL REPORT**.

Device options are tried in this order:

1. `Get-PrinterProperty` / `Set-PrinterProperty`, only when the driver already exposes one of a short list of `Config:*` names (`Config:PaperSourceOptions`, `Config:CNSrcOption`, `Config:CNPaperSource`, `Config:PaperSource`, `Config:CNFinisher`, `Config:OutputOptions`, `Config:CNOutputOption`, and the user-info names `Config:CNSetUserInfo`, `Config:SetUserInformation`, `Config:CNUserInformation`, `Config:CNUserName`, `Config:UserName`, `Config:CNSecureUserName`). A value is kept only when the same property reads back. A failed write is put back to the previous value.
2. UI Automation of the controls named above, then the properties window is closed and opened again for readback.

`PASS` on paper, output, Set User Information, and User Name requires one of those readbacks. A print-ticket `OptCas2` or `IFINE1` value is used only when the dialog was not opened (for example `REMAX_DEVICE_UI=0`) and the ticket still contains it. On the PS3 driver those ticket names are often absent, which is why the dialog is the fallback.

### What was checked without the Canon driver installed

`Get-PrinterProperty` is the supported spooler API for driver configuration. Microsoft documents it for printer properties, and PPD-based PostScript drivers sometimes surface installable options as `Config:*` names. Canon does not publish the v30.00 property names for **Paper Source Options** = **Cassette Feeding Unit** or for the **User Name** radio. This repo cannot query a live Canon driver, so those names are not confirmed. The script lists every property it sees in the log, writes only the candidate names above, and falls back to the recorded dialog.

`HKLM:\SYSTEM\CurrentControlSet\Control\Print\Printers\RemaxSecure\PrinterDriverData` and the printer key's DevMode values are private driver bytes. The script lists the value names and does not write them. Inventing a binary layout would risk a bad DEVMODE. The port-monitor values (`Protocol`, `Queue`, `Byte Count`, `SNMP Enabled`) are Windows spooler settings, not Canon data, and those are written.

Optional, if a later driver build does not expose the dialog: on one reference PC, set the options by hand, then capture printer-specific data and the global DEVMODE. Microsoft documents `d` as printer-specific data and `g` as the global DEVMODE. Do not add `2`. That flag also stores the port and the share.

```powershell
rundll32 printui.dll,PrintUIEntry /Ss /n "RemaxSecure" /a "$env:ProgramData\RemaxSecurePrinter\device-settings.dat" d g
```

On later PCs, point the installer at that file. The print username is still filled from the name typed in that run, because a shared file would contain one person's name. The dialog still runs unless `Get-PrinterProperty` already read back every Device Settings line.

```powershell
$env:REMAX_DEVICE_DAT = "$env:ProgramData\RemaxSecurePrinter\device-settings.dat"
irm https://raw.githubusercontent.com/ItsErod/canon-secure-print/main/install-windows.ps1 | iex
```

This file is not in the repo. Agents do not need it when the Device Settings dialog matches the recorded Windows 11 setup.

If `Canon iR-ADV C5235/5240 PS3` is not already installed, the same one-liner downloads the public release asset and checks it before install:

```text
https://github.com/ItsErod/canon-secure-print/releases/download/driver-v30/Canon-PS3-v30.00-x64.zip
SHA256 4db0d69d0b6417c39ed285698f9dc23dc5a90c6e3372c8f04da68b1d19b678da
26722033 bytes
```

The download uses `Invoke-WebRequest -UseBasicParsing` with TLS 1.2 and follows the GitHub 302 redirect. The file is saved as `download.zip` (or `.cab`, `.inf`, or `.exe` when that is the URL). Windows PowerShell 5.1 `Expand-Archive` rejects any other extension. A `PK` header is extracted as a zip even when the saved name is not `.zip`, using `System.IO.Compression.ZipFile` and then `Expand-Archive` only if that assembly does not load. A size or SHA256 mismatch stops the install and names both the value received and the value expected. The zip is not executed. `pnputil /add-driver /install` stages `x64/Driver/CNS30UA64.INF` (not `x64/misc/NullDriver/lasernull.inf`). The full pnputil output and exit code are written to the log. Exit 0 and 3010 mean staged. Exit 259 means the package is already present. The quoted model in `[Canon.NTamd64]` is exactly `Canon iR-ADV C5235/5240 PS3`. Registration does not point `-InfPath` at the temporary download. It tries `Add-PrinterDriver -Name` with no path, then the same command with the staged file under `C:\Windows\System32\DriverStore\FileRepository\cns30ua64.inf_amd64_*\CNS30UA64.INF` (from pnputil's `Published Name: oemNN.inf`, `Get-WindowsDriver -Online`, or that folder). If those fail, it tries `printui.exe /ia /m "<model>" /f "<store INF>"`, then `rundll32 printui.dll,PrintUIEntry /ia /m "<model>" /h x64 /v 3 /f "<store INF>"`. Each attempt and error is logged.

`REMAX_CANON_PKG_URL` replaces that URL for one run. A different URL is not checked against this SHA256.

If the Canon PS3 driver is still missing after that download, the report names the failure and lists the drivers already on the PC. Optional package, only when you host a different one:

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
3. Expect **RESULT: PASS** when `Canon iR-ADV C5235/5240 PS3` 30.00 x64 is already installed and Device Settings read back. **RESULT: PARTIAL**, exit code 2, means the queue is in place and a line could not be verified. Do those steps from the report, then run the installer again.
4. Print one secure job only if you want to confirm the copier shows that User Name.
5. Run `-Verify`. It reads Device Settings and clicks Cancel. It does not change the queue. `FAIL` on PAPER SOURCE, OUTPUT, USER INFO, or USER NAME means the value was read and is wrong.
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
| `install-windows.ps1` | Windows installer 1.2.5 (`-Verify`, `-SelfTest`) |
| `verify-windows.ps1` | Read-only Windows check (calls `install-windows.ps1 -Verify`) |
| `tests/simulate-install.sh` | Fake-CUPS test of the Mac install and verify flow |
| `tests/check-windows-installer.py` | Static check of the Windows script and README one-liners |
