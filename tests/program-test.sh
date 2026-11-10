#!/bin/sh
set -eu
tuna=${1:?usage: program-test.sh TUNA}
failures=0
fail() {
  echo "$0: FAIL: $1"
  failures=$((failures + 1))
}

status=0
version=$("$tuna" --version) || status=$?
[ "$status" -eq 0 ] || fail "--version exited with status $status"
printf '%s\n' "$version" | grep -Eqx 'tuna [0-9]+\.[0-9]+\.[0-9]+' ||
  fail "--version printed: $version"

status=0
usage=$("$tuna" --unknown 2>&1 > /dev/null) || status=$?
[ "$status" -eq 2 ] || fail "unknown arguments exited with status $status, not 2"
case $usage in
  *usage:*) ;;
  *) fail "unknown arguments printed no usage: $usage" ;;
esac

status=0
message=$(env -u HOME "$tuna" 2>&1 < /dev/null) || status=$?
[ "$status" -eq 1 ] || fail "no HOME exited with status $status, not 1"
[ "$message" = "tuna: HOME is not set" ] || fail "no HOME printed: $message"

echo "$0: $failures failures"
[ "$failures" -eq 0 ]
