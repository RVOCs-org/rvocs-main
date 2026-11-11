<div align="center">

# RVOCs

**RISC-V Open Computing System · 开放异构 AI 软件栈**

从内核驱动到模型服务，把跨架构适配沉淀为可复用的补丁、构建流程与交付镜像。
以 RISC-V 为起点，连接开放的异构算力生态。

[English](INTRODUCTION.en.md) | 简体中文

[快速开始](#-快速开始) · [架构](#-架构) · [支持范围](#-支持范围) · [发布说明](https://github.com/RVOCs-org/rvocs-main/blob/main/RELEASENOTES.md) · [贡献](#-参与贡献)

</div>

---

## 🧭 RVOCs 是什么

RVOCs（RISC-V Open Computing System）是一套**软硬件一体的开放异构计算系统**：以 RISC-V 服务器为主机，让 GPU / NPU 等加速器上的完整 AI 推理栈——驱动、运行时、编译器、框架、推理引擎——真正跑起来，并以 OpenAI 兼容 API 对外提供服务。

核心能力包括：

- **一条命令跑通全栈**：`rvocs.sh` 统一入口，自检（doctor）→ 宿主机依赖（install）→ 镜像（download/build）→ 验收（verify）→ 服务（deploy），阶段可拆分、可断点续跑。
- **跨架构、跨发行版**：架构差异在 `patches/<arch>/`，发行版差异在宿主机打包层（`host/`）；当前以 Ubuntu 26.04 LTS 为参考系统，Fedora / RHEL / openRuyi 按同一模型接入，上层命令不变。
- **补丁即资产**：跨架构适配不在业务代码里打洞，而是沉淀为各厂商仓库的 `patches/<arch>/` 补丁系列，可审查、可回放、可回馈上游。
- **版本可追溯**：每个仓库的 `VERSION` + `manifest.yaml`（上游 pin）+ gitlink 三方对齐；`baseline.sh` 一条命令切换上游基线，`--version` 查看组件 pin、`--list-releases` 查看已发布产物。
- **产物开箱即用**：镜像发布在华为云 SWR 公共命名空间，宿主机 `.deb` 发布在 GitHub Releases；`--download` 拉到本地即为统一命名的产物。
- **多加速器接口**：厂商仓库按 `rvocs-hcs-{vendor}` 命名接入，一条 target 声明能力矩阵即可扩展新设备，动作语义保持一致。

> RVOCs 打通系统与软件栈，提供经过验证的 RISC-V 计算基础；上层的资源编排与模型服务由 RISMA 等平台在其上构建。

## 🏗 架构

**六层软件栈**——上层使用模型接口，底层适配由各设备软件栈承接：

| 层 | 内容 | AMD 参考实现 | Tenstorrent 路径 |
|---|---|---|---|
| L6 应用与服务 | OpenAI-compatible API | vLLM serve | vLLM serve |
| L5 推理引擎 | 连续批处理 / PagedAttention | vLLM | vLLM + vllm-tt-plugin |
| L4 深度学习框架 | 训练/推理框架 | PyTorch (ROCm backend) | PyTorch (CPU) + TT-NN |
| L3 编译器与算子库 | 设备代码生成 | LLVM / Comgr · Triton · rocBLAS | TT-Metalium · sfpi |
| L2 用户态运行时 | 设备调用抽象 | ROCr · HIP | TT-UMD |
| L1 内核驱动与设备访问 | 枚举/映射/DMA | AMDGPU · AMDKFD · IOMMU | tt-kmd |
| L0 主机与发行版 | 内核、工具链、打包与设备节点 | Ubuntu 26.04 LTS（已支持）· Fedora / RHEL / openRuyi（适配中） | 同左 |

**一个入口编排，多个厂商仓库独立演进**：

```
┌─────────────────────────────────────────────────────────────┐
│                    rvocs-main（统一入口）                     │
│         rvocs.sh  doctor/install/download/build/             │
│                  verify/deploy/version/bom                   │
└──────────────┬──────────────────────────────┬───────────────┘
               ▼                              ▼
┌──────────────────────────────┐  ┌──────────────────────────┐
│   rvocs-hcs-tenstorrent      │  │      rvocs-hcs-amd       │
│  ┌────────┐   ┌───────────┐  │  │  ROCm/TheRock + vLLM    │
│  │ host/  │   │  stack/   │  │  │  镜像（patches/riscv64/ │
│  │ tt-kmd │ + │ TT-Metal  │  │  │  移植层，单分支）        │
│  │ 工具/大页│   │ + vLLM 镜像│  │  └──────────────────────────┘
│  └────────┘   └───────────┘  │
└──────────────────────────────┘
        ▼ 产物（统一命名，验收后交付）
┌─────────────────────────────────────────────────────────────┐
│  rvocs-vllm-tt-riscv64:v0.1.0      （SWR 公共命名空间）      │
│  rvocs-vllm-therock10.0-r9700-riscv64:v0.1.0                │
│  rvocs-tt-deps_0.1.0_riscv64.deb   （GitHub Releases）       │
└─────────────────────────────────────────────────────────────┘
```

设计取舍与 target 接入机制详见 [docs/ARCHITECTURE.md](https://github.com/RVOCs-org/rvocs-main/blob/main/docs/ARCHITECTURE.md)。

## 📦 支持范围

| 软件栈 / 路径 | 目标设备 | riscv64 | x86_64 | 当前公开状态 |
|---|---|---|---|---|
| AMD ROCm / TheRock | Radeon AI PRO R9700（gfx1201）· 当前参考实现 | ✅ 已支持 | 🔲 待支持 | ✅ 端到端 LLM 已验证 |
| Tenstorrent TT-Metal / TT-NN | Wormhole / Blackhole 系列（n300 等） | 🔶 适配中 | ✅ 已支持 | 🔶 组件验收通过，端到端待真卡验证 |
| CUDA / 国产加速卡 | 按实际设备适配 | 🔲 待定 | 🔲 待定 | 🔲 预留 target 扩展 |

架构列表示该软件栈在各宿主架构上的状态：**已支持**＝可构建并部署；**适配中**＝构建与组件验收通过、端到端验证推进中；**待支持 / 待定**＝尚未适配。

覆盖架构：**riscv64 / x86_64**（目标架构须与宿主一致，不做交叉构建）。

**推理引擎**：当前为 **vLLM**（PagedAttention + continuous batching），通过 `--engine` 选择；
**llama.cpp**（CPU / 边缘，无需加速卡）与 **SGLang**（前缀缓存，多轮与结构化生成）在规划中，暂不可用。

**操作系统**：当前以 **Ubuntu 26.04 LTS** 为参考系统（riscv64 / x86_64 完成验证）；**Fedora**、**Red Hat Enterprise Linux**、**openRuyi（如意社区）** 等发行版在适配推进中，差异由宿主机打包层与补丁层吸收，`rvocs.sh` 的动作与产物命名保持一致。

八卡服务器为硬件扩展能力，多卡验证推进中。

## 🚀 快速开始

### 前置条件

1. 一台目标架构的 Linux 主机（riscv64 / x86_64），参考系统 Ubuntu 26.04 LTS。
2. 对应加速卡：AMD 需 riscv64 内核 ≥ `7.0.0-31-generic`（旧内核 amdgpu 有缺陷）；Tenstorrent 需先装驱动。
3. Docker（构建与部署）；驱动安装需要 sudo。

### ① 获取统一入口并自检

```bash
git clone https://github.com/RVOCs-org/rvocs-main.git
cd rvocs-main
./rvocs.sh --clone         # 按需获取厂商仓库
./rvocs.sh --doctor        # 环境自检：PASS/WARN/FAIL，并给出下一步命令
./rvocs.sh --list-releases # 已发布的镜像 tag 与 .deb 全名
```

### ② 安装宿主机依赖（Tenstorrent 路径）

```bash
# 自动从 Releases 下载最新 .deb 并安装（tt-kmd 驱动 + tt-smi/tt-flash/tt-topology + 1G 大页）
./rvocs.sh --target tt-host --arch riscv --install
```

### ③ 获取镜像并验收

```bash
# AMD 路径（参考实现）：拉已发布镜像，或源码构建（首次约 20 小时）
./rvocs.sh --target therock --arch riscv --download     # rvocs-vllm-therock10.0-r9700-riscv64:v0.1.0
./rvocs.sh --target therock --arch riscv --build

# Tenstorrent 路径
./rvocs.sh --target tt-stack --arch riscv --download # rvocs-vllm-tt-riscv64:v0.1.0
# 镜像内验收由子仓库构建的 --stage verify 完成（不对用户单独开放）
```

也可以直接按 tag 拉取镜像：`./rvocs.sh --download rvocs-vllm-tt-riscv64:v0.1.0`。

可拉取的镜像 tag 见 [`RELEASES.list`](https://github.com/RVOCs-org/rvocs-main/blob/main/RELEASES.list)，或运行 `./rvocs.sh --list-releases`
（按宿主架构自动取最新版本）。

### ④ 启动 OpenAI 兼容服务

`--deploy` 暂未开放；镜像拉取/构建后按 `rvocs-hcs-tenstorrent` README 的 `docker run`
示例启动（默认模型 Qwen3-8B，端口 8000）。

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "Qwen3-8B", "messages": [{"role": "user", "content": "你好，RVOCs"}]}'
```

更多路径（GPU 冒烟、离线安装、代理模式）见 [docs/QUICKSTART.md](https://github.com/RVOCs-org/rvocs-main/blob/main/docs/QUICKSTART.md)。

## 📚 文档

| 文档 | 内容 |
|---|---|
| [快速开始](https://github.com/RVOCs-org/rvocs-main/blob/main/docs/QUICKSTART.md) | 分场景上手：自检、驱动、镜像、部署 |
| [CLI 参考](https://github.com/RVOCs-org/rvocs-main/blob/main/docs/CLI.md) | 全部动作、参数与环境变量 |
| [开发架构](https://github.com/RVOCs-org/rvocs-main/blob/main/docs/ARCHITECTURE.md) | 分层设计与 target 接入取舍 |
| [仓库说明](https://github.com/RVOCs-org/rvocs-main/blob/main/docs/REPOS.md) | 各仓库职责与产物 |
| [适配问题记录](https://github.com/RVOCs-org/rvocs-main/blob/main/docs/QUIRKS.md) | RISC-V 已知问题与处置 |
| [产物清单](https://github.com/RVOCs-org/rvocs-main/blob/main/RELEASES.list) | 已发布镜像 tag 与 `.deb` 全名（`--list-releases` 数据源） |
| [发布说明](https://github.com/RVOCs-org/rvocs-main/blob/main/RELEASENOTES.md) | 已发布产物与上游基线 |

## 🤝 参与贡献

提交问题、复现记录、架构补丁或新的 target——把可验证的工程经验留在公开的代码与文档中。

- **反馈问题**：[rvocs-main Issues](https://github.com/RVOCs-org/rvocs-main/issues)
- **新增加速器**：按 `rvocs-hcs-{vendor}` 建仓库，host/ + stack/ 分部件，声明能力矩阵接入
- **基线升级**：改 `manifest.yaml` 的 ref → `baseline.sh apply` → 重放补丁 → 提交（详见各仓库 README）

## 📄 许可

主仓库编排代码采用 Apache-2.0；各厂商仓库与上游组件遵循各自许可。

<div align="center">

**RVOCs · RISC-V Open Computing System · 元石智算**

[GitHub 组织](https://github.com/RVOCs-org) · 让下一次适配，从已有成果开始。

</div>
