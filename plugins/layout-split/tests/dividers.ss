(import (tuna) (test) (test-runner) (test-user) (layout) (layout-split) (views) (buffers) (document) (keys) (commands) (options)
        (layout-split-test parts))

(define atom layout-split-test/parts:atom)
(define named layout-split-test/parts:named)
(define set-parts! layout-split-test/parts:set-parts!)
(define attributes-of layout-split-test/parts:attributes-of)
(define tree layout-split-test/parts:tree)

(define (fresh name) (views:make (named name)))

(define questions '())
(define reply (lambda (question) 'null))

(define page
  (test-user:open-client
    (lambda (name value)
      (if (equal? name "layout-split-drag")
          (begin (set! questions (cons value questions)) (reply value))
          'null))))

(define (change index old new) (list (cons "index" index) (cons "old" old) (cons "new" new)))

(define (answering . changes) (lambda (question) (list->vector changes)))

(define (part-of v) (if (views:view? v) (layout:view-node v) v))

(define (dividers) (test-user:elements (test-user:screen page) "split-divider"))

;; A divider carries the marks of the part after it.
(define (divider-before v)
  (test-user:settle)
  (let ([at (number->string (document:node-start (part-of v)))])
    (find (lambda (e) (equal? at (test-user:element-attribute e "data-at"))) (dividers))))

(define (state-of e)
  (let* ([mark (test-user:element-attribute e "data-keymap")] [space (let loop ([i 0]) (if (char=? #\space (string-ref mark i)) i (loop (+ i 1))))])
    (substring mark (+ space 1) (string-length mark))))

;; A page answers lengths only for a pointer moved past a few pixels, so
;; the release is a drag's.
(define (drag-divider! e) (test-user:drag-cells! page e 0 0 1 0 "<drag-mouse-1>"))

(define (drag! v . changes)
  (set! reply (apply answering changes))
  (set! questions '())
  (test-runner:shown-reports-during (lambda () (drag-divider! (divider-before v)))))

(define (refusals-during thunk) (map (lambda (r) (list (car r) (cadr r))) (test-runner:shown-reports-during thunk)))

(define (restores) (filter (lambda (call) (equal? (car call) "layout-drag-restore")) (test-user:take-page-calls! page)))

(define (row . parts) (apply layout-split:container '((direction . row)) parts))

(define (column . parts) (apply layout-split:container '((direction . column)) parts))

;; Window history brings a level's parts back with views of its own.
(define (children-attributes)
  (let ([split (caddr (tree))])
    (map (lambda (d) (remp (lambda (a) (memq (car a) '(view buffer))) (vector-ref d 1))) (cddr split))))

(test "a split of n parts draws n - 1 dividers, one in each part but the last, each marked with the part after it"
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")] [d (fresh "d")])
    (set-parts! (row (atom a) (column (atom b) (atom c)) (atom d)))
    (layout:select! a)
    (test-user:settle)
    (let ([inner (document:enclosing (buffers:document layout:buffer) (document:node-start (layout:view-node b)))])
      (check-equal? (map document:node-start (list inner (layout:view-node c) (layout:view-node d)))
                    (sort < (map (lambda (e) (string->number (test-user:element-attribute e "data-at"))) (dividers))))
      (check-equal? (list (number->string (document:node-end inner)))
                    (map (lambda (e) (test-user:element-attribute e "data-to")) (list (divider-before inner)))))
    (check-equal? '("clickable" "clickable" "clickable") (map state-of (dividers)))
    (check-equal? '("vertical" "horizontal")
                  (map (lambda (v) (test-user:element-attribute (divider-before v) "aria-orientation")) (list d c)))))

(test "a drag between two weighted parts multiplies each weight by its new length over its old, and no other part changes"
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")])
    (set-parts! (row (atom a '(weight . 2)) (atom b) (atom c)))
    (layout:select! a)
    (check-equal? '() (drag! b (change 0 600 700) (change 1 300 200)))
    (check-equal? '(((weight . 7/3)) ((weight . 2/3)) ()) (map attributes-of (list a b c)))
    (check-equal? '((("at" . 0) ("clicks" . 1) ("index" . 1) ("axis" . "row")
                     ("before" . #((("index" . 0) ("minimum" . 10) ("counted" . #f))))
                     ("after" . #((("index" . 1) ("minimum" . 10) ("counted" . #f))))))
                  (map (lambda (q) (cons (cons "at" 0) (cdr q))) questions))
    (check-equal? (document:node-start (layout:view-node b)) (cdr (assoc "at" (car questions))))))

(test "a fraction is multiplied, at most 1, and a weight beside it scales by its own lengths"
  (let ([a (fresh "a")] [b (fresh "b")])
    (set-parts! (row (atom a '(size . 1/2)) (atom b)))
    (layout:select! a)
    (drag! b (change 0 500 600) (change 1 500 400))
    (check-equal? '(((size . 3/5)) ((weight . 4/5))) (map attributes-of (list a b)))
    (drag! b (change 0 600 1200) (change 1 400 10))
    (check-equal? '((size . 1)) (attributes-of a))))

(test "a count of columns along the split is multiplied and rounded, and a size across the split shares by weight"
  (let ([a (fresh "a")] [b (fresh "b")])
    (set-parts! (row (atom a '(size columns 40)) (atom b '(size lines 5))))
    (layout:select! a)
    (check-equal? '(#t #f) (map (lambda (e) (cdr (assoc "counted" e)))
                               (begin (drag! b (change 0 400 440) (change 1 600 560))
                                      (append (vector->list (cdr (assoc "before" (car questions))))
                                              (vector->list (cdr (assoc "after" (car questions))))))))
    (check-equal? '(((size columns 44)) ((size lines 5) (weight . 14/15))) (map attributes-of (list a b)))))

(test "a count of lines in a column split is multiplied as columns are in a row"
  (let ([a (fresh "a")] [b (fresh "b")])
    (set-parts! (column (atom a) (atom b '(size lines 10))))
    (layout:select! a)
    (drag! b (change 0 300 260) (change 1 200 240))
    (check-equal? '(((weight . 13/15)) ((size lines 12))) (map attributes-of (list a b)))))

(test "a part whose old length was 0 keeps its stored value, and its neighbour's scaling frees the space"
  (let ([a (fresh "a")] [b (fresh "b")])
    (set-parts! (row (atom a) (atom b '(size columns 100))))
    (layout:select! a)
    (drag! b (change 0 0 100) (change 1 1000 900))
    (check-equal? '(() ((size columns 90))) (map attributes-of (list a b)))))

(test "beside a locked part or one that fits its content the divider is fixed: inert, and a press asks nothing and selects nothing"
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")])
    (set-parts! (row (atom a) (atom b '(size . content)) (atom c '(locked . #t))))
    (layout:select! a)
    (check-equal? '("inert" "inert") (map state-of (list (divider-before b) (divider-before c))))
    (drag! b (change 0 300 400))
    (drag! c (change 1 300 400))
    (check-equal? '() questions)
    (check (eq? a (layout:selected-view)))
    (check-equal? '(() ((size . content)) ((locked . #t))) (map attributes-of (list a b c)))))

(test "the dividers of a locked split are fixed, and a split locked during the drag refuses what the page answers"
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")])
    (set-parts! (row (atom c) (layout:level '((locked . #t)) (row (atom a) (atom b)))))
    (test-user:settle)
    (check-equal? "inert" (state-of (divider-before b)))
    (set-parts! (row (atom c) (layout:level '() (row (atom a) (atom b)))))
    (layout:select! a)
    (set! reply (lambda (question)
                  (layout:set-part-attribute! (layout:level-of a) 'locked #t)
                  (vector (change 0 500 600) (change 1 500 400))))
    (test-user:take-page-calls! page)
    (check-equal? '((layout-split:mouse-drag-divider "the layout changed during the drag"))
                  (refusals-during (lambda () (drag-divider! (divider-before b)))))
    (check-equal? '(() ()) (map attributes-of (list a b)))
    (check-equal? 1 (length (restores)))))

(test "an answer to a split edited since the question is refused, nothing is stored, and the page puts its lengths back"
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")])
    (set-parts! (row (atom a) (atom b) (atom c)))
    (layout:select! a)
    (set! reply (lambda (question)
                  (layout:set-part-attribute! (layout:view-node c) 'weight 3)
                  (vector (change 0 300 400) (change 1 300 200))))
    (test-user:take-page-calls! page)
    (check-equal? '((layout-split:mouse-drag-divider "the layout changed during the drag"))
                  (refusals-during (lambda () (drag-divider! (divider-before b)))))
    (check-equal? '(() () ((weight . 3))) (map attributes-of (list a b c)))
    (check-equal? 1 (length (restores)))))

(test "an edit beside the split, outside it, does not refuse the answer"
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")])
    (set-parts! (column (row (atom a) (atom b)) (atom c)))
    (layout:select! a)
    (set! reply (lambda (question)
                  (layout:set-part-attribute! (layout:view-node c) 'weight 3)
                  (vector (change 0 300 400) (change 1 300 200))))
    (check-equal? '() (refusals-during (lambda () (drag-divider! (divider-before b)))))
    (check-equal? '(((weight . 4/3)) ((weight . 2/3)) ((weight . 3))) (map attributes-of (list a b c)))))

(test "a malformed answer raises not a drag answer, stores nothing, and the page puts its lengths back"
  (let ([a (fresh "a")] [b (fresh "b")])
    (set-parts! (row (atom a) (atom b)))
    (layout:select! a)
    (test-user:take-page-calls! page)
    (for-each
      (lambda (answer)
        (set! reply (lambda (question) answer))
        (check-equal? '((layout-split:mouse-drag-divider "not a drag answer"))
                      (refusals-during (lambda () (drag-divider! (divider-before b)))))
        (check-equal? '(() ()) (map attributes-of (list a b)))
        (check-equal? 1 (length (restores))))
      (list "parts" (vector "part") (vector (change 0 -1 100)) (vector (change 0 100 -5)) (vector (change 0 100 0))
            (vector (change 2 100 200)) (vector (change 0 100 200) (change 0 100 150)) (vector (list (cons "index" 0)))))))

(test "a page that answers nothing, as one without the page's script, changes nothing"
  (let ([a (fresh "a")] [b (fresh "b")])
    (set-parts! (row (atom a) (atom b)))
    (layout:select! a)
    (set! reply (lambda (question) 'null))
    (check-equal? '() (refusals-during (lambda () (drag-divider! (divider-before b)))))
    (check-equal? '(() ()) (map attributes-of (list a b)))))

(test "a part's minimum is the option's for a part, the sum along a split and the largest across one"
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")])
    (set-parts! (row (atom a) (column (atom b) (atom c))))
    (let ([inner (document:enclosing (buffers:document layout:buffer) (document:node-start (layout:view-node b)))]
          [outer (document:enclosing (buffers:document layout:buffer) (document:node-start (layout:view-node a)))])
      (check-equal? '(10 4 10 8 20 8)
                    (list (layout-split:minimum (layout:view-node a) (layout-split:direction row))
                          (layout-split:minimum (layout:view-node a) (layout-split:direction column))
                          (layout-split:minimum inner (layout-split:direction row))
                          (layout-split:minimum inner (layout-split:direction column))
                          (layout-split:minimum outer (layout-split:direction row))
                          (layout-split:minimum outer (layout-split:direction column))))
      (options:set! layout:min-width 12)
      (check-equal? 24 (layout-split:minimum outer (layout-split:direction row)))
      (options:unset! layout:min-width))
    (check-raises assertion-violation? (layout-split:minimum 'part (layout-split:direction row)))
    (check-raises assertion-violation? (layout-split:minimum (layout:view-node a) 'across))))

(test "scale-size multiplies a fraction, at most 1, and a count, rounded and at least 1, and raises for anything else"
  (check-equal? '(3/5 1 (columns 44) (lines 1) (columns 4))
                (list (layout-split:scale-size 1/2 6/5) (layout-split:scale-size 1/2 3) (layout-split:scale-size '(columns 40) 11/10)
                      (layout-split:scale-size '(lines 3) 1/10) (layout-split:scale-size '(columns 2) 7/4)))
  (check-raises assertion-violation? (layout-split:scale-size 'content 2))
  (check-raises assertion-violation? (layout-split:scale-size 1/2 0))
  (check-raises assertion-violation? (layout-split:scale-size 1/2 1.5)))

(test "stored values are rounded, so repeated drags do not lengthen their denominators"
  (let ([a (fresh "a")] [b (fresh "b")])
    (set-parts! (row (atom a) (atom b)))
    (layout:select! a)
    (drag! b (change 0 694.5 744.53125) (change 1 694.5 644.46875))
    (let ([w (cdr (assq 'weight (attributes-of a)))])
      (check (< (denominator w) 100000))
      (check (< (abs (- w (/ 744.53125 694.5))) 1/10000)))))

(test "a double click on a divider sets every weighted part of its split to weight 1, leaving sized and locked parts, in one edit"
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")] [d (fresh "d")])
    (set-parts! (row (atom a '(weight . 2)) (atom b '(weight . 1/3)) (atom c '(size columns 30) '(weight . 5))
                     (atom d '(weight . 4) '(locked . #t))))
    (layout:select! a)
    (set! questions '())
    (let ([before (buffers:version layout:buffer)])
      (test-user:click-element! page (divider-before b) "<double-mouse-1>")
      (check-equal? 1 (length (buffers:edits-since layout:buffer before))))
    (check-equal? '() questions)
    (check-equal? '(((weight . 1)) ((weight . 1)) ((size columns 30) (weight . 5)) ((weight . 4) (locked . #t)))
                  (map attributes-of (list a b c d)))))

(test "a drag in a level is one step of its window history, and C-c <left> brings the sizes back"
  (let ([a (fresh "a")] [b (fresh "b")])
    (set-parts! (row (atom a) (atom b)))
    (layout:select! a)
    (test-user:settle)
    (drag! b (change 0 500 600) (change 1 500 400))
    (check-equal? '(((weight . 6/5)) ((weight . 4/5))) (map attributes-of (list a b)))
    (test-user:press! "C-c <left>")
    (check-equal? '(() ()) (children-attributes))))

(test "between a part placed at a side in columns and the level, a drag of 4 columns gives the part 4 columns more"
  (let ([a (fresh "a")])
    (set-parts! (atom a))
    (layout:select! a)
    ((layout-split:display-at-side (layout:direction left) 50 '(columns 30)) (named "*explorer*"))
    (let ([explorer (layout:find-view (named "*explorer*"))] [level (layout:level-of a)])
      (drag! level (change 0 300 340) (change 1 1000 960))
      (check-equal? '((depth . 50) (size columns 34)) (attributes-of explorer)))))

(test "with the level zoomed, the dividers around it in the screen's frame are drawn and drag"
  (let ([a (fresh "a")] [b (fresh "b")])
    (set-parts! (row (atom a) (atom b)))
    (layout:select! a)
    ((layout-split:display-at-side (layout:direction left) 50 '(columns 30)) (named "*explorer*"))
    (test-user:press! "C-x 1")
    (check (layout:zoomed-view))
    (let ([explorer (layout:find-view (named "*explorer*"))] [level (layout:level-of a)])
      (check (divider-before level))
      (check (not (divider-before b)))
      (drag! level (change 0 300 330) (change 1 1000 970))
      (check-equal? '((depth . 50) (size columns 33)) (attributes-of explorer)))))

(define middle-clicked #f)

(commands:define-command (note-middle-click) "Notes a middle click." (set! middle-clicked #t))

(keys:bind! keys:global "<mouse-2>" note-middle-click)

(test "a button other than the left on a divider is looked up as anywhere else"
  (let ([a (fresh "a")] [b (fresh "b")])
    (set-parts! (row (atom a) (atom b)))
    (layout:select! a)
    (test-user:click-element! page (divider-before b) "<mouse-2>")
    (check middle-clicked)))
