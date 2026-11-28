(import (tuna) (test) (test-runner) (processes))

(define (home-named name) (string-append (getenv "HOME") "/" name))

(define (read-lines file)
  (if (file-exists? file)
      (call-with-input-file file
        (lambda (p) (let loop () (let ([line (get-line p)]) (if (eof-object? line) '() (cons line (loop)))))))
      '()))

;; Each start ends with an exit of its own, as a user's session does.
(define (start-with home configuration)
  (test-runner:make-home! home configuration)
  (when (file-exists? (string-append home "/events")) (delete-file (string-append home "/events")))
  (let-values ([(status output errors)
                (processes:run (car (command-line)) '() ""
                  (processes:options [directory home] [environment (test-runner:home-environment home)] [separate-stderr #t]))])
    (check-equal? 0 status)
    (check-equal? "" (utf8->string errors))
    (read-lines (string-append home "/events"))))

(test "an edit made just before exit is in the log, so the next start has it back where it was, and says so"
  (check-equal? '() (start-with (home-named "restarted") "restart/first.ss"))
  (check-equal? '("said: restored unsaved edits to b.txt" "said: Undo") (start-with (home-named "restarted") "restart/second.ss")))

(test "the quit command exits without asking about a modified buffer whose log holds its edits, which the next start has back"
  (check-equal? '("said: Redo") (start-with (home-named "restarted") "restart/third.ss"))
  (check-equal? '("said: restored unsaved edits to b.txt") (start-with (home-named "restarted") "restart/fourth.ss")))

(test "after undo:forget! the log holds no saved state to rebuild the edits from, so the quit command asks before it exits"
  (check-equal? '("said: restored unsaved edits to b.txt" "asked: Modified buffers exist; exit anyway? ")
                (start-with (home-named "restarted") "restart/fifth.ss")))

(test "redo after a restart puts every cursor back where it was after the edit"
  (check-equal? '() (start-with (home-named "cursors") "restart/sixth.ss"))
  (check-equal? '("said: restored unsaved edits to b.txt" "said: Undo" "said: Redo")
                (start-with (home-named "cursors") "restart/seventh.ss")))
