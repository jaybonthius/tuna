#!tuna
(define %on #f)
(define (mode enable?) (set! %on enable?) %on)
(define (enabled?) %on)
