# ModuleACEResonator - Build Verification

## 1. `Source/ModuleFactory.cpp`

Include added (alphabetical position note: this file's existing include list is
**not** actually alphabetized — see "known deviations" below — so the include
was placed at the end of the block, right after the other recently-added
modules, immediately before the `juce_core` include):

```cpp
#include "AudioSyncer.h"
#include "ChordKeyboard.h"
#include "TapeLooper.h"
#include "ModuleACEResonator.h"      // <-- added, ModuleFactory.cpp line 287

#include <juce_core/juce_core.h>
```

Registration added inside `ModuleFactory::ModuleFactory()`, at the end of the
plain (non-hidden) `REGISTER(...)` block, right after `TapeLooper`:

```cpp
   REGISTER(ChordKeyboard, chordkeyboard, kModuleCategory_Note);
   REGISTER(TapeLooper, tapelooper, kModuleCategory_Audio);
   REGISTER(ModuleACEResonator, latentresonator, kModuleCategory_Synth);   // <-- added, ModuleFactory.cpp line 527

   (Registered name changed from `aceresonator` to `latentresonator` after
   interactive testing surfaced the request to brand it as Latent Resonator
   on the canvas -- lowercase/no-space to match every other module's
   registered-name convention, e.g. `chordkeyboard`, `tapelooper`,
   `sampleplayer`. The C++ class stays `ModuleACEResonator` -- that's
   internal source naming, never shown to a user.)
```

`kModuleCategory_Synth` was chosen from the enum in `Source/ModuleFactory.h`
(`kModuleCategory_Note, _Synth, _Audio, _Instrument, _Processor, _Modulator,
_Pulse, _Other, _Unknown`) as the closest fit: the module is a generative
sound source rather than a plain audio effect (`_Processor`/`_Audio`), so it
sits alongside other generator-style modules.

### Known deviation from the task's literal instructions

The task asked for "alphabetical position" for both the include and the
`REGISTER` line. In the real file, neither the include list nor the
`REGISTER` calls are actually sorted alphabetically (e.g. the include block
goes `LaunchpadKeyboard, DrumPlayer, EffectChain, LooperRecorder, Chorder,
Arpeggiator, Razor, ...` with no discernible order, and `REGISTER` calls are
grouped only loosely, e.g. `Arpeggiator, AudioRouter, Amplifier, ...`). Rather
than invent a false alphabetical position in a file that has none, both
additions were placed at the end of their respective blocks (include list,
and the plain-`REGISTER` block before `REGISTER_HIDDEN` begins), which is the
lowest-risk, easiest-to-diff insertion point and consistent with how several
other modules were evidently added over time. This is called out explicitly
per the task's request for honesty about deviations.

## 2. `Source/CMakeLists.txt`

Both files added to `target_sources(BespokeSynth PRIVATE ...)`, in true
alphabetical order (this list genuinely is alphabetized), immediately before
`ModuleContainer.cpp`/`.h`:

```cmake
    ModulatorWander.cpp
    ModulatorWander.h
    ModuleACEResonator.cpp      # <-- added, CMakeLists.txt line 394
    ModuleACEResonator.h        # <-- added, CMakeLists.txt line 395
    ModuleContainer.cpp
    ModuleContainer.h
```

(Note: the task text said "near the top, given the name starts with 'A'" -
the actual class/file name is `ModuleACEResonator`, starting with "M", so it
was placed alphabetically among the other `Module*` entries rather than near
the top of the "A" section. `'A' < 'C'` in `ModuleACEResonator` vs.
`ModuleContainer` puts it immediately before `ModuleContainer`, which is
where it was inserted.)

## 3. Build command

Run from the root of a local BespokeSynth checkout, against a pre-configured
build directory (see the project's own `CONTRIBUTING.md` for the initial
`cmake -Bignore/build` configure step):

```
cmake --build ignore/build --target BespokeSynth --parallel 4 --config Release
```

## 4. Build result: SUCCESS (exit code 0)

Because the project was already built from a previous session, this
incremental build only needed to recompile the two touched/added files (plus
the version-info stamp) and relink:

```
[ 11%] Built target version-info
[ 11%] Building CXX object Source/CMakeFiles/BespokeSynth.dir/geninclude/VersionInfoBld.cpp.o
[ 11%] Building CXX object Source/CMakeFiles/BespokeSynth.dir/geninclude/VersionInfo.cpp.o
[ 11%] Building CXX object Source/CMakeFiles/BespokeSynth.dir/ModuleACEResonator.cpp.o
[ 11%] Building CXX object Source/CMakeFiles/BespokeSynth.dir/ModuleFactory.cpp.o
[ 11%] Linking CXX executable BespokeSynth_artefacts/Release/BespokeSynth.app/Contents/MacOS/BespokeSynth
[100%] Built target BespokeSynth
[exited with code 0]
```

No compiler errors and no compiler warnings were emitted for
`ModuleACEResonator.cpp` or the `ModuleFactory.cpp` changes (the only
warnings anywhere in the full log are pre-existing, unrelated CMake
dev-warnings from third-party `libs/` subprojects: a `cmake_minimum_required`
deprecation notice from `libs/readerwriterqueue` and a JUCE
`add_custom_command`/`CMP0175` policy notice — both present before this
change and unrelated to `ModuleACEResonator`).

The resulting binary was written to the standard CMake output path for this
target:

```
ignore/build/Source/BespokeSynth_artefacts/Release/BespokeSynth.app/Contents/MacOS/BespokeSynth
```

`clang-format -i Source/ModuleACEResonator.cpp Source/ModuleACEResonator.h`
was run (using the repo's own `.clang-format`, via the Xcode Command Line
Tools' `clang-format`, since no standalone `clang-format` was on `PATH`)
before this build, and the result was hand-checked against the pre-format
version — only whitespace/line-wrapping changed (e.g. the base class list
collapsed onto one line, ternary re-indentation), no logic was altered.

## 5. Known gap: subprocess lifecycle parity with `BridgeProcessManager.swift`

This module's process-lifecycle logic (`LaunchBridgeProcess`, `ShutdownBridge`,
the worker thread's health-check loop) was ported from a version of
`BridgeProcessManager.swift` that predates the app's current `v2.0.0` code by
a substantial margin — a later diff comparison found ~465 added lines in that
file that this module does not yet have equivalents for, chiefly:

- Auto-installing and repairing the `ace_step` Python package on first run
  (multi-strategy import probing, dependency reinstall, git clone/update
  fallback if the package is missing entirely).
- Filtering macOS network-stack log noise (`nw_socket_*`, `nw_endpoint_*`,
  etc.) out of the bridge's captured output so real server logs aren't
  buried.

What this module *does* correctly implement — subprocess launch via
`juce::ChildProcess`, `/health` polling on a background thread, and a
graceful `/shutdown` POST before process teardown — is a faithful port of
the core pattern and was verified against the real, current bridge server
(see the top-level `bespoke-migration/ace-bridge/` extraction). The
auto-install/log-filtering behavior above is additional robustness this
module does not yet replicate; it's a reasonable follow-up, not a blocker
for the module to be useful today (the target machine already has a working
`.venv-ace-bridge/` in every case this has been exercised).
