(import (tuna) (test) (test-runner) (processes))

(define (read-lines file)
  (if (file-exists? file)
      (call-with-input-file file
        (lambda (p) (let loop () (let ([line (get-line p)]) (if (eof-object? line) '() (cons line (loop)))))))
      '()))

;; Each configuration in restart/ is one start of Tuna, with the command
;; line a user would type, ending with an exit of its own; it notes the
;; questions it was asked and the reports it made in the home's events
;; file.
(define (start-with home configuration arguments)
  (test-runner:make-home! home configuration)
  (when (file-exists? (string-append home "/events")) (delete-file (string-append home "/events")))
  (let-values ([(status output errors)
                (processes:run (car (command-line)) arguments ""
                  (processes:options [directory home] [environment (test-runner:home-environment home)] [separate-stderr #t]))])
    (check-equal? 0 status)
    (check-equal? "" (utf8->string errors))
    (read-lines (string-append home "/events"))))

(test "the files open at exit are visited again at the next start, with the layout's view, and C-x C-c keeps them when no edit would be lost"
  (let ([home (string-append (getenv "HOME") "/restarted")])
    (test-runner:make-home! home)
    (call-with-output-file (string-append home "/a.txt") (lambda (p) (put-string p "one\ntwo\nthree\n")))
    (call-with-output-file (string-append home "/b.txt") (lambda (p) (put-string p "alpha\nbeta\ngamma\ndelta\n")))
    (check-equal? '() (start-with home "restart/first.ss" '("a.txt" "+3" "b.txt")))
    (check-equal? '() (start-with home "restart/second.ss" '()))
    (check-equal? '() (start-with home "restart/third.ss" '("+2" "c.txt")))
    (check-equal? '() (start-with home "restart/fourth.ss" '()))))

(test "once C-x C-c has asked about modified buffers, it asks nothing more, even with files:confirm-exit? on"
  (check-equal? '("asked: Modified buffers exist; exit anyway? ")
    (start-with (string-append (getenv "HOME") "/asked") "restart/asked.ss" '())))
