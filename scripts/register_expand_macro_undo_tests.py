#!/usr/bin/env python3
"""
Register `ExpandMacroUndoTests.swift` in the LatentResonatorTests target
of LatentResonator.xcodeproj. Idempotent: re-running is a no-op once the
file is registered. A timestamped backup of `project.pbxproj` is written
before any edit so the change can be rolled back by hand if needed.
"""
from __future__ import annotations

import shutil
import sys
import time
import uuid
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
PROJECT_DIR = REPO_ROOT / "LatentResonator"
PBXPROJ = PROJECT_DIR / "LatentResonator.xcodeproj" / "project.pbxproj"

FILE_NAME = "ExpandMacroUndoTests.swift"
FILE_REL_PATH = "LatentResonatorTests/ExpandMacroUndoTests.swift"

TEST_SOURCES_ANCHOR = "NeuralEngineTests.swift in Sources"
TEST_GROUP_ANCHOR = "NeuralEngineTests.swift"
TEST_GROUP_NAME = "LatentResonatorTests"


def generate_uuid() -> str:
    return uuid.uuid4().hex.upper()[:24]


def backup_project() -> Path:
    backup = PBXPROJ.with_name(f"{PBXPROJ.name}.backup_{int(time.time())}")
    shutil.copy2(PBXPROJ, backup)
    print(f"  backup: {backup.name}")
    return backup


def already_registered(content: str, file_name: str) -> bool:
    return f"/* {file_name} */" in content


def add_file_reference(content: str, file_name: str, file_ref_uuid: str) -> str:
    entry = (
        f"\t\t{file_ref_uuid} /* {file_name} */ = {{isa = PBXFileReference; "
        f'lastKnownFileType = sourcecode.swift; path = {file_name}; sourceTree = "<group>"; }};'
    )
    marker = "/* End PBXFileReference section */"
    if marker not in content:
        raise RuntimeError("PBXFileReference end marker not found")
    return content.replace(marker, entry + "\n" + marker, 1)


def add_build_file(content: str, file_name: str, build_uuid: str, file_ref_uuid: str) -> str:
    entry = (
        f"\t\t{build_uuid} /* {file_name} in Sources */ = {{isa = PBXBuildFile; "
        f"fileRef = {file_ref_uuid} /* {file_name} */; }};"
    )
    marker = "/* End PBXBuildFile section */"
    if marker not in content:
        raise RuntimeError("PBXBuildFile end marker not found")
    return content.replace(marker, entry + "\n" + marker, 1)


def add_to_group(content: str, file_name: str, file_ref_uuid: str,
                 group_name: str, anchor_file: str) -> str:
    import re

    group_pattern = re.compile(
        r"(?P<block>/\* " + re.escape(group_name) + r" \*/ = \{\n"
        r"\t\t\tisa = PBXGroup;\n"
        r"(?:\t\t\t[^\n]*\n)*?"
        r"\t\t\tchildren = \(\n"
        r"(?P<children>(?:[^\n]*\n)*?)"
        r"\t\t\t\);)",
        re.MULTILINE,
    )
    matches = list(group_pattern.finditer(content))
    if not matches:
        raise RuntimeError(f"PBXGroup '{group_name}' not found")
    target_match = None
    for m in matches:
        if anchor_file in m.group("children"):
            target_match = m
            break
    if target_match is None:
        target_match = matches[0]

    child_line = f"\t\t\t\t{file_ref_uuid} /* {file_name} */,"
    children_block = target_match.group("children")
    if child_line in children_block:
        return content
    new_children = children_block + child_line + "\n"
    return (
        content[: target_match.start("children")]
        + new_children
        + content[target_match.end("children"):]
    )


def add_to_sources_phase(content: str, file_name: str, build_uuid: str,
                         anchor_file: str) -> str:
    import re

    anchor_re = re.escape(anchor_file)
    pattern = re.compile(r"\t\t\t\t[0-9A-F]+ /\* " + anchor_re + r" \*/,")
    matches = list(pattern.finditer(content))
    if not matches:
        raise RuntimeError(f"Sources anchor '{anchor_file}' not found")
    target_match = matches[0]
    build_line = f"\t\t\t\t{build_uuid} /* {file_name} in Sources */,"
    if build_line in content:
        return content
    return content[: target_match.end()] + "\n" + build_line + content[target_match.end():]


def main() -> int:
    if not PBXPROJ.exists():
        print(f"ERROR: pbxproj not found at {PBXPROJ}", file=sys.stderr)
        return 1

    disk_path = PROJECT_DIR / FILE_REL_PATH
    if not disk_path.exists():
        print(f"ERROR: {FILE_NAME} not found on disk at {disk_path}", file=sys.stderr)
        return 1

    content = PBXPROJ.read_text()
    if already_registered(content, FILE_NAME):
        print(f"{FILE_NAME} already registered in pbxproj — nothing to do.")
        return 0

    print(f"Registering {FILE_NAME} in {PBXPROJ.name} ...")
    backup_project()

    file_ref_uuid = generate_uuid()
    build_uuid = generate_uuid()

    content = add_file_reference(content, FILE_NAME, file_ref_uuid)
    content = add_build_file(content, FILE_NAME, build_uuid, file_ref_uuid)
    content = add_to_group(content, FILE_NAME, file_ref_uuid,
                           TEST_GROUP_NAME, TEST_GROUP_ANCHOR)
    content = add_to_sources_phase(content, FILE_NAME, build_uuid,
                                   TEST_SOURCES_ANCHOR)

    PBXPROJ.write_text(content)
    print(f"  registered: {FILE_NAME} (target=test, group={TEST_GROUP_NAME})")
    print("done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
