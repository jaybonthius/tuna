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
mkdir -p "$home/.config/tuna/lib" "$dir/library" "$dir/work"
sh boot/copy-library.sh "$(dirname "$tuna")/plugins" "$dir/library"
cp tests/web/home/.config/tuna/lib/http.sls "$home/.config/tuna/lib/"
# The web line comes first, so the server's start waiting for the
# command line's settings does not rest on the order of the lines.
cat > "$home/.config/tuna/init.ss" <<'END'
(import (tuna) (tuna plugins) (http))
(use-plugin web
  (config
    (let ([port (http:free-port)])
      (printf "configured ~a\n" port)
      (set-option! web:port port))))
(use-plugin command-line)
(import (layout) (views) (buffers) (document) (files))
(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 1000))
      (sleep-for 0.01)
      (loop (+ n 1)))))
(define (shown)
  (let* ([view (layout:selected-view)] [b (views:buffer view)])
    (and b (list (buffers:name b) (document:line (buffers:document b) (views:point view))))))
(define (showing? name)
  (let ([s (shown)]) (and s (string=? (car s) name))))
(import (console))
END
printf 'one\ntwo\nthree\n' > "$dir/work/a.txt"
printf 'alpha\nbeta\ngamma\ndelta\n' > "$dir/work/b.txt"
printf '1\n2\n3\n' > "$dir/work/e.txt"
printf 'one\ntwo\nthree\nfour\n' > "$dir/work/f.txt"
mkdir "$home/folder"
for i in $(seq 300); do echo "line $i"; done > "$dir/work/g.txt"
for i in $(seq 300); do echo "row $i"; done > "$dir/work/h.txt"

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
# --eval is reported and the rest run; any other flag is reported. A
# reload of the plugin in the same process evaluates nothing again. Each
# port is one the system chose, so the configuration and the flag print
# theirs.
output=$(run '(web:port)
(import (tuna eval))
(eval-file "~/.config/tuna/init.ss")
(web:port)
(eval-file (string-append (getenv "TUNA_LIBRARY") "/command-line.sls"))
(display "reloaded\n")' --eval='(let ([port (http:free-port)]) (printf "flag ~a\n" port) (set-option! web:port port))' \
  --eval='(set-option! web:prot 1)' --evl=1 --eval='(display "third\n")')
port=$(printf '%s\n' "$output" | sed -n 's/^flag \([0-9]*\)$/\1/p')
expect "flags" "$(printf '%s\n' "$output" | sed 's/^configured [0-9]*$/configured/')" "configured
flag $port
! (command-line) variable web:prot is not bound
! (command-line) unknown flag --evl=1; the only flag is --eval=EXPR
third
Tuna is at http://127.0.0.1:$port/
$port
configured
$port
reloaded"

# Without --eval the configuration's setting is in effect.
output=$(run '(web:port)')
port=$(printf '%s\n' "$output" | sed -n 's/^configured \([0-9]*\)$/\1/p')
expect "no flags" "$output" "configured $port
Tuna is at http://127.0.0.1:$port/
$port"

# Every other argument is a file, visited in order with the --evals
# around it; the last is shown, at line N after +N, and a +N before
# another file is dropped. A reload of files and of the plugin opens no
# argument again, so a file killed since stays closed.
output=$(run '(wait-until (lambda () (showing? "b.txt")))
(shown)
(buffers:kill! (files:buffer-visiting "a.txt"))
(import (tuna eval))
(eval-file (string-append (getenv "TUNA_LIBRARY") "/files.sls"))
(eval-file (string-append (getenv "TUNA_LIBRARY") "/command-line.sls"))
(sleep-for 0.5)
(map buffers:name (files:buffers))
(shown)' +3 a.txt --eval='(write (map buffers:name (files:buffers)))' +2 b.txt)
expect "files" "$(printf '%s\n' "$output" | grep -v '^configured \|^Tuna is at ')" '("a.txt")
("b.txt" 2)
#t
("b.txt")
("b.txt" 2)'

# A file that cannot be visited is reported and skipped, and a +N after
# the last file moves nothing.
output=$(run '(wait-until (lambda () (showing? "f.txt")))
(shown)
(buffers:name (files:buffer-visiting "e.txt"))' +2 e.txt +3 f.txt '~/folder' +9)
expect "a folder" "$(printf '%s\n' "$output" | grep -v '^configured \|^Tuna is at ')" "! (command-line) files:read-document: is a folder with irritant \"$home/folder\"
(\"f.txt\" 3)
\"e.txt\""

# +N past the last line goes to the last line.
output=$(run '(wait-until (lambda () (showing? "f.txt")))
(shown)' +99 f.txt)
expect "past the last line" "$(printf '%s\n' "$output" | grep -v '^configured \|^Tuna is at ')" '("f.txt" 5)'

# Without +N, the file shown starts at its start, point and view, even
# where the view last showed another file at its end.
run '(let ([v (layout:selected-view)] [g (files:visit "g.txt")])
  (layout:switch-to-buffer g)
  (views:set-point! v (document:length (buffers:document g)))
  (views:scroll-to! v (views:point v) (views:align bottom)))' > /dev/null
output=$(run '(wait-until (lambda () (showing? "h.txt")))
(let* ([v (layout:selected-view)] [doc (buffers:document (views:buffer v))])
  (list (document:line doc (views:point v)) (document:line doc (views:top v))))' g.txt h.txt)
expect "from its start" "$(printf '%s\n' "$output" | grep -v '^configured \|^Tuna is at ')" '(1 1)'

[ "$failures" -eq 0 ] || exit 1
echo "$0: ok"
