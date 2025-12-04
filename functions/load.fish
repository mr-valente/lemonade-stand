function load
    argparse 'set=' -- $argv
    or return

    if set -q _flag_set
        set -l set_name $_flag_set
        set -l config_file /root/.cache/lemonade/model_sets.json

        if not test -f $config_file
            echo "Error: Configuration file $config_file not found."
            return 1
        end

        # Use jq to extract the array for the specific set
        set -l models (jq -r --arg s "$set_name" '.[$s][]?' $config_file)

        if test -z "$models"
            echo "Error: Set '$set_name' not found or empty in $config_file"
            return 1
        end

        for model in $models
            echo "Loading $model from set '$set_name'..."
            curl -X POST "http://localhost:$LEMONADE_PORT/api/v1/load" \
                -H "Content-Type: application/json" \
                -d "{ \"model_name\": \"$model\" }"
            echo ""
        end
    else
        if test (count $argv) -eq 0
            echo "Usage: load <model_name> [model_name...] OR load --set <set_name>"
            return 1
        end
        
        for model_name in $argv
            echo "Loading $model_name..."
            curl -X POST "http://localhost:$LEMONADE_PORT/api/v1/load" \
                -H "Content-Type: application/json" \
                -d "{ \"model_name\": \"$model_name\" }"
            echo ""
        end
    end
end
