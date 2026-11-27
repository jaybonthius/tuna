(import (tuna) (test) (test-browser))

(test "with no chromium on the PATH open raises"
  (putenv "PATH" "/nonexistent")
  (check-raises (lambda (e) (and (error? e) (equal? "no chromium on PATH" (condition-message e)))) (test-browser:open)))
