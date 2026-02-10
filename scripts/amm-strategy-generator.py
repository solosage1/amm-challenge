#!/usr/bin/env python3
"""
AMM Strategy Generator
Generates Solidity strategy code from templates with parameter substitution.
"""

import argparse
import json
import sys
from pathlib import Path


def load_template(template_name: str) -> str:
    """Load a template file by name."""
    template_path = Path(f".ralph-amm/templates/{template_name}.sol.template")
    if not template_path.exists():
        print(f"Error: Template not found: {template_path}", file=sys.stderr)
        sys.exit(1)
    return template_path.read_text()


def generate_strategy(template_name: str, params: dict, output_path: str) -> None:
    """
    Generate a strategy file from a template with parameter substitution.

    Args:
        template_name: Name of template (e.g., "fixed_fee", "size_adaptive")
        params: Dictionary of parameters to substitute
        output_path: Path to write generated strategy
    """
    # Load template
    code = load_template(template_name)

    # Substitute parameters (validation happens during substitution)
    for key, value in params.items():
        code = code.replace(f"{{{key}}}", str(value))

    # Ensure output directory exists
    output_file = Path(output_path)
    output_file.parent.mkdir(parents=True, exist_ok=True)

    # Write generated code
    output_file.write_text(code)
    print(f"✓ Generated: {output_path}")


def main():
    parser = argparse.ArgumentParser(
        description="Generate AMM strategy from template",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Fixed fee strategy (20 bps)
  python scripts/amm-strategy-generator.py \\
    --template fixed_fee \\
    --params '{"fee_bps": 20, "name": "FixedFee_20bps"}' \\
    --output .ralph-amm/generated/strategy_001.sol

  # Size-adaptive strategy
  python scripts/amm-strategy-generator.py \\
    --template size_adaptive \\
    --params '{
      "base_fee_bps": 35,
      "widen_bps": 10,
      "threshold_denominator": 20,
      "decay_bps": 1,
      "name": "SizeAdaptive_35_10"
    }' \\
    --output .ralph-amm/generated/strategy_002.sol
""",
    )

    parser.add_argument(
        "--template",
        required=True,
        choices=["fixed_fee", "size_adaptive", "inventory_adaptive", "time_decay", "combined"],
        help="Template name to use",
    )
    parser.add_argument(
        "--params",
        required=True,
        help="JSON string or file path containing template parameters",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Output path for generated strategy (.sol file)",
    )

    args = parser.parse_args()

    # Parse params (handle both inline JSON and file paths)
    if args.params.startswith("{"):
        params = json.loads(args.params)
    else:
        params = json.loads(Path(args.params).read_text())

    # Generate strategy
    generate_strategy(args.template, params, args.output)


if __name__ == "__main__":
    main()
