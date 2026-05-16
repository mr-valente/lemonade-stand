function __install_usage
    echo "Usage:"
    echo "  install <recipe> <backend> [--stream] [--force]"
    echo "  install <recipe:backend> [--stream] [--force]"
    echo "  install --all [--config PATH] [--stream] [--force]"
    echo ""
    echo "Recipes: flm, kokoro, llamacpp, ryzenai, sdcpp, whispercpp, vllm"
end

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

function __install_backend --argument-names recipe backend stream force
    set -l api_recipe (__install_api_recipe $recipe)
    set -l port $LEMONADE_PORT

    if test -z "$port"
        set port 8000
    end

    set -l body (jq -nc \
        --arg recipe "$api_recipe" \
        --arg backend "$backend" \
        --argjson stream "$stream" \
        --argjson force "$force" \
        '{recipe: $recipe, backend: $backend, stream: $stream, force: $force}')

    set -l headers -H "Content-Type: application/json"
    if set -q LEMONADE_API_KEY; and test -n "$LEMONADE_API_KEY"
        set -a headers -H "Authorization: Bearer $LEMONADE_API_KEY"
    end

    set -l curl_args -sS
    if test "$stream" = true
        set -a curl_args -N
    end

    curl $curl_args -X POST "http://localhost:$port/api/v1/install" $headers -d "$body"
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

        set -l targets (jq -r '
            ["flm", "kokoro", "llamacpp", "ryzenai", "sdcpp", "whispercpp", "vllm"][]
            as $recipe
            | select(.[$recipe].install == true)
            | if ((.[$recipe].backend // "") == "") then
                error("Recipe \($recipe) has install=true but no backend")
              else
                "\($recipe):\(.[$recipe].backend)"
              end
        ' "$config_file")

        if test $status -ne 0
            return 1
        end

        if test (count $targets) -eq 0
            echo "No install=true recipes found in $config_file."
            return 0
        end

        set -l install_status 0
        for target in $targets
            set -l parts (string split -m 1 : -- $target)
            set -l recipe $parts[1]
            set -l backend $parts[2]

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
            if test (count $parts) -ne 2
                __install_usage
                return 1
            end
            set recipe $parts[1]
            set backend $parts[2]
        case 2
            set recipe $argv[1]
            set backend $argv[2]
        case '*'
            __install_usage
            return 1
    end

    if test -z "$recipe"; or test -z "$backend"
        __install_usage
        return 1
    end

    __install_backend $recipe $backend $stream $force
end
