#!/usr/bin/env fish
# MTP tests use API fixtures and a temporary Hugging Face cache only.
functions -e path
set -l repo_root (path resolve (path dirname (status filename))/..)
source "$repo_root/functions/pull.fish"
set -g failures 0
function check --argument-names description
    if not $argv[2..-1]
        echo "FAIL: $description" >&2
        set -g failures (math $failures + 1)
    end
end

set -g sandbox (mktemp -d)
set -g cache "$sandbox/models--org--Model"
set -g old_path "$cache/snapshots/rev/MTP/mtp-old-BF16.gguf"
set -g new_path "$cache/snapshots/rev/MTP/mtp-new-Q4_0.gguf"
set -g main_path "$cache/snapshots/rev/main.gguf"
set -g projector_path "$cache/snapshots/rev/mmproj.gguf"
set -g old_checkpoint 'org/Model:MTP/mtp-old-BF16.gguf'
set -g new_checkpoint 'org/Model:MTP/mtp-new-Q4_0.gguf'
set -g variants '{"variants":[{"name":"Q4_K_M","draft_file":"MTP/mtp-new-Q4_0.gguf"}],"draft_files":["mtp-old-BF16.gguf","mtp-new-Q4_0.gguf","mtp-other-Q8_0.gguf"]}'

function reset_fixture
    rm -rf -- "$cache"
    mkdir -p (path dirname "$old_path") "$cache/blobs"
    printf old >"$cache/blobs/old"
    ln -s ../../../blobs/old "$old_path"
    printf main >"$main_path"
    printf projector >"$projector_path"
    set -g model (jq -nc --arg draft "$old_checkpoint" '{id:"user.Model",recipe:"llamacpp",source:"huggingface",checkpoints:{main:"org/Model:Q4_K_M",draft:$draft,mmproj:"org/Model:mmproj.gguf"},labels:["chat","vision","mtp"],recipe_options:{ctx_size:8192},system_prompt:"Keep me",routing:{priority:2}}')
    set -g original (__pull_registration_payload "$model" user.Model '')
    set -g events
    set -g failure_mode ''
    set -g other_model ''
    set -g other_path ''
end

function file_list --argument-names draft_path
    jq -nc --arg draft "$draft_path" --arg main "$main_path" --arg mmproj "$projector_path" \
        '{files:([{role:"main",path:$main}]
            + (if $draft == "" then [] else [{role:"draft",path:$draft}] end)
            + [{role:"mmproj",path:$mmproj}])}'
end

function __pull_api --argument-names method url body timeout
    switch "$method $url"
        case 'GET /api/v1/models/user.Model'
            echo $model
        case 'GET /api/v1/pull/variants?*'
            set -ga events inspect
            echo $variants
        case 'GET /api/v1/models/user.Model/files?include_paths=true'
            if test "$failure_mode" = old_files
                return 1
            end
            set -l draft (printf '%s\n' "$model" | jq -r '.checkpoints.draft // empty')
            if test -z "$draft"
                file_list ''
            else if test "$draft" = "$old_checkpoint"
                file_list "$old_path"
            else
                file_list "$new_path"
            end
        case 'GET /api/v1/models/Other/files?include_paths=true'
            if test "$failure_mode" = other_files
                return 1
            end
            jq -nc --arg path "$other_path" '{files:[{role:"main",path:$path}]}'
        case 'POST /api/v1/unload'
            set -ga events unload
            test "$failure_mode" = unload; and return 1
            if test "$failure_mode" = unload_not_loaded
                echo '{"error":"Model not loaded: user.Model"}'
                return 1
            end
            if test "$failure_mode" = unload_refused
                echo '{"error":"Model is pinned"}'
                return 1
            end
            check 'unload targets only this model' test (printf '%s' "$body" | jq -r '.model_name') = user.Model
            echo '{"status":"success"}'
        case 'POST /api/v1/models/register'
            set -ga events register
            set -g model (printf '%s\n' "$body" | jq -c '.id = "user.Model"')
            echo '{"status":"success"}'
        case 'GET /api/v1/models?show_all=true'
            set -ga events inventory
            test "$failure_mode" = inventory; and return 1
            if test "$failure_mode" = malformed_inventory
                echo '{}'
            else if test "$failure_mode" = empty_inventory
                echo '{"data":[]}'
            else
                jq -nc --argjson model "$model" --argjson other (test -n "$other_model"; and echo "$other_model"; or echo null) \
                    '{data:([$model,$other] | map(select(. != null)))}'
            end
        case '*'
            echo "Unexpected API call: $method $url" >&2
            return 1
    end
end

function __pull_resolve_hf_companion --argument-names checkpoint filename
    echo "MTP/$filename"
end

function __pull_refresh_registered
    set -ga events pull
    check 'old file remains throughout download' test -f "$old_path"
    test "$failure_mode" = pull; and return 1
    printf new >"$new_path"
    return 0
end

reset_fixture
pull --mtp Model --yes >/dev/null
check 'yes alone refreshes the current draft' test $status -eq 0
check 'refresh does not discover, unload, or clean up' test (string join ',' $events) = register,pull
check 'refresh retains the old draft' test -f "$old_path"

reset_fixture
pull --mtp Model --draft mtp-old-BF16.gguf --yes >/dev/null
check 'selecting the same draft by basename succeeds' test $status -eq 0
check 'same draft is resolved without replacement or cleanup' test (string join ',' $events) = register,pull

for invalid in '' ../outside.gguf /absolute.gguf org/Other:model.gguf
    reset_fixture
    pull --mtp Model --draft "$invalid" --yes >"$sandbox/output" 2>"$sandbox/error"
    check 'invalid explicit draft is rejected' test $status -eq 1
    check 'invalid explicit draft leaves registration alone' test (__pull_registration_payload "$model" user.Model '') = "$original"
end

reset_fixture
pull --mtp Model --draft MTP/mtp-new-Q4_0.gguf --yes >"$sandbox/output" 2>"$sandbox/error"
check 'explicit replacement succeeds' test $status -eq 0
check 'replacement unloads and downloads before cleanup' test (string join ',' $events) = unload,register,pull,inventory
check 'old draft link removed' test ! -L "$old_path"
check 'unreferenced old draft blob removed' test ! -e "$cache/blobs/old"
for filename in "$main_path" "$new_path" "$projector_path"
    check 'main, new draft, and projector remain' test -f "$filename"
end
set -l expected (printf '%s\n' "$original" | jq -cS --arg draft "$new_checkpoint" '.checkpoints.draft = $draft')
set -l actual (__pull_registration_payload "$model" user.Model '' | jq -cS .)
check 'only the draft checkpoint changes in the registration' test "$actual" = "$expected"

reset_fixture
set failure_mode pull
pull --mtp user.Model --draft MTP/mtp-new-Q4_0.gguf --yes >"$sandbox/output" 2>"$sandbox/error"
check 'failed download is reported' test $status -eq 1
check 'failed download restores registration before any cleanup' test (string join ',' $events) = unload,register,pull,register
check 'failed download preserves the complete old registration' test (__pull_registration_payload "$model" user.Model '') = "$original"
check 'failed download preserves old weights' test -f "$old_path"

for mode in inventory malformed_inventory empty_inventory other_files
    reset_fixture
    set failure_mode $mode
    if test "$mode" = other_files
        set other_model '{"id":"Other","checkpoints":{"main":"org/Other:Q4"}}'
    end
    pull --mtp Model --draft MTP/mtp-new-Q4_0.gguf --yes >"$sandbox/output" 2>"$sandbox/error"
    check 'incomplete reference checks report cleanup failure' test $status -eq 1
    check 'incomplete reference checks preserve old files' test -f "$old_path"
    check 'cleanup failure keeps successful replacement registered' test (printf '%s' "$model" | jq -r '.checkpoints.draft') = "$new_checkpoint"
end

for mode in old_files unload
    reset_fixture
    set failure_mode $mode
    pull --mtp Model --draft MTP/mtp-new-Q4_0.gguf --yes >"$sandbox/output" 2>"$sandbox/error"
    check 'preflight failure aborts replacement' test $status -eq 1
    check 'preflight failure leaves registration untouched' test (__pull_registration_payload "$model" user.Model '') = "$original"
    check 'preflight failure preserves old files' test -f "$old_path"
    contains pull $events
    check 'preflight failure never pulls' test $status -eq 1
end

# A model the server is not holding is already in the state a replacement
# needs, so a 404 from unload must not abort the replacement.
reset_fixture
set failure_mode unload_not_loaded
pull --mtp Model --draft MTP/mtp-new-Q4_0.gguf --yes >"$sandbox/output" 2>"$sandbox/error"
check 'an unloaded model does not block replacement' test $status -eq 0
check 'an unloaded model still runs the full replacement' test (string join ',' $events) = unload,register,pull,inventory
check 'an unloaded model replacement removes the old draft' test ! -L "$old_path"

reset_fixture
set failure_mode unload_refused
pull --mtp Model --draft MTP/mtp-new-Q4_0.gguf --yes >"$sandbox/output" 2>"$sandbox/error"
check 'a refused unload aborts replacement' test $status -eq 1
check 'a refused unload reports the server message' string match -q '*Model is pinned*' (cat "$sandbox/error")
check 'a refused unload leaves registration untouched' test (__pull_registration_payload "$model" user.Model '') = "$original"
check 'a refused unload preserves old files' test -f "$old_path"

reset_fixture
set other_model (jq -nc --arg draft "$old_checkpoint" '{id:"Other",checkpoints:{draft:$draft}}')
pull --mtp Model --draft MTP/mtp-new-Q4_0.gguf --yes >"$sandbox/output" 2>"$sandbox/error"
check 'shared checkpoint does not fail replacement' test $status -eq 0
check 'shared checkpoint keeps the old draft' test -f "$old_path"

for shared in path blob directory
    reset_fixture
    set other_model '{"id":"Other","checkpoints":{"main":"org/Model:other-selector"}}'
    set other_path "$old_path"
    if test "$shared" = blob
        set other_path "$cache/snapshots/rev/alias.gguf"
        ln -s ../../blobs/old "$other_path"
    else if test "$shared" = directory
        set other_path (path dirname "$old_path")
    end
    pull --mtp Model --draft MTP/mtp-new-Q4_0.gguf --yes >"$sandbox/output" 2>"$sandbox/error"
    check 'shared file does not fail replacement' test $status -eq 0
    check 'shared path, blob, or directory keeps old draft intact' test -f "$old_path"
end

reset_fixture
pull --mtp Model --no-draft --yes >"$sandbox/output" 2>"$sandbox/error"
check 'removal succeeds' test $status -eq 0
check 'removal unloads and re-registers without downloading' test (string join ',' $events) = unload,register,inventory
check 'removal deregisters the draft' test (printf '%s' "$model" | jq -r '.checkpoints.draft // "none"') = none
check 'removal deletes the old draft link' test ! -L "$old_path"
check 'removal deletes the unreferenced blob' test ! -e "$cache/blobs/old"
for filename in "$main_path" "$projector_path"
    check 'removal keeps the main weights and the projector' test -f "$filename"
end
set -l stripped (printf '%s\n' "$original" | jq -cS 'del(.checkpoints.draft)')
check 'removal changes only the draft checkpoint' test (__pull_registration_payload "$model" user.Model '' | jq -cS .) = "$stripped"

reset_fixture
set model (printf '%s\n' "$model" | jq -c 'del(.checkpoints.draft)')
pull --mtp Model --no-draft --yes >"$sandbox/output" 2>"$sandbox/error"
check 'removing an absent draft is a no-op' test $status -eq 0
check 'removing an absent draft touches nothing' test (count $events) -eq 0
check 'removing an absent draft says so' string match -q '*nothing to remove*' (cat "$sandbox/output")

reset_fixture
set other_model (jq -nc --arg draft "$old_checkpoint" '{id:"Other",checkpoints:{draft:$draft}}')
pull --mtp Model --no-draft --yes >"$sandbox/output" 2>"$sandbox/error"
check 'a shared draft is still deregistered' test $status -eq 0
check 'a shared draft file is kept' test -f "$old_path"

reset_fixture
set failure_mode unload_refused
pull --mtp Model --no-draft --yes >"$sandbox/output" 2>"$sandbox/error"
check 'a refused unload aborts removal' test $status -eq 1
check 'a refused unload leaves the registration untouched' test (__pull_registration_payload "$model" user.Model '') = "$original"
check 'a refused unload preserves the draft file' test -f "$old_path"

reset_fixture
pull --mtp Model --no-draft </dev/null >"$sandbox/output" 2>"$sandbox/error"
check 'non-interactive removal without --yes is refused' test $status -eq 1
check 'a refused removal never mutates' test (count $events) -eq 0
check 'a refused removal preserves the draft file' test -f "$old_path"

reset_fixture
pull --mtp Model --draft MTP/mtp-new-Q4_0.gguf --no-draft --yes >"$sandbox/output" 2>"$sandbox/error"
check '--draft with --no-draft is rejected' test $status -eq 1
check 'conflicting draft flags change nothing' test (count $events) -eq 0

set -l candidates (__pull_draft_candidates "$variants" 'MTP/mtp-new-Q4_0.gguf')
check 'menu includes alternatives and deduplicates flattened paths' test (string join ',' $candidates) = 'MTP/mtp-new-Q4_0.gguf,mtp-old-BF16.gguf,mtp-other-Q8_0.gguf'
for answer in '' 0 1 mtp-other-Q8_0.gguf
    set -l selected (printf '%s\n' "$answer" | __pull_prompt_draft "$old_checkpoint" $candidates 2>"$sandbox/menu")
    check 'draft prompt accepts default, index, and path' test $status -eq 0
    check 'draft prompt stdout contains only the selection' test (count $selected) -eq 1
    set -l expected "$old_checkpoint"
    test "$answer" = 1; and set expected $candidates[1]
    test "$answer" = mtp-other-Q8_0.gguf; and set expected $answer
    check 'draft prompt returns the chosen value' test "$selected" = "$expected"
end
for answer in 4 unknown
    set -l selected (printf '%s\n' "$answer" | __pull_prompt_draft "$old_checkpoint" $candidates 2>"$sandbox/menu")
    check 'invalid draft selection fails' test $status -eq 1
    check 'invalid draft selection emits no value' test (count $selected) -eq 0
end
for answer in n N none
    set -l selected (printf '%s\n' "$answer" | __pull_prompt_draft "$old_checkpoint" $candidates 2>"$sandbox/menu")
    check 'the None entry is reported apart from a cancelled selection' test $status -eq 2
    check 'the None entry emits no value' test (count $selected) -eq 0
end
check 'the menu offers a None entry' string match -q '*n) None*' (string join ' ' (cat "$sandbox/menu"))
set -l selected (__pull_prompt_draft "$old_checkpoint" $candidates </dev/null 2>"$sandbox/menu")
check 'EOF cancels draft selection' test $status -eq 1

# Feed the real draft prompt explicitly: Fish command substitutions do not
# inherit a redirected stdin in non-interactive scripts.
functions -c __pull_prompt_draft __test_prompt_draft
function __pull_prompt_draft
    printf '%s\n' "$draft_answer" | __test_prompt_draft $argv
end
function isatty
    return 0
end
for confirmation in y n
    reset_fixture
    set -g draft_answer 1
    printf '%s\n' "$confirmation" >"$sandbox/input"
    pull --mtp Model <"$sandbox/input" >"$sandbox/output" 2>"$sandbox/error"
    check 'interactive replacement or cancellation succeeds' test $status -eq 0
    if test "$confirmation" = y
        check 'interactive replacement selects the real path' test (printf '%s' "$model" | jq -r '.checkpoints.draft') = "$new_checkpoint"
        check 'interactive replacement cleans old draft' test ! -L "$old_path"
    else
        check 'declining replacement leaves old draft' test -f "$old_path"
        check 'declining replacement never mutates' test (string join ',' $events) = inspect
    end
end
for confirmation in y n
    reset_fixture
    set -g draft_answer n
    printf '%s\n' "$confirmation" >"$sandbox/input"
    pull --mtp Model <"$sandbox/input" >"$sandbox/output" 2>"$sandbox/error"
    check 'menu removal or its cancellation succeeds' test $status -eq 0
    if test "$confirmation" = y
        check 'menu removal deregisters the draft' test (printf '%s' "$model" | jq -r '.checkpoints.draft // "none"') = none
        check 'menu removal deletes the old draft' test ! -L "$old_path"
    else
        check 'declining removal keeps the draft file' test -f "$old_path"
        check 'declining removal never mutates' test (string join ',' $events) = inspect
    end
end

reset_fixture
set -l saved_variants $variants
set variants '{"variants":[{"name":"Q4_K_M","draft_file":"MTP/mtp-old-BF16.gguf"}],"draft_files":["mtp-old-BF16.gguf"]}'
set draft_answer invalid
printf 'y\n' >"$sandbox/input"
pull --mtp Model <"$sandbox/input" >"$sandbox/output" 2>"$sandbox/error"
check 'no alternatives refreshes without a selection prompt' test $status -eq 0
check 'no alternatives preserves the old draft' test (string join ',' $events) = inspect,register,pull
set variants $saved_variants
functions -e isatty

source "$repo_root/completions/pull.fish"
function __pull_completion_api --argument-names url
    switch "$url"
        case /api/v1/models/user.Model
            echo $model
        case '/api/v1/pull/variants?checkpoint=org/Model&source=huggingface'
            echo $variants
    end
end
set -l completions
for entry in (complete -C 'pull --mtp Model --draft ')
    set -a completions (string split \t -- "$entry")[1]
end
check '--mtp draft completion resolves a registered model' contains 'MTP/mtp-new-Q4_0.gguf' $completions
check '--mtp draft completion includes alternative quants' contains mtp-other-Q8_0.gguf $completions

rm -rf -- "$sandbox"
if test $failures -gt 0
    echo "$failures MTP test(s) failed." >&2
    exit 1
end
echo 'All MTP draft tests passed.'
