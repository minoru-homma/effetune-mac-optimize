//! Polyphase FIR filter design and storage, mirroring the JS reference plugin.
//!
//! - Prototype filter: Kaiser-windowed sinc, length N=63 (linear-phase Type-1).
//! - Beta = 5.0, normalised so Σ h = L (gives unit DC gain after L-fold up/down).
//! - Decomposed into L polyphase branches, each of length ⌈(N - p) / L⌉.

const N: usize = 63;
const BETA: f32 = 5.0;
const PI: f32 = core::f32::consts::PI;

pub struct PolyphaseFilters {
    /// L polyphase branches. branches[p][k] = h[p + L*k].
    pub branches: Vec<Vec<f32>>,
    /// Maximum length across branches (for state-buffer sizing).
    pub max_phase_len: usize,
    pub n: usize,
}

impl PolyphaseFilters {
    pub fn design(l: usize) -> Self {
        debug_assert!(l >= 1);
        let half_n = (N as f32 - 1.0) * 0.5;
        let i0_beta = bessel_i0(BETA);
        let inv_i0_beta = 1.0 / i0_beta;
        let inv_l = 1.0 / l as f32;

        // Build prototype filter h[0..N].
        let mut h = vec![0.0f32; N];
        let mut sum = 0.0f32;
        for n in 0..N {
            let arg = (n as f32 - half_n) * inv_l;
            let s = sinc(arg);
            let w = kaiser_window(n, N, inv_i0_beta);
            let hn = s * w;
            h[n] = hn;
            sum += hn;
        }
        // Normalise so Σ h == L (preserves amplitude after L-fold up/down).
        let scale = l as f32 / sum;
        for v in h.iter_mut() {
            *v *= scale;
        }

        // Polyphase decomposition: branch p contains coefficients h[p + L*k].
        let mut branches = Vec::with_capacity(l);
        let mut max_phase_len = 0usize;
        for p in 0..l {
            let phase_len = (N - p + l - 1) / l; // ⌈(N - p)/L⌉
            if phase_len > max_phase_len {
                max_phase_len = phase_len;
            }
            let mut coeffs = vec![0.0f32; phase_len];
            for k in 0..phase_len {
                let proto_idx = p + l * k;
                if proto_idx < N {
                    coeffs[k] = h[proto_idx];
                }
            }
            branches.push(coeffs);
        }

        PolyphaseFilters {
            branches,
            max_phase_len,
            n: N,
        }
    }
}

#[inline]
fn sinc(x: f32) -> f32 {
    let ax = if x >= 0.0 { x } else { -x };
    if ax < 1e-6 {
        1.0
    } else {
        let pix = PI * x;
        pix.sin() / pix
    }
}

#[inline]
fn kaiser_window(n: usize, length: usize, inv_i0_beta: f32) -> f32 {
    let center = (length as f32 - 1.0) * 0.5;
    let scaled = 2.0 * (n as f32 - center) / (length as f32 - 1.0);
    let inside = 1.0 - scaled * scaled;
    if inside <= 0.0 {
        return 0.0;
    }
    let arg = BETA * inside.sqrt();
    bessel_i0(arg) * inv_i0_beta
}

/// Modified Bessel function I0(x), standard rational-approximation pair from
/// Abramowitz & Stegun (Numerical Recipes form). Mirrors the JS reference so
/// the resulting filter coefficients differ only by f32 rounding.
fn bessel_i0(x: f32) -> f32 {
    let ax = if x >= 0.0 { x } else { -x };
    if ax < 3.75 {
        let y = (x / 3.75).powi(2);
        1.0
            + y * (3.5156229
                + y * (3.0899424
                    + y * (1.2067492
                        + y * (0.2659732 + y * (0.0360768 + y * 0.0045813)))))
    } else {
        let y = 3.75 / ax;
        (ax.exp() / ax.sqrt())
            * (0.39894228
                + y * (0.01328592
                    + y * (0.00225319
                        + y * (-0.00157565
                            + y * (0.00916281
                                + y * (-0.02057706
                                    + y * (0.02635537
                                        + y * (-0.01647633 + y * 0.00392377))))))))
    }
}
