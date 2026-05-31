# paper-optimizer

Autonomous ML paper result optimization using Claude Code.

Given a paper whose code is **already cloned on the host** and whose evaluation environment **runs locally** (GPU / Python / data paths you manage), this tool launches Claude Code to **analyze the codebase, brainstorm ideas, run experiments, and iterate until metrics improve over the baseline**.

## How It Works

```
optimize.sh savvy
       │
       ├── [1] Deep Research     → calls OpenRouter o4-mini-deep-research
       │                           saves research_report.md
       │
       ├── [2] Build Prompt      → fills template with paper config + research
       │                           saves master_prompt.md
       │
       ├── [3] Claude Code       → runs autonomously on the host:
       │       │
       │       ├── Phase 0: Confirm repo_path, venv/env, git snapshot, baseline eval
       │       ├── Phase 1: Deep code analysis → code_analysis.md
       │       ├── Phase 2: Idea library generation → idea_library.md
       │       └── Phase 3: Optimization loop (up to N iterations):
       │               ① Select idea from library
       │               ② Git snapshot (before modifying!)
       │               ③ Implement change
       │               ④ Evaluate locally (same shell / repo_path)
       │               ⑤ Debug if needed (max attempts + time limit)
       │               ⑥ Record result → scores.jsonl
       │               ⑦ Rollback if regression, update idea library
       │
       └── [4] Plot              → reads scores.jsonl → optimization_curve.png
```

## Project Structure

```
paper-optimizer/
├── optimize.sh               ← entry point
├── requirements.txt
├── scripts/
│   ├── run.py                ← main orchestrator (Python)
│   ├── deep_research.py      ← OpenRouter API call
│   ├── build_prompt.py       ← assemble master prompt from template + config
│   └── plot_results.py       ← generate optimization_curve.png
├── prompts/
│   └── optimize_prompt.md    ← master prompt template (the "brain")
└── papers/
    └── <paper_name>/
        ├── config.yaml        ← paper-specific config
        └── runs/
            ├── latest -> run_YYYYMMDD_HHMMSS/   (symlink)
            └── run_YYYYMMDD_HHMMSS/
                ├── memory/
                │   ├── code_analysis.md
                │   ├── research_report.md
                │   └── idea_library.md
                ├── results/
                │   ├── scores.jsonl
                │   ├── optimization_curve.png
                │   └── final_report.md
                └── logs/
                    ├── master_prompt.md
                    └── claude_output.log
```

## Quick Start

### Prerequisites

1. **Claude Code CLI** installed: `npm install -g @anthropic-ai/claude-code`
2. **Local clone** of the paper code at `repo_path`, with eval runnable from that tree
3. **Python 3.10+** with pip (project uses `optimizer/.venv` via `install.sh` at repo root)
4. An **OpenRouter API key** (for deep research; optional — use `--skip-research` to bypass)

### Add a New Paper

### Option A — Auto-onboard (recommended)

Provide the paper name and a **local path or GitHub URL hint**. Claude discovers `eval_command`, baseline metrics, and writes `config.yaml`:

```bash
# Local clone path (recommended)
./onboard.sh <paper_name> --repo /path/to/your/clone

# Optional: reproduction log file or directory (better baselines)
./onboard.sh <paper_name> --repo /path/to/clone --repro-log /path/to/repro.log

# Or let optimize trigger onboard when config is missing
./optimize.sh <paper_name> --repo /path/to/your/clone
```

After onboarding, verify `papers/<paper_name>/config.yaml` (`repo_path`, `venv_path`, `env_vars`, `eval_command`) then run:

```bash
./optimize.sh <paper_name> --skip-research
```

### Option B — Manual config

1. Create `papers/<paper_name>/config.yaml` (copy from another paper under `papers/` and edit)
2. Fill in: `paper_title`, `repo_path` (absolute path on host), optional `venv_path` / `env_vars`, `eval_command`, `baseline_metrics`

### Run Optimization

```bash
# Full run (with deep research)
./optimize.sh savvy

# Skip deep research (faster start)
./optimize.sh savvy --skip-research

# Preview the prompt without running
./optimize.sh savvy --dry-run

# Limit iterations
./optimize.sh savvy --skip-research --max-iter 5

# Background run
nohup ./optimize.sh savvy --skip-research > run.log 2>&1 &
tail -f run.log
```

## config.yaml Reference

```yaml
paper_title: "Paper Name"
paper_repo_url: "https://github.com/..."

# Local workspace
gpu_devices: "0,1"
repo_path: "/home/you/projects/REPONAME"   # absolute path on host
venv_path: "/home/you/projects/REPONAME/.venv/bin/activate"  # optional
env_vars: "CUDA_VISIBLE_DEVICES=0"         # optional

# Evaluation
eval_command: "python eval.py"
eval_timeout_minutes: 30

# Baseline metrics
baseline_metrics:
  overall: 58.0
  metric_a: 84.7
primary_metric: "overall"
metric_direction: "higher"   # or "lower"

# Loop settings
max_iterations: 20
max_debug_attempts: 3
max_debug_minutes: 15

# Deep research
research_api_key: "sk-example-change-me"
research_base_url: "http://127.0.0.1:8080/v1"
research_model: "openai/o4-mini-deep-research"
research_timeout_minutes: 20
openrouter_api_key: ""  # legacy fallback; leave empty when research_api_key is set
```

Replace `research_api_key` with your real key and `research_base_url` with
your OpenAI-compatible API endpoint. For local/proxy endpoints, keep the `/v1`
suffix, for example `http://your-openai-compatible-server:8080/v1` instead of
`http://your-openai-compatible-server:8080`.

## Output Files

| File | Description |
|------|-------------|
| `memory/code_analysis.md` | Claude's understanding of the codebase |
| `memory/idea_library.md` | All optimization ideas + iteration log |
| `memory/research_report.md` | Deep research report (if enabled) |
| `results/scores.jsonl` | One JSON line per iteration |
| `results/optimization_curve.png` | Plot of metrics across iterations |
| `results/final_report.md` | Final summary |
| `logs/master_prompt.md` | Full prompt sent to Claude Code |
| `logs/claude_output.log` | Raw Claude Code output |

## Version Control Design

Claude uses **git inside `repo_path`** on the host:

- At start: `git init` (if needed) + baseline commit tagged `_baseline`
- Before each modification: snapshot commit / `_pre_iter` tag
- After improvement: `_best` tag when appropriate
- On failure/regression: checkout prior state

The repo at `repo_path` is the single source of truth; `record_score.sh` runs with `--repo <repo_path>`.
