# 🍋 Lemonade Stand

A **server-first** Docker image for [Lemonade Server](https://lemonade-server.ai/) with full AMD acceleration support (ROCm, Vulkan, NPU).

Lemonade ships with a desktop GUI, but this image is for users who prefer to run Lemonade as a headless server. It includes the Linux browser Web UI, plus Fish shell with a Starship prompt and custom shell functions that enhance the existing `lemonade` CLI and wrap common API calls for ergonomic, interactive model management.

- **GitHub:** [github.com/mr-valente/lemonade-stand](https://github.com/mr-valente/lemonade-stand)
- **Lemonade SDK:** [github.com/lemonade-sdk/lemonade](https://github.com/lemonade-sdk/lemonade)

## What's included

- [Lemonade Server](https://github.com/lemonade-sdk/lemonade) built from source
- Lemonade Linux browser Web UI served from the HTTP port
- ROCm, Vulkan, and XRT/AMDXDNA backends for AMD GPUs, APUs, and NPUs
- Lemonade's container backends for Strix Halo (Gufo, Halogen, ROCm FPX, DwarfStar4, and two llama.cpp forks), run on the host's Docker daemon with a `preflight` check
- Fish shell with Starship prompt and enhanced `pull`/`load`/`unload`/`update`/`delete` commands with live tab completion
- Companion-aware GGUF pulls that preserve MTP/draft and multimodal projector paths, plus adding, replacing, or removing a registered model's MTP draft
- In-place model updates that never delete a model before its replacement has downloaded
- Confirmed deletion with conservative cleanup of unshared caches, alias pruning and a registry read-back so the server agrees the model is gone, plus removal of cache directories that earlier deletions stranded
- Docker health check against `/api/v1/health`

## Quick start

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
container backends need. Run `preflight` in the shell to confirm them.

```bash
docker compose up -d
docker exec -it lemonade-stand fish
```

## Shell tools

| Command | Description |
| :--- | :--- |
| `lm [args...]` | Alias for `lemonade`. |
| `preflight` | Check that container backends can run. |
| `install <recipe> [backend]` | Install or update a backend; Tab completes both from the server. |
| `install --all` | Install every backend marked with `"install"` in `config.json`. |
| `versions` | Inventory installed backends, container images, and ROCm runtimes. |
| `pull <model-or-repo> [options]` | Pull registered models or register a repository with its companion checkpoints. |
| `pull --mtp <model> [--draft PATH \| --no-draft]` | Add, refresh, replace, or remove a registered model's MTP draft. |
| `load <model> [model...] [options]` | Load models via the API. Tab-completes from available models. |
| `load --set <name>` | Load a named group of models from `model_sets.json`. |
| `unload <model>` | Unload a model. Tab-completes from loaded models. |
| `unload --all` | Unload all currently loaded models. |
| `update <model> [model...]` | Update downloaded models in place. |
| `update --all` | Update every model that has a newer upstream revision. |
| `update --check` | List models with updates available. |
| `update --prune` | Reclaim disk space from superseded revisions. |
| `delete <target> [target...]` | Delete models, or leftover cache directories, and conservatively clean cache leftovers. |

## Volumes

| Container path | Purpose |
| :--- | :--- |
| `$HF_HOME` | Model weights, mounted at the same path as on the host. |
| `/root/.cache/lemonade` | `config.json`, model registrations, `model_sets.json`, and downloaded backends. |
| `/root/.local/share/fish` | Fish shell command history. |
| `/var/run/docker.sock` | The host's Docker daemon, for container backends. |

Server settings live in `config.json` (`lemonade config set key=value`).
`LEMONADE_HOST` and `LEMONADE_PORT` override its address and port.

For full documentation, configuration reference, and examples, see the [GitHub repository](https://github.com/mr-valente/lemonade-stand).
