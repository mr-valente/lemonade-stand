# Autocomplete for 'update' command

complete -c update -s a -l all -d 'Update every model reported by check-updates'
complete -c update -s c -l check -d 'List pending updates without changing anything'
complete -c update -s f -l force -d 'Re-pull even when no update is reported'
complete -c update -l flm -d 'With --all, also refresh FLM models'
complete -c update -s n -l dry-run -d 'Show what would be done, change nothing'
complete -c update -s y -l yes -d 'Do not prompt for confirmation'
complete -c update -s p -l prune -d 'Delete superseded weights after updating'
complete -c update -l no-reload -d 'Leave models unloaded after updating'
complete -c update -s h -l help -d 'Show usage'

# Complete downloaded model names from the API — only those can be updated
complete -c update -f -a '(curl -s "http://localhost:$LEMONADE_PORT/api/v1/models" | jq -r ".data[] | select(.downloaded) | .id")'
