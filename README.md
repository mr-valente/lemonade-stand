# 🍋 Lemonade Stand

A **server-first** Docker image for [Lemonade Server](https://lemonade-server.ai/) with full AMD acceleration support (ROCm, Vulkan, NPU).

Lemonade ships with a desktop GUI, but this image is for users who prefer to run Lemonade as a headless server. It includes the Linux browser Web UI, plus Fish shell with a Starship prompt and custom shell functions that enhance the existing `lemonade` CLI and wrap common API calls for ergonomic, interactive model management.

- **Docker Hub:** [valentemath/lemonade-stand](https://hub.docker.com/r/valentemath/lemonade-stand)
- **Lemonade SDK:** [github.com/lemonade-sdk/lemonade](https://github.com/lemonade-sdk/lemonade)
- **Lemonade Server CLI docs:** [lemonade-server.ai/docs/guide/cli](https://lemonade-server.ai/docs/guide/cli/)

## Features

- **Server-first, no desktop GUI** — Designed for headless deployment with Docker.
- **Built from source** — Lemonade Server is compiled inside the image, always up to date.
- **Built-in browser Web UI** — Served from the Lemonade HTTP port.
- **AMD hardware acceleration** — ROCm and Vulkan for discrete/integrated GPUs, and XRT + AMDXDNA for NPU inference.
- **Container backends** — Lemonade's Strix Halo engines (Gufo, Halogen, ROCm FPX, DwarfStar4 and two llama.cpp forks) run on the host's Docker daemon, with a `preflight` check, GPU group alignment, and cleanup built in.
- **Fish shell + Starship prompt** — A polished terminal environment for interactive model management.
- **Enhanced model management** — `pull`, `fastpull`, `load`, `unload`, `update`, and `delete` add safer workflows and live tab completion around Lemonade's API and CLI. See [Managing models](docs/models.md).
- **Declarative backends** — Mark backends in `config.json` and `install --all` brings them up to date after every image upgrade.

## Prerequisites

- **Docker** (with Docker Compose)
- **AMD GPU or APU** — with a kernel that provides `/dev/kfd` and `/dev/dri`
- **NPU access** *(experimental)* — the host kernel must have the `amdxdna` module loaded

## Quick start

### 1. Create a `docker-compose.yml`

```yaml
services:
  lemonade-stand:
    image: valentemath/lemonade-stand:latest
    container_name: lemonade-stand
    network_mode: host
    devices:
      - /dev/kfd:/dev/kfd
      - /dev/dri:/dev/dri
      # - /dev/accel:/dev/accel  # Uncomment for NPU access
    volumes:
      # Model weights, at the same path inside and outside the container
      - /srv/lemonade/huggingface:/srv/lemonade/huggingface
      - /srv/lemonade/config:/root/.cache/lemonade
      - /srv/lemonade/fish:/root/.local/share/fish
      # Lets Lemonade run container backends on the host's Docker daemon
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - HF_HOME=/srv/lemonade/huggingface
      - LEMONADE_HOST=0.0.0.0
    stop_grace_period: 60s
    restart: unless-stopped
```

Host networking, the Docker socket, and the same-path model mount are what
[container backends](docs/container-backends.md) need. Each line is explained in
the [setup reference](docs/setup.md).

### 2. Start the container

```bash
docker compose up -d
```

Open the Web UI at `http://localhost:13305`, or connect to the shell:

```bash
docker exec -it lemonade-stand fish
```

### 3. Install backends and run a model

```fish
preflight                                  # confirm container backends can run
lemonade config set llamacpp.backend=rocm  # recommended default on Strix Halo
install llamacpp rocm                      # Tab completes recipes and backends

pull unsloth/Qwen3.8-27B-GGUF              # choose a quant; include its MTP file
load user.Qwen3.8-27B-GGUF-UD-Q4_K_XL      # load the registered model
unload user.Qwen3.8-27B-GGUF-UD-Q4_K_XL    # free the model
```

## Container backends

Lemonade can run a model's engine from a container image instead of a downloaded
binary. All six are built for Strix Halo (`gfx1151`) and install like any other
backend, for example `install rocmfpx`.

| Backend | What it is | Runs | Verdict |
| :--- | :--- | :--- | :--- |
| `gufo:rocm` | Open-source engine with kernels written per model for Strix Halo | A few top models, from ordinary GGUFs: Qwen3.8-27B, Qwen3.8-Flash-Next, DeepSeek-V4-Flash | **Run it.** Fastest on every measure for the models it covers |
| `rocmfpx:rocm` | llama.cpp fork with ROCmFP4/6/8 weight formats and MTP drafting | Its own ROCmFP4 builds: Qwen3.8-27B, Qwen3.6-35B-A3B, Gemma-4-26B-A4B | **Run it** for those models; faster and lighter than stock llama.cpp |
| `llamacpp:nathanw` | llama.cpp fork tuned for Strix Halo's Vulkan driver | Any GGUF | Situational: quickest llama.cpp on long prompts, slowest at generating |
| `llamacpp:halobox` | Community llama.cpp fork on a custom ROCm runtime | Any GGUF | Skip: no gain over the built-in ROCm backend |
| `halogen:rocm` | Free, proprietary agent engine with per-model kernels and a 262K context | Qwen3.8-Flash-Next in its own 119 GB format | For the flagship model, when it can have the whole machine |
| `ds4:rocm` | DwarfStar4, a DeepSeek V4 engine that streams weights from SSD | DeepSeek-V4/V4.1-Flash and GLM-5.3-Flash, 93 to 366 GB | Only for those models, including ones larger than memory |

Measured on a 128 GB Strix Halo with Qwen3.8-27B at Q4: Gufo generated 30.8
tokens/s and read a 25K-token prompt at 559 tokens/s, ROCm FPX 28.0 and 351,
and the built-in ROCm backend 23.8 and 325. Halogen and DwarfStar4 are untested
here.

Full guide, requirements and troubleshooting: [Container backends](docs/container-backends.md).

## Shell tools

These commands are available in the container's Fish shell:

| Command | Description |
| :--- | :--- |
| `lm [args...]` | Alias for `lemonade`. Use `lm list`, `lm backends`, `lm config`, etc. |
| `preflight` | Check that container backends can run: Docker socket, network, model paths, GPU group. |
| `install <recipe> [backend]` | Install or update a backend. Without a backend, the recipe's default. |
| `install --all` | Install every backend marked with `"install"` in `config.json`. |
| `versions` | Inventory installed backends, container images, ROCm runtimes, and executables. |
| `rocm-info` | Installed ROCm runtimes and diagnostic tools. |
| `pull <model-or-repo> [options]` | Pull a registered model, or register a repository with its companion checkpoints. |
| `pull --mtp <model> [--draft PATH \| --no-draft]` | Add, refresh, replace, or remove a registered model's MTP draft. |
| `fastpull <model-or-repo> [options]` | `pull` with several connections per file. |
| `load <model> [model...] [options]` | Load models. `load --set <name>` loads a group from `model_sets.json`. |
| `unload <model>` | Unload a model. `unload --all` unloads everything. |
| `update <model> [model...]` | Update models in place. Also `--all`, `--check`, `--prune`. |
| `delete <target> [target...]` | Delete models or leftover cache directories, and clean up after them. |

## Documentation

| Guide | Covers |
| :--- | :--- |
| [Setup reference](docs/setup.md) | Networking, volumes, devices, environment variables, and `config.json`. |
| [Backends](docs/backends.md) | Installing backends, declaring them in `config.json`, and inspecting versions and ROCm. |
| [Container backends](docs/container-backends.md) | What each one is for, how they run here, and troubleshooting. |
| [Managing models](docs/models.md) | `pull`, `fastpull`, `load`, `update`, `delete`, model sets, and manual registrations. |

## License

See the [Lemonade SDK license](https://github.com/lemonade-sdk/lemonade/blob/main/LICENSE) for Lemonade Server terms.
