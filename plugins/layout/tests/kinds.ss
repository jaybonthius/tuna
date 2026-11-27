(import (tuna) (test) (layout) (layout-split) (views) (buffers) (haml)
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
      (check-raises (layout-test/parts:raised-with 'layout:define-container message) (load-module! (list 'layout-test module))))
    '(kind-draw-symbol kind-keymap-number kind-adopt-symbol)
    '("not a procedure" "not a keymap or #f" "not a procedure or #f")))

(test "a container's kind carries its keymap, and a level's none"
  (check-equal? #f (buffers:kind-keymap (buffers:constructor-kind layout:level)))
  (check (eq? layout-test/boxes:box-keys (buffers:kind-keymap (buffers:constructor-kind layout-test/boxes:box)))))

(define (draw-column node children focused draw-child client) (haml (:div.column (map draw-child children))))

(layout:define-container column (draw draw-column) (child-attributes share) (collapse))

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
