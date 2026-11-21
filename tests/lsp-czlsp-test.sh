#!/bin/sh
# czlsp is not Tuna's to ship, so the test passes over it when it is not
# installed.
set -eu
tuna=${1:?usage: lsp-czlsp-test.sh TUNA}
if ! command -v czlsp > /dev/null 2>&1; then
  echo "$0: czlsp is not installed; skipped"
  exit 0
fi
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-lsp-czlsp-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
cp -R tests/lsp/home "$dir/home"
cp tests/lsp/live/czlsp.transcript "$dir/czlsp.transcript"
if sh tests/run-transcript.sh "$tuna" "$dir/czlsp.transcript"; then
  echo "$0: 0 failures"
else
  echo "$0: 1 failures"
  exit 1
fi
