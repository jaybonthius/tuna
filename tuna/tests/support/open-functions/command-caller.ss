prelude: :tuna/prelude
package: tuna/tests/support/open-functions
(import :tuna/kernel "command-advice")
(export install-fixture-advice! remove-fixture-advice! fixture-advice)

(def (install-fixture-advice! (ctx : context)) => :void
  (advise! ctx (command fixture) 'compiled
    around: (lambda (original n) (+ 10 (original n)))))
(def (remove-fixture-advice! (ctx : context)) => :void
  (unadvise! ctx (command fixture) 'compiled))
(def (fixture-advice) => advice-target-info
  (advice-for (command fixture)))
