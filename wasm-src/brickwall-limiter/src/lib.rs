//! WebAssembly port of the Brickwall Limiter.
//!
//! The DSP path mirrors `plugins/dynamics/brickwall_limiter.js`:
//!   1. Apply input gain.
//!   2. (osFactor > 1) Polyphase upsample by L.
//!   3. Lookahead delay + gain reduction at the (oversampled) sample rate.
//!   4. (osFactor > 1) Polyphase decimate back to the original rate.
//!
//! Filter coefficients are designed via Kaiser-windowed sinc with N=63 / β=5,
//! matching the JS reference exactly so the WASM and JS paths produce the same
//! output within float-precision noise.

mod filter;

use filter::PolyphaseFilters;

const MAX_CHANNELS: usize = 8;
const LUT_SIZE: usize = 1024;
const LUT_RANGE: f32 = 10.0;
const LN10_OVER_20: f32 = 0.115_129_254_649_702_3;

pub struct State {
    sample_rate: f32,
    channel_count: u32,
    max_block_size: u32,
    os_factor: u32,

    // Live parameters
    threshold_db: f32,
    release_ms: f32,
    lookahead_ms: f32,
    input_gain_db: f32,
    margin_db: f32,

    // Cached derived values
    input_gain_lin: f32,
    effective_threshold_lin: f32,
    release_coeff: f32,        // base-rate (osFactor==1)
    release_coeff_os: f32,     // oversampled-rate

    // Threshold-division LUT (shared between branches)
    threshold_lut: [f32; LUT_SIZE],
    last_threshold_lin: f32,

    // Polyphase filters (only used when os_factor > 1)
    filters: Option<PolyphaseFilters>,

    // Per-channel state (non-OS branch)
    delay_buf: Vec<Vec<f32>>,
    delay_write_pos: u32,
    delay_length: u32,
    gain_states: [f32; MAX_CHANNELS],

    // Per-channel state (OS branch)
    delay_buf_os: Vec<Vec<f32>>,
    delay_write_pos_os: [u32; MAX_CHANNELS],
    delay_length_os: u32,
    upsample_state: Vec<Vec<f32>>,
    downsample_state: Vec<Vec<f32>>,

    // Scratch buffers (sized once per init)
    input_scratch: Vec<f32>,
    oversampled: Vec<f32>,
    processed_os: Vec<f32>,
    output: Vec<f32>,
    x_buf: Vec<f32>, // upsample combined state+input
    z_buf: Vec<f32>, // downsample combined state+oversampled
    phase_indices: Vec<u32>,
    phase_remainders: Vec<u32>,

    last_min_gain: f32,
}

#[no_mangle]
pub extern "C" fn init(
    sample_rate: f32,
    channel_count: u32,
    max_block_size: u32,
    os_factor: u32,
) -> *mut State {
    let ch = channel_count.min(MAX_CHANNELS as u32) as usize;
    let bs = max_block_size as usize;
    let l = os_factor.max(1) as usize;

    let filters = if l > 1 { Some(PolyphaseFilters::design(l)) } else { None };
    let max_phase_len = filters.as_ref().map(|f| f.max_phase_len).unwrap_or(0);
    let n_filt = filters.as_ref().map(|f| f.n).unwrap_or(0);

    let upsample_state_len = if max_phase_len > 0 { max_phase_len - 1 } else { 0 };
    let m_down = if l > 1 { (n_filt + l - 1) / l } else { 0 };
    let downsample_state_len = if l > 1 { l * (m_down - 1) } else { 0 };

    let oversampled_len = bs * l * MAX_CHANNELS;
    let combined_up = upsample_state_len + bs;
    let combined_down = downsample_state_len + bs * l;

    let phase_indices = if l > 1 {
        let mut v = vec![0u32; bs];
        let d = downsample_state_len;
        for i in 0..bs {
            let n_index = i * l + d;
            v[i] = n_index as u32;
        }
        v
    } else {
        Vec::new()
    };
    let phase_remainders = if l > 1 {
        let mut v = vec![0u32; bs];
        for i in 0..bs {
            v[i] = ((i * l + downsample_state_len) % l) as u32;
        }
        v
    } else {
        Vec::new()
    };

    let mut state = Box::new(State {
        sample_rate,
        channel_count: ch as u32,
        max_block_size,
        os_factor: l as u32,

        threshold_db: 0.0,
        release_ms: 100.0,
        lookahead_ms: 3.0,
        input_gain_db: 0.0,
        margin_db: -1.0,

        input_gain_lin: 1.0,
        effective_threshold_lin: 1.0,
        release_coeff: 0.0,
        release_coeff_os: 0.0,

        threshold_lut: [1.0; LUT_SIZE],
        last_threshold_lin: -1.0,

        filters,

        delay_buf: vec![vec![0.0; bs * 2]; ch],
        delay_write_pos: 0,
        delay_length: bs as u32, // recomputed lazily
        gain_states: [1.0; MAX_CHANNELS],

        delay_buf_os: vec![vec![0.0; bs * l]; ch],
        delay_write_pos_os: [0; MAX_CHANNELS],
        delay_length_os: 1,
        upsample_state: vec![vec![0.0; upsample_state_len.max(1)]; ch],
        downsample_state: vec![vec![0.0; downsample_state_len.max(1)]; ch],

        input_scratch: vec![0.0; bs * MAX_CHANNELS],
        oversampled: vec![0.0; oversampled_len.max(1)],
        processed_os: vec![0.0; oversampled_len.max(1)],
        output: vec![0.0; bs * MAX_CHANNELS],
        x_buf: vec![0.0; combined_up.max(1)],
        z_buf: vec![0.0; combined_down.max(1)],
        phase_indices,
        phase_remainders,

        last_min_gain: 1.0,
    });

    rebuild_threshold_lut(&mut state);
    Box::into_raw(state)
}

#[no_mangle]
pub extern "C" fn free_state(state: *mut State) {
    if !state.is_null() {
        unsafe { drop(Box::from_raw(state)) };
    }
}

#[no_mangle]
pub extern "C" fn input_ptr(state: *mut State) -> *mut f32 {
    let s = unsafe { &mut *state };
    s.input_scratch.as_mut_ptr()
}

#[no_mangle]
pub extern "C" fn output_ptr(state: *mut State) -> *mut f32 {
    let s = unsafe { &mut *state };
    s.output.as_mut_ptr()
}

#[no_mangle]
pub extern "C" fn last_gain_reduction(state: *mut State) -> f32 {
    let s = unsafe { &mut *state };
    1.0 - s.last_min_gain
}

#[no_mangle]
pub extern "C" fn set_params(
    state: *mut State,
    threshold_db: f32,
    release_ms: f32,
    lookahead_ms: f32,
    input_gain_db: f32,
    margin_db: f32,
) {
    let s = unsafe { &mut *state };
    s.threshold_db = threshold_db;
    s.release_ms = release_ms.max(10.0);
    s.lookahead_ms = lookahead_ms.max(0.0);
    s.input_gain_db = input_gain_db;
    s.margin_db = margin_db;

    s.input_gain_lin = (input_gain_db * LN10_OVER_20).exp();
    let eff_db = threshold_db + margin_db;
    s.effective_threshold_lin = (eff_db * LN10_OVER_20).exp();

    let release_sec = s.release_ms * 0.001;
    let inv_sr = 1.0 / s.sample_rate;
    s.release_coeff = (-inv_sr / release_sec).exp();
    let inv_sr_os = inv_sr / s.os_factor as f32;
    s.release_coeff_os = (-inv_sr_os / release_sec).exp();

    if s.last_threshold_lin != s.effective_threshold_lin {
        rebuild_threshold_lut(s);
    }
}

#[no_mangle]
pub extern "C" fn process_block(state: *mut State, block_size: u32) {
    let s = unsafe { &mut *state };
    let bs = block_size as usize;
    let ch_count = s.channel_count as usize;
    if bs == 0 || bs > s.max_block_size as usize {
        return;
    }

    // Apply input gain into the scratch buffer (in-place).
    let total = ch_count * bs;
    let g = s.input_gain_lin;
    for i in 0..total {
        s.input_scratch[i] *= g;
    }

    if s.os_factor == 1 {
        process_no_oversampling(s, bs, ch_count);
    } else {
        process_oversampling(s, bs, ch_count);
    }
}

fn process_no_oversampling(s: &mut State, bs: usize, ch_count: usize) {
    // Recompute delay-line length when lookahead changes.
    let delay_samples = ((s.lookahead_ms * s.sample_rate * 0.001).ceil() as u32).max(0);
    let needed_len = (delay_samples as usize) + bs;
    if needed_len as u32 != s.delay_length {
        s.delay_length = needed_len as u32;
        for ch in 0..ch_count {
            s.delay_buf[ch] = vec![0.0; needed_len];
        }
        s.delay_write_pos = 0;
    }

    let dl = s.delay_length as usize;
    let release = s.release_coeff;
    let one_minus_release = 1.0 - release;
    let mut min_gain = 1.0f32;

    for ch in 0..ch_count {
        let in_off = ch * bs;
        let out_off = ch * bs;
        let mut current_gain = s.gain_states[ch];
        let buf = &mut s.delay_buf[ch];

        for k in 0..bs {
            let pos = (s.delay_write_pos as usize + k) % dl;
            let delayed = buf[pos];
            buf[pos] = s.input_scratch[in_off + k];
            let abs = if delayed >= 0.0 { delayed } else { -delayed };
            let target = lookup_threshold_div(&s.threshold_lut, s.effective_threshold_lin, abs);
            let new_gain = if target < current_gain {
                target
            } else {
                release * current_gain + one_minus_release * target
            };
            current_gain = new_gain;
            s.output[out_off + k] = delayed * current_gain;
        }

        s.gain_states[ch] = current_gain;
        if current_gain < min_gain {
            min_gain = current_gain;
        }
    }

    s.delay_write_pos = (s.delay_write_pos + bs as u32) % s.delay_length;
    s.last_min_gain = min_gain;
}

fn process_oversampling(s: &mut State, bs: usize, ch_count: usize) {
    let l = s.os_factor as usize;
    let filters = s.filters.as_ref().expect("polyphase filters initialised");
    let n_filt = filters.n;
    let max_phase_len = filters.max_phase_len;
    let upsample_state_len = max_phase_len - 1;
    let m_down = (n_filt + l - 1) / l;
    let downsample_state_len = l * (m_down - 1);

    let os_block = bs * l;

    // --- Recompute lookahead delay (oversampled domain).
    let raw_delay_orig = (s.lookahead_ms * s.sample_rate * 0.001).ceil() as u32;
    let delay_os = (raw_delay_orig.max(1) as usize) * l;
    if delay_os as u32 != s.delay_length_os {
        s.delay_length_os = delay_os as u32;
        for ch in 0..ch_count {
            s.delay_buf_os[ch] = vec![0.0; delay_os];
            s.delay_write_pos_os[ch] = 0;
        }
    }

    // --- Upsampling (per channel).
    let combined_up = upsample_state_len + bs;
    if s.x_buf.len() < combined_up {
        s.x_buf = vec![0.0; combined_up];
    }

    for ch in 0..ch_count {
        let in_off = ch * bs;
        let os_off = ch * os_block;
        // Build [state | input]
        let state = &s.upsample_state[ch];
        for i in 0..upsample_state_len {
            s.x_buf[i] = state[i];
        }
        for i in 0..bs {
            s.x_buf[upsample_state_len + i] = s.input_scratch[in_off + i];
        }

        for sample in 0..bs {
            let i_x = upsample_state_len + sample;
            let base_out = os_off + sample * l;
            for p in 0..l {
                let h = &filters.branches[p];
                let mut acc = 0.0f32;
                for k in 0..h.len() {
                    let idx = i_x as i32 - k as i32;
                    if idx < 0 {
                        break;
                    }
                    acc += h[k] * s.x_buf[idx as usize];
                }
                s.oversampled[base_out + p] = acc;
            }
        }

        // Save last upsample_state_len samples back into state.
        let state = &mut s.upsample_state[ch];
        for i in 0..upsample_state_len {
            state[i] = s.x_buf[combined_up - upsample_state_len + i];
        }
    }

    // --- Gain reduction in oversampled domain.
    let release = s.release_coeff_os;
    let one_minus_release = 1.0 - release;
    let mut min_gain = 1.0f32;
    for ch in 0..ch_count {
        let os_off = ch * os_block;
        let buf = &mut s.delay_buf_os[ch];
        let mut current_gain = s.gain_states[ch];
        let mut write_pos = s.delay_write_pos_os[ch] as usize;
        let buf_len = buf.len();

        for k in 0..os_block {
            let pos = (write_pos + k) % buf_len;
            let delayed = buf[pos];
            buf[pos] = s.oversampled[os_off + k];
            let abs = if delayed >= 0.0 { delayed } else { -delayed };
            let target = lookup_threshold_div(&s.threshold_lut, s.effective_threshold_lin, abs);
            let new_gain = if target < current_gain {
                target
            } else {
                release * current_gain + one_minus_release * target
            };
            current_gain = new_gain;
            s.processed_os[os_off + k] = delayed * current_gain;
        }

        s.gain_states[ch] = current_gain;
        s.delay_write_pos_os[ch] = ((write_pos + os_block) % buf_len) as u32;
        write_pos = s.delay_write_pos_os[ch] as usize;
        let _ = write_pos; // silence unused-after-update warning
        if current_gain < min_gain {
            min_gain = current_gain;
        }
    }
    s.last_min_gain = min_gain;

    // --- Downsampling (per channel).
    let combined_down = downsample_state_len + os_block;
    if s.z_buf.len() < combined_down {
        s.z_buf = vec![0.0; combined_down];
    }

    for ch in 0..ch_count {
        let os_off = ch * os_block;
        let out_off = ch * bs;
        let dstate = &s.downsample_state[ch];
        for i in 0..downsample_state_len {
            s.z_buf[i] = dstate[i];
        }
        for i in 0..os_block {
            s.z_buf[downsample_state_len + i] = s.processed_os[os_off + i];
        }

        for i in 0..bs {
            let n_index = s.phase_indices[i] as usize;
            let r = s.phase_remainders[i] as usize;
            let h = &filters.branches[r];
            let mut acc = 0.0f32;
            for k in 0..h.len() {
                let idx = n_index as i32 - (l * k) as i32;
                if idx < 0 {
                    break;
                }
                acc += h[k] * s.z_buf[idx as usize];
            }
            s.output[out_off + i] = acc;
        }

        let dstate = &mut s.downsample_state[ch];
        for i in 0..downsample_state_len {
            dstate[i] = s.z_buf[combined_down - downsample_state_len + i];
        }
    }
}

#[inline]
fn lookup_threshold_div(lut: &[f32; LUT_SIZE], threshold_lin: f32, abs_sample: f32) -> f32 {
    if abs_sample <= 1e-6 {
        return 1.0;
    }
    if abs_sample > threshold_lin {
        if abs_sample > LUT_RANGE {
            return threshold_lin / abs_sample;
        }
        let scale = LUT_SIZE as f32 / LUT_RANGE;
        let idx = (abs_sample * scale) as usize;
        let idx = idx.min(LUT_SIZE - 1);
        return lut[idx];
    }
    1.0
}

fn rebuild_threshold_lut(s: &mut State) {
    let scale = LUT_SIZE as f32 / LUT_RANGE;
    let inv_scale = 1.0 / scale;
    let thr = s.effective_threshold_lin;
    for i in 0..LUT_SIZE {
        let abs_sample = i as f32 * inv_scale;
        s.threshold_lut[i] = if abs_sample <= 1e-6 {
            1.0
        } else if abs_sample > thr {
            thr / abs_sample
        } else {
            1.0
        };
    }
    s.last_threshold_lin = thr;
}
