# Backends

A backend is the engine that runs a model: llama.cpp, whisper.cpp, FastFlowLM and
so on. Lemonade downloads each one on demand and reports it as one of three
formats:

| Format | What gets installed | Where it lives |
| :--- | :--- | :--- |
| `native` | A release archive of binaries | `/root/.cache/lemonade/bin/<recipe>/<backend>` |
| `python` | A bundled Python environment | Same directory |
| `container` | A container image, pinned by digest | The host's Docker daemon; see [Container backends](container-backends.md) |

`lemonade backends` lists every backend with its tier, format and state.

## Choosing a language model backend

These are the backends that run language models on a Strix Halo under Linux.
`ryzenai-llm:npu` requires Windows, and `llamacpp:cuda` and `llamacpp:metal`
need other hardware.

| Backend | Tier, format | What it is | Models |
| :--- | :--- | :--- | :--- |
| `llamacpp:rocm` | core, native | llama.cpp built against ROCm | Any GGUF |
| `llamacpp:vulkan` | core, native | llama.cpp on Vulkan | Any GGUF |
| `llamacpp:cpu` | core, native | llama.cpp on the CPU alone | Any GGUF |
| `llamacpp:nathanw`, `llamacpp:halobox` | guest, container | llama.cpp forks for Strix Halo | Any GGUF |
| `llamacpp-hrx:hrx` | experimental, native | Early access to AMD's experimental HRX GPU backend for llama.cpp | 28 catalog GGUFs; chat only |
| `gufo:rocm`, `rocmfpx:rocm`, `halogen:rocm`, `ds4:rocm` | guest, container | Engines described in [Container backends](container-backends.md#the-backends) | Their own catalogs |
| `flm:npu` | core, native | FastFlowLM, a runtime for the Ryzen AI NPU | 51 NPU model builds, each with its own context limit |
| `vllm:rocm` | experimental, python | vLLM, a serving engine built for batched requests | FP16 safetensors checkpoints |

### Which to run

- **`llamacpp:rocm` is the default**, and the one backend that runs everything.
  Register models with their MTP draft: with one, a 27B generated about twice as fast.
- **Gufo, for the models it covers.** Fastest on every measure for Qwen3.8-27B,
  and 75% faster than DwarfStar4 on the same DeepSeek V4 Flash weights.
- **Halogen, for Qwen3.8-Flash-Next.** The fastest thing measured here by a wide
  margin, at the price of about 90 GiB of memory while it is loaded.
- **ROCm FPX, for its catalog models.** Faster generation than stock llama.cpp
  in less memory.
- **`llamacpp:vulkan` as the fallback.** It matched ROCm at generating and does
  not share ROCm's multi-process bug.
- **`llamacpp:nathanw` when prompts are long and answers short.** It read long
  prompts fastest of the llama.cpp builds and generated slower.
- **`flm:npu` for small models you want off the GPU.** It is not fast, and large
  models get a small context: FastFlowLM allows a 27B at most 8,192 tokens.
- **`vllm:rocm` only to serve many requests at once.** For one request it was
  half the speed of llama.cpp; for 32 at once it delivered 6x the throughput.
- **Skip for now:** `llamacpp:halobox` (no gain over built-in ROCm),
  `llamacpp-hrx` (no MTP drafting in this release, so half the speed of ROCm
  with a draft), and `ds4:rocm` unless you need a model only it has.

### Measurements

Ryzen AI MAX+ 395 with 128 GB, Lemonade 2026.46.2, kernel 7.2.4, using
`lemonade bench`. Tokens per second; higher is better. Generating is the mean
of three 256-token replies; prompt columns are one run each.

**Qwen3.8-27B, 4-bit.** Each backend used the draft its registration ships with.

| Backend | Weights | Generating | Reading a 3K prompt | Reading a 25K prompt | First token after 25K |
| :--- | :--- | ---: | ---: | ---: | ---: |
| `gufo:rocm` | UD-Q4_K_XL | **30.8** | **585** | **559** | **44 s** |
| `rocmfpx:rocm` | ROCmFP4 Q4_0 | 28.0 | 383 | 351 | 71 s |
| `llamacpp:rocm` | UD-Q4_K_XL | 23.8 | 340 | 325 | 76 s |
| `llamacpp:vulkan` | UD-Q4_K_XL | 23.0 | 343 | 320 | 78 s |
| `llamacpp:nathanw` | UD-Q4_K_XL | 21.0 | 344 | 412 | 60 s |
| `llamacpp:halobox` | UD-Q4_K_XL | 20.3 | 401 | 351 | 71 s |
| `llamacpp-hrx:hrx` | Q4_K_M, no draft | 11.5 | 294 | 360 | 69 s |
| `flm:npu` | NPU build | 2.0 | 114 | n/a | n/a |

`llamacpp-hrx` cannot use a draft model yet. On the same file with no draft,
`llamacpp:rocm` generated 11.9 tokens/s and HRX 11.4, so the two engines are
level and the gap above is MTP drafting. FastFlowLM caps this model at 8,192
tokens of context, so the 25K prompt does not apply.

**Large models.** Different models, so compare within a model only.

| Backend | Model | Generating | Reading a 3K prompt | Reading a 25K prompt | First token after 25K | Memory |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: |
| `halogen:rocm` | Qwen3.8-Flash-Next, 119 GB | 63.5 | 1,833 | 1,990 | 12 s | 90 GiB |
| `gufo:rocm` | DeepSeek-V4-Flash IQ2XXS, 86 GB | 26.9 | 379 | 444 | 53 s | 92 GB |
| `ds4:rocm` | DeepSeek-V4-Flash IQ2XXS, 86 GB | 15.4 | about 220 | about 360 | 67 s | 97 GB |

Halogen reports 90 GiB in all at its default 262,144-token context: 63 GiB of
locked weights, a KV pool and working memory. It reads a further 48 GiB lookup
table from the file cache on demand. `free` counts the locked weights as
reclaimable cache, so it understates what Halogen holds. DwarfStar4 reports no timing split; its
prompt figures are derived from total request time.

**27B at 16-bit, and concurrency.** Qwen3.6-27B as BF16 GGUF on `llamacpp:rocm`
against FP16 safetensors on `vllm:rocm`.

| Backend | One request | 8 at once | 32 at once | Answer after a 25K prompt | GPU memory |
| :--- | ---: | ---: | ---: | ---: | ---: |
| `llamacpp:rocm` | 9.6 | 8.5 total | not run | 72 s | 53 GB |
| `vllm:rocm` | 4.3 | 30.0 total | 55.3 total | 98 s | 61 GB |

Lemonade runs `llama-server` with one slot, so simultaneous requests queue.
vLLM batches them. It also takes minutes to load, and compiles kernels the
first time it sees a model.

**A small model.** Gemma 4 E2B at 4-bit.

| Backend | Generating | Reading a 25K prompt |
| :--- | ---: | ---: |
| `llamacpp:rocm` with MTP draft | 174 | 6,500 |
| `flm:npu` | 24.5 | 707 |

These are speeds on a handful of models and say nothing about output quality.
Quantizations differ between rows where the Weights column says so.
`llamacpp:cpu` was not measured. Compare on your own models with:

```fish
lemonade bench MODEL --backend rocm --backend vulkan --scenarios chat --scenarios context-32k
```

## Installing

`install` wraps Lemonade's install API. Recipes and backends complete with Tab,
straight from the running server, with each backend's state and format beside it.

```fish
install llamacpp rocm        # one backend
install llamacpp:nathanw     # the same, as recipe:backend
install gufo                 # a recipe's default backend
install --all                # everything config.json marks for installation
```

`--stream` shows download progress, and `--force` bypasses Lemonade's hardware
filtering. Installing an installed backend updates it to the version Lemonade
currently pins.

### Declaring what to install

`install --all` reads an `install` key from each section of
`/root/.cache/lemonade/config.json`. Lemonade ignores the key, so it is safe to
keep beside the server's own settings:

```json
{
  "llamacpp": { "backend": "rocm", "install": ["rocm", "vulkan", "nathanw"] },
  "whispercpp": { "backend": "rocm", "install": true },
  "gufo": { "install": true }
}
```

- `"install": true` installs the section's `backend`. When that is unset or
  `auto`, it installs the recipe's default backend.
- `"install": [...]` installs each named backend.

After pulling a new image, `install --all` brings every backend up to the
versions that release expects.

## Backend executables on PATH

Backend executables are added to `PATH` automatically in Fish, including FLM,
llama.cpp, Whisper, Stable Diffusion, and installed ROCm utilities. The list
refreshes at each prompt, so newly installed backends appear in an open shell.
Among managed binaries, the configured backend takes precedence; existing system
PATH entries retain their priority. Use `type -a llama-server` to see alternatives.

```fish
backend-path --list       # refresh and show the added directories
flm list
llama-server --version
```

Container backends have nothing to run here; their marker directories stay off
`PATH`.

## Inspecting versions and ROCm

Run `versions` for a combined inventory of backend package versions, every
installed backend variant, ROCm runtimes, and executable paths. It reads local
`version.txt` and `versions.txt` markers (including multiline build details),
so ROCm llama.cpp release tags are preserved even when `llama-server --version`
reports a different upstream build number. Missing backend families are listed
too; directories without version markers are reported as unknown. The inventory
describes packages on disk, not versions of already-running processes.

These commands are available in Fish when the installed runtime supplies them;
`rocm-info` is a helper included with this image.

| Command | What it tells you |
| --- | --- |
| `rocm-info` | Installed ROCm runtime versions, locations, and available diagnostic binaries. Start here. |
| `hipconfig --version` | HIP version for the installation selected by `PATH`; `hipconfig --full` shows its configuration. |
| `rocminfo` | Devices visible to the HSA runtime and their GPU architecture identifiers, such as `gfx1151`. |
| `amd-smi --help` | Available AMD GPU monitoring commands for utilization, memory, temperature, and other supported metrics. |
| `rocm-smi --help` | Available commands for the older ROCm GPU monitoring utility. |
| `rocm-sdk --help` | Options for inspecting the wheel-based ROCm SDK, when installed. |

Lemonade downloads ROCm/TheRock on demand; the image does not install one global
ROCm SDK. Multiple runtime versions may coexist, including a separate vLLM
bundle. `rocm-info` reports their version markers and paths; `hipconfig` alone
reports the first tool on PATH, not necessarily the runtime every backend uses.
`LEMONADE_BACKEND_DIR` overrides the discovered backend cache directory.
The shell setup does not mix their `LD_LIBRARY_PATH` or Python environments.

For a container backend, `versions` shows the image pin and whether that image
is still present on the Docker host.
