#!tuna
;; Silences the core's writer of reports, beneath advice of modules
;; loaded after this one.
(define (silence report c) (void))

(advice-add! report silence)
