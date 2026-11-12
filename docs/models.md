# Managing models

The model commands wrap Lemonade's API and CLI with safer workflows and live tab
completion. Run them in the container's Fish shell: `docker exec -it lemonade-stand fish`.


## Pulling

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

A repository usually ships MTP companions at several quants, and the one a
variant advertises is only its recommendation. When more than one is available,
an interactive pull offers the same menu `--mtp` does, with the recommended
companion as the default:

```
Select an MTP/draft companion:
  1) MTP/mtp-gemma-4-E2B-it-BF16.gguf
  2) MTP/mtp-gemma-4-E2B-it-Q8_0.gguf
  3) mtp-gemma-4-E2B-it.gguf
  n) None: do not install a draft
Draft [1]:
```

`--yes`, `--draft PATH`, and `--no-draft` all skip the menu. A companion chosen
by bare filename is resolved back to its repository path before registration.

To add, replace, or remove an already-registered custom model's draft
checkpoint, use its public (bare) name or its internal `user.*` name:

```fish
# Choose a draft interactively; Enter keeps an existing draft
pull --mtp Qwen3.8-27B-GGUF-UD-Q4_K_XL

# Explicit replacement, without prompting
pull --mtp gemma-4-12B-it-qat-GGUF-UD-Q4_K_XL \
  --draft MTP/mtp-gemma-4-12B-it-Q4_0.gguf --yes

# Drop the draft entirely and delete its weights
pull --mtp gemma-4-12B-it-qat-GGUF-UD-Q4_K_XL --no-draft --yes
```

`--mtp` inspects that model's saved repository and quant, adds the matching
MTP checkpoint while preserving its recipe options, then downloads it. `--yes`
alone refreshes an existing draft; it never chooses a replacement automatically.
Replacing a draft unloads the model and leaves it ready to load with the new
draft; a model that is not currently loaded is simply left alone. The old registration is restored automatically if the download fails,
and the old files stay in place. After success, only the previous draft's resolved
cache files are deleted, and files still referenced by another model are kept.
If reference checks fail, cleanup is skipped and the command reports that the
replacement succeeded but old files may remain. Ordinary `update` runs refresh
the selected MTP alongside the main checkpoint.

Removing a draft is the same operation without a download. When a model has one
registered, the menu grows an `n) None` entry, and `--no-draft` selects it
without prompting:

```
Select an MTP/draft companion:
  0) Keep and refresh org/Model:MTP/mtp-old-BF16.gguf
  1) MTP/mtp-new-Q4_0.gguf
  n) None: deregister and delete the current draft
Draft [0]:
```

The model is unloaded, re-registered without its `draft` checkpoint — every
other checkpoint, `mmproj` included, is preserved — and only then are the old
draft's cache files deleted, under the same sharing checks a replacement uses.
The main weights are never touched and are not re-downloaded.

## Faster pulls

Lemonade downloads each file over a single connection, and Hugging Face shapes
per-connection throughput, so a pull leaves most of the link idle. `fastpull`
pre-seeds the cache using several ranged connections per file, then hands off to
`pull` for registration:

```fish
# Same arguments as pull
fastpull unsloth/Qwen3.8-27B-GGUF --quant UD-Q4_K_XL --yes

# More or fewer connections per file (default 8)
fastpull unsloth/Qwen3.8-27B-GGUF --streams 16 --yes
```

Measured on a 2.5 Gb/s link pulling a 3.1 GB model (main GGUF + projector), with
another download and a llama-server running concurrently:

| | Wall time | Effective |
|---|---|---|
| `pull` | 192 s | ~16 MB/s |
| `fastpull` | 45 s | ~69 MB/s |

Throughput plateaus around 8 connections; more than that buys very little. Set a
different default with `LEMONADE_FASTPULL_STREAMS`.

Every pre-seeded file is checked against the sha256 Hugging Face advertises, and
Lemonade verifies it again when it registers the model, so a corrupted transfer
cannot be registered. Anything `fastpull` cannot pre-seed — an unreachable
repository, a variant it cannot match, an ambiguous draft companion — is simply
left for `pull` to download the usual way, so the result is identical either way.

## Loading

```fish
# Load a single model
load Qwen3-0.6B-GGUF

# Load with per-request recipe options
load Qwen3-0.6B-GGUF --ctx_size 8192 --llamacpp_backend vulkan --llamacpp_args "--no-context-shift --no-mmap" --save_options true

# Load multiple models
load Qwen3-0.6B-GGUF user.nomic-embed

# Load a named set (see Model Sets below)
load --set coding

# Load a GGUF on a container backend (see Container backends)
load user.Qwen3.8-27B-GGUF-UD-Q4_K_XL --llamacpp_backend nathanw
```

Recipes that are container backends, such as `gufo` and `rocmfpx`, have their
own catalog models; those load by name alone. See
[Container backends](container-backends.md).

## Unloading

```fish
# Unload a specific model
unload Qwen3-0.6B-GGUF

# Unload all loaded models
unload --all
```

## Updating

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

Registry models are upgraded **in place**: `update` re-pulls the model under its existing
registration, so the new revision is downloaded alongside the old one and the
server only switches over once it is complete. Nothing is deleted first, so a
failed or interrupted download always leaves the working model intact — and the
registration in `user_models.json` (all checkpoints, quant, recipe options) is
never lost the way it is when you delete a model and pull it again. `update`
uses the enhanced `pull` path, so already-registered MTP/draft checkpoints are
refreshed along with the main weights; use `pull --mtp` once to add a draft
that was missing from an older registration, or `pull --mtp NAME --no-draft` to
drop one for good. Its prune keep-set also
includes every checkpoint reported by the model-files API.

If a model is loaded when it is updated, it is unloaded first — otherwise the
running backend keeps serving the old weights — and reloaded afterwards. Pass
`--no-reload` to leave it unloaded.

| Option | Description |
| :--- | :--- |
| `-a`, `--all` | Update pending registry and FLM models. |
| `-c`, `--check` | List pending updates and exit. |
| `-f`, `--force` | Re-pull even when no update is reported, and ignore the free-space check. |
| `-n`, `--dry-run` | Show what would be done, change nothing. |
| `-y`, `--yes` | Do not prompt for confirmation. |
| `-p`, `--prune` | Delete superseded weights after a successful update. |
| `--no-reload` | Leave models unloaded instead of restoring them. |

### FLM models

FLM (NPU) models use their own storage and downloader. `update --check` and
`update --all` now include models whose `flm list` output says the local version
is below the catalog requirement (`Local model ... version: ... < ...`). These
can appear as `downloaded: false` in Lemonade even though their weights exist.
Current FLM models are skipped unless explicitly forced. A `>` warning means
the FLM backend needs updating; it does not trigger a model re-download.
This checks FLM compatibility requirements, not arbitrary upstream file changes.

```fish
update --check
update --all
update gemma4-it-e2b-FLM
update gemma4-it-e4b-FLM --force  # explicitly refresh current weights
```

FLM updates files in place and does not provide the registry downloader's
snapshot rollback guarantee. The function rechecks FLM after a successful pull
and reports failure if the model is still outdated or incomplete.

### Reclaiming disk space

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

## Deleting

`delete` previews and confirms destructive work, asks Lemonade to unload and
delete each model, then removes leftovers that are safe to attribute to it:

```fish
delete --dry-run user.Qwen3.8-27B-GGUF-UD-Q4_K_XL
delete user.Qwen3.8-27B-GGUF-UD-Q4_K_XL
delete --yes user.old-model-1 user.old-model-2
```

The registration itself always goes through `POST /api/v1/delete`, the endpoint
behind `lemonade delete`, so Lemonade drops the model from `user_models.json`
and from the server's own model cache exactly as its own command would — an FLM
model is removed with `flm remove`, and a built-in stays registered with
`downloaded: false`. Nothing is deleted from disk behind the server's back.

Two things Lemonade's delete leaves behind are handled here. **Aliases** are one:
the server never touches `aliases.json`, so an alias outlives the model it names
and reappears the moment something else claims that name. Every alias that
resolves to a deleted model — through a chain of aliases, if it takes one — is
listed in the preview and removed with it, using the same endpoint as `lemonade
alias remove`. **Stale registry state** is the other: a `success` response is not
proof, so the registry is read back afterwards, and a model the server still
reports as `downloaded` is called out and fails the command instead of looking
deleted.

The cleanup cancels an active download before touching its files, clears stopped
download records, removes a repository cache and its lock directory only when no
remaining model still holds files there, and removes unreferenced files from
shared caches. It also runs Lemonade's legacy multi-repository orphan sweep.
`--no-cleanup` limits the operation to Lemonade's built-in delete behavior;
alias removal is deregistration rather than tidying, so it still runs.

A model registered from a local path (`"source": "local_path"`) is refused up
front. Lemonade resolves such a model straight to your own file and its delete
looks for a `models--` cache directory above it, so the call fails with a 500
and leaves the registration in place; the error says so and names the file
rather than relaying that.

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

FLM cleanup also covers outdated, partial, and unregistered weights under
`/root/.config/flm/models` (or the configured `FLM_MODEL_PATH` / XDG locations).
It maps Lemonade's `recipe: flm` and checkpoint to FLM's catalog, then removes
only the planned model directory after native deletion succeeds. Nested files
are included; directories shared by other registrations and symlinks are
protected. If the registry cannot be checked, cleanup is skipped with an error.

```fish
delete --dry-run gemma4-it-e2b-FLM
delete --yes gemma4-it:e2b        # native FLM checkpoint tag
# A leftover directory can also be named, even after catalog removal:
delete --dry-run LFM2-2.6B-NPU2
```

Collections are deliberately not cascade-deleted: deleting a collection removes
the collection entry, while its components stay installed. Name those component
models explicitly if they should also be deleted.

## Tab completion

The model-management functions support tab completion:

- `pull` + Tab — shows registered models; `--quant`, `--draft`, and `--mmproj` complete from repository inspection, including `--mtp --draft` against a registered model.
- `load` + Tab — shows all models known to the server plus set names from `model_sets.json`.
- `unload` + Tab — shows only the currently loaded models.
- `update` + Tab — shows downloaded models, including outdated FLM models.
- `delete` + Tab — shows downloaded models, removable `user.*` registrations, and leftover Hugging Face/FLM model directories.

## Model sets

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

## Manual registrations

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
