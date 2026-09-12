#!/usr/bin/env python3
"""
Register GraphNodeParamTests.swift in the LatentResonatorTests target of
LatentResonator.xcodeproj. Idempotent: skips if the file is already present.

Adds:
  - GraphNodeParamTests.swift

Worker S7 — Programmer P2 #5 + P1 #2 pin. Touches only project.pbxproj
(backed up to a timestamped sibling before mutation).
"""
import re
import shutil
import sys
from datetime import datetime

PBXPROJ = "/Users/leolambertini/RLTNAS/LatentResonator/LatentResonator.xcodeproj/project.pbxproj"

# (fileName, fileRefUUID, buildFileUUID)
FILES = [
    ("GraphNodeParamTests.swift", "GNP0000000000001FR00001", "GNP0000000000BF1R00001"),
]

# Group + Sources build phase UUIDs for the LatentResonatorTests target.
TESTS_GROUP_UUID   = "089C166500000069"  # LatentResonatorTests group
TESTS_SOURCES_UUID = "089C166500000064"  # Sources (test target)


def main():
    with open(PBXPROJ, "r") as f:
        content = f.read()

    already = [name for name, _, _ in FILES if name in content]
    if already:
        print("⚠️  Already present, skipping:", ", ".join(already))
    todo = [(n, fr, bf) for n, fr, bf in FILES if n not in content]
    if not todo:
        print("✅ Nothing to do.")
        return 0

    # Timestamped backup.
    bak = PBXPROJ + ".backup_graphnode_param_tests_" + datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy(PBXPROJ, bak)
    print("📦 Backup:", bak)

    # 1. PBXBuildFile entries (before /* End PBXBuildFile section */).
    build_entries = "\n".join(
        f"\t\t{bf} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {name} */; }};"
        for name, fr, bf in todo
    )
    content = re.sub(
        r"(/\* End PBXBuildFile section \*/)",
        build_entries + "\n" + r"\1",
        content,
        count=1,
    )

    # 2. PBXFileReference entries (before /* End PBXFileReference section */).
    fileref_entries = "\n".join(
        f"\t\t{fr} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};"
        for name, fr, bf in todo
    )
    content = re.sub(
        r"(/\* End PBXFileReference section \*/)",
        fileref_entries + "\n" + r"\1",
        content,
        count=1,
    )

    # 3. Add to LatentResonatorTests group children.
    group_children = "\n".join(
        f"\t\t\t\t{fr} /* {name} */," for name, fr, bf in todo
    )
    group_pattern = re.compile(
        r"(" + re.escape(TESTS_GROUP_UUID) + r" /\* LatentResonatorTests \*/ = \{\n"
        r"\t\t\tisa = PBXGroup;\n"
        r"\t\t\tchildren = \([^)]*?)(\n\t\t\t\);)",
        re.DOTALL,
    )
    if not group_pattern.search(content):
        print("❌ Could not locate LatentResonatorTests group children list")
        return 1
    content = group_pattern.sub(r"\1" + group_children + r"\2", content)

    # 4. Add to the test target's Sources build phase files list.
    sources_entries = "\n".join(
        f"\t\t\t\t{bf} /* {name} in Sources */," for name, fr, bf in todo
    )
    sources_pattern = re.compile(
        r"(" + re.escape(TESTS_SOURCES_UUID) + r" /\* Sources \*/ = \{\n"
        r"\t\t\tisa = PBXSourcesBuildPhase;\n"
        r"\t\t\tbuildActionMask = 2147483647;\n"
        r"\t\t\tfiles = \([^)]*?)(\n\t\t\t\);)",
        re.DOTALL,
    )
    if not sources_pattern.search(content):
        print("❌ Could not locate LatentResonatorTests Sources files list")
        return 1
    content = sources_pattern.sub(r"\1" + sources_entries + r"\2", content)

    with open(PBXPROJ, "w") as f:
        f.write(content)
    print("✅ Registered", ", ".join(n for n, _, _ in todo),
          "in LatentResonatorTests target")
    return 0


if __name__ == "__main__":
    sys.exit(main())
