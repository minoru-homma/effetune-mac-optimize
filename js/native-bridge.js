// Native (macOS) host bridge.
//
// When EffeTune runs inside the native WKWebView host (native/Sources/EffeTuneApp),
// the host injects `window.__effetuneNativeHost = true` and a postMessage shim
// `window.__effetuneNativePost`. In that mode audio is processed by the native
// CoreAudio engine + Rust DSP dylibs, NOT by Web Audio: the renderer becomes a
// pure controller that ships the pipeline and parameter changes to native and
// receives meters back.
//
// This module is the JS half of the parameter marshalling table. Each effect's
// `getParameters()` output is normalized into the payload shape that
// native/Sources/EffeTuneApp/AudioBridge.swift decodes. The native side limits
// effects to the 8 Rust modules (EffectKind.all); other plugin types are skipped.

export const isNativeHost = typeof window !== 'undefined' && window.__effetuneNativeHost === true;

// PEQ filter-type string -> Rust type_id (order matches FifteenBandPEQPlugin.FILTER_TYPES
// and wasm-src/peq-dsp/src/design.rs FT_* constants).
const PEQ_TYPE_ID = { pk: 0, lp: 1, hp: 2, ls: 3, hs: 4, bp: 5, no: 6, ap: 7 };

// Normalize one plugin instance -> { type, enabled, payload } for native.
// Returns null for effects the native host does not support.
function normalize(plugin) {
  const p = plugin.getParameters();
  const type = p.type || plugin.constructor.name;
  const enabled = p.enabled !== false;
  const id = plugin.id;

  switch (type) {
    case 'TransientShaperPlugin':
      return { id, type, enabled, payload: { params: [p.fa, p.fr, p.sa, p.sr, p.gt, p.gs, p.sm] } };

    case 'BrickwallLimiterPlugin':
      // Rust set_params order: threshold, release, lookahead, input_gain, margin(sm)
      return { id, type, enabled, payload: { params: [p.th, p.rl, p.la, p.ig, p.sm ?? -1.0] } };

    case 'AutoLevelerPlugin':
      // Rust set_params: target, window, maxGain, minGain, attack, release, noiseGate
      return { id, type, enabled, payload: { params: [p.tg, p.tw, p.mg, p.ng, p.at, p.rt, p.gt] } };

    case 'FifteenBandPEQPlugin':
    case 'FiveBandPEQPlugin': {
      const bands = [];
      for (let i = 0; p['f' + i] !== undefined; i++) {
        bands.push({
          enabled: p['e' + i] !== false,
          typeId: PEQ_TYPE_ID[p['t' + i]] ?? 0,
          freq: p['f' + i],
          gain: p['g' + i],
          q: p['q' + i],
        });
      }
      return { id, type, enabled, payload: { bands } };
    }

    case 'SubSynthPlugin':
      // Rust set_params: subLvl, dryLvl, subLpfF, subLpfSlope, subHpfF, subHpfSlope, dryHpfF, dryHpfSlope
      return { id, type, enabled, payload: { params: [p.sl, p.dl, p.slf, p.sls, p.shf, p.shs, p.dhf, p.dhs] } };

    case 'MultibandCompressorPlugin': {
      // crossovers f1..f4 + 5 bands [threshold, ratio, attack, release, knee, makeup]
      const bands = (p.bands || []).map((b) => ({ params: [b.t, b.r, b.a, b.rl, b.k, b.g] }));
      return { id, type, enabled, payload: { crossovers: [p.f1, p.f2, p.f3, p.f4], bands } };
    }

    case 'SpectrumAnalyzerPlugin':
    case 'SpectrogramPlugin':
      // Native taps a 2^pt time-domain window for the analyzer's own FFT.
      return { id, type, enabled, payload: { pt: p.pt } };

    case 'LevelMeterPlugin':
      // Display-only; native taps audio and sends per-channel peaks.
      return { id, type, enabled, payload: {} };

    default:
      return null; // unsupported on native host
  }
}

// Async request/reply bookkeeping for native file dialogs / IO.
let _reqCounter = 0;
const _pendingRequests = {};

class NativeBridge {
  constructor() {
    this.dspDir = null; // native resolves from its bundle; left null unless overridden
    this.sampleRate = 48000;
    this.channels = 2;
    this.bufferFrames = 128;
  }

  post(msg) {
    if (window.__effetuneNativePost) window.__effetuneNativePost(msg);
  }

  // Map UI audioPreferences -> native device/format payload.
  _devicePayload(cmd, prefs) {
    if (prefs) {
      this.sampleRate = prefs.sampleRate || this.sampleRate;
      this.channels = prefs.outputChannels || this.channels;
    }
    return {
      cmd,
      sampleRate: this.sampleRate,
      channels: this.channels,
      bufferFrames: this.bufferFrames,
      inputDeviceId: prefs?.inputDeviceId ?? null,
      outputDeviceId: prefs?.outputDeviceId ?? null,
    };
  }

  start(prefs) { this.post(this._devicePayload('start', prefs)); }

  // Reconfigure devices/format and restart the engine.
  setDevices(prefs) { this.post(this._devicePayload('setDevices', prefs)); }

  // Async: returns the native CoreAudio device list [{uid,name,hasInput,hasOutput,...}].
  listDevices() {
    return new Promise((resolve) => {
      window.__effetuneOnDevices = (devs) => { resolve(Array.isArray(devs) ? devs : []); };
      this.post({ cmd: 'listDevices' });
    });
  }

  stop() { this.post({ cmd: 'stop' }); }

  // Async request/reply (file dialogs + IO). Native answers via __effetuneReply.
  _request(cmd, args) {
    return new Promise((resolve) => {
      const reqId = ++_reqCounter;
      _pendingRequests[reqId] = resolve;
      this.post({ cmd, reqId, ...args });
    });
  }
  showSaveDialog(opts) { return this._request('showSaveDialog', opts); }
  showOpenDialog(opts) { return this._request('showOpenDialog', opts); }
  saveFile(path, content) { return this._request('saveFile', { path, content }); }
  readFile(path) { return this._request('readFile', { path }); }

  // All supported effects (enabled flag carried in each desc; disabled ones are
  // kept as bypassed slots so JS and native indices stay aligned).
  effects(pipeline) {
    return pipeline.map(normalize).filter(Boolean);
  }

  // Structural change (add/remove/reorder/preset load): rebuild the native chain.
  setPipeline(pipeline) {
    this.post({ cmd: 'setPipeline', channels: this.channels, dspDir: this.dspDir, effects: this.effects(pipeline) });
  }

  // Parameter change (slider drag): apply in place, preserving DSP state.
  updateParams(pipeline) {
    this.post({ cmd: 'updateParams', effects: this.effects(pipeline) });
  }
}

export const nativeBridge = isNativeHost ? new NativeBridge() : null;

// Expose to non-module code (e.g. plugins/plugin-base.js loaded via <script>).
if (isNativeHost && typeof window !== 'undefined') {
  window.nativeBridge = nativeBridge;

  // Native answers async requests (file dialogs / IO) here.
  window.__effetuneReply = (reqId, result) => {
    const cb = _pendingRequests[reqId];
    if (cb) { delete _pendingRequests[reqId]; cb(result); }
  };

  // Receive native meter pushes and route each to the matching plugin's
  // onMessage, shaped exactly like the worklet's 'processBuffer' message so the
  // existing plugin meter handlers work unchanged.
  window.__effetuneOnMeters = (list) => {
    if (!Array.isArray(list) || !window.audioManager?.pipeline) return;
    const pipeline = window.audioManager.pipeline;
    for (const item of list) {
      // native sends id as a string; plugin.id is numeric — compare loosely.
      const plugin = pipeline.find((p) => String(p.id) === String(item.id));
      if (plugin && typeof plugin.onMessage === 'function') {
        plugin.onMessage({ type: 'processBuffer', pluginId: item.id, measurements: item.measurements });
      }
    }
  };
}
