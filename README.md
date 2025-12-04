# 🍋 Lemonade Stand

**Lemonade Stand** is a specialized Docker container for running [Lemonade Server](https://lemonade-server.ai/), an AI inference server compatible with OpenAI's API.

While Lemonade Server natively defaults to Vulkan, this container is pre-configured for **ROCm** acceleration, making it the ideal solution for **AMD Strix Halo** users and other AMD GPU owners who want maximum performance on Linux.

**Why use this?**
This project is built for power users who prefer the command line. It wraps the Lemonade API in ergonomic shell functions, making it easy to manage models, switch contexts, and script workflows directly from the terminal without wrestling with raw `curl` commands.

## ✨ Features

*   **ROCm Native:** Pre-configured with `LEMONADE_LLAMACPP=rocm` for AMD hardware acceleration.
*   **Strix Halo Ready:** Includes recommended flags (`--flash-attn`, `--no-mmap`) for high-performance APUs.
*   **CLI-First Experience:**
    *   **Fish Shell & Starship:** A beautiful, modern terminal experience out of the box.
    *   **Smart Autocomplete:** Tab completion for model names (fetched live from the API) and model sets.
    *   **Custom Load/Unload Tools:** Built-in `load` and `unload` commands to manage models easily.
    *   **Model Sets:** Define groups of models to load in bulk via JSON configuration.
*   **Health Checks:** Built-in Docker health monitoring.

---

## 🚀 Quick Start

### 1. Prerequisites

*   **Docker** and **Docker Compose**.
*   **AMD GPU/APU** (Required for ROCm acceleration).
*   **HuggingFace Cache:** A directory on your host machine where models are stored (e.g., `~/.cache/huggingface`).

### 2. Deploy with Docker Compose

Create a `docker-compose.yml` file using the example below.

> **Note for Strix Halo Users:** The environment variables below are tuned for your hardware. Specifically, `LEMONADE_LLAMACPP_ARGS` enables Flash Attention and disables mmap to prevent memory pinning issues on unified memory architectures.

```yaml
services:
  lemonade-stand:
    image: valentemath/lemonade-stand:latest
    container_name: lemonade-stand
    hostname: lemonade
    ports:
     # These **both** must match the value of LEMONADE_PORT
      - "8000:8000"
    # Expose AMD GPU devices to the container
    devices:
      - /dev/kfd:/dev/kfd
      - /dev/dri:/dev/dri
    volumes:
      # Mount your host's HuggingFace cache to avoid re-downloading models
      - ${HOME}/.cache/huggingface:/huggingface
      # Persist shell history
      - ${HOME}/.local/share/lemonade/fish:/root/.local/share/fish
      # Persist custom model sets
      - ${HOME}/.config/lemonade/cache:/root/.cache/lemonade
    environment:
      # Strix Halo Optimization: Flash Attention on, mmap off
      - LEMONADE_LLAMACPP_ARGS=--flash-attn on --no-mmap
      # Set context size (default is 4096)
      - LEMONADE_CTX_SIZE=16384
      # Max loaded models: [LLMs] [Embeddings] [Rerankers]
      - LEMONADE_MAX_LOADED_MODELS=3
    restart: unless-stopped
```

Run the container:

```bash
docker compose up -d
```

---

## 🛠️ Managing Models

This container includes custom `fish` functions to make interacting with the API easier than writing raw `curl` commands.

### Enter the Container

```bash
docker exec -it lemonade-stand fish
```

### Loading Models

Use the `load` command to load a model by its HuggingFace ID. **Tab completion is enabled**, so you can type `load` and press Tab to see available models from the server.

```fish
# Load a specific model
load user.Qwen3-VL-32B-Instruct
```

### Unloading Models

Use the `unload` command to free up VRAM. Tab completion works here too, showing only currently loaded models.

```fish
# Unload a specific model
unload user.Qwen3-VL-32B-Instruct

# Unload ALL running models
unload --all
```

### Model Sets

You can define "sets" of models to load them all at once. Create a `model_sets.json` file in your mounted lemonade cache directory (mapped to `/root/.cache/lemonade/model_sets.json` inside the container).

**Example `model_sets.json`:**
```json
{
  "coding": [
    "Qwen/Qwen2.5-Coder-32B-Instruct-GGUF",
    "nomic-ai/nomic-embed-text-v1.5-GGUF"
  ],
  "chat": [
    "google/gemma-2-27b-it-GGUF"
  ]
}
```

**Usage:**
```fish
# Load the "coding" set defined above
load --set coding
```

---

## ⚙️ Configuration Reference

This container builds upon the standard [Lemonade Server CLI](https://lemonade-server.ai/docs/server/lemonade-server-cli/). Below are the key environment variables used in this image.

| Variable | Default | Description |
| :--- | :--- | :--- |
| `LEMONADE_PORT` | `8000` | The port the server listens on. |
| `LEMONADE_LLAMACPP` | `rocm` | **Changed from upstream.** Defaults to ROCm for AMD acceleration. |
| `LEMONADE_LLAMACPP_ARGS` | *None* | Arguments passed to the backend. Recommended for Strix Halo: `--flash-attn on --no-mmap`. |
| `LEMONADE_MAX_LOADED_MODELS` | `"1 1 1"` | Space-separated limits for `[LLMs] [Embeddings] [Rerankers]`. |
| `LEMONADE_CTX_SIZE` | `4096` | Default context window size. |
| `HF_HOME` | `/huggingface` | Internal path for the model cache. |

