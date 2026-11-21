#!/bin/sh
# Tuna never needs Playwright, so where it or its browsers are missing a
# browser test is skipped, not failed.
set -eu
test=${1:?usage: run-browser.sh TEST TUNA SCRIPT BROWSER...}
tuna=${2:?usage: run-browser.sh TEST TUNA SCRIPT BROWSER...}
script=${3:?usage: run-browser.sh TEST TUNA SCRIPT BROWSER...}
shift 3
status=0
if command -v node >/dev/null 2>&1; then
  browsers=$(node "$(dirname "$0")/browser/installed.mjs" "$test" "$@") || status=$?
else
  status=1
fi
case $status in
  0) ;;
  1) echo "$test: skipped: Playwright not installed"; exit 0 ;;
  *) exit "$status" ;;
esac
[ -n "$browsers" ] || exit 0
# A script launches only the browsers in BROWSERS: the others cannot start
# on this machine.
BROWSERS=$browsers exec node "$script" "$tuna"
