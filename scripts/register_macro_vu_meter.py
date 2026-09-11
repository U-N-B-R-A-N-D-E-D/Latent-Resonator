#!/usr/bin/env python3
"""
Register `MacroVUMeter.swift` in the Xcode project.

P4 — adds the newly-created `Views/Perform/MacroVUMeter.swift` (the PERFORM
macro mixer stereo VU meter that polls `MacroNode.telemetrySnapshot`) to:
  * the main `LatentResonator` target's Sources build phase,
  * the `Views` PBXGroup children list (mirrors the registration pattern
    used for `EnvelopeCurveView.swift`, which also lives in
    `Views/Perform/` but is registered directly under the `Views` group
    with `path = Perform/<file>.swift`),
  * the PBXBuildFile and PBXFileReference sections.

Idempotent: re-running it is a no-op once the file is registered. A
timestamped backup of `project.pbxproj` is written next to the original
before any edit so the change can be rolled back by hand if needed.

Approach mirrors `scripts/register_macro_lock_controller.py` (plain
string surgery on the pbxproj, no external deps) but targets the
`Views` group instead of `Graph`.
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

FILE_NAME = "MacroVUMeter.swift"
# On-disk location: Views/Perform/MacroVUMeter.swift
# pbxproj `path` is relative to the parent group (Views), so:
FILE_REL_PATH_IN_VIEWS_GROUP = "Perform/MacroVUMeter.swift"
GROUP_NAME = "Views"


def generate_uuid() -> str:
    """24-char hex UUID matching Xcode's pbxproj format."""
    return uuid.uuid4().hex.upper()[:24]


def backup_project() -> Path:
    backup = PBXPROJ.with_name(f"{PBXPROJ.name}.backup_{int(time.time())}")
    shutil.copy2(PBXPROJ, backup)
    print(f"  backup: {backup.name}")
    return backup


def already_registered(content: str) -> bool:
    return f"/* {FILE_NAME} */" in content


def add_file_reference(content: str, file_ref_uuid: str) -> str:
    """Insert a PBXFileReference entry just before `/* End PBXFileReference section */`.

    Mirrors the EnvelopeCurveView entry: `path = Perform/<file>.swift`.
    """
    entry = (
        f"\t\t{file_ref_uuid} /* {FILE_NAME} */ = {{isa = PBXFileReference; "
        f'lastKnownFileType = sourcecode.swift; path = {FILE_REL_PATH_IN_VIEWS_GROUP}; '
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


def add_to_views_group(content: str, file_ref_uuid: str) -> str:
    """Add the file ref to the `Views` PBXGroup children list.

    The Views group is the one whose `path = Views;` and which already
    contains `EnvelopeCurveView.swift` (same on-disk subfolder pattern).
    We insert the new child right after the EnvelopeCurveView entry so
    the Perform/ files sit together.
    """
    group_pattern = re.compile(
        r"(?P<block>/\* Views \*/ = \{\n"
        r"\t\t\tisa = PBXGroup;\n"
        r"\t\t\tchildren = \(\n"
        r"(?P<children>(?:\t\t\t\t[^\n]*\n)*?)"
        r"[ \t]*\);\n"
        r"\t\t\tpath = Views;\n"
        r"\t\t\tsourceTree = \"<group>\";\n"
        r"\t\t\};)",
        re.MULTILINE,
    )
    match = group_pattern.search(content)
    if not match:
        raise RuntimeError("Views PBXGroup block not found")

    child_line = f"\t\t\t\t{file_ref_uuid} /* {FILE_NAME} */,"
    children_block = match.group("children")
    if child_line in children_block:
        return content  # already present

    # Insert immediately after the EnvelopeCurveView child so the two
    # Perform/ files sit together. Fall back to appending at the end of
    # the children block if the anchor isn't found.
    anchor = "/* EnvelopeCurveView.swift */,\n"
    if anchor in children_block:
        new_children = children_block.replace(
            anchor,
            anchor + child_line + "\n",
            1,
        )
    else:
        new_children = children_block + child_line + "\n"

    return content[: match.start("children")] + new_children + content[match.end("children"):]


def add_to_main_sources_phase(content: str, build_uuid: str) -> str:
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
    build_line = f"\t\t\t\t{build_uuid} /* {FILE_NAME} in Sources */,"
    if build_line in block:
        return content
    new_block = block + build_line + "\n"
    return content[: match.start("block")] + new_block + closing + content[match.end():]


def main() -> int:
    if not PBXPROJ.exists():
        print(f"ERROR: pbxproj not found at {PBXPROJ}", file=sys.stderr)
        return 1

    disk_path = PROJECT_DIR / "LatentResonator" / "Views" / "Perform" / FILE_NAME
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
    content = add_to_views_group(content, file_ref_uuid)
    content = add_to_main_sources_phase(content, build_uuid)

    PBXPROJ.write_text(content)
    print(f"  registered: {FILE_NAME}")
    print("done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
