#!/usr/bin/env fish
# An interactive fish config can define its own `path` helper that shadows the
# builtin. Drop it so the tests exercise the real code.
functions -e path

set -l repo (builtin path resolve (builtin path dirname (status filename))/..)
source "$repo/functions/list.fish"

set -g failed 0
function check --argument-names description
    if not $argv[2..-1]
        echo "FAIL: $description" >&2
        set -g failed 1
    end
end
function refute --argument-names description
    if $argv[2..-1]
        echo "FAIL: $description" >&2
        set -g failed 1
    end
end

set -g sandbox (mktemp -d)
set -gx HOME "$sandbox/home"
mkdir -p "$HOME/.cache/lemonade"

# The server lists an aliased model again under each alias name, and drops the
# user. prefix that alias targets keep. pomelo names grapefruit, which names a
# model; ghost names a model that is not downloaded.
set -g fixture_models '{"data":[
  {"id":"Big-Model-GGUF","recipe":"llamacpp","labels":["chat","vision"],"size":3.0,"context_length":262144,"recipe_options":{},"downloaded":true},
  {"id":"Big-Model-MTP-GGUF","recipe":"llamacpp","labels":["chat","mtp"],"size":3.5,"context_length":32768,"recipe_options":{"ctx_size":32768},"downloaded":true},
  {"id":"embed-small","recipe":"llamacpp","labels":["custom","embeddings"],"size":0.5,"context_length":2048,"downloaded":true},
  {"id":"Voice-TTS","recipe":"kokoro","labels":["tts"],"size":null,"downloaded":true},
  {"id":"Not-Downloaded","recipe":"llamacpp","labels":["chat"],"size":4,"downloaded":false},
  {"id":"grapefruit","recipe":"llamacpp","labels":["chat","mtp"],"size":3.5,"downloaded":true},
  {"id":"pomelo","recipe":"llamacpp","labels":["chat","mtp"],"size":3.5,"downloaded":true}
]}'
set -g fixture_aliases '{"aliases":[
  {"alias":"grapefruit","target":"Big-Model-MTP-GGUF"},
  {"alias":"kumquat","target":"user.embed-small"},
  {"alias":"pomelo","target":"grapefruit"},
  {"alias":"ghost","target":"user.Gone-Model"}
]}'
set -g fixture_health '{"all_models_loaded":[{"model_name":"kumquat"},{"model_name":"Big-Model-GGUF"}]}'
set -g aliases_up true
set -g models_up true

function __list_api --argument-names path
    switch $path
        case /api/v1/models
            test $models_up = true; or return 7
            printf '%s\n' $fixture_models
        case /internal/aliases
            test $aliases_up = true; or return 22
            printf '%s\n' $fixture_aliases
        case /api/v1/health
            printf '%s\n' $fixture_health
    end
end

# Both Big-Model variants use the same 2 GiB main file and 1 GiB projector.
function __list_files
    for id in $argv
        switch $id
            case Big-Model-GGUF
                echo '{"files":[{"path":"/hf/big/main.gguf","size_bytes":2147483648},{"path":"/hf/big/mmproj.gguf","size_bytes":1073741824}]}'
            case Big-Model-MTP-GGUF
                echo '{"files":[{"path":"/hf/big/main.gguf","size_bytes":2147483648},{"path":"/hf/big/mmproj.gguf","size_bytes":1073741824},{"path":"/hf/big/mtp.gguf","size_bytes":536870912}]}'
            case embed-small
                echo '{"files":[{"path":"/hf/embed/model.gguf","size_bytes":536870912},{"path":"/hf/missing.bin","size_bytes":9,"exists":false}]}'
        end
    end
end

list >"$sandbox/out" 2>"$sandbox/err"
set -l code $status
set -l out (cat "$sandbox/out")
set -l text (string join \n -- $out)
check 'list succeeds' test $code -eq 0
check 'list writes nothing to stderr' test ! -s "$sandbox/err"
refute 'a pipe gets no color' string match -q \e'*' -- $text
refute 'aliases are not listed as models' string match -qr '^..(grapefruit|pomelo|kumquat|ghost) ' -- $out
refute 'models that are not downloaded are left out' string match -q '*Not-Downloaded*' -- $text
check 'an alias chain and a direct alias land on the same model' \
    string match -qr '^  Big-Model-MTP-GGUF +grapefruit, pomelo +chat +llamacpp +32K +3\.5 GB$' -- $out
check 'a user. target matches the bare model id, and a model loaded by alias is marked' \
    string match -qr '^● embed-small +kumquat +embed +llamacpp +2K +512 MB$' -- $out
check 'a model loaded by id is marked, and an unaliased model has an empty alias cell' \
    string match -qr '^● Big-Model-GGUF +chat +llamacpp +256K +3\.0 GB$' -- $out
check 'missing context and size show a dash' \
    string match -qr '^  Voice-TTS +tts +kokoro +— +—$' -- $out
check 'rows are sorted by name, ignoring case' \
    test (string join ' ' -- (string match -rg '^. (\S+)' -- $out[3..6])) = 'Big-Model-GGUF Big-Model-MTP-GGUF embed-small Voice-TTS'
check 'the summary counts models, aliases and loaded models, and counts shared files once' \
    string match -q '  4 models · 3 aliases · ● 2 loaded · 4.0 GB' -- $out
check 'an alias whose model is not downloaded is reported' \
    string match -qr '^    ghost → user\.Gone-Model$' -- $out
refute 'no line ends in spaces' string match -qr ' $' -- $out

# Filters match model and alias names, ignore case, and accept several.
list KUMQUAT >"$sandbox/out" 2>/dev/null
set out (cat "$sandbox/out")
check 'a filter matches an alias' string match -qr '^● embed-small ' -- $out
refute 'a filter leaves out other models' string match -q '*Big-Model*' -- $out
check 'a filtered summary covers the shown rows' string match -q '  1 model · 1 alias · ● 1 loaded · 512 MB' -- $out
list 'big*' voice >"$sandbox/out"
set out (cat "$sandbox/out")
check 'a wildcard anchors the pattern, and patterns combine' \
    test (string join ' ' -- (string match -rg '^. (\S+) ' -- $out[3..-3])) = 'Big-Model-GGUF Big-Model-MTP-GGUF Voice-TTS'
list '*gguf' >"$sandbox/out"
check 'a leading wildcard matches the end' string match -q '*2 models*' -- (cat "$sandbox/out")
list ghost >"$sandbox/out"
set out (cat "$sandbox/out")
check 'a filter that only matches a missing alias reports it without a table' \
    test "$out" = '  Aliases with no downloaded model:     ghost → user.Gone-Model'
list no-such-model >/dev/null 2>"$sandbox/err"
set code $status
check 'a filter that matches nothing fails' test $code -eq 1
check 'a filter that matches nothing says so' string match -q '*no-such-model*' -- (cat "$sandbox/err")

# Without the alias endpoint, read the server's aliases.json, which maps names.
set -g aliases_up false
printf '%s\n' '{"grapefruit":"Big-Model-MTP-GGUF","pomelo":"grapefruit","kumquat":"user.embed-small"}' >"$HOME/.cache/lemonade/aliases.json"
list >"$sandbox/out"
set out (cat "$sandbox/out")
check 'aliases.json is read when the endpoint is unavailable' \
    string match -qr '^  Big-Model-MTP-GGUF +grapefruit, pomelo ' -- $out
check 'alias entries are still folded with the file' string match -q '  4 models · 3 aliases*' -- $out
set -g aliases_up true

set -g models_up false
list >/dev/null 2>"$sandbox/err"
set code $status
check 'an unreachable server fails' test $code -eq 1
check 'an unreachable server is reported' string match -q '*could not read the model list*' -- (cat "$sandbox/err")
set -g models_up true

check 'help succeeds' list --help >/dev/null
list --bogus >/dev/null 2>&1
set code $status
check 'an unknown option is a usage error' test $code -eq 2

# A narrow terminal drops columns, then shortens names, and never wraps.
set -l long 'model	0	gemma-4-E2B-it-qat-GGUF-UD-Q4_K_XL	lime, clementine, satsuma	chat	whispercpp	131072	110.6' \
    'model	1	short	lemon	stt	flm		0.062' \
    'dangling	pomelo	user.Qwen3.8-Flash-Next-Halogen-With-A-Very-Long-Name'
for width in 100 80 60 46 40
    set -l lines (__list_render $width true 0 $long | string replace -ra '\e\[[0-9;]*m|\e\(B' '')
    set -l widest (__list_width $lines)
    check "nothing is wider than $width columns" test $widest -le $width
end
set -l lines (__list_render 46 false 0 $long)
check 'a long name is shortened from the middle' \
    string match -qr '^  gemma-4-E2…D-Q4_K_XL  lime' -- $lines
check 'a long alias list is shortened at the end' string match -q '*lime, cleme…*' -- $lines
set lines (__list_render 0 false 0 $long)
check 'width 0 keeps every column and the whole name' \
    string match -qr '^  gemma-4-E2B-it-qat-GGUF-UD-Q4_K_XL +lime, clementine, satsuma +chat +whispercpp +128K +110\.6 GB$' -- $lines
check 'color marks a loaded model in green' \
    string match -q '*'(set_color green)'●*' -- (__list_render 0 true 0 $long)

# Formatting helpers
check 'contexts are shown in K' test (__list_context 131072) = 128K
check 'a context of a million tokens or more is shown in M' test (__list_context 1572864) = 1.5M
check 'a missing context is a dash' test (__list_context '') = —
check 'sizes under 1000 MB are shown in MB' test (__list_size 0.062) = '63 MB'
check 'larger sizes are shown in GB' test (__list_size 110.6) = '110.6 GB'
check 'a missing size is a dash' test (__list_size null) = —
check 'files used by one model are not shared' test (printf '%s\n' '{"files":[{"path":"/a","size_bytes":5}]}' '{"files":[{"path":"/b","size_bytes":7}]}' | __list_shared_bytes) = 0
check 'a file used by three models is counted twice over' test (printf '%s\n' '{"files":[{"path":"/a","size_bytes":5}]}' '{"files":[{"path":"/a","size_bytes":5}]}' '{"files":[{"path":"/a","size_bytes":5}]}' | __list_shared_bytes) = 10
check 'unreadable file lists count nothing' test (printf 'not json\n' | __list_shared_bytes) = 0

rm -rf -- "$sandbox"
test $failed -eq 0; or exit 1
echo 'All list tests passed.'
