#!/bin/sh
set -eu

if ! command -v gerbil >/dev/null 2>&1; then
    printf '%s\n' 'Gerbil is required. Install it first, then rerun this script.' >&2
    exit 1
fi

export GERBIL_PATH="${XDG_DATA_HOME:-$HOME/.local/share}/tuna"
exec gerbil pkg install git.cons.io/jay/tuna
