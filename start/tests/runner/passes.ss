(import (tuna) (test) (answers))

(test "a test file's owner is named after its plugin and its path under tests/"
  (check-equal? '(test-file start runner passes) (owner-name (current-owner))))

(test "the lib/ of the tests folder is the user's lib/"
  (check-equal? 42 (answers:answer)))

(test "a test file runs in a home of its own"
  (check-equal? (current-directory) (getenv "HOME")))
