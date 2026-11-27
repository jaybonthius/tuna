#!/bin/sh
set -eu
tuna=${1:?usage: install-test.sh TUNA}
case $tuna in
  /*) ;;
  *) tuna=$PWD/$tuna ;;
esac
dir=$(mktemp -d "${TMPDIR:-/tmp}/tuna-install-test.XXXXXX")
trap 'rm -rf "$dir"' EXIT
failures=0
fail() {
  echo "$0: FAIL: $1"
  failures=$((failures + 1))
}

# An install of its own, holding only these plugins, so the test fetches
# nothing from the network and compiles little.
bin=$dir/bin
mkdir -p "$bin/plugins" "$dir/work"
cp "$tuna" "$bin/tuna"
cp -R "$(dirname "$tuna")/start" "$bin/start"
plugin() {
  mkdir -p "$bin/plugins/$1/src"
  printf '#!tuna\n%s\n' "$2" > "$bin/plugins/$1/src/$1.sls"
}
plugin fine '(define (where) "fine")'
plugin lone '(import (broken))
(define (where) "lone")'
plugin lone-user '(import (lone))'
plugin unbuilt '(define (where) "unbuilt")'
printf "(errorf 'build \"no compiler\")\n" > "$bin/plugins/unbuilt/build.ss"
plugin unbuilt-user '(import (unbuilt))'

# A library whose build fails, as libghostty's does without zig.
export GIT_CONFIG_NOSYSTEM=1
library=$dir/remotes/chez-broken
mkdir -p "$library/src"
printf '(library (broken) (export) (import (chezscheme)))\n' > "$library/src/broken.sls"
git -C "$library" init -q -b main
git -C "$library" add -A
git -C "$library" -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -qm one
commit=$(git -C "$library" rev-parse HEAD)
cat > "$bin/plugins/lone/tuna.deps" <<END
(library chez-broken
  (git "file://$library")
  (commit "$commit")
  (library-directories ("src" . "build/obj/src"))
  (build "false"))
END

run() {
  home=$1
  shift
  (cd "$dir/work" && HOME="$home" env -u TUNA_LIBRARY -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME \
    timeout 120 "$bin/tuna" "$@" < /dev/null)
}

# An install with one library and one build failing prints each failure
# and the plugins they leave out, loads the rest, and succeeds.
mkdir -p "$dir/installer"
status=0
run "$dir/installer" --install > "$dir/out" 2> "$dir/errors" || status=$?
[ "$status" -eq 0 ] || fail "tuna --install exited with status $status"
[ ! -s "$dir/errors" ] || fail "tuna --install wrote to standard error: $(cat "$dir/errors")"
expect_line() {
  grep -q -F -- "$1" "$dir/out" || fail "tuna --install did not print: $1 (it printed: $(cat "$dir/out"))"
}
expect_line "library chez-broken could not be installed: the build of library chez-broken failed with status 1"
expect_line "plugin lone is left out: it needs library chez-broken"
expect_line "plugin lone-user is left out: it needs library chez-broken"
expect_line "plugin unbuilt is left out: the build of plugin unbuilt failed with status 255: Exception in build: no compiler"
expect_line "plugin unbuilt-user is left out: the build of plugin unbuilt failed with status 255"
if grep -q "plugin fine" "$dir/out"; then fail "fine was left out"; fi
[ -f "$bin/plugins/unbuilt.failed" ] || fail "the failed build was not recorded beside its plugin"
[ ! -e "$bin/libraries/chez-broken" ] || fail "the failed library was left in the install"
installed=$(ls -A "$bin/libraries" 2>/dev/null || true)

# At an ordinary start a form that reaches a left-out plugin raises,
# naming the plugin and why, and the rest load.
mkdir -p "$dir/user/.config/tuna"
cat > "$dir/user/.config/tuna/init.ss" <<'END'
(import (tuna) (plugins) (fine))
(define (try form)
  (guard (c [(plugins:left-out? c) (printf "~s ~s\n" (plugins:left-out-plugin c) (plugins:left-out-library c))])
    (plugins:eval-form form)))
(printf "~a\n" (fine:where))
(try '(import (lone-user)))
(try '(import (unbuilt-user)))
(import (lone))
(exit)
END
output=$(run "$dir/user" 2>&1) || fail "the ordinary start exited with status $?"
expected='fine
lone chez-broken
unbuilt #f
! import: plugin lone is left out of Tuna'"'"'s install: it needs library chez-broken (import (lone)) at line 8, char 1 of '"$dir/user/.config/tuna/init.ss"
[ "$output" = "$expected" ] || fail "the ordinary start printed: $output"

# A module of a left-out plugin's name that the lookup finds elsewhere,
# here in lib/, loads.
mkdir -p "$dir/stand-in/.config/tuna/lib"
printf '#!tuna\n(define (where) "the stand-in")\n' > "$dir/stand-in/.config/tuna/lib/lone.sls"
printf '(import (tuna) (lone))\n(display (lone:where))\n(exit)\n' > "$dir/stand-in/.config/tuna/init.ss"
output=$(run "$dir/stand-in" 2>&1) || fail "the start with a stand-in exited with status $?"
[ "$output" = "the stand-in" ] || fail "the stand-in for lone gave: $output"

# Only tuna --install installs the install's libraries.
[ "$(ls -A "$bin/libraries" 2>/dev/null || true)" = "$installed" ] || fail "an ordinary start changed the install's libraries"
for home in "$dir/user" "$dir/stand-in"; do
  [ ! -e "$home/.local/share/tuna/libraries" ] || fail "an ordinary start installed a library into $home"
done

# Only the Tuna started to install installs.
mkdir -p "$dir/refuser/.config/tuna"
printf '(import (tuna) (plugins))\n(guard (c [(assertion-violation? c) (display "refused")]) (plugins:install-all!))\n(exit)\n' \
  > "$dir/refuser/.config/tuna/init.ss"
output=$(run "$dir/refuser" 2>&1) || fail "the start that calls plugins:install-all! exited with status $?"
[ "$output" = "refused" ] || fail "plugins:install-all! at an ordinary start gave: $output"

# Own plugins that disagree on a library are Tuna's own mistake: it is
# reported, which fails make exe, and leaves no plugin out silently.
plugin rival '(import (broken))'
sed 's/(build "false")/(build "true")/' "$bin/plugins/lone/tuna.deps" > "$bin/plugins/rival/tuna.deps"
mkdir -p "$dir/second"
run "$dir/second" --install > "$dir/out" 2> "$dir/errors" || true
grep -q "ask for chez-broken with different build clauses" "$dir/errors" ||
  fail "a conflict among own plugins' lines was not reported: $(cat "$dir/errors")"

# Own plugins that name a library at two commits on one line of history
# get the later, and an ordinary start compares them in the install's
# clone, fetching nothing.
twice=$dir/remotes/chez-twice
mkdir -p "$twice/src"
git -C "$twice" init -q -b main
for n in 1 2; do
  printf '(library (twice) (export version) (import (chezscheme)) (define (version) %s))\n' "$n" > "$twice/src/twice.sls"
  git -C "$twice" add -A
  git -C "$twice" -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false commit -qm "$n"
done
for pair in early:HEAD~1 late:HEAD; do
  plugin "${pair%%:*}" '(import (prefix (twice) twice:))
(define (version) (twice:version))'
  cat > "$bin/plugins/${pair%%:*}/tuna.deps" <<END
(library chez-twice
  (git "file://$twice")
  (commit "$(git -C "$twice" rev-parse "${pair#*:}")")
  (library-directories ("src" . "build/obj/src"))
  (build))
END
done
mkdir -p "$dir/third"
run "$dir/third" --install > /dev/null 2>&1 || true
mkdir -p "$dir/later/.config/tuna"
printf '(import (tuna) (early))\n(display (early:version))\n(exit)\n' > "$dir/later/.config/tuna/init.ss"
output=$(run "$dir/later" 2> /dev/null) || fail "the start with two commits of one library exited with status $?"
[ "$output" = "2" ] || fail "the later commit of chez-twice was not used: $output"
[ ! -e "$dir/later/.local/share/tuna/libraries" ] || fail "an ordinary start fetched to compare commits"

echo "$0: $failures failures"
[ "$failures" -eq 0 ]
