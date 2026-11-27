#!tuna
(import (buffers) (modes))

(define %viewing (make-weak-eq-hashtable))

(modes:define-minor-mode mode
  "Whether the current buffer is viewed, not edited."
  (state () (eq-hashtable-ref %viewing (buffers:current) #f))
  (lighter "View"))

(define (set-viewing! buffer on?) (eq-hashtable-set! %viewing buffer on?))
