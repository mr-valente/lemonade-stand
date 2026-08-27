# 🍋 Lemonade Stand

A **server-first** Docker image for [Lemonade Server](https://lemonade-server.ai/) with full AMD acceleration support (ROCm, Vulkan, NPU).

Lemonade ships with a desktop GUI, but this image is for users who prefer to run Lemonade as a headless server. It includes the Linux browser Web UI, plus Fish shell with a Starship prompt and custom shell functions that enhance the existing `lemonade` CLI and wrap common API calls for ergonomic, interactive model management.

- **GitHub:** [github.com/mr-valente/lemonade-stand](https://github.com/mr-valente/lemonade-stand)
- **Lemonade SDK:** [github.com/lemonade-sdk/lemonade](https://github.com/lemonade-sdk/lemonade)

## What's included

- [Lemonade Server](https://github.com/lemonade-sdk/lemonade) built from source
- Lemonade Linux browser Web UI served from the HTTP port
- ROCm, Vulkan, and XRT/AMDXDNA backends for AMD GPUs, APUs, and NPUs
- Fish shell with Starship prompt and custom `load`/`unload`/`update` commands with live tab completion
- In-place model updates that never delete a model before its replacement has downloaded
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
| `install <recipe> <backend>` | Install or update a backend via the API. |
| `install --all [--config <path>]` | Install every configured recipe marked with `"install": true`. |
| `load <model> [model...] [options]` | Load models via the API. Tab-completes from available models. |
| `load --set <name>` | Load a named group of models from `model_sets.json`. |
| `unload <model>` | Unload a model. Tab-completes from loaded models. |
| `unload --all` | Unload all currently loaded models. |
| `update <model> [model...]` | Update downloaded models in place. |
| `update --all` | Update every model that has a newer upstream revision. |
| `update --check` | List models with updates available. |
| `update --prune` | Reclaim disk space from superseded revisions. |

## Volumes

| Container path | Purpose |
| :--- | :--- |
| `/huggingface` | Model weights (mount to avoid re-downloading). |
| `/root/.cache/lemonade` | Custom model registrations and `model_sets.json`. |
| `/root/.local/share/fish` | Fish shell command history. |

Bind-mounted `/root` paths are written by container root. If a host data
directory becomes root-owned, stop the container and run:

```bash
sudo chown -R "$(id -u):$(id -g)" "$HOME/.local/share/lemonade-stand"
```

For full documentation, configuration reference, and examples, see the [GitHub repository](https://github.com/mr-valente/lemonade-stand).
