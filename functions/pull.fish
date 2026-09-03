function __pull_usage
    echo "Usage:"
    echo "  pull <model_name>"
    echo "  pull <owner/repo[:variant]> [options]"
    echo ""
    echo "Options for registry checkpoints:"
    echo "  -q, --quant <variant>    Select the main GGUF variant"
    echo "  -n, --name <name>        Set the registered user.* model name"
    echo "      --draft <path>       Override the repo-relative draft/MTP GGUF"
    echo "      --no-draft           Do not install an advertised draft GGUF"
    echo "      --mmproj <path>      Override the repo-relative projector GGUF"
    echo "      --no-mmproj          Do not install an advertised projector"
    echo "      --source <source>    huggingface or modelscope"
    echo "      --alias <name>       Register an alias after a successful pull"
    echo "  -r, --repair-mtp         Add and download the advertised MTP draft for an existing custom model"
    echo "  -y, --yes                Use the recommended variant and default name"
    echo "  -h, --help               Show this help"
    echo ""
    echo "Draft and projector companions are included automatically. Explicit paths"
    echo "are relative to the model repository, for example MTP/mtp-model-Q4_0.gguf."
end

function __pull_port
    if set -q LEMONADE_PORT; and test -n "$LEMONADE_PORT"
        echo $LEMONADE_PORT
    else
        echo 8000
    end
end

function __pull_api --argument-names method path body timeout
    test -z "$timeout"; and set timeout 120

    set -l curl_args -sS -m $timeout -X $method "http://localhost:"(__pull_port)"$path"
    set -a curl_args -H "Content-Type: application/json"

    if set -q LEMONADE_ADMIN_API_KEY; and test -n "$LEMONADE_ADMIN_API_KEY"
        set -a curl_args -H "Authorization: Bearer $LEMONADE_ADMIN_API_KEY"
    else if set -q LEMONADE_API_KEY; and test -n "$LEMONADE_API_KEY"
        set -a curl_args -H "Authorization: Bearer $LEMONADE_API_KEY"
    end

    if test -n "$body"
        set -a curl_args -d "$body"
    end

    set -l response (curl $curl_args -w '\n%{http_code}' 2>/dev/null)
    or return 2

    set -l code $response[-1]
    set -l payload $response[1..-2]

    if test (count $payload) -gt 0
        string join \n -- $payload
    end

    if string match -qr '^[45]' -- "$code"
        return 1
    end

    return 0
end

function __pull_api_error --argument-names payload
    set -l message (printf '%s\n' "$payload" | jq -r '
        if type == "object" then
            (.error | if type == "object" then (.message // (. | tostring)) else . end)
                // .detail // .message // empty
        else empty end' 2>/dev/null)

    if test -n "$message"; and test "$message" != null
        echo $message
    else if test -n "$payload"
        echo $payload
    else
        echo "no response from the server"
    end
end

function __pull_cli
    if command -q lemonade
        echo lemonade
    else if command -q lemonade-server
        echo lemonade-server
    end
end

function __pull_cli_exec
    set -l cli (__pull_cli)
    if test -z "$cli"
        echo "Error: neither lemonade nor lemonade-server is on PATH." >&2
        return 1
    end

    set -lx LEMONADE_PORT (__pull_port)
    set -q LEMONADE_ADMIN_API_KEY; and set -lx LEMONADE_ADMIN_API_KEY $LEMONADE_ADMIN_API_KEY
    set -q LEMONADE_API_KEY; and set -lx LEMONADE_API_KEY $LEMONADE_API_KEY
    command $cli $argv
end

function __pull_human_size --argument-names bytes
    if test -z "$bytes"; or test "$bytes" -le 0 2>/dev/null
        echo "unknown size"
        return
    end

    printf '%s\n' $bytes | awk '{
        split("B KB MB GB TB", unit, " ")
        i = 1
        size = $1
        while (size >= 1024 && i < 5) { size /= 1024; i++ }
        printf (i == 1 ? "%d %s\n" : "%.1f %s\n"), size, unit[i]
    }'
end

function __pull_normalize_hf_url --argument-names value
    set value (string replace -r '[?#].*$' '' -- "$value")
    set value (string replace -r '/+$' '' -- "$value")

    if string match -qr '^https?://(www\.)?huggingface\.co/' -- "$value"
        string replace -r '^https?://(www\.)?huggingface\.co/([^/]+/[^/]+).*$' '$2' -- "$value"
    else
        echo $value
    end
end

function __pull_variant_name --argument-names variants requested
    printf '%s\n' "$variants" | jq -r --arg requested "$requested" '
        [
            .variants[]?
            | select(
                ((.name // "") | ascii_downcase) == ($requested | ascii_downcase)
                or ((.primary_file // "") | ascii_downcase) == ($requested | ascii_downcase)
                or any(.files[]?; ascii_downcase == ($requested | ascii_downcase))
            )
            | .name
        ][0] // empty' 2>/dev/null
end

function __pull_prompt_variant --argument-names variants
    set -l entries (printf '%s\n' "$variants" | jq -r '
        .variants[]? | [.name, (.size_bytes // 0 | tostring)] | @tsv' 2>/dev/null)

    if test (count $entries) -eq 0
        return 1
    end

    echo "Select a main GGUF variant:"
    set -l visible (count $entries)
    if test $visible -gt 5
        set visible 5
    end

    for index in (seq $visible)
        set -l parts (string split \t -- $entries[$index])
        printf '  %d) %-18s %s\n' $index $parts[1] (__pull_human_size $parts[2])
    end
    if test (count $entries) -gt $visible
        echo "  ... "(math (count $entries) - $visible)" more; type any variant name"
    end

    read -l -P "Variant [1]: " answer
    or return 1

    if test -z "$answer"
        set answer 1
    end

    if string match -qr '^[0-9]+$' -- "$answer"
        if test $answer -lt 1; or test $answer -gt (count $entries)
            echo "Error: variant selection is out of range." >&2
            return 1
        end
        echo (string split \t -- $entries[$answer])[1]
        return 0
    end

    set -l selected (__pull_variant_name "$variants" "$answer")
    if test -z "$selected"
        echo "Error: '$answer' is not a variant reported by the server." >&2
        return 1
    end
    echo $selected
end

function __pull_resolve_hf_companion --argument-names checkpoint filename
    set -l curl_args -fsS --max-time 30
    if set -q HF_TOKEN; and test -n "$HF_TOKEN"
        set -a curl_args -H "Authorization: Bearer $HF_TOKEN"
    end

    set -l metadata (curl $curl_args "https://huggingface.co/api/models/$checkpoint" 2>/dev/null)
    or return 1

    set -l matches (printf '%s\n' "$metadata" | jq -r --arg filename "$filename" '
        [.siblings[]?.rfilename
         | select(. == $filename or endswith("/" + $filename))]
        | unique[]' 2>/dev/null)

    if test (count $matches) -eq 1
        echo $matches[1]
        return 0
    end

    return 1
end

function __pull_passthrough --argument-names model source alias_name
    set -l args pull $model
    test -n "$source"; and set -a args --source $source
    test -n "$alias_name"; and set -a args --alias $alias_name
    __pull_cli_exec $args
end

function __pull_registration_payload --argument-names model_json model_name draft
    printf '%s\n' "$model_json" | jq -c --arg model "$model_name" --arg draft "$draft" '
        {
            model_name: $model,
            checkpoints: ((.checkpoints // {}) + {
                main: (.checkpoints.main // .checkpoint // "")
            }),
            recipe: (.recipe // "llamacpp"),
            labels: (.labels // []),
            source: (.source // .registry_source),
            registry_source: (.registry_source // .source),
            recipe_options: (.recipe_options // {}),
            components: (.components // []),
            image_defaults: .image_defaults,
            audio_defaults: .audio_defaults,
            routing: .routing,
            system_prompt: .system_prompt,
            version: .version,
            auto_update: .auto_update,
            size: .size
        }
        | if $draft != "" then .checkpoints.draft = $draft else . end
        | with_entries(select(.value != null))' 2>/dev/null
end

function __pull_refresh_registered --argument-names model_name
    if command -q lemonade; or command -q lemonade-server
        __pull_cli_exec pull $model_name
        return $status
    end

    set -l body (jq -nc --arg model "$model_name" \
        '{model_name: $model, stream: false, do_not_upgrade: false}')
    set -l payload (__pull_api POST /api/v1/pull "$body" 600)
    set -l result $status
    if test $result -ne 0
        echo "Error: "(__pull_api_error "$payload") >&2
        return 1
    end
    if not printf '%s\n' "$payload" | jq -e '.status == "success"' >/dev/null 2>&1
        echo "Error: the server did not confirm the repaired model pull." >&2
        return 1
    end
end

function __pull_repair_mtp --argument-names requested_name assume_yes
    # Lemonade emits the public name of a regular registered model without the
    # internal `user.` prefix. Resolve a bare name back to its user registration;
    # never treat a built-in or extra model as a replaceable definition.
    set -l model_name $requested_name
    if not string match -q 'user.*' -- "$model_name"
        if string match -q 'builtin.*' -- "$model_name"; or string match -q 'extra.*' -- "$model_name"
            echo "Error: --repair-mtp only modifies custom user models." >&2
            return 1
        end
        set model_name "user.$model_name"
    end

    set -l encoded (string escape --style=url -- "$model_name")
    set -l model_json (__pull_api GET "/api/v1/models/$encoded" '' 60)
    set -l model_status $status
    if test $model_status -ne 0
        echo "Error: '$requested_name' is not an existing custom model: "(__pull_api_error "$model_json") >&2
        return 1
    end

    set -l recipe (printf '%s\n' "$model_json" | jq -r '.recipe // empty' 2>/dev/null)
    if test "$recipe" != llamacpp
        echo "Error: --repair-mtp currently supports only llamacpp/GGUF models." >&2
        return 1
    end

    set -l main (printf '%s\n' "$model_json" | jq -r '.checkpoints.main // .checkpoint // empty' 2>/dev/null)
    set -l existing_draft (printf '%s\n' "$model_json" | jq -r '.checkpoints.draft // empty' 2>/dev/null)
    set -l draft $existing_draft
    set -l checkpoint
    set -l variant

    if test -n "$draft"
        echo "The model already has a draft checkpoint registered; refreshing it."
    else
        if not string match -qr '^[^/]+/[^/:]+:.+$' -- "$main"
            echo "Error: '$model_name' does not have a registry GGUF checkpoint with a variant." >&2
            return 1
        end

        set checkpoint (string replace -r ':[^:]+$' '' -- "$main")
        set variant (string replace -r '^.*:' '' -- "$main")
        set -l source (printf '%s\n' "$model_json" | jq -r '.registry_source // .source // "huggingface"' 2>/dev/null)
        set source (string lower -- "$source")
        switch $source
            case hf huggingface
                set source huggingface
            case ms modelscope
                set source modelscope
            case '*'
                echo "Error: unsupported registry source '$source'." >&2
                return 1
        end

        set -l encoded_checkpoint (string escape --style=url -- "$checkpoint")
        set -l variants (__pull_api GET "/api/v1/pull/variants?checkpoint=$encoded_checkpoint&source=$source" '' 180)
        if test $status -ne 0
            echo "Error: could not inspect '$checkpoint': "(__pull_api_error "$variants") >&2
            return 1
        end

        set -l variant_name (__pull_variant_name "$variants" "$variant")
        if test -z "$variant_name"
            echo "Error: the registered variant '$variant' is not advertised by '$checkpoint'." >&2
            return 1
        end

        set draft (printf '%s\n' "$variants" | jq -r --arg variant "$variant_name" '
            [.variants[]?
             | select((.name | ascii_downcase) == ($variant | ascii_downcase))
             | .draft_file // empty][0] // empty' 2>/dev/null)
        if test -z "$draft"
            set -l legacy_drafts (printf '%s\n' "$variants" | jq -r '.draft_files[]?' 2>/dev/null)
            if test (count $legacy_drafts) -eq 1
                set draft $legacy_drafts[1]
                if not string match -q '*/*' -- "$draft"; and test "$source" = huggingface
                    set draft (__pull_resolve_hf_companion "$checkpoint" "$draft")
                    if test -z "$draft"
                        echo "Error: could not resolve the repository path for the advertised MTP draft." >&2
                        return 1
                    end
                end
            else if test (count $legacy_drafts) -gt 1
                echo "Error: multiple MTP drafts are advertised; use an explicit registration instead." >&2
                return 1
            end
        end

        if test -z "$draft"
            echo "Error: no MTP/draft companion is advertised for '$variant_name'." >&2
            return 1
        end
        set draft "$checkpoint:$draft"
    end

    set -l original_registration (__pull_registration_payload "$model_json" "$model_name" '')
    set -l repaired_registration (__pull_registration_payload "$model_json" "$model_name" "$draft")
    if test -z "$original_registration"; or test -z "$repaired_registration"
        echo "Error: could not construct a safe registration update." >&2
        return 1
    end

    echo ""
    echo "Repairing $requested_name"
    if test "$requested_name" != "$model_name"
        echo "  registration: $model_name"
    end
    echo "  draft:   $draft"
    echo "The existing registration will be backed up in memory and restored if the pull fails."

    if test "$assume_yes" != true
        if not isatty stdin
            echo "Error: refusing a non-interactive repair without --yes." >&2
            return 1
        end
        read -l -P "Add and download this MTP draft? [y/N] " answer
        if not string match -qir '^y(es)?$' -- "$answer"
            echo "Kept."
            return 0
        end
    end

    set -l registered (__pull_api POST /api/v1/models/register "$repaired_registration" 60)
    if test $status -ne 0; or not printf '%s\n' "$registered" | jq -e '.status == "success"' >/dev/null 2>&1
        echo "Error: could not update the model registration: "(__pull_api_error "$registered") >&2
        return 1
    end

    __pull_refresh_registered "$model_name"
    set -l pull_status $status
    if test $pull_status -eq 0
        echo "MTP draft installed for $model_name."
        return 0
    end

    echo "The repaired pull failed; restoring the previous registration..." >&2
    set -l restored (__pull_api POST /api/v1/models/register "$original_registration" 60)
    if test $status -ne 0; or not printf '%s\n' "$restored" | jq -e '.status == "success"' >/dev/null 2>&1
        echo "Error: restoration also failed. Preserve this registration payload before retrying:" >&2
        echo "$original_registration" >&2
    else
        echo "Previous registration restored." >&2
    end
    return $pull_status
end

function pull --description 'Pull Lemonade models with automatic MTP and companion checkpoints'
    argparse -n pull \
        'q/quant=' \
        'n/name=' \
        'draft=' \
        no-draft \
        'mmproj=' \
        no-mmproj \
        'source=' \
        'alias=' \
        r/repair-mtp \
        y/yes \
        h/help \
        -- $argv
    or return

    if set -q _flag_help
        __pull_usage
        return 0
    end

    if test (count $argv) -ne 1
        __pull_usage
        return 1
    end

    set -l model_arg $argv[1]
    if set -q _flag_repair_mtp
        if set -q _flag_quant; or set -q _flag_name; or set -q _flag_draft; or set -q _flag_no_draft; or set -q _flag_mmproj; or set -q _flag_no_mmproj; or set -q _flag_source; or set -q _flag_alias
            echo "Error: --repair-mtp is used by itself with an existing custom model." >&2
            return 1
        end
        for tool in curl jq
            if not command -q $tool
                echo "Error: $tool is required but not installed." >&2
                return 1
            end
        end
        set -l assume_yes false
        set -q _flag_yes; and set assume_yes true
        __pull_repair_mtp "$model_arg" "$assume_yes"
        return $status
    end

    if set -q _flag_draft; and set -q _flag_no_draft
        echo "Error: --draft and --no-draft cannot be used together." >&2
        return 1
    end
    if set -q _flag_mmproj; and set -q _flag_no_mmproj
        echo "Error: --mmproj and --no-mmproj cannot be used together." >&2
        return 1
    end

    set -l source
    if set -q _flag_source
        set source (string lower -- $_flag_source[-1])
        switch $source
            case hf huggingface
                set source huggingface
            case ms modelscope
                set source modelscope
            case '*'
                echo "Error: --source must be huggingface or modelscope." >&2
                return 1
        end
    end

    set -l checkpoint (__pull_normalize_hf_url "$model_arg")

    if string match -q '*://*' -- "$checkpoint"
        if set -q _flag_quant; or set -q _flag_name; or set -q _flag_draft; or set -q _flag_no_draft; or set -q _flag_mmproj; or set -q _flag_no_mmproj
            echo "Error: enhanced options require an owner/repo checkpoint or Hugging Face URL." >&2
            return 1
        end
        __pull_passthrough "$model_arg" "$source" "$_flag_alias"
        return $status
    end

    set -l checkpoint_variant
    if string match -qr '^[^:]+/[^:]+:.+$' -- "$checkpoint"
        set checkpoint_variant (string replace -r '^.*:' '' -- "$checkpoint")
        set checkpoint (string replace -r ':[^:]+$' '' -- "$checkpoint")
    end

    if not string match -q '*/*' -- "$checkpoint"
        if set -q _flag_quant; or set -q _flag_name; or set -q _flag_draft; or set -q _flag_no_draft; or set -q _flag_mmproj; or set -q _flag_no_mmproj
            echo "Error: --quant, --name, --draft, and --mmproj apply only to registry checkpoints." >&2
            return 1
        end
        __pull_passthrough "$model_arg" "$source" "$_flag_alias"
        return $status
    end

    if set -q _flag_quant
        if test -n "$checkpoint_variant"; and test (string lower -- "$checkpoint_variant") != (string lower -- "$_flag_quant[-1]")
            echo "Error: the :$checkpoint_variant suffix conflicts with --quant $_flag_quant[-1]." >&2
            return 1
        end
        set checkpoint_variant $_flag_quant[-1]
    end

    for tool in curl jq
        if not command -q $tool
            echo "Error: $tool is required but not installed." >&2
            return 1
        end
    end

    set -l encoded (string escape --style=url -- "$checkpoint")
    set -l path "/api/v1/pull/variants?checkpoint=$encoded"
    if test -n "$source"
        set path "$path&source="(string escape --style=url -- "$source")
    end

    echo "Inspecting $checkpoint..."
    set -l variants (__pull_api GET "$path" "" 180)
    set -l api_status $status
    if test $api_status -ne 0
        echo "Error: could not inspect $checkpoint: "(__pull_api_error "$variants") >&2
        return 1
    end

    set -l repo_kind (printf '%s\n' "$variants" | jq -r '.repo_kind // "gguf"')
    if test "$repo_kind" != gguf
        if set -q _flag_quant; or set -q _flag_name; or set -q _flag_draft; or set -q _flag_no_draft; or set -q _flag_mmproj; or set -q _flag_no_mmproj
            echo "Error: enhanced GGUF options do not apply to repository type '$repo_kind'." >&2
            return 1
        end
        set source (printf '%s\n' "$variants" | jq -r '.source // empty')
        __pull_passthrough "$model_arg" "$source" "$_flag_alias"
        return $status
    end

    set source (printf '%s\n' "$variants" | jq -r '.source // "huggingface"')

    set -l variant_name
    if test -n "$checkpoint_variant"
        set variant_name (__pull_variant_name "$variants" "$checkpoint_variant")
        if test -z "$variant_name"
            echo "Error: '$checkpoint_variant' is not a variant reported for $checkpoint." >&2
            return 1
        end
    else if set -q _flag_yes
        set variant_name (printf '%s\n' "$variants" | jq -r '.variants[0].name // empty')
    else
        if not isatty stdin
            echo "Error: choose a variant with --quant, use owner/repo:variant, or pass --yes." >&2
            return 1
        end
        set variant_name (__pull_prompt_variant "$variants")
        or return 1
    end

    if test -z "$variant_name"
        echo "Error: no GGUF variants were reported for $checkpoint." >&2
        return 1
    end

    set -l suggested_name (printf '%s\n' "$variants" | jq -r '.suggested_name // empty')
    test -n "$suggested_name"; or set suggested_name (string split -r -m 1 / -- "$checkpoint")[-1]
    set -l model_name "user.$suggested_name-$variant_name"

    if set -q _flag_name
        set model_name $_flag_name[-1]
    else if not set -q _flag_yes; and isatty stdin
        read -l -P "Model name [$model_name]: " answer
        or return 1
        test -n "$answer"; and set model_name $answer
    end

    if not string match -q 'user.*' -- "$model_name"
        set model_name "user.$model_name"
    end

    set -l draft
    if set -q _flag_draft
        set draft $_flag_draft[-1]
    else if not set -q _flag_no_draft
        set draft (printf '%s\n' "$variants" | jq -r --arg variant "$variant_name" '
            [.variants[]?
             | select((.name | ascii_downcase) == ($variant | ascii_downcase))
             | .draft_file // empty][0] // empty' 2>/dev/null)

        if test -z "$draft"
            set -l legacy_drafts (printf '%s\n' "$variants" | jq -r '.draft_files[]?' 2>/dev/null)
            if test (count $legacy_drafts) -eq 1
                set draft $legacy_drafts[1]
                if not string match -q '*/*' -- "$draft"; and test "$source" = huggingface
                    set -l resolved (__pull_resolve_hf_companion "$checkpoint" "$draft")
                    if test -n "$resolved"
                        set draft $resolved
                    else
                        echo "Error: the server advertised draft '$draft' but did not preserve its" >&2
                        echo "       repository path. Re-run with --draft PATH or --no-draft." >&2
                        return 1
                    end
                end
            else if test (count $legacy_drafts) -gt 1
                echo "Error: multiple draft companions were advertised; select one with --draft PATH" >&2
                printf '  - %s\n' $legacy_drafts >&2
                return 1
            end
        end
    end

    set -l mmproj
    if set -q _flag_mmproj
        set mmproj $_flag_mmproj[-1]
    else if not set -q _flag_no_mmproj
        set mmproj (printf '%s\n' "$variants" | jq -r '.mmproj_files[0] // empty')
        if test -n "$mmproj"; and not string match -q '*/*' -- "$mmproj"; and test "$source" = huggingface
            set -l resolved (__pull_resolve_hf_companion "$checkpoint" "$mmproj")
            if test -n "$resolved"
                set mmproj $resolved
            else
                echo "Error: the server advertised projector '$mmproj' but did not preserve its" >&2
                echo "       repository path. Re-run with --mmproj PATH or --no-mmproj." >&2
                return 1
            end
        end
    end

    set -l labels (printf '%s\n' "$variants" | jq -r '.suggested_labels[]?' 2>/dev/null)
    if test -n "$draft"
        set -l draft_name (string lower -- (path basename "$draft"))
        if string match -q 'mtp-*' -- "$draft_name"
            contains -- mtp $labels; or set -a labels mtp
        else if string match -q 'dflash-*' -- "$draft_name"; or test "$draft_name" = dflash.gguf
            contains -- dflash $labels; or set -a labels dflash
        end
    else
        set labels (string match -v -r '^(mtp|dflash)$' -- $labels)
    end
    if test -n "$mmproj"
        contains -- vision $labels; or set -a labels vision
    else
        set labels (string match -v -e vision -- $labels)
    end

    echo ""
    echo "Pulling $model_name"
    echo "  main:    $checkpoint:$variant_name"
    if test -n "$draft"
        echo "  draft:   $checkpoint:$draft"
    end
    if test -n "$mmproj"
        echo "  mmproj:  $checkpoint:$mmproj"
    end
    if test (count $labels) -gt 0
        echo "  labels:  "(string join ', ' $labels)
    end

    set -l cli_args pull $model_name \
        --checkpoint main "$checkpoint:$variant_name" \
        --recipe (printf '%s\n' "$variants" | jq -r '.recipe // "llamacpp"') \
        --source $source

    if test -n "$draft"
        set -a cli_args --checkpoint draft "$checkpoint:$draft"
    end
    if test -n "$mmproj"
        set -a cli_args --checkpoint mmproj "$checkpoint:$mmproj"
    end
    for label in $labels
        set -a cli_args --label $label
    end
    __pull_cli_exec $cli_args
    set -l pull_status $status
    if test $pull_status -eq 0; and set -q _flag_alias
        __pull_cli_exec alias add $_flag_alias[-1] $model_name
        return $status
    end
    return $pull_status
end
