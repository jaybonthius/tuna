(import (tuna) (test) (test-runner) (files) (files-test session))

(define (home-paths . names) (map files-test/session:home-path names))

(test "after a restart the recent files are as they were, less those that are gone, which leave the list as files loads"
  (test-runner:wait-until (lambda () (equal? (home-paths "c.txt" "a.txt") (files:recent-files)))))

(exit)
