#!/usr/bin/env python3
"""
Normalize malformed multi-entry lines in project.pbxproj.

Some registration scripts historically emitted two PBXBuildFile / PBXFileReference
entries on a single physical line, separated by tabs instead of newlines:

        <UUID> /* File.swift */ = { ... };            <UUID> /* File2.swift */ = { ... };

This script detects any line matching the pattern

        ...*/,\t+[A-Z0-9]{20,} /*...

(i.e. an entry ending with `*/,` followed by tabs and another entry's UUID)
and splits it into two properly indented lines. Idempotent: re-running on a
clean file is a no-op. A timestamped backup is written next to the original
before any edit.

Usage:
    python3 scripts/normalize_pbxproj_entries.py [path/to/project.pbxproj]
"""
from __future__ import annotations

import re
import shutil
import sys
from datetime import datetime
from pathlib import Path

DEFAULT_PBXPROJ = (
    Path(__file__).resolve().parents[1]
    / "LatentResonator"
    / "LatentResonator.xcodeproj"
    / "project.pbxproj"
)

# An entry ends with `*/,` then is followed by tabs and the start of the next
# entry: a 20+ char uppercase alphanumeric UUID then ` /*`. We allow 20+ to
# tolerate the project's mixed-length IDs (24-char hex, 24-char mnemonic, etc.).
MULTI_ENTRY_RE = re.compile(r"\*/,\t+([A-Z0-9]{20,} /\*)")


def split_line(line: str) -> list[str]:
    """Split a single physical line containing multiple pbxproj entries.

    Returns a list of properly indented lines (one entry per line). The
    leading indentation of the original line is preserved for the first
    entry; subsequent entries are re-indented with the same leading tabs.
    """
    # Capture leading whitespace (tabs) of the original line.
    leading = re.match(r"^(\t*)", line)
    indent = leading.group(1) if leading else "\t\t"

    # Find all split points: positions where `*/,` is followed by tabs and
    # the next UUID. We split AFTER the comma, inserting a newline + indent.
    parts = []
    cursor = 0
    for m in MULTI_ENTRY_RE.finditer(line):
        # End of the comma that terminates the current entry.
        split_pos = m.start() + len("*/,")
        parts.append(line[cursor:split_pos])
        cursor = split_pos
    parts.append(line[cursor:])

    # Reassemble: first part keeps original indent; each subsequent part gets
    # the same indent prepended (the tabs that were between entries are now
    # stripped because they live in `cursor` onward — but they were matched
    # as part of the separator, so `parts[1:]` start with the UUID directly).
    out = [parts[0].rstrip("\n")]
    for seg in parts[1:]:
        seg = seg.lstrip("\t").rstrip("\n")
        if seg:
            out.append(indent + seg)
    return out


def normalize(content: str) -> tuple[str, int]:
    """Return (new_content, num_lines_split)."""
    lines = content.splitlines(keepends=True)
    out_lines: list[str] = []
    splits = 0
    for line in lines:
        if MULTI_ENTRY_RE.search(line):
            new = split_line(line)
            # Preserve the original line ending.
            eol = "\n" if line.endswith("\n") else ""
            if eol:
                new = [seg + eol for seg in new[:-1]] + [new[-1] + eol]
            out_lines.extend(new)
            splits += 1
        else:
            out_lines.append(line)
    return "".join(out_lines), splits


def main(argv: list[str]) -> int:
    pbxproj = Path(argv[1]) if len(argv) > 1 else DEFAULT_PBXPROJ
    if not pbxproj.exists():
        print(f"ERROR: not found: {pbxproj}", file=sys.stderr)
        return 1

    content = pbxproj.read_text()
    new_content, splits = normalize(content)

    if splits == 0:
        print(f"✅ {pbxproj.name}: already normalized (no multi-entry lines).")
        return 0

    bak = pbxproj.with_name(f"{pbxproj.name}.bak.{datetime.now().strftime('%Y%m%d_%H%M%S')}")
    shutil.copy2(pbxproj, bak)
    print(f"📦 backup: {bak.name}")

    pbxproj.write_text(new_content)
    print(f"✅ split {splits} malformed line(s) in {pbxproj.name}.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
