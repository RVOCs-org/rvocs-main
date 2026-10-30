<div align="center">

# RVOCs

**RISC-V Open Computing System · an open heterogeneous AI software stack**

From kernel drivers to model serving: cross-architecture adaptation captured as reusable
patches, build pipelines and deliverable images. RISC-V is the starting point, not the limit.

English | [简体中文](INTRODUCTION.md)

[Quick start](#-quick-start) · [Architecture](#-architecture) · [Support](#-support-matrix) · [Release notes](https://gitee.com/rvocs/rvocs-main/blob/master/RELEASENOTES.md) · [Contributing](#-contributing)

</div>

---

## 🧭 What RVOCs is

RVOCs (RISC-V Open Computing System) is a hardware-plus-software open computing system:
a RISC-V server acts as the host, and the full AI inference stack — drivers, runtime,
compilers, frameworks, inference engine — runs on the attached GPU/NPU accelerators and is
served through an OpenAI-compatible API.

Core capabilities:

- **One command, whole stack**: `rvocs.sh` is the single entry point —
  doctor → install (host packages) → download/build (images) → verify → deploy.
  Stages are separable and resumable.
- **Cross-architecture, cross-distribution**: architecture differences live in
  `patches/<arch>/`, distribution differences in the host packaging layer (`host/`).
  Ubuntu 26.04 LTS is the reference system today; Fedora / RHEL / openRuyi plug into the
  same model without changing the CLI.
- **Patches are the asset**: adaptation is not sprinkled through application code; it is a
  reviewable, replayable patch series per vendor repository, upstreamable.
- **Traceable versions**: `<repo>/VERSION` + `manifest.yaml` (upstream pins) + gitlinks stay
  in sync; `baseline.sh` switches a baseline in one command and `--bom` prints the matrix.
- **Artifacts ready to use**: images are published to a public Huawei Cloud SWR namespace,
  host `.deb` packages to Gitee Releases; `--download` leaves a consistently named artifact
  on the local machine.
- **Accelerator-agnostic interface**: vendor repositories follow `rvocs-hcs-{vendor}`; a new
  device needs a capability matrix in the target registry, with unchanged action semantics.

> RVOCs provides the validated RISC-V compute base. Resource orchestration and model serving
> on top of it are built by platforms such as RISMA.

## 🏗 Architecture

**Six software layers** — upper layers consume model APIs, lower layers are provided by each
device software stack:

| Layer | Content | AMD reference | Tenstorrent path |
|---|---|---|---|
| L6 Application / service | OpenAI-compatible API | vLLM serve | vLLM serve |
| L5 Inference engine | continuous batching / PagedAttention | vLLM | vLLM + vllm-tt-plugin |
| L4 Deep-learning framework | training & inference | PyTorch (ROCm backend) | PyTorch (CPU) + TT-NN |
| L3 Compilers & kernel libraries | device code generation | LLVM / Comgr · Triton · rocBLAS | TT-Metalium · sfpi |
| L2 User-space runtime | device call abstraction | ROCr · HIP | TT-UMD |
| L1 Kernel driver & device access | enumeration / mapping / DMA | AMDGPU · AMDKFD · IOMMU | tt-kmd |
| L0 Host & distribution | kernel, toolchain, packaging, device nodes | Ubuntu 26.04 LTS (supported) · Fedora / RHEL / openRuyi (in progress) | same |

**One orchestrator, vendor repositories evolving independently**:

```
┌─────────────────────────────────────────────────────────────┐
│                    rvocs-main (single entry)                │
│         rvocs.sh  doctor/install/download/build/            │
│                  verify/deploy/version/bom                  │
└──────────────┬──────────────────────────────┬───────────────┘
               ▼                              ▼
┌──────────────────────────────┐  ┌──────────────────────────┐
│   rvocs-hcs-tenstorrent      │  │      rvocs-hcs-amd       │
│  ┌────────┐   ┌───────────┐  │  │  ROCm/TheRock + vLLM    │
│  │ host/  │   │  stack/   │  │  │  image (patches/riscv64/ │
│  │ tt-kmd │ + │ TT-Metal  │  │  │  layer, single branch)   │
│  │ tools  │   │ + vLLM    │  │  └──────────────────────────┘
│  └────────┘   └───────────┘  │
└──────────────────────────────┘
        ▼ artifacts (uniform naming, delivered after acceptance)
┌─────────────────────────────────────────────────────────────┐
│  rvocs-vllm-tt-riscv64:v0.1.0        (public SWR namespace) │
│  rvocs-vllm-therock10.0-r9700-riscv64:v0.1.0                │
│  rvocs-tt-deps_v0.1.0_riscv64.deb    (Gitee Releases)       │
└─────────────────────────────────────────────────────────────┘
```

Design trade-offs and the target integration mechanism:
[docs/ARCHITECTURE.md](https://gitee.com/rvocs/rvocs-main/blob/master/docs/ARCHITECTURE.md).

## 📦 Support matrix

| Stack / path | Target device | riscv64 | x86_64 | aarch64 | Public status |
|---|---|---|---|---|---|
| AMD ROCm / TheRock | Radeon AI PRO R9700 (gfx1201) — current reference | ✅ supported | 🔲 pending | 🔲 TBD | ✅ end-to-end LLM validated |
| Tenstorrent TT-Metal / TT-NN | Wormhole / Blackhole family (n300, …) | 🔶 in progress | ✅ supported | 🔲 TBD | 🔶 component acceptance pass, end-to-end pending real-card validation |
| CUDA / domestic accelerators | per-device adaptation | 🔲 TBD | 🔲 TBD | 🔲 TBD | 🔲 target extension reserved |

Each architecture column shows the state of that stack on that host architecture: **supported** = builds and deploys; **in progress** = build and component acceptance pass with end-to-end validation underway; **pending / TBD** = not ported yet.

Architectures: **riscv64 / x86_64 / aarch64** (target arch must match the host; no cross builds).

**Inference engine**: **vLLM** today (PagedAttention + continuous batching), selected with
`--engine`; **llama.cpp** (CPU / edge, no accelerator needed) and **SGLang** (prefix caching,
multi-turn and structured generation) are planned and not available yet.

**Operating systems**: **Ubuntu 26.04 LTS** is the reference (validated on riscv64 and
x86_64). **Fedora**, **Red Hat Enterprise Linux** and **openRuyi** are in progress; the
differences are absorbed by the host packaging layer and the patch layers, so `rvocs.sh`
actions and artifact naming stay the same.

The eight-card server is a hardware capability; multi-card validation is in progress.

## 🚀 Quick start

### Prerequisites

1. A Linux host of the target architecture (riscv64 / x86_64 / aarch64), Ubuntu 24.04 / 26.04.
2. The accelerator: AMD needs a riscv64 kernel ≥ `7.0.0-31-generic` (older kernels ship a
   broken amdgpu); Tenstorrent needs its driver first.
3. Docker (build and deployment); installing drivers requires sudo.

### ① Fetch the entry point and self-check

```bash
git clone https://gitee.com/rvocs/rvocs-main.git
cd rvocs-main
./rvocs.sh --doctor        # PASS/WARN/FAIL plus the commands to run next
```

### ② Install host dependencies (Tenstorrent path)

```bash
# downloads the newest .deb from Releases and installs it
# (tt-kmd driver + tt-smi/tt-flash/tt-topology + 1G hugepages)
./rvocs.sh --target tt-host --arch riscv --install --yes
```

### ③ Fetch images and verify

```bash
# AMD path (reference): pull the published image, or build from source (~20 h first time)
./rvocs.sh --target therock --arch riscv --download     # rvocs-vllm-therock10.0-r9700-riscv64:v0.1.0
./rvocs.sh --target therock --arch riscv --build

# Tenstorrent path
./rvocs.sh --target tt-stack --arch riscv --download # rvocs-vllm-tt-riscv64:v0.1.0
./rvocs.sh --target tt-stack --arch riscv --verify
```

A single image can also be pulled by tag:
`./rvocs.sh --download rvocs-vllm-tt-riscv64:v0.1.0`.

### ④ Start the OpenAI-compatible service

```bash
./rvocs.sh --target tt-stack --deploy --dry-run   # preview the run command
./rvocs.sh --target tt-stack --deploy --yes       # start (default model Qwen3-8B, port 8000)
```

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "Qwen3-8B", "messages": [{"role": "user", "content": "hello, RVOCs"}]}'
```

More paths (GPU smoke test, offline install, proxy modes):
[docs/QUICKSTART.md](https://gitee.com/rvocs/rvocs-main/blob/master/docs/QUICKSTART.md).

## 📚 Documentation

| Document | Content |
|---|---|
| [Quick start](https://gitee.com/rvocs/rvocs-main/blob/master/docs/QUICKSTART.md) | scenario walkthroughs: self-check, drivers, images, deployment |
| [CLI reference](https://gitee.com/rvocs/rvocs-main/blob/master/docs/CLI.md) | every action, option and environment variable |
| [Architecture](https://gitee.com/rvocs/rvocs-main/blob/master/docs/ARCHITECTURE.md) | layering and target integration trade-offs |
| [Repositories](https://gitee.com/rvocs/rvocs-main/blob/master/docs/REPOS.md) | responsibilities and artifacts per repository |
| [Known quirks](https://gitee.com/rvocs/rvocs-main/blob/master/docs/QUIRKS.md) | RISC-V issues and workarounds |
| [Release notes](https://gitee.com/rvocs/rvocs-main/blob/master/RELEASENOTES.md) | published artifacts and upstream baselines |

## 🤝 Contributing

File an issue, share a reproduction, submit an architecture patch or a new target — keep
verifiable engineering experience in public code and documentation.

- **Issues**: [rvocs-main issues](https://gitee.com/rvocs/rvocs-main/issues)
- **New accelerator**: create `rvocs-hcs-{vendor}` with `host/` + `stack/`, then declare the
  capability matrix in the target registry
- **Baseline bump**: edit `ref` in `manifest.yaml` → `baseline.sh apply` → replay patches →
  commit (see each repository's README)

## 📄 License

The orchestration code in `rvocs-main` is Apache-2.0; vendor repositories and upstream
components keep their own licenses.

<div align="center">

**RVOCs · RISC-V Open Computing System · Yuanshi Zhisuan**

[Gitee organization](https://gitee.com/rvocs) · Let the next port start from what already works.

</div>
