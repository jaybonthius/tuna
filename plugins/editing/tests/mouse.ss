(import (tuna) (test) (test-user) (tables) (commands) (modes) (syntax) (layout) (layout-split) (views) (buffers)
        (kill-ring) (editing) (editing-test scene) (editing-test md))

(define double '("clicks" . 2))

(define triple '("clicks" . 3))

(define shift '("modifiers" . #("shift")))

(define (click! at . fields)
  (apply editing-test/scene:mouse! "down" at fields)
  (apply editing-test/scene:mouse! "click" at fields))

(define (right! at . fields) (apply click! at '("button" . 3) fields))

(define (with-word-characters characters thunk)
  (let ([kept (tables:ref syntax:word-characters modes:fundamental)])
    (tables:set! syntax:word-characters modes:fundamental characters)
    (thunk)
    (tables:set! syntax:word-characters modes:fundamental kept)))

(editing-test/scene:take-said!)

(test "a press moves point and clears the region, and the click leaves point there"
  (editing-test/scene:show! "one two three" 1)
  (test-user:press! "C-SPC")
  (editing-test/scene:mouse! "down" 5)
  (check-equal? '((5 #f)) (editing-test/scene:cursors))
  (editing-test/scene:mouse! "click" 6)
  (check-equal? '((6 #f)) (editing-test/scene:cursors))
  (editing-test/scene:take-said!))

(test "a drag sets the mark at the press once the pointer moves, and its region is temporary"
  (editing-test/scene:show! "one two three" 1)
  (editing-test/scene:mouse! "down" 2)
  (editing-test/scene:mouse! "move" 2)
  (check-equal? '((2 #f)) (editing-test/scene:cursors))
  (editing-test/scene:mouse! "move" 6)
  (check-equal? '((6 2)) (editing-test/scene:cursors))
  (editing-test/scene:mouse! "move" 9)
  (editing-test/scene:mouse! "drag" 10)
  (check-equal? '((10 2)) (editing-test/scene:cursors))
  (test-user:press! "C-f")
  (check-equal? '((11 #f)) (editing-test/scene:cursors))
  (editing-test/scene:mouse! "down" 10)
  (editing-test/scene:mouse! "move" 3)
  (editing-test/scene:mouse! "drag" 2)
  (check-equal? '((2 10)) (editing-test/scene:cursors)))

(test "a release outside the view ends the region at point, and an empty region is taken as a click"
  (editing-test/scene:show! "one two three" 1)
  (editing-test/scene:mouse! "down" 2)
  (editing-test/scene:mouse! "move" 7)
  (editing-test/scene:mouse! "drag" #f)
  (check-equal? '((7 2)) (editing-test/scene:cursors))
  (editing-test/scene:mouse! "down" 3)
  (editing-test/scene:mouse! "move" 6)
  (editing-test/scene:mouse! "move" 3)
  (check-equal? '((3 3)) (editing-test/scene:cursors))
  (editing-test/scene:mouse! "drag" 3)
  (check-equal? '((3 #f)) (editing-test/scene:cursors)))

(test "a mouse region puts nothing on the kill ring, and delete-selection replaces it"
  (editing-test/scene:with-setting editing:delete-selection #t
    (lambda ()
      (editing-test/scene:show! "one two three" 1)
      (let ([kills-before (length (kill-ring:entries))])
        (editing-test/scene:mouse! "down" 5)
        (editing-test/scene:mouse! "move" 8)
        (editing-test/scene:mouse! "drag" 8)
        (check-equal? '(((8 5)) #t) (list (editing-test/scene:cursors) (= kills-before (length (kill-ring:entries))))))
      (test-user:press! "X")
      (check-equal? '("one X three" ((6 #f))) (editing-test/scene:state)))))

(test "a second press selects the word, a run of whitespace or a run of one character there, by the mode's word characters"
  (editing-test/scene:show! "foo-bar  x---y\nsecond line\nthird" 1)
  (click! 2)
  (editing-test/scene:mouse! "down" 2 double)
  (check-equal? '((4 1)) (editing-test/scene:cursors))
  (editing-test/scene:mouse! "click" 2 double)
  (check-equal? '((4 1)) (editing-test/scene:cursors))
  (with-word-characters "-"
    (lambda ()
      (editing-test/scene:mouse! "down" 2 double)
      (check-equal? '((8 1)) (editing-test/scene:cursors))
      (editing-test/scene:mouse! "down" 9 double)
      (check-equal? '((10 8)) (editing-test/scene:cursors))))
  (with-word-characters ""
    (lambda ()
      (editing-test/scene:mouse! "down" 12 double)
      (check-equal? '((14 11)) (editing-test/scene:cursors)))))

(test "dragging from a second press extends by words; a third press selects the line with its line break"
  (editing-test/scene:show! "foo-bar  x---y\nsecond line\nthird" 1)
  (editing-test/scene:mouse! "down" 17 double)
  (editing-test/scene:mouse! "move" 24 double)
  (editing-test/scene:mouse! "drag" 24 double)
  (check-equal? '((27 16)) (editing-test/scene:cursors))
  (editing-test/scene:mouse! "down" 20 triple)
  (check-equal? '((28 16)) (editing-test/scene:cursors))
  (editing-test/scene:mouse! "click" 20 triple)
  (check-equal? '((28 16)) (editing-test/scene:cursors))
  (editing-test/scene:mouse! "down" 30 triple)
  (check-equal? '((33 28)) (editing-test/scene:cursors))
  (test-user:press! "C-b")
  (check-equal? '((32 #f)) (editing-test/scene:cursors)))

(test "dragging after a third press extends by whole lines, backwards too, and a single press then places point"
  (editing-test/scene:show! "foo-bar  x---y\nsecond line\nthird" 1)
  (editing-test/scene:mouse! "down" 20 triple)
  (editing-test/scene:mouse! "move" 3)
  (check-equal? '((1 28)) (editing-test/scene:cursors))
  (editing-test/scene:mouse! "move" 30)
  (editing-test/scene:mouse! "drag" 30 triple)
  (check-equal? '((33 16)) (editing-test/scene:cursors))
  (click! 20)
  (check-equal? '((20 #f)) (editing-test/scene:cursors)))

(test "the fourth press of a run is a first press, and the fifth selects a word again"
  (editing-test/scene:show! "foo-bar  x---y\nsecond line\nthird" 1)
  (click! 20 triple)
  (click! 20 '("clicks" . 4))
  (check-equal? '((20 #f)) (editing-test/scene:cursors))
  (editing-test/scene:mouse! "down" 20 '("clicks" . 5))
  (check-equal? '((22 16)) (editing-test/scene:cursors)))

(test "a run of whitespace runs across line breaks"
  (editing-test/scene:show! "abc  \n  def\n\nxyz" 1)
  (editing-test/scene:mouse! "down" 6 double)
  (check-equal? '((9 4)) (editing-test/scene:cursors))
  (editing-test/scene:mouse! "down" 13 double)
  (check-equal? '((14 12)) (editing-test/scene:cursors)))

(test "shift-click extends the region from the mark, or from point when there is none; shift-drag extends the same way"
  (editing-test/scene:show! "abcdefghij" 3)
  (click! 7 shift)
  (check-equal? '((7 3)) (editing-test/scene:cursors))
  (click! 9 shift)
  (check-equal? '((9 3)) (editing-test/scene:cursors))
  (editing-test/scene:mouse! "down" 5 shift)
  (editing-test/scene:mouse! "move" 1)
  (editing-test/scene:mouse! "drag" 2 shift)
  (check-equal? '((2 3)) (editing-test/scene:cursors))
  (test-user:press! "C-f")
  (check-equal? '((3 #f)) (editing-test/scene:cursors)))

(test "a click acts on the primary cursor and removes the others"
  (editing-test/scene:show! "one two three" 1 5 9)
  (click! 3)
  (check-equal? '((3 #f)) (editing-test/scene:cursors)))

(test "C-g ends a drag, and so does any key found outside its keymap"
  (editing-test/scene:show! "one two three" 1)
  (editing-test/scene:mouse! "down" 2)
  (test-user:press! "C-g")
  (editing-test/scene:mouse! "move" 6)
  (check-equal? '((2 #f)) (editing-test/scene:cursors))
  (editing-test/scene:mouse! "down" 2)
  (test-user:press! "C-e")
  (editing-test/scene:mouse! "move" 6)
  (check-equal? '((14 #f)) (editing-test/scene:cursors)))

(test "a click in another view selects it; a locked view, such as the echo area, and a view in no layout refuse clicks"
  (let ([first (begin (editing-test/scene:show! "one two three" 14) (editing-test/scene:view))])
    (test-user:press! "C-x 2")
    (let ([second (find (lambda (v) (not (eq? v first))) (layout:views))])
      (layout:select! first)
      (editing-test/scene:mouse-in! second "down" 6)
      (editing-test/scene:mouse-in! second "click" 6)
      (check-equal? '(#t 6 14) (list (eq? (layout:selected-view) second) (views:point second) (views:point first)))
      (let ([locked ((layout-split:display-at-side (layout:direction down) 90 'content '((locked . #t)))
                     (buffers:make (buffers:free-name "*locked*") ""))])
        (editing-test/scene:mouse-in! locked "down" 1)
        (editing-test/scene:mouse-in! locked "click" 1)
        (check (eq? (layout:selected-view) second))
        (layout:delete-part! (layout:view-node locked)))
      (let ([loose (views:make (views:buffer first))])
        (editing-test/scene:mouse-in! loose "down" 4)
        (editing-test/scene:mouse-in! loose "click" 4)
        (check-equal? '(#t 1) (list (eq? (layout:selected-view) second) (views:point loose)))
        (views:drop! loose))
      (editing-test/scene:mouse-in! first "down" #f)
      (check-equal? '(#t 14) (list (eq? (layout:selected-view) first) (views:point first)))
      (test-user:press! "C-x 1"))))

(test "the mouse commands check their event"
  (editing-test/scene:show! "one" 1)
  (check-equal? '((editing:mouse-set-point "not an event"))
    (editing-test/scene:reports-during (lambda () (views:with-view (editing-test/scene:view) (commands:run editing:mouse-set-point 'x))))))

(test "the right button with no region sets the mark at point and point at the click; with one it moves the nearer end; again at the same place it kills"
  (editing-test/scene:show! "one two three four" 1)
  (right! 9)
  (check-equal? '((9 1)) (editing-test/scene:cursors))
  (right! 3)
  (check-equal? '((9 3)) (editing-test/scene:cursors))
  (right! 3)
  (check-equal? '(("onthree four" ((3 #f))) "e two ") (list (editing-test/scene:state) (kill-ring:text (kill-ring:current))))
  (right! 7)
  (test-user:press! "C-f")
  (check-equal? '((8 #f)) (editing-test/scene:cursors))
  (click! 5 double)
  (check-equal? '((8 1)) (editing-test/scene:cursors))
  (right! 11)
  (check-equal? '((13 1)) (editing-test/scene:cursors)))

(test "the middle button inserts the primary selection, the last region active when a command ended, at the click"
  (editing-test/scene:show! "onthree four" 1)
  (click! 9 double)
  (check-equal? '((13 9)) (editing-test/scene:cursors))
  (check-equal? "four" (kill-ring:text (list (editing:primary-selection))))
  (click! 1 '("button" . 2))
  (check-equal? '("fouronthree four" ((5 #f))) (editing-test/scene:state)))

(test "the middle button yanks, so the yanker of the kind it inserts places it"
  (let ([calls '()])
    (tables:set! kill-ring:yankers 'editing-test/md:image (lambda (b at piece) (set! calls (cons at calls)) at))
    (editing-test/scene:show! (editing-test/md:doc '() (editing-test/md:para '() "Pic " (editing-test/md:image '((src . "a.png"))) ".\n")) 7)
    (views:set-cursor! (car (views:cursors (editing-test/scene:view))) 7 6)
    (test-user:press! "C-x C-x")
    (click! 3 '("button" . 2))
    (check-equal? '(3) calls)
    (tables:remove! kill-ring:yankers 'editing-test/md:image)))
