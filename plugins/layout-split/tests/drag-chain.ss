(import (tuna) (test) (test-runner) (test-user) (layout) (layout-split) (views) (buffers) (document)
        (layout-split-test parts))

(define atom layout-split-test/parts:atom)
(define named layout-split-test/parts:named)
(define set-parts! layout-split-test/parts:set-parts!)
(define attributes-of layout-split-test/parts:attributes-of)

;; As a user's init.ss overrides it: a drag goes on into the next part
;; when the nearest is at its minimum, as Emacs's does.
(define (layout-split:drag-chain split parts)
  (let loop ([cs parts] [chain '()])
    (if (or (null? cs) (layout:locked? (car cs)) (eq? (document:node-attribute (car cs) 'size #f) 'content))
        (reverse chain)
        (loop (cdr cs) (cons (car cs) chain)))))

(define questions '())
(define reply (lambda (question) 'null))

(define page
  (test-user:open-client
    (lambda (name value)
      (if (equal? name "layout-split-drag")
          (begin (set! questions (cons value questions)) (reply value))
          'null))))

(define (change index old new) (list (cons "index" index) (cons "old" old) (cons "new" new)))

(define (divider-before v)
  (test-user:settle)
  (let ([at (number->string (document:node-start (layout:view-node v)))])
    (find (lambda (e) (equal? at (test-user:element-attribute e "data-at")))
          (test-user:elements (test-user:screen page) "split-divider"))))

(define (drag! v . changes)
  (set! reply (lambda (question) (list->vector changes)))
  (map (lambda (r) (list (car r) (cadr r)))
       (test-runner:shown-reports-during (lambda () (test-user:drag-cells! page (divider-before v) 0 0 1 0 "<drag-mouse-1>")))))

(define (chain-indexes side) (map (lambda (e) (cdr (assoc "index" e))) (vector->list (cdr (assoc side (car questions))))))

(define (fresh name) (views:make (named name)))

(test "an overriding drag-chain gives every part up to the first locked one on each side, nearest first, and the drag stores each"
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")] [d (fresh "d")])
    (set-parts! (layout-split:container '((direction . row)) (atom a) (atom b) (atom c) (atom d '(locked . #t))))
    (layout:select! a)
    (check-equal? '() (drag! b (change 0 300 400) (change 1 300 250) (change 2 300 250)))
    (check-equal? '((0) (1 2)) (list (chain-indexes "before") (chain-indexes "after")))
    (check-equal? '(((weight . 4/3)) ((weight . 5/6)) ((weight . 5/6)) ((locked . #t))) (map attributes-of (list a b c d)))))

(test "a part outside the chain cannot be answered for"
  (let ([a (fresh "a")] [b (fresh "b")] [c (fresh "c")] [d (fresh "d")])
    (set-parts! (layout-split:container '((direction . row)) (atom a) (atom b) (atom c) (atom d '(locked . #t))))
    (layout:select! a)
    (check-equal? '((layout-split:mouse-drag-divider "not a drag answer")) (drag! b (change 0 300 400) (change 3 300 200)))
    (check-equal? '(() () () ((locked . #t))) (map attributes-of (list a b c d)))))
