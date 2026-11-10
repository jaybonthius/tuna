#!/bin/sh
set -eu
tuna=${1:?usage: program-test.sh TUNA}
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
usage=$("$tuna" --unknown 2>&1 > /dev/null) || status=$?
[ "$status" -eq 2 ] || fail "unknown arguments exited with status $status, not 2"
case $usage in
  *usage:*) ;;
  *) fail "unknown arguments printed no usage: $usage" ;;
esac

status=0
message=$(env -u HOME "$tuna" 2>&1 < /dev/null) || status=$?
[ "$status" -eq 1 ] || fail "no HOME exited with status $status, not 1"
[ "$message" = "tuna: HOME is not set" ] || fail "no HOME printed: $message"

# Without TUNA_LIBRARY, Tuna's own library is plugins/ beside the program,
# however the program is started.
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-program-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
mkdir -p "$dir/bin/plugins" "$dir/home"
cp "$tuna" "$dir/bin/tuna"
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
printf '(import (tuna))\n(on-unload (lambda () (sleep (make-time (quote time-duration) 100000000 0))))\n' \
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
(fork-thread
  (lambda ()
    (sleep (make-time 'time-duration 200000000 0))
    (post! (lambda () (display "posted") (newline)))
    (sleep (make-time 'time-duration 300000000 0))
    (exit 5)))
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

echo "$0: $failures failures"
[ "$failures" -eq 0 ]
