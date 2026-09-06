#!/usr/bin/env fish
set -l repo (builtin path resolve (builtin path dirname (status filename))/..)
source "$repo/functions/versions.fish"
set -l sandbox (mktemp -d)
set -gx LEMONADE_BACKEND_DIR "$sandbox/cache with spaces/bin"
set -gx LEMONADE_BACKEND_VERSIONS_FILE "$sandbox/catalog.json"
printf '%s' '{"future-backend":{"cpu":"wanted-version"},"checksums":{}}' >"$LEMONADE_BACKEND_VERSIONS_FILE"
mkdir -p "$LEMONADE_BACKEND_DIR/llamacpp/rocm-nightly" "$LEMONADE_BACKEND_DIR/llamacpp/vulkan" "$LEMONADE_BACKEND_DIR/flm/npu" "$LEMONADE_BACKEND_DIR/llamacpp/ignored.staging"
printf b1322 >"$LEMONADE_BACKEND_DIR/llamacpp/rocm-nightly/version.txt"
printf 'llama.cpp: custom-build\nROCm: bundled-version\n' >"$LEMONADE_BACKEND_DIR/llamacpp/rocm-nightly/versions.txt"
printf b10825 >"$LEMONADE_BACKEND_DIR/llamacpp/vulkan/version.txt"
versions >"$sandbox/output" 2>"$sandbox/error"
set -l failed 0
for pattern in b1322 b10825 'ROCm: bundled-version' 'future-backend +not installed' 'flm/npu: directory present; version unknown' 'source: .*cache with spaces'
    if not string match -qr "$pattern" -- (cat "$sandbox/output")
        echo "FAIL: missing $pattern" >&2
        set failed 1
    end
end
if test -s "$sandbox/error"; or string match -qr 'wanted-version|ignored.staging' -- (cat "$sandbox/output")
    echo 'FAIL: stderr, catalog target mistaken for installed version, or staging directory reported.' >&2
    cat "$sandbox/error" >&2
    set failed 1
end
rm -rf -- "$sandbox"
test "$failed" -eq 0; or exit 1
echo 'All version inventory tests passed.'
