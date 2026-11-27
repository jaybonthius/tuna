(import (tuna) (test) (test-user) (tables) (commands) (keys) (layout) (views) (buffers) (undo) (editing) (edits))

(define (bound-to key) (commands:command-name (tables:ref keys:global key)))

(define (reports keys) (edits:reports-during (lambda () (test-user:press! keys))))

(define (current-buffer) (views:buffer (layout:selected-view)))

(keys:bind! keys:global "C-z" undo:undo)
(keys:bind! keys:global "C-Z" undo:redo)

(edits:take-said!)

(test "undo is on C-/, C-_ and C-x u, and redo on C-? and C-M-_; a configuration binds others, such as C-z and C-Z"
  (check-equal? '(undo:undo undo:undo undo:undo undo:redo undo:redo) (map bound-to '("C-/" "C-_" "C-x u" "C-?" "C-M-_")))
  (test-user:show! "x|y")
  (test-user:type! "abc")
  (test-user:press! "C-z")
  (check-equal? "x|y" (test-user:text))
  (test-user:press! "C-Z")
  (check-equal? "xabc|y" (test-user:text))
  (edits:take-said!))

(test "C-/ after typing takes the word back in one step and says Undo, and the buffer is unmodified again"
  (test-user:show! "x|y")
  (test-user:type! "abc")
  (check (buffers:modified? (current-buffer)))
  (test-user:press! "C-/")
  (check-equal? "x|y" (test-user:text))
  (check-equal? #f (buffers:modified? (current-buffer)))
  (check-equal? '("Undo") (edits:take-said!)))

(test "C-/ after 45 characters typed in one run takes back the last 5, then 20 at a time"
  (test-user:show! "|")
  (test-user:type! (make-string 45 #\a))
  (test-user:press! "C-/")
  (check-equal? (string-append (make-string 40 #\a) "|") (test-user:text))
  (test-user:press! "C-/")
  (check-equal? (string-append (make-string 20 #\a) "|") (test-user:text))
  (edits:take-said!))

(test "C-u 2 C-/ undoes two runs"
  (test-user:show! "|")
  (test-user:type! "one ")
  (test-user:press! "C-g")
  (test-user:type! "two ")
  (test-user:press! "C-g")
  (test-user:type! "three")
  (test-user:press! "C-u 2 C-/")
  (check-equal? "one |" (test-user:text))
  (edits:take-said!))

(test "C-/ with nothing left changes nothing and says so"
  (test-user:show! "x|y")
  (check-equal? '((undo:undo "no further undo information")) (reports "C-/"))
  (check-equal? "x|y" (test-user:text)))

(test "C-? after C-/ puts the text back with point after it and says Redo; again, with nothing to redo, it says so"
  (test-user:show! "x|y")
  (test-user:type! "abc")
  (test-user:press! "C-/ C-?")
  (check-equal? "xabc|y" (test-user:text))
  (check-equal? '("Undo" "Redo") (edits:take-said!))
  (check-equal? '((undo:redo "no further redo information")) (reports "C-?")))

(test "after an undo, C-g then C-/ moves on to the parent state, not back"
  (test-user:show! "x|y")
  (test-user:type! "abc")
  (test-user:press! "C-/ C-g")
  (check-equal? '((undo:undo "no further undo information")) (reports "C-/"))
  (check-equal? "x|y" (test-user:text))
  (edits:take-said!))

(test "C-/ with point moved away puts point back where the edit was"
  (test-user:show! "one |two three")
  (test-user:type! "big ")
  (test-user:press! "C-e C-/")
  (check-equal? "one |two three" (test-user:text))
  (edits:take-said!))

(test "C-/ after C-w puts the text back, with point where it was before the kill"
  (test-user:show! "one |two three")
  (test-user:press! "C-SPC M-f C-x C-x C-w")
  (check-equal? "one | three" (test-user:text))
  (test-user:press! "C-/")
  (check-equal? "one |two three" (test-user:text))
  (edits:take-said!))
