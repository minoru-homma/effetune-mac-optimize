mod filter;
mod envelope;
mod gain;

const MAX_CHANNELS: usize = 8;
const NUM_BANDS: usize = 5;
const NUM_CROSSOVERS: usize = 4;
const MIN_ENV_VAL: f32 = 1e-6;
const DC_OFFSET: f32 = 1e-25;
const LOG2: f32 = core::f32::consts::LN_2;
const GAIN_FACTOR: f32 = 0.115129254649702_f32;

pub struct State {
    sample_rate: f32,
    channel_count: u32,
    max_block_size: u32,

    crossover_freqs: [f32; NUM_CROSSOVERS],

    filter: filter::FilterBank,
    envelopes: [f32; NUM_BANDS * MAX_CHANNELS],

    band_params: [BandParams; NUM_BANDS],
    time_constants: [f32; NUM_BANDS * 2],

    gain_reductions: [f32; NUM_BANDS],
    fade_in: FadeIn,

    input: Vec<f32>,
    output: Vec<f32>,

    band_buffers: Vec<f32>,
    work_buffer: Vec<f32>,

    db_lut: gain::DbLookup,
    exp_lut: gain::ExpLookup,
}

#[derive(Clone, Copy, Default)]
struct BandParams {
    threshold_db: f32,
    ratio: f32,
    attack_ms: f32,
    release_ms: f32,
    knee_db: f32,
    makeup_db: f32,
    half_knee_db: f32,
    slope: f32,
    makeup_linear: f32,
}

#[derive(Clone, Copy)]
struct FadeIn {
    counter: u32,
    length: u32,
}

#[no_mangle]
pub extern "C" fn init(
    sample_rate: f32,
    channel_count: u32,
    max_block_size: u32,
    f1: f32,
    f2: f32,
    f3: f32,
    f4: f32,
) -> *mut State {
    let ch = channel_count.min(MAX_CHANNELS as u32) as usize;
    let bs = max_block_size as usize;

    let freqs = [f1, f2, f3, f4];

    let fade_len = (((sample_rate * 0.005) as u32).max(1)).min(max_block_size);

    let mut state = Box::new(State {
        sample_rate,
        channel_count: ch as u32,
        max_block_size,
        crossover_freqs: freqs,
        filter: filter::FilterBank::new(sample_rate, &freqs, ch),
        envelopes: [MIN_ENV_VAL; NUM_BANDS * MAX_CHANNELS],
        band_params: [BandParams::default(); NUM_BANDS],
        time_constants: [0.0; NUM_BANDS * 2],
        gain_reductions: [0.0; NUM_BANDS],
        fade_in: FadeIn {
            counter: 0,
            length: fade_len,
        },
        input: vec![0.0; bs * MAX_CHANNELS],
        output: vec![0.0; bs * MAX_CHANNELS],
        band_buffers: vec![0.0; bs * NUM_BANDS],
        work_buffer: vec![0.0; bs],
        db_lut: gain::DbLookup::new(),
        exp_lut: gain::ExpLookup::new(),
    });

    for b in 0..NUM_BANDS {
        let p = &mut state.band_params[b];
        p.threshold_db = -24.0;
        p.ratio = 4.0;
        p.attack_ms = 10.0;
        p.release_ms = 100.0;
        p.knee_db = 6.0;
        p.makeup_db = 0.0;
        recompute_band_derived(p);
    }
    recompute_time_constants(&mut state);

    Box::into_raw(state)
}

#[no_mangle]
pub extern "C" fn free_state(state: *mut State) {
    if !state.is_null() {
        unsafe {
            drop(Box::from_raw(state));
        }
    }
}

#[no_mangle]
pub extern "C" fn input_ptr(state: *mut State) -> *mut f32 {
    let s = unsafe { &mut *state };
    s.input.as_mut_ptr()
}

#[no_mangle]
pub extern "C" fn output_ptr(state: *mut State) -> *mut f32 {
    let s = unsafe { &mut *state };
    s.output.as_mut_ptr()
}

#[no_mangle]
pub extern "C" fn gain_reductions_ptr(state: *mut State) -> *mut f32 {
    let s = unsafe { &mut *state };
    s.gain_reductions.as_mut_ptr()
}

#[no_mangle]
pub extern "C" fn set_crossover_freqs(
    state: *mut State,
    f1: f32,
    f2: f32,
    f3: f32,
    f4: f32,
) {
    let s = unsafe { &mut *state };
    let new_freqs = [f1, f2, f3, f4];
    if new_freqs != s.crossover_freqs {
        s.crossover_freqs = new_freqs;
        s.filter = filter::FilterBank::new(s.sample_rate, &new_freqs, s.channel_count as usize);
        s.envelopes = [MIN_ENV_VAL; NUM_BANDS * MAX_CHANNELS];
        s.fade_in.counter = 0;
    }
}

#[no_mangle]
pub extern "C" fn set_band_params(
    state: *mut State,
    band: u32,
    threshold_db: f32,
    ratio: f32,
    attack_ms: f32,
    release_ms: f32,
    knee_db: f32,
    makeup_db: f32,
) {
    let s = unsafe { &mut *state };
    let band = band as usize;
    if band >= NUM_BANDS {
        return;
    }
    let prev = s.band_params[band];
    let p = &mut s.band_params[band];
    p.threshold_db = threshold_db;
    p.ratio = ratio.max(0.5).min(20.0);
    p.attack_ms = attack_ms.max(0.1);
    p.release_ms = release_ms.max(1.0);
    p.knee_db = knee_db.max(0.0);
    p.makeup_db = makeup_db;
    recompute_band_derived(p);

    if prev.attack_ms != p.attack_ms || prev.release_ms != p.release_ms {
        recompute_time_constants(s);
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

    for ch in 0..ch_count {
        let in_offset = ch * bs;
        let out_offset = ch * bs;

        // Split input into 5 bands.
        s.filter.split_bands(
            &s.input[in_offset..in_offset + bs],
            &mut s.band_buffers,
            ch,
            bs,
        );

        // Reset gain_reductions for this block (use max across channels).
        // Output buffer reused per channel; we'll write directly to s.output[out_offset..]
        // After summing bands.
        let env_offset = ch * NUM_BANDS;

        // Zero an accumulator (we use s.output directly as accumulator).
        for i in 0..bs {
            s.output[out_offset + i] = 0.0;
        }

        // Process bands 0-3 with SIMD (4 bands in parallel)
        envelope::process_quad_envelope(
            &s.band_buffers,
            &mut s.envelopes[env_offset..env_offset + 4],
            &s.time_constants[..8],
            bs,
            &mut s.work_buffer,
            &s.band_params[..4],
            &s.db_lut,
            &s.exp_lut,
            &mut s.gain_reductions[..4],
            &mut s.output[out_offset..out_offset + bs],
        );

        // Process band 4 scalar
        envelope::process_scalar_envelope(
            &s.band_buffers[4 * bs..5 * bs],
            &mut s.envelopes[env_offset + 4],
            s.time_constants[8],
            s.time_constants[9],
            bs,
            &mut s.work_buffer,
            &s.band_params[4],
            &s.db_lut,
            &s.exp_lut,
            &mut s.gain_reductions[4],
            &mut s.output[out_offset..out_offset + bs],
        );

        // Apply fade-in if active. Matches the JS plugin where the counter is shared
        // across channels in the same block: by the time channel 1 runs the counter is
        // already at length, so only channel 0 ever sees fade gain. This preserves
        // sample-level parity with the JS reference.
        if s.fade_in.counter < s.fade_in.length {
            let length = s.fade_in.length;
            let length_f = length as f32;
            let mut counter = s.fade_in.counter;
            for i in 0..bs {
                if counter >= length {
                    break;
                }
                let g = (counter as f32) / length_f;
                let g = if g > 1.0 { 1.0 } else { g };
                s.output[out_offset + i] *= g;
                counter += 1;
            }
            s.fade_in.counter = counter;
        }
    }
}

fn recompute_band_derived(p: &mut BandParams) {
    p.half_knee_db = p.knee_db * 0.5;
    p.slope = if (p.ratio - 1.0).abs() < 1e-9 {
        0.0
    } else {
        1.0 - 1.0 / p.ratio
    };
    p.makeup_linear = libm_exp(p.makeup_db * GAIN_FACTOR);
}

fn recompute_time_constants(s: &mut State) {
    let ms_factor = s.sample_rate / 1000.0;
    for b in 0..NUM_BANDS {
        let p = &s.band_params[b];
        let attack_samples = (p.attack_ms * ms_factor).max(1.0);
        let release_samples = (p.release_ms * ms_factor).max(1.0);
        s.time_constants[b * 2] = libm_exp(-LOG2 / attack_samples);
        s.time_constants[b * 2 + 1] = libm_exp(-LOG2 / release_samples);
    }
}

#[inline(always)]
pub(crate) fn libm_exp(x: f32) -> f32 {
    // Polynomial approximation to e^x; sufficient accuracy for audio coefficients.
    // Range reduction: e^x = 2^(x / ln 2). We split x = k*ln2 + r, |r| <= ln2/2.
    let inv_ln2 = 1.4426950408889634_f32;
    let ln2 = 0.6931471805599453_f32;
    let kf = (x * inv_ln2).round();
    let r = x - kf * ln2;
    // Polynomial for e^r on |r| <= ln2/2 ~ 0.347
    let r2 = r * r;
    let r3 = r2 * r;
    let r4 = r2 * r2;
    let er = 1.0
        + r
        + 0.5 * r2
        + 0.16666667 * r3
        + 0.04166667 * r4
        + 0.00833333 * r4 * r;
    // 2^k via bit manipulation
    let ki = kf as i32;
    let bits = ((127i32 + ki) as u32) << 23;
    let two_k = f32::from_bits(bits);
    er * two_k
}
