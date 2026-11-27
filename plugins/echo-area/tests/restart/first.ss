(import (tuna) (test) (layout) (echo-area) (echo-area-test))

(test "one echo area shows before the exit"
  (check-equal? 1 (length (filter (lambda (attributes) (equal? " *Echo Area*" (cdr (assq 'buffer attributes))))
                                  (echo-area-test:layout-atoms)))))

(echo-area:message! "Bye")
