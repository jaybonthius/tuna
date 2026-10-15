#!/bin/sh
# Invoked by prelude-test: compile real fixtures, then leave the caller untouched.
set -eu
fixtures=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
root=$(CDPATH= cd -- "$fixtures/../../../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
cp "$fixtures/target.ss" "$fixtures/caller.ss" "$fixtures/foreign-macro.ss" "$work/"
mkdir "$work/lib" "$work/runtime"
export GERBIL_PATH="$root/.gerbil" GERBIL_LOADPATH="$work/lib:$root/.gerbil/lib"
cd "$work"
compile() {
  systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0 timeout 2400 \
    gxc -O -s -d lib "$1.ss"
}
compiled_eval() {
  (cd runtime
   systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0 timeout 2400 \
     gxi -e "$1")
}
for module in foreign-macro target caller; do compile "$module"; done
compiled_eval '(import :tuna/tests/support/open-functions/caller :tuna/tests/support/open-functions/target (only-in :tuna/prelude redefine open-definition) :gerbil/expander)
  (unless (= (outside 1) 2) (error "original compiled caller"))
  (redefine (typed (n : :fixnum)) => :fixnum (fx+ n 10))
  (unless (= (outside 1) 11) (error "compiled caller ignored redefine"))
  (parameterize ((current-expander-context (import-module (quote :tuna/tests/support/open-functions/target) #f #t)))
    (eval (quote (redefine (secret (n : :fixnum)) => :fixnum (fx+ (helper n) 10)))))
  (unless (= (outside-private 1) 15) (error "private compiled caller"))
  (unless (= (self-loop 10000000) 0) (error "self tail calls"))
  (unless (mutual-a 10000000) (error "mutual tail calls"))
  (unless (equal? (tail-trace 1) (tail-trace 1000000)) (error "tail stack grew"))'
find lib -type f -name 'caller*' -exec sha256sum {} \; > caller.sha256
printf '\n(def (unrelated-helper (n : :fixnum)) => :fixnum n)\n' >> target.ss
compile target
compiled_eval '(import :tuna/tests/support/open-functions/caller)
  (unless (= (outside 1) 2) (error "helper broke compiled caller"))'
cp lib/tuna/tests/support/open-functions/target.ssi helper.ssi
sed 's/(def (typed (n : :fixnum)) => :fixnum (fx+ n 1))/(def (typed (n : :fixnum)) => :fixnum (fx+ n 101))/' target.ss > changed.ss
mv changed.ss target.ss
compile target
cmp helper.ssi lib/tuna/tests/support/open-functions/target.ssi
compiled_eval '(import :tuna/tests/support/open-functions/caller)
  (unless (= (outside 1) 102) (error "stale compiled body"))'
sha256sum -c caller.sha256
echo RECOMPILE-STABILITY-PASS
