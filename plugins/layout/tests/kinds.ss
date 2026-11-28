(import (tuna) (test) (test-runner) (layout) (layout-split) (views) (buffers) (document) (haml)
        (layout-test parts) (layout-test boxes))

(define (syntax-error? message)
  (lambda (c) (and (syntax-violation? c) (string=? message (condition-message c)))))

(test "a container kind needs one draw clause, takes each clause once, and knows its clauses"
  (for-each
    (lambda (module message)
      (check-raises (syntax-error? message) (load-module! (list 'layout-test module))))
    '(kind-without-draw kind-draw-twice kind-unknown-clause kind-collapse-argument kind-show-focused-argument
      kind-attribute-string kind-adopt-empty kind-name-list)
    '("a draw clause is required" "clause given twice" "invalid clause" "invalid clause" "invalid clause"
      "invalid clause" "invalid clause" "expected (layout:define-container id clause ...)")))

(test "a kind's draw and adopt must be procedures, and its keymap a keymap or #f"
  (for-each
    (lambda (module message)
      (check-raises (test-runner:raised-with 'layout:define-container message) (load-module! (list 'layout-test module))))
    '(kind-draw-symbol kind-keymap-number kind-adopt-symbol kind-beside-symbol)
    '("not a procedure" "not a keymap or #f" "not a procedure or #f" "not a procedure or #f")))

(test "a container's kind carries its keymap, and a level's none"
  (check-equal? #f (buffers:kind-keymap (buffers:constructor-kind layout:level)))
  (check (eq? layout-test/boxes:box-keys (buffers:kind-keymap (buffers:constructor-kind layout-test/boxes:box)))))

(define (draw-column node children focused draw-child client) (haml (:div.column (map draw-child children))))

(layout:define-container column (draw draw-column) (child-attributes share) (collapse))

(define (datum-of node)
  (car (document:datums (document:slice (buffers:document layout:buffer) (document:node-start node) (document:node-end node)))))

(define (pile-beside node child part direction)
  (and (eq? direction (layout:direction down)) (list (datum-of child) part)))

(layout:define-container pile (draw draw-column) (child-attributes share) (beside pile-beside))

(define (stray-beside node child part direction) 'nothing)

(layout:define-container stray (draw draw-column) (beside stray-beside))

(define (empty-beside node child part direction) '())

(layout:define-container hollow (draw draw-column) (beside empty-beside))

(define (row parts) (apply layout-split:container '((direction . row)) parts))

(test "add-beside! walks out from the view to its level, asking each container's beside clause about the child holding the view; the first to give parts places the part"
  (let* ([notes (buffers:make (buffers:free-name "notes") "one\n")]
         [a (views:make notes)] [b (views:make notes)] [c (views:make notes)]
         [atom layout-test/parts:atom] [new (atom (views:make notes))])
    (layout-test/parts:set-parts! (pile '() (layout-split:container '((direction . row)) (atom a) (atom b)) (atom c)))
    (layout:add-beside! a new (layout:direction down) row)
    (check-equal? (list 'layout:level '() (pile '() (layout-split:container '((direction . row)) (atom a) (atom b)) new (atom c)))
                  (layout-test/parts:tree))))

(test "when every container declines, add-beside! wraps the view and the part in the container make gives, which takes the view's place in its parent"
  (let* ([notes (buffers:make (buffers:free-name "notes") "one\n")]
         [c (views:make notes)] [d (views:make notes)] [atom layout-test/parts:atom] [new (atom (views:make notes))])
    (layout-test/parts:set-parts! (pile '() (atom c '(share . 2) '(title . "c")) (atom d)))
    (layout:add-beside! c new (layout:direction left) row)
    (check-equal? (list 'layout:level '()
                        (pile '() (layout-split:container '((direction . row) (share . 2)) new (atom c '(title . "c"))) (atom d)))
                  (layout-test/parts:tree))))

(test "add-beside! checks its arguments and what a beside clause and make return"
  (let* ([notes (buffers:make (buffers:free-name "notes") "one\n")]
         [d (views:make notes)] [atom layout-test/parts:atom] [new (lambda () (atom (views:make notes)))])
    (layout-test/parts:set-parts! (stray '() (atom d)))
    (check-raises (test-runner:raised-with 'layout:define-container "a beside clause returned what is not a list of one or more parts or #f")
                  (layout:add-beside! d (new) (layout:direction down) row))
    (layout-test/parts:set-parts! (hollow '() (atom d) (atom (views:make notes))))
    (check-raises (test-runner:raised-with 'layout:define-container "a beside clause returned what is not a list of one or more parts or #f")
                  (layout:add-beside! d (new) (layout:direction down) row))
    (layout-test/parts:set-parts! (pile '() (atom d)))
    (check-raises (test-runner:raised-with 'layout:add-beside! "not the datum of a container")
                  (layout:add-beside! d (new) (layout:direction right) (lambda (parts) 'nothing)))
    (check-raises (test-runner:raised-with 'layout:add-beside! "not a direction") (layout:add-beside! d (new) 'across row))
    (check-raises (test-runner:raised-with 'layout:add-beside! "not a part") (layout:add-beside! d 'part (layout:direction down) row))
    (check-raises (test-runner:raised-with 'layout:add-beside! "not a procedure") (layout:add-beside! d (new) (layout:direction down) 'row))
    (check-raises (test-runner:raised-with 'layout:add-beside! "not a view in the layout")
                  (layout:add-beside! (views:make notes) (new) (layout:direction down) row))
    (layout-test/parts:set-parts! (pile '() (atom d '(locked . #t))))
    (check-raises (test-runner:raised-with 'layout:add-beside! "a locked view") (layout:add-beside! d (new) (layout:direction down) row))))

(test "a collapsing kind left one child is replaced by it, and the child loses the kind's child attributes"
  (let* ([notes (buffers:make (buffers:free-name "notes") "one\n")]
         [a (views:make notes)] [b (views:make notes)] [c (views:make notes)])
    (layout-test/parts:set-parts!
      (layout-split:container '((direction . row))
        (column '((weight . 3) (title . "c")) (layout-test/parts:atom a '(share . 1) '(weight . 7)) (layout-test/parts:atom b))
        (layout-test/parts:atom c)))
    (layout:delete-part! (layout:view-node b))
    (check-equal? (list 'layout:level (list 'layout-split:container (buffers:name notes) (buffers:name notes)))
                  (layout-test/parts:outline))
    (check-equal? '((weight . 3)) (cddr (layout-test/parts:attributes-of a)))))
