#!/usr/bin/env bash
# 一键准备 mock 演示：初始化 mock 仓库 git、复制 target.md、写入 optimizer/papers/mock-demo/config.yaml
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOCK_REPO="${ROOT}/examples/mock_paper_repo"

# Workspace / data dir — respect env vars set by `autosota` CLI, otherwise
# fall back to the dev-mode layout rooted at the repo.
WORKSPACE_ROOT="${AUTOSOTA_WORKSPACE:-${ROOT}}"
if [ -n "${AUTOSOTA_DATA_DIR:-}" ]; then
    DATA_DIR="${AUTOSOTA_DATA_DIR}"
elif [ "${WORKSPACE_ROOT}" = "${ROOT}" ]; then
    DATA_DIR="${ROOT}/optimizer"   # dev mode: legacy layout
else
    DATA_DIR="${WORKSPACE_ROOT}/.autosota"
fi

PAPER_DIR="${WORKSPACE_ROOT}/paper"
CONFIG_DIR="${DATA_DIR}/papers/mock-demo"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"

echo "[setup_mock_demo] ROOT=${ROOT}"
echo "[setup_mock_demo] MOCK_REPO=${MOCK_REPO}"

mkdir -p "${PAPER_DIR}" "${CONFIG_DIR}"
cp -f "${ROOT}/examples/mock_target.md" "${PAPER_DIR}/target.md"
echo "[setup_mock_demo] Wrote ${PAPER_DIR}/target.md"

chmod +x "${MOCK_REPO}/run_eval.sh"

# 与 optimize_prompt 一致：评估侧在 repo 内使用 tools/record_score.sh
mkdir -p "${MOCK_REPO}/tools"
cp -f "${ROOT}/optimizer/scripts/record_score.sh" "${MOCK_REPO}/tools/record_score.sh"
chmod +x "${MOCK_REPO}/tools/record_score.sh"

if [[ ! -d "${MOCK_REPO}/.git" ]]; then
  git -C "${MOCK_REPO}" init
  git -C "${MOCK_REPO}" config user.email "mock@local"
  git -C "${MOCK_REPO}" config user.name "mock-demo"
fi

git -C "${MOCK_REPO}" add -A
git -C "${MOCK_REPO}" commit -m "baseline: mock repo for pipeline test" --allow-empty || true

python3 - <<PY
import yaml
from pathlib import Path

repo = Path("${MOCK_REPO}").resolve()
cfg = {
    "paper_title": "Mock Demo",
    "paper_repo_url": "",
    "repo_path": str(repo),
    "venv_path": "",
    "env_vars": "",
    "eval_command": "bash run_eval.sh",
    "eval_command_file": "run_eval.sh",
    "eval_timeout_minutes": 2,
    "gpu_devices": "0",
    "baseline_metrics": {"ETTh1_MSE": 0.3616, "ETTh1_MAE": 0.3650},
    "primary_metric": "ETTh1_MSE",
    "metric_direction": "lower",
    "metric_lower_bound": 0.0,
    "metric_upper_bound": None,
    "target_improvement_pct": 5.0,
    "max_iterations": 2,
    "max_debug_attempts": 2,
    "max_debug_minutes": 5,
    "research_timeout_minutes": 5,
    "research_model": "openai/o4-mini-deep-research",
    "openrouter_api_key": "",
    "setup_notes": (
        "Mock 仓库：仅用于流水线测试。评估脚本为 examples/mock_paper_repo/run_eval.sh。"
    ),
    "eval_output_format": (
        "The script prints lines:\n"
        '  mse_mean = <float>\n'
        '  mae_mean = <float>\n'
        "Parse ETTh1_MSE from \"mse_mean = {value}\" and ETTh1_MAE from \"mae_mean = {value}\"."
    ),
    "known_levers": (
        "- MOCK_MSE / MOCK_MAE: env vars read by run_eval.sh to simulate metric changes\n"
        "- Any file edit + git commit for record_score.sh workflow tests\n"
    ),
}

out = Path("${CONFIG_FILE}")
out.parent.mkdir(parents=True, exist_ok=True)
with open(out, "w", encoding="utf-8") as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
print(f"[setup_mock_demo] Wrote {out}")
PY

echo ""
echo "下一步（项目根目录）："
echo "  # 仅生成 master prompt，不调用 Claude API（仍会跑 onboard 补丁逻辑前的 gpu 写入等）"
echo "  bash run.sh mock-demo --skip-research --dry-run"
echo ""
echo "若根目录已有 config.yaml 且含 openrouter_api_key，研究会使用该 Key；无 Key 时请配合 --skip-research。"
echo "OpenRouter Key 也可写在 ${CONFIG_FILE} 的 openrouter_api_key 字段。"
