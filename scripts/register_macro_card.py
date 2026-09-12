#!/usr/bin/env python3
"""
Register `MacroCard.swift` in the Xcode project.

Adds the newly-created `Views/Patch/Cards/MacroCard.swift` to:
  * the main `LatentResonator` target's Sources build phase,
  * the `Cards` PBXGroup children list,
  * the PBXBuildFile and PBXFileReference sections.

Idempotent: re-running it is a no-op once the file is registered.
"""

from __future__ import annotations

import re
import shutil
import sys
import time
import uuid
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
PROJECT_DIR = REPO_ROOT / "LatentResonator"
PBXPROJ = PROJECT_DIR / "LatentResonator.xcodeproj" / "project.pbxproj"

FILE_NAME = "MacroCard.swift"
CARDS_GROUP_UUID = "PCH10000000000000000CRD1"


def generate_uuid() -> str:
    """24-char hex UUID matching Xcode's pbxproj format."""
    return uuid.uuid4().hex.upper()[:24]


def backup_project() -> Path:
    backup = PBXPROJ.with_name(f"{PBXPROJ.name}.backup_macro_card_{int(time.time())}")
    shutil.copy2(PBXPROJ, backup)
    print(f"  backup: {backup.name}")
    return backup


def already_registered(content: str) -> bool:
    return f"/* {FILE_NAME} */" in content


def add_file_reference(content: str, file_ref_uuid: str) -> str:
    """Insert a PBXFileReference entry just before `/* End PBXFileReference section */`."""
    entry = (
        f"\t\t{file_ref_uuid} /* {FILE_NAME} */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = sourcecode.swift; path = {FILE_NAME}; "
        f'sourceTree = "<group>"; }};'
    )
    marker = "/* End PBXFileReference section */"
    if marker not in content:
        raise RuntimeError("PBXFileReference end marker not found")
    return content.replace(marker, entry + "\n" + marker, 1)


def add_build_file(content: str, build_uuid: str, file_ref_uuid: str) -> str:
    """Insert a PBXBuildFile entry just before `/* End PBXBuildFile section */`."""
    entry = (
        f"\t\t{build_uuid} /* {FILE_NAME} in Sources */ = {{isa = PBXBuildFile; "
        f"fileRef = {file_ref_uuid} /* {FILE_NAME} */; }};"
    )
    marker = "/* End PBXBuildFile section */"
    if marker not in content:
        raise RuntimeError("PBXBuildFile end marker not found")
    return content.replace(marker, entry + "\n" + marker, 1)


def add_to_cards_group(content: str, file_ref_uuid: str) -> str:
    """Add the file ref to the `Cards` PBXGroup children list."""
    group_pattern = re.compile(
        r"(?P<block>" + re.escape(CARDS_GROUP_UUID) + r" /\* Cards \*/ = \{\n"
        r"\t\t\tisa = PBXGroup;\n"
        r"\t\t\tchildren = \(\n"
        r"(?P<children>(?:\t\t\t\t[^\n]*\n)*?)"
        r"[ \t]*\);\n"
        r"\t\t\tpath = Cards;\n"
        r"\t\t\tsourceTree = \"<group>\";\n"
        r"\t\t\};)",
        re.MULTILINE,
    )
    match = group_pattern.search(content)
    if not match:
        raise RuntimeError("Cards PBXGroup block not found")

    child_line = f"\t\t\t\t{file_ref_uuid} /* {FILE_NAME} */,"
    children_block = match.group("children")
    if child_line in children_block:
        return content

    # Append to the children list.
    new_children = children_block + child_line + "\n"
    return content[: match.start("children")] + new_children + content[match.end("children"):]


def add_to_main_sources_phase(content: str, build_uuid: str) -> str:
    """Add the build file to the main `LatentResonator` target's Sources phase."""
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
    build_line = f"\t\t\t\t{build_uuid} /* {FILE_NAME} in Sources */,"
    if build_line in block:
        return content
    new_block = block + build_line + "\n"
    return content[: match.start("block")] + new_block + closing + content[match.end():]


def main() -> int:
    if not PBXPROJ.exists():
        print(f"ERROR: pbxproj not found at {PBXPROJ}", file=sys.stderr)
        return 1

    disk_path = PROJECT_DIR / "LatentResonator" / "Views" / "Patch" / "Cards" / FILE_NAME
    if not disk_path.exists():
        print(f"ERROR: {FILE_NAME} not found on disk at {disk_path}", file=sys.stderr)
        return 1

    content = PBXPROJ.read_text()
    if already_registered(content):
        print(f"{FILE_NAME} already registered in pbxproj — nothing to do.")
        return 0

    print(f"Registering {FILE_NAME} in {PBXPROJ.name} ...")
    backup_project()

    file_ref_uuid = generate_uuid()
    build_uuid = generate_uuid()

    content = add_file_reference(content, file_ref_uuid)
    content = add_build_file(content, build_uuid, file_ref_uuid)
    content = add_to_cards_group(content, file_ref_uuid)
    content = add_to_main_sources_phase(content, build_uuid)

    PBXPROJ.write_text(content)
    print(f"  registered: {FILE_NAME}")
    print("done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
