# Release notes

本文件记录 **已实际发布** 的产物（镜像与交付包）、它们对应的上游基线，以及获取方式。
未发布的内容不列在这里。

命名规则见 [RVOCs 仓库使用说明 §7.4](../RVOCs仓库使用说明.md) 或各仓库 `manifest.yaml`。

---

## v0.1.0（2026-10-29）

首个公开发布。5 个产物：3 个镜像 + 2 个宿主机交付包。

| 产物 | 类型 | 架构 | 发布位置 | 获取命令 |
|---|---|---|---|---|
| `rvocs-vllm-tt-riscv64:v0.1.0` | vLLM 推理镜像（Tenstorrent） | riscv64 | SWR | `./rvocs.sh --download rvocs-vllm-tt-riscv64:v0.1.0` |
| `rvocs-vllm-tt-amd64:v0.1.0` | vLLM 推理镜像（Tenstorrent） | amd64 | SWR | `./rvocs.sh --download rvocs-vllm-tt-amd64:v0.1.0` |
| `rvocs-vllm-therock10.0-r9700-riscv64:v0.1.0` | vLLM 推理镜像（AMD GPU） | riscv64 | SWR | `./rvocs.sh --download rvocs-vllm-therock10.0-r9700-riscv64:v0.1.0` |
| `rvocs-tt-deps_v0.1.0_riscv64.deb` | 宿主机依赖（驱动 + 工具 + 大页 + udev） | riscv64 | GitHub Releases | `./rvocs.sh --target tt-host --arch riscv --download` |
| `rvocs-tt-deps_v0.1.0_amd64.deb` | 宿主机依赖（驱动 + 工具 + 大页 + udev） | amd64 | GitHub Releases | `./rvocs.sh --target tt-host --arch x86 --download` |

- 镜像 registry 前缀：`swr.cn-east-3.myhuaweicloud.com/cloud-mdgx/`（公开，无需登录）；
  `--download` 拉取后只保留短名（retag 后会自动删掉 registry 前缀的 tag，`docker images` 里只出现一个 `rvocs-...` 条目）
- 交付包获取：`./rvocs.sh --target tt-host --arch <arch> --download`（`.deb` 资产发布在 GitHub Releases；如需指向镜像，覆盖 `RVOCS_TT_HOST_RELEASES_*`）

### 1. `rvocs-vllm-tt-*`（Tenstorrent 栈）

基于 `tt-inference-server` 官方 Dockerfile 源码构建，内含 TT-Metal、vLLM 0.30.0 平台插件与 sfpi 工具链。

| 组件 | 版本 | pin |
|---|---|---|
| tt-inference-server | 0.22.0 系提交 | `0da24a9debc2f3a01046cbee674fa83f91f4902e` |
| tt-metal | v0.79.0-rc11 | `29f93c914b6137d22571a6c99df912f359739b54` |
| vllm-tt-plugin | main | `d84049edcece77c64772a39e92f920f5679efce4`（内部固定 vLLM 0.30.0） |
| sfpi | 7.78.0 系提交 | `fe971db51e0d67036109a6e57a0ea54524c9c63e` |
| tt-smi（镜像内） | v3.1.1 | `a2791bfec3324f4cb72a362b413460b89ca2b391` |
| 基础镜像 | `local/tt-metal/tt-metalium/ubuntu-26.04-riscv64:v1` | 不单独分发 |

运行时入口：`vllm serve`，默认模型 `Qwen3-8B`、端口 8000。

### 2. `rvocs-vllm-therock10.0-r9700-riscv64:v0.1.0`（AMD GPU 栈）

基于 TheRock 超级工程源码构建：ROCm 用户态 + 自建 torch/torchvision/vLLM + amdsmi 绑定。

| 组件 | 版本 / pin |
|---|---|
| TheRock | `therock-10.0`（`16adc4d875fd4f65ea23c7c84e1c66706fde3047`） |
| ROCm | 10.0.0（stable 通道） |
| 目标 GPU | Radeon AI PRO R9700（`gfx1201`，family `gfx120X-all`） |
| torch / torchvision | 源码构建（2.11 / 0.26） |
| vLLM | 与 ROCm 10.0 配套的源码构建版本 |
| venv | `/opt/venv-torch`（含 wheel 归档 `/opt/vllm-wheels`） |

镜像内启用多卡 NCCL 兼容默认值（`VLLM_RCCL_FIX=1` 于 riscv64）。

### 3. `rvocs-tt-deps_v0.1.0_{riscv64,amd64}.deb`

宿主机依赖包，安装后提供 `/dev/tenstorrent` 与配套工具。

| 组件 | 版本 |
|---|---|
| tt-kmd（DKMS 内核驱动） | `ttkmd-2.11.0` |
| tt-umd（用户态驱动，含 python 绑定） | `v0.9.14`（fetch 阶段可能按工具元数据微调） |
| tt-smi | `v6.8.0` |
| tt-flash | `v4.1.0` |
| tt-topology | `v1.2.20` |
| 其它 | 1G hugepages 配置、udev 规则、systemd 单元 |

riscv64 包内附带以下内核的预编译 `.ko`：`7.0.0-38-generic`、`7.0.0-31-generic`；其它内核走 DKMS 现场编译。

### 获取与使用

产物清单由仓库根目录的 `RELEASES.list` 维护（按 target 与宿主架构两级分组、组内从新到旧），`--list-releases`、
`--download`、`--deploy` 都读它；新增一个版本只需在文件里加一行。

```bash
./rvocs.sh --list-releases                         # 先看有哪些产物

# 1) 宿主机依赖（riscv64 或 x86_64）
./rvocs.sh --target tt-host --arch riscv --download   # 只下载 .deb 到 work/packages/
./rvocs.sh --target tt-host --arch riscv --install

# 2) 推理镜像（按宿主架构自动选 tag）
./rvocs.sh --target tt-stack --arch riscv --download    # -> rvocs-vllm-tt-riscv64:v0.1.0
./rvocs.sh --target therock      --arch riscv --download    # -> rvocs-vllm-therock10.0-r9700-riscv64:v0.1.0

# 3) 起服务
./rvocs.sh --target tt-stack --deploy
./rvocs.sh --target therock      --deploy
```

也可以先 `--download <tag>` 拉单个镜像，再按同名短 tag 部署。

### 兼容性

| 项 | 要求 / 说明 |
|---|---|
| 架构 | 镜像 tag 中的架构必须与宿主一致；amd64 镜像不能在 riscv64 上运行（`--download` 会加 `--platform` 仅用于搬运） |
| riscv64 内核 | AMD 栈要求 ≥ `7.0.0-31-generic`（旧内核 amdgpu 驱动有缺陷）；`--doctor` 会报 FAIL（非阻塞） |
| riscv64 glibc | ≥ 2.38 才能用预构建 sfpi；≥ 2.41 才能用 tt-deps 的 abi3 wheel |
| 磁盘 | 仅拉镜像 ≥ 40 GB；源码构建另需 200 GB 以上 |
| 未提供 | aarch64 产物、`rvocs-runtime-*` 镜像、`.tar.zst` 交付包（可用 `--build` 本地生成） |

### 校验

```bash
# 镜像 digest
docker inspect --format '{{index .RepoDigests 0}}' rvocs-vllm-tt-riscv64:v0.1.0

# deb 元信息与内容
dpkg-deb -I work/packages/rvocs-tt-deps_v0.1.0_riscv64.deb
dpkg-deb -c work/packages/rvocs-tt-deps_v0.1.0_riscv64.deb | head
```

发布时未随 release 附带 `.sha256` 文件，需要校验时请自行计算并与发布记录比对。

### 已知限制

- Tenstorrent 端到端推理尚未在真实卡上验证（验收止于 ttnn / vLLM 导入与镜像内冒烟）。
- `tt-kmd` 在 riscv64 上仍属 beta，固件相关步骤以 Tenstorrent 官方说明为准。
- riscv64 的 torch 栈按设计不含 torchvision / numba / opencv-python-headless 等重依赖。
- 旧内核（< `7.0.0-31-generic`）上 AMD 镜像不可用，需先升级并重启。

---

## 变更记录

| 版本 | 日期 | 说明 |
|---|---|---|
| v0.1.0 | 2026-10-29 | 首个公开发布：2 个 Tenstorrent 镜像（riscv64 / amd64）、1 个 TheRock 镜像（riscv64）、2 个 tt-deps 交付包（riscv64 / amd64） |
