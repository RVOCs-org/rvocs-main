# 已知 Quirk 清单：现象 → 根因 → 检测 → 处置

RISC-V 主机 + 异构加速卡的故障，绝大多数不是「功能没写」，而是**隐式架构假设**在某一层失效。
本页按 RVOCs 的分层（L1 内核 → L6 服务）组织，便于「先定位层级，再修根因」。

`./rvocs.sh --doctor` 能自动检测的条目在表中标了 ✅；其余需要人工按条目排查。

| # | 层 | Quirk | doctor |
| --- | --- | --- | --- |
| 1 | 宿主 | 厂商定制 rustc 三元组导致 abi3 wheel 构建 panic | ✅ |
| 2 | 宿主 | glibc 版本决定 SFPI 预构建包 / abi3 wheel 可用性 | ✅ |
| 3 | 宿主 | 1G hugepages 未配置（Tenstorrent 容器必需） | ✅ |
| 4 | 宿主 | `/dev/kfd`、`/dev/dri`、render/video 组缺失 | ✅ |
| 5 | 网络 | GitHub / PyPI / release 资产直连阻断 | ✅（仅 github） |
| 6 | L1 | amdgpu 加载即 Oops：`DIRECT_MAP_PHYSMEM_END` 未定义 | — |
| 7 | L2 | x86 内存序原语（`_mm_sfence` / `_mm_pause`）在 RISC-V 上不成立 | — |
| 8 | L2 | `kpack` 拆包写坏 ELF（patchelf ≤0.18.0） | ✅（patchelf 存在性） |
| 9 | L3 | ThinLTO 需要 lld；mold 缺 `LLVMgold.so` | — |
| 10 | L3 | LLVM/Comgr 主机目标与设备目标（HOST=RISCV64 / DEVICE=AMDGCN）需分别构建 | — |
| 11 | L3 | tt-metal streaming profiler 是 x86 AVX2 专用 | — |
| 12 | L4 | numpy 1.x/2.x 分叉（上游要求 <2） | — |
| 13 | L4 | TheRock 全量构建的 GFortran / CppHeaderParser / 磁盘 / 内存 | ✅（部分） |
| 14 | L5 | vLLM C++ 扩展的 x86 假设与 `-m64` / `-msse` 构建选项 | — |
| 15 | L5 | 多卡 RCCL 在 RISC-V 上需要 NCCL 兼容环境变量 | — |
| 16 | L5 | venv 顺序错误导致 `_ttnn.so: undefined symbol: PyImport_AddModuleRef` | — |
| 17 | L5 | tt-metal 已有构建目录重配失败（tt-logger / 版本文件） | — |
| 18 | 交付 | CPM 从 GitHub Releases 拉依赖被墙 | — |
| 19 | 交付 | SFPI 源码编译 ~90 分钟且产物膨胀到 42.6 GB | ✅（glibc 预检） |
| 20 | 交付 | `pyluwen` 版本冲突导致三个工具无法共用一个环境 | — |

---

## 1. 厂商定制 rustc 三元组（宿主）

- **现象**：构建 `pyluwen`（pyo3/maturin）时 panic：`Invalid target name: 'riscv64a23-unknown-linux-gnu'`。
- **根因**：部分 RISC-V 发行版的 rustc 报告的是厂商自定义 host 三元组，旧版 `target-lexicon`（0.12）无法解析。
  另外 maturin 需要 Rust ≥ 1.85（edition2024），Ubuntu 24.04 的 cargo 1.75 太旧。
- **检测**：`rustc -vV | grep host`；doctor 会与标准三元组比对。
- **处置**：让 rustup 的官方 `riscv64gc-unknown-linux-gnu` 工具链在 `PATH` 里优先；
  tt-host 的 abi3 wheel 在 `debian:13` 里构建（cargo 1.85.1、标准三元组、glibc 2.41）。

## 2. glibc 版本（宿主）

- **现象**：`sfpi` 交叉工具链可执行文件报 `GLIBC_2.38 not found`；或 abi3 wheel 装不上。
- **根因**：内置 `sfpi_7.78.0_riscv64_debian.txz` 最高引用 glibc 2.38 符号；tt-host 的 abi3 wheel 最低 glibc 2.41。
- **检测**：`ldd --version`；doctor 分别对 2.38 / 2.41 打 PASS/FAIL/WARN。
- **处置**：升级到 Ubuntu 26.04（glibc 2.43）；或 `--build -- --no-sfpi-prebuilt` 走容器内源码编译。

## 3. 1G hugepages（宿主）

- **现象**：Tenstorrent 容器启动失败，提示 `/dev/hugepages-1G` 不存在或不足。
- **根因**：tt-metal 需要 1G 大页做设备内存映射；重启后不会自动恢复。
- **检测**：`awk '/HugePages_Total/{print $2}' /proc/meminfo`。
- **处置**：tt-host 的 `hugepages-setup.sh`（NUMA 感知 + `dev-hugepages\x2d1G.mount` +
  `tt-hugepages.service`），安装一次即开机持久。

## 4. AMD 设备节点与用户组（宿主）

- **现象**：容器里 `rocminfo` 看不到卡，或 `torch.cuda.is_available()` 为 False。
- **根因**：缺 `/dev/kfd`、`/dev/dri/renderD*`，或当前用户不在 `render` / `video` 组。
- **检测**：`ls -l /dev/kfd /dev/dri/renderD*`；`id -nG`。
- **处置**：确认 `amdgpu`/`amdkfd` 已加载；部署时 `--group-add video --group-add render`
  （`--deploy` 生成命令已包含）。把用户永久加入组需重新登录。

## 5. 网络（宿主）

- **现象**：`git clone` 卡住、`pip install` 11 KB/s、release 资产下载 2–7 KB/s、`download.pytorch.org` 超时。
- **根因**：境内对 `github.com` / `raw.githubusercontent.com` 直连阻断（`api.github.com` 通常可达），
  PyPI 与 PyTorch 官方源速度不可用。
- **检测**：`curl -fsSI -m 8 https://github.com`（doctor 会探测并推荐 `--proxy cn`）。
- **处置**：`--proxy cn` → git 走 `gh-proxy.com` 改写、PyPI 走清华、Rust 工具链走清华、
  GitHub Release 资产走 gh-proxy（`UV_PYTHON_INSTALL_MIRROR`）。
  子仓库不在 gitconfig 里写全局规则（用 `-c insteadOf` / `GIT_CONFIG_*` 环境变量传递给子进程）。

## 6. amdgpu 加载即 Oops（L1）

- **现象**：`dmesg` 出现 `__init_single_page+0x16` / Store/AMO Page Fault（cause 15），`amdgpu` 加载失败。
- **根因**：`amdgpu` 为 HMM 统一内存注册 ZONE_DEVICE，`devm_request_free_mem_region()` 用
  `DIRECT_MAP_PHYSMEM_END` 限制上界；RISC-V 未定义该宏 → fallback `2^56-1`（≈64 PB），
  远超 SV48 vmemmap 覆盖范围（约 128 TB）→ `pfn_to_page()` 落在未映射 VA。
- **检测**：`dmesg | grep -A5 'Oops'`；确认内核版本是否含上游提交（`riscv: mm: Define DIRECT_MAP_PHYSMEM_END`，7.1-rc1 起）。
- **处置**：升级内核；或按上游补丁在 `arch/riscv/include/asm/pgtable.h` 按
  `CONFIG_FLATMEM` / `SPARSEMEM_VMEMMAP` / `SPARSEMEM` 分别定义（与本机一致的通常是 VMEMMAP 分支）。

## 7. x86 内存序原语（L2）

- **现象**：多线程推理偶发数据竞争、死锁、KV cache 分配异常。
- **根因**：栈内大量 `_mm_sfence` / `_mm_mfence` / `_mm_pause` 等 x86 内建，在 RISC-V 上要么不存在，
  要么语义不等价（x86 TSO vs RISC-V 弱内存序）。
- **检测**：`grep -rn '_mm_\(sfence\|mfence\|pause\)' <源码>`；运行时用压测复现。
- **处置**：替换为编译器内建（生成 `fence`）或架构可用指令；缓存分配器在关键路径补显式 fence。

## 8. kpack 拆包写坏 ELF（L2/交付）

- **现象**：拆包后的库 `ldd` 报错或进程 `SIGSEGV`，ELF 头部异常。
- **根因**：上游 `patchelf ≤ 0.18.0` 会写坏 PHDR 位于尾部的 LOAD 段——kpack 拆出来的库正是这种布局。
- **检测**：`patchelf --version`；doctor 检查存在性。
- **处置**：用上游脚本安装打过补丁的 patchelf：
  `sudo env INSTALL_PREFIX=/usr/local ./upstream/therock/dockerfiles/install_pinned_patchelf.sh`。

## 9. ThinLTO 与链接器（L3）

- **现象**：链接阶段报找不到 `LLVMgold.so`（mold）或 ThinLTO 相关错误。
- **根因**：ThinLTO 需要 lld；mold 依赖 `LLVMgold.so`，该组件未安装。
- **处置**：`apt-get install -y lld`，链接器选 `lld`；不要用 mold 绕过。

## 10. HOST/DEVICE 双目标（L3）

- **现象**：Triton / LLVM / Comgr 在主机侧运行正常，但生成 `.hsaco` 失败，或反过来。
- **根因**：主机目标（riscv64）与设备目标（amdgcn，如 gfx1201）必须分别构建；
  JIT 在 riscv64 主机上执行，产出的却是 GPU 设备码。
- **处置**：`GPU_TARGETS` 只控制设备侧；主机侧构建路径要单独补齐；
  Triton 需识别主机三元组并保留 LLVM/MLIR 的 RISC-V 后端模块。

## 11. tt-metal streaming profiler 的 AVX2（L3）

- **现象**：x86_64 之外编译 `tt_metal/impl/streaming_profiler/spsc_marker_decode.hpp` 失败。
- **根因**：该头文件直接用 `__m256i` 与 `_mm*_` 内建。
- **处置**：转换为 simde：`_mm*_` → `simde_mm*_`、`__m256i` → `simde__m256i`，
  提示常量用 `SIMDE_MM_HINT_T0`，`maskload` 需要 `const int64_t*`。
  与仓库内 `data_format/bfloat8.cpp` 的既有做法保持一致。

## 12. numpy 版本分叉（L4）

- **现象**：tt-metal 声明要求 `numpy<2`，但 riscv64 可用的 wheel 是 2.5.3。
- **处置**：移植层放宽到 2.5.3；已核查代码未使用 numpy 1.x 专有 API。
  若未来上游新增 1.x 依赖，需要在 `patches/` 里显式修掉而不是降级（riscv64 无 1.x wheel）。

## 13. TheRock 构建的硬前置（L4/宿主）

- **现象**：`gfortran: not found`；`hip-clr` PCH 生成失败；kpack 拆包缺模块；构建中途磁盘满。
- **处置**：
  - 只装了 `gfortran-15` 时软链 `sudo ln -s /usr/bin/gfortran-15 /usr/local/bin/gfortran`；
  - 装 `CppHeaderParser`（PCH 生成）与 `msgpack`、`zstandard`（kpack），`meson==1.12.0`；
  - 磁盘按 200 GB 准备，`--jobs` 从 40 起、内存吃紧降到 8–16（`amd-llvm` 链接每 job 4–8 GB）；
  - riscv64 默认 `-DBUILD_TESTING=OFF`、不启用 ccache（`--offload-compress` 未验证）。

## 14. vLLM C++ 扩展的 x86 假设（L5）

- **现象**：`-m64` / `-msse` 之类的编译选项报错；PagedAttention / KV cache 路径崩溃。
- **根因**：构建体系与扩展代码里残留 x86 专属选项与对齐假设。
- **处置**：清理 x86 专属 CMake 选项，补齐 RISC-V 目标；修正对齐与原子语义；
  容器化交付保证可复现。

## 15. 多卡 RCCL（L5）

- **处置**：riscv64 镜像写入 `/opt/stack/rccl_fix.env`：
  `NCCL_CUMEM_ENABLE=1`、`NCCL_WIN_ENABLE=0`；`--tensor-parallel-size 2` 通常需配 `--enforce-eager`；
  `--max-num-seqs` 取 2 的幂（工程推荐 64，上限 96）；首次 `torch.compile` 约 4–5 分钟。

## 16. venv 顺序 → `PyImport_AddModuleRef`（L5）

- **现象**：镜像构建成功，但 `import ttnn` 报
  `_ttnn.so: undefined symbol: PyImport_AddModuleRef`。
- **根因**：tt-metal 的 `build_metal.sh` 用 `command -v python3` 决定绑定目标解释器；
  若先编 C++ 后建 venv，绑定会链到系统 Python（3.14），与运行时 venv（3.12）ABI 不符。
- **处置**：**先建目标版本 venv 并激活**（`PATH` 前置），再调用 `build_metal.sh`。
  rvocs 的 `--build` 只是转发，这一步由 `tt-stack` 的 Dockerfile 保证。

## 17. tt-metal 已有构建目录重配失败（L5）

- **现象**：在已构建的目录上重跑 cmake 报 tt-logger target 缺失 /
  `WRITE_BASIC_CONFIG_VERSION_FILE` 无版本。
- **处置**：不要用「重配」绕过。用 `--build --stage workdir` 重建工作区，再 `--stage image`。

## 18. CPM 拉依赖被墙（交付）

- **现象**：configure 阶段卡在从 GitHub Releases / git 拉 CPM 或 Boost。
- **处置**：预置 `CPM_0.40.2.cmake` 到 `.cpmcache/cpm/`（存在性判断后跳过下载），
  并设 `CPM_USE_LOCAL_PACKAGES=ON` 复用系统 Boost。

## 19. SFPI 工具链（交付）

- **现象**：镜像构建耗时 4 小时+，镜像体积 40 GB+。
- **根因**：SFPI 交叉工具链在 CMake configure 内源码构建（实测 93 分钟）；
  旧 Dockerfile 的清理路径写成 `runtime/sfpi/sfpi-src`，实际在 `runtime/sfpi-src`，
  导致 binutils/gcc/newlib 源码与中间物（约 20 GB）留在镜像里（42.6 GB → 正常 ~15 GB）。
- **处置**：
  - 用内置预构建包（77 MB，sha256 `0214513e…`），前置三项预检：文件名逐字比对、sha256、
    `-mcpu=tt-bh -mabi=ilp32` 冒烟编译；
  - 预检失败自动回退源码编译并打印原因；
  - 清理路径必须指向 `${TT_METAL_HOME}/runtime/sfpi-src` 与 `sfpi-build.log`。

## 20. pyluwen 版本冲突（交付）

- **现象**：同一环境里装三个工具时依赖解析失败。
- **根因**：tt-smi 6.8.0 / tt-flash 4.1.0 需要 `pyluwen~=0.10.0`，tt-topology 1.2.20 需要 `~=0.8.5`。
- **处置**：每个工具独立环境 `/opt/tenstorrent/tools/<tool>`，`/usr/local/bin` 放包装脚本，
  用户无需激活 venv、运行不需要 sudo。

---

## 附：人工排查顺序

1. `./rvocs.sh --doctor` —— 先排掉宿主/网络/子仓库类问题；
2. `./rvocs.sh --status` —— 确认源码、构建目录、镜像、设备到底有没有；
3. `tail -f work/logs/build.log`（或子仓库的 `work/logs/build.log`）—— 找**第一个**错误，不要看最后一个；
4. 按本页「层」定位：内核（dmesg）→ 运行时（`rocminfo` / `tt-smi`）→ 编译器（链接/JIT）→ 框架（`import`）→ 引擎（serve）；
5. 修复后固化为补丁（子仓库的 `patches/<arch>/`），而不是手工改构建树。
