#!/usr/bin/env python3
"""
Register the P3.13 NodeGraph.swift vertedero-cleanup split files in the
Xcode project.

Adds the three newly-extracted files to:
  * the main `LatentResonator` target's Sources build phase,
  * the `Graph` PBXGroup children list,
  * the PBXBuildFile and PBXFileReference sections.

Files registered by this script (P3.13 slice #2):
  * Graph/NodeFactory.swift         (extracted from NodeGraph.swift)
  * Graph/GraphSerialization.swift  (extracted from NodeGraph.swift)
  * Graph/GraphSupportTypes.swift   (extracted from NodeGraph.swift)

Idempotent: re-running it is a no-op for any file already registered.
A timestamped backup of `project.pbxproj` is written next to the
original before any edit so the change can be rolled back by hand.

Approach mirrors `scripts/register_macro_lock_controller.py` (plain
string surgery on the pbxproj, no external deps), generalized to a
list of files so we only walk the pbxproj once per file.
"""

from __future__ import annotations

import os
import re
import shutil
import sys
import time
import uuid
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
PROJECT_DIR = REPO_ROOT / "LatentResonator"
PBXPROJ = PROJECT_DIR / "LatentResonator.xcodeproj" / "project.pbxproj"

GROUP_NAME = "Graph"

# (file name, on-disk relative path under LatentResonator/LatentResonator/)
FILES: list[tuple[str, str]] = [
    ("NodeFactory.swift", "Graph/NodeFactory.swift"),
    ("GraphSerialization.swift", "Graph/GraphSerialization.swift"),
    ("GraphSupportTypes.swift", "Graph/GraphSupportTypes.swift"),
]


def generate_uuid() -> str:
    """24-char hex UUID matching Xcode's pbxproj format."""
    return uuid.uuid4().hex.upper()[:24]


def backup_project() -> Path:
    backup = PBXPROJ.with_name(f"{PBXPROJ.name}.backup_{int(time.time())}")
    shutil.copy2(PBXPROJ, backup)
    print(f"  backup: {backup.name}")
    return backup


def already_registered(content: str, file_name: str) -> bool:
    return f"/* {file_name} */" in content


def add_file_reference(content: str, file_ref_uuid: str, file_name: str) -> str:
    """Insert a PBXFileReference entry just before `/* End PBXFileReference section */`."""
    entry = (
        f"\t\t{file_ref_uuid} /* {file_name} */ = {{isa = PBXFileReference; "
        f'lastKnownFileType = sourcecode.swift; path = {file_name}; sourceTree = "<group>"; }};'
    )
    marker = "/* End PBXFileReference section */"
    if marker not in content:
        raise RuntimeError("PBXFileReference end marker not found")
    return content.replace(marker, entry + "\n" + marker, 1)


def add_build_file(content: str, build_uuid: str, file_ref_uuid: str, file_name: str) -> str:
    """Insert a PBXBuildFile entry just before `/* End PBXBuildFile section */`."""
    entry = (
        f"\t\t{build_uuid} /* {file_name} in Sources */ = {{isa = PBXBuildFile; "
        f"fileRef = {file_ref_uuid} /* {file_name} */; }};"
    )
    marker = "/* End PBXBuildFile section */"
    if marker not in content:
        raise RuntimeError("PBXBuildFile end marker not found")
    return content.replace(marker, entry + "\n" + marker, 1)


def add_to_graph_group(content: str, file_ref_uuid: str, file_name: str) -> str:
    """Add the file ref to the `Graph` PBXGroup children list."""
    group_pattern = re.compile(
        r"(/\* Graph \*/ = \{\n(?:\t[^\n]*\n)*?\t\t\tchildren = \(\n)(?P<children>(?:\t\t\t\t[^\n]*\n)*?)(\t\t\t\);)",
        re.MULTILINE,
    )
    match = group_pattern.search(content)
    if not match:
        raise RuntimeError("Graph PBXGroup block not found")
    child_line = f"\t\t\t\t{file_ref_uuid} /* {file_name} */,"
    children_block = match.group("children")
    if child_line in children_block:
        return content  # already present
    new_children = children_block + child_line + "\n"
    return content[: match.start("children")] + new_children + content[match.end("children"):]


def add_to_main_sources_phase(content: str, build_uuid: str, file_name: str) -> str:
    """Add the build file to the main `LatentResonator` target's Sources phase.

    The main Sources phase is the one that lists `NeuralEngine.swift in Sources`
    (the test target's Sources phase lists `NeuralEngineTests.swift in Sources`).
    """
    sources_phase_pattern = re.compile(
        r"(?P<block>\t\t[0-9A-F]+ /\* Sources \*/ = \{\n"
        r"\t\t\tisa = PBXSourcesBuildPhase;\n"
        r"\t\t\tbuildActionMask = 2147483647;\n"
        r"\t\t\tfiles = \(\n"
        r"(?:\t\t\t\t[^\n]*\n)*?"
        r"\t\t\t\t[0-9A-F]+ /\* NeuralEngine\.swift in Sources \*/,\n"
        r"(?:\t\t\t\t[^\n]*\n)*?)"
        r"(\t\t\t\);)",
        re.MULTILINE,
    )
    match = sources_phase_pattern.search(content)
    if not match:
        raise RuntimeError("Main Sources build phase (containing NeuralEngine.swift) not found")
    block = match.group("block")
    closing = match.group(2)
    build_line = f"\t\t\t\t{build_uuid} /* {file_name} in Sources */,"
    if build_line in block:
        return content
    new_block = block + build_line + "\n"
    return content[: match.start("block")] + new_block + closing + content[match.end():]


def main() -> int:
    if not PBXPROJ.exists():
        print(f"ERROR: pbxproj not found at {PBXPROJ}", file=sys.stderr)
        return 1

    # Verify all files exist on disk first.
    missing = []
    for file_name, rel_path in FILES:
        disk_path = PROJECT_DIR / "LatentResonator" / rel_path
        if not disk_path.exists():
            missing.append(str(disk_path))
    if missing:
        for p in missing:
            print(f"ERROR: file not found on disk: {p}", file=sys.stderr)
        return 1

    content = PBXPROJ.read_text()

    pending: list[tuple[str, str]] = []
    for file_name, _ in FILES:
        if already_registered(content, file_name):
            print(f"{file_name} already registered in pbxproj — skipping.")
        else:
            pending.append(file_name)

    if not pending:
        print("Nothing to do.")
        return 0

    print(f"Registering {len(pending)} file(s) in {PBXPROJ.name} ...")
    backup_project()

    for file_name in pending:
        file_ref_uuid = generate_uuid()
        build_uuid = generate_uuid()
        content = add_file_reference(content, file_ref_uuid, file_name)
        content = add_build_file(content, build_uuid, file_ref_uuid, file_name)
        content = add_to_graph_group(content, file_ref_uuid, file_name)
        content = add_to_main_sources_phase(content, build_uuid, file_name)
        print(f"  registered: {file_name}")

    PBXPROJ.write_text(content)
    print("done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
