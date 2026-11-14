#!tuna
(define (silence report c) (void))

(advice-add! report silence)
