//! WebAssembly port of Auto Leveler.
//!
//! Mirrors `plugins/dynamics/auto_leveler.js`:
//!   1. Mono-mix the input.
//!   2. Apply two K-weighting biquads (pre-filter, shelf) — fixed coefficients.
//!   3. Maintain a circular buffer of weighted-square values (length = window).
//!   4. Compute mean square -> LUFS, derive target gain in linear domain.
//!   5. Smoothly apply the gain to all channels with attack/release coefficients.
//!
//! All state lives in a single Box<State>. Output overwrites the input buffer.

const MAX_CHANNELS: usize = 8;
const LN10: f32 = core::f32::consts::LN_10;

// K-weighting filter coefficients (BS.1770 simplified; matches JS reference).
const PRE_B0: f32 = 1.0;
const PRE_B1: f32 = -2.0;
const PRE_B2: f32 = 1.0;
const PRE_A1: f32 = -1.99004745483398;
const PRE_A2: f32 = 0.99007225036621;

const SHELF_B0: f32 = 1.53512485958697;
const SHELF_B1: f32 = -2.69169618940638;
const SHELF_B2: f32 = 1.19839281085285;
const SHELF_A1: f32 = -1.69065929318241;
const SHELF_A2: f32 = 0.73248077421585;

#[derive(Clone, Copy, Default)]
struct BiquadState {
    x1: f32,
    x2: f32,
    y1: f32,
    y2: f32,
}

pub struct State {
    sample_rate: f32,
    channel_count: u32,
    max_block_size: u32,

    // Live params
    target_lufs: f32,         // dB
    window_ms: f32,
    max_gain_db: f32,
    min_gain_db: f32,
    attack_ms: f32,
    release_ms: f32,
    noise_gate_db: f32,

    // Cached derived
    target_lin: f32,           // 10^(target/10)
    noise_gate_lin: f32,       // 10^(gate/10)
    max_gain_lin: f32,         // 10^(max/20)
    min_gain_lin: f32,         // 10^(min/20)
    attack_coeff: f32,
    release_coeff: f32,
    attack_coeff_inv: f32,
    release_coeff_inv: f32,

    // Filter states
    pre: BiquadState,
    shelf: BiquadState,

    // Circular buffer of weighted-square samples
    lufs_buf: Vec<f32>,
    buf_index: usize,
    buf_filled: bool,
    sum: f32,

    // Smoothing state
    current_gain: f32,
    last_input_lufs: f32,
    last_output_lufs: f32,

    // Scratch
    mono: Vec<f32>,
    weighted: Vec<f32>,
    io: Vec<f32>,
}

#[no_mangle]
pub extern "C" fn init(sample_rate: f32, channel_count: u32, max_block_size: u32) -> *mut State {
    let ch = channel_count.min(MAX_CHANNELS as u32);
    let bs = max_block_size as usize;
    // Initial buffer sized for 10s max window (the JS upper bound).
    let max_window_samples = ((10000.0_f32 * sample_rate) / 1000.0) as usize;
    let initial_window = ((3000.0_f32 * sample_rate) / 1000.0) as usize;
    let _ = max_window_samples;
    let state = Box::new(State {
        sample_rate,
        channel_count: ch,
        max_block_size,
        target_lufs: -18.0,
        window_ms: 3000.0,
        max_gain_db: 0.0,
        min_gain_db: -12.0,
        attack_ms: 50.0,
        release_ms: 5000.0,
        noise_gate_db: -60.0,
        target_lin: 1.0,
        noise_gate_lin: 1.0,
        max_gain_lin: 1.0,
        min_gain_lin: 1.0,
        attack_coeff: 0.0,
        release_coeff: 0.0,
        attack_coeff_inv: 0.0,
        release_coeff_inv: 0.0,
        pre: BiquadState::default(),
        shelf: BiquadState::default(),
        lufs_buf: vec![0.0; initial_window.max(1)],
        buf_index: 0,
        buf_filled: false,
        sum: 0.0,
        current_gain: 1.0,
        last_input_lufs: -144.0,
        last_output_lufs: -144.0,
        mono: vec![0.0; bs],
        weighted: vec![0.0; bs],
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
pub extern "C" fn last_input_lufs(state: *mut State) -> f32 {
    let s = unsafe { &mut *state };
    s.last_input_lufs
}

#[no_mangle]
pub extern "C" fn last_output_lufs(state: *mut State) -> f32 {
    let s = unsafe { &mut *state };
    s.last_output_lufs
}

#[no_mangle]
pub extern "C" fn set_params(
    state: *mut State,
    target_lufs: f32,
    window_ms: f32,
    max_gain_db: f32,
    min_gain_db: f32,
    attack_ms: f32,
    release_ms: f32,
    noise_gate_db: f32,
) {
    let s = unsafe { &mut *state };
    s.target_lufs = target_lufs;
    s.window_ms = window_ms;
    s.max_gain_db = max_gain_db;
    s.min_gain_db = min_gain_db;
    s.attack_ms = attack_ms.max(1.0);
    s.release_ms = release_ms.max(1.0);
    s.noise_gate_db = noise_gate_db;

    s.target_lin = (target_lufs / 10.0 * LN10).exp();
    s.noise_gate_lin = (noise_gate_db / 10.0 * LN10).exp();
    s.max_gain_lin = (max_gain_db / 20.0 * LN10).exp();
    s.min_gain_lin = (min_gain_db / 20.0 * LN10).exp();

    let attack_samples = (s.attack_ms * s.sample_rate / 1000.0).max(1.0);
    let release_samples = (s.release_ms * s.sample_rate / 1000.0).max(1.0);
    s.attack_coeff = (-core::f32::consts::LN_2 / attack_samples).exp();
    s.release_coeff = (-core::f32::consts::LN_2 / release_samples).exp();
    s.attack_coeff_inv = 1.0 - s.attack_coeff;
    s.release_coeff_inv = 1.0 - s.release_coeff;

    // Resize circular buffer if window changed.
    let window_samples = ((window_ms * s.sample_rate) / 1000.0) as usize;
    let window_samples = window_samples.max(1);
    if window_samples != s.lufs_buf.len() {
        s.lufs_buf = vec![0.0; window_samples];
        s.buf_index = 0;
        s.buf_filled = false;
        s.sum = 0.0;
    }
}

#[inline(always)]
fn process_biquad(input: &[f32], output: &mut [f32], st: &mut BiquadState,
                  b0: f32, b1: f32, b2: f32, a1: f32, a2: f32) {
    let mut x1 = st.x1;
    let mut x2 = st.x2;
    let mut y1 = st.y1;
    let mut y2 = st.y2;
    for i in 0..input.len() {
        let x = input[i];
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
        x2 = x1;
        x1 = x;
        y2 = y1;
        y1 = y;
        output[i] = y;
    }
    st.x1 = x1;
    st.x2 = x2;
    st.y1 = y1;
    st.y2 = y2;
}

#[no_mangle]
pub extern "C" fn process_block(state: *mut State, block_size: u32) {
    let s = unsafe { &mut *state };
    let bs = block_size as usize;
    let ch_count = s.channel_count as usize;
    if bs == 0 || bs > s.max_block_size as usize || ch_count == 0 {
        return;
    }

    // 1. Mono mix
    let scale = 1.0 / ch_count as f32;
    for i in 0..bs {
        s.mono[i] = 0.0;
    }
    for ch in 0..ch_count {
        let off = ch * bs;
        for i in 0..bs {
            s.mono[i] += s.io[off + i] * scale;
        }
    }

    // 2. K-weighting filters (pre then shelf, in-place reuse weighted buffer).
    {
        let (mono, weighted) = (&s.mono[..bs], &mut s.weighted[..bs]);
        process_biquad(mono, weighted, &mut s.pre, PRE_B0, PRE_B1, PRE_B2, PRE_A1, PRE_A2);
    }
    {
        let weighted_in = s.weighted[..bs].to_vec();
        let weighted = &mut s.weighted[..bs];
        process_biquad(&weighted_in, weighted, &mut s.shelf,
                       SHELF_B0, SHELF_B1, SHELF_B2, SHELF_A1, SHELF_A2);
    }

    // 3. Update circular sum buffer with squared values.
    let window_samples = s.lufs_buf.len();
    let mut sum_change = 0.0_f32;
    let start_idx = s.buf_index;
    let end_idx = (start_idx + bs) % window_samples;
    for i in 0..bs {
        let w = s.weighted[i];
        let sq = w * w;
        let pos = (start_idx + i) % window_samples;
        sum_change -= s.lufs_buf[pos];
        sum_change += sq;
        s.lufs_buf[pos] = sq;
    }
    s.sum += sum_change;
    s.buf_index = end_idx;
    if !s.buf_filled && bs > 0 && end_idx <= start_idx {
        s.buf_filled = true;
    }

    // 4. Compute current LUFS (linear and dB).
    let valid = if s.buf_filled { window_samples } else { end_idx };
    let mut cur_lin = 0.0_f32;
    if valid > 0 && s.sum > 0.0 {
        cur_lin = s.sum / valid as f32;
    }
    let mut cur_lufs = -144.0_f32;
    if cur_lin > 0.0 {
        cur_lufs = 10.0 * (cur_lin.ln() / LN10) - 0.691;
    }
    s.last_input_lufs = cur_lufs;

    // 5. Target gain in linear domain.
    let mut target_gain = if cur_lin < s.noise_gate_lin || cur_lin <= 0.0 {
        1.0_f32
    } else {
        (s.target_lin / cur_lin).sqrt()
    };
    if target_gain > s.max_gain_lin { target_gain = s.max_gain_lin; }
    if target_gain < s.min_gain_lin { target_gain = s.min_gain_lin; }

    // 6. Smooth + apply.
    let mut g = s.current_gain;
    for i in 0..bs {
        let use_attack = target_gain < g;
        let coeff = if use_attack { s.attack_coeff } else { s.release_coeff };
        let inv = if use_attack { s.attack_coeff_inv } else { s.release_coeff_inv };
        g = g * coeff + target_gain * inv;
        for ch in 0..ch_count {
            let idx = ch * bs + i;
            s.io[idx] = s.io[idx] * g;
        }
    }
    s.current_gain = g;

    // 7. Output LUFS metering.
    let mut out_lufs = -144.0_f32;
    if cur_lufs > -144.0 && g > 0.0 {
        out_lufs = cur_lufs + 20.0 * (g.ln() / LN10);
        if out_lufs < -144.0 {
            out_lufs = -144.0;
        }
    }
    s.last_output_lufs = out_lufs;
}
