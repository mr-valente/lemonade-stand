#!/usr/bin/env fish
# An interactive fish config can define its own `path` helper, which shadows the
# `path` builtin. Drop it so the tests exercise the real code.
functions -e path

set -g tests_failed 0

function assert_equal --argument-names expected actual description
    if test "$expected" != "$actual"
        echo "FAIL: $description" >&2
        echo "  expected: $expected" >&2
        echo "  actual:   $actual" >&2
        set -g tests_failed (math $tests_failed + 1)
    end
end

function assert_contains --argument-names expected description
    if not contains -- "$expected" $argv[3..-1]
        echo "FAIL: $description" >&2
        echo "  missing: $expected" >&2
        set -g tests_failed (math $tests_failed + 1)
    end
end

function assert_not_contains --argument-names unexpected description
    if contains -- "$unexpected" $argv[3..-1]
        echo "FAIL: $description" >&2
        echo "  unexpected: $unexpected" >&2
        set -g tests_failed (math $tests_failed + 1)
    end
end

set -l repo (builtin path resolve (builtin path dirname (status filename))/..)
source "$repo/functions/install.fish"
source "$repo/completions/install.fish"

# What the server reports: a native recipe with a container backend beside it,
# a container-only recipe, a renamed recipe, and one this machine cannot run.
set -g system_info_fixture '{"recipes":{
  "llamacpp":{"default_backend":"rocm","display_name":"Llama.cpp GPU","backends":{
    "rocm":{"state":"update_available","format":"native"},
    "nathanw":{"state":"installable","format":"container"},
    "metal":{"state":"unsupported","format":"native"}}},
  "gufo":{"default_backend":"rocm","display_name":"Gufo","backends":{
    "rocm":{"state":"installed","format":"container"}}},
  "sd-cpp":{"default_backend":"vulkan","display_name":"StableDiffusion.cpp","backends":{
    "vulkan":{"state":"installable","format":"native"}}},
  "ryzenai-llm":{"default_backend":"npu","display_name":"Ryzen AI","backends":{
    "npu":{"state":"unsupported","format":"native"}}}}}'

# Stand in for the server: answer system-info, record every install request.
function curl
    set -l url (string match -r 'http://\S+' -- $argv)[1]
    if string match -q '*/system-info' -- $url
        printf '%s\n' "$system_info_fixture"
    else if string match -q '*/install' -- $url
        set -ga install_requests (printf '%s\n' $argv[-1] | jq -r '"\(.recipe):\(.backend) stream=\(.stream) force=\(.force)"')
        echo '{"status":"success"}'
    end
end

function installs
    set -g install_requests
    install $argv >/dev/null 2>&1
    set -g install_status $status
end

installs llamacpp nathanw
assert_equal 'llamacpp:nathanw stream=false force=false' "$install_requests" 'a recipe and backend install that pair'

installs llamacpp:nathanw --stream --force
assert_equal 'llamacpp:nathanw stream=true force=true' "$install_requests" 'the recipe:backend form and its flags reach the API'

installs gufo
assert_equal 'gufo:rocm stream=false force=false' "$install_requests" 'a recipe alone installs its default backend'

installs sdcpp
assert_equal 'sd-cpp:vulkan stream=false force=false' "$install_requests" 'a config section name maps to its recipe'

installs no-such-recipe
assert_equal 1 "$install_status" 'an unknown recipe without a backend is an error'
assert_equal '' "$install_requests" 'an unknown recipe installs nothing'

set -l sandbox (mktemp -d)
printf '%s\n' '{
  "port": 13305,
  "rocm_channel": "nightly",
  "llamacpp": {"backend": "rocm", "install": ["rocm", "nathanw"]},
  "gufo": {"install": true},
  "sdcpp": {"backend": "auto", "install": true},
  "whispercpp": {"backend": "rocm", "install": true},
  "kokoro": {"backend": "cpu", "install": false},
  "vllm": {"backend": "rocm"}
}' >"$sandbox/config.json"

installs --all --config "$sandbox/config.json"
assert_equal 0 "$install_status" 'install --all succeeds'
assert_equal 5 (count $install_requests) 'install --all installs exactly the marked backends'
for expected in llamacpp:rocm llamacpp:nathanw gufo:rocm sd-cpp:vulkan whispercpp:rocm
    assert_contains "$expected stream=false force=false" "install --all covers $expected" $install_requests
end

printf '%s\n' '{"llamacpp": {"backend": "rocm"}}' >"$sandbox/config.json"
installs --all --config "$sandbox/config.json"
assert_equal 0 "$install_status" 'install --all with nothing marked is not an error'
assert_equal '' "$install_requests" 'install --all with nothing marked installs nothing'

installs --all --config "$sandbox/missing.json"
assert_equal 1 "$install_status" 'install --all needs its configuration file'

set -l recipes (complete -C 'install ' | string replace -r '\t.*' '')
for expected in llamacpp gufo sd-cpp
    assert_contains $expected "completion offers the $expected recipe" $recipes
end
assert_not_contains ryzenai-llm 'completion hides recipes this machine cannot run' $recipes

set -l backends (complete -C 'install llamacpp ')
assert_contains nathanw\t'installable, container' 'completion describes a container backend' $backends
assert_contains rocm\t'update available, native, default' 'completion marks the default backend' $backends
assert_not_contains metal 'completion hides unsupported backends' (string replace -r '\t.*' '' -- $backends)

rm -rf -- "$sandbox"
test "$tests_failed" -eq 0; or exit 1
echo 'All install tests passed.'
