(import (tuna) (test) (test-runner) (test-user) (hooks) (buffers) (document) (views) (commands)
        (terminal) (terminal-test))

(define marks '())

(hooks:add! terminal:semantic-prompt (lambda (t mark code command) (set! marks (cons (list mark code command) marks))))

(define t (terminal-test:shell!))

(define (point-line) (document:line (buffers:document t) (views:point (terminal-test:view))))

(define (before-point n)
  (let ([p (views:point (terminal-test:view))]) (document:text (buffers:document t) (- p n) p)))

(test "bash starts with the plugin's integration, which reports the folder and marks prompts and commands"
  (terminal:send! t "cd /tmp && ls -d /tmp && false\r")
  (test-runner:wait-until (lambda () (equal? "/tmp" (terminal:directory t))))
  (terminal-test:wait-for t "\n$ ")
  (check-equal? '("$ cd /tmp && ls -d /tmp && false" "/tmp" "$ ") (terminal-test:screen-lines t))
  (check-equal? '((prompt #f #f) (prompt #f #f) (input #f #f) (command-start #f "cd /tmp && ls -d /tmp && false")
                  (command-end 1 #f) (prompt #f #f) (prompt #f #f) (input #f #f))
                (reverse marks)))

(test "a program sets its title, and the title hook runs"
  (let ([titles '()])
    (hooks:add! terminal:title-changed (lambda (t) (set! titles (cons (terminal:title t) titles))))
    (terminal:send! t "printf '\\e]2;building\\a'\r")
    (test-runner:wait-until (lambda () (pair? titles)))
    (check-equal? '("building") titles)
    (check-equal? "building" (terminal:title t))))

(test "the shell's marks lead to each prompt's input, in copy mode"
  (terminal-test:show! t)
  (check-equal? 4 (point-line))
  (test-user:press! "C-c M-p")
  (check-equal? 3 (point-line))
  (check-equal? 'copy (terminal-test:input-mode))
  (test-user:press! "C-c M-p")
  (check-equal? 1 (point-line))
  (test-user:press! "C-c M-n")
  (check-equal? 3 (point-line)))

(test "leaving copy mode brings point back to the program's cursor"
  (test-user:press! "q")
  (check-equal? 'semi-char (terminal-test:input-mode))
  (check-equal? 4 (point-line)))

(test "a view whose point is at the program's cursor follows it; a view moved away stays, until a key sent brings it back"
  (terminal:send! t "echo one\r")
  (terminal-test:wait-for t "\none\n$ ")
  (check-equal? "$ " (before-point 2))
  (views:set-point! (terminal-test:view) 5)
  (terminal:send! t "echo two\r")
  (terminal-test:wait-for t "\ntwo\n$ ")
  (check-equal? 5 (views:point (terminal-test:view)))
  (test-user:press! "SPC")
  (terminal-test:wait-for t "\n$  ")
  (check-equal? "$  " (before-point 3)))

(test "a terminal keeps no undo history"
  (check (buffers:silent? t)))

(test "terminal:open shows the terminal selected last, or with a prefix argument starts a new one"
  (terminal-test:show! (buffers:make "notes" ""))
  (commands:run terminal:open)
  (check (eq? t (views:buffer (terminal-test:view))))
  (terminal-test:show! (buffers:make "more notes" ""))
  (parameterize ([commands:prefix-argument '(4)]) (commands:run terminal:open))
  (check-equal? "*terminal*<2>" (buffers:name (views:buffer (terminal-test:view)))))
