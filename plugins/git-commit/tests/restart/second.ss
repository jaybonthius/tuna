(import (tuna) (test) (git-commit))

(test "after a restart the message saved before it is the newest"
  (check-equal? '("Kept across a restart") (git-commit:messages)))
