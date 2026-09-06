source (builtin path dirname (status filename))/../functions/__lemonade_flm.fish

# Autocomplete for 'update' command

complete -c update -s a -l all -d 'Update pending registry and FLM models'
complete -c update -s c -l check -d 'List pending updates without changing anything'
complete -c update -s f -l force -d 'Re-pull even when no update is reported'
complete -c update -l flm -d 'Include FLM updates (included by default)'
complete -c update -s n -l dry-run -d 'Show what would be done, change nothing'
complete -c update -s y -l yes -d 'Do not prompt for confirmation'
complete -c update -s p -l prune -d 'Delete superseded weights after updating'
complete -c update -l no-reload -d 'Leave models unloaded after updating'
complete -c update -s h -l help -d 'Show usage'

function __update_completion_models
    set -l port $LEMONADE_PORT
    test -n "$port"; or set port 8000

    set -l headers
    if set -q LEMONADE_ADMIN_API_KEY; and test -n "$LEMONADE_ADMIN_API_KEY"
        set -a headers -H "Authorization: Bearer $LEMONADE_ADMIN_API_KEY"
    else if set -q LEMONADE_API_KEY; and test -n "$LEMONADE_API_KEY"
        set -a headers -H "Authorization: Bearer $LEMONADE_API_KEY"
    end

    set -l models (curl -s --max-time 3 "http://localhost:$port/api/v1/models?show_all=true" $headers 2>/dev/null)
    set -l flm_status (__flm_status)
    test -n "$flm_status"; or set flm_status '{"models":[]}'
    printf '%s\n' "$models" | jq -r --argjson flm "$flm_status" '
        .data[]? | . as $model
        | select(.downloaded or (.recipe == "flm" and any($flm.models[];
            .name == ($model.checkpoints.main // $model.checkpoint)
            and (.state == "ready" or .state == "outdated"))))
        | [.id, (.recipe // "model")] | @tsv' 2>/dev/null
end

# Complete downloaded model names from the API — only those can be updated
complete -c update -f -a '(__update_completion_models)'
