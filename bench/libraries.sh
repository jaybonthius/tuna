#!/bin/sh
# Pinned to one CPU, so that each median compares like with like.
set -eu
tuna=${1:?usage: libraries.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
cpu=${BENCH_CPU:-$(($(nproc) - 1))}
runs=9
count=30
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-bench-libraries.XXXXXX")
trap 'rm -rf "$dir"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=Tuna GIT_AUTHOR_EMAIL=tuna@example.org
export GIT_COMMITTER_NAME=Tuna GIT_COMMITTER_EMAIL=tuna@example.org

mkdir -p "$dir/plugin" "$dir/none/.config/tuna" "$dir/some/.config/tuna"
: > "$dir/plugin/tuna.deps"
imports=
i=0
while [ $i -lt $count ]; do
  repository=$dir/remotes/chez-l$i
  mkdir -p "$repository/src"
  printf '(library (l%s) (export l%s) (import (chezscheme)) (define (l%s) %s))\n' $i $i $i $i \
    > "$repository/src/l$i.sls"
  git -C "$repository" init -q -b main
  git -C "$repository" add -A
  git -C "$repository" commit -q -m one
  printf '(library chez-l%s (git "file://%s") (commit "%s") (library-directories ("src" . "obj")) (build))\n' \
    $i "$repository" "$(git -C "$repository" rev-parse HEAD)" >> "$dir/plugin/tuna.deps"
  imports="$imports (l$i)"
  i=$((i + 1))
done
printf '#!tuna\n(import%s)\n(define (sum) (+%s))\n' "$imports" "$(echo "$imports" | sed 's/(l\([0-9]*\))/ (l\1)/g')" \
  > "$dir/plugin/uses.sls"
printf '(display "configured-ms ")\n(display (real-time))\n(newline)\n(exit)\n' > "$dir/none/.config/tuna/init.ss"
printf '(import (tuna plugins))\n(use-plugin uses (local "%s"))\n(display "configured-ms ")\n(display (real-time))\n(newline)\n(exit)\n' \
  "$dir/plugin" > "$dir/some/.config/tuna/init.ss"

start() {
  output=$(cd "$dir" && HOME="$dir/$1" TUNA_LIBRARY="$(dirname "$tuna")/plugins" taskset -c "$cpu" "$tuna" < /dev/null 2>&1)
  case $output in
    configured-ms*) echo "$output" | awk '{ print $2 }' ;;
    *) echo "libraries: $output" >&2; exit 1 ;;
  esac
}

median() {
  sort -n | awk '{ v[NR] = $1 } END { print v[int((NR + 1) / 2)] }'
}

# The first start installs the libraries; the others resolve them again
# with nothing to install, as every start does.
start none > /dev/null
start some > /dev/null
for shape in none some; do
  : > "$dir/$shape.times"
  i=0
  while [ $i -lt $runs ]; do
    start $shape >> "$dir/$shape.times"
    i=$((i + 1))
  done
done
none=$(median < "$dir/none.times")
some=$(median < "$dir/some.times")
echo "start with Tuna's own libraries: $none ms; with $count more: $some ms (medians of $runs)"
