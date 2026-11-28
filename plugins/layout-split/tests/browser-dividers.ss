(import (tuna) (test) (test-runner) (test-browser) (test-user) (cdp) (cdp page) (design-tokens) (layout) (layout-split) (views) (buffers)
        (document) (editing) (layout-split-test parts))

(define atom layout-split-test/parts:atom)
(define named layout-split-test/parts:named)
(define set-parts! layout-split-test/parts:set-parts!)
(define attributes-of layout-split-test/parts:attributes-of)

(define page (test-browser:open (page-options [width 1200] [height 800] [color-scheme (color-scheme light)])))

(define (fresh name) (views:make (named name)))

(define (row . parts) (apply layout-split:container '((direction . row)) parts))

(define (column . parts) (apply layout-split:container '((direction . column)) parts))

(define (show! parts)
  (set-parts! parts)
  (layout:select! (car (layout:views)))
  (test-browser:wait-for-applied page))

(define (query p selector) (test-browser:call (lambda () (page-query p selector))))

(define (box e) (test-browser:call (lambda () (element-box e))))

(define (style e property) (test-browser:call (lambda () (element-style e property))))

(define (attribute e name) (test-browser:call (lambda () (element-attribute e name))))

(define (start-of v) (document:node-start (if (views:view? v) (layout:view-node v) v)))

(define (divider-before v) (car (query page (format ".split-divider[data-at=\"~a\"]" (start-of v)))))

;; A part's divider carries the marks of the part after it.
(define (part-element p v) (car (query p (format ".split-child:has(> :not(.split-divider)[data-at=\"~a\"])" (start-of v)))))

(define (width p v) (rectangle-width (box (part-element p v))))

(define (height p v) (rectangle-height (box (part-element p v))))

(define (centre e)
  (let ([r (box e)]) (make-point (+ (rectangle-x r) (/ (rectangle-width r) 2)) (+ (rectangle-y r) (/ (rectangle-height r) 2)))))

(define (moved at dx dy) (make-point (+ (point-x at) dx) (+ (point-y at) dy)))

(define (near? a b) (< (abs (- a b)) 1))

(define (weight-of v) (let ([w (assq 'weight (attributes-of v))]) (if w (cdr w) 1)))

;; The rule along a part's start is outside the length a flex value sets.
(define (rule-of p v) (if (string=? "0px" (style (part-element p v) "border-left-width")) 0 1))

(define (cell p v) (string->number (let ([s (style (part-element p v) "--layout-cell-width")]) (substring s 0 (- (string-length s) 2)))))

(define (held-drag! divider dx dy)
  (let ([at (centre divider)])
    (test-browser:press-button! page divider)
    (test-browser:move-pointer! page (moved at (/ dx 2) (/ dy 2)))
    (test-browser:move-pointer! page (moved at dx dy))))

;; The page follows a press once Tuna's question about it arrives, which a
;; press that changes no screen sends after the press's answer.
(define (held-drag-shown! divider dx dy)
  (let ([at (centre divider)])
    (held-drag! divider dx dy)
    (test-runner:wait-until
      (lambda () (let ([now (centre divider)]) (> (+ (abs (- (point-x now) (point-x at))) (abs (- (point-y now) (point-y at)))) 1))))))

(define (text-of v) (document:text (buffers:document (views:buffer v))))

;; The page writes a length in pixels; Tuna stores a weight, a fraction or a count.
(define (stored-shown?)
  (for-all (lambda (e) (let ([s (attribute e "style")])
                         (not (exists (lambda (i) (string=? "px" (substring s i (+ i 2)))) (iota (- (string-length s) 1))))))
           (query page ".split-child")))

(test "a divider shows the resize pointer and its state, and one beside a part that fits its content is inert with the arrow"
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")] [d (fresh "d")])
    (show! (row (column (atom a) (atom b)) (atom c) (atom d '(size . content))))
    (check-equal? '("col-resize" "row-resize" "default")
                  (map (lambda (v) (style (divider-before v) "cursor")) (list c b d)))
    (check-equal? '(#t #t #t)
                  (map (lambda (v e) (let ([mark (attribute (divider-before v) "data-keymap")])
                                       (string=? e (substring mark (- (string-length mark) (string-length e)) (string-length mark)))))
                       (list c b d) '("clickable" "clickable" "inert")))
    (check-equal? "none" (style (divider-before c) "background-image"))))

(test "a press at a divider, on either edge of it, reaches the divider, not the part beside it"
  (let ([a (fresh "a")] [b (fresh "b")])
    (show! (row (atom a) (atom b)))
    (let* ([divider (divider-before b)] [r (box divider)] [id (test-browser:call (lambda () (element-backend-node-id divider)))])
      (test-browser:call (lambda () (element-hover! divider)))
      (for-each
        (lambda (x)
          (check-equal? id (test-browser:call
                             (lambda ()
                               (cdr (assoc "backendNodeId"
                                           (cdp-call (page-session page) "DOM.getNodeForLocation"
                                             (list (cons "x" (exact (floor x))) (cons "y" (exact (floor (+ (rectangle-y r) 100))))))))))))
        (list (+ (rectangle-x r) 0.5) (+ (rectangle-x r) (rectangle-width r) -0.5))))))

(test "a drag moves the divider with the pointer, keeps the two parts' total and every other part's length, and stores weights in the ratio of the lengths"
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")])
    (show! (row (atom a '(weight . 2)) (atom b) (atom c)))
    (let* ([divider (divider-before b)] [from (point-x (centre divider))]
           [before (map (lambda (v) (width page v)) (list a b c))])
      (held-drag-shown! divider 100 0)
      (let ([during (map (lambda (v) (width page v)) (list a b c))])
        (check-compare near? (+ (car before) 100) (car during))
        (check-compare near? (+ (car before) (cadr before)) (+ (car during) (cadr during)))
        (check-compare near? (caddr before) (caddr during))
        (check-compare near? (+ from 100) (point-x (centre (divider-before b))))
        (test-browser:release-button! page)
        (let ([after (map (lambda (v) (width page v)) (list a b c))])
          (check (stored-shown?))
          (for-each (lambda (x y) (check-compare near? x y)) during after)
          (check-compare (lambda (x y) (< (abs (- x y)) 1/200))
                         (/ (car after) (- (cadr after) (rule-of page b)))
                         (/ (weight-of a) (weight-of b)))
          (check-equal? 1 (weight-of c)))))))

(test "a short move stores nothing"
  (let ([a (fresh "a")] [b (fresh "b")])
    (show! (row (atom a) (atom b)))
    (held-drag! (divider-before b) 2 0)
    (check-equal? '() (test-runner:shown-reports-during (lambda () (test-browser:release-button! page))))
    (check-equal? '(() ()) (map attributes-of (list a b)))))

(test "a part stops at its minimum, and the divider with it, while the pointer goes on"
  (let ([a (fresh "a")] [b (fresh "b")])
    (show! (row (atom a) (atom b)))
    (let ([least (* 10 (cell page b))])
      (held-drag-shown! (divider-before b) 1000 0)
      (check-compare near? least (- (width page b) (rule-of page b)))
      (test-browser:release-button! page)
      (check-compare near? least (- (width page b) (rule-of page b))))))

(test "a part under its minimum may grow but never shrink"
  (let ([a (fresh "a")] [b (fresh "b")])
    (show! (row (atom a) (atom b '(size columns 5))))
    (let ([was (width page b)] [one (cell page b)])
      (held-drag! (divider-before b) 100 0)
      (test-browser:release-button! page)
      (check-equal? '((size columns 5)) (attributes-of b))
      (check-compare near? was (width page b))
      (held-drag! (divider-before b) (* -3 one) 0)
      (test-browser:release-button! page)
      (check-equal? '((size columns 8)) (attributes-of b)))))

(test "a part with no length gives no space, grows when its neighbour gives, and keeps its weight"
  (let ([a (fresh "a")] [b (fresh "b")])
    (show! (row (atom a) (atom b '(size columns 200))))
    (check-compare near? 0 (width page a))
    (held-drag! (divider-before b) -50 0)
    (test-browser:release-button! page)
    (check-equal? '((size columns 200)) (attributes-of b))
    (let ([one (cell page b)])
      (held-drag! (divider-before b) (* 20 one) 0)
      (test-browser:release-button! page)
      (check-equal? '(() ((size columns 180))) (map attributes-of (list a b))))))

(test "a count of columns moves by whole columns, and the size stored is the one shown"
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")])
    (show! (row (atom a '(size columns 40)) (atom b) (atom c)))
    (let ([one (cell page a)] [c-was (width page c)])
      (held-drag-shown! (divider-before b) (* 4.4 one) 0)
      (check-compare near? (* 44 one) (width page a))
      (test-browser:release-button! page)
      (check-equal? '((size columns 44)) (attributes-of a))
      (check-compare near? (* 44 one) (width page a))
      (check-compare near? c-was (width page c)))))

(test "another page of another width shows its old sizes during the drag, and the same proportions and counts after"
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")]
        [narrow (test-browser:open (page-options [width 700] [height 800] [color-scheme (color-scheme light)]))])
    (show! (row (atom a) (atom b) (atom c '(size columns 30))))
    (test-browser:wait-for-applied narrow)
    (let ([before (map (lambda (v) (width narrow v)) (list a b c))])
      (held-drag-shown! (divider-before b) 120 0)
      (check-equal? before (map (lambda (v) (width narrow v)) (list a b c)))
      (test-browser:release-button! page)
      (test-browser:wait-for-applied narrow)
      (let ([here (map (lambda (v) (width page v)) (list a b))] [there (map (lambda (v) (width narrow v)) (list a b c))])
        (check-compare (lambda (x y) (< (abs (- x y)) 1/100))
                       (/ (car here) (- (cadr here) (rule-of page b)))
                       (/ (car there) (- (cadr there) (rule-of narrow b))))
        (check-compare near? (caddr before) (caddr there))))
    (test-browser:close! narrow)))

(test "a nested split's divider changes only its pair, and the outer divider leaves the nested parts' proportions"
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")])
    (show! (row (atom a) (column (atom b) (atom c))))
    (let ([inner (document:enclosing (buffers:document layout:buffer) (start-of b))] [a-was (width page a)])
      (held-drag! (divider-before c) 0 60)
      (test-browser:release-button! page)
      (check-compare near? a-was (width page a))
      (let ([ratio (/ (height page b) (height page c))])
        (held-drag! (divider-before inner) -100 0)
        (test-browser:release-button! page)
        (check-compare near? (- a-was 100) (width page a))
        (check-compare (lambda (x y) (< (abs (- x y)) 1/100)) ratio (/ (height page b) (height page c)))))))

(test "a part placed at a side in columns takes the columns the drag showed, and the divider beside a locked part does nothing"
  (let ([a (fresh "a")])
    (show! (atom a))
    ((layout-split:display-at-side (layout:direction left) 50 '(columns 30)) (named "*explorer*"))
    ((layout-split:display-at-side (layout:direction down) 90 'content '((locked . #t))) (named "*echo*"))
    (test-browser:wait-for-applied page)
    (let* ([explorer (layout:find-view (named "*explorer*"))] [echo (layout:find-view (named "*echo*"))]
           [level (layout:level-of a)] [one (cell page explorer)])
      (held-drag! (divider-before level) (* 4 one) 0)
      (test-browser:release-button! page)
      (check-equal? '((depth . 50) (size columns 34)) (attributes-of explorer))
      (check-compare near? (* 34 one) (- (width page explorer) (rule-of page explorer)))
      (check-equal? "default" (style (divider-before echo) "cursor"))
      (let ([before (list (attributes-of a) (attributes-of echo))])
        (held-drag! (divider-before echo) 0 -50)
        (test-browser:release-button! page)
        (check-equal? before (list (attributes-of a) (attributes-of echo)))))
    (layout:delete-part! (layout:view-node (layout:find-view (named "*explorer*"))))
    (layout:delete-part! (layout:view-node (layout:find-view (named "*echo*"))))))

(test "a key typed during the drag waits, and runs after the release, once the sizes are stored"
  (let ([a (views:make (buffers:make (buffers:free-name "typed") "one"))] [b (fresh "b")])
    (show! (row (atom a) (atom b)))
    (held-drag! (divider-before b) 80 0)
    (test-browser:press! page "x")
    (check-equal? "one" (text-of a))
    (test-browser:release-button! page)
    (test-runner:wait-until (lambda () (= 4 (string-length (text-of a)))))
    (check (> (weight-of a) 1))))

(test "a quit key during the drag stops it: the page puts the lengths back and nothing is stored"
  (let ([a (fresh "a")] [b (fresh "b")])
    (show! (row (atom a) (atom b)))
    (let ([before (map (lambda (v) (width page v)) (list a b))])
      (held-drag! (divider-before b) 80 0)
      (check-equal? '((cancelled quit))
                    (map (lambda (c) (list 'cancelled (cancelled-reason c)))
                         (test-runner:reports-during (lambda () (test-browser:press! page "C-g")))))
      (test-runner:wait-until (lambda () (equal? before (map (lambda (v) (width page v)) (list a b)))))
      (test-browser:release-button! page)
      (check-equal? '(() ()) (map attributes-of (list a b)))
      (check-equal? before (map (lambda (v) (width page v)) (list a b))))))

(test "of two pages dragging one split, the later answer is refused, and that page shows what the first stored"
  (let ([a (fresh "a")] [b (fresh "b")] [other (test-browser:open (page-options [width 1200] [height 800]))])
    (show! (row (atom a) (atom b)))
    (test-browser:wait-for-applied other)
    (held-drag! (divider-before b) 80 0)
    (test-browser:drag! other (car (query other (format ".split-divider[data-at=\"~a\"]" (start-of b))))
                        (moved (centre (divider-before b)) -100 0))
    (let ([stored (map attributes-of (list a b))])
      (check-equal? '((layout-split:mouse-drag-divider "the layout changed during the drag"))
                    (map (lambda (r) (list (car r) (cadr r)))
                         (test-runner:shown-reports-during (lambda () (test-browser:release-button! page)))))
      (check-equal? stored (map attributes-of (list a b)))
      (test-runner:wait-until (lambda () (near? (width other a) (width page a)))))
    (test-browser:close! other)))

(test "a drag whose divider a change removes answers nothing and changes nothing"
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")])
    (show! (row (atom a) (atom b) (atom c)))
    (held-drag! (divider-before c) 80 0)
    (layout:delete-part! (layout:view-node c))
    (test-browser:wait-for-applied page)
    (check-equal? '() (test-runner:shown-reports-during (lambda () (test-browser:release-button! page))))
    (check-equal? '(() ()) (map attributes-of (list a b)))))

(test "a double click on a divider balances its split, and C-c <left> brings the sizes back"
  (let ([a (fresh "a")] [b (fresh "b")])
    (show! (row (atom a '(weight . 3)) (atom b)))
    (test-browser:double-click! page (divider-before b))
    (check-equal? '(((weight . 1)) ()) (map attributes-of (list a b)))
    (test-browser:wait-for-applied page)
    (check-compare near? (width page a) (- (width page b) (rule-of page b)))
    (test-browser:press! page "C-c <left>")
    (check-equal? '((weight . 3))
                  (let ([split (caddr (layout-split-test/parts:tree))])
                    (remp (lambda (x) (memq (car x) '(view buffer))) (vector-ref (caddr split) 1))))))


(test "a divider that can move lights under the pointer, and one that cannot does not"
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")])
    (show! (row (atom a) (atom b) (atom c '(size . content))))
    (let ([unlit "rgba(0, 0, 0, 0)"] [movable (divider-before b)] [fixed (divider-before c)])
      (check-equal? unlit (style movable "background-color"))
      (test-browser:call (lambda () (element-hover! movable)))
      (check (not (equal? unlit (style movable "background-color"))))
      (test-browser:call (lambda () (element-hover! fixed)))
      (check-equal? (list unlit unlit) (map (lambda (v) (style (divider-before v) "background-color")) (list b c))))))

(test "a button released outside the window ends the drag at its next move, and the lengths reached are stored"
  (let ([a (fresh "a")] [b (fresh "b")])
    (show! (row (atom a) (atom b)))
    (let ([before (width page a)] [at (centre (divider-before b))])
      (held-drag-shown! (divider-before b) 80 0)
      (test-browser:release-outside! page (moved at 80 0))
      (check-compare near? (+ before 80) (width page a))
      (check (> (weight-of a) 1))
      (check (stored-shown?)))))
