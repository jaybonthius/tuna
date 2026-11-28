(import (tuna) (test) (test-user) (buffers) (undo) (undo-test edits))

(test "a group is one command's edits to a buffer, and the edits of one batch outside a command; undo and redo move by groups"
  (let ([b (buffers:make "notes" "abc\n")])
    (undo-test/edits:run-in b undo-test/edits:insert 1 "1")
    (undo-test/edits:run-in b undo-test/edits:insert 1 "2")
    (buffers:replace! b 1 1 "3")
    (buffers:replace! b 1 1 "4")
    (test-user:settle)
    (buffers:replace! b 1 1 "5")
    (test-user:settle)
    (buffers:replace! b 1 1 "6")
    (test-user:settle)
    (check-equal? '("654321abc\n" (#f 0 1 2 3 4)) (list (undo-test/edits:text b) (undo-test/edits:parents b)))
    (undo-test/edits:run-in b undo:undo 1)
    (check-equal? "54321abc\n" (undo-test/edits:text b))
    (undo-test/edits:run-in b undo:undo 2)
    (check-equal? "21abc\n" (undo-test/edits:text b))
    (undo-test/edits:run-in b undo:redo 1)
    (check-equal? "4321abc\n" (undo-test/edits:text b))
    (undo-test/edits:run-in b undo:undo 3)
    (check-equal? "abc\n" (undo-test/edits:text b))
    (check-equal? '((undo:undo "no further undo information")) (undo-test/edits:reports-during (lambda () (undo-test/edits:run-in b undo:undo 1))))
    (check-equal? '((undo:redo "no further redo information")) (undo-test/edits:reports-during (lambda () (undo-test/edits:run-in b undo:redo 9))))
    (check-equal? "654321abc\n" (undo-test/edits:text b)))
  (undo-test/edits:take-said!))

(test "undo and redo take a positive count, a current buffer and a buffer"
  (for-each (lambda (n) (check-raises (undo-test/edits:raised? 'undo:undo "undo takes a count of 1 or more") (undo:undo n))) '(0 -1))
  (for-each (lambda (n) (check-raises (undo-test/edits:raised? 'undo:undo "not a positive count") (undo:undo n))) '(1.5 x))
  (check-raises (undo-test/edits:raised? 'undo:redo "redo takes a count of 1 or more") (undo:redo 0))
  (check-raises (undo-test/edits:raised? 'undo:undo "no buffer is current") (undo:undo 1))
  (check-raises (undo-test/edits:raised? 'undo:history "not a buffer") (undo:history "notes")))

(test "a command paused at a prompt keeps the edits it made before the pause as a group of their own"
  (let ([p (buffers:make "paused" "\n")])
    (undo-test/edits:run-in p undo-test/edits:insert-pausing "x")
    (check-equal? '("xx\n" (#f 0 1)) (list (undo-test/edits:text p) (undo-test/edits:parents p)))
    (undo-test/edits:run-in p undo:undo 1)
    (check-equal? "x\n" (undo-test/edits:text p)))
  (undo-test/edits:take-said!))

(test "typing joins the previous group while the same command runs again, up to 20 commands; another command ends the run"
  (let* ([t (buffers:make "typing" "\n")] [type (lambda (s) (undo-test/edits:run-in t undo-test/edits:type s))])
    (for-each type (map string (string->list "abcdefghijklmnopqrstuvwxy")))
    (check-equal? '("\nabcdefghijklmnopqrstuvwxy" (#f 0 1)) (list (undo-test/edits:text t) (undo-test/edits:parents t)))
    (undo-test/edits:run-in t undo:undo 1)
    (check-equal? "\nabcdefghijklmnopqrst" (undo-test/edits:text t))
    (undo-test/edits:run-in t undo:undo 1)
    (check-equal? "\n" (undo-test/edits:text t))
    (undo-test/edits:run-in t undo:redo 1)
    (for-each type '("1" "2"))
    (undo-test/edits:run-in t undo-test/edits:insert 1 "#")
    (for-each type '("3" "4"))
    (check-equal? '("#\nabcdefghijklmnopqrst1234" (#f 0 1 1 3 4)) (list (undo-test/edits:text t) (undo-test/edits:parents t)))
    (undo-test/edits:run-in t undo:undo 1)
    (check-equal? "#\nabcdefghijklmnopqrst12" (undo-test/edits:text t)))
  (undo-test/edits:take-said!))

(test "typing into another buffer between two runs ends the group"
  (let ([t (buffers:make "typed" "\n")] [other (buffers:make "elsewhere" "\n")])
    (undo-test/edits:run-in t undo-test/edits:type "5")
    (undo-test/edits:run-in other undo-test/edits:type "z")
    (undo-test/edits:run-in t undo-test/edits:type "6")
    (undo-test/edits:run-in t undo:undo 1)
    (check-equal? "\n5" (undo-test/edits:text t)))
  (undo-test/edits:take-said!))

(test "an edit group holds every edit its body makes, across commands and pauses, and returns the body's values"
  (let ([g (buffers:make "group" "\n")])
    (check-equal? '(1 2)
      (call-with-values
        (lambda ()
          (undo:with-edit-group g
            (undo-test/edits:run-in g undo-test/edits:insert 1 "a")
            (test-user:settle)
            (undo-test/edits:run-in g undo-test/edits:insert 1 "b")
            (values 1 2)))
        list))
    (check-equal? '("ba\n" (#f 0)) (list (undo-test/edits:text g) (undo-test/edits:parents g)))))

(test "a body that raises has its edits undone, unrecorded, and the condition raised again"
  (let ([g (buffers:make "raising" "ba\n")])
    (check-raises (undo-test/edits:raised? 'body "failed")
      (undo:with-edit-group g
        (buffers:replace! g 1 1 "x")
        (test-user:settle)
        (buffers:replace! g 1 1 "y")
        (error 'body "failed")))
    (check-equal? '("ba\n" (#f)) (list (undo-test/edits:text g) (undo-test/edits:parents g)))))

(test "a nested group joins the outer one; when it raises, only its own edits are undone"
  (let ([g (buffers:make "nested" "ba\n")])
    (undo:call-with-edit-group g
      (lambda ()
        (buffers:replace! g 1 1 "1")
        (guard (c [(eq? c 'inner) 'caught])
          (undo:with-edit-group g
            (buffers:replace! g 1 1 "2")
            (raise 'inner)))
        (buffers:replace! g 1 1 "3")))
    (check-equal? '("31ba\n" (#f 0)) (list (undo-test/edits:text g) (undo-test/edits:parents g)))
    (undo-test/edits:run-in g undo:undo 1)
    (check-equal? "ba\n" (undo-test/edits:text g)))
  (undo-test/edits:take-said!))

(test "a body left by a continuation ends its group once its task goes on; only a pause comes back into the body"
  (let ([e (buffers:make "escape" "0123456789\n")])
    (check-equal? 'escaped (call/cc (lambda (out) (undo:with-edit-group e (buffers:replace! e 1 1 "a") (out 'escaped)))))
    (undo-test/edits:run-in e undo-test/edits:insert 1 "b")
    (undo-test/edits:run-in e undo-test/edits:insert 1 "c")
    (call/cc (lambda (out) (undo:with-edit-group e (buffers:replace! e 1 1 "d") (out 'escaped))))
    (undo-test/edits:run-in e undo-test/edits:insert 1 "f")
    (check-equal? '("fdcba0123456789\n" (#f 0 1 2 3 4)) (list (undo-test/edits:text e) (undo-test/edits:parents e)))))

(test "call-with-edit-group takes a buffer and a procedure"
  (let ([g (buffers:make "checked" "\n")])
    (check-raises (undo-test/edits:raised? 'undo:call-with-edit-group "not a procedure") (undo:call-with-edit-group g 'thunk))
    (check-raises (undo-test/edits:raised? 'undo:call-with-edit-group "not a buffer") (undo:call-with-edit-group "group" void))))

(test "with-edit-group's example: two edits, one group"
  (let ([notes (buffers:make "example" "Buy milk.\n")])
    (buffers:with-buffer notes
      (undo:with-edit-group (buffers:current)
        (buffers:replace! (buffers:current) 1 1 "a")
        (buffers:replace! (buffers:current) 2 2 "b")))
    (check-equal? '("abBuy milk.\n" (1 0 (0 #f) (1 0))) (list (undo-test/edits:text notes) (undo-test/edits:tree notes)))
    (undo-test/edits:run-in notes undo:undo 1)
    (check-equal? "Buy milk.\n" (undo-test/edits:text notes))
    (undo-test/edits:run-in notes undo:redo 1)
    (check-equal? "abBuy milk.\n" (undo-test/edits:text notes)))
  (undo-test/edits:take-said!))
