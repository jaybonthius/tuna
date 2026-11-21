#!/bin/sh
# Views that view atoms name come back after a restart, numbered as
# before, with their cursors, scroll position, folds, narrowing and the
# plugin's own options; a view that no atom drew does not.
set -eu
tuna=${1:?usage: views-restart-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-views-restart-test.XXXXXX")
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
cat > "$home/.config/tuna/init.ss" <<'END'
(import (tuna) (tuna plugins) (document) (md))
(use-plugin views)
(define notes (buffers:make "notes" "one two\nthree four\nfive six\n"))
(define layout
  (buffers:make "*layout*" (md:doc '() (views:view '((view . 3) (buffer . "notes"))))))
(import (console))
END

run() {
  (cd "$dir/work" && printf '%s\n' "$1" | HOME="$home" TUNA_LIBRARY="$dir/library" "$tuna" 2>&1)
}

expect() {
  [ "$2" = "$3" ] || fail "$1: expected $(printf '%s' "$3" | tr '\n' '|'), got $(printf '%s' "$2" | tr '\n' '|')"
}

output=$(run "(define v (views:atom-view (document:token (buffers:document layout) 1)))
(define loose (views:make notes))
(views:id loose)
(views:set-point! v 12)
(views:set-mark! v 9)
(views:add-cursor! v 2)
(views:fold! v 18 22)
(views:narrow! v 1 25)
(views:scroll-to! v 9 (views:align top))
(views:set-option! v views:wrap-lines #f)")
expect "first run" "$output" "4
#<cursor>"

output=$(run "(define v (views:find 3))
(list (views:point v) (views:mark v) (map views:cursor-point (views:cursors v)) (views:top v #f))
(list (views:folded? v 20) (call-with-values (lambda () (views:bounds v)) list))
(views:with-view v (views:wrap-lines))
(views:find 4)
(views:id (views:make notes))")
expect "after a restart" "$output" "(12 9 (12 2) 9)
(#t (1 25))
#f
#f
5"

# Only views that atoms name by number are saved: the view of an atom
# without a number, and the copy for a second atom naming a drawn view,
# are made again at each start, so saving them would add views each time.
draw_atoms='(define chat
  (buffers:make "chat"
    (md:doc (quote ())
      (views:view (quote ((buffer . "notes"))))
      (views:view (quote ((view . 3) (buffer . "notes"))))
      (views:view (quote ((view . 3) (buffer . "notes")))))))
(views:draw (views:make chat) #f)'
count='(length (filter views:find (cdr (iota 40))))'
output=$(run "$count
$draw_atoms")
expect "saved views before drawing atoms" "$(printf '%s\n' "$output" | head -n 1)" 1
output=$(run "$count
$draw_atoms")
expect "saved views after drawing atoms" "$(printf '%s\n' "$output" | head -n 1)" 1
output=$(run "$count")
expect "saved views after drawing atoms twice" "$output" 1

echo "$0: $failures failures"
[ "$failures" -eq 0 ]
