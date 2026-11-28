(import (tuna) (test) (test-runner) (hooks) (document) (buffers) (buffers-test))

(buffers:define-layer kept (read-only))

(define (text b) (document:text (buffers:document b)))

(define (read-only-of b) (string-append (buffers:name b) " is read-only"))

(test "a read-only buffer refuses every edit by its name and says so for typing; splice!, the writers' way, still writes"
  (let ([b (buffers-test:fresh "abc\n")])
    (check-equal? #f (buffers:read-only? b))
    (buffers:set-read-only! b 'yes)
    (check-equal? #t (buffers:read-only? b))
    (check-raises (buffers-test:raised-with? 'buffers:replace! (read-only-of b) '()) (buffers:replace! b 1 2 "x"))
    (check-raises (buffers-test:raised-with? 'buffers:insert! (read-only-of b) '()) (buffers:insert! b 4 "x"))
    (check-raises (buffers-test:raised-with? 'buffers:replace! (read-only-of b) '()) (buffers:replace! b 1 3 ""))
    (check-equal? '(#t #t "abc\n") (list (buffers:refuses-text? b 1 1) (buffers:refuses-text? b 4 4) (text b)))
    (buffers:splice! b 1 1 (document:from-datum "s"))
    (check-equal? "sabc\n" (text b))
    (buffers:set-read-only! b #f)
    (buffers:replace! b 1 2 "S")
    (check-equal? '(#f "Sabc\n") (list (buffers:read-only? b) (text b)))))

(test "check-writable refuses a read-only buffer with the same words, and passes an editable one or one inside with-read-only-inhibited"
  (let ([b (buffers-test:fresh "abc\n")])
    (buffers:check-writable b)
    (buffers:set-read-only! b #t)
    (check-equal? (list 'refused (read-only-of b)) (buffers-test:refusal (lambda () (buffers:check-writable b))))
    (check-equal? 'allowed (buffers-test:refusal (lambda () (buffers:with-read-only-inhibited b (buffers:check-writable b)))))
    (check-raises (test-runner:raised-with 'buffers:check-writable "not a buffer") (buffers:check-writable 'b))))

(test "inside with-read-only-inhibited of a buffer, edits go in despite its read-only state and read-only text; other buffers stay refused"
  (let ([b (buffers-test:fresh "abc\n")] [other (buffers-test:fresh "xyz\n")])
    (buffers:set-read-only! b #t)
    (buffers:set-read-only! other #t)
    (buffers:add-span! (buffers:layer b kept) 2 3 'kept)
    (check-equal? (list 'one (list 'refused (read-only-of other)))
      (call-with-values
        (lambda ()
          (buffers:with-read-only-inhibited b
            (buffers:replace! b 1 3 "AB")
            (values 'one (buffers-test:refusal (lambda () (buffers:replace! other 1 1 "o"))))))
        list))
    (buffers:call-with-read-only-inhibited b (lambda () (buffers:insert! b 1 ">")))
    (check-equal? '(">ABc\n" "xyz\n") (list (text b) (text other)))
    (check-raises (buffers-test:raised-with? 'buffers:insert! (read-only-of b) '()) (buffers:insert! b 1 "x"))))

(test "a buffer's read-only state goes first, then its read-only text"
  (let ([b (buffers-test:fresh "abc\n")])
    (buffers:add-span! (buffers:layer b kept) 2 3 'kept)
    (check-equal? (list 'refused (string-append "the text of " (buffers:name b) " is read-only"))
                  (buffers-test:refusal (lambda () (buffers:replace! b 2 3 "x"))))
    (buffers:set-read-only! b #t)
    (check-equal? (list 'refused (read-only-of b)) (buffers-test:refusal (lambda () (buffers:replace! b 2 3 "x"))))))

(test "read-only-changed runs, with the buffer current, each time the state turns, and not when it stays"
  (let ([b (buffers-test:fresh "abc\n")] [seen '()])
    (let ([note (lambda (buffer) (set! seen (cons (list (eq? buffer b) (eq? (buffers:current) b) (buffers:read-only? buffer)) seen)))])
      (hooks:add! buffers:read-only-changed note)
      (buffers:set-read-only! b #t)
      (buffers:set-read-only! b #t)
      (buffers:set-read-only! b #f)
      (hooks:remove! buffers:read-only-changed note))
    (check-equal? '((#t #t #t) (#t #t #f)) (reverse seen))))

(test "the read-only procedures check their arguments, and set-read-only! takes a live buffer on the main thread"
  (let ([b (buffers-test:fresh "x\n")])
    (check-raises (test-runner:raised-with 'buffers:read-only? "not a buffer") (buffers:read-only? 'b))
    (check-raises (test-runner:raised-with 'buffers:call-with-read-only-inhibited "not a procedure") (buffers:call-with-read-only-inhibited b 'x))
    (check-equal? '(buffers:set-read-only! "not on the main thread") (buffers-test:on-thread (lambda () (buffers:set-read-only! b #t))))
    (buffers:kill! b)
    (check-raises (test-runner:raised-with 'buffers:set-read-only! "not a live buffer") (buffers:set-read-only! b #t))))
