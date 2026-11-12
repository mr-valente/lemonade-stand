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
