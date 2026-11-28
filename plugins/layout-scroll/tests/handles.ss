(import (tuna) (test) (test-runner) (layout) (layout-split) (layout-scroll) (views) (buffers) (document) (web) (test-user))

(define questions '())
(define reply (lambda (question) 'null))

(define page
  (test-user:open-client
    (lambda (name value)
      (if (equal? name "layout-scroll-drag")
          (begin (set! questions (cons value questions)) (reply value))
          'null))))

(define (fresh name) (views:make (or (buffers:find name) (buffers:make name (string-append name "\n")))))

(define (atom view . attributes)
  (views:view (cons* (cons 'view (views:id view)) (cons 'buffer (buffers:name (views:buffer view))) attributes)))

(define (set-parts! part)
  (let ([n (document:length (buffers:document layout:buffer))])
    (buffers:replace! layout:buffer 1 (- n 1) (document:from-datum part)))
  (test-user:settle))

(define (strip . columns) (apply layout-scroll:container '() columns))

(define (attributes-of v)
  (remp (lambda (a) (memq (car a) '(view buffer)))
        (let find-in ([d (car (document:datums (buffers:document layout:buffer)))])
          (if (vector? d)
              (and (eqv? (views:id v) (cdr (assq 'view (vector-ref d 1)))) (vector-ref d 1))
              (exists find-in (cddr d))))))

(define (handles) (test-user:elements (test-user:screen page) "strip-handle"))

(define (handle-of v)
  (test-user:settle)
  (let ([at (number->string (document:node-start (layout:view-node v)))])
    (find (lambda (e) (equal? at (test-user:element-attribute e "data-at"))) (handles))))

(define (change index old new) (list (cons "index" index) (cons "old" old) (cons "new" new)))

;; A page answers lengths only for a pointer moved past a few pixels, so
;; the release is a drag's.
(define (drag! v . changes)
  (set! reply (lambda (question) (list->vector changes)))
  (set! questions '())
  (map (lambda (r) (list (car r) (cadr r)))
       (test-runner:shown-reports-during (lambda () (test-user:drag-cells! page (handle-of v) 0 0 1 0 "<drag-mouse-1>")))))

(test "a drawn column that fits no content and is not locked carries a handle marked with the column, and a placeholder has none"
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")] [d (fresh "d")] [e (fresh "e")] [f (fresh "f")])
    (set-parts! (strip (atom a '(size . 1/3)) (atom b '(size . 1/3)) (atom c '(size columns 40)) (atom d '(size . content))
                       (atom e '(size . 1/3) '(locked . #t)) (atom f '(size . 1/2))))
    (layout:select! a)
    (test-user:settle)
    (let ([drawn (map (lambda (e) (string->number (test-user:element-attribute e "data-at")))
                      (test-user:elements (test-user:screen page) "layout-view"))])
      (check-equal? (filter (lambda (at) (memv at drawn)) (map (lambda (v) (document:node-start (layout:view-node v))) (list a b c)))
                    (map (lambda (e) (string->number (test-user:element-attribute e "data-at"))) (handles)))
      (check (not (handle-of d)))
      (check (not (handle-of e)))
      (check (not (handle-of f))))
    (check-equal? "vertical" (test-user:element-attribute (handle-of a) "aria-orientation"))))

(test "a drag of a handle multiplies its column's size by the column's new length over its old, not the selected column's"
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")])
    (set-parts! (strip (atom a '(size . 1/3)) (atom b '(size . 1/2)) (atom c '(size columns 40))))
    (layout:select! a)
    (check-equal? '() (drag! b (change 1 500 400)))
    (check-equal? '(((size . 1/3)) ((size . 2/5)) ((size columns 40))) (map attributes-of (list a b c)))
    (check (eq? a (layout:selected-view)))
    (check-equal? '((("index" . 1) ("axis" . "row") ("minimum" . 10) ("counted" . #f)))
                  (map (lambda (q) (filter (lambda (p) (member (car p) '("index" "axis" "minimum" "counted"))) q)) questions))
    (check-equal? '() (drag! c (change 2 400 440)))
    (check-equal? '((size columns 44)) (attributes-of c))
    (check-equal? #t (cdr (assoc "counted" (car questions))))))

(test "a column whose size lies across the strip is scaled from the default size, and a fraction stops at the strip's length"
  (let ([a (fresh "a")] [b (fresh "b")])
    (set-parts! (strip (atom a '(size lines 5)) (atom b '(size . 1/2))))
    (layout:select! b)
    (drag! a (change 0 500 600))
    (check-equal? '((size . 3/5)) (attributes-of a))
    (drag! b (change 1 500 1500))
    (check-equal? '((size . 1)) (attributes-of b))))

(test "an answer to a column edited since the question is refused; an edit to another column is not"
  (let ([a (fresh "a")] [b (fresh "b")])
    (set-parts! (strip (atom a '(size . 1/2)) (atom b '(size . 1/2))))
    (layout:select! a)
    (set! reply (lambda (question) (layout:set-part-attribute! (layout:view-node a) 'size 1/3) (vector (change 0 500 600))))
    (check-equal? '((layout-scroll:mouse-drag-edge "the layout changed during the drag"))
                  (map (lambda (r) (list (car r) (cadr r)))
                       (test-runner:shown-reports-during (lambda () (test-user:drag-cells! page (handle-of a) 0 0 1 0 "<drag-mouse-1>")))))
    (check-equal? '((size . 1/3)) (attributes-of a))
    (set! reply (lambda (question) (layout:set-part-attribute! (layout:view-node b) 'size 1/3) (vector (change 0 500 600))))
    (check-equal? '() (map (lambda (r) (list (car r) (cadr r)))
                           (test-runner:shown-reports-during (lambda () (test-user:drag-cells! page (handle-of a) 0 0 1 0 "<drag-mouse-1>")))))
    (check-equal? '(((size . 2/5)) ((size . 1/3))) (map attributes-of (list a b)))))

(test "an answer for another column is not a drag answer"
  (let ([a (fresh "a")] [b (fresh "b")])
    (set-parts! (strip (atom a '(size . 1/2)) (atom b '(size . 1/2))))
    (layout:select! a)
    (check-equal? '((layout-scroll:mouse-drag-edge "not a drag answer")) (drag! a (change 1 500 600)))
    (check-equal? '(((size . 1/2)) ((size . 1/2))) (map attributes-of (list a b)))))

(test "a double click on a handle gives its column the default size, and the second press asks nothing"
  (let ([a (fresh "a")] [b (fresh "b")])
    (set-parts! (strip (atom a '(size . 1/3)) (atom b '(size columns 30))))
    (layout:select! a)
    (set! questions '())
    (test-user:click-element! page (handle-of b) "<double-mouse-1>")
    (check-equal? '() questions)
    (check-equal? '(((size . 1/3)) ((size . 1/2))) (map attributes-of (list a b)))))
