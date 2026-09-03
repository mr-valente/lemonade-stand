function __pull_completion_port
    if set -q LEMONADE_PORT; and test -n "$LEMONADE_PORT"
        echo $LEMONADE_PORT
    else
        echo 8000
    end
end

function __pull_completion_api --argument-names path
    set -l headers
    if set -q LEMONADE_ADMIN_API_KEY; and test -n "$LEMONADE_ADMIN_API_KEY"
        set -a headers -H "Authorization: Bearer $LEMONADE_ADMIN_API_KEY"
    else if set -q LEMONADE_API_KEY; and test -n "$LEMONADE_API_KEY"
        set -a headers -H "Authorization: Bearer $LEMONADE_API_KEY"
    end
    curl -s --max-time 3 "http://localhost:"(__pull_completion_port)"$path" $headers 2>/dev/null
end

function __pull_completion_checkpoint
    set -l tokens (commandline -opc)
    set -e tokens[1]

    # argparse rejects a required-value option while its value is the token
    # currently being completed. Scan only far enough to find the positional
    # repository so `pull owner/repo --quant <Tab>` still has repository context.
    set -l skip_next false
    set -l positional_only false
    for token in $tokens
        if test $skip_next = true
            set skip_next false
            continue
        end

        if test $positional_only = true
            echo $token
            return
        end

        switch $token
            case --
                set positional_only true
            case -q --quant -n --name --draft --mmproj --source --alias
                set skip_next true
            case '-q?*' '-n?*' '--quant=*' '--name=*' '--draft=*' '--mmproj=*' '--source=*' '--alias=*'
                continue
            case '-*'
                continue
            case '*'
                echo $token
                return
        end
    end
end

function __pull_completion_variants
    set -l checkpoint (__pull_completion_checkpoint)
    test -n "$checkpoint"; or return

    set checkpoint (string replace -r ':[^:]+$' '' -- "$checkpoint")
    string match -q '*/*' -- "$checkpoint"; or return

    set -l encoded (string escape --style=url -- "$checkpoint")
    __pull_completion_api "/api/v1/pull/variants?checkpoint=$encoded" |
        jq -r '.variants[]? | [.name, ((.size_bytes // 0) / 1073741824 | tostring) + " GB"] | @tsv' 2>/dev/null
end

function __pull_completion_drafts
    set -l checkpoint (__pull_completion_checkpoint)
    test -n "$checkpoint"; or return

    set checkpoint (string replace -r ':[^:]+$' '' -- "$checkpoint")
    set -l encoded (string escape --style=url -- "$checkpoint")
    __pull_completion_api "/api/v1/pull/variants?checkpoint=$encoded" |
        jq -r '
            ([.variants[]?.draft_file]
             | map(select(. != null and . != "")) | unique) as $resolved
            | if ($resolved | length) > 0
              then $resolved[]
              else .draft_files[]?
              end' 2>/dev/null
end

function __pull_completion_mmproj
    set -l checkpoint (__pull_completion_checkpoint)
    test -n "$checkpoint"; or return

    set checkpoint (string replace -r ':[^:]+$' '' -- "$checkpoint")
    set -l encoded (string escape --style=url -- "$checkpoint")
    __pull_completion_api "/api/v1/pull/variants?checkpoint=$encoded" |
        jq -r '.mmproj_files[]?' 2>/dev/null
end

function __pull_completion_models
    __pull_completion_api '/api/v1/models?show_all=true' |
        jq -r '.data[]? | [.id, ((.recipe // "model") + if .downloaded then ", downloaded" else "" end)] | @tsv' 2>/dev/null
end

complete -c pull -s q -l quant -r -f -a '(__pull_completion_variants)' -d 'Main GGUF variant'
complete -c pull -s n -l name -r -f -d 'Registered user.* model name'
complete -c pull -l draft -r -f -a '(__pull_completion_drafts)' -d 'Draft or MTP GGUF path'
complete -c pull -l no-draft -d 'Do not install the advertised draft GGUF'
complete -c pull -l mmproj -r -f -a '(__pull_completion_mmproj)' -d 'Multimodal projector GGUF path'
complete -c pull -l no-mmproj -d 'Do not install the advertised projector'
complete -c pull -l source -r -f -a 'huggingface modelscope' -d 'Remote model registry'
complete -c pull -l alias -r -f -d 'Alias to register after pulling'
complete -c pull -s r -l repair-mtp -d 'Add and download an MTP draft for an existing custom model'
complete -c pull -s y -l yes -d 'Use recommended defaults without prompting'
complete -c pull -s h -l help -d 'Show usage'
complete -c pull -f -a '(__pull_completion_models)'
