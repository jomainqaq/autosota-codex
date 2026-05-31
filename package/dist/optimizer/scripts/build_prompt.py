#!/usr/bin/env python3
"""Compatibility wrapper for the bundled prompt builder."""

import argparse
import re
import subprocess
import sys
from pathlib import Path

import yaml


def load_config(path):
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def as_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def lower_is_better(cfg):
    direction = str(cfg.get("metric_direction") or "").strip().lower()
    if direction:
        return direction.startswith("lower") or direction.startswith("min")
    if "lower_is_better" in cfg:
        return bool(cfg.get("lower_is_better"))
    return False


def fmt(value):
    text = f"{float(value):.10g}"
    return "0" if text == "-0" else text


def patch_prompt_target(output_path, cfg):
    target_value = as_float(cfg.get("target_value"))
    if target_value is None or cfg.get("target_improvement_pct") is not None:
        return
    primary = str(cfg.get("primary_metric") or "").strip()
    if not primary:
        return

    path = Path(output_path)
    if not path.is_file():
        return
    text = path.read_text(encoding="utf-8")

    lower = lower_is_better(cfg)
    op = "<=" if lower else ">="
    action = "Decrease" if lower else "Improve"
    better = "Lower" if lower else "Higher"
    value_text = fmt(target_value)

    baseline = None
    baselines = cfg.get("baseline_metrics")
    if isinstance(baselines, dict):
        baseline = as_float(baselines.get(primary))
    if baseline not in (None, 0):
        delta = ((baseline - target_value) if lower else (target_value - baseline)) / abs(baseline) * 100.0
        delta_label = "decrease" if lower else "increase"
        goal = (
            f"**Optimization goal**: {action} `{primary}` to {op} **{value_text}** "
            f"({delta_label} {fmt(delta)}% vs baseline of {fmt(baseline)}). {better} is better for this metric."
        )
    else:
        goal = (
            f"**Optimization goal**: {action} `{primary}` to {op} **{value_text}** "
            f"from the explicit target in target.md. {better} is better for this metric."
        )

    escaped = re.escape(primary)
    text, goal_count = re.subn(
        rf"\*\*Optimization goal\*\*: [^\n]*`{escaped}`[^\n]*",
        goal,
        text,
        count=1,
    )
    text = re.sub(
        rf"Stop early if `{escaped}`\s*(?:<=|>=)\s*[-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?\.",
        f"Stop early if `{primary}` {op} {value_text}.",
        text,
    )
    text = re.sub(
        rf"IF BEST_SCORE\s*(?:<=|>=)\s*[-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?:",
        f"IF BEST_SCORE {op} {value_text}:",
        text,
    )

    if goal_count:
        path.write_text(text, encoding="utf-8")
        print(f"  [BuildPrompt] Target corrected from target_value: {primary} {op} {value_text}")


def parse_args(argv):
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--config")
    parser.add_argument("--output")
    known, _ = parser.parse_known_args(argv)
    return known


def main():
    args = parse_args(sys.argv[1:])
    impl_path = Path(__file__).with_name("_build_prompt_impl.py")
    result = subprocess.run([sys.executable, str(impl_path), *sys.argv[1:]], check=False)
    if result.returncode == 0 and args.config and args.output:
        patch_prompt_target(args.output, load_config(args.config))
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
