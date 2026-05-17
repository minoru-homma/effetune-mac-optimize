//! Biquad direct-form 1 state and coefficient container.
//!
//! State and coefficients are kept in f64 to match the JS reference, which
//! does all arithmetic in IEEE-754 double (JS numbers) and only the final
//! sample store is rounded to f32 (Float32Array). Keeping the recursion in
//! f64 removes the high-Q / low-frequency noise-floor divergence the old
//! all-f32 port had (see the A/B parity gate).

#[derive(Clone, Copy, Default)]
pub struct BiquadState {
    pub x1: f64,
    pub x2: f64,
    pub y1: f64,
    pub y2: f64,
}

#[derive(Clone, Copy)]
pub struct Coeffs {
    pub b0: f64,
    pub b1: f64,
    pub b2: f64,
    pub a1: f64,
    pub a2: f64,
}

impl Coeffs {
    pub fn identity() -> Self {
        Coeffs {
            b0: 1.0,
            b1: 0.0,
            b2: 0.0,
            a1: 0.0,
            a2: 0.0,
        }
    }
}
