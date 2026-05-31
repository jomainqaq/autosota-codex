# Mock 论文代码仓库（测试用）

本目录用于验证 **auto-pipeline** 的本地流程：git 提交、`run_eval.sh` 输出指标、`record_score.sh` 可写入 `scores.jsonl`。

- **评估入口**：`bash run_eval.sh`（或 `bash ./run_eval.sh`）
- **指标**：`ETTh1_MSE`、`ETTh1_MAE`（模拟数值，非真实训练）

可通过环境变量覆盖输出，便于手动模拟「改进」：

```bash
export MOCK_MSE=0.34 MOCK_MAE=0.35
bash run_eval.sh
```

首次使用前请在仓库根目录执行 `examples/setup_mock_demo.sh`，脚本会在此目录 `git init` 并做初始提交。
