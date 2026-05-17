//! WebAssembly port of Sub Synth.
//!
//! Mirrors `plugins/saturation/sub_synth.js`:
//!   - Three filter chains (Sub LPF, Sub HPF, Dry HPF), each made of zero or
//!     more cascaded 1st- and 2nd-order Butterworth biquads.
//!   - Slope (in dB/oct) controls how many sections; 0 means bypass.
//!   - Per sample: rectify input -> apply sub LPF chain -> apply sub HPF chain
//!     to get sub signal; apply dry HPF chain to original; mix.

const MAX_CHANNELS: usize = 8;
const MAX_STAGES_PER_CHAIN: usize = 8; // 48 dB/oct max -> 4 second-order + 1 first-order

const PI: f32 = core::f32::consts::PI;

pub struct State {
    sample_rate: f32,
    channel_count: u32,
    max_block_size: u32,

    // Live params
    sub_level: f32,    // 0..(>1)
    dry_level: f32,
    sub_lpf_freq: f32,
    sub_lpf_slope: f32, // dB/oct, 0=bypass
    sub_hpf_freq: f32,
    sub_hpf_slope: f32,
    dry_hpf_freq: f32,
    dry_hpf_slope: f32,

    // Filter chains
    sub_lpf: FilterChain,
    sub_hpf: FilterChain,
    dry_hpf: FilterChain,

    io: Vec<f32>,
}

struct FilterChain {
    // For each stage: order (1 or 2) and coefficients.
    orders: [u8; MAX_STAGES_PER_CHAIN],
    // 1st-order coeffs: b0, b1, a1 (a0=1)
    // 2nd-order coeffs: b0, b1, b2, a1, a2 (a0=1)
    coeff: [[f32; 5]; MAX_STAGES_PER_CHAIN],
    // States: 1st-order uses (x1, y1); 2nd-order uses (x1, x2, y1, y2)
    state: [[f32; 4]; MAX_STAGES_PER_CHAIN * MAX_CHANNELS],
    n_stages: usize,
}

impl FilterChain {
    fn new() -> Self {
        FilterChain {
            orders: [0; MAX_STAGES_PER_CHAIN],
            coeff: [[0.0; 5]; MAX_STAGES_PER_CHAIN],
            state: [[0.0; 4]; MAX_STAGES_PER_CHAIN * MAX_CHANNELS],
            n_stages: 0,
        }
    }

    fn reset_state(&mut self) {
        for s in self.state.iter_mut() {
            *s = [0.0; 4];
        }
    }

    fn rebuild_lpf(&mut self, slope_db_oct: f32, freq: f32, sample_rate: f32) {
        let (order1, order2) = section_counts(slope_db_oct);
        let mut idx = 0usize;
        for _ in 0..order1 {
            self.orders[idx] = 1;
            self.coeff[idx][..3].copy_from_slice(&design_lpf1(freq, sample_rate));
            idx += 1;
        }
        for _ in 0..order2 {
            self.orders[idx] = 2;
            self.coeff[idx].copy_from_slice(&design_lpf2(freq, sample_rate));
            idx += 1;
        }
        let new_n = idx;
        if new_n != self.n_stages {
            self.reset_state();
        }
        self.n_stages = new_n;
    }

    fn rebuild_hpf(&mut self, slope_db_oct: f32, freq: f32, sample_rate: f32) {
        let (order1, order2) = section_counts(slope_db_oct);
        let mut idx = 0usize;
        for _ in 0..order1 {
            self.orders[idx] = 1;
            self.coeff[idx][..3].copy_from_slice(&design_hpf1(freq, sample_rate));
            idx += 1;
        }
        for _ in 0..order2 {
            self.orders[idx] = 2;
            self.coeff[idx].copy_from_slice(&design_hpf2(freq, sample_rate));
            idx += 1;
        }
        let new_n = idx;
        if new_n != self.n_stages {
            self.reset_state();
        }
        self.n_stages = new_n;
    }

    #[inline(always)]
    fn process_sample(&mut self, mut x: f32, ch: usize) -> f32 {
        for s in 0..self.n_stages {
            let st_idx = s * MAX_CHANNELS + ch;
            let st = &mut self.state[st_idx];
            let c = &self.coeff[s];
            if self.orders[s] == 1 {
                // y = b0*x + b1*x1 - a1*y1
                let y = c[0] * x + c[1] * st[0] - c[2] * st[2];
                st[0] = x;     // x1
                st[2] = y;     // y1
                x = y;
            } else {
                // y = b0*x + b1*x1 + b2*x2 - a1*y1 - a2*y2
                let y = c[0] * x + c[1] * st[0] + c[2] * st[1]
                      - c[3] * st[2] - c[4] * st[3];
                st[1] = st[0];  // x2 = x1
                st[0] = x;      // x1 = x
                st[3] = st[2];  // y2 = y1
                st[2] = y;      // y1 = y
                x = y;
            }
        }
        x
    }
}

fn section_counts(slope_db_oct: f32) -> (i32, i32) {
    let abs_slope = slope_db_oct.abs();
    if abs_slope == 0.0 {
        return (0, 0);
    }
    let n = (abs_slope / 6.0).round() as i32;
    if n % 2 == 1 {
        (1, (n - 1) / 2)
    } else {
        (0, n / 2)
    }
}

fn design_lpf1(freq: f32, sr: f32) -> [f32; 3] {
    // 1st-order LPF (matches JS):
    // b0 = c/(1+c), b1 = c/(1+c), a1 = -((1-c)/(1+c))
    let c = (PI * freq / sr).tan();
    let denom = 1.0 + c;
    [c / denom, c / denom, -((1.0 - c) / denom)]
}

fn design_hpf1(freq: f32, sr: f32) -> [f32; 3] {
    let c = (PI * freq / sr).tan();
    let denom = 1.0 + c;
    [1.0 / denom, -1.0 / denom, -((1.0 - c) / denom)]
}

fn design_lpf2(freq: f32, sr: f32) -> [f32; 5] {
    let w0 = 2.0 * PI * freq / sr;
    let q = core::f32::consts::FRAC_1_SQRT_2;
    let alpha = w0.sin() / (2.0 * q);
    let cos_w = w0.cos();
    let a0 = 1.0 + alpha;
    let inv_a0 = 1.0 / a0;
    [
        ((1.0 - cos_w) * 0.5) * inv_a0,
        (1.0 - cos_w) * inv_a0,
        ((1.0 - cos_w) * 0.5) * inv_a0,
        (-2.0 * cos_w) * inv_a0,
        (1.0 - alpha) * inv_a0,
    ]
}

fn design_hpf2(freq: f32, sr: f32) -> [f32; 5] {
    let w0 = 2.0 * PI * freq / sr;
    let q = core::f32::consts::FRAC_1_SQRT_2;
    let alpha = w0.sin() / (2.0 * q);
    let cos_w = w0.cos();
    let a0 = 1.0 + alpha;
    let inv_a0 = 1.0 / a0;
    [
        ((1.0 + cos_w) * 0.5) * inv_a0,
        (-(1.0 + cos_w)) * inv_a0,
        ((1.0 + cos_w) * 0.5) * inv_a0,
        (-2.0 * cos_w) * inv_a0,
        (1.0 - alpha) * inv_a0,
    ]
}

#[no_mangle]
pub extern "C" fn init(sample_rate: f32, channel_count: u32, max_block_size: u32) -> *mut State {
    let ch = channel_count.min(MAX_CHANNELS as u32);
    let bs = max_block_size as usize;
    let state = Box::new(State {
        sample_rate,
        channel_count: ch,
        max_block_size,
        sub_level: 1.0,
        dry_level: 1.0,
        sub_lpf_freq: 160.0,
        sub_lpf_slope: -12.0,
        sub_hpf_freq: 5.0,
        sub_hpf_slope: -6.0,
        dry_hpf_freq: 40.0,
        dry_hpf_slope: 0.0,
        sub_lpf: FilterChain::new(),
        sub_hpf: FilterChain::new(),
        dry_hpf: FilterChain::new(),
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
pub extern "C" fn set_params(
    state: *mut State,
    sl: f32, dl: f32,
    slf: f32, sls: f32,
    shf: f32, shs: f32,
    dhf: f32, dhs: f32,
) {
    let s = unsafe { &mut *state };
    s.sub_level = sl / 100.0;
    s.dry_level = dl / 100.0;
    s.sub_lpf_freq = slf;
    s.sub_lpf_slope = sls;
    s.sub_hpf_freq = shf;
    s.sub_hpf_slope = shs;
    s.dry_hpf_freq = dhf;
    s.dry_hpf_slope = dhs;

    // Rebuild filter chains.
    s.sub_lpf.rebuild_lpf(sls, slf, s.sample_rate);
    s.sub_hpf.rebuild_hpf(shs, shf, s.sample_rate);
    s.dry_hpf.rebuild_hpf(dhs, dhf, s.sample_rate);
}

#[no_mangle]
pub extern "C" fn process_block(state: *mut State, block_size: u32) {
    let s = unsafe { &mut *state };
    let bs = block_size as usize;
    let ch_count = s.channel_count as usize;
    if bs == 0 || bs > s.max_block_size as usize {
        return;
    }

    let sub_level = s.sub_level;
    let dry_level = s.dry_level;

    for ch in 0..ch_count {
        let off = ch * bs;
        for i in 0..bs {
            let dry_in = s.io[off + i];
            let mut sub_in = if dry_in >= 0.0 { dry_in } else { -dry_in };
            if s.sub_lpf.n_stages > 0 {
                sub_in = s.sub_lpf.process_sample(sub_in, ch);
            }
            if s.sub_hpf.n_stages > 0 {
                sub_in = s.sub_hpf.process_sample(sub_in, ch);
            }
            let mut dry_out = dry_in;
            if s.dry_hpf.n_stages > 0 {
                dry_out = s.dry_hpf.process_sample(dry_out, ch);
            }
            s.io[off + i] = dry_out * dry_level + sub_in * sub_level;
        }
    }
}
