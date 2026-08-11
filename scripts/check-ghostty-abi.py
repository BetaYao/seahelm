#!/usr/bin/env python3
"""Fail the build when ghostty.h declares a function libghostty implements
differently.

C lets a caller pass more arguments than the callee reads, so an over-declared
parameter is silent at compile time and wrong at run time: upstream commit
c5f921bb0 declared `ghostty_surface_free_text(surface, text)` for an
implementation that takes only `text`, and the arm64 build reads its argument
from x0. Every call therefore handed it the surface, it found nothing to free,
and each `ghostty_surface_read_text` buffer leaked — 105 MB/h across 19 panes,
invisible for 15 months.

Comparing the header against the framework's own copy would not have caught it:
all three copies are byte-identical and all three are wrong. The invariant worth
enforcing is header-vs-implementation, so this compares the declarations in
`ghostty.h` with the `export fn` signatures in the vendored Zig source.

Usage: check-ghostty-abi.py [header] [zig-source-root]
Exit 0 when every shared symbol agrees, 1 on any mismatch, 2 when inputs are
missing (treated as a hard failure: an unrunnable check must not read as a pass).
"""

import glob
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_HEADER = os.path.join(REPO, "ghostty.h")
DEFAULT_ZIG_ROOT = os.path.join(REPO, "ghostty", "src")

# A local patch to the vendored header is legitimate — it is how a wrong upstream
# declaration gets corrected — so the check reads what is actually compiled and
# never assumes the header matches upstream.
DECL = re.compile(r"\b\w+[\s*]+(ghostty_\w+)\s*\(([^;]*?)\)\s*;", re.S)
EXPORT = re.compile(r"export fn (ghostty_\w+)\s*\(([^)]*)\)", re.S)


def count_args(text):
    """Parameters in a C or Zig parameter list.

    Splits on top-level commas and drops empty segments: Zig permits a trailing
    comma in a multi-line parameter list, and counting commas instead of
    parameters reported every such function as one argument too many.
    """
    text = text.strip()
    if text in ("", "void"):
        return 0
    parts, depth, current = [], 0, ""
    for char in text:
        if char in "(<[":
            depth += 1
        elif char in ")>]":
            depth -= 1
        if char == "," and depth == 0:
            parts.append(current)
            current = ""
        else:
            current += char
    parts.append(current)
    return len([p for p in parts if p.strip()])


def parse_header(path):
    source = re.sub(r"//[^\n]*", "", open(path, errors="ignore").read())
    return {m.group(1): count_args(m.group(2)) for m in DECL.finditer(source)}


def parse_zig(root):
    out = {}
    for path in glob.glob(os.path.join(root, "**", "*.zig"), recursive=True):
        for m in EXPORT.finditer(open(path, errors="ignore").read()):
            out[m.group(1)] = (count_args(m.group(2)), os.path.relpath(path, REPO))
    return out


def main():
    header = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_HEADER
    zig_root = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_ZIG_ROOT

    if not os.path.exists(header):
        sys.stderr.write("ghostty ABI check: header not found: %s\n" % header)
        return 2
    if not os.path.isdir(zig_root):
        sys.stderr.write(
            "ghostty ABI check: zig source not found: %s\n"
            "  the submodule is needed to verify declarations; run scripts/setup.sh\n" % zig_root
        )
        return 2

    declared = parse_header(header)
    implemented = parse_zig(zig_root)
    shared = sorted(set(declared) & set(implemented))
    if not shared:
        sys.stderr.write("ghostty ABI check: parsed no shared symbols — check is not working\n")
        return 2

    bad = [(k, declared[k], implemented[k][0], implemented[k][1])
           for k in shared if declared[k] != implemented[k][0]]
    if not bad:
        print("ghostty ABI check: %d symbols agree" % len(shared))
        return 0

    sys.stderr.write("ghostty ABI check: %d of %d symbols disagree\n" % (len(bad), len(shared)))
    for name, want, got, path in bad:
        sys.stderr.write(
            "  %s: header declares %d arg(s), %s implements %d\n" % (name, want, path, got)
        )
    sys.stderr.write(
        "\nA caller compiled against the header will pass arguments the implementation\n"
        "never reads. Correct the declaration in ghostty.h to match the implementation\n"
        "(and every call site), or re-vendor a header that matches the linked binary.\n"
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
