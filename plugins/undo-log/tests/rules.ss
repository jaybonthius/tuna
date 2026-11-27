(import (tuna) (test) (test-runner) (test-user) (hooks) (options) (ask) (commands) (document) (buffers) (files)
        (undo) (undo-log) (edits) (logs))

(test "undo-log:keep-log? chooses the files whose buffers keep a log, and by default refuses those under /tmp/ and /dev/shm/"
  (options:with ([undo-log:keep-log? (lambda (path) (not (string=? (path-extension path) "gpg")))])
    (check-equal? '(#f #t) (map (undo-log:keep-log?) '("/home/me/notes.gpg" "/home/me/notes.txt"))))
  (check-equal? '(#f #f #t #t) (map (options:default undo-log:keep-log?) '("/tmp/a.txt" "/dev/shm/a" "/home/me/a.txt" "/tmpfile"))))

(options:set! undo-log:keep-log? (lambda (path) #t))

(define (kept? b) (exists (lambda (entry) (entry b)) (hooks:entries files:unsaved-kept)))

(define (visited name text)
  (let ([path (logs:home-path name)])
    (logs:write-text! path text)
    (files:visit path)))

(define r-path (logs:home-path "r.txt"))

(define r (visited "r.txt" "rules\n"))

(test "reloading undo-log alone keeps undo's history, and writes the log again whole with the saves it held"
  (edits:run-in r edits:insert 1 "1 ")
  (files:save-buffer r)
  (edits:run-in r edits:insert 1 "2 ")
  (check-equal? '(undo-history group saved at saved group) (logs:logged-kinds r-path 6))
  (reload-modules! '((undo-log)))
  (test-runner:wait-until (lambda () (equal? (logs:kinds r-path) '(undo-history group group saved saved at))))
  (edits:run-in r edits:insert 1 "3 ")
  (check-equal? '(undo-history group group saved saved at group) (logs:logged-kinds r-path 7))
  (check-equal? '(3 1 (0 #f) (1 0) (2 1) (3 2)) (edits:tree r)))

(define n (visited "n.txt" "no log\n"))

(buffers:with-buffer n (options:set-local! undo:limit 0))

(test "files:save-buffers-kill-tuna asks only when a modified buffer keeps no log of its edits"
  (check (and (buffers:modified? r) (kept? r)))
  (buffers:replace! n 1 1 "x")
  (check (not (kept? n)))
  (let ([asked '()])
    (options:with ([ask:yes-or-no-reader (lambda (question) (set! asked (cons question asked)) #f)])
      (commands:run files:save-buffers-kill-tuna))
    (check-equal? '("Modified buffers exist; exit anyway? ") asked)))

(test "a command that kills a modified file buffer asks only about one that keeps no log"
  (let ([k (visited "k.txt" "kill\n")] [asked '()])
    (edits:run-in k edits:insert 1 "k ")
    (check-equal? '(undo-history group saved at) (logs:logged-kinds (logs:home-path "k.txt") 4))
    (options:with ([ask:y-or-n-reader (lambda (question) (set! asked (cons question asked)) #f)])
      (check-equal? '(#t #f) (list (commands:run edits:kill k) (commands:run edits:kill n))))
    (check-equal? 1 (length asked))
    (check (buffers:live? n))))

(test "undo:forget! drops a buffer's history and so its log; the log starts again with no saved state, so the edits are not kept"
  (undo:forget! r)
  (test-runner:wait-until (lambda () (not (logs:logged? r-path))))
  (edits:run-in r edits:insert 1 "4 ")
  (check-equal? '(undo-history group at) (logs:logged-kinds r-path 3))
  (check-equal? '(#t #f #f) (list (buffers:modified? r) (cadr (undo:history r)) (kept? r))))

(test "an edit group larger than the undo limit leaves a history with no saved state, so the edits are not kept"
  (let ([l (visited "l.txt" "limit\n")])
    (buffers:with-buffer l (options:set-local! undo:limit 100))
    (let ([reports (edits:reports-during (lambda () (buffers:replace! l 1 1 (make-string 200 #\x)) (test-user:settle)))])
      (check-equal? '(undo:limit) (map condition-who reports)))
    (check-equal? '(#t #f #f) (list (buffers:modified? l) (cadr (undo:history l)) (kept? l)))))

(test "reloading undo-log alone writes no log for a buffer that had none until its history holds a group, and then with the saved state"
  (let ([f (visited "f.txt" "fresh\n")] [f-path (logs:home-path "f.txt")])
    (reload-modules! '((undo-log)))
    (test-user:settle)
    (check (not (logs:logged? f-path)))
    (buffers:replace! f 1 1 "x")
    (check-equal? '(undo-history group saved at) (logs:logged-kinds f-path 4))
    (check (kept? f))))

(test "reloading undo-log alone does not keep edits made while the buffer kept no log, as it has no saved state for them"
  (let ([m-path (logs:home-path "m.nolog")])
    (options:set! undo-log:keep-log? (lambda (path) (not (string=? (path-extension path) "nolog"))))
    (let ([m (visited "m.nolog" "missed\n")])
      (buffers:replace! m 1 1 "x")
      (test-user:settle)
      (options:set! undo-log:keep-log? (lambda (path) #t))
      (reload-modules! '((undo-log)))
      (buffers:replace! m 1 1 "y")
      (logs:logged-kinds m-path 3)
      (check-equal? '(#t 0 #f) (list (buffers:modified? m) (cadr (undo:history m)) (kept? m))))))

(test "a silent edit that changes tokens leaves the edits unkept until the buffer is saved again"
  (let ([s (visited "s.txt" "silent\n")])
    (edits:run-in s edits:insert 1 "a ")
    (check-equal? '(undo-history group saved at) (logs:logged-kinds (logs:home-path "s.txt") 4))
    (check (kept? s))
    (buffers:with-silent-edits s (buffers:replace! s 3 3 "~"))
    (check-equal? '(#t #f) (list (buffers:modified? s) (kept? s)))
    (files:save-buffer s)
    (edits:run-in s edits:insert 1 "b ")
    (test-user:settle)
    (check-equal? '(#t #t) (list (buffers:modified? s) (kept? s)))))

(buffers:define-layer marks (travels))

(test "a silent edit that changes no token leaves undo's history, so the edits stay kept"
  (let ([t (visited "t.txt" "spans\n")])
    (edits:run-in t edits:insert 1 "a ")
    (check-equal? '(undo-history group saved at) (logs:logged-kinds (logs:home-path "t.txt") 4))
    (check (kept? t))
    (buffers:with-silent-edits t (buffers:add-span! (buffers:layer t marks) 3 6 'seen))
    (check-equal? (list #t #f '(1 0 (0 #f) (1 0)) #t)
      (list (buffers:modified? t) (buffers:edit-moves? (car (reverse (buffers:edits-since t 1)))) (edits:tree t) (kept? t)))))
