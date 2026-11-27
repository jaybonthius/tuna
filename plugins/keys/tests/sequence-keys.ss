(import (tuna) (test) (keys))

(define (raised-by-sequence-keys? e)
  (and (who-condition? e) (eq? 'keys:sequence-keys (condition-who e))))

(test "keys:sequence-keys gives the keys of a sequence as keys:bind! writes one, in order"
  (check-equal? '("C-a" "C-k" "C-k") (keys:sequence-keys "C-a C-k C-k"))
  (check-equal? '("C-x" "4" "<f1>") (keys:sequence-keys "C-x 4 <f1>"))
  (check-equal? '("C--" "-" "SPC" "C-M-S-<return>") (keys:sequence-keys "C-- - SPC C-M-S-<return>"))
  (check-equal? '("a") (keys:sequence-keys "a")))

(test "keys:sequence-keys raises under its own name for what is not a sequence"
  (for-each
    (lambda (keys) (check-raises raised-by-sequence-keys? (keys:sequence-keys keys)))
    '("" "C-a  C-k" " a" "a " "S-a" "M-C-a" "<f 1>" C-a)))
