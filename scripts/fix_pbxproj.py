#!/usr/bin/env python3
"""
Fix project.pbxproj to properly add ImplicitGraphBuilder.swift to build phase.
The Ruby script added the file reference but failed to add the build file entry.
"""

import re
import sys

PBXPROJ_PATH = "/Users/leolambertini/RLTNAS/LatentResonator/LatentResonator.xcodeproj/project.pbxproj"

# The UUID from the file reference
IMPLICIT_GRAPH_BUILDER_FILE_REF = "4F393EFCCBF84376AB4E8486"
IMPLICIT_GRAPH_BUILDER_FILENAME = "ImplicitGraphBuilder.swift"

# Generate new UUIDs for the build file entries
BUILD_FILE_UUID_1 = "A12345678901234567890123"  # For main target

def fix_pbxproj():
    with open(PBXPROJ_PATH, 'r') as f:
        content = f.read()
    
    # Check if already fixed
    if "ImplicitGraphBuilder.swift in Sources" in content:
        print("✅ ImplicitGraphBuilder.swift already in Sources build phase")
        return True
    
    # Check if file reference exists
    if IMPLICIT_GRAPH_BUILDER_FILE_REF not in content:
        print("❌ Error: File reference not found in project.pbxproj")
        return False
    
    # Step 1: Add PBXBuildFile entry before End PBXBuildFile
    build_file_entry = f'''\t\t{BUILD_FILE_UUID_1} /* ImplicitGraphBuilder.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {IMPLICIT_GRAPH_BUILDER_FILE_REF} /* ImplicitGraphBuilder.swift */; }};
'''
    
    # Find the last PBXBuildFile entry and insert after it
    # Pattern to find: /* End PBXBuildFile section */
    build_file_pattern = r'(\t+[A-F0-9]+ /\* .*\.swift in Sources \*/ = \{isa = PBXBuildFile;[^\}]+\};)\n(/\* End PBXBuildFile section \*/)'
    
    match = re.search(build_file_pattern, content)
    if match:
        # Insert the new build file entry before the end comment
        content = content.replace(
            match.group(2),
            build_file_entry + match.group(2)
        )
        print("✅ Added PBXBuildFile entry")
    else:
        print("❌ Could not find PBXBuildFile section end")
        return False
    
    # Step 2: Add to Sources build phase
    # Find the main target's Sources build phase and add the file
    # Look for the main target (first /* Sources */ = {)
    sources_entry = f'''\t\t\t\t{BUILD_FILE_UUID_1} /* ImplicitGraphBuilder.swift in Sources */,
'''
    
    # Find the pattern: main target Sources files = (
    # and insert the new file reference
    main_sources_pattern = r'(089C166500000010 /\* Sources \*/ = \{[^\}]+files = \(\n)(\t+089C166500000030 /\* LatentResonatorApp\.swift in Sources \*/)'
    
    match = re.search(main_sources_pattern, content, re.DOTALL)
    if match:
        # Insert after the files = ( line
        content = content.replace(
            match.group(1) + match.group(2),
            match.group(1) + sources_entry + match.group(2)
        )
        print("✅ Added to main target Sources build phase")
    else:
        print("❌ Could not find main target Sources build phase")
        return False
    
    # Write the fixed content
    with open(PBXPROJ_PATH, 'w') as f:
        f.write(content)
    
    print("✅ project.pbxproj fixed successfully")
    return True

if __name__ == "__main__":
    print("🔧 Fixing project.pbxproj...")
    print()
    
    success = fix_pbxproj()
    sys.exit(0 if success else 1)
