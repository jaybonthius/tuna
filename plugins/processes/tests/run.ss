(import (tuna) (test) (test-runner) (processes))

(define (violation thunk)
  (guard (c [(assertion-violation? c) (list (condition-who c) (condition-message c))])
    (thunk)
    'no-violation))

(define (error-message thunk)
  (guard (c [(error? c) (condition-message c)])
    (thunk)
    'no-error))

(define (run . arguments) (call-with-values (lambda () (apply processes:run arguments)) list))

(define (output-line program arguments directory)
  (let-values ([(status out err) (processes:run program arguments #f (processes:options [directory directory]))])
    (let ([text (utf8->string out)]) (substring text 0 (- (string-length text) 1)))))

(test "processes:run returns the exit status, all the output and all the standard error, which joins the output unless kept apart"
  (check-equal? (list 0 (string->utf8 "main\n") #vu8()) (run "printf" '("main\n")))
  (check-equal? (list 4 (string->utf8 "out\n") (string->utf8 "err\n"))
    (run "sh" '("-c" "echo out; echo err >&2; exit 4") #f (processes:options [separate-stderr #t])))
  (check-equal? (list 4 (string->utf8 "out\nerr\nagain\n") #vu8())
    (run "sh" '("-c" "echo out; echo err >&2; echo again; exit 4"))))

(test "processes:run writes its input, a string as UTF-8 or a bytevector, then closes standard input, which without input closes at once"
  (check-equal? (list 0 (string->utf8 "input as text") #vu8()) (run "cat" '() "input as text"))
  (check-equal? (list 0 (bytevector 1 2 3) #vu8()) (run "cat" '() (bytevector 1 2 3)))
  (check-equal? (list 0 #vu8() #vu8()) (run "cat" '())))

(test "processes:run returns all of a long output"
  (let-values ([(status out err) (processes:run "head" '("-c" "3000000" "/dev/zero"))])
    (check-equal? 0 status)
    (check-equal? 3000000 (bytevector-length out))))

(test "processes:run applies the directory and environment options"
  (check-equal? (list 0 (string->utf8 "/\nhi\n") #vu8())
    (run "sh" '("-c" "pwd; echo $GREETING") #f (processes:options [directory "/"] [environment '(("GREETING" . "hi"))]))))

(test "a directory starting with ~ or ~user is expanded when the program starts"
  (mkdir (string-append (getenv "HOME") "/sub"))
  (check-equal? (getenv "HOME") (output-line "pwd" '() "~"))
  (check-equal? (string-append (getenv "HOME") "/sub") (output-line "pwd" '() "~/sub"))
  (let ([user (output-line "id" '("-un") #f)])
    (check-equal? (output-line "sh" (list "-c" (string-append "getent passwd " user " | cut -d: -f6")) #f)
                  (output-line "pwd" '() (string-append "~" user))))
  (check-equal? "cannot run pwd: No such file or directory"
    (error-message (lambda () (processes:run "pwd" '() #f (processes:options [directory "~no-such-user/sub"]))))))

(test "processes:run raises for a terminal, and in the task for a program that cannot start"
  (check-equal? '(processes:run "a program run to its end has no terminal")
    (violation (lambda () (processes:run "true" '() #f (processes:options [terminal '(24 . 80)])))))
  (check-equal? "cannot run no-such-program: No such file or directory"
    (error-message (lambda () (processes:run "no-such-program" '())))))

(test "the program processes:run runs is the caller's own process, and a cancel that ends the task stops it"
  (let* ([running (spawn-task (lambda (restore) (processes:run "sleep" '("10"))))]
         [sleeper (lambda () (find (lambda (p) (equal? '("sleep" "10") (processes:command-line p))) (processes:all)))])
    (test-runner:wait-until sleeper)
    (let ([sleeper (sleeper)])
      (check-equal? (current-owner) (processes:owner sleeper))
      (cancel-task running 'stop)
      (check-equal? '(cancelled stop) (call-with-values (lambda () (join-task running)) list))
      (test-runner:wait-until (lambda () (processes:status sleeper)))
      (check-equal? -1 (processes:status sleeper))
      (test-runner:wait-until (lambda () (not (memq sleeper (processes:all))))))))

(test "once processes:run returns or raises, its process is no longer in processes:all"
  (processes:run "true" '())
  (check-equal? '() (processes:all))
  (error-message (lambda () (processes:run "no-such-program" '())))
  (check-equal? '() (processes:all)))

(test "processes:run checks its arguments"
  (check-equal? '(processes:run "not a string or bytevector") (violation (lambda () (processes:run "cat" '() 'input))))
  (check-equal? '(processes:run "not a string free of NUL characters") (violation (lambda () (processes:run 'cat '())))))
