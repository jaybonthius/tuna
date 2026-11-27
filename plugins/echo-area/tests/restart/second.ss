(import (tuna) (test) (layout) (echo-area) (echo-area-test))

(test "after the restart one echo area shows, and no message"
  (check-equal? 1 (length (filter (lambda (attributes) (equal? " *Echo Area*" (cdr (assq 'buffer attributes))))
                                  (echo-area-test:layout-atoms))))
  (check-equal? #f (echo-area:current-message)))
