//! WebAssembly port of the Transient Shaper.
//!
//! Mirrors `plugins/dynamics/transient_shaper.js`:
//!   - Per-channel fast and slow envelope followers (one-pole IIR).
//!   - Diff (fast − slow) drives a per-sample target gain that blends transient
//!     and sustain gains.
//!   - Smoothed application of that gain across all channels with hard clip.
//!
//! Output overwrites the input buffer in place.

const MAX_CHANNELS: usize = 8;
const LN10_OVER_20: f32 = 0.115_129_254_649_702_3;

pub struct State {
    sample_rate: f32,
    channel_count: u32,
    max_block_size: u32,

    // Live params (recomputed cheaply in process_block)
    fast_atk_ms: f32,
    fast_rel_ms: f32,
    slow_atk_ms: f32,
    slow_rel_ms: f32,
    transient_gain_db: f32,
    sustain_gain_db: f32,
    smoothing_ms: f32,

    fast_env: [f32; MAX_CHANNELS],
    slow_env: [f32; MAX_CHANNELS],
    smoothed_gain: f32,
    last_gain_db: f32,

    io: Vec<f32>,
}

#[no_mangle]
pub extern "C" fn init(sample_rate: f32, channel_count: u32, max_block_size: u32) -> *mut State {
    let ch = channel_count.min(MAX_CHANNELS as u32);
    let bs = max_block_size as usize;
    let state = Box::new(State {
        sample_rate,
        channel_count: ch,
        max_block_size,
        fast_atk_ms: 1.0,
        fast_rel_ms: 20.0,
        slow_atk_ms: 20.0,
        slow_rel_ms: 300.0,
        transient_gain_db: 0.0,
        sustain_gain_db: 0.0,
        smoothing_ms: 5.0,
        fast_env: [0.0; MAX_CHANNELS],
        slow_env: [0.0; MAX_CHANNELS],
        smoothed_gain: 1.0,
        last_gain_db: 0.0,
        io: vec![0.0; bs * MAX_CHANNELS],
    });
    Box::into_raw(state)
}

#[no_mangle]
pub extern "C" fn free_state(state: *mut State) {
    if !state.is_null() {
        unsafe { drop(Box::from_raw(state)) };
    }
}

#[no_mangle]
pub extern "C" fn io_ptr(state: *mut State) -> *mut f32 {
    let s = unsafe { &mut *state };
    s.io.as_mut_ptr()
}

#[no_mangle]
pub extern "C" fn last_gain_db(state: *mut State) -> f32 {
    let s = unsafe { &mut *state };
    s.last_gain_db
}

#[no_mangle]
pub extern "C" fn set_params(
    state: *mut State,
    fa: f32, fr: f32, sa: f32, sr: f32,
    gt: f32, gs: f32, sm: f32,
) {
    let s = unsafe { &mut *state };
    s.fast_atk_ms = fa;
    s.fast_rel_ms = fr;
    s.slow_atk_ms = sa;
    s.slow_rel_ms = sr;
    s.transient_gain_db = gt;
    s.sustain_gain_db = gs;
    s.smoothing_ms = sm;
}

#[no_mangle]
pub extern "C" fn process_block(state: *mut State, block_size: u32) {
    let s = unsafe { &mut *state };
    let bs = block_size as usize;
    let ch_count = s.channel_count as usize;
    if bs == 0 || bs > s.max_block_size as usize {
        return;
    }

    let g_tr = (s.transient_gain_db * LN10_OVER_20).exp();
    let g_sus = (s.sustain_gain_db * LN10_OVER_20).exp();
    let sr = s.sample_rate;
    let a_fa_atk = (-1.0 / (s.fast_atk_ms * 0.001 * sr)).exp();
    let a_fa_rel = (-1.0 / (s.fast_rel_ms * 0.001 * sr)).exp();
    let a_sa_atk = (-1.0 / (s.slow_atk_ms * 0.001 * sr)).exp();
    let a_sa_rel = (-1.0 / (s.slow_rel_ms * 0.001 * sr)).exp();
    let a_smooth = (-1.0 / (s.smoothing_ms * 0.001 * sr)).exp();
    let one_minus_smooth = 1.0 - a_smooth;

    let mut fast_env = s.fast_env;
    let mut slow_env = s.slow_env;
    let mut g = s.smoothed_gain;

    for i in 0..bs {
        let mut max_diff = 0.0f32;
        for ch in 0..ch_count {
            let idx = ch * bs + i;
            let x = s.io[idx];
            let abs_x = if x >= 0.0 { x } else { -x };

            let coeff_f = if abs_x > fast_env[ch] { a_fa_atk } else { a_fa_rel };
            fast_env[ch] = fast_env[ch] * coeff_f + abs_x * (1.0 - coeff_f);

            let coeff_s = if abs_x > slow_env[ch] { a_sa_atk } else { a_sa_rel };
            slow_env[ch] = slow_env[ch] * coeff_s + abs_x * (1.0 - coeff_s);

            let diff = fast_env[ch] - slow_env[ch];
            if diff > max_diff {
                max_diff = diff;
            }
        }

        let t = max_diff;
        let g_tr_val = 1.0 + (g_tr - 1.0) * t;
        let g_sus_val = 1.0 + (g_sus - 1.0) * (1.0 - t);
        let target = g_tr_val * g_sus_val;

        g = one_minus_smooth * target + a_smooth * g;

        for ch in 0..ch_count {
            let idx = ch * bs + i;
            let mut y = s.io[idx] * g;
            if y > 1.0 { y = 1.0; }
            else if y < -1.0 { y = -1.0; }
            s.io[idx] = y;
        }
    }

    s.fast_env = fast_env;
    s.slow_env = slow_env;
    s.smoothed_gain = g;
    s.last_gain_db = if g > 0.0 { 20.0 * g.ln() / core::f32::consts::LN_10 } else { -144.0 };
}
