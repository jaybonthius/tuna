(import (tuna) (test) (test-user) (buffers) (layout) (layout-split) (editing) (echo-area) (minibuffer) (completion)
        (chez-scheme) (chez-scheme-completion) (eval) (eval-test))

(test "M-: evaluates and keeps the input in its history"
  (eval-test:eval! "(+ 1 2)" #f)
  (check-equal? '("3" ("(+ 1 2)")) (list (echo-area:current-message) (eval:expression-history))))
