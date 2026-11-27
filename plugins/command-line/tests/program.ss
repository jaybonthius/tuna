(import (tuna) (test) (test-runner) (processes) (web-test http))

(define (lines text)
  (let ([p (open-input-string text)])
    (let loop () (let ([line (get-line p)]) (if (eof-object? line) '() (cons line (loop)))))))

;; The flags reach the program as a user types them, so the server's
;; start, after the batch the configuration loads web in, meets the
;; --eval's setting whichever plugin loads first.
(test "run as a program, an --eval's port is the one web starts on, once, and the file named is shown"
  (let* ([home (string-append (getenv "HOME") "/program")]
         [configured (web-test/http:free-port)]
         [given (web-test/http:free-port)])
    (test-runner:make-home! home "program/configuration.ss")
    (call-with-output-file (string-append home "/a.txt") (lambda (p) (put-string p "one\ntwo\n")))
    (call-with-output-file (string-append home "/configured-port") (lambda (p) (write configured p)))
    (let-values ([(status output errors)
                  (processes:run (car (command-line)) (list (format "--eval=(options:set! web:port ~a)" given) "+2" "a.txt") ""
                    (processes:options [directory home] [environment (test-runner:home-environment home)] [separate-stderr #t]))])
      (check-equal? 0 status)
      (check-equal? "" (utf8->string errors))
      (check-equal? (list (format "Tuna is at http://127.0.0.1:~a/" given)) (lines (utf8->string output))))))
