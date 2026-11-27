(import (tuna) (test) (test-runner) (test-user) (options) (buffers) (views) (layout) (processes) (runs) (echo-area)
        (shell-commands) (shell-commands-test))

(define run shell-commands-test:run)

(define (minibuffer-question)
  (let ([shown (test-user:elements (test-user:screen) "minibuffer-question")])
    (and (pair? shown) (test-user:element-text (car shown)))))

(test "M-! reads a line and runs it; one line of output goes to the echo area and into *Shell Command Output*, unmodified"
  (test-user:press! "M-!")
  (check-equal? "Shell command: " (minibuffer-question))
  (test-user:type! "echo hi")
  (test-user:press! "RET")
  (test-runner:wait-until (lambda () (equal? "hi" (shell-commands-test:message))))
  (let ([out (buffers:find "*Shell Command Output*")])
    (check-equal? '("hi\n" #f) (list (shell-commands-test:text out) (buffers:modified? out))))
  (check-equal? "echo hi" (car (shell-commands:shell-command-history))))

(test "more than one line of output shows the buffer"
  (run shell-commands:shell-command "seq 3" #f)
  (check (member "*Shell Command Output*" (shell-commands-test:shown)))
  (check-equal? "1\n2\n3\n" (shell-commands-test:output-text)))

(test "no output tells how the program ended, and standard error joins the output"
  (run shell-commands:shell-command "false" #f)
  (check-equal? '("(Shell command failed with code 1 and no output)" "")
                (list (shell-commands-test:message) (shell-commands-test:output-text)))
  (run shell-commands:shell-command "true" #f)
  (check-equal? "(Shell command succeeded with no output)" (shell-commands-test:message))
  (run shell-commands:shell-command "kill -9 $$" #f)
  (check-equal? "(Shell command killed by signal 9 and no output)" (shell-commands-test:message))
  (run shell-commands:shell-command "echo out; echo err >&2" #f)
  (check-equal? "out\nerr\n" (shell-commands-test:output-text)))

(test "runs:shell names the shell and its switches, and runs:environment reaches the program"
  (options:set! runs:shell '("bash" "-c"))
  (run shell-commands:shell-command "echo $0" #f)
  (check-equal? "bash" (shell-commands-test:message))
  (options:set! runs:shell '("sh" "-c"))
  (run shell-commands:shell-command "echo $0,$TERM" #f)
  (check-equal? "sh,dumb" (shell-commands-test:message))
  (options:set! runs:shell '("/bin/sh" "-c")))

(test "an empty line is refused"
  (check-equal? '((shell-commands:shell-command "no command line" ()))
                (shell-commands-test:reported (lambda () (run shell-commands:shell-command "  " #f)))))

(test "with a prefix argument the output goes in at each cursor, from one run, with point before it and no mark"
  (let ([notes (buffers:make "notes" "a\nb\nc\n")] [v (shell-commands-test:view)])
    (layout:switch-to-buffer notes)
    (views:set-point! v 1)
    (views:add-cursor! v 3)
    (views:add-cursor! v 5)
    (run shell-commands:shell-command "printf x" '(4))
    (check-equal? '("xa\nxb\nxc\n" (1 4 7) (#f #f #f))
                  (list (shell-commands-test:text notes) (map views:cursor-point (views:cursors v)) (map views:cursor-mark (views:cursors v))))))

(test "with a prefix argument a buffer that refuses text at a cursor is found first, so the program never runs"
  (let ([ended-run (runs:start-for-user "*ended*" "true")])
    (shell-commands-test:ended ended-run)
    (layout:switch-to-buffer ended-run)
    (check-equal? '((shell-commands:shell-command "the buffer refuses the output" ("*ended*")))
                  (shell-commands-test:reported (lambda () (run shell-commands:shell-command "touch $HOME/ran; echo out" '(4)))))
    (check-equal? #f (file-exists? (shell-commands-test:home-path "ran")))))

(test "a line ending in & runs as M-&"
  (run shell-commands:shell-command "echo later &" #f)
  (let ([async (buffers:find "*Async Shell Command*")])
    (check-equal? 0 (shell-commands-test:ended async))
    (check-equal? "later" (shell-commands-test:output async))))

(test "C-g stops a program M-! waits for"
  (layout:switch-to-buffer (buffers:make "plain" "text\n"))
  (test-user:press! "M-!")
  (test-user:type! "sleep 30; echo never")
  (test-user:press! "RET")
  (test-runner:wait-until
    (lambda () (exists (lambda (p) (member "sleep 30; echo never" (processes:command-line p))) (processes:all))))
  (check (for-all cancelled? (shell-commands-test:reports-during (lambda () (test-user:press! "C-g")))))
  (check-equal? "Quit" (shell-commands-test:message))
  (test-runner:wait-until
    (lambda () (not (exists (lambda (p) (member "sleep 30; echo never" (processes:command-line p))) (processes:all))))))

