#!/usr/bin/env bash
set -euo pipefail

: "${XDG_RUNTIME_DIR:=/run/lemonade}"
export XDG_RUNTIME_DIR

mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

exec "$@"
