#!/bin/sh
set -eu
tuna=${1:?usage: transcript-test.sh TUNA}
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-transcript-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
failures=0
fail() {
  echo "$0: FAIL: $1"
  failures=$((failures + 1))
}

# A runner that passed everything would make every transcript useless.
transcript() {
  mkdir -p "$dir/$1/home/.config/tuna"
  printf '(import (console))\n' > "$dir/$1/home/.config/tuna/init.ss"
  printf "$2" > "$dir/$1/t.transcript"
  sh tests/run-transcript.sh "$tuna" "$dir/$1/t.transcript" 2>&1
}

if output=$(transcript wrong '> (+ 1 2)\n4\n'); then
  fail "a wrong value passed"
fi
case $output in
  *"-4"*"+3"*) ;;
  *) fail "a wrong value's failure did not show the difference: $output" ;;
esac

if output=$(transcript missing '> (+ 1 2)\n'); then
  fail "output the transcript does not expect passed"
fi

if output=$(transcript status '> (exit 3)\n'); then
  fail "a non-zero exit status passed"
fi

if ! output=$(transcript right '; comment\n> (list 1\n    2)\n(1 2)\n'); then
  fail "a right transcript failed: $output"
fi

echo "$0: $failures failures"
[ "$failures" -eq 0 ]
