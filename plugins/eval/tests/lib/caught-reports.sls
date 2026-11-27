#!tuna
(import (test-runner))

(define %caught #f)

;; Not a dynamic-wind, whose after-thunk would run at each pause of the
;; test's task, while the reports come from other tasks.
(define (awaited n thunk)
  (let ([outer %caught])
    (set! %caught '())
    (guard (c [#t (set! %caught outer) (raise c)])
      (thunk)
      (test-runner:wait-until (lambda () (>= (length %caught) n))))
    (let ([caught (reverse %caught)])
      (set! %caught outer)
      caught)))

(define (during thunk) (awaited 0 thunk))

;; A test file imports this before the plugins it tests, so this advice
;; on report sits inside theirs: they still see each report the test
;; catches, as the echo area shows it and eval counts it, while the
;; kernel's writer, which would fail the test file, does not.
(advice-add! report
  (lambda (next c)
    (if %caught
        (set! %caught (cons c %caught))
        (next c))))
