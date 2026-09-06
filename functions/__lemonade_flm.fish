# Shared FLM discovery. JSON "installed" means compatible/current, not present.
function __flm_binary
    if set -q LEMONADE_FLM_NPU_BIN; and test -x "$LEMONADE_FLM_NPU_BIN"
        echo "$LEMONADE_FLM_NPU_BIN"
        return
    end
    set -l root "$HOME/.cache/lemonade/bin"
    set -q XDG_CACHE_HOME; and set root "$XDG_CACHE_HOME/lemonade/bin"
    set -q LEMONADE_BACKEND_DIR; and set root "$LEMONADE_BACKEND_DIR"
    if test -x "$root/flm/npu/flm"
        echo "$root/flm/npu/flm"
    else
        command -s flm
    end
end

function __flm_catalog
    set -l binary (__flm_binary)
    test -n "$binary"; or return 1
    set -l payload (command "$binary" list --json 2>/dev/null)
    or return 1
    printf '%s\n' "$payload" | jq -ce '
        select((.models | type) == "array")
        | select(all(.models[]; (.name | type) == "string" and (.url | type) == "string"))' 2>/dev/null
end

function __flm_status
    set -l binary (__flm_binary)
    test -n "$binary"; or return 1
    set -l listing (command "$binary" list 2>&1)
    or return 1
    __flm_parse_status $listing
end

function __flm_parse_status
    # The same warning icon also means "model newer than the FLM runtime".
    # Only the explicit < comparison is evidence that weights need updating.
    printf '%s\n' $argv | jq -Rsc '
        gsub("\u001b[[][0-9;]*[A-Za-z]"; "") | split("\n") as $lines
        | [$lines[] | capture("Local model (?<name>[^[:space:]]+) version: (?<local>[^[:space:]]+) (?<comparison>[<>]) (?<required>[^[:space:]]+)")?] as $warnings
        | [$lines[] | capture("^[[:space:]]*- (?<name>[^[:space:]]+) (?<marker>✅|⏬|⚠️?)[[:space:]]*$")?
            | . as $row
            | ([$warnings[] | select(.name == $row.name)][0] // {}) as $warning
            | {name, state: (if .marker == "✅" then "ready"
                elif .marker == "⏬" then "missing"
                elif $warning.comparison == "<" then "outdated"
                elif $warning.comparison == ">" then "incompatible"
                else "unknown" end),
                local_version: ($warning.local // ""), required_version: ($warning.required // "")}]
        | if length == 0 then error("unrecognized flm list output") else {models:.} end' 2>/dev/null
end

function __flm_model_roots
    set -l roots
    if set -q FLM_MODEL_PATH; and test -n "$FLM_MODEL_PATH"
        set -a roots "$FLM_MODEL_PATH/models"
    end
    if set -q XDG_CONFIG_HOME; and test -n "$XDG_CONFIG_HOME"
        set -a roots "$XDG_CONFIG_HOME/flm/models"
    end
    set -a roots "$HOME/.config/flm/models" "$HOME/.flm/models"
    set -l seen
    for root in $roots
        test -d "$root"; or continue
        set root (builtin path resolve "$root")
        contains -- "$root" $seen; and continue
        set -a seen "$root"
        echo "$root"
    end
end

function __flm_repo_name --argument-names model
    # Prefer the catalog's on-disk name when available. list --json replaces that
    # field with the public tag, so its URL is the fallback used by Lemonade too.
    set -l tag (printf '%s\n' "$model" | jq -r '.name')
    set -l binary (__flm_binary)
    set -l catalog (builtin path dirname "$binary")/model_list.json
    if test -f "$catalog"
        set -l name (jq -r --arg tag "$tag" '
            ($tag | split(":")) as $parts | .models[$parts[0]][$parts[1]].name // empty' "$catalog" 2>/dev/null)
        if string match -qr '^[A-Za-z0-9_][A-Za-z0-9_.-]*$' -- "$name"
            echo "$name"
            return
        end
    end
    printf '%s\n' "$model" | jq -er '
        .url | sub("[?#].*$"; "") | sub("/(tree|resolve)/.*$"; "")
        | sub("/+$"; "") | split("/")[-1]
        | select(test("^[A-Za-z0-9_][A-Za-z0-9_.-]*$"))' 2>/dev/null
end

function __flm_model_dirs --argument-names model
    set -l name (__flm_repo_name "$model")
    or return 1
    for root in (__flm_model_roots)
        test -d "$root/$name"; and echo "$root/$name"
    end
    return 0
end

function __flm_safe_dir --argument-names directory
    # Exactly one model directory below a known FLM root, never a root, sibling,
    # traversal, or symlink to another location.
    test -L "$directory"; and return 1
    for root in (__flm_model_roots)
        if test (builtin path dirname "$directory") = "$root"; and test (builtin path resolve "$directory") = "$directory"
            return 0
        end
    end
    return 1
end
