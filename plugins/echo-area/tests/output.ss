(import (tuna) (test))

;; A form of its own, so it loads before echo-area.
(import (echo-area-test beneath))

(import (test-user) (options) (editing) (echo-area) (echo-area-test))

(define messages echo-area-test:messages)

(define port (echo-area:open-output-port))

(test "writes since the last message show as one message, and the log joins its last line until a line break"
  (echo-area:message! "Before")
  (parameterize ([current-output-port port])
    (display "out")
    (write 7))
  (check-equal? '("out7" "Before\nout7\n" 4) (list (echo-area:current-message) (messages) (port-position port)))
  (display "\nnext" port)
  (check-equal? '("out7\nnext" "Before\nout7\nnext\n" 9) (list (echo-area:current-message) (messages) (port-position port))))

(test "a message ends the printed message: the next write starts a new one, and a new log line after the partial one"
  (echo-area:message! "Middle")
  (display "after" port)
  (check-equal? '("after" #f "Before\nout7\nnext\nMiddle\nafter\n") (list (echo-area:current-message) (echo-area:current-face) (messages))))

(test "so does the next typed key; two equal prints log as two lines, which count as a repeat once a later message ends the second"
  (test-user:press! "C-g")
  (display "a" port)
  (test-user:press! "C-a")
  (display "a" port)
  (check-equal? '("a" "Before\nout7\nnext\nMiddle\nafter\nQuit\na\na\n") (list (echo-area:current-message) (messages)))
  (echo-area:message! "m")
  (check-equal? "Before\nout7\nnext\nMiddle\nafter\nQuit\na [2 times]\nm\n" (messages)))

(test "a printed line that a line break ended is not a repeat"
  (display "m\n" port)
  (echo-area:message! "z")
  (check-equal? '("m" "m" "z") (list-tail (echo-area-test:log-lines) (- (length (echo-area-test:log-lines)) 3))))

(test "reports queued before a write show before it, and a report ends the printed message"
  (echo-area-test:reports-during
    (lambda ()
      (report (make-message-condition "Disk full"))
      (display "later" port)))
  (check-equal? '("later" ("Disk full" "later"))
    (list (echo-area:current-message) (list-tail (echo-area-test:log-lines) (- (length (echo-area-test:log-lines)) 2))))
  (echo-area-test:reports-during (lambda () (report (make-message-condition "Disk full again"))))
  (echo-area:message! "")
  (check-equal? '("later" "Disk full again") (list-tail (echo-area-test:log-lines) (- (length (echo-area-test:log-lines)) 2))))

(test "a fresh port starts at the start of a line, and fresh-line writes a line break only after text that has none"
  (let ([fresh (echo-area:open-output-port)])
    (fresh-line fresh)
    (check-equal? 0 (port-position fresh))
    (display "x" fresh)
    (fresh-line fresh)
    (fresh-line fresh)
    (check-equal? '(2 "x\n") (list (port-position fresh) (echo-area:current-message)))))

(test "with echo-area:log-max 0, a write shows and is not logged"
  (echo-area:message! "")
  (let ([before (messages)])
    (options:with ([echo-area:log-max 0]) (display "quiet" port))
    (check-equal? (list "quiet" before) (list (echo-area:current-message) (messages)))))

(test "text written on another thread goes to standard output, not the echo area, and only the main thread's writes are counted"
  (echo-area:message! "")
  (let ([counted (echo-area:open-output-port)])
    (check-equal? 0 (echo-area-test:on-thread (lambda () (display "from a thread\n" counted) (flush-output-port counted) (port-position counted))))
    (check-equal? #f (echo-area:current-message))))

(test "a closed port takes no more writes, and the port cannot be positioned"
  (let ([closed (echo-area:open-output-port)])
    (close-port closed)
    (check-raises (lambda (c) (assertion-violation? c)) (display "late" closed))
    (check-equal? #f (echo-area:current-message)))
  (check-raises (echo-area-test:raised? 'echo-area:open-output-port "the port cannot be positioned") (set-port-position! port 0))
  (check-equal? "echo area" (port-name port)))

(test "the documented example prints into the echo area"
  (parameterize ([current-output-port (echo-area:open-output-port)])
    (display "out")
    (write 7))
  (check-equal? "out7" (echo-area:current-message)))
