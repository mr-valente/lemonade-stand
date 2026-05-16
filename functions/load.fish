function __load_usage
    echo "Usage:"
    echo "  load <model_name> [model_name...] [options]"
    echo "  load --set <set_name> [options]"
    echo ""
    echo "Options:"
    echo "  --ctx_size <tokens>"
    echo "  --llamacpp_backend <vulkan|rocm|metal|cpu>"
    echo "  --llamacpp_args <args>"
    echo "  --whispercpp_backend <backend>"
    echo "  --whispercpp_args <args>"
    echo "  --steps <count>"
    echo "  --cfg_scale <scale>"
    echo "  --width <pixels>"
    echo "  --height <pixels>"
    echo "  --save_options <true|false>"
    echo "  --merge_args <true|false>"
end

function __load_bool --argument-names option value
    set -l normalized (string lower -- "$value")

    switch $normalized
        case true false
            echo $normalized
        case '*'
            echo "Error: --$option must be true or false." >&2
            return 1
    end
end

function __load_int --argument-names option value
    if string match -qr '^[0-9]+$' -- "$value"
        echo $value
        return 0
    end

    echo "Error: --$option must be an integer." >&2
    return 1
end

function __load_number --argument-names option value
    if string match -qr '^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$' -- "$value"
        echo $value
        return 0
    end

    echo "Error: --$option must be a number." >&2
    return 1
end

function __load_body --argument-names model_name
    set -l option_args $argv[2..-1]

    jq -nc --arg model_name "$model_name" $option_args '$ARGS.named'
end

function __load_model --argument-names model_name
    set -l option_args $argv[2..-1]
    set -l port $LEMONADE_PORT

    if test -z "$port"
        set port 8000
    end

    set -l body (__load_body "$model_name" $option_args)
    or return

    set -l headers -H "Content-Type: application/json"
    if set -q LEMONADE_API_KEY; and test -n "$LEMONADE_API_KEY"
        set -a headers -H "Authorization: Bearer $LEMONADE_API_KEY"
    end

    curl -sS -X POST "http://localhost:$port/api/v1/load" $headers -d "$body"
end

function load
    argparse -n load \
        'set=' \
        'ctx_size=' \
        'llamacpp_backend=' \
        'llamacpp_args=' \
        'whispercpp_backend=' \
        'whispercpp_args=' \
        'steps=' \
        'cfg_scale=' \
        'width=' \
        'height=' \
        'save_options=' \
        'merge_args=' \
        'h/help' \
        -- $argv
    or return

    if set -q _flag_help
        __load_usage
        return 0
    end

    set -l load_jq_args

    if set -q _flag_save_options
        set -l save_options (__load_bool save_options $_flag_save_options[-1])
        or return
        set -a load_jq_args --argjson save_options "$save_options"
    end

    if set -q _flag_ctx_size
        set -l ctx_size (__load_int ctx_size $_flag_ctx_size[-1])
        or return
        set -a load_jq_args --argjson ctx_size "$ctx_size"
    end

    if set -q _flag_llamacpp_backend
        set -a load_jq_args --arg llamacpp_backend "$_flag_llamacpp_backend[-1]"
    end

    if set -q _flag_llamacpp_args
        set -a load_jq_args --arg llamacpp_args "$_flag_llamacpp_args[-1]"
    end

    if set -q _flag_whispercpp_backend
        set -a load_jq_args --arg whispercpp_backend "$_flag_whispercpp_backend[-1]"
    end

    if set -q _flag_whispercpp_args
        set -a load_jq_args --arg whispercpp_args "$_flag_whispercpp_args[-1]"
    end

    if set -q _flag_steps
        set -l steps (__load_int steps $_flag_steps[-1])
        or return
        set -a load_jq_args --argjson steps "$steps"
    end

    if set -q _flag_cfg_scale
        set -l cfg_scale (__load_number cfg_scale $_flag_cfg_scale[-1])
        or return
        set -a load_jq_args --argjson cfg_scale "$cfg_scale"
    end

    if set -q _flag_width
        set -l width (__load_int width $_flag_width[-1])
        or return
        set -a load_jq_args --argjson width "$width"
    end

    if set -q _flag_height
        set -l height (__load_int height $_flag_height[-1])
        or return
        set -a load_jq_args --argjson height "$height"
    end

    if set -q _flag_merge_args
        set -l merge_args (__load_bool merge_args $_flag_merge_args[-1])
        or return
        set -a load_jq_args --argjson merge_args "$merge_args"
    end

    if set -q _flag_set
        if test (count $argv) -ne 0
            __load_usage
            return 1
        end

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
            __load_model "$model" $load_jq_args
            echo ""
        end
    else
        if test (count $argv) -eq 0
            __load_usage
            return 1
        end
        
        for model_name in $argv
            echo "Loading $model_name..."
            __load_model "$model_name" $load_jq_args
            echo ""
        end
    end
end
