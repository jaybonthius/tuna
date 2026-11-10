#!/bin/sh
set -eu
tuna=${1:?usage: run-transcript.sh TUNA TRANSCRIPT}
transcript=${2:?usage: run-transcript.sh TUNA TRANSCRIPT}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
folder=$(dirname "$transcript")
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-transcript.XXXXXX")
trap 'rm -rf "$dir"' EXIT

mkdir "$dir/home" "$dir/work" "$dir/library"
if [ -d "$folder/home" ]; then
  cp -R "$folder/home/." "$dir/home/"
fi
# Tuna's own library is the test's, so no transcript depends on what lies
# beside the executable.
if [ -d "$folder/library" ]; then
  cp -R "$folder/library/." "$dir/library/"
fi

: > "$dir/input"
: > "$dir/expected"
awk -v input="$dir/input" -v expected="$dir/expected" '
  /^;/ { next }
  /^> / { print substr($0, 3) > input; continuing = 1; next }
  continuing && /^[ \t]/ { print > input; next }
  { continuing = 0; print > expected }
' "$transcript"

# The working folder is empty, so nothing beside the test is found by a
# relative path.
status=0
(cd "$dir/work" && HOME="$dir/home" TUNA_LIBRARY="$dir/library" "$tuna" < "$dir/input" > "$dir/actual" 2>&1) || status=$?

# Each run has a fresh home folder, so a transcript writes its path as ~.
sed "s|$dir/home|~|g" "$dir/actual" > "$dir/shown"

if [ "$status" -ne 0 ]; then
  echo "$transcript: FAIL: exit status $status"
  cat "$dir/shown"
  exit 1
fi
if ! diff -u --label expected --label actual "$dir/expected" "$dir/shown"; then
  echo "$transcript: FAIL"
  exit 1
fi
echo "$transcript: ok"
