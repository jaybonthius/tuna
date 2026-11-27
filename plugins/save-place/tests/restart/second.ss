(import (test) (visits) (save-place))

(test "after a restart, a killed file reopens at its place and an open one at views' newer point"
  (check-equal? 4 (visits:reopened-point "b.txt"))
  (check-equal? 20 (visits:reopened-point "a.txt")))
