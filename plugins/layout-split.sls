#!tuna
(import (layout) (buffers) (document) (views) (keys) (repeat) (commands) (web) (haml))

(define-enumeration direction (row column) directions)

(module %internals
  (parts weight weight-text column? split-node? with-weight without node-datum replace-node!
   holding-split balanced)

  (define (parts node)
    (let ([acc '()])
      (document:for-each-child node (fx+ (document:node-start node) 1) (fx- (document:node-end node) 1)
        (lambda (c at) (when (document:node? c) (set! acc (cons c acc)))))
      (reverse acc)))

  (define (positive-weight w) (if (and (real? w) (finite? w) (> w 0)) w 1))

  (define (weight node) (positive-weight (document:node-attribute node 'weight 1)))

  (define (weight-text node) (number->string (inexact (weight node))))

  (define (column? node) (eq? (document:node-attribute node 'direction 'row) 'column))

  (define (split-node? node kind)
    (and node (not (document:atom? node)) (eq? (document:node-kind node) kind)))

  (define (datum-attributes d) (if (vector? d) (vector-ref d 1) (cadr d)))

  (define (locked-datum? d)
    (let ([p (assq 'locked (datum-attributes d))]) (and p (cdr p) #t)))

  (define (with-attributes d attributes)
    (if (vector? d) (vector (vector-ref d 0) attributes) (cons* (car d) attributes (cddr d))))

  (define (without d keys)
    (with-attributes d (remp (lambda (a) (memq (car a) keys)) (datum-attributes d))))

  (define (with-weight d w)
    (with-attributes d (append (remp (lambda (a) (eq? (car a) 'weight)) (datum-attributes d))
                               (list (cons 'weight w)))))

  (define (node-datum node)
    (car (document:datums (document:slice (buffers:document layout:buffer)
                                          (document:node-start node) (document:node-end node)))))

  (define (replace-node! node content)
    (buffers:replace! layout:buffer (document:node-start node) (document:node-end node) content))

  (define (holding-split atom kind)
    (let ([doc (buffers:document layout:buffer)])
      (let loop ([n atom])
        (let ([p (document:enclosing doc (document:node-start n))])
          (cond
            [(not p) (values #f #f)]
            [(split-node? p kind) (values p n)]
            [else (loop p)])))))

  (define (balanced d kind)
    (if (or (vector? d) (locked-datum? d))
        d
        (let ([children (map (lambda (c) (balanced c kind)) (cddr d))])
          (cons* (car d) (cadr d)
                 (if (eq? (car d) kind)
                     (map (lambda (c)
                            (let ([w (assq 'weight (datum-attributes c))])
                              (if (and w (not (eqv? (cdr w) 1)) (not (locked-datum? c))) (with-weight c 1) c)))
                          children)
                     children))))))

(import %internals)

(define (%draw-split node children focused draw-child)
  (haml (:div.split ([class (if (column? node) "column" "row")])
          (map (lambda (c) (haml (:div.split-child ([style "flex:" (weight-text c) " 1 0"]) (draw-child c))))
               children))))

(define (%split-neighbour node child direction)
  (let-values ([(before after) (if (column? node) (values 'up 'down) (values 'left 'right))])
    (let loop ([cs (parts node)] [previous #f])
      (cond
        [(null? cs) #f]
        [(fx= (document:node-start (car cs)) (document:node-start child))
         (cond
           [(eq? direction before) previous]
           [(eq? direction after) (and (pair? (cdr cs)) (cadr cs))]
           [else #f])]
        [else (loop (cdr cs) (car cs))]))))

(layout:define-container container
  (draw %draw-split)
  (neighbour %split-neighbour)
  (child-attributes weight)
  (collapse))

(define (split-view! view direction)
  (unless (views:view? view)
    (assertion-violation 'layout-split:split-view! "not a view" view))
  (unless (enum-set-member? direction (enum-set-universe (directions)))
    (assertion-violation 'layout-split:split-view! "not a split direction" direction))
  (let ([atom (layout:view-node view)] [b (views:buffer view)] [kind (car (container '()))])
    (unless atom
      (assertion-violation 'layout-split:split-view! "not a view in the layout" view))
    (when (layout:locked? atom)
      (assertion-violation 'layout-split:split-view! "a locked view" view))
    (unless b
      (assertion-violation 'layout-split:split-view! "the view shows no buffer" view))
    (let* ([new (views:make b)]
           [new-datum (vector 'views:view (list (cons 'view (views:id new)) (cons 'buffer (buffers:name b))))]
           [d (node-datum atom)]
           [parent (document:enclosing (buffers:document layout:buffer) (document:node-start atom))])
      (views:set-point! new (views:point view))
      (if (and (split-node? parent kind) (eq? (if (column? parent) 'column 'row) direction))
          (let ([w (/ (weight atom) 2)])
            (replace-node! atom (document:from-datum (with-weight d w) (with-weight new-datum w))))
          ;; The new split takes the view's place, so what placed the view
          ;; in its parent goes to the split.
          (let ([place (filter (lambda (a) (memq (car a) (if (split-node? parent kind) '(weight pinned) '(pinned))))
                               (vector-ref d 1))])
            (replace-node! atom
              (container (cons (cons 'direction direction) place) (without d (map car place)) new-datum))))
      new)))

(define (%resize! who n sign)
  (unless (and (integer? n) (exact? n))
    (assertion-violation who "not an exact integer" n))
  (let ([atom (layout:view-node (layout:selected-view))] [kind (car (container '()))])
    (let-values ([(split part) (holding-split atom kind)])
      (unless split
        (assertion-violation who "the selected view is in no split"))
      (when (layout:locked? split)
        (assertion-violation who "a locked part" split))
      (let* ([cs (parts split)] [k (length cs)]
             [total (fold-left + 0 (map weight cs))]
             [delta (* sign n total 1/10)])
        (when (fx= k 1)
          (assertion-violation who "the selected view has no sibling in its split"))
        (let ([weights (map (lambda (c)
                              (if (fx= (document:node-start c) (document:node-start part))
                                  (+ (weight c) delta)
                                  (- (weight c) (/ delta (- k 1)))))
                            cs)])
          (unless (for-all positive? weights)
            (assertion-violation who "the split cannot change that much" n))
          (let ([d (node-datum split)])
            (replace-node! split (cons* (car d) (cadr d) (map with-weight (cddr d) weights)))
            (void)))))))

(define (%display-in b direction)
  (or (layout:reuse-view b)
      (let ([selected (layout:selected-view)])
        (and (not (layout:locked? (layout:view-node selected)))
             (let ([v (split-view! selected direction)])
               (views:set-buffer! v b)
               v)))))

(define (display-below b)
  (unless (buffers:buffer? b)
    (assertion-violation 'layout-split:display-below "not a buffer" b))
  (%display-in b (direction column)))

(define (display-right b)
  (unless (buffers:buffer? b)
    (assertion-violation 'layout-split:display-right "not a buffer" b))
  (%display-in b (direction row)))

(commands:define-command (split-below)
  "Splits the selected view with a new view below it."
  (split-view! (layout:selected-view) (direction column))
  (void))

(commands:define-command (split-right)
  "Splits the selected view with a new view to its right."
  (split-view! (layout:selected-view) (direction row))
  (void))

(commands:define-command (enlarge [n (commands:prefix-number)])
  "Adds n tenths of its split's total weight to the part holding the selected view, taken evenly from its siblings."
  (%resize! 'layout-split:enlarge n 1))

(commands:define-command (shrink [n (commands:prefix-number)])
  "Takes n tenths of its split's total weight from the part holding the selected view, given evenly to its siblings."
  (%resize! 'layout-split:shrink n -1))

(commands:define-command (balance)
  "Sets the weight of every child of every split in the frame's zoomed part to 1."
  (let ([root (document:token (buffers:document layout:buffer) 0)])
    (unless (or (layout:zoomed-view) (layout:locked? root))
      (let ([kind (car (container '()))])
        (for-each
          (lambda (child)
            (let* ([d (node-datum child)] [b (balanced d kind)])
              (unless (equal? d b) (replace-node! child b))))
          (parts root))))))

(define-table resize-keymap "Keys that go on resizing after C-x { or C-x }.")

(keys:bind! keys:global "C-x 2" split-below)
(keys:bind! keys:global "C-x 3" split-right)
(keys:bind! keys:global "C-x }" enlarge)
(keys:bind! keys:global "C-x {" shrink)
(keys:bind! keys:global "C-x +" balance)

(keys:bind! resize-keymap "}" enlarge)
(keys:bind! resize-keymap "{" shrink)
(table-set! repeat:keymaps resize-keymap)
(table-set! web:stylesheets 'layout-split "layout-split/layout-split.css")
