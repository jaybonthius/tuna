prelude: :tuna/prelude
package: tuna/tests/support/open-functions
(export probe keyword-probe callback callback-log base-context)
(import :tuna/kernel)

(def callback-log [])
(def base-context #f)
(def (probe . args) => :values
  (set! base-context (current-context))
  (apply values args))
(def (keyword-probe (n : :fixnum) add: (add : :fixnum := 3)) => :fixnum
  (fx+ n add))
(def (callback . args) => :void
  (set! callback-log (cons args callback-log)))
