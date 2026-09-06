# fastpull passes everything except its own flags through to pull, so it offers
# the same completions. The helpers live in completions/pull.fish; fish autoloads
# that file when pull is completed, so source it here to make them available.
if not functions -q __pull_completion_variants
    set -l pull_completions (status dirname)/pull.fish
    test -f "$pull_completions"; and source "$pull_completions"
end

complete -c fastpull -s j -l streams -r -f -a '2 4 8 12 16' -d 'Connections per file (default 8)'
complete -c fastpull -s q -l quant -r -f -a '(__pull_completion_variants)' -d 'Main GGUF variant'
complete -c fastpull -s n -l name -r -f -d 'Registered user.* model name'
complete -c fastpull -l draft -r -f -a '(__pull_completion_drafts)' -d 'Draft or MTP GGUF path'
complete -c fastpull -l no-draft -d 'Do not install the advertised draft GGUF'
complete -c fastpull -l mmproj -r -f -a '(__pull_completion_mmproj)' -d 'Multimodal projector GGUF path'
complete -c fastpull -l no-mmproj -d 'Do not install the advertised projector'
complete -c fastpull -l source -r -f -a 'huggingface modelscope' -d 'Remote model registry'
complete -c fastpull -l alias -r -f -d 'Alias to register after pulling'
complete -c fastpull -s y -l yes -d 'Use recommended defaults without prompting'
complete -c fastpull -s h -l help -d 'Show usage'
complete -c fastpull -f -a '(__pull_completion_models)'
