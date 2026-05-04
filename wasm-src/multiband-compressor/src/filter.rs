//! Linkwitz-Riley 4th-order crossover (two cascaded 2nd-order Butterworth biquads, Q = 1/sqrt(2)).
//!
//! Coefficient design follows the JS reference:
//!   pre-warped bilinear transform, K = 2*fs, warped = 2*fs * tan(pi*fc/fs).
//! For 4th-order Linkwitz-Riley, a Butterworth section is computed and squared (cascaded twice).

use crate::{DC_OFFSET, NUM_CROSSOVERS};

#[derive(Clone, Copy, Default)]
struct Biquad {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
}

#[derive(Clone, Copy)]
struct BiquadState {
    x1: f32,
    x2: f32,
    y1: f32,
    y2: f32,
}

impl Default for BiquadState {
    fn default() -> Self {
        BiquadState {
            x1: DC_OFFSET,
            x2: -DC_OFFSET,
            y1: DC_OFFSET,
            y2: -DC_OFFSET,
        }
    }
}

#[derive(Clone, Copy, Default)]
struct LRSection {
    stage1: Biquad,
    stage2: Biquad,
}

#[derive(Clone, Copy, Default)]
struct LRStateChannel {
    stage1: BiquadState,
    stage2: BiquadState,
}

pub struct FilterBank {
    lp_coeffs: [LRSection; NUM_CROSSOVERS],
    hp_coeffs: [LRSection; NUM_CROSSOVERS],
    lp_state: [[LRStateChannel; 8]; NUM_CROSSOVERS],
    hp_state: [[LRStateChannel; 8]; NUM_CROSSOVERS],
}

impl FilterBank {
    pub fn new(sample_rate: f32, frequencies: &[f32; NUM_CROSSOVERS], _channel_count: usize) -> Self {
        let mut lp_coeffs = [LRSection::default(); NUM_CROSSOVERS];
        let mut hp_coeffs = [LRSection::default(); NUM_CROSSOVERS];

        for i in 0..NUM_CROSSOVERS {
            let f = frequencies[i].max(10.0).min(sample_rate * 0.499);
            lp_coeffs[i] = design_lr4(sample_rate, f, true);
            hp_coeffs[i] = design_lr4(sample_rate, f, false);
        }

        FilterBank {
            lp_coeffs,
            hp_coeffs,
            lp_state: [[LRStateChannel::default(); 8]; NUM_CROSSOVERS],
            hp_state: [[LRStateChannel::default(); 8]; NUM_CROSSOVERS],
        }
    }

    pub fn split_bands(
        &mut self,
        input: &[f32],
        band_buffers: &mut [f32],
        ch: usize,
        block_size: usize,
    ) {
        // band_buffers layout: 5 bands * block_size, contiguous per band.
        // Use stack-allocated temp buffers (max block size 1024 supported here).
        let mut hp1 = [0.0f32; 1024];
        let mut hp2 = [0.0f32; 1024];
        debug_assert!(block_size <= 1024);
        let bs = block_size;

        // Band 0: input -> LP[0]
        let band0 = &mut band_buffers[0..bs];
        apply_lr(&self.lp_coeffs[0], &mut self.lp_state[0][ch], input, band0, bs);

        // hp1 = HP[0](input)
        apply_lr(&self.hp_coeffs[0], &mut self.hp_state[0][ch], input, &mut hp1[..bs], bs);

        // Band 1: hp1 -> LP[1]
        let band1 = &mut band_buffers[bs..2 * bs];
        apply_lr(&self.lp_coeffs[1], &mut self.lp_state[1][ch], &hp1[..bs], band1, bs);

        // hp2 = HP[1](hp1)
        apply_lr(&self.hp_coeffs[1], &mut self.hp_state[1][ch], &hp1[..bs], &mut hp2[..bs], bs);

        // Band 2: hp2 -> LP[2]
        let band2 = &mut band_buffers[2 * bs..3 * bs];
        apply_lr(&self.lp_coeffs[2], &mut self.lp_state[2][ch], &hp2[..bs], band2, bs);

        // hp1 reused = HP[2](hp2)
        apply_lr(&self.hp_coeffs[2], &mut self.hp_state[2][ch], &hp2[..bs], &mut hp1[..bs], bs);

        // Band 3: hp1 -> LP[3]
        let band3 = &mut band_buffers[3 * bs..4 * bs];
        apply_lr(&self.lp_coeffs[3], &mut self.lp_state[3][ch], &hp1[..bs], band3, bs);

        // Band 4: hp1 -> HP[3]
        let band4 = &mut band_buffers[4 * bs..5 * bs];
        apply_lr(&self.hp_coeffs[3], &mut self.hp_state[3][ch], &hp1[..bs], band4, bs);
    }
}

#[inline(always)]
fn apply_lr(
    coeffs: &LRSection,
    state: &mut LRStateChannel,
    input: &[f32],
    output: &mut [f32],
    block_size: usize,
) {
    let s1 = &coeffs.stage1;
    let s2 = &coeffs.stage2;

    let (mut s1_x1, mut s1_x2, mut s1_y1, mut s1_y2) = (
        state.stage1.x1,
        state.stage1.x2,
        state.stage1.y1,
        state.stage1.y2,
    );
    let (mut s2_x1, mut s2_x2, mut s2_y1, mut s2_y2) = (
        state.stage2.x1,
        state.stage2.x2,
        state.stage2.y1,
        state.stage2.y2,
    );

    for i in 0..block_size {
        let x = input[i];
        let y1 = s1.b0 * x + s1.b1 * s1_x1 + s1.b2 * s1_x2 - s1.a1 * s1_y1 - s1.a2 * s1_y2;
        s1_x2 = s1_x1;
        s1_x1 = x;
        s1_y2 = s1_y1;
        s1_y1 = y1;

        let y2 = s2.b0 * y1 + s2.b1 * s2_x1 + s2.b2 * s2_x2 - s2.a1 * s2_y1 - s2.a2 * s2_y2;
        s2_x2 = s2_x1;
        s2_x1 = y1;
        s2_y2 = s2_y1;
        s2_y1 = y2;

        output[i] = y2;
    }

    state.stage1.x1 = s1_x1;
    state.stage1.x2 = s1_x2;
    state.stage1.y1 = s1_y1;
    state.stage1.y2 = s1_y2;
    state.stage2.x1 = s2_x1;
    state.stage2.x2 = s2_x2;
    state.stage2.y1 = s2_y1;
    state.stage2.y2 = s2_y2;
}

fn design_lr4(fs: f32, fc: f32, is_lp: bool) -> LRSection {
    let butter = design_butterworth_section(fs, fc, is_lp);
    LRSection {
        stage1: butter,
        stage2: butter,
    }
}

fn design_butterworth_section(fs: f32, fc: f32, is_lp: bool) -> Biquad {
    // 2nd-order Butterworth, Q = 1/sqrt(2).
    let q = core::f32::consts::FRAC_1_SQRT_2;
    let k = 2.0 * fs;
    let warped = 2.0 * fs * libm_tan(core::f32::consts::PI * fc / fs);
    let om = warped;
    let k2 = k * k;
    let om2 = om * om;
    let k2q = k2 * q;
    let om2q = om2 * q;
    let a0 = k2q + k * om + om2q;
    let a1 = -2.0 * k2q + 2.0 * om2q;
    let a2 = k2q - k * om + om2q;
    let (b0, b1, b2) = if is_lp {
        (om2q, 2.0 * om2q, om2q)
    } else {
        (k2q, -2.0 * k2q, k2q)
    };
    Biquad {
        b0: b0 / a0,
        b1: b1 / a0,
        b2: b2 / a0,
        a1: a1 / a0,
        a2: a2 / a0,
    }
}

#[inline]
fn libm_tan(x: f32) -> f32 {
    // tan(x) = sin(x) / cos(x) using Maclaurin series; fc/fs is bounded so x in (0, pi/2 ~ 1.57).
    // Range-reduce to |y| <= pi/4 for accuracy.
    let pi = core::f32::consts::PI;
    let half_pi = pi * 0.5;
    let mut y = x;
    let mut sign = 1.0_f32;
    let mut reciprocal = false;
    if y > half_pi {
        y = pi - y;
        sign = -1.0;
    }
    let quarter_pi = core::f32::consts::FRAC_PI_4;
    if y > quarter_pi {
        y = half_pi - y;
        reciprocal = true;
    }
    // Polynomial approximations on [0, pi/4]
    let y2 = y * y;
    let sin_y = y * (1.0 - y2 * (1.0 / 6.0 - y2 * (1.0 / 120.0 - y2 * (1.0 / 5040.0))));
    let cos_y = 1.0 - y2 * (0.5 - y2 * (1.0 / 24.0 - y2 * (1.0 / 720.0 - y2 * (1.0 / 40320.0))));
    let t = if reciprocal { cos_y / sin_y } else { sin_y / cos_y };
    sign * t
}
