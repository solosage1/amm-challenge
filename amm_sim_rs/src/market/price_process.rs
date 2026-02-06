//! Geometric Brownian Motion price process.

use rand::SeedableRng;
use rand_distr::{Distribution, StandardNormal};
use rand_pcg::Pcg64;

/// Generates fair prices using Geometric Brownian Motion.
///
/// The GBM model: dS = mu * S * dt + sigma * S * dW
/// where:
/// - S is the price
/// - mu is the drift
/// - sigma is the per-step volatility
/// - dW is a Wiener process increment
pub struct GBMPriceProcess {
    /// Current price
    current_price: f64,
    /// Drift
    #[allow(dead_code)]
    mu: f64,
    /// Per-step volatility
    #[allow(dead_code)]
    sigma: f64,
    /// Time step
    #[allow(dead_code)]
    dt: f64,
    /// Pre-computed drift term: (mu - 0.5 * sigma^2) * dt
    drift_term: f64,
    /// Pre-computed volatility term: sigma * sqrt(dt)
    vol_term: f64,
    /// Random number generator
    rng: Pcg64,
}

impl GBMPriceProcess {
    /// Create a new GBM price process.
    pub fn new(initial_price: f64, mu: f64, sigma: f64, dt: f64, seed: Option<u64>) -> Self {
        let rng = match seed {
            Some(s) => Pcg64::seed_from_u64(s),
            None => Pcg64::from_entropy(),
        };

        Self {
            current_price: initial_price,
            mu,
            sigma,
            dt,
            drift_term: (mu - 0.5 * sigma * sigma) * dt,
            vol_term: sigma * dt.sqrt(),
            rng,
        }
    }

    /// Get current price.
    #[inline]
    pub fn current_price(&self) -> f64 {
        self.current_price
    }

    /// Generate the next price.
    #[inline]
    pub fn step(&mut self) -> f64 {
        let z: f64 = StandardNormal.sample(&mut self.rng);
        let exponent = self.drift_term + self.vol_term * z;
        self.current_price *= exponent.exp();
        self.current_price
    }

    /// Reset the price process.
    pub fn reset(&mut self, initial_price: f64, seed: Option<u64>) {
        self.current_price = initial_price;
        if let Some(s) = seed {
            self.rng = Pcg64::seed_from_u64(s);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_gbm_deterministic() {
        let mut process1 = GBMPriceProcess::new(100.0, 0.0, 0.1, 1.0, Some(42));
        let mut process2 = GBMPriceProcess::new(100.0, 0.0, 0.1, 1.0, Some(42));

        // Same seed should produce same prices
        for _ in 0..100 {
            assert_eq!(process1.step(), process2.step());
        }
    }

    #[test]
    fn test_gbm_positive_prices() {
        let mut process = GBMPriceProcess::new(100.0, -0.5, 0.3, 1.0, Some(42));

        // GBM should always produce positive prices
        for _ in 0..1000 {
            let price = process.step();
            assert!(price > 0.0);
        }
    }
}
