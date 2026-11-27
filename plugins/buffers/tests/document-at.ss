(import (tuna) (test) (test-runner) (timers) (buffers) (document))

(define (raised? who message)
  (lambda (c)
    (and (who-condition? c) (eq? who (condition-who c))
         (message-condition? c) (string=? message (condition-message c)))))

(test "document-at gives a buffer's content at a version its edit log holds, the current document at the current version"
  (let* ([b (buffers:make "versions" "one\ntwo\n")] [at (lambda (v) (document:text (buffers:document-at b v)))])
    (check (eq? (buffers:document-at b 0) (buffers:document b)))
    (do ([i 0 (+ i 1)]) ((= i 10)) (buffers:replace! b 1 1 (number->string i)))
    (check-equal? '(10 "9876543210one\ntwo\n" "876543210one\ntwo\n" "one\ntwo\n") (list (buffers:version b) (at 10) (at 9) (at 0)))
    (buffers:replace! b 1 11 "")
    (buffers:with-silent-edits b (buffers:replace! b 5 8 "TWO"))
    (buffers:replace! b 1 4 "one")
    (check-equal? '("one\nTWO\n" "one\nTWO\n" "one\ntwo\n" "9876543210one\ntwo\n") (list (at 13) (at 12) (at 11) (at 10)))
    (check-raises (raised? 'buffers:document-at "not a version of the buffer") (buffers:document-at b 14))
    (check-raises (raised? 'buffers:document-at "not a buffer") (buffers:document-at 'b 0))))

(test "once the edit log no longer holds the edits since a version, its content is #f"
  (let ([t (buffers:make "trimmed" "abc\n")])
    (do ([i 0 (+ i 1)]) ((= i 1500)) (buffers:replace! t 1 1 "x"))
    (timers:set-idle! #t)
    (test-runner:wait-until (lambda () (not (buffers:document-at t 499))))
    (timers:set-idle! #f)
    (check-equal? '(#f #f 504)
      (list (buffers:document-at t 0) (buffers:document-at t 499) (string-length (document:text (buffers:document-at t 500)))))))
