#!/bin/sh
set -eu
source=$HOME/.local/share/tuna/source
config=${XDG_CONFIG_HOME:-$HOME/.config}/tuna
scheme=${SCHEME:-$(command -v scheme || true)}

missing=
for tool in git cc make; do
  command -v "$tool" > /dev/null || missing="$missing $tool,"
done
if [ -z "$scheme" ] ||
   ! echo '(exit (if (and (threaded?) (string=? (scheme-version) "Chez Scheme Version 10.4.1")) 0 1))' |
     "$scheme" -q > /dev/null 2>&1; then
  missing="$missing threaded Chez Scheme 10.4.1 (set SCHEME to it or put scheme on PATH),"
fi
if [ -n "$missing" ]; then
  echo "Tuna needs${missing%,}." >&2
  exit 1
fi

if [ -d "$source" ]; then
  git -C "$source" pull --ff-only
  git -C "$source" submodule update --init --recursive
else
  git clone --recursive https://github.com/jaybonthius/tuna "$source"
fi
make -C "$source" exe SCHEME="$scheme"
mkdir -p "$HOME/.local/bin" "$config"
ln -sf "$source/build/bin/tuna" "$HOME/.local/bin/tuna"
if [ ! -e "$config/init.ss" ]; then
  cp "$source/init.example.ss" "$config/init.ss"
  echo "Wrote $config/init.ss, the plugins Tuna loads; edit it to choose others."
fi
echo "Run $HOME/.local/bin/tuna and open the address it prints in a browser."
