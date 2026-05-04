//! WebAssembly port of the 5-Band Parametric EQ.
//!
//! The DSP path mirrors `plugins/eq/five_band_peq.js`: 5 cascaded biquads per channel
//! using RBJ-cookbook coefficient designs. Inactive bands (disabled, or peak/shelf
//! with negligible gain) are skipped at runtime.
//!
//! IIR filters are inherently serial, so this port focuses on removing JS overhead
//! and uses WASM SIMD only to process two channels of a single biquad in parallel.

mod biquad;
mod design;

const NUM_BANDS: usize = 5;
const MAX_CHANNELS: usize = 8;

// Filter type IDs — must match JS numeric mapping in the plugin glue.
pub const FT_PEAKING: u32 = 0;
pub const FT_LOWPASS: u32 = 1;
pub const FT_HIGHPASS: u32 = 2;
pub const FT_LOW_SHELF: u32 = 3;
pub const FT_HIGH_SHELF: u32 = 4;
pub const FT_BANDPASS: u32 = 5;
pub const FT_NOTCH: u32 = 6;
pub const FT_ALLPASS: u32 = 7;

#[derive(Clone, Copy)]
struct BandConfig {
    enabled: bool,
    bypassed: bool,
    type_id: u32,
    freq: f32,
    gain_db: f32,
    q: f32,
    coeffs: biquad::Coeffs,
}

impl Default for BandConfig {
    fn default() -> Self {
        BandConfig {
            enabled: false,
            bypassed: true,
            type_id: FT_PEAKING,
            freq: 1000.0,
            gain_db: 0.0,
            q: 1.0,
            coeffs: biquad::Coeffs::identity(),
        }
    }
}

pub struct State {
    sample_rate: f32,
    channel_count: u32,
    max_block_size: u32,
    bands: [BandConfig; NUM_BANDS],
    states: [[biquad::BiquadState; MAX_CHANNELS]; NUM_BANDS],
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
        bands: [BandConfig::default(); NUM_BANDS],
        states: [[biquad::BiquadState::default(); MAX_CHANNELS]; NUM_BANDS],
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
pub extern "C" fn set_band(
    state: *mut State,
    band: u32,
    enabled: u32,
    type_id: u32,
    freq: f32,
    gain_db: f32,
    q: f32,
) {
    let s = unsafe { &mut *state };
    let band = band as usize;
    if band >= NUM_BANDS {
        return;
    }
    let cfg = &mut s.bands[band];
    cfg.enabled = enabled != 0;
    cfg.type_id = type_id;
    cfg.freq = freq;
    cfg.gain_db = gain_db;
    cfg.q = q;

    let (coeffs, bypassed) = design::design(s.sample_rate, type_id, freq, gain_db, q, cfg.enabled);
    cfg.coeffs = coeffs;
    cfg.bypassed = bypassed;
}

#[no_mangle]
pub extern "C" fn process_block(state: *mut State, block_size: u32) {
    let s = unsafe { &mut *state };
    let bs = block_size as usize;
    let ch_count = s.channel_count as usize;
    if bs == 0 || bs > s.max_block_size as usize {
        return;
    }

    if ch_count == 2 {
        // Stereo SIMD path: process both channels of every active band in parallel.
        process_stereo_simd(s, bs);
    } else {
        process_scalar(s, bs, ch_count);
    }
}

fn process_scalar(s: &mut State, bs: usize, ch_count: usize) {
    for ch in 0..ch_count {
        let offset = ch * bs;
        for band in 0..NUM_BANDS {
            let cfg = &s.bands[band];
            if cfg.bypassed {
                continue;
            }
            let c = &cfg.coeffs;
            let st = &mut s.states[band][ch];
            let (mut x1, mut x2) = (st.x1, st.x2);
            let (mut y1, mut y2) = (st.y1, st.y2);
            let slice = &mut s.io[offset..offset + bs];
            for sample in slice.iter_mut() {
                let x = *sample;
                let y = c.b0 * x + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2;
                x2 = x1;
                x1 = x;
                y2 = y1;
                y1 = y;
                *sample = y;
            }
            st.x1 = x1;
            st.x2 = x2;
            st.y1 = y1;
            st.y2 = y2;
        }
    }
}

#[cfg(target_arch = "wasm32")]
#[target_feature(enable = "simd128")]
fn process_stereo_simd(s: &mut State, bs: usize) {
    use core::arch::wasm32::*;
    let left_off = 0;
    let right_off = bs;
    for band in 0..NUM_BANDS {
        let cfg = &s.bands[band];
        if cfg.bypassed {
            continue;
        }
        let c = &cfg.coeffs;
        let b0 = f32x4_splat(c.b0);
        let b1 = f32x4_splat(c.b1);
        let b2 = f32x4_splat(c.b2);
        let a1 = f32x4_splat(c.a1);
        let a2 = f32x4_splat(c.a2);

        let st_l = &s.states[band][0];
        let st_r = &s.states[band][1];
        // Pack as [L, R, _, _]; only the first two lanes matter.
        let mut x1 = f32x4(st_l.x1, st_r.x1, 0.0, 0.0);
        let mut x2 = f32x4(st_l.x2, st_r.x2, 0.0, 0.0);
        let mut y1 = f32x4(st_l.y1, st_r.y1, 0.0, 0.0);
        let mut y2 = f32x4(st_l.y2, st_r.y2, 0.0, 0.0);

        // SAFETY: indices stay in bounds because bs ≤ max_block_size and
        // io is sized for max_block_size * MAX_CHANNELS.
        let io = &mut s.io[..];
        for i in 0..bs {
            let xl = io[left_off + i];
            let xr = io[right_off + i];
            let x = f32x4(xl, xr, 0.0, 0.0);

            // y = b0*x + b1*x1 + b2*x2 - a1*y1 - a2*y2
            let mut y = f32x4_mul(b0, x);
            y = f32x4_add(y, f32x4_mul(b1, x1));
            y = f32x4_add(y, f32x4_mul(b2, x2));
            y = f32x4_sub(y, f32x4_mul(a1, y1));
            y = f32x4_sub(y, f32x4_mul(a2, y2));

            io[left_off + i] = f32x4_extract_lane::<0>(y);
            io[right_off + i] = f32x4_extract_lane::<1>(y);

            x2 = x1;
            x1 = x;
            y2 = y1;
            y1 = y;
        }

        let st = &mut s.states[band];
        st[0].x1 = f32x4_extract_lane::<0>(x1);
        st[0].x2 = f32x4_extract_lane::<0>(x2);
        st[0].y1 = f32x4_extract_lane::<0>(y1);
        st[0].y2 = f32x4_extract_lane::<0>(y2);
        st[1].x1 = f32x4_extract_lane::<1>(x1);
        st[1].x2 = f32x4_extract_lane::<1>(x2);
        st[1].y1 = f32x4_extract_lane::<1>(y1);
        st[1].y2 = f32x4_extract_lane::<1>(y2);
    }
}

#[cfg(not(target_arch = "wasm32"))]
fn process_stereo_simd(s: &mut State, bs: usize) {
    process_scalar(s, bs, 2);
}
