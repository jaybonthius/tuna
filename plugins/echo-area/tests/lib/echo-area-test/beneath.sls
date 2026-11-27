#!tuna
;; Loaded before echo-area, so its advice on report is beneath the
;; plugin's: it keeps a report the test causes off standard error while the
;; plugin's advice still shows and logs it. Threads report too, so the
;; list is kept under a mutex.
(define %caught #f)

(define %mutex (make-mutex))

(define (reports-during thunk)
  (with-mutex %mutex (set! %caught '()))
  (thunk)
  (with-mutex %mutex
    (let ([caught (reverse %caught)])
      (set! %caught #f)
      caught)))

(advice-add! report
  (lambda (report c)
    (unless (with-mutex %mutex (and %caught (begin (set! %caught (cons c %caught)) #t)))
      (report c))))
