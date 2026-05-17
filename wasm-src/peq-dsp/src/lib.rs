//! Shared DSP for the 5-Band and 15-Band Parametric EQ WASM crates.
//!
//! `biquad` (direct-form-1 state + coefficient container) and `design`
//! (RBJ-cookbook coefficient design, mirroring `plugins/eq/*_peq.js`) were
//! previously byte-identical copies in each band crate. They now live here so
//! the two ports cannot drift apart.

pub mod biquad;
pub mod design;

// Filter type IDs — must match the JS numeric mapping in the plugin glue.
pub const FT_PEAKING: u32 = 0;
pub const FT_LOWPASS: u32 = 1;
pub const FT_HIGHPASS: u32 = 2;
pub const FT_LOW_SHELF: u32 = 3;
pub const FT_HIGH_SHELF: u32 = 4;
pub const FT_BANDPASS: u32 = 5;
pub const FT_NOTCH: u32 = 6;
pub const FT_ALLPASS: u32 = 7;
