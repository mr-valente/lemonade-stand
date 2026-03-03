# 🍋 Lemonade Stand

A **server-first** Docker image for [Lemonade Server](https://lemonade-server.ai/) with full AMD acceleration support (ROCm, Vulkan, NPU).

Lemonade ships with a desktop GUI, but this image is for users who prefer to run Lemonade as a headless server and manage everything from the command line. It includes Fish shell with a Starship prompt and custom shell functions that enhance the existing `lemonade-server` CLI and wrap common API calls for ergonomic, interactive model management.

- **Docker Hub:** [valentemath/lemonade-stand](https://hub.docker.com/r/valentemath/lemonade-stand)
- **Lemonade SDK:** [github.com/lemonade-sdk/lemonade](https://github.com/lemonade-sdk/lemonade)
- **Lemonade Server CLI docs:** [lemonade-server.ai/docs/server/lemonade-server-cli](https://lemonade-server.ai/docs/server/lemonade-server-cli/)

## Features

- **Server-first, no GUI** — Designed for headless deployment with Docker.
- **Built from source** — Lemonade Server and FastFlowLM are compiled inside the image, always up to date.
- **AMD hardware acceleration** — ROCm and Vulkan for discrete/integrated GPUs, and XRT + AMDXDNA for NPU inference.
- **Fish shell + Starship prompt** — A polished terminal environment for interactive model management.
- **Simple `load` / `unload` commands** — Manage models without writing curl commands. Tab completion fetches model names live from the API.
- **Model sets** — Define named groups of models in a JSON file and load them all at once.

## Prerequisites

- **Docker** (with Docker Compose)
- **AMD GPU or APU** — with ROCm-compatible drivers on the host for GPU acceleration
- **NPU access** *(experimental)* — the host kernel must have the `amdxdna` module loaded

## Quick start

### 1. Create a `docker-compose.yml`

```yaml
services:
  lemonade-stand:
    image: valentemath/lemonade-stand:latest
    container_name: lemonade-stand
    ports:
      - "8000:8000"
    devices:
      - /dev/kfd:/dev/kfd
      - /dev/dri:/dev/dri
      # - /dev/accel:/dev/accel  # Uncomment for NPU access
    volumes:
      - /path/to/huggingface:/huggingface
      - /path/to/fish-history:/root/.local/share/fish
      - /path/to/lemonade-cache:/root/.cache/lemonade
    environment:
      - LEMONADE_HOST=0.0.0.0
      # Recommended settings for Strix Halo devices:
      - LEMONADE_LLAMACPP=rocm
      - LEMONADE_LLAMACPP_ARGS=
          --flash-attn on
          --no-mmap 
      # - LEMONADE_FLM_LINUX_BETA=1 # Uncomment for NPU access
    restart: unless-stopped
```

### 2. Start the container

```bash
docker compose up -d
```

Connect to the shell

```bash
docker exec -it lemonade-stand fish
```

From inside the container you can manage models interactively:

```fish
lm list                          # list all available models
lm pull Gemma3-4b-it-FLM         # download a model from the registry
load Gemma3-4b-it-FLM            # load a model from the registry
unload Gemma3-4b-it-FLM           # free the model
```

## Managing models

### Loading

```fish
# Load a single model
load Qwen3-0.6B-GGUF

# Load multiple models
load Qwen3-0.6B-GGUF user.nomic-embed

# Load a named set (see Model Sets below)
load --set coding
```

### Unloading

```fish
# Unload a specific model
unload Qwen3-0.6B-GGUF

# Unload all loaded models
unload --all
```

### Tab completion

Both `load` and `unload` support tab completion:

- `load` + Tab — shows all models known to the server plus set names from `model_sets.json`.
- `unload` + Tab — shows only the currently loaded models.

### Model sets

Define groups of models in `/root/.cache/lemonade/model_sets.json` (mount a host directory to persist this file across container restarts):

```json
{
  "coding": [
    "user.Qwen2.5-Coder-32B-Instruct",
    "user.nomic-embed"
  ],
  "chat": [
    "user.Gemma-3-27B-IT"
  ]
}
```

Then load an entire set:

```fish
load --set coding
```

### Installing custom models

Use `lemonade-server pull` (or the `lm` alias) to register and download models from HuggingFace. Custom model names must use the `user.` namespace prefix:

```fish
# Register a custom GGUF model
lm pull user.Phi-4-Mini-GGUF \
  --checkpoint unsloth/Phi-4-mini-instruct-GGUF:Q4_K_M \
  --recipe llamacpp

# Register an embedding model
lm pull user.nomic-embed \
  --checkpoint nomic-ai/nomic-embed-text-v1-GGUF:Q4_K_S \
  --recipe llamacpp \
  --embedding

# Register a vision model with multimodal projector
lm pull user.Gemma-3-4b \
  --checkpoint ggml-org/gemma-3-4b-it-GGUF:Q4_K_M \
  --recipe llamacpp \
  --vision \
  --mmproj mmproj-model-f16.gguf
```

See the full [pull options](https://lemonade-server.ai/docs/server/lemonade-server-cli/#options-for-pull) in the Lemonade docs.

## Configuration

The server is configured entirely through environment variables. Set them in your `docker-compose.yml` or pass them with `docker run -e`.

### Server settings

| Variable | Default | Description |
| :--- | :--- | :--- |
| `LEMONADE_HOST` | `localhost` | Address to listen on. Set to `0.0.0.0` to accept external connections. |
| `LEMONADE_PORT` | `8000` | Port the server listens on. The compose `ports` mapping must match. |
| `LEMONADE_LOG_LEVEL` | `info` | Logging verbosity (`debug`, `info`, `warning`, `error`). |
| `LEMONADE_API_KEY` | *(none)* | If set, requires Bearer authentication on all requests. |

### Backend selection

| Variable | Default | Description |
| :--- | :--- | :--- |
| `LEMONADE_LLAMACPP` | `vulkan` | LLM backend: `rocm`, `vulkan`, or `cpu`. |
| `LEMONADE_WHISPERCPP` | `cpu` | Audio backend: `vulkan` or `cpu` on Linux. |
| `LEMONADE_FLM_LINUX_BETA` | *(unset)* | Set to `1` to enable FastFlowLM on Linux (experimental). |

### Inference tuning

| Variable | Default | Description |
| :--- | :--- | :--- |
| `LEMONADE_CTX_SIZE` | `4096` | Default context window size for models. |
| `LEMONADE_LLAMACPP_ARGS` | *(none)* | Extra arguments passed to `llama-server` (e.g., `--flash-attn on --no-mmap`). |
| `LEMONADE_MAX_LOADED_MODELS` | `1` | Max models loaded per type slot (LLMs, audio, image, etc.). Use `-1` for unlimited. |

### Paths and storage

| Variable | Default (in container) | Description |
| :--- | :--- | :--- |
| `HF_HOME` | `/huggingface` | HuggingFace home directory. |
| `HF_HUB_CACHE` | `/huggingface/hub` | HuggingFace Hub download cache. |

For the complete list of options, see the [Lemonade Server CLI documentation](https://lemonade-server.ai/docs/server/lemonade-server-cli/).

## Volumes

Mount these paths to persist data across container restarts:

| Container path | Purpose |
| :--- | :--- |
| `/huggingface` | Model weights. Without this mount, models are re-downloaded on every new container. |
| `/root/.cache/lemonade` | Lemonade cache — custom model registrations and `model_sets.json`. |
| `/root/.local/share/fish` | Fish shell command history. |

## Device access

| Host device | Purpose |
| :--- | :--- |
| `/dev/kfd` | AMD GPU kernel driver (required for ROCm) |
| `/dev/dri` | AMD GPU render nodes (required for ROCm and Vulkan) |
| `/dev/accel` | NPU accelerator (required for XRT / AMDXDNA models) |

## Shell tools reference

These fish functions are available inside the container:

| Command | Description |
| :--- | :--- |
| `lm [args...]` | Alias for `lemonade-server`. Use `lm serve`, `lm list`, `lm pull`, etc. |
| `load <model> [model...]` | Load models via the API. |
| `load --set <name>` | Load a named model set from `model_sets.json`. |
| `unload <model>` | Unload a model via the API. |
| `unload --all` | Unload all currently loaded models. |

## License

See the [Lemonade SDK license](https://github.com/lemonade-sdk/lemonade/blob/main/LICENSE) for Lemonade Server terms.
