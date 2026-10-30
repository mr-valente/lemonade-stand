# Autocomplete for 'unload' command

function __unload_completion_port
    if set -q LEMONADE_PORT; and test -n "$LEMONADE_PORT"
        echo $LEMONADE_PORT
    else
        echo 13305
    end
end

# Complete loaded model names from the health endpoint
complete -c unload -f -a '(curl -s http://localhost:(__unload_completion_port)/api/v1/health | jq -r ".all_models_loaded[]?.model_name")'
