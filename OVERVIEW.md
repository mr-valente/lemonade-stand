# 🍋 Lemonade Stand

A **server-first** Docker image for [Lemonade Server](https://lemonade-server.ai/) with full AMD acceleration support (ROCm, Vulkan, NPU).

Lemonade ships with a desktop GUI, but this image is for users who prefer to run Lemonade as a headless server and manage everything from the command line. It includes Fish shell with a Starship prompt and custom shell functions that enhance the existing `lemonade-server` CLI and wrap common API calls for ergonomic, interactive model management.

- **GitHub:** [github.com/mr-valente/lemonade-stand](https://github.com/mr-valente/lemonade-stand)
- **Lemonade SDK:** [github.com/lemonade-sdk/lemonade](https://github.com/lemonade-sdk/lemonade)

## What's included

- [Lemonade Server](https://github.com/lemonade-sdk/lemonade) and [FastFlowLM](https://github.com/FastFlowLM/FastFlowLM) built from source
- ROCm, Vulkan, and XRT/AMDXDNA backends for AMD GPUs, APUs, and NPUs
- Fish shell with Starship prompt and custom `load`/`unload` commands with live tab completion
- Docker health check against `/api/v1/health`

## Quick start

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
      # Recommended llamacpp args for Strix Halo:
      - LEMONADE_LLAMACPP=rocm
      - LEMONADE_LLAMACPP_ARGS=
          --flash-attn on
          --no-mmap 
      # - LEMONADE_FLM_LINUX_BETA=1 # Uncomment for NPU access
    restart: unless-stopped
```

```bash
docker compose up -d
docker exec -it lemonade-stand fish
```

## Shell tools

| Command | Description |
| :--- | :--- |
| `lm [args...]` | Alias for `lemonade-server`. |
| `load <model> [model...]` | Load models via the API. Tab-completes from available models. |
| `load --set <name>` | Load a named group of models from `model_sets.json`. |
| `unload <model>` | Unload a model. Tab-completes from loaded models. |
| `unload --all` | Unload all currently loaded models. |

## Volumes

| Container path | Purpose |
| :--- | :--- |
| `/huggingface` | Model weights (mount to avoid re-downloading). |
| `/root/.cache/lemonade` | Custom model registrations and `model_sets.json`. |
| `/root/.local/share/fish` | Fish shell command history. |

For full documentation, configuration reference, and examples, see the [GitHub repository](https://github.com/mr-valente/lemonade-stand).
