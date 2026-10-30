# Quickstart

三种情况最常见：**tenstorrent** 上手（本文主线）、**AMD ROCm** 上手、以及只想确认环境是否就绪。
无论哪种，先跑一次自检，它能省掉大部分「编译到一半才失败」的时间。

---

## 0. 前置条件

| 项 | 要求 |
| --- | --- |
| 主机 | Linux（riscv64 / x86_64 / aarch64）；Windows 请用 WSL |
| 仓库 | 克隆 `rvocs-main` 即可 |
| 权限 | 构建与部署需要 docker；安装驱动需要 sudo |
| 网络 | 国内环境用 `--proxy cn`（默认 `auto` 会自行探测） |

```bash
git clone <rvocs-main>.git && cd rvocs-main
chmod +x rvocs.sh scripts/actions/*.sh     # 若克隆后丢了可执行位
```

子仓库目录不在默认位置时用环境变量：

```bash
RVOCS_SIBLINGS_DIR=/opt/stacks ./rvocs.sh --status
RVOCS_TENSTORRENT_DIR=/data/tenstorrent ./rvocs.sh --target tt-stack --build
```

---

## 1. 先自检

```bash
./rvocs.sh --doctor
```

它会检查平台与 glibc、工具链与 docker、磁盘与内存、子仓库与分支、加速卡与设备节点、网络与镜像源，
并按 `PASS / WARN / FAIL` 分级给出**下一步该敲的命令**。

| 结果 | 含义 | 处置 |
| --- | --- | --- |
| `[PASS]` | 满足 | 继续 |
| `[WARN]` | 该场景才需要，或可降级 | 按提示判断；无卡机器上设备项 WARN 属正常 |
| `[FAIL]` | 阻塞 | 必须先修，否则后面的构建一定失败 |

riscv64 上最常见的两个 FAIL：glibc < 2.38（内置交叉工具链包不可用，改用源码编译）与未验证的架构。
其余「能跑但会踩坑」的条件（厂商定制 rustc 三元组、1G 大页、render/video 组等）以 WARN 提示，
细节见 [QUIRKS.md](QUIRKS.md)。

---

## 2. Tenstorrent 上手

### 2.1 宿主机：驱动与工具

```bash
./rvocs.sh --target tt-host --arch riscv --install --yes
```

一次装好四样东西：内核驱动（提供 `/dev/tenstorrent`）、`tt-smi` / `tt-flash` / `tt-topology`、
1G hugepages（开机持久）、udev 规则。装完自检：

```bash
./rvocs.sh --target tt-host --arch riscv --verify
```

没有现成交付包时会先构建（`fetch → patch → wheels → kmd → bundle → verify`）。

### 2.2 推理镜像

```bash
./rvocs.sh --target tt-stack --arch riscv --download    # 拉现成镜像
./rvocs.sh --target tt-stack --arch riscv --build       # 或从源码构建（2–4 小时）
./rvocs.sh --target tt-stack --arch riscv --verify      # 镜像内验收
```

构建可用 `--stage` 分段：

```bash
./rvocs.sh --target tt-stack --arch riscv --build --stage prep   # 只准备可编辑的源码
./rvocs.sh --target tt-stack --arch riscv --build --stage image  # 改完再出镜像
./rvocs.sh --target tt-stack --arch riscv --build -- --no-sfpi-prebuilt   # 强制源码编译工具链
```

### 2.3 起服务

```bash
./rvocs.sh --target tt-stack --deploy --dry-run   # 先看命令
./rvocs.sh --target tt-stack --deploy --yes       # 真正启动
```

默认 `Qwen3-8B`、端口 `8000`、设备 `n300`；用 `TT_DEPLOY_MODEL`、`DEPLOY_PORT`、`TT_DEPLOY_DEVICE` 覆盖。
服务起来后是 OpenAI 兼容接口，例如 `http://127.0.0.1:8000/v1`。

### 2.4 验收点

| 层 | 检查 |
| --- | --- |
| 宿主机 | `tt-smi` 能读卡；`/dev/hugepages-1G` 已挂载；重启后驱动自动加载 |
| 镜像 | Python 3.12 环境可 `import ttnn` 与 `import vllm`；交叉工具链可执行 |
| 服务 | `/v1/models` 有返回；一次对话请求能正常出 token |

---

## 3. 其它加速器

AMD ROCm 的流程相同，只是 target 换成 `therock`：

```bash
./rvocs.sh --target therock --arch riscv --build     # 源码全栈，约 20 小时以上
./rvocs.sh --target therock --arch riscv --verify
./rvocs.sh --target therock --deploy --yes
```

x86 主机上同一 target 走官方预构建产物，通常一小时以内即可出镜像。
支持的栈与加速器见 `./rvocs.sh --list-targets`。

---

## 4. 只看现状

```bash
./rvocs.sh --version      # 版本快照：子仓库 pin + 实时 git + 镜像 tag
./rvocs.sh --status       # 工作区体积、产物、本地镜像、设备节点
./rvocs.sh --bom          # 全栈版本矩阵
```

只读动作默认覆盖全部 target，不触发任何构建。

---

## 5. 清理

```bash
(cd work/rvocs-tt-deps-riscv64 && sudo ./uninstall.sh)   # 卸载宿主机依赖（--keep-kmd / --purge）
docker image rm <tag> && docker builder prune      # 镜像与构建缓存
rm -rf work/                                       # rvocs 工作区（不影响子仓库源码）
```
