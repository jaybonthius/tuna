(import (tuna) (test) (test-runner) (hooks) (options) (scopes) (commands) (buffers) (document) (buffers-test md) (buffers-test))

(options:define-option width 70 fixnum?)

(define (names) (map buffers:name (remp (lambda (b) (buffers:internal-name? (buffers:name b))) (buffers:all))))

(define (kill-all!) (for-each buffers:kill! (buffers:all)))

(test "a buffer is made from a string held in a buffers:text root, a datum of one node, or a document of one node"
  (check-equal? '(buffers:text () "Buy milk.\n") (buffers-test:root (buffers:make "plain" "Buy milk.\n")))
  (check-equal? '(buffers-test/md:para () "a") (buffers-test:root (buffers:make "datum" '(buffers-test/md:para () "a"))))
  (check-equal? '(buffers-test/md:para () "a") (buffers-test:root (buffers:make "document" (document:from-datum '(buffers-test/md:para () "a")))))
  (check-equal? '("plain" "datum" "document") (names))
  (check-equal? (list #f "datum") (list (buffers:find "nothing") (buffers:name (buffers:find "datum"))))
  (kill-all!))

(test "make refuses a live buffer's name, content that is not one node, and a name that is not a string"
  (buffers:make "plain" "")
  (check-raises (buffers-test:raised-with? 'buffers:make "a live buffer has the name" '("plain")) (buffers:make "plain" "again"))
  (check-raises (buffers-test:raised-with? 'buffers:make "not one node" '(#(buffers-test/md:image ()))) (buffers:make "atom" '#(buffers-test/md:image ())))
  (check-raises (buffers-test:raised-with? 'buffers:make "not one node" '(((buffers-test/md:para ()) (buffers-test/md:para ()))))
    (buffers:make "two" (document:from-datum '(buffers-test/md:para ()) '(buffers-test/md:para ()))))
  (check-raises (buffers-test:raised-with? 'buffers:make "not a string" '(name)) (buffers:make 'name "a"))
  (kill-all!))

(test "rename! gives a buffer a name no live buffer has"
  (let ([plain (buffers:make "plain" "")])
    (buffers:make "datum" "")
    (check-raises (buffers-test:raised-with? 'buffers:rename! "a live buffer has the name" '("datum")) (buffers:rename! plain "datum"))
    (buffers:rename! plain "renamed")
    (check-equal? (list "renamed" #f plain) (list (buffers:name plain) (buffers:find "plain") (buffers:find "renamed")))
    (check-equal? '(#t #f #f) (list (buffers:buffer? plain) (buffers:buffer? "renamed") (buffers:current))))
  (kill-all!))

(test "killing asks the queries, then calls killed with the buffer current and live, then drops its scope"
  (let ([plain (buffers:make "plain" "")] [seen '()])
    (buffers:with-buffer plain (options:set-local! width 3))
    (let ([note (lambda (b) (set! seen (list (buffers:name b) (eq? (buffers:current) b) (buffers:live? b) (width))))])
      (hooks:add! buffers:killed note)
      (check-equal? #t (buffers:kill! plain))
      (hooks:remove! buffers:killed note))
    (check-equal? '("plain" #t #t 3) seen)
    (check-equal? '(#f 70 ()) (list (buffers:live? plain) (buffers:with-buffer plain (width)) (names)))
    (check-raises (buffers-test:raised? 'buffers:replace! "not a live buffer") (buffers:replace! plain 1 1 "a"))
    (check-raises (buffers-test:raised? 'buffers:kill! "not a live buffer") (buffers:kill! plain))))

(test "a kill query that returns #f keeps the buffer"
  (let ([keep-scratch (lambda (b) (not (string=? (buffers:name b) "*scratch*")))]
        [scratch (buffers:make "*scratch*" "")])
    (hooks:add! buffers:kill-queries keep-scratch)
    (check-equal? #f (buffers:kill! scratch))
    (check (buffers:live? scratch))
    (hooks:remove! buffers:kill-queries keep-scratch)
    (check-equal? #t (buffers:kill! scratch))))

(test "a kill query may pause, as one asking the user does"
  (let* ([b (buffers:make "asked" "")]
         [pausing (lambda (b) (suspend (lambda (resume) (spawn-task (lambda (restore) (resume (lambda () #f)))))))])
    (hooks:add! buffers:kill-queries pausing)
    (check-equal? #f (buffers:kill! b))
    (hooks:remove! buffers:kill-queries pausing)
    (check (buffers:live? b))
    (buffers:kill! b)))

(test "free-name gives the name while no live buffer has it, else the first free NAME<N> from 2"
  (check-equal? "*run*" (buffers:free-name "*run*"))
  (let ([first (buffers:make "*run*" "")])
    (check-equal? "*run*<2>" (buffers:free-name "*run*"))
    (buffers:make "*run*<2>" "")
    (check-equal? "*run*<3>" (buffers:free-name "*run*"))
    (buffers:kill! first)
    (check-equal? "*run*" (buffers:free-name "*run*")))
  (check-raises (buffers-test:raised-with? 'buffers:free-name "not a string" '(run)) (buffers:free-name 'run))
  (kill-all!))

(test "a name starting with a space is internal, and a buffer made with one starts silent"
  (check-equal? '(#t #f #f) (map buffers:internal-name? '(" *Minibuf*" "notes" "")))
  (check-equal? '(#t #f) (map (lambda (n) (buffers:silent? (buffers:make n ""))) '(" internal" "visible")))
  (let ([b (buffers:find " internal")])
    (buffers:rename! b "shown")
    (check (buffers:silent? b)))
  (kill-all!))

(test "buffers:all is the live buffers most recently used first; a new one goes at the end; moving it to the front or back is a use"
  (let* ([a (buffers:make "a" "")] [b (buffers:make "b" "")] [c (buffers:make "c" "")])
    (check-equal? '("a" "b" "c") (names))
    (buffers:move-to-front! c)
    (check-equal? '("c" "a" "b") (names))
    (buffers:move-to-back! c)
    (check-equal? '("a" "b" "c") (names))
    (buffers:move-to-front! b)
    (buffers:make "d" "")
    (check-equal? '("b" "a" "c" "d") (names))
    (buffers:kill! b)
    (check-equal? '("a" "c" "d") (names))
    (check-raises (buffers-test:raised? 'buffers:move-to-front! "not a live buffer") (buffers:move-to-front! b))
    (check-raises (buffers-test:raised? 'buffers:move-to-back! "not a buffer") (buffers:move-to-back! 'a)))
  (kill-all!))

(test "with-buffer makes the buffer current with its scope bound, even when it is current already"
  (let ([t (buffers:make "t" "")])
    (buffers:with-buffer t (options:set-local! width 4))
    (check-equal? '(4 70) (list (buffers:with-buffer t (width)) (width)))
    (check-equal? 4 (buffers:with-buffer t (parameterize ([scopes:current (scopes:make)]) (buffers:with-buffer t (width)))))
    (check-equal? (list t 4) (buffers:call-with-buffer t (lambda () (list (buffers:current) (width)))))
    (check-equal? #f (buffers:current))
    (buffers:kill! t)))

(test "a killed buffer has no scope, and with-buffer leaves the current scope as it is"
  (let ([t (buffers:make "t" "")] [s (scopes:make)])
    (buffers:with-buffer t (options:set-local! width 6))
    (buffers:kill! t)
    (check (eq? s (parameterize ([scopes:current s]) (buffers:with-buffer t (scopes:current)))))
    (check-equal? (list t 70) (buffers:with-buffer t (list (buffers:current) (width))))))

(test "reset-scope! gives the buffer a new empty scope, which becomes current where the old one was"
  (let ([t (buffers:make "t" "")])
    (buffers:with-buffer t
      (options:set-local! width 5)
      (let ([old (scopes:current)])
        (buffers:reset-scope! t)
        (check-equal? 70 (width))
        (check (not (eq? old (scopes:current))))))
    (check-equal? 70 (buffers:with-buffer t (width)))
    (buffers:kill! t)
    (check-raises (buffers-test:raised? 'buffers:reset-scope! "not a live buffer") (buffers:reset-scope! t))
    (check-equal? '(buffers:reset-scope! "not on the main thread")
      (let ([u (buffers:make "u" "")])
        (buffers-test:on-thread (lambda () (buffers:reset-scope! u)))))
    (kill-all!)))

(commands:define-command (rebuild)
  "Makes the current buffer again, as a revert function does."
  (buffers:replace! (buffers:current) 1 (- (document:length (buffers:document (buffers:current))) 1) "again\n"))

(test "revert-buffer runs the current buffer's revert function, and raises when it is #f"
  (let ([t (buffers:make "t" "old\n")])
    (buffers:with-buffer t
      (check-equal? '("nothing reverts this buffer")
        (map condition-message (test-runner:reports-during (lambda () (commands:run buffers:revert-buffer)))))
      (options:set-local! buffers:revert-function rebuild)
      (commands:run buffers:revert-buffer))
    (check-equal? "again\n" (document:text (buffers:document t)))
    (buffers:kill! t)))
