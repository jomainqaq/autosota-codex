#!/bin/bash
# onboard.sh — Auto-discover config for a new paper via Claude Code
#
# Usage:
#   ./onboard.sh <paper_name> [options]
#
# Options:
#   --repo      <path_or_url>  Local clone path or GitHub URL hint
#   --repro-log <path>         Path to reproduction log file or directory
#                              (RECOMMENDED: dramatically speeds up onboarding and
#                               gives accurate baseline metrics from actual runs)
#   --api-key   <key>          OpenRouter API key (or set OPENROUTER_API_KEY)
#   --dry-run                  Preview prompt without running Claude
#
# Examples:
#   ./onboard.sh ts-rag --repo /path/to/TS-RAG
#
#   # Fast mode with reproduction log (recommended):
#   ./onboard.sh paper-27 \
#       --repo /path/to/repo \
#       --repro-log /path/to/reproduction_logs/g1_027_....log
#
# After onboarding succeeds, run:
#   ./optimize.sh <paper_name> --skip-research

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <paper_name> [--repo PATH_OR_URL] [--repro-log PATH] [--dry-run]"
    echo ""
    echo "Examples:"
    echo "  $0 ts-rag --repo /path/to/TS-RAG"
    echo "  $0 paper-27 --repo /path/to/repo --repro-log /path/to/repro.log"
    exit 1
fi

# Activate venv — honour the path that run.sh already set up (AUTOSOTA_DATA_DIR/venv)
# and fall back to legacy locations for standalone use.
VENV_CANDIDATES=()
[ -n "${AUTOSOTA_DATA_DIR:-}" ] && VENV_CANDIDATES+=("$AUTOSOTA_DATA_DIR/venv")
[ -n "${AUTOSOTA_WORKSPACE:-}" ] && VENV_CANDIDATES+=("$AUTOSOTA_WORKSPACE/.autosota/venv")
VENV_CANDIDATES+=("$SCRIPT_DIR/.venv" "$HOME/.autosota/venv" "$HOME/.venv")

for venv in "${VENV_CANDIDATES[@]}"; do
    if [ -f "$venv/bin/activate" ]; then
        # shellcheck disable=SC1090
        source "$venv/bin/activate"
        break
    fi
done

python -c "import yaml" 2>/dev/null || pip install -q pyyaml

exec python "$SCRIPT_DIR/scripts/onboard.py" "$@"
