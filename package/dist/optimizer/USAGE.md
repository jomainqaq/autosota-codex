# paper-optimizer 使用说明

> 适用：本仓库 `optimizer/` 目录下的本地工作流（无 Docker）。

---

## 目录结构

```
paper-optimizer/
├── optimize.sh          ← 主入口（优化流程）
├── onboard.sh           ← 新 paper 接入入口
├── papers/
│   └── <paper-name>/
│       ├── config.yaml              ← 论文配置（onboard 生成或手写）
│       └── runs/
│           ├── latest/              ← 软链接，指向最新一次运行目录
│           └── run_<timestamp>/
│               ├── logs/
│               │   ├── master_prompt.md
│               │   └── claude_output.log
│               ├── memory/
│               │   ├── research_report.md
│               │   ├── code_analysis.md
│               │   └── idea_library.md
│               └── results/
│                   ├── scores.jsonl
│                   ├── optimization_curve.png
│                   └── final_report.md
├── prompts/
│   ├── optimize_prompt.md
│   ├── ideas_prompt.md
│   └── onboard_prompt.md
└── scripts/
    ├── run.py
    ├── onboard.py
    ├── build_prompt.py
    ├── deep_research.py
    └── plot_results.py
```

---

## 场景一：已有 config，直接跑优化（最常见）

```bash
cd /path/to/auto-pipeline/optimizer

# 完整流程（含 deep research）
bash optimize.sh paper-27

# 跳过 deep research（省时）
bash optimize.sh paper-27 --skip-research

# 限制最大迭代数
bash optimize.sh paper-27 --skip-research --max-iter 5

# 只生成 master_prompt，不跑 Claude
bash optimize.sh paper-27 --dry-run
```

**后台运行：**

```bash
nohup bash optimize.sh paper-27 --skip-research > /tmp/paper-27.log 2>&1 &
echo "PID=$!"
```

**查看进度：**

```bash
tail -f papers/paper-27/runs/latest/logs/claude_output.log
watch -n 30 cat papers/paper-27/runs/latest/results/scores.jsonl
cat papers/paper-27/runs/latest/memory/idea_library.md
```

---

## 场景二：接入新 paper（先 onboard，再优化）

**前提：你已在机器上 `git clone` 论文代码，且本机环境能跑通评测（依赖、数据路径自行就绪）。**

```bash
cd /path/to/auto-pipeline/optimizer

# Step 1：Onboard — 探索本地仓库，生成 config.yaml
bash onboard.sh paper-XX \
    --repo /absolute/path/to/clone \
    --repro-log /path/to/reproduction.log

# --repro-log（可选）：
#   传单个 .log 文件 → 直接嵌入 onboard 提示，便于对齐基线
#   传目录           → 提示 Claude 在该目录下查找匹配日志

# Step 2：检查 config.yaml（尤其 repo_path、venv_path、eval_command）
cat papers/paper-XX/config.yaml

# Step 3：优化
bash optimize.sh paper-XX --skip-research
```

若尚无 `config.yaml`，也可从仓库根目录用上层脚本一次跑通（见项目根目录 `README.md` 中的 `run.sh`）。

---

## config.yaml 字段说明

```yaml
paper_title: "论文标题"
paper_repo_url: "https://github.com/user/repo"

# 本地工作区
gpu_devices: "0,1"
repo_path: "/home/you/projects/paper-code"   # 本机绝对路径
venv_path: "/home/you/projects/paper-code/.venv/bin/activate"  # 可选
env_vars: "CUDA_VISIBLE_DEVICES=0"         # 可选

eval_command: "bash scripts/eval.sh"
eval_timeout_minutes: 30

baseline_metrics:
  accuracy: 0.7353
primary_metric: "accuracy"
metric_direction: "higher"
target_improvement_pct: 2.0

max_iterations: 20
max_debug_attempts: 3
max_debug_minutes: 15

openrouter_api_key: "YOUR_OPENROUTER_API_KEY"
research_model: "openai/o4-mini-deep-research"
research_timeout_minutes: 20

eval_output_format: |
  Describe how to parse metrics from stdout.

known_levers: |
  - learning_rate: default 1e-4

setup_notes: |
  Any one-time setup notes for humans (data layout, checkpoints, etc.)
```

---

## 多 paper 并行运行

不同 paper 使用不同 GPU，在各自 `config.yaml` 中设置 `gpu_devices`（或由上层 `run.sh` 写入）：

```bash
nohup bash optimize.sh paper-27 --skip-research > /tmp/27.log 2>&1 &
nohup bash optimize.sh paper-44 --skip-research > /tmp/44.log 2>&1 &
```

---

## 查看全部 paper 当前状态

```bash
for p in papers/*/runs/latest/results/scores.jsonl; do
    name=$(echo "$p" | cut -d/ -f2)
    echo "=== $name ===" && tail -1 "$p" 2>/dev/null | python3 -c \
        "import sys,json; r=json.load(sys.stdin); print(f'  iter={r[\"iter\"]} {r[\"primary_metric\"]:.4f} [{r[\"status\"]}] {r[\"idea_title\"]}')" \
        2>/dev/null || echo "  (no results yet)"
done

ps aux | grep "run\.py" | grep -v grep | awk '{print $2, $12, $13}'
```

---

## 版本回退机制

在 **`repo_path` 本地 git 仓库**内自动管理：

| 情况 | 行为 |
|------|------|
| Debug 超限或超时 | 回退到本轮开始前的提交 |
| 明显回归（相对 `_best`） | 回退到 `_best` |

Git 标签：`_baseline`（初始）、`_best`（历史最优）、`_pre_iter`、`_leap_entry` 等（见 `optimize_prompt.md`）。

---

## 强制终止

```bash
pkill -f "run.py paper-27"
pkill -f "claude"
```

---

## v2：Leap 跨越式优化

连续多轮仅为 `PARAM` 调参会触发 **Leap**：强制做结构性（A+B）idea，详见 `prompts/optimize_prompt.md`。

---

## 常见问题

**Q：deep research 卡住？**

会写入占位 `research_report.md` 并继续；下次可加 `--skip-research`。

**Q：缺依赖或数据？**

在 `setup_notes` 中说明；Phase 0 需能跑通 `eval_command`。

**Q：如何查看某轮代码改动？**

在 `repo_path` 下：

```bash
cd /path/to/repo
git log --oneline -10
git show <commit-hash>
git diff _baseline HEAD --stat
```

**Q：复用已有 run 目录继续跑？**

```bash
bash optimize.sh paper-27 --reuse-run papers/paper-27/runs/run_20260315_155236
```
