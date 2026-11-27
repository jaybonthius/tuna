(import (tuna) (test) (test-runner) (test-user) (options) (document) (buffers) (files) (undo) (undo-log) (edits) (logs))

(options:set! undo-log:keep-log? (lambda (path) #t))

(define a-path (logs:home-path "a.txt"))

(define a #f)

(define (in-a command . args) (apply edits:run-in a command args))

(define (text b) (document:text (buffers:document b)))

(define (text-and-modified b) (list (text b) (buffers:modified? b)))

(define (visit-again! path)
  (let ([open (length (files:buffers))])
    (reload-modules! '((buffers)))
    (test-runner:wait-until (lambda () (= (length (files:buffers)) open)))
    (files:visit path)))

(test "a file buffer's log is first written once its history holds a group, after the batch, readable only by the user"
  (logs:write-text! a-path "alpha\n")
  (set! a (files:visit a-path))
  (check-equal? '((0 0 (0 #f)) #f) (list (edits:tree a) (buffers:modified? a)))
  (test-user:settle)
  (check (not (logs:logged? a-path)))
  (in-a edits:insert 1 "1 ")
  (check-equal? '(undo-history group saved at) (logs:logged-kinds a-path 4))
  (in-a edits:insert 1 "2 ")
  (check-equal? '(undo-history group saved at group) (logs:logged-kinds a-path 5))
  (check-equal? '((#(1 () ("1 "))) (saved 0 6 3816658035) (at 1) (#(1 () ("2 "))))
    (map (lambda (r) (if (eq? (car r) 'group) (list-tail r 5) r)) (cdr (logs:records a-path))))
  (check-equal? "600" (logs:file-mode (logs:log-of a-path))))

(test "undo and redo are logged as moves, and reaching the saved state leaves the buffer unmodified"
  (in-a undo:undo 1)
  (check (buffers:modified? a))
  (test-user:settle)
  (in-a undo:undo 1)
  (check-equal? '("alpha\n" #f) (text-and-modified a))
  (test-user:settle)
  (in-a undo:redo 1)
  (check-equal? '("1 alpha\n" #t) (text-and-modified a))
  (check-equal? '(undo-history group saved at group at at at) (logs:logged-kinds a-path 8)))

(test "a save marks the saved state, and undo and redo move the buffer's modified flag around it"
  (files:save-buffer a)
  (check-equal? '((1 1 (0 #f) (1 0) (2 1)) #f "1 alpha\n") (list (edits:tree a) (buffers:modified? a) (logs:read-text a-path)))
  (in-a undo:undo 1)
  (check (buffers:modified? a))
  (in-a undo:redo 1)
  (check (not (buffers:modified? a))))

(test "a visit reads the log and makes the buffer with the unsaved edits applied, marked modified"
  (in-a edits:insert 1 "3 ")
  (set! a (visit-again! a-path))
  (check-equal? '("3 1 alpha\n" #t (3 1 (0 #f) (1 0) (2 1) (3 1))) (list (text a) (buffers:modified? a) (edits:tree a)))
  (in-a undo:undo 1)
  (check-equal? '("1 alpha\n" #f) (text-and-modified a))
  (in-a undo:undo 1)
  (check-equal? '("alpha\n" #t) (text-and-modified a))
  (in-a undo:redo 2)
  (check-equal? '("3 1 alpha\n" #t) (text-and-modified a)))

(test "killing a file buffer moves its log to the saved state: the next visit opens at the file's text, the edits a redo away"
  (buffers:kill! a)
  (set! a (files:visit a-path))
  (check-equal? '("1 alpha\n" #f 1) (list (text a) (buffers:modified? a) (car (edits:tree a))))
  (in-a undo:redo 1)
  (check-equal? '("3 1 alpha\n" #t) (text-and-modified a)))

(test "when the file changed outside Tuna a new history starts, and a log that held unsaved edits is set aside with a warning"
  (set! a (visit-again! a-path))
  (logs:write-text! a-path "changed\n")
  (let ([reports (edits:reports-during (lambda () (set! a (visit-again! a-path))))])
    (check-equal? 1 (length reports))
    (check (warning? (car reports)))
    (check-equal? (list (files:abbreviated-path (string-append (logs:log-of a-path) ".stale")))
                  (condition-irritants (car reports))))
  (check-equal? '("changed\n" #f (0 0 (0 #f))) (list (text a) (buffers:modified? a) (edits:tree a)))
  (check (file-exists? (string-append (logs:log-of a-path) ".stale")))
  (in-a edits:insert 1 "new ")
  (check-equal? '(undo-history group saved at) (logs:logged-kinds a-path 4)))

(test "a file changed outside Tuna whose log held no unsaved edits starts a new history quietly"
  (files:save-buffer a)
  (logs:write-text! a-path "again\n")
  (buffers:kill! a)
  (check-equal? '() (edits:reports-during (lambda () (set! a (files:visit a-path)))))
  (check-equal? '("again\n" (0 0 (0 #f))) (list (text a) (edits:tree a))))

(test "loading undo, and so undo-log, attaches a modified file buffer at its log's current state"
  (in-a edits:insert 1 "x ")
  (in-a edits:insert 1 "y ")
  (test-user:settle)
  (reload-modules! '((undo)))
  (test-runner:wait-until (lambda () (guard (c [(assertion-violation? c) #f]) (= (length (edits:tree a)) 5))))
  (check-equal? '("y x again\n" #t (2 0 (0 #f) (1 0) (2 1))) (list (text a) (buffers:modified? a) (edits:tree a)))
  (in-a undo:undo 2)
  (check-equal? '("again\n" #f) (text-and-modified a))
  (in-a undo:redo 1))

(test "loading undo-log attaches an unmodified file buffer its log holds unsaved edits for, with them back"
  (unload-owner! (module-owner '(undo)))
  (files:revert-from-file a)
  (check-equal? '("again\n" #f) (text-and-modified a))
  (load-module! '(undo))
  (load-module! '(undo-log))
  (load-module! '(edits))
  (test-runner:wait-until (lambda () (buffers:modified? a)))
  (check-equal? '("x again\n" #t (1 0 (0 #f) (1 0) (2 1))) (list (text a) (buffers:modified? a) (edits:tree a))))

(test "a revert is one group"
  (logs:write-text! a-path "reverted\n")
  (files:revert-from-file a)
  (check-equal? '("reverted\n" #f (3 3 (0 #f) (1 0) (2 1) (3 1))) (list (text a) (buffers:modified? a) (edits:tree a)))
  (in-a undo:undo 1)
  (check-equal? '("x again\n" #t) (text-and-modified a))
  (in-a undo:redo 1))

(test "writing to another file starts a log there with the whole history"
  (let ([b-path (logs:home-path "b.txt")])
    (files:write-file b-path a)
    (check-equal? (list b-path '(3 3 (0 #f) (1 0) (2 1) (3 1))) (list (files:path a) (edits:tree a)))
    (check-equal? '(undo-history group group group saved saved at) (logs:logged-kinds b-path 7))
    (in-a undo:undo 1)
    (check (buffers:modified? a))))

(test "a buffer with an undo limit of 0 keeps no log, and its log is deleted"
  (let ([b-path (logs:home-path "b.txt")])
    (buffers:with-buffer a (options:set-local! undo:limit 0))
    (in-a edits:insert 1 "z ")
    (test-runner:wait-until (lambda () (not (logs:logged? b-path))))
    (check (not (logs:logged? b-path)))))

(test "a file that undo-log:keep-log? refuses keeps no log"
  (let ([g-path (logs:home-path "secret.gpg")])
    (options:with ([undo-log:keep-log? (lambda (path) (not (string=? (path-extension path) "gpg")))])
      (logs:write-text! g-path "s\n")
      (let ([g (files:visit g-path)])
        (edits:run-in g edits:insert 1 "t")
        (test-user:settle)
        (check-equal? '(1 0 (0 #f) (1 0)) (edits:tree g))
        (check (not (logs:logged? g-path)))))))

(define c-path (logs:home-path "c.txt"))

(define c #f)

(define (in-c command . args) (apply edits:run-in c command args))

(define unreadable-records #f)

(define (permission-denied? c) (i/o-file-protection-error? c))

(test "a log that cannot be read is reported and left as it is, and the buffer keeps no log for the session"
  (logs:write-text! c-path "gamma\n")
  (set! c (files:visit c-path))
  (in-c edits:insert 1 "1 ")
  (check-equal? '(undo-history group saved at) (logs:logged-kinds c-path 4))
  (set! unreadable-records (logs:records c-path))
  (chmod (logs:log-of c-path) 0)
  (let ([reports (edits:awaited-reports 1 (lambda () (set! c (visit-again! c-path))))])
    (check-equal? '(#t) (map permission-denied? reports)))
  (check-equal? '("gamma\n" (0 0 (0 #f))) (list (text c) (edits:tree c)))
  (in-c edits:insert 1 "x "))

(test "neither a save nor a reload of undo-log starts a log in place of one that cannot be read"
  (files:save-buffer c)
  (in-c edits:insert 1 "y ")
  (let ([reports (edits:awaited-reports 1 (lambda () (reload-modules! '((undo-log)))))])
    (check-equal? '(#t) (map permission-denied? reports)))
  (in-c edits:insert 1 "z ")
  (test-user:settle)
  (logs:write-text! c-path "gamma\n")
  (chmod (logs:log-of c-path) #o600)
  (check-equal? unreadable-records (logs:records c-path))
  (set! c (visit-again! c-path))
  (check-equal? '("1 gamma\n" #t) (text-and-modified c)))

(test "setting the undo limit to 0 in the batch that made an edit deletes the log after that edit's record is written"
  (in-c edits:insert 1 "2 ")
  (check-equal? '(undo-history group saved at group) (logs:logged-kinds c-path 5))
  (buffers:replace! c 1 1 "3 ")
  (buffers:with-buffer c (options:set-local! undo:limit 0))
  (test-runner:wait-until (lambda () (not (logs:logged? c-path))))
  (check (not (logs:logged? c-path))))

(test "a log grown past twice its size when last written whole is written again whole, without the moves that no longer count"
  (let* ([g-path (logs:home-path "grown.txt")] [count-at (lambda () (length (filter (lambda (k) (eq? k 'at)) (logs:kinds g-path))))])
    (logs:write-text! g-path "grown\n")
    (let ([g (files:visit g-path)])
      (edits:run-in g edits:insert 1 "x")
      (logs:logged-kinds g-path 4)
      (do ([i 0 (+ i 1)]) ((= i 100))
        (edits:run-in g edits:insert 1 (make-string 1000 #\g))
        (test-user:settle)
        (edits:run-in g undo:undo 1)
        (test-user:settle)
        (edits:run-in g undo:redo 1)
        (test-user:settle))
      (let ([tree (edits:tree g)] [shown (text g)])
        (test-runner:wait-until (lambda () (< 0 (count-at) 100)))
        (check-equal? 'undo-history (car (logs:kinds g-path)))
        (set! g (visit-again! g-path))
        (check-equal? (list shown tree) (list (text g) (edits:tree g)))))))
