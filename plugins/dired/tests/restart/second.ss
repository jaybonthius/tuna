(import (tuna) (test) (test-runner) (buffers) (echo-area) (dired))

(define (listings) (list-sort string<? (map buffers:name (filter dired:folder (buffers:all)))))

(test "after a restart the listings of folders that still exist come back, and a message names the one gone"
  (test-runner:wait-until (lambda () (equal? '("~/src/tuna/") (listings))))
  (test-runner:wait-until echo-area:current-message)
  (check-equal? "Folder ~/notes/ no longer exists" (echo-area:current-message)))
