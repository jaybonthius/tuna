#!/bin/sh
set -eu
repository=${1:?usage: build-grammar.sh REPOSITORY COMMIT OUTPUT}
commit=${2:?usage: build-grammar.sh REPOSITORY COMMIT OUTPUT}
output=${3:?usage: build-grammar.sh REPOSITORY COMMIT OUTPUT}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-grammar.XXXXXX")
trap 'rm -rf "$dir"' EXIT
git -C "$repository" archive "$commit" src | tar -x -C "$dir"
scanner=
[ -f "$dir/src/scanner.c" ] && scanner=$dir/src/scanner.c
mkdir -p "$(dirname "$output")"
cc -O2 -std=c11 -fPIC -shared -I"$dir/src" -o "$output.new" "$dir/src/parser.c" $scanner
mv "$output.new" "$output"
