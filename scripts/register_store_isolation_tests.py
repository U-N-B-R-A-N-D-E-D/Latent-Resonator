#!/usr/bin/env python3
"""
Register StoreIsolationTests.swift in the LatentResonatorTests target.
Idempotent: skips if already present.
"""
import re
import shutil
import sys
from datetime import datetime

PBXPROJ = "/Users/leolambertini/RLTNAS/LatentResonator/LatentResonator.xcodeproj/project.pbxproj"

FILES = [
    ("StoreIsolationTests.swift", "SI000000000000001SI000001", "BF000000000000001SI000001"),
]

TESTS_GROUP_UUID  = "089C166500000069"  # LatentResonatorTests group
TESTS_SOURCES_UUID = "089C166500000064"  # Sources (test target)


def main():
    with open(PBXPROJ, "r") as f:
        content = f.read()

    already = [name for name, _, _ in FILES if name in content]
    if already:
        print("⚠️  Already present, skipping:", ", ".join(already))
        return 0

    bak = PBXPROJ + ".backup_si_" + datetime.now().strftime("Y%m%d_%H%M%S")
    shutil.copy(PBXPROJ, bak)
    print("📦 Backup:", bak)

    build_entries = "\n".join(
        f"\t\t{bf} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {name} */; }};"
        for name, fr, bf in FILES
    )
    content = re.sub(
        r"(/\* End PBXBuildFile section \*/)",
        build_entries + "\n" + r"\1",
        content,
        count=1,
    )

    fileref_entries = "\n".join(
        f"\t\t{fr} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};"
        for name, fr, bf in FILES
    )
    content = re.sub(
        r"(/\* End PBXFileReference section \*/)",
        fileref_entries + "\n" + r"\1",
        content,
        count=1,
    )

    group_children = "\n".join(
        f"\t\t\t\t{fr} /* {name} */," for name, fr, bf in FILES
    )
    group_children = "\n" + group_children
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

    sources_entries = "\n".join(
        f"\t\t\t\t{bf} /* {name} in Sources */," for name, fr, bf in FILES
    )
    sources_entries = "\n" + sources_entries
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
    print("✅ Registered", ", ".join(n for n, _, _ in FILES), "in LatentResonatorTests target")
    return 0


if __name__ == "__main__":
    sys.exit(main())
