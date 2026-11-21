#!/bin/sh
set -eu
exec sh tests/run-browser.sh "$0" "${1:?usage: faces-browser-test.sh TUNA}" tests/faces-browser/faces.mjs chromium
