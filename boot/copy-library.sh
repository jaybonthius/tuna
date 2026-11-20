#!/bin/sh
# A submodule's checkout and the folder a plugin's build wrote are large,
# and neither tests nor builds change them, so a copy of a library links
# to them. Any other link is followed: one relative to the source tree
# would lead nowhere from the copy.
set -eu
from=${1:?usage: copy-library.sh FROM TO}
to=${2:?usage: copy-library.sh FROM TO}
case $from in
  /*) ;;
  *) from=$PWD/$from ;;
esac
mkdir -p "$to"
for entry in "$from"/*; do
  [ -e "$entry" ] || continue
  name=$(basename "$entry")
  if [ -e "$entry/.git" ]; then
    ln -s "$entry" "$to/$name"
  elif [ -d "$entry" ]; then
    mkdir "$to/$name"
    for part in "$entry"/*; do
      [ -e "$part" ] || [ -L "$part" ] || continue
      if [ -e "$part/.git" ] || { [ "$(basename "$part")" = build ] && [ -d "$part" ]; }; then
        ln -s "$part" "$to/$name/$(basename "$part")"
      else
        cp -RL "$part" "$to/$name/"
      fi
    done
  else
    cp -R "$entry" "$to/"
  fi
done
