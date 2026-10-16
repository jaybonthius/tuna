;;; Separate contract fixture: the record binding is not the routing macro.
prelude: :gerbil/core
package: tuna/tests/support/open-functions
(import :tuna/kernel :tuna/lib/advice)
(export (struct-out command) command-advice-target fixture-result)

(defstruct command ((name : :symbol)) final: #t)
(def effective values)
(def state
  (new-advice-state 'command 'fixture "command-advice fixture"
    (lambda (records) (set! effective (compose-advice values records)))))

(def (fixture-state (name : :symbol)) => advice-state
  (unless (eq? name 'fixture) (error "Unknown fixture command" name))
  state)
(def (fixture-result . args) => :values
  (:- (apply effective args) :values))

;; Private helpers must stay hygienic in separately compiled consumers.
(defrules command-advice-target (add remove inspect)
  ((_ add ctx target name kind callback option ...)
   (register-advice! ctx (fixture-state target) name kind callback option ...))
  ((_ remove ctx target name)
   (remove-advice! ctx (fixture-state target) name))
  ((_ inspect target)
   (inspect-advice (fixture-state target))))
