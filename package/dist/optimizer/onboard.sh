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

ORIG_ARGS=("$@")
PAPER_NAME=""
EXPECT_VALUE=false
for arg in "${ORIG_ARGS[@]}"; do
    if [ "${EXPECT_VALUE}" = true ]; then
        EXPECT_VALUE=false
        continue
    fi
    case "${arg}" in
        --repo|--repro-log|--api-key|--paper-dir|--target|--claude-log-file)
            EXPECT_VALUE=true
            ;;
        --dry-run|--force|--*)
            ;;
        *)
            PAPER_NAME="${arg}"
            break
            ;;
    esac
done

sanitize_saved_prompt() {
    local repo_path="${AUTOSOTA_ONBOARD_REPO_PATH:-}"
    local data_dir="${AUTOSOTA_DATA_DIR:-}"
    local paper_name="${PAPER_NAME:-}"

    if [ -z "${repo_path}" ] || [ -z "${data_dir}" ] || [ -z "${paper_name}" ]; then
        return 0
    fi
    if [[ "${repo_path}" != /* ]] || [ ! -d "${repo_path}" ]; then
        return 0
    fi

    python - "${data_dir}/papers/${paper_name}/onboard_prompt.md" "${repo_path}" <<'PYEOF'
import re
import shlex
import sys
from pathlib import Path

prompt_path = Path(sys.argv[1])
repo_path = sys.argv[2]
if not prompt_path.is_file():
    raise SystemExit(0)

text = prompt_path.read_text(encoding="utf-8")
if "# Paper Onboarding Task" not in text:
    raise SystemExit(0)

safe_step1 = "\n".join([
    "### Step 1 - Verify the Local Repository Boundary",
    "",
    "The local repository path has already been resolved by autosota.",
    f"Use exactly this repository path as `repo_path`: `{repo_path}`",
    "",
    "Allowed search boundary: REPO_PATH only. Do not run find, rg, grep, or ls against /, /home, $HOME, mounted drives, sibling directories, or any path outside REPO_PATH.",
    "If REPO_PATH does not contain the expected code, stop and report the mismatch instead of broadening the search.",
    "",
    "```bash",
    f"REPO_PATH={shlex.quote(repo_path)}",
    'test -d "$REPO_PATH"',
    'ls "$REPO_PATH"',
    'test -f "$REPO_PATH/README.md" && sed -n "1,200p" "$REPO_PATH/README.md"',
    "```",
    "",
])

boundary_note = "\n".join([
    "## Repository Search Boundary",
    "",
    f"Autosota resolved the repository to `{repo_path}`. All code discovery must stay inside this directory.",
    "Do not use whole-filesystem, home-directory, sibling-directory, or mounted-drive discovery commands.",
    "",
])

updated = re.sub(
    r"### Step 1[^\n]*\n[\s\S]*?(?=### Step 2[^\n]*\n)",
    safe_step1,
    text,
    count=1,
)
updated = updated.replace('REPO_PATH="<discovered_repo_path>"', f"REPO_PATH={shlex.quote(repo_path)}")
updated = updated.replace("\n## Goal\n", f"\n{boundary_note}## Goal\n", 1)
if updated != text:
    prompt_path.write_text(updated, encoding="utf-8")
    print(f"[Onboard] Sanitized prompt search boundary: {prompt_path}")
PYEOF
}

python "$SCRIPT_DIR/scripts/onboard.py" "${ORIG_ARGS[@]}"
STATUS=$?
sanitize_saved_prompt
exit "${STATUS}"
