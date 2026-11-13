#!/bin/sh
set -eu
tuna=${1:?usage: build-plugins.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
library=$(dirname "$tuna")/plugins
libraries=$(dirname "$tuna")/libraries

for script in "$library"/*/build.ss; do
  [ -f "$script" ] || continue
  (cd "$(dirname "$script")" && "$tuna" --script build.ss)
done

if [ -f "$library/tuna.deps" ]; then
  "$tuna" --script "$(dirname "$0")/build-libraries.ss" "$tuna" "$libraries" "$library/tuna.deps" \
    "$(dirname "$tuna")/../libraries"
fi

# Loading each main module once makes a plugin that fails to compile, or
# compiles with a warning, fail the build.
home=$(mktemp -d "${TMPDIR:-/tmp}/tuna-build-plugins.XXXXXX")
trap 'rm -rf "$home"' EXIT
mkdir -p "$home/.config/tuna"
for module in "$library"/*.sls; do
  printf '(import (%s))\n' "$(basename "$module" .sls)"
done > "$home/.config/tuna/init.ss"
echo '(exit)' >> "$home/.config/tuna/init.ss"
output=$(cd "$home" && HOME="$home" TUNA_LIBRARY="$library" "$tuna" < /dev/null 2>&1)
if [ -n "$output" ]; then
  echo "$output"
  exit 1
fi
