(import (tuna) (test) (test-runner) (buffers) (terminal) (terminal-test))

(test "after a restart the shell's terminal comes back with its screen and scrollback, a line saying the shell ended, and a new shell in its last folder; the command does not run again"
  (test-runner:wait-until (lambda () (buffers:find "*terminal*")))
  (let ([t (buffers:find "*terminal*")])
    (check (terminal:terminal? t))
    (terminal-test:wait-for t "$ ")
    (terminal:send! t "pwd\r")
    (terminal-test:wait-for t "\n/tmp\n$ ")
    (check-equal? (append '("$ cd /tmp; seq 1 30") (map (lambda (i) (number->string (+ i 1))) (iota 30)) '("$ " "[The shell ended.]" "$ pwd" "/tmp" "$ "))
                  (filter (lambda (l) (not (string=? l ""))) (terminal-test:lines (terminal-test:text t))))
    (check-equal? #f (buffers:find "*sleep*"))))
