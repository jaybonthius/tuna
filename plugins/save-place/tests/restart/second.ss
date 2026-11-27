(import (test) (save-place-test visits) (save-place))

(test "after a restart, a killed file reopens at its place and an open one at views' newer point"
  (check-equal? 4 (save-place-test/visits:reopened-point "b.txt"))
  (check-equal? 20 (save-place-test/visits:reopened-point "a.txt")))
