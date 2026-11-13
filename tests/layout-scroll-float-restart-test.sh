#!/bin/sh
set -eu
tuna=${1:?usage: layout-scroll-float-restart-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-layout-scroll-float-restart-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
failures=0
fail() {
  echo "$0: FAIL: $1"
  failures=$((failures + 1))
}

home=$dir/home
mkdir -p "$home/.config/tuna/lib" "$dir/work"
sh boot/copy-library.sh "$(dirname "$tuna")/plugins" "$dir/library"
cp tests/scroll-float/home/.config/tuna/lib/web.sls "$home/.config/tuna/lib/"
cat > "$home/.config/tuna/init.ss" <<'END'
(import (tuna) (tuna plugins) (document) (buffers))
(define notes (buffers:make "notes" "one\ntwo\nthree\n"))
(define other (buffers:make "other" "other\n"))
(use-plugin layout-split)
(use-plugin layout-scroll)
(use-plugin layout-float)
(define (tree) (car (document:datums (buffers:document layout:buffer))))
(define (popups) (car (document:datums (buffers:document layout:popups-buffer))))
(define (set-parts! . parts)
  (let ([n (document:length (buffers:document layout:buffer))])
    (buffers:replace! layout:buffer 1 (- n 1) (apply document:from-datum parts))
    (void)))
(import (console))
END

run() {
  (cd "$dir/work" && printf '%s\n' "$1" | HOME="$home" TUNA_LIBRARY="$dir/library" "$tuna" 2>&1)
}

expect() {
  [ "$2" = "$3" ] || fail "$1: expected $(printf '%s' "$3" | tr '\n' '|'), got $(printf '%s' "$2" | tr '\n' '|')"
}

# A strip and a float desktop come back as they were, with the selected
# view; popups and their places in the selection order do not.
output=$(run "(set-parts! (layout-scroll:container '() '#(views:view ((view . 3) (buffer . \"notes\"))) (layout-float:container '((size . 1/3)) '#(views:view ((view . 4) (buffer . \"other\"))) '#(views:view ((view . 5) (buffer . \"notes\") (place box 1/4 1/2))))))
(layout:select! (views:find 5))
(define p (layout-float:show-at! (views:find 3) 1 other 1/2 1/2))
(layout:select! p)
(length (cddr (caddr (popups))))
(views:id (layout:selected-view))")
expect "first run" "$output" '1
6'

output=$(run "(tree)
(popups)
(list (views:id (layout:selected-view)) (map views:id (layout:views)))")
expect "after a restart" "$output" '(layout:root () (layout-scroll:container () #(views:view ((view . 3) (buffer . "notes"))) (layout-float:container ((size . 1/3)) #(views:view ((view . 4) (buffer . "other"))) #(views:view ((view . 5) (buffer . "notes") (place box 1/4 1/2))))))
(layout:popups-root ())
(5 (3 4 5))'

echo "$0: $failures failures"
[ "$failures" -eq 0 ]
