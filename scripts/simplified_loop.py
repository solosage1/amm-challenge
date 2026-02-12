#!/usr/bin/env python3
"""
Compatibility shim for the simplified loop implementation.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import simplified_loop_core as _core  # type: ignore
from simplified_loop_core import *  # noqa: F401,F403


subprocess = _core.subprocess
evaluate_with_pipeline = _core.evaluate_with_pipeline


def bootstrap_champion(args: Any) -> int:
    original_eval = _core.evaluate_with_pipeline
    _core.evaluate_with_pipeline = evaluate_with_pipeline
    try:
        return int(_core.bootstrap_champion(args))
    finally:
        _core.evaluate_with_pipeline = original_eval


def main() -> int:
    return int(_core.main())


if __name__ == "__main__":
    raise SystemExit(main())
