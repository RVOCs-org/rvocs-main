# 子仓库简介与协作方式

`rvocs-main` 不实现构建，只调度下面三个仓库。理解它们各自的「阶段 / 补丁 / 产物」是读懂
`rvocs.sh` 行为的前提。

---

## 0. 一览

| target | 仓库 / 部件 | 层 | 分支 | 入口 | 产物 |
| --- | --- | --- | --- | --- | --- |
| `tt-host` | `rvocs-hcs-tenstorrent/host` | 宿主机 | 单分支 `main` | `host/scripts/build.sh` | `host/dist/rvocs-tt-deps_<version>_<debarch>.tar.zst`、`.deb` |
| `tt-stack` | `rvocs-hcs-tenstorrent/stack` | 设备栈镜像 | 单分支 `main` | `stack/scripts/build.sh` | `rvocs-vllm-tt-<arch>:<version>` |
| `therock` | `rvocs-hcs-amd` | 设备栈镜像 | 单分支 `main` | `scripts/build.sh` | `rvocs-vllm-therock<rocm>-<gpu>-<arch>:<version>`、`rvocs-runtime-therock...` |

三者共同的工程约定（`rvocs-main` 沿用同一套）：

1. `scripts/build.sh` 只做参数解析、校验与阶段编排；实际动作在 `NN-<阶段>.sh`，公共逻辑在 `scripts/lib/common.sh`；
2. 源码不入库（`work/` 与 `dist/` 被 gitignore），补丁入库（`patches/`，`series` 决定顺序）；
3. `--proxy cn|direct|auto` 统一网络模式；
4. 阶段可单独重跑（长构建断点续跑），失败即中止并把日志路径打出来。

---

## 1. `tt-host` —— 宿主机依赖

**职责**：让宿主具备「能看见卡、能读卡、能跑容器」的条件。

- **组件**：tt-kmd（DKMS 内核驱动，提供 `/dev/tenstorrent`）、tt-umd（用户态驱动）、
  tt-smi / tt-flash / tt-topology（每工具独立 venv，落在 `/opt/tenstorrent/tools/<tool>`，
  `/usr/local/bin` 里是包装脚本）、1G hugepages（NUMA 感知 + systemd 持久化）、udev 规则。
- **阶段**：`fetch`（浅克隆 pin 的 ref 到 `work/src`）→ `patch`（`common/<组件>` → `<arch>/<组件>`）→
  `wheels`（按目标 Python 版本做 wheelhouse）→ `kmd`（DKMS 包 + 预编译 `.ko`）→
  `bundle`（tar.zst + deb）→ `verify`（交付包静态自检）。
- **为什么单分支**：架构差异几乎都落在补丁上，`--arch` 已贯穿脚本与 `install.sh`；
  开分支会让脚本/文档双份漂移。只有「安装流程本身需要分叉」时才考虑新分支。
- **矩阵**：riscv64 → Ubuntu 26.04（预编译内核 7.0.0-38/31）；x86_64 → 22.04 / 24.04 / 26.04；
  Python 3.10 / 3.12 / 3.14。abi3 wheel 在 `debian:13` 里构建（rustc 1.85.1 + 标准三元组），
  最低 glibc 2.41。
- **已知冲突**：tt-smi 6.8.0 与 tt-flash 4.1.0 需要 `pyluwen~=0.10.0`，tt-topology 1.2.20 需要
  `pyluwen~=0.8.5` → 每个工具独立环境，不共享 venv。
- **与镜像的兼容性**：镜像内置 tt-umd 的 `KMD_MINIMUM_VERSION=2.0.0` 且无上限检查，因此
  tt-kmd 2.11.x 兼容；已在真实 Wormhole 上验证 tt-smi 6.8.0 + TT-KMD 2.11.0 正常读卡。

**rvocs 侧**：`--install` 负责「从 `RELEASES.list` 找最新 `.deb` → 下载 → sudo install」；
`--build` 只建包（缺包时才回退到本地构建）；交付包与镜像的验收由子仓库内部的
`--stage verify` 完成，不作为对外动作开放。

---

## 2. `tt-stack` —— TT-Metal + vLLM 镜像

**职责**：把 Tenstorrent 的推理栈从源码编成可直接 `docker run` 的 OpenAI 兼容服务镜像。

- **pin**：tt-inference-server `v0.22.0`(9ef9d660)、tt-metal `v0.79.0-rc11`(29f93c91)、
  vllm-tt-plugin `d84049e`（内部 pin vLLM 0.30.0）、sfpi `7.78.0`、tt-smi `v3.1.1`；
  Python 3.12.15 + torch 2.14.0+cpu（RISE riscv64 wheel）。
- **阶段**：`fetch`（子模块 + 离线资产校验）→ `workdir`（本地 clone 出独立源码树、按 series 打补丁、
  SFPI 选包与预检、资产就位、生成 `model_spec.json`）→ `base`（riscv64 基础镜像
  `local/tt-metal/tt-metalium/ubuntu-26.04-riscv64:v1`）→ `image`（8 个命名构建上下文）→ `verify`。
- **补丁布局**：`patches/riscv64/<component>/series`（`tt-metal` 1001–1007、`vllm-tt-plugin` 2001–2002），
  只作用于 `work/` 副本；`upstream/` 永远干净。
- **SFPI 工具链优先级**：`--no-sfpi-prebuilt` > `--sfpi-prebuilt DIR` > 内置
  `assets/<arch>/sfpi-prebuilt/*.txz` > 容器内源码编译（~90 分钟）。
  用内置包前做三项预检：文件名逐字比对、sha256、`-mcpu=tt-bh -mabi=ilp32` 冒烟编译。
- **关键约束**：venv 必须先建、编译时 `PATH` 前置 venv，否则 `_ttnn.so` 绑到系统 Python 3.14，
  `import ttnn` 报 `undefined symbol: PyImport_AddModuleRef`。
- **已知限制**：无 riscv64 官方 wheel 的组件被剔除（torchvision、numba、opencv-python-headless、
  qwen-vl-utils、av）；numpy 放宽到 2.5.3；端到端推理尚未在真实卡上验证（验收止于
  `import ttnn` / `import vllm`）；`install-host.sh` 的 kmd/固件步骤在 riscv64 上是 beta。
- **耗时**：命中 SFPI 预构建包约 2 小时（镜像层构建）；未命中 +90 分钟；
  全量无预构建实测 3h58m。

**rvocs 侧**：`--build` 直接委派（`--stage` 可透传），`--download` 走 `docker pull`，
`--deploy` 用固定的设备/大页/缓存卷参数生成命令。

---

## 3. `amd-the-rock` —— ROCm/TheRock + Python 栈镜像

**职责**：把 ROCm 超级工程（TheRock）+ torch / torchvision / triton / vLLM 编成推理镜像。

- **pin**：TheRock `therock-10.0`(16adc4d8)、ROCm 10.0.0、torch 2.11 / torchvision 0.26、
  配套 ROCm 10.0 的 vLLM；目标 GPU 默认 `r9700`（gfx1201 / family gfx120X-all）。
- **阶段**：`preflight` → `fetch`（TheRock 源码 / 官方 tarball；按需拉框架侧源码）→
  `workdir`（应用 `patches/<arch>/`）→ `build`（cmake + ninja → `upstream/therock/build/dist/rocm`）→
  `wheels`（pip 或源码编译 → `work/venv-stack` + `work/wheelhouse`）→ `image` → `verify`。
- **两条路径**：
  - x86_64/aarch64：`--mode prebuilt`（官方 ROCm tarball）+ `--wheel-mode pip`（官方 wheel），分钟级；
  - riscv64：`--mode source` + `--wheel-mode source`，约 23 小时。
- **补丁布局**：`patches/<arch>/components.map`（组件 → 路径）+ `<component>/series` + `image/*.py`
  （镜像构建期执行的 Python 补丁，不走 series）。
  当前 riscv64 内置 21 个 `.patch` + 3 个镜像期 `.py`，不依赖内网 GitLab。
- **基线管理**：`scripts/tools/baseline.sh status|check|sync|bump|tag|rollback`，
  CI 用 `check` 防止子模块 gitlink 与 `manifest.yaml` 漂移。
- **硬前置**：gfortran（只有 gfortran-15 时要软链）、打过补丁的 patchelf（kpack 拆包）、
  `CppHeaderParser` / `msgpack` / `zstandard`、`--jobs` 与内存匹配、~200 GB 磁盘。
- **参考耗时**（80 核 riscv64 + R9700）：TheRock 17h31m（增量续跑）、四个 wheel ~5h、
  镜像 49 min（17.4 GB）、压测 5.5h（最优 740 tok/s @ max-num-seqs=96）。
- **已知限制**：已有构建目录不支持切换 GPU family 后重配（需 `baseline.sh clean`）；
  镜像只含用户态（宿主提供 amdgpu 驱动与 `/dev/kfd`、`/dev/dri`）。

**rvocs 侧**：`--download` 只对 x86_64/aarch64 开放（riscv64 无预构建，直接拒绝并建议 `--build`）；
`--build` 透传 `--gpu/--jobs/--components/--wheelhouse/--venv`；`--deploy` 固定 AMD 设备与组参数。

---

## 4. 交叉兼容矩阵

| 组合 | 状态 |
| --- | --- |
| `tt-host`（tt-kmd 2.11.x）+ `tt-stack` 镜像（tt-umd 0.9.10+13） | 已验证（Wormhole） |
| `tt-host`（宿主 tt-smi 6.8.0）+ `tt-stack` 镜像（镜像内 tt-smi 3.1.1） | 版本独立，互不冲突（各自 venv） |
| `amd-the-rock` 镜像 + 宿主 amdgpu/amdkfd | 依赖发行版内核（含 ZONE_DEVICE/HMM 修复，见 QUIRKS.md） |
| `tt-stack` 与 `amd-the-rock` 同一台机器 | 理论可行（不同 `/dev` 节点），未验证；建议分机验证 |

---

## 5. 不要做的事

- ❌ 在 `upstream/` 里提交自己的改动（子模块会变成本地提交，别人无法复现）→ 一律做成 `patches/`。
- ❌ 在已打补丁的树上 `git diff` 生成新补丁（会把前面补丁的改动带上）→ 先 `git checkout -- <file>` 再改。
- ❌ 用 `cmake` 重配修复 tt-metal 构建目录（会报 tt-logger 缺失/版本文件错误）→ 重建 `workdir`。
- ❌ 在容器里 `pip install` 源码构建（amd-the-rock 镜像内不含 gcc）→ 在宿主 `work/venv-stack` 组装后整体搬入。
- ❌ 用 `riscv64/ubuntu:*` 作为基础镜像（版本不全）→ 用官方 `ubuntu:26.04` 多架构镜像。
