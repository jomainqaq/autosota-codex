#!/bin/bash
# optimize.sh — Entry point for paper-optimizer
#
# Usage:
#   ./optimize.sh <paper_name> [options]
#
# Options:
#   --skip-research      Skip deep research phase (use cached report)
#   --dry-run            Build prompt, but don't actually run Claude Code
#   --max-iter N         Override max_iterations from config
#   --max-total-minutes M  Wall-clock cap on Claude (minutes); maps to max_total_hours in config
#   --reuse-run DIR      Resume from an existing run directory
#   --repo <path_or_url> Auto-onboard: local clone path or GitHub repo URL hint
#   --api-key <key>      OpenRouter API key (overrides OPENROUTER_API_KEY env)
#
# Exit code: matches Claude Code when it runs (non-zero on failure/timeout); if Claude exits 0
# but plot_results fails, exits with the plot script's code. Dry-run exits 0 after prompt build.
#
# Examples:
#   ./optimize.sh savvy                                             # Run with existing config
#   ./optimize.sh savvy --skip-research                            # Skip deep research
#   ./optimize.sh savvy --dry-run                                  # Preview prompt only
#   ./optimize.sh savvy --max-iter 10                              # Limit iterations
#   ./optimize.sh newpaper --repo /path/to/clone                    # Auto-discover config

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

_newest_run_dir() {
    local paper_name="$1"
    local runs_dir="${AUTOSOTA_DATA_DIR:-${SCRIPT_DIR}}/papers/${paper_name}/runs"
    [ -d "${runs_dir}" ] || return 0
    python - "${runs_dir}" <<'PYEOF'
import os
import sys

runs_dir = sys.argv[1]
runs = [
    name for name in os.listdir(runs_dir)
    if name.startswith("run_") and os.path.isdir(os.path.join(runs_dir, name))
]
print(os.path.join(runs_dir, sorted(runs)[-1]) if runs else "")
PYEOF
}

_set_latest_run() {
    local paper_name="$1"
    local run_dir="$2"
    local runs_dir="${AUTOSOTA_DATA_DIR:-${SCRIPT_DIR}}/papers/${paper_name}/runs"
    [ -n "${run_dir}" ] && [ -d "${run_dir}" ] && [ -d "${runs_dir}" ] || return 0
    if [ -L "${runs_dir}/latest" ] || [ ! -e "${runs_dir}/latest" ]; then
        ln -sfn "${run_dir}" "${runs_dir}/latest" || true
    fi
}

_sync_latest_when_created() {
    local paper_name="$1"
    local initial_newest="$2"
    local child_pid="$3"
    local newest=""

    while kill -0 "${child_pid}" 2>/dev/null; do
        newest="$(_newest_run_dir "${paper_name}")"
        if [ -n "${newest}" ] && [ "${newest}" != "${initial_newest}" ]; then
            _set_latest_run "${paper_name}" "${newest}"
            echo "[Run] latest -> ${newest}"
            return 0
        fi
        sleep 1
    done
    return 0
}

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <paper_name> [--skip-research] [--dry-run] [--max-iter N]"
    echo ""
    echo "Available papers:"
    if [ -d "$SCRIPT_DIR/papers" ]; then
        ls "$SCRIPT_DIR/papers/" | sed 's/^/  /'
    fi
    exit 1
fi

# Activate virtual environment — prefer the writable data dir set up by run.sh
VENV_CANDIDATES=()
[ -n "${AUTOSOTA_DATA_DIR:-}" ] && VENV_CANDIDATES+=("$AUTOSOTA_DATA_DIR/venv")
[ -n "${AUTOSOTA_WORKSPACE:-}" ] && VENV_CANDIDATES+=("$AUTOSOTA_WORKSPACE/.autosota/venv")
VENV_CANDIDATES+=(
    "$SCRIPT_DIR/.venv"
    "$HOME/.autosota/venv"
    "$HOME/.venv"
)

VENV_ACTIVATED=false
for venv in "${VENV_CANDIDATES[@]}"; do
    if [ -f "$venv/bin/activate" ]; then
        # shellcheck disable=SC1090
        source "$venv/bin/activate"
        VENV_ACTIVATED=true
        echo "[Setup] Using venv: $venv"
        break
    fi
done

if [ "$VENV_ACTIVATED" = false ]; then
    echo "[Setup] No venv found, using system Python."
fi

# Check required Python packages
python -c "import yaml, openai, matplotlib" 2>/dev/null || {
    echo "[Setup] Installing required packages..."
    pip install -q pyyaml openai matplotlib
}

# Delegate to the Python orchestrator, but keep this shell alive briefly so
# runs/latest can be updated as soon as the new run directory appears.
PAPER_NAME="$1"
INITIAL_NEWEST="$(_newest_run_dir "${PAPER_NAME}")"
python "$SCRIPT_DIR/scripts/run.py" "$@" &
PYTHON_PID=$!

trap 'kill -TERM "${PYTHON_PID}" 2>/dev/null || true; wait "${PYTHON_PID}" 2>/dev/null || true; exit 143' INT TERM
_sync_latest_when_created "${PAPER_NAME}" "${INITIAL_NEWEST}" "${PYTHON_PID}"
set +e
wait "${PYTHON_PID}"
STATUS=$?
set -e
trap - INT TERM
FINAL_NEWEST="$(_newest_run_dir "${PAPER_NAME}")"
_set_latest_run "${PAPER_NAME}" "${FINAL_NEWEST}"
exit "${STATUS}"
