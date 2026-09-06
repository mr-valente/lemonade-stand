source (builtin path dirname (status filename))/__lemonade_flm.fish

function __update_usage
    echo "Usage:"
    echo "  update <model_name> [model_name...] [options]"
    echo "  update --all [options]"
    echo "  update --check"
    echo "  update --prune"
    echo ""
    echo "Options:"
    echo "  -a, --all         Update pending registry and FLM models"
    echo "  -c, --check       List pending updates and exit without changing anything"
    echo "  -f, --force       Re-pull even when no update is reported, and ignore the"
    echo "                    free-space check"
    echo "      --flm         Include FLM updates (now included by default)"
    echo "  -n, --dry-run     Show what would be done, change nothing"
    echo "  -y, --yes         Do not prompt for confirmation"
    echo "  -p, --prune       Delete superseded weights after a successful update"
    echo "      --no-reload   Leave models unloaded instead of restoring them"
    echo "  -h, --help        Show this help"
    echo ""
    echo "Models are upgraded in place through the enhanced 'pull' function. Registered"
    echo "multi-checkpoint definitions (including MTP drafts) are preserved, and the new"
    echo "registry revision only replaces the old one after every checkpoint downloads successfully."
    echo "FLM updates use its own in-place downloader and compatibility checks."
end

# ---------------------------------------------------------------------------
# API plumbing
# ---------------------------------------------------------------------------

function __update_port
    if set -q LEMONADE_PORT; and test -n "$LEMONADE_PORT"
        echo $LEMONADE_PORT
    else
        echo 8000
    end
end

# __update_api METHOD PATH [BODY] [TIMEOUT]
# Prints the response body on stdout. Returns 1 on an HTTP error status and 2
# when the request itself failed (server down, connection refused, ...).
function __update_api --argument-names method path body timeout
    set -l port (__update_port)

    test -z "$timeout"; and set timeout 600

    set -l curl_args -sS -m $timeout -X $method "http://localhost:$port$path"
    set -a curl_args -H "Content-Type: application/json"

    if set -q LEMONADE_ADMIN_API_KEY; and test -n "$LEMONADE_ADMIN_API_KEY"
        set -a curl_args -H "Authorization: Bearer $LEMONADE_ADMIN_API_KEY"
    else if set -q LEMONADE_API_KEY; and test -n "$LEMONADE_API_KEY"
        set -a curl_args -H "Authorization: Bearer $LEMONADE_API_KEY"
    end

    if test -n "$body"
        set -a curl_args -d "$body"
    end

    # curl's own diagnostics are suppressed: every call site reports the
    # failure in terms of what it was trying to do.
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

# Pull the human-readable message out of an API error body.
function __update_api_error --argument-names payload
    set -l message (echo $payload | jq -r '
        if type == "object" then
            (.error | if type == "object" then (.message // (. | tostring)) else . end) // .detail // empty
        else empty end' 2>/dev/null)

    if test -n "$message"; and test "$message" != null
        echo $message
    else if test -n "$payload"
        echo $payload
    else
        echo "no response from the server"
    end
end

function __update_human_size --argument-names bytes
    if test -z "$bytes"; or test "$bytes" -le 0 2>/dev/null
        echo "0 B"
        return 0
    end

    echo $bytes | awk '{
        split("B KB MB GB TB", unit, " ")
        i = 1
        size = $1
        while (size >= 1024 && i < 5) { size /= 1024; i++ }
        printf (i == 1 ? "%d %s\n" : "%.1f %s\n"), size, unit[i]
    }'
end

# ---------------------------------------------------------------------------
# Model inventory
# ---------------------------------------------------------------------------

# Emits one TSV line per known model: id, recipe, downloaded, size_gb
function __update_inventory
    set -l payload (__update_api GET "/api/v1/models?show_all=true" "" 120)
    or return 1

    echo $payload | jq -r '.data[]? | [.id, (.recipe // ""), (.downloaded | tostring), ((.size // 0) | tostring), (.checkpoints.main // .checkpoint // "")] | @tsv'
end

function __update_field --argument-names inventory_line index
    string split \t -- $inventory_line | sed -n "$index"p
end

# Resolved on-disk paths for one model (only files that actually exist).
function __update_model_files --argument-names model_name
    set -l encoded (string escape --style=url -- $model_name)
    set -l payload (__update_api GET "/api/v1/models/$encoded/files?include_paths=true" "" 60)
    or return 1

    echo $payload | jq -r '.files[]? | select(.exists) | .path' 2>/dev/null
end

# Currently loaded model names.
function __update_loaded_models
    set -l payload (__update_api GET /api/v1/health "" 30)
    or return 1

    echo $payload | jq -r '.all_models_loaded[]?.model_name' 2>/dev/null
end

# The "models--owner--repo" cache directory a resolved path lives in, if any.
function __update_repo_dir --argument-names resolved_path
    set -l current $resolved_path

    while test -n "$current"; and test "$current" != /
        set -l base (basename $current)
        if string match -q 'models--*' -- $base; or string match -q 'modelscope--models--*' -- $base
            echo $current
            return 0
        end
        set current (dirname $current)
    end

    return 1
end

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------

function __update_cli
    if command -q lemonade
        echo lemonade
    else if command -q lemonade-server
        echo lemonade-server
    end
end

# Upgrade one model in place. The CLI is preferred because it renders download
# progress; the API is the fallback when no CLI is on PATH.
function __update_pull --argument-names model_name
    set -l cli (__update_cli)

    if test -n "$cli"; and functions -q pull
        pull --yes -- "$model_name"
        return $status
    end

    if test -n "$cli"
        # The CLI picks up the port and key from the environment; export them so
        # it talks to the same server this function does, even when they are set
        # as plain (unexported) shell variables.
        # Note: these must not sit inside an if/begin block — `set -l` there is
        # scoped to the block and would be gone by the time the CLI runs.
        set -lx LEMONADE_PORT (__update_port)
        set -q LEMONADE_ADMIN_API_KEY; and set -lx LEMONADE_ADMIN_API_KEY $LEMONADE_ADMIN_API_KEY
        set -q LEMONADE_API_KEY; and set -lx LEMONADE_API_KEY $LEMONADE_API_KEY

        $cli pull $model_name
        return $status
    end

    echo "  (no lemonade CLI on PATH, downloading through the API without progress)"

    set -l body (jq -nc --arg model_name "$model_name" \
        '{model_name: $model_name, do_not_upgrade: false, stream: false}')

    set -l payload (__update_api POST /api/v1/pull "$body" 0)
    set -l result $status

    if test $result -ne 0
        echo "  Error: "(__update_api_error "$payload") >&2
        return 1
    end

    return 0
end

# ---------------------------------------------------------------------------
# Prune: reclaim weights that no downloaded model resolves to any more
# ---------------------------------------------------------------------------
#
# Two levels, both driven by what the server currently reports as a model's
# resolved files:
#
#   1. A whole snapshot directory that no downloaded model resolves into (and
#      that no refs/* entry pins) is a fully superseded revision.
#   2. A single file that one of the models just updated used to resolve to,
#      that it no longer resolves to, and that no other downloaded model claims.
#      This is the case where one repository holds several quants: the old
#      snapshot has to stay for the other quant, but the old file inside it is
#      dead weight.
#
# Whatever that leaves unreferenced in blobs/ (the layout huggingface tooling
# writes; Lemonade's own downloader writes real files) is reclaimed too.

# __update_prune_plan [SUPERSEDED_PATH...] -- [REPO_DIR...]
# Emits one tab-separated record per reclaimable path:
#   DIR\t<snapshot dir>
#   FILE\t<file>\t<bytes>
#   BLOB\t<blob>\t<bytes>
function __update_prune_plan
    set -l superseded
    set -l repo_dirs
    set -l past_separator false

    for arg in $argv
        if test "$arg" = --
            set past_separator true
        else if test $past_separator = true
            set -a repo_dirs $arg
        else
            set -a superseded $arg
        end
    end

    test (count $repo_dirs) -eq 0; and return 0

    # Keep-set: every file (and therefore every snapshot directory) a
    # downloaded model still resolves to.
    set -l keep_paths
    set -l keep_snapshots

    for line in (__update_inventory)
        test (__update_field $line 3) = true; or continue

        for resolved in (__update_model_files (__update_field $line 1))
            set -a keep_paths $resolved

            set -l repo (__update_repo_dir $resolved)
            or continue

            set -l relative (string replace -- "$repo/snapshots/" "" $resolved)
            test "$relative" = "$resolved"; and continue

            set -l snapshot_dir "$repo/snapshots/"(string split -m 1 / -- $relative)[1]
            contains -- $snapshot_dir $keep_snapshots; or set -a keep_snapshots $snapshot_dir
        end
    end

    for repo in $repo_dirs
        test -d "$repo/snapshots"; or continue

        # refs/* pin the revisions the server falls back to; never touch those.
        for ref in (find "$repo/refs" -type f 2>/dev/null)
            set -l ref_id (string trim -- (cat $ref 2>/dev/null))
            test -n "$ref_id"; or continue
            set -l ref_dir "$repo/snapshots/$ref_id"
            contains -- $ref_dir $keep_snapshots; or set -a keep_snapshots $ref_dir
        end

        set -l doomed_dirs
        set -l survivors

        for snapshot in (find "$repo/snapshots" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
            if contains -- $snapshot $keep_snapshots
                set -a survivors $snapshot
            else
                set -a doomed_dirs $snapshot
            end
        end

        # Superseded files that live in a snapshot this repo is keeping.
        set -l doomed_files
        for path in $superseded
            string match -q "$repo/*" -- $path; or continue
            test -e "$path"; or continue
            contains -- $path $keep_paths; and continue

            set -l inside_doomed_dir false
            for snapshot in $doomed_dirs
                if string match -q "$snapshot/*" -- $path
                    set inside_doomed_dir true
                    break
                end
            end
            test $inside_doomed_dir = true; and continue

            set -a doomed_files $path
        end

        test (count $doomed_dirs) -eq 0; and test (count $doomed_files) -eq 0; and continue

        for snapshot in $doomed_dirs
            printf 'DIR\t%s\n' $snapshot
        end

        for path in $doomed_files
            set -l bytes 0
            if not test -L "$path"
                # A symlink's bytes live in the blob it points at, which the
                # BLOB pass below accounts for.
                set bytes (__update_path_bytes $path)
            end
            printf 'FILE\t%s\t%s\n' $path $bytes
        end

        # A blob is reclaimable once nothing that survives points at it.
        set -l referenced
        if test (count $survivors) -gt 0
            for link in (find $survivors -type l 2>/dev/null)
                contains -- $link $doomed_files; and continue
                set -a referenced (readlink -f $link)
            end
        end

        for blob in (find "$repo/blobs" -mindepth 1 -maxdepth 1 -type f 2>/dev/null)
            string match -qr '\.(incomplete|partial|lock|metadata)$' -- $blob; and continue
            contains -- (readlink -f $blob) $referenced; and continue
            printf 'BLOB\t%s\t%s\n' $blob (__update_path_bytes $blob)
        end
    end
end

# Bytes actually occupied by a path, ignoring symlinks (their target is
# accounted for separately).
function __update_path_bytes --argument-names path
    if test -d "$path"
        find $path -type f -printf '%s\n' 2>/dev/null | awk '{s += $1} END {print s + 0}'
    else if test -f "$path"; and not test -L "$path"
        stat -c %s $path 2>/dev/null; or echo 0
    else
        echo 0
    end
end

function __update_prune_size
    set -l bytes 0

    for entry in $argv
        set -l parts (string split \t -- $entry)
        switch $parts[1]
            case DIR
                set bytes (math "$bytes + "(__update_path_bytes $parts[2]))
            case FILE BLOB
                set bytes (math "$bytes + $parts[3]")
        end
    end

    echo $bytes
end

function __update_prune_apply
    set -l removed 0

    # Directories first so a superseded file inside one is not visited twice,
    # then files, then the blobs both of them released.
    for kind in DIR FILE BLOB
        for entry in $argv
            set -l parts (string split \t -- $entry)
            test "$parts[1]" = "$kind"; or continue

            set -l target $parts[2]
            test -e "$target"; or test -L "$target"; or continue

            # Belt and braces: only ever delete inside a HuggingFace-style cache.
            if not string match -qr '/(models--|modelscope--models--)[^/]+/(snapshots|blobs)/' -- "$target/"
                echo "  Refusing to delete unexpected path: $target" >&2
                continue
            end

            switch $kind
                case DIR
                    rm -rf -- $target
                case '*'
                    rm -f -- $target
            end
            or continue

            set removed (math $removed + 1)

            # Leave no empty directories behind inside the snapshot tree.
            if test "$kind" = FILE
                set -l parent (dirname $target)
                while string match -qr '/snapshots/[^/]+/' -- "$parent/"
                    rmdir $parent 2>/dev/null; or break
                    set parent (dirname $parent)
                end
            end
        end
    end

    echo $removed
end

# ---------------------------------------------------------------------------
# update
# ---------------------------------------------------------------------------

function update --description 'Update downloaded Lemonade models to their latest upstream revision'
    argparse -n update \
        a/all \
        c/check \
        f/force \
        flm \
        n/dry-run \
        y/yes \
        p/prune \
        no-reload \
        h/help \
        -- $argv
    or return

    if set -q _flag_help
        __update_usage
        return 0
    end

    if set -q _flag_all; and test (count $argv) -gt 0
        echo "Error: --all does not take model names." >&2
        return 1
    end

    set -l dry_run false
    set -q _flag_dry_run; and set dry_run true

    set -l assume_yes false
    set -q _flag_yes; and set assume_yes true

    set -l prune_only false
    if set -q _flag_prune; and not set -q _flag_all; and test (count $argv) -eq 0
        set prune_only true
    end

    if not set -q _flag_all; and not set -q _flag_check; and test (count $argv) -eq 0
        if test $prune_only = false
            __update_usage
            return 1
        end
    end

    for tool in curl jq
        if not command -q $tool
            echo "Error: $tool is required but not installed." >&2
            return 1
        end
    end

    # ---- server reachable? ------------------------------------------------
    set -l health (__update_api GET /api/v1/health "" 10)
    switch $status
        case 2
            echo "Error: could not reach a Lemonade server on port "(__update_port)"." >&2
            echo "       Is it running? Set LEMONADE_PORT if it listens elsewhere." >&2
            return 1
        case 1
            echo "Error: "(__update_api_error "$health") >&2
            return 1
    end

    # ---- inventory --------------------------------------------------------
    set -l inventory (__update_inventory)
    or begin
        echo "Error: could not read the model list from the server." >&2
        return 1
    end

    # ---- prune-only -------------------------------------------------------
    if test $prune_only = true
        set -l repo_dirs
        for line in $inventory
            test (__update_field $line 3) = true; or continue
            for resolved in (__update_model_files (__update_field $line 1))
                set -l repo (__update_repo_dir $resolved)
                or continue
                contains -- $repo $repo_dirs; or set -a repo_dirs $repo
            end
        end

        __update_run_prune $dry_run $assume_yes -- $repo_dirs
        return $status
    end

    # FLM marks outdated weights as downloaded=false. Keep the recipe/checkpoint
    # mapping from Lemonade, but use FLM's local compatibility check for status.
    set -l flm_status '{"models":[]}'
    set -l needs_flm false
    for line in $inventory
        test (__update_field "$line" 2) = flm; or continue
        if set -q _flag_all; or set -q _flag_check; or contains -- (__update_field "$line" 1) $argv
            set needs_flm true
        end
    end
    if test "$needs_flm" = true
        set flm_status (__flm_status)
        if test $status -ne 0
            echo "Error: could not read FLM model status. Run 'flm list' to inspect it." >&2
            return 1
        end
    end

    # ---- validate the requested names before touching the network ---------
    set -l requested
    set -l requested_recipes
    set -l skipped

    for name in $argv
        set -l line
        for candidate in $inventory
            if test (__update_field $candidate 1) = "$name"
                set line $candidate
                break
            end
        end

        if test -z "$line"
            echo "Error: unknown model '$name'. Run 'lm list' to see what is registered." >&2
            return 1
        end

        set -l recipe (__update_field $line 2)

        if test "$recipe" = flm
            set -l state (printf '%s\n' "$flm_status" | jq -r --arg checkpoint (__update_field "$line" 5) \
                '[.models[] | select(.name == $checkpoint)][0].state // "unknown"')
            switch "$state"
                case missing
                    echo "Error: '$name' is not installed in FLM. Use 'pull $name' to install it." >&2
                    return 1
                case incompatible unknown
                    echo "Error: FLM reports '$state' for '$name'. Inspect 'flm list'; a newer FLM backend may be required." >&2
                    return 1
            end
        else if test (__update_field $line 3) != true
            echo "Error: '$name' is not downloaded. Use 'lm pull $name' to install it." >&2
            return 1
        end

        if test "$recipe" = cloud
            set -a skipped "$name (cloud model, nothing to download)"
            continue
        end

        set -a requested $name
        set -a requested_recipes $recipe
    end

    # ---- which models need updating? --------------------------------------
    set -l pending
    set -l checked false

    # The check is only worth its network round trips when something actually
    # depends on the answer. FLM models are never covered by it and --force
    # ignores it.
    set -l needs_check false
    if set -q _flag_all; or set -q _flag_check
        set needs_check true
    else if not set -q _flag_force
        for recipe in $requested_recipes
            test "$recipe" = flm; and continue
            set needs_check true
            break
        end
    end

    if test $needs_check = true
        echo "Checking for model updates..."
        set -l payload (__update_api POST /api/v1/models/check-updates '{}' 900)
        set -l check_status $status

        if test $check_status -ne 0
            # Nothing that gets here can proceed without the answer: --all and
            # --check have no other source of targets, and a named update needs
            # it to decide whether there is anything to do. --force skips the
            # check altogether, which is the way past a server that cannot
            # reach the registry.
            echo "Error: update check failed: "(__update_api_error "$payload") >&2
            echo "       Pass --force with a model name to re-pull without checking." >&2
            return 1
        end

        set checked true
        set pending (echo $payload | jq -r '.models[]?' | sort)
    end

    set -l flm_unchecked
    for line in $inventory
        test (__update_field "$line" 2) = flm; or continue
        test "$needs_flm" = true; or continue
        set -l name (__update_field "$line" 1)
        if not set -q _flag_all; and not set -q _flag_check; and not contains -- "$name" $requested
            continue
        end
        set -l state (printf '%s\n' "$flm_status" | jq -r --arg checkpoint (__update_field "$line" 5) \
            '[.models[] | select(.name == $checkpoint)][0].state // "unknown"')
        switch "$state"
            case outdated
                contains -- "$name" $pending; or set -a pending "$name"
            case incompatible unknown
                set -a flm_unchecked "$name ($state; inspect flm list and the installed FLM backend)"
        end
    end
    for note in $flm_unchecked
        echo "FLM status unresolved: $note" >&2
    end

    if set -q _flag_check
        if test (count $pending) -eq 0; and test (count $flm_unchecked) -eq 0
            echo "All downloaded models are up to date."
        else if test (count $pending) -gt 0
            echo "Updates available for "(count $pending)" model(s):"
            for name in $pending
                echo "  - $name"
            end
            echo "Run 'update --all' to update them."
        end
        test (count $flm_unchecked) -eq 0
        return $status
    end

    # ---- build the target list --------------------------------------------
    set -l targets

    if set -q _flag_all
        set targets $pending

    else
        for index in (seq (count $requested))
            set -l name $requested[$index]

            if test $checked = true; or test "$requested_recipes[$index]" = flm
                if not set -q _flag_force; and not contains -- $name $pending
                    set -a skipped "$name (already up to date, use --force to re-pull)"
                    continue
                end
            end

            set -a targets $name
        end
    end

    for note in $skipped
        echo "Skipping $note"
    end

    if test (count $targets) -eq 0
        if set -q _flag_all; and test $checked = true; and test (count $flm_unchecked) -eq 0
            echo "All downloaded models are up to date."
        end
        test (count $flm_unchecked) -eq 0
        return $status
    end

    # ---- preview ----------------------------------------------------------
    set -l total_gb 0

    echo ""
    echo "The following model(s) will be updated:"
    for name in $targets
        set -l line
        for candidate in $inventory
            if test (__update_field $candidate 1) = "$name"
                set line $candidate
                break
            end
        end

        set -l recipe (__update_field $line 2)
        set -l size (__update_field $line 4)
        test -n "$size"; or set size 0

        set -l note ""
        if test "$recipe" = flm
            set note "  (FLM compatibility update)"
            set -q _flag_force; and set note "  (FLM: forced refresh)"
        else
            set total_gb (math "$total_gb + $size")
        end

        printf '  - %s (%s GB, %s)%s\n' $name $size $recipe $note
    end

    # A new revision is staged next to the old one, so peak usage is roughly
    # the size of everything being downloaded. Where that lands is taken from a
    # model already on disk rather than from HF_HUB_CACHE, because the server's
    # models_dir setting can point the cache somewhere else entirely.
    set -l cache_dir
    for name in $targets
        for resolved in (__update_model_files $name)
            set -l repo (__update_repo_dir $resolved)
            or continue
            set cache_dir (dirname $repo)
            break
        end
        test -n "$cache_dir"; and break
    end

    if test -z "$cache_dir"
        if set -q HF_HUB_CACHE; and test -d "$HF_HUB_CACHE"
            set cache_dir $HF_HUB_CACHE
        else if set -q HF_HOME; and test -d "$HF_HOME/hub"
            set cache_dir "$HF_HOME/hub"
        end
    end

    set -l total_bytes (math -s0 "$total_gb * 1024 * 1024 * 1024")

    if test -n "$cache_dir"; and test $total_bytes -gt 0
        set -l available (df -B1 --output=avail $cache_dir 2>/dev/null | tail -n 1 | string trim)
        if string match -qr '^[0-9]+$' -- "$available"
            set -l needed (math -s0 "$total_bytes * 1.05")
            printf '\nDownload size: ~%s GB, free in %s: %s\n' $total_gb $cache_dir (__update_human_size $available)

            if test $available -lt $needed
                if set -q _flag_force
                    echo "Warning: probably not enough free space, continuing because --force was given." >&2
                else
                    echo "Error: not enough free space to stage the new revisions." >&2
                    echo "       Reclaim some with 'update --prune', or pass --force to try anyway." >&2
                    return 1
                end
            end
        end
    end

    if set -q _flag_dry_run
        echo ""
        echo "Dry run: nothing was changed."
        return 0
    end

    if not set -q _flag_yes; and isatty stdin
        echo ""
        read -l -P "Proceed? [y/N] " answer
        if not string match -qir '^y(es)?$' -- "$answer"
            echo "Aborted."
            return 1
        end
    end

    # ---- update -----------------------------------------------------------
    set -l loaded (__update_loaded_models)
    set -l updated
    set -l failed
    set -l to_reload
    set -l repo_dirs
    set -l superseded

    for name in $targets
        echo ""
        echo "==> $name"

        # A running backend keeps serving the old weights from its open file
        # handles, so unload first and restore afterwards.
        if contains -- $name $loaded
            echo "  Unloading (currently loaded)..."
            set -l payload (__update_api POST /api/v1/unload (jq -nc --arg m "$name" '{model_name: $m}') 120)
            if test $status -ne 0
                echo "  Error: could not unload $name: "(__update_api_error "$payload") >&2
                echo "  Skipping (updating a loaded model would not take effect)." >&2
                set -a failed $name
                continue
            end
            set -a to_reload $name
        end

        # Where the model resolved before the pull, so a superseded file inside a
        # snapshot that other models still need can be reclaimed afterwards.
        set -l before (__update_model_files $name)

        __update_pull $name
        set -l pull_status $status
        if test $pull_status -eq 0
            for line in $inventory
                test (__update_field "$line" 1) = "$name"; or continue
                test (__update_field "$line" 2) = flm; or continue
                set -l refreshed (__flm_status)
                if test $status -ne 0; or not printf '%s\n' "$refreshed" | jq -e --arg cp (__update_field "$line" 5) \
                        'any(.models[]; .name == $cp and .state == "ready")' >/dev/null 2>&1
                    echo "  FLM did not confirm current, complete weights after the pull." >&2
                    set pull_status 1
                end
            end
        end
        if test $pull_status -eq 0
            set -a updated $name

            set -l after (__update_model_files $name)
            set -l restaged false

            for resolved in $before
                contains -- $resolved $after; and continue
                set restaged true
                contains -- $resolved $superseded; or set -a superseded $resolved
            end

            for resolved in $after
                contains -- $resolved $before; or set restaged true
            end

            # Only a pull that actually moved the model to a new revision can
            # leave anything behind worth reclaiming.
            if test $restaged = true
                for resolved in $before $after
                    set -l repo (__update_repo_dir $resolved)
                    or continue
                    contains -- $repo $repo_dirs; or set -a repo_dirs $repo
                end
            end
        else
            echo "  Update failed; inspect the model status before retrying." >&2
            set -a failed $name
        end
    end

    # ---- restore --------------------------------------------------------
    if test (count $to_reload) -gt 0
        if set -q _flag_no_reload
            echo ""
            echo "Left unloaded: $to_reload"
        else
            echo ""
            for name in $to_reload
                echo "Reloading $name..."
                set -l payload (__update_api POST /api/v1/load (jq -nc --arg m "$name" '{model_name: $m}') 900)
                if test $status -ne 0
                    echo "  Warning: could not reload $name: "(__update_api_error "$payload") >&2
                end
            end
        end
    end

    # ---- prune ------------------------------------------------------------
    if set -q _flag_prune; and test (count $repo_dirs) -gt 0
        echo ""
        __update_run_prune $dry_run $assume_yes $superseded -- $repo_dirs
    end

    # ---- summary ----------------------------------------------------------
    echo ""
    if test (count $updated) -gt 0
        echo "Updated "(count $updated)" model(s): $updated"
    end

    if test (count $failed) -gt 0
        echo "Failed "(count $failed)" model(s): $failed" >&2
        return 1
    end

    if test (count $repo_dirs) -gt 0; and not set -q _flag_prune
        echo ""
        echo "Tip: the revisions these models replaced are still on disk."
        echo "     Run 'update --prune' to reclaim that space."
    end

    test (count $flm_unchecked) -eq 0
    return $status
end

# Shared by --prune and prune-only.
# __update_run_prune DRY_RUN ASSUME_YES [SUPERSEDED_PATH...] -- [REPO_DIR...]
function __update_run_prune --argument-names dry_run assume_yes
    echo "Looking for superseded weights..."
    set -l plan (__update_prune_plan $argv[3..-1])

    if test (count $plan) -eq 0
        echo "Nothing to reclaim."
        return 0
    end

    set -l bytes (__update_prune_size $plan)
    set -l dirs (string match -r '^DIR\t.*' -- $plan)
    set -l files (string match -r '^FILE\t.*' -- $plan)

    echo "Reclaimable: "(__update_human_size $bytes)
    for entry in $dirs
        echo "  - "(string split \t -- $entry)[2]" (superseded revision)"
    end
    for entry in $files
        echo "  - "(string split \t -- $entry)[2]" (superseded file)"
    end

    if test "$dry_run" = true
        echo "Dry run: nothing was deleted."
        return 0
    end

    if test "$assume_yes" != true
        if not isatty stdin
            echo "Nothing deleted: re-run with --yes to confirm without a prompt."
            return 0
        end

        read -l -P "Delete these? [y/N] " answer
        if not string match -qir '^y(es)?$' -- "$answer"
            echo "Kept."
            return 0
        end
    end

    set -l removed (__update_prune_apply $plan)
    echo "Reclaimed "(__update_human_size $bytes)" ($removed path(s) removed)."
    return 0
end
