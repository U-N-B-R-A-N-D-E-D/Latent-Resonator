#!/usr/bin/env python3
"""
Register Worker ALPHA deliverables in the LatentResonator.xcodeproj:
  - GestureRecorderCard.swift in the main LatentResonator target
  - SpectralAnalyzerNodeTests.swift in LatentResonatorTests
  - AudioInputNodeTests.swift in LatentResonatorTests
  - MarkovSequencerNodeTests.swift in LatentResonatorTests
  - GestureRecorderNodeTests.swift in LatentResonatorTests

Idempotent: skips files already present in the project.
"""
import re
import shutil
import secrets
import sys
from datetime import datetime

PBXPROJ = "/Users/leolambertini/RLTNAS/LatentResonator/LatentResonator.xcodeproj/project.pbxproj"

# Main target group + sources phase UUIDs.
MAIN_GROUP_UUID = "089C166500000003"   # LatentResonator group
MAIN_SOURCES_UUID = "089C166500000010"  # Sources (main target)
CARDS_GROUP_UUID = "PCH10000000000000000CRD1"  # Views/Patch/Cards group

# Test target group + sources phase UUIDs.
TESTS_GROUP_UUID = "089C166500000069"   # LatentResonatorTests group
TESTS_SOURCES_UUID = "089C166500000064" # Sources (test target)


def new_uuid():
    return secrets.token_hex(12).upper()


# (fileName, fileRefUUID, buildFileUUID, groupUUID, sourcesUUID, path)
FILES = [
    (
        "GestureRecorderCard.swift",
        new_uuid(),
        new_uuid(),
        CARDS_GROUP_UUID,
        MAIN_SOURCES_UUID,
        "Views/Patch/Cards/GestureRecorderCard.swift",
    ),
    (
        "SpectralAnalyzerNodeTests.swift",
        new_uuid(),
        new_uuid(),
        TESTS_GROUP_UUID,
        TESTS_SOURCES_UUID,
        "SpectralAnalyzerNodeTests.swift",
    ),
    (
        "AudioInputNodeTests.swift",
        new_uuid(),
        new_uuid(),
        TESTS_GROUP_UUID,
        TESTS_SOURCES_UUID,
        "AudioInputNodeTests.swift",
    ),
    (
        "MarkovSequencerNodeTests.swift",
        new_uuid(),
        new_uuid(),
        TESTS_GROUP_UUID,
        TESTS_SOURCES_UUID,
        "MarkovSequencerNodeTests.swift",
    ),
    (
        "GestureRecorderNodeTests.swift",
        new_uuid(),
        new_uuid(),
        TESTS_GROUP_UUID,
        TESTS_SOURCES_UUID,
        "GestureRecorderNodeTests.swift",
    ),
]


def main():
    with open(PBXPROJ, "r") as f:
        content = f.read()

    already = [name for name, _, _, _, _, _ in FILES if name in content]
    if already:
        print("⚠️  Already present, skipping:", ", ".join(already))
    todo = [entry for entry in FILES if entry[0] not in content]
    if not todo:
        print("✅ Nothing to do.")
        return 0

    bak = PBXPROJ + ".backup_worker_alpha_" + datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy(PBXPROJ, bak)
    print("📦 Backup:", bak)

    # 1. PBXBuildFile entries.
    build_entries = "\n".join(
        f"\t\t{bf} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {name} */; }};"
        for name, fr, bf, _, _, _ in todo
    )
    content = re.sub(
        r"(/\* End PBXBuildFile section \*/)",
        build_entries + "\n" + r"\1",
        content,
        count=1,
    )

    # 2. PBXFileReference entries.
    fileref_entries = "\n".join(
        f'\t\t{fr} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};'
        if group == TESTS_GROUP_UUID
        else f'\t\t{fr} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{path}"; sourceTree = "<group>"; }};'
        for name, fr, _, group, _, path in todo
    )
    content = re.sub(
        r"(/\* End PBXFileReference section \*/)",
        fileref_entries + "\n" + r"\1",
        content,
        count=1,
    )

    # 3. Add to the correct group children lists.
    for name, fr, _, group_uuid, _, _ in todo:
        group_children = f"\n\t\t\t\t{fr} /* {name} */,"
        group_pattern = re.compile(
            r"(" + re.escape(group_uuid) + r" /\* [^\*]+ \*/ = \{\n"
            r"\t\t\tisa = PBXGroup;\n"
            r"\t\t\tchildren = \([^)]*?)(\n\t\t\t\);)",
            re.DOTALL,
        )
        if not group_pattern.search(content):
            print(f"❌ Could not locate group children list for {name}")
            return 1
        content = group_pattern.sub(r"\1" + group_children + r"\2", content, count=1)

    # 4. Add to the correct Sources build phase files list.
    for name, _, bf, _, sources_uuid, _ in todo:
        sources_entries = f"\n\t\t\t\t{bf} /* {name} in Sources */,"
        sources_pattern = re.compile(
            r"(" + re.escape(sources_uuid) + r" /\* Sources \*/ = \{\n"
            r"\t\t\tisa = PBXSourcesBuildPhase;\n"
            r"\t\t\tbuildActionMask = 2147483647;\n"
            r"\t\t\tfiles = \([^)]*?)(\n\t\t\t\);)",
            re.DOTALL,
        )
        if not sources_pattern.search(content):
            print(f"❌ Could not locate Sources build phase for {name}")
            return 1
        content = sources_pattern.sub(r"\1" + sources_entries + r"\2", content, count=1)

    with open(PBXPROJ, "w") as f:
        f.write(content)

    print("✅ Registered", ", ".join(n for n, _, _, _, _, _ in todo))
    return 0


if __name__ == "__main__":
    sys.exit(main())
