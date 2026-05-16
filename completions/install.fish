# Autocomplete for 'install' command

complete -c install -l all -d 'Install every recipe marked install=true'
complete -c install -s c -l config -r -F -d 'Path to Lemonade config.json'
complete -c install -s s -l stream -d 'Stream install progress'
complete -c install -s f -l force -d 'Bypass hardware filtering'
complete -c install -s h -l help -d 'Show usage'

complete -c install -f -n 'not __fish_seen_subcommand_from flm kokoro llamacpp ryzenai ryzenai-llm sdcpp sd-cpp whispercpp vllm' -a 'flm kokoro llamacpp ryzenai sdcpp whispercpp vllm' -d 'Recipe'
complete -c install -f -n '__fish_seen_subcommand_from flm kokoro llamacpp ryzenai ryzenai-llm sdcpp sd-cpp whispercpp vllm' -a 'cpu rocm vulkan npu default' -d 'Backend'
