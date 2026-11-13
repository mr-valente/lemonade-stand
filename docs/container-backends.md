# Container backends

A container backend runs a model's engine from a container image instead of a
downloaded binary. Lemonade pins each image by digest, starts one container per
loaded model, and talks to it over HTTP like any other backend. All six target
Strix Halo (`gfx1151`).

In this image, Lemonade runs them on the **host's Docker daemon** through a
mounted socket. The backend containers are siblings of `lemonade-stand`, not
children inside it: `docker ps` on the host shows them, and their images live in
the host's image store.

## Requirements

| Compose setting | Why |
| :--- | :--- |
| `- /var/run/docker.sock:/var/run/docker.sock` | Lemonade asks the host daemon to pull images and start containers. |
| `network_mode: host` | Each backend gets a private network that only the host can reach. |
| Model weights at the same path on both sides, with `HF_HOME` set to it | The daemon mounts model files using the paths Lemonade sees. |
| `stop_grace_period: 60s` | Lemonade gives each backend 10 seconds to stop before it exits itself. |

The [quick start](../README.md#quick-start) has all four, and the
[setup reference](setup.md) explains each. Then check from the shell:

```fish
preflight
```

```text
Container backend preflight
  ok    Docker daemon reachable (29.8.2)
  ok    Host networking
  ok    Model path is the same on the host: /srv/lemonade/huggingface/hub
  ok    render group matches /dev/dri/renderD128 (gid 988)
  note  Forwarded to backends: GPU_MAX_HW_QUEUES=1
```

The same check runs at container start and prints only what is wrong, so
`docker logs lemonade-stand` shows a broken setup immediately. Lemonade's own
report is in `lemonade backends`: a backend it cannot run is `action_required`.

Mounting the Docker socket gives this container root-equivalent control of the
host's containers. Lemonade's rootless path needs Podman on the host and a
`lemond` that runs outside Docker, which is not what this image is.

## The backends

| Backend | What it is | Models | Author, license |
| :--- | :--- | :--- | :--- |
| `gufo:rocm` | Engine with kernels written per model for Strix Halo | Qwen3.8-27B, Qwen3.8-Flash-Next, DeepSeek-V4-Flash, from ordinary GGUF weights plus a draft model | [gufo-org](https://github.com/gufo-org/gufo), MIT |
| `rocmfpx:rocm` | llama.cpp fork adding the ROCmFP4, FP6 and FP8 weight formats and MTP drafting | ROCmFP4 builds of Qwen3.8-27B, Qwen3.6-35B-A3B and Gemma-4-26B-A4B | [ROCmFPX](https://github.com/ROCmFPX/ROCmFPX), MIT |
| `llamacpp:nathanw` | llama.cpp fork tuned for Strix Halo's Vulkan driver: faster flash attention, quantized KV cache, MoE prefill | Any GGUF | [Nathanw1014](https://github.com/Nathanw1014/llama.cpp/tree/strix-halo-vulkan), MIT |
| `llamacpp:halobox` | Halo Box's llama.cpp fork, built against a custom ROCm runtime | Any GGUF | [halo-box](https://github.com/halo-box/strix-llama.cpp), MIT |
| `halogen:rocm` | Engine for AI agents with kernels built for each model; 262,144-token context by default. Needs Linux 6.18.4 or newer with `CONFIG_HSA_AMD_SVM` | Qwen3.8-Flash-Next in Halogen's own format (119 GB) | [Peonist](https://github.com/peonist-ai/halogen-flash-server), proprietary; free, including commercial use |
| `ds4:rocm` | DwarfStar4, a self-contained DeepSeek V4 engine that streams weights from SSD when they do not fit in memory | DeepSeek-V4-Flash, V4.1-Flash and GLM-5.3-Flash, 93 to 366 GB | [antirez](https://github.com/antirez/ds4), MIT |

All but Halogen are packaged as images by Donato Capitella
([kyuz0](https://hub.docker.com/u/kyuz0)).

For which of these to run, and how they compare with the built-in backends,
see [Choosing a language model backend](backends.md#choosing-a-language-model-backend).

## Using one

Install it, then load a model on it:

```fish
install rocmfpx                               # or: install llamacpp nathanw
pull Qwen3.8-27B-ROCmFP4-STRIX-MTP            # recipes with their own models
load Qwen3.8-27B-ROCmFP4-STRIX-MTP

# The llama.cpp forks run any GGUF you already have
load user.Qwen3.8-27B-GGUF-UD-Q4_K_XL --llamacpp_backend nathanw
load user.Qwen3.8-27B-GGUF-UD-Q4_K_XL --llamacpp_backend nathanw --save_options true
```

`lm list` shows each recipe's models. To have `install --all` keep a backend
installed across image upgrades, mark it in `config.json`; see
[Declaring what to install](backends.md#declaring-what-to-install).

## How they run

Each loaded model is one container named
`lemonade-<port>-<recipe>-<backend>-<model>` and labeled `ai.lemonade`:

```bash
docker ps --filter label=ai.lemonade
docker logs lemonade-13305-rocmfpx-rocm-Qwen3.8-27B-ROCmFP4-STRIX-MTP
```

Lemonade starts each one without privileges: every capability dropped,
`no-new-privileges`, only the GPU device nodes its engine needs, its model files
mounted read-only, and a private network with no route to the internet. With
`log_level` set to `debug`, the server log shows the full `docker run` command.

This image adds three things around that:

- **GPU group.** Backends open the GPU through the `render` group. The
  entrypoint gives the image's `render` group the ID that owns the host's
  render node, so the group Lemonade passes along is the right one.
- **Environment forwarding.** Lemonade passes a backend only the variables it
  sets itself. Variables named in `LEMONADE_CONTAINER_ENV` (default
  `GPU_MAX_HW_QUEUES`) are forwarded from this container when they are set, so
  GPU tuning applies to native and container backends alike.
- **Cleanup.** A backend can outlive a Lemonade that was killed rather than
  stopped, holding its model in memory. At startup the entrypoint removes
  containers and networks left by a previous run on the same port.

## Things to know

- **Two or more ROCm processes on kernels before 7.4** keep the GPU at 100%
  busy while idle ([ROCm/TheRock#9141](https://github.com/ROCm/TheRock/issues/9141)).
  Set `GPU_MAX_HW_QUEUES=1` on this container; it is forwarded to container
  backends by default. Vulkan backends, `llamacpp:nathanw` included, are not
  affected.
- **Pruning images removes idle backends.** A backend's image is pulled by
  digest and is in use only while a model is loaded on it. `docker image prune`
  therefore removes it, and so does any scheduled cleanup of unused images,
  such as Komodo's Auto Prune, which runs daily when it is on for the server.
  Lemonade still lists the backend as installed, and its models fail to load.
  Turn scheduled pruning off on the host that runs this container. `versions`
  reports an image that has gone missing, and `install` pulls it again.
- **Guest tier.** Lemonade classes every container backend as *guest*:
  maintained by a contributor, with no support or update guarantee. Lemonade
  pins and validates the image digests it ships; the engines themselves are
  third-party code.
- **Updates** arrive with Lemonade releases, which move the pins. After
  upgrading this image, `install --all` pulls the new images.

## Troubleshooting

| Symptom | Cause and fix |
| :--- | :--- |
| `lemonade backends` shows `action_required` | The daemon is unreachable. Mount the Docker socket; run `preflight`. |
| Load fails with "got no address on its network", or times out waiting for the backend | The container is not on host networking. Set `network_mode: host`. |
| Load fails and the backend log says the model is a directory or cannot be opened | The model path differs between container and host. Docker created an empty directory at the missing host path; remove it, then mount the weights at the same path on both sides. |
| The model loads but runs on the CPU | The backend could not open the GPU. Run `preflight` and check the render group line. |
| A stopped Lemonade left containers behind | Restart `lemonade-stand`; the entrypoint removes them. Or: `docker rm -f $(docker ps -aq --filter label=ai.lemonade)`. |
