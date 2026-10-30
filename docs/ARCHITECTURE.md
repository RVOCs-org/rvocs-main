# 架构与设计取舍

## 1. 调用链

```
rvocs.sh                       ← 唯一入口：解析动作/target/arch，导出环境，分发
  └── scripts/lib/common.sh    ← arch 归一化、代理、子仓库发现、能力校验、镜像 tag
        ├── config/defaults.sh ← 版本/水位/镜像/部署默认值
        └── config/repos.sh    ← target 注册表（目录候选、角色、分支、能力矩阵）

  ├──（只读）scripts/actions/{version,status,doctor,bom}.sh   一次处理全部 target
  └──（写）  scripts/actions/{install,download,build,verify,deploy}.sh
                     │
                     └── 委派：../<子仓库>/scripts/build.sh --arch <arch> --proxy <mode> [--stage ...] [透传]

子仓库内部（各自实现，本仓库不复制）：
  build.sh → NN-阶段.sh → scripts/lib/common.sh → upstream/ 源码 + patches/<arch>/ + docker/ + assets/
```

关键点：**本仓库没有任何编译知识**。它知道的是「哪个仓库、在哪个目录、用哪个动作、传什么参数」，
以及「现在这台机器的前置条件够不够」。

---

## 2. 为什么用平级 sibling，而不用子模块 / vendoring

| 方案 | 问题 |
| --- | --- |
| git submodule | 子仓库源码体积大（tenstorrent 5 GB+、therock 30 GB+），clone 成本高；子仓库自带 `upstream/` 二级子模块，嵌套子模块在 riscv64 上更容易出问题 |
| vendoring（复制进来） | 必然双份漂移；子仓库的 `manifest.yaml`、`baseline.sh`、CI 都以上游 gitlink 为权威，复制后失去意义 |
| 只调用不引用 | 无法保证版本配对，也无法做跨仓库 BOM |
| **平级 sibling（当前）** | 各仓库独立演进与发版；rvocs 只读它们的 git 状态与产物；`RVOCS_<ID>_DIR` 可任意挂载；本地没有时按需 clone **上层仓库**（不含 `upstream/` 源码，源码由各仓库自己的 `fetch` 拉取） |

代价：需要一次目录布局约定（四个仓库同父目录），并由 `--doctor` 显式检查。

---

## 3. 为什么是单分支

所有子仓库都是单分支（`master`）。早期 `tt-stack` 与 `amd-the-rock` 用过 `master` +
`RISCV-Porting` 双分支，但代价是同一改动要在两边各提交一次，容易漂移；现在 riscv64 的差异
（`base` 阶段、SFPI 预检、`patches/riscv64`、`assets/`）都放在同一分支的按架构目录里，
由 `--arch` 在运行时选择。

`rvocs-main` 没有这种需求：

- 本仓库不含补丁（补丁都在子仓库的 `patches/<arch>/`）；
- 架构差异只体现在两类输入：`--arch` 参数 与「子仓库该用哪个分支」——两者都能运行时判定；
- 单分支让 `doctor` / `bom` / `status` 在任何架构、任何子仓库组合下都是同一份代码。

**什么时候才开分支**：当某个架构需要**不同的动作集合或不同的编排顺序**（例如 riscv64 需要
额外的 `bootstrap` 阶段），而不是「参数不同」。届时同步更新本文与 `config/repos.sh`。

---

## 4. target 注册表与能力矩阵

`config/repos.sh` 是唯一事实源，五处声明构成一个 target：

| 函数 | 作用 |
| --- | --- |
| `normalize_target` | 别名 → 规范 id（`amd` → `therock`） |
| `repo_dirs_for` | 目录候选（`tt-host` → `tt-host-master` → `tt-dependency-installer`） |
| `repo_label` / `repo_role` | 人读名称与职责 |
| `repo_porting_branch` | riscv64 需要哪个分支（空 = 不要求） |
| `target_actions` / `target_archs` | 能力矩阵与架构支持 |

扩展一个新 target（例如 `nvidia-cuda`）：

1. 在 `config/repos.sh` 补上五个函数分支；
2. 若动作语义与现有实现不同，加 `scripts/actions/<动作>.sh` 的 `case` 分支（相同则复用）；
3. `manifest.yaml` 加 `targets` 与 `bom` 条目；
4. `docs/REPOS.md` 补一段，`docs/CLI.md` 补参数翻译表。

不需要改 `rvocs.sh`——它按 `$ACTION` 找脚本、按能力矩阵校验。

---

## 5. 动作翻译表（rvocs 提供的最小语义）

| rvocs | 子仓库 | 说明 |
| --- | --- | --- |
| `--arch x86` | `--arch x86_64` | 唯一的重写；其余参数不改 |
| `--proxy auto` | `--proxy auto`（各子仓库自行探测） | 网络决策交给子仓库，rvocs 只转发 |
| `--stage <s>` | `--stage <s>` | 空则用子仓库默认阶段序列 |
| `--download` | therock: `--mode prebuilt --stage fetch`；tenstorrent: `docker pull` | 按 target 语义化 |
| `--verify` | `--stage verify` | 统一「验收」语义 |
| `--deploy` | 无（本仓库生成 docker 命令） | 子仓库只交付镜像，不定义部署参数 |
| `--install` | 无（本仓库解包 + `sudo ./install.sh`） | 子仓库交付包里带安装器 |

「rvocs 会多做一点」的地方只有四处，都是为了把跨仓库的隐形约束显式化：

1. **仓库自动获取**：需要子仓库脚本而本地没有时，clone `master` 到同级目录（`--no-clone` 可关闭）；
2. **部件定位**：`tt-host` 与 `tt-stack` 是同一个厂商仓库的两个部件，入口分别是 `host/scripts/build.sh`
   与 `stack/scripts/build.sh`，pin 与产物也各自在 `host/`、`stack/` 下；
3. **镜像存在性检查**：`--verify` / `--deploy` 前确认本地有镜像，而不是等到容器里报错；
4. **产物发现**：`--install` 先找已下载的 `.deb`，没有则从 Gitee release 拉最新版。

---

## 6. BOM 的权威性链条

```
上游仓库 commit ──gitlink──> 子仓库 manifest.yaml ──抄录──> rvocs-main/manifest.yaml
        （权威）                （人读索引）                （全栈展示，不参与构建）
```

因此：

- 升级基线 = **在各子仓库内**升级 gitlink 并 commit，然后同步 rvocs 的 `manifest.yaml` 与
  `config/defaults.sh` 的镜像 tag；
- `--bom` / `--version` 同时打印「manifest 记录的 pin」与「实时 git 状态」，两者不一致时一眼可见；
- 任何「改 manifest.yaml 就能改构建」的期待都是错的——构建只看各子仓库自己的 gitlink。

---

## 7. 安全与副作用

| 动作 | 副作用 | 保护 |
| --- | --- | --- |
| `--version/--status/--bom/--list-targets` | 无 | — |
| `--doctor` | 无（只读探测） | 不自动修复任何东西 |
| `--download` | 占磁盘、拉网络 | 已有镜像则跳过 |
| `--build` | 长时间占用 CPU/磁盘 | 必须显式 `--target`；`--dry-run` 可预览 |
| `--verify` | 起一次性容器 | 缺镜像时直接报错并给出两条修复命令 |
| `--deploy` | 启动容器 | **默认只打印命令**，`--yes` 才执行；同名容器已存在时拒绝覆盖 |
| `--install` | 加载内核模块、写 `/etc` | 必须 `--yes`；解包到 `work/` 而不是覆盖系统文件 |

---

## 8. 约定清单

| 约定 | 值 |
| --- | --- |
| target id | 小写、`-` 连接（`tt-host`、`tt-stack`、`therock`） |
| 架构名 | 对内一律 `x86_64` / `riscv64` / `aarch64` |
| 环境变量 | `RVOCS_<ID大写>_DIR` |
| 工作区 | `work/`（gitignored），日志 `work/logs/{rvocs,build}.log` |
| 阶段脚本 | `scripts/actions/<动作>.sh`，参数 `<target> [透传...]` |
| 退出码 | `0` 成功；`1` 参数/校验失败、doctor 有 FAIL、子仓库失败 |
| 文档 | 每个动作的行为都要能在 `docs/CLI.md` 找到对应行 |
