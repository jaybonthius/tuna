(import (tuna) (test) (test-runner) (test-user) (options) (ask) (document) (buffers) (views) (layout)
        (status-line) (editing) (undo) (files) (auto-revert) (files-test) (file-watch-test) (auto-revert-test))

(define (home name) (file-watch-test:home name))

(define (read-file name) (call-with-input-file (home name) get-string-all))

(define asked '())

(define (answering reply) (lambda (question) (set! asked (cons question asked)) reply))

(define (take-asked!) (let ([a (reverse asked)]) (set! asked '()) a))

(define (contains? s part)
  (and s (let loop ([i 0])
           (and (<= (+ i (string-length part)) (string-length s))
                (or (string=? part (substring s i (+ i (string-length part)))) (loop (+ i 1)))))))

(define (canceled-reports thunk)
  (map files:canceled-condition? (test-runner:reports-during thunk 1)))

(options:set! ask:yes-or-no-reader (answering #f) ask:y-or-n-reader (answering #t))

(file-watch-test:write! "notes.txt" "one\ntwo\n")

(define notes (files:visit (home "notes.txt")))

(define v (auto-revert-test:show! notes))

(define question "~/notes.txt changed on disk since it was read; save anyway? ")

(define (change-file-until-stale! text)
  (file-watch-test:write! "notes.txt" text)
  (test-runner:wait-until (lambda () (auto-revert:stale? notes))))

(test "a modified buffer whose file changes keeps its text and point; the status line shows Stale, and the echo area says so once, as it becomes Stale: a later change says nothing"
  (views:set-point! v 1)
  (test-user:type! "mine ")
  (change-file-until-stale! "theirs 1\n")
  (check-equal? '("mine one\ntwo\n" 6) (list (auto-revert-test:text notes) (views:point v)))
  (check (member "Stale" (auto-revert-test:lighters v)))
  (check (contains? (status-line:show-minor-modes v) "Stale"))
  (check-equal? '("notes.txt changed on disk; unsaved edits kept") (files-test:take-said!))
  (file-watch-test:write! "notes.txt" "theirs 1, again\n")
  (auto-revert:check notes)
  (check-equal? '(#t ()) (list (auto-revert:stale? notes) (files-test:take-said!))))

(test "typing in a Stale buffer asks nothing"
  (test-user:type! "more ")
  (check-equal? '() (take-asked!))
  (check-equal? "mine more one\ntwo\n" (auto-revert-test:text notes)))

(test "C-x C-s on a Stale buffer asks save anyway, naming the file; no writes nothing and keeps the mark"
  (check-equal? '(#t) (canceled-reports (lambda () (test-user:press! "C-x C-s"))))
  (check-equal? (list question) (take-asked!))
  (check-equal? "theirs 1, again\n" (read-file "notes.txt"))
  (check (auto-revert:stale? notes)))

(test "yes writes the buffer and clears the mark"
  (options:set! ask:yes-or-no-reader (answering #t))
  (test-user:press! "C-x C-s")
  (test-runner:wait-until (lambda () (not (buffers:modified? notes))))
  (check-equal? (list question) (take-asked!))
  (check-equal? '("mine more one\ntwo\n" #f #f)
    (list (read-file "notes.txt") (buffers:modified? notes) (auto-revert:stale? notes)))
  (options:set! ask:yes-or-no-reader (answering #f)))

(test "C-x x g on a Stale buffer reverts it, discarding the edits as one edit, and clears the mark; undo brings the edits back"
  (test-user:type! "edit ")
  (change-file-until-stale! "theirs 2\n")
  (let ([edited (auto-revert-test:text notes)])
    (test-user:press! "C-x x g")
    (auto-revert-test:wait-for-text notes "theirs 2\n")
    (check-equal? '(#f #f) (list (buffers:modified? notes) (auto-revert:stale? notes)))
    (test-user:press! "C-/")
    (check-equal? edited (auto-revert-test:text notes))
    (files:revert-from-file notes)))

(test "the mark clears when the file changes back to the bytes the buffer was read from"
  (test-user:type! "x")
  (change-file-until-stale! "theirs 3\n")
  (file-watch-test:write! "notes.txt" "theirs 2\n")
  (test-runner:wait-until (lambda () (not (auto-revert:stale? notes)))))

(test "undoing a Stale buffer's edits until it is unmodified leaves the mark and reloads nothing; the next change of the file reloads it"
  (change-file-until-stale! "theirs 4\n")
  (let loop ([n 0]) (when (and (buffers:modified? notes) (< n 10)) (test-user:press! "C-/") (loop (+ n 1))))
  (check-equal? '(#f #t "theirs 2\n") (list (buffers:modified? notes) (auto-revert:stale? notes) (auto-revert-test:text notes)))
  (file-watch-test:write! "notes.txt" "theirs 5\n")
  (auto-revert-test:wait-for-text notes "theirs 5\n")
  (check-equal? #f (auto-revert:stale? notes)))

(test "a polled Stale buffer undone until it is unmodified is not reloaded by the next check either; the file's next change reloads it"
  (options:set! auto-revert:use-notify? #f auto-revert:interval 1000)
  (test-user:type! "edit ")
  (file-watch-test:write! "notes.txt" "theirs 7\n")
  (auto-revert:check notes)
  (check (auto-revert:stale? notes))
  (let loop ([n 0]) (when (and (buffers:modified? notes) (< n 10)) (test-user:press! "C-/") (loop (+ n 1))))
  (auto-revert:check notes)
  (check-equal? '(#f #t "theirs 5\n") (list (buffers:modified? notes) (auto-revert:stale? notes) (auto-revert-test:text notes)))
  (file-watch-test:write! "notes.txt" "theirs 8\n")
  (auto-revert:check notes)
  (check-equal? '(#f "theirs 8\n") (list (auto-revert:stale? notes) (auto-revert-test:text notes)))
  (options:unset! auto-revert:use-notify? auto-revert:interval))

(test "text typed while a reload's read runs is kept: the file's text is not applied, the buffer is Stale, and the echo area says so"
  (files-test:take-said!)
  (files-test:typing-during-read notes "typed " (lambda () (change-file-until-stale! "theirs 6\n")))
  (check-equal? "typed theirs 8\n" (auto-revert-test:text notes))
  (check-equal? '("notes.txt changed on disk; unsaved edits kept") (files-test:take-said!)))

(test "C-x s, answered y, asks save anyway of a Stale buffer, and no ends the command before the next buffer"
  (file-watch-test:write! "todo.txt" "todo\n")
  (let ([todo (files:visit (home "todo.txt"))])
    (buffers:replace! todo 1 1 "mine ")
    (take-asked!)
    (check-equal? '(#t) (canceled-reports (lambda () (test-user:press! "C-x s"))))
    (check-equal? (list "Save file ~/notes.txt? " question) (take-asked!))
    (check-equal? '(#t #t) (map buffers:modified? (list notes todo)))
    (files:not-modified todo)))

(test "after files:write-file to another path the mark clears, and the buffer is followed at the new path, even when that write fails"
  (files:write-file (home "copy.txt") notes)
  (check-equal? #f (auto-revert:stale? notes))
  (test-user:type! "edit ")
  (file-watch-test:write! "copy.txt" "copy changed\n")
  (test-runner:wait-until (lambda () (auto-revert:stale? notes)))
  (options:set! auto-revert:interval 0.05)
  (check-raises error? (files:write-file (home "missing/moved.txt") notes))
  (check-equal? #f (auto-revert:stale? notes))
  (mkdir (home "missing"))
  (file-watch-test:write! "missing/moved.txt" "made later\n")
  (test-runner:wait-until (lambda () (auto-revert:stale? notes)))
  (options:unset! auto-revert:interval))
