#!/usr/bin/env python3
"""
AMM Phase 7 Code Extractor
Extracts and validates Solidity code from Codex output.

Primary input is the plain-text file produced by:
  codex exec --output-last-message <path>

Backward compatibility: if the input file is JSON, we will attempt to extract
the response text from common keys.
"""

import argparse
import json
import re
import sys
from pathlib import Path

# Import existing validator
sys.path.insert(0, str(Path(__file__).parent.parent))
from amm_competition.evm.validator import SolidityValidator

# ============================================================================
# CODE EXTRACTION
# ============================================================================

def extract_code_from_response(response_text: str) -> tuple[str | None, dict]:
    """
    Extract Solidity code and metadata from Codex response.

    Returns:
        (code, metadata) tuple where code is the Solidity source
        and metadata is the parsed JSON metadata dict
    """

    # Parse implementation section
    impl_pattern = r'---REVISED_IMPLEMENTATION---\s*```solidity\s*(.*?)\s*```\s*---END_REVISED_IMPLEMENTATION---'
    impl_match = re.search(impl_pattern, response_text, re.DOTALL)

    if not impl_match:
        print("ERROR: Could not find REVISED_IMPLEMENTATION section", file=sys.stderr)
        print("Response text preview:", file=sys.stderr)
        print(response_text[:500], file=sys.stderr)
        return None, {}

    code = impl_match.group(1).strip()

    # Parse metadata section
    metadata = {}
    meta_pattern = r'---STRATEGY_METADATA---\s*(\{.*?\})\s*---END_STRATEGY_METADATA---'
    meta_match = re.search(meta_pattern, response_text, re.DOTALL)

    if meta_match:
        try:
            metadata = json.loads(meta_match.group(1))
        except json.JSONDecodeError as e:
            print(f"WARN: Failed to parse metadata JSON: {e}", file=sys.stderr)
            # Try to extract at least the name
            name_pattern = r'"name":\s*"([^"]+)"'
            name_match = re.search(name_pattern, meta_match.group(1))
            if name_match:
                metadata = {"name": name_match.group(1)}

    return code, metadata

# ============================================================================
# VALIDATION
# ============================================================================

def validate_and_save(code: str, metadata: dict, output_path: Path) -> bool:
    """
    Validate code and save if valid.

    Returns:
        True if validation passed and file saved, False otherwise
    """

    # Run validator
    validator = SolidityValidator()
    result = validator.validate(code)

    if not result.valid:
        print(f"ERROR: Validation failed:", file=sys.stderr)
        for error in result.errors:
            print(f"  - {error}", file=sys.stderr)
        return False

    if result.warnings:
        print("WARN: Validation warnings:", file=sys.stderr)
        for warning in result.warnings:
            print(f"  - {warning}", file=sys.stderr)

    # Save code
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(code)

    # Save metadata alongside
    if metadata:
        meta_path = output_path.with_suffix('.json')
        meta_path.write_text(json.dumps(metadata, indent=2))
        print(f"✓ Metadata saved: {meta_path}")

    print(f"✓ Valid strategy extracted: {output_path}")
    strategy_name = metadata.get('name', output_path.stem)
    print(f"  Strategy: {strategy_name}")

    if 'hypothesis_ids' in metadata:
        print(f"  Hypotheses: {', '.join(metadata['hypothesis_ids'])}")

    return True

# ============================================================================
# MAIN
# ============================================================================

def main():
    parser = argparse.ArgumentParser(description="Extract Solidity code from Codex response")
    parser.add_argument(
        "--codex-response",
        required=True,
        help="Path to Codex --output-last-message file (plain text). JSON is accepted for backward compatibility.",
    )
    parser.add_argument("--output", required=True, help="Output path for .sol file")
    args = parser.parse_args()

    # Load Codex response
    response_path = Path(args.codex_response)
    if not response_path.exists():
        print(f"ERROR: Response file not found: {response_path}", file=sys.stderr)
        sys.exit(1)

    raw_text = response_path.read_text()

    # Prefer treating input as plain text (Codex --output-last-message).
    response_text = raw_text

    # Backward compatibility: if the file appears to be JSON, attempt to decode
    # and extract the response content from common keys.
    stripped = raw_text.lstrip()
    if stripped.startswith("{") or stripped.startswith("["):
        try:
            response_data = json.loads(raw_text)
            if isinstance(response_data, dict):
                candidate = (
                    response_data.get("output", "")
                    or response_data.get("content", "")
                    or response_data.get("text", "")
                    or response_data.get("response", "")
                )
                if isinstance(candidate, str) and candidate.strip():
                    response_text = candidate
            elif isinstance(response_data, str) and response_data.strip():
                response_text = response_data
        except json.JSONDecodeError:
            # Not valid JSON; keep raw_text
            pass

    # Extract code
    code, metadata = extract_code_from_response(response_text)

    if not code:
        print("ERROR: Failed to extract Solidity code", file=sys.stderr)
        sys.exit(1)

    # Validate and save
    if not validate_and_save(code, metadata, Path(args.output)):
        sys.exit(1)

    print("SUCCESS: Strategy ready for testing")
    sys.exit(0)

if __name__ == "__main__":
    main()
