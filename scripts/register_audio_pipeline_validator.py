#!/usr/bin/env python3
"""
Register `AudioPipelineValidator.swift` (main target, Graph group) and
`AudioPipelineValidatorTests.swift` (test target) in the Xcode project.

P3.13 surgical slice 5 (FINAL) — adds the two newly-created files of the
audio-engine-lifecycle extraction to:

  Main target (LatentResonator):
    * PBXFileReference section
    * PBXBuildFile section
    * `Graph` PBXGroup children list
    * Main `LatentResonator` target's Sources build phase (the one that
      already lists `NeuralEngine.swift in Sources`)

  Test target (LatentResonatorTests):
    * PBXFileReference section
    * PBXBuildFile section
    * `LatentResonatorTests` PBXGroup children list
    * Test target's Sources build phase (UUID 089C166500000064)

Idempotent: re-running it is a no-op once a file is registered. A
timestamped backup of `project.pbxproj` is written next to the original
before any edit so the change can be rolled back by hand if needed.

Approach mirrors `scripts/register_macro_lock_controller.py` (plain
string surgery on the pbxproj, no external deps) but registers TWO files
across TWO targets in a single pass.
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

# Test target UUIDs (same as scripts/register_p313_tests.py).
TESTS_GROUP_UUID = "089C166500000069"   # LatentResonatorTests group
TESTS_SOURCES_UUID = "089C166500000064"  # Sources (test target)

# (fileName, relativePathFromTargetDir, group, target) where target is
# "main" or "tests".
FILES = [
    (
        "AudioPipelineValidator.swift",
        "Graph/AudioPipelineValidator.swift",
        "Graph",
        "main",
    ),
    (
        "AudioPipelineValidatorTests.swift",
        "AudioPipelineValidatorTests.swift",
        "LatentResonatorTests",
        "tests",
    ),
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


def add_file_reference(content: str, file_name: str, file_ref_uuid: str) -> str:
    """Insert a PBXFileReference entry just before the section end marker."""
    entry = (
        f"\t\t{file_ref_uuid} /* {file_name} */ = {{isa = PBXFileReference; "
        f'lastKnownFileType = sourcecode.swift; path = {file_name}; sourceTree = "<group>"; }};'
    )
    marker = "/* End PBXFileReference section */"
    if marker not in content:
        raise RuntimeError("PBXFileReference end marker not found")
    return content.replace(marker, entry + "\n" + marker, 1)


def add_build_file(content: str, file_name: str, build_uuid: str, file_ref_uuid: str) -> str:
    """Insert a PBXBuildFile entry just before the section end marker."""
    entry = (
        f"\t\t{build_uuid} /* {file_name} in Sources */ = {{isa = PBXBuildFile; "
        f"fileRef = {file_ref_uuid} /* {file_name} */; }};"
    )
    marker = "/* End PBXBuildFile section */"
    if marker not in content:
        raise RuntimeError("PBXBuildFile end marker not found")
    return content.replace(marker, entry + "\n" + marker, 1)


def add_to_graph_group(content: str, file_name: str, file_ref_uuid: str) -> str:
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
        return content
    new_children = children_block + child_line + "\n"
    return content[: match.start("children")] + new_children + content[match.end("children"):]


def add_to_tests_group(content: str, file_name: str, file_ref_uuid: str) -> str:
    """Add the file ref to the `LatentResonatorTests` PBXGroup children list."""
    group_pattern = re.compile(
        r"(" + re.escape(TESTS_GROUP_UUID) + r" /\* LatentResonatorTests \*/ = \{\n"
        r"\t\t\tisa = PBXGroup;\n"
        r"\t\t\tchildren = \([^)]*?)(\n\t\t\t\);)",
        re.DOTALL,
    )
    match = group_pattern.search(content)
    if not match:
        raise RuntimeError("LatentResonatorTests PBXGroup block not found")
    child_line = f"\t\t\t\t{file_ref_uuid} /* {file_name} */,"
    children_block = match.group(1)
    if child_line in children_block:
        return content
    new_children = children_block + child_line + "\n"
    return content[: match.start(1)] + new_children + content[match.end(1):]


def add_to_main_sources_phase(content: str, file_name: str, build_uuid: str) -> str:
    """Add the build file to the main `LatentResonator` target's Sources phase.

    The main Sources phase is the one that lists `NeuralEngine.swift in Sources`.
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


def add_to_tests_sources_phase(content: str, file_name: str, build_uuid: str) -> str:
    """Add the build file to the LatentResonatorTests target's Sources phase."""
    sources_pattern = re.compile(
        r"(" + re.escape(TESTS_SOURCES_UUID) + r" /\* Sources \*/ = \{\n"
        r"\t\t\tisa = PBXSourcesBuildPhase;\n"
        r"\t\t\tbuildActionMask = 2147483647;\n"
        r"\t\t\tfiles = \([^)]*?)(\n\t\t\t\);)",
        re.DOTALL,
    )
    match = sources_pattern.search(content)
    if not match:
        raise RuntimeError("LatentResonatorTests Sources build phase not found")
    files_block = match.group(1)
    build_line = f"\t\t\t\t{build_uuid} /* {file_name} in Sources */,"
    if build_line in files_block:
        return content
    new_block = files_block + build_line + "\n"
    return content[: match.start(1)] + new_block + content[match.end(1):]


def main() -> int:
    if not PBXPROJ.exists():
        print(f"ERROR: pbxproj not found at {PBXPROJ}", file=sys.stderr)
        return 1

    # Verify both source files exist on disk before touching pbxproj.
    for file_name, rel_path, _group, _target in FILES:
        disk_path = PROJECT_DIR / "LatentResonator" / rel_path
        if not disk_path.exists():
            # The test file lives under LatentResonatorTests/, not LatentResonator/.
            if _target == "tests":
                disk_path = PROJECT_DIR / "LatentResonatorTests" / file_name
            if not disk_path.exists():
                print(f"ERROR: {file_name} not found on disk at {disk_path}", file=sys.stderr)
                return 1

    content = PBXPROJ.read_text()

    todo = []
    for file_name, rel_path, group, target in FILES:
        if already_registered(content, file_name):
            print(f"{file_name} already registered in pbxproj — skipping.")
        else:
            todo.append((file_name, rel_path, group, target))

    if not todo:
        print("Nothing to do.")
        return 0

    print(f"Registering {len(todo)} file(s) in {PBXPROJ.name} ...")
    backup_project()

    for file_name, _rel_path, _group, target in todo:
        file_ref_uuid = generate_uuid()
        build_uuid = generate_uuid()

        content = add_file_reference(content, file_name, file_ref_uuid)
        content = add_build_file(content, file_name, build_uuid, file_ref_uuid)

        if target == "main":
            content = add_to_graph_group(content, file_name, file_ref_uuid)
            content = add_to_main_sources_phase(content, file_name, build_uuid)
        else:
            content = add_to_tests_group(content, file_name, file_ref_uuid)
            content = add_to_tests_sources_phase(content, file_name, build_uuid)

    PBXPROJ.write_text(content)
    for file_name, _rel, _group, target in todo:
        print(f"  registered: {file_name} ({target} target)")
    print("done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
