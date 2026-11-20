#!/bin/sh
set -eu
tuna=${1:?usage: dired-restart-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-dired-restart-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
failures=0
fail() {
  echo "$0: FAIL: $1"
  failures=$((failures + 1))
}

home=$dir/home
mkdir -p "$home/.config/tuna/lib" "$dir/library" "$dir/work"
sh boot/copy-library.sh "$(dirname "$tuna")/plugins" "$dir/library"
cp -R tests/dired/home/.config/tuna/lib/. "$home/.config/tuna/lib/"
cat > "$home/.config/tuna/init.ss" <<'END'
(import (tuna) (tuna plugins) (document))
(use-plugin files)
(use-plugin command-line)
(use-plugin echo-area)
(use-plugin dired)
(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 1000))
      (sleep-for 0.01)
      (loop (+ n 1)))))
(define (listings)
  (list-sort string<? (map buffers:name (filter dired:folder (buffers:all)))))
(define (shown)
  (let* ([view (layout:selected-view)] [b (and view (views:buffer view))])
    (and b (buffers:name b))))
(import (console))
END
mkdir -p "$home/src/tuna" "$home/notes"
printf 'x\n' > "$home/src/tuna/a.txt"

run() {
  input=$1
  shift
  (cd "$dir/work" && printf '%s\n' "$input" | HOME="$home" TUNA_LIBRARY="$dir/library" "$tuna" "$@" 2>&1)
}

expect() {
  [ "$2" = "$3" ] || fail "$1: expected $(printf '%s' "$3" | tr '\n' '|'), got $(printf '%s' "$2" | tr '\n' '|')"
}

# A folder on the command line opens its listing, as C-x C-f on it does.
output=$(run '(wait-until (lambda () (equal? (shown) "~/src/tuna/")))
(shown)
(dired:visit "~/notes")
(listings)' "$home/src/tuna")
expect "first start" "$output" '"~/src/tuna/"
#<buffer ~/notes/>
("~/notes/" "~/src/tuna/")'

# A restart lists the open listings' folders again; one gone since is
# left out, and a message names it.
rm -r "$home/notes"
output=$(run '(wait-until (lambda () (equal? (listings) (list "~/src/tuna/"))))
(listings)
(echo-area:current-message)')
expect "restart" "$output" '("~/src/tuna/")
"Folder ~/notes/ no longer exists"'

[ "$failures" -eq 0 ] || exit 1
echo "$0: ok"
