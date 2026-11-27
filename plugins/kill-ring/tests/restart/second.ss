(import (test) (kill-ring))

(test "after a restart the ring holds the saved texts, newest first, the yank pointer at the newest"
  (check-equal? '(("newest") ("Hello there" "two!") ("first")) (kill-ring:entries))
  (check-equal? '("newest") (kill-ring:current))
  (check-equal? '("Hello there" "two!") (kill-ring:rotate! 1)))
