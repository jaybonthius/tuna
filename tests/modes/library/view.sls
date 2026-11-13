#!tuna
(import (buffers) (modes))

(define %viewing (make-weak-eq-hashtable))
(define (mode) (eq-hashtable-ref %viewing (buffers:current) #f))
(define (set-viewing! buffer on?) (eq-hashtable-set! %viewing buffer on?))
(table-set! modes:minor-modes mode 0)
(table-set! modes:lighters mode "View")
