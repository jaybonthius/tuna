(import (tuna) (test) (test-user) (layout) (layout-split) (layout-tabs) (echo-area) (minibuffer) (views) (buffers) (document)
        (layout-test parts) (layout-test focus))

(define atom layout-test/parts:atom)
(define view-named layout-test/focus:view-named)
(define begin! layout-test/focus:begin!)
(define reset! layout-test/focus:reset!)
(define made-beside layout-test/focus:made-beside)
(define selected layout-test/focus:selected)
(define shown layout-test/focus:shown)
(define prompt! layout-test/focus:prompt!)
(define who layout-test/focus:who)

(define (select-in-order! . vs) (for-each layout:select! vs))

(define (click-part! v) (layout-test/parts:click! (document:node-start (layout:view-node v))))

(test "a prompt that ended leaves its locked part in the order, and the successor passes over it and records no use"
  (let* ([a (begin! "a")] [b (begin (test-user:press! "C-x 3") (made-beside a "b"))])
    (prompt!)
    (check-equal? '("a" " *Minibuf*") (layout-test/focus:order))
    (let ([before (layout-test/focus:front 3)])
      (test-user:press! "C-x 0")
      (check-equal? "b" (selected))
      (check-equal? before (layout-test/focus:front 3)))
    (check-raises (layout-test/parts:raised-with 'layout:delete-part! "the last view of its level")
                  (layout-test/focus:in-client layout:delete-view))))

(test "after a prompt answered with RET, the successor below is chosen the same way"
  (let* ([a (begin! "a")] [b (begin (test-user:press! "C-x 2") (made-beside a "b"))])
    (layout-test/focus:ask!)
    (test-user:press! "RET")
    (check-equal? "" (layout-test/focus:answer))
    (test-user:press! "C-x 0")
    (check-equal? "b" (selected))))

(test "the view selected before a prompt is chosen over one never selected, and with no prompt the successor is the same"
  (let* ([a (begin! "a")] [b (begin (test-user:press! "C-x 3") (made-beside a "b"))])
    (test-user:press! "C-x o")
    (prompt!)
    (test-user:press! "C-x 0")
    (check-equal? "a" (selected)))
  (let* ([a (begin! "a")] [b (begin (test-user:press! "C-x 3") (made-beside a "b"))])
    (test-user:press! "C-x 0")
    (check-equal? "b" (selected))))

(test "a locked bar first in the layout is passed over"
  (let ([a (view-named "a")] [bar (view-named "bar")])
    (layout-test/parts:set-parts!
      (layout-split:container '((direction . column)) (atom bar '(locked . #t)) (layout:level '() (atom a))))
    (layout:select! a)
    (test-user:press! "C-x 3")
    (made-beside a "b")
    (test-user:press! "C-x 0")
    (check-equal? "b" (selected))))

(test "a view in a nested level hands over to that level's view, whichever order the views beside it were selected in"
  (let ([a (view-named "a")] [b (view-named "b")] [c (view-named "c")])
    (reset! (layout-split:container '((direction . row)) (atom a) (layout:level '() (layout-split:container '((direction . column)) (atom b) (atom c)))))
    (select-in-order! a c b)
    (prompt!)
    (test-user:press! "C-x 0")
    (check-equal? "c" (selected))
    (let ([b2 (view-named "b2")])
      (reset! (layout-split:container '((direction . row)) (atom a) (layout:level '() (layout-split:container '((direction . column)) (atom b2) (atom c)))))
      (select-in-order! c a b2)
      (test-user:press! "C-x 0")
      (check-equal? "c" (selected)))))

(test "a zoomed view that leaves ends the zoom"
  (let* ([a (begin! "a")] [b (begin (test-user:press! "C-x 3") (made-beside a "b"))])
    (prompt!)
    (test-user:press! "C-x 1")
    (check-equal? "a" (who (layout:zoomed-view)))
    (test-user:press! "C-x 0")
    (check-equal? '("b" #f) (list (selected) (layout:zoomed-view)))))

(test "killing a buffer deletes no view, and the selection stays"
  (let* ([a (begin! "a")] [b (begin (test-user:press! "C-x 3") (made-beside a "b"))])
    (check (layout-test/focus:in-client (lambda () (buffers:kill! (views:buffer a)))))
    (check-equal? '("a" 3) (list (selected) (length (layout:views))))))

(test "C-x 4 0 deletes the view after killing its buffer, and the successor is the level's view selected most recently"
  (let ([a (view-named "a")] [b (view-named "b")] [c (view-named "c")])
    (reset! (layout-split:container '((direction . row)) (layout-split:container '((direction . column)) (atom a) (atom c)) (atom b)))
    (select-in-order! c a)
    (prompt!)
    (test-user:press! "C-x 4 0")
    (check-equal? "c" (selected)))
  (let* ([a (begin! "a")] [b (begin (test-user:press! "C-x 3") (made-beside a "b"))])
    (prompt!)
    (test-user:press! "C-x 4 0")
    (check-equal? "b" (selected))))

(test "the part mode's x deletes the selected part, and the part beside it is selected"
  (let* ([a (begin! "a")] [b (begin (test-user:press! "C-x 3") (made-beside a "b"))])
    (prompt!)
    (test-user:press! "s-' x RET")
    (check-equal? '("b" ("b" "echo" " *Minibuf*")) (list (selected) (shown)))))

(test "a part placed beside the user's level and used after the new view was made is passed over: the new view took the old one's space"
  (let* ([a (begin! "a")] [explorer (layout-test/focus:explorer!)] [b (begin (test-user:press! "C-x 3") (made-beside a "b"))])
    (click-part! explorer)
    (click-part! a)
    (check-equal? '("a" "explorer") (list-head (layout-test/focus:order) 2))
    (test-user:press! "C-x 0")
    (check-equal? "b" (selected))))

(test "a view beside a nested level stays outside the choice for a view in it"
  (let ([outline (view-named "outline")] [pi (view-named "pi")])
    (reset! (layout-split:container '((direction . row) (title . "chat")) (atom outline '(size columns 24)) (layout:level '() (atom pi))))
    (layout:select! pi)
    (test-user:press! "C-x 3")
    (made-beside pi "pi2")
    (click-part! outline)
    (click-part! pi)
    (test-user:press! "C-x 0")
    (check-equal? "pi2" (selected))))

(test "a tabs container keeps the tab that showed the view that left while the tab holds a view to give"
  (let ([a (view-named "a")] [b (view-named "b")] [c (view-named "c")])
    (reset! (layout-tabs:container '() (layout-split:container '((direction . row)) (atom a) (atom b)) (atom c)))
    (select-in-order! b c a)
    (test-user:press! "C-x 0")
    (check-equal? '("b" ("b" "echo")) (list (selected) (shown)))))

(test "tabs inside tabs: the inner tabs keep the tab that held the view, though the outer tabs hold nothing but the inner ones"
  (let ([x (view-named "x")] [a (view-named "a")] [b (view-named "b")])
    (reset! (layout-tabs:container '() (layout-tabs:container '() (atom x) (layout-split:container '((direction . row)) (atom a) (atom b)))))
    (select-in-order! x b a)
    (test-user:press! "C-x 0")
    (check-equal? '("b" ("b" "echo")) (list (selected) (shown))))
  (let ([c2 (view-named "c2")] [x (view-named "x")] [a (view-named "a2")] [b (view-named "b2")])
    (reset! (layout-tabs:container '() (atom c2) (layout-tabs:container '() (atom x) (layout-split:container '((direction . row)) (atom a) (atom b)))))
    (select-in-order! x b a)
    (test-user:press! "C-x 0")
    (check-equal? '("b2" ("b2" "echo")) (list (selected) (shown)))))

(test "a tab is kept only when the tabs had it; tabs holding the tabs that lost a view keep nothing of their own"
  (let ([y (view-named "y")] [z (view-named "z")] [w (view-named "w")])
    (reset! (layout-tabs:container '() (layout-tabs:container '() (layout-tabs:container '() (atom y)) (atom z) (atom w))))
    (select-in-order! w z)
    (test-user:press! "C-x 0")
    (check-equal? '("w" ("w" "echo")) (list (selected) (shown)))))

(test "a tab whose only view goes leaves the views on screen after it to compete: the view beside the tabs, or the tab that comes into view"
  (let ([a (view-named "a")] [c (view-named "c")] [d (view-named "d")])
    (reset! (layout-split:container '((direction . row)) (layout-tabs:container '() (atom a) (atom c)) (atom d)))
    (select-in-order! c d a)
    (test-user:press! "C-x t 0")
    (check-equal? "d" (selected))
    (let ([a2 (view-named "a2")])
      (reset! (layout-split:container '((direction . row)) (layout-tabs:container '() (atom a2) (atom c)) (atom d)))
      (select-in-order! d c a2)
      (test-user:press! "C-x t 0")
      (check-equal? "c" (selected)))))

(test "C-x t 0 after a prompt selects the remaining tab's view"
  (let* ([a (begin! "a")])
    (test-user:press! "C-x t 2")
    (made-beside a "a2")
    (check-equal? "a2" (selected))
    (prompt!)
    (test-user:press! "C-x t 0")
    (check-equal? "a" (selected))))

(test "a collapse that dissolves a nested level leaves the level it was in"
  (let ([x (view-named "x")] [a (view-named "a")] [m (view-named "m")])
    (reset! (layout-split:container '((direction . row)) (atom x) (layout:level '() (layout-split:container '((direction . column)) (atom a) (layout:level '() (atom m))))))
    (select-in-order! m x a)
    (test-user:press! "C-x 0")
    (check-equal? "m" (selected))))

(test "deselect! of the selected view the user works in selects its successor and records no use; of a view not selected, nothing"
  (let* ([a (begin! "a")] [b (begin (test-user:press! "C-x 3") (made-beside a "b"))] [before (layout-test/focus:front 3)])
    (layout:deselect! a)
    (check-equal? "b" (selected))
    (check-equal? before (layout-test/focus:front 3))
    (layout:deselect! a)
    (check-equal? "b" (selected))))
