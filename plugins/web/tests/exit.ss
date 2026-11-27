(import (tuna) (test) (test-runner) (processes))

(define (lines text)
  (let ([p (open-input-string text)])
    (let loop () (let ([line (get-line p)]) (if (eof-object? line) '() (cons line (loop)))))))

;; The keys come from a code page and run inside web's handling of them,
;; with every plugin of a full configuration loaded, so the exit happens
;; with their code on the stack.
(define (exit-run name)
  (let ([home (string-append (getenv "HOME") "/" name)])
    (test-runner:make-home! home (string-append "exit/" name ".ss"))
    (call-with-output-file (string-append home "/notes.txt") (lambda (p) (put-string p "one\n")))
    (processes:run (car (command-line)) '("notes.txt") ""
      (processes:options [directory home] [environment (test-runner:home-environment home)] [separate-stderr #t]))))

(define (printed-only-its-address? output)
  (let ([printed (lines (utf8->string output))] [prefix "Tuna is at http://127.0.0.1:"])
    (and (= 1 (length printed))
         (<= (string-length prefix) (string-length (car printed)))
         (string=? prefix (substring (car printed) 0 (string-length prefix))))))

(test "C-x C-c from a page exits with status 0, and Tuna prints only its address"
  (let-values ([(status output errors) (exit-run "c-x-c-c")])
    (check-equal? 0 status)
    (check-equal? "" (utf8->string errors))
    (check (printed-only-its-address? output))))

(test "so does C-x C-c while M-x's prompt, paused inside web's handling of its key, is open"
  (let-values ([(status output errors) (exit-run "c-x-c-c-in-m-x")])
    (check-equal? 0 status)
    (check-equal? "" (utf8->string errors))
    (check (printed-only-its-address? output))))
