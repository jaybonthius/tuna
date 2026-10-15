prelude: :gerbil/core
package: tuna/tests/support/open-functions
(export foreign-definition)

;; A macro bound to core def deliberately emits an ordinary closed procedure.
(defrule (foreign-definition name)
  (def (name (n : :fixnum)) => :fixnum (fx+ n 7)))
