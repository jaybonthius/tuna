#!/bin/sh
set -eu
tuna=${1:?usage: libraries-from-git-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac

# The libraries come from GitHub, and an offline run should not fail the
# suite.
if ! GIT_TERMINAL_PROMPT=0 timeout 20 git ls-remote https://github.com/jaybonthius/chez-md4c HEAD > /dev/null 2>&1; then
  echo "$0: skipped: GitHub is unreachable"
  exit 0
fi

dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-libraries-from-git-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
failures=0
fail() {
  echo "$0: FAIL: $1"
  failures=$((failures + 1))
}

mkdir -p "$dir/home/.config/tuna" "$dir/plugin" "$dir/work"
cat > "$dir/plugin/markdown-shell.sls" <<'END'
#!tuna
(import (md4c) (process))

(define (heading-level text)
  (let ([first (car (markdown-parse text))])
    (and (markdown-heading? first) (markdown-heading-level first))))

(define (echo text)
  (utf8->string (process-result-stdout (run-process "echo" (list text)))))
END
cat > "$dir/plugin/tuna.deps" <<'END'
(library chez-md4c
  (git "https://github.com/jaybonthius/chez-md4c")
  (commit "e9d08ede95e180b415a397abf1bcaf76f0c010b2")
  (library-directories ("src" . "build/obj/src"))
  (build "make" "build/obj/src/md4c/libchez-md4c.so"))
(library chez-process
  (git "https://github.com/jaybonthius/chez-process")
  (commit "1d3356c0f82248125ae4771d116f94597046f2df")
  (library-directories ("src" . "build/obj/src"))
  (build "make" "build/obj/src/process/libchez-process.so"))
END
cat > "$dir/home/.config/tuna/init.ss" <<END
(import (tuna) (tuna plugins))
(use-plugin markdown-shell (local "$dir/plugin"))
(write (list (markdown-shell:heading-level "## Hi\n") (markdown-shell:echo "hello")))
(exit)
END

# A user's git settings, such as address rewrites, would change where the
# libraries come from.
output=$(cd "$dir/work" && GIT_CONFIG_NOSYSTEM=1 HOME="$dir/home" env -u TUNA_LIBRARY "$tuna" < /dev/null 2>&1) ||
  fail "tuna exited with status $?"
[ "$output" = '(2 "hello\n")' ] || fail "the plugin gave: $output"
libraries=$dir/home/.local/share/tuna/libraries
head=$(cat "$libraries/chez-process/.git/HEAD" 2>/dev/null || true)
[ "$head" = 1d3356c0f82248125ae4771d116f94597046f2df ] || fail "chez-process is checked out at: $head"
[ -f "$libraries/chez-process/build/obj/src/process.so" ] ||
  fail "(process) was not compiled into its own object folder"
# The plugin's line for chez-md4c is Tuna's own, so Tuna's built copy
# serves it.
[ ! -e "$libraries/chez-md4c" ] || fail "chez-md4c was installed though Tuna's own line agrees"

echo "$0: $failures failures"
[ "$failures" -eq 0 ]
