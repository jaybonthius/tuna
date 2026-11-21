#!/bin/sh
set -eu
exec sh tests/run-browser.sh "$0" "${1:?usage: views-edits-browser-test.sh TUNA}" tests/views-browser/edits.mjs chromium webkit
