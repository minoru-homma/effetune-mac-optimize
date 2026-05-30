# EffeTune — Native macOS App

A native macOS build of EffeTune whose **effect set is limited to the 8 Rust DSP
modules**. Goals: **low latency** (CoreAudio direct, small buffers) and **light
weight / OS integration** (no bundled Chromium; UI runs in a system `WKWebView`).

The ~58 pure-JavaScript effects are intentionally **out of scope** — so there is
**no DSP to port or rewrite**. The Rust modules already expose a clean C ABI and
build natively unchanged.

> Full plan: `~/.claude/plans/native-macos-app-mutable-raccoon.md`

## Directory layout

```
native/
├── dsp/      # built universal dylibs (one per module) — gitignored, produced by build
├── tools/    # verification harnesses (verify_dsp.c)
├── engine/   # CoreAudio AUHAL engine + RT-safe effect chain host   (TODO)
└── app/      # WKWebView host app + JS<->Native bridge              (TODO)
```

## Build the native DSP dylibs

```bash
node scripts/build-native-dsp.js
```

- Builds each `wasm-src/<module>` for the installed Apple targets
  (`aarch64-apple-darwin`, and `x86_64-apple-darwin` if installed), `lipo`-ing to
  a universal dylib when more than one arch is available.
- Output: `native/dsp/lib<crate>.dylib` (8 files).
- **Zero Rust source changes.** Same `#[no_mangle] extern "C"` symbols as the WASM
  build; only the cargo target differs (`wasm32-unknown-unknown` → Apple).

## Why dlopen-per-module (not static link)

Every module exports the **same symbol names** (`init`, `process_block`,
`free_state`, …). Statically linking all 8 into one binary collides. The native
app therefore `dlopen`s each dylib separately and resolves symbols with `dlsym`,
keeping namespaces isolated — no source change needed.

## Module ABI conventions (verified from the dylibs)

Not all modules share one ABI. Three families exist — the chain host must handle
each. Buffers are **planar (channel-major), `idx = ch * block_size + frame`**.

| Family | Modules | I/O symbols | Process | Params |
|---|---|---|---|---|
| **io (in-place)** | transient_shaper, sub_synth, five_band_peq, fifteen_band_peq, auto_leveler | `io_ptr` | `process_block(state, n)` | `set_params(...)` / `set_band(...)` |
| **split in/out** | brickwall_limiter, multiband_compressor | `input_ptr` + `output_ptr` | `process_block(state, n)` | `set_params` / `set_band_params`+`set_crossover_freqs` |
| **analyzer (read-only)** | spectrum_analyzer | `input_ptr`, `spectrum_ptr`, `peaks_ptr` | `analyze(...)` (no audio output) | `init(pt)`, `fft_size`, `update_peaks` |

Common lifecycle: `init(sample_rate, channel_count, max_block) -> *State`
(spectrum_analyzer differs: `init(points)`), `free_state(*State)`. Meters are
read via per-module getters (`last_gain_db`, `last_input_lufs`,
`last_gain_reduction`, `gain_reductions_ptr`, …).

## Swift engine package

`native/Package.swift` builds:
- **EffeTuneEngine** — `EffectModule` (dlopen loader, 3 ABI families),
  `EffectParams` (per-effect marshalling), `EffectChain` (RT-safe ordered
  processing), `CoreAudioEngine` (AUHAL duplex, configurable buffer frames).
- **dsptest** — headless offline verifier.
- **EffeTuneApp** — AppKit + WKWebView host; `AudioBridge` decodes JS commands
  (`start`/`stop`/`setPipeline`/`setParam`) into engine + chain operations.

```bash
cd native
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./.build/debug/dsptest "$(pwd)/dsp"
```

## Build & run the app

```bash
native/app/make-app.sh                 # build dylibs + app, assemble EffeTune.app, ad-hoc sign
# dev run with the UI served from the repo (Web Audio still active until wiring lands):
EFFETUNE_WEBROOT="$(pwd)" open native/.build/EffeTune.app
```

`Requires the active Xcode (DEVELOPER_DIR), not just Command Line Tools.`

## Status

- [x] All 8 modules build as native arm64 dylibs, unchanged (`scripts/build-native-dsp.js`).
- [x] dlopen/dlsym + `init`→`set_params`→`process_block`→`free_state` verified on a
      real signal (`native/tools/verify_dsp.c`, transient_shaper → PASS).
- [x] `EffectModule`/`EffectChain` host: all 8 modules (io / split / analyzer)
      load and process; PEQ boost, limiter ceiling, and a 2-effect chain verified
      offline (`dsptest` → PASS).
- [x] Per-effect param marshalling: io & split families + PEQ `set_band`, limiter,
      transient, sub-synth, auto-leveler, multiband (`EffectParams.swift`).
- [x] `CoreAudioEngine`: **dual-unit AUHAL** (separate input + output devices)
      bridged by a ring buffer; engine runs at the input device's rate, output
      AUHAL converts to the output device. Device enumeration + selection wired.
      **LIVE: audio passes input→chain→output; PEQ effect confirmed audible.**
- [x] WKWebView host app (`native/Sources/EffeTuneApp`) + JS↔Native bridge
      (`AudioBridge.swift`); assembles into a codesigned `EffeTune.app` via
      `native/app/make-app.sh`. Custom `effetune://` scheme serves the UI;
      native Audio menu opens the config dialog; mic permission requested.
- [x] Renderer fully in controller mode: `AudioManager` + `PipelineWorkletSync`
      route pipeline/param changes to native (Web Audio off). Normalizers for
      PEQ / transient / limiter / auto-leveler. Plugin list filtered to the 8.
- [x] **native→JS meters**: engine polls effect meter getters ~20Hz and pushes
      to the matching plugin's `onMessage`. **LIVE: Auto Leveler LUFS graph
      confirmed** (also Transient Shaper gain).
- [ ] Remaining: Sub Synth / Multiband param normalizers; Spectrum Analyzer
      waveform forwarding (needs an audio-buffer tap); Multiband/Brickwall meters;
      presets filtered to the 8 supported effects.
- [ ] Presets filtered to the 8 effects (graceful skip of unknown names in
      `js/preset-manager.js`).
- [ ] E2E: latency (loopback @64/128), live chain audio, RT param updates, preset
      load, app size vs Electron.

## Verify the DSP path

```bash
cc -O2 -o native/tools/verify_dsp native/tools/verify_dsp.c -lm
node scripts/build-native-dsp.js
native/tools/verify_dsp native/dsp/libtransient_shaper.dylib   # expect: PASS
```
