#!/bin/sh
# Tuna's own library is the one built beside the executable, since some
# of its plugins build native code. The plugins come before their compiled
# objects, so each object is newer than its source, which is how Chez
# decides an object is current.
set -eu
tuna=${1:?usage: test-home.sh TUNA LIBRARY HOME}
library=${2:?usage: test-home.sh TUNA LIBRARY HOME}
home=${3:?usage: test-home.sh TUNA LIBRARY HOME}
bin=$(dirname "$tuna")
mkdir -p "$library" "$home/.cache/tuna" "$home/.config/tuna/lib"
cp -R "$(dirname "$0")/modules/." "$home/.config/tuna/lib/"
cp -R "$bin/plugins/." "$library/"
cp -R "$bin/plugins-cache" "$home/.cache/tuna/library"
start=$home/.cache/tuna/start$(cd "$bin" && pwd)/start
mkdir -p "$(dirname "$start")"
cp -R "$bin/start-cache" "$start"
