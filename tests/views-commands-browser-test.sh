#!/bin/sh
set -eu
exec sh tests/run-browser.sh "$0" "${1:?usage: views-commands-browser-test.sh TUNA}" tests/views-browser/commands.mjs chromium webkit
