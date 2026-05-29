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

  switch (type) {
    case 'TransientShaperPlugin':
      return { type, enabled, payload: { params: [p.fa, p.fr, p.sa, p.sr, p.gt, p.gs, p.sm] } };

    case 'BrickwallLimiterPlugin':
      // Rust set_params order: threshold, release, lookahead, input_gain, margin(sm)
      return { type, enabled, payload: { params: [p.th, p.rl, p.la, p.ig, p.sm ?? -1.0] } };

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
      return { type, enabled, payload: { bands } };
    }

    // TODO(full-integration): confirm JS param keys against the Rust set_params
    // arg order for these three, then enable. Until then they pass through
    // unprocessed on the native host.
    //   AutoLevelerPlugin       -> [target, window, maxGain, minGain, attack, release, noiseGate]
    //   SubSynthPlugin          -> [subLvl, dryLvl, subLpfF, subLpfS, subHpfF, subHpfS, dryHpfF, dryHpfS]
    //   MultibandCompressorPlugin -> crossovers[4] + 5×[threshold,ratio,attack,release,knee,makeup]
    case 'SpectrumAnalyzerPlugin':
      return { type, enabled, payload: {} };

    default:
      return null; // unsupported on native host
  }
}

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

  start({ sampleRate = 48000, channels = 2, bufferFrames = 128 } = {}) {
    this.sampleRate = sampleRate; this.channels = channels; this.bufferFrames = bufferFrames;
    this.post({ cmd: 'start', sampleRate, channels, bufferFrames });
  }

  stop() { this.post({ cmd: 'stop' }); }

  // pipeline: array of plugin instances (the current EffeTune chain).
  setPipeline(pipeline) {
    const effects = pipeline.map(normalize).filter(Boolean);
    this.post({ cmd: 'setPipeline', channels: this.channels, dspDir: this.dspDir, effects });
  }

  // Update a single effect in place (cheap path for slider drags).
  setParam(index, plugin) {
    const effect = normalize(plugin);
    if (effect) this.post({ cmd: 'setParam', index, effect });
  }
}

export const nativeBridge = isNativeHost ? new NativeBridge() : null;
