function __delete_completion_port
    if set -q LEMONADE_PORT; and test -n "$LEMONADE_PORT"
        echo $LEMONADE_PORT
    else
        echo 8000
    end
end

function __delete_completion_headers
    if set -q LEMONADE_ADMIN_API_KEY; and test -n "$LEMONADE_ADMIN_API_KEY"
        echo -H
        echo "Authorization: Bearer $LEMONADE_ADMIN_API_KEY"
    else if set -q LEMONADE_API_KEY; and test -n "$LEMONADE_API_KEY"
        echo -H
        echo "Authorization: Bearer $LEMONADE_API_KEY"
    end
end

function __delete_completion_get --argument-names path
    curl -s --max-time 3 \
        "http://localhost:"(__delete_completion_port)"$path" \
        (__delete_completion_headers) 2>/dev/null
end

function __delete_completion_cache_dir
    # The environment answers this without a round trip, which a completion
    # should prefer. Only fall back to the server, which is authoritative when
    # models_dir points the cache somewhere else entirely.
    if set -q HF_HUB_CACHE; and test -d "$HF_HUB_CACHE"
        echo $HF_HUB_CACHE
        return 0
    end
    if set -q HF_HOME; and test -d "$HF_HOME/hub"
        echo "$HF_HOME/hub"
        return 0
    end

    set -l storage (__delete_completion_get /api/v1/system-info \
        | jq -r '.model_storage.path // empty' 2>/dev/null)
    if test -n "$storage"; and test -d "$storage"
        echo $storage
        return 0
    end
    if set -q HOME; and test -d "$HOME/.cache/huggingface/hub"
        echo "$HOME/.cache/huggingface/hub"
        return 0
    end
    return 1
end

# The token that names a cache directory: its repository id where that maps back
# to exactly this directory, and the directory itself where it cannot -- a
# repository whose own name contains "--" is not recoverable from the name.
function __delete_completion_cache_target --argument-names cache_name
    set -l source huggingface
    set -l remainder
    if string match -q 'modelscope--models--*' -- "$cache_name"
        set source modelscope
        set remainder (string replace 'modelscope--models--' '' -- "$cache_name")
    else if string match -q 'models--*' -- "$cache_name"
        set remainder (string replace 'models--' '' -- "$cache_name")
    else
        return 1
    end

    set -l repo (string replace -a -- -- / "$remainder")
    if string match -qr '^[^/]+/[^/]+$' -- "$repo"
        echo "$repo"\t"leftover $source cache"
    else
        echo "$cache_name"\t"leftover $source cache"
    end
end

function __delete_completion_targets
    set -l models (__delete_completion_get '/api/v1/models?show_all=true')
    set -l aliases (__delete_completion_get /internal/aliases \
        | jq -r '.aliases[]?.alias' 2>/dev/null)

    for entry in (printf '%s\n' "$models" | jq -r '
            .data[]?
            | select((.downloaded == true or (.id | startswith("user.")))
                     and (.id | startswith("extra.") | not)
                     and .recipe != "cloud")
            | [.id, ((.recipe // "model") + if .downloaded then ", downloaded" else ", registered" end)]
            | @tsv' 2>/dev/null)
        set -l parts (string split \t -- $entry)
        contains -- $parts[1] $aliases; or echo $entry
    end

    # Directories an earlier delete left behind. A model that still holds files
    # claims its own directory and is offered above under its model name, so
    # only what nothing claims is listed here.
    set -l cache_dir (__delete_completion_cache_dir)
    or return
    set -l claimed (printf '%s\n' "$models" | jq -r '
        .data[]?
        | select(.downloaded == true or (.id | startswith("user.")))
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
          + gsub("/"; "--")' 2>/dev/null)

    for entry in (find "$cache_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
        set -l name (path basename "$entry")
        string match -q 'models--*' -- "$name"
        or string match -q 'modelscope--models--*' -- "$name"
        or continue
        contains -- $name $claimed; and continue
        __delete_completion_cache_target "$name"
    end
end

complete -c delete -s n -l dry-run -d 'Preview models and files without deleting'
complete -c delete -s y -l yes -d 'Do not prompt for confirmation'
complete -c delete -l no-cleanup -d 'Skip additional cache cleanup'
complete -c delete -s h -l help -d 'Show usage'
complete -c delete -f -a '(__delete_completion_targets)'
