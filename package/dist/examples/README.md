# 示例与本地冒烟测试

## Mock 论文仓库

`examples/mock_paper_repo/` 是一个**最小可运行**的假「论文代码」目录：

- `run_eval.sh`：立即打印 `mse_mean` / `mae_mean`（与 `optimizer/papers/mock-demo/config.yaml` 中的基线一致）
- 配合 `record_score.sh` 可做 git 提交与 `scores.jsonl` 写入练习

## 一键准备

在项目根目录执行：

```bash
bash examples/setup_mock_demo.sh
```

该脚本会：

1. 将 `examples/mock_target.md` 复制为 `paper/target.md`（论文名推断为 **mock-demo**）
2. 在 `examples/mock_paper_repo` 内 `git init`（若尚未初始化）并做初始提交
3. 将 `optimizer/scripts/record_score.sh` 复制到 `examples/mock_paper_repo/tools/record_score.sh`（与 prompt 中的路径一致，便于手测）
4. 生成 `optimizer/papers/mock-demo/config.yaml`，其中 `repo_path` 为**本机绝对路径**

## 验证流水线（推荐）

```bash
bash run.sh mock-demo --skip-research --dry-run
```

将跳过深度研究，并只做 dry-run（不真正拉起长时间 Claude 优化；具体行为见 `optimizer/scripts/run.py`）。

## 真跑 Claude（检查工作区 / 工具是否正常）

前提：`which claude` 能找到 **Claude Code CLI**，且已登录（见 [Claude Code 文档](https://docs.anthropic.com/en/docs/claude-code)）。根目录 `config.yaml` 里可配置 `research_api_key` 和 `research_base_url`（深度研究会用到）；`research_base_url` 必须带 `/v1`，例如 `http://127.0.0.1:8080/v1`。仅测优化阶段时可加 `--skip-research`；`openrouter_api_key` 只保留作 legacy fallback。

**工作区说明**：编排器会把 Claude 子进程的**当前工作目录（cwd）**设为 `config.yaml` 里的 `repo_path`（例如 mock 的 `examples/mock_paper_repo`），与 prompt 里「在论文仓库里改代码」一致；若仍出现路径问题，可看终端里打印的 `CWD:` 行确认。

建议先用**短时间上限**做一次冒烟（到点会强杀子进程，可能等不到完整一轮优化）：

```bash
bash run.sh mock-demo --skip-research --max-total-minutes 15
```

- 不要加 `--dry-run`，否则会只生成 prompt、不启动 `claude`。  
- 日志：`tail -f logs/optimizer_detail/mock-demo.log`，以及本次 run 目录下 `runs/run_*/logs/claude_output.log`（或与前者为同一文件的 symlink）。  
- Mock 的 prompt 很长，首次调用可能较慢；若 15 分钟内几乎无输出，先检查网络与 CLI 登录状态。

## 单独跑模拟评估

```bash
cd examples/mock_paper_repo
bash run_eval.sh
```

模拟「指标变好」：

```bash
MOCK_MSE=0.30 MOCK_MAE=0.31 bash run_eval.sh
```
