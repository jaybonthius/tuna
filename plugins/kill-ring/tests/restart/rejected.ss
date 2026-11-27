(import (tuna) (test))

(define reported '())

(define (keep next c) (set! reported (cons c reported)))

(advice-add! report keep)

(import (kill-ring))

(advice-remove! report keep)

(test "a saved text that fails its check is reported as a warning, and the ring starts empty"
  (check-equal? 1 (length reported))
  (check (warning? (car reported)))
  (check-equal? '() (kill-ring:entries)))
