#!/bin/sh
set -eu
exec sh tests/run-browser.sh "$0" "${1:?usage: views-sideways-browser-test.sh TUNA}" tests/views-browser/sideways.mjs chromium webkit
