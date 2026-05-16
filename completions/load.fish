# Autocomplete for 'load' command

complete -c load -s h -l help -d 'Show usage'

# Complete set names from the JSON file
# -r: Indicates that --set requires an argument (prevents falling back to positional args)
complete -c load -l set -r -f -a '(jq -r "keys[]" /root/.cache/lemonade/model_sets.json 2>/dev/null)' -d 'Load a model set'

complete -c load -l ctx_size -r -f -d 'Context window size'
complete -c load -l llamacpp_backend -r -f -a 'vulkan rocm metal cpu' -d 'llama.cpp backend'
complete -c load -l llamacpp_args -r -d 'Extra llama-server arguments'
complete -c load -l whispercpp_backend -r -f -a 'cpu vulkan npu' -d 'Whisper backend'
complete -c load -l whispercpp_args -r -d 'Extra whisper-server arguments'
complete -c load -l steps -r -f -d 'Image inference steps'
complete -c load -l cfg_scale -r -f -d 'Image guidance scale'
complete -c load -l width -r -f -d 'Image width'
complete -c load -l height -r -f -d 'Image height'
complete -c load -l save_options -r -f -a 'true false' -d 'Save per-model recipe options'
complete -c load -l merge_args -r -f -a 'true false' -d 'Merge global and per-model args'

# Complete model names from the API
complete -c load -f -a '(curl -s http://localhost:$LEMONADE_PORT/api/v1/models | jq -r ".data[].id")'
