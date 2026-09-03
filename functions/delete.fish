function __delete_usage
    echo "Usage:"
    echo "  delete <target> [target...] [options]"
    echo ""
    echo "Targets:"
    echo "  A model name, or a leftover cache directory that no model claims."
    echo "  Name such a directory either by repository ('unsloth/Model-GGUF') or"
    echo "  by directory ('models--unsloth--Model-GGUF')."
    echo ""
    echo "Options:"
    echo "  -n, --dry-run      Show models and files without deleting anything"
    echo "  -y, --yes          Do not prompt for confirmation"
    echo "      --no-cleanup   Skip the additional cache and stale-job cleanup"
    echo "  -h, --help         Show this help"
    echo ""
    echo "The server removes each registration first. Cleanup then removes unshared"
    echo "repository caches, stale lock directories, unreferenced shared-repo files,"
    echo "legacy orphans, and stopped download records. Collection components"
    echo "are retained unless they are also named explicitly. A cache directory"
    echo "named on the command line is removed even with --no-cleanup."
end

function __delete_port
    if set -q LEMONADE_PORT; and test -n "$LEMONADE_PORT"
        echo $LEMONADE_PORT
    else
        echo 8000
    end
end

function __delete_api --argument-names method path body timeout
    test -z "$timeout"; and set timeout 120

    set -l curl_args -sS -m $timeout -X $method "http://localhost:"(__delete_port)"$path"
    set -a curl_args -H "Content-Type: application/json"
    if set -q LEMONADE_ADMIN_API_KEY; and test -n "$LEMONADE_ADMIN_API_KEY"
        set -a curl_args -H "Authorization: Bearer $LEMONADE_ADMIN_API_KEY"
    else if set -q LEMONADE_API_KEY; and test -n "$LEMONADE_API_KEY"
        set -a curl_args -H "Authorization: Bearer $LEMONADE_API_KEY"
    end
    if test -n "$body"
        set -a curl_args -d "$body"
    end

    set -l response (curl $curl_args -w '\n%{http_code}' 2>/dev/null)
    or return 2

    set -l code $response[-1]
    set -l payload $response[1..-2]
    if test (count $payload) -gt 0
        string join \n -- $payload
    end

    if string match -qr '^[45]' -- "$code"
        return 1
    end
    return 0
end

function __delete_api_error --argument-names payload
    set -l message (printf '%s\n' "$payload" | jq -r '
        if type == "object" then
            (.error | if type == "object" then (.message // (. | tostring)) else . end)
                // .detail // .message // empty
        else empty end' 2>/dev/null)

    if test -n "$message"; and test "$message" != null
        echo $message
    else if test -n "$payload"
        echo $payload
    else
        echo "no response from the server"
    end
end

function __delete_inventory
    __delete_api GET '/api/v1/models?show_all=true' '' 120
end

function __delete_model_files --argument-names model_name
    set -l encoded (string escape --style=url -- "$model_name")
    set -l payload (__delete_api GET "/api/v1/models/$encoded/files?include_paths=true" '' 60)
    or return 1

    printf '%s\n' "$payload" | jq -r --arg model "$model_name" '
        .files[]? | select((.path // "") != "")
        | [$model, (.role // "unknown"), .path, (.size_bytes // 0 | tostring)] | @tsv' 2>/dev/null
end

function __delete_repo_records --argument-names model_name model_json
    printf '%s\n' "$model_json" | jq -r --arg model "$model_name" '
        # A model that has a local origin reports it in .source
        # (local_path/local_upload/extra_models_dir), so the registry that owns
        # the cache directory lives in .registry_source. Only servers too old to
        # send that field put the registry in .source.
        ((.registry_source // "") | if . == "" then (.source // "") else . end) as $source
        | select($source == "huggingface" or $source == "modelscope")
        | (if ((.checkpoints // {}) | length) > 0
           then .checkpoints
           elif (.checkpoint // "") != ""
           then {main: .checkpoint}
           else {}
           end)[]
        | split(":")[0]
        | select(test("^[^/]+/[^/]+$"))
        | [$model, $source, .] | @tsv' 2>/dev/null
end

function __delete_cache_name --argument-names source repo
    set -l encoded (string replace -a / -- -- "$repo")
    switch $source
        case huggingface
            echo "models--$encoded"
        case modelscope
            echo "modelscope--models--$encoded"
        case '*'
            return 1
    end
end

function __delete_repo_dir --argument-names resolved_path
    set -l current $resolved_path
    while test -n "$current"; and test "$current" != /
        set -l base (path basename "$current")
        if string match -q 'models--*' -- "$base"; or string match -q 'modelscope--models--*' -- "$base"
            echo $current
            return 0
        end
        set current (path dirname "$current")
    end
    return 1
end

function __delete_storage_path
    set -l payload (__delete_api GET /api/v1/system-info '' 60)
    or return 1
    printf '%s\n' "$payload" | jq -r '.model_storage.path // empty' 2>/dev/null
end

function __delete_repo_cache_name --argument-names source repo
    string match -qr '^[^./][^/]*/[^./][^/]*$' -- "$repo"; or return 1
    __delete_cache_name "$source" "$repo"
end

function __delete_cache_dir
    # Mirrors the server's own resolution: an explicit models_dir wins, and that
    # is what system-info reports, followed by the HuggingFace variables and the
    # platform default.
    set -l candidates (__delete_storage_path)
    if set -q HF_HUB_CACHE; and test -n "$HF_HUB_CACHE"
        set -a candidates $HF_HUB_CACHE
    end
    if set -q HF_HOME; and test -n "$HF_HOME"
        set -a candidates "$HF_HOME/hub"
    end
    if set -q HOME; and test -n "$HOME"
        set -a candidates "$HOME/.cache/huggingface/hub"
    end

    for candidate in $candidates
        test -n "$candidate"; and test -d "$candidate"; or continue
        path resolve "$candidate"
        return 0
    end
    return 1
end

# Every cache directory a target could mean. Prints one path per match, so a
# repository id that exists under both registries is reported rather than
# guessed at.
function __delete_cache_matches --argument-names cache_dir target
    test -n "$cache_dir"; or return 1

    set -l names
    if string match -qr '^(modelscope--)?models--[^/]+$' -- "$target"
        set names $target
    else
        for source in huggingface modelscope
            set -l name (__delete_repo_cache_name "$source" "$target")
            or continue
            set -a names $name
        end
    end

    for name in $names
        test -d "$cache_dir/$name"; and echo "$cache_dir/$name"
    end
end

function __delete_path_bytes --argument-names target
    if test -d "$target"
        find "$target" -type f -printf '%s\n' 2>/dev/null | awk '{sum += $1} END {print sum + 0}'
    else if test -f "$target"; and not test -L "$target"
        stat -c %s "$target" 2>/dev/null; or echo 0
    else
        echo 0
    end
end

function __delete_human_size --argument-names bytes
    if test -z "$bytes"; or test "$bytes" -le 0 2>/dev/null
        echo "0 B"
        return
    end

    printf '%s\n' $bytes | awk '{
        split("B KB MB GB TB", unit, " ")
        i = 1
        size = $1
        while (size >= 1024 && i < 5) { size /= 1024; i++ }
        printf (i == 1 ? "%d %s\n" : "%.1f %s\n"), size, unit[i]
    }'
end

# The cache directory names claimed by the models in an inventory, in the same
# form the registries write them.
function __delete_used_cache_names --argument-names inventory
    printf '%s\n' "$inventory" | jq -r '
        .data[]?
        | ((.registry_source // "") | if . == "" then (.source // "") else . end) as $source
        | select($source == "huggingface" or $source == "modelscope")
        | (if ((.checkpoints // {}) | length) > 0
           then .checkpoints
           elif (.checkpoint // "") != ""
           then {main: .checkpoint}
           else {}
           end)[]
        | split(":")[0]
        | select(test("^[^/]+/[^/]+$"))
        | (if $source == "modelscope" then "modelscope--models--" else "models--" end)
          + gsub("/"; "--")' 2>/dev/null
end

function __delete_stop_download --argument-names model_name
    set -l downloads (__delete_api GET /api/v1/downloads '' 30)
    or return 0

    set -l ids (printf '%s\n' "$downloads" | jq -r --arg model "$model_name" '
        .[]? | select(.model_name == $model and .running == true) | .id' 2>/dev/null)

    for id in $ids
        echo "  Cancelling active download $id..."
        set -l body (jq -nc --arg id "$id" '{id: $id, action: "cancel"}')
        set -l ignored (__delete_api POST /api/v1/downloads/control "$body" 30)

        set -l stopped false
        for attempt in (seq 1 40)
            set downloads (__delete_api GET /api/v1/downloads '' 30)
            or break
            if not printf '%s\n' "$downloads" | jq -e --arg id "$id" \
                    'any(.[]?; .id == $id and .running == true)' >/dev/null 2>&1
                set stopped true
                break
            end
            sleep 0.25
        end

        if test $stopped != true
            echo "Error: download $id did not stop; refusing to delete files it may still use." >&2
            return 1
        end

        set body (jq -nc --arg id "$id" '{id: $id, action: "remove"}')
        set ignored (__delete_api POST /api/v1/downloads/control "$body" 30)
    end
end

function __delete_execute_model --argument-names model_name
    set -l body (jq -nc --arg model "$model_name" '{model_name: $model}')
    set -l payload (__delete_api POST /api/v1/delete "$body" 180)
    set -l api_status $status

    if test $api_status -ne 0
        echo "  Error: "(__delete_api_error "$payload") >&2
        return 1
    end

    if not printf '%s\n' "$payload" | jq -e '.status == "success"' >/dev/null 2>&1
        echo "  Error: the server did not confirm deletion." >&2
        return 1
    end
end

function __delete_remove_cache_dir --argument-names repo_path
    test -n "$repo_path"; or return 1
    set repo_path (string replace -r '/+$' '' -- "$repo_path")
    string match -qr '^/[^\n]*$' -- "$repo_path"; or return 1

    set -l storage (path dirname "$repo_path")
    set -l cache_name (path basename "$repo_path")
    test "$storage" != /; or return 1
    test -d "$storage"; or return 1
    set storage (path resolve "$storage")
    string match -qr '^(modelscope--)?models--[^/]+$' -- "$cache_name"; or return 1

    set repo_path "$storage/$cache_name"
    test (path dirname "$repo_path") = "$storage"; or return 1

    set -l removed_bytes (__delete_path_bytes "$repo_path")
    set -l removed_any false
    if test -e "$repo_path"; or test -L "$repo_path"
        rm -rf -- "$repo_path"
        or return 1
        set removed_any true
    end

    set -l lock_path "$storage/.locks/$cache_name"
    if test -e "$lock_path"; or test -L "$lock_path"
        rm -rf -- "$lock_path"
        or return 1
        set removed_any true
    end
    rmdir "$storage/.locks" 2>/dev/null

    if test $removed_any = true
        echo "  Removed cache directory $cache_name ("(__delete_human_size $removed_bytes)")."
    end
end

function __delete_keep_paths --argument-names inventory
    set -l model_names (printf '%s\n' "$inventory" | jq -r '
        .data[]?
        | select(.downloaded == true or (.id | startswith("user.")))
        | .id' 2>/dev/null)
    for model_name in $model_names
        __delete_model_files "$model_name" | while read -l record
            set -l parts (string split \t -- "$record")
            test (count $parts) -ge 3; and echo $parts[3]
        end
    end
end

function __delete_shard_siblings --argument-names resolved_path
    set -l base (path basename "$resolved_path")
    set -l groups (string match --groups-only -r '^(.+)-[0-9]{5}-of-([0-9]{5})\.gguf$' -- "$base")
    test (count $groups) -eq 2; or return 0

    set -l escaped_prefix (string escape --style=regex -- "$groups[1]")
    set -l escaped_total (string escape --style=regex -- "$groups[2]")
    for candidate in (find (path dirname "$resolved_path") -mindepth 1 -maxdepth 1 \( -type f -o -type l \) 2>/dev/null)
        set -l shard_pattern "^$escaped_prefix-[0-9]{5}-of-$escaped_total\\.gguf\$"
        if string match -qr "$shard_pattern" -- (path basename "$candidate")
            echo $candidate
        end
    end
end

function __delete_cleanup_blob --argument-names repo_dir blob
    test -n "$blob"; or return
    string match -q "$repo_dir/blobs/*" -- "$blob"; or return
    test -f "$blob"; or return

    for link in (find "$repo_dir/snapshots" -type l 2>/dev/null)
        if test (readlink -f "$link" 2>/dev/null) = "$blob"
            return
        end
    end
    rm -f -- "$blob"
end

function __delete_remove_shared_leftovers
    set -l file_records
    set -l successful_models
    set -l keep_paths
    set -l section files

    for arg in $argv
        switch $arg
            case --successful
                set section successful
            case --keep
                set section keep
            case '*'
                switch $section
                    case files
                        set -a file_records "$arg"
                    case successful
                        set -a successful_models "$arg"
                    case keep
                        set -a keep_paths "$arg"
                end
        end
    end

    set -l removed 0

    for record in $file_records
        set -l parts (string split \t -- "$record")
        test (count $parts) -ge 4; or continue
        contains -- $parts[1] $successful_models; or continue

        set -l resolved_path $parts[3]
        contains -- "$resolved_path" $keep_paths; and continue

        set -l repo_dir (__delete_repo_dir "$resolved_path")
        or continue
        string match -q "$repo_dir/*" -- "$resolved_path"; or continue

        set -l candidates $resolved_path "$resolved_path.partial" (__delete_shard_siblings "$resolved_path")
        for candidate in $candidates
            test -e "$candidate"; or test -L "$candidate"; or continue
            contains -- "$candidate" $keep_paths; and continue
            test -d "$candidate"; and continue
            string match -q "$repo_dir/*" -- "$candidate"; or continue

            set -l blob
            if test -L "$candidate"
                set blob (readlink -f "$candidate" 2>/dev/null)
            end
            rm -f -- "$candidate"
            or continue
            set removed (math $removed + 1)
            __delete_cleanup_blob "$repo_dir" "$blob"

            set -l parent (path dirname "$candidate")
            while test "$parent" != "$repo_dir"; and string match -q "$repo_dir/*" -- "$parent"
                rmdir "$parent" 2>/dev/null; or break
                set parent (path dirname "$parent")
            end
        end
    end

    if test $removed -gt 0
        echo "  Removed $removed unreferenced file(s) from shared repository caches."
    end
end

function delete --description 'Delete Lemonade models and clean their filesystem leftovers'
    argparse -n delete \
        n/dry-run \
        y/yes \
        no-cleanup \
        h/help \
        -- $argv
    or return

    if set -q _flag_help
        __delete_usage
        return 0
    end

    if test (count $argv) -eq 0
        __delete_usage
        return 1
    end

    for tool in curl jq
        if not command -q $tool
            echo "Error: $tool is required but not installed." >&2
            return 1
        end
    end

    set -l requested
    for model_name in $argv
        contains -- "$model_name" $requested; or set -a requested $model_name
    end

    set -l health (__delete_api GET /api/v1/health '' 10)
    switch $status
        case 2
            echo "Error: could not reach a Lemonade server on port "(__delete_port)"." >&2
            return 1
        case 1
            echo "Error: "(__delete_api_error "$health") >&2
            return 1
    end

    set -l inventory (__delete_inventory)
    or begin
        echo "Error: could not read the model inventory." >&2
        return 1
    end

    set -l model_names
    set -l model_records
    set -l file_records
    set -l repo_records
    set -l orphan_records
    set -l total_bytes 0
    set -l aliases (__delete_api GET /internal/aliases '' 30)
    if test $status -ne 0
        set aliases '{"aliases":[]}'
    end

    # A target that names no model is matched against the cache directory, so a
    # repository an earlier delete left behind can still be named directly. Only
    # models that actually hold files are allowed to keep a directory alive: a
    # built-in whose registration survives its deletion with downloaded=false is
    # exactly the case that strands one.
    set -l cache_dir (__delete_cache_dir)
    set -l live_cache_names (__delete_used_cache_names (printf '%s\n' "$inventory" | jq -c \
        '.data |= map(select(.downloaded == true or (.id | startswith("user."))))' 2>/dev/null))

    for model_name in $requested
        set -l alias_target (printf '%s\n' "$aliases" | jq -r --arg alias "$model_name" \
            '[.aliases[]? | select(.alias == $alias) | .target][0] // empty' 2>/dev/null)
        if test -n "$alias_target"
            echo "Error: '$model_name' is an alias for '$alias_target'." >&2
            echo "       Delete '$alias_target', or remove only the alias with:" >&2
            echo "       lemonade alias remove '$model_name'" >&2
            return 1
        end

        set -l model_json (printf '%s\n' "$inventory" | jq -c --arg model "$model_name" \
            '[.data[]? | select(.id == $model)][0] // empty' 2>/dev/null)
        if test -z "$model_json"
            set -l matches (__delete_cache_matches "$cache_dir" "$model_name")
            if test (count $matches) -gt 1
                echo "Error: '$model_name' names both a Hugging Face and a ModelScope cache" >&2
                echo "       directory. Name the directory itself to pick one:" >&2
                for match in $matches
                    echo "       "(path basename "$match") >&2
                end
                return 1
            end
            if test (count $matches) -eq 1
                set -l cache_name (path basename "$matches[1]")
                if contains -- "$cache_name" $live_cache_names
                    echo "Error: cache directory '$cache_name' still belongs to a downloaded model." >&2
                    echo "       Delete that model instead, so its registration goes with it." >&2
                    return 1
                end
                set -a orphan_records "$model_name"\t"$matches[1]"\t(__delete_path_bytes "$matches[1]")
                continue
            end

            echo "Error: unknown model '$model_name'." >&2
            if test -n "$cache_dir"
                echo "       No cache directory of that name in $cache_dir either." >&2
            end
            return 1
        end

        set -l recipe (printf '%s\n' "$model_json" | jq -r '.recipe // "unknown"')
        if string match -q 'extra.*' -- "$model_name"
            echo "Error: '$model_name' is externally managed and cannot be deleted through Lemonade." >&2
            return 1
        end
        if test "$recipe" = cloud
            echo "Error: '$model_name' is a cloud model; use 'lemonade cloud uninstall' instead." >&2
            return 1
        end

        set -a model_names $model_name
        set -a model_records "$model_name"\t"$recipe"\t(printf '%s\n' "$model_json" | jq -r '.downloaded | tostring')
        set -l current_files (__delete_model_files "$model_name")
        for record in $current_files
            set -a file_records $record
            set -l parts (string split \t -- "$record")
            set total_bytes (math "$total_bytes + $parts[4]")
        end
        for record in (__delete_repo_records "$model_name" "$model_json")
            contains -- "$record" $repo_records; or set -a repo_records $record
        end
    end

    if test (count $model_records) -gt 0
        echo "The following model(s) will be deleted:"
    end
    for record in $model_records
        set -l parts (string split \t -- "$record")
        printf '  - %s (%s, downloaded: %s)\n' $parts[1] $parts[2] $parts[3]
        set -l model_json (printf '%s\n' "$inventory" | jq -c --arg model "$parts[1]" \
            '[.data[]? | select(.id == $model)][0]')
        set -l components (printf '%s\n' "$model_json" | jq -r '.components[]?' 2>/dev/null)
        if test (count $components) -gt 0
            echo "    collection components kept: "(string join ', ' $components)
        end
    end
    if test (count $file_records) -gt 0
        echo "Resolved model files:"
        set -l listed_files
        for record in $file_records
            contains -- "$record" $listed_files; and continue
            set -a listed_files "$record"
            set -l parts (string split \t -- "$record")
            printf '  - %s [%s] %s (%s)\n' \
                $parts[1] $parts[2] $parts[3] (__delete_human_size $parts[4])
        end
        echo "Resolved total: "(__delete_human_size $total_bytes)
    end
    if test (count $orphan_records) -gt 0
        echo "The following leftover cache directory(s) will be removed:"
        for record in $orphan_records
            set -l parts (string split \t -- "$record")
            printf '  - %s (%s)\n' (path basename "$parts[2]") (__delete_human_size $parts[3])
        end
    end
    if not set -q _flag_no_cleanup; and test (count $repo_records) -gt 0
        echo "Repository caches are removed only when no remaining model references them."
    end

    if set -q _flag_dry_run
        echo "Dry run: nothing was changed."
        return 0
    end

    if not set -q _flag_yes
        if not isatty stdin
            echo "Error: refusing a non-interactive delete without --yes." >&2
            return 1
        end
        set -l prompt "Delete these models and their unshared cache files? [y/N] "
        if test (count $model_records) -eq 0
            set prompt "Delete these cache directories? [y/N] "
        end
        read -l -P $prompt answer
        if not string match -qir '^y(es)?$' -- "$answer"
            echo "Kept."
            return 0
        end
    end

    set -l successful
    set -l failed
    for model_name in $model_names
        echo ""
        echo "==> $model_name"
        if not set -q _flag_no_cleanup
            if not __delete_stop_download "$model_name"
                set -a failed $model_name
                continue
            end
        end

        if __delete_execute_model "$model_name"
            echo "  Deleted registration and server-managed files."
            set -a successful $model_name
        else
            set -a failed $model_name
        end
    end

    if not set -q _flag_no_cleanup; and test (count $successful) -gt 0
        set -l remaining (__delete_inventory)
        if test $status -ne 0
            echo "Warning: could not refresh inventory; skipped direct filesystem cleanup." >&2
        else
            set -l excluded_ids $successful
            for alias_record in (printf '%s\n' "$aliases" | jq -r '.aliases[]? | [.alias, .target] | @tsv' 2>/dev/null)
                set -l alias_parts (string split \t -- "$alias_record")
                if contains -- $alias_parts[2] $successful
                    contains -- $alias_parts[1] $excluded_ids; or set -a excluded_ids $alias_parts[1]
                end
            end
            set -l excluded_json (printf '%s\n' $excluded_ids | jq -Rsc \
                'split("\n") | map(select(. != ""))')
            set -l cleanup_inventory (printf '%s\n' "$remaining" | jq -c \
                --argjson excluded "$excluded_json" \
                '.data |= map(select(.id as $id | ($excluded | index($id) | not)))')

            set -l keep_paths (__delete_keep_paths "$cleanup_inventory" | sort -u)

            # A directory survives if anything left still claims it: a remaining
            # registration's checkpoint, or a file a remaining model resolves to.
            # Only a model that holds files counts. A built-in stays in the
            # inventory with downloaded=false after its own delete, and letting
            # that pin a directory is what stranded these caches to begin with;
            # keep_paths below is the safety net for anything still on disk.
            set -l used_names (__delete_used_cache_names (printf '%s\n' "$cleanup_inventory" \
                | jq -c '.data |= map(select(.downloaded == true))' 2>/dev/null))
            for keep in $keep_paths
                set -l keep_dir (__delete_repo_dir "$keep")
                or continue
                set -l keep_name (path basename "$keep_dir")
                contains -- "$keep_name" $used_names; or set -a used_names $keep_name
            end

            set -l candidates
            for record in $repo_records
                set -l parts (string split \t -- "$record")
                contains -- $parts[1] $successful; or continue
                test -n "$cache_dir"; or continue
                set -l name (__delete_repo_cache_name $parts[2] $parts[3])
                or continue
                contains -- "$cache_dir/$name" $candidates; or set -a candidates "$cache_dir/$name"
            end
            # The server drops a registration it cannot resolve a path for and
            # leaves the directory behind, and a checkpoint is not always
            # reported, so take the directory the resolved files sat in as well.
            for record in $file_records
                set -l parts (string split \t -- "$record")
                test (count $parts) -ge 3; or continue
                contains -- $parts[1] $successful; or continue
                set -l repo_dir (__delete_repo_dir "$parts[3]")
                or continue
                contains -- "$repo_dir" $candidates; or set -a candidates $repo_dir
            end

            if test -z "$cache_dir"; and test (count $repo_records) -gt 0
                echo "Warning: could not locate the model cache directory; cleaning only the directories the deleted models resolved to." >&2
            end

            for candidate in $candidates
                test -e "$candidate"; or continue
                contains -- (path basename "$candidate") $used_names; and continue
                __delete_remove_cache_dir "$candidate"
                or echo "  Warning: refused or failed cleanup for "(path basename "$candidate")"." >&2
            end

            __delete_remove_shared_leftovers $file_records --successful $successful --keep $keep_paths

            set -l cleanup (__delete_api POST /internal/cleanup-cache '{"dry_run":false}' 300)
            if test $status -eq 0
                set -l swept (printf '%s\n' "$cleanup" | jq -r '.total_bytes // 0' 2>/dev/null)
                if test -n "$swept"; and test "$swept" -gt 0 2>/dev/null
                    echo "  Swept "(__delete_human_size $swept)" of legacy multi-repo leftovers."
                end
            end
        end
    end

    # A directory named on the command line is the request itself, not extra
    # tidying, so --no-cleanup does not hold it back.
    set -l removed_orphans
    for record in $orphan_records
        set -l parts (string split \t -- "$record")
        echo ""
        echo "==> $parts[1]"
        if __delete_remove_cache_dir "$parts[2]"
            set -a removed_orphans (path basename "$parts[2]")
        else
            echo "  Error: could not remove $parts[2]." >&2
            set -a failed $parts[1]
        end
    end

    echo ""
    if test (count $successful) -gt 0
        echo "Deleted "(count $successful)" model(s): "(string join ', ' $successful)
    end
    if test (count $removed_orphans) -gt 0
        echo "Removed "(count $removed_orphans)" cache directory(s): "(string join ', ' $removed_orphans)
    end
    if test (count $failed) -gt 0
        echo "Failed "(count $failed)" target(s): "(string join ', ' $failed) >&2
        return 1
    end
end
