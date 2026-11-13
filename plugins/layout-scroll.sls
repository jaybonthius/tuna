#!tuna
(import (layout) (layout-split) (buffers) (document) (views) (keys) (commands) (web) (haml))

(define (%size? v) (and (real? v) (exact? v) (< 0 v) (<= v 1)))

(define-option default-size 1/2 %size?
  "The size of a new column, as an exact fraction of its strip's length.")

(define-option size-presets '(1/3 1/2 2/3) (lambda (v) (and (list? v) (pair? v) (for-all %size? v)))
  "The sizes layout-scroll:cycle-size steps through, smallest first.")

(module %internals
  (parts strip-node? holding-strip child-holding position-of size-of row? item-id datum-of replace-node! with-size cross-direction
   scroller-of strip-of-scroller forget-strips!)

  (define (parts node)
    (let ([acc '()])
      (document:for-each-child node (fx+ (document:node-start node) 1) (fx- (document:node-end node) 1)
        (lambda (c at) (when (document:node? c) (set! acc (cons c acc)))))
      (reverse acc)))

  (define (strip-node? node kind)
    (and node (not (document:atom? node)) (eq? (document:node-kind node) kind)))

  (define (holding-strip atom kind)
    (let ([doc (buffers:document layout:buffer)])
      (let climb ([child atom])
        (let ([n (document:enclosing doc (document:node-start child))])
          (cond
            [(not n) (values #f #f)]
            [(strip-node? n kind) (values n child)]
            [else (climb n)])))))

  (define (child-holding node atom)
    (let ([doc (buffers:document layout:buffer)] [start (document:node-start node)])
      (let climb ([child atom])
        (let ([n (document:enclosing doc (document:node-start child))])
          (if (fx= (document:node-start n) start) child (climb n))))))

  (define (position-of child cs)
    (let loop ([cs cs] [k 0])
      (if (fx= (document:node-start (car cs)) (document:node-start child)) k (loop (cdr cs) (fx+ k 1)))))

  (define (size-of node)
    (let ([s (document:node-attribute node 'size #f)])
      (if (%size? s) s (default-size))))

  (define (row? node) (not (eq? (document:node-attribute node 'direction 'row) 'column)))

  (define (cross-direction node) (if (row? node) 'column 'row))

  (define (item-id child) (views:id (layout:part-view child)))

  (define (datum-of node)
    (car (document:datums (document:slice (buffers:document layout:buffer)
                                          (document:node-start node) (document:node-end node)))))

  (define (replace-node! node content)
    (buffers:replace! layout:buffer (document:node-start node) (document:node-end node) content))

  (define (datum-attributes d) (if (vector? d) (vector-ref d 1) (cadr d)))

  (define (with-size d size)
    (let ([others (remp (lambda (a) (eq? (car a) 'size)) (datum-attributes d))]
          [size (if size (list (cons 'size size)) '())])
      (if (vector? d)
          (vector (vector-ref d 0) (append others size))
          (cons* (car d) (append others size) (cddr d)))))

  ;; Each strip's scroller is found by an anchor right after the strip's
  ;; opening, which follows edits around it and reports the strip's
  ;; deletion.
  (define strips '())

  (define (live-strips)
    (set! strips
      (filter (lambda (e)
                (or (not (buffers:anchor-deleted? (car e)))
                    (begin (views:drop-scroller! (cdr e)) #f)))
              strips))
    strips)

  (define (scroller-of node on-rest)
    (let ([at (fx+ (document:node-start node) 1)])
      (cond
        [(find (lambda (e) (fx= (buffers:anchor-position (car e)) at)) (live-strips)) => cdr]
        [else
         (let ([s (views:make-scroller on-rest)])
           (set! strips (cons (cons (buffers:anchor layout:buffer at) s) strips))
           s)])))

  (define (strip-of-scroller s)
    (let ([e (find (lambda (e) (eq? (cdr e) s)) (live-strips))])
      (and e (let ([n (document:enclosing (buffers:document layout:buffer) (buffers:anchor-position (car e)))])
               (and n (fx= (fx+ (document:node-start n) 1) (buffers:anchor-position (car e))) n)))))

  (define (forget-strips!)
    (for-each (lambda (e) (views:drop-scroller! (cdr e))) strips)
    (set! strips '())))

(import %internals)

(define (%kind) (car (container '())))

(define (%focused focused children)
  (or (and focused (find (lambda (c) (fx= (document:node-start c) (document:node-start focused))) children))
      (car children)))

(define (%rested scroller client item alignment focus)
  (let ([node (strip-of-scroller scroller)])
    (when node
      (let ([child (find (lambda (c) (eqv? (item-id c) focus)) (parts node))])
        (when child
          (let ([v (layout:part-view child)])
            (unless (layout:locked? (layout:view-node v))
              (layout:select! v))))))))

;; Columns not drawn are placeholders of their own size, so the strip's
;; length is exact on every client.
(define (%drawn-ids children focus client scroller)
  (or (let ([in-view (views:scroller-in-view scroller client)]) (and in-view (cons focus in-view)))
      (let ([ids (map item-id children)] [sizes (map size-of children)])
        (define (filling ids sizes)
          (let loop ([ids ids] [sizes sizes] [total 0])
            (if (or (null? ids) (>= total 1)) '() (cons (car ids) (loop (cdr ids) (cdr sizes) (+ total (car sizes)))))))
        (let loop ([ids ids] [sizes sizes] [before-ids '()] [before-sizes '()])
          (cond
            [(null? ids) (list focus)]
            [(eqv? (car ids) focus)
             (cons focus (append (filling before-ids before-sizes) (filling (cdr ids) (cdr sizes))))]
            [else (loop (cdr ids) (cdr sizes) (cons (car ids) before-ids) (cons (car sizes) before-sizes))])))))

(define (%draw-strip node children focused draw-child client)
  (let* ([scroller (scroller-of node %rested)]
         [center? (eq? (document:node-attribute node 'center 'never) 'always)]
         [shown (%focused focused children)]
         [focus (item-id shown)])
    (unless (eqv? (views:scroller-focus scroller) focus)
      (views:place-scroller! scroller focus (if center? (views:scroller-align center) (views:scroller-align nearest)) focus))
    (let ([drawn (%drawn-ids children focus client scroller)])
      (views:draw-scroller scroller client (if (row? node) (views:axis row) (views:axis column))
        (string-append "layout-strip " (if (row? node) "row" "column") (if center? " center" ""))
        (map (lambda (c)
               (let ([id (item-id c)])
                 (haml (:div.strip-item ([data-item id] [style "--strip-size:" (number->string (inexact (size-of c)))])
                         (if (memv id drawn)
                             (draw-child c)
                             (haml (:div.strip-placeholder ([data-at (document:node-start c)] [data-to (document:node-end c)])
                                     (layout:part-title c))))
                         (:span.strip-end)))))
             children)))))

(define (%strip-neighbour node child direction)
  (let-values ([(before after) (if (row? node) (values 'left 'right) (values 'up 'down))])
    (let loop ([cs (parts node)] [previous #f])
      (cond
        [(null? cs) #f]
        [(fx= (document:node-start (car cs)) (document:node-start child))
         (cond
           [(eq? direction before) previous]
           [(eq? direction after) (and (pair? (cdr cs)) (cadr cs))]
           [else #f])]
        [else (loop (cdr cs) (car cs))]))))

(define-table keymap "The keymap of strips: keys that act on the column holding the selected view.")

(layout:define-container container
  (draw %draw-strip)
  (neighbour %strip-neighbour)
  (keymap keymap)
  (child-attributes size))

(define (%selected-strip who)
  (let ([atom (layout:view-node (layout:selected-view))])
    (let-values ([(strip column) (if atom (holding-strip atom (%kind)) (values #f #f))])
      (unless strip
        (assertion-violation who "the selected view is in no strip"))
      (values strip column))))

(define (%check-unlocked who node)
  (when (layout:locked? node)
    (assertion-violation who "a locked part" node)))

(define (%unlocked-column who)
  (let-values ([(strip column) (%selected-strip who)])
    (%check-unlocked who column)
    (values strip column)))

(define (%select-column! column)
  (let ([v (layout:part-view column)])
    (unless (layout:locked? (layout:view-node v))
      (layout:select! v))))

(define (%new-view-datum b)
  (let ([v (views:make b)])
    (values v (vector 'views:view (list (cons 'view (views:id v)) (cons 'buffer (buffers:name b)))))))

(define (add-column! view b)
  (unless (views:view? view)
    (assertion-violation 'layout-scroll:add-column! "not a view" view))
  (unless (buffers:buffer? b)
    (assertion-violation 'layout-scroll:add-column! "not a buffer" b))
  (let ([atom (layout:view-node view)])
    (unless atom
      (assertion-violation 'layout-scroll:add-column! "not a view in the layout" view))
    (let-values ([(strip column) (holding-strip atom (%kind))])
      (unless strip
        (assertion-violation 'layout-scroll:add-column! "the view is in no strip" view))
      (when (layout:locked? strip)
        (assertion-violation 'layout-scroll:add-column! "a locked part" strip))
      (let-values ([(new d) (%new-view-datum b)])
        (let ([at (document:node-end column)])
          (buffers:replace! layout:buffer at at (with-size d (default-size))))
        new))))

;; Unlike most display actions this one selects: a strip scrolls to its
;; focused column, so a new column not selected may be out of view.
(define (display-in-new-column b)
  (unless (buffers:buffer? b)
    (assertion-violation 'layout-scroll:display-in-new-column "not a buffer" b))
  (let* ([selected (layout:selected-view)] [atom (layout:view-node selected)])
    (and atom (not (layout:locked? atom))
         (let-values ([(strip column) (holding-strip atom (%kind))])
           (and strip (not (layout:locked? strip))
                (let ([new (add-column! selected b)])
                  (layout:select! new)
                  new))))))

(commands:define-command (first)
  "Selects the first column of the strip holding the selected view."
  (let-values ([(strip column) (%selected-strip 'layout-scroll:first)])
    (%select-column! (car (parts strip)))))

(commands:define-command (last)
  "Selects the last column of the strip holding the selected view."
  (let-values ([(strip column) (%selected-strip 'layout-scroll:last)])
    (%select-column! (car (reverse (parts strip))))))

(commands:define-command (center)
  "Scrolls the strip holding the selected view so that its column is in the middle."
  (let-values ([(strip column) (%selected-strip 'layout-scroll:center)])
    (let ([id (item-id column)])
      (views:place-scroller! (scroller-of strip %rested) id (views:scroller-align center) id))))

(define (%set-size! who size)
  (let-values ([(strip column) (%unlocked-column who)])
    (replace-node! column (with-size (datum-of column) size))))

;; From a size between presets the next larger one, as Niri cycles.
(define (%cycle-size! who forward?)
  (let-values ([(strip column) (%selected-strip who)])
    (let* ([now (size-of column)] [presets (size-presets)]
           [next (if forward?
                     (or (find (lambda (p) (> p now)) presets) (car presets))
                     (or (find (lambda (p) (< p now)) (reverse presets)) (car (reverse presets))))])
      (%set-size! who next))))

(commands:define-command (cycle-size)
  "Gives the column holding the selected view the next of layout-scroll:size-presets."
  (%cycle-size! 'layout-scroll:cycle-size #t))

(commands:define-command (cycle-size-back)
  "Gives the column holding the selected view the previous of layout-scroll:size-presets."
  (%cycle-size! 'layout-scroll:cycle-size-back #f))

(commands:define-command (full-size)
  "Makes the column holding the selected view as long as its strip; again, gives it layout-scroll:default-size."
  (let-values ([(strip column) (%selected-strip 'layout-scroll:full-size)])
    (%set-size! 'layout-scroll:full-size (if (= (size-of column) 1) (default-size) 1))))

;; A column of a row strip is a column split, and of a column strip a row
;; split, so its views lie across the strip.
(define (%column-of datums strip size)
  (with-size (apply layout-split:container (list (cons 'direction (cross-direction strip)))
                    (map (lambda (d) (with-size d #f)) datums))
             size))

(define (%split-of column strip)
  (and (not (document:atom? column))
       (eq? (document:node-kind column) (car (layout-split:container '())))
       (eq? (document:node-attribute column 'direction 'row) (cross-direction strip))))

(commands:define-command (consume)
  "Moves the column after the one holding the selected view into it, at its end."
  (let-values ([(strip column) (%unlocked-column 'layout-scroll:consume)])
    (let ([next (let ([m (list-tail (parts strip) (position-of column (parts strip)))])
                  (and (pair? (cdr m)) (cadr m)))])
      (when next
        (%check-unlocked 'layout-scroll:consume next)
        (let* ([d (datum-of column)] [moved (with-size (datum-of next) #f)]
               [merged (if (%split-of column strip)
                           (append d (list moved))
                           (%column-of (list d moved) strip (size-of column)))])
          (buffers:replace! layout:buffer (document:node-start column) (document:node-end next)
                            (document:from-datum merged)))))))

;; Layout removes the part, so the column collapses and sheds child
;; attributes exactly as its kind declares; the part's views outlive the
;; removal only because the part comes back in the same batch. A quit
;; between the two edits would lose the part, and Tuna's dynamic-wind
;; holds quits off while its in runs.
(define (%move-out! who column k toward-end?)
  (let ([cs (parts column)])
    (when (pair? (cdr cs))
      (let* ([part (list-ref cs k)]
             [out (with-size (datum-of part) (default-size))]
             [start (document:node-start column)]
             [selected (layout:selected-view)])
        (%check-unlocked who part)
        (dynamic-wind
          (lambda ()
            (layout:delete-part! part)
            (let ([at (if toward-end? (document:node-end (document:token (buffers:document layout:buffer) start)) start)])
              (buffers:replace! layout:buffer at at out)))
          void void)
        (when (layout:view-node selected)
          (layout:select! selected))))))

(commands:define-command (expel)
  "Moves the last part of the column holding the selected view out of it, into a new column after it."
  (let-values ([(strip column) (%unlocked-column 'layout-scroll:expel)])
    (unless (document:atom? column)
      (%move-out! 'layout-scroll:expel column (fx- (length (parts column)) 1) #t))))

(define (%consume-or-expel! who toward-end?)
  (let-values ([(strip column) (%unlocked-column who)])
    (let ([atom (layout:view-node (layout:selected-view))])
      (if (fx= (document:node-start atom) (document:node-start column))
          (let* ([cs (parts strip)]
                 [j (let ([k (position-of column cs)]) (if toward-end? (fx+ k 1) (fx- k 1)))])
            (when (and (fx>= j 0) (fx< j (length cs)))
              (let ([other (list-ref cs j)])
                (%check-unlocked who other)
                (let* ([od (datum-of other)] [moved (with-size (datum-of column) #f)]
                       [merged (if (%split-of other strip)
                                   (append od (list moved))
                                   (%column-of (list od moved) strip (size-of other)))]
                       [lead (if toward-end? column other)] [trail (if toward-end? other column)])
                  (buffers:replace! layout:buffer (document:node-start lead) (document:node-end trail)
                                    (document:from-datum merged))))))
          (%move-out! who column (position-of (child-holding column atom) (parts column)) toward-end?)))))

(commands:define-command (consume-or-expel-left)
  "Moves the selected view into the column before its own when it is alone there, else the part of its column holding it out into a new column before it."
  (%consume-or-expel! 'layout-scroll:consume-or-expel-left #f))

(commands:define-command (consume-or-expel-right)
  "Moves the selected view into the column after its own when it is alone there, else the part of its column holding it out into a new column after it."
  (%consume-or-expel! 'layout-scroll:consume-or-expel-right #t))

(keys:bind! keymap "s-," consume)
(keys:bind! keymap "s-." expel)
(keys:bind! keymap "s-[" consume-or-expel-left)
(keys:bind! keymap "s-]" consume-or-expel-right)
(keys:bind! keymap "s-c" center)
(keys:bind! keymap "s-r" cycle-size)
(keys:bind! keymap "s-R" cycle-size-back)
(keys:bind! keymap "C-s-f" full-size)
(keys:bind! keymap "s-<home>" first)
(keys:bind! keymap "s-<end>" last)
(table-set! web:stylesheets 'layout-scroll "layout-scroll/layout-scroll.css")
(on-unload forget-strips!)
