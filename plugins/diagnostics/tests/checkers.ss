(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (tables) (timers) (keys) (modes) (buffers) (document)
        (files) (views) (layout) (processes) (ask) (diagnostics) (diagnostics-test marks) (diagnostics-test linter))

;; ask's own writer reports each message, such as the Wrote of a save, as
;; a warning, which would fail the file.
(options:set! ask:message-writer (lambda (text) (void)))

(options:set! diagnostics:check-delay 0.05)

(keys:bind! keys:global "C-c c" diagnostics:check)

;; The claims are that no checker runs, so the check waits well past
;; diagnostics:check-delay first.
(define (past-delay) (timers:sleep 0.3))

(define runs '())

(define (runs!)
  (let ([r runs])
    (set! runs '())
    r))

(define (check-beta b)
  (set! runs (cons b runs))
  (list (diagnostics-test/marks:warn b "beta" "checked")))

(define (reports-during thunk)
  (map condition-message (test-runner:reports-during thunk 1)))

(define folder (string-append (getenv "HOME") "/project"))

(mkdir folder)

(define plain
  (let ([path (string-append folder "/plain.txt")])
    (with-output-to-file path (lambda () (display "alpha beta\n")))
    (files:visit path)))

(buffers:with-buffer plain (hooks:add-local! diagnostics:checkers check-beta))

(test "a checker runs when the mode turns on, once the delay has passed since the last edit, and after a save; its findings are its source's report"
  (diagnostics-test/marks:mode! plain #t)
  (test-runner:wait-until (lambda () (pair? runs)))
  (check-equal? (list (list plain) '(("beta" warning "checked")) '(("beta" (diagnostic.warning) "checked")))
                (list (runs!) (diagnostics-test/marks:all-seen plain) (diagnostics-test/marks:marks plain)))
  (buffers:insert! plain 1 "x")
  (check-equal? '() runs)
  (test-runner:wait-until (lambda () (pair? runs)))
  (check-equal? (list (list plain) '(("beta" warning "checked"))) (list (runs!) (diagnostics-test/marks:all-seen plain))))

(test "with check-delay #f an edit runs no checker, and a save still does"
  (options:set! diagnostics:check-delay #f)
  (buffers:insert! plain 1 "y")
  (past-delay)
  (check-equal? '() runs)
  (files:save-buffer plain)
  (test-runner:wait-until (lambda () (pair? runs)))
  (check-equal? (list plain) (runs!))
  (options:set! diagnostics:check-delay 0.05))

(test "with check-on-save? #f a save runs no checker"
  (options:set! diagnostics:check-on-save? #f diagnostics:check-delay #f)
  (buffers:insert! plain 1 "w")
  (files:save-buffer plain)
  (past-delay)
  (check-equal? '() runs)
  (options:unset! diagnostics:check-on-save?)
  (options:set! diagnostics:check-delay 0.05))

(test "with the mode off its marks are hidden and no checker runs, on an edit or a save"
  (diagnostics-test/marks:mode! plain #f)
  (buffers:insert! plain 1 "z")
  (files:save-buffer plain)
  (past-delay)
  (check-equal? '(() () (("beta" warning "checked"))) (list runs (diagnostics-test/marks:marks plain) (diagnostics-test/marks:all-seen plain))))

(test "a check started while the last of the same checker runs quits the last, whose program stops; only the new one reports; checking? holds while one runs"
  (let ([calls 0])
    (define (slow b)
      (set! calls (+ calls 1))
      (let ([n calls])
        (when (= n 1) (processes:run "sleep" '("30")))
        (list (diagnostics-test/marks:warn b "beta" (format "check ~a" n)))))
    (let ([q (buffers:make "q" "alpha beta\n")])
      (buffers:with-buffer q (hooks:add-local! diagnostics:checkers slow))
      (diagnostics-test/marks:mode! q #t)
      (test-runner:wait-until (lambda () (pair? (processes:all))))
      (check-equal? '(#t (("sleep" "30"))) (list (diagnostics:checking? q) (map processes:command-line (processes:all))))
      (views:set-buffer! (layout:selected-view) q)
      (test-user:press! "C-c c")
      (test-runner:wait-until (lambda () (and (null? (processes:all)) (not (diagnostics:checking? q)))))
      (check-equal? '(#f (("beta" warning "check 2")) 2) (list (diagnostics:checking? q) (diagnostics-test/marks:all-seen q) calls)))))

(test "two buffers checked at once each get their own findings, placed by the version each check started at"
  (options:set! diagnostics:check-delay #f)
  (let ([held '()])
    (define (pausing b)
      (let ([d (diagnostics-test/marks:warn b "beta" (buffers:name b))])
        (suspend (lambda (resume) (set! held (cons resume held))))
        (list d)))
    (let ([one (buffers:make "one" "alpha beta\n")] [two (buffers:make "two" "beta alpha\n")])
      (for-each (lambda (b) (buffers:with-buffer b (hooks:add-local! diagnostics:checkers pausing))) (list one two))
      (diagnostics-test/marks:mode! one #t)
      (diagnostics-test/marks:mode! two #t)
      (test-runner:wait-until (lambda () (= 2 (length held))))
      (check-equal? '(#t #t) (list (diagnostics:checking? one) (diagnostics:checking? two)))
      (buffers:insert! one 1 "new ")
      (for-each (lambda (resume) (resume void)) held)
      (test-runner:wait-until (lambda () (not (or (diagnostics:checking? one) (diagnostics:checking? two)))))
      (check-equal? '((("beta" warning "one")) (("beta" warning "two"))) (list (diagnostics-test/marks:all-seen one) (diagnostics-test/marks:all-seen two)))))
  (options:set! diagnostics:check-delay 0.05))

(test "a checker that raises, or returns what is not a list of diagnostics, is reported and not called again in that buffer until C-u diagnostics:check; check-failed? says so meanwhile"
  (let ([calls 0])
    (define (broken b) (set! calls (+ calls 1)) (error 'broken "no linter installed"))
    (let ([r (buffers:make "r" "alpha beta\n")])
      (buffers:with-buffer r (hooks:add-local! diagnostics:checkers broken))
      (check-equal? '("no linter installed") (reports-during (lambda () (diagnostics-test/marks:mode! r #t))))
      (check (diagnostics:check-failed? r))
      (buffers:insert! r 1 "x")
      (views:set-buffer! (layout:selected-view) r)
      (test-user:press! "C-c c")
      (past-delay)
      (check-equal? '(1 #t) (list calls (diagnostics:check-failed? r)))
      (check-equal? '("no linter installed") (reports-during (lambda () (test-user:press! "C-u C-c c"))))
      (check-equal? '(2 #t) (list calls (diagnostics:check-failed? r)))))
  (let ([odd (buffers:make "odd" "alpha\n")])
    (buffers:with-buffer odd (hooks:add-local! diagnostics:checkers (lambda (b) 'none)))
    (reports-during (lambda () (diagnostics-test/marks:mode! odd #t)))
    (check (diagnostics:check-failed? odd))))

(test "a checker a mode adds goes with the mode, and its findings with it"
  (tables:define-table sh-keys)
  (hooks:define-hook sh-hook)
  (modes:define-major-mode sh-mode (keymap sh-keys) (hook sh-hook))
  (hooks:add! sh-hook (lambda () (options:set-local! diagnostics:mode #t) (hooks:add-local! diagnostics:checkers check-beta)))
  (let ([script (buffers:make "script" "alpha beta\n")])
    (modes:set-major-mode sh-mode script)
    (test-runner:wait-until (lambda () (pair? (diagnostics:in script))))
    (check-equal? '(("beta" warning "checked")) (diagnostics-test/marks:all-seen script))
    (modes:set-major-mode modes:fundamental script)
    (check-equal? '() (diagnostics-test/marks:all-seen script))))

(test "a checker's findings go when its module unloads"
  (let ([bad (buffers:make "bad" "a bad word\n")])
    (diagnostics-test/marks:mode! bad #t)
    (test-runner:wait-until (lambda () (pair? (diagnostics:in bad))))
    (check-equal? '(("bad" error "bad word")) (diagnostics-test/marks:all-seen bad))
    (unload-owner! (module-owner '(diagnostics-test linter)))
    (check-equal? '() (diagnostics-test/marks:all-seen bad))))
