# EffeTune (mac-optimize fork)

Fork of `Frieve-A/effetune` (remote `upstream`); `origin`/`fork` = `minoru-homma/effetune-mac-optimize`.
Adds a native macOS app + Rust/WASM DSP + perf work on top of upstream.

## Architecture
- Native macOS app (Swift/WKWebView, `native/`) and Electron app (`electron/`) are **mutually-exclusive runtimes** sharing the `js/` web UI.
- Native-only bridge: `native/Sources/EffeTuneApp/AudioBridge.swift` ↔ `js/native-bridge.js`; JS detects it via `window.__effetuneNativeHost` / `isNativeHost`.
- **Not used by the native app** (Electron-only): `electron/main.js`, `js/audio/audio-io-manager.js`.
- Shared but branch on `isNativeHost`: `js/app.js`, `js/audio-manager.js`. New shared behavior must be a no-op under the native host (guard on `electronAPI`/null nodes).

## Native analyzer overlay (GPU rendering)
- Canvas2D analyzers are rendered natively (Swift/Metal) on the native host instead of by JS, cutting total CPU (e.g. Spectrogram 39%→16%, Oscilloscope 30.6%→9.4% across all processes) and eliminating their 30 Hz meter-push IPC. Files: `native/Sources/EffeTuneApp/AnalyzerOverlay.swift` (transparent NSView over the WKWebView + CVDisplayLink + `AnalyzerRenderer` registry), `{Spectrogram,Oscilloscope,StereoMeter,LevelMeter}Renderer.swift`, shared shaders/pipelines + `SurfacePresenter` in `SpectrumRenderer.swift`.
- Flow: the plugin's rAF loop reports its `getBoundingClientRect` + params via `nativeBridge.setOverlayRect` (see `OVERLAY_TYPES` in `js/native-bridge.js`); the renderer pulls tap data straight from the `EffectModule` and presents via an **IOSurface-backed `CALayer.contents`** (NOT `CAMetalLayer` — its `nextDrawable`/FramePacing path profiled as the dominant cost). Native skips the meter push for overlay-managed ids (`overlay.hasActiveEntry`).
- Spectrum stays on **WebGPU** (already GPU; native gave no win). Per-frame present has a ~floor cost that scales with drawable pixels, so the drawable is capped to 1× (`EFFETUNE_OVERLAY_SCALE`); `?nativeOverlay=0` forces the JS Canvas path for A/B.
- **Build `--release`**: the Spectrogram FFT is hand-ported Swift — a debug build (no opt + bounds checks) roughly doubles native CPU (~12%→~39%).

## Build / run / test
- Native: `native/app/make-app.sh` (`--release` for release — required for analyzer perf, see above); dev run `EFFETUNE_WEBROOT="$(pwd)" open native/.build/EffeTune.app`.
- Electron: `npm start`; package `npm run build:mac`. WASM: `npm run build:wasm`. Tests: `npm test` (= `node scripts/ab-test.js`).
- CI (`.github/workflows/build.yml`, supports manual dispatch): `gh workflow run build.yml --repo minoru-homma/effetune-mac-optimize --ref <branch>`.

## Upstream merge workflow
- Versioning: fork appends `-w<N>` to the upstream version (e.g. `1.65.1-w1`).
- `merge/upstream-v*` branches track upstream. Merging upstream conflicts predictably in: `electron/main.js`, `js/audio-manager.js`, `js/audio/audio-io-manager.js`, `package.json` — keep both fork and upstream additions.
- After changing `version`, sync the lockfile: `npm install --package-lock-only --ignore-scripts`.
