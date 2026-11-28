(import (tuna) (test) (test-runner) (test-user) (editing) (minibuffer) (command-picker) (shell-commands) (shell-commands-test))

(test "M-p in M-! offers the line given before the restart"
  (test-user:press! "M-! M-p")
  (check-equal? "echo kept" (shell-commands-test:input))
  (check (for-all cancelled? (test-runner:reports-during (lambda () (test-user:press! "C-g"))))))

(test "M-p in compile offers the line given before the restart"
  (test-user:press! "M-x")
  (test-user:type! "shell-commands:compile")
  (test-user:press! "RET M-p")
  (check-equal? "echo built" (shell-commands-test:input))
  (check (for-all cancelled? (test-runner:reports-during (lambda () (test-user:press! "C-g"))))))
