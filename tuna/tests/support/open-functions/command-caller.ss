prelude: :tuna/prelude
package: tuna/tests/support/open-functions
(import :tuna/kernel "command-advice")
(export install-fixture-advice! remove-fixture-advice! fixture-advice)

;; Internal control tokens must not resolve to these ordinary local bindings.
(def (install-fixture-advice! (ctx : context)) => :void
  (let ((add #f) (remove #f) (inspect #f))
    (advise! ctx (command fixture) 'compiled
      around: (lambda (original n) (+ 10 (original n))))))
(def (remove-fixture-advice! (ctx : context)) => :void
  (let ((add #f) (remove #f) (inspect #f))
    (unadvise! ctx (command fixture) 'compiled)))
(def (fixture-advice) => advice-target-info
  (let ((add #f) (remove #f) (inspect #f))
    (advice-for (command fixture))))
