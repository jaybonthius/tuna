#!tuna
(import (layout) (buffers) (document) (views) (keys) (commands) (web) (haml))

(module %internals
  (parts float-node? holding-float place-of base-of base-child? length-css view-datum by-use)

  (define (parts node)
    (let ([acc '()])
      (document:for-each-child node (fx+ (document:node-start node) 1) (fx- (document:node-end node) 1)
        (lambda (c at) (when (document:node? c) (set! acc (cons c acc)))))
      (reverse acc)))

  (define (float-node? node kind)
    (and node (not (document:atom? node)) (eq? (document:node-kind node) kind)))

  (define (fraction? v) (and (real? v) (exact? v) (<= 0 v 1)))

  ;; A place that is not one of the two forms is read as the centre, so
  ;; a hand-edited layout still draws.
  (define (place-of node)
    (let ([p (document:node-attribute node 'place #f)])
      (cond
        [(not p) #f]
        [(and (list? p) (fx= (length p) 3) (eq? (car p) 'box) (fraction? (cadr p)) (fraction? (caddr p))) p]
        [(and (list? p) (fx= (length p) 2) (eq? (car p) 'anchor) (fixnum? (cadr p))) p]
        [else '(box 1/2 1/2)])))

  (define (base-of cs) (find (lambda (c) (not (place-of c))) cs))

  (define (base-child? cs child)
    (let ([b (base-of cs)])
      (and b (fx= (document:node-start b) (document:node-start child)))))

  (define (holding-float atom kind)
    (let ([doc (buffers:document layout:buffer)])
      (let climb ([child atom])
        (let ([n (document:enclosing doc (document:node-start child))])
          (cond
            [(not n) (values #f #f)]
            [(float-node? n kind) (values n child)]
            [else (climb n)])))))

  ;; A size in columns or lines is the view's, so the float's border is
  ;; added to it: a border taken from it would leave the view short of its
  ;; last line, and a view following point there would scroll.
  (define (length-css v)
    (cond
      [(and (real? v) (exact? v) (< 0 v) (<= v 1)) (string-append (number->string (inexact (* 100 v))) "%")]
      [(and (list? v) (fx= (length v) 2) (memq (car v) '(columns lines)) (fixnum? (cadr v)) (fx> (cadr v) 0))
       (string-append "calc(" (number->string (cadr v)) (if (eq? (car v) 'columns) "ch" "lh") " + var(--layout-float-frame))")]
      [else "50%"]))

  (define (view-ids node)
    (if (document:atom? node)
        (let ([id (document:node-attribute node 'view #f)]) (if id (list id) '()))
        (fold-right (lambda (c acc) (append (view-ids c) acc)) '() (parts node))))

  ;; Floats from the one drawn on top: the one holding the view selected
  ;; last first, a locked view counting, since a float whose selected view
  ;; is locked is still the one in use; then those never used, the later
  ;; above the earlier, as the page stacks them.
  (define (by-use floats)
    (let* ([order (map views:id (layout:selection-order))]
           [keyed (map (lambda (c)
                         (cons c (let ([ids (view-ids c)])
                                   (let loop ([os order] [k 0])
                                     (cond
                                       [(null? os) #f]
                                       [(memv (car os) ids) k]
                                       [else (loop (cdr os) (fx+ k 1))])))))
                       floats)])
      (append (map car (list-sort (lambda (a b) (fx< (cdr a) (cdr b))) (filter cdr keyed)))
              (reverse (map car (remp cdr keyed))))))

  (define (view-datum v . attributes)
    (vector 'views:view (cons* (cons 'view (views:id v)) (cons 'buffer (buffers:name (views:buffer v))) attributes))))

(import %internals)

(define (%kind) (buffers:kind-name (buffers:constructor-kind container)))

;; Each module that shows popups has an entry of the numbers of their
;; views, so that they go when it unloads; a number outlives a view
;; dropped meanwhile. A module that does not import this one may unload
;; after this one, when this one's definitions raise; so this one, as it
;; unloads, removes every popup and sets each entry's numbers to #f, and
;; the entry's unload action then does nothing.
(define %made '())

(define (%forget-made! v)
  (let ([id (views:id v)])
    (for-each (lambda (e) (set-cdr! e (remv id (cdr e)))) %made)))

(define (%size? v)
  (or (and (real? v) (exact? v) (< 0 v) (<= v 1))
      (and (list? v) (fx= (length v) 2) (memq (car v) '(columns lines)) (fixnum? (cadr v)) (fx> (cadr v) 0))))

(define (%extent? v)
  (or (eq? v 'content) (%size? v)))

;; Raising a float changes its z-index and not its place in the page, so
;; its element is never moved.
(define (%stacking floats)
  (let loop ([ranked (by-use floats)] [z (length floats)] [acc '()])
    (if (null? ranked) acc (loop (cdr ranked) (fx- z 1) (cons (cons (car ranked) z) acc)))))

(define (%float-html c place z draw-child)
  (let* ([width (document:node-attribute c 'width 1/2)]
         [w (if (eq? width 'content) "fit-content" (length-css width))]
         [height (document:node-attribute c 'height 1/2)]
         [h (if (eq? height 'content) "auto" (length-css height))]
         [classes (string-append (if (eq? width 'content) " float-content-inline-size" "")
                                 (if (eq? height 'content) " float-content-block-size" ""))])
    (if (eq? (car place) 'anchor)
        (haml (:div ([class "float-child anchored" classes]
                     [style "--layout-float-anchor:--view-anchor-" (cadr place) ";--layout-float-inline-size:" w
                            ";--layout-float-block-size:" h ";--layout-float-z:" z])
                (draw-child c)))
        (let ([x (number->string (inexact (cadr place)))] [y (number->string (inexact (caddr place)))])
          (haml (:div ([class "float-child" classes]
                       [style "--layout-float-inline-size:" w ";--layout-float-block-size:" h
                              ";--layout-float-x:" x ";--layout-float-y:" y ";--layout-float-z:" z])
                  (draw-child c)))))))

(define (%draw-float node children focused draw-child client)
  (let* ([base (base-of children)]
         [base-html (and base (draw-child base))]
         [floats (remq base children)]
         [z (%stacking floats)])
    ;; A popup's anchor counts as drawn only once its view is, and a popup
    ;; anchored in another popup comes after it, so floats are drawn in
    ;; order. An anchor's number does not outlive the process, so a float
    ;; whose anchor is unknown is drawn at the centre, not hidden while it
    ;; can be selected.
    (let loop ([fs floats] [acc '()])
      (if (null? fs)
          (haml (:div.float ([class (layout:part-class node)]) (when base-html (haml (:div.float-base base-html))) (reverse acc)))
          (let* ([c (car fs)] [p (place-of c)]
                 [anchor (and p (eq? (car p) 'anchor) (views:find-anchor (cadr p)))]
                 [place (if (or anchor (and p (eq? (car p) 'box))) p '(box 1/2 1/2))])
            (loop (cdr fs)
                  (if (and anchor (not (views:anchor-drawn? anchor client)))
                      acc
                      (cons (%float-html c place (cdr (assq c z)) draw-child) acc))))))))

(define (%float-neighbour node child direction)
  (and (memq direction '(left right))
       (let ([cs (parts node)])
         (and (not (base-child? cs child))
              (let loop ([fs (remq (base-of cs) cs)] [previous #f])
                (cond
                  [(null? fs) #f]
                  [(fx= (document:node-start (car fs)) (document:node-start child))
                   (if (eq? direction 'left) previous (and (pair? (cdr fs)) (cadr fs)))]
                  [else (loop (cdr fs) (car fs))]))))))

(define-table keymap "The keymap of float containers: keys that act on the floats around the selected view.")

;; A part moved into a desktop without a base would otherwise become its
;; base and fill it.
(define (%adopt node d)
  (if (assq 'place (if (vector? d) (vector-ref d 1) (cadr d)))
      d
      (if (vector? d)
          (vector (vector-ref d 0) (append (vector-ref d 1) '((place box 1/2 1/2))))
          (cons* (car d) (append (cadr d) '((place box 1/2 1/2))) (cddr d)))))

(layout:define-container container
  (draw %draw-float)
  (neighbour %float-neighbour)
  (keymap keymap)
  (child-attributes place width height)
  (adopt %adopt))

(define (%popups-container)
  (let ([root (document:token (buffers:document layout:popups-buffer) 0)])
    (find (lambda (c) (float-node? c (%kind))) (parts root))))

(define (%add-popup! datum)
  (let ([c (%popups-container)])
    (if c
        (let ([at (fx- (document:node-end c) 1)])
          (buffers:replace! layout:popups-buffer at at datum))
        (let ([at (fx- (document:node-end (document:token (buffers:document layout:popups-buffer) 0)) 1)])
          (buffers:replace! layout:popups-buffer at at (container '() datum))))))

(define (%popup-atom-of id)
  (let ([c (%popups-container)])
    (and c (find (lambda (a) (and (document:atom? a) (eqv? (document:node-attribute a 'view) id)))
                 (parts c)))))

(define (%popup-atom view) (%popup-atom-of (views:id view)))

(define (%popup-of b anchored?)
  (find (lambda (v)
          (let ([a (%popup-atom v)])
            (and a (eq? (eq? (car (place-of a)) 'anchor) anchored?))))
        (views:showing b)))

(define (%shown? view) (or (layout:view-node view) (%popup-atom view)))

(define (%remove-anchor-of! atom)
  (let ([p (place-of atom)])
    (when (and p (eq? (car p) 'anchor))
      (let ([a (views:find-anchor (cadr p))]) (when a (views:remove-anchor! a))))))

(define (%remove-popup! atom)
  (%remove-anchor-of! atom)
  (let ([c (%popups-container)])
    (if (null? (cdr (parts c)))
        (buffers:replace! layout:popups-buffer (document:node-start c) (document:node-end c) "")
        (buffers:replace! layout:popups-buffer (document:node-start atom) (document:node-end atom) ""))))

;; A popup anchored in another popup must come after it to be drawn, so
;; a popup that changes goes to the end.
(define (%replace-popup! atom d)
  (let* ([end (fx- (document:node-end (%popups-container)) 1)]
         [later (document:datums (document:slice (buffers:document layout:popups-buffer) (document:node-end atom) end))])
    (buffers:replace! layout:popups-buffer (document:node-start atom) end
      (apply document:from-datum (append later (list d))))))

(define (%remove-popups!)
  (let ([c (%popups-container)])
    (when c
      (for-each %remove-anchor-of! (parts c))
      (buffers:replace! layout:popups-buffer (document:node-start c) (document:node-end c) ""))))

(define (%unmade! e)
  (set! %made (remq e %made))
  (for-each (lambda (id) (let ([a (%popup-atom-of id)]) (when a (%remove-popup! a)))) (cdr e)))

;; Called before the popup is added, and the unload action is registered
;; before its entry is kept, so a quit between any two steps leaves at
;; worst a number or an action with nothing to remove.
(define (%note-made! v)
  (let ([e (or (assoc (current-owner) %made)
               (let ([e (list (current-owner))])
                 (on-unload (lambda () (when (cdr e) (%unmade! e))))
                 (set! %made (cons e %made))
                 e))])
    (set-cdr! e (cons (views:id v) (cdr e)))))

(define (%check-extent who v)
  (unless (%extent? v)
    (assertion-violation who "not a fraction, (columns n), (lines n) or content" v)))

(define (show-at! view position b width height)
  (unless (views:view? view)
    (assertion-violation 'layout-float:show-at! "not a view" view))
  (unless (buffers:buffer? b)
    (assertion-violation 'layout-float:show-at! "not a buffer" b))
  (%check-extent 'layout-float:show-at! width)
  (%check-extent 'layout-float:show-at! height)
  (unless (%shown? view)
    (assertion-violation 'layout-float:show-at! "not a view in the layout or a popup" view))
  (unless (and (fixnum? position) (fx<= 0 position (document:length (buffers:document (views:buffer view)))))
    (assertion-violation 'layout-float:show-at! "not a position in the view's buffer" position))
  (let* ([old (%popup-of b #t)]
         [atom (and old (%popup-atom old))]
         [anchor (and atom (views:find-anchor (cadr (place-of atom))))])
    (if (and anchor (eq? (views:anchor-view anchor) view)
             (equal? (document:node-attribute atom 'width) width) (equal? (document:node-attribute atom 'height) height))
        (begin (views:move-anchor! anchor position) old)
        (let ([v (or old (views:make b))])
          (when anchor (views:remove-anchor! anchor))
          (let ([d (view-datum v (list 'place 'anchor (views:anchor-id (views:add-anchor! view position)))
                               (cons 'width width) (cons 'height height) '(locked . #t))])
            (if atom
                (%replace-popup! atom d)
                (begin (%note-made! v) (%add-popup! d)))
            v)))))

(define (close! view)
  (unless (views:view? view)
    (assertion-violation 'layout-float:close! "not a view" view))
  (let ([atom (%popup-atom view)])
    (unless atom
      (assertion-violation 'layout-float:close! "not a popup" view))
    (%forget-made! view)
    (%remove-popup! atom)
    (void)))

(define display-palette
  (case-lambda
    [(b) (display-palette b '(lines 12))]
    [(b height)
     (unless (buffers:buffer? b)
       (assertion-violation 'layout-float:display-palette "not a buffer" b))
     (%check-extent 'layout-float:display-palette height)
     (or (%popup-of b #f)
         (let ([v (views:make b)])
           (%note-made! v)
           (%add-popup! (view-datum v '(place box 1/2 1/5) '(width . 3/5) (cons 'height height) '(locked . #t)))
           v))]))

(define (%orphan? atom)
  (let ([p (place-of atom)])
    (and p (eq? (car p) 'anchor)
         (let ([a (views:find-anchor (cadr p))])
           (not (and a (%shown? (views:anchor-view a))))))))

;; A popup goes once its anchor goes, or the anchor's view leaves the
;; layout and the popups, whatever edit or reload did it, not only after
;; commands. Removing one may leave another anchored in it.
(define (%sweep)
  (let loop ()
    (let* ([c (%popups-container)] [orphan (and c (find %orphan? (parts c)))])
      (when orphan
        (let ([v (views:find (document:node-attribute orphan 'view))])
          (when v (%forget-made! v)))
        (%remove-popup! orphan)
        (loop)))))

(define (%selected-float)
  (let ([atom (layout:view-node (layout:selected-view))])
    (let-values ([(f child) (if atom (holding-float atom (%kind)) (values #f #f))])
      (values atom f child))))

(commands:define-command (toggle)
  "Floats the selected view in the middle of the float container around it, or around its level's part; on a float, puts its buffer where layout:display-buffer shows it."
  (let ([v (layout:selected-view)])
    (let-values ([(atom f child) (%selected-float)])
      (unless atom
        (assertion-violation 'layout-float:toggle "the selected view is a popup"))
      (when (layout:locked? atom)
        (assertion-violation 'layout-float:toggle "a locked view" v))
      (if (and child (not (base-child? (parts f) child)))
          (let ([b (views:buffer v)] [p (views:point v)])
            (layout:delete-part! atom)
            (let ([shown (layout:display-buffer b)])
              (views:set-point! shown p)
              (layout:select! shown)))
          (let* ([new (views:make (views:buffer v))]
                 [d (view-datum new '(place box 1/2 1/2) '(width . 1/2) '(height . 1/2))])
            (views:set-point! new (views:point v))
            (if f
                (let ([at (fx- (document:node-end f) 1)]) (buffers:replace! layout:buffer at at d))
                (let* ([doc (buffers:document layout:buffer)]
                       [main (car (parts (layout:level-of v)))])
                  (buffers:replace! layout:buffer (document:node-start main) (document:node-end main)
                    (container '() (car (document:datums (document:slice doc (document:node-start main) (document:node-end main))))
                               d))))
            (layout:delete-part! (layout:view-node v))
            (layout:select! new))))))

(commands:define-command (cycle)
  "Selects the most recently used view of the float drawn on top, or, from a float, of the base, unless it is locked."
  (let-values ([(atom f child) (%selected-float)])
    (when f
      (let* ([cs (parts f)] [base (base-of cs)] [on-base? (base-child? cs child)]
             [others (filter (lambda (c) (not (eq? (eq? c base) on-base?))) cs)]
             [v (exists (lambda (c)
                          (let ([v (layout:part-view c)])
                            (and (not (layout:locked? (layout:view-node v))) v)))
                        (by-use others))])
        (when v (layout:select! v))))))

(commands:define-command (wrap-in-float)
  "Wraps the selected part in a float container, as its base."
  (layout:wrap! (lambda (parts) (apply container '() parts))))

(on-unload
  (lambda ()
    (for-each (lambda (e) (set-cdr! e #f)) %made)
    (set! %made '())
    (%remove-popups!)))
(keys:bind! keys:global "s-v" toggle)
(keys:bind! layout:part-mode-keymap "w f" wrap-in-float)
(keys:bind! keymap "s-V" cycle)
(table-set! web:stylesheets 'layout-float "layout-float/layout-float.css")
(advice-add! batch-ended
  (lambda (ended)
    (guard (c [#t (report c)]) (as-module (this-module) (%sweep)))
    (ended)))
