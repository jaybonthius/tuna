#!/bin/sh
# Invoked by prelude-test: compile real fixtures, then leave the caller untouched.
set -eu
fixtures=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
root=$(CDPATH= cd -- "$fixtures/../../../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
cp "$fixtures/target.ss" "$fixtures/caller.ss" "$fixtures/foreign-macro.ss" \
   "$fixtures/command-advice.ss" "$fixtures/command-caller.ss" "$work/"
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
for module in foreign-macro target caller command-advice command-caller; do compile "$module"; done
compiled_eval '(import :tuna/tests/support/open-functions/command-advice
  :tuna/tests/support/open-functions/command-caller
  :tuna/kernel :tuna/lib/advice (only-in :tuna/kernel/plugins activate-plugin!))
  (def owner #f)
  (def selected (advice-target-info-identity (fixture-advice)))
  (defplugin (compiled-command-advisor ctx) "Compiled contract routing."
    (set! owner ctx) (install-fixture-advice! ctx))
  (activate-plugin! compiled-command-advisor)
  (unless (= (fixture-result 2) 12) (error "compiled add route"))
  (unless (eq? selected (advice-target-info-identity (fixture-advice))) (error "unstable identity"))
  (unless (equal? (map advice-info-name (advice-target-info-advice (fixture-advice))) (quote (compiled)))
    (error "compiled inspect route"))
  (unless (eq? (command-name (make-command (quote record))) (quote record)) (error "command collision"))
  (remove-fixture-advice! owner)
  (unless (= (fixture-result 2) 2) (error "compiled remove route"))
  (install-fixture-advice! owner)
  (deactivate-plugin! compiled-command-advisor)
  (unless (= (fixture-result 2) 2) (error "compiled routed cleanup"))'
compiled_eval '(import :tuna/tests/support/open-functions/caller :tuna/tests/support/open-functions/target
  (only-in :tuna/prelude redefine open-definition advise! unadvise! advice-for)
  :tuna/kernel (only-in :tuna/kernel/plugins activate-plugin!) :gerbil/expander)
  (def owner #f)
  (def saved typed)
  (defplugin (compiled-advisor ctx) "Compiled public and private targets."
    (set! owner ctx)
    (advise! ctx typed (quote plus) around: (lambda (original n) (+ 100 (original n))))
    (advise! ctx (function :tuna/tests/support/open-functions/target secret) (quote private)
      around: (lambda (original n) (+ 100 (original n)))))
  (activate-plugin! compiled-advisor)
  (unless (= (outside 1) 102) (error "compiled advice bypassed"))
  (unless (= (saved 1) 102) (error "saved advice bypassed"))
  (unless (= (outside-private 1) 105) (error "private compiled advice bypassed"))
  (def token-value (vector-ref token 0))
  (advise! owner public-call (quote named) before: inside)
  (redefine (inside (n : :fixnum)) => :fixnum (vector-set! token 0 n) n)
  (public-call 7)
  (unless (= (vector-ref token 0) 7) (error "compiled named callback lost liveness"))
  (redefine (inside (n : :fixnum)) => :fixnum (typed n))
  (vector-set! token 0 token-value)
  (redefine (typed (n : :fixnum)) => :fixnum (+ n 20))
  (unless (= (outside 1) 121) (error "redefine lost advice"))
  (unless (= ((open-definition typed) 1) 21) (error "getter returned effective facade"))
  (deactivate-plugin! compiled-advisor)
  (unless (= (saved 1) 21) (error "cleanup restored stale base"))
  (redefine (typed (n : :fixnum)) => :fixnum (+ n 1))
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
compiled_eval '(import :tuna/tests/support/open-functions/caller :tuna/tests/support/open-functions/target
  (only-in :tuna/prelude advise!) :tuna/kernel (only-in :tuna/kernel/plugins activate-plugin!))
  (unless (= (outside 1) 2) (error "helper broke compiled caller"))
  (defplugin (helper-advisor ctx) "Metadata survives helper recompilation."
    (advise! ctx typed (quote helper) around: (lambda (original n) (+ 10 (original n))))
    (advise! ctx (function :tuna/tests/support/open-functions/target secret) (quote private)
      around: (lambda (original n) (+ 10 (original n)))))
  (activate-plugin! helper-advisor)
  (unless (= (outside 1) 12) (error "helper broke compiled advice"))
  (unless (= (outside-private 1) 15) (error "helper broke private compiled advice"))
  (deactivate-plugin! helper-advisor)'
cp lib/tuna/tests/support/open-functions/target.ssi helper.ssi
sed 's/(def (typed (n : :fixnum)) => :fixnum (fx+ n 1))/(def (typed (n : :fixnum)) => :fixnum (fx+ n 101))/' target.ss > changed.ss
mv changed.ss target.ss
compile target
cmp helper.ssi lib/tuna/tests/support/open-functions/target.ssi
compiled_eval '(import :tuna/tests/support/open-functions/caller)
  (unless (= (outside 1) 102) (error "stale compiled body"))'
sha256sum -c caller.sha256
echo RECOMPILE-STABILITY-PASS
