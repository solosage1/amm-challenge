#!/usr/bin/env python3
"""
AMM Phase 7 Knowledge Store

Persistent storage for learning across iterations:
- Parameter optima discovered
- Mechanism effectiveness ceilings
- Failed approaches (to avoid re-exploring)
- Regime-specific insights

Usage:
    from amm_phase7_knowledge_store import KnowledgeStore

    ks = KnowledgeStore('.ralph-amm/phase7/state')
    ks.record_edge_result('ArbOracleDualRegime', 502.5,
                          ['fair_inference', 'dual_regime'],
                          {'ewma_alpha': 0.2, 'buffer': 5})
    ks.record_insight('mechanism_ceiling', 'dual_regime saturates at ~505',
                     'Iterations 7-9 all hit 502-508', 0.8)

    # Get formatted output for prompt injection
    prompt_section = ks.format_for_prompt()
"""

import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional


class KnowledgeStore:
    """Persistent knowledge storage for Phase 7 learning."""

    def __init__(self, state_dir: str):
        self.state_dir = Path(state_dir)
        self.state_dir.mkdir(parents=True, exist_ok=True)

        self.store_path = self.state_dir / 'knowledge_store.json'
        self._data = self._load()

    def _load(self) -> Dict[str, Any]:
        """Load existing knowledge store or create new."""
        if self.store_path.exists():
            try:
                return json.loads(self.store_path.read_text())
            except json.JSONDecodeError:
                pass

        return {
            'version': 1,
            'created': datetime.now(timezone.utc).isoformat(),
            'edge_results': [],
            'parameter_optima': {},
            'mechanism_ceilings': {},
            'failed_approaches': [],
            'insights': [],
            'regime_weaknesses': [],
        }

    def _save(self) -> None:
        """Atomically save knowledge store."""
        self._data['updated'] = datetime.now(timezone.utc).isoformat()
        tmp = self.store_path.with_suffix('.json.tmp')
        tmp.write_text(json.dumps(self._data, indent=2))
        os.replace(tmp, self.store_path)

    def record_edge_result(
        self,
        strategy: str,
        edge: float,
        mechanisms: List[str],
        parameters: Dict[str, float],
        iteration: Optional[int] = None,
    ) -> None:
        """Record an edge result with its mechanisms and parameters.

        Args:
            strategy: Strategy name
            edge: Edge score achieved
            mechanisms: List of mechanisms used (e.g., ['fair_inference', 'dual_regime'])
            parameters: Dict of parameter values (e.g., {'ewma_alpha': 0.2})
            iteration: Optional iteration number
        """
        entry = {
            'timestamp': datetime.now(timezone.utc).isoformat(),
            'strategy': strategy,
            'edge': edge,
            'mechanisms': mechanisms,
            'parameters': parameters,
            'iteration': iteration,
        }
        self._data['edge_results'].append(entry)

        # Update parameter optima
        for param, value in parameters.items():
            if param not in self._data['parameter_optima']:
                self._data['parameter_optima'][param] = {
                    'best_value': value,
                    'best_edge': edge,
                    'all_tested': [{value: edge}],
                }
            else:
                optima = self._data['parameter_optima'][param]
                if edge > optima['best_edge']:
                    optima['best_value'] = value
                    optima['best_edge'] = edge
                # Track all tested values
                optima['all_tested'].append({value: edge})

        # Update mechanism ceilings
        for mech in mechanisms:
            if mech not in self._data['mechanism_ceilings']:
                self._data['mechanism_ceilings'][mech] = {
                    'ceiling': edge,
                    'ceiling_strategy': strategy,
                    'appearances': 1,
                }
            else:
                ceiling = self._data['mechanism_ceilings'][mech]
                ceiling['appearances'] += 1
                if edge > ceiling['ceiling']:
                    ceiling['ceiling'] = edge
                    ceiling['ceiling_strategy'] = strategy

        self._save()

    def record_insight(
        self,
        category: str,
        insight: str,
        evidence: str,
        confidence: float,
    ) -> None:
        """Record a learning insight.

        Args:
            category: Type of insight (e.g., 'mechanism_ceiling', 'parameter_sensitivity')
            insight: The insight statement
            evidence: Supporting evidence
            confidence: Confidence level 0.0-1.0
        """
        entry = {
            'timestamp': datetime.now(timezone.utc).isoformat(),
            'category': category,
            'insight': insight,
            'evidence': evidence,
            'confidence': confidence,
        }
        self._data['insights'].append(entry)
        self._save()

    def record_failed_approach(
        self,
        approach: str,
        reason: str,
        edge_achieved: Optional[float] = None,
    ) -> None:
        """Record an approach that failed or underperformed.

        Args:
            approach: Description of the approach
            reason: Why it failed
            edge_achieved: Edge score if any
        """
        entry = {
            'timestamp': datetime.now(timezone.utc).isoformat(),
            'approach': approach,
            'reason': reason,
            'edge_achieved': edge_achieved,
        }
        self._data['failed_approaches'].append(entry)
        self._save()

    def record_regime_weakness(
        self,
        strategy: str,
        regime: str,
        edge_at_regime: float,
        nominal_edge: float,
        spread: float,
    ) -> None:
        """Record a regime-specific weakness.

        Args:
            strategy: Strategy name
            regime: Which regime is weak (e.g., 'high_vol', 'low_retail')
            edge_at_regime: Edge at the weak regime
            nominal_edge: Edge at nominal conditions
            spread: Difference between best and worst regimes
        """
        entry = {
            'timestamp': datetime.now(timezone.utc).isoformat(),
            'strategy': strategy,
            'regime': regime,
            'edge_at_regime': edge_at_regime,
            'nominal_edge': nominal_edge,
            'spread': spread,
        }
        self._data['regime_weaknesses'].append(entry)
        self._save()

    def get_best_parameters(self) -> Dict[str, Dict]:
        """Get the best parameter values discovered."""
        return self._data['parameter_optima']

    def get_mechanism_ceilings(self) -> Dict[str, Dict]:
        """Get mechanism ceilings."""
        return self._data['mechanism_ceilings']

    def get_high_confidence_insights(self, min_confidence: float = 0.7) -> List[Dict]:
        """Get insights above confidence threshold."""
        return [
            i for i in self._data['insights']
            if i.get('confidence', 0) >= min_confidence
        ]

    def format_for_prompt(self, max_sections: int = 3) -> str:
        """Format knowledge store for prompt injection.

        Returns markdown suitable for adding to prompts.
        """
        lines = []

        # Best parameter values
        optima = self._data['parameter_optima']
        if optima:
            lines.append("### Known Parameter Optima")
            lines.append("| Parameter | Best Value | Best Edge |")
            lines.append("|-----------|------------|-----------|")
            for param, data in sorted(optima.items(), key=lambda x: -x[1]['best_edge']):
                lines.append(f"| {param} | {data['best_value']} | {data['best_edge']:.1f} |")
            lines.append("")

        # Mechanism ceilings
        ceilings = self._data['mechanism_ceilings']
        if ceilings:
            lines.append("### Mechanism Ceilings (Known Limits)")
            lines.append("| Mechanism | Ceiling | Appearances |")
            lines.append("|-----------|---------|-------------|")
            for mech, data in sorted(ceilings.items(), key=lambda x: -x[1]['ceiling']):
                lines.append(f"| {mech} | {data['ceiling']:.1f} | {data['appearances']} |")
            lines.append("")

        # High-confidence insights
        insights = self.get_high_confidence_insights(0.7)
        if insights:
            lines.append("### Key Insights (High Confidence)")
            for i in insights[-5:]:  # Most recent 5
                lines.append(f"- **{i['category']}**: {i['insight']}")
            lines.append("")

        # Failed approaches (avoid these)
        failed = self._data['failed_approaches']
        if failed:
            lines.append("### Approaches to Avoid")
            for f in failed[-5:]:
                lines.append(f"- {f['approach']}: {f['reason']}")
            lines.append("")

        # Regime weaknesses
        weaknesses = self._data['regime_weaknesses']
        if weaknesses:
            lines.append("### Regime-Specific Weaknesses")
            for w in weaknesses[-3:]:
                lines.append(f"- {w['strategy']}: weak at {w['regime']} "
                           f"(edge={w['edge_at_regime']:.1f}, spread={w['spread']:.1f})")
            lines.append("")

        return "\n".join(lines) if lines else ""


def main():
    """CLI for knowledge store operations."""
    import argparse

    parser = argparse.ArgumentParser(description="Knowledge store CLI")
    parser.add_argument('--state-dir', default='.ralph-amm/phase7/state',
                       help='State directory')
    parser.add_argument('--format', action='store_true',
                       help='Output formatted for prompt')
    parser.add_argument('--json', action='store_true',
                       help='Output raw JSON')

    args = parser.parse_args()

    ks = KnowledgeStore(args.state_dir)

    if args.format:
        print(ks.format_for_prompt())
    elif args.json:
        print(json.dumps(ks._data, indent=2))
    else:
        # Summary
        print(f"Knowledge Store: {ks.store_path}")
        print(f"  Edge results: {len(ks._data['edge_results'])}")
        print(f"  Parameter optima: {len(ks._data['parameter_optima'])}")
        print(f"  Mechanism ceilings: {len(ks._data['mechanism_ceilings'])}")
        print(f"  Insights: {len(ks._data['insights'])}")
        print(f"  Failed approaches: {len(ks._data['failed_approaches'])}")


if __name__ == '__main__':
    main()
