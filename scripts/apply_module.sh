#!/usr/bin/env bash
# apply_module.sh -- graft the Latent Resonator module onto a Bespoke Synth
# source tree. Idempotent: safe to run repeatedly.
#
# Usage: scripts/apply_module.sh <bespoke_source_dir>
#
# What it does:
#   1. copies ModuleACEResonator.{h,cpp} into <dir>/Source/
#   2. adds the #include and REGISTER(...) line to Source/ModuleFactory.cpp
#   3. adds both filenames to target_sources in Source/CMakeLists.txt
#   4. applies bespoke-migration/patches/*.patch to libs/JUCE (if not applied)
set -euo pipefail

if [ $# -ne 1 ] || [ ! -d "$1" ]; then
    echo "usage: $0 <bespoke_source_dir>" >&2
    exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$(cd "$1" && pwd)"
MODULE_DIR="$REPO_ROOT/bespoke-migration/module"
PATCH_DIR="$REPO_ROOT/bespoke-migration/patches"

FACTORY="$TARGET/Source/ModuleFactory.cpp"
CMAKE="$TARGET/Source/CMakeLists.txt"
INCLUDE_LINE='#include "ModuleACEResonator.h"'
REGISTER_LINE='   REGISTER(ModuleACEResonator, latentresonator, kModuleCategory_Synth);'

for f in "$FACTORY" "$CMAKE" "$MODULE_DIR/ModuleACEResonator.h" "$MODULE_DIR/ModuleACEResonator.cpp"; do
    if [ ! -f "$f" ]; then
        echo "error: missing $f" >&2
        exit 1
    fi
done

# 1. copy sources (cp is idempotent; only report when content changes)
for f in ModuleACEResonator.h ModuleACEResonator.cpp; do
    if [ -f "$TARGET/Source/$f" ] && cmp -s "$MODULE_DIR/$f" "$TARGET/Source/$f"; then
        echo "ok: Source/$f up to date"
    else
        cp "$MODULE_DIR/$f" "$TARGET/Source/$f"
        echo "copied: Source/$f"
    fi
done

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# 2a. include in ModuleFactory.cpp (after the last local #include "...")
if grep -qF "$INCLUDE_LINE" "$FACTORY"; then
    echo "ok: include already present"
else
    awk -v inc="$INCLUDE_LINE" '
        { lines[NR]=$0; if ($0 ~ /^#include "/) last=NR }
        END { for (i=1;i<=NR;i++) { print lines[i]; if (i==last) print inc } }' "$FACTORY" > "$tmp"
    cat "$tmp" > "$FACTORY"
    echo "added: include"
fi

# 2b. REGISTER line (after the last active REGISTER(...) line)
if grep -qE '^[[:space:]]*REGISTER\(ModuleACEResonator,' "$FACTORY"; then
    echo "ok: REGISTER already present"
else
    awk -v reg="$REGISTER_LINE" '
        { lines[NR]=$0; if ($0 ~ /^[ \t]*REGISTER\(/) last=NR }
        END {
            if (!last) exit 3
            for (i=1;i<=NR;i++) { print lines[i]; if (i==last) print reg }
        }' "$FACTORY" > "$tmp" || { echo "error: no REGISTER( anchor in ModuleFactory.cpp" >&2; exit 1; }
    cat "$tmp" > "$FACTORY"
    echo "added: REGISTER"
fi

# 3. CMake target_sources (insert before ModuleContainer.cpp to keep alphabetical order)
if grep -qE '^[[:space:]]*ModuleACEResonator\.cpp' "$CMAKE"; then
    echo "ok: CMake sources already present"
else
    if ! grep -qE '^[[:space:]]*ModuleContainer\.cpp' "$CMAKE"; then
        echo "error: anchor ModuleContainer.cpp not found in Source/CMakeLists.txt" >&2
        exit 1
    fi
    awk '
        !done && /^[ \t]*ModuleContainer\.cpp/ {
            print "    ModuleACEResonator.cpp"
            print "    ModuleACEResonator.h"
            done=1
        }
        { print }' "$CMAKE" > "$tmp"
    cat "$tmp" > "$CMAKE"
    echo "added: CMake sources"
fi

# 4. JUCE patches
JUCE_DIR="$TARGET/libs/JUCE"
for p in "$PATCH_DIR"/*.patch; do
    [ -f "$p" ] || continue
    name="$(basename "$p")"
    if [ ! -d "$JUCE_DIR/modules" ]; then
        echo "error: $JUCE_DIR is empty; run 'git submodule update --init --recursive' first" >&2
        exit 1
    fi
    if git -C "$JUCE_DIR" apply --reverse --check "$p" >/dev/null 2>&1; then
        echo "ok: patch already applied: $name"
    elif git -C "$JUCE_DIR" apply --check "$p" >/dev/null 2>&1; then
        git -C "$JUCE_DIR" apply "$p"
        echo "applied: $name"
    else
        echo "error: patch $name neither applies nor is already applied (JUCE version drift?)" >&2
        exit 1
    fi
done

echo "done."
