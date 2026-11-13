#!tuna
(import (buffers) (document) (views) (keys) (commands) (web) (haml))

(define-enumeration direction (left right up down) directions)

(define-table display-rules
  "Maps a predicate on buffers to the action that shows the buffers it accepts.")

(module %internals
  (check-main-thread check-view check-direction register-container! check-parts check-popup-parts
   the-frame frame-record? open-layout! opened-popups current-index index-atom index-of-id atom-of part-of
   view-of selected-id shown-views select-id! set-zoom! frame-zoom frame-order children root-node
   locked-node? locked-in? title-of draw-layout draw-popups neighbour-of remove-part! bar-view node-datum
   note-batch save-now! focus-keymaps last-selected-unlocked-atom lead-down order-views)

  (define main-thread (get-thread-id))

  (define (check-main-thread who)
    (unless (fx= (get-thread-id) main-thread)
      (assertion-violation who "not on the main thread")))

  (define (check-view who v)
    (unless (views:view? v)
      (assertion-violation who "not a view" v)))

  (define (check-direction who d)
    (unless (enum-set-member? d (enum-set-universe (directions)))
      (assertion-violation who "not a direction" d)))

  ;; Entries made by the configuration outlive a reload of this module,
  ;; so the record type stays the same.
  (define-record-type container
    (nongenerative layout:container/draw/neighbour/child-attributes/collapse/show-focused)
    (sealed #t)
    (fields draw neighbour child-attributes collapse? show-focused?))

  (define-table containers)

  (define (container-entry kind) (table-ref containers kind #f))

  (define (register-container! kind draw neighbour child-attributes collapse? show-focused?)
    (unless (procedure? draw)
      (assertion-violation 'layout:define-container "not a procedure" draw))
    (unless (or (not neighbour) (procedure? neighbour))
      (assertion-violation 'layout:define-container "not a procedure or #f" neighbour))
    (let ([keymap (buffers:kind-keymap (buffers:kind kind))])
      (unless (or (not keymap) (table? keymap))
        (assertion-violation 'layout:define-container "not a keymap or #f" keymap)))
    (table-set! containers kind (make-container draw neighbour child-attributes collapse? show-focused?)))

  (define (attributes? a)
    (and (list? a) (for-all (lambda (p) (and (pair? p) (symbol? (car p)))) a)))

  (define (view-atom-datum? d)
    (and (vector? d) (fx= (vector-length d) 2) (eq? (vector-ref d 0) 'views:view)
         (attributes? (vector-ref d 1))
         (let ([id (assq 'view (vector-ref d 1))]) (and id (fixnum? (cdr id)) (fx> (cdr id) 0)))
         (let ([b (assq 'buffer (vector-ref d 1))]) (and b (string? (cdr b))))))

  (define (part-datum? d known?)
    (or (view-atom-datum? d)
        (and (pair? d) (symbol? (car d)) (pair? (cdr d)) (attributes? (cadr d)) (pair? (cddr d))
             (list? (cddr d)) (known? (car d))
             (for-all (lambda (c) (part-datum? c known?)) (cddr d)))))

  (define (true-attribute? attributes key)
    (let ([p (assq key attributes)]) (and p (cdr p) #t)))

  (define (datum-attributes d) (if (vector? d) (vector-ref d 1) (cadr d)))

  (define (unlocked-view-datum? d)
    (and (not (true-attribute? (datum-attributes d) 'locked))
         (or (vector? d) (exists unlocked-view-datum? (cddr d)))))

  (define (datum-view-ids d acc)
    (if (vector? d)
        (cons (cdr (assq 'view (vector-ref d 1))) acc)
        (fold-left (lambda (acc c) (datum-view-ids c acc)) acc (cddr d))))

  (define (distinct-ids? ids)
    (or (null? ids) (and (not (memv (car ids) (cdr ids))) (distinct-ids? (cdr ids)))))

  ;; Container kinds load after this module, so a saved layout is checked
  ;; for its shape only; an edit is checked against the kinds loaded.
  (define (layout-datum? v)
    (and (part-datum? v (lambda (kind) #t))
         (pair? v) (eq? (car v) 'layout:root)
         (unlocked-view-datum? v)
         (distinct-ids? (datum-view-ids v '()))))

  ;; A consent is not told which buffer it is asked for, so a view number
  ;; already in either tree may be written again only where the edit
  ;; replaces it.
  (define (parts-fit? node edit empty-ok?)
    (let* ([inserted (buffers:edit-inserted edit)] [datums (document:datums inserted)])
      (and (for-all (lambda (d) (part-datum? d container-entry)) datums)
           (or empty-ok?
               (fx> (fx+ (fx- (document:node-end node) (document:node-start node) 2)
                         (fx- (document:length inserted) (document:length (buffers:edit-removed edit))))
                    0))
           (let ([ids (fold-left (lambda (acc d) (datum-view-ids d acc)) '() datums)])
             (and (distinct-ids? ids)
                  (or (not layout-buffer)
                      (let* ([ix (current-index)] [px (popups-index)] [s (buffers:edit-start edit)]
                             [e (fx+ s (document:length (buffers:edit-removed edit)))])
                        (for-all (lambda (id)
                                   (let ([a (index-atom ix id)] [p (index-atom px id)])
                                     (and (or (not a) (holds-range? a s e)) (or (not p) (holds-range? p s e)))))
                                 ids))))))))

  (define (check-parts node edit) (parts-fit? node edit #f))

  (define (check-popup-parts node edit) (parts-fit? node edit #t))

  (define-saved saved-layout #f (lambda (v) (or (not v) (layout-datum? v))))

  (define (frame-state? v)
    (and (list? v) (fx= (length v) 2)
         (list? (car v)) (for-all (lambda (id) (and (fixnum? id) (fx> id 0))) (car v))
         (or (not (cadr v)) (and (fixnum? (cadr v)) (fx> (cadr v) 0)))))

  (define-saved saved-frame '(() #f) frame-state?)

  ;; A frame keeps the views in the order they were last selected, the
  ;; selected one first, and nothing per container: a container's focused
  ;; child is the child holding the first of them, so selecting a view
  ;; focuses every container on its path, and deleting one leaves no
  ;; stale focus.
  (define-record-type frame-record
    (sealed #t)
    (fields (mutable order) (mutable zoom)))

  (define the-frame (make-frame-record (car (saved-frame)) (cadr (saved-frame))))

  (define (frame-zoom) (current-index) (frame-record-zoom the-frame))

  (define (frame-order) (current-index) (frame-record-order the-frame))

  (define layout-buffer #f)
  (define popups-buffer #f)
  (define saved-key #f)
  (define frame-dirty? #f)
  (define known-ids '())

  (define (layout-doc) (buffers:document layout-buffer))

  (define (popups-doc) (buffers:document popups-buffer))

  ;; Each node is known by its start, which no other node of a document
  ;; shares.
  (define-record-type index
    (sealed #t)
    (fields doc atom-list ids kids parents))

  (define last-index #f)
  (define last-popups-index #f)

  (define (view-atom? n)
    (and (document:atom? n) (eq? (document:node-kind n) 'views:view)))

  (define (atom-id n)
    (let ([id (document:node-attribute n 'view)])
      (and (fixnum? id) (fx> id 0) id)))

  (define (node-children node)
    (if (document:atom? node)
        '()
        (let ([acc '()])
          (document:for-each-child node (fx+ (document:node-start node) 1) (fx- (document:node-end node) 1)
            (lambda (c at) (when (document:node? c) (set! acc (cons c acc)))))
          (reverse acc))))

  (define (build-index doc)
    (let ([ids (make-eqv-hashtable)] [kids (make-eqv-hashtable)] [parents (make-eqv-hashtable)])
      (let ([atoms (let walk ([n (document:token doc 0)] [acc '()])
                     (cond
                       [(view-atom? n)
                        (let ([id (atom-id n)])
                          (when (and id (not (hashtable-contains? ids id))) (hashtable-set! ids id n)))
                        (cons n acc)]
                       [else
                        (let ([cs (node-children n)])
                          (hashtable-set! kids (document:node-start n) cs)
                          (for-each (lambda (c) (hashtable-set! parents (document:node-start c) n)) cs)
                          (fold-left (lambda (acc c) (walk c acc)) acc cs))]))])
        (for-each
          (lambda (a)
            (unless (views:find (atom-id a))
              (views:atom-view a)
              (hashtable-set! registered (atom-id a) #t)))
          atoms)
        (make-index doc (reverse atoms) ids kids parents))))

  ;; The frame is checked against each new document when it is first
  ;; read, not in an edit's hook, so a quit landing in the check leaves it
  ;; to be made again at the next read.
  (define synced-doc #f)
  (define synced-popups-doc #f)

  (define (current-index)
    (let ([doc (layout-doc)] [popups (popups-doc)])
      (unless (and last-index (eq? (index-doc last-index) doc))
        (set! last-index (build-index doc)))
      (unless (and last-popups-index (eq? (index-doc last-popups-index) popups))
        (set! last-popups-index (build-index popups)))
      (unless (and (eq? synced-doc doc) (eq? synced-popups-doc popups))
        (fix-frame! last-index last-popups-index)
        (set! synced-doc doc)
        (set! synced-popups-doc popups))
      last-index))

  (define (popups-index) (current-index) last-popups-index)

  (define (index-atom ix id) (hashtable-ref (index-ids ix) id #f))

  (define (index-of-id id)
    (let ([ix (current-index)])
      (cond
        [(index-atom ix id) ix]
        [(index-atom last-popups-index id) last-popups-index]
        [else #f])))

  (define (atom-of id)
    (let ([ix (index-of-id id)]) (and ix (index-atom ix id))))

  (define (index-atoms) (index-atom-list (current-index)))

  (define (root-node) (document:token (layout-doc) 0))

  (define (kids-of ix n) (hashtable-ref (index-kids ix) (document:node-start n) '()))

  (define (parent-in ix n) (hashtable-ref (index-parents ix) (document:node-start n) #f))

  (define (children n) (kids-of (current-index) n))


  ;; views:atom-view takes the first atom it is given in a batch for a
  ;; view's own, and gives a later one at another place a copy, so an atom
  ;; moved by an edit after it would draw a copy. Layout gives each view's
  ;; atom to views:atom-view once: where it makes a view an atom names and
  ;; views lacks, and at the end of the batch that made the atom, so that
  ;; views saves the view.
  (define registered (make-eqv-hashtable))

  (define (view-of atom)
    (or (views:find (atom-id atom))
        (begin
          (hashtable-set! registered (atom-id atom) #t)
          (views:atom-view atom))))

  (define (token-like doc node)
    (let* ([s (document:node-start node)] [t (and (fx< s (document:length doc)) (document:token doc s))])
      (and (document:node? t) (fx= (document:node-end t) (document:node-end node))
           (eq? (document:node-kind t) (document:node-kind node))
           (or (view-atom? t) (not (document:atom? t)))
           t)))

  (define (first-view-id n)
    (if (document:atom? n)
        (and (view-atom? n) (atom-id n))
        (let ([found #f])
          (document:for-each-child n (fx+ (document:node-start n) 1) (fx- (document:node-end n) 1)
            (lambda (c at) (when (and (not found) (document:node? c)) (set! found (first-view-id c)))))
          found)))

  ;; A node does not tell its document, and the two trees can each hold
  ;; a part of one kind at the same range; the views in it, numbered
  ;; uniquely across both, tell them apart.
  (define (part-of who node)
    (unless (document:node? node)
      (assertion-violation who "not a node" node))
    (let* ([ix (current-index)] [px last-popups-index]
           [t (token-like (index-doc ix) node)] [p (token-like (index-doc px) node)])
      (cond
        [(and t p) (if (eqv? (first-view-id node) (first-view-id p)) (values px p) (values ix t))]
        [t (values ix t)]
        [p (values px p)]
        [else (assertion-violation who "not a part of the layout" node)])))

  (define (selected-id) (current-index) (car (frame-record-order the-frame)))

  (define (holds? n p) (and (fx<= (document:node-start n) p) (fx< p (document:node-end n))))

  (define (zoom-position)
    (let ([z (frame-zoom)])
      (and z (let ([a (index-atom (current-index) z)]) (and a (document:node-start a))))))

  (define (pinned? n) (document:node-attribute n 'pinned #f))

  (define (locked-in? ix n)
    (let loop ([n n])
      (and n (or (and (document:node-attribute n 'locked #f) #t) (loop (parent-in ix n))))))

  (define (locked-node? n) (locked-in? (current-index) n))

  (define (shown-children ix node zoom-at)
    (let ([cs (kids-of ix node)])
      (if (and zoom-at (holds? node zoom-at) (not (fx= zoom-at (document:node-start node))))
          (filter (lambda (c) (or (holds? c zoom-at) (pinned? c))) cs)
          cs)))

  (define (shows-focused? n)
    (let ([entry (kind-entry n)]) (and entry (container-show-focused? entry))))

  (define (focused-or-first ix node shown)
    (let ([f (focused-child ix node)])
      (or (and f (find (lambda (c) (fx= (document:node-start c) (document:node-start f))) shown))
          (car shown))))

  (define (atoms-under zoom-at visible?)
    (let ([ix (current-index)])
      (reverse
        (let walk ([n (root-node)] [acc '()])
          (if (view-atom? n)
              (cons n acc)
              (let ([shown (shown-children ix n zoom-at)])
                (fold-left (lambda (acc c) (walk c acc)) acc
                  (if (and visible? (pair? shown) (shows-focused? n)) (list (focused-or-first ix n shown)) shown))))))))

  (define-record-type shown-entry
    (sealed #t)
    (fields index zoom-at atoms))

  (define zoom-cache (make-shown-entry #f #f '()))

  ;; Selecting a view in a part its container hides shows that part, so
  ;; whether a selection ends the zoom asks only what the zoom leaves.
  (define (shown-atoms)
    (let* ([ix (current-index)] [zoom-at (zoom-position)])
      (unless (and (eq? (shown-entry-index zoom-cache) ix) (eqv? (shown-entry-zoom-at zoom-cache) zoom-at))
        (set! zoom-cache (make-shown-entry ix zoom-at (atoms-under zoom-at #f))))
      (shown-entry-atoms zoom-cache)))

  (define-record-type visible-entry
    (sealed #t)
    (fields index zoom-at order atoms))

  (define visible-cache (make-visible-entry #f #f #f '()))

  (define (visible-atoms)
    (let* ([ix (current-index)] [zoom-at (zoom-position)] [order (frame-record-order the-frame)])
      (unless (and (eq? (visible-entry-index visible-cache) ix) (eqv? (visible-entry-zoom-at visible-cache) zoom-at)
                   (eq? (visible-entry-order visible-cache) order))
        (set! visible-cache (make-visible-entry ix zoom-at order (atoms-under zoom-at #t))))
      (visible-entry-atoms visible-cache)))

  (define (shown-views) (map view-of (visible-atoms)))

  (define-record-type focus-entry
    (sealed #t)
    (fields index order table))

  (define focus-cache (make-focus-entry #f #f #f))
  (define popups-focus-cache (make-focus-entry #f #f #f))

  ;; The first view of the order inside a container leads to it through
  ;; every container above it, so a later one stops where it meets one
  ;; known.
  (define (focus-table ix)
    (let ([order (frame-record-order the-frame)]
          [cache (if (eq? ix last-popups-index) popups-focus-cache focus-cache)])
      (if (and (eq? (focus-entry-index cache) ix) (eq? (focus-entry-order cache) order))
          (focus-entry-table cache)
          (let ([t (make-eqv-hashtable)])
            (for-each
              (lambda (id)
                (let ([a (index-atom ix id)])
                  (when a
                    (let climb ([child a])
                      (let ([p (parent-in ix child)])
                        (when (and p (not (hashtable-contains? t (document:node-start p))))
                          (hashtable-set! t (document:node-start p) child)
                          (climb p)))))))
              order)
            (if (eq? ix last-popups-index)
                (set! popups-focus-cache (make-focus-entry ix order t))
                (set! focus-cache (make-focus-entry ix order t)))
            t))))

  (define (focused-child ix node)
    (hashtable-ref (focus-table ix) (document:node-start node) #f))

  (define (lead-down ix n)
    (if (document:atom? n)
        (and (view-atom? n) n)
        (let ([c (or (focused-child ix n) (let ([cs (kids-of ix n)]) (and (pair? cs) (car cs))))])
          (and c (lead-down ix c)))))

  (define (set-order! order)
    (unless (equal? order (frame-record-order the-frame))
      (frame-record-order-set! the-frame order)
      (set! frame-dirty? #t)))

  (define (set-zoom! z)
    (unless (eqv? z (frame-record-zoom the-frame))
      (frame-record-zoom-set! the-frame z)
      (set! frame-dirty? #t)))

  ;; Popups are drawn over the whole layout, zoomed or not.
  (define (select-id! id)
    (unless (or (index-atom (popups-index) id) (exists (lambda (a) (eqv? (atom-id a) id)) (shown-atoms)))
      (set-zoom! #f))
    (set-order! (cons id (remv id (frame-record-order the-frame)))))

  ;; A deleted view leaves the order, so the first view left is where the
  ;; focused children lead from the root.
  (define (fix-frame! ix px)
    (let* ([order (filter (lambda (id) (or (index-atom ix id) (index-atom px id))) (frame-record-order the-frame))])
      (set-order!
        (if (null? order)
            (let ([a (or (lead-down ix (root-node)) (car (index-atom-list ix)))]) (list (atom-id a)))
            order))
      (unless (and (frame-record-zoom the-frame) (index-atom ix (frame-record-zoom the-frame)))
        (set-zoom! #f))))

  (define (title-of ix n)
    (let ([title (document:node-attribute n 'title #f)])
      (cond
        [(string? title) title]
        [(view-atom? n)
         (let* ([v (view-of n)] [b (views:buffer v)])
           (if b (buffers:name b) (let ([name (document:node-attribute n 'buffer "")]) (if (string? name) name ""))))]
        [else
         (let ([c (or (focused-child ix n) (let ([cs (kids-of ix n)]) (and (pair? cs) (car cs))))])
           (if c (title-of ix c) ""))])))

  ;; A popup is drawn outside the layout's screen view, so its element
  ;; carries no positions, which would name the layout's.
  (define (draw-view-atom atom selected client marks?)
    (let ([v (view-of atom)])
      (haml (:div.layout-view ([class (and (eqv? (atom-id atom) selected) "selected")]
                               [data-at (and marks? (document:node-start atom))]
                               [data-to (and marks? (document:node-end atom))])
              (views:draw v client)))))

  (define (draw-plain shown draw-child)
    (haml (:div.layout-part (map draw-child shown))))

  (define (draw-tree ix root zoom-at client)
    (let ([selected (selected-id)] [marks? (eq? ix last-index)])
      (let draw ([n root])
        (cond
          [(view-atom? n) (draw-view-atom n selected client marks?)]
          [(document:atom? n) '()]
          [else
           (let* ([shown (shown-children ix n zoom-at)]
                  [entry (container-entry (document:node-kind n))]
                  [draw-child (lambda (c)
                                (unless (and (document:node? c) (exists (lambda (s) (fx= (document:node-start s) (document:node-start c))) shown))
                                  (assertion-violation 'layout:screen "not a child to show" c))
                                (draw c))])
             (if entry
                 (guard (c [(not (quit-condition? c)) (report c) (draw-plain shown draw)])
                   ((container-draw entry) n shown (focused-child ix n) draw-child client))
                 (draw-plain shown draw)))]))))

  (define (draw-layout client)
    (draw-tree (current-index) (root-node) (zoom-position) client))

  (define (draw-popups client)
    (let ([px (popups-index)])
      (if (null? (index-atom-list px))
          '()
          (draw-tree px (document:token (popups-doc) 0) #f client))))

  (define (kind-entry n) (and (not (document:atom? n)) (container-entry (document:node-kind n))))

  ;; A kind may name the siblings in a cycle, so a walk across locked
  ;; views stops where it started.
  (define (neighbour-of ix atom direction)
    (let up ([n atom])
      (let ([p (parent-in ix n)])
        (and p
             (let ([entry (kind-entry p)])
               (let across ([child n])
                 (let ([sibling (and entry (container-neighbour entry)
                                     ((container-neighbour entry) p child direction))])
                   (cond
                     [(not sibling) (up p)]
                     [(not (and (document:node? sibling)
                                (exists (lambda (c) (fx= (document:node-start c) (document:node-start sibling))) (kids-of ix p))))
                      (assertion-violation 'layout:neighbour "a kind's neighbour is not a child of its container" sibling)]
                     [(fx= (document:node-start sibling) (document:node-start n)) #f]
                     [else
                      (let ([a (lead-down ix sibling)])
                        (if (and a (not (locked-in? ix a))) (view-of a) (across sibling)))]))))))))

  (define (node-datum ix n)
    (car (document:datums (document:slice (index-doc ix) (document:node-start n) (document:node-end n)))))

  (define (with-attributes d attributes)
    (if (vector? d) (vector (vector-ref d 0) attributes) (cons* (car d) attributes (cddr d))))

  (define (unlocked-atoms-outside s e)
    (exists (lambda (a) (and (not (holds-range? a s e)) (not (locked-node? a)))) (index-atoms)))

  (define (holds-range? a s e) (and (fx<= s (document:node-start a)) (fx<= (document:node-end a) e)))

  ;; Removing and collapsing are one edit, so one undo restores both. The
  ;; popups may all go; the layout keeps a view that is not locked.
  (define (remove-part! ix node)
    (let ([layout? (eq? ix (current-index))])
      (let loop ([n node])
        (let ([p (parent-in ix n)] [b (if layout? layout-buffer popups-buffer)])
          (when (not p)
            (assertion-violation 'layout:delete-part! "the root" node))
          (if (and (parent-in ix p) (null? (cdr (kids-of ix p))))
              (loop p)
              (let ([s (document:node-start n)] [e (document:node-end n)])
                (unless (or (not layout?) (unlocked-atoms-outside s e))
                  (assertion-violation 'layout:delete-part! "the last view that is not locked" node))
                (let ([others (remp (lambda (c) (fx= (document:node-start c) s)) (kids-of ix p))]
                      [entry (kind-entry p)] [grand (parent-in ix p)])
                  (if (and grand entry (container-collapse? entry) (fx= (length others) 1))
                      ;; A part's pinned attribute, like its kind's child
                      ;; attributes, belongs to its place, which the child
                      ;; takes.
                      (let* ([child (car others)] [d (node-datum ix child)]
                             [own (container-child-attributes entry)]
                             [place (cons 'pinned (let ([g (kind-entry grand)]) (if g (container-child-attributes g) '())))]
                             [kept (remp (lambda (a) (or (memq (car a) own) (memq (car a) place))) (datum-attributes d))]
                             [moved (filter (lambda (a) (memq (car a) place)) (datum-attributes (node-datum ix p)))])
                        (buffers:replace! b (document:node-start p) (document:node-end p)
                          (with-attributes d (append kept moved))))
                      (buffers:replace! b s e "")))))))))

  (define (bar-view b)
    (let* ([root (root-node)] [bars (cdr (children root))])
      (or (exists (lambda (c) (and (view-atom? c) (let ([v (view-of c)]) (and (eq? (views:buffer v) b) v)))) bars)
          (let ([v (views:make b)] [at (fx- (document:node-end root) 1)])
            (buffers:replace! layout-buffer at at
              (vector 'views:view (list (cons 'view (views:id v)) (cons 'buffer (buffers:name b))
                                        '(pinned . #t) '(locked . #t))))
            v))))

  (define (focus-keymaps)
    (let* ([id (selected-id)] [ix (index-of-id id)] [atom (index-atom ix id)]
           [inner (views:keymaps (view-of atom))])
      (let loop ([n (parent-in ix atom)] [acc '()])
        (if n
            (loop (parent-in ix n)
                  (let* ([kind (buffers:kind (document:node-kind n))] [k (and kind (buffers:kind-keymap kind))])
                    (if k (cons k acc) acc)))
            (append inner (reverse acc))))))

  (define (order-views)
    (let ([ix (current-index)] [px last-popups-index])
      (fold-right
        (lambda (id acc)
          (let ([a (or (index-atom ix id) (index-atom px id))]) (if a (cons (view-of a) acc) acc)))
        '() (frame-record-order the-frame))))

  ;; An atom names its buffer so that a view restarts on it; the view's
  ;; buffer may have changed since the atom was written.
  (define (current-datum)
    (let refresh ([d (node-datum (current-index) (root-node))])
      (if (vector? d)
          (let* ([id (cdr (assq 'view (vector-ref d 1)))] [v (views:find id)] [b (and v (views:buffer v))])
            (if b
                (vector 'views:view (map (lambda (a) (if (eq? (car a) 'buffer) (cons 'buffer (buffers:name b)) a))
                                         (vector-ref d 1)))
                d))
          (cons* (car d) (cadr d) (map refresh (cddr d))))))

  (define (save-key)
    (cons (layout-doc)
          (map (lambda (a)
                 (let* ([v (views:find (atom-id a))] [b (and v (views:buffer v))])
                   (and b (buffers:name b))))
               (index-atoms))))

  (define (save-now!)
    (let ([key (save-key)])
      (unless (and saved-key (eq? (car key) (car saved-key)) (equal? (cdr key) (cdr saved-key)))
        (let ([d (current-datum)])
          (unless (equal? d (saved-layout))
            (set-saved! saved-layout d)))
        (set! saved-key key)))
    ;; Popups are never saved, so neither are their places in the order.
    (when frame-dirty?
      (let* ([ix (current-index)]
             [state (list (filter (lambda (id) (index-atom ix id)) (frame-record-order the-frame))
                          (frame-record-zoom the-frame))])
        (unless (equal? state (saved-frame))
          (set-saved! saved-frame state)))
      (set! frame-dirty? #f)))

  ;; Views whose atoms left the layout are dropped once the batch ends, so
  ;; a part moved by two edits keeps its views.
  (define (note-batch)
    (let ([ids (map atom-id (append (index-atoms) (index-atom-list (popups-index))))])
      (for-each
        (lambda (id)
          (unless (memv id ids)
            (let ([v (views:find id)]) (when v (views:drop! v)))))
        known-ids)
      (set! known-ids ids)
      (for-each
        (lambda (a)
          (unless (hashtable-contains? registered (atom-id a))
            (views:atom-view a)
            (hashtable-set! registered (atom-id a) #t)))
        (index-atoms))
      (vector-for-each
        (lambda (id) (unless (memv id ids) (hashtable-delete! registered id)))
        (hashtable-keys registered)))
    (save-now!))

  (define (last-selected-unlocked-atom node)
    (let ([atoms (filter (lambda (a)
                           (and (holds-range? a (document:node-start node) (document:node-end node))
                                (not (locked-node? a))))
                         (index-atoms))])
      (or (exists (lambda (id) (find (lambda (a) (eqv? (atom-id a) id)) atoms)) (frame-order))
          (and (pair? atoms) (car atoms)))))

  (define (first-buffer)
    (find (lambda (b) (not (member (buffers:name b) '("*layout*" "*popups*")))) (buffers:all)))

  (define (default-datum)
    (let* ([b (or (first-buffer) (buffers:make "*scratch*" ""))] [v (views:make b)])
      (list 'layout:root '()
            (vector 'views:view (list (cons 'view (views:id v)) (cons 'buffer (buffers:name b)))))))

  (define (opened-popups) popups-buffer)

  (define (open-layout! popups-root)
    (set! layout-buffer
      (or (buffers:find "*layout*")
          (buffers:make "*layout*" (or (saved-layout) (default-datum)))))
    (set! popups-buffer (or (buffers:find "*popups*") (buffers:make "*popups*" popups-root)))
    (set! known-ids (map atom-id (append (index-atoms) (index-atom-list (popups-index)))))
    layout-buffer)

  (record-writer (record-type-descriptor frame-record)
    (lambda (f p wr) (display "#<frame>" p))))

(import %internals)

(define-syntax define-container
  (lambda (x)
    (define (invalid c) (syntax-violation 'layout:define-container "invalid clause" x c))
    (syntax-case x ()
      [(_ id clause ...)
       (identifier? #'id)
       (let loop ([clauses #'(clause ...)] [seen '()] [draw #f] [neighbour #'#f] [keymap #'#f]
                  [attributes '()] [collapse #'#f] [show-focused #'#f])
         (if (null? clauses)
             (begin
               (unless draw
                 (syntax-violation 'layout:define-container "a draw clause is required" x))
               #`(begin
                   (buffers:define-kind id (content nodes) (consent check-parts) (keymap #,keymap))
                   (define-values ()
                     (begin
                       (register-container! (car (id '())) #,draw #,neighbour '#,(datum->syntax #'id attributes)
                                            #,collapse #,show-focused)
                       (values)))))
             (let* ([c (car clauses)]
                    [name (syntax-case c () [(k . _) (identifier? #'k) (syntax->datum #'k)] [_ (invalid c)])])
               (when (memq name seen)
                 (syntax-violation 'layout:define-container "clause given twice" x c))
               (let ([seen (cons name seen)] [rest (cdr clauses)])
                 (define (expression)
                   (syntax-case c () [(_ e) #'e] [_ (invalid c)]))
                 (define (flag)
                   (syntax-case c () [(_) #'#t] [_ (invalid c)]))
                 (case name
                   [(draw) (loop rest seen (expression) neighbour keymap attributes collapse show-focused)]
                   [(neighbour) (loop rest seen draw (expression) keymap attributes collapse show-focused)]
                   [(keymap) (loop rest seen draw neighbour (expression) attributes collapse show-focused)]
                   [(child-attributes)
                    (syntax-case c ()
                      [(_ a ...) (for-all identifier? #'(a ...))
                       (loop rest seen draw neighbour keymap (syntax->datum #'(a ...)) collapse show-focused)]
                      [_ (invalid c)])]
                   [(collapse) (loop rest seen draw neighbour keymap attributes (flag) show-focused)]
                   [(show-focused) (loop rest seen draw neighbour keymap attributes collapse (flag))]
                   [else (invalid c)])))))]
      [_ (syntax-violation 'layout:define-container "expected (layout:define-container id clause ...)" x)])))

(define (frame client)
  (unless (web:client? client)
    (assertion-violation 'layout:frame "not a client" client))
  the-frame)

(define (frame? v) (frame-record? v))

(define (call-with-frame frame thunk)
  (unless (frame-record? frame)
    (assertion-violation 'layout:call-with-frame "not a frame" frame))
  (unless (procedure? thunk)
    (assertion-violation 'layout:call-with-frame "not a procedure" thunk))
  (check-main-thread 'layout:call-with-frame)
  (views:call-with-view (selected-view frame) thunk))

(define (current-frame) the-frame)

(define (screen client)
  (unless (web:client? client)
    (assertion-violation 'layout:screen "not a client" client))
  (check-main-thread 'layout:screen)
  (haml (:div.layout-screen ([data-view (views:id screen-view)] [data-version (buffers:version buffer)]
                             [data-showing (views:shown-count screen-view)])
          (draw-layout client)
          (draw-popups client))))

(define selected-view
  (case-lambda
    [() (selected-view (current-frame))]
    [(frame)
     (unless (frame-record? frame)
       (assertion-violation 'layout:selected-view "not a frame" frame))
     (check-main-thread 'layout:selected-view)
     (view-of (atom-of (selected-id)))]))

(define (select! view)
  (check-view 'layout:select! view)
  (check-main-thread 'layout:select!)
  (let ([id (views:id view)])
    (unless (atom-of id)
      (assertion-violation 'layout:select! "not a view in the layout" view))
    (select-id! id)
    (void)))

(define zoomed-view
  (case-lambda
    [() (zoomed-view (current-frame))]
    [(frame)
     (unless (frame-record? frame)
       (assertion-violation 'layout:zoomed-view "not a frame" frame))
     (check-main-thread 'layout:zoomed-view)
     (let ([z (frame-zoom)])
       (and z (view-of (index-atom (current-index) z))))]))

(define views
  (case-lambda
    [() (views (current-frame))]
    [(frame)
     (unless (frame-record? frame)
       (assertion-violation 'layout:views "not a frame" frame))
     (check-main-thread 'layout:views)
     (shown-views)]))

(define (neighbour view direction)
  (check-view 'layout:neighbour view)
  (check-direction 'layout:neighbour direction)
  (check-main-thread 'layout:neighbour)
  (let* ([id (views:id view)] [ix (index-of-id id)])
    (unless ix
      (assertion-violation 'layout:neighbour "not a view in the layout" view))
    (neighbour-of ix (index-atom ix id) direction)))

(define selection-order
  (case-lambda
    [() (selection-order (current-frame))]
    [(frame)
     (unless (frame-record? frame)
       (assertion-violation 'layout:selection-order "not a frame" frame))
     (check-main-thread 'layout:selection-order)
     (order-views)]))

(define (%draw-root node shown focused draw-child client)
  (let ([parts (if (null? shown)
                   '()
                   (cons (haml (:div.layout-main (draw-child (car shown))))
                         (map (lambda (c) (haml (:div.layout-bar (draw-child c)))) (cdr shown))))])
    (haml (:div.layout-root parts))))

(define (%root-neighbour node child direction)
  (let ([cs (children node)] [at (document:node-start child)])
    (case direction
      [(down) (let ([m (memp (lambda (c) (fx= (document:node-start c) at)) cs)]) (and m (pair? (cdr m)) (cadr m)))]
      [(up) (let loop ([cs cs] [before #f])
              (cond
                [(null? cs) #f]
                [(fx= (document:node-start (car cs)) at) before]
                [else (loop (cdr cs) (car cs))]))]
      [else #f])))

(define-table keymap "The keymap of the layout's root, for mouse keys on the layout's own drawing.")

(define-container root (draw %draw-root) (neighbour %root-neighbour) (keymap keymap))

(define (%draw-popups node shown focused draw-child client)
  (haml (:div.layout-popups (map draw-child shown))))

;; Popups come and go, so their root may be empty.
(buffers:define-kind popups-root (content nodes) (consent check-popup-parts))

(define-values ()
  (begin (register-container! (car (popups-root '())) %draw-popups #f '() #f #f) (values)))

(define buffer (open-layout! (popups-root '())))

(define popups-buffer (opened-popups))

;; The layout's own drawing is a view of its buffer that no part shows,
;; so a click on it is a mouse key at a position in the buffer.
(define screen-view (views:make buffer))

(define (view-node view)
  (check-view 'layout:view-node view)
  (check-main-thread 'layout:view-node)
  (index-atom (current-index) (views:id view)))

(define (part-view node)
  (check-main-thread 'layout:part-view)
  (let-values ([(ix n) (part-of 'layout:part-view node)])
    (view-of (lead-down ix n))))

(define (part-title node)
  (check-main-thread 'layout:part-title)
  (let-values ([(ix n) (part-of 'layout:part-title node)])
    (title-of ix n)))

(define (locked? node)
  (check-main-thread 'layout:locked?)
  (let-values ([(ix n) (part-of 'layout:locked? node)])
    (locked-in? ix n)))

(define (%delete! ix node)
  (when (locked-in? ix node)
    (assertion-violation 'layout:delete-part! "a locked part" node))
  (remove-part! ix node)
  (void))

(define (delete-part! node)
  (check-main-thread 'layout:delete-part!)
  (let-values ([(ix n) (part-of 'layout:delete-part! node)])
    (%delete! ix n)))

(define (add-bar! b)
  (unless (buffers:buffer? b)
    (assertion-violation 'layout:add-bar! "not a buffer" b))
  (check-main-thread 'layout:add-bar!)
  (bar-view b))

(define (%check-action-result who result)
  (unless (or (not result) (views:view? result))
    (assertion-violation who "an action returned what is not a view or #f" result))
  (unless (or (not result) (atom-of (views:id result)))
    (assertion-violation who "an action returned a view not in the layout" result))
  result)

(define (reuse-view b)
  (unless (buffers:buffer? b)
    (assertion-violation 'layout:reuse-view "not a buffer" b))
  (check-main-thread 'layout:reuse-view)
  (let ([shown (filter (lambda (v) (eq? (views:buffer v) b)) (views))])
    (cond
      [(null? shown) #f]
      [(memq (selected-view) shown) (selected-view)]
      [else (car shown)])))

(define (use-other-view b)
  (unless (buffers:buffer? b)
    (assertion-violation 'layout:use-other-view "not a buffer" b))
  (or (reuse-view b)
      (let* ([selected (selected-view)]
             [candidates (filter (lambda (v) (not (or (eq? v selected) (locked-node? (view-node v))))) (views))]
             [order (frame-order)]
             [age (lambda (v) (let ([m (memv (views:id v) order)]) (if m (length m) 0)))])
        (and (pair? candidates)
             (let ([v (fold-left (lambda (best v) (if (< (age v) (age best)) v best)) (car candidates) (cdr candidates))])
               (views:set-buffer! v b)
               v)))))

(define-option display-action use-other-view procedure?
  "The action layout:display-buffer tries after the rules and the caller's.")

(define display-buffer
  (case-lambda
    [(b) (display-buffer b #f)]
    [(b action)
     (unless (buffers:buffer? b)
       (assertion-violation 'layout:display-buffer "not a buffer" b))
     (unless (or (not action) (procedure? action))
       (assertion-violation 'layout:display-buffer "not a procedure" action))
     (check-main-thread 'layout:display-buffer)
     (or (exists (lambda (rule)
                   (and ((car rule) b) (%check-action-result 'layout:display-buffer ((cdr rule) b))))
                 (reverse (table-entries display-rules)))
         (and action (%check-action-result 'layout:display-buffer (action b)))
         (%check-action-result 'layout:display-buffer ((display-action) b))
         (let ([v (selected-view)])
           (unless (eq? (views:buffer v) b) (views:set-buffer! v b))
           v))]))

(define (switch-to-buffer b)
  (unless (buffers:buffer? b)
    (assertion-violation 'layout:switch-to-buffer "not a buffer" b))
  (let* ([v (selected-view)] [ix (index-of-id (views:id v))])
    (if (locked-in? ix (index-atom ix (views:id v)))
        (select! (display-buffer b))
        (unless (eq? (views:buffer v) b) (views:set-buffer! v b)))))

(commands:define-command (other-view)
  "Selects the next view the frame shows that is not locked, after the selected one, cyclically."
  (let* ([shown (views)] [selected (selected-view)]
         [after (let ([m (memq selected shown)])
                  (if m (append (cdr m) (list-head shown (fx- (length shown) (length m)))) shown))])
    (let ([next (find (lambda (v) (not (or (eq? v selected) (locked-node? (view-node v))))) after)])
      (when next (select! next)))))

(commands:define-command (delete-view)
  "Deletes the selected view's part."
  (let* ([id (views:id (selected-view))] [ix (index-of-id id)])
    (%delete! ix (index-atom ix id))))

(commands:define-command (zoom)
  "Zooms the frame to the selected view; when zoomed, shows the whole layout again."
  (set-zoom! (and (not (frame-zoom)) (view-node (selected-view)) (views:id (selected-view))))
  (void))

(commands:define-command (mouse-select-view [event (keys:command-event)])
  "Selects the view that the part clicked in the layout's drawing leads to through focused children, unless it is locked."
  (unless (keys:event? event)
    (assertion-violation 'layout:mouse-select-view "not an event" event))
  (let* ([posn (keys:event-start event)] [v (views:posn-view posn)] [p (views:posn-point posn)])
    (when (and v p (eq? (views:buffer v) buffer))
      (let* ([doc (buffers:document buffer)]
             [t (and (fx< p (document:length doc)) (document:token doc p))]
             [part (if (and (document:node? t) (document:atom? t)) t (document:enclosing doc p))]
             [atom (and part (lead-down (current-index) part))])
        (when (and atom (not (locked-node? atom)))
          (select! (view-of atom)))))))

(define (%select-toward direction)
  (let ([v (neighbour (selected-view) direction)])
    (when v (select! v))))

(commands:define-command (select-left)
  "Selects the neighbour of the selected view to the left."
  (%select-toward (direction left)))

(commands:define-command (select-right)
  "Selects the neighbour of the selected view to the right."
  (%select-toward (direction right)))

(commands:define-command (select-up)
  "Selects the neighbour of the selected view above."
  (%select-toward (direction up)))

(commands:define-command (select-down)
  "Selects the neighbour of the selected view below."
  (%select-toward (direction down)))

(commands:define-command (reset-layout)
  "Makes the root's first part the view in it selected last that is not locked, keeping the bars."
  (let ([main (car (children (root-node)))])
    (when (locked-node? main)
      (assertion-violation 'layout:reset-layout "a locked part" main))
    (let ([atom (last-selected-unlocked-atom main)])
      (unless atom
        (assertion-violation 'layout:reset-layout "no view that is not locked in the root's first part" main))
      (let* ([v (view-of atom)]
             [name (let ([b (views:buffer v)]) (if b (buffers:name b) (document:node-attribute atom 'buffer "")))]
             [d (vector 'views:view (list (cons 'view (views:id v)) (cons 'buffer name)))])
        (set-zoom! #f)
        (unless (equal? (node-datum (current-index) main) d)
          (buffers:replace! buffer (document:node-start main) (document:node-end main) d))
        (select! v)))))

(define (%handle-key client item)
  (call-with-frame (frame client)
    (lambda () (keys:press! client (keys:item-key item)))))

(define (%focus-keymaps client posn) (if posn '() (focus-keymaps)))

(define (%keep-layout b) (not (or (eq? b buffer) (eq? b popups-buffer))))

(keys:bind! keys:global "C-x o" other-view)
(keys:bind! keys:global "C-x 0" delete-view)
(keys:bind! keys:global "C-x 1" zoom)
(keys:bind! keys:global "s-i" select-up)
(keys:bind! keys:global "s-j" select-left)
(keys:bind! keys:global "s-k" select-down)
(keys:bind! keys:global "s-l" select-right)
(keys:bind! keys:global "s-<up>" select-up)
(keys:bind! keys:global "s-<left>" select-left)
(keys:bind! keys:global "s-<down>" select-down)
(keys:bind! keys:global "s-<right>" select-right)
(keys:bind! keymap "<mouse-1>" mouse-select-view)
(keys:bind! keymap "<down-mouse-1>" keys:ignore)
(add-hook! keys:find-keymaps %focus-keymaps)
(add-hook! buffers:kill-queries %keep-layout)
(table-set! web:input-handlers "key" %handle-key)
(table-set! web:stylesheets 'layout "layout/layout.css")
;; A raise in note-batch must not skip the advice it encloses, which
;; ends the batch for the plugins loaded before this one.
(advice-add! batch-ended (lambda (ended) (guard (c [#t (report c)]) (note-batch)) (ended)))
(on-unload save-now!)
(on-unload (lambda () (views:drop! screen-view)))
