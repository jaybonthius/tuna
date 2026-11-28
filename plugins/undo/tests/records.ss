(import (tuna) (test) (test-runner) (test-user) (options) (commands) (buffers) (document) (views) (undo) (undo-test edits))

(define (shapes records) (map (lambda (x) (list (car x) (cadr x))) records))

(define (text-document text) (document:from-datum (list 'buffers:text '() text)))

(define r (buffers:make "records" "\n"))

(test "take-records! gives the whole history the first time, then what changed since; #f with no history, () with no change"
  (check-equal? #f (undo:take-records! r))
  (undo-test/edits:run-in r undo-test/edits:insert 1 "a")
  (check-equal? '((undo-history 2) (group 1) (at 1)) (shapes (undo:take-records! r)))
  (check-equal? '() (undo:take-records! r))
  (undo-test/edits:run-in r undo-test/edits:insert 2 "b")
  (let ([g (car (undo:take-records! r))])
    (check-equal? '(group 2 1 () () ((2 () ("b"))))
      (list (car g) (cadr g) (caddr g) (list-ref g 4) (list-ref g 5)
            (map (lambda (e) (list (vector-ref e 0) (document:datums (vector-ref e 1)) (document:datums (vector-ref e 2))))
                 (list-tail g 6)))))
  (undo-test/edits:run-in r undo:undo 1)
  (check-equal? '((at 1)) (undo:take-records! r))
  (check-equal? '((undo-history 2) (group 1) (group 2) (at 1)) (shapes (undo:take-all-records! r)))
  (undo-test/edits:take-said!))

(test "a group taken while still open gets the cursors after it in a more record when it closes, which a history from the records keeps"
  (let* ([o (buffers:make "open" "abc\n")] [v (views:make o)] [taken #f])
    (views:set-point! v 2)
    (views:with-view v
      (undo:with-edit-group o
        (buffers:replace! o 2 2 "x")
        (set! taken (undo:take-records! o))
        (views:set-point! v 4)))
    (check-equal? '((undo-history 2) (group 1) (at 1)) (shapes taken))
    (check-equal? '() (list-ref (cadr taken) 5))
    (let ([more (undo:take-records! o)])
      (check-equal? '((more 1 (4))) more)
      (let-values ([(h fits?) (undo:records->history (append taken more))])
        (let* ([copy (buffers:make "open copy" "axbc\n")] [w (views:make copy)])
          (check-equal? #t (undo:install! copy h 0))
          (views:with-view w (commands:run undo:undo 1))
          (views:set-point! w 1)
          (views:with-view w (commands:run undo:redo 1))
          (check-equal? '("axbc\n" (4)) (list (undo-test/edits:text copy) (map views:cursor-point (views:cursors w))))
          (views:drop! w))))
    (views:drop! v))
  (undo-test/edits:take-said!))

(test "a history built from records holds the same tree, and gives the text of its current state from the text of any state"
  (let-values ([(copy fits?) (undo:records->history (undo:take-all-records! r))])
    (check fits?)
    (check-equal? "a\n" (document:text (undo:current-document copy 0 (text-document "\n"))))
    (check-equal? "a\n" (document:text (undo:current-document copy 2 (text-document "ab\n"))))
    (check-equal? '(#f #f)
      (list (undo:current-document copy 2 (text-document "xyz\n")) (undo:current-document copy 9 (text-document "\n"))))))

(test "installed on a buffer holding the text of its current state, a history from records is that buffer's history"
  (let-values ([(copy fits?) (undo:records->history (undo:take-all-records! r))])
    (let ([r2 (buffers:make "copy" "a\n")])
      (check-equal? #t (undo:install! r2 copy 0))
      (check-equal? '(1 1 (0 #f) (1 0) (2 1)) (undo-test/edits:tree r2))
      (undo-test/edits:run-in r2 undo:redo 1)
      (check-equal? '("ab\n" #t) (list (undo-test/edits:text r2) (buffers:modified? r2)))
      (undo-test/edits:run-in r2 undo:undo 2)
      (check-equal? "\n" (undo-test/edits:text r2))
      (check-raises (undo-test/edits:raised? 'undo:install! "not a history on no buffer") (undo:install! r copy 0))))
  (undo-test/edits:take-said!))

(test "a buffer last marked unmodified at the version holds the saved state's text, and install moves it on to the current state"
  (let-values ([(again fits?) (undo:records->history (undo:take-all-records! r))])
    (let ([r3 (buffers:make "saved" "\n")])
      (check-equal? #t (undo:install! r3 again 0 0))
      (check-equal? '("a\n" #t (1 0 (0 #f) (1 0) (2 1))) (list (undo-test/edits:text r3) (buffers:modified? r3) (undo-test/edits:tree r3)))
      (undo-test/edits:run-in r3 undo:undo 1)
      (check-equal? '("\n" #f) (list (undo-test/edits:text r3) (buffers:modified? r3)))))
  (undo-test/edits:take-said!))

(test "a buffer marked modified holds the current state's text, and the saved state becomes the one undo marks unmodified"
  (let-values ([(third fits?) (undo:records->history (undo:take-all-records! r))])
    (let ([r4 (buffers:make "unsaved" "a\n")])
      (buffers:set-modified! r4 #t)
      (check-equal? #t (undo:install! r4 third 0 0))
      (undo-test/edits:run-in r4 undo:undo 1)
      (check-equal? '("\n" #f) (list (undo-test/edits:text r4) (buffers:modified? r4)))))
  (undo-test/edits:take-said!))

(test "a state whose text is not as long as the buffer's installs nothing"
  (let-values ([(fourth fits?) (undo:records->history (undo:take-all-records! r))])
    (check-equal? #f (undo:install! (buffers:make "longer" "abc\n") fourth 0))))

(test "replaying stops at the first record that does not fit; records without a header, or with another version's, give no history; records->history takes a list"
  (let-values ([(h fits?) (undo:records->history '((undo-history 2 0 2 0) (group 1 7 0 () () #(1 #f #f))))])
    (check-equal? '(#t #f) (list (and h #t) fits?)))
  (let-values ([(h fits?) (undo:records->history '((at 1)))])
    (check-equal? '(#f #f) (list h fits?)))
  (let-values ([(h fits?) (undo:records->history '((undo-history 1 0 2 0) (at 0)))])
    (check-equal? '(#f #f) (list h fits?)))
  (let-values ([(h fits?) (undo:records->history '())])
    (check-equal? '(#f #t) (list h fits?)))
  (check-raises (undo-test/edits:raised? 'undo:records->history "not a list") (undo:records->history 'records)))

(test "attach! holds a buffer's edits until install!, which adds them to the history it installs; meanwhile a task asking for the history waits"
  (let ([a (buffers:make "attached" "\n")])
    (check-equal? '(#t #f) (let* ([first (undo:attach! a)] [second (undo:attach! a)]) (list first second)))
    (buffers:replace! a 1 1 "x")
    (let ([waiter (spawn-task (lambda (restore) (car (undo:history a))))])
      (check-equal? #t (undo:install! a #f 0))
      (check-equal? 1 (test-runner:join waiter)))
    (check-equal? '((1 0 (0 #f) (1 0)) #f) (let* ([t (undo-test/edits:tree a)] [again (undo:attach! a)]) (list t again)))
    (undo-test/edits:run-in a undo:undo 1)
    (check-equal? '("\n" #f) (list (undo-test/edits:text a) (buffers:modified? a))))
  (undo-test/edits:take-said!))

(test "while its records are taken, a history keeps the groups between the saved state and the current one past the limit"
  (let ([t (buffers:make "kept" "\n")])
    (buffers:with-buffer t (options:set-local! undo:limit 100))
    (undo-test/edits:run-in t undo-test/edits:insert 1 "a")
    (buffers:set-modified! t #f)
    (undo:take-records! t)
    (for-each (lambda (i) (undo-test/edits:run-in t undo-test/edits:insert 1 (make-string 30 #\x))) '(1 2 3))
    (test-user:settle)
    (undo-test/edits:run-in t undo:undo 3)
    (check-equal? '("a\n" #f) (list (undo-test/edits:text t) (buffers:modified? t))))
  (undo-test/edits:take-said!))
