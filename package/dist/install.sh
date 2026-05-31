#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  autosota — Python venv 安装脚本
#
#  用法：
#    bash install.sh                      # 默认把 venv 装到 ~/.autosota/venv
#    AUTOSOTA_DATA_DIR=/my/path bash install.sh
#    PIP_INDEX_URL=https://... bash install.sh   # 可选：自定义 pip 源
#
#  典型场景：
#    1. 从 git 检出：bash install.sh  → venv 在 ~/.autosota/venv
#    2. npm 安装后执行：`autosota doctor` 会在需要时自动触发 venv 创建
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# venv 位置优先级：AUTOSOTA_DATA_DIR > ~/.autosota
if [ -n "${AUTOSOTA_DATA_DIR:-}" ]; then
    DATA_DIR="${AUTOSOTA_DATA_DIR}"
else
    DATA_DIR="${HOME}/.autosota"
fi
VENV="${DATA_DIR}/venv"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step() { echo -e "\n${GREEN}━━━ $* ${NC}"; }

# ────────────────────────────────────────────────────────────
step "1/3  检查 python3"
# ────────────────────────────────────────────────────────────
if ! command -v python3 >/dev/null 2>&1; then
    die "python3 未安装。请先安装 Python 3.10+（例：sudo apt install python3 python3-venv）"
fi
PY_VER="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
info "python3 版本: ${PY_VER}"

if ! python3 -c "import sys; assert sys.version_info >= (3, 10)" 2>/dev/null; then
    warn "推荐使用 Python 3.10+；当前 ${PY_VER} 可能不兼容部分依赖"
fi

# ────────────────────────────────────────────────────────────
step "2/3  检查 codex CLI（运行时必需）"
# ────────────────────────────────────────────────────────────
if command -v codex >/dev/null 2>&1; then
    info "codex: $(codex --version 2>/dev/null | head -1 || echo present)"
else
    warn "未检测到 codex CLI。npm 全局安装 autosota-codex 后会自动安装 bundled @openai/codex。"
    warn "（先不中断安装；稍后可用 \`autosota doctor\` 复查）"
fi

if command -v nvidia-smi >/dev/null 2>&1; then
    info "nvidia-smi: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo ok)"
else
    warn "未检测到 nvidia-smi；若评测脚本无需 GPU 可忽略"
fi

# ────────────────────────────────────────────────────────────
step "3/3  创建 venv → ${VENV}"
# ────────────────────────────────────────────────────────────
mkdir -p "${DATA_DIR}"

if [ -d "${VENV}" ]; then
    warn "已存在 venv：${VENV}"
    BACKUP="${VENV}.bak_$(date +%Y%m%d_%H%M%S)"
    warn "备份为 ${BACKUP} 后重建"
    mv "${VENV}" "${BACKUP}"
fi

info "创建虚拟环境..."
python3 -m venv "${VENV}"

PIP_ARGS=()
if [ -n "${PIP_INDEX_URL:-}" ]; then
    info "使用自定义 pip 源: ${PIP_INDEX_URL}"
    PIP_ARGS+=(--index-url "${PIP_INDEX_URL}")
fi

info "升级 pip..."
"${VENV}/bin/pip" install --upgrade pip -q "${PIP_ARGS[@]}"

info "安装核心依赖..."
"${VENV}/bin/pip" install -q "${PIP_ARGS[@]}" \
    "pyyaml>=6.0" \
    "openai>=1.0" \
    "matplotlib>=3.7" \
    "httpx>=0.27"

info "验证..."
"${VENV}/bin/python" - <<'PY'
import yaml, openai, matplotlib, httpx
print(f"  pyyaml={yaml.__version__}  openai={openai.__version__}  matplotlib={matplotlib.__version__}")
print("  ✓ venv OK")
PY

# ────────────────────────────────────────────────────────────
echo -e "\n${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  安装完成！${NC}"
echo -e "  Data dir : ${DATA_DIR}"
echo -e "  venv     : ${VENV}"
echo -e ""
echo -e "  从 git 检出使用："
echo -e "    cd ${PROJECT_DIR}"
echo -e "    bash run.sh --repo /path/to/your-clone"
echo -e ""
echo -e "  全局安装使用 (需要 Node 18+)："
echo -e "    npm install -g ${PROJECT_DIR}"
echo -e "    autosota init       # 脚手架 config.yaml + paper/"
echo -e "    autosota doctor     # 环境自检"
echo -e "    autosota --repo /path/to/your-clone"
echo -e "${GREEN}════════════════════════════════════════${NC}\n"
