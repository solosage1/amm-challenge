"""Geometric Brownian Motion price process generator."""

from dataclasses import dataclass
from decimal import Decimal
from typing import Iterator, Optional

import numpy as np


@dataclass
class GBMPriceProcess:
    """Generates fair prices using Geometric Brownian Motion.

    The GBM model: dS = mu * S * dt + sigma * S * dW
    where:
    - S is the price
    - mu is the drift
    - sigma is the per-step volatility
    - dW is a Wiener process increment
    """
    initial_price: float
    mu: float = 0.0           # Drift
    sigma: float = 0.001      # Per-step volatility
    dt: float = 1.0           # Time step
    seed: Optional[int] = None

    def __post_init__(self) -> None:
        self._rng = np.random.default_rng(self.seed)
        self._current_price = self.initial_price

    def reset(self, seed: Optional[int] = None) -> None:
        """Reset the price process to initial state."""
        if seed is not None:
            self._rng = np.random.default_rng(seed)
        self._current_price = self.initial_price

    @property
    def current_price(self) -> Decimal:
        """Current fair price as Decimal."""
        return Decimal(str(self._current_price))

    def step(self) -> Decimal:
        """Generate the next price.

        Returns:
            The new fair price after one time step
        """
        # GBM discretization: S(t+dt) = S(t) * exp((mu - 0.5*sigma^2)*dt + sigma*sqrt(dt)*Z)
        z = self._rng.standard_normal()
        drift = (self.mu - 0.5 * self.sigma ** 2) * self.dt
        diffusion = self.sigma * np.sqrt(self.dt) * z
        self._current_price = self._current_price * np.exp(drift + diffusion)
        return self.current_price

    def generate(self, n_steps: int) -> Iterator[Decimal]:
        """Generate a sequence of prices.

        Args:
            n_steps: Number of price steps to generate

        Yields:
            Fair price at each step (starting with initial price)
        """
        yield self.current_price
        for _ in range(n_steps - 1):
            yield self.step()

    def generate_path(self, n_steps: int) -> list[Decimal]:
        """Generate a complete price path.

        Args:
            n_steps: Number of prices in the path

        Returns:
            List of prices including initial price
        """
        return list(self.generate(n_steps))
