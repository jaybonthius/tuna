(import (tuna) (test) (test-runner) (processes))

(define home (string-append (getenv "HOME") "/restarted"))

(define (read-lines file)
  (if (file-exists? file)
      (call-with-input-file file
        (lambda (p) (let loop () (let ([line (get-line p)]) (if (eof-object? line) '() (cons line (loop)))))))
      '()))

;; Each configuration in restart/ is one start of Tuna on the same home,
;; ending with an exit of its own, as a user's session does; it notes
;; the questions it was asked in the home's events file.
(define (start-with configuration)
  (test-runner:make-home! home configuration)
  (when (file-exists? (string-append home "/events")) (delete-file (string-append home "/events")))
  (let-values ([(status output errors)
                (processes:run (car (command-line)) '() ""
                  (processes:options [directory home] [environment (test-runner:home-environment home)] [separate-stderr #t]))])
    (check-equal? 0 status)
    (check-equal? "" (utf8->string errors))
    (read-lines (string-append home "/events"))))

(test "an edit made just before exit is in the log, so the next start has it back where it was"
  (check-equal? '() (start-with "restart/first.ss"))
  (check-equal? '() (start-with "restart/second.ss")))

(test "the quit command exits without asking about a modified buffer whose log holds its edits, which the next start has back"
  (check-equal? '() (start-with "restart/third.ss"))
  (check-equal? '() (start-with "restart/fourth.ss")))

(test "after undo:forget! the log holds no saved state to rebuild the edits from, so the quit command asks before it exits"
  (check-equal? '("asked: Modified buffers exist; exit anyway? ") (start-with "restart/fifth.ss")))
