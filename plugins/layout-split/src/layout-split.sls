#!tuna
(import (layout) (buffers) (document) (views) (keys) (commands) (web) (haml) (options) (tables))

(define-enumeration direction (row column) directions)

(module %internals
  (parts weight least-weight flex-text column? split-node? with-weight without node-datum replace-node!
   holding-split balanced evened transposed check-size check-attributes place! axis-of
   datum-attributes with-attribute fraction? counted? position-of positive-weight)

  (define (parts node)
    (let ([acc '()])
      (document:for-each-child node (fx+ (document:node-start node) 1) (fx- (document:node-end node) 1)
        (lambda (c at) (when (document:node? c) (set! acc (cons c acc)))))
      (reverse acc)))

  (define (positive-weight w) (if (and (real? w) (finite? w) (> w 0)) w 1))

  (define (weight node) (positive-weight (document:node-attribute node 'weight 1)))

  (define (column? node) (eq? (document:node-attribute node 'direction 'row) 'column))

  (define (fraction? s) (and (real? s) (exact? s) (< 0 s) (<= s 1)))

  (define (counted? s unit)
    (and (list? s) (fx= (length s) 2) (eq? (car s) unit) (fixnum? (cadr s)) (fx> (cadr s) 0)))

  ;; A size along the other axis, such as columns in a column split,
  ;; means nothing here, so the child shares by weight.
  (define (weighted? node child)
    (let ([s (document:node-attribute child 'size #f)])
      (not (or (fraction? s) (eq? s 'content) (counted? s (if (column? node) 'lines 'columns))))))

  ;; Flexbox gives growing items only that share of the free space when
  ;; their factors add up to less than 1, so a weight is drawn over the
  ;; least of its split's weights, each then at least 1.
  (define (least-weight node)
    (fold-left (lambda (least c) (if (weighted? node c) (min least (weight c)) least)) +inf.0 (parts node)))

  (define (flex-text node child least)
    (let ([s (document:node-attribute child 'size #f)])
      (cond
        [(fraction? s)
         (string-append "0 0 " (number->string (inexact (* 100 s))) "%")]
        [(eq? s 'content) "none"]
        [(counted? s (if (column? node) 'lines 'columns))
         (string-append "0 0 " (number->string (cadr s)) (if (column? node) "lh" "ch"))]
        [else (string-append (number->string (inexact (/ (weight child) least))) " 1 0")])))

  (define (split-node? node kind)
    (and node (not (document:atom? node)) (eq? (document:node-kind node) kind)))

  (define (datum-attributes d) (if (vector? d) (vector-ref d 1) (cadr d)))

  (define (locked-datum? d)
    (let ([p (assq 'locked (datum-attributes d))]) (and p (cdr p) #t)))

  (define (placed-datum? d)
    (let ([p (assq 'depth (datum-attributes d))]) (and p (cdr p) #t)))

  (define (kept-whole? d level)
    (or (vector? d) (locked-datum? d) (eq? (car d) level)))

  (define (holds-placed? d level)
    (or (placed-datum? d)
        (and (not (vector? d)) (not (eq? (car d) level))
             (exists (lambda (c) (holds-placed? c level)) (cddr d)))))

  (define (with-attributes d attributes)
    (if (vector? d) (vector (vector-ref d 0) attributes) (cons* (car d) attributes (cddr d))))

  (define (without d keys)
    (with-attributes d (remp (lambda (a) (memq (car a) keys)) (datum-attributes d))))

  (define (with-attribute d key v)
    (with-attributes d (append (remp (lambda (a) (eq? (car a) key)) (datum-attributes d))
                               (list (cons key v)))))

  (define (with-weight d w) (with-attribute d 'weight w))

  (define (node-datum node)
    (car (document:datums (document:slice (buffers:document layout:buffer)
                                          (document:node-start node) (document:node-end node)))))

  (define (replace-node! node content)
    (buffers:replace! layout:buffer (document:node-start node) (document:node-end node) content))

  ;; Resizing takes from the other parts of a split, so it stays in the
  ;; view's level, as the other commands that mean the other views do.
  (define (holding-split atom kind direction)
    (let ([doc (buffers:document layout:buffer)] [level (buffers:kind-name (buffers:constructor-kind layout:level))])
      (let loop ([n atom])
        (let ([p (document:enclosing doc (document:node-start n))])
          (cond
            [(or (not p) (eq? (document:node-kind p) level)) (values #f #f)]
            [(and (split-node? p kind) (eq? (if (column? p) 'column 'row) direction)) (values p n)]
            [else (loop p)])))))

  (define (evened c)
    (let ([w (assq 'weight (datum-attributes c))])
      (if (and w (not (eqv? (cdr w) 1)) (not (locked-datum? c)) (not (assq 'size (datum-attributes c))))
          (with-weight c 1)
          c)))

  (define (balanced d kind level)
    (if (kept-whole? d level)
        d
        (let ([children (map (lambda (c) (balanced c kind level)) (cddr d))])
          (cons* (car d) (cadr d) (if (eq? (car d) kind) (map evened children) children)))))

  (define (turned attributes)
    (let ([p (assq 'direction attributes)])
      (if p
          (map (lambda (a) (if (eq? a p) (cons 'direction (if (eq? (cdr p) 'column) 'row 'column)) a))
               attributes)
          (cons '(direction . column) attributes))))

  ;; A child's size in columns or lines means nothing across its split,
  ;; so it is kept rather than converted, and transposing back gives the
  ;; layout as it was. Placed parts persist for the level's views, so a
  ;; split holding one keeps its direction: turning it would move them.
  (define (transposed d kind level)
    (if (or (kept-whole? d level) (placed-datum? d))
        d
        (cons* (car d)
               (if (and (eq? (car d) kind) (not (holds-placed? d level)))
                   (turned (cadr d))
                   (cadr d))
               (map (lambda (c) (transposed c kind level)) (cddr d)))))

  (define (check-size who v)
    (unless (or (fraction? v) (eq? v 'content) (counted? v 'columns) (counted? v 'lines))
      (assertion-violation who "not a fraction, (columns n), (lines n) or content" v)))

  (define (check-attributes who a)
    (unless (and (list? a) (for-all (lambda (p) (and (pair? p) (symbol? (car p)))) a))
      (assertion-violation who "not an association list of attributes" a))
    (for-each
      (lambda (p)
        (when (memq (car p) '(view buffer depth size))
          (assertion-violation who "an attribute the action sets itself" (car p))))
      a))

  (define (level? node) (split-node? node (buffers:kind-name (buffers:constructor-kind layout:level))))

  (define (split? node) (split-node? node (buffers:kind-name (buffers:constructor-kind container))))

  (define (axis-of side) (if (memq side '(left right)) 'row 'column))

  (define (along? node axis)
    (and (split? node) (eq? (document:node-attribute node 'direction 'row) axis)))

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

  (define (split-holds-placed? node)
    (and (split? node) (exists placed-depth (parts node))))

  (define (leads-to-level? node)
    (or (level? node) (and (split? node) (exists leads-to-level? (parts node)))))

  ;; Only splits are entered, so a level made elsewhere, such as inside
  ;; tabs, is never taken for the user's windows.
  (define (stop-part depth)
    (let loop ([x (car (parts (document:token (buffers:document layout:buffer) 0)))])
      (if (and (split? x) (for-all (lambda (c) (let ([d (placed-depth c)]) (or (not d) (> d depth)))) (parts x)))
          (let ([c (find leads-to-level? (parts x))])
            (if c (loop c) x))
          x)))

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
           [x (stop-part depth)] [p (document:enclosing (buffers:document layout:buffer) (document:node-start x))]
           [main? (or (level? x) (split-holds-placed? x))])
      (cond
        [(and main? (along? x axis) (split-holds-placed? x))
         (insert-at! x (index-in x before? depth) atom)]
        [(and main? (along? p axis))
         (insert-at! p (fx+ (position-of x (parts p)) (if before? 0 1)) atom)]
        [else
         (let* ([d (node-datum x)]
                [place (if (split? p) (filter place-attribute? (datum-attributes d)) '())]
                [bare (with-attributes d (remp place-attribute? (datum-attributes d)))]
                [inner (if main? bare (layout:level '() bare))]
                [beside (lambda (kept) (if before? (list atom kept) (list kept atom)))])
           (buffers:replace! layout:buffer (document:node-start x) (document:node-end x)
             (apply document:from-datum
               (if (along? p axis)
                   (beside (with-attributes inner place))
                   (list (apply container (cons (cons 'direction axis) place) (beside inner)))))))])
      v)))

(import %internals)

(define (%kind) (buffers:kind-name (buffers:constructor-kind container)))

(define (%level-kind) (buffers:kind-name (buffers:constructor-kind layout:level)))

(define (%draw-split node children focused draw-child client)
  (let ([direction (if (column? node) "column" "row")] [part (layout:part-class node)]
        [movable (views:keymap-mark divider-keymap)] [fixed (views:keymap-mark fixed-divider-keymap)]
        [least (least-weight node)])
    (haml (:div.split ([class (if part (string-append direction " " part) direction)])
            (let loop ([cs children] [before '()])
              (if (null? cs)
                  '()
                  (let ([c (car cs)])
                    (cons (haml (:div.split-child ([style "--layout-split-flex:" (flex-text node c least)])
                                  (draw-child c)
                                  (when (pair? (cdr cs))
                                    (%draw-divider node (cadr cs) (if (%movable? node (cons c before) (cdr cs)) movable fixed)))))
                          (loop (cdr cs) (cons c before))))))))))

;; A divider carries the marks of the part after it, as a tab carries its
;; child's, so a press on it names that part.
(define (%draw-divider node next mark)
  (haml (:div.split-divider ([role "separator"] [aria-orientation (if (column? node) "horizontal" "vertical")]
                             [data-at (document:node-start next)] [data-to (document:node-end next)]
                             [data-keymap mark]))))

(define (%movable? split before after)
  (and (not (layout:locked? split)) (pair? (drag-chain split before)) (pair? (drag-chain split after))))

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

;; As Emacs's split-window joins the parent's combination only when it
;; runs along the split, a split takes a part beside the view itself, and
;; leaves a view inside a split of its own to the containers around.
(define (%split-beside node child part direction)
  (and (document:atom? child) (eq? (axis-of direction) (if (column? node) 'column 'row))
       (let ([w (/ (weight child) 2)] [d (node-datum child)])
         (if (memq direction '(right down))
             (list (with-weight d w) (with-weight part w))
             (list (with-weight part w) (with-weight d w))))))

(layout:define-container container
  (draw %draw-split)
  (neighbour %split-neighbour)
  (beside %split-beside)
  (child-attributes weight size)
  (collapse))

(define split-view!
  (case-lambda
    [(view direction) (split-view! view direction #f)]
    [(view direction shown) (%split-view! view direction shown)]))

;; A view made to show a displayed buffer shows it from the start, so its
;; history does not begin with the buffer it was split from.
(define (%split-view! view direction shown)
  (unless (views:view? view)
    (assertion-violation 'layout-split:split-view! "not a view" view))
  (unless (or (not shown) (buffers:buffer? shown))
    (assertion-violation 'layout-split:split-view! "not a buffer" shown))
  (unless (enum-set-member? direction (enum-set-universe (directions)))
    (assertion-violation 'layout-split:split-view! "not a split direction" direction))
  (let ([atom (layout:view-node view)] [b (views:buffer view)])
    (unless atom
      (assertion-violation 'layout-split:split-view! "not a view in the layout" view))
    (when (layout:locked? atom)
      (assertion-violation 'layout-split:split-view! "a locked view" view))
    (unless (or shown b)
      (assertion-violation 'layout-split:split-view! "the view shows no buffer" view))
    (let ([new (views:make (or shown b))])
      (unless shown (views:copy-state! view new))
      (layout:add-beside! view (vector 'views:view (list (cons 'view (views:id new)) (cons 'buffer (buffers:name (or shown b)))))
                          (if (eq? direction 'column) (layout:direction down) (layout:direction right))
                          (lambda (parts) (apply container (list (cons 'direction direction)) parts)))
      new)))

(define (%resize! who axis n sign)
  (unless (and (integer? n) (exact? n))
    (assertion-violation who "not an exact integer" n))
  (let ([atom (layout:view-node (layout:selected-view))] [kind (%kind)])
    (let-values ([(split part) (if atom (holding-split atom kind axis) (values #f #f))])
      (unless split
        (error who (if (eq? axis 'row) "the selected view is in no row split" "the selected view is in no column split")))
      (when (layout:locked? split)
        (error who "a locked part"))
      (let* ([cs (parts split)] [k (length cs)]
             [total (fold-left + 0 (map weight cs))]
             [delta (* sign n total 1/10)])
        (when (fx= k 1)
          (error who "the selected view has no sibling in its split"))
        (let ([weights (map (lambda (c)
                              (if (fx= (document:node-start c) (document:node-start part))
                                  (+ (weight c) delta)
                                  (- (weight c) (/ delta (- k 1)))))
                            cs)])
          (unless (for-all positive? weights)
            (error who "the split cannot change that much"))
          (let ([d (node-datum split)])
            (replace-node! split (cons* (car d) (cadr d) (map with-weight (cddr d) weights)))
            (void)))))))

(define (%display-in b direction)
  (or (layout:reuse-view b)
      (let* ([selected (layout:selected-view)] [atom (layout:view-node selected)])
        (and atom (not (layout:locked? atom))
             (split-view! selected direction b)))))

(define (display-below b)
  (unless (buffers:buffer? b)
    (assertion-violation 'layout-split:display-below "not a buffer" b))
  (%display-in b (direction column)))

(define (display-right b)
  (unless (buffers:buffer? b)
    (assertion-violation 'layout-split:display-right "not a buffer" b))
  (%display-in b (direction row)))

(define (%threshold? v) (or (not v) (and (fixnum? v) (fx> v 0))))

(options:define-option split-width-threshold 160 %threshold?
  "The fewest columns a view needs for layout-split:display-pop-up to split it beside, or #f never to.")

(options:define-option split-height-threshold 80 %threshold?
  "The fewest lines a view needs for layout-split:display-pop-up to split it below, or #f never to, except as the only view of its level.")

;; A part that carries depth was placed at a side by a plugin, as
;; display-at-side places one, and is no window of the user's to split.
(define (%placed? atom level)
  (let ([doc (buffers:document layout:buffer)])
    (let loop ([n atom])
      (cond
        [(or (not n) (fx= (document:node-start n) (document:node-start level))) #f]
        [(document:node-attribute n 'depth #f) #t]
        [else (loop (document:enclosing doc (document:node-start n)))]))))

(define (%size view)
  (let ([client (or (web:current-client)
                    (find (lambda (c) (let-values ([(columns lines) (views:body-size view c)]) columns))
                          (web:clients)))])
    (if client (views:body-size view client) (values #f #f))))

(define (%split-sensibly view alone? b)
  (let-values ([(columns lines) (%size view)])
    (let ([height (split-height-threshold)] [width (split-width-threshold)])
      (cond
        [(and height lines (>= lines height)) (split-view! view (direction column) b)]
        [(and width columns (>= columns width)) (split-view! view (direction row) b)]
        [alone? (split-view! view (direction column) b)]
        [else #f]))))

(define (display-pop-up b)
  (unless (buffers:buffer? b)
    (assertion-violation 'layout-split:display-pop-up "not a buffer" b))
  (or (layout:reuse-view b)
      (let* ([selected (layout:selected-view)] [level (layout:level-of selected)])
        (and level
             (let* ([in-level (filter (lambda (v)
                                        (let ([l (layout:level-of v)] [atom (layout:view-node v)])
                                          (and l (fx= (document:node-start l) (document:node-start level))
                                               (not (layout:locked? atom)) (not (%placed? atom level)))))
                                      (layout:views))]
                    [alone? (and (pair? in-level) (null? (cdr in-level)))]
                    [cells (lambda (v) (let-values ([(columns lines) (%size v)]) (if columns (* columns lines) 0)))]
                    [largest (and (pair? in-level)
                                  (fold-left (lambda (best v) (if (> (cells v) (cells best)) v best)) (car in-level) (cdr in-level)))]
                    [least-recent (find (lambda (v) (memq v in-level)) (reverse (layout:selection-order)))]
                    [made (or (and largest (%split-sensibly largest alone? b))
                              (and least-recent (not (eq? least-recent largest)) (%split-sensibly least-recent alone? b)))])
               made)))
      (layout:use-other-view b)))

(define (%prefix-size) (and (commands:prefix-argument) (commands:prefix-number)))

;; As Emacs's split-window-below sizes its windows, a positive size is the
;; selected view's and a negative one the new view's.
(define (%split-selected! who direction size unit zero-message)
  (unless (or (not size) (and (integer? size) (exact? size)))
    (assertion-violation who "not an exact integer or #f" size))
  (when (eqv? size 0)
    (error who zero-message))
  (let ([v (layout:selected-view)])
    (let ([a (layout:view-node v)])
      (unless (and a (not (layout:locked? a)))
        (error who "a locked part")))
    (unless (views:buffer v)
      (error who "the view shows no buffer"))
    (let ([new (split-view! v direction)])
      (when size
        (layout:set-part-attribute! (if (> size 0) (%part-beside v new) (layout:view-node new)) 'size (list unit (abs size))))
      (void))))

;; The new view may have gone beside a part around the view, such as a
;; strip's column, and the size is that part's.
(define (%part-beside view new)
  (let* ([doc (buffers:document layout:buffer)]
         [beside (document:enclosing doc (document:node-start (layout:view-node new)))])
    (let loop ([n (layout:view-node view)])
      (let ([p (document:enclosing doc (document:node-start n))])
        (if (fx= (document:node-start p) (document:node-start beside)) n (loop p))))))

(commands:define-command (split-below [lines (%prefix-size)])
  "Splits the selected view with a new view below it; with LINES, the prefix argument, the selected view is that many lines high, or the new view when it is negative."
  (%split-selected! 'layout-split:split-below (direction column) lines 'lines "a view cannot be 0 lines high"))

(commands:define-command (split-right [columns (%prefix-size)])
  "Splits the selected view with a new view to its right; with COLUMNS, the prefix argument, the selected view is that many columns wide, or the new view when it is negative."
  (%split-selected! 'layout-split:split-right (direction row) columns 'columns "a view cannot be 0 columns wide"))

(commands:define-command (enlarge [n (commands:prefix-number)])
  "Adds n tenths of its row split's total weight to the part holding the selected view in the innermost row split around it, taken evenly from its siblings."
  (%resize! 'layout-split:enlarge (direction row) n 1))

(commands:define-command (shrink [n (commands:prefix-number)])
  "Takes n tenths of its row split's total weight from the part holding the selected view in the innermost row split around it, given evenly to its siblings."
  (%resize! 'layout-split:shrink (direction row) n -1))

(commands:define-command (enlarge-vertically [n (commands:prefix-number)])
  "Adds n tenths of its column split's total weight to the part holding the selected view in the innermost column split around it, taken evenly from its siblings."
  (%resize! 'layout-split:enlarge-vertically (direction column) n 1))

(commands:define-command (shrink-vertically [n (commands:prefix-number)])
  "Takes n tenths of its column split's total weight from the part holding the selected view in the innermost column split around it, given evenly to its siblings."
  (%resize! 'layout-split:shrink-vertically (direction column) n -1))

(commands:define-command (balance)
  "Sets the weight of every child of every split in the selected view's level to 1, but sized and locked children and the levels inside it."
  (let ([level (layout:level-of (layout:selected-view))])
    (when (and level (not (layout:locked? level)))
      (for-each
        (lambda (child)
          (let* ([d (node-datum child)] [b (balanced d (%kind) (%level-kind))])
            (unless (equal? d b) (replace-node! child b))))
        (parts level)))
    (void)))

(commands:define-command (transpose)
  "Turns each split in the selected view's level between side by side and stacked, leaving as they are its locked parts, its placed parts and the splits holding them, and the levels inside it."
  (let* ([level (layout:level-of (layout:selected-view))]
         [part (and level (not (layout:locked? level)) (car (parts level)))]
         [before (and part (node-datum part))]
         [after (and before (transposed before (%kind) (%level-kind)))])
    (when (equal? before after)
      (error 'layout-split:transpose "no split to transpose in the selected view's level"))
    (replace-node! part after)
    (void)))

(commands:define-command (wrap-in-row)
  "Wraps the selected part in a row split."
  (layout:wrap! (lambda (parts) (apply container '((direction . row)) parts))))

(commands:define-command (wrap-in-column)
  "Wraps the selected part in a column split."
  (layout:wrap! (lambda (parts) (apply container '((direction . column)) parts))))

(define display-at-side
  (case-lambda
    [(side depth size) (display-at-side side depth size '())]
    [(side depth size attributes)
     (unless (enum-set-member? side (enum-set-universe (layout:directions)))
       (assertion-violation 'layout-split:display-at-side "not a direction" side))
     (unless (real? depth)
       (assertion-violation 'layout-split:display-at-side "not a real number" depth))
     (check-size 'layout-split:display-at-side size)
     (check-attributes 'layout-split:display-at-side attributes)
     (lambda (b)
       (unless (buffers:buffer? b)
         (assertion-violation 'layout-split:display-at-side "not a buffer" b))
       (or (layout:find-view b) (place! b side depth size attributes)))]))

(define (minimum part axis)
  (unless (document:node? part)
    (assertion-violation 'layout-split:minimum "not a part" part))
  (unless (enum-set-member? axis (enum-set-universe (directions)))
    (assertion-violation 'layout-split:minimum "not a split direction" axis))
  (let cells ([part part])
    (if (split-node? part (%kind))
        (let ([ms (map cells (parts part))])
          (if (eq? (%axis part) axis) (fold-left + 0 ms) (fold-left max 0 ms)))
        (if (eq? axis 'row) (layout:min-width) (layout:min-height)))))

(define (drag-chain split parts)
  (unless (and (document:node? split) (list? parts) (pair? parts))
    (assertion-violation 'layout-split:drag-chain "not a split and the parts on one side of a divider" split parts))
  (let ([nearest (car parts)])
    (if (or (layout:locked? nearest) (eq? (document:node-attribute nearest 'size #f) 'content))
        '()
        (list nearest))))

;; Stored values are rounded, or each drag would lengthen the exact
;; ratio's denominator in every later layout and window-history step; a
;; part changed by a pixel in tens of thousands still gets a new value.
(define (%rounded x) (rationalize x (/ x 100000)))

(define (scale-size size ratio)
  (unless (and (rational? ratio) (exact? ratio) (positive? ratio))
    (assertion-violation 'layout-split:scale-size "not a positive exact number" ratio))
  (cond
    [(fraction? size) (min 1 (%rounded (* size ratio)))]
    [(or (counted? size 'columns) (counted? size 'lines)) (list (car size) (max 1 (round (* (cadr size) ratio))))]
    [else (assertion-violation 'layout-split:scale-size "not a fraction, (columns n) or (lines n)" size)]))

(define (%axis split) (if (column? split) 'column 'row))

(define (%unit axis) (if (eq? axis 'column) 'lines 'columns))

(define (%size-of d)
  (let ([p (assq 'size (datum-attributes d))]) (and p (cdr p))))

(define (%pressed-divider event)
  (let-values ([(split next) (layout:pressed-part event container)])
    (let ([k (and split (position-of next (parts split)))])
      (if (and k (fx> k 0)) (values split k) (values #f #f)))))

(define (%chain-entries split side chain cs)
  (map (lambda (p)
         (unless (memp (lambda (c) (fx= (document:node-start c) (document:node-start p))) side)
           (assertion-violation 'layout-split:drag-chain "not a part on the divider's side" p))
         (when (eq? (document:node-attribute p 'size #f) 'content)
           (assertion-violation 'layout-split:drag-chain "a part that fits its content" p))
         (list (cons "index" (position-of p cs)) (cons "minimum" (minimum p (%axis split)))
               (cons "counted" (counted? (document:node-attribute p 'size #f) (%unit (%axis split))))))
       chain))

;; A part's weight, fraction or count is proportional to its length
;; along the split, so scaling each changed part by its length's ratio
;; leaves every other part as long as it was. A part that was 0 long has
;; no ratio, so it keeps its value: the space it grew into is what
;; scaling its neighbour freed.
(define (%stored d changes axis)
  (cons* (car d) (cadr d)
         (let loop ([cs (cddr d)] [k 0])
           (if (null? cs)
               '()
               (cons (let ([change (find (lambda (c) (fx= (layout:drag-change-index c) k)) changes)])
                       (if (and change (> (layout:drag-change-old change) 0))
                           (%scaled (car cs) (/ (layout:drag-change-new change) (layout:drag-change-old change)) axis)
                           (car cs)))
                     (loop (cdr cs) (fx+ k 1)))))))

(define (%scaled d ratio axis)
  (let ([size (%size-of d)])
    (if (or (fraction? size) (counted? size (%unit axis)))
        (with-attribute d 'size (scale-size size ratio))
        (with-weight d (%rounded (* (let ([p (assq 'weight (datum-attributes d))]) (if p (positive-weight (cdr p)) 1)) ratio))))))

(define (%drag! who split k clicks client)
  (when (layout:locked? split)
    (error who "a locked part"))
  (let* ([cs (parts split)] [axis (%axis split)]
         [before-side (reverse (list-head cs k))] [after-side (list-tail cs k)]
         [before (drag-chain split before-side)] [after (drag-chain split after-side)])
    (when (and (pair? before) (pair? after))
      (let ([question (list (cons "at" (document:node-start (list-ref cs k))) (cons "clicks" clicks) (cons "index" k)
                            (cons "axis" (symbol->string axis))
                            (cons "before" (list->vector (%chain-entries split before-side before cs)))
                            (cons "after" (list->vector (%chain-entries split after-side after cs))))]
            [indexes (map (lambda (p) (position-of p cs)) (append before after))])
        (layout:ask-drag who client split "layout-split-drag" question indexes
          (lambda (now changes) (replace-node! now (%stored (node-datum now) changes axis))))))))

(commands:define-command (mouse-drag-divider [event (keys:command-event)])
  "Moves the divider pressed as the mouse drags it, and gives the parts on its two sides the lengths reached when the button comes up."
  (let-values ([(split k) (%pressed-divider event)])
    (let ([client (web:current-client)])
      (when (and split client)
        (%drag! 'layout-split:mouse-drag-divider split k (keys:event-clicks event) client)))))

(commands:define-command (mouse-balance [event (keys:command-event)])
  "Sets the weight of every child of the split whose divider was clicked to 1, but sized and locked children."
  (let-values ([(split k) (%pressed-divider event)])
    (when split
      (when (layout:locked? split)
        (error 'layout-split:mouse-balance "a locked part"))
      (let* ([d (node-datum split)] [even (cons* (car d) (cadr d) (map evened (cddr d)))])
        (unless (equal? d even)
          (replace-node! split even))))))

(tables:define-table divider-keymap "The keymap of a divider the mouse can drag.")

(tables:define-table fixed-divider-keymap "The keymap of a divider that cannot move, beside a locked part or one that fits its content.")

(tables:define-table resize-keymap "Keys that go on resizing after C-x {, C-x } or C-x ^.")

(keys:bind! keys:global "C-x 2" split-below)
(keys:bind! keys:global "C-x 3" split-right)
(keys:bind! keys:global "C-x }" enlarge)
(keys:bind! keys:global "C-x {" shrink)
(keys:bind! keys:global "C-x ^" enlarge-vertically)
(keys:bind! keys:global "C-x +" balance)
(keys:bind! keys:global "C-x w t" transpose)

(keys:bind! layout:part-mode-keymap "w r" wrap-in-row)
(keys:bind! layout:part-mode-keymap "w c" wrap-in-column)
(keys:bind! resize-keymap "}" enlarge)
(keys:bind! resize-keymap "{" shrink)
(keys:bind! resize-keymap "^" enlarge-vertically)
(keys:bind! resize-keymap "v" shrink-vertically)
(tables:set! keys:repeat-keymaps resize-keymap)
(options:set! layout:display-action display-pop-up)
(keys:bind! divider-keymap "<down-mouse-1>" mouse-drag-divider)
(keys:bind! divider-keymap "<mouse-1>" keys:ignore)
(keys:bind! divider-keymap "<drag-mouse-1>" keys:ignore)
(keys:bind! divider-keymap "<double-down-mouse-1>" keys:ignore)
(keys:bind! divider-keymap "<double-mouse-1>" mouse-balance)
(keys:bind! fixed-divider-keymap "<down-mouse-1>" keys:ignore)
(keys:bind! fixed-divider-keymap "<mouse-1>" keys:ignore)
(keys:bind! fixed-divider-keymap "<drag-mouse-1>" keys:ignore)
(tables:set! web:stylesheets 'layout-split "layout-split/layout-split.css")
(tables:set! web:scripts 'layout-split "layout-split/layout-split.js")
