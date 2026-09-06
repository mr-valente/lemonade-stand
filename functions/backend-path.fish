function __lemonade_backend_root
    if set -q LEMONADE_BACKEND_DIR; and test -n "$LEMONADE_BACKEND_DIR"
        echo "$LEMONADE_BACKEND_DIR"
    else if set -q XDG_CACHE_HOME; and test -n "$XDG_CACHE_HOME"
        echo "$XDG_CACHE_HOME/lemonade/bin"
    else
        echo "$HOME/.cache/lemonade/bin"
    end
end

function __lemonade_rocm_roots
    set -l root (__lemonade_backend_root)
    set -q ROCM_PATH; and test -d "$ROCM_PATH"; and echo "$ROCM_PATH"
    for family in therock-wheels therock
        set -l candidates "$root/$family"/*
        for directory in (printf '%s\n' $candidates | sort -Vr)
            test -d "$directory"; and echo "$directory"
        end
    end
    test -d /opt/rocm; and echo /opt/rocm
end

function backend-path --description 'Refresh PATH for installed Lemonade backends and ROCm tools'
    set -l root (__lemonade_backend_root)
    set -l directories /opt/bin
    # Runtime tools precede vLLM's separately bundled ROCm utilities.
    for runtime in (__lemonade_rocm_roots)
        set -a directories "$runtime/venv/bin" "$runtime/bin" "$runtime/lib/llvm/bin"
    end
    # Put the selected backend ahead of the other variants of the same command.
    set -l config (builtin path dirname "$root")/config.json
    for entry in (jq -r '
        . as $config | to_entries[] | select(.value | type == "object")
        | select(.value.backend != null)
        | [(if .key == "sdcpp" then "sd-cpp" else .key end), .value.backend,
            (.value.rocm_channel // $config.rocm_channel // "stable")] | @tsv' "$config" 2>/dev/null)
        set -l parts (string split \t -- "$entry")
        set -l backend $parts[2]
        if test "$backend" = rocm; and not test -d "$root/$parts[1]/rocm"
            set backend "rocm-$parts[3]"
        end
        set -a directories "$root/$parts[1]/$backend" "$root/$parts[1]/$backend/bin"
    end
    for recipe in "$root"/*
        switch (builtin path basename "$recipe")
            case therock therock-wheels '*.old' '*.staging'
                continue
        end
        for backend in "$recipe"/*
            string match -qr '\.(old|staging)$' -- "$backend"; and continue
            set -a directories "$backend" "$backend/bin"
        end
    end

    # Track only our own additions, so refresh can change precedence or remove a
    # deleted backend without changing the user's original PATH entries.
    set -l original
    for directory in $PATH
        contains -- "$directory" $__lemonade_added_paths; or set -a original "$directory"
    end
    set -g __lemonade_added_paths
    for directory in $directories
        test -d "$directory"; or continue
        contains -- "$directory" $original $__lemonade_added_paths; and continue
        set -ga __lemonade_added_paths "$directory"
    end
    set -gx PATH $original $__lemonade_added_paths
    if contains -- --list $argv
        printf '%s\n' $__lemonade_added_paths
    end
end
