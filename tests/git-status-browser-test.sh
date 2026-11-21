#!/bin/sh
set -eu
exec sh tests/run-browser.sh "$0" "${1:?usage: git-status-browser-test.sh TUNA}" tests/git-status-browser/buttons.mjs chromium
