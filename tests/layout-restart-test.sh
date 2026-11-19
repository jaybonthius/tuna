#!/bin/sh
# The layout, the selection order and the zoom come back after a
# restart, with each view's cursor; a saved layout that its check
# refuses is set aside with a warning and the default used; with no
# buffer at all, the default shows a new *scratch*.
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
(when (getenv "INTERNAL_BUFFER") (buffers:make " *internal*" "x\n"))
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
(views:set-point! (views:find 3) 5)
(layout:select! (views:find 3))
(commands:run layout:zoom)
(tree)")
expect "first run" "$output" '#<view 3>
(layout:level () (layout-split:container ((direction . row)) #(views:view ((view . 1) (buffer . "notes"))) #(views:view ((view . 3) (buffer . "notes")))))'

output=$(run "(tree)
(list (views:id (layout:selected-view)) (map views:id (layout:views)) (views:point (views:find 3)))")
expect "after a restart" "$output" '(layout:level () (layout-split:container ((direction . row)) #(views:view ((view . 1) (buffer . "notes"))) #(views:view ((view . 3) (buffer . "notes")))))
(3 (3) 5)'

# The zoom is saved as the view's number and how far out its level is.
selection=$home/.local/share/tuna/saved/tuna/layout/saved-selection.ss
expect "the saved selection" "$(cat "$selection")" '((3 1) (3 . 1))'

saved=$home/.local/share/tuna/saved/tuna/layout/saved-layout.ss
[ -f "$saved" ] || fail "no saved layout at $saved"
echo '(layout:level () #(views:view ((view . 1) (buffer . "notes") (locked . #t))))' > "$saved"
output=$(run "(tree)")
expect "a layout with no view that is not locked" "$(printf '%s\n' "$output" | sed 's/ at .*rejected//' | tail -n 1)" \
  '(layout:level () #(views:view ((view . 5) (buffer . "notes"))))'
printf '%s\n' "$output" | grep -q 'saved-layout.ss' || fail "no warning names the set-aside file: $output"
[ -f "$saved.rejected" ] || fail "the refused layout was not set aside"

echo '(layout:level () (layout:level () #(views:view ((view . 1) (buffer . "notes")))))' > "$saved"
output=$(run "(tree)")
expect "a level holding a level" "$(printf '%s\n' "$output" | tail -n 1)" \
  '(layout:level () #(views:view ((view . 7) (buffer . "notes"))))'

echo '(layout:level () (layout-split:container ((direction . row)) "text"))' > "$saved"
output=$(run "(tree)")
expect "a layout holding text" "$(printf '%s\n' "$output" | tail -n 1)" \
  '(layout:level () #(views:view ((view . 9) (buffer . "notes"))))'

echo '(layout:level () (layout-split:container ((direction . row)) #(views:view ((view . 1) (buffer . "notes"))) #(views:view ((view . 1) (buffer . "notes")))))' > "$saved"
output=$(run "(tree)")
expect "a layout naming a view twice" "$(printf '%s\n' "$output" | tail -n 1)" \
  '(layout:level () #(views:view ((view . 11) (buffer . "notes"))))'

rm -rf "$home/.local"
output=$(NO_BUFFERS=1 run "(tree)
(map buffers:name (buffers:all))")
expect "no buffer" "$output" '(layout:level () #(views:view ((view . 1) (buffer . "*scratch*"))))
("*scratch*" " *layout*" " *popups*")'

rm -rf "$home/.local"
output=$(NO_BUFFERS=1 INTERNAL_BUFFER=1 run "(tree)
(map buffers:name (buffers:all))")
expect "only an internal buffer" "$output" '(layout:level () #(views:view ((view . 1) (buffer . "*scratch*"))))
(" *internal*" "*scratch*" " *layout*" " *popups*")'

echo "$0: $failures failures"
[ "$failures" -eq 0 ]
