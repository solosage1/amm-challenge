#!/usr/bin/env python3
"""
Facade module for simplified loop domains.
"""

from __future__ import annotations

from typing import Any

import simplified_loop_domains.runner as _runner
from simplified_loop_domains.runner import *  # noqa: F401,F403


subprocess = _runner.subprocess
evaluate_with_pipeline = _runner.evaluate_with_pipeline


def bootstrap_champion(args: Any) -> int:
    original_eval = _runner.evaluate_with_pipeline
    _runner.evaluate_with_pipeline = evaluate_with_pipeline
    try:
        return int(_runner.bootstrap_champion(args))
    finally:
        _runner.evaluate_with_pipeline = original_eval


def main() -> int:
    return int(_runner.main())


if __name__ == "__main__":
    raise SystemExit(main())
