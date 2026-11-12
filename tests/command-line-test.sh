#!/bin/sh
set -eu
tuna=${1:?usage: command-line-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-command-line-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
failures=0
fail() {
  echo "$0: FAIL: $1"
  failures=$((failures + 1))
}

home=$dir/home
mkdir -p "$home/.config/tuna" "$dir/library" "$dir/work"
sh boot/copy-library.sh "$(dirname "$tuna")/plugins" "$dir/library"
# The web line comes first, so the server's start waiting for the
# command line's settings does not rest on the order of the lines.
cat > "$home/.config/tuna/init.ss" <<'END'
(import (tuna) (tuna plugins))
(use-plugin web
  (config
    (set-option! web:port 19341)))
(use-plugin command-line)
(import (console))
END

run() {
  input=$1
  shift
  (cd "$dir/work" && printf '%s\n' "$input" | HOME="$home" TUNA_LIBRARY="$dir/library" "$tuna" "$@" 2>&1)
}

expect() {
  [ "$2" = "$3" ] || fail "$1: expected $(printf '%s' "$3" | tr '\n' '|'), got $(printf '%s' "$2" | tr '\n' '|')"
}

# Each --eval runs in order, at the REPL, so its setting wins over the
# configuration's, and the server starts once, on its port. A failing
# --eval is reported and the rest run; any other flag is reported, and an
# argument that is not a flag is left to other plugins. A reload of the
# plugin in the same process evaluates nothing again.
output=$(run '(web:port)
(import (tuna eval))
(eval-file "~/.config/tuna/init.ss")
(web:port)
(eval-file (string-append (getenv "TUNA_LIBRARY") "/command-line.sls"))
(display "reloaded\n")' --eval='(set-option! web:port 19342)' --eval='(set-option! web:prot 1)' --evl=1 \
  notes.txt --eval='(display "third\n")')
expect "flags" "$output" '! (command-line) variable web:prot is not bound
! (command-line) unknown flag --evl=1; the only flag is --eval=EXPR
third
Tuna is at http://127.0.0.1:19342/
19342
19342
reloaded'

# Without --eval the configuration's setting is in effect.
output=$(run '(web:port)')
expect "no flags" "$output" 'Tuna is at http://127.0.0.1:19341/
19341'

[ "$failures" -eq 0 ] || exit 1
echo "$0: ok"
