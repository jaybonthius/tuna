(import (tuna) (test) (test-user) (test-runner) (hooks) (options) (timers) (commands) (keys) (buffers) (views) (layout)
        (layout-split) (editing) (minibuffer) (jump-history) (jump-history-test))

(commands:define-command (show [b (buffers:current)])
  "Shows B in the selected view."
  (layout:switch-to-buffer b))

(commands:define-command (jump [b (buffers:current)] [position 0])
  "Shows B in the selected view at POSITION, recording the place it leaves."
  (let ([from (views:buffer (jump-history-test:view))] [at (views:point (jump-history-test:view))])
    (layout:switch-to-buffer b)
    (views:set-point! (jump-history-test:view) position)
    (jump-history:push! from at)))

(commands:define-command (read-name)
  "Reads a name."
  (minibuffer:read "Name: "))

(keys:bind! keys:global "C-c n" read-name)

(define first (buffers:make "first" "one\ntwo\nthree\n"))
(define second (buffers:make "second" "four\nfive\n"))
(define third (buffers:make "third" "six\n"))

(define (here) (let ([v (jump-history-test:view)]) (cons (buffers:name (views:buffer v)) (views:point v))))

(define (places) (map (lambda (p) (cons (buffers:name (car p)) (cdr p))) (jump-history:places)))

(define (raised-by? who message)
  (lambda (c) (and (who-condition? c) (eq? who (condition-who c)) (string=? message (condition-message c)))))

(define back-error '((jump-history:go-back "At start of jump history")))

(define forward-error '((jump-history:go-forward "At end of jump history")))

(layout:switch-to-buffer first)

(test "a switch made outside a command, as at start or by a timer, records nothing"
  (check-equal? '(("first" . 1) ()) (list (here) (places)))
  (timers:run-after 0 (lambda () (layout:switch-to-buffer second)))
  (test-runner:wait-until (lambda () (equal? "second" (car (here)))))
  (layout:switch-to-buffer first)
  (check-equal? '() (places)))

(test "a switch inside a command records the place the view left; a switch to the buffer shown, or from an internal buffer, records nothing"
  (views:set-point! (jump-history-test:view) 5)
  (commands:run show second)
  (check-equal? '(("first" . 5)) (places))
  (commands:run show second)
  (check-equal? '(("first" . 5)) (places))
  (commands:run show (buffers:make " *internal*" "x"))
  (commands:run show third)
  (check-equal? '(("second" . 1) ("first" . 5)) (places)))

(test "with jump-history:record-switch removed from layout:after-switch-to-buffer, a switch records nothing"
  (hooks:remove! layout:after-switch-to-buffer jump-history:record-switch)
  (commands:run show first)
  (check-equal? '(("second" . 1) ("first" . 5)) (places))
  (commands:run show third)
  (hooks:add! layout:after-switch-to-buffer jump-history:record-switch))

(test "M-, goes back to the newest place without recording its own switch, C-M-, forward again; each raises at its end"
  (test-user:press! "M-,")
  (check-equal? '(("second" . 1) (("first" . 5))) (list (here) (places)))
  (test-user:press! "M-,")
  (check-equal? '(("first" . 5) ()) (list (here) (places)))
  (check-equal? back-error (jump-history-test:press-reporting! "M-,"))
  (test-user:press! "C-M-,")
  (check-equal? '("second" . 1) (here))
  (test-user:press! "C-M-,")
  (check-equal? '("third" . 1) (here))
  (check-equal? forward-error (jump-history-test:press-reporting! "C-M-,"))
  (check-equal? '(("second" . 1) ("first" . 5)) (places)))

(test "going forward keeps the forward list, so C-M-, twice after M-, twice goes forward twice; a new place empties it"
  (test-user:press! "M-, M-,")
  (check-equal? '("first" . 5) (here))
  (test-user:press! "C-M-, C-M-,")
  (check-equal? '("third" . 1) (here))
  (test-user:press! "M-,")
  (commands:run jump third 2)
  (check-equal? '("third" . 2) (here))
  (check-equal? forward-error (jump-history-test:press-reporting! "C-M-,")))

(test "a place equal to the newest is not recorded twice, and a place follows edits"
  (check-equal? '(("second" . 1) ("first" . 5)) (places))
  (jump-history:push! second 1)
  (check-equal? '(("second" . 1) ("first" . 5)) (places))
  (jump-history:push! second 3)
  (check-equal? '(("second" . 3) ("second" . 1) ("first" . 5)) (places))
  (buffers:replace! second 1 1 "new\n")
  (check-equal? '(("second" . 7) ("second" . 1) ("first" . 5)) (places)))

(test "a killed buffer's places go from both lists"
  (test-user:press! "M-,")
  (check-equal? '("second" . 7) (here))
  (buffers:kill! third)
  (check-equal? forward-error (jump-history-test:press-reporting! "C-M-,"))
  (buffers:kill! second)
  (check-equal? '(("first" . 5)) (places)))

(test "jump-history:after-return is called with the view after going back or forward"
  (let* ([returned '()] [note (lambda (v) (set! returned (cons v returned)))])
    (hooks:add! jump-history:after-return note)
    (test-user:press! "M-,")
    (hooks:remove! jump-history:after-return note)
    (check-equal? (list (jump-history-test:view)) returned)))

(test "M-, and C-M-, from a waiting prompt record no place in the prompt's buffer"
  (commands:run jump first 9)
  (test-user:press! "C-c n")
  (check-equal? " *Minibuf*" (car (here)))
  (test-user:press! "M-,")
  (check-equal? '("first" . 5) (here))
  (check-equal? forward-error (jump-history-test:press-reporting! "C-M-,"))
  (layout:select! (minibuffer:prompt-view (minibuffer:current-prompt)))
  (check-equal? '(cancelled) (jump-history-test:press-reporting! "C-g")))

(test "M-< in a prompt records nothing, its buffer being internal"
  (let ([before (places)])
    (test-user:press! "C-c n")
    (test-user:type! "abc")
    (test-user:press! "M-<")
    (check-equal? before (places))
    (check-equal? '(cancelled) (jump-history-test:press-reporting! "C-g"))))

(test "with jump-history:view-key as jump-history:history-key each view keeps its own history, recorded in the selected view"
  (options:set! jump-history:history-key jump-history:view-key)
  (check-equal? '() (places))
  (commands:run jump first 9)
  (check-equal? '(("first" . 5)) (places))
  (commands:run layout-split:split-right)
  (let ([other (find (lambda (v) (not (eq? v (jump-history-test:view)))) (layout:views))])
    (layout:select! other)
    (check-equal? '() (places))
    (check-raises (raised-by? 'jump-history:push! "not a buffer") (jump-history:push! "first" 1))))

(test "push! given a view records in that view's history, and raises for what is no view; a place in an internal buffer is never pushed"
  (let ([other (find (lambda (v) (not (eq? v (jump-history-test:view)))) (layout:views))])
    (jump-history:push! first 3 other)
    (check-equal? '() (places))
    (layout:select! other)
    (check-equal? '(("first" . 3) ("first" . 5)) (places))
    (check-raises (raised-by? 'jump-history:push! "not a view") (jump-history:push! first 3 'v))
    (check-raises (raised-by? 'jump-history:push! "not a position") (jump-history:push! first -1))
    (jump-history:push! (buffers:make " *hidden*" "x") 1)
    (check-equal? '(("first" . 3) ("first" . 5)) (places)))
  (options:unset! jump-history:history-key))

(test "push! and a buffer switch run no jump-history:after-jump; a jump from a list runs it, whose entry recenters on point"
  (let* ([jumped '()] [note (lambda (v) (set! jumped (cons (views:point v) jumped)))]
         [placements '()] [placed (lambda (next v p align) (set! placements (cons (list p align) placements)) (next v p align))])
    (hooks:add! jump-history:after-jump note)
    (advice-add! views:scroll-to! placed)
    (commands:run jump first 9)
    (commands:run show (buffers:make "fourth" "x\n"))
    (check-equal? '("fourth" () ()) (list (car (here)) jumped placements))
    (commands:run jump first 5)
    (check-equal? '() placements)
    (jump-history:after-jump (jump-history-test:view))
    (advice-remove! views:scroll-to! placed)
    (hooks:remove! jump-history:after-jump note)
    (check-equal? (list '(5) (list (list 5 (views:align center)))) (list jumped placements))))

(test "after-jump and after-return mark point's line for a moment, until the next command"
  (jump-history:after-jump (jump-history-test:view))
  (check-equal? '("two") (jump-history-test:pulsed (jump-history-test:view)))
  (test-user:press! "C-f")
  (check-equal? '() (jump-history-test:pulsed (jump-history-test:view)))
  (test-user:press! "M-,")
  (check (pair? (jump-history-test:pulsed (jump-history-test:view)))))
