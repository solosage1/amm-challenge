#!/usr/bin/env python3
"""
AMM Phase 7 Template Extractor
Extracts reusable template from successful strategy
"""

import argparse
import json
import re
from pathlib import Path
from typing import Dict, List, Tuple

# ============================================================================
# PARAMETER IDENTIFICATION
# ============================================================================

def to_snake_case(name: str) -> str:
    """Convert CamelCase to snake_case"""
    return re.sub(r'(?<!^)(?=[A-Z])', '_', name).lower()

def identify_parameters(code: str) -> List[Tuple[str, str, str]]:
    """
    Identify parameterizable constants in strategy code.

    Returns:
        List of (constant_name, value, param_type) tuples
    """
    parameters = []

    # Look for constant declarations
    const_pattern = r'uint256\s+(?:public\s+)?constant\s+(\w+)\s*=\s*([^;]+);'
    for match in re.finditer(const_pattern, code):
        name, value = match.groups()
        # Skip standard constants
        if name not in ['WAD', 'BPS', 'MAX_FEE']:
            parameters.append((name, value.strip(), 'uint256'))

    # Look for direct numeric literals in fee calculations
    # (pattern: bpsToWad(<number>) or <number> * BPS)
    bps_patterns = [
        r'bpsToWad\((\d+)\)',
        r'(\d+)\s*\*\s*BPS',
    ]

    for pattern in bps_patterns:
        for match in re.finditer(pattern, code):
            value = match.group(1)
            param_name = f"fee_{value}_bps"
            # Avoid duplicates
            if not any(p[0] == param_name for p in parameters):
                parameters.append((param_name, value, 'uint256_bps'))

    return parameters

# ============================================================================
# TEMPLATE CREATION
# ============================================================================

def create_template(code: str, parameters: List[Tuple[str, str, str]],
                   strategy_name: str, edge_score: float, metadata: Dict) -> Tuple[str, Dict]:
    """
    Create template by replacing parameters with placeholders.

    Returns:
        (template_code, parameter_schema)
    """
    template = code
    param_schema = {
        "template_name": to_snake_case(strategy_name),
        "source_strategy": strategy_name,
        "source_edge": edge_score,
        "source_metadata": metadata,
        "parameters": {}
    }

    for param_name, value, param_type in parameters:
        placeholder_name = to_snake_case(param_name)
        placeholder = f"{{{placeholder_name}}}"

        # Replace in declarations
        if param_type == 'uint256':
            template = template.replace(f"constant {param_name} = {value};",
                                       f"constant {param_name} = {placeholder};")
        elif param_type == 'uint256_bps':
            # Replace bps patterns
            template = template.replace(f"bpsToWad({value})", f"bpsToWad({placeholder})")
            template = template.replace(f"{value} * BPS", f"{placeholder} * BPS")

        param_schema["parameters"][placeholder_name] = {
            "type": param_type,
            "original_value": value,
            "description": f"Parameter from {param_name}"
        }

    # Also parameterize strategy name
    template = template.replace(f'return "{strategy_name}";', 'return "{name}";')

    return template, param_schema

# ============================================================================
# MAIN
# ============================================================================

def main():
    parser = argparse.ArgumentParser(description="Extract template from strategy")
    parser.add_argument("--strategy", required=True, help="Path to strategy .sol file")
    parser.add_argument("--result", required=True, help="Path to test result JSON")
    parser.add_argument("--output-dir", required=True, help="Output directory for template")
    args = parser.parse_args()

    # Load strategy code
    strategy_path = Path(args.strategy)
    if not strategy_path.exists():
        print(f"ERROR: Strategy file not found: {strategy_path}")
        return 1

    code = strategy_path.read_text()

    # Load test result
    result_path = Path(args.result)
    if not result_path.exists():
        print(f"ERROR: Result file not found: {result_path}")
        return 1

    result = json.loads(result_path.read_text())

    strategy_name = result.get('strategy_name', 'Unknown')
    edge_score = result.get('final_edge', 0)

    # Load metadata if available
    metadata_path = strategy_path.with_suffix('.json')
    metadata = {}
    if metadata_path.exists():
        try:
            metadata = json.loads(metadata_path.read_text())
        except json.JSONDecodeError:
            pass

    # Identify parameters
    parameters = identify_parameters(code)

    if not parameters:
        print(f"WARN: No parameterizable constants found in {strategy_name}")
        print("Template extraction skipped - strategy may be too simple or too complex")
        return 0

    # Create template
    template_code, param_schema = create_template(code, parameters, strategy_name, edge_score, metadata)

    # Save template
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    template_filename = f"{param_schema['template_name']}.sol.template"
    template_path = output_dir / template_filename
    template_path.write_text(template_code)

    # Save schema
    schema_path = output_dir / f"{param_schema['template_name']}_schema.json"
    schema_path.write_text(json.dumps(param_schema, indent=2))

    # Update templates created log
    templates_log_path = output_dir.parent / "state" / ".templates_created.json"
    if templates_log_path.exists():
        try:
            templates_log = json.loads(templates_log_path.read_text())
        except json.JSONDecodeError:
            templates_log = []
    else:
        templates_log = []

    templates_log.append({
        "template_name": param_schema['template_name'],
        "source_strategy": strategy_name,
        "source_edge": edge_score,
        "timestamp": result.get('timestamp', ''),
        "parameters_count": len(parameters)
    })

    templates_log_path.write_text(json.dumps(templates_log, indent=2))

    print(f"✓ Template created: {template_path}")
    print(f"✓ Schema created: {schema_path}")
    print(f"  Parameters: {len(parameters)}")
    print(f"  Source edge: {edge_score:.2f}")

    return 0

if __name__ == "__main__":
    import sys
    sys.exit(main())
