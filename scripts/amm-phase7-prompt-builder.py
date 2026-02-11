#!/usr/bin/env python3
"""
AMM Phase 7 Prompt Builder
Constructs context-aware prompts for Codex that enforce Draft→Review→Revise pattern
"""

import argparse
import json
import re
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# Add scripts directory to path for local imports
sys.path.insert(0, str(Path(__file__).parent))

# ============================================================================
# PROMPT TEMPLATE
# ============================================================================

PROMPT_TEMPLATE = """# AMM Strategy Generation

Generate a Solidity AMM fee strategy to maximize Edge against a 30bps fixed-fee competitor.

**Target**: Edge > {current_target} | **Best (1000-sim canonical)**: {best_edge_display} | **Iter**: {iteration}

## Quick Start
1. Read `README.md` for simulation mechanics and math
2. Read `.ralph-amm/phase7/state/.best_strategy.sol` for current best approach
3. Read `.ralph-amm/phase7/state/.knowledge_context.json` for lessons learned

## Testing
**ALWAYS use 1000 simulations** for reliable results:
```bash
amm-match run your_strategy.sol --simulations 1000
```

## Contract Template
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {{AMMStrategyBase}} from "./AMMStrategyBase.sol";
import {{IAMMStrategy, TradeInfo}} from "./IAMMStrategy.sol";

contract Strategy is AMMStrategyBase {{
    function afterInitialize(uint256 initialX, uint256 initialY) external override returns (uint256 bidFee, uint256 askFee) {{
        // Init slots[0..31], return opening fees in WAD
    }}
    function afterSwap(TradeInfo calldata trade) external override returns (uint256 bidFee, uint256 askFee) {{
        // Update slots, return fees in WAD
    }}
    function getName() external pure override returns (string memory) {{ return "YourName"; }}
}}
```

## Constraints
- Storage: ONLY slots[0..31] (no state variables)
- Blocked: .call(), delegatecall(), assembly, new, selfdestruct, transfer, send
- Helpers: WAD=1e18, BPS=1e14, clampFee(), bpsToWad(), wmul(), wdiv(), sqrt()

## Output Format
```
---STRATEGY_IDEA---
Brief description
---END_STRATEGY_IDEA---

---IMPLEMENTATION---
<complete Solidity code>
---END_IMPLEMENTATION---

---METADATA---
{{"name": "StrategyName", "key_innovation": "one line"}}
---END_METADATA---
```
"""

# ============================================================================
# STATE LOADING
# ============================================================================

def load_knowledge_context(state_dir: Path) -> dict:
    """Load harvested knowledge context if available."""
    knowledge_path = state_dir / '.knowledge_context.json'
    if knowledge_path.exists():
        try:
            return json.loads(knowledge_path.read_text())
        except json.JSONDecodeError:
            pass
    return {}


def load_auto_plan(plan_path: Path) -> dict:
    """Load optional autonomous opportunity plan."""
    if not plan_path:
        return {}
    if plan_path.exists():
        try:
            data = json.loads(plan_path.read_text())
            if isinstance(data, dict):
                return data
        except json.JSONDecodeError:
            pass
    return {}


def load_state(state_dir: Path) -> Dict:
    """Load current Phase 7 state"""
    best_edge = 0.0
    best_edge_path = state_dir / '.best_edge.txt'
    if best_edge_path.exists():
        try:
            best_edge = float(best_edge_path.read_text().strip())
        except ValueError:
            best_edge = 0.0

    state = {
        'best_edge': best_edge,  # Canonical: 1000-sim best edge
        'best_edge_any': best_edge,
        'iteration': int((state_dir / '.iteration_count.txt').read_text().strip()),
        'start_time': int((state_dir / '.start_timestamp.txt').read_text().strip()),
        'strategies_log': [],
        'knowledge_context': {},
        'best_edge_sims': 1000,
    }

    # If the loop is currently failing before it can update .best_edge.txt, allow a
    # human/auxiliary discoveries file to override the displayed best edge in prompts.
    # Canonical best remains 1000-sim only.
    manual_discoveries = state_dir / "discoveries_iter8_9.md"
    if manual_discoveries.exists():
        try:
            candidates = []
            for m in re.finditer(
                r"\*\*(\d+(?:\.\d+)?)\s+Edge\b(?:\s*@\s*(\d+)\s*sims)?",
                manual_discoveries.read_text(),
            ):
                try:
                    edge = float(m.group(1))
                except ValueError:
                    continue
                sims = 0
                try:
                    sims = int(m.group(2)) if m.group(2) else 0
                except ValueError:
                    sims = 0
                candidates.append((sims, edge))

            candidates_1000 = [(s, e) for s, e in candidates if s >= 1000]
            if candidates_1000:
                max_sims = max(s for s, _ in candidates_1000)
                best_edge_at_max_sims = max(e for s, e in candidates_1000 if s == max_sims)
                if best_edge_at_max_sims > state["best_edge"]:
                    state["best_edge"] = best_edge_at_max_sims
                    state["best_edge_sims"] = max_sims
        except Exception:
            pass

    # Load strategies log if it exists and is valid
    strategies_file = state_dir / '.strategies_log.json'
    if strategies_file.exists():
        try:
            state['strategies_log'] = json.loads(strategies_file.read_text())
        except json.JSONDecodeError:
            pass

    # Load knowledge context from session harvester
    knowledge = load_knowledge_context(state_dir)
    if knowledge:
        state['knowledge_context'] = knowledge
        try:
            # Prefer explicit 1000-sim canonical fields if present.
            k_best_1000 = knowledge.get("true_best_edge_1000", None)
            if k_best_1000 is not None:
                state["best_edge"] = max(state["best_edge"], float(k_best_1000))
                state["best_edge_sims"] = 1000
            elif knowledge.get("true_best_edge", None) is not None:
                # Backward compatibility with older harvester schema.
                state["best_edge"] = max(state["best_edge"], float(knowledge["true_best_edge"]))
                state["best_edge_sims"] = 1000

            k_best_any = knowledge.get("true_best_edge_any", None)
            if k_best_any is not None:
                state["best_edge_any"] = max(state["best_edge_any"], float(k_best_any))
        except Exception:
            pass

    return state

# ============================================================================
# HYPOTHESIS PRIORITIZATION
# ============================================================================

def select_hypothesis_gaps(state: Dict) -> List[Tuple[str, str]]:
    """Prioritize hypothesis gaps to explore"""
    # Identify which hypotheses have been under-explored
    tested_hypotheses = {}
    for entry in state['strategies_log']:
        hyp_ids = entry.get('hypothesis_ids', [])
        if isinstance(hyp_ids, list):
            for hyp in hyp_ids:
                tested_hypotheses[hyp] = tested_hypotheses.get(hyp, 0) + 1

    # Priority order based on research backlog
    all_gaps = [
        ("H-001", "Fair price inference from arbitrage"),
        ("H-002", "Post-arb tighten, post-retail widen"),
        ("H-003", "Inventory-skewed asymmetric fees"),
        ("H-004", "Volatility proxy via price changes"),
        ("H-005", "Hysteresis/decay to avoid oscillation"),
        ("H-006", "Trade-size reactive widening"),
        ("GAP-A", "Fair price inference strategies"),
        ("GAP-B", "Multi-regime adaptive fees"),
        ("GAP-C", "Directional asymmetry with hysteresis"),
        ("GAP-D", "Real-time volatility signaling"),
        ("GAP-E", "Timestamp-level fee coherence"),
        ("GAP-F", "Cross-AMM retail volume inference"),
        ("GAP-G", "Arb-informed price bands"),
        ("GAP-H", "Entropy-based fee scheduling"),
    ]

    # Return least-tested gaps first
    return sorted(all_gaps, key=lambda x: tested_hypotheses.get(x[0], 0))

def format_hypothesis_gaps(gaps: List[Tuple[str, str]]) -> str:
    """Format hypothesis gaps for prompt"""
    lines = []
    for gap_id, gap_desc in gaps:
        lines.append(f"- **{gap_id}**: {gap_desc}")
    return '\n'.join(lines)

# ============================================================================
# KNOWLEDGE CONTEXT FORMATTING
# ============================================================================

def format_knowledge_section(knowledge: dict) -> str:
    """Format harvested knowledge context for prompt inclusion."""
    if not knowledge:
        return ""

    sections = []

    # Note: Best edge is already shown in the prompt header, so we skip it here
    # to avoid confusion from potentially different values

    # Lessons learned
    lessons = knowledge.get('lessons_learned', [])
    if lessons:
        sections.append("### Lessons Learned")
        for lesson in lessons[:7]:  # Limit to 7
            # Truncate long lessons
            if len(lesson) > 100:
                lesson = lesson[:97] + "..."
            sections.append(f"- {lesson}")
        sections.append("")

    # Strategies tested table (prefer authoritative 1000-sim results)
    all_tested_1000 = knowledge.get('all_tested_strategies_1000', [])
    all_tested = all_tested_1000 or knowledge.get('all_tested_strategies', [])
    if all_tested:
        title = "### Strategies Tested (1000-Sim Canonical)"
        if not all_tested_1000:
            title = "### Strategies Tested (Best Available Sims)"
        sections.append(title)
        sections.append("")
        sections.append("| Strategy | Edge | Sims | Iter |")
        sections.append("|----------|------|------|------|")
        for s in all_tested[:12]:  # Limit to top 12
            name = s.get('name', 'Unknown')[:25]
            edge = s.get('edge', 0)
            sims = s.get('sims', 0)
            iteration = s.get('iteration', 0)
            sections.append(f"| {name} | {edge:.2f} | {sims} | {iteration} |")
        sections.append("")

    # Regressions to avoid
    regressions = knowledge.get('regressions', [])
    if regressions:
        sections.append("### Regressions to Avoid")
        sections.append("These modifications made performance worse:")
        for reg in regressions[:5]:  # Limit to 5
            from_s = reg.get('from', 'Unknown')
            from_e = reg.get('from_edge', 0)
            to_s = reg.get('to', 'Unknown')
            to_e = reg.get('to_edge', 0)
            delta = to_e - from_e
            sections.append(f"- **{from_s}** ({from_e:.1f}) -> **{to_s}** ({to_e:.1f}) [{delta:+.1f}]")
        sections.append("")

    if not sections:
        return ""

    return "## Accumulated Knowledge from Sessions\n\n" + "\n".join(sections)


def format_auto_plan_section(plan: dict) -> str:
    """Format autonomous plan guidance for prompt injection."""
    if not plan:
        return ""
    if not bool(plan.get("execute_this_iteration", False)):
        return ""

    selected = plan.get("selected_opportunity") or {}
    search_plan = plan.get("search_plan") or {}
    lines = ["## Autonomous Opportunity Plan (Execution Mode)"]
    lines.append(f"- **Mode**: {plan.get('mode', 'unknown')}")
    lines.append(f"- **Selected Opportunity**: {selected.get('id', 'unknown')}")
    if selected.get("rationale"):
        lines.append(f"- **Rationale**: {selected.get('rationale')}")
    if selected.get("expected_uplift") is not None:
        lines.append(f"- **Expected Uplift**: {selected.get('expected_uplift')} edge")

    frozen_core = search_plan.get("frozen_core") or []
    if frozen_core:
        lines.append("")
        lines.append("### Frozen Core (Do Not Rewrite)")
        for item in frozen_core:
            lines.append(f"- {item}")

    mutation_dims = search_plan.get("mutation_dimensions") or []
    if mutation_dims:
        lines.append("")
        lines.append("### Targeted Mutation Dimensions")
        for item in mutation_dims:
            lines.append(f"- {item}")

    run_budget = search_plan.get("run_budget") or {}
    if run_budget:
        lines.append("")
        lines.append("### Execution Budget")
        lines.append(f"- Variants: {run_budget.get('variants', 'N/A')}")
        lines.append(f"- Parallel Workers: {run_budget.get('parallel_workers', 'N/A')}")
        lines.append(f"- Authoritative Sims: {run_budget.get('authoritative_sims', 1000)}")
        lines.append("- Execute variants in parallel where possible.")
        lines.append("- Early-kill weak variants per criteria below.")

    promotion = search_plan.get("promotion_criteria") or {}
    if promotion:
        lines.append("")
        lines.append("### Promotion Criteria")
        for key, value in promotion.items():
            lines.append(f"- {key}: {value}")

    kill = search_plan.get("kill_criteria") or {}
    if kill:
        lines.append("")
        lines.append("### Kill Criteria")
        for key, value in kill.items():
            lines.append(f"- {key}: {value}")

    lines.append("")
    lines.append("### Implementation Instructions")
    lines.append("- Produce a concise batch plan and execute it immediately.")
    lines.append("- Prefer action over verbose planning.")
    lines.append("- Keep changes explainable and measurable against 1000-sim edge.")
    return "\n".join(lines)


# ============================================================================
# RECENT RESULTS FORMATTING
# ============================================================================

# ============================================================================
# INSIGHT LOADING (from forensics, synthesis, auditor)
# ============================================================================

def load_iteration_discoveries(state_dir: Path) -> str:
    """Load discoveries from previous iterations' knowledge files and manual discoveries."""
    discoveries = []

    # Check for manual discoveries file first (highest priority)
    manual_path = state_dir / 'discoveries_iter8_9.md'
    if manual_path.exists():
        return manual_path.read_text()

    # Load from knowledge JSON files (parsed from codex.jsonl)
    for i in range(1, 100):
        knowledge_path = state_dir / f'iteration_{i}_knowledge.json'
        if not knowledge_path.exists():
            continue
        try:
            data = json.loads(knowledge_path.read_text())
            experiments = data.get('edge_experiments', [])
            # Get top 3 from this iteration
            top = sorted(experiments, key=lambda x: x.get('edge', 0), reverse=True)[:3]
            for exp in top:
                discoveries.append(f"- {exp['strategy']}: {exp['edge']:.1f} edge")
        except Exception:
            continue

    if discoveries:
        return "### Previous Iteration Discoveries\n" + "\n".join(discoveries[:15])
    return ""


def load_insights(state_dir: Path) -> Dict:
    """Load insights from forensics, synthesis, auditor engines, and knowledge store."""
    insights = {
        'forensics': None,
        'synthesis': None,
        'audit': None,
        'discoveries': None,
        'knowledge_store': None,
    }

    # Load forensics insights
    forensics_path = state_dir / 'forensics_insights.json'
    if forensics_path.exists():
        try:
            data = json.loads(forensics_path.read_text())
            insights['forensics'] = data
        except Exception:
            pass

    # Load synthesis report
    synthesis_path = state_dir / 'synthesis_report.json'
    if synthesis_path.exists():
        try:
            data = json.loads(synthesis_path.read_text())
            insights['synthesis'] = data
        except Exception:
            pass

    # Load assumption audit
    audit_path = state_dir / 'assumption_audit.json'
    if audit_path.exists():
        try:
            data = json.loads(audit_path.read_text())
            insights['audit'] = data
        except Exception:
            pass

    # Load iteration discoveries
    discoveries = load_iteration_discoveries(state_dir)
    if discoveries:
        insights['discoveries'] = discoveries

    # Load from knowledge store
    try:
        from amm_phase7_knowledge_store import KnowledgeStore
        ks = KnowledgeStore(str(state_dir))
        knowledge_output = ks.format_for_prompt()
        if knowledge_output:
            insights['knowledge_store'] = knowledge_output
    except ImportError:
        pass
    except Exception:
        pass

    return insights


def format_insights_section(insights: Dict) -> str:
    """Format loaded insights for inclusion in prompt."""
    sections = []

    # Forensics insights
    if insights.get('forensics'):
        f = insights['forensics']
        lines = ["### Simulation Forensics Insights"]

        if 'edge_curves' in f and f['edge_curves']:
            ec = f['edge_curves']
            lines.append(f"- **Edge Timing**: Early game {ec.get('early_game_pct', 0):.0f}%, "
                        f"Mid game {ec.get('mid_game_pct', 0):.0f}%, "
                        f"Late game {ec.get('late_game_pct', 0):.0f}%")

        if 'price_regimes' in f and f['price_regimes']:
            pr = f['price_regimes']
            ratio = pr.get('vol_edge_ratio', 1)
            if ratio > 1.3:
                lines.append(f"- **Volatility**: Strategy excels in high-vol ({ratio:.1f}x edge ratio)")
            elif ratio < 0.8:
                lines.append(f"- **Volatility**: Strategy struggles in high-vol ({ratio:.1f}x edge ratio)")

        if 'fee_timing' in f and f['fee_timing']:
            ft = f['fee_timing']
            lines.append(f"- **Fee Timing**: {ft.get('timing_interpretation', 'N/A')}")

        sections.append('\n'.join(lines))

    # Synthesis insights
    if insights.get('synthesis'):
        s = insights['synthesis']
        lines = ["### Cross-Strategy Synthesis"]

        # Top mechanisms
        if 'mechanism_performance' in s:
            top_mechs = sorted(
                s['mechanism_performance'].items(),
                key=lambda x: x[1].get('avg_edge', 0),
                reverse=True
            )[:3]
            if top_mechs:
                mech_str = ", ".join([f"{m[0]} ({m[1].get('avg_edge', 0):.0f} avg edge)" for m in top_mechs])
                lines.append(f"- **Top Mechanisms**: {mech_str}")

        # Synthesis candidates
        if 'synthesis_candidates' in s and s['synthesis_candidates']:
            candidate = s['synthesis_candidates'][0]
            mechs = " + ".join(candidate.get('mechanisms', []))
            lines.append(f"- **Untested Combo**: {mechs} (predicted ~{candidate.get('predicted_edge', 0):.0f} edge)")

        # Parameter insights
        if 'parameter_insights' in s:
            for mech, insight in list(s['parameter_insights'].items())[:2]:
                if 'recommendation' in insight:
                    lines.append(f"- **{mech}**: {insight['recommendation']}")

        sections.append('\n'.join(lines))

    # Audit insights
    if insights.get('audit'):
        a = insights['audit']
        lines = ["### Assumption Audit"]

        # List violations
        if 'tests' in a:
            violations = [
                (name, result) for name, result in a['tests'].items()
                if result.get('status') == 'VIOLATED'
            ]
            for name, result in violations[:2]:
                lines.append(f"- **VIOLATED**: {result.get('assumption', name)}")
                lines.append(f"  - {result.get('implication', 'N/A')}")

            # List weak assumptions
            weak = [
                (name, result) for name, result in a['tests'].items()
                if result.get('status') == 'WEAK'
            ]
            for name, result in weak[:2]:
                lines.append(f"- **WEAK**: {result.get('assumption', name)} (r={result.get('correlation', 0):.2f})")

        sections.append('\n'.join(lines))

    # Discoveries from previous iterations
    if insights.get('discoveries'):
        sections.insert(0, insights['discoveries'])

    # Knowledge store (parameter optima, mechanism ceilings, etc.)
    if insights.get('knowledge_store'):
        sections.append("### Persistent Knowledge Store\n" + insights['knowledge_store'])

    if not sections:
        return ""

    return "\n---\n\n## AI-Generated Insights\n\n" + "\n\n".join(sections) + "\n"


def format_recent_results(state: Dict) -> str:
    """Format recent authoritative (1000-sim) results for context."""
    entries = state.get("strategies_log", [])
    if not entries:
        return "**No authoritative 1000-sim results logged yet.**"

    def get_authoritative_edge(entry: Dict):
        if not isinstance(entry, dict):
            return (None, None)
        metrics = entry.get("metrics", {})
        if isinstance(metrics, dict):
            edge_1000 = metrics.get("edge_1000", None)
            if edge_1000 is not None:
                try:
                    return (float(edge_1000), 1000)
                except (TypeError, ValueError):
                    pass
        n_sims = entry.get("n_simulations", None)
        final_edge = entry.get("final_edge", None)
        try:
            if n_sims is not None and int(n_sims) >= 1000 and final_edge is not None:
                return (float(final_edge), int(n_sims))
        except (TypeError, ValueError):
            pass
        return (None, None)

    recent = []
    for entry in reversed(entries):
        edge, sims = get_authoritative_edge(entry)
        if edge is None:
            continue
        row = dict(entry)
        row["_edge"] = edge
        row["_sims"] = sims
        recent.append(row)
        if len(recent) >= 8:
            break

    if not recent:
        return "**No authoritative 1000-sim results logged yet.**"

    lines = ["**Recent 1000-Sim Results**:", ""]
    for entry in recent:
        name = entry.get('strategy_name', 'Unknown')
        status = str(entry.get("status") or "unknown")
        edge = entry.get("_edge", None)
        sims = entry.get("_sims", None)
        hyp_ids = entry.get('hypothesis_ids', [])

        if isinstance(hyp_ids, list):
            hyp_str = ','.join(hyp_ids) if hyp_ids else 'H-baseline'
        else:
            hyp_str = 'H-baseline'

        edge_str = f"{edge:.2f}" if edge is not None else "N/A"
        sims_str = str(sims) if sims is not None else "?"

        note_parts = []
        if status != "ok":
            note_parts.append(status)
            err = entry.get("error") if isinstance(entry.get("error"), dict) else {}
            stage = err.get("stage")
            if stage:
                note_parts.append(f"stage={stage}")
            msg = err.get("message")
            if msg:
                msg = str(msg).replace("\n", " ").strip()
                note_parts.append(f"msg={msg[:80]}")
        note = f" [{' | '.join(note_parts)}]" if note_parts else ""

        lines.append(f"- {name}: Edge {edge_str} @ {sims_str} sims{note} (Hypothesis: {hyp_str})")

    return '\n'.join(lines)

# ============================================================================
# PROMPT BUILDING
# ============================================================================

def build_prompt(
    iteration: int,
    state_dir: Path,
    output_path: Path,
    *,
    target_edge: float,
    max_runtime_seconds: int,
    auto_plan_path: Optional[Path] = None,
):
    """Build context-rich prompt for Codex from current loop state."""
    state = load_state(state_dir)
    insights = load_insights(state_dir)

    prompt = PROMPT_TEMPLATE.format(
        current_target=target_edge,
        best_edge_display=f"{state['best_edge']:.2f} @ {int(state['best_edge_sims'] or 1000)} sims",
        iteration=iteration,
    )

    sections: List[str] = []

    recent_results = format_recent_results(state)
    if recent_results:
        sections.append(recent_results)

    knowledge_section = format_knowledge_section(state.get("knowledge_context", {}))
    if knowledge_section:
        sections.append(knowledge_section)

    insight_section = format_insights_section(insights)
    if insight_section:
        sections.append(insight_section.strip())

    if auto_plan_path is not None:
        auto_plan = load_auto_plan(auto_plan_path)
        auto_plan_section = format_auto_plan_section(auto_plan)
        if auto_plan_section:
            sections.append(auto_plan_section)

    hypothesis_gaps = select_hypothesis_gaps(state)[:5]
    if hypothesis_gaps:
        sections.append(
            "## Priority Hypothesis Gaps\n\n" + format_hypothesis_gaps(hypothesis_gaps)
        )

    if sections:
        prompt += "\n\n---\n\n" + "\n\n".join(sections) + "\n"

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(prompt)

    print(f"Prompt built: {output_path} ({len(prompt)} bytes)")

# ============================================================================
# MAIN
# ============================================================================

def main():
    parser = argparse.ArgumentParser(description="Build Phase 7 Codex prompt")
    parser.add_argument("--iteration", type=int, required=True, help="Current iteration number")
    parser.add_argument("--state-dir", required=True, help="Path to state directory")
    parser.add_argument("--output", required=True, help="Output path for prompt")
    parser.add_argument("--target-edge", type=float, default=527.0, help="Target edge to achieve (default: 527)")
    parser.add_argument(
        "--auto-plan",
        default="",
        help="Optional path to autonomous plan JSON for execution guidance",
    )
    parser.add_argument(
        "--max-runtime-seconds",
        type=int,
        default=36000,
        help="Max runtime in seconds (default: 36000 = 10 hours)",
    )
    args = parser.parse_args()

    build_prompt(
        args.iteration,
        Path(args.state_dir),
        Path(args.output),
        target_edge=args.target_edge,
        max_runtime_seconds=args.max_runtime_seconds,
        auto_plan_path=Path(args.auto_plan) if args.auto_plan else None,
    )

if __name__ == "__main__":
    main()
