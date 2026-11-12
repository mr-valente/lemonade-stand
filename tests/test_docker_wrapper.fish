#!/usr/bin/env fish
# The docker wrapper forwards LEMONADE_CONTAINER_ENV to the containers Lemonade
# starts and leaves every other docker command alone.
set -l repo (builtin path resolve (builtin path dirname (status filename))/..)
set -l sandbox (mktemp -d)
set -g failed 0

# Point the wrapper at a stand-in client that prints its arguments, one per line.
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$@"' >"$sandbox/docker-real"
sed "s|^real=.*|real=$sandbox/docker-real|" "$repo/utils/docker-wrapper.sh" >"$sandbox/docker"
chmod +x "$sandbox/docker-real" "$sandbox/docker"

function check --argument-names description expected actual
    if test "$expected" != "$actual"
        echo "FAIL: $description" >&2
        echo "  expected: $expected" >&2
        echo "  actual:   $actual" >&2
        set -g failed 1
    end
end

set -l backend run --rm --label ai.lemonade --label ai.lemonade.recipe=gufo image serve
set -l other run --rm --label mine image serve

set -l got (env LEMONADE_CONTAINER_ENV='GPU_MAX_HW_QUEUES,UNSET_NAME OTHER' GPU_MAX_HW_QUEUES=1 OTHER=x "$sandbox/docker" $backend)
check 'set variables are forwarded to a Lemonade backend, unset ones skipped' \
    "run --env GPU_MAX_HW_QUEUES --env OTHER $backend[2..]" "$got"

set got (env LEMONADE_CONTAINER_ENV=GPU_MAX_HW_QUEUES GPU_MAX_HW_QUEUES=1 "$sandbox/docker" $other)
check 'containers Lemonade did not start are left alone' "$other" "$got"

set got (env -u LEMONADE_CONTAINER_ENV GPU_MAX_HW_QUEUES=1 "$sandbox/docker" $backend)
check 'nothing is forwarded when the list is empty' "$backend" "$got"

set got (env LEMONADE_CONTAINER_ENV=GPU_MAX_HW_QUEUES GPU_MAX_HW_QUEUES=1 "$sandbox/docker" image ls -a --filter label=ai.lemonade)
check 'other docker commands pass through' 'image ls -a --filter label=ai.lemonade' "$got"

rm -rf -- "$sandbox"
test "$failed" -eq 0; or exit 1
echo 'All docker wrapper tests passed.'
