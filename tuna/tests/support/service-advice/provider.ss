prelude: :tuna/prelude
package: tuna/tests/support/service-advice
(import :std/interface :tuna/kernel "./contract")
(export new-counter step-body events record! reset-events!)

(def events [])
(def (record! (event : :t)) => :void (set! events (append events [event])))
(def (reset-events!) => :void (set! events []))
(defclass counter ((value : :fixnum)) final: #t)
(def (step-body (n : :fixnum)) => :fixnum
  (record! 'body)
  n)
(implement Counter counter
  (step (lambda ((self : counter) n)
          (set! self.value (fx+ self.value (step-body n)))
          self.value))
  (inline (lambda (self n) (fx+ n 100)))
  (multiple (lambda (self) (values 1 "two"))))
(def (new-counter) => Counter (Counter (counter value: 0)))
