#!/usr/bin/env python3
"""Copy lib/canon_ppd.pl into the heredocs in the shell installers.

The curl | bash one-liner has no sibling files, so the Perl helper is
embedded. lib/canon_ppd.pl stays the editable source. Run this after
editing it, or pass --check in tests.
"""

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
START = "<<'END_CANON_PPD'\n"
END = "\nEND_CANON_PPD\n"
FILES = ("install-mac.sh", "verify-mac.sh")


def main() -> int:
    check = "--check" in sys.argv
    perl = (ROOT / "lib" / "canon_ppd.pl").read_text()
    if "\nEND_CANON_PPD\n" in perl or perl.startswith("END_CANON_PPD\n"):
        print("lib/canon_ppd.pl contains the heredoc terminator", file=sys.stderr)
        return 1
    if not perl.endswith("\n"):
        perl += "\n"
    desired = perl[:-1]
    stale = False
    for name in FILES:
        path = ROOT / name
        text = path.read_text()
        start = text.find(START)
        if start < 0:
            print(f"{name}: missing {START.strip()}", file=sys.stderr)
            return 1
        start += len(START)
        end = text.find(END, start)
        if end < 0:
            print(f"{name}: missing END_CANON_PPD", file=sys.stderr)
            return 1
        if text.find(START, start) != -1:
            print(f"{name}: more than one canon heredoc", file=sys.stderr)
            return 1
        body = text[start:end]
        if body != desired:
            stale = True
            if check:
                print(f"{name}: embedded canon_ppd.pl does not match lib/canon_ppd.pl", file=sys.stderr)
            else:
                path.write_text(text[:start] + desired + text[end:])
                print(f"updated {name}")
    if check and stale:
        return 1
    if check:
        print("embed matches lib/canon_ppd.pl")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
