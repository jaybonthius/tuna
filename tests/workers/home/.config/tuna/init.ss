(import (tuna))

(define log '())
(define (note! x) (set! log (cons x log)))

(define (job-results worker input count)
  (suspend
    (lambda (resume)
      (let ([got '()])
        (start-job worker input
          (lambda (v)
            (set! got (cons v got))
            (when (= (length got) count)
              (resume (lambda () (reverse got))))))))))

;; A job's change is forgotten once its thread has ended, after every
;; result and report it sent.
(define (wait-for-end job)
  (let loop ()
    (when (exists (lambda (change) (eq? (cadr change) job)) (module-changes '(repl)))
      (sleep-for 0.01)
      (loop))))

(define (wait-for-file path)
  (let loop ()
    (unless (file-exists? path)
      (sleep-for 0.01)
      (loop))))
