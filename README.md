# RVOCs

**RVOCs（RISC-V Open Computing System）是一套开放的异构 AI 软件栈**：把加速器驱动、用户态运行时、
深度学习框架与推理引擎串成一条可复现的构建与交付链路，让同一套模型服务能跑在 RISC-V 与 x86 主机上。

`rvocs-main` 是它的统一入口 —— 一个 `rvocs.sh`，统一管理宿主机依赖、设备栈镜像与服务部署。

```
rvocs.sh  ──┬── 宿主机     驱动 · 工具 · 大页 · 设备节点
            ├── 设备栈     镜像：运行时 + 框架 + 推理引擎
            └── 服务       OpenAI 兼容 API
```

---

## RVOCs 是什么

- **硬件**：服务器级 CPU（RISC-V / x86）＋ 加速器（GPU / NPU / TPU），以 PCIe 与 IOMMU 互联。
- **软件**：操作系统 → 加速器软件栈 → 深度学习框架 → 推理服务，四层各自可替换。
- **目标**：让「换架构」「换卡」不再等于「重做一套基础设施」——上层模型服务保持不变。

---

## 为什么需要 RVOCs

x86 上的 AI 软件基础设施，在 RISC-V 上默认并不存在：驱动、运行时、算子库、框架与推理引擎的
二进制发行物都缺位，只能从源码重建。RVOCs 不重写这些软件栈，而是把「怎样在 RISC-V 上把它编出来、
跑起来」固化成可复用的构建流程与补丁，并持续回馈上游。

- **面向多栈、多加速器**：新增一种软件栈或一张卡，是加一个 target，而不是新建一套流程。
- **面向 RISC-V 生态**：适配经验以补丁与构建配方沉淀，可审计、可复现、可回馈。
- **已验证**：RISC-V 主机 + AMD Radeon AI PRO R9700 端到端跑通 LLM 推理服务，
  32 并发吞吐达同配置 x86 平台的 95.8%，12 小时压力测试稳定。

---

## 支持范围

| 软件栈 | 加速器 | 状态 |
| --- | --- | --- |
| Tenstorrent（TT-Metal / TT-NN） | Wormhole / Blackhole 系列（n300 等） | 镜像构建与组件验收通过（端到端待真卡验证） |
| AMD ROCm（TheRock） | Radeon AI PRO R9700（gfx1201） | 端到端 LLM 推理已验证 |
| CUDA / 国产加速卡 | — | 预留扩展位，按 target 接入 |

主机架构：**RISC-V (riscv64)** · x86_64。

---

## Quickstart：以 Tenstorrent 为例

准备好一台带 Tenstorrent 卡的主机：

```bash
git clone https://github.com/RVOCs-org/rvocs-main.git && cd rvocs-main
./rvocs.sh --clone                         # 按需获取厂商仓库

# ① 宿主机：内核驱动、tt-smi / tt-flash 等工具、1G 大页
./rvocs.sh --target tt-host --arch x86 --install          # riscv64 主机用 --arch riscv

# ② 推理镜像：产物清单见 --list-releases，拉现成镜像或源码构建
./rvocs.sh --target tt-stack --arch x86 --download        # 或 --build；riscv64 用 --arch riscv

# ③ 起服务：--deploy 尚未开放，用 docker run 启动（完整参数见 docs/DEPLOY.md）
```

最小启动示例（x86_64，在线拉取权重）：

```bash
docker run -d --name tt-vllm --ipc host \
  --device /dev/tenstorrent:/dev/tenstorrent \
  --mount type=bind,src=/dev/hugepages-1G,dst=/dev/hugepages-1G \
  --volume tt-cache:/home/container_app_user/cache_root \
  -p 8000:8000 rvocs-vllm-tt-amd64:v0.1.0 \
  --model Qwen/Qwen3-8B --tt-device n300
```

默认模型 `Qwen3-8B`、端口 `8000`；riscv64 主机把镜像换成 `rvocs-vllm-tt-riscv64:v0.1.0`。
离线部署（标准 HF cache、`--env-file`、鉴权、故障排查）见 [docs/DEPLOY.md](docs/DEPLOY.md)。

先看看环境是否就绪：`./rvocs.sh --doctor`。

### 重装与卸载（宿主机依赖）

```bash
./rvocs.sh --target tt-host --arch x86 --install          # 同版本已安装时自动 --reinstall
./rvocs.sh --target tt-host --arch x86 --download         # 只下载到 work/packages

sudo /opt/tt-deps/uninstall.sh                            # 只卸系统状态，保留包注册与 /opt/tt-deps
sudo /opt/tt-deps/uninstall.sh --purge                    # 彻底卸载：/etc/tenstorrent + dpkg -r
sudo apt purge tt-deps                                    # 或直接走 apt
```

默认安装会对 n300 升级固件；不想刷用 `TT_DEPS_SKIP_FLASH=1 ./rvocs.sh ... --install`。
重装/卸载的完整说明见 [docs/CLI.md](docs/CLI.md#9-安装重装与卸载tt-host)。

其它加速器与分阶段构建见 [docs/QUICKSTART.md](docs/QUICKSTART.md)。

---

## 常用命令

```bash
./rvocs.sh --doctor                       # 环境自检：缺什么、下一步做什么
./rvocs.sh --version                      # 版本快照与上游组件 pin
./rvocs.sh --list-releases                # 已发布产物（按 target 分组，含 digest）
./scripts/tools/digest.sh <deb|镜像>       # 计算产物 digest（填 RELEASES.list 用）
./rvocs.sh --list-targets                 # 可用的栈/加速器与支持的动作
./rvocs.sh --clone                        # 获取厂商仓库
```

| 动作 | 语义 |
| --- | --- |
| `--install` | 安装宿主机依赖（驱动、工具、大页） |
| `--list-releases` | 列出已发布产物（读 `RELEASES.list`） |
| `--download` | 下载最新产物（镜像 / `.deb`） |
| `--build` | 从源码构建镜像或交付包 |
| `--clone` | 获取厂商仓库 |

`--target` 选栈与加速器，`--arch` 选架构，`--stage` 只跑某一段，`--proxy` 选网络模式；
产物清单在 `RELEASES.list` 里按 target 与架构两级分组维护（每行带 sha256 digest，`--download` 会校验），新增一个版本只需在对应 target + 架构小段顶部加一行。
完整参数见 [docs/CLI.md](docs/CLI.md)。

---

## 仓库组成

| 仓库 | 职责 |
| --- | --- |
| `rvocs-main` | 统一 CLI、全栈版本矩阵、发布产物清单 |
| `rvocs-hcs-tenstorrent` | Tenstorrent 厂商仓库：`host/` 宿主机驱动、工具与系统配置；`stack/` TT-Metal + vLLM 镜像 |
| `rvocs-hcs-amd` | AMD ROCm 软件栈镜像：TheRock + PyTorch + vLLM |

各仓库独立演进；`rvocs-main` 只负责发现它们、翻译参数、串接阶段，不重复实现构建逻辑。
`tt-host` 与 `tt-stack` 是 `rvocs-hcs-tenstorrent` 的两个部件（target），不是独立仓库。
细节见 [docs/REPOS.md](docs/REPOS.md)。

---

## 文档

| 文档 | 内容 |
| --- | --- |
| [docs/INTRODUCTION.md](docs/INTRODUCTION.md) | 项目介绍：定位、架构、支持范围与上手路径（[English](docs/INTRODUCTION.en.md)） |
| [RELEASES.list](RELEASES.list) | 已发布产物清单（`--list-releases` / `--download` 的数据源） |
| [RELEASENOTES.md](RELEASENOTES.md) | 已发布的镜像与交付包、对应上游基线、获取方式 |
| [docs/QUICKSTART.md](docs/QUICKSTART.md) | 分场景上手：自检、驱动与工具、镜像、部署 |
| [docs/DEPLOY.md](docs/DEPLOY.md) | 部署指南：前置检查、模型权重、`docker run` 参数、验证与故障排查 |
| [docs/CLI.md](docs/CLI.md) | 全部参数、动作语义、环境变量 |
| [docs/REPOS.md](docs/REPOS.md) | 各仓库的职责与产物 |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 分层与设计取舍 |
| [docs/QUIRKS.md](docs/QUIRKS.md) | RISC-V 适配中的已知问题与处置 |

---

## 许可

本仓库编排代码以 Apache-2.0 发布（见 [LICENSE](LICENSE)）。各子仓库与上游组件版权归各自作者所有。
