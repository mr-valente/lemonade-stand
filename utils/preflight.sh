#!/usr/bin/env bash
# Check that this container can run Lemonade's container backends.
#
# Lemonade asks the host's Docker daemon to start each container backend, so
# three things must line up between this container and the host: the Docker
# socket, the network, and the paths of the model files.
#
#   preflight           report every check
#   preflight --quiet   report only problems (used at container start)
set -uo pipefail

quiet=false
case ${1:-} in
    -q | --quiet) quiet=true ;;
    -h | --help)
        sed -n '2,9s/^# \{0,1\}//p' "$0"
        exit 0
        ;;
    '') ;;
    *)
        echo "Usage: preflight [--quiet]" >&2
        exit 2
        ;;
esac

failures=0
pass() { $quiet || printf '  ok    %s\n' "$1"; }
note() { $quiet || printf '  note  %s\n' "$1"; }
fail() {
    failures=$((failures + 1))
    printf '  FAIL  %s\n        %s\n' "$1" "$2"
}

$quiet || echo "Container backend preflight"

# 1. The Docker daemon.
if ! command -v docker >/dev/null; then
    fail "No docker client in this image" "Rebuild from a current lemonade-stand Dockerfile."
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    fail "The Docker daemon is not reachable" \
        "Mount the host socket: -v /var/run/docker.sock:/var/run/docker.sock"
    exit 1
fi
pass "Docker daemon reachable ($(docker info --format '{{.ServerVersion}}' 2>/dev/null))"

# Docker bind-mounts these files from /var/lib/docker/containers/<id>/, which
# names this container even when it shares the host's hostname.
self=$(grep -oEm1 '/containers/[0-9a-f]{64}/' /proc/self/mountinfo | cut -d/ -f3)
if [[ -z $self ]] || ! docker inspect "$self" >/dev/null 2>&1; then
    note "Could not identify this container; skipping the network and path checks"
    exit 0
fi

# 2. The network. Each backend gets a private network that only the host can
# reach, so Lemonade has to share the host's network namespace.
network=$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$self")
if [[ $network == host ]]; then
    pass "Host networking"
else
    fail "This container is on the '$network' network" \
        "Set network_mode: host (and drop ports:) so Lemonade can reach its backends."
fi

# 3. Model paths. Lemonade hands the daemon the paths it sees, so each model
# directory must be a host mount at the same path on both sides.
hub=${HF_HUB_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}/hub}
config=$HOME/.cache/lemonade/config.json
extra=$(jq -r '.extra_models_dir // empty' "$config" 2>/dev/null)
for directory in "$hub" $extra; do
    source_path=$(docker inspect "$self" | jq -r --arg dir "$directory" '
        [.[0].Mounts[] | select(.Destination as $d | $dir == $d or ($dir | startswith($d + "/")))]
        | max_by(.Destination | length) as $mount
        | if $mount then $mount.Source + ($dir | ltrimstr($mount.Destination)) else empty end')
    if [[ -z $source_path ]]; then
        fail "$directory is not mounted from the host" \
            "Mount the host's model directory at the same path inside this container."
    elif [[ $source_path != "$directory" ]]; then
        fail "$directory is $source_path on the host" \
            "Mount it as $source_path:$source_path and set HF_HOME to match."
    else
        pass "Model path is the same on the host: $directory"
    fi
done

# 4. GPU access. Backends run without privileges and open the GPU through the
# render group, whose ID must be the one that owns the device nodes.
node=$(find /dev/dri -maxdepth 1 -name 'renderD*' 2>/dev/null | head -n 1)
if [[ -z $node ]]; then
    fail "No GPU render node under /dev/dri" "Pass the GPU through: privileged, or devices: /dev/dri and /dev/kfd."
elif [[ $(stat -c %g "$node") == "$(getent group render | cut -d: -f3)" ]]; then
    pass "render group matches $node (gid $(stat -c %g "$node"))"
else
    fail "render group does not own $node" "Restart the container; its entrypoint aligns the group."
fi

forwarded=()
for name in ${LEMONADE_CONTAINER_ENV//,/ }; do
    [[ -v $name ]] && forwarded+=("$name=${!name}")
done
if ((${#forwarded[@]})); then
    note "Forwarded to backends: ${forwarded[*]}"
fi

if ((failures)) && $quiet; then
    echo "        Container backends will not work until this is fixed. Run 'preflight' for the full report."
fi
((failures == 0))
