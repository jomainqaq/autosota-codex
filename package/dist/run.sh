#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  run.sh — Optimize a paper's ML code to exceed SOTA
#
#  Usage:
#    bash run.sh [paper_name] [options]
#
#  Input files (put in paper/ directory):
#    paper/paper.pdf           论文 PDF（可选，帮助 Codex 理解背景）
#    paper/target.md           优化目标（指标、基线值、方向）← 从中自动推断目录名
#
#  Optional:
#    [paper_name]              结果存储目录名（默认从 target.md 自动推断）
#    --paper-dir <path>        论文文件目录（默认: ./paper/）
#    --target <path>           target.md 路径（默认: <paper-dir>/target.md）
#    --repo <path_or_url>      本地克隆路径或仓库 URL 提示（传给 onboard）
#    --devices <gpu_ids>       使用的 GPU（默认: 0,1）
#    --api-key <key>           OpenRouter API key（覆盖 config.yaml）
#    --skip-onboard            跳过 onboard，直接使用已有 config.yaml
#    --force-onboard           强制重新 onboard（即使 config.yaml 已存在）
#    --skip-research           跳过文献调研阶段
#    --skip-export             跳过优化结束后的代码导出步骤
#    --export-on-failure       在 optimize 非 0 退出时仍执行导出（默认仅成功时导出）
#    --dry-run                 只生成 prompt，不实际运行
#    --priors-dir <path>        先验知识目录（默认: ./paper/priors/）
#                               可包含 references.md / ideas.md / directions.md
#    --review-ideas             两阶段模式：先生成 idea library，暂停等待人工审核，再继续优化
#    --ideas-file <path>        直接注入已有的 idea_library.md（跳过 PHASE 2 idea 生成）
#    --max-iter N              覆盖最大迭代次数
#    --target-pct N            覆盖目标提升百分比（默认来自 config.yaml）
#    --max-debug N             覆盖每轮最大调试次数
#    --max-debug-min N         覆盖每次调试超时分钟数
#    --research-timeout N      覆盖文献调研超时分钟数
#    --max-total-minutes M     Codex 进程墙钟上限（分钟，防止长时间占用；冒烟测试可设 10～15）
#    -i, --interactive         交互模式：每轮迭代结束后暂停，等待 `autosota continue` 放行
#                              （配合 `autosota steer` 可在轮间精准注入指示）
#
#  Outputs:
#    logs/sota/<paper>.log             整体运行日志（同时输出到终端）
#    logs/optimizer_detail/<paper>_onboard.log   onboard Codex 详细日志
#    logs/optimizer_detail/<paper>.log           optimize Codex 详细日志
#    optimized_code/<paper>/           优化后的最佳代码（从本地 repo_path 导出）
#
#  环境变量（npm 全局安装 `autosota` 时会自动设置）:
#    AUTOSOTA_WORKSPACE   工作区根目录（默认: 本仓库根；CLI 下为当前工作目录）
#    AUTOSOTA_ROOT        安装包根目录（含 optimizer/、run.sh）
#
#  Examples:
#    bash run.sh                                                   # 自动推断名称
#    bash run.sh ts-rag --repo /path/to/clone
#    bash run.sh --devices 2,3
#    bash run.sh --skip-onboard --skip-research                  # 已有 config，快速重跑
#    bash run.sh mypaper --export-on-failure                     # 优化失败仍导出 optimized_code 快照
# ═══════════════════════════════════════════════════════════════════════════

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPTIMIZER_DIR="${SCRIPT_DIR}/optimizer"

# ── Workspace & data roots ────────────────────────────────────────────────
# WORKSPACE_ROOT:  where paper/, config.yaml, logs/, optimized_code/ live
#                  (= cwd when invoked via `autosota` CLI; = SCRIPT_DIR in dev)
# DATA_DIR:        writable runtime state (venv, papers/<name>/config.yaml,
#                  runs/), never inside the read-only npm install tree.
WORKSPACE_ROOT="${AUTOSOTA_WORKSPACE:-$SCRIPT_DIR}"
if [ -n "${AUTOSOTA_DATA_DIR:-}" ]; then
    DATA_DIR="${AUTOSOTA_DATA_DIR}"
elif [ "${WORKSPACE_ROOT}" = "${SCRIPT_DIR}" ]; then
    # Dev mode: keep legacy layout (<repo>/optimizer/.venv, <repo>/optimizer/papers/)
    DATA_DIR="${OPTIMIZER_DIR}"
else
    DATA_DIR="${WORKSPACE_ROOT}/.autosota"
fi
export AUTOSOTA_DATA_DIR="${DATA_DIR}"
mkdir -p "${DATA_DIR}/papers"

VENV_DIR="${DATA_DIR}/venv"
# Back-compat: if a legacy optimizer/.venv still exists in dev checkouts, reuse it.
if [ ! -f "${VENV_DIR}/bin/python" ] && [ -f "${OPTIMIZER_DIR}/.venv/bin/python" ]; then
    VENV_DIR="${OPTIMIZER_DIR}/.venv"
fi

ROOT_CONFIG=""
if [ -f "${WORKSPACE_ROOT}/config.yaml" ]; then
    ROOT_CONFIG="${WORKSPACE_ROOT}/config.yaml"
elif [ -f "${SCRIPT_DIR}/config.yaml" ]; then
    ROOT_CONFIG="${SCRIPT_DIR}/config.yaml"
fi

# ── Helper: export best code from local repo_path (see papers/<paper>/config.yaml) ──
_export_best_code() {
    local paper_name="$1"
    local out_root="$2"
    local config_path="${DATA_DIR}/papers/${paper_name}/config.yaml"
    local export_dir="${out_root}/${paper_name}"

    echo ""
    echo "[Export] Saving best code for ${paper_name}..."

    local repo_path
    repo_path=$(python3 - "${config_path}" <<'PYEOF'
import yaml, sys
with open(sys.argv[1]) as f:
    c = yaml.safe_load(f)
print((c.get("repo_path") or "").strip())
PYEOF
) || true

    if [ -z "${repo_path}" ] || [ ! -d "${repo_path}" ]; then
        echo "[Export] Invalid or missing repo_path in ${config_path} — skipping export."
        return 0
    fi

    # Checkout _best if tag exists
    local tag_ok
    tag_ok=$(git -C "${repo_path}" rev-parse --verify _best >/dev/null 2>&1 && echo YES || echo NO)

    if [ "${tag_ok}" = "YES" ]; then
        git -C "${repo_path}" checkout _best --quiet 2>/dev/null || true
        echo "[Export] Checked out _best in ${repo_path}"
    else
        echo "[Export] WARNING: _best tag not found — exporting current HEAD"
    fi

    # Parse best summary from scores.jsonl
    local scores_path="${DATA_DIR}/papers/${paper_name}/runs/latest/results/scores.jsonl"
    local best_summary="n/a"
    if [ -f "${scores_path}" ]; then
        best_summary=$(python3 - "${scores_path}" "${config_path}" <<'PYEOF'
import json, sys

import yaml

lines = [l.strip() for l in open(sys.argv[1]) if l.strip()]
records = [json.loads(l) for l in lines]
ok = [r for r in records if r.get("status") == "success" and r.get("primary_metric") is not None]
if not ok:
    print("n/a")
    sys.exit(0)
bl = next((r for r in records if r.get("idea_id") == "baseline"), None)
if bl:
    with open(sys.argv[2]) as f:
        cfg = yaml.safe_load(f) or {}
    lower_better = bl.get("lower_is_better")
    if isinstance(lower_better, str):
        lower_better = lower_better.strip().lower() == "true"
    elif lower_better is None:
        lower_better = str(cfg.get("metric_direction") or "higher").strip().lower() == "lower"
    best = min(ok, key=lambda r: r["primary_metric"]) if lower_better \
           else max(ok, key=lambda r: r["primary_metric"])
    raw_delta = bl["primary_metric"] - best["primary_metric"] if lower_better \
                else best["primary_metric"] - bl["primary_metric"]
    if bl["primary_metric"]:
        delta = raw_delta / abs(bl["primary_metric"]) * 100
        print(f"{best.get('idea_title','?')} ({delta:+.2f}%)")
    else:
        print(f"{best.get('idea_title','?')} ({raw_delta:+.4g})")
else:
    print(ok[-1].get("idea_title", "n/a"))
PYEOF
        ) || true
    fi

    rm -rf "${export_dir}"
    if cp -a "${repo_path}" "${export_dir}" 2>/dev/null; then
        echo "[Export] ✓ copied repo → ${export_dir}"
    else
        echo "[Export]   copy failed (non-fatal)"
    fi

    local diff_out="${export_dir}/final_patch.diff"
    git -C "${repo_path}" diff _baseline _best -- 2>/dev/null > "${diff_out}" || true
    if [ -s "${diff_out}" ]; then
        echo "[Export] ✓ patch diff  → ${diff_out}"
    fi

    echo "[Export] Done. Best: ${best_summary}"
}

# ── Parse arguments ────────────────────────────────────────────────────────
PAPER_NAME=""
REPO=""
DEVICES="0,1"
API_KEY=""
PAPER_DIR=""
TARGET_FILE=""
SKIP_ONBOARD=false
FORCE_ONBOARD=false
SKIP_RESEARCH=false
INTERACTIVE=false
SKIP_EXPORT=false
EXPORT_ON_FAILURE=false
DRY_RUN=false
REVIEW_IDEAS=false
IDEAS_FILE=""
MAX_ITER=""
TARGET_PCT=""
MAX_DEBUG=""
MAX_DEBUG_MIN=""
RESEARCH_TIMEOUT=""
MAX_TOTAL_MINUTES=""
PRIORS_DIR=""
INPUT_SNAPSHOT_DIR=""

# First positional arg is paper_name (only if it doesn't look like a flag).
# Note: must reject both --* (long flags) and -* (short flags like -i).
if [ -n "${1:-}" ] && [[ "${1}" != -* ]]; then
    PAPER_NAME="$1"
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)        REPO="$2";        shift 2 ;;
        --devices)     DEVICES="$2";     shift 2 ;;
        --api-key)     API_KEY="$2";     shift 2 ;;
        --paper-dir)   PAPER_DIR="$2";   shift 2 ;;
        --target)      TARGET_FILE="$2"; shift 2 ;;
        --max-iter)    MAX_ITER="$2";    shift 2 ;;
        --target-pct)    TARGET_PCT="$2";    shift 2 ;;
        --max-debug)     MAX_DEBUG="$2";     shift 2 ;;
        --max-debug-min) MAX_DEBUG_MIN="$2"; shift 2 ;;
        --research-timeout) RESEARCH_TIMEOUT="$2"; shift 2 ;;
        --max-total-minutes) MAX_TOTAL_MINUTES="$2"; shift 2 ;;
        --priors-dir)    PRIORS_DIR="$2";    shift 2 ;;
        --review-ideas)  REVIEW_IDEAS=true;  shift ;;
        --ideas-file)    IDEAS_FILE="$2";    shift 2 ;;
        --skip-onboard)  SKIP_ONBOARD=true;  shift ;;
        --force-onboard) FORCE_ONBOARD=true; shift ;;
        --skip-research) SKIP_RESEARCH=true; shift ;;
        --skip-export)   SKIP_EXPORT=true;   shift ;;
        --export-on-failure) EXPORT_ON_FAILURE=true; shift ;;
        --dry-run)       DRY_RUN=true;       shift ;;
        -i|--interactive) INTERACTIVE=true;  shift ;;
        *)
            # Catch a paper_name that appears AFTER a flag, e.g. `autosota -i savvy …`.
            # The pre-loop "first positional" check rejects anything starting with `-`,
            # so a paper name following short flags lands here.
            if [[ "$1" != -* ]] && [ -z "${PAPER_NAME}" ]; then
                PAPER_NAME="$1"
                shift
            else
                echo "[ERROR] Unknown argument: $1"
                echo ""
                echo "Usage: bash run.sh [paper_name] [options]"
                exit 1
            fi
            ;;
    esac
done

# ── Auto-detect paper-dir ──────────────────────────────────────────────────
if [ -z "${PAPER_DIR}" ] && [ -d "${WORKSPACE_ROOT}/paper" ]; then
    PAPER_DIR="${WORKSPACE_ROOT}/paper"
fi

# ── Auto-detect target.md ──────────────────────────────────────────────────
if [ -z "${TARGET_FILE}" ] && [ -n "${PAPER_DIR}" ] && [ -f "${PAPER_DIR}/target.md" ]; then
    TARGET_FILE="${PAPER_DIR}/target.md"
fi

# ── Auto-detect priors directory ──────────────────────────────────────────
if [ -z "${PRIORS_DIR}" ] && [ -n "${PAPER_DIR}" ] && [ -d "${PAPER_DIR}/priors" ]; then
    PRIORS_DIR="${PAPER_DIR}/priors"
fi

# ── Auto-infer paper_name from target.md ──────────────────────────────────
if [ -z "${PAPER_NAME}" ]; then
    if [ -n "${TARGET_FILE}" ] && [ -f "${TARGET_FILE}" ]; then
        PAPER_NAME=$(python3 - "${TARGET_FILE}" <<'PYEOF'
import sys, re

text = open(sys.argv[1], encoding="utf-8").read()

title = ""
for pattern in [
    r'\*\*论文\*\*[：:]\s*(.+)',
    r'\*\*Paper\*\*[：:]\s*(.+)',
    r'^#\s+(.+)',
]:
    m = re.search(pattern, text, re.MULTILINE | re.IGNORECASE)
    if m:
        title = m.group(1).strip()
        break

if not title:
    for line in text.splitlines():
        line = line.strip().lstrip('#').strip()
        if line:
            title = line
            break

title = title.split(':')[0].strip()
slug = re.sub(r'[^a-z0-9]+', '-', title.lower()).strip('-')
slug = re.sub(r'-+', '-', slug)[:30].rstrip('-')
print(slug or "paper")
PYEOF
)
        echo "[Setup] Paper name inferred from target.md: ${PAPER_NAME}"
    else
        EXISTING=$(ls "${DATA_DIR}/papers/" 2>/dev/null | head -1)
        if [ -n "${EXISTING}" ]; then
            PAPER_NAME="${EXISTING}"
            echo "[Setup] Paper name inferred from existing config: ${PAPER_NAME}"
        else
            echo "[ERROR] Cannot determine paper name."
            echo "        Either provide it as the first argument, or create paper/target.md."
            echo ""
            echo "Usage: bash run.sh [paper_name] [options]"
            exit 1
        fi
    fi
fi

CONFIG_FILE="${DATA_DIR}/papers/${PAPER_NAME}/config.yaml"

if [ ! -f "${CONFIG_FILE}" ] && [ "${SKIP_ONBOARD}" = true ]; then
    echo "[ERROR] --skip-onboard specified but ${CONFIG_FILE} does not exist."
    exit 1
fi

# ── Setup virtual environment ──────────────────────────────────────────────
if [ ! -f "${VENV_DIR}/bin/python" ]; then
    if ! command -v python3 >/dev/null 2>&1; then
        echo "[ERROR] python3 not found. Install Python 3.10+ first (e.g. sudo apt install python3-venv)." >&2
        exit 1
    fi
    echo "[Setup] Creating Python venv at ${VENV_DIR}..."
    mkdir -p "$(dirname "${VENV_DIR}")"
    python3 -m venv "${VENV_DIR}"
    PIP_ARGS=()
    [ -n "${PIP_INDEX_URL:-}" ] && PIP_ARGS+=(--index-url "${PIP_INDEX_URL}")
    "${VENV_DIR}/bin/pip" install --upgrade pip -q "${PIP_ARGS[@]}"
    "${VENV_DIR}/bin/pip" install pyyaml openai matplotlib -q "${PIP_ARGS[@]}"
fi

source "${VENV_DIR}/bin/activate"

# ── Load model credentials from config.yaml ────────────────────────────────
# autosota-codex supports splitting code optimization (Codex) and deep research
# 拆到不同的账号 / 提供商。配置优先级：
#   1) CLI --api-key（仅作为 Codex 的 key 兼容旧行为）
#   2) 各自专用字段（codex_api_key / research_api_key / research_base_url）
#   3) 共享 fallback：openrouter_api_key（旧版字段）
#
# 解析后的值会以环境变量形式下传给子进程：
#   CODEX_API_KEY / CODEX_MODEL / CODEX_*                    → codex CLI shim
#   RESEARCH_API_KEY / RESEARCH_BASE_URL / RESEARCH_MODEL     → deep_research.py
#   OPENROUTER_API_KEY                                        → 旧脚本 / 兼容
_read_cfg_field() {
    # Print the trimmed scalar value of a top-level YAML field, or empty.
    local field="$1"
    [ -z "${ROOT_CONFIG}" ] && { echo ""; return; }
    python3 - "${ROOT_CONFIG}" "${field}" <<'PYEOF'
import sys, yaml
with open(sys.argv[1]) as f:
    c = yaml.safe_load(f) or {}
v = c.get(sys.argv[2])
print("" if v is None else str(v).strip())
PYEOF
}

OPENROUTER_KEY_CFG=$(_read_cfg_field openrouter_api_key)
CODEX_API_KEY_CFG=$(_read_cfg_field codex_api_key)
CODEX_MODEL_CFG=$(_read_cfg_field codex_model)
CODEX_SANDBOX_CFG=$(_read_cfg_field codex_sandbox)
CODEX_APPROVAL_CFG=$(_read_cfg_field codex_approval)
CODEX_CLI_ARGS_CFG=$(_read_cfg_field codex_cli_args)
CLAUDE_MODEL_CFG=$(_read_cfg_field claude_model)
RESEARCH_API_KEY_CFG=$(_read_cfg_field research_api_key)
RESEARCH_BASE_URL_CFG=$(_read_cfg_field research_base_url)
RESEARCH_MODEL_CFG=$(_read_cfg_field research_model)

# Resolve effective Codex settings. CLI --api-key wins for Codex only.
EFFECTIVE_CODEX_KEY="${API_KEY:-${CODEX_API_KEY_CFG}}"
EFFECTIVE_CODEX_MODEL="${CODEX_MODEL_CFG:-${CLAUDE_MODEL_CFG:-gpt-5.5}}"
EFFECTIVE_CODEX_SANDBOX="${CODEX_SANDBOX_CFG:-danger-full-access}"
EFFECTIVE_CODEX_APPROVAL="${CODEX_APPROVAL_CFG:-never}"

# Resolve effective Research key/base (CLI --api-key does NOT override research,
# so users can put a separate cheaper key in config.yaml).
EFFECTIVE_RESEARCH_KEY="${RESEARCH_API_KEY_CFG:-${OPENROUTER_KEY_CFG}}"
EFFECTIVE_RESEARCH_BASE="${RESEARCH_BASE_URL_CFG:-https://openrouter.ai/api/v1}"

# Export for the Codex-backed claude compatibility shim.
if [ -n "${EFFECTIVE_CODEX_KEY}" ]; then
    export CODEX_API_KEY="${EFFECTIVE_CODEX_KEY}"
fi
export CODEX_MODEL="${EFFECTIVE_CODEX_MODEL}"
export CODEX_DEFAULT_MODEL="${EFFECTIVE_CODEX_MODEL}"
export CODEX_SANDBOX="${EFFECTIVE_CODEX_SANDBOX}"
export CODEX_APPROVAL="${EFFECTIVE_CODEX_APPROVAL}"
if [ -n "${CODEX_CLI_ARGS_CFG}" ]; then
    export CODEX_CLI_ARGS="${CODEX_CLI_ARGS_CFG}"
fi
if [ -n "${AUTOSOTA_CODEX_SHIM_DIR:-}" ] && [ -d "${AUTOSOTA_CODEX_SHIM_DIR}" ]; then
    export PATH="${AUTOSOTA_CODEX_SHIM_DIR}:${PATH}"
fi
# Prevent inherited Claude variables from accidentally driving a real Claude CLI
# if the compatibility shim is not first on PATH.
unset ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_API_KEY 2>/dev/null || true

# Export for deep_research.py (and any other OpenAI-compatible callers).
if [ -n "${EFFECTIVE_RESEARCH_KEY}" ]; then
    export RESEARCH_API_KEY="${EFFECTIVE_RESEARCH_KEY}"
    export RESEARCH_BASE_URL="${EFFECTIVE_RESEARCH_BASE}"
fi
if [ -n "${RESEARCH_MODEL_CFG}" ]; then
    export RESEARCH_MODEL="${RESEARCH_MODEL_CFG}"
fi

# Back-compat: keep OPENROUTER_API_KEY populated so legacy callers / per-paper
# config fallbacks still work. Prefer the shared key, then fall back to the
# claude / research key whichever exists.
if [ -n "${OPENROUTER_KEY_CFG}" ]; then
    export OPENROUTER_API_KEY="${OPENROUTER_KEY_CFG}"
elif [ -n "${EFFECTIVE_RESEARCH_KEY}" ]; then
    export OPENROUTER_API_KEY="${EFFECTIVE_RESEARCH_KEY}"
fi

# Used by onboard.py / generate_ideas.py / run.py to add `--model` to the
# legacy `claude` command. The shim interprets this as a Codex model.
export CLAUDE_MODEL="${EFFECTIVE_CODEX_MODEL}"

# ── Setup log directories (BEFORE provider env exports so [Setup] lines log) ──
LOGS_ROOT="${WORKSPACE_ROOT}/logs"
LOGS_SOTA="${LOGS_ROOT}/sota"
LOGS_OPTIMIZER_DTL="${LOGS_ROOT}/optimizer_detail"
OPTIMIZED_CODE_DIR="${WORKSPACE_ROOT}/optimized_code"

mkdir -p "${LOGS_SOTA}" "${LOGS_OPTIMIZER_DTL}" "${OPTIMIZED_CODE_DIR}"

SOTA_LOG="${LOGS_SOTA}/${PAPER_NAME}.log"
ONBOARD_LOG="${LOGS_OPTIMIZER_DTL}/${PAPER_NAME}_onboard.log"
OPTIMIZE_LOG="${LOGS_OPTIMIZER_DTL}/${PAPER_NAME}.log"

# Tee all subsequent output to sota log (still visible in terminal).
# IMPORTANT: must come before codex_env below — otherwise
# its `[Setup] Applied...` echoes only hit the
# terminal and never make it into logs/sota/<paper>.log, which makes it look
# like the env overrides silently failed.
exec > >(tee -a "${SOTA_LOG}") 2>&1

# ── Pass-through env vars from config.yaml's `codex_env:` map ──────────────
# Lets users declare provider-specific knobs (for example OPENAI_BASE_URL)
# inside the workspace
# config without polluting ~/.bashrc. Each entry is exported verbatim before
# launching Codex. This way switching workspaces automatically toggles the
# right env vars on/off.
#
# Precedence: config.yaml wins over the inherited shell environment, so the
# declared "this run uses this provider" intent is authoritative.
if [ -n "${ROOT_CONFIG}" ]; then
    _CODEX_ENV_EXPORTS=$(python3 - "${ROOT_CONFIG}" <<'PYEOF'
import shlex, sys, yaml
with open(sys.argv[1]) as f:
    c = yaml.safe_load(f) or {}
env_map = c.get("codex_env")
if not isinstance(env_map, dict):
    sys.exit(0)
for k, v in env_map.items():
    if not isinstance(k, str):
        continue
    # Allow letters/digits/underscore; reject anything else as a safety net.
    if not k.replace("_", "").isalnum() or not k:
        continue
    if v is None:
        continue
    val = str(v)
    print(f"export {k}={shlex.quote(val)}")
PYEOF
)
    if [ -n "${_CODEX_ENV_EXPORTS}" ]; then
        eval "${_CODEX_ENV_EXPORTS}"
        # Echo what got applied so the run header makes the override visible.
        echo "[Setup] Applied codex_env from config.yaml:"
        # shellcheck disable=SC2001
        echo "${_CODEX_ENV_EXPORTS}" | sed 's/^/    /'
    fi
fi

# API_KEY (passed to subcommands as --api-key) keeps its old meaning: the
# Codex key. If the user only set codex_api_key in config.yaml, propagate it
# here so onboard.py still bakes a usable key into the per-paper config.yaml.
if [ -z "${API_KEY}" ]; then
    API_KEY="${EFFECTIVE_CODEX_KEY}"
fi

echo "═══════════════════════════════════════════════════════════════"
echo "  auto-pipeline  |  $(date)"
echo "  Paper   : ${PAPER_NAME}"
echo "  Workspace: ${WORKSPACE_ROOT}"
echo "  Data    : ${DATA_DIR}"
[ -n "${REPO}" ] && echo "  Repo    : ${REPO}"
echo "  Devices : ${DEVICES}"
[ -n "${TARGET_FILE}" ] && echo "  Target  : ${TARGET_FILE}"
[ -n "${PAPER_DIR}" ]   && echo "  PaperDir: ${PAPER_DIR}"
[ -n "${PRIORS_DIR}" ]  && echo "  Priors  : ${PRIORS_DIR}"
echo "  Workdir : ${OPTIMIZER_DIR}"
echo "  SotaLog : ${SOTA_LOG}"
echo "  CodexLog: ${OPTIMIZE_LOG}"
echo "═══════════════════════════════════════════════════════════════"

cd "${OPTIMIZER_DIR}"

# ── Step 1: Onboard (discover / update config.yaml) ───────────────────────
if [ "${SKIP_ONBOARD}" = false ]; then
    if [ -f "${CONFIG_FILE}" ] && [ "${FORCE_ONBOARD}" = false ]; then
        echo "[Onboard] config.yaml already exists — skipping onboard."
        echo "          Use --force-onboard to re-run discovery."
    else
        echo "[Onboard] Running auto-discovery..."
        echo "[Onboard] Codex log: ${ONBOARD_LOG}"
        ONBOARD_ARGS=("${PAPER_NAME}")
        [ -n "${REPO}" ]        && ONBOARD_ARGS+=(--repo "${REPO}")
        [ -n "${API_KEY}" ]     && ONBOARD_ARGS+=(--api-key "${API_KEY}")
        [ -n "${PAPER_DIR}" ]   && ONBOARD_ARGS+=(--paper-dir "${PAPER_DIR}")
        [ -n "${TARGET_FILE}" ] && ONBOARD_ARGS+=(--target "${TARGET_FILE}")
        [ "${FORCE_ONBOARD}" = true ] && ONBOARD_ARGS+=(--force)
        [ "${DRY_RUN}" = true ] && ONBOARD_ARGS+=(--dry-run)
        ONBOARD_ARGS+=(--claude-log-file "${ONBOARD_LOG}")

        bash onboard.sh "${ONBOARD_ARGS[@]}"

        if [ "${DRY_RUN}" = true ]; then
            echo "[DRY RUN] Onboard complete. Exiting."
            exit 0
        fi

        if [ ! -f "${CONFIG_FILE}" ]; then
            echo "[ERROR] Onboard did not produce config.yaml. Aborting."
            exit 1
        fi
    fi
fi

# ── Step 2: Patch GPU selection in config.yaml ────────────────────────────
python - "${CONFIG_FILE}" "${DEVICES}" <<'PYEOF'
import shlex
import sys

import yaml

path, devices = sys.argv[1:3]
with open(path) as f:
    c = yaml.safe_load(f)

c["gpu_devices"] = devices
eval_command = c.get("eval_command")
if isinstance(eval_command, str) and "--gpu-ids" in eval_command:
    parts = shlex.split(eval_command)
    updated = []
    i = 0
    changed = False
    while i < len(parts):
        part = parts[i]
        if part == "--gpu-ids" and i + 1 < len(parts):
            updated.extend([part, devices])
            i += 2
            changed = True
            continue
        if part.startswith("--gpu-ids="):
            updated.append(f"--gpu-ids={devices}")
            i += 1
            changed = True
            continue
        updated.append(part)
        i += 1
    if changed:
        c["eval_command"] = shlex.join(updated)

with open(path, "w") as f:
    yaml.dump(c, f, default_flow_style=False, allow_unicode=True)
print(f"[Setup] gpu_devices set to: {devices}")
if isinstance(eval_command, str) and "--gpu-ids" in eval_command:
    print(f"[Setup] eval_command --gpu-ids set to: {devices}")
PYEOF

# ── Step 3: Snapshot user-edited inputs before each run ───────────────────
INPUT_SNAPSHOT_DIR="${DATA_DIR}/papers/${PAPER_NAME}/input_snapshots/input_$(date +%Y%m%d_%H%M%S)_$$"
python - "${CONFIG_FILE}" "${TARGET_FILE:-}" "${TARGET_PCT:-}" "${REPO:-}" "${WORKSPACE_ROOT}" "${PRIORS_DIR:-}" "${INPUT_SNAPSHOT_DIR}" <<'PYEOF'
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

import yaml

config_path, target_path_arg, cli_target_pct, repo_arg, workspace_root, priors_dir_arg, snapshot_dir_arg = sys.argv[1:8]
workspace = Path(workspace_root).resolve()
snapshot_dir = Path(snapshot_dir_arg).resolve()
priors_snapshot_dir = snapshot_dir / "priors"
snapshot_dir.mkdir(parents=True, exist_ok=True)
priors_snapshot_dir.mkdir(parents=True, exist_ok=True)

with open(config_path, encoding="utf-8") as f:
    cfg = yaml.safe_load(f) or {}

changed = False
manifest = {
    "created_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "config_path": str(Path(config_path).resolve()),
    "workspace_root": str(workspace),
    "cli_target_pct": cli_target_pct or None,
    "repo_arg": repo_arg or None,
    "target": None,
    "priors": [],
    "parsed_target": None,
}

def save_config():
    with open(config_path, "w", encoding="utf-8") as f:
        yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True)

def resolve_workspace_path(value):
    if not value:
        return None
    path = Path(os.path.expanduser(value))
    if not path.is_absolute():
        path = workspace / path
    return path.resolve()

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def file_record(src, dst=None):
    src = Path(src)
    rec = {
        "source": str(src),
        "source_size": src.stat().st_size,
        "source_mtime": int(src.stat().st_mtime),
        "source_sha256": sha256_file(src),
    }
    if dst is not None and Path(dst).exists():
        dst = Path(dst)
        rec.update({
            "snapshot": str(dst),
            "snapshot_size": dst.stat().st_size,
            "snapshot_sha256": sha256_file(dst),
        })
    return rec

def copy_if_file(src, dst):
    if src is None or not Path(src).is_file():
        return None
    dst = Path(dst)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    return file_record(src, dst)

def valid_git_root(path):
    try:
        res = subprocess.run(
            ["git", "-C", path, "rev-parse", "--show-toplevel"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except Exception:
        return ""
    if res.returncode != 0:
        return ""
    return res.stdout.strip()

def as_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None

def front_matter(text):
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}
    for idx in range(1, len(lines)):
        if lines[idx].strip() == "---":
            data = yaml.safe_load("\n".join(lines[1:idx])) or {}
            return data if isinstance(data, dict) else {}
    return {}

def metric_direction_lower():
    direction = str(cfg.get("metric_direction") or "lower").lower()
    lower_is_better = not direction.startswith("higher")
    if "lower_is_better" in cfg:
        lower_is_better = bool(cfg.get("lower_is_better"))
    return lower_is_better

def plausible_values(values, baseline, lower_is_better):
    if baseline is None or baseline == 0:
        return values
    if lower_is_better:
        preferred = [v for v in values if 0 <= v <= abs(baseline) * 1.5]
    else:
        preferred = [v for v in values if v >= abs(baseline) * 0.5]
    return preferred or values

def extract_target(text):
    primary = str(cfg.get("primary_metric") or "").strip()
    baselines = cfg.get("baseline_metrics") or {}
    baseline = as_float(baselines.get(primary)) if primary else None
    lower_is_better = metric_direction_lower()
    fm = front_matter(text)

    pct_override = as_float(fm.get("target_improvement_pct")) if fm else None
    fm_target_value = as_float(fm.get("target_value")) if fm else None
    candidates = []

    def add(value, line, reason, score):
        if value is not None:
            candidates.append({
                "value": float(value),
                "line": line.strip(),
                "reason": reason,
                "score": score,
            })

    if fm_target_value is not None:
        add(fm_target_value, "target_value", "front_matter", 100)

    number_re = re.compile(r"(?<![A-Za-z0-9_.-])([0-9]+(?:\.[0-9]+)?)(?![A-Za-z0-9_.-])")
    explicit_re = re.compile(r"(?:target_value|目标值|target)\s*[:：=为]?\s*(?:<=|≤|>=|≥)?\s*([0-9]+(?:\.[0-9]+)?)", re.I)
    target_hint_re = re.compile(r"(目标值|目标|target|<=|≤|>=|≥|或更低|or lower|or less|至少|at least)", re.I)

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        explicit = explicit_re.search(line)
        if explicit:
            add(float(explicit.group(1)), line, "explicit_target_line", 90)
            continue
        if not target_hint_re.search(line):
            continue

        search_line = line
        score = 70
        if primary and primary.lower() in line.lower():
            idx = line.lower().find(primary.lower())
            search_line = line[idx:idx + 120]
            score = 85
        values = [float(m.group(1)) for m in number_re.finditer(search_line)]
        values = plausible_values(values, baseline, lower_is_better)
        if len(values) == 1:
            add(values[0], line, "target_hint_line", score)

    if not candidates:
        m = re.search(r"(?:<=|≤)\s*([0-9]+(?:\.[0-9]+)?)", text)
        if m:
            add(float(m.group(1)), m.group(0), "threshold_operator", 60)

    if pct_override is not None:
        return {
            "primary_metric": primary or None,
            "baseline": baseline,
            "lower_is_better": lower_is_better,
            "target_value": fm_target_value,
            "target_improvement_pct": pct_override,
            "source_line": "target_improvement_pct",
            "source": "front_matter",
        }

    if not candidates:
        return None

    best_score = max(c["score"] for c in candidates)
    best = [c for c in candidates if c["score"] == best_score]
    unique_values = {round(c["value"], 10) for c in best}
    if len(unique_values) > 1:
        details = "; ".join(f"{c['value']:g} from {c['line']}" for c in best[:5])
        raise SystemExit(
            "[Inputs] ERROR: ambiguous target.md numeric target. "
            f"Use an explicit line like '{primary or 'metric'} <= 0.1234'. Candidates: {details}"
        )

    value = best[0]["value"]
    pct = None
    if baseline not in (None, 0):
        if lower_is_better:
            pct = (baseline - value) / abs(baseline) * 100.0
        else:
            pct = (value - baseline) / abs(baseline) * 100.0

    return {
        "primary_metric": primary or None,
        "baseline": baseline,
        "lower_is_better": lower_is_better,
        "target_value": value,
        "target_improvement_pct": pct,
        "source_line": best[0]["line"],
        "source": best[0]["reason"],
    }

target_path = resolve_workspace_path(target_path_arg)
target_snapshot = snapshot_dir / "target.md"
target_text = ""
if target_path and target_path.is_file():
    manifest["target"] = copy_if_file(target_path, target_snapshot)
    target_text = target_snapshot.read_text(encoding="utf-8")

priors_dir = resolve_workspace_path(priors_dir_arg)
for name in ("references.md", "ideas.md", "directions.md"):
    src = priors_dir / name if priors_dir and priors_dir.is_dir() else None
    rec = copy_if_file(src, priors_snapshot_dir / name)
    if rec:
        rec["name"] = name
        manifest["priors"].append(rec)

if target_text:
    directions_path = priors_snapshot_dir / "directions.md"
    existing_directions = directions_path.read_text(encoding="utf-8") if directions_path.exists() else ""
    target_block = (
        "# Current Target\n\n"
        "This is the current user-edited paper/target.md for this run.\n\n"
        "```markdown\n"
        f"{target_text.rstrip()}\n"
        "```\n\n"
        "---\n\n"
    )
    directions_path.write_text(target_block + existing_directions, encoding="utf-8")

manifest["priors_snapshot_dir"] = str(priors_snapshot_dir)
manifest["snapshot_files"] = []
for path in sorted(snapshot_dir.rglob("*")):
    if path.is_file() and path.name != "manifest.json":
        manifest["snapshot_files"].append({
            "path": str(path),
            "size": path.stat().st_size,
            "sha256": sha256_file(path),
        })

if repo_arg and not re.match(r"^(https?://|git@)", repo_arg):
    repo_path = resolve_workspace_path(repo_arg)
    repo_root = valid_git_root(str(repo_path))
    if repo_root:
        if cfg.get("repo_path") != repo_root:
            cfg["repo_path"] = repo_root
            changed = True
        print(f"[Setup] repo_path set from --repo: {repo_root}")
    else:
        current = cfg.get("repo_path") or ""
        if current:
            print(f"[Setup] --repo ignored because it is not a git repo: {repo_path}")
            print(f"[Setup] keeping existing repo_path: {current}")
        else:
            print(f"[Setup] WARNING: --repo is not a git repo and repo_path is unset: {repo_path}")

cfg["input_snapshot_dir"] = str(snapshot_dir)
changed = True

if cli_target_pct:
    print(f"[Inputs] target from CLI --target-pct: {cli_target_pct}")
elif manifest["target"] is not None:
    parsed = extract_target(target_text)
    if parsed is None:
        raise SystemExit(
            "[Inputs] ERROR: target.md exists but no unambiguous numeric target was found. "
            "Add an explicit line such as 'ETTh1_MSE <= 0.1440' or YAML front matter 'target_value: 0.1440'."
        )
    manifest["parsed_target"] = parsed
    if parsed["target_value"] is not None:
        cfg["target_value"] = round(parsed["target_value"], 10)
        changed = True
    if parsed["target_improvement_pct"] is not None:
        cfg["target_improvement_pct"] = round(parsed["target_improvement_pct"], 6)
        changed = True
    if manifest["target"]:
        cfg["target_source"] = str(target_path)
        cfg["target_source_sha256"] = manifest["target"]["source_sha256"]
        changed = True

    metric = parsed["primary_metric"] or "primary_metric"
    if parsed["target_value"] is not None:
        op = "<=" if parsed["lower_is_better"] else ">="
        print(f"[Inputs] target.md: {metric} {op} {parsed['target_value']:g}")
    if parsed["target_improvement_pct"] is not None:
        print(f"[Inputs] target_improvement_pct set to: {parsed['target_improvement_pct']:.2f}")
    else:
        print("[Inputs] target_improvement_pct unchanged because baseline_metrics is missing or zero")
    if parsed.get("source_line"):
        print(f"[Inputs] target source line: {parsed['source_line']}")
else:
    print("[Inputs] target.md not found; keeping existing target fields in config.yaml")

manifest["effective_config"] = {
    "repo_path": cfg.get("repo_path"),
    "primary_metric": cfg.get("primary_metric"),
    "metric_direction": cfg.get("metric_direction"),
    "target_value": cfg.get("target_value"),
    "target_improvement_pct": cfg.get("target_improvement_pct"),
}
with open(snapshot_dir / "manifest.json", "w", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2, sort_keys=True)

if changed:
    save_config()

print(f"[Inputs] snapshot: {snapshot_dir}")
print(f"[Inputs] priors snapshot: {priors_snapshot_dir}")
PYEOF

if [ -d "${INPUT_SNAPSHOT_DIR}/priors" ]; then
    PRIORS_DIR="${INPUT_SNAPSHOT_DIR}/priors"
    export AUTOSOTA_INPUT_SNAPSHOT_DIR="${INPUT_SNAPSHOT_DIR}"
fi

# ── Step 4: Optimize ──────────────────────────────────────────────────────
OPTIMIZE_ARGS=("${PAPER_NAME}")
[ "${SKIP_RESEARCH}" = true ]  && OPTIMIZE_ARGS+=(--skip-research)
[ "${DRY_RUN}" = true ]        && OPTIMIZE_ARGS+=(--dry-run)
[ -n "${API_KEY}" ]            && OPTIMIZE_ARGS+=(--api-key "${API_KEY}")
[ -n "${MAX_ITER}" ]           && OPTIMIZE_ARGS+=(--max-iter "${MAX_ITER}")
[ -n "${TARGET_PCT}" ]         && OPTIMIZE_ARGS+=(--target-pct "${TARGET_PCT}")
[ -n "${MAX_DEBUG}" ]          && OPTIMIZE_ARGS+=(--max-debug "${MAX_DEBUG}")
[ -n "${MAX_DEBUG_MIN}" ]      && OPTIMIZE_ARGS+=(--max-debug-min "${MAX_DEBUG_MIN}")
[ -n "${RESEARCH_TIMEOUT}" ]   && OPTIMIZE_ARGS+=(--research-timeout "${RESEARCH_TIMEOUT}")
[ -n "${MAX_TOTAL_MINUTES}" ]  && OPTIMIZE_ARGS+=(--max-total-minutes "${MAX_TOTAL_MINUTES}")
[ -n "${PRIORS_DIR}" ]         && OPTIMIZE_ARGS+=(--priors-dir "${PRIORS_DIR}")
[ "${REVIEW_IDEAS}" = true ]   && OPTIMIZE_ARGS+=(--review-ideas)
[ -n "${IDEAS_FILE}" ]         && OPTIMIZE_ARGS+=(--ideas-file "${IDEAS_FILE}")
[ "${INTERACTIVE}" = true ]    && OPTIMIZE_ARGS+=(--interactive)
OPTIMIZE_ARGS+=(--claude-log-file "${OPTIMIZE_LOG}")

echo ""
echo "[Optimize] Starting optimization for ${PAPER_NAME}..."
echo "[Optimize] Codex log: ${OPTIMIZE_LOG}  (tail -f to follow)"
# set -e would abort before OPTIMIZE_EXIT=$? on failure; capture exit code explicitly.
set +e
bash optimize.sh "${OPTIMIZE_ARGS[@]}"
OPTIMIZE_EXIT=$?
set -e

if [ -n "${INPUT_SNAPSHOT_DIR}" ] && [ -d "${INPUT_SNAPSHOT_DIR}" ]; then
    LATEST_RUN=$(python - "${DATA_DIR}/papers/${PAPER_NAME}/runs/latest" <<'PYEOF'
import os
import sys
path = sys.argv[1]
print(os.path.realpath(path) if os.path.exists(path) else "")
PYEOF
)
    if [ -n "${LATEST_RUN}" ] && [ -d "${LATEST_RUN}" ]; then
        mkdir -p "${LATEST_RUN}/inputs"
        cp -a "${INPUT_SNAPSHOT_DIR}/." "${LATEST_RUN}/inputs/"
        echo "[Inputs] snapshot copied to: ${LATEST_RUN}/inputs"
    fi
fi

# ── Step 5: Export best code ──────────────────────────────────────────────
# 约定：optimize（run.py）退出码非 0 时默认不导出，避免在失败/超时后误覆盖快照；
#       需要「仍保存当前仓库状态」时用 --export-on-failure。
if [ "${DRY_RUN}" = false ] && [ "${SKIP_EXPORT}" = false ]; then
    if [ "${OPTIMIZE_EXIT}" -eq 0 ] || [ "${EXPORT_ON_FAILURE}" = true ]; then
        if [ "${OPTIMIZE_EXIT}" -ne 0 ] && [ "${EXPORT_ON_FAILURE}" = true ]; then
            echo "[Export] optimize exited ${OPTIMIZE_EXIT} — exporting anyway (--export-on-failure)"
        fi
        _export_best_code "${PAPER_NAME}" "${OPTIMIZED_CODE_DIR}"
    else
        echo "[Export] Skipped: optimize exited ${OPTIMIZE_EXIT} (use --export-on-failure to export anyway)"
    fi
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Finished: ${PAPER_NAME}  |  $(date)"
echo "  Logs      : ${LOGS_ROOT}/"
echo "  Code      : ${OPTIMIZED_CODE_DIR}/${PAPER_NAME}/"
echo "  Exit code : ${OPTIMIZE_EXIT}  (from optimizer/run.py; 0 = success)"
echo "═══════════════════════════════════════════════════════════════"

exit "${OPTIMIZE_EXIT}"
