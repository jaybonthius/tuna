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
   note-batch save-now! selected-keymaps enclosing-keymaps last-selected-unlocked-atom lead-down order-views
   in-part-mode? enter-part-mode! leave-part-mode! selection-in choose-part! drawn-part-class
   choose-datum! parent-part child-part sibling-part end-part shift-part! lift-part! lower-part! raise-part!
   splice-part! wrap-part! deletion-successor check-holds-no-locked mode-key?)

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
    (nongenerative layout:container/draw/neighbour/child-attributes/collapse/show-focused/adopt)
    (sealed #t)
    (fields draw neighbour child-attributes collapse? show-focused? adopt))

  (define-table containers)

  (define (container-entry kind) (table-ref containers kind #f))

  (define (register-container! kind draw neighbour child-attributes collapse? show-focused? adopt)
    (unless (procedure? draw)
      (assertion-violation 'layout:define-container "not a procedure" draw))
    (unless (or (not neighbour) (procedure? neighbour))
      (assertion-violation 'layout:define-container "not a procedure or #f" neighbour))
    (unless (or (not adopt) (procedure? adopt))
      (assertion-violation 'layout:define-container "not a procedure or #f" adopt))
    (let ([keymap (buffers:kind-keymap (buffers:kind kind))])
      (unless (or (not keymap) (table? keymap))
        (assertion-violation 'layout:define-container "not a keymap or #f" keymap)))
    (table-set! containers kind (make-container draw neighbour child-attributes collapse? show-focused? adopt)))

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
    (let ([v (view-of atom)] [part (and marks? (drawn-part-class atom))])
      (haml (:div.layout-view ([class (if (eqv? (atom-id atom) selected) (if part "selected part-selected" "selected") part)]
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

  ;; Kinds ask for the selected part's class as they draw, so the part is
  ;; found once per screen, and the popups, whose positions may equal a
  ;; part's, are drawn without it.
  (define drawn-selection #f)

  (define (drawn-part-class node)
    (and drawn-selection
         (fx= (document:node-start node) (car drawn-selection))
         (fx= (document:node-end node) (cdr drawn-selection))
         "part-selected"))

  (define (draw-layout client)
    (let ([ix (current-index)])
      (fluid-let ([drawn-selection (and mode-on?
                                        (let ([n (selection-in ix)])
                                          (and n (cons (document:node-start n) (document:node-end n)))))])
        (draw-tree ix (root-node) (zoom-position) client))))

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
                      (buffers:replace! b (document:node-start p) (document:node-end p)
                        (take-place ix p (node-datum ix (car others))))
                      (buffers:replace! b s e "")))))))))

  (define (child-attributes-of n)
    (let ([entry (kind-entry n)]) (if entry (container-child-attributes entry) '())))

  ;; A part's pinned attribute, like its kind's child attributes, belongs
  ;; to its place, which the child takes.
  (define (take-place ix container d)
    (let* ([own (child-attributes-of container)]
           [grand (parent-in ix container)]
           [place (cons 'pinned (if grand (child-attributes-of grand) '()))]
           [kept (remp (lambda (a) (or (memq (car a) own) (memq (car a) place))) (datum-attributes d))]
           [moved (filter (lambda (a) (memq (car a) place)) (datum-attributes (node-datum ix container)))])
      (with-attributes d (append kept moved))))

  (define (bar-view b)
    (let* ([root (root-node)] [bars (cdr (children root))])
      (or (exists (lambda (c) (and (view-atom? c) (let ([v (view-of c)]) (and (eq? (views:buffer v) b) v)))) bars)
          (let ([v (views:make b)] [at (fx- (document:node-end root) 1)])
            (buffers:replace! layout-buffer at at
              (vector 'views:view (list (cons 'view (views:id v)) (cons 'buffer (buffers:name b))
                                        '(pinned . #t) '(locked . #t))))
            v))))

  (define (selected-keymaps)
    (let* ([id (selected-id)] [ix (index-of-id id)])
      (views:keymaps (view-of (index-atom ix id)))))

  (define (enclosing-keymaps)
    (let* ([id (selected-id)] [ix (index-of-id id)])
      (let loop ([n (parent-in ix (index-atom ix id))] [acc '()])
        (if n
            (loop (parent-in ix n)
                  (let* ([kind (buffers:kind (document:node-kind n))] [k (and kind (buffers:kind-keymap kind))])
                    (if k (cons k acc) acc)))
            (reverse acc)))))

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
    (follow-focus!)
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

  (define mode-on? #f)

  (define (in-part-mode?) mode-on?)

  ;; The selected part is known by its first view and its length, which
  ;; follow it wherever an edit such as an undo moves it, and by its
  ;; positions, which keep its place when it goes. The start stays after
  ;; text inserted at it and the end before, so a part added or removed
  ;; beside it leaves the place on it.
  (define selection-view #f)
  (define selection-length #f)
  (define selection-start #f)
  (define selection-end #f)

  (define (main-part ix) (car (kids-of ix (root-node))))

  (define (position-in n nodes)
    (let loop ([ns nodes] [k 0])
      (if (fx= (document:node-start (car ns)) (document:node-start n)) k (loop (cdr ns) (fx+ k 1)))))

  (define (visited? ix n)
    (let ([m (main-part ix)])
      (and (fx<= (document:node-start m) (document:node-start n))
           (fx<= (document:node-end n) (document:node-end m))
           (not (locked-in? ix n)))))

  (define (part-at ix s e)
    (let ([doc (index-doc ix)])
      (and (fx< s (document:length doc))
           (let ([t (document:token doc s)])
             (and (document:node? t) (fx= (document:node-end t) e) (visited? ix t) t)))))

  (define (covering-part ix lo hi)
    (let ([m (main-part ix)])
      (and (fx<= (document:node-start m) lo) (fx<= hi (document:node-end m)) (not (locked-in? ix m))
           (let down ([n m])
             (let ([c (find (lambda (c)
                              (and (fx<= (document:node-start c) lo)
                                   (if (fx= lo hi) (fx< hi (document:node-end c)) (fx<= hi (document:node-end c)))
                                   (not (document:node-attribute c 'locked #f))))
                            (kids-of ix n))])
               (if c (down c) n))))))

  (define (atom-part ix)
    (let ([a (index-atom ix (selected-id))])
      (and a (not (locked-in? ix a)) a)))

  ;; A popup may be the selected view, and is no part of the layout.
  (define (part-or-main ix)
    (or (atom-part ix) (let ([m (main-part ix)]) (and (not (locked-in? ix m)) m))))

  (define (set-selection! n)
    (set! selection-view (first-view-id n))
    (set! selection-length (fx- (document:node-end n) (document:node-start n)))
    (set! selection-start (buffers:anchor-after layout-buffer (document:node-start n)))
    (set! selection-end (buffers:anchor layout-buffer (document:node-end n))))

  (define (located ix id len)
    (let ([a (index-atom ix id)])
      (and a (let climb ([n a])
               (cond
                 [(fx= (fx- (document:node-end n) (document:node-start n)) len) n]
                 [(parent-in ix n) => climb]
                 [else #f])))))

  (define (selection-in ix)
    (if mode-on?
        (let* ([s (buffers:anchor-position selection-start)] [e (buffers:anchor-position selection-end)]
               [n (or (let ([n (located ix selection-view selection-length)]) (and n (visited? ix n) n))
                      (part-at ix s e) (covering-part ix (fxmin s e) (fxmax s e)) (part-or-main ix))])
          (when (and n (not (and (fx= s (document:node-start n)) (fx= e (document:node-end n)))))
            (set-selection! n))
          n)
        (atom-part ix)))

  (define (focus-part! ix n)
    (let ([a (let ([a (lead-down ix n)])
               (if (and a (not (locked-in? ix a))) a (last-selected-unlocked-atom n)))])
      (when a (select-id! (atom-id a)))))

  ;; Code, a hand scroll or an edit the mode did not make can move focus
  ;; or the selected part without the other. Drawing reads the selection,
  ;; so the selection is moved to focus once, at the end of the batch. A
  ;; part the mode chose whose views are all locked cannot take focus, so
  ;; it stays selected until focus or the layout changes.
  (define agreed-focus #f)
  (define agreed-doc #f)

  (define (agree!)
    (set! agreed-focus (selected-id))
    (set! agreed-doc (layout-doc)))

  (define (follow-focus!)
    (when (and mode-on? (not (and (eqv? (selected-id) agreed-focus) (eq? (layout-doc) agreed-doc))))
      (let* ([ix (current-index)] [n (selection-in ix)] [a (atom-part ix)])
        (when (and n a (not (holds-range? a (document:node-start n) (document:node-end n))))
          (set-selection! a))
        (agree!))))

  (define (choose-part! ix n)
    (when mode-on? (set-selection! n))
    (focus-part! ix n)
    (agree!))

  (define (enter-part-mode!)
    (let* ([ix (current-index)] [n (part-or-main ix)])
      (unless n
        (assertion-violation 'layout:part-mode "no part that is not locked"))
      (set-selection! n)
      (set! mode-on? #t)))

  (define (leave-part-mode!)
    (set! mode-on? #f))

  ;; Keys the mode does not bind leave it before they are looked up, so
  ;; they run as they would outside it.
  (define (mode-key? keymap client key)
    (and mode-on? (string? key)
         (let ([pending (keys:pending client)])
           (and (table-ref keymap (if pending (string-append pending " " key) key) #f) #t))))

  (define (parent-part ix n)
    (let ([p (parent-in ix n)]) (and p (parent-in ix p) p)))

  (define (child-part ix n)
    (let ([cs (filter (lambda (c) (not (locked-in? ix c))) (kids-of ix n))] [f (focused-child ix n)])
      (and (pair? cs)
           (or (and f (find (lambda (c) (fx= (document:node-start c) (document:node-start f))) cs))
               (car cs)))))

  (define (siblings ix n)
    (let ([p (parent-part ix n)]) (if p (kids-of ix p) (list n))))

  (define (sibling-part ix n step)
    (let loop ([ns (if (fx> step 0) (siblings ix n) (reverse (siblings ix n)))])
      (cond
        [(fx= (document:node-start (car ns)) (document:node-start n))
         (find (lambda (c) (not (locked-in? ix c))) (cdr ns))]
        [else (loop (cdr ns))])))

  (define (end-part ix n last?)
    (find (lambda (c) (not (locked-in? ix c))) (if last? (reverse (siblings ix n)) (siblings ix n))))

  (define (datum-length d)
    (if (vector? d) 1 (fold-left (lambda (n c) (fx+ n (datum-length c))) 2 (cddr d))))

  (define (first-view-number d)
    (if (vector? d) (cdr (assq 'view (vector-ref d 1))) (first-view-number (caddr d))))

  ;; Each verb's edit may collapse or adopt around the part it moves, so
  ;; the part is found again afterwards by its first view, whose number
  ;; is unique, and its length, which no ancestor shares.
  (define (choose-datum! d)
    (let* ([ix (current-index)] [n (and d (located ix (first-view-number d) (datum-length d)))])
      (when n (choose-part! ix n))))

  (define (without d names)
    (with-attributes d (remp (lambda (a) (memq (car a) names)) (datum-attributes d))))

  (define (with-children d children) (cons* (car d) (cadr d) children))

  (define (collapses? n)
    (let ([entry (kind-entry n)]) (and entry (container-collapse? entry))))

  ;; A place attribute means something only to the kinds that name it,
  ;; so a part moving to another kind sheds the old kind's and the new
  ;; kind gives it its own.
  (define (arrive from to d)
    (if (eq? (document:node-kind from) (document:node-kind to))
        d
        (let* ([names (child-attributes-of to)]
               [d (without d (remp (lambda (a) (memq a names)) (child-attributes-of from)))]
               [entry (kind-entry to)])
          (if (and entry (container-adopt entry))
              (let ([r ((container-adopt entry) to d)])
                (unless (same-part? r d)
                  (assertion-violation 'layout:define-container "an adopt clause returned another part" r))
                r)
              d))))

  (define (same-part? r d)
    (if (vector? d)
        (and (vector? r) (fx= (vector-length r) 2) (eq? (vector-ref r 0) (vector-ref d 0)) (attributes? (vector-ref r 1))
             (equal? (assq 'view (vector-ref r 1)) (assq 'view (vector-ref d 1))))
        (and (pair? r) (eq? (car r) (car d)) (pair? (cdr r)) (attributes? (cadr r)) (equal? (cddr r) (cddr d)))))

  (define (datums ix nodes) (map (lambda (n) (node-datum ix n)) nodes))

  (define (replacing ds k new)
    (append (list-head ds k) new (list-tail ds (fx+ k 1))))

  ;; One replacement of the children that changed, so anchors in the
  ;; others, such as a strip's, stay where they are.
  (define (set-children! ix node old new)
    (let* ([kids (kids-of ix node)] [n (length old)] [m (length new)]
           [p (let loop ([o old] [d new] [p 0])
                (if (and (pair? o) (pair? d) (equal? (car o) (car d))) (loop (cdr o) (cdr d) (fx+ p 1)) p))]
           [q (let loop ([o (reverse old)] [d (reverse new)] [q 0])
                (if (and (fx< (fx+ p q) (fxmin n m)) (equal? (car o) (car d))) (loop (cdr o) (cdr d) (fx+ q 1)) q))]
           [s (if (fx> p 0) (document:node-end (list-ref kids (fx- p 1))) (fx+ (document:node-start node) 1))]
           [e (if (fx> q 0) (document:node-start (list-ref kids (fx- n q))) (fx- (document:node-end node) 1))]
           [middle (list-head (list-tail new p) (fx- m (fx+ p q)))])
      (buffers:replace! layout-buffer s e (if (null? middle) "" (apply document:from-datum middle)))))

  (define (replace-child! ix child new)
    (let* ([p (parent-in ix child)] [ks (kids-of ix p)] [old (datums ix ks)])
      (set-children! ix p old (replacing old (position-in child ks) new))))

  (define (check-unlocked who ix n)
    (when (locked-in? ix n)
      (assertion-violation who "a locked part" n)))

  (define (holds-locked? ix n)
    (or (locked-in? ix n)
        (let below ([n n])
          (exists (lambda (c) (or (document:node-attribute c 'locked #f) (below c))) (kids-of ix n)))))

  (define (check-holds-no-locked who ix n)
    (when (holds-locked? ix n)
      (assertion-violation who "a locked part" n)))

  (define (shift-part! who ix n step)
    (let ([p (parent-part ix n)])
      (and p
           (let* ([ks (kids-of ix p)] [k (position-in n ks)] [j (fx+ k step)])
             (and (fx>= j 0) (fx< j (length ks))
                  (let ([old (datums ix ks)])
                    (check-unlocked who ix (list-ref ks j))
                    (set-children! ix p old
                      (replacing (replacing old k (list (list-ref old j))) j (list (list-ref old k))))
                    (list-ref old k)))))))

  ;; From its container's first place a part goes before the container,
  ;; and from any other after it, so the order on screen is kept.
  (define (lift-part! ix n)
    (let* ([c (parent-part ix n)] [g (and c (parent-part ix c))])
      (and g
           (let* ([ks (kids-of ix c)] [k (position-in n ks)] [d (node-datum ix n)]
                  [rest (datums ix (remp (lambda (x) (fx= (document:node-start x) (document:node-start n))) ks))]
                  [moved (if (null? rest) (take-place ix c d) (arrive c g d))]
                  [left (cond
                          [(null? rest) '()]
                          [(and (null? (cdr rest)) (collapses? c)) (list (take-place ix c (car rest)))]
                          [else (list (with-children (node-datum ix c) rest))])])
             (replace-child! ix c (if (fx= k 0) (cons moved left) (append left (list moved))))
             moved))))

  ;; The container after the part takes it at its start, and one before
  ;; it at its end, the places on screen nearest the part's own.
  (define (lower-part! ix n)
    (let ([c (parent-part ix n)])
      (and c
           (let* ([ks (kids-of ix c)] [k (position-in n ks)]
                  [open? (lambda (x) (not (or (document:atom? x) (locked-in? ix x))))]
                  [after (find open? (list-tail ks (fx+ k 1)))]
                  [target (or after (find open? (reverse (list-head ks k))))])
             (and target
                  (let* ([moved (arrive c target (node-datum ix n))]
                         [td (node-datum ix target)]
                         [filled (with-children td (if after (cons moved (cddr td)) (append (cddr td) (list moved))))]
                         [old (datums ix ks)]
                         [new (remove-at (replacing old (position-in target ks) (list filled)) k)])
                    (if (and (null? (cdr new)) (collapses? c))
                        (replace-child! ix c (list (take-place ix c filled)))
                        (set-children! ix c old new))
                    moved))))))

  (define (remove-at ds k) (append (list-head ds k) (list-tail ds (fx+ k 1))))

  (define (unlocked-view-in? ix n)
    (exists (lambda (a) (and (holds-range? a (document:node-start n) (document:node-end n)) (not (locked-node? a))))
            (index-atoms)))

  (define (raise-part! who ix n)
    (let ([c (parent-part ix n)])
      (and c
           (begin
             (for-each (lambda (x)
                         (unless (fx= (document:node-start x) (document:node-start n))
                           (check-holds-no-locked who ix x)))
                       (kids-of ix c))
             (unless (or (unlocked-view-in? ix n) (unlocked-atoms-outside (document:node-start c) (document:node-end c)))
               (assertion-violation who "the last view that is not locked" n))
             (let ([moved (take-place ix c (node-datum ix n))])
               (replace-child! ix c (list moved))
               moved)))))

  ;; Layout does not know which attribute weighs a child, so the children
  ;; share the container's numeric place attributes, such as a strip's
  ;; size, equally.
  (define (splice-part! who ix n)
    (let ([g (parent-in ix n)] [ks (kids-of ix n)])
      (and (pair? ks) (or (parent-in ix g) (null? (cdr ks)))
           (begin
             (for-each (lambda (x) (check-unlocked who ix x)) ks)
             (let* ([names (child-attributes-of g)] [count (length ks)]
                    [shares (filter (lambda (a) (and (memq (car a) names) (real? (cdr a))))
                                    (datum-attributes (node-datum ix n)))]
                    [moved (map (lambda (d)
                                  (if (parent-in ix g)
                                      (arrive n g (with-attributes d
                                                    (append (remp (lambda (a) (assq (car a) shares)) (datum-attributes d))
                                                            (map (lambda (a) (cons (car a) (/ (cdr a) count))) shares))))
                                      (take-place ix n d)))
                                (datums ix ks))])
               (replace-child! ix n moved)
               (car moved))))))

  (define (wrap-part! who ix n make)
    (let* ([place (cons 'pinned (child-attributes-of (parent-in ix n)))]
           [d (node-datum ix n)]
           [w (make (list (without d place)))])
      (unless (and (list? w) (fx>= (length w) 3) (symbol? (car w)) (container-entry (car w)) (attributes? (cadr w)))
        (assertion-violation who "not the datum of a container" w))
      (let ([moved (with-attributes w (append (cadr w) (filter (lambda (a) (memq (car a) place)) (datum-attributes d))))])
        (buffers:replace! layout-buffer (document:node-start n) (document:node-end n) moved)
        moved)))

  (define (deletion-successor ix n)
    (let ([next (or (sibling-part ix n -1) (sibling-part ix n 1))])
      (and next (node-datum ix next))))

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
                  [attributes '()] [collapse #'#f] [show-focused #'#f] [adopt #'#f])
         (if (null? clauses)
             (begin
               (unless draw
                 (syntax-violation 'layout:define-container "a draw clause is required" x))
               #`(begin
                   (buffers:define-kind id (content nodes) (consent check-parts) (keymap #,keymap))
                   (define-values ()
                     (begin
                       (register-container! (car (id '())) #,draw #,neighbour '#,(datum->syntax #'id attributes)
                                            #,collapse #,show-focused #,adopt)
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
                   [(draw) (loop rest seen (expression) neighbour keymap attributes collapse show-focused adopt)]
                   [(neighbour) (loop rest seen draw (expression) keymap attributes collapse show-focused adopt)]
                   [(keymap) (loop rest seen draw neighbour (expression) attributes collapse show-focused adopt)]
                   [(child-attributes)
                    (syntax-case c ()
                      [(_ a ...) (for-all identifier? #'(a ...))
                       (loop rest seen draw neighbour keymap (syntax->datum #'(a ...)) collapse show-focused adopt)]
                      [_ (invalid c)])]
                   [(collapse) (loop rest seen draw neighbour keymap attributes (flag) show-focused adopt)]
                   [(show-focused) (loop rest seen draw neighbour keymap attributes collapse (flag) adopt)]
                   [(adopt) (loop rest seen draw neighbour keymap attributes collapse show-focused (expression))]
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
  (begin (register-container! (car (popups-root '())) %draw-popups #f '() #f #f #f) (values)))

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
  "Deletes the selected view's part; in the part mode, the selected part, then selects the part before it, else the one after."
  (if (in-part-mode?)
      (let* ([ix (current-index)] [n (selection-in ix)] [next (and n (deletion-successor ix n))])
        (when n
          (check-holds-no-locked 'layout:delete-view ix n)
          (%delete! ix n)
          (choose-datum! next)))
      (let* ([id (views:id (selected-view))] [ix (index-of-id id)])
        (%delete! ix (index-atom ix id)))))

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

(define-table part-mode-keymap
  "The part mode's keymap. A key it does not bind leaves the mode and runs as it would outside it.")

(define (part-mode?) (in-part-mode?))

(define (selected-part)
  (check-main-thread 'layout:selected-part)
  (selection-in (current-index)))

(define (part-class node)
  (unless (document:node? node)
    (assertion-violation 'layout:part-class "not a node" node))
  (drawn-part-class node))

(define (wrap! make)
  (unless (procedure? make)
    (assertion-violation 'layout:wrap! "not a procedure" make))
  (check-main-thread 'layout:wrap!)
  (let* ([ix (current-index)] [n (selection-in ix)])
    (unless n
      (assertion-violation 'layout:wrap! "no part is selected"))
    (choose-datum! (wrap-part! 'layout:wrap! ix n make))))

(define (%select! choose)
  (let* ([ix (current-index)] [n (selection-in ix)] [to (and n (choose ix n))])
    (when to (choose-part! ix to))))

(define (%edit! verb)
  (let* ([ix (current-index)] [n (selection-in ix)])
    (when n (choose-datum! (verb ix n)))))

(commands:define-command (part-mode)
  "Enters the part mode with the selected view's part selected: keys select parts of the layout and move them."
  (enter-part-mode!))

(commands:define-command (part-mode-leave)
  "Leaves the part mode; the selected view stays."
  (leave-part-mode!))

(commands:define-command (select-parent)
  "Selects the container of the selected part."
  (%select! parent-part))

(commands:define-command (select-child)
  "Selects the focused child of the selected part, the one holding the view selected last."
  (%select! child-part))

(commands:define-command (select-previous)
  "Selects the part before the selected one in its container."
  (%select! (lambda (ix n) (sibling-part ix n -1))))

(commands:define-command (select-next)
  "Selects the part after the selected one in its container."
  (%select! (lambda (ix n) (sibling-part ix n 1))))

(commands:define-command (select-first)
  "Selects the first part of the selected part's container."
  (%select! (lambda (ix n) (end-part ix n #f))))

(commands:define-command (select-last)
  "Selects the last part of the selected part's container."
  (%select! (lambda (ix n) (end-part ix n #t))))

(commands:define-command (shift-backward)
  "Swaps the selected part with the part before it in its container."
  (%edit! (lambda (ix n) (shift-part! 'layout:shift-backward ix n -1))))

(commands:define-command (shift-forward)
  "Swaps the selected part with the part after it in its container."
  (%edit! (lambda (ix n) (shift-part! 'layout:shift-forward ix n 1))))

(commands:define-command (lift)
  "Moves the selected part out of its container, to beside it."
  (%edit! lift-part!))

(commands:define-command (lower)
  "Moves the selected part into the nearest container among its siblings after it, as its first child, else before it, as its last."
  (%edit! lower-part!))

(commands:define-command (raise)
  "Makes the selected part take its container's place, deleting its siblings."
  (%edit! (lambda (ix n) (raise-part! 'layout:raise ix n))))

(commands:define-command (splice)
  "Replaces the selected container with its children."
  (%edit! (lambda (ix n) (splice-part! 'layout:splice ix n))))

(define %mode-press (make-thread-parameter #f))

;; A key the part mode binds acts on the layout, so it runs in the
;; layout's own view, where undo's keys undo window changes.
(define (%handle-key client item)
  (let ([key (keys:item-key item)])
    (cond
      [(mode-key? part-mode-keymap client key)
       (parameterize ([%mode-press #t])
         (views:call-with-view screen-view (lambda () (keys:press! client key))))]
      [else
       (when (in-part-mode?) (leave-part-mode!))
       (call-with-frame (frame client) (lambda () (keys:press! client key)))])))

;; Clicks reach keys without the layout's key handler.
(define (%leave-on-other-input command)
  (when (and (in-part-mode?) (keys:command-keys) (not (%mode-press)))
    (leave-part-mode!)))

(define (cursor-keymaps client posn)
  (cond
    [posn '()]
    [(in-part-mode?) (cons part-mode-keymap (selected-keymaps))]
    [else (selected-keymaps)]))

(define (container-keymaps client posn)
  (if posn '() (enclosing-keymaps)))

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
(keys:bind! keys:global "s-'" part-mode)
(keys:bind! keys:global "C-x w" part-mode)
(keys:bind! part-mode-keymap "RET" part-mode-leave)
(keys:bind! part-mode-keymap "i" select-parent)
(keys:bind! part-mode-keymap "k" select-child)
(keys:bind! part-mode-keymap "j" select-previous)
(keys:bind! part-mode-keymap "l" select-next)
(keys:bind! part-mode-keymap "<up>" select-parent)
(keys:bind! part-mode-keymap "<down>" select-child)
(keys:bind! part-mode-keymap "<left>" select-previous)
(keys:bind! part-mode-keymap "<right>" select-next)
(keys:bind! part-mode-keymap "0" select-first)
(keys:bind! part-mode-keymap "$" select-last)
(keys:bind! part-mode-keymap "I" lift)
(keys:bind! part-mode-keymap "K" lower)
(keys:bind! part-mode-keymap "J" shift-backward)
(keys:bind! part-mode-keymap "L" shift-forward)
(keys:bind! part-mode-keymap "S-<up>" lift)
(keys:bind! part-mode-keymap "S-<down>" lower)
(keys:bind! part-mode-keymap "S-<left>" shift-backward)
(keys:bind! part-mode-keymap "S-<right>" shift-forward)
(keys:bind! part-mode-keymap "r" raise)
(keys:bind! part-mode-keymap "-" splice)
(keys:bind! part-mode-keymap "x" delete-view)
(keys:bind! keymap "<mouse-1>" mouse-select-view)
(keys:bind! keymap "<down-mouse-1>" keys:ignore)
(add-hook! keys:find-keymaps cursor-keymaps)
(add-hook! keys:find-keymaps container-keymaps 90)
(add-hook! commands:before-command %leave-on-other-input)
(add-hook! buffers:kill-queries %keep-layout)
(table-set! web:input-handlers "key" %handle-key)
(table-set! web:stylesheets 'layout "layout/layout.css")
;; A raise in note-batch must not skip the advice it encloses, which
;; ends the batch for the plugins loaded before this one.
(advice-add! batch-ended (lambda (ended) (guard (c [#t (report c)]) (note-batch)) (ended)))
(on-unload save-now!)
(on-unload (lambda () (views:drop! screen-view)))
