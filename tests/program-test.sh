#!/bin/sh
set -eu
tuna=${1:?usage: program-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
failures=0
fail() {
  echo "$0: FAIL: $1"
  failures=$((failures + 1))
}

status=0
version=$("$tuna" --version) || status=$?
[ "$status" -eq 0 ] || fail "--version exited with status $status"
printf '%s\n' "$version" | grep -Eqx 'tuna [0-9]+\.[0-9]+\.[0-9]+' ||
  fail "--version printed: $version"

status=0
message=$(env -u HOME "$tuna" 2>&1 < /dev/null) || status=$?
[ "$status" -eq 1 ] || fail "no HOME exited with status $status, not 1"
[ "$message" = "tuna: HOME is not set" ] || fail "no HOME printed: $message"

dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-program-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT

# Tuna's own options are read only at the start of the command line;
# every other command line reaches the configuration and plugins.
mkdir -p "$dir/arguments/.config/tuna"
printf '(write (list (command-line-arguments) (cdr (command-line)) (string? (car (command-line)))))\n(exit)\n' \
  > "$dir/arguments/.config/tuna/init.ss"
for case in 'notes.org +12|(("notes.org" "+12") ("notes.org" "+12") #t)' \
            '--version x|(("--version" "x") ("--version" "x") #t)' \
            '--script|(("--script") ("--script") #t)' \
            'x --script y|(("x" "--script" "y") ("x" "--script" "y") #t)'; do
  arguments=${case%%|*}
  expected=${case#*|}
  status=0
  # The arguments are split on purpose.
  # shellcheck disable=SC2086
  output=$(HOME="$dir/arguments" "$tuna" $arguments 2>&1 < /dev/null) || status=$?
  [ "$status" -eq 0 ] || fail "tuna $arguments exited with status $status"
  [ "$output" = "$expected" ] || fail "tuna $arguments gave the configuration: $output"
done

# --script runs a Chez script as scheme --script does, loading no
# configuration, and exits with its status.
cat > "$dir/script.ss" <<'END'
(write (list (command-line) (command-line-arguments)))
(newline)
(when (equal? (command-line-arguments) '("exit")) (exit 3))
(when (equal? (command-line-arguments) '("raise")) (car '()))
END
status=0
output=$(cd "$dir" && HOME="$dir/arguments" "$tuna" --script script.ss a "b c" 2>&1 < /dev/null) || status=$?
[ "$status" -eq 0 ] || fail "--script exited with status $status, not 0"
[ "$output" = '(("script.ss" "a" "b c") ("a" "b c"))' ] || fail "--script printed: $output"
for case in exit:3 raise:255; do
  status=0
  (cd "$dir" && HOME="$dir/arguments" "$tuna" --script script.ss "${case%:*}" > /dev/null 2>&1 < /dev/null) ||
    status=$?
  [ "$status" -eq "${case#*:}" ] || fail "--script that ends by ${case%:*} exited with status $status"
done

# Without TUNA_LIBRARY, Tuna's own library is plugins/ beside the program,
# however the program is started, and holds the bundled plugins.
mkdir -p "$dir/bin/plugins" "$dir/home/.config/tuna"
cp "$tuna" "$dir/bin/tuna"
sh boot/copy-library.sh "$(dirname "$tuna")/plugins" "$dir/bin/plugins"
printf '(import (console))\n' > "$dir/home/.config/tuna/init.ss"
printf '#!tuna\n(define (where) "beside the program")\n' > "$dir/bin/plugins/own.sls"
ln -s "$dir/bin/tuna" "$dir/linked-tuna"
for program in "$dir/bin/tuna" "$dir/linked-tuna"; do
  output=$(echo '(import (own)) (own:where)' | env -u TUNA_LIBRARY HOME="$dir/home" "$program" 2>&1)
  [ "$output" = '"beside the program"' ] || fail "$program found Tuna's own library as: $output"
done

# Tuna's own names are never looked for in the working folder.
mkdir -p "$dir/work/tuna"
printf '(library (tuna extra) (export where) (import (chezscheme)) (define where "work"))\n' > "$dir/work/tuna/extra.sls"
output=$(cd "$dir/work" && echo "(import (tuna extra))" | env -u TUNA_LIBRARY HOME="$dir/home" "$dir/bin/tuna" 2>&1)
[ "$output" = '! library (tuna extra) not found' ] || fail "(tuna extra) from the working folder: $output"
[ ! -e "$dir/work/tuna/extra.so" ] || fail "(tuna extra) was compiled in the working folder"

# exit's status is the process's, whichever thread calls it, even when
# the console's end of input comes while the modules unload.
mkdir -p "$dir/slow/.config/tuna"
printf '(import (tuna))\n(import (rename (only (chezscheme) sleep) (sleep chez:sleep)))\n(on-unload (lambda () (chez:sleep (make-time (quote time-duration) 100000000 0))))\n(import (console))\n' \
  > "$dir/slow/.config/tuna/init.ss"
for form in '(exit 4)' '(thread-join (fork-thread (lambda () (exit 4))))'; do
  status=0
  echo "$form" | HOME="$dir/slow" "$tuna" > /dev/null 2>&1 || status=$?
  [ "$status" -eq 4 ] || fail "$form exited with status $status, not 4"
done

# The main thread writes and exits while the console waits for input.
mkdir -p "$dir/waiting/.config/tuna"
cat > "$dir/waiting/.config/tuna/init.ss" <<'END'
(import (tuna))
(import (rename (only (chezscheme) sleep) (sleep chez:sleep)))
(fork-thread
  (lambda ()
    (chez:sleep (make-time 'time-duration 200000000 0))
    (post! (lambda () (display "posted") (newline)))
    (chez:sleep (make-time 'time-duration 300000000 0))
    (exit 5)))
(import (console))
END
mkfifo "$dir/input"
sleep 5 > "$dir/input" &
writer=$!
start=$(date +%s%N)
status=0
output=$(HOME="$dir/waiting" "$tuna" < "$dir/input" 2>&1) || status=$?
elapsed=$(( ($(date +%s%N) - start) / 1000000 ))
kill "$writer"
[ "$status" -eq 5 ] || fail "exit while the console waits exited with status $status, not 5"
[ "$output" = posted ] || fail "a write while the console waits printed: $output"
[ "$elapsed" -lt 3000 ] || fail "exit while the console waits took $elapsed ms"

# Tuna reads no standard input: with no configuration it runs until a
# signal ends it, and a configuration without the console ends with exit.
mkdir -p "$dir/empty" "$dir/batch/.config/tuna"
printf '(exit 6)\n' > "$dir/forms"
HOME="$dir/empty" "$tuna" < "$dir/forms" > "$dir/empty-output" 2>&1 &
idle=$!
sleep 0.5
if kill -0 "$idle" 2> /dev/null; then
  kill "$idle"
  status=0
  wait "$idle" || status=$?
  [ "$status" -eq 143 ] || fail "with no configuration, SIGTERM gave status $status"
else
  fail "with no configuration, Tuna ended by itself"
fi
[ ! -s "$dir/empty-output" ] || fail "with no configuration, Tuna printed: $(cat "$dir/empty-output")"
printf '(display "done")\n(exit 7)\n' > "$dir/batch/.config/tuna/init.ss"
status=0
output=$(HOME="$dir/batch" "$tuna" < "$dir/forms" 2>&1) || status=$?
[ "$status" -eq 7 ] || fail "a configuration ending in (exit 7) exited with status $status"
[ "$output" = done ] || fail "a configuration ending in exit printed: $output"

echo "$0: $failures failures"
[ "$failures" -eq 0 ]
