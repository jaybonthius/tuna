(import (tuna) (test) (test-user) (tables) (commands) (keys) (layout) (views) (buffers) (undo) (editing) (undo-test edits))

(define (bound-to key) (commands:command-name (tables:ref keys:global key)))

(define (reports keys) (undo-test/edits:reports-during (lambda () (test-user:press! keys))))

(define (current-buffer) (views:buffer (layout:selected-view)))

(define (points) (map views:cursor-point (views:cursors (layout:selected-view))))

(keys:bind! keys:global "C-z" undo:undo)
(keys:bind! keys:global "C-Z" undo:redo)

(undo-test/edits:take-said!)

(test "undo is on C-/, C-_ and C-x u, and redo on C-? and C-M-_; a configuration binds others, such as C-z and C-Z"
  (check-equal? '(undo:undo undo:undo undo:undo undo:redo undo:redo) (map bound-to '("C-/" "C-_" "C-x u" "C-?" "C-M-_")))
  (test-user:show! "x|y")
  (test-user:type! "abc")
  (test-user:press! "C-z")
  (check-equal? "x|y" (test-user:text))
  (test-user:press! "C-Z")
  (check-equal? "xabc|y" (test-user:text))
  (undo-test/edits:take-said!))

(test "C-/ after typing takes the word back in one step and says Undo, and the buffer is unmodified again"
  (test-user:show! "x|y")
  (test-user:type! "abc")
  (check (buffers:modified? (current-buffer)))
  (test-user:press! "C-/")
  (check-equal? "x|y" (test-user:text))
  (check-equal? #f (buffers:modified? (current-buffer)))
  (check-equal? '("Undo") (undo-test/edits:take-said!)))

(test "C-/ after 45 characters typed in one run takes back the last 5, then 20 at a time"
  (test-user:show! "|")
  (test-user:type! (make-string 45 #\a))
  (test-user:press! "C-/")
  (check-equal? (string-append (make-string 40 #\a) "|") (test-user:text))
  (test-user:press! "C-/")
  (check-equal? (string-append (make-string 20 #\a) "|") (test-user:text))
  (undo-test/edits:take-said!))

(test "C-u 2 C-/ undoes two runs"
  (test-user:show! "|")
  (test-user:type! "one ")
  (test-user:press! "C-g")
  (test-user:type! "two ")
  (test-user:press! "C-g")
  (test-user:type! "three")
  (test-user:press! "C-u 2 C-/")
  (check-equal? "one |" (test-user:text))
  (undo-test/edits:take-said!))

(test "M-- C-/ and M-0 C-? change nothing and say the count must be 1 or more"
  (test-user:show! "x|y")
  (test-user:type! "abc")
  (check-equal? '((undo:undo "undo takes a count of 1 or more")) (reports "M-- C-/"))
  (check-equal? "xabc|y" (test-user:text))
  (test-user:press! "C-/")
  (check-equal? '((undo:redo "redo takes a count of 1 or more")) (reports "M-0 C-?"))
  (check-equal? "x|y" (test-user:text))
  (undo-test/edits:take-said!))

(test "C-/ with nothing left changes nothing and says so"
  (test-user:show! "x|y")
  (check-equal? '((undo:undo "no further undo information")) (reports "C-/"))
  (check-equal? "x|y" (test-user:text)))

(test "C-? after C-/ puts the text back with point after it and says Redo; again, with nothing to redo, it says so"
  (test-user:show! "x|y")
  (test-user:type! "abc")
  (test-user:press! "C-/ C-?")
  (check-equal? "xabc|y" (test-user:text))
  (check-equal? '("Undo" "Redo") (undo-test/edits:take-said!))
  (check-equal? '((undo:redo "no further redo information")) (reports "C-?")))

(test "C-/ after a yank at three cursors puts each back where it was before it, and C-? where it was after it"
  (test-user:show! "|one\ntwo\nthree")
  (views:add-cursor! (layout:selected-view) 5)
  (views:add-cursor! (layout:selected-view) 9)
  (test-user:press! "C-k C-y")
  (check-equal? '("one\ntwo\nthree" (4 8 14)) (list (undo-test/edits:text (current-buffer)) (points)))
  (test-user:press! "C-/")
  (check-equal? '("\n\n" (1 2 3)) (list (undo-test/edits:text (current-buffer)) (points)))
  (test-user:press! "C-?")
  (check-equal? '("one\ntwo\nthree" (4 8 14)) (list (undo-test/edits:text (current-buffer)) (points)))
  (undo-test/edits:take-said!))

(test "after an undo, C-g then C-/ moves on to the parent state, not back"
  (test-user:show! "x|y")
  (test-user:type! "abc")
  (test-user:press! "C-/ C-g")
  (check-equal? '((undo:undo "no further undo information")) (reports "C-/"))
  (check-equal? "x|y" (test-user:text))
  (undo-test/edits:take-said!))

(test "C-/ with point moved away puts point back where the edit was"
  (test-user:show! "one |two three")
  (test-user:type! "big ")
  (test-user:press! "C-e C-/")
  (check-equal? "one |two three" (test-user:text))
  (undo-test/edits:take-said!))

(test "C-/ after C-w puts the text back, with point where it was before the kill"
  (test-user:show! "one |two three")
  (test-user:press! "C-SPC M-f C-x C-x C-w")
  (check-equal? "one | three" (test-user:text))
  (test-user:press! "C-/")
  (check-equal? "one |two three" (test-user:text))
  (undo-test/edits:take-said!))
