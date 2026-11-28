(import (tuna) (test) (test-runner) (test-user) (options) (hooks) (ask) (buffers) (views) (modes) (commands) (processes)
        (buffers-test) (terminal) (terminal-test))

(test "a terminal runs a program on a pseudo-terminal and shows its screen in a buffer named after the program"
  (let ([t (terminal:start '("sh" "-c" "echo hello; echo world; read x; echo got $x; read y"))])
    (terminal-test:wait-for t "world")
    (check-equal? '("hello" "world") (terminal-test:screen-lines t))
    (check-equal? '(#t #f "*sh*") (list (terminal:terminal? t) (terminal:terminal? (buffers:make "plain" "")) (buffers:name t)))
    (check (eq? terminal:mode (modes:major-mode t)))
    (let ([p (terminal:process t)])
      (check-equal? #f (processes:owner p))
      (check (eq? t (processes:buffer p)))
      (terminal:send! t "it\r")
      (terminal-test:wait-for t "got it")
      (check-equal? '("hello" "world" "it" "got it") (terminal-test:screen-lines t))
      (check-equal? 24 (length (terminal-test:lines (terminal-test:text t))))
      (terminal:send! t "\r")
      (test-runner:wait-until (lambda () (not (buffers:live? t))))
      (check-equal? 0 (processes:status p)))))

(test "a screen holds one line per row, of 80 columns and 24 rows when no client's input started it"
  (let ([t (terminal:start '("sh" "-c" "stty size; sleep 30"))])
    (terminal-test:wait-for t "24 80")
    (check-equal? 23 (length (filter (lambda (c) (char=? c #\newline)) (string->list (terminal:screen-text t)))))
    (buffers:kill! t)))

(test "a second terminal of a name in use gets <2>, and options give the folder and environment"
  (let* ([a (terminal:start '("sh" "-c" "pwd; echo $GREETING; sleep 30")
                            (processes:options [directory "/tmp"] [environment '(("GREETING" . "hi"))]))]
         [b (terminal:start '("sh" "-c" "sleep 30"))])
    (check-equal? '("*sh*" "*sh*<2>") (map buffers:name (list a b)))
    (terminal-test:wait-for a "hi")
    (check-equal? '("/tmp" "hi") (terminal-test:screen-lines a))
    (check-equal? '("/tmp" "") (list (terminal:directory a) (terminal:title a)))
    (for-each buffers:kill! (list a b))))

(test "options that give the clauses the terminal sets itself raise before any program starts"
  (for-each
    (lambda (options)
      (check-raises (buffers-test:raised? 'terminal:start "options other than a directory and an environment")
                    (terminal:start '("true") options)))
    (list (processes:options [separate-stderr #t]) (processes:options [terminal (cons 24 80)])
          (processes:options [full-log (processes:full-log drop)]))))

(test "new programs get the plugin's terminal type and its compiled entry"
  (let ([c (terminal:start '("sh" "-c" "echo $TERM $COLORTERM $TERM_PROGRAM; infocmp -x | grep -c Ms=; sleep 30"))])
    (terminal-test:wait-for c "\n1")
    (check-equal? '("xterm-ghostty truecolor tuna" "1") (terminal-test:screen-lines c))
    (buffers:kill! c)))

(test "with kill-buffer-on-exit? off the buffer stays with a line saying how the program ended, the exited hook gets the status, and a key warns"
  (let ([statuses '()])
    (options:set! terminal:kill-buffer-on-exit? #f)
    (hooks:add! terminal:exited (lambda (t status) (set! statuses (cons (list t status) statuses))))
    (let ([d (terminal:start '("sh" "-c" "echo bye; exit 3"))])
      (test-runner:wait-until (lambda () (pair? statuses)))
      (check-equal? (list (list d 3)) statuses)
      (check (buffers:live? d))
      (check-equal? '("bye" "[The program exited with code 3.]") (terminal-test:screen-lines d))
      (terminal-test:show! d)
      (check-equal? '("the program has ended")
        (map condition-message (test-runner:reports-during (lambda () (test-user:press! "x")))))
      (check-raises (buffers-test:raised-with? 'terminal:send! "the program has ended" (list d))
                    (terminal:send! d "x"))
      (buffers:kill! d))
    (let ([unfinished (terminal:start '("sh" "-c" "printf half; kill -9 $$"))])
      (test-runner:wait-until (lambda () (= 2 (length statuses))))
      (check-equal? '("half" "[The program ended by signal 9.]") (terminal-test:screen-lines unfinished))
      (buffers:kill! unfinished))
    (options:unset! terminal:kill-buffer-on-exit?)))

(test "when the program ends its buffer goes, and the view that showed it shows the buffer it showed before"
  (let ([plain (buffers:make "before" "")] [t (terminal:start '("sh" "-c" "read x"))])
    (terminal-test:show! plain)
    (terminal-test:show! t)
    (terminal:send! t "\r")
    (test-runner:wait-until (lambda () (not (buffers:live? t))))
    (check (eq? plain (views:buffer (terminal-test:view))))))

(test "killing a terminal's buffer ends its program"
  (let* ([a (terminal:start '("sh" "-c" "sleep 30"))] [p (terminal:process a)])
    (buffers:kill! a)
    (test-runner:wait-until (lambda () (processes:status p)))
    (check-equal? -1 (processes:status p))))

(define idle #f)

(commands:define-command (kill-idle)
  "Kills the idle shell's terminal."
  (buffers:kill! idle))

(test "the plugin's writes leave no unsaved text, so killing an idle shell from a command asks nothing"
  (set! idle (terminal-test:shell!))
  (check-equal? #f (buffers:modified? idle))
  (let ([asked '()])
    (options:with ([ask:y-or-n-reader (lambda (question) (set! asked (cons question asked)) #f)])
      (commands:run kill-idle))
    (check-equal? '() asked))
  (check-equal? #f (buffers:live? idle)))
