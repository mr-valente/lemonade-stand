# Autocomplete for 'unload' command

# Complete loaded model names from the health endpoint
complete -c unload -f -a '(curl -s http://localhost:$LEMONADE_PORT/api/v1/health | jq -r ".all_models_loaded[]?.model_name")'