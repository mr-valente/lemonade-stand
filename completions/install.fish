# Autocomplete for 'install' command

complete -c install -f
complete -c install -l all -d 'Install every config.json section marked for installation'
complete -c install -s c -l config -r -F -d 'Path to Lemonade config.json'
complete -c install -s s -l stream -d 'Stream install progress'
complete -c install -s f -l force -d 'Bypass hardware filtering'
complete -c install -s h -l help -d 'Show usage'

function __install_completion_info
    set -l port 13305
    if set -q LEMONADE_PORT; and test -n "$LEMONADE_PORT"
        set port $LEMONADE_PORT
    end
    set -l headers
    if set -q LEMONADE_API_KEY; and test -n "$LEMONADE_API_KEY"
        set headers -H "Authorization: Bearer $LEMONADE_API_KEY"
    end
    curl -s -m 5 $headers "http://localhost:$port/api/v1/system-info" 2>/dev/null
end

# Positional words typed so far, after the command itself.
function __install_completion_words
    set -l words
    set -l skip false
    for token in (commandline -opc)[2..]
        if test "$skip" = true
            set skip false
        else if contains -- $token -c --config
            set skip true
        else if not string match -q -- '-*' $token
            set -a words $token
        end
    end
    test (count $words) -gt 0; and printf '%s\n' $words
end

# Recipes with at least one backend this machine can run.
function __install_completion_recipes
    __install_completion_info | jq -r '
        .recipes | to_entries[]
        | select(any(.value.backends[]; .state != "unsupported"))
        | "\(.key)\t\(.value.display_name // "Recipe")"' 2>/dev/null
end

# The chosen recipe's backends, described by state and format.
function __install_completion_backends
    set -l recipe (__install_completion_words)[1]
    switch "$recipe"
        case ryzenai
            set recipe ryzenai-llm
        case sdcpp
            set recipe sd-cpp
    end
    __install_completion_info | jq -r --arg recipe "$recipe" '
        .recipes[$recipe] as $r
        | $r.backends | to_entries[]
        | select(.value.state != "unsupported")
        | "\(.key)\t\(.value.state | gsub("_"; " ")), \(.value.format // "native")\(if .key == $r.default_backend then ", default" else "" end)"' 2>/dev/null
end

complete -c install -f -n 'test (count (__install_completion_words)) -eq 0' -a '(__install_completion_recipes)'
complete -c install -f -n 'test (count (__install_completion_words)) -eq 1; and not string match -q "*:*" -- (__install_completion_words)' -a '(__install_completion_backends)'
