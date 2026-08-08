#!/bin/sh
set -eu

cd "$(dirname "$0")"
export EXPERT=1

if [ "$(id -u)" -ne 0 ]; then
    exec sudo -E "$0" "$@"
fi

exec ./install.sh "$@"
