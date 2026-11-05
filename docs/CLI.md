# CLI 参考

```bash
./rvocs.sh [动作] [--target 目标] [--arch 架构] [选项] [-- 透传参数]
```

一个动作 + 一组 target，没有隐含的批量副作用：**有副作用的动作必须显式 `--target`**。

---

## 1. 动作

| 动作 | 是否需要 target | 语义 |
| --- | --- | --- |
| `--version` | 否（默认全部） | 版本快照：`manifest.yaml` 的 pin + 实时 git 分支/提交/describe + 镜像 tag |
| `--status` | 否（默认全部） | 仓库状态、子模块初始化情况、工作区体积、产物、本地镜像、设备节点 |
| `--doctor` | 否（默认全部） | 环境自检（Quickstart 第一步）；有 FAIL 时退出码非 0 |
| `--bom` | 否 | 全栈版本矩阵（读 `manifest.yaml` 的 `bom` 段） |
| `--list-targets` | 否 | target × 动作能力矩阵 + 架构支持 |
| `--install` | 是 | 安装宿主机依赖（仅 `tt-host`） |
| `--download` | 是 | 拉现成产物，不编译 |
| `--build` | 是 | 源码构建（委派子仓库 `scripts/build.sh`） |
| `--verify` | 是 | 验收 |
| `--deploy` | 是 | 生成容器启动命令；`--yes` 才执行 |

多个 target 用 `/` 或 `,` 分隔：`--target tt-stack/therock`、`--target all`。

---

## 2. 选项

| 选项 | 默认 | 说明 |
| --- | --- | --- |
| `--target <t...>` | 只读动作=all；写动作必填 | `tt-host` `tt-stack` `therock` `rvocs` `all`，可用别名（见 §6） |
| `--engine <e>` | `vllm` | 推理引擎：目前只实现 `vllm`；`llamacpp` / `sglang` 属规划，传入会明确报错 |
| `--arch <a>` | `host` | `x86` `riscv` `arm` `host`，也接受 `x86_64` `riscv64` `aarch64` `amd64` `arm64` `rv64` |
| `--stage <s>` | 子仓库默认 | 透传；支持带空格的多阶段（如 `--stage "fetch workdir"`） |
| `--proxy <m>` | `auto` | `cn` = gh-proxy + 清华 PyPI/Rust；`direct`；`auto` 探测 github.com |
| `--workdir <d>` | `./work` | rvocs 自己的工作区（日志、解包产物） |
| `--no-clone` | 关 | 不自动获取缺失的子仓库（离线、或已有副本时使用） |
| `--dry-run` | 关 | 只打印将执行的命令；对 `--deploy` 会强制打印不执行 |
| `--yes` / `-y` | 关 | 允许 `--deploy` 真正启动容器、`--install` 执行 sudo 步骤 |
| `-- <参数...>` | — | 原样追加给子仓库脚本（`build/verify/download`）或 `install.sh`（`install`） |
| `-h` / `--help` | — | 帮助 |

`--arch` 必须与宿主一致：本仓库不做跨架构构建，`--doctor` 会在不一致时给出 WARN。
`--deploy` 不需要 `--arch`（按宿主架构选镜像）。

---

### 2.1 子仓库的自动获取

用户只需要 `rvocs-main` 这一个仓库。当某个动作确实要调用子仓库脚本时，缺失的仓库会被
`git clone` 到 `RVOCS_SIBLINGS_DIR`（默认与 `rvocs-main` 同级）下的预期目录名：

| 动作 | 会不会触发 clone | 原因 |
| --- | --- | --- |
| `--install` / `--build` / `--verify` | 会 | 需要子仓库的 `scripts/build.sh` / 交付包安装器 |
| `--download` | 视 target 而定 | `tt-stack` 只是 `docker pull`（不需要仓库）；`therock` / `tt-host` 需要 |
| `--deploy` | 不会 | 只用镜像名与部署参数 |
| `--version` / `--status` / `--doctor` / `--bom` | 不会 | 只读动作不触发网络，缺失项会明确标注 |

所有仓库都是单分支（`main`；远端只有 `master` 时会自动回退，可用 `RVOCS_BRANCH` 覆盖），clone 分支与 `--arch` 无关；架构差异放在各仓库自己的
`patches/<arch>/` 层。想用自己的副本或离线运行，加 `--no-clone`（缺少仓库时直接报错，
并打印可复制的手动 `git clone` 命令）。

---

## 3. 各 target 的动作实现（参数翻译明细）

### 3.1 `tt-host`（宿主机层）

| 动作 | 实际执行 |
| --- | --- |
| `--install` | 先找 `work/packages/` 里已下载的 `.deb`；没有则从 GitHub Releases 下最新的 `rvocs-tt-deps_<version>_<debarch>.deb` → `sudo apt-get install`；release 无对应架构时回退「本地构建 bundle → `install.sh`」 |
| `--build` | `bash host/scripts/build.sh --arch <arch> --proxy <mode>`（阶段：fetch → patch → wheels → kmd → bundle → verify） |
| `--download` | 从 GitHub Releases 下载最新的 `rvocs-tt-deps_<version>_<debarch>.deb` 到 `work/packages/`（只下不装） |
| `--verify` | 已解包 → `work/rvocs-tt-deps-<debarch>/verify.sh`；否则 `host/scripts/build.sh --stage verify`（交付物静态自检） |
| `--deploy` | 不支持（宿主机层不跑容器） |

`sudo` 步骤需要 `--yes`。`--install -- --check` 会把 `--check` 传给交付包的 `install.sh`。

### 3.2 `tt-stack`（设备栈镜像）

| 动作 | 实际执行 |
| --- | --- |
| `--download` | `docker pull <RVOCS_REGISTRY>/<镜像 tag>` → retag 成本地名 → 删掉 registry 前缀的 tag（按 arch 选 tag；已存在则跳过；异构 tag 自动加 `--platform`） |
| `--build` | `bash stack/scripts/build.sh --arch <arch> --proxy <mode> [--stage <s>]`；默认全流程 `fetch→workdir→base→image→verify` |
| `--verify` | `--stage verify`（镜像内 13 项检查，输出 `VERIFY_OK`） |
| `--deploy` | 生成 `docker run --ipc host --publish <port>:8000 --device /dev/tenstorrent --mount /dev/hugepages-1G --volume <cache> <image> --model <m> --tt-device <d>` |
| `--install` | 不支持 → 提示用 `--target tt-host --install` |

常用透传：`-- --no-sfpi-prebuilt`、`-- --image-tag <tag>`、`-- --workdir <dir>`。

### 3.3 `therock`（设备栈镜像）

| 动作 | 实际执行 |
| --- | --- |
| `--download` | 仅 x86_64/aarch64：`--mode prebuilt --stage fetch`（官方 ROCm tarball）；riscv64 直接拒绝并建议 `--build` |
| `--build` | `bash scripts/build.sh --arch <arch> --proxy <mode> [--stage <s>]`；riscv64 自动 `--mode source --wheel-mode source` |
| `--verify` | `--stage verify --gpu <gpu>`（kpack/ldd/rocminfo/torch/vllm） |
| `--deploy` | 生成 `docker run -d --network=host --ipc=host --device=/dev/kfd --device=/dev/dri --group-add video --group-add render --security-opt seccomp=unconfined -v <models>:/models:ro -e MODEL_PATH=... <image>` |
| `--install` | 不支持 → 内核驱动来自发行版（amdgpu/amdkfd 已入主线） |

常用透传：`-- --gpu r9700`、`-- --jobs 40`、`-- --components ml`、`-- --wheelhouse /path`、`-- --venv /path`。

### 3.4 `rvocs`（编排层自身）

只支持 `--version` `--status` `--doctor` `--bom`。

---

## 4. 环境变量

| 变量 | 作用 |
| --- | --- |
| `RVOCS_SIBLINGS_DIR` | 子仓库父目录（默认 `rvocs-main/..`），自动 clone 也落在这一层 |
| `RVOCS_TT_HOST_DIR` | 直接指定 tt-host 的仓库路径（`rvocs-hcs-tenstorrent`，优先级最高，不再 clone） |
| `RVOCS_TT_STACK_DIR` | 直接指定 tt-stack 的仓库路径（同一个厂商仓库，只是部件不同） |
| `RVOCS_THEROCK_DIR` | 直接指定 therock 的仓库路径（`rvocs-hcs-amd`） |
| `RVOCS_TENSTORRENT_URL` / `RVOCS_THEROCK_URL` | 覆盖自动 clone 用的远端地址（tt-host 与 tt-stack 共用前者） |
| `RVOCS_NO_CLONE=1` | 等价于 `--no-clone`：缺仓库直接报错，不联网 |
| `RVOCS_BRANCH` | 自动 clone 用的分支，默认 `main`；回退顺序 `main` → `master` → 远端默认分支 |
| `RVOCS_ENGINE` | 推理引擎，默认 `vllm`（目前仅此一个；`llamacpp` / `sglang` 属规划） |
| `RVOCS_REGISTRY` | 已发布镜像的 registry 前缀，默认 `swr.cn-east-3.myhuaweicloud.com/cloud-mdgx` |
| `RVOCS_TT_HOST_REPO_SLUG` / `RVOCS_TT_HOST_RELEASES_PAGE` / `RVOCS_TT_HOST_RELEASES_API` | tt-host 交付包的 GitHub Releases 位置（默认 `RVOCs-org/rvocs-hcs-tenstorrent`） |
| `RVOCS_MIN_KERNEL_RISCV64` | riscv64 内核下限（默认 `7.0.0-31-generic`），低于此值 `--doctor` 报非阻塞 FAIL |
| `ARCH` / `PROXY_MODE` / `WORK_DIR` / `STAGE` | 等价于同名命令行选项（命令行优先） |
| `PROXY=1` | 强制镜像模式（跳过探测） |
| `TT_DEPLOY_MODEL` / `TT_DEPLOY_DEVICE` / `TT_CACHE_VOLUME` / `DEPLOY_PORT` | Tenstorrent 部署参数 |
| `AMDG_DEPLOY_MODEL` / `AMDG_MODELS_DIR` / `AMDG_CONTAINER_NAME` | AMD 部署参数 |
| `AMDG_GPU_ID` / `AMDG_ROCM_VERSION` | AMD 镜像 tag 与构建目标 |

镜像 tag 与子仓库的一致性由 `config/defaults.sh` 维护；子仓库升级 pin 后同步这里与 `manifest.yaml`。

---

## 5. 日志与退出码

| 动作类型 | 日志位置 |
| --- | --- |
| 只读（version/status/doctor/bom） | `work/logs/rvocs.log` |
| 构建类（install/download/build/verify/deploy） | `work/logs/build.log`（追加；与子仓库同名习惯一致） |

| 退出码 | 含义 |
| --- | --- |
| `0` | 成功（含「无需变更」的情况，如镜像已存在、`--deploy` 只打印） |
| `1` | 参数错误 / 前置校验失败 / `--doctor` 有 FAIL / 子仓库动作失败 |

失败时错误信息会带上「怎么修」：缺失仓库给候选目录与环境变量名，分支不对给 `git checkout` 命令，
缺镜像给 `--build` / `--download` 两个选项。

---

## 6. 别名

| 规范 target | 可用别名 |
| --- | --- |
| `tt-host` | `tt-host-master`、`tt-dependency-installer`、`tt-deps`、`host` |
| `tt-stack` | `tt`、`tt-metal`、`ttnn` |
| `therock` | `amd`、`amd-the-rock`、`rocm` |
| `rvocs` | `rvocs-main`、`main`、`self` |

目录候选（在 `RVOCS_SIBLINGS_DIR` 下按序探测）：`tt-host` → `tt-host-master` →
`tt-dependency-installer`；`tt-stack`；`amd-the-rock` → `therock`。

自动 clone 的默认地址（可用 `RVOCS_TENSTORRENT_URL` / `RVOCS_THEROCK_URL` 覆盖）：

| target | 地址 | clone 分支 |
| --- | --- | --- |
| `tt-host` | `https://github.com/RVOCs-org/rvocs-hcs-tenstorrent.git` | 单分支 `main`（`master` 自动回退） |
| `tt-stack` | `https://github.com/RVOCs-org/rvocs-hcs-tenstorrent.git` | 单分支 `main`（`master` 自动回退） |
| `therock` | `https://github.com/RVOCs-org/rvocs-hcs-amd.git` | 单分支 `main`（`master` 自动回退） |

克隆到的是**上层仓库**（各子仓库的 `upstream/` 代码由它自己的 `fetch` 阶段拉取），
所以首次执行只会下载编排脚本与补丁层，不会一次拉几十 GB 源码。

---

## 7. 示例合集

```bash
# 版本与状态
./rvocs.sh --version
./rvocs.sh --target tt-stack/therock/tt-host --version
./rvocs.sh --target all --status
./rvocs.sh --bom

# 自检
./rvocs.sh --doctor
PROXY=1 ./rvocs.sh --target all --doctor

# 宿主机
./rvocs.sh --target tt-host --arch riscv --build
./rvocs.sh --target tt-host --arch riscv --install --yes
./rvocs.sh --target tt-host --arch riscv --install --yes -- --check

# Tenstorrent
./rvocs.sh --target tt-stack --arch riscv --download
./rvocs.sh --target tt-stack --arch riscv --build --stage prep
./rvocs.sh --target tt-stack --arch riscv --build --stage image
./rvocs.sh --target tt-stack --arch riscv --build -- --no-sfpi-prebuilt
./rvocs.sh --target tt-stack --arch riscv --verify
./rvocs.sh --target tt-stack --arch riscv --deploy --dry-run
TT_DEPLOY_MODEL=Qwen3-32B DEPLOY_PORT=8080 ./rvocs.sh --target tt-stack --arch riscv --deploy --yes

# AMD
./rvocs.sh --target therock --arch x86 --download
./rvocs.sh --target therock --arch x86 --build -- --gpu r9700
./rvocs.sh --target therock --arch riscv --build -- --jobs 40
./rvocs.sh --target therock --arch riscv --verify
./rvocs.sh --target therock --arch riscv --deploy --dry-run
```
