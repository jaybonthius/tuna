#!/bin/sh
set -eu
tuna=${1:?usage: undo-log-restart-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-undo-log-restart-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
failures=0
fail() {
  echo "$0: FAIL: $1"
  failures=$((failures + 1))
}

home=$dir/home
mkdir -p "$home/.config/tuna/lib" "$dir/library" "$dir/work"
sh boot/copy-library.sh "$(dirname "$tuna")/plugins" "$dir/library"
cp tests/undo-log/home/.config/tuna/lib/web.sls "$home/.config/tuna/lib/"
cat > "$home/.config/tuna/init.ss" <<'END'
(import (tuna) (tuna plugins) (document))
(use-plugin undo-log
  (config
    (set-option! undo-log:keep-log? (lambda (path) #t))))
(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 1000))
      (sleep-for 0.01)
      (loop (+ n 1)))))
(define (shown)
  (let* ([view (layout:selected-view)] [b (and view (views:buffer view))])
    (and b (let ([doc (buffers:document b)] [point (views:point view)])
             (list (buffers:name b) (document:line doc point)
                   (document:text doc point (min (+ point 5) (document:length doc))))))))
(define (showing? name)
  (let ([s (shown)]) (and s (string=? (car s) name))))
(define (b) (files:buffer-visiting "b.txt"))
(define (text) (document:text (buffers:document (b))))
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

# An edit, then exit at once: exit waits for the log's last write.
output=$(run '(wait-until (lambda () (showing? "b.txt")))
(shown)
(buffers:replace! (b) 1 1 "unsaved ")
(shown)' a.txt +3 b.txt)
expect "first start" "$output" '("b.txt" 3 "gamma")
#<edit 1>
("b.txt" 3 "gamma")'

# A restart visits b.txt again with the unsaved edit in, before the view
# binds its cursor, so the view shows the text it was on.
output=$(run '(wait-until (lambda () (and (= (length (files:buffers)) 2) (showing? "b.txt"))))
(shown)
(list (text) (buffers:modified? (b)))
(buffers:with-buffer (b) (commands:run undo:undo 1))
(list (text) (buffers:modified? (b)))
(commands:run files:save-buffers-kill-tuna)')
expect "restart" "$output" '("b.txt" 3 "gamma")
("unsaved alpha\nbeta\ngamma\ndelta\n" #t)
("alpha\nbeta\ngamma\ndelta\n" #f)'

# Undone to the file's text before exit: the next start opens the file as
# it is, with the edit a redo away.
output=$(run '(wait-until (lambda () (and (= (length (files:buffers)) 2) (showing? "b.txt"))))
(list (text) (buffers:modified? (b)))
(buffers:with-buffer (b) (commands:run undo:redo 1))
(list (text) (buffers:modified? (b)))')
expect "after the quit command" "$output" '("alpha\nbeta\ngamma\ndelta\n" #f)
("unsaved alpha\nbeta\ngamma\ndelta\n" #t)'

# The quit command exits without asking about a modified buffer whose
# log holds its edits; no reader of yes or no is loaded, so a question
# would raise. The next start has the edit back.
output=$(run '(wait-until (lambda () (showing? "b.txt")))
(list (text) (buffers:modified? (b)))
(commands:run files:save-buffers-kill-tuna)')
expect "quit with a logged edit" "$output" '("unsaved alpha\nbeta\ngamma\ndelta\n" #t)'
output=$(run '(wait-until (lambda () (and (= (length (files:buffers)) 2) (showing? "b.txt"))))
(list (text) (buffers:modified? (b)))')
expect "after quitting with a logged edit" "$output" '("unsaved alpha\nbeta\ngamma\ndelta\n" #t)'

# Exit waits for the writer even after many batches.
output=$(run '(wait-until (lambda () (showing? "b.txt")))
(do ([i 0 (+ i 1)]) ((= i 200)) (buffers:replace! (b) 1 1 "x") (sleep-for 0))
(string-length (text))')
expect "many batches" "$output" '231'
output=$(run '(wait-until (lambda () (showing? "b.txt")))
(list (string-length (text)) (length (undo:history (b))))')
expect "after many batches" "$output" '(231 204)'

# After undo:forget! the log holds no saved state to rebuild the edits
# from, so the quit command asks before it exits.
output=$(run '(wait-until (lambda () (showing? "b.txt")))
(undo:forget! (b))
(buffers:replace! (b) 1 1 "y")
(set-option! ask:yes-or-no-reader (lambda (question) (display question) (newline) #t))
(commands:run files:save-buffers-kill-tuna)')
expect "quit after forgetting" "$output" '#<edit 1>
Modified buffers exist; exit anyway? '

[ "$failures" -eq 0 ] || exit 1
echo "$0: ok"
