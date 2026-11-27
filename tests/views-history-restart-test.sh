#!/bin/sh
# A saved view's buffer history and the buffers' last points outlast a
# restart: an entry and a last point wait for a buffer of their name, so
# a file reopened from the saved visits opens where it was left, until
# the first idle, when those still waiting go.
set -eu
tuna=${1:?usage: views-history-restart-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-views-history-restart-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
failures=0
fail() {
  echo "$0: FAIL: $1"
  failures=$((failures + 1))
}

home=$dir/home
mkdir -p "$home/.config/tuna/lib" "$dir/library" "$dir/work"
cp -R plugins/. "$dir/library/"
cp tests/views/home/.config/tuna/lib/web.sls \
   tests/views/home/.config/tuna/lib/md.sls "$home/.config/tuna/lib/"
printf 'one\ntwo\nthree\n' > "$home/a.txt"
cat > "$home/.config/tuna/init.ss" <<'END'
(import (tuna) (document) (md))
(use-plugin views)
(use-plugin files)
(define notes (buffers:make "notes" "one two\nthree four\nfive six\n"))
(define layout
  (buffers:make "*layout*" (md:doc '() (views:view '((view . 3) (buffer . "notes"))))))
(define (names bs) (map buffers:name bs))
(import (console))
END

run() {
  (cd "$dir/work" && printf '%s\n' "$1" | HOME="$home" TUNA_LIBRARY="$dir/library" "$tuna" 2>&1)
}

expect() {
  [ "$2" = "$3" ] || fail "$1: expected $(printf '%s' "$3" | tr '\n' '|'), got $(printf '%s' "$2" | tr '\n' '|')"
}

output=$(run '(define v (views:atom-view (document:token (buffers:document layout) 1)))
(views:set-point! v 12)
(define late (buffers:make "late" "late\n"))
(views:set-buffer! v late)
(views:set-point! v 3)
(define file (files:visit "~/a.txt"))
(define x (views:make file))
(views:set-point! x 9)
(views:drop! x)
(names (views:previous-buffers v))')
expect "first run" "$output" '("notes")'

output=$(run '(define v (views:atom-view (document:token (buffers:document layout) 1)))
(views:buffer v)
(names (views:previous-buffers v))
(define late (buffers:make "late" "late\n"))
(list (buffers:name (views:buffer v)) (views:point v))
(views:set-buffer! v notes)
(list (views:point v) (names (views:previous-buffers v)))
(define file (files:visit "~/a.txt"))
(views:last-point file)
(let ([y (views:make notes)]) (views:set-buffer! y file) (views:point y))')
expect "after a restart" "$output" '#f
("notes")
("late" 3)
(12 ("late"))
9
9'

# The histories are written when Tuna idles and when views unloads, not
# after every batch as the views are.
output=$(run '(define v (views:atom-view (document:token (buffers:document layout) 1)))
(define f (string-append (getenv "HOME") "/.local/share/tuna/saved/tuna/views/histories.ss"))
(define (text) (call-with-input-file f get-string-all))
(define before (text))
(define late (buffers:make "late" "late\n"))
(views:set-buffer! v late)
(string=? before (text))
(timers:set-idle! #t)
(timers:sleep 1.5)
(timers:set-idle! #f)
(timers:sleep 0.3)
(string=? before (text))')
expect "written at idle" "$output" '#t
#f'

# A start makes its buffers again before it first idles; an entry or a
# last point whose buffer no start makes again goes then, so the saved
# histories hold no buffer that is gone after two restarts.
histories=$home/.local/share/tuna/saved/tuna/views/histories.ss
output=$(run '(define v (views:atom-view (document:token (buffers:document layout) 1)))
(define gone (buffers:make "*gone*<7>" "gone\n"))
(views:set-buffer! v gone)
(views:set-point! v 3)
(views:set-buffer! v notes)
(names (views:previous-buffers v))')
expect "a run that shows a buffer no start makes" "$output" '("*gone*<7>")'
grep -q 'gone' "$histories" || fail "the gone buffer is not saved at exit"
for restart in 1 2; do
  output=$(run '(define v (views:atom-view (document:token (buffers:document layout) 1)))
(timers:set-idle! #t)
(timers:sleep 1.5)
(timers:set-idle! #f)
(names (views:previous-buffers v))')
  expect "restart $restart without it" "$output" '()'
  if grep -q 'gone' "$histories"; then fail "restart $restart: the gone buffer is still saved"; fi
done

echo "$0: $failures failures"
[ "$failures" -eq 0 ]
