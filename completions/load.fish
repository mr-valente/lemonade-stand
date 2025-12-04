# Autocomplete for 'load' command

# Complete set names from the JSON file
# -r: Indicates that --set requires an argument (prevents falling back to positional args)
complete -c load -l set -r -f -a '(jq -r "keys[]" /root/.cache/lemonade/model_sets.json 2>/dev/null)'

# Complete model names from the API
complete -c load -f -a '(curl -s http://localhost:$LEMONADE_PORT/api/v1/models | jq -r ".data[].id")'
