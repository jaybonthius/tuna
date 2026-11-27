#!/bin/sh
set -eu
tuna=${1:?usage: build-plugins.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
bin=$(dirname "$tuna")

# tuna --install builds and loads each plugin once, so a plugin that fails
# to compile, or compiles with a warning, fails the build. The objects it
# leaves are kept for tests, which would otherwise compile the same
# plugins in every home.
home=$(mktemp -d "${TMPDIR:-/tmp}/tuna-build-plugins.XXXXXX")
trap 'rm -rf "$home"' EXIT
status=0
(cd "$home" && HOME="$home" env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME \
  "$tuna" --install < /dev/null 2> "$home/errors") || status=$?
if [ "$status" -ne 0 ] || [ -s "$home/errors" ]; then
  cat "$home/errors" >&2
  echo "tuna --install failed with status $status" >&2
  exit 1
fi
rm -rf "$bin/plugins-cache" "$bin/start-cache"
cp -R "$home/.cache/tuna/library" "$bin/plugins-cache"
cp -R "$home/.cache/tuna/start$(cd "$bin" && pwd)/start" "$bin/start-cache"
