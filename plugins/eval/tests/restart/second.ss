(import (tuna) (test) (caught-reports) (test-user) (buffers) (layout) (layout-split) (editing) (echo-area) (minibuffer)
        (completion) (chez-scheme) (chez-scheme-completion) (eval) (eval-test))

(test "after a restart, M-p at M-:'s prompt recalls the input of the last session"
  (test-user:press! "M-: M-p")
  (check-equal? "(+ 1 2)" (eval-test:input))
  (check-equal? '(cancelled) (eval-test:reports-during (lambda () (test-user:press! "C-g")))))
