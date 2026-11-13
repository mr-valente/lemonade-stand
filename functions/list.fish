# 'lemonade list' prints an aliased model once under its own name and again
# under each alias, so aliases look like extra models. This lists each
# downloaded model once, with the aliases that point at it.

function __list_usage
    echo 'Usage: list [pattern...]'
    echo ''
    echo 'Show the models downloaded on this server, one row per model, with the'
    echo 'aliases that point at it. A ● marks a model that is loaded.'
    echo ''
    echo 'Arguments:'
    echo '  pattern     Show models whose name or alias contains this text, ignoring'
    echo "              case. With a *, the whole name must match: 'gemma*'."
    echo ''
    echo 'Options:'
    echo '  -h, --help  Show this help'
    echo ''
    echo "To browse models that can be downloaded, use 'lemonade list'."
end

function __list_port
    if set -q LEMONADE_PORT; and test -n "$LEMONADE_PORT"
        echo $LEMONADE_PORT
    else
        echo 13305
    end
end

function __list_curl
    set -l headers
    if set -q LEMONADE_ADMIN_API_KEY; and test -n "$LEMONADE_ADMIN_API_KEY"
        set headers -H "Authorization: Bearer $LEMONADE_ADMIN_API_KEY"
    else if set -q LEMONADE_API_KEY; and test -n "$LEMONADE_API_KEY"
        set headers -H "Authorization: Bearer $LEMONADE_API_KEY"
    end
    curl -sSf -m 30 $headers $argv 2>/dev/null
end

function __list_api --argument-names path
    __list_curl "http://localhost:"(__list_port)"$path"
end

function __list_files
    # One curl call for every model. Each response is a JSON object, and jq
    # reads them back to back; a model whose request fails is simply absent.
    set -l urls
    for id in $argv
        set -a urls "http://localhost:"(__list_port)"/api/v1/models/"(string escape --style=url -- $id)"/files?include_paths=true"
    end
    test (count $urls) -gt 0; and __list_curl $urls
    return 0
end

function __list_records --argument-names pattern
    # Reads the models, aliases and health responses from stdin, in that
    # order, and writes one tab-separated record per line:
    #   model     loaded  id  aliases  type  recipe  context  size
    #   dangling  alias   target
    jq -nr --arg re "$pattern" '
        # The alias endpoint lists objects; aliases.json maps alias to target.
        def pairs:
            if (.aliases? | type) == "array" then
                [.aliases[] | objects
                    | select((.alias | type) == "string" and (.target | type) == "string")
                    | {alias, target}]
            elif type == "object" then
                [to_entries[] | select(.value | type == "string") | {alias: .key, target: .value}]
            else [] end;
        # The models endpoint drops the user. prefix that alias targets keep.
        def bare: ltrimstr("user.");
        def tagged($name): any(.labels[]?; . == $name);
        def kind:
            if tagged("embeddings") or tagged("embedding") then "embed"
            elif tagged("reranking") then "rerank"
            elif tagged("transcription") then "stt"
            elif tagged("tts") then "tts"
            elif tagged("upscaling") then "upscale"
            elif tagged("image") then "image"
            elif tagged("classification") or tagged("decision") then "classify"
            elif tagged("chat") or tagged("reasoning") or tagged("vision") or tagged("llm") then "chat"
            else "" end;
        def matches: $re == "" or test($re; "i");

        input as $models | input as $aliases | input as $health
        | ($aliases | pairs) as $pairs
        | ($pairs | map({key: .alias, value: .target}) | from_entries) as $map
        # An alias may name another alias. Follow the chain; the bound also
        # ends a cycle.
        | [$pairs[] | {alias, target: (reduce range(0; 16) as $i (.target; $map[.] // .))}] as $links
        | [$health.all_models_loaded[]?.model_name | strings] as $loaded
        | [$models.data[]? | objects
            | select((.id | type) == "string" and .downloaded != false)
            | select(.id as $id | $map | has($id) | not)] as $local
        | ($local | map(.id)) as $ids
        | ($local | sort_by(.id | ascii_downcase)[]
            | .id as $id
            | [$links[] | select(.target == $id or (.target | bare) == $id) | .alias] as $names
            | select(any(([$id] + $names)[]; matches))
            | ["model",
               (if any(([$id, "user." + $id] + $names)[]; IN($loaded[])) then 1 else 0 end),
               $id,
               ($names | join(", ")),
               kind,
               (.recipe // ""),
               # The ctx_size a loaded model runs with, else its configured
               # one, else the largest it supports.
               (.context_length // .recipe_options.ctx_size? // ""),
               (.size // "")]
            | @tsv),
          ($links[]
            | select(.target as $t | any($t, ($t | bare); IN($ids[])) | not)
            | select(any(.alias, .target; matches))
            | ["dangling", .alias, .target]
            | @tsv)' 2>/dev/null
end

function __list_shared_bytes
    # Two models can use the same file, such as a model and its MTP variant.
    # Each model's size counts it, so report the bytes counted more than once.
    jq -n '
        [inputs | objects
            | [.files[]? | objects
                | select((.path | type) == "string" and .path != "" and .exists != false)
                | {path, bytes: (.size_bytes // 0)}]
            | unique_by(.path)[]]
        | group_by(.path)
        | map((length - 1) * .[0].bytes)
        | add // 0' 2>/dev/null
    or echo 0
end

function __list_context --argument-names tokens
    if not string match -qr '^[1-9][0-9]*$' -- "$tokens"
        echo —
    else if test $tokens -ge 1048576
        echo (math -s1 $tokens / 1048576)M
    else if test $tokens -ge 1024
        echo (math "round($tokens / 1024)")K
    else
        echo $tokens
    end
end

function __list_size --argument-names gib
    if not string match -qr '^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$' -- "$gib"
        echo —
        return
    end
    set -l mib (math "round($gib * 1024)")
    if test $mib -lt 1000
        echo "$mib MB"
    else
        printf '%.1f GB\n' $gib
    end
end

function __list_width
    set -l widest 0
    for length in (string length --visible -- $argv)
        test $length -gt $widest; and set widest $length
    end
    echo $widest
end

function __list_span
    # A two-column gutter, the columns, and two spaces between each pair.
    math (string join ' + ' -- $argv) + 2 \* (count $argv)
end

function __list_fit --argument-names text width
    # Shorten from the middle: the family is at the start of a model name and
    # the quant at the end, and both are worth keeping.
    if test (string length --visible -- "$text") -le $width
        echo $text
        return
    end
    set -l head (math "ceil(($width - 1) / 2)")
    set -l tail (math "$width - 1 - $head")
    echo (string sub -l $head -- "$text")…(string sub -s -$tail -- "$text")
end

function __list_render --argument-names width color shared
    # width 0 means no limit, which is what a pipe gets.
    set -l records $argv[4..-1]

    set -l loaded
    set -l names
    set -l aliases
    set -l kinds
    set -l recipes
    set -l contexts
    set -l sizes
    set -l dangling
    set -l alias_count 0
    set -l total 0
    for record in $records
        set -l fields (string split \t -- $record)
        switch $fields[1]
            case model
                set -a loaded "$fields[2]"
                set -a names "$fields[3]"
                set -a aliases "$fields[4]"
                if test -n "$fields[4]"
                    set alias_count (math $alias_count + (count (string split ', ' -- $fields[4])))
                end
                set -l kind "$fields[5]"
                test -n "$kind"; or set kind —
                set -a kinds $kind
                set -l recipe "$fields[6]"
                test -n "$recipe"; or set recipe —
                set -a recipes $recipe
                set -a contexts (__list_context "$fields[7]")
                set -a sizes (__list_size "$fields[8]")
                if string match -qr '^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$' -- "$fields[8]"
                    set total (math "$total + $fields[8]")
                end
            case dangling
                set -a dangling "$fields[2]"\t"$fields[3]"
        end
    end

    # Empty strings, not empty lists: an empty list would erase every word it
    # is joined to, such as $dim$cell.
    set -l bold ''
    set -l dim ''
    set -l yellow ''
    set -l green ''
    set -l reset ''
    if test "$color" = true
        set bold (set_color --bold)
        set dim (set_color brblack)
        set yellow (set_color yellow)
        set green (set_color green)
        set reset (set_color normal)
    end

    if test (count $names) -gt 0
        set -l headers MODEL ALIAS TYPE RECIPE CONTEXT SIZE
        set -l w (__list_width MODEL $names) (__list_width ALIAS $aliases) \
            (__list_width TYPE $kinds) (__list_width RECIPE $recipes) \
            (__list_width CONTEXT $contexts) (__list_width SIZE $sizes)
        set -l visible 1 2 3 4 5 6
        if test "$width" -gt 0
            # Too wide for the terminal: drop the least useful columns, then
            # shorten names rather than let rows wrap.
            for column in 5 3 4
                test (__list_span $w[$visible]) -le $width; and break
                set visible (string match -v -- $column $visible)
            end
            # Names give way to 20 columns, aliases to 10, then names to 8.
            for limit in 1:20 2:10 1:8
                set -l over (math (__list_span $w[$visible]) - $width)
                test $over -gt 0; or break
                set -l column (string split : -- $limit)
                set w[$column[1]] (math "max(min($w[$column[1]], $column[2]), $w[$column[1]] - $over)")
            end
        end

        set -l line
        for column in $visible
            if contains -- $column 5 6
                set -a line (string pad -w $w[$column] -- $headers[$column])
            else
                set -a line (string pad -r -w $w[$column] -- $headers[$column])
            end
        end
        set -l rule $dim(string repeat -n (math (__list_span $w[$visible]) - 2) ─)$reset
        echo "  $bold"(string join '  ' -- $line)"$reset"
        echo "  $rule"

        for i in (seq (count $names))
            set line
            for column in $visible
                switch $column
                    case 1
                        set -a line (string pad -r -w $w[1] -- (__list_fit $names[$i] $w[1]))
                    case 2
                        set -a line $yellow(string pad -r -w $w[2] -- (string shorten -m $w[2] -- "$aliases[$i]"))$reset
                    case 3
                        set -l cell (string pad -r -w $w[3] -- $kinds[$i])
                        test "$kinds[$i]" = —; and set cell $dim$cell$reset
                        set -a line $cell
                    case 4
                        set -l cell (string pad -r -w $w[4] -- $recipes[$i])
                        test "$recipes[$i]" = —; and set cell $dim$cell$reset
                        set -a line $cell
                    case 5
                        set -l cell (string pad -w $w[5] -- $contexts[$i])
                        test "$contexts[$i]" = —; and set cell $dim$cell$reset
                        set -a line $cell
                    case 6
                        set -l cell (string pad -w $w[6] -- $sizes[$i])
                        test "$sizes[$i]" = —; and set cell $dim$cell$reset
                        set -a line $cell
                end
            end
            set -l gutter '  '
            test "$loaded[$i]" = 1; and set gutter "$green●$reset "
            echo $gutter(string join '  ' -- $line)
        end
        echo "  $rule"

        set -l summary (count $names)' model'
        test (count $names) -eq 1; or set summary[1] $summary[1]s
        if test $alias_count -eq 1
            set -a summary '1 alias'
        else
            set -a summary "$alias_count aliases"
        end
        set -l loaded_count (count (string match 1 -- $loaded))
        test $loaded_count -gt 0; and set -a summary "$green●$dim $loaded_count loaded"
        set total (math "max(0, $total - $shared / 1073741824)")
        test (math "round($total * 1024)") -gt 0; and set -a summary (__list_size $total)
        # Wrap between items rather than let the terminal break one.
        set -l lines $summary[1]
        for item in $summary[2..-1]
            set -l joined "$lines[-1] · $item"
            if test "$width" -gt 0; and test (math 2 + (string length --visible -- $joined)) -gt $width
                set -a lines $item
            else
                set lines[-1] $joined
            end
        end
        for summary_line in $lines
            echo "  $dim$summary_line$reset"
        end
    end

    if test (count $dangling) -gt 0
        test (count $names) -gt 0; and echo
        echo '  Aliases with no downloaded model:'
        for entry in $dangling
            set -l pair (string split \t -- $entry)
            set -l target $pair[2]
            if test "$width" -gt 0
                set -l room (math "max(10, $width - 7 - "(string length --visible -- $pair[1])")")
                set target (__list_fit $target $room)
            end
            echo "    $yellow$pair[1]$reset $dim→$reset $target"
        end
    end
end

function list --description 'List downloaded models and the aliases that point at them'
    argparse -n list h/help -- $argv
    or return 2
    if set -q _flag_help
        __list_usage
        return 0
    end
    for tool in curl jq
        if not command -q $tool
            echo "list: $tool is required" >&2
            return 1
        end
    end

    # Plain text matches anywhere in a name; a * anchors the pattern.
    set -l expressions
    for pattern in $argv
        test -n "$pattern"; or continue
        set -l expression (string escape --style=regex -- $pattern | string replace -a '\*' '.*')
        string match -qr '\*' -- $pattern; and set expression "^$expression\$"
        set -a expressions "(?:$expression)"
    end
    set -l filter (string join '|' -- $expressions)

    set -l models (__list_api /api/v1/models)
    if test $status -ne 0; or not printf '%s\n' $models | jq -e '(.data | type) == "array"' >/dev/null 2>&1
        echo "list: could not read the model list from Lemonade on port "(__list_port) >&2
        return 1
    end
    set -l aliases (__list_api /internal/aliases)
    if not printf '%s\n' $aliases | jq -e '(.aliases | type) == "array"' >/dev/null 2>&1
        # Without the endpoint, read the file the server keeps its aliases in.
        set aliases (cat "$HOME/.cache/lemonade/aliases.json" 2>/dev/null)
        printf '%s\n' $aliases | jq -e 'type == "object"' >/dev/null 2>&1
        or set aliases '{}'
    end
    set -l health (__list_api /api/v1/health)
    printf '%s\n' $health | jq -e 'type == "object"' >/dev/null 2>&1
    or set health '{}'

    set -l records (begin
            printf '%s\n' $models
            printf '%s\n' $aliases
            printf '%s\n' $health
        end | __list_records "$filter")

    set -l ids
    for record in $records
        set -l fields (string split \t -- $record)
        test "$fields[1]" = model; and set -a ids $fields[3]
    end
    if test (count $records) -eq 0
        if test -n "$filter"
            echo "No downloaded model or alias matches: $argv" >&2
            return 1
        end
        echo "No models are downloaded. To browse the registry, use 'lemonade list'."
        return 0
    end

    set -l shared 0
    if test (count $ids) -gt 1
        set shared (__list_files $ids | __list_shared_bytes)
    end

    set -l width 0
    set -l color false
    if isatty stdout
        set width $COLUMNS
        string match -qr '^[1-9][0-9]*$' -- "$width"; or set width 80
        set -q NO_COLOR; and test -n "$NO_COLOR"; or set color true
    end
    __list_render $width $color $shared $records
end
