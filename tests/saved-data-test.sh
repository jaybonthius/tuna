#!/bin/sh
set -eu
tuna=${1:?usage: saved-data-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-saved-data-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
failures=0
fail() {
  echo "$0: FAIL: $1"
  failures=$((failures + 1))
}

home=$dir/home
saved=$home/.local/share/tuna/saved
mkdir -p "$home/.config/tuna/lib" "$dir/library" "$dir/work"
cat > "$home/.config/tuna/init.ss" <<'END'
(import (tuna) (tuna plugins))
(define-saved answers '() list?)
END
cat > "$home/.config/tuna/lib/hist.sls" <<'END'
#!tuna
(define-saved entries '() list?)
(set-saved! entries (cons "first" (entries)))
END

run() {
  (cd "$dir/work" && printf '%s\n' "$1" | HOME="$home" TUNA_LIBRARY="$dir/library" "$tuna" 2>&1)
}

expect() {
  [ "$2" = "$3" ] || fail "$1: expected $(printf '%s' "$3" | tr '\n' '|'), got $(printf '%s' "$2" | tr '\n' '|')"
}

expect_file() {
  if [ -f "$2" ]; then
    expect "$1" "$(cat "$2")" "$3"
  else
    fail "$1: no file $2"
  fi
}

# Exit waits for every write, the last set's included, however large.
output=$(run "(set-saved! answers '(\"yes\"))
(import (hist))
(thread-join (fork-thread (lambda () (set-saved! hist:entries (cons \"thread\" (hist:entries))))))
(define-saved big '() list?)
(set-saved! big (make-list 100000 \"a line of text in a long history\"))")
expect "first run" "$output" ""
expect_file "the configuration's datum" "$saved/user/init/answers.ss" '("yes")'
expect_file "a module's datum, set on another thread" "$saved/user/hist/entries.ss" '("thread" "first")'
[ -f "$saved/user/repl/big.ss" ] || fail "the REPL's datum was not written"
leftovers=$(find "$saved" -name '*.new')
expect "temporary files" "$leftovers" ""

output=$(run "(answers)
(import (hist))
(hist:entries)
(define-saved big '() list?)
(length (big))
(remove-saved! answers)
(answers)")
expect "after a restart" "$output" '("yes")
("first" "thread" "first")
100000
()'
[ -e "$saved/user/init/answers.ss" ] && fail "remove-saved! left the file"
expect_file "a datum set again" "$saved/user/hist/entries.ss" '("first" "thread" "first")'

# A fork is another source, so it starts empty and keeps its own data; the
# original's stays for its return.
mkdir -p "$home/src/notes" "$home/src/notes-fork"
printf '#!tuna\n(define-saved hits 0 fixnum?)\n' > "$home/src/notes/notes.sls"
cp "$home/src/notes/notes.sls" "$home/src/notes-fork/notes.sls"
use_notes() {
  printf '(import (tuna) (tuna plugins))\n(use-plugin notes (local "~/src/%s"))\n' "$1" > "$home/.config/tuna/init.ss"
}
folder() {
  printf '%s' "$home/src/$1" | sed 's|%|%25|g; s|/|%2F|g'
}
use_notes notes
expect "the original" "$(run "(notes:hits)
(set-saved! notes:hits 3)")" "0"
use_notes notes-fork
expect "the fork" "$(run "(notes:hits)
(set-saved! notes:hits 5)")" "0"
use_notes notes
expect "the original again" "$(run "(notes:hits)")" "3"
expect_file "the original's file" "$saved/$(folder notes)/notes/hits.ss" "3"
expect_file "the fork's file" "$saved/$(folder notes-fork)/notes/hits.ss" "5"

# A value that the form's new check fails is copied aside and its file
# deleted, in that order, after the write already queued.
run "(define-saved kind '(1 2) list?)
(set-saved! kind '(1 2 3))
(define-saved kind 0 fixnum?)" > /dev/null
expect_file "a kept value that fails a new check" "$saved/user/repl/kind.ss.rejected" '(1 2 3)'
[ -e "$saved/user/repl/kind.ss" ] && fail "a kept value that fails a new check left its file"

# Printer settings of the code that sets a value do not change its file.
run "(print-extended-identifiers #t)
(define-saved odd '() list?)
(set-saved! odd (list (string->symbol \"#foo\")))" > /dev/null
expect "a symbol printed under print-extended-identifiers" "$(run "(define-saved odd '() list?)
(symbol->string (car (odd)))")" '"#foo"'

# A file that cannot be opened stays in place, and the load fails.
use_notes notes
chmod 000 "$saved/$(folder notes)/notes/hits.ss"
case $(run "(notes:hits)") in
  '! '*) ;;
  *) fail "a file that cannot be opened was not reported" ;;
esac
chmod 644 "$saved/$(folder notes)/notes/hits.ss"
[ -e "$saved/$(folder notes)/notes/hits.ss.rejected" ] && fail "a file that cannot be opened was rejected"
expect "a file that could not be opened" "$(run "(notes:hits)")" "3"

# A deletion that fails is reported, and the file stays.
chmod 555 "$saved/$(folder notes)/notes"
output=$(run "(remove-saved! notes:hits)")
chmod 755 "$saved/$(folder notes)/notes"
case $output in
  '! '*) ;;
  *) fail "a failed deletion was not reported: $output" ;;
esac
expect_file "a file that could not be deleted" "$saved/$(folder notes)/notes/hits.ss" "3"

# A write that fails is reported, and Tuna still exits normally.
rm -rf "$saved"
printf 'not a folder\n' > "$saved"
use_notes notes
status=0
output=$(run "(set-saved! notes:hits 4)") || status=$?
expect "exit status after a failed write" "$status" 0
case $output in
  '! '*) ;;
  *) fail "a failed write was not reported: $output" ;;
esac

echo "$0: $failures failures"
[ "$failures" -eq 0 ]
