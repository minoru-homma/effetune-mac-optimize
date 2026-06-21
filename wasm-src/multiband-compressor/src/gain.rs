//! dB conversion + linear-gain LUTs, matching the JS reference.
//!
//! - DbLookup: maps absolute envelope (0..10) -> dB (-120..+20). 4096 entries.
//! - ExpLookup: maps gain reduction in dB (0..60) -> linear gain (1..~0.001). 2048 entries.

use crate::{GAIN_FACTOR, MIN_ENV_VAL};

const DB_LOOKUP_SIZE: usize = 4096;
const DB_LOOKUP_RANGE: f32 = 10.0;
const EXP_LOOKUP_SIZE: usize = 2048;
const EXP_LOOKUP_RANGE: f32 = 60.0;
const MIN_DB_VALUE: f32 = -120.0;
const LOG10_20: f32 = 8.685_889_6_f32;

pub struct DbLookup {
    table: [f32; DB_LOOKUP_SIZE],
    scale: f32,
}

impl DbLookup {
    pub fn new() -> Self {
        let scale = DB_LOOKUP_SIZE as f32 / DB_LOOKUP_RANGE;
        let mut table = [0.0f32; DB_LOOKUP_SIZE];
        for i in 0..DB_LOOKUP_SIZE {
            let x = i as f32 / scale;
            table[i] = if x < MIN_ENV_VAL {
                MIN_DB_VALUE
            } else {
                LOG10_20 * libm_ln(x)
            };
        }
        DbLookup { table, scale }
    }

    #[inline(always)]
    pub fn lookup(&self, x: f32) -> f32 {
        if x < MIN_ENV_VAL {
            return MIN_DB_VALUE;
        }
        let idx = (x * self.scale) as i32;
        let idx = idx.clamp(0, (DB_LOOKUP_SIZE - 1) as i32) as usize;
        self.table[idx]
    }
}

pub struct ExpLookup {
    table: [f32; EXP_LOOKUP_SIZE],
    scale: f32,
}

impl ExpLookup {
    pub fn new() -> Self {
        let scale = EXP_LOOKUP_SIZE as f32 / EXP_LOOKUP_RANGE;
        let mut table = [0.0f32; EXP_LOOKUP_SIZE];
        for i in 0..EXP_LOOKUP_SIZE {
            let x_db = i as f32 / scale;
            table[i] = libm_exp_neg(x_db * GAIN_FACTOR);
        }
        ExpLookup { table, scale }
    }

    #[inline(always)]
    pub fn lookup(&self, gain_reduction_db: f32) -> f32 {
        if gain_reduction_db <= 0.0 {
            return 1.0;
        }
        if gain_reduction_db >= EXP_LOOKUP_RANGE {
            return self.table[EXP_LOOKUP_SIZE - 1];
        }
        let idx = (gain_reduction_db * self.scale) as i32;
        let idx = idx.clamp(0, (EXP_LOOKUP_SIZE - 1) as i32) as usize;
        self.table[idx]
    }
}

#[inline(always)]
fn libm_ln(x: f32) -> f32 {
    // Decompose x = 2^k * m, m in [1, 2). ln(x) = k*ln2 + ln(m).
    let bits = x.to_bits();
    let exp_unbiased = ((bits >> 23) & 0xff) as i32 - 127;
    let mantissa_bits = (bits & 0x7f_ffff) | (127u32 << 23);
    let m = f32::from_bits(mantissa_bits); // m in [1, 2)
    let k = exp_unbiased as f32;

    // Polynomial for ln(m) on [1, 2) using y = (m-1)/(m+1), ln(m) = 2*(y + y^3/3 + y^5/5 + ...)
    let y = (m - 1.0) / (m + 1.0);
    let y2 = y * y;
    let ln_m = 2.0 * y * (1.0 + y2 * (1.0 / 3.0 + y2 * (1.0 / 5.0 + y2 * (1.0 / 7.0))));

    k * core::f32::consts::LN_2 + ln_m
}

#[inline(always)]
fn libm_exp_neg(x: f32) -> f32 {
    // Compute e^(-x) where x >= 0.
    crate::libm_exp(-x)
}
