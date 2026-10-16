prelude: :gerbil/core
package: tuna/tests/support/service-interfaces
(import :tuna/kernel)
(export (service-interface-out Base Auxiliary QualifiedBase QualifiedSibling)
        payload new-payload payload-value default-count reset-defaults! next-default)

;; Ordinary interface inheritance requires its signature types in scope.
(defstruct payload ((value : :fixnum)) final: #t)
(def (new-payload (value : :fixnum)) => payload (make-payload value))
(def default-count 0)
(def (reset-defaults!) => :void (set! default-count 0))
(def (next-default) => :fixnum
  (set! default-count (fx1+ default-count))
  default-count)

(service-interface Base
  (run (n : :fixnum)) => :fixnum
  (optional (n : :fixnum := (next-default))) => :fixnum
  (keyword (n : :fixnum) add: (add : :fixnum := (next-default))) => :fixnum
  (rest (n : :fixnum) . tail) => :list
  (combined (n : :fixnum) (offset : :fixnum := (next-default))
            scale: (scale : :fixnum := (next-default)) . tail) => :list
  (predicate (n :~ fixnum?)) => :fixnum
  (typed (value : payload)) => payload
  (nullable (present? : :boolean)) => (Maybe :fixnum)
  (multiple) => :values
  (loose value))

(service-interface Auxiliary (side) => :string)

;; Same spelling, independent interface-qualified implementations.
(service-interface QualifiedBase
  (run) => :symbol
  (widen (value : :fixnum)) => :symbol
  (choose (value :~ positive? : :fixnum := 1)) => :fixnum)
(service-interface QualifiedSibling
  (run) => :symbol
  (choose (value :~ zero? : :fixnum := 0)) => :fixnum)
