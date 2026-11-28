(import (tuna) (test) (test-user) (test-runner) (options) (views) (buffers) (document) (keys) (commands) (search) (editing)
        (flash) (flash-test))

(define seen '())

;; A style whose procedure notes the option it reads, so a test sees what
;; binding holds where a jump searches.
(define noting
  (search:make-style "Noting"
    (lambda (text partial? classes)
      (set! seen (cons (cons text (flash:rainbow)) seen))
      (search:regexp-quote text))))

(define kept 'none)

(commands:define-command (read-noting)
  "Reads a match in the noting style with flash:rainbow bound on."
  (set! kept (options:with ([flash:rainbow #t]) (flash:read-match (search:make-query "" noting)))))

(define (line-targets n)
  (let* ([v (flash-test:view)] [b (views:buffer v)] [doc (buffers:document b)])
    (map (lambda (i) (let ([p (buffers:stop b (document:line-start doc (+ i 1)))]) (flash:make-target v p p))) (iota n))))

(commands:define-command (read-lines)
  "Reads one of the first three line starts."
  (set! kept 'waiting)
  (set! kept (flash:read-target (line-targets 3))))

(keys:bind! keys:global "C-c n" read-noting)
(keys:bind! keys:global "C-c t" read-lines)

(define (kept-line)
  (and (flash:target? kept) (document:line (buffers:document (views:buffer (flash-test:view))) (flash:target-start kept))))

(test "options bound around a read hold wherever its jump searches, at every key"
  (flash-test:show! "foo fob for\nbar |foo\nfox\nFoo\n")
  (flash-test:press! "C-c n f o")
  (check (member '("f" . #t) seen))
  (check (member '("fo" . #t) seen))
  (check (for-all cdr seen))
  (check (flash-test:quitting! "C-g")))

(test "read-target labels the targets given; a character that is no label says so and the read goes on, and a label returns its target"
  (flash-test:show! "|one\ntwo\nthree\nfour\n")
  (flash-test:press! "C-c t")
  (check-equal? '("{d}one" "{a}two" "{s}three" "four" "") (flash-test:lines))
  (check-equal? '("No target labelled x")
                (map condition-message (test-runner:reports-during (lambda () (flash-test:press! "x")))))
  (check-equal? "Flash: " (flash-test:prompt))
  (flash-test:press! "s")
  (check-equal? 3 (kept-line)))

(test "in read-target, RET takes the first label's target, DEL does nothing, and another key ends the read with #f and runs"
  (flash-test:show! "|one\ntwo\nthree\nfour\n")
  (flash-test:press! "C-c t RET")
  (check-equal? 2 (kept-line))
  (flash-test:press! "C-c t DEL")
  (check-equal? (list 'waiting "Flash: ") (list kept (flash-test:prompt)))
  (flash-test:press! "a")
  (check-equal? 2 (kept-line))
  (flash-test:press! "C-c t C-e")
  (check-equal? (list #f "one|\ntwo\nthree\nfour\n") (list kept (flash-test:text))))

(test "read-match and read-target check their arguments"
  (check-raises (lambda (c) (equal? "not a query" (condition-message c))) (flash:read-match "foo"))
  (check-raises (lambda (c) (equal? "not a list of targets" (condition-message c))) (flash:read-target '(1)))
  (check-raises (lambda (c) (equal? "not a range of the view's buffer" (condition-message c)))
                (flash:make-target (flash-test:view) 5 2))
  (check-raises (lambda (c) (equal? "no client's key ran the running command" (condition-message c))) (flash:read-match))
  (for-each (lambda (labels) (check-raises (lambda (c) #t) (options:set! flash:labels labels))) '("aa" "a s" "a\tb" 7))
  (check-equal? "asdfjkl;ghqwertyuiopzxcvbnm" (flash:labels)))
