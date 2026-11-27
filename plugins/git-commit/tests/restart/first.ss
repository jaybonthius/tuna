(import (tuna) (test) (test-user) (buffers) (layout) (files) (echo-area) (git-commit) (git-test repositories))

(git-test/repositories:git! "" "init" "-q" "repo")
(git-test/repositories:write-file! "repo/.git/COMMIT_EDITMSG" "\n# Please enter the commit message.\n")

(define m (files:visit (git-test/repositories:path "repo/.git/COMMIT_EDITMSG")))

(layout:switch-to-buffer m)

(test "C-c M-s keeps the message"
  (buffers:replace! m 1 1 "Kept across a restart")
  (test-user:press! "C-c M-s")
  (check-equal? "Kept across a restart" (car (git-commit:messages))))
