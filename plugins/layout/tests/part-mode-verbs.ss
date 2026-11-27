(import (tuna) (test) (test-user) (layout) (layout-split) (layout-tabs) (layout-scroll) (layout-float)
        (views) (buffers) (document) (haml)
        (layout-test parts))

(define atom layout-test/parts:atom)
(define part layout-test/parts:part)
(define outline layout-test/parts:outline)
(define outline-of layout-test/parts:outline-of)
(define selected layout-test/parts:selected-name)

(define (row . parts) (apply layout-split:container '((direction . row)) parts))
(define (column . parts) (apply layout-split:container '((direction . column)) parts))

;; Made afresh for each case, since a view whose atom leaves the layout
;; is dropped.
(define views-by-name '())

(define (v n . attributes)
  (let ([name (string-append "n" (number->string n))])
    (apply atom (cdr (assoc name views-by-name)) attributes)))

(define (start! selected-n part)
  (layout:part-mode-leave)
  (set! views-by-name
    (map (lambda (n)
           (let ([name (string-append "n" (number->string n))])
             (cons name (views:make (or (buffers:find name) (buffers:make name ""))))))
         '(3 4 5 6 7 8)))
  (layout-test/parts:set-parts! (part))
  (layout:select! (cdr (assoc (string-append "n" (number->string selected-n)) views-by-name)))
  (test-user:press! "s-'"))

(define (main) (cadr (outline)))
(define (main-datum) (caddr (layout-test/parts:tree)))

(define (refusal thunk) (layout-test/parts:refusals-during thunk))

(test "J and L swap the selected part with the part before or after it, with its place attributes; from an end, nothing changes"
  (start! 4 (lambda () (row (v 3 '(weight . 2)) (v 4 '(weight . 3)) (v 5))))
  (test-user:press! "L")
  (check-equal? '(layout-split:container "n3" "n5" "n4") (main))
  (check-equal? '(((weight . 2)) () ((weight . 3))) (map (lambda (d) (cddr (vector-ref d 1))) (cddr (main-datum))))
  (check-equal? '("n4" "n4") (list (part) (selected)))
  (test-user:press! "L")
  (check-equal? '(layout-split:container "n3" "n5" "n4") (main))
  (test-user:press! "S-<left> S-<left>")
  (check-equal? '(layout-split:container "n4" "n3" "n5") (main))
  (test-user:press! "J")
  (check-equal? '(layout-split:container "n4" "n3" "n5") (main)))

(test "a locked part moves, and others move past it, but a part inside a locked part does not"
  (start! 4 (lambda () (row (v 3) (v 4) (v 5 '(locked . #t)))))
  (test-user:press! "L")
  (check-equal? '(layout-split:container "n3" "n5" "n4") (main))
  (test-user:press! "j J")
  (check-equal? '((layout-split:container "n5" "n3" "n4") "n5" "n4") (list (main) (part) (selected)))
  (start! 4 (lambda () (row (v 3) (layout-split:container '((direction . column) (locked . #t)) (v 4) (v 5)))))
  (check-equal? '((layout:shift-forward "a locked part")) (refusal (lambda () (test-user:press! "k L"))))
  (check-equal? '(layout-split:container "n3" (layout-split:container "n4" "n5")) (main)))

(define (strip-placement)
  (test-user:settle)
  (test-user:element-attribute (car (test-user:elements (test-user:screen) "layout-strip")) "data-placement"))

(test "moving the focused column along a strip places the strip again, so it scrolls to the column's new place"
  (start! 4 (lambda () (layout-scroll:container '() (v 3) (v 4) (v 5))))
  (let ([placed (strip-placement)])
    (test-user:press! "L")
    (check-equal? '(layout-scroll:container "n3" "n5" "n4") (main))
    (check (not (equal? placed (strip-placement))))))

(test "I lifts the part out of its container, before it from its first place and after it from any other; a split left one child collapses"
  (start! 5 (lambda () (row (v 3) (column (v 4) (v 5 '(weight . 5)) (v 6)))))
  (test-user:press! "I")
  (check-equal? '(layout-split:container "n3" (layout-split:container "n4" "n6") "n5") (main))
  (check-equal? '((weight . 5)) (cddr (vector-ref (car (last-pair (main-datum))) 1)))
  (check-equal? '("n5" "n5") (list (part) (selected)))
  (start! 4 (lambda () (row (v 3) (column (v 4) (v 5 '(weight . 2))))))
  (test-user:press! "I")
  (check-equal? '(layout-split:container "n3" "n4" "n5") (main))
  (check-equal? '(() () ()) (map (lambda (d) (cddr (vector-ref d 1))) (cddr (main-datum)))))

(test "a container that does not collapse keeps one child; one left empty goes, and the part takes its place; nothing lifts out of the root's part"
  (start! 4 (lambda () (row (v 3) (layout-tabs:container '((weight . 2)) (v 4) (v 5)))))
  (test-user:press! "I")
  (check-equal? '(layout-split:container "n3" "n4" (layout-tabs:container "n5")) (main))
  (start! 4 (lambda () (row (v 3) (layout-tabs:container '((weight . 2)) (v 4)))))
  (test-user:press! "I")
  (check-equal? '(layout-split:container "n3" "n4") (main))
  (check-equal? '((weight . 2)) (cddr (vector-ref (car (last-pair (main-datum))) 1)))
  (test-user:press! "I")
  (check-equal? '(layout-split:container "n3" "n4") (main)))

(test "K moves the part into the nearest container after it, as its first child, else before it, as its last, taking that kind's place attributes"
  (start! 3 (lambda () (row (v 3 '(weight . 2)) (v 4) (layout-scroll:container '() (v 5 '(size . 1/3))))))
  (test-user:press! "K")
  (check-equal? (row (v 4) (layout-scroll:container '() (v 3 '(size . 1/2)) (v 5 '(size . 1/3)))) (main-datum))
  (check-equal? '("n3" "n3") (list (part) (selected)))
  (start! 6 (lambda () (row (layout-float:container '() (v 3)) (v 4) (v 6))))
  (test-user:press! "K")
  (check-equal? (row (layout-float:container '() (v 3) (v 6 '(place box 1/2 1/2))) (v 4)) (main-datum)))

(test "a split left one child by K collapses, and with no container among its siblings nothing moves"
  (start! 4 (lambda () (row (v 4) (column (v 5) (v 6)))))
  (test-user:press! "K")
  (check-equal? '(layout-split:container "n4" "n5" "n6") (main))
  (check-equal? 'column (cdr (assq 'direction (cadr (main-datum)))))
  (start! 4 (lambda () (row (v 4) (column (v 5) (v 6)))))
  (test-user:press! "l k K")
  (check-equal? '(layout-split:container "n4" (layout-split:container "n5" "n6")) (main)))

(test "r raises the part over its siblings, deleting them; it refuses over a locked part or a container holding one"
  (start! 5 (lambda () (row (v 3) (layout-tabs:container '((weight . 3)) (v 4) (v 5 '(title . "three"))))))
  (test-user:press! "r")
  (check-equal? (row (v 3) (v 5 '(title . "three") '(weight . 3))) (main-datum))
  (start! 4 (lambda () (row (v 3 '(locked . #t)) (v 4))))
  (check-equal? '((layout:raise "a locked part")) (refusal (lambda () (test-user:press! "r"))))
  (start! 3 (lambda () (row (v 3) (column (v 4) (v 5 '(locked . #t))))))
  (check-equal? '((layout:raise "a locked part")) (refusal (lambda () (test-user:press! "r"))))
  (start! 4 (lambda () (row (v 3) (column (v 4) (layout-tabs:container '() (v 5 '(locked . #t)))) (v 6))))
  (check-equal? '((layout:delete-view "a locked part")) (refusal (lambda () (test-user:press! "i x"))))
  (check-equal? '(layout-split:container "n3" (layout-split:container "n4" (layout-tabs:container "n5")) "n6") (main))
  (start! 4 (lambda () (row (v 3) (v 4))))
  (test-user:press! "r")
  (check-equal? "n4" (main)))

(test "- replaces a container with its children, which share its numeric place attributes; the root's part only when one part takes its place"
  (start! 4 (lambda () (layout-scroll:container '() (v 3 '(size . 1/2)) (layout-split:container '((direction . column) (size . 1/2)) (v 4) (v 5 '(weight . 4))))))
  (test-user:press! "i -")
  (check-equal? (layout-scroll:container '() (v 3 '(size . 1/2)) (v 4 '(size . 1/4)) (v 5 '(size . 1/4))) (main-datum))
  (check-equal? "n4" (part))
  (start! 3 (lambda () (row (v 3) (v 4))))
  (test-user:press! "i -")
  (check-equal? '(layout-split:container "n3" "n4") (main))
  (start! 3 (lambda () (layout-tabs:container '() (v 3))))
  (test-user:press! "i -")
  (check-equal? "n3" (main)))

(test "x deletes the selected part, then selects the part before it, else the one after; it never empties a level"
  (start! 4 (lambda () (row (v 3) (column (v 4) (v 5)) (v 6))))
  (test-user:press! "i x")
  (check-equal? '((layout-split:container "n3" "n6") "n3" "n3") (list (main) (part) (selected)))
  (start! 3 (lambda () (row (v 3))))
  (check-equal? '((layout:delete-part! "the last view of its level")) (refusal (lambda () (test-user:press! "x")))))

(test "w and a kind's letter wrap the selected part in a container of that kind, which takes the part's place attributes"
  (start! 4 (lambda () (row (v 3) (v 4 '(weight . 2)))))
  (test-user:press! "w c")
  (check-equal? (row (v 3) (layout-split:container '((direction . column) (weight . 2)) (v 4))) (main-datum))
  (check-equal? '(layout-split:container "n4") (part))
  (check-raises (layout-test/parts:raised-with 'layout:wrap! "not the datum of a container")
                (layout:wrap! (lambda (parts) (list 'nonsense '() (car parts)))))
  (test-user:press! "w t w s w f w r")
  (check-equal? '(layout-split:container "n3"
                   (layout-split:container (layout-float:container (layout-scroll:container (layout-tabs:container (layout-split:container "n4"))))))
                (main)))

(test "the verbs act on the selected view's atom outside the mode"
  (start! 4 (lambda () (row (v 3) (v 4 '(weight . 2)))))
  (test-user:press! "RET")
  (layout-split:wrap-in-column)
  (check-equal? '(layout-split:container "n3" (layout-split:container "n4")) (main)))

(define (draw-pile node children focused draw-child client) (haml (:div (map draw-child children))))

(define (adopt-pile node d)
  (if (vector? d) (vector (vector-ref d 0) (append (vector-ref d 1) '((share . 1)))) d))

(layout:define-container pile (draw draw-pile) (child-attributes share) (adopt adopt-pile))

(define (adopt-other node d) (v 4))

(layout:define-container stray (draw draw-pile) (adopt adopt-other))

(test "a kind's adopt clause gives a part arriving from another kind its own place attributes, and may not return another part"
  (start! 3 (lambda () (row (v 3 '(weight . 2)) (pile '() (v 4)))))
  (test-user:press! "K")
  (check-equal? (pile '() (v 3 '(share . 1)) (v 4)) (main-datum))
  (start! 3 (lambda () (row (v 3) (stray '() (v 4)))))
  (check-equal? '((layout:define-container "an adopt clause returned another part")) (refusal (lambda () (test-user:press! "K"))))
  (check-equal? (row (v 3) (stray '() (v 4))) (main-datum)))

(test "focus and the selected part follow each other after changes the mode did not make"
  (start! 4 (lambda () (row (v 3) (column (v 4) (v 5)) (v 6))))
  (layout:select! (cdr (assoc "n6" views-by-name)))
  (test-user:settle)
  (check-equal? '("n6" "n6") (list (part) (selected)))
  (test-user:press! "j")
  (layout:select! (cdr (assoc "n5" views-by-name)))
  (test-user:settle)
  (check-equal? '((layout-split:container "n4" "n5") "n5") (list (part) (selected)))
  (layout:delete-part! (layout:selected-part))
  (test-user:settle)
  (check-equal? '((layout-split:container "n3" "n6") "n6" "n6") (list (main) (part) (selected)))
  (start! 4 (lambda () (row (v 3) (column (v 4) (v 5)) (v 6))))
  (test-user:press! "i")
  (let ([n (layout:selected-part)])
    (buffers:replace! layout:buffer (document:node-start n) (document:node-end n) (document:from-datum (v 4) (v 5))))
  (test-user:settle)
  (check-equal? '((layout-split:container "n3" "n4" "n5" "n6") "n4" "n4") (list (main) (part) (selected))))

(test "a container whose views are all locked takes no focus, so it stays selected while focus stays where it was"
  (start! 3 (lambda () (row (v 3) (column (v 4 '(locked . #t)) (v 5 '(locked . #t))))))
  (test-user:press! "l")
  (check-equal? '((layout-split:container "n4" "n5") "n3") (list (part) (selected)))
  (test-user:press! "w r")
  (check-equal? '((layout-split:container "n3" (layout-split:container (layout-split:container "n4" "n5")))
                  (layout-split:container (layout-split:container "n4" "n5")) "n3")
                (list (main) (part) (selected)))
  (test-user:press! "RET"))

(define (level-example! selected-name)
  (layout:part-mode-leave)
  (set! views-by-name
    (map (lambda (name) (cons name (views:make (or (buffers:find name) (buffers:make name "")))))
         '("*explorer*" "notes.org" "*pi*" "*Echo*")))
  (let ([w (lambda (name . attributes) (apply atom (cdr (assoc name views-by-name)) attributes))])
    (layout-test/parts:set-parts!
      (column (row (w "*explorer*" '(depth . 50) '(size columns 30)) (layout:level '() (row (w "notes.org") (w "*pi*"))))
              (w "*Echo*" '(depth . 90) '(size . content) '(locked . #t)))))
  (layout:select! (cdr (assoc selected-name views-by-name))))

(define user-level '(layout:level (layout-split:container "notes.org" "*pi*")))

(test "from notes.org, s-' i i j L RET moves the explorer past the level to the right edge"
  (level-example! "notes.org")
  (test-user:press! "s-' i i")
  (check-equal? (list user-level "notes.org") (list (part) (selected)))
  (test-user:press! "j L RET")
  (check-equal? (list 'layout:level (list 'layout-split:container (list 'layout-split:container user-level "*explorer*") "*Echo*")) (outline))
  (check-equal? "*explorer*" (selected)))

(test "I lifts the explorer before the row it was first in, which collapses, and L moves it below the level"
  (level-example! "*explorer*")
  (test-user:press! "s-' I")
  (check-equal? (list 'layout:level (list 'layout-split:container "*explorer*" user-level "*Echo*")) (outline))
  (test-user:press! "L")
  (check-equal? (list 'layout:level (list 'layout-split:container user-level "*explorer*" "*Echo*")) (outline))
  (test-user:press! "RET"))

(test "I on a view passes through its level, a level holding one part, and puts it beside the level, where it persists"
  (level-example! "*pi*")
  (test-user:press! "s-' I")
  (check-equal? '(layout:level (layout-split:container (layout-split:container "*explorer*" (layout:level "notes.org") "*pi*") "*Echo*"))
                (outline))
  (test-user:press! "RET"))

(test "K moves the explorer into the level's part, wrapping a lone view in a container of the kind of the level's parent"
  (level-example! "*explorer*")
  (test-user:press! "s-' K")
  (check-equal? '(layout:level (layout-split:container (layout:level (layout-split:container "*explorer*" "notes.org" "*pi*")) "*Echo*"))
                (outline))
  (level-example! "*explorer*")
  (layout:delete-part! (layout:view-node (cdr (assoc "*pi*" views-by-name))))
  (layout:select! (cdr (assoc "*explorer*" views-by-name)))
  (test-user:press! "s-' K")
  (check-equal? '(layout:level (layout-split:container (layout:level (layout-split:container "*explorer*" "notes.org")) "*Echo*"))
                (outline))
  (check-equal? '((direction . row)) (cadr (caddr (caddr (main-datum)))))
  (test-user:press! "RET"))

(test "lifting a level's only part leaves the level empty, so the part takes its place; - splices a level, keeping its part"
  (level-example! "notes.org")
  (test-user:press! "s-' i I")
  (check-equal? '(layout:level (layout-split:container (layout-split:container "*explorer*" (layout-split:container "notes.org" "*pi*")) "*Echo*"))
                (outline))
  (level-example! "notes.org")
  (test-user:press! "s-' i i -")
  (check-equal? '(layout:level (layout-split:container (layout-split:container "*explorer*" (layout-split:container "notes.org" "*pi*")) "*Echo*"))
                (outline))
  (test-user:press! "RET"))

(test "w l wraps the selected part in a level; around a level, or a level's part, it changes nothing"
  (level-example! "*pi*")
  (test-user:press! "s-' w l")
  (let ([wrapped '(layout:level (layout-split:container (layout-split:container "*explorer*" (layout:level (layout-split:container "notes.org" (layout:level "*pi*")))) "*Echo*"))])
    (check-equal? wrapped (outline))
    (check-equal? '((layout:level "*pi*") "*pi*") (list (part) (selected)))
    (test-user:press! "w l k w l")
    (check-equal? wrapped (outline)))
  (test-user:press! "RET"))

(test "x deletes a level and what it holds"
  (level-example! "notes.org")
  (test-user:press! "s-' i i x")
  (check-equal? '(layout:level (layout-split:container "*explorer*" "*Echo*")) (outline))
  (check-equal? "*explorer*" (selected))
  (test-user:press! "RET"))

(test "a locked part is selected and moved without taking focus, and is never deleted or raised over by the user's commands"
  (level-example! "notes.org")
  (test-user:press! "s-' i i i $")
  (check-equal? '("*Echo*" "notes.org" #t) (list (part) (selected) (layout:locked? (layout:selected-part))))
  (test-user:press! "J")
  (let ([moved (list 'layout:level (list 'layout-split:container "*Echo*" (list 'layout-split:container "*explorer*" user-level)))])
    (check-equal? moved (outline))
    (check-equal? "notes.org" (selected))
    (check-equal? '((layout:delete-view "a locked part")) (refusal (lambda () (test-user:press! "x"))))
    (check-equal? '((layout:raise "a locked part")) (refusal (lambda () (test-user:press! "l r"))))
    (check-equal? moved (outline)))
  (test-user:press! "RET"))
