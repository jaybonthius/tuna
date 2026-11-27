(import (tuna) (test) (test-user) (views) (editing) (jump-history) (isearch) (isearch-test))

(define b (isearch-test:show! "j" "foo bar foo bar foo\n"))

(test "a search that ends away from where it started records the start once in the jump list, and M-, returns there"
  (views:set-point! (isearch-test:view) 5)
  (test-user:press! "C-s f o o C-s C-s RET")
  (check-equal? (list 20 (list (cons b 5))) (list (isearch-test:point) (jump-history:places)))
  (test-user:press! "M-,")
  (check-equal? 5 (isearch-test:point)))

(test "C-g and ESC record nothing"
  (let ([before (length (jump-history:places))])
    (check (isearch-test:cancelling! "C-s f o o C-s C-g"))
    (check (isearch-test:cancelling! "C-s b a r ESC"))
    (check-equal? (list 5 before) (list (isearch-test:point) (length (jump-history:places))))))

(test "a key that ends the search records as RET does"
  (test-user:press! "C-s b a r C-f")
  (check-equal? '(9 (5)) (list (isearch-test:point) (map cdr (jump-history:places)))))

(test "a search that ends where it started records nothing"
  (let ([before (length (jump-history:places))])
    (views:set-point! (isearch-test:view) 1)
    (test-user:press! "C-s C-f")
    (check-equal? (list 2 before) (list (isearch-test:point) (length (jump-history:places))))))
