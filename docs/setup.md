# Setup reference

Everything the container needs from its compose file, and where the server keeps
its settings. The [quick start](../README.md#quick-start) shows these together.

## Networking

Run the container with `network_mode: host`. Lemonade then listens directly on
the host, on port 13305 unless you change it, and can reach the
[container backends](container-backends.md) it starts.

Other containers reach the server through the host gateway:

```yaml
  some-client:
    extra_hosts:
      - "host.docker.internal:host-gateway"
    # then use http://host.docker.internal:13305
```

A bridge network with `ports: ["13305:13305"]` still works if you only use
native backends. Container backends will not load on it; `preflight` says so.

## Volumes

| Container path | Purpose |
| :--- | :--- |
| `$HF_HOME` | Model weights. Mount it at the **same path as on the host** (see below). |
| `/root/.cache/lemonade` | Server state: `config.json`, model registrations, `model_sets.json`, and downloaded backends under `bin/`. |
| `/root/.config/flm` | FastFlowLM (NPU) models. |
| `/root/.local/share/fish` | Fish shell command history. |
| `/var/run/docker.sock` | The host's Docker daemon, for container backends. |

### Model weights need the same path on both sides

Lemonade tells the host's Docker daemon which model files to mount into a
container backend, using the paths it sees itself. The daemon resolves them on
the host, so the directory must have one path in both places:

```yaml
    volumes:
      - /srv/lemonade/huggingface:/srv/lemonade/huggingface
    environment:
      - HF_HOME=/srv/lemonade/huggingface
```

The hub cache is `$HF_HOME/hub`. The image defaults `HF_HOME` to `/huggingface`,
which suits native backends alone: mount any host directory there.

### File ownership

The image runs Lemonade as root for broad device access, so files it creates in
bind-mounted directories are owned by root on the host. To repair a tree:

```bash
docker compose down
sudo chown -R "$(id -u):$(id -g)" /srv/lemonade/config
```

## Devices

| Host device | Purpose |
| :--- | :--- |
| `/dev/kfd` | AMD GPU compute interface (required for ROCm) |
| `/dev/dri` | AMD GPU render nodes (required for ROCm and Vulkan) |
| `/dev/accel` | NPU accelerator (required for FastFlowLM and other XRT / AMDXDNA models) |

Pass them with `devices:`, or run the container `privileged`. NPU models also
need an unlimited memlock limit:

```yaml
    ulimits:
      memlock: { soft: -1, hard: -1 }
```

At startup the entrypoint gives the image's `render` group the ID that owns the
host's render node. Lemonade passes that group to container backends, which run
without privileges and open the GPU through it.

## Environment variables

| Variable | Default | Description |
| :--- | :--- | :--- |
| `LEMONADE_HOST` | *(from `config.json`)* | Address to listen on. Set `0.0.0.0` to accept connections from other machines. |
| `LEMONADE_PORT` | *(from `config.json`)* | Port to listen on. The shell tools, the `lemonade` CLI and the health check follow it. |
| `LEMONADE_API_KEY` | *(none)* | Requires Bearer authentication on API requests. Recommended whenever the host is not `localhost`. |
| `HF_HOME` | `/huggingface` | Hugging Face home; weights are stored in `$HF_HOME/hub`. |
| `HF_TOKEN` | *(none)* | Hugging Face token for gated repositories and higher rate limits. |
| `LEMONADE_CONTAINER_ENV` | `GPU_MAX_HW_QUEUES` | Names of variables to forward from this container into container backends, separated by spaces or commas. |
| `LEMONADE_FASTPULL_STREAMS` | `8` | Connections per file for `fastpull`. |
| `LEMONADE_BACKEND_DIR` | `/root/.cache/lemonade/bin` | Where the shell tools look for installed backends. |

Lemonade itself no longer reads `LEMONADE_HOST` or `LEMONADE_PORT`. The
entrypoint passes them to the server as `--host` and `--port`, where they
override `config.json`. Set the port in one place: either here or in
`config.json`, not both with different values.

## Server configuration

Every other server setting lives in `/root/.cache/lemonade/config.json`. It is a
sparse file: it holds only what you change, and everything else follows
Lemonade's defaults. Edit it and restart, or change it live:

```fish
lemonade config                          # show the effective configuration
lemonade config set llamacpp.backend=rocm
lemonade config set max_loaded_models=-1 ctx_size=32768
```

Settings worth knowing on AMD hardware:

| Key | Default | Description |
| :--- | :--- | :--- |
| `llamacpp.backend` | `auto` | Default llama.cpp backend: `rocm`, `vulkan`, `cpu`, or a container backend such as `nathanw`. |
| `llamacpp.args` | *(none)* | Extra `llama-server` arguments for every load. |
| `rocm_channel` | `stable` | `nightly` tracks Lemonade's newest ROCm llama.cpp builds. |
| `ctx_size` | `-1` | Default context size; `-1` lets Lemonade size it to the model and memory. |
| `max_loaded_models` | `1` | Models kept loaded per type; `-1` is unlimited. |
| `auto_evict` | `false` | Unload idle models when memory use passes `auto_evict_threshold_pct`. |
| `global_timeout` | `600` | Seconds before a request is abandoned. |
| `log_level` | `info` | `debug` also shows backend output and each `docker run` command. |

The `install` key in a recipe's section belongs to this image, not Lemonade; see
[Declaring what to install](backends.md#declaring-what-to-install). For the full
list, see Lemonade's
[configuration guide](https://lemonade-server.ai/docs/guide/configuration/).

## Health check

The image's health check queries `/api/v1/health` on `LEMONADE_PORT`, or 13305
when that is unset. If you set the port only in `config.json`, set
`LEMONADE_PORT` to match so the check and the shell tools find the server.
