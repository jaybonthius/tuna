(import (tuna) (test) (test-user) (buffers) (undo) (edits))

(test "a group is one command's edits to a buffer, and the edits of one batch outside a command; undo and redo move by groups"
  (let ([b (buffers:make "notes" "abc\n")])
    (edits:run-in b edits:insert 1 "1")
    (edits:run-in b edits:insert 1 "2")
    (buffers:replace! b 1 1 "3")
    (buffers:replace! b 1 1 "4")
    (test-user:settle)
    (buffers:replace! b 1 1 "5")
    (test-user:settle)
    (buffers:replace! b 1 1 "6")
    (test-user:settle)
    (check-equal? '("654321abc\n" (#f 0 1 2 3 4)) (list (edits:text b) (edits:parents b)))
    (edits:run-in b undo:undo 1)
    (check-equal? "54321abc\n" (edits:text b))
    (edits:run-in b undo:undo 2)
    (check-equal? "21abc\n" (edits:text b))
    (edits:run-in b undo:redo 1)
    (check-equal? "4321abc\n" (edits:text b))
    (edits:run-in b undo:undo 3)
    (check-equal? "abc\n" (edits:text b))
    (check-equal? '((undo:undo "no further undo information")) (edits:reports-during (lambda () (edits:run-in b undo:undo 1))))
    (check-equal? '((undo:redo "no further redo information")) (edits:reports-during (lambda () (edits:run-in b undo:redo 9))))
    (check-equal? "654321abc\n" (edits:text b)))
  (edits:take-said!))

(test "undo and redo take a positive count, a current buffer and a buffer"
  (for-each (lambda (n) (check-raises (edits:raised? 'undo:undo "not a positive count") (undo:undo n))) '(0 -1 1.5 x))
  (check-raises (edits:raised? 'undo:redo "not a positive count") (undo:redo 0))
  (check-raises (edits:raised? 'undo:undo "no buffer is current") (undo:undo 1))
  (check-raises (edits:raised? 'undo:history "not a buffer") (undo:history "notes")))

(test "a command paused at a prompt keeps the edits it made before the pause as a group of their own"
  (let ([p (buffers:make "paused" "\n")])
    (edits:run-in p edits:insert-pausing "x")
    (check-equal? '("xx\n" (#f 0 1)) (list (edits:text p) (edits:parents p)))
    (edits:run-in p undo:undo 1)
    (check-equal? "x\n" (edits:text p)))
  (edits:take-said!))

(test "typing joins the previous group while the same command runs again, up to 20 commands; another command ends the run"
  (let* ([t (buffers:make "typing" "\n")] [type (lambda (s) (edits:run-in t edits:type s))])
    (for-each type (map string (string->list "abcdefghijklmnopqrstuvwxy")))
    (check-equal? '("\nabcdefghijklmnopqrstuvwxy" (#f 0 1)) (list (edits:text t) (edits:parents t)))
    (edits:run-in t undo:undo 1)
    (check-equal? "\nabcdefghijklmnopqrst" (edits:text t))
    (edits:run-in t undo:undo 1)
    (check-equal? "\n" (edits:text t))
    (edits:run-in t undo:redo 1)
    (for-each type '("1" "2"))
    (edits:run-in t edits:insert 1 "#")
    (for-each type '("3" "4"))
    (check-equal? '("#\nabcdefghijklmnopqrst1234" (#f 0 1 1 3 4)) (list (edits:text t) (edits:parents t)))
    (edits:run-in t undo:undo 1)
    (check-equal? "#\nabcdefghijklmnopqrst12" (edits:text t)))
  (edits:take-said!))

(test "typing into another buffer between two runs ends the group"
  (let ([t (buffers:make "typed" "\n")] [other (buffers:make "elsewhere" "\n")])
    (edits:run-in t edits:type "5")
    (edits:run-in other edits:type "z")
    (edits:run-in t edits:type "6")
    (edits:run-in t undo:undo 1)
    (check-equal? "\n5" (edits:text t)))
  (edits:take-said!))

(test "an edit group holds every edit its body makes, across commands and pauses, and returns the body's values"
  (let ([g (buffers:make "group" "\n")])
    (check-equal? '(1 2)
      (call-with-values
        (lambda ()
          (undo:with-edit-group g
            (edits:run-in g edits:insert 1 "a")
            (test-user:settle)
            (edits:run-in g edits:insert 1 "b")
            (values 1 2)))
        list))
    (check-equal? '("ba\n" (#f 0)) (list (edits:text g) (edits:parents g)))))

(test "a body that raises has its edits undone, unrecorded, and the condition raised again"
  (let ([g (buffers:make "raising" "ba\n")])
    (check-raises (edits:raised? 'body "failed")
      (undo:with-edit-group g
        (buffers:replace! g 1 1 "x")
        (test-user:settle)
        (buffers:replace! g 1 1 "y")
        (error 'body "failed")))
    (check-equal? '("ba\n" (#f)) (list (edits:text g) (edits:parents g)))))

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
    (check-equal? '("31ba\n" (#f 0)) (list (edits:text g) (edits:parents g)))
    (edits:run-in g undo:undo 1)
    (check-equal? "ba\n" (edits:text g)))
  (edits:take-said!))

(test "a body left by a continuation ends its group once its task goes on; only a pause comes back into the body"
  (let ([e (buffers:make "escape" "0123456789\n")])
    (check-equal? 'escaped (call/cc (lambda (out) (undo:with-edit-group e (buffers:replace! e 1 1 "a") (out 'escaped)))))
    (edits:run-in e edits:insert 1 "b")
    (edits:run-in e edits:insert 1 "c")
    (call/cc (lambda (out) (undo:with-edit-group e (buffers:replace! e 1 1 "d") (out 'escaped))))
    (edits:run-in e edits:insert 1 "f")
    (check-equal? '("fdcba0123456789\n" (#f 0 1 2 3 4)) (list (edits:text e) (edits:parents e)))))

(test "call-with-edit-group takes a buffer and a procedure"
  (let ([g (buffers:make "checked" "\n")])
    (check-raises (edits:raised? 'undo:call-with-edit-group "not a procedure") (undo:call-with-edit-group g 'thunk))
    (check-raises (edits:raised? 'undo:call-with-edit-group "not a buffer") (undo:call-with-edit-group "group" void))))

(test "with-edit-group's example: two edits, one group"
  (let ([notes (buffers:make "example" "Buy milk.\n")])
    (buffers:with-buffer notes
      (undo:with-edit-group (buffers:current)
        (buffers:replace! (buffers:current) 1 1 "a")
        (buffers:replace! (buffers:current) 2 2 "b")))
    (check-equal? '("abBuy milk.\n" (1 0 (0 #f) (1 0))) (list (edits:text notes) (edits:tree notes)))
    (edits:run-in notes undo:undo 1)
    (check-equal? "Buy milk.\n" (edits:text notes))
    (edits:run-in notes undo:redo 1)
    (check-equal? "abBuy milk.\n" (edits:text notes)))
  (edits:take-said!))
