(import (tuna) (test) (layout) (layout-split) (views) (buffers) (document) (haml) (test-user))

(define (atom view . attributes)
  (views:view (cons* (cons 'view (views:id view)) (cons 'buffer (buffers:name (views:buffer view))) attributes)))

(define (set-parts! . parts)
  (let ([n (document:length (buffers:document layout:buffer))])
    (buffers:replace! layout:buffer 1 (- n 1) (apply document:from-datum parts)))
  (test-user:settle))

(define a (buffers:make (buffers:free-name "a") "a\n"))
(define va (views:make a))
(define vb (views:make a))
(define vc (views:make a))

(test "super with i, j, k, l or the arrows selects the neighbour above, left, below or right"
  (set-parts! (layout-split:container '((direction . row)) (atom va) (layout-split:container '((direction . column)) (atom vb) (atom vc))))
  (layout:select! va)
  (test-user:press! "s-l")
  (check-equal? vb (layout:selected-view))
  (test-user:press! "s-k")
  (check-equal? vc (layout:selected-view))
  (test-user:press! "s-i")
  (check-equal? vb (layout:selected-view))
  (test-user:press! "s-j")
  (check-equal? va (layout:selected-view))
  (test-user:press! "s-<right> s-<down> s-<up> s-<left>")
  (check-equal? va (layout:selected-view)))

(test "selection-order lists the views by their last selection"
  (check-equal? (list va vb vc) (layout:selection-order)))

(define (draw-ring node children focused draw-child client) (haml (:div (map draw-child children))))

(define (ring-neighbour node child direction)
  (let* ([cs (let ([acc '()])
               (document:for-each-child node (+ (document:node-start node) 1) (- (document:node-end node) 1)
                 (lambda (c at) (when (document:node? c) (set! acc (cons c acc)))))
               (reverse acc))]
         [k (let loop ([cs cs] [k 0]) (if (= (document:node-start (car cs)) (document:node-start child)) k (loop (cdr cs) (+ k 1))))])
    (list-ref cs (mod (+ k 1) (length cs)))))

(layout:define-container ring (draw draw-ring) (neighbour ring-neighbour))

(test "a kind that names its siblings in a cycle cannot hang the neighbour walk, which stops where it began when every other child is locked"
  (set-parts! (ring '() (atom va) (atom vb '(locked . #t)) (atom vc '(locked . #t))))
  (layout:select! va)
  (check-equal? #f (layout:neighbour va (layout:direction right)))
  (set-parts! (ring '() (atom va) (atom vb '(locked . #t)) (atom vc)))
  (check-equal? vc (layout:neighbour va (layout:direction right))))
