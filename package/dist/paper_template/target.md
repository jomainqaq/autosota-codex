# 目标描述

**论文**：TS-RAG: Retrieval-Augmented Generation based Time Series Foundation Models are Stronger Zero-Shot Forecaster

**任务**：基于检索增强生成（RAG）框架，使用 Chronos-Bolt 作为骨干模型，在七个公开时间序列基准数据集（ETTh1、ETTh2、ETTm1、ETTm2、Weather、Electricity、Exchange Rate）上进行零样本预测，通过引入 Adaptive Retrieval Mixer（ARM）模块动态融合检索到的历史时序模式，降低预测误差（MSE / MAE）。

## 主要指标

| 指标 | 说明 | 优化方向 | 当前基线值 |
|------|------|----------|------------|
| `ETTh1_MSE` | ETTh1 数据集上的均方误差（**主指标**，Lookback=64） | 越低越好 ↓ | 0.3616 |
| `ETTh1_MAE` | ETTh1 数据集上的平均绝对误差 | 越低越好 ↓ | 0.3650 |

## 目标

在主指标 `ETTh1_MSE`（Lookback=64）上相比 Chronos-Bolt 基线提升，目标值为 0.3540 或更低。
