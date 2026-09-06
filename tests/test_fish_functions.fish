# An interactive fish config can define its own `path` helper, which shadows the
# `path` builtin these functions rely on. Drop it so the tests exercise the real
# code rather than the surrounding shell.
functions -e path

set -g tests_failed 0

function assert_contains --argument-names expected description
    set -l values $argv[3..-1]
    if not contains -- "$expected" $values
        echo "FAIL: $description" >&2
        echo "  missing: $expected" >&2
        set -g tests_failed (math $tests_failed + 1)
    end
end

function assert_not_contains --argument-names unexpected description
    set -l values $argv[3..-1]
    if contains -- "$unexpected" $values
        echo "FAIL: $description" >&2
        echo "  unexpected: $unexpected" >&2
        set -g tests_failed (math $tests_failed + 1)
    end
end

function assert_equal --argument-names expected actual description
    if test "$expected" != "$actual"
        echo "FAIL: $description" >&2
        echo "  expected: $expected" >&2
        echo "  actual:   $actual" >&2
        set -g tests_failed (math $tests_failed + 1)
    end
end

function assert_path_missing --argument-names target description
    if test -e "$target"; or test -L "$target"
        echo "FAIL: $description" >&2
        echo "  still exists: $target" >&2
        set -g tests_failed (math $tests_failed + 1)
    end
end

function assert_path_exists --argument-names target description
    if not test -e "$target"; and not test -L "$target"
        echo "FAIL: $description" >&2
        echo "  missing: $target" >&2
        set -g tests_failed (math $tests_failed + 1)
    end
end

set -l repo_root (path resolve (path dirname (status filename))/..)
source "$repo_root/functions/pull.fish"

set -g pull_fixture '{
  "source":"huggingface",
  "recipe":"llamacpp",
  "repo_kind":"gguf",
  "suggested_name":"Qwen3.8-27B-GGUF",
  "suggested_labels":["chat","vision","mtp"],
  "mmproj_files":["mmproj-BF16.gguf","mmproj-F16.gguf"],
  "draft_files":["mtp-Qwen3.8-27B-Q4_0.gguf"],
  "variants":[{
    "name":"UD-Q4_K_XL",
    "primary_file":"Qwen3.8-27B-UD-Q4_K_XL.gguf",
    "files":["Qwen3.8-27B-UD-Q4_K_XL.gguf"],
    "draft_file":"MTP/mtp-Qwen3.8-27B-Q4_0.gguf",
    "size_bytes":17179869184
  }]
}'

function __pull_api
    echo $pull_fixture
end

function __pull_cli_exec
    set -g pull_cli_args $argv
end

function __pull_resolve_hf_companion --argument-names checkpoint filename
    echo $filename
end

# Exercise the command substitution used by interactive pulls. Menu output must
# remain visible on stderr without contaminating the selected checkpoint.
set -l menu_output (mktemp)
for answer in '' 1 ud-q4_k_xl
    set -l selected (printf '%s\n' "$answer" | __pull_prompt_variant "$pull_fixture" 2>$menu_output)
    assert_equal 0 $status 'variant prompt accepts default, index, and name'
    assert_equal 1 (count $selected) 'variant prompt emits exactly one value'
    assert_equal UD-Q4_K_XL "$selected" 'variant prompt returns only the canonical variant'
end
assert_contains 'Select a main GGUF variant:' 'variant menu is displayed on stderr' (cat $menu_output)
for answer in 0 2 unknown
    set -l selected (printf '%s\n' "$answer" | __pull_prompt_variant "$pull_fixture" 2>$menu_output)
    assert_equal 1 $status 'invalid variant selection fails'
    assert_equal 0 (count $selected) 'invalid variant selection emits no value'
end
set -l selected (__pull_prompt_variant "$pull_fixture" </dev/null 2>$menu_output)
assert_equal 1 $status 'EOF cancels variant selection'
assert_equal 0 (count $selected) 'cancelled selection emits no value'
rm -- $menu_output

# Simulate terminal input while keeping all server and download calls stubbed.
# Multiple global drafts must not override the selected variant's draft_file.
set -l original_fixture $pull_fixture
set pull_fixture (printf '%s\n' "$pull_fixture" | jq -c '.draft_files += ["mtp-other-BF16.gguf"]')
function isatty
    return 0
end
functions -c __pull_prompt_variant __test_prompt_variant
function __pull_prompt_variant --argument-names variants
    printf '\n' | __test_prompt_variant "$variants"
end
set -g pull_cli_args
set -l prompt_input (mktemp)
printf '\n\n' >$prompt_input
pull unsloth/Qwen3.8-27B-GGUF <$prompt_input >/dev/null 2>/dev/null
assert_equal 0 $status 'interactive pull accepts default variant and model name'
assert_contains 'user.Qwen3.8-27B-GGUF-UD-Q4_K_XL' 'interactive default name contains only the variant' $pull_cli_args
assert_contains 'unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_XL' 'interactive main checkpoint contains only the variant' $pull_cli_args
assert_contains 'unsloth/Qwen3.8-27B-GGUF:MTP/mtp-Qwen3.8-27B-Q4_0.gguf' \
    'interactive pull resolves the variant-specific draft despite multiple global drafts' $pull_cli_args
rm -- $prompt_input
functions -e isatty __pull_prompt_variant
functions -c __test_prompt_variant __pull_prompt_variant
functions -e __test_prompt_variant
set pull_fixture $original_fixture

pull --yes --quant UD-Q4_K_XL unsloth/Qwen3.8-27B-GGUF >/dev/null
assert_contains 'unsloth/Qwen3.8-27B-GGUF:MTP/mtp-Qwen3.8-27B-Q4_0.gguf' \
    'pull preserves the repository-relative MTP path' $pull_cli_args
assert_contains draft 'pull registers the draft checkpoint role' $pull_cli_args
assert_contains mmproj 'pull registers the projector checkpoint role' $pull_cli_args
assert_contains mtp 'pull applies the MTP label' $pull_cli_args
assert_contains vision 'pull retains advertised labels' $pull_cli_args

set -g pull_cli_args
pull --yes --no-draft --no-mmproj unsloth/Qwen3.8-27B-GGUF >/dev/null
assert_not_contains draft '--no-draft omits the draft checkpoint role' $pull_cli_args
assert_not_contains mtp '--no-draft removes the companion-derived MTP label' $pull_cli_args
assert_not_contains mmproj '--no-mmproj omits the projector checkpoint role' $pull_cli_args
assert_not_contains vision '--no-mmproj removes the companion-derived vision label' $pull_cli_args

set -g pull_cli_args
pull --yes Qwen3-0.6B-GGUF >/dev/null
assert_equal 'pull Qwen3-0.6B-GGUF' (string join ' ' $pull_cli_args) \
    'registered models pass through without manual re-registration'

set -g pull_fixture '{
  "source":"huggingface",
  "recipe":"llamacpp",
  "repo_kind":"gguf",
  "suggested_name":"Legacy-GGUF",
  "suggested_labels":["chat"],
  "mmproj_files":[],
  "draft_files":["mtp-Legacy-Q4_0.gguf"],
  "variants":[{"name":"Q4_K_M","files":["Legacy-Q4_K_M.gguf"],"size_bytes":1}]
}'
function __pull_resolve_hf_companion
    echo 'MTP/mtp-Legacy-Q4_0.gguf'
end
set -g pull_cli_args
pull --yes legacy/Legacy-GGUF >/dev/null
assert_contains 'legacy/Legacy-GGUF:MTP/mtp-Legacy-Q4_0.gguf' \
    'pull repairs the flattened draft path from older servers' $pull_cli_args
assert_contains mtp 'legacy MTP discovery adds the missing label' $pull_cli_args

set -g repair_model_json '{
  "id":"user.Legacy-Q4",
  "checkpoint":"legacy/Legacy-GGUF:Q4_K_M",
  "checkpoints":{"main":"legacy/Legacy-GGUF:Q4_K_M"},
  "recipe":"llamacpp",
  "source":"huggingface",
  "registry_source":"huggingface",
  "labels":["chat"],
  "recipe_options":{"ctx_size":8192}
}'
set -g repaired_registration
function __pull_api --argument-names method path body timeout
    switch "$method $path"
        case 'GET /api/v1/models/user.Legacy-Q4'
            echo $repair_model_json
        case 'GET /api/v1/pull/variants?checkpoint=legacy/Legacy-GGUF&source=huggingface'
            echo $pull_fixture
        case 'POST /api/v1/models/register'
            set -g repaired_registration $body
            echo '{"status":"success"}'
        case '*'
            echo '{}'
    end
end
function __pull_refresh_registered
    if test "$repair_pull_fails" = true
        return 1
    end
    return 0
end
pull --yes --repair-mtp Legacy-Q4 >/dev/null
set -l repaired_draft (printf '%s\n' "$repaired_registration" | jq -r '.checkpoints.draft')
assert_equal 'legacy/Legacy-GGUF:MTP/mtp-Legacy-Q4_0.gguf' $repaired_draft \
    'repair-mtp adds the discovered draft to the existing registration'
set -l repaired_ctx (printf '%s\n' "$repaired_registration" | jq -r '.recipe_options.ctx_size')
assert_equal 8192 $repaired_ctx \
    'repair-mtp preserves existing recipe options while adding the draft'

set -g repair_pull_fails true
pull --yes --repair-mtp Legacy-Q4 >/dev/null 2>/dev/null
set -l repair_failure_status $status
assert_equal 1 $repair_failure_status \
    'repair-mtp reports a failed companion download'
set -l restored_draft (printf '%s\n' "$repaired_registration" | jq -r '.checkpoints.draft // empty')
assert_equal '' "$restored_draft" \
    'repair-mtp restores the original registration after a failed pull'
set -e repair_pull_fails

source "$repo_root/completions/pull.fish"
set -g pull_completion_fixture '{
  "variants":[{
    "name":"Q4_K_M",
    "size_bytes":1,
    "draft_file":"MTP/mtp-Legacy-Q4_0.gguf"
  }],
  "draft_files":["mtp-Legacy-Q4_0.gguf"],
  "mmproj_files":[]
}'
function __pull_completion_api
    echo $pull_completion_fixture
end

set -l quant_completion (complete -C 'pull legacy/Legacy-GGUF --quant ')
set -l quant_parts (string split \t -- $quant_completion[1])
assert_equal Q4_K_M $quant_parts[1] \
    'quant completion retains repository context after a value-taking option'

set -l draft_completion (complete -C 'pull unsloth/Qwen3.8-27B-GGUF --draft ')
set -l draft_parts (string split \t -- $draft_completion[1])
assert_equal 'MTP/mtp-Legacy-Q4_0.gguf' $draft_parts[1] \
    'draft completion prefers the preserved repository-relative path'

source "$repo_root/functions/update.fish"
function __update_cli
    echo lemonade
end
set -g pull_cli_args
__update_pull user.Legacy-Q4 >/dev/null
assert_equal 'pull user.Legacy-Q4' (string join ' ' $pull_cli_args) \
    'update re-pulls registered models through the enhanced pull function'

source "$repo_root/functions/delete.fish"
set -l sandbox (mktemp -d)
set -g delete_storage "$sandbox/hub"
set -g delete_repo "$delete_storage/models--unsloth--Model"
set -g delete_lock "$delete_storage/.locks/models--unsloth--Model"
mkdir -p "$delete_repo/snapshots/revision" "$delete_lock"
printf model >"$delete_repo/snapshots/revision/Model-Q4_K_M.gguf"
printf lock >"$delete_lock/download.lock"

set -g delete_before (printf '{"data":[{"id":"BuiltIn","source":"huggingface","registry_source":"huggingface","checkpoints":{"main":"unsloth/Model:Q4_K_M"},"recipe":"llamacpp","downloaded":true,"components":[]}]}')
# Built-in models remain in show_all after deletion with downloaded=false. The
# cleanup must exclude the model just deleted while still respecting other users.
set -g delete_after (printf '{"data":[{"id":"BuiltIn","source":"huggingface","registry_source":"huggingface","checkpoints":{"main":"unsloth/Model:Q4_K_M"},"recipe":"llamacpp","downloaded":false,"components":[]}]}')
set -g delete_inventory_calls 0

function __delete_inventory
    set -g delete_inventory_calls (math $delete_inventory_calls + 1)
    if test $delete_inventory_calls -eq 1
        echo $delete_before
    else
        echo $delete_after
    end
end

function __delete_api --argument-names method path body timeout
    switch $path
        case /api/v1/health
            echo '{"status":"ok"}'
        case '/api/v1/models/BuiltIn/files?include_paths=true'
            printf '{"files":[{"name":"Model-Q4_K_M.gguf","role":"main","path":"%s/snapshots/revision/Model-Q4_K_M.gguf","size_bytes":5,"exists":true}]}\n' $delete_repo
        case /api/v1/downloads
            echo '[]'
        case /api/v1/system-info
            printf '{"model_storage":{"path":"%s"}}\n' $delete_storage
        case /api/v1/delete
            echo '{"status":"success"}'
        case /internal/cleanup-cache
            echo '{"total_bytes":0,"orphaned_files":[]}'
        case '*'
            echo '{}'
    end
end

delete --yes BuiltIn >/dev/null
assert_path_missing "$delete_repo" 'delete removes an unshared repository cache'
assert_path_missing "$delete_lock" 'delete removes the matching Hugging Face lock directory'

set -l shared_repo "$delete_storage/models--unsloth--Shared"
set -l shared_snapshot "$shared_repo/snapshots/revision"
mkdir -p "$shared_snapshot"
set -l shard_one "$shared_snapshot/Shared-00001-of-00002.gguf"
set -l shard_two "$shared_snapshot/Shared-00002-of-00002.gguf"
printf one >"$shard_one"
printf two >"$shard_two"
set -l shared_record "user.Shared"\tmain\t"$shard_one"\t3

__delete_remove_shared_leftovers "$shared_record" --successful user.Shared --keep >/dev/null
assert_path_missing "$shard_one" 'shared-cache cleanup removes the resolved shard'
assert_path_missing "$shard_two" 'shared-cache cleanup removes every shard in the same family'

mkdir -p "$shared_snapshot"
printf one >"$shard_one"
printf two >"$shard_two"
__delete_remove_shared_leftovers "$shared_record" --successful user.Shared --keep "$shard_one" >/dev/null
assert_path_exists "$shard_one" 'shared-cache cleanup keeps a path claimed by another model'
assert_path_exists "$shard_two" 'keeping the primary shard keeps its entire shard family'

rm -rf -- "$sandbox"

# --- leftover cache directories -------------------------------------------

set -l cache_sandbox (mktemp -d)
set -g delete_storage "$cache_sandbox/hub"
set -g pinned_dir "$delete_storage/models--unsloth--Pinned"
set -g local_dir "$delete_storage/models--unsloth--Local"
set -g orphan_dir "$delete_storage/models--unsloth--Orphan"
set -g orphan_lock "$delete_storage/.locks/models--unsloth--Orphan"
set -g claimed_dir "$delete_storage/models--unsloth--Claimed"
set -g odd_dir "$delete_storage/models--unsloth--Odd--Name"

mkdir -p "$pinned_dir/snapshots/rev" "$local_dir/snapshots/rev" "$orphan_dir/snapshots/rev" \
    "$claimed_dir/snapshots/rev" "$odd_dir/snapshots/rev" "$orphan_lock"
printf pinned >"$pinned_dir/snapshots/rev/Pinned-Q4.gguf"
printf local >"$local_dir/snapshots/rev/Local-Q4.gguf"
printf orphan >"$orphan_dir/snapshots/rev/Orphan-Q4.gguf"
printf claimed >"$claimed_dir/snapshots/rev/Claimed-Q4.gguf"
printf odd >"$odd_dir/snapshots/rev/Odd-Q4.gguf"
printf lock >"$orphan_lock/download.lock"

# user.Pinned shares its repository with a built-in that is registered but holds
# nothing on disk. user.Local reports a local origin in `source`, so only
# `registry_source` identifies the registry that owns its directory, and it
# resolves no files, so the checkpoint is the only route to its directory.
set -g cache_models '[
  {"id":"user.Pinned","source":"huggingface","registry_source":"huggingface","checkpoints":{"main":"unsloth/Pinned:Pinned-Q4.gguf"},"recipe":"llamacpp","downloaded":true,"components":[]},
  {"id":"Pinned-GGUF","source":"huggingface","registry_source":"huggingface","checkpoints":{"main":"unsloth/Pinned:Pinned-Q4.gguf"},"recipe":"llamacpp","downloaded":false,"components":[]},
  {"id":"user.Local","source":"local_upload","registry_source":"huggingface","checkpoints":{"main":"unsloth/Local:Local-Q4.gguf"},"recipe":"llamacpp","downloaded":true,"components":[]},
  {"id":"user.Claimed","source":"huggingface","registry_source":"huggingface","checkpoints":{"main":"unsloth/Claimed:Claimed-Q4.gguf"},"recipe":"llamacpp","downloaded":true,"components":[]}
]'

function __cache_inventory --argument-names deleted
    printf '{"data":%s}\n' (printf '%s' $cache_models | jq -c --arg deleted "$deleted" \
        'map(select(.id != $deleted))')
end

# The first read is the inventory the delete is planned against; every later
# read is the inventory the server reports once the registration is gone.
set -g cache_deleted ''
set -g cache_reads 0
function __delete_inventory
    set -g cache_reads (math $cache_reads + 1)
    if test $cache_reads -eq 1
        __cache_inventory ''
    else
        __cache_inventory "$cache_deleted"
    end
end

function __delete_api --argument-names method path body timeout
    switch $path
        case /api/v1/health
            echo '{"status":"ok"}'
        case '/api/v1/models/user.Pinned/files?include_paths=true'
            printf '{"files":[{"name":"Pinned-Q4.gguf","role":"main","path":"%s/snapshots/rev/Pinned-Q4.gguf","size_bytes":6}]}\n' $pinned_dir
        case '/api/v1/models/user.Claimed/files?include_paths=true'
            printf '{"files":[{"name":"Claimed-Q4.gguf","role":"main","path":"%s/snapshots/rev/Claimed-Q4.gguf","size_bytes":7}]}\n' $claimed_dir
        case /api/v1/system-info
            printf '{"model_storage":{"path":"%s"}}\n' $delete_storage
        case /api/v1/downloads
            echo '[]'
        case /api/v1/delete
            echo '{"status":"success"}'
        case /internal/cleanup-cache
            echo '{"total_bytes":0,"orphaned_files":[]}'
        case '*'
            echo '{}'
    end
end

set cache_deleted user.Pinned
set cache_reads 0
delete --yes user.Pinned >/dev/null
assert_path_missing "$pinned_dir" \
    'a registration holding no files does not pin a repository directory'
assert_path_exists "$claimed_dir" \
    'a directory another downloaded model claims is left alone'

set cache_deleted user.Local
set cache_reads 0
delete --yes user.Local >/dev/null
assert_path_missing "$local_dir" \
    'the registry comes from registry_source when source carries a local origin'

set cache_deleted ''
set cache_reads 0

# A directory nothing claims is deletable by repository id, by directory name,
# and reports the lock directory with it.
delete --yes unsloth/Orphan >/dev/null
assert_path_missing "$orphan_dir" 'a leftover directory is deletable by repository id'
assert_path_missing "$orphan_lock" 'deleting a leftover directory takes its lock directory'

mkdir -p "$odd_dir/snapshots/rev"
delete --yes models--unsloth--Odd--Name >/dev/null
assert_path_missing "$odd_dir" 'a leftover directory is deletable by directory name'

delete --yes unsloth/Claimed >/dev/null 2>/dev/null
set -l claimed_status $status
assert_equal 1 $claimed_status 'deleting a claimed directory is refused'
assert_path_exists "$claimed_dir" 'a refused delete leaves the claimed directory in place'

delete --dry-run --yes unsloth/Claimed >/dev/null 2>/dev/null
mkdir -p "$orphan_dir/snapshots/rev"
printf orphan >"$orphan_dir/snapshots/rev/Orphan-Q4.gguf"
delete --dry-run unsloth/Orphan >/dev/null
assert_path_exists "$orphan_dir" 'a dry run leaves leftover directories in place'

# --- completions ----------------------------------------------------------

source "$repo_root/completions/delete.fish"

function __delete_completion_get --argument-names path
    switch $path
        case /internal/aliases
            echo '{"aliases":[]}'
        case '*'
            printf '{"data":%s}\n' $cache_models
    end
end

function __delete_completion_cache_dir
    echo $delete_storage
end

set -l offered
for line in (__delete_completion_targets)
    set -a offered (string split \t -- $line)[1]
end

assert_contains unsloth/Orphan 'completion offers a cache directory no model claims' $offered
assert_not_contains unsloth/Claimed \
    'completion leaves out a directory a downloaded model claims' $offered
assert_contains user.Claimed 'completion still offers registered models' $offered

mkdir -p "$delete_storage/models--unsloth--Odd--Name" "$delete_storage/datasets--foo--bar"
set offered
for line in (__delete_completion_targets)
    set -a offered (string split \t -- $line)[1]
end
assert_contains models--unsloth--Odd--Name \
    'a directory name that does not map back to a repository id is offered as itself' $offered
assert_not_contains datasets--foo--bar 'completion ignores non-model cache directories' $offered

rm -rf -- "$cache_sandbox"

fish --no-config "$repo_root/tests/test_repair_mtp.fish"
or set -g tests_failed (math $tests_failed + 1)
fish --no-config "$repo_root/tests/test_flm_functions.fish"
or set -g tests_failed (math $tests_failed + 1)
fish --no-config "$repo_root/tests/test_backend_path.fish"
or set -g tests_failed (math $tests_failed + 1)
fish --no-config "$repo_root/tests/test_versions.fish"
or set -g tests_failed (math $tests_failed + 1)

if test $tests_failed -gt 0
    echo "$tests_failed test(s) failed." >&2
    exit 1
end

echo 'All Fish function tests passed.'
