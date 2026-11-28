(import (tuna) (test) (test-user) (layout) (layout-split) (views) (buffers) (commands) (tables) (web)
        (layout-split-test parts))

(define atom layout-split-test/parts:atom)
(define named layout-split-test/parts:named)
(define outline layout-split-test/parts:outline)
(define attributes-of layout-split-test/parts:attributes-of)
(define raised-with layout-split-test/parts:raised-with)
(define set-parts! layout-split-test/parts:set-parts!)

(define (fresh name) (views:make (named name)))

(define (weights . vs) (map (lambda (v) (let ([w (assq 'weight (attributes-of v))]) (and w (cdr w)))) vs))

(define (place-echo! b)
  (layout:display-buffer b (layout-split:display-at-side (layout:direction down) 90 'content '((locked . #t)))))

(test "C-x 2 and C-x 3 split the selected view with a view of its buffer at its point, and the selected view stays selected"
  (let ([a (views:make (buffers:make (buffers:free-name "notes") "one\ntwo\n"))])
    (set-parts! (atom a))
    (layout:select! a)
    (views:set-point! a 5)
    (test-user:press! "C-x 2")
    (let ([below (cadr (layout:views))])
      (check-equal? (list 'layout:level (list 'column (layout-split-test/parts:name-of a) (layout-split-test/parts:name-of a))) (outline))
      (check (eq? a (layout:selected-view)))
      (check-equal? 5 (views:point below))
      (test-user:press! "C-x 3")
      (let ([right (cadr (layout:views))])
        (check-equal? (list 'layout:level (list 'column (list 'row (layout-split-test/parts:name-of a) (layout-split-test/parts:name-of a))
                                                (layout-split-test/parts:name-of a)))
                      (outline))
        (check (eq? a (layout:selected-view)))
        (check-equal? 5 (views:point right))))))

(test "split-view! joins a split of its direction, halving the view's weight, or wraps the view in a new one; it takes a buffer, and checks its arguments"
  (let ([a (fresh "a")] [b (fresh "b")])
    (set-parts! (layout-split:container '((direction . row)) (atom a) (atom b)))
    (layout:select! a)
    (let ([new (layout-split:split-view! a (layout-split:direction row))])
      (check-equal? '(layout:level (row "a" "a" "b")) (outline))
      (check-equal? '(1/2 1/2 #f) (weights a new b))
      (check-equal? '() (views:previous-buffers new)))
    (let ([other (layout-split:split-view! b (layout-split:direction column) (named "other"))])
      (check-equal? '(layout:level (row "a" "a" (column "b" "other"))) (outline))
      (check-equal? '() (views:previous-buffers other)))
    (check (eq? a (layout:selected-view)))
    (check-raises (raised-with 'layout-split:split-view! "not a split direction") (layout-split:split-view! a 'diagonal))
    (check-raises (raised-with 'layout-split:split-view! "not a view") (layout-split:split-view! 'view (layout-split:direction row)))
    (check-equal? '(row column) (enum-set->list (layout-split:directions column row)))))

(test "moving goes left and right in a row and up and down in a column, else asks the split's parent"
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")])
    (set-parts! (layout-split:container '((direction . column)) (layout-split:container '((direction . row)) (atom a) (atom b)) (atom c)))
    (let ([moves (lambda (v) (map (lambda (d) (let ([n (layout:neighbour v d)]) (and n (layout-split-test/parts:name-of n))))
                                  (list (layout:direction left) (layout:direction right) (layout:direction up) (layout:direction down))))])
      (check-equal? '(#f "b" #f "c") (moves a))
      (check-equal? '("a" #f #f "c") (moves b))
      (check-equal? '(#f #f "a" #f) (moves c)))))

(define (three-in-a-row!)
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")] [d (fresh "d")])
    (set-parts! (layout-split:container '((direction . column))
                  (layout-split:container '((direction . row)) (atom a '(weight . 1/2)) (atom b '(weight . 1/2)) (atom c))
                  (atom d)))
    (layout:select! a)
    (values a b c d)))

(test "enlarging adds tenths of the split's total weight, taken evenly from the siblings, and shrinking takes them; too much raises"
  (let-values ([(a b c d) (three-in-a-row!)])
    (test-user:press! "C-x }")
    (check-equal? '(7/10 2/5 9/10) (weights a b c))
    (commands:run layout-split:enlarge 3)
    (check-equal? '(13/10 1/10 3/5) (weights a b c))
    (commands:run layout-split:shrink 2)
    (check-equal? '(9/10 3/10 4/5) (weights a b c))
    (check-raises (raised-with 'layout-split:enlarge "the split cannot change that much") (layout-split:enlarge 20))
    (check-raises (raised-with 'layout-split:enlarge "not an exact integer") (layout-split:enlarge 'x))
    (check-raises (raised-with 'layout-split:shrink "not an exact integer") (layout-split:shrink 1.5))
    (check-equal? '(9/10 3/10 4/5) (weights a b c))))

(test "in a column, enlarging and shrinking change the view's share of its column, and C-u counts four"
  (let-values ([(a b c d) (three-in-a-row!)])
    (layout:select! d)
    (commands:run layout-split:enlarge 1)
    (let ([row-weight (lambda () (cdr (assq 'weight (cadr (caddr (caddr (layout-split-test/parts:tree)))))))])
      (check-equal? '(4/5 6/5) (list (row-weight) (car (weights d))))
      (test-user:press! "C-u C-x {")
      (check-equal? '(8/5 2/5) (list (row-weight) (car (weights d)))))))

(test "the resize keys are a repeating keymap, but without the repeat plugin } after C-x } is only another key"
  (let-values ([(a b c d) (three-in-a-row!)])
    (check (tables:ref keys:repeat-keymaps layout-split:resize-keymap #f))
    (test-user:press! "C-x }")
    (let ([after (weights a b c)])
      (check-equal? 1 (length (layout-split-test/parts:refusals-during (lambda () (test-user:press! "}")))))
      (check-equal? after (weights a b c)))))

(test "balancing sets every weight in the selected view's level to 1, zoomed or not"
  (let-values ([(a b c d) (three-in-a-row!)])
    (commands:run layout-split:enlarge 2)
    (commands:run layout:zoom)
    (test-user:press! "C-x +")
    (commands:run layout:zoom)
    (check-equal? '(1 1 1 1) (map (lambda (w) (or w 1)) (weights a b c d)))))

(test "deleting a view leaves its split one child, which takes the split's place and the split's own place in its parent"
  (let-values ([(a b c d) (three-in-a-row!)])
    (layout:select! d)
    (commands:run layout-split:enlarge 1)
    (layout:select! a)
    (let ([row-weight (cdr (assq 'weight (cadr (caddr (caddr (layout-split-test/parts:tree))))))])
      (layout:delete-part! (layout:view-node b))
      (layout:delete-part! (layout:view-node c))
      (check-equal? '(layout:level (column "a" "d")) (outline))
      (check-equal? (list row-weight) (weights a))
      (check (eq? a (layout:selected-view))))))

(test "a locked view is not split, a view in no split cannot be resized, and the display actions decline in a locked view"
  (let ([a (fresh "a")])
    (set-parts! (atom a))
    (layout:select! a)
    (let ([echo (place-echo! (named "*Echo*"))])
      (check-raises (raised-with 'layout-split:split-view! "a locked view") (layout-split:split-view! echo (layout-split:direction row)))
      (check-raises (raised-with 'layout-split:enlarge "the selected view is in no split") (layout-split:enlarge 1))
      (layout:select! echo)
      (check (eq? a (layout-split:display-below (views:buffer a))))
      (check-equal? #f (layout-split:display-right (named "new")))
      (check-equal? #f (layout-split:display-below (named "newer")))
      (layout:select! a)
      (let ([v (layout-split:display-right (named "newest"))])
        (check-equal? '(layout:level (column (layout:level (row "a" "newest")) "*Echo*")) (outline))
        (check (eq? a (layout:selected-view)))
        (check (eq? v (layout-split:display-below (named "newest"))))))))

(test "balancing leaves a locked split and its children, sized children and the levels inside the level as they are, and nothing outside it"
  (let ([vs (map fresh '("v1" "v7" "v8" "v9" "v10" "v11" "echo"))])
    (define (v name) (find (lambda (w) (string=? name (layout-split-test/parts:name-of w))) vs))
    (set-parts! (layout-split:container '((direction . column) (weight . 1/2))
                  (layout:level '()
                    (layout-split:container '((direction . row))
                      (atom (v "v1") '(weight . 2))
                      (layout-split:container '((direction . column) (weight . 3) (locked . #t)) (atom (v "v7") '(weight . 2)) (atom (v "v8")))
                      (atom (v "v9") '(weight . 2) '(size . 1/4))
                      (layout:level '((weight . 5)) (layout-split:container '((direction . column)) (atom (v "v10") '(weight . 3)) (atom (v "v11"))))))
                  (atom (v "echo") '(depth . 90) '(size . content) '(locked . #t) '(weight . 3))))
    (layout:select! (v "v1"))
    (commands:run layout-split:balance)
    (check-equal? '(1 2 #f 2 3 #f 3) (apply weights vs))
    (let ([inner-level (let find-level ([d (caddr (caddr (layout-split-test/parts:tree)))])
                         (cond
                           [(vector? d) #f]
                           [(and (eq? (car d) 'layout:level) (pair? (cadr d))) d]
                           [else (exists find-level (cddr d))]))])
      (check-equal? '((weight . 1)) (cadr inner-level)))
    (check-equal? '((direction . column) (weight . 1/2)) (cadr (caddr (layout-split-test/parts:tree))))))

(define (flexes)
  (test-user:settle)
  (map (lambda (e) (test-user:element-attribute e "style")) (test-user:elements (test-user:screen) "split-child")))

(test "a child's size along its split takes the place of its weight: a fraction, columns, lines or its content's size; across the split it means nothing"
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")] [d (fresh "d")] [e (fresh "e")])
    (set-parts! (layout-split:container '((direction . row))
                  (atom a '(size columns 30))
                  (atom b '(size lines 5) '(weight . 2))
                  (atom c '(size . 1/4))
                  (layout-split:container '((direction . column)) (atom d '(size lines 5)) (atom e '(size . content)))))
    (check-equal? '("--layout-split-flex:0 0 30ch" "--layout-split-flex:2.0 1 0" "--layout-split-flex:0 0 25.0%"
                    "--layout-split-flex:1.0 1 0" "--layout-split-flex:0 0 5lh" "--layout-split-flex:none")
                  (flexes))
    (layout-split:split-view! a (layout-split:direction column))
    (check-equal? '((direction . column) (size columns 30)) (cadr (caddr (caddr (layout-split-test/parts:tree)))))
    (check-equal? '(() ()) (map attributes-of (list-head (layout:views) 2)))))

(define v-names '("t1" "t7" "t8" "t9" "t10" "t12"))

(define (transposable!)
  (let ([vs (map fresh v-names)])
    (define (v k) (list-ref vs k))
    (set-parts! (layout-split:container '((direction . row))
                  (layout-split:container '((size columns 30) (direction . column)) (atom (v 0) '(weight . 2)) (atom (v 1) '(size lines 5)))
                  (layout-split:container '((direction . column) (locked . #t)) (atom (v 2)) (atom (v 3)))
                  (layout:level '() (layout-split:container '((direction . row)) (atom (v 4)) (atom (v 5))))))
    (layout:select! (v 0))
    (v 0)))

(test "C-x w t turns each split in the selected view's level between side by side and stacked, keeping weights and sizes, locked parts and the levels inside"
  (let* ([first (transposable!)] [before (layout-split-test/parts:tree)])
    (test-user:press! "C-x w t")
    (check-equal? '(layout:level (column (row "t1" "t7") (column "t8" "t9") (layout:level (row "t10" "t12")))) (outline))
    (check-equal? '((size columns 30) (direction . row)) (cadr (caddr (caddr (layout-split-test/parts:tree)))))
    (check (eq? first (layout:selected-view)))
    (layout-split:transpose)
    (check-equal? before (layout-split-test/parts:tree))))

(commands:define-command (nothing) "Does nothing." (void))

(test "transposing is a step of the window history"
  (transposable!)
  (commands:run nothing)
  (let ([before (layout-split-test/parts:tree)])
    (test-user:press! "C-x w t")
    (test-user:press! "C-c <left>")
    (check-equal? before (layout-split-test/parts:tree))))

(test "a level with no split to transpose raises; a split holding a placed part keeps its direction; from a placed part nothing turns"
  (let ([a (fresh "a")])
    (set-parts! (atom a))
    (layout:select! a)
    (check-raises (raised-with 'layout-split:transpose "no split to transpose in the selected view's level") (layout-split:transpose))
    (set-parts! (layout-split:container '((direction . row))
                  (layout-split:container '() (atom a) (atom (fresh "b")))
                  (atom (fresh "placed") '(depth . 50))))
    (layout:select! a)
    (layout-split:transpose)
    (check-equal? '(layout:level (row (column "a" "b") "placed")) (outline))
    (set-parts! (atom a))
    (let* ([echo (place-echo! (named " *Echo Area*"))]
           [explorer ((layout-split:display-at-side (layout:direction left) 50 '(columns 30)) (named "*explorer*"))]
           [placed (layout-split-test/parts:tree)])
      (for-each
        (lambda (v)
          (layout:select! v)
          (check-raises (raised-with 'layout-split:transpose "no split to transpose in the selected view's level") (layout-split:transpose))
          (check-equal? placed (layout-split-test/parts:tree)))
        (list explorer echo)))))

(test "w r and w c in the part mode wrap the selected part in a row or a column split"
  (let ([a (fresh "a")] [b (fresh "b")])
    (set-parts! (layout-split:container '((direction . row)) (atom a) (atom b)))
    (layout:select! b)
    (test-user:press! "s-' w r RET")
    (check-equal? '(layout:level (row "a" (row "b"))) (outline))
    (test-user:press! "s-' w c RET")
    (check-equal? '(layout:level (row "a" (row (column "b")))) (outline))))

(test "the kind's stylesheet is in web's table of stylesheets"
  (check-equal? "layout-split/layout-split.css" (tables:ref web:stylesheets 'layout-split #f)))

(test "a view that shows no buffer is split only to show a buffer given"
  (let ([e (fresh "empty")])
    (set-parts! (atom e))
    (layout:select! e)
    (for-each buffers:kill! (remp (lambda (b) (buffers:internal-name? (buffers:name b))) (buffers:all)))
    (check-equal? #f (views:buffer e))
    (check-raises (raised-with 'layout-split:split-view! "the view shows no buffer") (layout-split:split-view! e (layout-split:direction row)))
    (let ([new (layout-split:split-view! e (layout-split:direction row) (named "shown"))])
      (check-equal? (list #f "shown") (list (views:buffer e) (buffers:name (views:buffer new)))))))
