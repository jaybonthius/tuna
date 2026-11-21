#!/bin/sh
set -eu
exec sh tests/run-browser.sh "$0" "${1:?usage: views-bars-browser-test.sh TUNA}" tests/views-browser/bars.mjs chromium webkit
