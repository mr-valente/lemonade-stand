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
# Container backends leave an image pin as their marker. The image lives on the
# Docker host, so report whether it is still there.
set -l present (string repeat -n 64 a)
set -l pruned (string repeat -n 64 b)
mkdir -p "$LEMONADE_BACKEND_DIR/llamacpp/nathanw" "$LEMONADE_BACKEND_DIR/gufo/rocm" "$sandbox/tools"
printf 'vulkan-radv-performance@sha256:%s\n' $present >"$LEMONADE_BACKEND_DIR/llamacpp/nathanw/version.txt"
printf 'rocm-10.0-gufo@sha256:%s\n' $pruned >"$LEMONADE_BACKEND_DIR/gufo/rocm/version.txt"
printf '%s\n' '#!/bin/sh' 'case "$1 $2" in' \
    '"image ls") echo 0123456789ab ;;' \
    "\"image inspect\") echo kyuz0/amd-strix-halo-toolboxes@sha256:$present ;;" \
    'esac' >"$sandbox/tools/docker"
chmod +x "$sandbox/tools/docker"
set -l saved_path $PATH
set -gx PATH "$sandbox/tools" $PATH
versions >"$sandbox/output" 2>"$sandbox/error"
set -gx PATH $saved_path
for pattern in 'vulkan-radv-performance@sha256:a+\n +image: present on the Docker host' 'rocm-10.0-gufo@sha256:b+\n +image: missing from the Docker host; run: install gufo rocm'
    if not string match -qr "$pattern" -- (cat "$sandbox/output" | string collect)
        echo "FAIL: missing $pattern" >&2
        set failed 1
    end
end
if test -s "$sandbox/error"
    echo 'FAIL: container backend markers must not produce errors.' >&2
    cat "$sandbox/error" >&2
    set failed 1
end
rm -rf -- "$sandbox"
test "$failed" -eq 0; or exit 1
echo 'All version inventory tests passed.'
