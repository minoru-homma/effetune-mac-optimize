//! WebAssembly port of Spectrum Analyzer's main-thread `process()` work:
//!   - Read circular `averageBuffer` from `bufferPosition`.
//!   - Apply pre-computed Hann window.
//!   - Run radix-2 in-place FFT (matches the JS `1/N` post-scaling form).
//!   - Compute 10·log10 magnitudes with DC/AC dB correction.
//!   - Update peak-hold values with linear decay.
//!
//! The plugin's own canvas drawing remains in JS — that is unchanged here.

const MAX_PT: usize = 14;

// 10 * log10(16) = +12.04dB, 10 * log10(4) = +6.02dB
const CORR_AC: f32 = 12.041_2; // 10*log10(16)
const CORR_DC: f32 = 6.020_6;  // 10*log10(4)
const LOG10_INV: f32 = 0.434_294_5; // 1 / ln(10)

pub struct State {
    pt: u32,
    fft_size: usize,
    half_fft: usize,

    sin_table: Vec<f32>,
    cos_table: Vec<f32>,
    window: Vec<f32>,
    bit_reverse: Vec<u32>,

    // Working buffers
    real: Vec<f32>,
    imag: Vec<f32>,
    in_avg: Vec<f32>,

    // Output buffers
    spectrum: Vec<f32>,
    peaks: Vec<f32>,
}

#[no_mangle]
pub extern "C" fn init(pt: u32) -> *mut State {
    let pt = pt.min(MAX_PT as u32);
    let fft_size = 1usize << pt;
    let half_fft = fft_size >> 1;
    let mut state = Box::new(State {
        pt,
        fft_size,
        half_fft,
        sin_table: vec![0.0; fft_size],
        cos_table: vec![0.0; fft_size],
        window: vec![0.0; fft_size],
        bit_reverse: vec![0; fft_size],
        real: vec![0.0; fft_size],
        imag: vec![0.0; fft_size],
        in_avg: vec![0.0; fft_size],
        spectrum: vec![-144.0; half_fft],
        peaks: vec![-145.0; half_fft],
    });

    let factor = 2.0 * core::f32::consts::PI / fft_size as f32;
    for i in 0..fft_size {
        let t = factor * i as f32;
        state.sin_table[i] = -t.sin();
        state.cos_table[i] = t.cos();
        state.window[i] = 0.5 * (1.0 - t.cos());
    }
    for i in 0..fft_size {
        state.bit_reverse[i] = reverse_bits(i as u32, pt);
    }

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
    s.in_avg.as_mut_ptr()
}

#[no_mangle]
pub extern "C" fn spectrum_ptr(state: *mut State) -> *mut f32 {
    let s = unsafe { &mut *state };
    s.spectrum.as_mut_ptr()
}

#[no_mangle]
pub extern "C" fn peaks_ptr(state: *mut State) -> *mut f32 {
    let s = unsafe { &mut *state };
    s.peaks.as_mut_ptr()
}

#[no_mangle]
pub extern "C" fn fft_size(state: *mut State) -> u32 {
    let s = unsafe { &mut *state };
    s.fft_size as u32
}

/// Run the windowed FFT on a circular `averageBuffer` whose write position is
/// `buffer_position` (mod fft_size). The averageBuffer must already be in the
/// `in_avg` linear-memory slot (use `input_ptr`). Updates `spectrum` in place.
#[no_mangle]
pub extern "C" fn analyze(state: *mut State, buffer_position: u32) {
    let s = unsafe { &mut *state };
    let n = s.fft_size;
    let half = s.half_fft;
    let mask = (n - 1) as u32;

    // Copy windowed circular buffer into real, zero imag.
    let mut pos = buffer_position & mask;
    for i in 0..n {
        s.real[i] = s.in_avg[pos as usize] * s.window[i];
        s.imag[i] = 0.0;
        pos = (pos + 1) & mask;
    }

    // Bit-reversal permutation.
    for i in 0..n {
        let j = s.bit_reverse[i] as usize;
        if j > i {
            s.real.swap(i, j);
            s.imag.swap(i, j);
        }
    }

    // Cooley-Tukey FFT with 1/N normalisation per stage (matches JS reference).
    let mut size = 2usize;
    let mut stage = 1u32;
    while size <= n {
        let half_size = size >> 1;
        let shift = s.pt - stage;
        let mut i = 0usize;
        while i < n {
            let mut j = i;
            let mut k = 0u32;
            while j < i + half_size {
                let table_index = ((k << shift) as usize) & (n - 1);
                let cos = s.cos_table[table_index];
                let sin = s.sin_table[table_index];

                let r_high = s.real[j + half_size];
                let i_high = s.imag[j + half_size];
                let tr = r_high * cos - i_high * sin;
                let ti = r_high * sin + i_high * cos;

                let rj = s.real[j];
                let ij = s.imag[j];
                s.real[j + half_size] = (rj - tr) * 0.5;
                s.imag[j + half_size] = (ij - ti) * 0.5;
                s.real[j] = (rj + tr) * 0.5;
                s.imag[j] = (ij + ti) * 0.5;

                j += 1;
                k += 1;
            }
            i += size;
        }
        size <<= 1;
        stage += 1;
    }

    // Magnitudes -> dB with DC/AC correction.
    for i in 0..half {
        let r = s.real[i];
        let im = s.imag[i];
        let raw_power = r * r + im * im;
        let corr = if i == 0 { CORR_DC } else { CORR_AC };
        // 10 * log10(x) = 10 * ln(x) / ln(10) = 10 * LOG10_INV * ln(x)
        let db = 10.0 * LOG10_INV * (raw_power + 1e-24).ln() + corr;
        s.spectrum[i] = db;
    }
}

/// Apply linear peak decay (in dB) and lift peaks to current spectrum.
#[no_mangle]
pub extern "C" fn update_peaks(state: *mut State, decay_db: f32) {
    let s = unsafe { &mut *state };
    for i in 0..s.half_fft {
        let mut p = s.peaks[i];
        if p.is_nan() || p < -145.0 || p > 0.0 {
            p = -145.0;
        }
        let decayed = p - decay_db;
        let cur = s.spectrum[i];
        let new_peak = if cur > decayed { cur } else { decayed };
        s.peaks[i] = if new_peak < -145.0 {
            -145.0
        } else if new_peak > 0.0 {
            0.0
        } else {
            new_peak
        };
    }
}

#[inline]
fn reverse_bits(mut x: u32, bits: u32) -> u32 {
    let mut result = 0u32;
    for _ in 0..bits {
        result = (result << 1) | (x & 1);
        x >>= 1;
    }
    result
}
