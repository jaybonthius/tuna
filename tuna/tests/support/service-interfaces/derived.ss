prelude: :gerbil/core
package: tuna/tests/support/service-interfaces
(import :std/interface :tuna/kernel "./base")
(export (service-interface-out Extra Diamond QualifiedExtra)
        new-provider new-qualified-provider events reset-events!)

(service-interface (Extra Base Auxiliary) (extra) => :fixnum)
;; Diamond inheritance must not install the Base path twice.
(service-interface (Diamond Extra Base) (leaf) => :symbol)

(def events [])
(def (reset-events!) => :void (set! events []))
(def (record! (event : :symbol)) => :void
  (set! events (append events [event])))

(defclass provider ((state : :fixnum)) final: #t)
(defmethod {run provider}
  (lambda ((self : provider) (n : :fixnum)) => :fixnum
    (record! 'function-before)
    (set! self.state (fx+ self.state n))
    (record! 'body)
    (record! 'function-after)
    self.state))
(defmethod {extra provider}
  (lambda ((self : provider)) => :fixnum self.state))
(defmethod {side provider} (lambda (self) "side"))
(defmethod {leaf provider} (lambda (self) 'leaf))
(defmethod {optional provider} (lambda (self n) n))
(defmethod {keyword provider} (lambda (self n add: add) (+ n add)))
(defmethod {rest provider} (lambda (self n . tail) (cons n tail)))
(defmethod {combined provider}
  (lambda (self n offset scale: scale . tail) (cons* n offset scale tail)))
(defmethod {predicate provider} (lambda (self n) n))
(defmethod {typed provider} (lambda (self value) value))
(defmethod {nullable provider} (lambda (self present?) (and present? 7)))
(defmethod {multiple provider} (lambda (self) (values 1 "two")))
(defmethod {loose provider} (lambda (self value) value))

(def (new-provider) => Diamond (Diamond (provider state: 0)))

(service-interface (QualifiedExtra QualifiedBase QualifiedSibling)
  (widen (value : :t)) => :symbol
  (choose (value :~ negative? : :fixnum := -2)) => :fixnum
  (special) => :fixnum)

(defclass qualified-provider () final: #t)
(implement QualifiedBase qualified-provider
  (run (lambda (self) 'base))
  (widen (lambda (self value) 'base-value))
  (choose (lambda (self value) (fx+ value 100))))
(implement QualifiedSibling qualified-provider
  (run (lambda (self) 'sibling))
  (choose (lambda (self value) value)))
(implement QualifiedExtra qualified-provider
  (run (lambda (self) 'extra-run))
  (widen (lambda (self value) 'extra-value))
  (choose (lambda (self value) (fx- value 100)))
  (special (lambda (self) 7)))
(def (new-qualified-provider) => QualifiedExtra
  (QualifiedExtra (qualified-provider)))
