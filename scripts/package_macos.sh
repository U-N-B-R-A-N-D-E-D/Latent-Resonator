#!/usr/bin/env bash
# package_macos.sh -- assemble dist/LatentResonator-<version>-macOS-arm64.zip
# from an already built BespokeSynth.app (fork with the latentresonator module).
#
# Usage:
#   scripts/package_macos.sh [path/to/BespokeSynth.app]
#   APP=/path/to/BespokeSynth.app scripts/package_macos.sh
#   BUILD_DIR=/path/to/cmake/build scripts/package_macos.sh   # app is searched for
#
# Environment (all optional):
#   APP         path to BespokeSynth.app (overridden by the first argument)
#   BUILD_DIR   CMake build dir to search for BespokeSynth.app
#   VERSION     overrides the VERSION file / git describe
#   REPO_URL    public URL of this repository (default: git remote origin)
#   OUT_DIR     output directory (default: <repo>/dist)
#
# The zip never contains model weights, a Python venv or __pycache__.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_SRC="$REPO_ROOT/bespoke-migration/ace-bridge"
MODULE_SRC="$REPO_ROOT/bespoke-migration/module"
PATCH_DIR="$REPO_ROOT/bespoke-migration/patches"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/dist}"

die() { echo "error: $*" >&2; exit 1; }

# --- locate the app ---------------------------------------------------------
APP_PATH="${1:-${APP:-}}"
if [ -z "$APP_PATH" ] && [ -n "${BUILD_DIR:-}" ]; then
    [ -d "$BUILD_DIR" ] || die "BUILD_DIR does not exist: $BUILD_DIR"
    APP_PATH="$(find "$BUILD_DIR" -type d -name BespokeSynth.app -prune | head -n 1)"
fi
[ -n "$APP_PATH" ] || die "no app given: pass a path, or set APP or BUILD_DIR"
[ -d "$APP_PATH" ] || die "app not found: $APP_PATH"
APP_PATH="$(cd "$APP_PATH" && pwd)"
APP_EXE="$APP_PATH/Contents/MacOS/BespokeSynth"
[ -x "$APP_EXE" ] || die "not a built app (missing Contents/MacOS/BespokeSynth): $APP_PATH"

if command -v lipo >/dev/null 2>&1; then
    archs="$(lipo -archs "$APP_EXE" 2>/dev/null || true)"
    case "$archs" in
        *arm64*) ;;
        *) echo "warning: executable archs '$archs' do not include arm64" >&2 ;;
    esac
fi

# --- version ----------------------------------------------------------------
if [ -z "${VERSION:-}" ]; then
    if [ -f "$REPO_ROOT/VERSION" ]; then
        VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"
    else
        VERSION="$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null || true)"
    fi
fi
VERSION="${VERSION#v}"
[ -n "$VERSION" ] || VERSION="0.0.0-unknown"

# --- provenance -------------------------------------------------------------
REPO_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
if [ -z "${REPO_URL:-}" ]; then
    REPO_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
fi
# strip any credentials embedded in the URL (https://user:token@host/...)
REPO_URL="$(printf '%s' "$REPO_URL" | sed -E 's#^(https?://)[^/@]*@#\1#')"
[ -n "$REPO_URL" ] || REPO_URL="<REPOSITORY URL - set REPO_URL when packaging>"

BESPOKE_REPO="https://github.com/BespokeSynth/BespokeSynth"
BESPOKE_COMMIT="unknown"
JUCE_COMMIT="unknown"
if [ -f "$PATCH_DIR/BESPOKE_BASE.txt" ]; then
    # shellcheck disable=SC1091
    . "$PATCH_DIR/BESPOKE_BASE.txt"
fi

# --- stage ------------------------------------------------------------------
NAME="LatentResonator-${VERSION}-macOS-arm64"
STAGE_ROOT="$OUT_DIR/.stage"
STAGE="$STAGE_ROOT/$NAME"
ZIP="$OUT_DIR/$NAME.zip"

rm -rf "$STAGE_ROOT"
mkdir -p "$STAGE/ace-bridge" "$STAGE/models" "$STAGE/licenses"

echo "copying app..."
ditto "$APP_PATH" "$STAGE/BespokeSynth.app"

echo "copying bridge..."
for f in ace_bridge_server.py requirements_bridge.txt setup_ace_bridge.sh README.md; do
    [ -f "$BRIDGE_SRC/$f" ] || die "missing bridge file: $BRIDGE_SRC/$f"
    cp "$BRIDGE_SRC/$f" "$STAGE/ace-bridge/$f"
done
chmod +x "$STAGE/ace-bridge/setup_ace_bridge.sh"

# example patches, if any (tolerate absence)
n_examples=0
for d in "$REPO_ROOT/examples" "$REPO_ROOT/bespoke-migration/examples" "$PATCH_DIR"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.bsk "$d"/*.json; do
        [ -f "$f" ] || continue
        mkdir -p "$STAGE/examples"
        cp "$f" "$STAGE/examples/"
        n_examples=$((n_examples + 1))
    done
done
echo "example patches: $n_examples"

# licenses
cp "$REPO_ROOT/LICENSE" "$STAGE/licenses/LICENSE-repository"
[ -f "$MODULE_SRC/LICENSE" ] && cp "$MODULE_SRC/LICENSE" "$STAGE/licenses/LICENSE-module-GPL-3.0"
[ -f "$REPO_ROOT/NOTICE" ] && cp "$REPO_ROOT/NOTICE" "$STAGE/licenses/NOTICE"
cp "$REPO_ROOT/LICENSE" "$STAGE/LICENSE"
[ -f "$REPO_ROOT/NOTICE" ] && cp "$REPO_ROOT/NOTICE" "$STAGE/NOTICE"

# strip anything that must never ship
find "$STAGE" -name __pycache__ -type d -prune -exec rm -rf {} +
find "$STAGE" -name '*.pyc' -type f -delete
find "$STAGE" -name '.venv*' -type d -prune -exec rm -rf {} +
find "$STAGE" -name '.DS_Store' -type f -delete

cat > "$STAGE/models/README.txt" <<'EOF'
Model weights are NOT included in this download (about 7.7 GB, separate licence).

The module looks for the ACE-Step v1 3.5B checkpoint in:

    models/ace-step/        (next to BespokeSynth.app, i.e. in this folder)

If the LATENT_RESONATOR_MODEL_PATH environment variable is set, it wins.

How to get the weights:

  1. Run  cd ace-bridge && ./setup_ace_bridge.sh --with-model
     It creates models/ace-step/ and starts the bridge, which downloads the
     checkpoint into that folder the first time it loads the model.

  2. Or point the module at a checkpoint folder you already have (edit its
     "model path" field, or set LATENT_RESONATOR_MODEL_PATH).

Without weights the bridge runs in passthrough mode: audio flows, but no
neural processing happens (the module status says so).

The weights are distributed under their own licence; see NOTICE.
EOF

cat > "$STAGE/QUICKSTART.txt" <<'EOF'
Latent Resonator @VERSION@ -- macOS (Apple Silicon, arm64)
==========================================================

What this is: a build of Bespoke Synth (GPL-3) with an extra module,
"latentresonator", that sends audio to a local Python bridge running
ACE-Step v1 3.5B and plays the regenerated result back into the patch.

Requirements: Apple Silicon Mac, macOS 14+, Python 3.12
(brew install python@3.12), ~16 GB free disk, internet for the first setup.

Steps
-----
0. Unzip. If macOS says the app is "damaged" or from an unidentified
   developer (this build is only ad-hoc signed, not notarized), run once:

       xattr -cr BespokeSynth.app

   then open it with right-click -> Open the first time.

1. Create the Python environment and fetch the weights (Terminal):

       cd ace-bridge
       ./setup_ace_bridge.sh --with-model

   This creates ace-bridge/.venv-ace-bridge (Python 3.12), installs the
   dependencies, creates models/ace-step/ and starts the bridge, which then
   downloads the ~7.7 GB checkpoint into that folder (see models/README.txt).
   When the log says the model is ready, stop it with Ctrl+C: the module
   starts its own bridge, so leaving this one running would occupy the port.

2. Optional: load the ready-made example patch.
   Copy it into Bespoke's data folder:

       mkdir -p ~/Documents/BespokeSynth/layouts
       cp examples/latent_resonator_demo.json ~/Documents/BespokeSynth/layouts/

   then set  "layout" : "layouts/latent_resonator_demo.json"  in
   ~/Documents/BespokeSynth/userprefs.json (created on Bespoke's first run;
   open the app once first) and restart the app. The patch wires a signal
   generator into latentresonator, then gain, splitter and both outputs, plus
   a "regenerate" pulse button.

   Or build it by hand: add "signalgenerator", "latentresonator" and "gain"
   from the menus, drag cables between them, and connect gain to the outputs.

3. Open BespokeSynth.app. The module launches the bridge itself and loads
   the weights (about a minute the first time). Its status line reads
   "bridge unreachable" until then; when ready it shows the model and dtype.

4. Make sound: on the "source" signal generator raise "vol" (it starts at
   0). With "dry monitor" at 0.5 you should hear the tone right away.
   Click "regenerate" on latentresonator (or the "regenerate" pulse button):
   a progress bar runs, then the regenerated take plays, looped. Use
   "out gain dB" if it is quiet (normalisation targets about -3 dBFS).
   "iterate" feeds each take back as the next input.

Honest limits
-------------
- Inference is not real time. A take takes seconds (about 1-8 s for 3-30 s of
  audio in our tests on a 32 GB Apple Silicon Mac); it never runs at audio
  rate and cannot be played live.
- The very first run is slow (weights download, model load and warm-up).
- The model is about 14 GB in float32 and the bridge runs it in float16;
  16 GB of unified memory or more is advised.
- The output is largely regenerated: it does not preserve the input's waveform.
- Weights are not bundled and are subject to their own licence.
- Not notarized; ad-hoc signed. Only tested on Apple Silicon.
- The GUI of this build was checked only by loading the example patch;
  playback and the regenerate workflow were not exercised by hand.

Licence and source: see SOURCE.txt, LICENSE and NOTICE. This program is free
software (GPL-3.0-or-later) and comes with NO WARRANTY.
EOF
sed -i '' "s/@VERSION@/$VERSION/g" "$STAGE/QUICKSTART.txt"

cat > "$STAGE/SOURCE.txt" <<EOF
Latent Resonator $VERSION -- corresponding source (GPL-3.0-or-later)
==================================================================

This binary is a build of Bespoke Synth (GPL-3.0-or-later) plus the
Latent Resonator module and two small compatibility changes. In accordance
with GPL-3 sections 6(b)/6(d), the complete corresponding source is
available to anyone who has this binary, for at least three years after
you received it, at no charge beyond the cost of the transfer.

1. This project (module, bridge, packaging scripts, patches)
     $REPO_URL
     commit $REPO_COMMIT

2. Upstream Bespoke Synth (unmodified base)
     $BESPOKE_REPO
     commit $BESPOKE_COMMIT
     JUCE submodule (libs/JUCE) commit $JUCE_COMMIT

3. To reproduce this build:
     git clone --recursive $BESPOKE_REPO bespoke && cd bespoke
     git checkout $BESPOKE_COMMIT && git submodule update --init --recursive
     <this project>/scripts/apply_module.sh .
     cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64
     cmake --build build --config Release
     <this project>/scripts/package_macos.sh

If the URLs above are unreachable, request the source by opening an issue
on the repository or contacting the distributor you received this from.
EOF

# --- ad-hoc sign ------------------------------------------------------------
echo "ad-hoc signing..."
xattr -cr "$STAGE/BespokeSynth.app" 2>/dev/null || true
codesign --force --deep -s - "$STAGE/BespokeSynth.app"
codesign --verify --deep "$STAGE/BespokeSynth.app" || die "codesign verification failed"

# --- zip + checksum ---------------------------------------------------------
mkdir -p "$OUT_DIR"
rm -f "$ZIP" "$ZIP.sha256"
# ditto keeps symlinks and bundle metadata intact (plain zip may break frameworks)
ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$STAGE" "$ZIP"
(cd "$OUT_DIR" && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")
rm -rf "$STAGE_ROOT"

echo "created: $ZIP"
cat "$ZIP.sha256"
