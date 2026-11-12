#!/bin/sh
set -eu
tuna=${1:?usage: kill-ring-restart-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-kill-ring-restart-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
failures=0
fail() {
  echo "$0: FAIL: $1"
  failures=$((failures + 1))
}

home=$dir/home
file=$home/.local/share/tuna/saved/tuna/kill-ring/texts.ss
mkdir -p "$home/.config/tuna" "$dir/library" "$dir/work"
cp -R plugins/. "$dir/library/"
cat > "$home/.config/tuna/init.ss" <<'END'
(import (tuna) (tuna plugins))
(use-plugin kill-ring)
(import (buffers) (console))
END

run() {
  (cd "$dir/work" && printf '%s\n' "$1" | HOME="$home" TUNA_LIBRARY="$dir/library" "$tuna" 2>&1)
}

expect() {
  [ "$2" = "$3" ] || fail "$1: expected $(printf '%s' "$3" | tr '\n' '|'), got $(printf '%s' "$2" | tr '\n' '|')"
}

# Exit writes the ring's text, the last kill's included; a piece goes as
# its text, and an entry with a piece over 4,096 characters stays out.
output=$(run '(define b (buffers:make "b" "Hello world\n"))
(kill-ring:push! (list "first"))
(kill-ring:push! (list "x" (make-string 4097 #\z)))
(kill-ring:push! (list (kill-ring:piece b 1 6) "two"))
(kill-ring:append! (list " there" "!"))
(kill-ring:push! (list "newest"))
(kill-ring:rotate! 3)')
expect "first run" "$output" '("first")'
expect "the saved text" "$(cat "$file")" '(("newest") ("Hello there" "two!") ("first"))'

# The next start rebuilds the ring from it, with the yank pointer at the
# newest entry.
output=$(run '(kill-ring:entries)
(kill-ring:current)
(kill-ring:rotate! 1)')
expect "after a restart" "$output" '(("newest") ("Hello there" "two!") ("first"))
("newest")
("Hello there" "two!")'

# Text that fails the check is set aside, and the ring starts empty.
printf '(("ok") (1))\n' > "$file"
output=$(run '(kill-ring:entries)')
expect "a stored value that fails its check" "$output" "! (kill-ring) define-saved: $file holds a value that fails its check; it is moved to $file.rejected
()"
[ -f "$file.rejected" ] || fail "the rejected text was not kept"

echo "$0: $failures failures"
[ "$failures" -eq 0 ]
