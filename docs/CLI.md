# rvocs.sh 命令参考

`rvocs.sh` 是编排层的唯一入口：解析参数、检查前置条件、把动作分发给厂商仓库。它自己不实现任何构建逻辑。

```bash
./rvocs.sh [动作] [--target 目标] [--arch 架构] [选项] [-- 透传参数]
```

---

## 1. 动作（互斥，选一个）

| 动作 | 说明 | 需要 `--target` |
|---|---|---|
| `--version` | 版本与上游组件 pin；不带 `--target` 时只显示 rvocs-main | 否 |
| `--list-releases` | 打印 `RELEASES.list` 中已发布的产物（镜像 tag / `.deb` 全名），按架构分组、组内从新到旧 | 否（可用 `--target` 过滤） |
| `--clone` | 把厂商仓库 clone 到同级目录；不带 `--target` 时 clone 全部 | 否 |
| `--doctor` | 环境自检：OS / 内核 / 磁盘 / 设备节点 / 已知 quirk + 下一步命令 | 否 |
| `--install` | 安装宿主机依赖（tt-kmd / tt-smi / 1G 大页 / udev） | 是 |
| `--download [tag]` | 下载 `RELEASES.list` 中最新版本的产物；给 tag 时直接拉该镜像 | 给 tag 时不需要 |
| `--build` | 从源码构建镜像或交付包 | 是 |
| `--deploy` | 启动推理容器（镜像名取自 `RELEASES.list`） | 是 |
| `--list-targets` | target × 动作 × 架构能力矩阵 | 否 |

> `--verify` 已不作为对外动作开放；验收由子仓库构建流程内部的 `--stage verify` 完成。

---

## 2. Target 与架构

| target | 别名 | 仓库 / 部件 |
|---|---|---|
| `rvocs` | `main`、`self` | 本仓库 |
| `tt-host` | `host` | `rvocs-hcs-tenstorrent/host` |
| `tt-stack` | `tenstorrent`、`tt`、`stack` | `rvocs-hcs-tenstorrent/stack` |
| `therock` | `amd`、`rocm` | `rvocs-hcs-amd` |
| `all` | — | 全部 |

`--target` 支持 `a/b`、`a,b`。`--arch` 取 `x86` / `riscv` / `arm` / `host`，归一化为 `x86_64` / `riscv64` / `aarch64`；目标架构必须与宿主一致（不做交叉构建）。

---

## 3. 选项

| 选项 | 默认 | 说明 |
|---|---|---|
| `--target <t>` | 见动作表 | 目标；`install` / `build` / `deploy` 必须显式给出 |
| `--arch <a>` | `host` | 宿主架构 |
| `--engine <e>` | `vllm` | 推理引擎；目前只实现 `vllm`，`llamacpp` / `sglang` 属规划，传入会明确报错 |
| `--stage <s>` | 子仓库默认 | 透传给子仓库构建（如 `image` / `prep`） |
| `--proxy cn\|direct\|auto` | `auto` | 网络模式 |
| `--workdir <dir>` | `./work` | 日志与下载产物 |
| `-h, --help` | — | 显示帮助 |
| `-- <args...>` | — | 原样透传给子仓库构建脚本 |

**已移除的选项**：`--status`、`--verify`、`--bom`、`--sync`、`--dry-run`、`--yes` / `-y`、`--no-clone`。有副作用的动作（`--install` / `--deploy`）现在直接执行；仓库获取统一走 `--clone`。

---

## 4. 已发布产物：`RELEASES.list`

仓库根目录的 `RELEASES.list` 是产物清单的**唯一来源**，`--list-releases`、`--download`、`--deploy` 都读它。

格式（空白分隔，一行一个产物）：

```
<target>    <version>    <artifact>
```

**按 target 与宿主架构两级分区**：

- 一级用 `# ===== <target> =====` 分出 `tt-host` / `tt-stack` / `therock` 三块；
- 每块内部再用 `# ---- <arch> ----` 分出 `riscv64`、`x86_64`（产物名里是
  `amd64`）、`aarch64`（产物名里是 `arm64`）三小段；
- 一行产物写进它所属 target 的、对应架构的小段；某个组合没有产物就留一行注释
  说明（例如 therock 的 x86_64 仍在适配中）。

**每个 (target, 架构) 小段内部，新版本写在上面**。

- `<artifact>`：完整 `.deb` 文件名，或完整 docker tag（短名，不带 registry 前缀）；
- 镜像从 `<RVOCS_REGISTRY>/<artifact>` 拉取；`.deb` 从
  `<RVOCS_TT_HOST_RELEASES_PAGE>/download/<version>/<artifact>` 下载；
- `--download` / `--deploy` 取「该 target 在目标架构小段里的第一行」，因此各
  target、各架构都能独立发版，互不牵连；
- 新增一个版本：在对应 target + 架构小段的**顶部**插入一行即可，无需改脚本；
  新增 target 或架构则加一段注释 + 若干行。

```bash
./rvocs.sh --list-releases                  # 全部 target
./rvocs.sh --target amd --list-releases    # 只看 AMD
./rvocs.sh --target tenstorrent --list-releases
./rvocs.sh --target tt-host --arch riscv --download   # 下载最新 v0.1.0 的 riscv64 .deb
./rvocs.sh --target tt-stack --arch x86 --download   # 拉最新 v0.1.0 的 amd64 镜像
./rvocs.sh --download rvocs-vllm-tt-amd64:v0.1.0     # 显式指定一个 tag
```

`--download` 拉镜像后自动打成本地短名，并删除带 registry 前缀的 tag，`docker images` 里只出现一条。

---

## 5. 获取子仓库：`--clone`

子仓库不会被任何动作隐式 clone。缺仓库时错误信息会直接给出 `--clone` 命令：

```bash
./rvocs.sh --clone                          # clone 两个厂商仓库
./rvocs.sh --target therock --clone          # 只 clone AMD
./rvocs.sh --target tt-host --clone          # tt-host 与 tt-stack 共用同一仓库，只 clone 一次
```

clone 分支默认 `main`，找不到时依次回退 `master`、远端默认分支；可用 `RVOCS_BRANCH` 覆盖。clone 先落到临时目录，成功后再移动到位，**不会破坏已有目录**。

已有副本可用 `RVOCS_SIBLINGS_DIR`、`RVOCS_TT_HOST_DIR`、`RVOCS_TT_STACK_DIR`、`RVOCS_THEROCK_DIR` 指向。

---

## 6. `--version` 输出

| target | 显示内容 |
|---|---|
| `rvocs` | 本仓库版本、baseline、git 状态 |
| `tt-host` | 仓库版本 + `sources` 组件 pin + 交付包路径 |
| `tt-stack` | 仓库版本 + `upstream` 组件 pin |
| `therock` | 仓库版本 + ROCm release + `upstream` pin + **框架组件版本**（`config/sources.sh` 的 pin + `manifest.yaml` 的 `framework_versions`） |

AMD 栈的 pytorch / triton / torchvision / vllm **pin 来自 `rvocs-hcs-amd/config/sources.sh`**，对应的可读版本号来自该仓库 `manifest.yaml` 的 `framework_versions`；RCCL·NCCL 随 TheRock 提供，版本取 `release.rocm_version`。rvocs-main 不再保存这些数值，改基线时只改厂商仓库。

版本信息**不再显示** `image` / `local image`；镜像名请查 `--list-releases`。

---

## 7. 环境变量

| 变量 | 作用 |
|---|---|
| `RVOCS_SIBLINGS_DIR` | 子仓库父目录（默认 `rvocs-main/..`） |
| `RVOCS_TT_HOST_DIR` / `RVOCS_TT_STACK_DIR` / `RVOCS_THEROCK_DIR` | 直接指定仓库路径 |
| `RVOCS_URL` / `RVOCS_TENSTORRENT_URL` / `RVOCS_THEROCK_URL` | 覆盖 clone 远端 |
| `RVOCS_BRANCH` | clone 分支，默认 `main`；回退顺序 `main` → `master` → 远端默认 |
| `RVOCS_ENGINE` | 推理引擎，默认 `vllm` |
| `RVOCS_REGISTRY` | 已发布镜像的 registry 前缀 |
| `RVOCS_TT_HOST_REPO_SLUG` / `RVOCS_TT_HOST_RELEASES_PAGE` | tt-host 交付包的 GitHub Releases 位置 |
| `RVOCS_MIN_KERNEL_RISCV64` | riscv64 内核下限，默认 `7.0.0-31-generic` |
| `GH_PROXY=1` | `baseline.sh` 解析远端 ref 时走 gh-proxy |
| `TT_DEPLOY_MODEL` / `TT_DEPLOY_DEVICE` / `TT_CACHE_VOLUME` / `DEPLOY_PORT` | Tenstorrent 部署参数 |
| `AMDG_DEPLOY_MODEL` / `AMDG_MODELS_DIR` / `AMDG_CONTAINER_NAME` | AMD 部署参数 |
| `AMDG_GPU_ID` / `AMDG_ROCM_VERSION` | AMD 镜像名与构建目标 |

---

## 8. 日志与退出码

| 类型 | 日志 |
|---|---|
| 只读动作（version / doctor / list-releases / clone / list-targets） | `work/logs/rvocs.log` |
| 构建类动作（install / download / build / deploy） | `work/logs/build.log` |

退出码：`0` 成功；`1` 参数错误、前置校验失败、`--doctor` 有阻塞 FAIL 或子仓库动作失败。`--doctor` 的 FAIL 分 blocking / non-blocking 两类，后者（如 riscv64 内核过低）只影响 `--target therock`，不阻塞其它路径。
