#!/usr/bin/env python3
"""
Register the three P3.13 safety-net test files in the LatentResonatorTests
target of LatentResonator.xcodeproj. Idempotent: skips files already present.

Adds:
  - MaterialityTests.swift
  - ApplyMacroStepLocksTests.swift
  - SpectralPipelineOverlapAddTests.swift
"""
import re
import shutil
import sys
from datetime import datetime

PBXPROJ = "/Users/leolambertini/RLTNAS/LatentResonator/LatentResonator.xcodeproj/project.pbxproj"

# (fileName, fileRefUUID, buildFileUUID)
FILES = [
    ("MaterialityTests.swift",              "P313000000000001MAT00001", "P3130000000000BFMAT00001"),
    ("ApplyMacroStepLocksTests.swift",       "P313000000000002AML00001", "P3130000000000BFAML00001"),
    ("SpectralPipelineOverlapAddTests.swift","P313000000000003SPO00001", "P3130000000000BFSPO00001"),
]

# Group + Sources build phase UUIDs for the LatentResonatorTests target.
TESTS_GROUP_UUID  = "089C166500000069"  # LatentResonatorTests group
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

    # Backup
    bak = PBXPROJ + ".backup_p313_" + datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy(PBXPROJ, bak)
    print("📦 Backup:", bak)

    # 1. PBXBuildFile entries (before /* End PBXBuildFile section */)
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

    # 2. PBXFileReference entries (before /* End PBXFileReference section */)
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
    # The group block starts with the group UUID and contains a `children = (`
    # list ending with `);`. We insert before that closing.
    # NOTE: prepend a leading "\n" so the first appended child is separated
    # from the last existing child by a newline, not jammed onto its line.
    group_children = "\n".join(
        f"\t\t\t\t{fr} /* {name} */," for name, fr, bf in todo
    )
    group_children = "\n" + group_children
    # Match the LatentResonatorTests group block specifically.
    group_pattern = re.compile(
        r"(" + re.escape(TESTS_GROUP_UUID) + r" /\* LatentResonatorTests \*/ = \{\n"
        r"\t\t\tisa = PBXGroup;\n"
        r"\t\t\tchildren = \([^)]*?)(\n\t\t\t\);)",
        re.DOTALL,
    )
    if not group_pattern.search(content):
        print("❌ Could not locate LatentResonatorTests group children list"); return 1
    content = group_pattern.sub(r"\1" + group_children + r"\2", content)

    # 4. Add to the test target's Sources build phase files list.
    # NOTE: prepend a leading "\n" so the first appended build file is
    # separated from the last existing entry by a newline, not jammed onto
    # its line (this was the root cause of the pbxproj malformation).
    sources_entries = "\n".join(
        f"\t\t\t\t{bf} /* {name} in Sources */," for name, fr, bf in todo
    )
    sources_entries = "\n" + sources_entries
    # The test Sources phase is the second /* Sources */ block; identify it
    # by its UUID header.
    sources_pattern = re.compile(
        r"(" + re.escape(TESTS_SOURCES_UUID) + r" /\* Sources \*/ = \{\n"
        r"\t\t\tisa = PBXSourcesBuildPhase;\n"
        r"\t\t\tbuildActionMask = 2147483647;\n"
        r"\t\t\tfiles = \([^)]*?)(\n\t\t\t\);)",
        re.DOTALL,
    )
    if not sources_pattern.search(content):
        print("❌ Could not locate LatentResonatorTests Sources files list"); return 1
    content = sources_pattern.sub(r"\1" + sources_entries + r"\2", content)

    with open(PBXPROJ, "w") as f:
        f.write(content)
    print("✅ Registered", ", ".join(n for n, _, _ in todo), "in LatentResonatorTests target")
    return 0

if __name__ == "__main__":
    sys.exit(main())
