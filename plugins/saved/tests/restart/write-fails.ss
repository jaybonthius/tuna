(import (tuna) (test) (test-runner) (saved) (saved-test kept) (saved-test files))

;; A file where the datum's folder would go makes its write fail.
(saved-test/files:write-text! (saved-test/files:file "tuna" "saved-test" "kept") "")

(test "a write that fails is reported"
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (saved:set! saved-test/kept:answers '("lost"))
    (test-runner:wait-until (lambda () (pair? reported)))
    (advice-remove! report keep)
    (check-equal? 1 (length reported))
    (check (i/o-error? (car reported)))))
