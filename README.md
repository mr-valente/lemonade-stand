# 🍋 Lemonade Stand

A **server-first** Docker image for [Lemonade Server](https://lemonade-server.ai/) with full AMD acceleration support (ROCm, Vulkan, NPU).

Lemonade ships with a desktop GUI, but this image is for users who prefer to run Lemonade as a headless server. It includes the Linux browser Web UI, plus Fish shell with a Starship prompt and custom shell functions that enhance the existing `lemonade` CLI and wrap common API calls for ergonomic, interactive model management.

- **Docker Hub:** [valentemath/lemonade-stand](https://hub.docker.com/r/valentemath/lemonade-stand)
- **Lemonade SDK:** [github.com/lemonade-sdk/lemonade](https://github.com/lemonade-sdk/lemonade)
- **Lemonade Server CLI docs:** [lemonade-server.ai/docs/guide/cli](https://lemonade-server.ai/docs/guide/cli/)

## Features

- **Server-first, no desktop GUI** — Designed for headless deployment with Docker.
- **Built from source** — Lemonade Server is compiled inside the image, always up to date.
- **Built-in browser Web UI** — The Linux Web UI is bundled into the server build and served from the Lemonade HTTP port.
- **AMD hardware acceleration** — ROCm and Vulkan for discrete/integrated GPUs, and XRT + AMDXDNA for NPU inference.
- **Fish shell + Starship prompt** — A polished terminal environment for interactive model management.
- **Enhanced model management** — `pull`, `load`, `unload`, `update`, and `delete` add safer workflows and live tab completion around Lemonade's API and CLI.
- **Companion-aware pulls** — `pull` discovers GGUF variants and registers advertised MTP/draft and multimodal projector files as explicit checkpoints.
- **In-place model updates** — `update` upgrades downloaded models to their latest upstream revision without deleting them first, and reclaims the space the old revision used.
- **Thorough deletion** — `delete` cancels active downloads and removes safe-to-delete cache, lock, and orphaned-file leftovers after Lemonade deletes the model, and can remove cache directories earlier deletions stranded.
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
    restart: unless-stopped
```

### 2. Start the container

```bash
docker compose up -d
```

Open the Web UI:

```text
http://localhost:8000
```

Connect to the shell

```bash
docker exec -it lemonade-stand fish
```

From inside the container you can manage models interactively:

```fish
lm list                                    # list all available models
pull unsloth/Qwen3.8-27B-GGUF              # choose a quant; include its MTP file
load user.Qwen3.8-27B-GGUF-UD-Q4_K_XL      # load the registered model
unload user.Qwen3.8-27B-GGUF-UD-Q4_K_XL    # free the model
```

## Managing models

### Pulling

For a registered Lemonade model, `pull` delegates directly to the Lemonade CLI:

```fish
pull Qwen3-0.6B-GGUF
```

For a Hugging Face or ModelScope repository, it inspects the repository first,
offers its GGUF variants, and creates an explicit multi-checkpoint registration.
Advertised MTP/draft and multimodal projector files are included automatically:

```fish
pull unsloth/Qwen3.8-27B-GGUF

# Non-interactive, with an explicit quant and name
pull unsloth/Qwen3.8-27B-GGUF \
  --quant UD-Q4_K_XL \
  --name user.Qwen3.8-27B-UD-Q4_K_XL \
  --yes
```

The resulting registration contains `main`, `draft`, and (when advertised)
`mmproj` checkpoints. This is important for repositories whose MTP file lives in
a subdirectory such as `MTP/mtp-Qwen3.8-27B-Q4_0.gguf`; keeping the full relative
path prevents the draft from being silently missed. Use `--no-draft` or
`--no-mmproj` to opt out, or `--draft PATH` / `--mmproj PATH` to override the
automatic choice.

To repair an already-registered custom model whose original registration has no
draft checkpoint, use its public (bare) name or its internal `user.*` name:

```fish
pull --repair-mtp Qwen3.8-27B-GGUF-UD-Q4_K_XL --yes
```

The repair inspects that model's saved repository and quant, adds the matching
MTP checkpoint while preserving its recipe options, then downloads it. The old
registration is restored automatically if the download fails. After a
successful repair, ordinary `update` runs refresh the MTP alongside the main
checkpoint.

### Loading

```fish
# Load a single model
load Qwen3-0.6B-GGUF

# Load with per-request recipe options
load Qwen3-0.6B-GGUF --ctx_size 8192 --llamacpp_backend vulkan --llamacpp_args "--no-context-shift --no-mmap" --save_options true

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

### Updating

`lemonade check-updates` reports which downloaded models have a newer upstream
revision but cannot act on it. `update` does:

```fish
# See what has an update waiting
update --check

# Update one model (or several)
update user.Phi-4-Mini-GGUF
update user.Phi-4-Mini-GGUF user.nomic-embed

# Update everything that has a newer revision
update --all

# Update everything, then reclaim the space the old revisions used
update --all --prune
```

Models are upgraded **in place**: `update` re-pulls the model under its existing
registration, so the new revision is downloaded alongside the old one and the
server only switches over once it is complete. Nothing is deleted first, so a
failed or interrupted download always leaves the working model intact — and the
registration in `user_models.json` (all checkpoints, quant, recipe options) is
never lost the way it is when you delete a model and pull it again. `update`
uses the enhanced `pull` path, so already-registered MTP/draft checkpoints are
refreshed along with the main weights; use `pull --repair-mtp` once to add a
draft that was missing from an older registration. Its prune keep-set also
includes every checkpoint reported by the model-files API.

If a model is loaded when it is updated, it is unloaded first — otherwise the
running backend keeps serving the old weights — and reloaded afterwards. Pass
`--no-reload` to leave it unloaded.

| Option | Description |
| :--- | :--- |
| `-a`, `--all` | Update every model reported by `check-updates`. |
| `-c`, `--check` | List pending updates and exit. |
| `-f`, `--force` | Re-pull even when no update is reported, and ignore the free-space check. |
| `--flm` | With `--all`, also refresh FLM models. |
| `-n`, `--dry-run` | Show what would be done, change nothing. |
| `-y`, `--yes` | Do not prompt for confirmation. |
| `-p`, `--prune` | Delete superseded weights after a successful update. |
| `--no-reload` | Leave models unloaded instead of restoring them. |

#### FLM models

FLM (NPU) models are managed by the `flm` CLI rather than the HuggingFace cache,
and Lemonade's update check skips them — `flm` cannot report whether a newer
revision exists. They are therefore never included in `update --all` unless you
ask for them, and updating one is always an unconditional re-download:

```fish
update --all --flm          # everything, FLM models included
update llama3.2-1b-FLM      # just this one
```

#### Reclaiming disk space

An in-place upgrade leaves the previous revision in the HuggingFace cache. That
is what makes the upgrade safe, but the old weights are dead once the new ones
land. `--prune` removes them:

```fish
update --all --prune        # update, then clean up
update --prune              # clean up superseded revisions from earlier updates
```

Pruning only deletes files that no downloaded model resolves to any more, and it
lists everything before deleting it. Add `--dry-run` to see the list without
touching anything.

### Deleting

`delete` previews and confirms destructive work, asks Lemonade to unload and
delete each model, then removes leftovers that are safe to attribute to it:

```fish
delete --dry-run user.Qwen3.8-27B-GGUF-UD-Q4_K_XL
delete user.Qwen3.8-27B-GGUF-UD-Q4_K_XL
delete --yes user.old-model-1 user.old-model-2
```

The cleanup cancels an active download before touching its files, clears stopped
download records, removes a repository cache and its lock directory only when no
remaining model still holds files there, and removes unreferenced files from
shared caches. It also runs Lemonade's legacy multi-repository orphan sweep.
`--no-cleanup` limits the operation to Lemonade's built-in delete behavior.

A registration that is merely *known* to the server does not keep a directory
alive; only one that actually holds files does. A built-in model stays listed
after its own deletion with `downloaded: false`, and treating that as a claim is
what leaves repository directories behind in the first place.

Those already-stranded directories can be named directly, either by repository
or by directory:

```fish
delete --dry-run unsloth/gemma-4-12b-it-GGUF
delete --yes models--unsloth--gemma-4-12b-it-GGUF
```

Tab completion lists them, so anything in `$HF_HUB_CACHE` that no downloaded or
registered model claims is reachable without typing it out. A directory that is
still claimed is refused, with the model to delete instead named in the error. A
directory named on the command line is the request itself rather than extra
tidying, so `--no-cleanup` does not hold it back.

Collections are deliberately not cascade-deleted: deleting a collection removes
the collection entry, while its components stay installed. Name those component
models explicitly if they should also be deleted.

### Tab completion

The model-management functions support tab completion:

- `pull` + Tab — shows registered models; `--quant`, `--draft`, and `--mmproj` complete from repository inspection.
- `load` + Tab — shows all models known to the server plus set names from `model_sets.json`.
- `unload` + Tab — shows only the currently loaded models.
- `update` + Tab — shows only the downloaded models.
- `delete` + Tab — shows downloaded models, removable `user.*` registrations, and leftover cache directories that no model claims.

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

### Manual registrations

The enhanced `pull` function covers ordinary GGUF repositories. For unusual
recipes or checkpoint roles, use Lemonade's manual form through `lm`. Custom
model names must use the `user.` namespace prefix:

```fish
# Register a custom GGUF model
lm pull user.Phi-4-Mini-GGUF \
  --checkpoint main unsloth/Phi-4-mini-instruct-GGUF:Q4_K_M \
  --recipe llamacpp

# Register an embedding model
lm pull user.nomic-embed \
  --checkpoint main nomic-ai/nomic-embed-text-v1-GGUF:Q4_K_S \
  --recipe llamacpp \
  --label embeddings

# Register a vision model with multimodal projector
lm pull user.Gemma-3-4b \
  --checkpoint main ggml-org/gemma-3-4b-it-GGUF:Q4_K_M \
  --checkpoint mmproj ggml-org/gemma-3-4b-it-GGUF:mmproj-model-f16.gguf \
  --recipe llamacpp \
  --label vision
```

See the full [pull options](https://lemonade-server.ai/docs/guide/cli/#options-for-pull) in the Lemonade docs.

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

For the complete list of options, see the [Lemonade Server CLI documentation](https://lemonade-server.ai/docs/guide/cli/).

## Volumes

Mount these paths to persist data across container restarts:

| Container path | Purpose |
| :--- | :--- |
| `/huggingface` | Model weights. Without this mount, models are re-downloaded on every new container. |
| `/root/.cache/lemonade` | Lemonade cache — custom model registrations and `model_sets.json`. |
| `/root/.local/share/fish` | Fish shell command history. |

This image runs Lemonade as root for broad device access. If you bind-mount host
directories under `/root`, Docker-created files on the host will also be owned by
root. To repair an existing `~/.local/share/lemonade-stand` tree:

```bash
docker compose down
sudo chown -R "$(id -u):$(id -g)" "$HOME/.local/share/lemonade-stand"
```

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
| `install <recipe> <backend>` | Install or update a backend via the API. |
| `install --all [--config <path>]` | Install every configured recipe marked with `"install": true`. |
| `pull <model-or-repo> [options]` | Pull a registered model or interactively register a repository with its companion checkpoints. |
| `load <model> [model...] [options]` | Load models via the API. |
| `load --set <name>` | Load a named model set from `model_sets.json`. |
| `unload <model>` | Unload a model via the API. |
| `unload --all` | Unload all currently loaded models. |
| `update <model> [model...]` | Update downloaded models in place. |
| `update --all` | Update every model that has a newer upstream revision. |
| `update --check` | List models with updates available. |
| `update --prune` | Reclaim disk space from superseded revisions. |
| `delete <target> [target...]` | Delete models, or leftover cache directories, and safely clean their filesystem leftovers. |

## License

See the [Lemonade SDK license](https://github.com/lemonade-sdk/lemonade/blob/main/LICENSE) for Lemonade Server terms.
