#!/bin/sh
set -eu
exec sh tests/run-browser.sh "$0" "${1:?usage: views-lists-browser-test.sh TUNA}" tests/views-browser/lists.mjs chromium webkit
