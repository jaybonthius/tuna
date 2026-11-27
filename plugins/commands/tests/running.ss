(import (tuna) (test) (hooks) (plugins) (commands)
        (rename (only (chezscheme) sleep) (sleep chez:sleep)))

(define (raised? who message)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c)))))

(define events '())

(define (event! . e) (set! events (cons e events)))

(define (take-events!) (let ([e (reverse events)]) (set! events '()) e))

(define (run-values thunk) (call-with-values thunk list))

(define (reports-during thunk)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (thunk)
    (advice-remove! report keep)
    (reverse reported)))

(define (note-before c) (event! 'before c (commands:this-command) (commands:last-command)))

(define (note-after c) (event! 'after c (commands:this-command) (commands:last-command)))

(hooks:add! commands:before-command note-before)

(hooks:add! commands:after-command note-after)

(commands:define-command (inner [x (begin (event! 'reading-inner) 1)])
  "Notes what it sees."
  (event! 'inner (commands:this-command) (commands:last-command))
  x)

(commands:define-command (outer [x (begin (event! 'reading-outer (commands:this-command)) 2)])
  "Runs inner, then notes what it sees."
  (let ([v (commands:run inner)])
    (event! 'outer (commands:this-command) (commands:last-command))
    (+ x v)))

(commands:define-command (execute [command inner])
  "Runs COMMAND."
  (commands:run command))

(commands:define-command (twice)
  "Runs inner, then outer."
  (commands:run inner 1)
  (commands:run outer 1))

(commands:define-command (broken) "Raises." (event! 'broken) (car '()))

(commands:define-command (broken-reading [x (car '())]) "Raises reading X." x)

(commands:define-command (odd) "Raises a symbol." (raise 'oops))

(commands:define-command (catching)
  "Catches what broken raises."
  (guard (c [(assertion-violation? c) (condition-message c)])
    (commands:run broken)))

;; The main thread spins, so a thread watching for the spin keeps the
;; deadline: on a miss it cancels with the reason missed.
(define spinning #f)

(commands:define-command (spin) "Runs until quit." (set! spinning #t) (let loop () (loop)))

(commands:define-command (careful) "Warns, then returns." (warning 'careful "watch out") 'done)

(commands:define-command (noted) "Notes what it sees."
  (event! 'noted (commands:this-command) (commands:last-command)))

(commands:define-command (two) "Returns two values." (values 1 2))

(commands:define-command (owner [o (current-owner)]) "Returns the owners it sees." (list o (current-owner)))

(commands:define-command (prefixed [n (commands:prefix-number)]) "Returns N and the raw prefix." (list n (commands:prefix-argument)))

(commands:define-command (prefix) "Keeps the last command." (commands:keep-last-command!))

(commands:define-command (run-prefix) "Runs prefix." (commands:run prefix))

(commands:define-command (prefix-broken) "Keeps the last command, then raises." (commands:keep-last-command!) (car '()))

(test "before-command comes before the interactive expressions; in both hooks the run's command runs and the last command is the one before"
  (take-events!)
  (check-equal? 3 (commands:run outer))
  (check-equal? (list (list 'before outer outer #f) (list 'reading-outer outer) '(reading-inner) (list 'inner inner #f)
                      (list 'outer outer #f) (list 'after inner inner #f))
                (take-events!)))

(test "a run inside another calls neither hook, sees the same last command, and ends last, so it becomes the last command"
  (check-equal? #f (commands:this-command))
  (check (eq? inner (commands:last-command)))
  (check-equal? 11 (commands:run outer 10))
  (check-equal? (list (list 'before outer outer inner) '(reading-inner) (list 'inner inner inner) (list 'outer outer inner)
                      (list 'after inner inner inner))
                (take-events!))
  (check-equal? 5 (commands:run inner 5))
  (check-equal? (list (list 'before inner inner inner) (list 'inner inner inner) (list 'after inner inner inner))
                (take-events!)))

(test "the inner run that ended last becomes the last command, as M-x makes the command it runs the last one"
  (check-equal? 3 (commands:run execute outer))
  (check-equal? (list (list 'before execute execute inner) (list 'reading-outer outer) '(reading-inner) (list 'inner inner inner)
                      (list 'outer outer inner) (list 'after outer outer inner))
                (take-events!))
  (check-equal? 2 (commands:run twice))
  (check-equal? (list (list 'before twice twice outer) (list 'inner inner outer) '(reading-inner) (list 'inner inner outer)
                      (list 'outer outer outer) (list 'after outer outer outer))
                (take-events!)))

(test "a raise in an outermost run, in its body or its interactive expressions, is reported; after-command runs, and run returns no values"
  (let ([reported (reports-during (lambda () (check-equal? '() (run-values (lambda () (commands:run broken))))))])
    (check-equal? 1 (length reported))
    (check-equal? 'car (condition-who (car reported))))
  (check-equal? (list (list 'before broken broken outer) '(broken) (list 'after broken broken outer)) (take-events!))
  (let ([reported (reports-during (lambda () (check-equal? '() (run-values (lambda () (commands:run broken-reading))))))])
    (check-equal? 1 (length reported))
    (check (assertion-violation? (car reported))))
  (check-equal? (list (list 'before broken-reading broken-reading broken) (list 'after broken-reading broken-reading broken))
                (take-events!))
  (let ([reported (reports-during (lambda () (commands:run odd)))])
    (check-equal? '(oops) reported))
  (check-equal? (list (list 'before odd odd broken-reading) (list 'after odd odd broken-reading)) (take-events!)))

(test "a raise in an inner run reaches the outer command, and the inner run ended when it left"
  (check-equal? "~s is not a pair" (commands:run catching))
  (check-equal? (list (list 'before catching catching odd) '(broken) (list 'after broken broken odd)) (take-events!))
  (let ([reported (reports-during (lambda () (commands:run execute broken)))])
    (check-equal? 1 (length reported)))
  (check-equal? (list (list 'before execute execute broken) '(broken) (list 'after broken broken broken)) (take-events!)))

(test "a quit is reported, and after-command runs"
  (let* ([main (current-task)]
         [quitter (fork-task
                    (lambda (restore)
                      (let ([deadline (add-duration (current-time 'time-monotonic) (make-time 'time-duration 0 30))])
                        (let loop ()
                          (cond
                            [spinning (cancel-task main)]
                            [(time>? (current-time 'time-monotonic) deadline) (cancel-task main 'missed)]
                            [else (chez:sleep (make-time 'time-duration 1000000 0)) (loop)])))))]
         [reported (reports-during (lambda () (commands:run spin)))])
    (check-equal? 1 (length reported))
    (check (cancelled? (car reported)))
    (check-equal? #f (cancelled-reason (car reported))))
  (check-equal? (list (list 'before spin spin broken) (list 'after spin spin broken)) (take-events!)))

(test "a warning is reported and the command goes on"
  (let ([reported (reports-during (lambda () (check-equal? 'done (commands:run careful))))])
    (check-equal? 1 (length reported))
    (check (warning? (car reported))))
  (check-equal? (list (list 'before careful careful spin) (list 'after careful careful spin)) (take-events!)))

(test "a command a hook entry runs is an inner run: it calls no hook and does not become the last command"
  (let ([run-noted (lambda (c) (commands:run noted))])
    (hooks:add! commands:before-command run-noted)
    (hooks:add! commands:after-command run-noted)
    (check-equal? 4 (commands:run inner 4))
    (hooks:remove! commands:before-command run-noted)
    (hooks:remove! commands:after-command run-noted))
  (check-equal? (list (list 'before inner inner careful) (list 'noted noted careful) (list 'inner inner careful)
                      (list 'after inner inner careful) (list 'noted noted careful))
                (take-events!))
  (check (eq? inner (commands:last-command))))

(test "a raise from report is reported once more; one from that report is dropped; either way after-command runs once"
  (let* ([failing (lambda (next c) (if (eq? c 'oops) (raise 'report-failed) (next c)))]
         [reported (reports-during
                     (lambda ()
                       (advice-add! report failing)
                       (check-equal? '() (run-values (lambda () (commands:run odd))))
                       (advice-remove! report failing)))])
    (check-equal? '(report-failed) reported))
  (let ([always-failing (lambda (next c) (raise 'report-failed))])
    (advice-add! report always-failing)
    (check-equal? '() (run-values (lambda () (commands:run odd))))
    (advice-remove! report always-failing))
  (check-equal? (list (list 'before odd odd inner) (list 'after odd odd inner) (list 'before odd odd odd) (list 'after odd odd odd))
                (take-events!)))

(test "a command's values are run's values"
  (check-equal? '(1 2) (run-values (lambda () (commands:run two)))))

(test "the command and its interactive expressions run as the user, (repl)"
  (check-equal? (list (plugins:repl-owner) (plugins:repl-owner)) (commands:run owner)))

(test "run takes a command, on the main thread"
  (check-raises (raised? 'commands:run "not a command") (commands:run 'inner))
  (check-raises (raised? 'commands:run "not a command") (commands:run (lambda () 1)))
  (let ([outcome #f])
    (join-task (fork-task (lambda (restore) (set! outcome (guard (c [(assertion-violation? c) (condition-message c)]) (commands:run inner 1))))))
    (check-equal? "not on the main thread" outcome))
  (take-events!))

(test "the prefix argument is a thread parameter that refuses anything but a prefix; prefix-number reads it as a number"
  (check-equal? #f (commands:prefix-argument))
  (check-equal? '(1 7 -3 4 16 -1)
    (map (lambda (p) (parameterize ([commands:prefix-argument p]) (commands:prefix-number))) '(#f 7 -3 (4) (16) -)))
  (for-each
    (lambda (v)
      (check-raises (raised? 'commands:prefix-argument "not a prefix argument")
        (parameterize ([commands:prefix-argument v]) 'never)))
    '("4" (4 4) 1.5))
  (check-equal? '(4 (4)) (parameterize ([commands:prefix-argument '(4)]) (commands:run prefixed)))
  (check-equal? '(-1 -) (parameterize ([commands:prefix-argument '-]) (commands:run execute prefixed)))
  (join-task (fork-task (lambda (restore) (commands:prefix-argument 9))))
  (check-equal? #f (commands:prefix-argument))
  (take-events!))

(test "a run that keeps the last command leaves it as it was, and the hooks still see the command that ended"
  (check-equal? 1 (commands:run inner 1))
  (take-events!)
  (commands:run prefix)
  (commands:run run-prefix)
  (check-equal? (list (list 'before prefix prefix inner) (list 'after prefix prefix inner)
                      (list 'before run-prefix run-prefix inner) (list 'after prefix prefix inner))
                (take-events!))
  (check (eq? inner (commands:last-command))))

(test "a raise after the keep still keeps the last command"
  (check-equal? 2 (commands:run outer 1))
  (check-equal? 1 (length (reports-during (lambda () (commands:run prefix-broken)))))
  (check (eq? inner (commands:last-command)))
  (check-equal? (list (list 'before outer outer inner) '(reading-inner) (list 'inner inner inner) (list 'outer outer inner)
                      (list 'after inner inner inner) (list 'before prefix-broken prefix-broken inner)
                      (list 'after prefix-broken prefix-broken inner))
                (take-events!)))

(test "keep-last-command! raises outside a command and on another thread, and does nothing in a hook entry"
  (check-raises (raised? 'commands:keep-last-command! "no command is running") (commands:keep-last-command!))
  (let ([outcome #f])
    (join-task (fork-task (lambda (restore) (set! outcome (guard (c [(assertion-violation? c) (condition-message c)]) (commands:keep-last-command!))))))
    (check-equal? "not on the main thread" outcome))
  (let ([keep (lambda (c) (commands:keep-last-command!))])
    (commands:run twice)
    (hooks:add! commands:after-command keep)
    (commands:run inner 1)
    (hooks:remove! commands:after-command keep)
    (check (eq? inner (commands:last-command)))
    (commands:run twice)
    (hooks:add! commands:before-command keep)
    (commands:run inner 1)
    (hooks:remove! commands:before-command keep)
    (check (eq? inner (commands:last-command))))
  (take-events!))
