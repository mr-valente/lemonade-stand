#!/usr/bin/env bash
# Lemonade starts each container backend with `docker run` and passes it only
# the variables Lemonade sets itself. Tuning set on this container, such as
# GPU_MAX_HW_QUEUES, would therefore reach native backends but not container
# ones. This forwards the variables named in LEMONADE_CONTAINER_ENV to the
# containers Lemonade starts, and passes every other command through untouched.
real=/opt/docker/bin/docker

if [[ ${1:-} == run && -n ${LEMONADE_CONTAINER_ENV:-} && " $* " == *" ai.lemonade "* ]]; then
    forward=()
    for name in ${LEMONADE_CONTAINER_ENV//,/ }; do
        # `--env NAME` copies the value from this process's environment.
        [[ -v $name ]] && forward+=(--env "$name")
    done
    exec "$real" run "${forward[@]}" "${@:2}"
fi

exec "$real" "$@"
