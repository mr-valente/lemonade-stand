function __install_usage
    echo "Usage:"
    echo "  install <recipe> [backend] [--stream] [--force]"
    echo "  install <recipe:backend> [--stream] [--force]"
    echo "  install --all [--config PATH] [--stream] [--force]"
    echo ""
    echo "Without a backend, the recipe's default backend is installed."
    echo "Recipes and backends come from the server; 'lemonade backends' lists them."
    echo ""
    echo "--all installs every config.json section marked for installation:"
    echo '  "install": true                 the section\'s backend, or the recipe default'
    echo '  "install": ["rocm", "nathanw"]  each named backend'
end

# config.json names two sections differently from the recipes they configure.
function __install_api_recipe --argument-names recipe
    switch $recipe
        case ryzenai
            echo ryzenai-llm
        case sdcpp
            echo sd-cpp
        case '*'
            echo $recipe
    end
end

function __install_port
    if set -q LEMONADE_PORT; and test -n "$LEMONADE_PORT"
        echo $LEMONADE_PORT
    else
        echo 13305
    end
end

function __install_headers
    printf '%s\n' -H "Content-Type: application/json"
    if set -q LEMONADE_API_KEY; and test -n "$LEMONADE_API_KEY"
        printf '%s\n' -H "Authorization: Bearer $LEMONADE_API_KEY"
    end
end

# The server's view of every recipe: its default backend and each backend's
# state, tier and format (native, python or container).
function __install_system_info
    curl -sS -m 30 (__install_headers) "http://localhost:"(__install_port)"/api/v1/system-info"
end

function __install_default_backend --argument-names info recipe
    printf '%s\n' "$info" | jq -r --arg recipe "$recipe" '.recipes[$recipe].default_backend // empty' 2>/dev/null
end

function __install_backend --argument-names recipe backend stream force
    set -l body (jq -nc \
        --arg recipe "$recipe" \
        --arg backend "$backend" \
        --argjson stream "$stream" \
        --argjson force "$force" \
        '{recipe: $recipe, backend: $backend, stream: $stream, force: $force}')

    set -l curl_args -sS
    if test "$stream" = true
        set -a curl_args -N
    end

    curl $curl_args -X POST "http://localhost:"(__install_port)"/api/v1/install" (__install_headers) -d "$body"
end

function install --description 'Install Lemonade backends via the API'
    argparse 'a/all' 'c/config=' 's/stream' 'f/force' 'h/help' -- $argv
    or return

    if set -q _flag_help
        __install_usage
        return 0
    end

    set -l stream false
    if set -q _flag_stream
        set stream true
    end

    set -l force false
    if set -q _flag_force
        set force true
    end

    if set -q _flag_all
        if test (count $argv) -ne 0
            __install_usage
            return 1
        end

        set -l config_file ~/.cache/lemonade/config.json
        if set -q _flag_config
            set config_file $_flag_config
        end

        if not test -f "$config_file"
            echo "Error: Configuration file $config_file not found."
            return 1
        end

        # One "section:backend" line per install; an empty backend means the
        # recipe's default, which only the server knows.
        set -l targets (jq -r '
            to_entries[]
            | select(.value | type == "object")
            | select(.value.install == true or (.value.install | type) == "array")
            | .key as $section
            | if (.value.install | type) == "array" then .value.install[]
              elif (.value.backend // "auto") == "auto" then ""
              else .value.backend end
            | "\($section):\(.)"
        ' "$config_file")

        if test $status -ne 0
            echo "Error: could not read $config_file."
            return 1
        end

        if test (count $targets) -eq 0
            echo "Nothing is marked for installation in $config_file."
            return 0
        end

        set -l info
        set -l install_status 0
        for target in $targets
            set -l parts (string split -m 1 : -- $target)
            set -l recipe (__install_api_recipe $parts[1])
            set -l backend $parts[2]

            if test -z "$backend"
                test -n "$info"; or set info (__install_system_info 2>/dev/null | string collect)
                set backend (__install_default_backend "$info" $recipe)
                if test -z "$backend"
                    echo "Error: $parts[1] has no backend set and the server reports no default for it."
                    set install_status 1
                    continue
                end
            end

            echo "Installing $recipe:$backend..."
            __install_backend $recipe $backend $stream $force
            or set install_status 1
            echo ""
        end

        return $install_status
    end

    if set -q _flag_config
        echo "Error: --config can only be used with --all."
        return 1
    end

    set -l recipe
    set -l backend

    switch (count $argv)
        case 1
            set -l parts (string split -m 1 : -- $argv[1])
            set recipe $parts[1]
            set backend $parts[2]
        case 2
            set recipe $argv[1]
            set backend $argv[2]
        case '*'
            __install_usage
            return 1
    end

    if test -z "$recipe"
        __install_usage
        return 1
    end
    set recipe (__install_api_recipe $recipe)

    if test -z "$backend"
        set backend (__install_default_backend (__install_system_info | string collect) $recipe)
        if test -z "$backend"
            echo "Error: '$recipe' is not a recipe the server knows. Run 'lemonade backends' to list them."
            return 1
        end
        echo "Installing $recipe:$backend..."
    end

    __install_backend $recipe $backend $stream $force
end
