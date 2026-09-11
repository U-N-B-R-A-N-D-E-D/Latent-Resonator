#!/usr/bin/env python3
"""
Register `ParameterRouterController.swift` (P3.13 Slice 4) in the Xcode
project, plus its safety-net test file.

Adds two newly-created files to `project.pbxproj`:
  * `LatentResonator/Graph/ParameterRouterController.swift` -> main
    `LatentResonator` target's Sources build phase + the `Graph` PBXGroup.
  * `LatentResonatorTests/ParameterRouterTests.swift` -> test target's
    Sources build phase + the `LatentResonatorTests` PBXGroup.

Idempotent: re-running is a no-op once both files are registered. A
timestamped backup of `project.pbxproj` is written next to the original
before any edit so the change can be rolled back by hand if needed.

Approach mirrors `scripts/register_macro_mixer_controller.py` (Slice 2):
plain string surgery on the pbxproj, no external deps. That script already
generalizes Slice 1 to handle TWO files across TWO targets/groups in a
single pass; this script is a verbatim copy with the FILES table swapped
to the Slice 4 pair.
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

# Files to register: (file_name, relative_path_from_target_dir, group_name,
# target_kind) where target_kind is "main" or "test".
FILES = [
    {
        "name": "ParameterRouterController.swift",
        "rel_path": "Graph/ParameterRouterController.swift",
        "group": "Graph",
        "target": "main",
    },
    {
        "name": "ParameterRouterTests.swift",
        "rel_path": "ParameterRouterTests.swift",
        "group": "LatentResonatorTests",
        "target": "test",
    },
]

# Anchor files used to locate the correct Sources build phase and the
# correct PBXGroup. The main Sources phase is the one that lists
# NeuralEngine.swift; the test Sources phase is the one that lists
# NeuralEngineTests.swift. The Graph group is anchored by NodeGraph.swift;
# the LatentResonatorTests group is anchored by NeuralEngineTests.swift.
MAIN_SOURCES_ANCHOR = "NeuralEngine.swift in Sources"
TEST_SOURCES_ANCHOR = "NeuralEngineTests.swift in Sources"
GRAPH_GROUP_ANCHOR = "NodeGraph.swift"
TEST_GROUP_ANCHOR = "NeuralEngineTests.swift"


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


def add_file_reference(content: str, file_name: str, file_ref_uuid: str) -> str:
    """Insert a PBXFileReference entry just before `/* End PBXFileReference section */`."""
    entry = (
        f"\t\t{file_ref_uuid} /* {file_name} */ = {{isa = PBXFileReference; "
        f'lastKnownFileType = sourcecode.swift; path = {file_name}; sourceTree = "<group>"; }};'
    )
    marker = "/* End PBXFileReference section */"
    if marker not in content:
        raise RuntimeError("PBXFileReference end marker not found")
    return content.replace(marker, entry + "\n" + marker, 1)


def add_build_file(content: str, file_name: str, build_uuid: str, file_ref_uuid: str) -> str:
    """Insert a PBXBuildFile entry just before `/* End PBXBuildFile section */`."""
    entry = (
        f"\t\t{build_uuid} /* {file_name} in Sources */ = {{isa = PBXBuildFile; "
        f"fileRef = {file_ref_uuid} /* {file_name} */; }};"
    )
    marker = "/* End PBXBuildFile section */"
    if marker not in content:
        raise RuntimeError("PBXBuildFile end marker not found")
    return content.replace(marker, entry + "\n" + marker, 1)


def add_to_group(content: str, file_name: str, file_ref_uuid: str, group_name: str, anchor_file: str) -> str:
    """Add the file ref to the named PBXGroup children list.

    The group is located by finding the `/* <group_name> */ = {` block that
    also contains `/* <anchor_file> */` in its children list (to disambiguate
    groups with similar names). The new child line is appended after the
    anchor file's child line so the placement is deterministic.
    """
    import re

    # Match the whole PBXGroup block for the named group.
    group_pattern = re.compile(
        r"(?P<block>/\* " + re.escape(group_name) + r" \*/ = \{\n"
        r"\t\t\tisa = PBXGroup;\n"
        r"(?:\t\t\t[^\n]*\n)*?"
        r"\t\t\tchildren = \(\n"
        r"(?P<children>(?:\t\t\t\t[^\n]*\n)*?)"
        r"\t\t\t\);)",
        re.MULTILINE,
    )
    matches = list(group_pattern.finditer(content))
    if not matches:
        raise RuntimeError(f"PBXGroup '{group_name}' not found")
    # Pick the instance whose children contain the anchor file.
    target_match = None
    for m in matches:
        if anchor_file in m.group("children"):
            target_match = m
            break
    if target_match is None:
        # Fall back to first match.
        target_match = matches[0]

    child_line = f"\t\t\t\t{file_ref_uuid} /* {file_name} */,"
    children_block = target_match.group("children")
    if child_line in children_block:
        return content  # already present
    new_children = children_block + child_line + "\n"
    return (
        content[: target_match.start("children")]
        + new_children
        + content[target_match.end("children"):]
    )


def add_to_sources_phase(content: str, file_name: str, build_uuid: str, anchor_file: str) -> str:
    """Add the build file to the Sources build phase that contains the anchor file.

    The anchor file is `NeuralEngine.swift in Sources` for the main target and
    `NeuralEngineTests.swift in Sources` for the test target. The new build
    file line is inserted immediately after the anchor's `*/,` token.

    NOTE: the test target's Sources phase in the current pbxproj has a
    malformed line where two build-file entries share a single physical
    line (`NeuralEngineTests.swift in Sources */,<tabs>MaterialityTests...`).
    We therefore match only the anchor token `/* <anchor> \*/,` (without
    requiring a trailing newline) and insert a fresh line after the comma.
    In the malformed case this also has the benign side effect of splitting
    the line into two properly-terminated entries.
    """
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
    # Insert right after the anchor's closing comma.
    return content[: target_match.end()] + "\n" + build_line + content[target_match.end():]


def register_one(content: str, file_info: dict) -> str:
    file_name = file_info["name"]
    if already_registered(content, file_name):
        print(f"  {file_name}: already registered — skipping")
        return content

    file_ref_uuid = generate_uuid()
    build_uuid = generate_uuid()

    content = add_file_reference(content, file_name, file_ref_uuid)
    content = add_build_file(content, file_name, build_uuid, file_ref_uuid)

    # Group registration.
    if file_info["group"] == "Graph":
        content = add_to_group(content, file_name, file_ref_uuid, "Graph", GRAPH_GROUP_ANCHOR)
    elif file_info["group"] == "LatentResonatorTests":
        content = add_to_group(content, file_name, file_ref_uuid, "LatentResonatorTests", TEST_GROUP_ANCHOR)
    else:
        raise RuntimeError(f"Unknown group: {file_info['group']}")

    # Sources phase registration.
    if file_info["target"] == "main":
        content = add_to_sources_phase(content, file_name, build_uuid, MAIN_SOURCES_ANCHOR)
    elif file_info["target"] == "test":
        content = add_to_sources_phase(content, file_name, build_uuid, TEST_SOURCES_ANCHOR)
    else:
        raise RuntimeError(f"Unknown target: {file_info['target']}")

    print(f"  registered: {file_name} (target={file_info['target']}, group={file_info['group']})")
    return content


def main() -> int:
    if not PBXPROJ.exists():
        print(f"ERROR: pbxproj not found at {PBXPROJ}", file=sys.stderr)
        return 1

    # Verify all files exist on disk first.
    for f in FILES:
        disk_path = PROJECT_DIR / "LatentResonator" / f["rel_path"]
        if not disk_path.exists():
            # Test file lives under LatentResonatorTests, not LatentResonator/.
            alt = PROJECT_DIR / "LatentResonatorTests" / f["name"]
            if alt.exists():
                continue
            print(f"ERROR: {f['name']} not found on disk at {disk_path} or {alt}", file=sys.stderr)
            return 1

    content = PBXPROJ.read_text()
    if all(already_registered(content, f["name"]) for f in FILES):
        print("All files already registered in pbxproj — nothing to do.")
        return 0

    print(f"Registering {len(FILES)} file(s) in {PBXPROJ.name} ...")
    backup_project()

    for f in FILES:
        content = register_one(content, f)

    PBXPROJ.write_text(content)
    print("done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
