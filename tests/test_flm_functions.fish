#!/usr/bin/env fish
functions -e path
set -l repo (builtin path resolve (builtin path dirname (status filename))/..)
source "$repo/functions/update.fish"
source "$repo/functions/delete.fish"
set -g failures 0
function check --argument-names description
    if not $argv[2..-1]
        echo "FAIL: $description" >&2
        test -f "$sandbox/error"; and cat "$sandbox/error" >&2
        set -g failures (math $failures + 1)
    end
end
set -g sandbox (mktemp -d)
set -gx LEMONADE_BACKEND_DIR "$sandbox/cache/bin"
set -gx FLM_MODEL_PATH "$sandbox/flm"
mkdir -p "$LEMONADE_BACKEND_DIR/flm/npu" "$FLM_MODEL_PATH/models"
set -gx FLM_TEST_FIXTURES "$sandbox"
printf '#!/bin/sh\nif [ "$2" = "--json" ]; then cat "$FLM_TEST_FIXTURES/catalog"; else cat "$FLM_TEST_FIXTURES/list"; fi\n' >"$LEMONADE_BACKEND_DIR/flm/npu/flm"
chmod +x "$LEMONADE_BACKEND_DIR/flm/npu/flm"
printf '%s\n' '{"models":[{"name":"gemma4-it:e2b","url":"https://huggingface.co/FastFlowLM/Old/resolve/main"},{"name":"ready:1b","url":"https://huggingface.co/FastFlowLM/Ready"},{"name":"missing:1b","url":"https://huggingface.co/FastFlowLM/Missing"},{"name":"ghost:1b","url":"https://huggingface.co/FastFlowLM/Ghost"}]}' >"$sandbox/catalog"
set -g original_listing 'Models:
[WARNING] Local model gemma4-it:e2b version: 0.9.39 < 0.9.43
  - gemma4-it:e2b ⚠️
  - ready:1b ✅
  - missing:1b ⏬
  - ghost:1b ⏬'
set -g models '{"data":[{"id":"Main","recipe":"llamacpp","downloaded":true,"size":0},{"id":"Old-FLM","recipe":"flm","downloaded":false,"checkpoint":"gemma4-it:e2b"},{"id":"Ready-FLM","recipe":"flm","downloaded":true,"checkpoints":{"main":"ready:1b"}},{"id":"Missing-FLM","recipe":"flm","downloaded":false,"checkpoint":"missing:1b"}]}'
function reset_fixture
    printf '%s\n' "$original_listing" >"$sandbox/list"
    rm -rf -- "$FLM_MODEL_PATH/models"
    mkdir -p "$FLM_MODEL_PATH/models/Old/nested" "$FLM_MODEL_PATH/models/Ready" "$FLM_MODEL_PATH/models/Ghost"
    printf old >"$FLM_MODEL_PATH/models/Old/model.q4nx"
    printf partial >"$FLM_MODEL_PATH/models/Old/nested/partial"
    printf keep >"$FLM_MODEL_PATH/models/Ready/model.q4nx"
    printf ghost >"$FLM_MODEL_PATH/models/Ghost/model.q4nx"
    set -g pulled
    set -g deleted
    set -g failure_mode ''
    set -g inventory_reads 0
    set -g shared false
end
function __update_api --argument-names method url body timeout
    switch "$url"
        case '/api/v1/models?show_all=true'
            echo "$models"
        case /api/v1/models/check-updates
            echo '{"models":["Main"]}'
        case '/api/v1/models/*/files?include_paths=true'
            echo '{"files":[]}'
        case /api/v1/health
            echo '{"status":"ok","all_models_loaded":[]}'
        case '*'
            echo '{"status":"success"}'
    end
end
function __update_pull --argument-names name
    set -ga pulled "$name"
    if test "$failure_mode" = pull
        return 1
    end
    if test "$name" = Old-FLM; and test "$failure_mode" != stale_after_pull
        printf '%s\n' 'Models:' '  - gemma4-it:e2b ✅' '  - ready:1b ✅' '  - missing:1b ⏬' >"$sandbox/list"
    end
    return 0
end
function __delete_api --argument-names method url body timeout
    switch "$url"
        case '/api/v1/models?show_all=true'
            set -g inventory_reads (math $inventory_reads + 1)
            if test "$failure_mode" = inventory; and test $inventory_reads -gt 1
                return 1
            end
            if test "$shared" = true
                printf '%s\n' "$models" | jq -c '.data += [{id:"Other-FLM",recipe:"flm",downloaded:true,checkpoint:"gemma4-it:e2b"}]'
            else
                echo "$models"
            end
        case /api/v1/delete
            set -g deleted (printf '%s\n' "$body" | jq -r '.model_name')
            test "$failure_mode" = delete; and return 1
            echo '{"status":"success"}'
        case /internal/aliases
            echo '{"aliases":[]}'
        case /api/v1/downloads
            echo '[]'
        case /api/v1/system-info
            echo '{}'
        case '*'
            echo '{"status":"ok","files":[]}'
    end
end

reset_fixture
set -l status_json (__flm_status)
check 'outdated parser recognizes exact warning' test (printf '%s' "$status_json" | jq -r '.models[0].state') = outdated
set -l states (__flm_parse_status 'Models:' '[WARNING] Local model newer:1b version: 2.0.0 > 1.0.3' '  - newer:1b ⚠️' '  - unknown:1b ⚠️')
check 'newer weights need a backend update, not redownload' test (printf '%s' "$states" | jq -r '.models[0].state') = incompatible
check 'unexplained warning is not treated as outdated' test (printf '%s' "$states" | jq -r '.models[1].state') = unknown
__flm_parse_status 'unexpected output' >/dev/null
check 'unknown list format fails closed' test $status -ne 0
set -l entry (jq -c '.models[0]' "$sandbox/catalog")
check 'FLM path strips URL revision suffix' test (__flm_repo_name "$entry") = Old
check 'FLM path follows its own model root' test (__flm_model_dirs "$entry") = "$FLM_MODEL_PATH/models/Old"

update --check >"$sandbox/output" 2>"$sandbox/error"
check 'combined check succeeds' test $status -eq 0
check 'check includes outdated model marked downloaded=false' rg -q Old-FLM "$sandbox/output"
check 'check never downloads' test (count $pulled) -eq 0
update --all --dry-run >"$sandbox/output" 2>"$sandbox/error"
check 'all dry-run previews outdated FLM model' rg -q Old-FLM "$sandbox/output"
check 'dry-run never downloads' test (count $pulled) -eq 0
update --all --yes >"$sandbox/output" 2>"$sandbox/error"
check 'all updates both registries' test (string join ',' $pulled) = Main,Old-FLM
reset_fixture
update Old-FLM --yes >"$sandbox/output" 2>"$sandbox/error"
check 'named update accepts outdated local FLM weights' test $status -eq 0
check 'named update pulls its model' contains Old-FLM $pulled
reset_fixture
update Ready-FLM --yes >"$sandbox/output" 2>"$sandbox/error"
check 'current FLM model is skipped' test (count $pulled) -eq 0
update Ready-FLM --force --yes >"$sandbox/output" 2>"$sandbox/error"
check 'force still refreshes a current FLM model' contains Ready-FLM $pulled
update Missing-FLM --yes >"$sandbox/output" 2>"$sandbox/error"
check 'missing weights are not treated as installed' test $status -eq 1
reset_fixture
set failure_mode stale_after_pull
update Old-FLM --yes >"$sandbox/output" 2>"$sandbox/error"
check 'successful exit with still-outdated weights is reported as failure' test $status -eq 1

for target in Old-FLM gemma4-it:e2b Old
    reset_fixture
    delete --yes "$target" >"$sandbox/output" 2>"$sandbox/error"
    check 'FLM deletion succeeds by model id, native tag, or directory name' test $status -eq 0
    check 'FLM deletion uses canonical registration id' test "$deleted" = Old-FLM
    check 'FLM deletion removes nested and stale weights' test ! -e "$FLM_MODEL_PATH/models/Old"
    check 'FLM deletion preserves sibling models' test -f "$FLM_MODEL_PATH/models/Ready/model.q4nx"
end
reset_fixture
delete --dry-run gemma4-it:e2b >"$sandbox/output" 2>"$sandbox/error"
check 'dry-run includes the FLM directory' rg -q /models/Old "$sandbox/output"
check 'dry-run leaves FLM weights untouched' test -f "$FLM_MODEL_PATH/models/Old/model.q4nx"
check 'dry-run never deletes registration' test -z "$deleted"
for target in ghost:1b Ghost
    reset_fixture
    delete --yes "$target" >"$sandbox/output" 2>"$sandbox/error"
    check 'unregistered FLM weights can be deleted' test $status -eq 0
    check 'unregistered FLM directory is removed' test ! -e "$FLM_MODEL_PATH/models/Ghost"
    check 'unregistered cleanup does not delete any registration' test -z "$deleted"
end
reset_fixture
mkdir -p "$FLM_MODEL_PATH/models/Unlisted"
delete --yes Unlisted >"$sandbox/output" 2>"$sandbox/error"
check 'directory removed from both catalogs can be cleaned' test ! -e "$FLM_MODEL_PATH/models/Unlisted"
for mode in delete inventory
    reset_fixture
    set failure_mode "$mode"
    delete --yes Old-FLM >"$sandbox/output" 2>"$sandbox/error"
    check 'API failure is reported' test $status -eq 1
    check 'API failure prevents FLM filesystem cleanup' test -f "$FLM_MODEL_PATH/models/Old/model.q4nx"
end
reset_fixture
set shared true
delete --yes Old-FLM >"$sandbox/output" 2>"$sandbox/error"
check 'shared FLM weights are protected before native deletion' test $status -eq 1
check 'shared FLM registration is untouched' test -z "$deleted"
check 'shared FLM weights are kept' test -f "$FLM_MODEL_PATH/models/Old/model.q4nx"
reset_fixture
mv "$FLM_MODEL_PATH/models/Old" "$sandbox/outside"
ln -s "$sandbox/outside" "$FLM_MODEL_PATH/models/Old"
delete --yes Old-FLM >"$sandbox/output" 2>"$sandbox/error"
check 'symlinked FLM directory is refused' test $status -eq 1
check 'symlink target remains untouched' test -f "$sandbox/outside/model.q4nx"

reset_fixture
delete --yes --no-cleanup Old-FLM >"$sandbox/output" 2>"$sandbox/error"
check 'no-cleanup leaves additional FLM cleanup to the server' test -f "$FLM_MODEL_PATH/models/Old/nested/partial"
delete --yes --no-cleanup Old >"$sandbox/output" 2>"$sandbox/error"
check 'explicit directory cleanup still applies with no-cleanup' test ! -e "$FLM_MODEL_PATH/models/Old"

reset_fixture
source "$repo/completions/update.fish"
source "$repo/completions/delete.fish"
function curl
    echo "$models"
end
function __delete_completion_get --argument-names url
    if test "$url" = /internal/aliases
        echo '{"aliases":[]}'
    else
        echo "$models"
    end
end
function __delete_completion_cache_dir
    return 1
end
set -l offered
for entry in (complete -C 'update ')
    set -a offered (string split \t -- "$entry")[1]
end
check 'update completion includes outdated FLM weights' contains Old-FLM $offered
contains Missing-FLM $offered
check 'update completion excludes missing weights' test $status -ne 0
set offered
for entry in (__delete_completion_targets)
    set -a offered (string split \t -- "$entry")[1]
end
check 'delete completion includes outdated FLM weights' contains Old-FLM $offered
check 'delete completion includes orphaned native FLM tags' contains ghost:1b $offered

rm -rf -- "$sandbox"
if test $failures -gt 0
    echo "$failures FLM test(s) failed." >&2
    exit 1
end
echo 'All FLM function tests passed.'
