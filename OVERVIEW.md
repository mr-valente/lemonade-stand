# 🍋 Lemonade Stand

**Lemonade Stand** is a specialized Docker container for running [Lemonade Server](https://lemonade-server.ai/), an AI inference server compatible with OpenAI's API.

*   **Source Code:** [github.com/mr-valente/lemonade-stand](https://github.com/mr-valente/lemonade-stand)
*   **Official Lemonade SDK:** [github.com/lemonade-sdk/lemonade](https://github.com/lemonade-sdk/lemonade)

While Lemonade Server natively defaults to Vulkan, this container is pre-configured for **ROCm** acceleration, making it the ideal solution for **AMD Strix Halo** users and other AMD GPU owners who want maximum performance on Linux.

## Why use this image?

This project is built for power users who prefer the command line. It wraps the Lemonade API in ergonomic shell functions, making it easy to manage models, switch contexts, and script workflows directly from the terminal without wrestling with raw `curl` commands.

## ✨ Features

*   **ROCm Native:** Pre-configured with `LEMONADE_LLAMACPP=rocm` for AMD hardware acceleration.
*   **Strix Halo Ready:** Includes recommended flags (`--flash-attn`, `--no-mmap`) for high-performance APUs.
*   **CLI-First Experience:**
    *   **Fish Shell & Starship:** A beautiful, modern terminal experience out of the box.
    *   **Smart Autocomplete:** Tab completion for model names (fetched live from the API) and model sets.
    *   **Custom Load/Unload Tools:** Built-in `load` and `unload` commands to manage models easily.
    *   **Model Sets:** Define groups of models to load in bulk via JSON configuration.

## 🚀 Quick Start

Create a `docker-compose.yml`:

```yaml
services:
  lemonade-stand:
    image: valentemath/lemonade-stand:latest
    container_name: lemonade-stand
    hostname: lemonade
    ports:
      - "8000:8000"
    devices:
      - /dev/kfd:/dev/kfd
      - /dev/dri:/dev/dri
    volumes:
      - ${HOME}/.cache/huggingface:/huggingface
      - ${HOME}/.local/share/lemonade/fish:/root/.local/share/fish
      - ${HOME}/.config/lemonade/cache:/root/.cache/lemonade
    environment:
      - LEMONADE_LLAMACPP_ARGS=--flash-attn on --no-mmap
      - LEMONADE_CTX_SIZE=16384
      - LEMONADE_MAX_LOADED_MODELS=3
    restart: unless-stopped
```

Run it:

```bash
docker compose up -d
docker exec -it lemonade-stand fish
```

Once inside, try loading a model:

```fish
load user.Qwen3-VL-32B-Instruct
```
