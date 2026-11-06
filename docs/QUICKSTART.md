# Quickstart

三种情况最常见：**Tenstorrent** 上手（本文主线）、**AMD ROCm** 上手、以及只想确认环境是否就绪。
无论哪种，先跑一次自检，它能省掉大部分「编译到一半才失败」的时间。

---

## 0. 前置条件

| 项 | 要求 |
| --- | --- |
| 主机 | Linux（riscv64 / x86_64 / aarch64）；Windows 请用 WSL |
| 仓库 | 克隆 `rvocs-main` 即可，厂商仓库用 `--clone` 按需获取 |
| 权限 | 构建与部署需要 docker；安装驱动需要 sudo |
| 网络 | 国内环境用 `--proxy cn`（默认 `auto` 会自行探测） |

```bash
git clone https://github.com/RVOCs-org/rvocs-main.git
cd rvocs-main
chmod +x rvocs.sh scripts/actions/*.sh     # 若克隆后丢了可执行位
./rvocs.sh --clone                         # 把两个厂商仓库 clone 到同级目录
```

只需要某个厂商时：`./rvocs.sh --target therock --clone`。已有副本用环境变量指过去：

```bash
RVOCS_SIBLINGS_DIR=/opt/stacks ./rvocs.sh --target tt-stack --clone
RVOCS_TENSTORRENT_DIR=/data/tenstorrent ./rvocs.sh --target tt-stack --build
```

---

## 1. 先自检

```bash
./rvocs.sh --doctor
```

它检查平台与 glibc、工具链与 docker、磁盘与内存、子仓库、加速卡与设备节点、网络与镜像源，
按 `PASS / WARN / FAIL` 分级给出**下一步该敲的命令**。

| 结果 | 含义 | 处置 |
| --- | --- | --- |
| `[PASS]` | 满足 | 继续 |
| `[WARN]` | 该场景才需要，或可降级 | 按提示判断；无卡机器上设备项 WARN 属正常 |
| `[FAIL] (blocking)` | 阻塞 | 必须先修 |
| `[FAIL] (non-blocking)` | 只影响某一个栈 | 如 riscv64 内核过低只影响 `therock`，其它路径可用 |

常见 quirk 见 [QUIRKS.md](QUIRKS.md)。

---

## 2. Tenstorrent 上手

### 2.1 宿主机：驱动与工具

```bash
./rvocs.sh --target tt-host --arch riscv --install
```

一次装好四样东西：内核驱动（提供 `/dev/tenstorrent`）、`tt-smi` / `tt-flash` / `tt-topology`、
1G hugepages（开机持久）、udev 规则。默认从 `RELEASES.list` 里最新版本的 `.deb` 安装；
没有现成交付包时回退到本地构建。

### 2.2 推理镜像

```bash
./rvocs.sh --list-releases                            # 看已发布产物
./rvocs.sh --target tt-stack --arch riscv --download # 拉最新版本
./rvocs.sh --target tt-stack --arch riscv --build    # 或从源码构建（2–4 小时）
```

构建可用 `--stage` 分段：

```bash
./rvocs.sh --target tt-stack --arch riscv --build --stage prep   # 只准备可编辑的源码
./rvocs.sh --target tt-stack --arch riscv --build --stage image  # 改完再出镜像
./rvocs.sh --target tt-stack --arch riscv --build -- --no-sfpi-prebuilt
```

### 2.3 起服务

```bash
./rvocs.sh --target tt-stack --deploy
```

默认 `Qwen3-8B`、端口 `8000`、设备 `n300`；用 `TT_DEPLOY_MODEL`、`DEPLOY_PORT`、
`TT_DEPLOY_DEVICE` 覆盖。服务起来后是 OpenAI 兼容接口，例如 `http://127.0.0.1:8000/v1`。

### 2.4 验收点

| 层 | 检查 |
| --- | --- |
| 宿主机 | `tt-smi` 能读卡；`/dev/hugepages-1G` 已挂载；重启后驱动自动加载 |
| 镜像 | 交叉工具链可执行；镜像内验收由子仓库构建的 `--stage verify` 完成 |
| 服务 | `/v1/models` 有返回；一次对话请求能正常出 token |

---

## 3. 其它加速器

AMD ROCm 流程相同，target 换成 `therock`（别名 `amd`）：

```bash
./rvocs.sh --target amd --list-releases
./rvocs.sh --target therock --arch riscv --download
./rvocs.sh --target therock --arch riscv --build     # 源码全栈，约 20 小时以上
./rvocs.sh --target therock --deploy
```

x86 主机上同一 target 走官方预构建产物，通常一小时以内即可出镜像。
支持的栈与加速器见 `./rvocs.sh --list-targets`。

---

## 4. 查看版本与产物

```bash
./rvocs.sh --version                  # 版本快照：子仓库 pin + 实时 git 状态
./rvocs.sh --target therock --version # 额外显示 AMD 框架组件版本
./rvocs.sh --list-releases            # 已发布镜像 tag 与 .deb 全名
```

只读动作不触发构建；厂商仓库缺失也不会自动联网，先用 `--clone`。

---

## 5. 清理

```bash
(cd work/rvocs-tt-deps-riscv64 && sudo ./uninstall.sh)   # 卸载宿主机依赖（--keep-kmd / --purge）
docker image rm <tag> && docker builder prune             # 镜像与构建缓存
rm -rf work/                                             # rvocs 工作区（不影响子仓库源码）
```
