function unload
    argparse 'a/all' -- $argv
    or return

    if set -q _flag_all
        set -l health_response (curl -s "http://localhost:$LEMONADE_PORT/api/v1/health")
        set -l models (echo $health_response | jq -r '.all_models_loaded[]?.model_name')

        if test -z "$models"
            echo "No models currently loaded."
            return 0
        end

        for model in $models
            echo "Unloading $model..."
            curl -s -X POST "http://localhost:$LEMONADE_PORT/api/v1/unload" \
                -H "Content-Type: application/json" \
                -d "{ \"model_name\": \"$model\" }"
            echo ""
        end
    else
        if test (count $argv) -eq 0
            echo "Usage: unload <model_name> OR unload --all"
            return 1
        end
        set -l model_name $argv[1]
        curl -X POST "http://localhost:$LEMONADE_PORT/api/v1/unload" \
            -H "Content-Type: application/json" \
            -d "{ \"model_name\": \"$model_name\" }"
    end
end
