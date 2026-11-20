#!/bin/sh
# The live servers are not Tuna's to ship, so the test passes over them
# when they are not installed, as a machine without Python tools would.
set -eu
tuna=${1:?usage: lsp-live-test.sh TUNA}
for program in basedpyright-langserver ruff; do
  if ! command -v "$program" > /dev/null 2>&1; then
    echo "$0: $program is not installed; skipped"
    exit 0
  fi
done
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-lsp-live-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
cp -R tests/lsp/home "$dir/home"
cp tests/lsp/live/live.transcript "$dir/live.transcript"
if sh tests/run-transcript.sh "$tuna" "$dir/live.transcript"; then
  echo "$0: 0 failures"
else
  echo "$0: 1 failures"
  exit 1
fi
