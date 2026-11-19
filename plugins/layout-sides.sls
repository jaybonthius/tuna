#!tuna
(import (layout) (layout-split) (buffers) (document) (views))

(module %internals
  (check-size check-attributes place!)

  (define (check-size who v)
    (unless (or (and (real? v) (exact? v) (< 0 v) (<= v 1))
                (eq? v 'content)
                (and (list? v) (fx= (length v) 2) (memq (car v) '(columns lines)) (fixnum? (cadr v)) (fx> (cadr v) 0)))
      (assertion-violation who "not a fraction, (columns n), (lines n) or content" v)))

  (define (check-attributes who a)
    (unless (and (list? a) (for-all (lambda (p) (and (pair? p) (symbol? (car p)))) a))
      (assertion-violation who "not an association list of attributes" a))
    (for-each
      (lambda (p)
        (when (memq (car p) '(view buffer depth size))
          (assertion-violation who "an attribute the action sets itself" (car p))))
      a))

  (define (doc) (buffers:document layout:buffer))

  (define (parts node)
    (let ([acc '()])
      (document:for-each-child node (fx+ (document:node-start node) 1) (fx- (document:node-end node) 1)
        (lambda (c at) (when (document:node? c) (set! acc (cons c acc)))))
      (reverse acc)))

  (define (kind? node kind) (and (not (document:atom? node)) (eq? (document:node-kind node) kind)))

  (define (level? node) (kind? node (buffers:kind-name (buffers:constructor-kind layout:level))))

  (define (split? node) (kind? node (buffers:kind-name (buffers:constructor-kind layout-split:container))))

  (define (axis-of side) (if (memq side '(left right)) 'row 'column))

  (define (along? node axis)
    (and node (split? node) (eq? (document:node-attribute node 'direction 'row) axis)))

  (define (depth-of node)
    (let ([d (document:node-attribute node 'depth #f)]) (and (real? d) d)))

  (define (holds-level? node)
    (and (not (document:atom? node)) (exists (lambda (c) (or (level? c) (holds-level? c))) (parts node))))

  ;; A part holding a placed part is placed too, unless it holds a level:
  ;; then it is the way to the user's windows.
  (define (placed-depth node)
    (or (depth-of node)
        (and (not (document:atom? node)) (not (holds-level? node))
             (exists placed-depth (parts node)))))

  (define (holds-placed? node)
    (and (split? node) (exists placed-depth (parts node))))

  (define (leads-to-level? node)
    (or (level? node) (and (split? node) (exists leads-to-level? (parts node)))))

  ;; Only splits are entered, so a level made elsewhere, such as inside
  ;; tabs, is never taken for the user's windows.
  (define (stop-part depth)
    (let loop ([x (car (parts (document:token (doc) 0)))])
      (if (and (split? x) (for-all (lambda (c) (let ([d (placed-depth c)]) (or (not d) (> d depth)))) (parts x)))
          (let ([c (find leads-to-level? (parts x))])
            (if c (loop c) x))
          x)))

  (define (datum-of node)
    (car (document:datums (document:slice (doc) (document:node-start node) (document:node-end node)))))

  (define (datum-attributes d) (if (vector? d) (vector-ref d 1) (cadr d)))

  (define (with-attributes d attributes)
    (if (vector? d) (vector (vector-ref d 0) attributes) (cons* (car d) attributes (cddr d))))

  (define (position-of node nodes)
    (let loop ([ns nodes] [k 0])
      (if (fx= (document:node-start (car ns)) (document:node-start node)) k (loop (cdr ns) (fx+ k 1)))))

  ;; Of two parts at one depth the later sits nearer the edge, as hook
  ;; entries keep their order.
  (define (index-in x before? depth)
    (let* ([cs (parts x)] [n (length cs)]
           [h (let ([c (find leads-to-level? cs)]) (cond [c (position-of c cs)] [before? n] [else -1]))]
           [deeper? (lambda (c) (let ([d (placed-depth c)]) (and d (> d depth))))])
      (if before?
          (let loop ([i (fx- h 1)])
            (cond [(fx< i 0) 0] [(deeper? (list-ref cs i)) (fx+ i 1)] [else (loop (fx- i 1))]))
          (let loop ([i (fx+ h 1)])
            (cond [(fx>= i n) n] [(deeper? (list-ref cs i)) i] [else (loop (fx+ i 1))])))))

  (define (insert-at! node k d)
    (let* ([cs (parts node)]
           [at (if (fx< k (length cs)) (document:node-start (list-ref cs k)) (fx- (document:node-end node) 1))])
      (buffers:replace! layout:buffer at at d)))

  (define (place-attribute? a) (memq (car a) '(weight size)))

  ;; Wrapping the user's windows in a level and placing the part beside
  ;; them is one edit, so no level ever holds a level between the two.
  (define (place! b side depth size attributes)
    (let* ([v (views:make b)]
           [atom (vector 'views:view (append (list (cons 'view (views:id v)) (cons 'buffer (buffers:name b))
                                                   (cons 'depth depth) (cons 'size size))
                                             attributes))]
           [axis (axis-of side)] [before? (memq side '(left up))]
           [x (stop-part depth)] [p (document:enclosing (doc) (document:node-start x))]
           [main? (or (level? x) (holds-placed? x))])
      (cond
        [(and main? (along? x axis) (holds-placed? x))
         (insert-at! x (index-in x before? depth) atom)]
        [(and main? (along? p axis))
         (insert-at! p (fx+ (position-of x (parts p)) (if before? 0 1)) atom)]
        [else
         (let* ([d (datum-of x)]
                [place (if (split? p) (filter place-attribute? (datum-attributes d)) '())]
                [bare (with-attributes d (remp place-attribute? (datum-attributes d)))]
                [inner (if main? bare (layout:level '() bare))]
                [beside (lambda (kept) (if before? (list atom kept) (list kept atom)))])
           (buffers:replace! layout:buffer (document:node-start x) (document:node-end x)
             (apply document:from-datum
               (if (along? p axis)
                   (beside (with-attributes inner place))
                   (list (apply layout-split:container (cons (cons 'direction axis) place) (beside inner)))))))])
      v)))

(import %internals)

(define display-at-side
  (case-lambda
    [(side depth size) (display-at-side side depth size '())]
    [(side depth size attributes)
     (unless (enum-set-member? side (enum-set-universe (layout:directions)))
       (assertion-violation 'layout-sides:display-at-side "not a direction" side))
     (unless (real? depth)
       (assertion-violation 'layout-sides:display-at-side "not a real number" depth))
     (check-size 'layout-sides:display-at-side size)
     (check-attributes 'layout-sides:display-at-side attributes)
     (lambda (b)
       (unless (buffers:buffer? b)
         (assertion-violation 'layout-sides:display-at-side "not a buffer" b))
       (or (layout:find-view b) (place! b side depth size attributes)))]))
