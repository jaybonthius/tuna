#!/bin/sh
set -eu
tuna=${1:?usage: layout-tabs-restart-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-layout-tabs-restart-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
failures=0
fail() {
  echo "$0: FAIL: $1"
  failures=$((failures + 1))
}

home=$dir/home
mkdir -p "$home/.config/tuna/lib" "$dir/work"
sh tests/test-home.sh "$tuna" "$dir/library" "$home"
cp tests/layout/home/.config/tuna/lib/web.sls "$home/.config/tuna/lib/"
cat > "$home/.config/tuna/init.ss" <<'END'
(import (tuna) (tuna plugins) (document) (buffers))
(define notes (buffers:make "notes" "one\ntwo\nthree\n"))
(define other (buffers:make "other" "other\n"))
(use-plugin layout-split)
(use-plugin layout-tabs)
(define (tree) (car (document:datums (buffers:document layout:buffer))))
(import (console))
END

run() {
  (cd "$dir/work" && printf '%s\n' "$1" | HOME="$home" TUNA_LIBRARY="$dir/library" "$tuna" 2>&1)
}

expect() {
  [ "$2" = "$3" ] || fail "$1: expected $(printf '%s' "$3" | tr '\n' '|'), got $(printf '%s' "$2" | tr '\n' '|')"
}

output=$(run "(layout-split:split-view! (layout:selected-view) (layout-split:direction row))
(layout:select! (layout-tabs:add-tab! (views:find 3) other))
(layout-tabs:add-tab! (views:find 4) notes)
(layout:select! (views:find 1))
(tree)
(map views:id (layout:views))")
expect "first run" "$output" '#<view 3>
#<view 5>
(layout:level () (layout-split:container ((direction . row)) #(views:view ((view . 1) (buffer . "notes"))) (layout-tabs:container () #(views:view ((view . 3) (buffer . "notes"))) #(views:view ((view . 4) (buffer . "other"))) #(views:view ((view . 5) (buffer . "notes"))))))
(1 4)'

output=$(run "(tree)
(list (views:id (layout:selected-view)) (map views:id (layout:views)))")
expect "after a restart" "$output" '(layout:level () (layout-split:container ((direction . row)) #(views:view ((view . 1) (buffer . "notes"))) (layout-tabs:container () #(views:view ((view . 3) (buffer . "notes"))) #(views:view ((view . 4) (buffer . "other"))) #(views:view ((view . 5) (buffer . "notes"))))))
(1 (1 4))'

echo "$0: $failures failures"
[ "$failures" -eq 0 ]
