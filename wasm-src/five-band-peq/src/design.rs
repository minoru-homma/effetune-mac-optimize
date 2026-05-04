//! RBJ-cookbook biquad coefficient design, mirroring `plugins/eq/five_band_peq.js`.
//! Returns (coefficients, bypassed). When `bypassed` is true the band should be
//! skipped entirely (identity transfer).

use crate::biquad::Coeffs;
use crate::{
    FT_ALLPASS, FT_BANDPASS, FT_HIGH_SHELF, FT_HIGHPASS, FT_LOW_SHELF, FT_LOWPASS, FT_NOTCH,
    FT_PEAKING,
};

const PI: f32 = core::f32::consts::PI;
const TWO_PI: f32 = 2.0 * PI;
const BYPASS_THRESHOLD: f32 = 0.01;
const A0_THRESHOLD: f32 = 1e-8;
const SHELF_Q_MAX: f32 = 2.0;
const GENERAL_Q_MIN: f32 = 0.1;

pub fn design(
    sample_rate: f32,
    type_id: u32,
    freq: f32,
    gain_db: f32,
    q_in: f32,
    enabled: bool,
) -> (Coeffs, bool) {
    if !enabled {
        return (Coeffs::identity(), true);
    }

    let is_shelf = type_id == FT_LOW_SHELF || type_id == FT_HIGH_SHELF;
    let mut q = q_in;
    if is_shelf && q > SHELF_Q_MAX {
        q = SHELF_Q_MAX;
    }
    if q < GENERAL_Q_MIN {
        q = GENERAL_Q_MIN;
    }

    let gain_abs = if gain_db < 0.0 { -gain_db } else { gain_db };
    let gain_independent = matches!(
        type_id,
        FT_LOWPASS | FT_HIGHPASS | FT_BANDPASS | FT_NOTCH | FT_ALLPASS
    );
    if gain_abs < BYPASS_THRESHOLD && !gain_independent {
        return (Coeffs::identity(), true);
    }

    let a = pow10(0.025 * gain_db); // 10^(gain/40) = sqrt(10^(gain/20))
    let w0 = freq * TWO_PI / sample_rate;
    let w0c = clamp(w0, 1e-6, PI - 1e-6);
    let cos_w0 = cosf(w0c);
    let sin_w0 = sinf(w0c);
    let alpha = sin_w0 / (2.0 * q);

    #[allow(unused_assignments)]
    let (mut b0, mut b1, mut b2, mut a0, mut a1, mut a2) = (0.0f32, 0.0f32, 0.0f32, 1.0f32, 0.0f32, 0.0f32);

    match type_id {
        x if x == FT_PEAKING => {
            let alpha_mul = alpha * a;
            let alpha_div = alpha / a;
            let neg_2cos = -2.0 * cos_w0;
            b0 = 1.0 + alpha_mul;
            b1 = neg_2cos;
            b2 = 1.0 - alpha_mul;
            a0 = 1.0 + alpha_div;
            a1 = neg_2cos;
            a2 = 1.0 - alpha_div;
        }
        x if x == FT_LOWPASS => {
            let one_minus = 1.0 - cos_w0;
            let neg_2cos = -2.0 * cos_w0;
            b0 = one_minus * 0.5;
            b1 = one_minus;
            b2 = b0;
            a0 = 1.0 + alpha;
            a1 = neg_2cos;
            a2 = 1.0 - alpha;
        }
        x if x == FT_HIGHPASS => {
            let one_plus = 1.0 + cos_w0;
            let neg_2cos = -2.0 * cos_w0;
            b0 = one_plus * 0.5;
            b1 = -one_plus;
            b2 = b0;
            a0 = 1.0 + alpha;
            a1 = neg_2cos;
            a2 = 1.0 - alpha;
        }
        x if x == FT_LOW_SHELF => {
            let sqrt_a = sqrtf(if a < 0.0 { 0.0 } else { a });
            let two_sqrt_a_alpha = 2.0 * sqrt_a * alpha;
            let a_plus_1 = a + 1.0;
            let a_minus_1 = a - 1.0;
            let term1 = a_plus_1 - a_minus_1 * cos_w0;
            let term2 = a_plus_1 + a_minus_1 * cos_w0;
            b0 = a * (term1 + two_sqrt_a_alpha);
            b1 = 2.0 * a * (a_minus_1 - a_plus_1 * cos_w0);
            b2 = a * (term1 - two_sqrt_a_alpha);
            a0 = term2 + two_sqrt_a_alpha;
            a1 = -2.0 * (a_minus_1 + a_plus_1 * cos_w0);
            a2 = term2 - two_sqrt_a_alpha;
        }
        x if x == FT_HIGH_SHELF => {
            let sqrt_a = sqrtf(if a < 0.0 { 0.0 } else { a });
            let two_sqrt_a_alpha = 2.0 * sqrt_a * alpha;
            let a_plus_1 = a + 1.0;
            let a_minus_1 = a - 1.0;
            let term1 = a_plus_1 + a_minus_1 * cos_w0;
            let term2 = a_plus_1 - a_minus_1 * cos_w0;
            b0 = a * (term1 + two_sqrt_a_alpha);
            b1 = -2.0 * a * (a_minus_1 + a_plus_1 * cos_w0);
            b2 = a * (term1 - two_sqrt_a_alpha);
            a0 = term2 + two_sqrt_a_alpha;
            a1 = 2.0 * (a_minus_1 - a_plus_1 * cos_w0);
            a2 = term2 - two_sqrt_a_alpha;
        }
        x if x == FT_BANDPASS => {
            let neg_2cos = -2.0 * cos_w0;
            b0 = alpha;
            b1 = 0.0;
            b2 = -alpha;
            a0 = 1.0 + alpha;
            a1 = neg_2cos;
            a2 = 1.0 - alpha;
        }
        x if x == FT_NOTCH => {
            let neg_2cos = -2.0 * cos_w0;
            b0 = 1.0;
            b1 = neg_2cos;
            b2 = 1.0;
            a0 = 1.0 + alpha;
            a1 = neg_2cos;
            a2 = 1.0 - alpha;
        }
        x if x == FT_ALLPASS => {
            let neg_2cos = -2.0 * cos_w0;
            b0 = 1.0 - alpha;
            b1 = neg_2cos;
            b2 = 1.0 + alpha;
            a0 = 1.0 + alpha;
            a1 = neg_2cos;
            a2 = 1.0 - alpha;
        }
        _ => return (Coeffs::identity(), true),
    }

    let a0_abs = if a0 < 0.0 { -a0 } else { a0 };
    if a0_abs < A0_THRESHOLD {
        return (Coeffs::identity(), true);
    }
    let inv_a0 = 1.0 / a0;
    (
        Coeffs {
            b0: b0 * inv_a0,
            b1: b1 * inv_a0,
            b2: b2 * inv_a0,
            a1: a1 * inv_a0,
            a2: a2 * inv_a0,
        },
        false,
    )
}

#[inline]
fn clamp(x: f32, lo: f32, hi: f32) -> f32 {
    if x < lo { lo } else if x > hi { hi } else { x }
}

// Math intrinsics (libm-free f32 implementations).

#[inline]
fn pow10(x: f32) -> f32 {
    (x * core::f32::consts::LN_10).exp()
}

#[inline]
fn sinf(x: f32) -> f32 {
    x.sin()
}

#[inline]
fn cosf(x: f32) -> f32 {
    x.cos()
}

#[inline]
fn sqrtf(x: f32) -> f32 {
    if x <= 0.0 { 0.0 } else { x.sqrt() }
}
