#!/bin/bash
# Exercise install-mac.sh and verify-mac.sh against a fake CUPS.
# This does not replace a Mac with the real Canon driver installed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

bash -n install-mac.sh
bash -n verify-mac.sh
python3 tests/sync-embed.py --check
perl -c lib/canon_ppd.pl >/dev/null
perl lib/canon_ppd.pl self-test >/dev/null

# macOS /bin/bash is 3.2. `curl | sudo bash` leaves BASH_SOURCE unset, and
# set -u then aborts on ${BASH_SOURCE[0]} before lpadmin. The default form
# ${BASH_SOURCE[0]-} is required. A bare expansion must not come back.
if grep -n 'src="${BASH_SOURCE\[0\]}"' install-mac.sh verify-mac.sh >/dev/null; then
  echo "BASH_SOURCE[0] is expanded without a default; a piped bash 3.2 installer aborts under set -u" >&2
  exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/remax-sim.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

ppd_dir="$work/ppd"
state="$work/state"
support="$work/support"
mkdir -p "$ppd_dir" "$state" "$support"

cat > "$work/driver.ppd" <<'EOF'
*PPD-Adobe: "4.3"
*%INFO_PrPr1: b2xkY29sb24=
*%INFO_PrPr2: END_3
*PCFileName: "CNMCIRAC5235S2.PPD"
*ModelName: "Canon iR-ADV C5235/5240 P"
*NickName: "Canon iR-ADV C5235/5240 PS"
*OpenUI *CNSrcOption/Cassette Feeding Unit: PickOne
*DefaultCNSrcOption: None
*CNSrcOption OptCas2/On: ""
*CloseUI: *CNSrcOption
*OpenUI *CNFinisher/Output Options: PickOne
*DefaultCNFinisher: None
*CNFinisher IFINE1/Inner Finisher E1: ""
*CloseUI: *CNFinisher
*OpenUI *CNDuplex/Print Style: PickOne
*DefaultCNDuplex: DuplexFront
*CNDuplex None/1-sided Printing: ""
*CloseUI: *CNDuplex
*CNInSlotManMediaType JAPANESE/Japanese Paper: ""
*%INFO_PrPr1=PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz4=
*%INFO_PrPr2=END_38
EOF

cat > "$work/bad.ppd" <<'EOF'
*PPD-Adobe: "4.3"
*ModelName: "Japanese Paper Tray"
*NickName: "Japanese Paper"
*DefaultCNSrcOption: OptCas2
*DefaultCNFinisher: IFINE1
*DefaultCNDuplex: None
EOF

# Stale colour queue the installer must remove.
printf '%s\n' 'lpd://old.example/RemaxSecure_COLOUR' > "$state/RemaxSecure_COLOUR.uri"
printf '%s\n' '*PPD-Adobe: "4.3"' > "$ppd_dir/RemaxSecure_COLOUR.ppd"

isolated="$work/isolated"
mkdir -p "$isolated"
cp install-mac.sh verify-mac.sh "$isolated/"

export REMAX_TEST_MODE=1
export REMAX_PPD_SOURCE="$work/driver.ppd"
export REMAX_PRINT_USER=tsiogase
export REMAX_CONSOLE_USER=erod
export REMAX_LPADMIN="$ROOT/tests/fake-lpadmin"
export REMAX_LPSTAT="$ROOT/tests/fake-lpstat"
export REMAX_CUPS_PPD_DIR="$ppd_dir"
export REMAX_CUPS_STATE="$state"
export REMAX_SUPPORT_DIR="$support"
unset REMAX_FAKE_DROP_ON_O || true

run_install() {
  local script="$1"
  local log="$2"
  export REMAX_LOG="$log"
  bash "$script" | tee "$work/stdout.txt"
}

assert_report() {
  local file="$1"
  local label
  for label in "RESULT:      PASS" "DRIVER:      PASS" "CASSETTE:    PASS" "FINISHER:    PASS" "SIDES:       PASS" "ENTER NAME:  PASS"; do
    if ! grep -q "^${label}" "$file"; then
      echo "missing report line: $label" >&2
      cat "$file" >&2
      exit 1
    fi
  done
}

assert_installed() {
  local installed="$ppd_dir/RemaxSecure.ppd"
  [[ -f "$installed" ]]
  perl "$ROOT/lib/canon_ppd.pl" verify "$installed" tsiogase erod >/dev/null
  grep -q '^\*DefaultCNSrcOption: OptCas2$' "$installed"
  grep -q '^\*DefaultCNFinisher: IFINE1$' "$installed"
  grep -q '^\*DefaultCNDuplex: None$' "$installed"
  grep -q '^\*%INFO_PrPr1: eJyNksFOwzAMhu97iql3yIY4cEizAxKH' "$installed"
  grep -q '^\*%INFO_PrPr3: END_598$' "$installed"
  grep -q 'Japanese Paper' "$installed"
  if grep -E '^\*%INFO_PrPr[0-9]+=' "$installed" >/dev/null; then
    echo "legacy equals-form INFO_PrPr is still in the installed PPD" >&2
    exit 1
  fi
  [[ "$(cat "$state/RemaxSecure.uri")" == "lpd://172.16.105.21/RemaxSecure" ]]
  [[ ! -e "$ppd_dir/RemaxSecure_COLOUR.ppd" ]]
  [[ ! -e "$state/RemaxSecure_COLOUR.uri" ]]
  grep -q '^-x RemaxSecure_COLOUR$' "$state/lpadmin.log"
  grep -q -- '-P ' "$state/lpadmin.log"
  grep -q -- '-o CNSrcOption=OptCas2' "$state/lpadmin.log"
}

echo "=== self-test from a single copied script (curl layout) ==="
bash "$isolated/install-mac.sh" --self-test
bash "$isolated/verify-mac.sh" --self-test

echo "=== install via embedded helper ==="
run_install "$isolated/install-mac.sh" "$work/install.log"
assert_report "$work/stdout.txt"
assert_installed
grep -q 'Enter Name should show tsiogase' "$work/stdout.txt"
[[ -f "$support/last-install.txt" ]]
grep -q '^result=PASS$' "$support/last-install.txt"
grep -q 'installer 1.0.1' "$work/stdout.txt"

echo "=== install via stdin pipe (curl | sudo bash layout) ==="
export REMAX_LOG="$work/install-stdin.log"
cat "$isolated/install-mac.sh" | bash >"$work/stdout.txt"
assert_report "$work/stdout.txt"
assert_installed
grep -q 'installer 1.0.1' "$work/stdout.txt"

echo "=== verify ==="
export REMAX_LOG="$work/verify.log"
bash "$isolated/verify-mac.sh" | tee "$work/verify-stdout.txt"
assert_report "$work/verify-stdout.txt"
grep -q 'No changes made.' "$work/verify-stdout.txt"

echo "=== idempotent install via repo copy (lib/canon_ppd.pl) ==="
run_install "$ROOT/install-mac.sh" "$work/install-again.log"
assert_report "$work/stdout.txt"
assert_installed

echo "=== repair when lpadmin -o drops defaults ==="
export REMAX_FAKE_DROP_ON_O=1
run_install "$isolated/install-mac.sh" "$work/install-drop.log"
unset REMAX_FAKE_DROP_ON_O
assert_report "$work/stdout.txt"
assert_installed
grep -q 'Defaults missing after lpadmin -o' "$work/install-drop.log"

echo "=== reject a PPD that only mentions Japanese Paper ==="
export REMAX_PPD_SOURCE="$work/bad.ppd"
export REMAX_LOG="$work/bad.log"
set +e
bash "$isolated/install-mac.sh" >"$work/bad-stdout.txt" 2>"$work/bad-stderr.txt"
bad_rc=$?
set -e
if [[ "$bad_rc" -eq 0 ]]; then
  echo "bad PPD was accepted" >&2
  cat "$work/bad-stdout.txt" "$work/bad-stderr.txt" >&2
  exit 1
fi
grep -q 'Refusing to install' "$work/bad-stdout.txt"
export REMAX_PPD_SOURCE="$work/driver.ppd"
assert_installed

echo "=== missing driver explains what to install ==="
unset REMAX_PPD_SOURCE
export REMAX_LOG="$work/missing.log"
set +e
bash "$isolated/install-mac.sh" >"$work/missing-stdout.txt" 2>"$work/missing-stderr.txt"
miss_rc=$?
set -e
if [[ "$miss_rc" -eq 0 ]]; then
  echo "missing driver was treated as success" >&2
  exit 1
fi
grep -q 'CNMCIRAC5235S2.ppd.gz' "$work/missing-stdout.txt"
export REMAX_PPD_SOURCE="$work/driver.ppd"
assert_installed

echo "=== username required when there is no terminal ==="
export REMAX_LOG="$work/nouser.log"
set +e
env -u REMAX_PRINT_USER bash "$isolated/install-mac.sh" >"$work/nouser-stdout.txt" 2>"$work/nouser-stderr.txt"
nouser_rc=$?
set -e
if [[ "$nouser_rc" -eq 0 ]]; then
  echo "missing username was accepted" >&2
  exit 1
fi
cat "$work/nouser-stdout.txt" "$work/nouser-stderr.txt" | grep -q 'REMAX_PRINT_USER'
export REMAX_PRINT_USER=tsiogase

echo "=== non-mac refusal ==="
set +e
env -u REMAX_TEST_MODE bash "$ROOT/install-mac.sh" --help >/dev/null
help_rc=$?
env -u REMAX_TEST_MODE bash "$ROOT/install-mac.sh" >"$work/os-stdout.txt" 2>"$work/os-stderr.txt"
os_rc=$?
set -e
[[ "$help_rc" -eq 0 ]]
if [[ "$os_rc" -eq 0 ]]; then
  echo "non-mac install was accepted" >&2
  exit 1
fi
cat "$work/os-stdout.txt" "$work/os-stderr.txt" | grep -q 'macOS'

echo "=== verify fails on a queue that is not Remax Secure ==="
bad_dir="$work/bad-cups/ppd"
bad_state="$work/bad-cups/state"
mkdir -p "$bad_dir" "$bad_state"
cp "$work/driver.ppd" "$bad_dir/RemaxSecure.ppd"
printf '%s\n' 'lpd://172.16.105.21/RemaxSecure' > "$bad_state/RemaxSecure.uri"
export REMAX_CUPS_PPD_DIR="$bad_dir"
export REMAX_CUPS_STATE="$bad_state"
export REMAX_LOG="$work/verify-bad.log"
set +e
bash "$isolated/verify-mac.sh" >"$work/verify-bad-stdout.txt" 2>"$work/verify-bad-stderr.txt"
verify_bad_rc=$?
set -e
if [[ "$verify_bad_rc" -eq 0 ]]; then
  echo "unpatched queue verified as PASS" >&2
  cat "$work/verify-bad-stdout.txt" >&2
  exit 1
fi
grep -q '^RESULT:      FAIL' "$work/verify-bad-stdout.txt"
grep -q '^ENTER NAME:  FAIL' "$work/verify-bad-stdout.txt"

echo "simulate-install: PASS"
