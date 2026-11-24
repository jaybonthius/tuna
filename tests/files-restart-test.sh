#!/bin/sh
set -eu
tuna=${1:?usage: files-restart-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-files-restart-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
failures=0
fail() {
  echo "$0: FAIL: $1"
  failures=$((failures + 1))
}

home=$dir/home
mkdir -p "$home/.config/tuna/lib" "$dir/library" "$dir/work"
sh tests/test-home.sh "$tuna" "$dir/library" "$home"
cp -R tests/files/home/.config/tuna/lib/. "$home/.config/tuna/lib/"
cat > "$home/.config/tuna/init.ss" <<'END'
(import (tuna) (tuna plugins) (document))
;; ask's own writer prints each message, which the checks would read as
;; a result.
(use-plugin ask
  (config
    (set-option! ask:message-writer (lambda (text) (void)))))
(use-plugin files)
(use-plugin command-line)
(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 1000))
      (sleep-for 0.01)
      (loop (+ n 1)))))
(define (shown)
  (let* ([view (layout:selected-view)] [b (and view (views:buffer view))])
    (and b (list (buffers:name b) (document:line (buffers:document b) (views:point view))))))
(define (showing? name)
  (let ([s (shown)]) (and s (string=? (car s) name))))
(import (console))
END
printf 'one\ntwo\nthree\n' > "$dir/work/a.txt"
printf 'alpha\nbeta\ngamma\ndelta\n' > "$dir/work/b.txt"

run() {
  input=$1
  shift
  (cd "$dir/work" && printf '%s\n' "$input" | HOME="$home" TUNA_LIBRARY="$dir/library" "$tuna" "$@" 2>&1)
}

expect() {
  [ "$2" = "$3" ] || fail "$1: expected $(printf '%s' "$3" | tr '\n' '|'), got $(printf '%s' "$2" | tr '\n' '|')"
}

# The command line's files are visited, and the last is shown at +N; a
# flag, which starts with --, is not a file.
output=$(run '(wait-until (lambda () (showing? "b.txt")))
(map buffers:name (files:buffers))
(shown)
(buffers:replace! (files:buffer-visiting "b.txt") 1 1 "unsaved ")' --eval='(void)' a.txt +3 --other b.txt)
expect "first start" "$output" '! (command-line) unknown flag --other; the only flag is --eval=EXPR
("a.txt" "b.txt")
("b.txt" 3)
#<edit 1>'

# A restart visits the files that were open, and the command line again
# only if one is given, and the layout's view comes back. Without undo,
# the unsaved edit is gone, but the view keeps the point it had after
# that edit.
output=$(run '(wait-until (lambda () (and (= (length (files:buffers)) 2) (showing? "b.txt"))))
(map buffers:name (files:buffers))
(shown)
(document:text (buffers:document (files:buffer-visiting "b.txt")))')
expect "restart" "$output" '("a.txt" "b.txt")
("b.txt" 4)
"alpha\nbeta\ngamma\ndelta\n"'

# C-x C-c exits without asking when no edits would be lost, with the
# open files kept for the next start. A missing file is an empty buffer
# of one line, so +2 goes to line 1. The files reopened and those on the
# command line are read side by side, so their order is not fixed.
output=$(run '(wait-until (lambda () (showing? "c.txt")))
(shown)
(commands:run (table-ref keys:global "C-x C-c"))
(display "not reached")' +2 c.txt)
expect "quit command" "$output" '("c.txt" 1)'
output=$(run '(wait-until (lambda () (= (length (files:buffers)) 3)))
(list-sort string<? (map buffers:name (files:buffers)))')
expect "after the quit command" "$output" '("a.txt" "b.txt" "c.txt")'

[ "$failures" -eq 0 ] || exit 1
echo "$0: ok"
