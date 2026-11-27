(import (test) (jobs-test) (fuzzy))

(test "the installed plugin's worker runs with the library beside it"
  (check-equal? '((4) #f) (jobs-test:finished fuzzy:match-names "abcd")))
