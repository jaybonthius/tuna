(import (tuna) (test) (test-runner) (processes) (recorder) (setting))

(define (reports-during thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (thunk)
    (advice-remove! report keep)
    (reverse reported)))

(define (violation thunk)
  (guard (c [(assertion-violation? c) (list (condition-who c) (condition-message c))])
    (thunk)
    'no-violation))

(define (syntax-message form)
  (guard (c [(syntax-violation? c) (condition-message c)])
    (eval form (interaction-environment))
    'no-violation))

(define (ignore-output bytes end) (void))

(define (start-recorded program arguments . options)
  (let ([r (recorder:make)])
    (apply processes:start program arguments (recorder:on-output r) (recorder:on-exit r) options)
    r))

(test "an own process's output reaches on-output in order, each piece with the offset after it, then the end, then the exit status"
  (let* ([r (recorder:make)]
         [p (processes:start "printf" '("one\ntwo\n") (recorder:on-output r) (recorder:on-exit r))])
    (check-equal? '((output "one\ntwo\n" 8) (eof 8) (exit 0)) (recorder:wait-for-exit r))
    (check (processes:process? p))
    (check (not (processes:process? 'p)))
    (check-equal? 0 (processes:status p))
    (check-equal? (current-owner) (processes:owner p))
    (check-equal? '("printf" "one\ntwo\n") (processes:command-line p))
    (check (not (memq p (processes:all))))))

(test "on-output runs in a task on the main thread, as the module that started the process"
  (let ([seen #f] [done? #f] [main (get-thread-id)])
    (processes:start "printf" '("x")
      (lambda (bytes end)
        (unless (eof-object? bytes)
          (set! seen (list (current-owner) (task? (current-task)) (eqv? (get-thread-id) main)))))
      (lambda (status) (set! done? #t)))
    (test-runner:wait-until (lambda () done?))
    (check-equal? (list (current-owner) #t #t) seen)))

(test "the exit status is the exit code, or -n when signal n ended the program"
  (check-equal? '((eof 0) (exit 3)) (recorder:wait-for-exit (start-recorded "sh" '("-c" "exit 3"))))
  (check-equal? '((eof 0) (exit -15)) (recorder:wait-for-exit (start-recorded "sh" '("-c" "kill -TERM $$")))))

(test "a program that cannot start goes to report, then to on-exit as its condition, after the end of output"
  (let* ([r (recorder:make)] [missing #f]
         [reported (reports-during
                     (lambda ()
                       (set! missing (processes:start "no-such-program" '() (recorder:on-output r) (recorder:on-exit r)))
                       (recorder:wait-for-exit r)))])
    (check-equal? 1 (length reported))
    (let ([events (recorder:events r)])
      (check-equal? '(eof 0) (car events))
      (check-equal? (car reported) (cadr (cadr events))))
    (check-equal? #f (processes:pid missing))
    (check (condition? (processes:status missing)))
    (check (not (memq missing (processes:all))))))

(test "a program without a / is looked up in the PATH of its environment, which adds to Tuna's and loses a variable given #f"
  (check-equal? '((output "hi--sh\n" 7) (eof 7) (exit 0))
    (recorder:wait-for-exit
      (start-recorded "sh" '("-c" "echo \"$GREETING-$HOME-$0\"")
        (processes:options [environment '(("GREETING" . "hi") ("HOME" . #f))]))))
  (let* ([r #f]
         [reported (reports-during
                     (lambda ()
                       (set! r (start-recorded "printf" '("x") (processes:options [environment '(("PATH" . "/nowhere"))])))
                       (recorder:wait-for-exit r)))])
    (check-equal? 1 (length reported))
    (check (condition? (cadr (assq 'exit (recorder:events r)))))))

(test "a process runs in the directory its options give"
  (check-equal? '((output "/\n" 2) (eof 2) (exit 0))
    (recorder:wait-for-exit (start-recorded "pwd" '() (processes:options [directory "/"])))))

(test "standard error joins the output, unless separate-stderr keeps it apart for processes:error-output"
  (let* ([both "echo out; echo err >&2"]
         [joined (recorder:make)]
         [joined-process (processes:start "sh" (list "-c" both) (recorder:on-output joined) (recorder:on-exit joined))]
         [apart (recorder:make)]
         [apart-process (processes:start "sh" (list "-c" both) (recorder:on-output apart) (recorder:on-exit apart)
                          (processes:options [separate-stderr #t]))])
    (check-equal? '((output "out\nerr\n" 8) (eof 8) (exit 0)) (recorder:wait-for-exit joined))
    (check-equal? #f (processes:error-output joined-process))
    (check-equal? '((output "out\n" 4) (eof 4) (exit 0)) (recorder:wait-for-exit apart))
    (check-equal? "err\n" (utf8->string (processes:error-output apart-process)))))

(test "processes:report-error-output reports the first line of standard error as a warning from the who given, and nothing when there is none"
  (let* ([r (recorder:make)]
         [complaining (processes:start "sh" '("-c" "echo 'bad flag' >&2; echo more >&2; exit 2")
                        (recorder:on-output r) (recorder:on-exit r) (processes:options [separate-stderr #t]))]
         [joined-recorder (recorder:make)]
         [joined (processes:start "sh" '("-c" "echo err >&2") ignore-output (recorder:on-exit joined-recorder))])
    (check-equal? '((eof 0) (exit 2)) (recorder:wait-for-exit r))
    (recorder:wait-for-exit joined-recorder)
    (let ([reported (reports-during (lambda () (processes:report-error-output complaining 'my-lister)))])
      (check-equal? 1 (length reported))
      (check (warning? (car reported)))
      (check-equal? 'my-lister (condition-who (car reported)))
      (check-equal? "bad flag" (condition-message (car reported))))
    (check-equal? '() (reports-during (lambda () (processes:report-error-output joined 'my-lister))))
    (check-equal? '(processes:report-error-output "not a symbol or string")
      (violation (lambda () (processes:report-error-output complaining 3))))
    (check-equal? '(processes:report-error-output "not a process")
      (violation (lambda () (processes:report-error-output 'complaining 'my-lister))))))

(test "output not yet delivered stops reading at processes:log-size bytes, so a flood comes in pieces no larger, whole and in order"
  (setting:with processes:log-size 1000
    (lambda ()
    (let* ([pieces '()] [done? #f])
      (processes:start "head" '("-c" "100000" "/dev/zero")
        (lambda (bytes end)
          (if (eof-object? bytes)
              (set! done? #t)
              (set! pieces (cons (cons (bytevector-length bytes) end) pieces))))
        (lambda (status) (void)))
      (test-runner:wait-until (lambda () done?))
      (let ([pieces (reverse pieces)])
        (check-equal? 100000 (apply + (map car pieces)))
        (check (for-all (lambda (piece) (<= (car piece) 1000)) pieces))
        (check (let loop ([pieces pieces] [at 0])
                 (or (null? pieces)
                     (and (= (cdar pieces) (+ at (caar pieces))) (loop (cdr pieces) (cdar pieces)))))))))))

(test "a raise in on-output or on-exit goes to report, and delivery goes on"
  (let* ([r (recorder:make)]
         [record-output (recorder:on-output r)]
         [reported (reports-during
                     (lambda ()
                       (processes:start "printf" '("x")
                         (lambda (bytes end) (if (eof-object? bytes) (record-output bytes end) (car bytes)))
                         (recorder:on-exit r))
                       (recorder:wait-for-exit r)))])
    (check-equal? '((eof 1) (exit 0)) (recorder:events r))
    (check-equal? 1 (length reported))
    (check-equal? 'car (condition-who (car reported))))
  (let* ([status #f]
         [reported (reports-during
                     (lambda ()
                       (processes:start "true" '() ignore-output (lambda (s) (set! status s) (cdr s)))
                       (test-runner:wait-until (lambda () status))))])
    (check-equal? 1 (length reported))
    (check-equal? 'cdr (condition-who (car reported)))))

(test "processes:all lists the processes running, oldest first"
  (let* ([first (processes:start "sleep" '("5") ignore-output)] [second (processes:start-for-user "sleep" '("5"))])
    (check-equal? (list first second) (filter (lambda (p) (memq p (list first second))) (processes:all)))
    (processes:stop! first)
    (processes:stop! second)))

(test "processes:start checks its arguments, and only the main thread starts a process"
  (check-equal? '(processes:start "not a string free of NUL characters")
    (violation (lambda () (processes:start "a\x0;b" '() ignore-output))))
  (check-equal? '(processes:start "not a list of strings free of NUL characters")
    (violation (lambda () (processes:start "printf" '(x) ignore-output))))
  (check-equal? '(processes:start "not a list of strings free of NUL characters")
    (violation (lambda () (processes:start "printf" "x" ignore-output))))
  (check-equal? '(processes:start "not a procedure") (violation (lambda () (processes:start "printf" '() 'output))))
  (check-equal? '(processes:start "not processes:options")
    (violation (lambda () (processes:start "printf" '() ignore-output (lambda (status) (void)) 'options))))
  (check-equal? '(processes:start "not on the main thread")
    (test-runner:join (fork-task (lambda (restore) (violation (lambda () (processes:start "printf" '() ignore-output))))))))

(test "processes:options takes each clause at most once, #f meaning its default, and checks each value"
  (check (processes:options? (processes:options)))
  (check (processes:options? (processes:options [directory #f] [environment #f] [terminal #f] [separate-stderr #f] [full-log #f])))
  (check (not (processes:options? 'options)))
  (check-equal? "unknown clause" (syntax-message '(processes:options [directory "/"] [shell "bash"])))
  (check-equal? "clause given twice" (syntax-message '(processes:options [directory "/"] [directory "/tmp"])))
  (check-equal? "expected (processes:options [name value] ...)" (syntax-message '(processes:options directory)))
  (check-equal? '(processes:options "not a directory string or #f") (violation (lambda () (processes:options [directory 'root]))))
  (check-equal? '(processes:options "not an association list of variable names and values")
    (violation (lambda () (processes:options [environment '(("A=B" . "c"))]))))
  (check-equal? '(processes:options "not an association list of variable names and values")
    (violation (lambda () (processes:options [environment '(("A" . c))]))))
  (check-equal? '(processes:options "not a pair of rows and columns from 0 to 65535, or #f")
    (violation (lambda () (processes:options [terminal '(24 . -1)]))))
  (check-equal? '(processes:options "not a boolean") (violation (lambda () (processes:options [separate-stderr 'yes]))))
  (check-equal? '(processes:options "not a processes:full-log action or #f")
    (violation (lambda () (processes:options [full-log 'keep]))))
  (check-equal? '(processes:options "a terminal joins standard error to the output")
    (violation (lambda () (processes:options [terminal '(24 . 80)] [separate-stderr #t]))))
  (check-equal? 'pause (processes:full-log pause))
  (check-equal? "universe of full-log does not include specified symbol" (syntax-message '(processes:full-log keep))))

(test "each options clause has an accessor, and processes:environment? is the rule for an environment"
  (let ([given (processes:options [directory "/"] [environment '(("A" . "b"))] [separate-stderr #t]
                                  [full-log (processes:full-log pause)])])
    (check-equal? '("/" (("A" . "b")) #f #t pause)
      (map (lambda (accessor) (accessor given))
           (list processes:options-directory processes:options-environment processes:options-terminal
                 processes:options-separate-stderr processes:options-full-log))))
  (check-equal? '(24 . 80) (processes:options-terminal (processes:options [terminal (cons 24 80)])))
  (check-equal? '(processes:options-full-log "not processes:options")
    (violation (lambda () (processes:options-full-log 'options))))
  (check-equal? '(#t #t #f #f #f #f)
    (map processes:environment? (list '(("A" . "b") ("C" . #f)) '() '(("A=B" . "c")) '(("" . "c")) '(("A" . "b\x0;")) 'x)))
  (check-equal? 1048576 (processes:log-size)))

(test "processes:start is a changeable definition that advice reaches"
  (let* ([started '()]
         [logged (lambda (start program arguments . rest)
                   (set! started (cons program started))
                   (apply start program arguments rest))])
    (advice-add! processes:start logged)
    (let ([r (start-recorded "true" '())])
      (advice-remove! processes:start logged)
      (check-equal? '((eof 0) (exit 0)) (recorder:wait-for-exit r))
      (check-equal? '("true") started))))

(test "input is written in order by a thread of the plugin, and closing it ends the program's input once the queue is written"
  (let* ([r (recorder:make)] [cat (processes:start "cat" '() (recorder:on-output r) (recorder:on-exit r))])
    (processes:send! cat "one ")
    (processes:send! cat (string->utf8 "two"))
    (processes:close-input! cat)
    (check-equal? '((output "one two" 7) (eof 7) (exit 0)) (recorder:wait-for-exit r))))

(test "input sent after the program ended does nothing; input sent after it was closed raises"
  (let ([r (recorder:make)])
    (let ([ended (processes:start "true" '() ignore-output (recorder:on-exit r))])
      (recorder:wait-for-exit r)
      (processes:send! ended "after the end does nothing")))
  (let ([closed (processes:start "cat" '() ignore-output)])
    (processes:close-input! closed)
    (check-equal? '(processes:send! "the input was closed") (violation (lambda () (processes:send! closed "x"))))
    (check-equal? '(processes:send! "not a string or bytevector") (violation (lambda () (processes:send! closed 'x))))
    (check-equal? '(processes:send! "not a process") (violation (lambda () (processes:send! 'cat "x"))))
    (check-equal? '(processes:close-input! "not a process") (violation (lambda () (processes:close-input! 'cat))))))

(test "on a terminal of the size given, the program's streams are the terminal, a resize reaches it, and closing the input sends C-d"
  (let* ([lines '()] [r (recorder:make)]
         [tty (processes:start-for-user "sh" '("-c" "stty size; read line; stty size; tty")
                (processes:options [terminal '(24 . 80)]))])
    (processes:attach! tty 0 (processes:line-receiver 0 (lambda (line end) (set! lines (cons line lines)))) (recorder:on-exit r))
    (test-runner:wait-until (lambda () (pair? lines)))
    (processes:resize! tty 30 100)
    (processes:send! tty "go\n")
    (check-equal? '((exit 0)) (recorder:wait-for-exit r))
    (let ([lines (reverse lines)])
      (check-equal? '("24 80" "go" "30 100") (list-head lines 3))
      (check-equal? "/dev/" (substring (list-ref lines 3) 0 5)))
    (check-equal? '(processes:resize! "not a number of rows from 0 to 65535") (violation (lambda () (processes:resize! tty -1 10))))
    (check-equal? '(processes:resize! "not a number of columns from 0 to 65535")
      (violation (lambda () (processes:resize! tty 10 'wide)))))
  (let ([r (recorder:make)])
    (processes:close-input!
      (processes:start "cat" '() (recorder:on-output r) (recorder:on-exit r) (processes:options [terminal '(24 . 80)])))
    (check-equal? '(exit 0) (car (reverse (recorder:wait-for-exit r)))))
  (let ([cat (processes:start "cat" '() ignore-output)])
    (check-equal? '(processes:resize! "not a process with a terminal") (violation (lambda () (processes:resize! cat 10 10))))
    (check-equal? #f (processes:foreground-group cat))
    (processes:stop! cat)))

(test "a terminal's foreground group is the program's own until a job holds the terminal, and #f once stopped"
  (let* ([r (recorder:make)]
         [job-shell (processes:start "sh" '("-c" "read line; set -m; sleep 5") (recorder:on-output r) (recorder:on-exit r)
                      (processes:options [terminal '(24 . 80)]))])
    (test-runner:wait-until (lambda () (and (processes:pid job-shell) (processes:foreground-group job-shell))))
    (check-equal? (processes:pid job-shell) (processes:foreground-group job-shell))
    (processes:send! job-shell "\n")
    (test-runner:wait-until
      (lambda () (not (eqv? (processes:foreground-group job-shell) (processes:pid job-shell)))))
    (check (integer? (processes:foreground-group job-shell)))
    (processes:stop! job-shell)
    (check-equal? #f (processes:foreground-group job-shell))
    (check-equal? '(exit -1) (car (reverse (recorder:wait-for-exit r))))))
