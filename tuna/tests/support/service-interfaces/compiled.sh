#!/bin/sh
# Compile declarations independently, then run without the source fixtures.
set -eu
fixtures=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
root=$(CDPATH= cd -- "$fixtures/../../../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
cp "$fixtures/base.ss" "$fixtures/derived.ss" "$fixtures/caller.ss" "$work/"
mkdir "$work/lib" "$work/runtime"
export GERBIL_PATH="$root/.gerbil" GERBIL_LOADPATH="$work/lib:$root/.gerbil/lib"
cd "$work"
for module in base derived caller; do
  systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0 timeout 2400 \
    gxi -e '(import :gerbil/expander)' -e "(import-module \"./$module.ss\" #f #t)"
  systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0 timeout 2400 \
    gxc -O -s -d lib "$module.ss"
done
cd runtime
systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0 timeout 2400 \
  gxi -e '(import :tuna/tests/support/service-interfaces/caller)' -e '(check-preservation)'
