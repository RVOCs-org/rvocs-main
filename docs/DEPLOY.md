# rvocs-vllm-tt 推理镜像部署手册（v0.1.0）

> 适用镜像：`rvocs-vllm-tt-amd64:v0.1.0`
> 适用硬件：Tenstorrent N300（单卡双芯片）/ N150 系列；多卡 4×N300（`t3k`，8 ASIC）；宿主机 x86_64 或 riscv64
> 本文目标：在一台**干净机器**上，从拿到镜像到服务可用，全程可复制执行。
> 适用 rvocs-main v1.0.1；`--deploy` 暂未开放，容器启动统一用 `docker run`。

---

## 0. 交付物与版本矩阵

| 项              | 值                                                                                             |
| -------------- | --------------------------------------------------------------------------------------------- |
| 镜像（x86_64）     | `rvocs-vllm-tt-amd64:v0.1.0`                                                                  |
| 镜像（riscv64）    | `rvocs-vllm-tt-riscv64:v0.1.0`(暂未正式测试)                                                        |
| 镜像体积           | 拉取约 3.8 GB，落盘约 15.9 GB                                                                        |
| tt-metal       | v0.79.0-rc11                                                                                  |
| vLLM           | 0.30.0（源码编译）                                                                                  |
| vllm-tt-plugin | d84049e                                                                                       |
| Python / torch | 3.12.15 / 2.14.0+cpu                                                                          |
| 容器内用户 / 工作目录   | `container_app_user` / `/home/container_app_user/app/src`                                     |
| 容器入口           | `bash -c 'source $PYTHON_ENV_DIR/bin/activate && exec python run_vllm_api_server.py "$@" --'` |
| 默认服务端口         | 8000（OpenAI 兼容）                                                                               |

镜像内置 48 个模型规格，常用：

```text
Qwen/Qwen3-8B            Qwen/Qwen3-32B          Qwen/QwQ-32B
Qwen/Qwen2.5-72B(-Instruct)
meta-llama/Llama-3.1-8B(-Instruct)   meta-llama/Llama-3.3-70B-Instruct
deepseek-ai/DeepSeek-R1-0528
openai/gpt-oss-120b
mistralai/Mistral-7B-Instruct-v0.3
google/gemma-3-27b-it
```

`--model` 既接受完整 repo id（`Qwen/Qwen3-8B`），也接受短名（`Qwen3-8B`），后者按 basename 唯一匹配。

---

## 1. 部署前检查清单

在目标机器上逐项确认，任何一项不满足都会导致容器起不来或服务不可用。

### 1.1 硬件与系统

```bash
# 板卡是否被系统识别（应有 /dev/tenstorrent/0、/dev/tenstorrent/1 ...）
ls -l /dev/tenstorrent/

# 驱动模块是否加载
lsmod | grep tenstorrent

# 工具是否就位
which tt-smi tt-flash tt-topology

# 板卡健康与固件
tt-smi -s
```

`tt-smi -s` 应看到 `host_info.Driver`（如 `TT-KMD 2.11.0`）和 `device_info` 数组：
单张 N300 为 2 个 ASIC 条目，4 张 N300（`t3k`）为 8 个；`ls /dev/tenstorrent/` 也应有对应数量的节点。

### 1.2 1G 大页（必须）

容器内固定挂载 `/dev/hugepages-1G`，宿主机必须先准备好：

```bash
# 预留 4 个 1G 大页（=4 GiB）：按模型规模调整，建议 ≥4，大模型用 8
echo 4 | sudo tee /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages

# 挂载 hugetlbfs
sudo mkdir -p /dev/hugepages-1G
sudo mountpoint -q /dev/hugepages-1G || \
  sudo mount -t hugetlbfs -o mode=777,pagesize=1024M none /dev/hugepages-1G

# 确认
cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
mount | grep hugepages-1G
```

> 重启会失效。生产环境请用 `host/` 交付包里的 systemd 单元（`tt-hugepages.service` + `dev-hugepages\x2d1G.mount`）持久化。

### 1.3 设备权限（udev）

容器以非 root 用户 `container_app_user` 运行，设备节点必须是 0666：

```bash
sudo tee /etc/udev/rules.d/99-tenstorrent.rules >/dev/null <<'EOF'
KERNEL=="tenstorrent!*", SUBSYSTEM=="tenstorrent", MODE="0666"
SUBSYSTEM=="tenstorrent", MODE="0666"
KERNEL=="tenstorrent*", MODE="0666"
EOF
sudo udevadm control --reload-rules && sudo udevadm trigger
ls -l /dev/tenstorrent/     # 应为 crw-rw-rw-
```

### 1.4 Docker 与资源

```bash
docker info >/dev/null && echo docker-ok
df -h /var/lib/docker      # 需 ≥25 GB 空闲（镜像 16G + 权重另算）
free -g                    # 建议 ≥32 GB
```

---

## 2. 安装宿主机依赖（三选一）

### 方式 A：仓库一键脚本（推荐）

在 `rvocs-hcs-tenstorrent` 仓库中：

```bash
# 安装驱动(tt-kmd) + 工具(tt-smi/tt-flash/tt-topology) + 1G大页 + udev
./rvocs.sh --target tt-host --arch x86 --install
# riscv64 机器用 --arch riscv

# 自检（无卡机器设备项为 WARN 属正常）
sudo /opt/tt-deps/verify.sh 2>/dev/null || ./host/packaging/verify.sh
```

### 方式 B：.deb 交付包

```bash
# 从 GitHub Releases 获取 rvocs-tt-deps_0.1.0_amd64.deb（riscv64 为 _riscv64.deb）
sudo apt-get install -y ./rvocs-tt-deps_0.1.0_amd64.deb
tt-smi -s
```

### 方式 C：tar.zst 交付包

```bash
tar --zstd -xf rvocs-tt-deps_0.1.0_amd64.tar.zst
cd rvocs-tt-deps_0.1.0_amd64
sudo ./install.sh --check   # 前置检查
sudo ./install.sh           # 安装
./verify.sh
```

> 装完后 `tt-smi` / `tt-flash` / `tt-topology` 直接在 PATH 中，无需激活 venv、无需 sudo。

### 固件（新卡必做）

```bash
tt-smi -r            # 复位设备
# 若提示固件过旧，按仓库 host/docs 说明用 tt-flash 升级后重新复位
```

---

## 3. 获取镜像

### 3.0 用编排层下载（推荐）

```bash
./rvocs.sh --target tt-stack --arch x86 --download     # x86_64
./rvocs.sh --target tt-stack --arch riscv --download   # riscv64
```

下载后本地短名为 `rvocs-vllm-tt-amd64:v0.1.0`（riscv64 为 `-riscv64`），可直接用于下面的 `docker run`。

### 3.1 直接从 SWR 拉取

```bash
IMAGE=swr.cn-east-3.myhuaweicloud.com/cloud-mdgx/rvocs-vllm-tt-amd64:v0.1.0
docker pull "$IMAGE"
docker image inspect "$IMAGE" --format '{{.Id}} {{.Size}}'
```

若仓库为私有，先登录：

```bash
docker login swr.cn-east-3.myhuaweicloud.com -u <用户名>
```

### 3.2 从离线 tar 导入（内网/无网机器）

```bash
docker load -i rvocs-vllm-tt-amd64_v0.1.0.tar
docker images | grep rvocs-vllm-tt
# 如需对齐官方 tag：
docker tag <导入后的镜像ID> swr.cn-east-3.myhuaweicloud.com/cloud-mdgx/rvocs-vllm-tt-amd64:v0.1.0
```

### 3.3 校验

```bash
docker run --rm --entrypoint /bin/bash "$IMAGE" -c \
  'source $PYTHON_ENV_DIR/bin/activate && python -c "import ttnn, vllm; print(ttnn.__file__); print(vllm.__version__)"'
```

期望输出 ttnn 路径与 `0.30.0`。

---

## 4. 准备模型权重

镜像有两种取权重方式，**必须二选一**。

### 4.1 在线模式（机器可访问 HuggingFace）

不设 `MODEL_WEIGHTS_DIR` 时，wrapper 会自动下载到 `cache_root/weights/<model_name>`：

- 需要外网可达 `huggingface.co`；受限网络可设 `HF_ENDPOINT=https://hf-mirror.com`
- gated 模型（Llama / gemma）需要 `HF_TOKEN`

### 4.2 离线模式（推荐用于内网）——预置标准 HF cache

关键点：**vLLM 只认标准 HF cache 目录结构**，不是随便一个权重文件夹。目录必须是：

```text
/data/models/
└── models--Qwen--Qwen3-8B/
    ├── blobs/                                  # 真实权重文件（大文件放这里）
    ├── refs/
    │   └── main                                # 内容为一个 commit/revision 字符串
    └── snapshots/
        └── b968826d9c46dd6066d109eabc6255188de91218/
            ├── config.json -> ../../blobs/...
            ├── tokenizer.json -> ../../blobs/...
            ├── merges.txt -> ../../blobs/...
            ├── vocab.json -> ../../blobs/...
            ├── model-00001-of-00005.safetensors -> ../../blobs/...
            └── ...（snapshots 下全是软链，指向 blobs）
```

> 目录名规则：`models--<org>--<name>`，org/name 中的 `/` 换成 `--`。

**最省事的做法**：在一台能联网的机器上用 huggingface-cli 下载，`HF_HUB_CACHE` 指向此目录：

```bash
# 联网机器
export HF_ENDPOINT=https://hf-mirror.com
pip install -U huggingface_hub
HF_HUB_CACHE=/data/models huggingface-cli download Qwen/Qwen3-8B
# 然后把整个 /data/models 同步到目标机器
```

下载完成后校验结构：

```bash
ls -l /data/models/models--Qwen--Qwen3-8B/snapshots/*/ | head
cat /data/models/models--Qwen--Qwen3-8B/refs/main
du -sh /data/models/models--Qwen--Qwen3-8B
```

> 若你手上只有普通权重目录（`config.json` + `*.safetensors` 平铺），也可用「本地路径直供」方式，见 6.3。

---

## 5. 编写 .env

在宿主机创建一个 env 文件，例如 `/opt/tt/tt-infer.env`。

### 5.1 离线模式（内网，推荐）

```bash
sudo mkdir -p /opt/tt
sudo tee /opt/tt/tt-infer.env >/dev/null <<'EOF'
# ---- 强制离线，禁止访问 HuggingFace ----
HF_HUB_OFFLINE=1
TRANSFORMERS_OFFLINE=1

# ---- 告诉 vLLM 去哪找标准 HF cache（关键！）----
HF_HUB_CACHE=/data/models

# ---- 鉴权：二者只设一个 ----
# 方式一：直接用固定 API Key（推荐，简单）
VLLM_API_KEY=sk-rvocs-0123456789
# 方式二：用 JWT_SECRET（调用方需自己签 JWT）
# JWT_SECRET=testing

# ---- 可选 ----
# HF_TOKEN=hf_xxx
# HF_ENDPOINT=https://hf-mirror.com
EOF
sudo chmod 600 /opt/tt/tt-infer.env
```

### 5.2 在线模式

```bash
sudo tee /opt/tt/tt-infer.env >/dev/null <<'EOF'
HF_ENDPOINT=https://hf-mirror.com
HF_TOKEN=hf_xxxxxxxxxxxxxxxx
VLLM_API_KEY=sk-rvocs-0123456789
EOF
```

### 5.3 鉴权语义（务必理解，否则必踩 401）

镜像 `handle_secrets()` 的优先级：

1. 传 `--no-auth` → 关闭鉴权，`Authorization` 头不校验
2. 设了 `VLLM_API_KEY` → **它本身就是 Bearer token 的字面量**
   → 请求头 `Authorization: Bearer sk-rvocs-0123456789`
3. 未设 `VLLM_API_KEY`，设了 `JWT_SECRET` → wrapper 期望 JWT（HS256）
   
   ```python
   jwt.encode({"team_id": "tenstorrent", "token_id": "debug-test"}, JWT_SECRET, algorithm="HS256")
   ```
4. 两者都没设 → 无鉴权，但日志会告警

> 同时设了 `VLLM_API_KEY` 和 `JWT_SECRET` 时，**`VLLM_API_KEY` 生效**，用 JWT 会 401。

---

## 6. docker run 命令

### 6.1 标准离线启动（推荐模板）

> 若镜像已用 `--download` 拉到本地，可把 `IMAGE` 换成短名 `rvocs-vllm-tt-amd64:v0.1.0`。

```bash
IMAGE=swr.cn-east-3.myhuaweicloud.com/cloud-mdgx/rvocs-vllm-tt-amd64:v0.1.0

docker run -d \
  --name tt-vllm \
  --restart unless-stopped \
  --env-file /opt/tt/tt-infer.env \
  --ipc host \
  --device /dev/tenstorrent:/dev/tenstorrent \
  --mount type=bind,src=/dev/hugepages-1G,dst=/dev/hugepages-1G \
  --publish 0.0.0.0:8000:8000 \
  --volume /data/models:/data/models:ro \
  --volume tt-cache-Qwen3-8B:/home/container_app_user/cache_root \
  "$IMAGE" \
  --model Qwen/Qwen3-8B \
  --tt-device n300
```

> 单卡用 `n300`；4 张 n300 用 `t3k`（8 ASIC，TP=8），见 6.5。

### 6.2 在线启动（自动下载权重）

去掉 `/data/models` 挂载与离线变量即可：

```bash
docker run -d \
  --name tt-vllm \
  --env-file /opt/tt/tt-infer.env \
  --ipc host \
  --device /dev/tenstorrent:/dev/tenstorrent \
  --mount type=bind,src=/dev/hugepages-1G,dst=/dev/hugepages-1G \
  --publish 0.0.0.0:8000:8000 \
  --volume tt-cache-Qwen3-8B:/home/container_app_user/cache_root \
  "$IMAGE" \
  --model Qwen3-8B --tt-device n300
```

### 6.3 本地权重目录直供（没有标准 HF cache 时）

把权重目录直接挂进去，并用 `MODEL_WEIGHTS_DIR` 指定：

```bash
docker run -d --name tt-vllm \
  --env-file /opt/tt/tt-infer.env \
  --ipc host \
  --device /dev/tenstorrent:/dev/tenstorrent \
  --mount type=bind,src=/dev/hugepages-1G,dst=/dev/hugepages-1G \
  --publish 0.0.0.0:8000:8000 \
  --volume tt-cache-Qwen3-8B:/home/container_app_user/cache_root \
  --mount type=bind,src=/srv/weights/Qwen3-8B,dst=/home/container_app_user/readonly_weights_mount/Qwen3-8B,readonly \
  -e MODEL_WEIGHTS_DIR=/home/container_app_user/readonly_weights_mount/Qwen3-8B \
  "$IMAGE" \
  --model Qwen/Qwen3-8B --tt-device n300
```

> 注意：此方式下 vLLM 仍会用 `--model Qwen/Qwen3-8B` 解析 `config.json`。若目标是完全离线，仍建议同时设 `HF_HUB_CACHE` 指向标准 cache，或把 `--model` 换成容器内本地路径（wrapper 按 basename 仍能匹配到 model spec）。

### 6.4 参数逐条说明

| 参数                          | 必要性    | 说明                                                 |
| --------------------------- | ------ | -------------------------------------------------- |
| `--env-file`                | **必须** | 离线变量与鉴权变量都靠它注入；漏了就会去联网拉 `config.json`              |
| `--ipc host`                | **必须** | tt-metal 需要共享内存                                    |
| `--device /dev/tenstorrent` | **必须** | 暴露板卡字符设备                                           |
| `--mount .../hugepages-1G`  | **必须** | tt-metal 使用 1G 大页                                  |
| `--publish 8000:8000`       | 建议     | OpenAI 兼容 API 端口                                   |
| `--volume /data/models:ro`  | 离线必须   | 只读挂载标准 HF cache                                    |
| `--volume ...cache_root`    | **必须** | 模型权重缓存 + tt-metal kernel 编译缓存 + 日志；不持久化会导致每次重启重新编译 |
| `--name` + `--restart`      | 建议     | 便于运维与自愈                                            |
| `--model`                   | **必须** | repo id 或短名                                        |
| `--tt-device`               | **必须** | `n300`（单卡双 die）/ `n150` / `t3k`（**4×N300=8 ASIC，TP=8**）/ `galaxy`（多机） |
| `--disable-trace-capture`   | 可选     | 关闭 trace capture，调试/省内存时可加                         |

### 6.5 多卡：4×n300（t3k，TP=8）

4 张 n300 一共 8 个 ASIC（每张 2 die）。`--tt-device t3k` 会选择 8 芯片的 T3K 拓扑，
vLLM 以 **TP=8** 启动，不需要再传 `--tensor-parallel-size`。

```bash
# 4 张 n300 = 8 ASIC；模型需要在 model_spec.json 的 T3K 段有规格
docker run -d --name tt-vllm-t3k \
  --restart unless-stopped \
  --env-file /opt/tt/tt-infer.env \
  --ipc host \
  --device /dev/tenstorrent:/dev/tenstorrent \
  --mount type=bind,src=/dev/hugepages-1G,dst=/dev/hugepages-1G \
  --publish 0.0.0.0:8000:8000 \
  --volume /data/models:/data/models:ro \
  --volume tt-cache-t3k:/home/container_app_user/cache_root \
  "$IMAGE" \
  --model Qwen/Qwen3-32B \
  --tt-device t3k
```

注意事项：

- 先确认 8 个设备节点都在：`ls /dev/tenstorrent/`（应为 0–7）；`tt-smi -s` 的 `device_info` 应有 8 条。
- 1G 大页按 8 卡规模准备（建议 ≥8 页，见 1.2 节）。
- `t3k` 适合 32B / 70B / 120B 级别的模型；小模型（如 `Qwen3-8B`）在 4 张卡上不会自动吃满 8 个 ASIC。
  验证多卡吞吐请选 `Qwen/Qwen3-32B`、`meta-llama/Llama-3.3-70B-Instruct`、`openai/gpt-oss-120b` 等
  （镜像内 `model_spec.json` 的 `T3K` 段有对应规格）。
- 日志中应出现 `MESH_DEVICE=T3K`；`/v1/models` 返回 200 后再压测。

### 6.6 其它常用变体

```bash
# 换端口 + 关闭鉴权（仅内网测试）
... --publish 0.0.0.0:9000:8000 --env-file /opt/tt/tt-infer.env ... --no-auth

# 限制上下文与并发（默认 max_model_len=40960, max_num_seqs=32）
... "$IMAGE" --model Qwen/Qwen3-8B --tt-device n300 \
    --max-model-len 8192 --max-num-seqs 8

# 前台运行便于看日志（调试）
docker run --rm ... （去掉 -d）
```

---

## 7. 验证服务

### 7.1 等待就绪

首次启动需要编译 tt-metal kernels，**约 2–5 分钟**，`/health` 才会返回 200。

```bash
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/health)
  echo "$((i*5))s health=$code"
  [ "$code" = "200" ] && break
  sleep 5
done
```

同时观察日志确认**没有**联网行为：

```bash
docker logs tt-vllm 2>&1 | grep -iE 'replace model_id|Application startup complete|Uvicorn running|Network is unreachable|LocalEntryNotFound'
```

正常离线启动会看到：

```text
HF_HUB_OFFLINE is True, replace model_id [Qwen/Qwen3-8B] to model_path [/data/models/models--Qwen--Qwen3-8B/snapshots/<rev>]
```

### 7.2 列模型

```bash
export TT_API_KEY=sk-rvocs-0123456789      # 与 .env 中 VLLM_API_KEY 一致；无鉴权则省略该头
curl -s http://127.0.0.1:8000/v1/models -H "Authorization: Bearer $TT_API_KEY" | python3 -m json.tool
```

记下返回的 `data[0].id`（即 `served_model_name`），后续请求用它。

### 7.3 Chat / Completion 冒烟

```bash
curl -s http://127.0.0.1:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TT_API_KEY" \
  -d '{"model":"Qwen/Qwen3-8B","messages":[{"role":"user","content":"用一句话介绍你自己"}],"max_tokens":64,"temperature":0}' \
  | python3 -m json.tool
```

期望得到正常文本与 `usage` 统计。

### 7.4 流式

```bash
curl -N http://127.0.0.1:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TT_API_KEY" \
  -d '{"model":"Qwen/Qwen3-8B","messages":[{"role":"user","content":"数到10"}],"stream":true,"max_tokens":64}'
```

---

## 8. 故障排查

| 现象                                                                           | 根因                            | 解决                                                                                    |
| ---------------------------------------------------------------------------- | ----------------------------- | ------------------------------------------------------------------------------------- |
| `[Errno 101] Network is unreachable ... huggingface.co/.../config.json`      | 缺离线变量，vLLM 试图联网               | 补 `--env-file`，内含 `HF_HUB_OFFLINE=1` + `HF_HUB_CACHE=/data/models`，并挂载 `/data/models` |
| `LocalEntryNotFoundError: Cannot find an appropriate cached snapshot folder` | 设了 offline 但没告诉 vLLM cache 位置 | 设 `HF_HUB_CACHE=/data/models`，确认 `models--Qwen--Qwen3-8B/snapshots/<rev>/` 存在         |
| `{"error":"Unauthorized"}`                                                   | 鉴权方式不匹配                       | 同时设了 `VLLM_API_KEY` 与 `JWT_SECRET` 时用字面量 key；只想用 JWT 就删掉 `VLLM_API_KEY`               |
| 容器秒退，日志 `Exited (1)`                                                         | 参数/模型名错误                      | `docker logs --tail 100 tt-vllm`                                                      |
| `could not select device driver` / 找不到 `/dev/tenstorrent/0`                  | 驱动未加载或设备未出现                   | `modprobe tenstorrent`；检查 DKMS 是否装好；`tt-smi -s`                                       |
| `Permission denied` 访问 `/dev/tenstorrent/*`                                  | udev 规则未生效                    | 重新安装 0666 规则并 `udevadm trigger`                                                       |
| 启动卡住 / OOM / `HugePages_Total: 0`                                            | 未预留 1G 大页                     | 按 1.2 节设置 `nr_hugepages` 并挂载                                                          |
| `/health` 长时间不返回但容器 running                                                  | 正在编译 kernel（首次 2–5 分钟）        | 耐心等待；确认 cache_root 卷已持久化，二次启动会快很多                                                     |
| 端口被占用                                                                        | 8000 已被占用                     | `--publish 8001:8000` 换宿主端口                                                           |
| `Physical chip id X not found in control plane chip mapping`                 | 拓扑/固件状态异常                     | `tt-smi -r` 复位；必要时断电冷启动；`tt-topology -ls` 检查                                          |

### 8.1 收集诊断信息

```bash
docker ps -a --filter name=tt-vllm
docker logs --tail 200 tt-vllm
docker inspect tt-vllm --format '{{json .HostConfig.Binds}}{{"\n"}}{{json .HostConfig.Devices}}'
tt-smi -s
dmesg -T | grep -iE 'tenstorrent|wormhole' | tail -40
```

---

## 9. 运维操作

### 9.1 停止 / 启动 / 重启

```bash
docker stop tt-vllm
docker start tt-vllm
docker restart tt-vllm
docker rm -f tt-vllm          # 删除容器（cache 卷保留）
```

### 9.2 更新镜像

```bash
docker pull swr.cn-east-3.myhuaweicloud.com/cloud-mdgx/rvocs-vllm-tt-amd64:v0.1.0
docker rm -f tt-vllm
# 用 6.1 的命令重新 run（cache 卷可复用，kernel 缓存仍有效）
```

### 9.3 清理

```bash
docker volume ls | grep tt-cache
docker volume rm tt-cache-Qwen3-8B     # 仅确认不再需要 kernel 缓存/权重时
docker image prune
```

### 9.4 日志与缓存位置

| 内容                 | 位置                                                     |
| ------------------ | ------------------------------------------------------ |
| 容器 stdout          | `docker logs tt-vllm`                                  |
| vLLM 日志文件          | 卷内 `cache_root/logs/vllm_*.log`                        |
| tt-metal kernel 缓存 | 卷内 `cache_root/tt_metal_cache/cache_<model>/<device>/` |
| 权重（在线下载时）          | 卷内 `cache_root/weights/<model>/`                       |

---

## 10. 附录

### 10.1 容器内关键路径

```text
/home/container_app_user/app/src                    # 工作目录 / wrapper 所在
/home/container_app_user/tt-metal                   # TT-Metal / TT-NN
/home/container_app_user/vllm-tt-plugin             # vLLM TT 插件
/home/container_app_user/model_specs/model_spec.json# 48 个模型规格
/home/container_app_user/cache_root                 # 缓存卷挂载点
/home/container_app_user/readonly_weights_mount     # 只读权重挂载点
```

### 10.2 环境变量速查

| 变量                     | 作用                                            | 离线必备 |
| ---------------------- | --------------------------------------------- | ---- |
| `HF_HUB_OFFLINE`       | 禁止访问 HF Hub                                   | ✅    |
| `TRANSFORMERS_OFFLINE` | transformers 离线                               | ✅    |
| `HF_HUB_CACHE`         | 标准 HF cache 根目录（`models--*` 的父目录）             | ✅    |
| `MODEL_WEIGHTS_DIR`    | 直接指定权重目录                                      | 可选   |
| `HF_TOKEN`             | 访问 gated 模型                                   | 在线可选 |
| `HF_ENDPOINT`          | 换 HF 镜像站（如 `https://hf-mirror.com`）           | 在线可选 |
| `VLLM_API_KEY`         | 固定 Bearer token（字面量）                          | 鉴权用  |
| `JWT_SECRET`           | JWT（HS256）签名密钥                                | 鉴权用  |
| `TT_METAL_HOME`        | 镜像内已固定为 `/home/container_app_user/tt-metal`   | 镜像内置 |
| `CACHE_ROOT`           | 镜像内已固定为 `/home/container_app_user/cache_root` | 镜像内置 |

### 10.3 一键部署脚本（可直接保存使用）

```bash
#!/usr/bin/env bash
# deploy_tt.sh —— 干净机器上一键部署 rvocs-vllm-tt
set -euo pipefail

IMAGE="${IMAGE:-swr.cn-east-3.myhuaweicloud.com/cloud-mdgx/rvocs-vllm-tt-amd64:v0.1.0}"
MODEL="${MODEL:-Qwen/Qwen3-8B}"
DEVICE="${DEVICE:-n300}"
MODELS_ROOT="${MODELS_ROOT:-/data/models}"
ENVF="${ENVF:-/opt/tt/tt-infer.env}"
API_KEY="${API_KEY:-sk-rvocs-0123456789}"
NAME="${NAME:-tt-vllm}"
PORT="${PORT:-8000}"

echo "[1/6] 检查 Docker"; docker info >/dev/null || { echo "docker 不可用"; exit 1; }
echo "[2/6] 检查设备"; ls /dev/tenstorrent/* >/dev/null 2>&1 || { echo "未发现 /dev/tenstorrent/*"; exit 1; }
echo "[3/6] 配置 1G 大页"
echo 4 | sudo tee /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages >/dev/null || true
sudo mkdir -p /dev/hugepages-1G
sudo mountpoint -q /dev/hugepages-1G || sudo mount -t hugetlbfs -o mode=777,pagesize=1024M none /dev/hugepages-1G

echo "[4/6] 写 env 文件"
sudo mkdir -p "$(dirname "$ENVF")"
sudo tee "$ENVF" >/dev/null <<EOF
HF_HUB_OFFLINE=1
TRANSFORMERS_OFFLINE=1
HF_HUB_CACHE=$MODELS_ROOT
VLLM_API_KEY=$API_KEY
EOF
sudo chmod 600 "$ENVF"

echo "[5/6] 拉镜像（本地已存在则跳过）"
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull "$IMAGE"

echo "[6/6] 启动容器"
docker rm -f "$NAME" >/dev/null 2>&1 || true
VOL="tt-cache-$(echo "$MODEL" | tr '/:' '--')"
docker run -d --name "$NAME" --restart unless-stopped \
  --env-file "$ENVF" --ipc host \
  --device /dev/tenstorrent:/dev/tenstorrent \
  --mount type=bind,src=/dev/hugepages-1G,dst=/dev/hugepages-1G \
  --publish "0.0.0.0:${PORT}:8000" \
  --volume "$MODELS_ROOT:$MODELS_ROOT:ro" \
  --volume "$VOL":/home/container_app_user/cache_root \
  "$IMAGE" --model "$MODEL" --tt-device "$DEVICE" >/dev/null

echo "等待服务就绪（首次约 2-5 分钟）..."
for i in $(seq 1 90); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/health" || true)
  [ "$code" = "200" ] && { echo "READY at $((i*5))s"; break; }
  sleep 5
done
curl -s "http://127.0.0.1:${PORT}/v1/models" -H "Authorization: Bearer $API_KEY" | head -c 300; echo
```

---

## 11. 最小检查清单（打印版）

```text
[ ] lsmod | grep tenstorrent            # 驱动加载
[ ] ls /dev/tenstorrent/                # 设备节点存在且 0666
[ ] cat /sys/.../hugepages-1048576kB/nr_hugepages   # ≥4
[ ] mount | grep hugepages-1G           # 已挂载
[ ] docker info                         # Docker 可用
[ ] docker pull $IMAGE                  # 镜像已就位
[ ] /data/models/models--Qwen--Qwen3-8B/snapshots/<rev>/config.json   # 离线权重就绪
[ ] /opt/tt/tt-infer.env                # 含 HF_HUB_OFFLINE / HF_HUB_CACHE / VLLM_API_KEY
[ ] docker run ...                      # 按第 6 章
[ ] curl /health == 200                 # 就绪
[ ] curl /v1/chat/completions 有输出    # 推理正常
```
