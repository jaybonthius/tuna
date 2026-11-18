#!/bin/sh
set -eu
tuna=${1:?usage: terminal-restart-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-terminal-restart-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
failures=0
fail() {
  echo "$0: FAIL: $1"
  failures=$((failures + 1))
}

home=$dir/home
mkdir -p "$home/.config/tuna/lib" "$dir/library" "$dir/work"
sh "$(dirname "$0")/../boot/copy-library.sh" "$(dirname "$tuna")/plugins" "$dir/library"
# No server starts: the web plugin is the transcripts' stand-in.
cp "$(dirname "$0")/terminal/home/.config/tuna/lib/web.sls" "$home/.config/tuna/lib/web.sls"
cat > "$home/.config/tuna/init.ss" <<'END'
(import (tuna) (tuna plugins) (document))
(use-plugin terminal
  (config
    (set-option! terminal:shell '("bash" "--norc" "--noprofile"))
    (set-option! terminal:environment '(("PS1" . "$ ") ("HISTFILE" . #f)))))
(define (contains? s part)
  (let ([n (string-length part)])
    (let loop ([i 0])
      (and (<= (+ i n) (string-length s))
           (or (string=? (substring s i (+ i n)) part) (loop (+ i 1)))))))
(define (wait-for b part)
  (let loop ([n 0])
    (unless (or (contains? (terminal:screen-text b) part) (= n 1000))
      (sleep-for 0.01)
      (loop (+ n 1)))))
(define (write-out name value)
  (with-output-to-file (string-append (getenv "HOME") "/" name) (lambda () (write value)) 'replace))
(cond
  [(file-exists? (string-append (getenv "HOME") "/first"))
   (let ([t (let find ([n 0])
              (or (buffers:find "*terminal*") (= n 1000) (begin (sleep-for 0.01) (find (+ n 1)))))])
     (wait-for t "\n$ ")
     (terminal:send! t "pwd\r")
     (wait-for t "\n/tmp\n$ ")
     (write-out "second"
       (list (terminal:terminal? t)
             (document:text (buffers:document t))
             (buffers:find "*sleep*"))))]
  [else
   (let ([t (terminal:start #f)])
     (terminal:start '("sleep" "30"))
     (wait-for t "$ ")
     (terminal:send! t "cd /tmp; seq 1 30\r")
     (wait-for t "\n30\n$ ")
     (write-out "first" #t))])
(exit)
END

run() {
  output=$(cd "$dir/work" && HOME="$home" TUNA_LIBRARY="$dir/library" timeout 60 "$tuna" < /dev/null 2>&1) ||
    fail "Tuna failed: $output"
  [ -z "$output" ] || fail "Tuna wrote: $output"
}

run
[ -f "$home/first" ] || fail "the first run did not finish"
# Tuna's quit ends the shell; at the next start the terminal comes back
# with its last screen and scrollback, a line saying the shell ended,
# and a new shell in its last folder. The command does not run again.
run
expected='(#t "$ cd /tmp; seq 1 30\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n21\n22\n23\n24\n25\n26\n27\n28\n29\n30\n$ \n[The shell ended.]\n$ pwd\n/tmp\n$ \n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n" #f)'
actual=$(cat "$home/second" 2>/dev/null || true)
[ "$actual" = "$expected" ] || fail "after a restart: $actual"
# Only the new shell's screen is kept; the others' files are deleted.
[ "$(ls "$home/.local/share/tuna/terminal/"*/ | wc -l)" -eq 1 ] || fail "screens of ended programs were kept"

echo "$0: $failures failures"
[ "$failures" -eq 0 ]
