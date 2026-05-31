#!/usr/bin/env bash
# 模拟评估：秒级结束，打印与 config 中 baseline 一致的指标（可用环境变量覆盖）。
set -euo pipefail
cd "$(dirname "$0")"

MSE="${MOCK_MSE:-0.3616}"
MAE="${MOCK_MAE:-0.3650}"

echo "[mock] evaluation complete"
echo "mse_mean = ${MSE}"
echo "mae_mean = ${MAE}"
