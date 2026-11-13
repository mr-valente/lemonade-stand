# Autocomplete for 'list'

complete -c list -s h -l help -d 'Show usage'

function __list_completion_port
    if set -q LEMONADE_PORT; and test -n "$LEMONADE_PORT"
        echo $LEMONADE_PORT
    else
        echo 13305
    end
end

function __list_completion_names
    # Downloaded models and every alias, which the filter also matches. The
    # model list repeats some aliases as models, so print aliases first and
    # skip those names below.
    set -l base "http://localhost:"(__list_completion_port)
    set -l aliases (curl -s -m 5 "$base/internal/aliases" | jq -r '.aliases[]? | "\(.alias)\t→ \(.target)"' 2>/dev/null)
    printf '%s\n' $aliases
    set -l alias_names (string replace -r '\t.*' '' -- $aliases)
    for entry in (curl -s -m 5 "$base/api/v1/models" | jq -r '.data[]? | select(.downloaded != false) | "\(.id)\t\(.recipe // "model")"' 2>/dev/null)
        contains -- (string replace -r '\t.*' '' -- $entry) $alias_names; or echo $entry
    end
end

complete -c list -f -a '(__list_completion_names)'
