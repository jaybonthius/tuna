(import (tuna) (test))

;; A form of its own, so it loads before echo-area.
(import (echo-area-test beneath))

(import (test-user) (layout) (views) (buffers) (document) (keys) (commands) (hooks) (options) (faces) (editing)
        (echo-area) (echo-area-test))

(define view echo-area-test:view)
(define reports-during echo-area-test:reports-during)

(define (shown-during thunk)
  (reports-during (lambda () (thunk) (test-user:settle)))
  (test-user:settle)
  (let ([e (echo-area-test:element)])
    (list (echo-area:current-message) (test-user:element-attribute e "data-face") (echo-area-test:last-logged))))

(test "a report shows at the batch's end in the error face, the message alone, and the log has who: message and irritants"
  (check-equal? '("() is not a pair" "error" "car: () is not a pair")
    (shown-during (lambda () (spawn-task (lambda (restore) (car '())))))))

(test "the log holds each report as report's line has it after the module"
  (check-equal?
    '("spell:check: no dictionary" "spell:check: no word with irritant 42" "two irritants with irritants (1 \"b\")"
      "f: bad 3 and \"x\"" "spell:check: slow" "g: &error with irritants (1 2)" "non-condition value 42")
    (map (lambda (c) (caddr (shown-during (lambda () (report c)))))
         (list
           (condition (make-who-condition 'spell:check) (make-message-condition "no dictionary"))
           (condition (make-error) (make-who-condition 'spell:check) (make-message-condition "no word") (make-irritants-condition '(42)))
           (condition (make-error) (make-message-condition "two irritants") (make-irritants-condition '(1 "b")))
           (condition (make-error) (make-who-condition 'f) (make-format-condition) (make-message-condition "bad ~a and ~s")
                      (make-irritants-condition '(3 "x")))
           (condition (make-warning) (make-who-condition 'spell:check) (make-message-condition "slow"))
           (condition (make-error) (make-who-condition 'g) (make-irritants-condition '(1 2)))
           42))))

(test "a warning shows in the warning face, and a warning that is also serious in the error face, echo-area:face left unbound"
  (check-equal? '("aspell is slow" "warning" "spell:check: aspell is slow")
    (shown-during (lambda () (warningf 'spell:check "~a is slow" "aspell"))))
  (check-equal? '("both" "error" "both")
    (shown-during (lambda () (report (condition (make-warning) (make-error) (make-message-condition "both"))))))
  (check-equal? #f (echo-area:face)))

(define (refuse-loudly node edit) (error 'notes:consent "not today"))

(buffers:define-kind loud (consent refuse-loudly))

(test "a report raised inside a kind's consent, while an edit is refused, changes no buffer there and shows at the batch's end"
  (let ([b (buffers:make "*loud*" (loud '() "text\n"))])
    (check-equal? '(notes:consent)
      (map condition-who (reports-during (lambda () (spawn-task (lambda (restore) (buffers:replace! b 1 1 "x"))) (test-user:settle)))))
    (check-equal? '("text\n" "not today") (list (document:text (buffers:document b)) (echo-area:current-message)))))

(define (broken-draw node view) (error 'notes:draw "cannot draw"))

(buffers:define-kind broken (draw broken-draw))

(test "a report raised while the clients are drawn after a batch shows in the next batch, the same on every client"
  (let* ([other (test-user:open-client)] [c (buffers:make "*broken*" (broken '() "text\n"))]
         [drawn '()] [note (lambda (screen client)
                             (when (eq? client (test-user:client)) (set! drawn (cons (echo-area:current-message) drawn)))
                             (screen client))])
    (echo-area:message! "Before")
    (advice-add! layout:screen note)
    (let ([reported (reports-during (lambda () (views:set-buffer! (view) c) (test-user:settle)))])
      (check (pair? reported))
      (check (for-all (lambda (c) (eq? 'notes:draw (condition-who c))) reported)))
    (advice-remove! layout:screen note)
    (check-equal? '("Before" "cannot draw") (list-head (reverse drawn) 2))
    (check-equal? '("cannot draw" "cannot draw") (list (echo-area-test:echo) (echo-area-test:echo other)))
    (check-equal? "notes:draw: cannot draw" (substring (echo-area-test:last-logged) 0 23))
    (reports-during (lambda () (views:set-buffer! (view) (buffers:make "fine" "x\n")) (test-user:settle)))))

(test "reports queued before a message show before it"
  (reports-during (lambda () (report (condition (make-error) (make-message-condition "first"))) (echo-area:message! "second")))
  (check-equal? '("first" "second") (list-tail (echo-area-test:log-lines) (- (length (echo-area-test:log-lines)) 2))))

(commands:define-command (wait) "Waits until quit." (suspend (lambda (resume) #f)))

(keys:bind! keys:global "C-c w" wait)

(test "a quit shows Quit once, as when C-g quits a paused command"
  (test-user:press! "C-c w")
  (check (for-all cancelled? (reports-during (lambda () (test-user:press! "C-g") (test-user:settle)))))
  (check-equal? '("Quit" "Quit") (list (echo-area:current-message) (echo-area-test:last-logged)))
  (test-user:press! "C-g")
  (check-equal? "Quit [2 times]" (echo-area-test:last-logged)))

(test "a message that raises while the queue shows drops only its own report, and the reports after it show at the next batch"
  (let ([refuse-second (lambda (message! format-string . vs)
                         (if (equal? vs '("second"))
                             (error 'notes:show "cannot show")
                             (apply message! format-string vs)))])
    (reports-during
      (lambda ()
        (for-each (lambda (m) (report (condition (make-error) (make-message-condition m)))) '("first" "second" "third"))
        (advice-add! echo-area:message! refuse-second)
        (test-user:settle)
        (advice-remove! echo-area:message! refuse-second)
        (test-user:settle)))
    (check-equal? '("first" "third" "notes:show: cannot show")
      (list-tail (echo-area-test:log-lines) (- (length (echo-area-test:log-lines)) 3)))))

(commands:define-command (fail) "Raises." (error 'notes:fail "no"))

(keys:bind! keys:global "C-c f" fail)

(test "a command's report shows as it ends, before the other after-command entries"
  (let* ([seen #f] [note (lambda (command) (set! seen (echo-area:current-message)))])
    (hooks:add! commands:after-command note)
    (check-equal? '(notes:fail) (map condition-who (reports-during (lambda () (test-user:press! "C-c f")))))
    (hooks:remove! commands:after-command note)
    (check-equal? "no" seen)))

(test "a report is logged even when the message that shows it logs nothing"
  (reports-during
    (lambda ()
      (report (condition (make-error) (make-message-condition "quiet")))
      (options:with ([echo-area:log-max 0]) (echo-area:message! "unlogged"))))
  (check-equal? (list "unlogged" "quiet") (list (echo-area:current-message) (echo-area-test:last-logged))))

(commands:define-command (quiet-fail) "Raises where nothing is logged."
  (options:with ([echo-area:log-max 0]) (error 'notes:quiet "lost")))

(keys:bind! keys:global "C-c q" quiet-fail)

(test "an error raised where the log is off is logged all the same"
  (reports-during (lambda () (test-user:press! "C-c q")))
  (check-equal? "notes:quiet: lost" (echo-area-test:last-logged)))
