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

# Delegate everything to the Python orchestrator
exec python "$SCRIPT_DIR/scripts/run.py" "$@"
