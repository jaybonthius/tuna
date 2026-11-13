#!/bin/sh
# The layout and the frame come back after a restart, with each view's
# cursor; a saved layout that its check refuses is set aside with a
# warning and the default used; with no buffer at all, the default shows
# a new *scratch*.
set -eu
tuna=${1:?usage: layout-restart-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-layout-restart-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
failures=0
fail() {
  echo "$0: FAIL: $1"
  failures=$((failures + 1))
}

home=$dir/home
mkdir -p "$home/.config/tuna/lib" "$dir/work"
sh boot/copy-library.sh "$(dirname "$tuna")/plugins" "$dir/library"
cp tests/layout/home/.config/tuna/lib/web.sls "$home/.config/tuna/lib/"
cat > "$home/.config/tuna/init.ss" <<'END'
(import (tuna) (tuna plugins) (document) (buffers))
(define notes (if (getenv "NO_BUFFERS") #f (buffers:make "notes" "one\ntwo\nthree\n")))
(use-plugin layout-split)
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
(views:set-point! (views:find 2) 5)
(layout:select! (views:find 2))
(commands:run layout:zoom)
(tree)")
expect "first run" "$output" '#<view 2>
(layout:root () (layout-split:container ((direction . row)) #(views:view ((view . 1) (buffer . "notes"))) #(views:view ((view . 2) (buffer . "notes")))))'

output=$(run "(tree)
(list (views:id (layout:selected-view)) (map views:id (layout:views)) (views:point (views:find 2)))")
expect "after a restart" "$output" '(layout:root () (layout-split:container ((direction . row)) #(views:view ((view . 1) (buffer . "notes"))) #(views:view ((view . 2) (buffer . "notes")))))
(2 (2) 5)'

saved=$home/.local/share/tuna/saved/tuna/layout/saved-layout.ss
[ -f "$saved" ] || fail "no saved layout at $saved"
echo '(layout:root () #(views:view ((view . 1) (buffer . "notes") (locked . #t))))' > "$saved"
output=$(run "(tree)")
expect "a layout with no view that is not locked" "$(printf '%s\n' "$output" | sed 's/ at .*rejected//' | tail -n 1)" \
  '(layout:root () #(views:view ((view . 3) (buffer . "notes"))))'
printf '%s\n' "$output" | grep -q 'saved-layout.ss' || fail "no warning names the set-aside file: $output"
[ -f "$saved.rejected" ] || fail "the refused layout was not set aside"

echo '(layout:root () (layout-split:container ((direction . row)) "text"))' > "$saved"
output=$(run "(tree)")
expect "a layout holding text" "$(printf '%s\n' "$output" | tail -n 1)" \
  '(layout:root () #(views:view ((view . 4) (buffer . "notes"))))'

echo '(layout:root () (layout-split:container ((direction . row)) #(views:view ((view . 1) (buffer . "notes"))) #(views:view ((view . 1) (buffer . "notes")))))' > "$saved"
output=$(run "(tree)")
expect "a layout naming a view twice" "$(printf '%s\n' "$output" | tail -n 1)" \
  '(layout:root () #(views:view ((view . 5) (buffer . "notes"))))'

rm -rf "$home/.local"
output=$(NO_BUFFERS=1 run "(tree)
(map buffers:name (buffers:all))")
expect "no buffer" "$output" '(layout:root () #(views:view ((view . 1) (buffer . "*scratch*"))))
("*scratch*" "*layout*")'

echo "$0: $failures failures"
[ "$failures" -eq 0 ]
