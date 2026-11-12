#!/usr/bin/env bash
set -euo pipefail

: "${XDG_RUNTIME_DIR:=/run/lemonade}"
export XDG_RUNTIME_DIR

mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# Lemonade gives container backends the GPU through this image's render group,
# so the group must carry the ID that owns the host's device nodes.
render_node=$(find /dev/dri -maxdepth 1 -name 'renderD*' 2>/dev/null | head -n 1 || true)
if [[ -n $render_node ]]; then
    render_gid=$(stat -c %g "$render_node")
    if [[ $render_gid != 0 && $render_gid != "$(getent group render | cut -d: -f3)" ]]; then
        groupmod --non-unique --gid "$render_gid" render || true
    fi
fi

# Container backends run on the host's Docker daemon.
if [[ -S /var/run/docker.sock ]]; then
    # A backend outlives a Lemonade that was killed rather than stopped, and
    # keeps its model in memory. Nothing from a previous run is still wanted.
    port=${LEMONADE_PORT:-$(jq -r '.port // empty' "$HOME/.cache/lemonade/config.json" 2>/dev/null || true)}
    stale="name=lemonade-${port:-13305}-"
    docker ps -aq --filter label=ai.lemonade --filter "$stale" | xargs -r docker rm -f >/dev/null || true
    docker network ls -q --filter label=ai.lemonade --filter "$stale" | xargs -r docker network rm >/dev/null || true

    preflight --quiet || true
else
    echo "Container backends are off: /var/run/docker.sock is not mounted."
fi

# Lemonade takes its address and port from config.json, not the environment.
# This image's tools and health check follow LEMONADE_PORT, so when these
# variables are set, hand them to the server too and keep everything agreed.
if [[ ${1##*/} == lemond ]]; then
    if [[ -n ${LEMONADE_PORT:-} ]]; then set -- "$@" --port "$LEMONADE_PORT"; fi
    if [[ -n ${LEMONADE_HOST:-} ]]; then set -- "$@" --host "$LEMONADE_HOST"; fi
fi

exec "$@"
