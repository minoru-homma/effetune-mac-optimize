# EffeTune (mac-optimize fork)

Fork of `Frieve-A/effetune` (remote `upstream`); `origin`/`fork` = `minoru-homma/effetune-mac-optimize`.
Adds a native macOS app + Rust/WASM DSP + perf work on top of upstream.

## Architecture
- Native macOS app (Swift/WKWebView, `native/`) and Electron app (`electron/`) are **mutually-exclusive runtimes** sharing the `js/` web UI.
- Native-only bridge: `native/Sources/EffeTuneApp/AudioBridge.swift` ↔ `js/native-bridge.js`; JS detects it via `window.__effetuneNativeHost` / `isNativeHost`.
- **Not used by the native app** (Electron-only): `electron/main.js`, `js/audio/audio-io-manager.js`.
- Shared but branch on `isNativeHost`: `js/app.js`, `js/audio-manager.js`. New shared behavior must be a no-op under the native host (guard on `electronAPI`/null nodes).

## Build / run / test
- Native: `native/app/make-app.sh` (`--release` for release); dev run `EFFETUNE_WEBROOT="$(pwd)" open native/.build/EffeTune.app`.
- Electron: `npm start`; package `npm run build:mac`. WASM: `npm run build:wasm`. Tests: `npm test` (= `node scripts/ab-test.js`).
- CI (`.github/workflows/build.yml`, supports manual dispatch): `gh workflow run build.yml --repo minoru-homma/effetune-mac-optimize --ref <branch>`.

## Upstream merge workflow
- Versioning: fork appends `-w<N>` to the upstream version (e.g. `1.65.1-w1`).
- `merge/upstream-v*` branches track upstream. Merging upstream conflicts predictably in: `electron/main.js`, `js/audio-manager.js`, `js/audio/audio-io-manager.js`, `package.json` — keep both fork and upstream additions.
- After changing `version`, sync the lockfile: `npm install --package-lock-only --ignore-scripts`.
