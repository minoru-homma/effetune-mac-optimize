//! Fused envelope follower + gain calculation + apply, mirroring the JS reference.
//!
//! Two entry points:
//! - process_quad_envelope: 4 bands processed in parallel using array-of-4 patterns that
//!   LLVM auto-vectorises to WASM SIMD f32x4 with `target-feature=+simd128`.
//! - process_scalar_envelope: scalar version for the 5th band.
//!
//! Both paths apply makeup gain and accumulate into the per-channel output buffer.

use crate::gain::{DbLookup, ExpLookup};
use crate::{BandParams, MIN_ENV_VAL};

#[inline(always)]
pub fn process_quad_envelope(
    band_buffers: &[f32],
    envelopes: &mut [f32],
    time_constants: &[f32], // [a0, r0, a1, r1, a2, r2, a3, r3]
    block_size: usize,
    _work_buffer: &mut [f32],
    band_params: &[BandParams],
    db_lut: &DbLookup,
    exp_lut: &ExpLookup,
    gain_reductions: &mut [f32],
    output: &mut [f32],
) {
    debug_assert_eq!(envelopes.len(), 4);
    debug_assert_eq!(band_params.len(), 4);
    debug_assert_eq!(gain_reductions.len(), 4);
    debug_assert!(time_constants.len() >= 8);

    let bs = block_size;
    // Pre-load per-band scalars into 4-arrays (auto-vectorisable).
    let attacks = [
        time_constants[0],
        time_constants[2],
        time_constants[4],
        time_constants[6],
    ];
    let releases = [
        time_constants[1],
        time_constants[3],
        time_constants[5],
        time_constants[7],
    ];
    let thresholds = [
        band_params[0].threshold_db,
        band_params[1].threshold_db,
        band_params[2].threshold_db,
        band_params[3].threshold_db,
    ];
    let half_knees = [
        band_params[0].half_knee_db,
        band_params[1].half_knee_db,
        band_params[2].half_knee_db,
        band_params[3].half_knee_db,
    ];
    let knees = [
        band_params[0].knee_db,
        band_params[1].knee_db,
        band_params[2].knee_db,
        band_params[3].knee_db,
    ];
    let slopes = [
        band_params[0].slope,
        band_params[1].slope,
        band_params[2].slope,
        band_params[3].slope,
    ];
    let makeups = [
        band_params[0].makeup_linear,
        band_params[1].makeup_linear,
        band_params[2].makeup_linear,
        band_params[3].makeup_linear,
    ];

    let mut env = [
        envelopes[0],
        envelopes[1],
        envelopes[2],
        envelopes[3],
    ];

    let mut last_gain_change_abs = [0.0f32; 4];

    for i in 0..bs {
        // Gather samples from 4 bands at index i.
        let s = [
            band_buffers[0 * bs + i],
            band_buffers[1 * bs + i],
            band_buffers[2 * bs + i],
            band_buffers[3 * bs + i],
        ];

        // Envelope follower (4-way SIMD friendly).
        let mut abs_s = [0.0f32; 4];
        let mut coeff = [0.0f32; 4];
        for k in 0..4 {
            abs_s[k] = if s[k] >= 0.0 { s[k] } else { -s[k] };
            coeff[k] = if abs_s[k] > env[k] { attacks[k] } else { releases[k] };
        }
        for k in 0..4 {
            env[k] = env[k] * coeff[k] + abs_s[k] * (1.0 - coeff[k]);
            if env[k] < MIN_ENV_VAL {
                env[k] = MIN_ENV_VAL;
            }
        }

        // dB conversion (scalar gather from LUT, 4 lookups).
        let env_db = [
            db_lut.lookup(env[0]),
            db_lut.lookup(env[1]),
            db_lut.lookup(env[2]),
            db_lut.lookup(env[3]),
        ];

        // Gain change calculation: branchless soft-knee for compression / expansion.
        let mut gain_change = [0.0f32; 4];
        for k in 0..4 {
            let diff = env_db[k] - thresholds[k];
            let above = diff >= half_knees[k];
            let below = diff <= -half_knees[k];
            let in_knee = !above & !below;
            let above_val = diff * slopes[k];
            let knee = knees[k];
            let inv_knee = if knee > 1e-9 { 1.0 / knee } else { 0.0 };
            let t = (diff + half_knees[k]) * inv_knee;
            let in_knee_val = slopes[k] * knee * t * t * 0.5;
            gain_change[k] = if below {
                0.0
            } else if above {
                above_val
            } else if in_knee {
                in_knee_val
            } else {
                0.0
            };
        }

        // Apply gain (gain_change > 0 = reduce; < 0 = boost).
        let mut gain_mult = [0.0f32; 4];
        for k in 0..4 {
            let abs_gc = if gain_change[k] >= 0.0 { gain_change[k] } else { -gain_change[k] };
            let fe = exp_lut.lookup(abs_gc);
            gain_mult[k] = if gain_change[k] >= 0.0 {
                fe
            } else if fe > 1e-30 {
                1.0 / fe
            } else {
                1.0
            };
            last_gain_change_abs[k] = abs_gc;
        }

        // Sum 4 bands into output[i].
        let mut acc = output[i];
        for k in 0..4 {
            acc += s[k] * makeups[k] * gain_mult[k];
        }
        output[i] = acc;
    }

    // Persist envelope state and gain reductions for metering.
    for k in 0..4 {
        envelopes[k] = env[k];
        gain_reductions[k] = if last_gain_change_abs[k] < 0.0 {
            0.0
        } else {
            last_gain_change_abs[k]
        };
    }
}

#[inline(always)]
pub fn process_scalar_envelope(
    band_buffer: &[f32],
    envelope_state: &mut f32,
    attack_coeff: f32,
    release_coeff: f32,
    block_size: usize,
    _work_buffer: &mut [f32],
    params: &BandParams,
    db_lut: &DbLookup,
    exp_lut: &ExpLookup,
    gain_reduction: &mut f32,
    output: &mut [f32],
) {
    let bs = block_size;
    let mut env = *envelope_state;
    let threshold = params.threshold_db;
    let half_knee = params.half_knee_db;
    let knee = params.knee_db;
    let slope = params.slope;
    let makeup = params.makeup_linear;
    let inv_knee = if knee > 1e-9 { 1.0 / knee } else { 0.0 };

    let mut last_gain_change_abs = 0.0f32;

    for i in 0..bs {
        let s = band_buffer[i];
        let abs_s = if s >= 0.0 { s } else { -s };
        let coeff = if abs_s > env { attack_coeff } else { release_coeff };
        env = env * coeff + abs_s * (1.0 - coeff);
        if env < MIN_ENV_VAL {
            env = MIN_ENV_VAL;
        }

        let env_db = db_lut.lookup(env);
        let diff = env_db - threshold;
        let gain_change = if diff <= -half_knee {
            0.0
        } else if diff >= half_knee {
            diff * slope
        } else {
            let t = (diff + half_knee) * inv_knee;
            slope * knee * t * t * 0.5
        };

        let abs_gc = if gain_change >= 0.0 { gain_change } else { -gain_change };
        let fe = exp_lut.lookup(abs_gc);
        let mult = if gain_change >= 0.0 {
            fe
        } else if fe > 1e-30 {
            1.0 / fe
        } else {
            1.0
        };
        output[i] += s * makeup * mult;
        last_gain_change_abs = abs_gc;
    }

    *envelope_state = env;
    *gain_reduction = last_gain_change_abs.max(0.0);
}
