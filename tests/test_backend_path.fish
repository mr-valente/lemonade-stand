#!/usr/bin/env fish
set -l repo (builtin path resolve (builtin path dirname (status filename))/..)
source "$repo/functions/backend-path.fish"
set -l sandbox (mktemp -d)
set -gx LEMONADE_BACKEND_DIR "$sandbox/cache with spaces/bin"
set -l failures 0
mkdir -p "$LEMONADE_BACKEND_DIR"
backend-path 2>"$sandbox/error"
if test -s "$sandbox/error"
    echo 'FAIL: an empty backend cache must not produce shell startup errors.' >&2
    cat "$sandbox/error" >&2
    set failures (math $failures + 1)
end
for directory in llamacpp/vulkan llamacpp/rocm-nightly flm/npu whispercpp/rocm/bin vllm/rocm/bin therock-wheels/gfx1151-7.14.0/venv/bin therock/gfx1151-7.13.0/bin
    mkdir -p "$LEMONADE_BACKEND_DIR/$directory"
end
printf '%s\n' '{"llamacpp":{"backend":"vulkan"},"rocm_channel":"nightly"}' >"$sandbox/cache with spaces/config.json"
for binary in llamacpp/vulkan/llama-server llamacpp/rocm-nightly/llama-server flm/npu/flm whispercpp/rocm/bin/whisper-server vllm/rocm/bin/hipconfig therock-wheels/gfx1151-7.14.0/venv/bin/hipconfig
    printf '#!/bin/sh\nexit 0\n' >"$LEMONADE_BACKEND_DIR/$binary"
    chmod +x "$LEMONADE_BACKEND_DIR/$binary"
end
backend-path
set -l first_path "$PATH"
backend-path
if test "$first_path" != "$PATH"
    echo 'FAIL: backend-path must be idempotent.' >&2
    set failures (math $failures + 1)
end
for command_name in llama-server flm whisper-server hipconfig
    set -l expected
    switch "$command_name"
        case llama-server
            set expected "$LEMONADE_BACKEND_DIR/llamacpp/vulkan/llama-server"
        case flm
            set expected "$LEMONADE_BACKEND_DIR/flm/npu/flm"
        case whisper-server
            set expected "$LEMONADE_BACKEND_DIR/whispercpp/rocm/bin/whisper-server"
        case hipconfig
            set expected "$LEMONADE_BACKEND_DIR/therock-wheels/gfx1151-7.14.0/venv/bin/hipconfig"
    end
    if test (command -s "$command_name") != "$expected"
        echo "FAIL: wrong executable selected for $command_name." >&2
        set failures (math $failures + 1)
    end
end
printf '%s\n' '{"llamacpp":{"backend":"rocm"},"rocm_channel":"nightly"}' >"$sandbox/cache with spaces/config.json"
backend-path
if test (command -s llama-server) != "$LEMONADE_BACKEND_DIR/llamacpp/rocm-nightly/llama-server"
    echo 'FAIL: PATH must follow the changed default backend.' >&2
    set failures (math $failures + 1)
end
rm -rf -- "$LEMONADE_BACKEND_DIR/flm"
backend-path
if contains -- "$LEMONADE_BACKEND_DIR/flm/npu" $PATH
    echo 'FAIL: uninstalled backends must leave PATH on refresh.' >&2
    set failures (math $failures + 1)
end
source "$repo/functions/rocm-info.fish"
printf '7.14.0\n' >"$LEMONADE_BACKEND_DIR/therock-wheels/gfx1151-7.14.0/version.txt"
rocm-info >"$sandbox/rocm-output" 2>"$sandbox/error"
if test -s "$sandbox/error"; or not rg -q '^ROCm 7.14.0:' "$sandbox/rocm-output"
    echo 'FAIL: rocm-info must report runtime version markers without shell errors.' >&2
    cat "$sandbox/error" >&2
    set failures (math $failures + 1)
end
rm -rf -- "$sandbox"
if test $failures -gt 0
    exit 1
end
echo 'All backend PATH tests passed.'
