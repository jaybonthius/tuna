(import (tuna) (test) (test-runner) (test-user) (buffers) (views) (commands) (editing) (buffers-test) (terminal) (terminal-test))

(define t (terminal-test:shell!))

(define (refusals thunk)
  (map (lambda (c) (list (condition-who c) (condition-message c) (condition-irritants c))) (test-runner:reports-during thunk)))

(test "the plugin writes the buffer, which is read-only, so the user's edits are refused by its name, in copy mode as in any other"
  (terminal-test:show! t)
  (terminal:send! t "echo hello\r")
  (terminal-test:wait-for t "\nhello\n$ ")
  (check (buffers:read-only? t))
  (let ([before (terminal-test:text t)] [refused '(buffers:replace! "*terminal* is read-only" ())])
    (test-user:press! "C-c C-t")
    (check-equal? 'copy (terminal-test:input-mode))
    (views:set-point! (terminal-test:view) 2)
    (check-equal? (list refused) (refusals (lambda () (test-user:press! "C-k"))))
    (check-equal? (list refused) (refusals (lambda () (test-user:press! "C-d"))))
    (check-equal? (list refused) (refusals (lambda () (terminal-test:in-view (lambda () (commands:run editing:kill-line))))))
    (check-equal? before (terminal-test:text t))))

(test "in copy mode the plugin writes nothing to the buffer; leaving it writes the newest screen"
  (let ([before (terminal-test:text t)])
    (terminal:send! t "echo during-copy; printf '\\e]2;written\\a'\r")
    (test-runner:wait-until (lambda () (equal? "written" (terminal:title t))))
    (check-equal? before (terminal-test:text t))
    (test-user:press! "q")
    (terminal-test:wait-for t "during-copy\n$ ")
    (check-equal? '("$ echo hello" "hello" "$ echo during-copy; printf '\\e]2;written\\a'" "during-copy" "$ ")
                  (terminal-test:screen-lines t))))

(test "a printing key in copy mode leaves it and reaches the program"
  (test-user:press! "C-c C-t")
  (test-user:press! "a")
  (check-equal? 'semi-char (terminal-test:input-mode))
  (terminal-test:wait-for t "$ a")
  (check-equal? "$ a" (car (reverse (terminal-test:screen-lines t)))))

(test "C-x C-q enters copy mode, as ghostel's does, and the buffer stays read-only; made editable by name, its rows still refuse edits in words"
  (test-user:press! "C-c C-j")
  (check-equal? 'semi-char (terminal-test:input-mode))
  (test-user:press! "C-x C-q")
  (check-equal? '(copy #t) (list (terminal-test:input-mode) (buffers:read-only? t)))
  (views:set-point! (terminal-test:view) 2)
  (check-equal? '((buffers:replace! "*terminal* is read-only" ())) (refusals (lambda () (test-user:press! "C-k"))))
  (editing:read-only-mode t #f)
  (let ([before (terminal-test:text t)])
    (check-equal? '((buffers:replace! "the text of *terminal* is read-only" ())) (refusals (lambda () (test-user:press! "C-k"))))
    (check-equal? before (terminal-test:text t)))
  (editing:read-only-mode t #t)
  (test-user:press! "q"))
