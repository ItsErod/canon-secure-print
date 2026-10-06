# Remax Secure Printer

Terminal installer for the RE/MAX Escarpment Canon secure queue. Agents run one command in Terminal. There is no `.app` and nothing clicks the Canon utility.

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
2. `install-mac.sh`, `verify-mac.sh`, and `README.md` must be on that branch. `lib/canon_ppd.pl` is the same Perl helper already embedded inside the two scripts, so a lone `curl` of `install-mac.sh` still runs.
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

`install-windows.ps1` is an outline only. It exits with an error and does not install a queue. Mac is the supported path.

## Layout

| File | Role |
| --- | --- |
| `install-mac.sh` | Installer agents run |
| `verify-mac.sh` | Read-only check for IT |
| `lib/canon_ppd.pl` | Encoder and PPD patcher (also embedded in the two scripts) |
| `install-windows.ps1` | Not implemented |
| `tests/simulate-install.sh` | Fake-CUPS test of the install and verify flow |
