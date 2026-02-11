#!/usr/bin/env python3
"""
AMM Phase 7 Cross-Strategy Synthesis Engine

Extracts and catalogs mechanisms from successful strategies, identifies
performance correlations, and suggests novel untested combinations.

Usage:
    python scripts/amm-phase7-synthesis.py --state-dir .ralph-amm/phase7/state
"""

import argparse
import json
import re
import sys
from collections import defaultdict
from datetime import datetime
from itertools import combinations
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

try:
    import numpy as np
    NUMPY_AVAILABLE = True
except ImportError:
    NUMPY_AVAILABLE = False

# Add parent to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))


def log(message: str, level: str = "INFO"):
    """Simple logging."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] [{level}] {message}")


# Mechanism detection patterns (regex)
MECHANISM_PATTERNS = {
    "fair_price_inference": {
        "pattern": r"(fair(?:Candidate|Price)?|pHat)\s*=.*?(?:wmul|wdiv)\s*\(\s*spot.*?gamma",
        "description": "Infers fair price from arbitrage trades using fee-adjusted spot",
        "flags": re.IGNORECASE | re.DOTALL,
    },
    "ewma_smoothing": {
        "pattern": r"fair\s*=\s*\(\s*fair\s*\*\s*(\d+)\s*\+.*?\*\s*(\d+)\s*\)\s*/\s*(\d+)",
        "description": "Exponential weighted moving average for price smoothing",
        "flags": re.IGNORECASE | re.DOTALL,
    },
    "inventory_skew": {
        "pattern": r"(spot(?:Above)?|spot\s*>\s*fair).*?(?:bidFee|askFee)",
        "description": "Asymmetric fees based on spot vs fair price position",
        "flags": re.IGNORECASE | re.DOTALL,
    },
    "timestamp_gating": {
        "pattern": r"trade\.timestamp\s*!=\s*(?:lastTs|slots\[\d+\])",
        "description": "Per-timestamp state tracking for first-trade detection",
        "flags": re.IGNORECASE,
    },
    "protection_buffer": {
        "pattern": r"buffer\s*=\s*bpsToWad\s*\(\s*(\d+)\s*\)",
        "description": "Fixed buffer added to protective fee calculations",
        "flags": re.IGNORECASE,
    },
    "competitive_undercut": {
        "pattern": r"undercut\s*=\s*bpsToWad\s*\(\s*(\d+)\s*\)",
        "description": "Fee reduction to undercut normalizer for routing",
        "flags": re.IGNORECASE,
    },
    "fee_clamping": {
        "pattern": r"clampFee\s*\(",
        "description": "Uses fee clamping to ensure valid fee range",
        "flags": re.IGNORECASE,
    },
    "max_jump_limit": {
        "pattern": r"maxJump\s*=\s*(\d+)\s*\*\s*BPS",
        "description": "Limits fair price jumps to prevent noise amplification",
        "flags": re.IGNORECASE,
    },
    "gamma_calculation": {
        "pattern": r"gamma(?:Req|Base|Match)?\s*=.*?(?:WAD\s*-|wdiv)",
        "description": "Explicit gamma (1-fee) calculations for no-arb bounds",
        "flags": re.IGNORECASE | re.DOTALL,
    },
    "exact_arb_inversion": {
        "pattern": r"fairCandidate\s*=\s*wdiv\s*\(\s*wmul\s*\(\s*k\s*,\s*gamma\s*\)\s*,\s*wmul\s*\(\s*xVirtual\s*,\s*xVirtual\s*\)\s*\)\s*;|fairCandidate\s*=\s*wdiv\s*\(\s*k\s*,\s*wmul\s*\(\s*gamma\s*,\s*wmul\s*\(\s*rx\s*,\s*rx\s*\)\s*\)\s*\)\s*;",
        "description": "Infers fair price by inverting the simulator's closed-form arbitrage sizing (exact arb inversion)",
        "flags": re.IGNORECASE | re.DOTALL,
    },
    "dual_regime_quoting": {
        "pattern": r"mis\s*=.*?tightBand.*?if\s*\(\s*mis\s*<=\s*tightBand\s*\)",
        "description": "Dual-regime quoting (tight-band vs protective-band logic)",
        "flags": re.IGNORECASE | re.DOTALL,
    },
    "volatility_tracking": {
        "pattern": r"vol(?:Ewma|atility)?\s*=.*?(?:absDiff|wmul)",
        "description": "Tracks volatility for adaptive fee adjustment",
        "flags": re.IGNORECASE | re.DOTALL,
    },
    "regime_switching": {
        "pattern": r"regime|phase|mode\s*=",
        "description": "Multi-regime or phase-based fee strategy",
        "flags": re.IGNORECASE,
    },
    "initial_wide_fees": {
        "pattern": r"afterInitialize.*?bpsToWad\s*\(\s*(\d+)\s*\).*?return",
        "description": "Sets specific initial fee level",
        "flags": re.IGNORECASE | re.DOTALL,
    },
}

# Anti-patterns that correlate with poor performance
ANTI_PATTERNS = {
    "excessive_initial_fee": {
        "pattern": r"afterInitialize.*?bpsToWad\s*\(\s*(7\d|8\d|9\d|1\d\d)\s*\)",
        "description": "Initial fees too high (70+ bps), loses early routing",
        "flags": re.IGNORECASE | re.DOTALL,
    },
    "no_price_inference": {
        "anti_pattern": "fair_price_inference",  # Absence of this mechanism
        "description": "No fair price inference - can't adapt to market",
    },
    "excessive_ewma_smoothing": {
        "pattern": r"fair\s*=\s*\(\s*fair\s*\*\s*(9\d)\s*\+",
        "description": "EWMA too slow (90%+ weight on old value)",
        "flags": re.IGNORECASE | re.DOTALL,
    },
    "fixed_symmetric_fees": {
        "pattern": r"bidFee\s*=\s*askFee\s*=\s*bpsToWad",
        "description": "Symmetric fixed fees - no adaptability",
        "flags": re.IGNORECASE,
    },
}


def extract_mechanisms(source_code: str) -> List[Dict]:
    """
    Extract mechanisms from Solidity source code.

    Returns:
        List of dicts with mechanism name, params, and context.
    """
    mechanisms = []

    for mech_name, config in MECHANISM_PATTERNS.items():
        pattern = config["pattern"]
        flags = config.get("flags", 0)

        matches = list(re.finditer(pattern, source_code, flags))
        for match in matches:
            # Extract parameters from capture groups
            params = match.groups() if match.groups() else []

            # Get context (surrounding code)
            start = max(0, match.start() - 50)
            end = min(len(source_code), match.end() + 50)
            context = source_code[start:end].replace("\n", " ").strip()

            mechanisms.append({
                "name": mech_name,
                "description": config["description"],
                "params": list(params),
                "context": context[:200],  # Limit context length
            })

    return mechanisms


def extract_anti_patterns(source_code: str) -> List[Dict]:
    """
    Detect anti-patterns in Solidity source code.

    Returns:
        List of detected anti-patterns.
    """
    anti_patterns = []

    for pattern_name, config in ANTI_PATTERNS.items():
        if "pattern" in config:
            pattern = config["pattern"]
            flags = config.get("flags", 0)

            if re.search(pattern, source_code, flags):
                anti_patterns.append({
                    "name": pattern_name,
                    "description": config["description"],
                    "severity": "warning",
                })

    return anti_patterns


def load_strategies_log(state_dir: Path) -> List[Dict]:
    """Load strategies log from state directory."""
    log_path = state_dir / ".strategies_log.json"
    if not log_path.exists():
        # Try alternate location
        log_path = state_dir / "strategies_log.json"

    if not log_path.exists():
        log(f"Strategies log not found at {log_path}", "WARN")
        return []

    try:
        return json.loads(log_path.read_text())
    except Exception as e:
        log(f"Failed to load strategies log: {e}", "ERROR")
        return []

def load_codex_edge_observations(state_dir: Path) -> Dict[str, Dict]:
    """
    Parse iteration_*_codex.jsonl files for any amm-match runs and capture
    the best observed Edge per strategy (preferring higher simulation counts).

    Returns:
        Dict keyed by strategy file stem -> {edge, simulations, file, source}
    """
    edge_re = re.compile(r"\bEdge:\s*([0-9]+(?:\.[0-9]+)?)\b")
    sims_re = re.compile(r"--simulations\s+(\d+)\b")
    file_re = re.compile(r"\bamm-match\s+run\s+([A-Za-z0-9_./-]+\.sol)\b")

    observations: Dict[str, Dict] = {}

    for jsonl_path in sorted(state_dir.glob("iteration_*_codex.jsonl")):
        try:
            with jsonl_path.open("r", encoding="utf-8", errors="ignore") as f:
                for lineno, line in enumerate(f, start=1):
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except Exception:
                        continue

                    if obj.get("type") != "item.completed":
                        continue
                    item = obj.get("item")
                    if not isinstance(item, dict) or item.get("type") != "command_execution":
                        continue

                    cmd = str(item.get("command") or "")
                    out = str(item.get("aggregated_output") or "")

                    if "amm-match" not in cmd or " run " not in cmd:
                        continue

                    sims = 0
                    m_sims = sims_re.search(cmd)
                    if m_sims:
                        try:
                            sims = int(m_sims.group(1))
                        except ValueError:
                            sims = 0

                    direct_file = None
                    m_file = file_re.search(cmd)
                    if m_file:
                        direct_file = m_file.group(1)

                    # Case 1: loop output with explicit "---- file.sol" markers
                    current_file = None
                    any_markers = False
                    for ln in out.splitlines():
                        if ln.startswith("---- "):
                            any_markers = True
                            parts = ln.split()
                            current_file = parts[1] if len(parts) >= 2 else None
                            continue
                        m_edge = edge_re.search(ln)
                        if not m_edge:
                            continue
                        try:
                            edge = float(m_edge.group(1))
                        except ValueError:
                            continue
                        if current_file and current_file.endswith(".sol"):
                            stem = Path(current_file).stem
                            prev = observations.get(stem)
                            rec = {
                                "edge": edge,
                                "simulations": sims,
                                "file": current_file,
                                "source": f"{jsonl_path.name}:{lineno}",
                            }
                            if prev is None or sims > int(prev.get("simulations", 0)) or (
                                sims == int(prev.get("simulations", 0)) and edge > float(prev.get("edge", 0))
                            ):
                                observations[stem] = rec

                    if any_markers:
                        continue

                    # Case 2: single-run output inferred from the command's file argument
                    if not direct_file:
                        continue

                    m_edge = edge_re.search(out)
                    if not m_edge:
                        continue
                    try:
                        edge = float(m_edge.group(1))
                    except ValueError:
                        continue

                    stem = Path(direct_file).stem
                    prev = observations.get(stem)
                    rec = {
                        "edge": edge,
                        "simulations": sims,
                        "file": direct_file,
                        "source": f"{jsonl_path.name}:{lineno}",
                    }
                    if prev is None or sims > int(prev.get("simulations", 0)) or (
                        sims == int(prev.get("simulations", 0)) and edge > float(prev.get("edge", 0))
                    ):
                        observations[stem] = rec
        except Exception as e:
            log(f"Failed to parse {jsonl_path}: {e}", "WARN")

    return observations


def analyze_strategies(state_dir: Path, min_edge: float = 350.0) -> Dict:
    """
    Analyze all strategies in the state directory.

    Returns:
        Dict with mechanism catalog, performance correlations, and synthesis candidates.
    """
    strategies_log = load_strategies_log(state_dir)
    edge_observations = load_codex_edge_observations(state_dir)

    # Also scan for .sol files directly
    generated_dir = state_dir.parent / "generated"
    root_dir = state_dir.parent.parent.parent  # Go up to project root

    sol_files = list(generated_dir.glob("*.sol")) if generated_dir.exists() else []
    # Include repo-root candidate strategies (not just arb_*).
    sol_files.extend(list(root_dir.glob("*.sol")))

    analysis = {
        "timestamp": datetime.now().isoformat(),
        "strategies_analyzed": 0,
        "mechanism_catalog": defaultdict(list),
        "mechanism_performance": {},
        "synthesis_candidates": [],
        "anti_patterns_detected": [],
        "parameter_insights": {},
    }

    # Track mechanisms per strategy
    strategy_mechanisms: Dict[str, Set[str]] = {}

    # Analyze strategies from log
    for entry in strategies_log:
        if entry.get("status") != "ok":
            continue

        edge = entry.get("final_edge", 0)
        if edge < min_edge:
            continue

        strategy_name = entry.get("strategy_name", "unknown")

        # Try to find source file
        artifact_paths = entry.get("artifact_paths", {})
        strategy_path = artifact_paths.get("strategy_path", "")

        if strategy_path and Path(strategy_path).exists():
            source_code = Path(strategy_path).read_text()
            mechanisms = extract_mechanisms(source_code)
            anti_patterns = extract_anti_patterns(source_code)

            mech_names = set()
            for mech in mechanisms:
                mech_name = mech["name"]
                mech_names.add(mech_name)
                analysis["mechanism_catalog"][mech_name].append({
                    "strategy": strategy_name,
                    "edge": edge,
                    "params": mech["params"],
                })

            strategy_mechanisms[strategy_name] = mech_names

            for ap in anti_patterns:
                analysis["anti_patterns_detected"].append({
                    "strategy": strategy_name,
                    "edge": edge,
                    **ap,
                })

            analysis["strategies_analyzed"] += 1

    # Also analyze standalone .sol files
    for sol_path in sol_files:
        if sol_path.stem in strategy_mechanisms:
            continue  # Already analyzed from log

        try:
            source_code = sol_path.read_text()
            mechanisms = extract_mechanisms(source_code)

            mech_names = set()
            for mech in mechanisms:
                mech_name = mech["name"]
                mech_names.add(mech_name)
                analysis["mechanism_catalog"][mech_name].append({
                    "strategy": sol_path.stem,
                    "edge": (
                        edge_observations.get(sol_path.stem, {}).get("edge")
                        if sol_path.stem in edge_observations
                        else None
                    ),
                    "params": mech["params"],
                })

            strategy_mechanisms[sol_path.stem] = mech_names
            analysis["strategies_analyzed"] += 1

        except Exception as e:
            log(f"Failed to analyze {sol_path}: {e}", "WARN")

    # Compute mechanism performance metrics
    if NUMPY_AVAILABLE:
        for mech_name, occurrences in analysis["mechanism_catalog"].items():
            edges = [o["edge"] for o in occurrences if o["edge"] is not None]
            if edges:
                analysis["mechanism_performance"][mech_name] = {
                    "count": len(occurrences),
                    "strategies_with_edge": len(edges),
                    "avg_edge": float(np.mean(edges)),
                    "max_edge": float(max(edges)),
                    "min_edge": float(min(edges)),
                    "std_edge": float(np.std(edges)) if len(edges) > 1 else 0,
                }

    # Generate synthesis candidates (untested combinations)
    analysis["synthesis_candidates"] = generate_synthesis_candidates(
        analysis["mechanism_catalog"],
        analysis["mechanism_performance"],
        strategy_mechanisms,
    )

    # Extract parameter insights
    analysis["parameter_insights"] = extract_parameter_insights(analysis["mechanism_catalog"])

    # Convert defaultdict to regular dict for JSON serialization
    analysis["mechanism_catalog"] = dict(analysis["mechanism_catalog"])

    return analysis


def generate_synthesis_candidates(
    mechanism_catalog: Dict,
    mechanism_performance: Dict,
    strategy_mechanisms: Dict[str, Set[str]],
    min_avg_edge: float = 380.0,
) -> List[Dict]:
    """
    Generate novel mechanism combinations that haven't been tested.

    Returns:
        List of synthesis candidate dicts.
    """
    candidates = []

    # Get high-performing mechanisms
    high_perf_mechs = [
        mech for mech, perf in mechanism_performance.items()
        if perf.get("avg_edge", 0) >= min_avg_edge and perf.get("count", 0) >= 2
    ]

    if not high_perf_mechs:
        # Fall back to all mechanisms with data
        high_perf_mechs = list(mechanism_performance.keys())[:8]

    # Get all existing combinations
    existing_combos: Set[frozenset] = set()
    for mechs in strategy_mechanisms.values():
        existing_combos.add(frozenset(mechs))

    # Generate new combinations
    for combo_size in [2, 3]:
        for combo in combinations(high_perf_mechs, combo_size):
            combo_set = frozenset(combo)

            # Check if this exact combination exists
            if combo_set in existing_combos:
                continue

            # Check if any existing strategy has this as a subset
            is_subset = any(combo_set.issubset(existing) for existing in existing_combos)

            if not is_subset:
                # Calculate predicted edge (simple average of component edges)
                predicted_edge = np.mean([
                    mechanism_performance.get(m, {}).get("avg_edge", 350)
                    for m in combo
                ]) if NUMPY_AVAILABLE else 380

                candidates.append({
                    "mechanisms": list(combo),
                    "predicted_edge": float(predicted_edge),
                    "rationale": f"Untested combination of {len(combo)} high-performing mechanisms",
                    "is_novel": True,
                })

    # Sort by predicted edge
    candidates.sort(key=lambda x: x["predicted_edge"], reverse=True)

    return candidates[:10]  # Top 10 candidates


def extract_parameter_insights(mechanism_catalog: Dict) -> Dict:
    """
    Extract insights about optimal parameter values.

    Returns:
        Dict mapping mechanism names to parameter insights.
    """
    insights = {}

    # EWMA smoothing parameters
    if "ewma_smoothing" in mechanism_catalog:
        occurrences = mechanism_catalog["ewma_smoothing"]
        alphas = []
        for occ in occurrences:
            params = occ.get("params", [])
            if len(params) >= 3:
                try:
                    # EWMA formula: fair = (fair * old_weight + new * new_weight) / total
                    old_weight = int(params[0])
                    new_weight = int(params[1])
                    total = int(params[2])
                    alpha = new_weight / total  # Alpha is the weight on new data
                    alphas.append({
                        "alpha": alpha,
                        "edge": occ.get("edge"),
                        "strategy": occ.get("strategy"),
                    })
                except (ValueError, ZeroDivisionError):
                    pass

        if alphas and NUMPY_AVAILABLE:
            edges_with_alpha = [(a["alpha"], a["edge"]) for a in alphas if a["edge"]]
            if edges_with_alpha:
                best_alpha = max(edges_with_alpha, key=lambda x: x[1])[0]
                insights["ewma_smoothing"] = {
                    "best_alpha": best_alpha,
                    "alpha_range": (min(a[0] for a in edges_with_alpha), max(a[0] for a in edges_with_alpha)),
                    "recommendation": f"EWMA alpha near {best_alpha:.2f} performs best",
                }

    # Protection buffer parameters
    if "protection_buffer" in mechanism_catalog:
        occurrences = mechanism_catalog["protection_buffer"]
        buffers = []
        for occ in occurrences:
            params = occ.get("params", [])
            if params:
                try:
                    buffer_bps = int(params[0])
                    buffers.append({
                        "buffer_bps": buffer_bps,
                        "edge": occ.get("edge"),
                    })
                except ValueError:
                    pass

        if buffers and NUMPY_AVAILABLE:
            edges_with_buffer = [(b["buffer_bps"], b["edge"]) for b in buffers if b["edge"]]
            if edges_with_buffer:
                best_buffer = max(edges_with_buffer, key=lambda x: x[1])[0]
                insights["protection_buffer"] = {
                    "best_buffer_bps": best_buffer,
                    "buffer_range": (min(b[0] for b in edges_with_buffer), max(b[0] for b in edges_with_buffer)),
                    "recommendation": f"Protection buffer near {best_buffer} bps performs best",
                }

    # Initial fee insights
    if "initial_wide_fees" in mechanism_catalog:
        occurrences = mechanism_catalog["initial_wide_fees"]
        init_fees = []
        for occ in occurrences:
            params = occ.get("params", [])
            if params:
                try:
                    fee_bps = int(params[0])
                    init_fees.append({
                        "fee_bps": fee_bps,
                        "edge": occ.get("edge"),
                    })
                except ValueError:
                    pass

        if init_fees and NUMPY_AVAILABLE:
            edges_with_fee = [(f["fee_bps"], f["edge"]) for f in init_fees if f["edge"]]
            if edges_with_fee:
                best_fee = max(edges_with_fee, key=lambda x: x[1])[0]
                insights["initial_fee"] = {
                    "best_initial_fee_bps": best_fee,
                    "fee_range": (min(f[0] for f in edges_with_fee), max(f[0] for f in edges_with_fee)),
                    "recommendation": f"Initial fees near {best_fee} bps perform best",
                }

    return insights


def generate_synthesis_report(analysis: Dict) -> str:
    """Generate markdown report from synthesis analysis."""

    lines = ["## Cross-Strategy Synthesis Insights\n"]

    # Mechanism performance table
    if analysis.get("mechanism_performance"):
        lines.append("### High-Performance Mechanisms")
        lines.append("| Mechanism | Count | Avg Edge | Max Edge |")
        lines.append("|-----------|-------|----------|----------|")

        sorted_mechs = sorted(
            analysis["mechanism_performance"].items(),
            key=lambda x: x[1].get("avg_edge", 0),
            reverse=True,
        )

        for mech_name, perf in sorted_mechs[:10]:
            lines.append(
                f"| {mech_name} | {perf.get('count', 0)} | "
                f"{perf.get('avg_edge', 0):.1f} | {perf.get('max_edge', 0):.1f} |"
            )
        lines.append("")

    # Synthesis candidates
    if analysis.get("synthesis_candidates"):
        lines.append("### Untested Synthesis Candidates")
        for i, candidate in enumerate(analysis["synthesis_candidates"][:5], 1):
            mechs = " + ".join(candidate["mechanisms"])
            lines.append(f"{i}. **{mechs}**")
            lines.append(f"   - Predicted edge: ~{candidate['predicted_edge']:.0f}")
            lines.append(f"   - {candidate['rationale']}")
        lines.append("")

    # Parameter insights
    if analysis.get("parameter_insights"):
        lines.append("### Optimal Parameter Values")
        for mech_name, insight in analysis["parameter_insights"].items():
            if "recommendation" in insight:
                lines.append(f"- **{mech_name}**: {insight['recommendation']}")
        lines.append("")

    # Anti-patterns
    if analysis.get("anti_patterns_detected"):
        lines.append("### Anti-Patterns to Avoid")
        seen_patterns = set()
        for ap in analysis["anti_patterns_detected"]:
            pattern_name = ap["name"]
            if pattern_name not in seen_patterns:
                lines.append(f"- **{pattern_name}**: {ap['description']}")
                seen_patterns.add(pattern_name)
        lines.append("")

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="AMM Phase 7 Cross-Strategy Synthesis Engine")
    parser.add_argument("--state-dir", type=str, required=True, help="Path to state directory")
    parser.add_argument("--output", type=str, help="Output JSON file path")
    parser.add_argument("--min-edge", type=float, default=350.0, help="Minimum edge to analyze")
    parser.add_argument("--report-only", action="store_true", help="Print report to stdout only")

    args = parser.parse_args()

    state_dir = Path(args.state_dir)
    if not state_dir.exists():
        log(f"State directory not found: {state_dir}", "ERROR")
        sys.exit(1)

    try:
        analysis = analyze_strategies(state_dir, min_edge=args.min_edge)

        # Generate report
        report = generate_synthesis_report(analysis)
        analysis["report"] = report

        if args.report_only:
            print(report)
        else:
            if args.output:
                output_path = Path(args.output)
                # Remove report from JSON (keep it human-readable separately)
                json_analysis = {k: v for k, v in analysis.items() if k != "report"}
                output_path.write_text(json.dumps(json_analysis, indent=2, default=str))
                log(f"Analysis saved to {output_path}")

                # Also save report as .md
                report_path = output_path.with_suffix(".md")
                report_path.write_text(report)
                log(f"Report saved to {report_path}")

            print("\n" + "="*60)
            print(report)
            print("="*60 + "\n")

        log(f"Analyzed {analysis['strategies_analyzed']} strategies")

    except Exception as e:
        log(f"Synthesis analysis failed: {e}", "ERROR")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
