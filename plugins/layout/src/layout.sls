#!tuna
(import (buffers) (document) (views) (keys) (commands) (modes) (web) (haml) (ask) (hooks) (options) (tables) (saved) (plain-data))
;; This plugin's raise is a command, so Chez's goes by another name.
(import (rename (only (chezscheme) raise) (raise raise-object)))

(define-enumeration direction (left right up down) directions)

(tables:define-table display-rules
  "Maps a predicate on buffers to the action that shows the buffers it accepts.")

(options:define-option page-title (lambda (name) (string-append name " - Tuna")) procedure?
  "A procedure of the selected view's buffer name that returns the title of every client's page.")

(options:define-option history-limit 10 (lambda (v) (and (integer? v) (exact? v) (>= v 0)))
  "How many window changes each level's history keeps to go back through; 0 keeps none.")

(module %internals
  (check-main-thread check-view check-direction register-container! check-parts check-popup-parts check-level
   open-layout! opened-popups current-index index-atom index-of-id atom-of part-of
   view-of atom-id selected-id shown-views select-id! set-zoom! current-zoom current-order zoom-level children root-node
   locked-node? locked-in? title-of shown-buffer-name draw-layout draw-popups neighbour-of remove-part! check-removable removed-part removal-refusal node-datum
   note-batch save-now! selected-keymaps enclosing-keymaps most-recent-atom atoms-in order-views
   enclosing-level reference-atom level-units unit-placed? other-view-in? deselect-id! same-node? same-level? visible-atoms index-atoms
   in-part-mode? enter-part-mode! leave-part-mode! selection-in choose-part! drawn-part-class
   choose-datum! parent-part child-part sibling-part end-part shift-part! lift-part! lower-part! raise-part!
   splice-part! wrap-part! deletion-successor check-unlocked check-holds-no-locked mode-key? beside-in! part-datum? container-entry
   note-before! note-after! history-step! parent-in holds-range? popups-index index-atom-list datum-attributes with-attributes)

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
    (nongenerative layout:container/draw/neighbour/child-attributes/collapse/show-focused/adopt/beside)
    (sealed #t)
    (fields draw neighbour child-attributes collapse? show-focused? adopt beside))

  (tables:define-table containers)

  (define (container-entry kind) (tables:ref containers kind #f))

  (define (register-container! kind draw neighbour child-attributes collapse? show-focused? adopt beside)
    (unless (procedure? draw)
      (assertion-violation 'layout:define-container "not a procedure" draw))
    (unless (or (not neighbour) (procedure? neighbour))
      (assertion-violation 'layout:define-container "not a procedure or #f" neighbour))
    (unless (or (not adopt) (procedure? adopt))
      (assertion-violation 'layout:define-container "not a procedure or #f" adopt))
    (unless (or (not beside) (procedure? beside))
      (assertion-violation 'layout:define-container "not a procedure or #f" beside))
    (let ([keymap (buffers:kind-keymap (buffers:kind kind))])
      (unless (or (not keymap) (tables:table? keymap))
        (assertion-violation 'layout:define-container "not a keymap or #f" keymap)))
    (tables:set! containers kind (make-container draw neighbour child-attributes collapse? show-focused? adopt beside)))

  (define (attributes? a)
    (and (list? a) (for-all (lambda (p) (and (pair? p) (symbol? (car p)))) a)))

  (define (view-atom-datum? d)
    (and (vector? d) (fx= (vector-length d) 2) (eq? (vector-ref d 0) 'views:view)
         (attributes? (vector-ref d 1))
         (let ([id (assq 'view (vector-ref d 1))]) (and id (fixnum? (cdr id)) (fx> (cdr id) 0)))
         (let ([b (assq 'buffer (vector-ref d 1))]) (and b (string? (cdr b))))))

  (define (level-datum? d) (and (pair? d) (eq? (car d) 'layout:level)))

  ;; Two levels with nothing between them would mark one boundary twice,
  ;; and a zoom counted in levels would count a step that hides nothing.
  (define (part-datum? d known?)
    (or (view-atom-datum? d)
        (and (pair? d) (symbol? (car d)) (pair? (cdr d)) (attributes? (cadr d)) (pair? (cddr d))
             (list? (cddr d)) (known? (car d))
             (or (not (level-datum? d)) (and (null? (cdddr d)) (not (level-datum? (caddr d)))))
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
         (level-datum? v)
         (unlocked-view-datum? v)
         (distinct-ids? (datum-view-ids v '()))))

  ;; A consent is not told which buffer it is asked for, so a view number
  ;; already in either tree may be written again only where the edit
  ;; replaces it.
  (define (parts-fit? node edit empty-ok?)
    (let* ([inserted (buffers:piece-document (buffers:edit-inserted edit))] [datums (document:datums inserted)])
      (and (for-all (lambda (d) (part-datum? d container-entry)) datums)
           (or empty-ok?
               (fx> (fx+ (fx- (document:node-end node) (document:node-start node) 2)
                         (fx- (document:length inserted) (buffers:piece-length (buffers:edit-removed edit))))
                    0))
           (let ([ids (fold-left (lambda (acc d) (datum-view-ids d acc)) '() datums)])
             (and (distinct-ids? ids)
                  (or (not layout-buffer)
                      (let* ([ix (current-index)] [px (popups-index)] [s (buffers:edit-start edit)]
                             [e (fx+ s (buffers:piece-length (buffers:edit-removed edit)))])
                        (for-all (lambda (id)
                                   (let ([a (index-atom ix id)] [p (index-atom px id)])
                                     (and (or (not a) (holds-range? a s e)) (or (not p) (holds-range? p s e)))))
                                 ids))))))))

  (define (check-parts node edit) (parts-fit? node edit #f))

  (define (check-popup-parts node edit) (parts-fit? node edit #t))

  (define (check-level node edit)
    (let ([s (buffers:edit-start edit)] [datums (document:datums (buffers:piece-document (buffers:edit-inserted edit)))])
      (and (fx= s (fx+ (document:node-start node) 1))
           (fx= (fx+ s (buffers:piece-length (buffers:edit-removed edit))) (fx- (document:node-end node) 1))
           (fx= (length datums) 1)
           (not (level-datum? (car datums)))
           (parts-fit? node edit #f))))

  (saved:define-saved saved-layout #f (lambda (v) (or (not v) (layout-datum? v))))

  (define (positive-fixnum? v) (and (fixnum? v) (fx> v 0)))

  (define (zoom? v)
    (and (pair? v) (positive-fixnum? (car v)) (or (eq? (cdr v) 'root) (positive-fixnum? (cdr v)))))

  (define (selection-state? v)
    (and (list? v) (fx= (length v) 2)
         (list? (car v)) (for-all positive-fixnum? (car v))
         (or (not (cadr v)) (zoom? (cadr v)))))

  (saved:define-saved saved-selection '(() #f) selection-state?)

  ;; The views' ids are kept in the order they were last selected, the
  ;; selected one first, and nothing per container: a container's focused
  ;; child is the child holding the first of them, so selecting a view
  ;; focuses every container on its path, and deleting one leaves no
  ;; stale focus.
  (define view-order (car (saved-selection)))
  (define zoom-state (cadr (saved-selection)))

  (define (current-zoom) (current-index) zoom-state)

  (define (current-order) (current-index) view-order)

  (define layout-buffer #f)
  (define popups-buffer #f)
  (define saved-key #f)
  (define selection-dirty? #f)
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

  ;; The order and the zoom are checked against each new document when
  ;; it is first read, not in an edit's hook, so a cancel landing in the
  ;; check leaves it to be made again at the next read.
  (define synced-doc #f)
  (define synced-popups-doc #f)
  (define synced-index #f)

  ;; At start-up the saved order may begin with a part a plugin placed
  ;; and locked, which the user never chose to work in.
  (define restoring? #f)

  (define (current-index)
    (let ([doc (layout-doc)] [popups (popups-doc)])
      (unless (and last-index (eq? (index-doc last-index) doc))
        (set! last-index (build-index doc)))
      (unless (and last-popups-index (eq? (index-doc last-popups-index) popups))
        (set! last-popups-index (build-index popups)))
      (unless (and (eq? synced-doc doc) (eq? synced-popups-doc popups))
        (fix-selection! synced-index last-index last-popups-index)
        (set! synced-doc doc)
        (set! synced-popups-doc popups)
        (set! synced-index last-index))
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

  (define (selected-id) (current-index) (car view-order))

  (define (level? n) (and (not (document:atom? n)) (eq? (document:node-kind n) 'layout:level)))

  (define (enclosing-level ix n)
    (let loop ([p (parent-in ix n)])
      (if (or (not p) (level? p)) p (loop (parent-in ix p)))))

  (define (zoom-level ix atom target)
    (let loop ([l (enclosing-level ix atom)] [k 1])
      (let ([out (enclosing-level ix l)])
        (if (or (not out) (and (fixnum? target) (fx= k target))) l (loop out (fx+ k 1))))))

  ;; Zoom draws the zoomed view in place of its level's part, so it is
  ;; known by that level's start and the view's atom.
  (define (zoom-place ix z)
    (and z (let ([a (index-atom ix (car z))])
             (and a (cons (document:node-start (zoom-level ix a (cdr z))) a)))))

  (define (locked-in? ix n)
    (let loop ([n n])
      (and n (or (and (document:node-attribute n 'locked #f) #t) (loop (parent-in ix n))))))

  (define (locked-node? n) (locked-in? (current-index) n))

  (define (shown-children ix node zp)
    (if (and zp (fx= (car zp) (document:node-start node))) (list (cdr zp)) (kids-of ix node)))

  (define (shows-focused? n)
    (let ([entry (kind-entry n)]) (and entry (container-show-focused? entry))))

  (define (focused-or-first ix node shown)
    (let ([f (focused-child ix node)])
      (or (and f (find (lambda (c) (fx= (document:node-start c) (document:node-start f))) shown))
          (car shown))))

  (define (atoms-under ix zp visible?)
    (reverse
      (let walk ([n (root-node)] [acc '()])
        (if (view-atom? n)
            (cons n acc)
            (let ([shown (shown-children ix n zp)])
              (fold-left (lambda (acc c) (walk c acc)) acc
                (if (and visible? (pair? shown) (shows-focused? n)) (list (focused-or-first ix n shown)) shown)))))))

  (define-record-type shown-entry
    (sealed #t)
    (fields index zoom atoms))

  (define zoom-cache (make-shown-entry #f #f '()))

  ;; Selecting a view in a part its container hides shows that part, so
  ;; whether a selection ends the zoom asks only what the zoom leaves.
  (define (shown-atoms)
    (let* ([ix (current-index)] [z zoom-state])
      (unless (and (eq? (shown-entry-index zoom-cache) ix) (equal? (shown-entry-zoom zoom-cache) z))
        (set! zoom-cache (make-shown-entry ix z (atoms-under ix (zoom-place ix z) #f))))
      (shown-entry-atoms zoom-cache)))

  (define-record-type visible-entry
    (sealed #t)
    (fields index zoom order atoms))

  (define visible-cache (make-visible-entry #f #f #f '()))

  (define (visible-atoms)
    (let* ([ix (current-index)] [z zoom-state] [order view-order])
      (unless (and (eq? (visible-entry-index visible-cache) ix) (equal? (visible-entry-zoom visible-cache) z)
                   (eq? (visible-entry-order visible-cache) order))
        (set! visible-cache (make-visible-entry ix z order (atoms-under ix (zoom-place ix z) #t))))
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
    (let ([order view-order]
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

  ;; A locked part is its plugin's, so a choice made for the user takes
  ;; one only when nothing else is left.
  (define (most-recent-atom ix atoms order)
    (let* ([unlocked (remp (lambda (a) (locked-in? ix a)) atoms)]
           [pool (if (null? unlocked) atoms unlocked)])
      (and (pair? pool)
           (or (exists (lambda (id) (find (lambda (a) (eqv? (atom-id a) id)) pool)) order)
               (car pool)))))

  (define (other-view-in? ix n)
    (let loop ([n n])
      (and n (or (and (document:node-attribute n 'other-view #f) #t) (loop (parent-in ix n))))))

  (define (reference-candidate? ix id)
    (let ([a (index-atom ix id)])
      (and a (not (locked-in? ix a)) (not (other-view-in? ix a)))))

  (define (reference-in ix order)
    (let ([atoms (index-atom-list ix)])
      (or (most-recent-atom ix (filter (lambda (a) (reference-candidate? ix (atom-id a))) atoms) order)
          (most-recent-atom ix atoms order))))

  (define (with-first id order) (cons id (remv id order)))

  (define (set-order! order)
    (unless (equal? order view-order)
      (set! view-order order)
      (set! selection-dirty? #t)))

  (define (set-zoom! z)
    (unless (equal? z zoom-state)
      (set! zoom-state z)
      (set! selection-dirty? #t)))

  ;; Popups are drawn over the whole layout, zoomed or not.
  ;; A popup's or a prompt's buffer is none the user returns to with
  ;; C-x b, so only a view of the layout showing a buffer that is not
  ;; internal records a use. A prompt that quits selects its view again
  ;; before its picker ends the preview there, so a previewed buffer
  ;; records none.
  (define (select-id! id)
    (unless (or (index-atom (popups-index) id) (exists (lambda (a) (eqv? (atom-id a) id)) (shown-atoms)))
      (set-zoom! #f))
    (set-order! (cons id (remv id view-order)))
    (let* ([a (index-atom (current-index) id)] [b (and a (views:buffer (view-of a)))])
      (when (and b (not (buffers:internal-name? (buffers:name b))) (not (views:previewing? (view-of a))))
        (buffers:move-to-front! b))))

  ;; The previous document's index says which view the user worked in,
  ;; since an edit can remove it or change what it may be. Its successor
  ;; takes its place in the order whether or not it was selected, so a
  ;; prompt or popup that ends later returns to it. Nothing records a
  ;; use, since the user chose none of these views.
  (define (fix-selection! old ix px)
    (let* ([live? (lambda (id) (or (index-atom ix id) (index-atom px id)))]
           [selected (and (pair? view-order) (car view-order))]
           [r (and old (not restoring?) (reference-in old view-order))]
           [r-id (and r (atom-id r))]
           [handed? (and r (not (reference-candidate? ix r-id)))]
           [order (filter live? view-order)]
           [order (if handed? (hand-over old ix r-id order (and (eqv? r-id selected) (not (live? r-id)))) order)]
           [order (if (or restoring? (null? order)
                          (and (not (live? selected)) (not (and handed? (eqv? r-id selected)))))
                      (with-first (atom-id (reference-in ix order)) order)
                      order)])
      (set! restoring? #f)
      (set-order! order)
      (fix-zoom! old ix px)))

  ;; A view added to the zoomed level would be hidden by the zoom, so the
  ;; zoom ends, as tmux's split-window ends one.
  (define (fix-zoom! old ix px)
    (let ([z zoom-state] [id (and (pair? view-order) (car view-order))])
      (when (and z (not (and (index-atom ix (car z))
                             (or (index-atom px id)
                                 (exists (lambda (a) (eqv? (atom-id a) id)) (atoms-under ix (zoom-place ix z) #f)))
                             (not (added-to-zoom? old ix z)))))
        (set-zoom! #f))))

  (define (added-to-zoom? old ix z)
    (and old
         (exists (lambda (a) (not (index-atom old (atom-id a))))
                 (atoms-in ix (zoom-level ix (index-atom ix (car z)) (cdr z))))))

  (define (hand-over old ix r-id order select?)
    (let ([s (successor old ix r-id order)])
      (cond
        [(not s) order]
        [select? (with-first (atom-id s) order)]
        [(not (reference-candidate? ix (atom-id s))) order]
        [else
         (let loop ([os (remv (atom-id s) order)] [before '()])
           (cond
             [(null? os) (append (reverse before) (list (atom-id s)))]
             [(reference-candidate? ix (car os)) (append (reverse before) (cons (atom-id s) os))]
             [else (loop (cdr os) (cons (car os) before))]))])))

  ;; The successor is sought where the leaving view sat, so the level it
  ;; was in keeps the selection while that level has a view to give.
  (define (successor old ix r-id order)
    (let ([pins (pins-across old ix r-id)])
      (or (exists (lambda (level) (most-recent-atom ix (level-candidates ix level pins r-id order) order))
                  (levels-across old ix r-id))
          (most-recent-atom ix (remp (lambda (a) (eqv? (atom-id a) r-id)) (index-atom-list ix)) order))))

  (define (surviving-atoms old ix n)
    (filter values (map (lambda (a) (index-atom ix (atom-id a))) (atoms-in old n))))

  ;; An edit may dissolve a level, or a level holding a level, so a part
  ;; of the old tree is found by the views it held, wherever they went.
  (define (innermost ix atoms keep?)
    (let loop ([n (parent-in ix (car atoms))])
      (cond
        [(not n) #f]
        [(and (keep? n)
              (for-all (lambda (a) (holds-range? a (document:node-start n) (document:node-end n))) atoms))
         n]
        [else (loop (parent-in ix n))])))

  (define (levels-across old ix r-id)
    (let loop ([l (enclosing-level old (index-atom old r-id))] [acc '()])
      (if (not l)
          (reverse acc)
          (let* ([atoms (surviving-atoms old ix l)]
                 [found (and (pair? atoms) (innermost ix atoms level?))])
            (loop (enclosing-level old l)
                  (if (or (not found) (and (pair? acc) (same-node? found (car acc)))) acc (cons found acc)))))))

  ;; A container that shows one child goes on showing the one that held
  ;; the leaving view; otherwise the order would show the tab of a view
  ;; selected before it, since that tab lost its newest view. An edit may
  ;; dissolve containers, so a tab is found after it as the child, of
  ;; each container that shows one, holding every view the tab held.
  (define (pins-across old ix r-id)
    (let loop ([child (index-atom old r-id)] [acc '()])
      (let ([k (parent-in old child)])
        (if (not k)
            acc
            (loop k (if (shows-focused? k) (pin-held ix (surviving-atoms old ix child) acc) acc))))))

  (define (pin-held ix held acc)
    (if (null? held)
        acc
        (let up ([c (car held)] [acc acc])
          (let ([n (parent-in ix c)])
            (cond
              [(not n) acc]
              [(and (shows-focused? n) (not (assv (document:node-start n) acc))
                    (for-all (lambda (a) (holds-range? a (document:node-start c) (document:node-end c))) held))
               (up n (cons (cons (document:node-start n) c) acc))]
              [else (up n acc)])))))

  (define (shown-kids ix n pins holds?)
    (let ([kids (kids-of ix n)])
      (if (and (pair? kids) (shows-focused? n))
          (let ([pin (assv (document:node-start n) pins)])
            (list (if (and pin (holds? (cdr pin))) (cdr pin) (focused-or-first ix n kids))))
          kids)))

  ;; What use-other-view weighs, the zoom aside: the zoomed view was
  ;; selected after every view the zoom hides, so it outranks them anyway.
  (define (level-candidates ix level pins excluded order)
    (define (shown-atoms-of n inner)
      (cond
        [(view-atom? n) (if (eqv? (atom-id n) excluded) '() (list n))]
        [(document:atom? n) '()]
        [else (fold-right (lambda (c acc) (append (shown-atoms-of c inner) acc)) '()
                (shown-kids ix n pins
                  (lambda (c) (exists (lambda (a) (not (or (locked-in? ix a) (unit-placed? ix a inner)))) (shown-atoms-of c inner)))))]))
    (define (usable? a) (and (not (locked-in? ix a)) (not (unit-placed? ix a level))))
    (let walk ([n (car (kids-of ix level))])
      (cond
        [(view-atom? n) (if (and (not (eqv? (atom-id n) excluded)) (usable? n)) (list n) '())]
        [(document:atom? n) '()]
        [(level? n)
         (let ([s (stand-in ix n (shown-atoms-of n n) order)])
           (if (and s (usable? s)) (list s) '()))]
        [else (fold-right (lambda (c acc) (append (walk c) acc)) '()
                (shown-kids ix n pins (lambda (c) (pair? (walk c)))))])))

  (define (deselect-id! id)
    (let ([ix (current-index)] [px last-popups-index] [order view-order])
      (when (and (pair? order) (eqv? (car order) id))
        (let* ([r (reference-in ix order)]
               [next (if (eqv? (atom-id r) id) (successor ix ix id order) r)])
          (when (and next (not (eqv? (atom-id next) id)))
            (set-order! (with-first (atom-id next) order))
            (fix-zoom! #f ix px))))))

  (define (title-of ix n)
    (let ([title (document:node-attribute n 'title #f)])
      (cond
        [(string? title) title]
        [(view-atom? n) (shown-buffer-name n)]
        [else
         (let ([c (or (focused-child ix n) (let ([cs (kids-of ix n)]) (and (pair? cs) (car cs))))])
           (if c (title-of ix c) ""))])))

  (define (shown-buffer-name atom)
    (let ([b (views:buffer (view-of atom))])
      (if b (buffers:name b) (let ([name (document:node-attribute atom 'buffer "")]) (if (string? name) name "")))))

  ;; A popup is drawn outside the layout's screen view, so its element
  ;; carries no positions, which would name the layout's.
  (define (draw-atom atom selected client marks?)
    (let ([v (view-of atom)] [part (drawn-part-class atom)])
      (haml (:div.layout-view ([class (if (eqv? (atom-id atom) selected) (if part (string-append "selected " part) "selected") part)]
                               [data-at (and marks? (document:node-start atom))]
                               [data-to (and marks? (document:node-end atom))])
              (draw-view-atom atom v client)))))

  (define (draw-plain shown draw-child)
    (haml (:div.layout-part (map draw-child shown))))

  (define (draw-tree ix root zp client)
    (fluid-let ([drawn-index ix] [drawn-focus (focus-path ix)])
      (draw-nodes ix root zp client)))

  (define (focus-path ix)
    (let ([a (index-atom ix (selected-id))])
      (if a
          (let climb ([n (parent-in ix a)] [acc '()])
            (if n (climb (parent-in ix n) (cons (document:node-start n) acc)) acc))
          '())))

  (define (draw-nodes ix root zp client)
    (let ([selected (selected-id)] [marks? (eq? ix last-index)])
      (let draw ([n root])
        (cond
          [(view-atom? n) (draw-atom n selected client marks?)]
          [(document:atom? n) '()]
          [else
           (let* ([shown (shown-children ix n zp)]
                  [entry (container-entry (document:node-kind n))]
                  [draw-child (lambda (c)
                                (unless (and (document:node? c) (exists (lambda (s) (fx= (document:node-start s) (document:node-start c))) shown))
                                  (assertion-violation 'layout:screen "not a child to show" c))
                                (draw c))])
             (if entry
                 (guard (c [(not (cancelled? c)) (report c) (draw-plain shown draw)])
                   ((container-draw entry) n shown (focused-child ix n) draw-child client))
                 (draw-plain shown draw)))]))))

  ;; Kinds ask for a part's classes as they draw, so the selected part,
  ;; the selected view's level and the focus path are found once per
  ;; screen; the popups, whose positions may equal a part's, are drawn
  ;; without the first two.
  (define drawn-selection #f)
  (define drawn-level #f)
  (define drawn-index #f)
  (define drawn-focus '())

  (define (drawn-part-class node)
    (and drawn-index
         (let* ([ix drawn-index] [s (document:node-start node)]
                [classes
                 (filter values
                   (list (and drawn-selection (fx= s (car drawn-selection))
                              (fx= (document:node-end node) (cdr drawn-selection))
                              "part-selected")
                         ;; A level draws nothing of its own, so the mode
                         ;; outlines the selected view's level to show how
                         ;; far the commands that act in it reach.
                         (and drawn-level (fx= s drawn-level) "part-level")
                         (and (placed? node) "placed")
                         (and (locked-in? ix node) "locked")
                         (and (not (document:atom? node))
                              (exists (lambda (c) (or (level? c) (placed? c))) (kids-of ix node))
                              "frame")
                         (and (memv s drawn-focus) "focus-path")))])
           (and (pair? classes)
                (fold-left (lambda (acc c) (string-append acc " " c)) (car classes) (cdr classes))))))

  (define (placed? node) (and (document:node-attribute node 'depth #f) #t))

  (define (node-range n) (cons (document:node-start n) (document:node-end n)))

  (define (draw-layout client)
    (let ([ix (current-index)])
      (fluid-let ([drawn-selection (and mode-on? (let ([n (selection-in ix)]) (and n (node-range n))))]
                  [drawn-level (and mode-on? (document:node-start (enclosing-level ix (reference-atom ix))))])
        (draw-tree ix (root-node) (zoom-place ix zoom-state) client))))

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
                      (let ([a (most-recent-atom ix (atoms-in ix sibling) view-order)])
                        (if (and a (not (locked-in? ix a))) (view-of a) (across sibling)))]))))))))

  (define (node-datum ix n)
    (car (document:datums (document:slice (index-doc ix) (document:node-start n) (document:node-end n)))))

  (define (with-attributes d attributes)
    (if (vector? d) (vector (vector-ref d 0) attributes) (cons* (car d) attributes (cddr d))))

  (define (unlocked-atoms-outside s e)
    (exists (lambda (a) (and (not (holds-range? a s e)) (not (locked-node? a)))) (index-atoms)))

  (define (holds-range? a s e) (and (fx<= s (document:node-start a)) (fx<= (document:node-end a) e)))

  ;; Removing a part also removes each container it leaves empty, since
  ;; the kinds' checks refuse a container left empty between two.
  (define (removed-part ix node)
    (let ([layout? (eq? ix (current-index))])
      (let loop ([n node])
        (let ([p (parent-in ix n)])
          (if (and p (not (and layout? (level? p))) (parent-in ix p) (null? (cdr (kids-of ix p))))
              (loop p)
              n)))))

  ;; The popups may all go; the layout keeps a view that is not locked.
  (define (removal-refusal ix removed)
    (let ([p (parent-in ix removed)] [layout? (eq? ix (current-index))])
      (cond
        [(not p) "the root"]
        [(and layout? (level? p)) "the last view of its level"]
        [(and layout? (not (unlocked-atoms-outside (document:node-start removed) (document:node-end removed))))
         "the last view that is not locked"]
        [else #f])))

  (define (check-removable who ix node)
    (let ([refusal (removal-refusal ix (removed-part ix node))])
      (when refusal
        (error who refusal))))

  ;; Removing and collapsing are one edit, for the same reason.
  (define (remove-part! ix node)
    (let* ([n (removed-part ix node)] [refusal (removal-refusal ix n)])
      (when refusal
        (assertion-violation 'layout:delete-part! refusal node))
      (let* ([p (parent-in ix n)] [s (document:node-start n)] [e (document:node-end n)]
             [b (if (eq? ix (current-index)) layout-buffer popups-buffer)]
             [others (remp (lambda (c) (fx= (document:node-start c) s)) (kids-of ix p))]
             [entry (kind-entry p)] [grand (parent-in ix p)])
        (if (and grand entry (container-collapse? entry) (fx= (length others) 1))
            (buffers:replace! b (document:node-start p) (document:node-end p)
              (take-place ix p (node-datum ix (car others))))
            (buffers:replace! b s e "")))))

  (define (child-attributes-of n)
    (let ([entry (kind-entry n)]) (if entry (container-child-attributes entry) '())))

  ;; A part's kind's child attributes belong to its place, which the
  ;; child takes. A level may not hold a level, so one that would gives
  ;; way to its part.
  (define (take-place ix container d)
    (let* ([own (child-attributes-of container)]
           [grand (parent-in ix container)]
           [place (if grand (child-attributes-of grand) '())]
           [kept (remp (lambda (a) (or (memq (car a) own) (memq (car a) place))) (datum-attributes d))]
           [moved (filter (lambda (a) (memq (car a) place)) (datum-attributes (node-datum ix container)))]
           [d (with-attributes d (append kept moved))])
      (if (and grand (level? grand) (level-datum? d)) (caddr d) d)))

  (define (same-node? a b) (fx= (document:node-start a) (document:node-start b)))

  (define (same-level? ix a b) (same-node? (enclosing-level ix a) (enclosing-level ix b)))

  (define (reference-atom ix) (reference-in ix view-order))

  (define (unit-of ix atom level)
    (let loop ([n atom] [unit atom])
      (let ([p (parent-in ix n)])
        (if (same-node? p level) unit (loop p (if (level? p) p unit))))))

  ;; The atoms of one nested level are adjacent in the layout's order.
  (define (level-units ix level atoms)
    (let ([s (document:node-start level)] [e (document:node-end level)] [order view-order])
      (let loop ([as (filter (lambda (a) (and (fx< s (document:node-start a)) (fx<= (document:node-end a) e))) atoms)]
                 [acc '()])
        (if (null? as)
            (reverse acc)
            (let ([unit (unit-of ix (car as) level)])
              (if (eq? unit (car as))
                  (loop (cdr as) (cons unit acc))
                  (let-values ([(inside rest) (partition (lambda (a) (holds-range? a (document:node-start unit) (document:node-end unit))) as)])
                    (loop rest (cons (stand-in ix unit inside order) acc)))))))))

  ;; A nested level stands for the view in it the user would display in,
  ;; so a part a plugin placed inside it does not hide the rest.
  (define (stand-in ix level atoms order)
    (most-recent-atom ix (let ([free (remp (lambda (a) (unit-placed? ix a level)) atoms)]) (if (null? free) atoms free))
                      order))

  ;; A plugin's placed part carries depth, on its atom or on a container
  ;; such as tabs that took the atom's place attributes. A level nested in
  ;; a placed part is a plugin's too, so the walk goes up to the level
  ;; weighing the unit, not to the atom's own level.
  (define (unit-placed? ix atom level)
    (let loop ([n atom])
      (and (not (same-node? n level))
           (or (and (document:node-attribute n 'depth #f) #t) (loop (parent-in ix n))))))

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
        '() view-order)))

  ;; An atom names its buffer so that a view restarts on it; the view's
  ;; buffer may have changed since the atom was written.
  (define (current-datum)
    (refreshed (node-datum (current-index) (root-node)) buffer-name-now))

  (define (buffer-name-now id)
    (let* ([v (views:find id)] [b (and v (views:buffer v))])
      (and b (buffers:name b))))

  (define (refreshed d name-of)
    (let refresh ([d d])
      (if (vector? d)
          (let ([name (name-of (cdr (assq 'view (vector-ref d 1))))])
            (if name
                (vector 'views:view (map (lambda (a) (if (eq? (car a) 'buffer) (cons 'buffer name) a))
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
            (saved:set! saved-layout d)))
        (set! saved-key key)))
    ;; Popups are never saved, so neither are their places in the order.
    (when selection-dirty?
      (let* ([ix (current-index)]
             [state (list (filter (lambda (id) (index-atom ix id)) view-order)
                          zoom-state)])
        (unless (equal? state (saved-selection))
          (saved:set! saved-selection state)))
      (set! selection-dirty? #f)))

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
    (note-history-levels!)
    (save-now!))

  (define (first-buffer)
    (find (lambda (b) (not (buffers:internal-name? (buffers:name b)))) (buffers:all)))

  (define (default-datum)
    (let* ([b (or (first-buffer) (buffers:make "*scratch*" ""))] [v (views:make b)])
      (list 'layout:level '()
            (vector 'views:view (list (cons 'view (views:id v)) (cons 'buffer (buffers:name b)))))))

  (define (opened-popups) popups-buffer)

  (define (open-layout! popups-root)
    (set! layout-buffer
      (or (buffers:find " *layout*")
          (begin
            (set! restoring? #t)
            (buffers:make " *layout*" (or (saved-layout) (default-datum))))))
    (set! popups-buffer (or (buffers:find " *popups*") (buffers:make " *popups*" popups-root)))
    (set! known-ids (map atom-id (append (index-atoms) (index-atom-list (popups-index)))))
    layout-buffer)

  (define mode-on? #f)

  (define (in-part-mode?) mode-on?)

  ;; The selected part is known by its first view and its length, which
  ;; follow it wherever an edit the mode did not make moves it, and by its
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

  (define (visited? ix n) (and (parent-in ix n) #t))

  (define (part-at ix s e)
    (let ([doc (index-doc ix)])
      (and (fx< s (document:length doc))
           (let ([t (document:token doc s)])
             (and (document:node? t) (fx= (document:node-end t) e) (visited? ix t) t)))))

  (define (covering-part ix lo hi)
    (let ([m (main-part ix)])
      (and (fx<= (document:node-start m) lo) (fx<= hi (document:node-end m))
           (let down ([n m])
             (let ([c (find (lambda (c)
                              (and (fx<= (document:node-start c) lo)
                                   (if (fx= lo hi) (fx< hi (document:node-end c)) (fx<= hi (document:node-end c)))))
                            (kids-of ix n))])
               (if c (down c) n))))))

  (define (atom-part ix)
    (let ([a (index-atom ix (selected-id))])
      (and a (not (locked-in? ix a)) a)))

  ;; A popup may be the selected view, and is no part of the layout.
  (define (part-or-main ix)
    (or (index-atom ix (selected-id)) (main-part ix)))

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
    (let ([a (most-recent-atom ix (atoms-in ix n) view-order)])
      (when (and a (not (locked-in? ix a))) (select-id! (atom-id a)))))

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
    (set-selection! (part-or-main (current-index)))
    (set! mode-on? #t))

  (define (leave-part-mode!)
    (set! mode-on? #f))

  ;; Keys the mode does not bind leave it before they are looked up, so
  ;; they run as they would outside it.
  (define (mode-key? keymap client key)
    (and mode-on? (string? key)
         (let ([pending (keys:pending client)])
           (and (tables:ref keymap (if pending (string-append pending " " key) key) #f) #t))))

  (define (parent-part ix n)
    (let ([p (parent-in ix n)]) (and p (parent-in ix p) p)))

  (define (child-part ix n)
    (let ([cs (kids-of ix n)] [f (focused-child ix n)])
      (and (pair? cs)
           (or (and f (find (lambda (c) (same-node? c f)) cs))
               (car cs)))))

  (define (siblings ix n)
    (let ([p (parent-part ix n)]) (if p (kids-of ix p) (list n))))

  (define (sibling-part ix n step)
    (let loop ([ns (if (fx> step 0) (siblings ix n) (reverse (siblings ix n)))])
      (cond
        [(same-node? (car ns) n) (and (pair? (cdr ns)) (cadr ns))]
        [else (loop (cdr ns))])))

  (define (end-part ix n last?)
    (car (if last? (reverse (siblings ix n)) (siblings ix n))))

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

  ;; The parts outside the view's level persist for it, so the walk
  ;; stops there.
  (define (beside-in! ix atom part direction make)
    (let up ([n atom])
      (let* ([p (parent-in ix n)] [entry (kind-entry p)]
             [r (and entry (container-beside entry) ((container-beside entry) p n part direction))])
        (unless (or (not r) (and (pair? r) (list? r) (for-all (lambda (d) (part-datum? d container-entry)) r)))
          (assertion-violation 'layout:define-container "a beside clause returned what is not a list of one or more parts or #f" r))
        (cond
          [r (replace-child! ix n r)]
          [(not (level? p)) (up p)]
          [else
           (wrap-part! 'layout:add-beside! ix atom
             (lambda (parts)
               (make (if (memq direction '(right down)) (list (car parts) part) (list part (car parts))))))]))))

  ;; A lock binds only the user's commands, so a locked part is a
  ;; refusal the user is told, not a caller's mistake.
  (define (check-unlocked who ix n)
    (when (locked-in? ix n)
      (error who "a locked part")))

  (define (holds-locked? ix n)
    (or (locked-in? ix n)
        (let below ([n n])
          (exists (lambda (c) (or (document:node-attribute c 'locked #f) (below c))) (kids-of ix n)))))

  (define (check-holds-no-locked who ix n)
    (when (holds-locked? ix n)
      (error who "a locked part")))

  ;; A lock keeps a part from being destroyed or replaced, and keeps the
  ;; parts inside it as they are; the part may still move.
  (define (shift-part! who ix n step)
    (let ([p (parent-part ix n)])
      (and p
           (let* ([ks (kids-of ix p)] [k (position-in n ks)] [j (fx+ k step)])
             (and (fx>= j 0) (fx< j (length ks))
                  (let ([old (datums ix ks)])
                    (check-unlocked who ix p)
                    (set-children! ix p old
                      (replacing (replacing old k (list (list-ref old j))) j (list (list-ref old k))))
                    (list-ref old k)))))))

  (define (rebuilt ix top node new)
    (if (same-node? top node)
        new
        (let ([inner (rebuilt ix (car (kids-of ix top)) node new)])
          (if (null? inner) '() (list (with-children (node-datum ix top) inner))))))

  ;; From its container's first place a part goes before the container,
  ;; and from any other after it, so the order on screen is kept.
  (define (lift-part! who ix n)
    (let ([c (parent-in ix n)])
      (and c (parent-in ix c)
           (begin
             (check-unlocked who ix c)
             (if (level? c)
                 (let ([moved (take-place ix c (node-datum ix n))])
                   (replace-child! ix c (list moved))
                   moved)
                 (let out ([t c] [up (parent-in ix c)])
                   (cond
                     [(level? up) (let ([g (parent-in ix up)]) (and g (out up g)))]
                     [else
                      (check-unlocked who ix up)
                      (let* ([ks (kids-of ix c)] [k (position-in n ks)] [d (node-datum ix n)]
                             [rest (datums ix (remp (lambda (x) (same-node? x n)) ks))]
                             [left (cond
                                     [(null? rest) '()]
                                     [(and (null? (cdr rest)) (collapses? c)) (list (take-place ix c (car rest)))]
                                     [else (list (with-children (node-datum ix c) rest))])]
                             [kept (rebuilt ix t c left)]
                             [moved (if (null? kept) (take-place ix t d) (arrive c up d))])
                        (replace-child! ix t (if (fx= k 0) (cons moved kept) (append kept (list moved))))
                        moved)])))))))

  (define (level-part ix n)
    (if (level? n) (level-part ix (car (kids-of ix n))) n))

  ;; The container after the part takes it at its start, and one before
  ;; it at its end, the places on screen nearest the part's own. A level
  ;; holds one part, so a view that is a level's part is first wrapped in
  ;; a container of the moving part's container's kind.
  (define (lower-part! who ix n)
    (let ([c (parent-in ix n)])
      (and c (not (level? c))
           (let* ([ks (kids-of ix c)] [k (position-in n ks)]
                  [open? (lambda (x) (not (or (document:atom? x) (locked-in? ix x))))]
                  [after (find open? (list-tail ks (fx+ k 1)))]
                  [target (or after (find open? (reverse (list-head ks k))))])
             (and target
                  (let ([inner (level-part ix target)])
                    (check-unlocked who ix c)
                    (check-unlocked who ix inner)
                    (let* ([into (if (document:atom? inner)
                                     (with-children (without (node-datum ix c) (append '(title locked depth) (place-names ix c)))
                                                    (list (node-datum ix inner)))
                                     (node-datum ix inner))]
                           [moved (if (document:atom? inner) (node-datum ix n) (arrive c inner (node-datum ix n)))]
                           [filled (with-children into (if after (cons moved (cddr into)) (append (cddr into) (list moved))))]
                           [target-datum (car (rebuilt ix target inner (list filled)))]
                           [old (datums ix ks)]
                           [new (remove-at (replacing old (position-in target ks) (list target-datum)) k)])
                      (if (and (null? (cdr new)) (collapses? c))
                          (replace-child! ix c (list (take-place ix c target-datum)))
                          (set-children! ix c old new))
                      moved)))))))

  (define (place-names ix n)
    (let ([p (parent-in ix n)]) (if p (child-attributes-of p) '())))

  (define (remove-at ds k) (append (list-head ds k) (list-tail ds (fx+ k 1))))

  (define (unlocked-view-in? ix n)
    (exists (lambda (a) (and (holds-range? a (document:node-start n) (document:node-end n)) (not (locked-node? a))))
            (index-atoms)))

  (define (raise-part! who ix n)
    (let ([c (parent-part ix n)])
      (and c
           (begin
             (check-unlocked who ix c)
             (for-each (lambda (x)
                         (unless (same-node? x n)
                           (check-holds-no-locked who ix x)))
                       (kids-of ix c))
             (unless (or (unlocked-view-in? ix n) (unlocked-atoms-outside (document:node-start c) (document:node-end c)))
               (error who "the last view that is not locked"))
             (let ([moved (take-place ix c (node-datum ix n))])
               (replace-child! ix c (list moved))
               moved)))))

  ;; Layout does not know which attribute weighs a child, so the children
  ;; share the container's numeric place attributes, such as a strip's
  ;; size, equally. A level holds one part, so only a container of one
  ;; part is spliced into one.
  (define (splice-part! who ix n)
    (let ([g (parent-in ix n)] [ks (kids-of ix n)])
      (and g (pair? ks) (or (not (level? g)) (null? (cdr ks)))
           (begin
             (check-unlocked who ix n)
             (let* ([names (child-attributes-of g)] [count (length ks)]
                    [shares (filter (lambda (a) (and (memq (car a) names) (real? (cdr a))))
                                    (datum-attributes (node-datum ix n)))]
                    [moved (map (lambda (d)
                                  (if (level? g)
                                      (take-place ix n d)
                                      (arrive n g (with-attributes d
                                                    (append (remp (lambda (a) (assq (car a) shares)) (datum-attributes d))
                                                            (map (lambda (a) (cons (car a) (/ (cdr a) count))) shares))))))
                                (datums ix ks))])
               (replace-child! ix n moved)
               (car moved))))))

  ;; A level around a level, or around a level's part, would mark one
  ;; boundary twice, so that wrap changes nothing.
  (define (wrap-part! who ix n make)
    (let* ([p (parent-in ix n)]
           [place (child-attributes-of p)]
           [d (node-datum ix n)]
           [w (make (list (without d place)))])
      (unless (and (list? w) (fx>= (length w) 3) (symbol? (car w)) (container-entry (car w)) (attributes? (cadr w)))
        (assertion-violation who "not the datum of a container" w))
      (check-unlocked who ix p)
      (and (not (and (level-datum? w) (or (level? n) (level? p))))
           (let ([moved (with-attributes w (append (cadr w) (filter (lambda (a) (memq (car a) place)) (datum-attributes d))))])
             (buffers:replace! layout-buffer (document:node-start n) (document:node-end n) moved)
             moved))))

  (define (deletion-successor ix n)
    (let ([next (or (sibling-part ix n -1) (sibling-part ix n 1))])
      (and next (node-datum ix next))))

  ;; A level is known to its history by an anchor right after its
  ;; opening, which follows edits around the level. An edit that removes
  ;; the level and puts it back, as a collapse or a move around it does,
  ;; deletes the anchor, so the level is also known as the level so many
  ;; out from its first view, which such an edit leaves as it was.
  (define-record-type history
    (sealed #t)
    (fields (mutable anchor) (mutable view) (mutable rank) (mutable back) (mutable forward)))

  (define histories '())

  (define (rank-of ix level)
    (let loop ([l (enclosing-level ix (lead-first ix level))] [k 1])
      (if (same-node? l level) k (loop (enclosing-level ix l) (fx+ k 1)))))

  (define (lead-first ix n) (if (document:atom? n) n (lead-first ix (car (kids-of ix n)))))

  (define (history-level! ix h)
    (if (buffers:anchor-deleted? (history-anchor h))
        (let ([a (index-atom ix (history-view h))])
          (and a
               (let ([level (zoom-level ix a (history-rank h))])
                 (and (fx= (rank-of ix level) (history-rank h))
                      (fx= (atom-id (lead-first ix level)) (history-view h))
                      (not (find (lambda (g) (anchored-at? g (fx+ (document:node-start level) 1))) histories))
                      (begin
                        (history-anchor-set! h (buffers:anchor layout-buffer (fx+ (document:node-start level) 1)))
                        level)))))
        (let ([n (document:token (index-doc ix) (fx- (buffers:anchor-position (history-anchor h)) 1))])
          (and (document:node? n) (not (document:atom? n)) (level? n) n))))

  (define (anchored-at? h at)
    (and (not (buffers:anchor-deleted? (history-anchor h))) (fx= (buffers:anchor-position (history-anchor h)) at)))

  ;; Histories are found again one at a time, in order, since one found
  ;; by its view may not take a level another history already holds.
  (define (locate-histories! ix)
    (set! histories
      (let loop ([hs histories])
        (if (null? hs)
            '()
            (let* ([h (car hs)] [level (history-level! ix h)])
              (if level
                  (begin
                    (history-view-set! h (atom-id (lead-first ix level)))
                    (history-rank-set! h (rank-of ix level))
                    (cons h (loop (cdr hs))))
                  (loop (cdr hs))))))))

  ;; Levels move only with the layout's document.
  (define located-doc #f)

  (define (note-history-levels!)
    (unless (eq? (layout-doc) located-doc)
      (let ([ix (current-index)])
        (locate-histories! ix)
        (move-root-history! ix))
      (set! located-doc (layout-doc))))

  (define (history-of ix level create?)
    (let ([at (fx+ (document:node-start level) 1)])
      (define (here? h) (anchored-at? h at))
      (or (find here? histories)
          (begin (locate-histories! ix) (find here? histories))
          (and create?
               (let ([h (make-history (buffers:anchor layout-buffer at) (atom-id (lead-first ix level)) (rank-of ix level) '() '())])
                 (set! histories (cons h histories))
                 h)))))

  ;; Parts outside a level persist for its views, so no history may move
  ;; them: a level holding a placed part, outside the levels inside it,
  ;; keeps none.
  (define (holds-placed? ix level)
    (let walk ([n (car (kids-of ix level))])
      (or (and (document:node-attribute n 'depth #f) #t)
          (and (not (document:atom? n)) (not (level? n)) (exists walk (kids-of ix n))))))

  (define (first-level-inside ix level)
    (let walk ([n (car (kids-of ix level))])
      (cond
        [(level? n) n]
        [(document:atom? n) #f]
        [else (exists walk (kids-of ix n))])))

  ;; An interior is kept as the layout's document, which no edit
  ;; changes, with its range and the names of the buffers its views
  ;; showed, so a command records it without making its datum; and with
  ;; each view's point, which Emacs's window configurations keep too but
  ;; whose moves are no change.
  (define-record-type interior
    (sealed #t)
    (fields doc start end atoms names points))

  (define (interior-of doc start end atoms buffers points)
    (make-interior doc start end atoms (map (lambda (b) (and b (buffers:name b))) buffers) points))

  (define (by-view i field) (map (lambda (a x) (cons (atom-id a) x)) (interior-atoms i) (field i)))

  (define (interior-datum i)
    (let ([names (by-view i interior-names)])
      (refreshed (car (document:datums (document:slice (interior-doc i) (interior-start i) (interior-end i))))
                 (lambda (id) (let ([p (assv id names)]) (and p (cdr p)))))))

  (define (current-interior ix level)
    (let* ([part (car (kids-of ix level))] [atoms (atoms-in ix part)])
      (interior-of (index-doc ix) (document:node-start part) (document:node-end part)
                   atoms (map atom-buffer atoms) (map atom-point atoms))))

  ;; A command's level, and the views in it, change only with the
  ;; layout's document, which most commands leave as it was, so a command
  ;; in the level of the one before reuses them and reads afresh only the
  ;; views' buffers and points.
  (define-record-type scope
    (sealed #t)
    (fields doc version level-start history start end atoms))

  (define-record-type before
    (sealed #t)
    (fields scope buffers points))

  (define last-scope #f)
  (define pending #f)
  (define done-command #f)

  (define (atoms-in ix part)
    (let ([s (document:node-start part)] [e (document:node-end part)])
      (filter (lambda (a) (holds-range? a s e)) (index-atom-list ix))))

  (define (atom-buffer a) (views:buffer (view-of a)))

  (define (atom-point a) (views:point (view-of a)))

  (define (scope-of ix level)
    (let ([last last-scope])
      (if (and last (eq? (scope-doc last) (index-doc ix)) (fx= (scope-level-start last) (document:node-start level)))
          last
          (let ([part (car (kids-of ix level))])
            (set! last-scope
              (make-scope (index-doc ix) (buffers:version layout-buffer) (document:node-start level)
                          (and (not (holds-placed? ix level)) (history-of ix level #t))
                          (document:node-start part) (document:node-end part) (atoms-in ix part)))
            last-scope))))

  (define (note-before!)
    (set! pending #f)
    (let* ([ix (current-index)] [a (index-atom ix (selected-id))])
      (when (and a (> (history-limit) 0))
        (let ([sc (scope-of ix (enclosing-level ix a))])
          (when (scope-history sc)
            (let ([views (map view-of (scope-atoms sc))])
              (set! pending (make-before sc (map views:buffer views) (map views:point views)))))))))

  ;; An edit at the level's opening or closing may rebuild the level, so
  ;; it counts; when the buffer no longer keeps the edits, any may have
  ;; reached the interior.
  (define (interior-edited? sc)
    (and (not (eq? (layout-doc) (scope-doc sc)))
         (let ([edits (buffers:edits-since layout-buffer (scope-version sc))])
           (or (not edits)
               (let loop ([es edits] [lo (scope-start sc)] [hi (scope-end sc)])
                 (and (pair? es)
                      (let* ([e (car es)] [s (buffers:edit-start e)] [r (buffers:piece-length (buffers:edit-removed e))])
                        (cond
                          [(fx< (fx+ s r) lo)
                           (let ([shift (fx- (buffers:piece-length (buffers:edit-inserted e)) r)])
                             (loop (cdr es) (fx+ lo shift) (fx+ hi shift)))]
                          [(fx> s hi) (loop (cdr es) lo hi)]
                          [else #t]))))))))

  ;; Making the two datums is most of what recording costs, and an
  ;; interior no edit reached, or whose length or views changed, is told
  ;; without them. The scope found after a change is the next command's,
  ;; if it starts in this level.
  (define (changed-interior b)
    (let* ([ix (current-index)] [sc (before-scope b)] [atoms (scope-atoms sc)] [edited? (interior-edited? sc)])
      (and (or edited? (not (for-all (lambda (a buffer) (eq? (atom-buffer a) buffer)) atoms (before-buffers b))))
           (let ([level (history-level! ix (scope-history sc))])
             (and level
                  (let ([was (interior-of (scope-doc sc) (scope-start sc) (scope-end sc) atoms (before-buffers b) (before-points b))]
                        [now (scope-of ix level)])
                    (and (or (and edited?
                                  (or (not (fx= (fx- (scope-end now) (scope-start now)) (fx- (scope-end sc) (scope-start sc))))
                                      (not (fx= (length (scope-atoms now)) (length atoms)))
                                      (not (for-all (lambda (x y) (eqv? (atom-id x) (atom-id y))) (scope-atoms now) atoms))))
                             (not (equal? (interior-datum was) (interior-datum (current-interior ix level)))))
                         was)))))))

  ;; As Emacs's tab-bar history, a change is recorded once per command,
  ;; and not again for the same command repeated in sequence, such as a
  ;; resize key held down.
  (define (note-after! command)
    (let* ([b pending] [was (and b (changed-interior b))])
      (set! pending #f)
      (when (and was (not (eq? command done-command)))
        (let ([h (scope-history (before-scope b))])
          (history-back-set! h (list-head* (cons was (history-back h)) (history-limit)))))
      (set! done-command (and was command))))

  (define (list-head* ls n) (if (fx< n (length ls)) (list-head ls n) ls))

  ;; A view the restored interior names that is now elsewhere in the
  ;; layout gets a new view of its buffer, so no view is named twice.
  (define (restore-interior! ix level d made!)
    (let ([outside (filter (lambda (a) (not (holds-range? a (document:node-start level) (document:node-end level))))
                           (index-atom-list ix))])
      (let fresh ([d d])
        (cond
          [(vector? d)
           (let ([id (cdr (assq 'view (vector-ref d 1)))])
             (if (exists (lambda (a) (eqv? (atom-id a) id)) outside)
                 (let ([v (views:make (views:buffer (view-of (index-atom ix id))))])
                   (made! id v)
                   (vector 'views:view (map (lambda (a) (if (eq? (car a) 'view) (cons 'view (views:id v)) a)) (vector-ref d 1))))
                 d))]
          [else (cons* (car d) (cadr d) (map fresh (cddr d)))]))))

  ;; An atom's buffer is the one its view showed when it was recorded, so
  ;; its point is a position in that buffer and nowhere else. A view whose
  ;; buffer was killed since would wait for a buffer of its name, so it
  ;; shows another, as Emacs's set-window-configuration does.
  (define (show-recorded! d points)
    (let walk ([d d])
      (if (vector? d)
          (let* ([id (cdr (assq 'view (vector-ref d 1)))]
                 [v (view-of (index-atom (current-index) id))]
                 [b (let ([p (assq 'buffer (vector-ref d 1))]) (and p (buffers:find (cdr p))))]
                 [p (let ([p (assv id points)]) (and p (cdr p)))])
            (cond
              [b
               (unless (eq? (views:buffer v) b)
                 (views:set-buffer! v b))
               (when p
                 (views:set-point! v (fxmin p (fx- (document:length (buffers:document b)) 1))))]
              [(not (views:buffer v)) (views:replace-buffer! v)]))
          (for-each walk (cddr d)))))

  ;; A cancel between the replace and the lists' update would lose an
  ;; entry or keep one twice; Tuna's dynamic-wind holds cancels off while
  ;; its in runs. A refused restore leaves the lists as they were, and
  ;; the views made for it, which no part names, go.
  (define (history-step! who back?)
    (let* ([ix (current-index)] [level (enclosing-level ix (reference-atom ix))]
           [h (and (not (holds-placed? ix level)) (history-of ix level #f))]
           [entries (if h (if back? (history-back h) (history-forward h)) '())])
      (when (null? entries)
        (error who (if back? "no more back history in this level" "no more forward history in this level")))
      (let ([now (current-interior ix level)] [part (car (kids-of ix level))] [selected (selected-id)] [entry (car entries)])
        (dynamic-wind
          (lambda ()
            (let ([made '()] [restored? #f])
              (dynamic-wind
                void
                (lambda ()
                  (let ([d (restore-interior! ix level (interior-datum entry) (lambda (id v) (set! made (cons (cons id v) made))))]
                        [points (by-view entry interior-points)])
                    (buffers:replace! layout-buffer (document:node-start part) (document:node-end part) d)
                    (set! restored? #t)
                    (if back?
                        (begin (history-back-set! h (cdr entries)) (history-forward-set! h (cons now (history-forward h))))
                        (begin (history-forward-set! h (cdr entries)) (history-back-set! h (cons now (history-back h)))))
                    (show-recorded! d (append (map (lambda (m) (cons (views:id (cdr m)) (let ([p (assv (car m) points)]) (and p (cdr p)))))
                                                   made)
                                              points))))
                (lambda () (unless restored? (for-each (lambda (m) (views:drop! (cdr m))) made))))))
          void void)
        (let ([ix (current-index)])
          (unless (index-atom ix selected)
            (let* ([level (history-level! ix h)] [a (and level (most-recent-atom ix (atoms-in ix level) view-order))])
              (when (and a (not (locked-in? ix a))) (select-id! (atom-id a)))))))))

  ;; A level a plugin's part made around the user's windows holds exactly
  ;; what the root held before, so the root's history becomes its own.
  (define (move-root-history! ix)
    (let* ([root (root-node)] [h (find (lambda (h) (anchored-at? h (fx+ (document:node-start root) 1))) histories)])
      (when (and h (or (pair? (history-back h)) (pair? (history-forward h))) (holds-placed? ix root))
        (let ([inner (first-level-inside ix root)])
          (when inner
            (let ([g (history-of ix inner #t)])
              (when (and (null? (history-back g)) (null? (history-forward g)))
                (history-back-set! g (history-back h))
                (history-forward-set! g (history-forward h)))))
          (history-back-set! h '())
          (history-forward-set! h '()))))))

(import %internals)

(define-syntax define-container
  (lambda (x)
    (define (invalid c) (syntax-violation 'layout:define-container "invalid clause" x c))
    (syntax-case x ()
      [(_ id clause ...)
       (identifier? #'id)
       (let loop ([clauses #'(clause ...)] [seen '()] [draw #f] [neighbour #'#f] [keymap #'#f]
                  [attributes '()] [collapse #'#f] [show-focused #'#f] [adopt #'#f] [beside #'#f])
         (if (null? clauses)
             (begin
               (unless draw
                 (syntax-violation 'layout:define-container "a draw clause is required" x))
               #`(begin
                   (buffers:define-kind id (content nodes) (consent check-parts) (keymap #,keymap))
                   (define-values ()
                     (begin
                       (register-container! (buffers:kind-name (buffers:constructor-kind id)) #,draw #,neighbour '#,(datum->syntax #'id attributes)
                                            #,collapse #,show-focused #,adopt #,beside)
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
                   [(draw) (loop rest seen (expression) neighbour keymap attributes collapse show-focused adopt beside)]
                   [(neighbour) (loop rest seen draw (expression) keymap attributes collapse show-focused adopt beside)]
                   [(keymap) (loop rest seen draw neighbour (expression) attributes collapse show-focused adopt beside)]
                   [(child-attributes)
                    (syntax-case c ()
                      [(_ a ...) (for-all identifier? #'(a ...))
                       (loop rest seen draw neighbour keymap (syntax->datum #'(a ...)) collapse show-focused adopt beside)]
                      [_ (invalid c)])]
                   [(collapse) (loop rest seen draw neighbour keymap attributes (flag) show-focused adopt beside)]
                   [(show-focused) (loop rest seen draw neighbour keymap attributes collapse (flag) adopt beside)]
                   [(adopt) (loop rest seen draw neighbour keymap attributes collapse show-focused (expression) beside)]
                   [(beside) (loop rest seen draw neighbour keymap attributes collapse show-focused adopt (expression))]
                   [else (invalid c)])))))]
      [_ (syntax-violation 'layout:define-container "expected (layout:define-container id clause ...)" x)])))

(define (screen client)
  (unless (web:client? client)
    (assertion-violation 'layout:screen "not a client" client))
  (check-main-thread 'layout:screen)
  (haml (:div.layout-screen ([data-view (views:id screen-view)] [data-version (buffers:version buffer)]
                             [data-showing (views:shown-count screen-view)])
          (draw-layout client)
          (draw-popups client))))

(define (selected-view)
  (check-main-thread 'layout:selected-view)
  (view-of (atom-of (selected-id))))

(define (select! view)
  (check-view 'layout:select! view)
  (check-main-thread 'layout:select!)
  (let ([id (views:id view)])
    (unless (atom-of id)
      (assertion-violation 'layout:select! "not a view in the layout" view))
    (select-id! id)
    (void)))

(define (deselect! view)
  (check-view 'layout:deselect! view)
  (check-main-thread 'layout:deselect!)
  (deselect-id! (views:id view)))

(define (zoomed-view)
  (check-main-thread 'layout:zoomed-view)
  (let ([z (current-zoom)])
    (and z (view-of (index-atom (current-index) (car z))))))

(define (views)
  (check-main-thread 'layout:views)
  (shown-views))

(define (neighbour view direction)
  (check-view 'layout:neighbour view)
  (check-direction 'layout:neighbour direction)
  (check-main-thread 'layout:neighbour)
  (let* ([id (views:id view)] [ix (index-of-id id)])
    (unless ix
      (assertion-violation 'layout:neighbour "not a view in the layout" view))
    (neighbour-of ix (index-atom ix id) direction)))

(define (add-beside! view part direction make)
  (check-view 'layout:add-beside! view)
  (check-direction 'layout:add-beside! direction)
  (check-main-thread 'layout:add-beside!)
  (unless (part-datum? part container-entry)
    (assertion-violation 'layout:add-beside! "not a part" part))
  (unless (procedure? make)
    (assertion-violation 'layout:add-beside! "not a procedure" make))
  (let* ([ix (current-index)] [a (index-atom ix (views:id view))])
    (unless a
      (assertion-violation 'layout:add-beside! "not a view in the layout" view))
    (when (locked-in? ix a)
      (assertion-violation 'layout:add-beside! "a locked view" view))
    (beside-in! ix a part direction make)
    (void)))

(define (selection-order)
  (check-main-thread 'layout:selection-order)
  (order-views))

(tables:define-table keymap "The layout's keymap, last on the focus path and for mouse keys on the layout's own drawing.")

(define (%draw-level node shown focused draw-child client)
  (haml (:div.layout-level ([class (drawn-part-class node)]) (map draw-child shown))))

(buffers:define-kind level (content nodes) (consent check-level))

(define-values ()
  (begin (register-container! (buffers:kind-name (buffers:constructor-kind level)) %draw-level #f '() #f #f #f #f) (values)))

(define (%draw-popups node shown focused draw-child client)
  (haml (:div.layout-popups (map draw-child shown))))

;; Popups come and go, so their root may be empty.
(buffers:define-kind popups-root (content nodes) (consent check-popup-parts))

(define-values ()
  (begin (register-container! (buffers:kind-name (buffers:constructor-kind popups-root)) %draw-popups #f '() #f #f #f #f) (values)))

(define buffer (open-layout! (popups-root '())))

(define popups-buffer (opened-popups))

;; The layout's own drawing is a view of its buffer that no part shows,
;; so a click on it is a mouse key at a position in the buffer.
(define screen-view (views:make buffer))

(hooks:define-hook selection-changed
  "Called once at the end of each batch in which the selected view changed, with the view selected and the one selected when it was last called, or #f when that one has left the layout.")

;; The view is known by its number, since a view that left the layout is
;; dropped by the end of the batch, and a dropped view answers nothing.
(define %told-selection (selected-id))

;; Told at the end of the batch, whatever made the change, as Emacs runs
;; window-selection-change-functions at redisplay: a selection a job's
;; callback makes runs no command, and one undone within the batch is
;; none.
(define (%tell-selection!)
  (let ([id (selected-id)] [previous (atom-of %told-selection)])
    (unless (eqv? id %told-selection)
      (set! %told-selection id)
      (selection-changed (selected-view) (and previous (view-of previous))))))

(define (view-node view)
  (check-view 'layout:view-node view)
  (check-main-thread 'layout:view-node)
  (index-atom (current-index) (views:id view)))

(define (popup-node view)
  (check-view 'layout:popup-node view)
  (check-main-thread 'layout:popup-node)
  (index-atom (popups-index) (views:id view)))

(define (part-view node)
  (check-main-thread 'layout:part-view)
  (let-values ([(ix n) (part-of 'layout:part-view node)])
    (view-of (most-recent-atom ix (atoms-in ix n) (current-order)))))

(define (part-title node)
  (check-main-thread 'layout:part-title)
  (let-values ([(ix n) (part-of 'layout:part-title node)])
    (title-of ix n)))

(define (locked? node)
  (check-main-thread 'layout:locked?)
  (let-values ([(ix n) (part-of 'layout:locked? node)])
    (locked-in? ix n)))

(define (level-of view)
  (check-view 'layout:level-of view)
  (check-main-thread 'layout:level-of)
  (let* ([ix (current-index)] [a (index-atom ix (views:id view))])
    (and a (enclosing-level ix a))))

;; A plugin removes its own locked part with this procedure; the lock
;; binds only the user's commands.
(define (delete-part! node)
  (check-main-thread 'layout:delete-part!)
  (let-values ([(ix n) (part-of 'layout:delete-part! node)])
    (remove-part! ix n)
    (void)))

(define (deletion-refusal node)
  (check-main-thread 'layout:deletion-refusal)
  (let-values ([(ix n) (part-of 'layout:deletion-refusal node)])
    (removal-refusal ix (removed-part ix n))))

(define (set-part-attribute! node key value)
  (check-main-thread 'layout:set-part-attribute!)
  (unless (symbol? key)
    (assertion-violation 'layout:set-part-attribute! "not a symbol" key))
  (unless (plain-data:plain-data? value)
    (assertion-violation 'layout:set-part-attribute! "not plain data" value))
  (let-values ([(ix n) (part-of 'layout:set-part-attribute! node)])
    (let* ([d (node-datum ix n)] [old (datum-attributes d)]
           [kept (remp (lambda (a) (eq? (car a) key)) old)]
           [new (if value (append kept (list (cons key value))) kept)])
      (unless (equal? new old)
        (buffers:replace! (if (eq? ix (current-index)) buffer popups-buffer) (document:node-start n) (document:node-end n)
          (with-attributes d new)))
      (void))))

(define (pressed-part event container)
  (unless (keys:event? event)
    (assertion-violation 'layout:pressed-part "not an event" event))
  (let* ([kind (and (procedure? container) (buffers:constructor-kind container))]
         [name (and kind (buffers:kind-name kind))])
    (unless (and name (container-entry name))
      (assertion-violation 'layout:pressed-part "not a container kind" container))
    (let* ([posn (keys:event-start event)] [v (views:posn-view posn)] [child (views:posn-node posn)]
           [parent (and v child (eq? (views:buffer v) buffer)
                        (document:enclosing (buffers:document buffer) (document:node-start child)))])
      (if (and parent (eq? (document:node-kind parent) name))
          (values parent child)
          (values #f #f)))))

(define (%positive-count? v) (and (fixnum? v) (fx> v 0)))

(options:define-option min-width 10 %positive-count?
  "The fewest columns a mouse drag leaves a part along a row, such as a part of a row split or a column of a row strip.")

(options:define-option min-height 4 %positive-count?
  "The fewest lines a mouse drag leaves a part along a column, such as a part of a column split or a column of a column strip.")

(define-record-type (drag-change %make-drag-change drag-change?)
  (sealed #t)
  (fields index old new))

(define (%not-a-drag-answer who answer)
  (error who "not a drag answer" answer))

(define (%drag-change who entry)
  (let ([field (lambda (name) (let ([p (and (list? entry) (for-all pair? entry) (assoc name entry))]) (and p (cdr p))))])
    (let ([index (field "index")] [old (field "old")] [new (field "new")])
      (unless (and (fixnum? index) (real? old) (finite? old) (>= old 0) (real? new) (finite? new) (> new 0))
        (%not-a-drag-answer who entry))
      (%make-drag-change index (exact old) (exact new)))))

;; A page answers null when it has no drag to give, as one without the
;; page's script does, and web gives #f for a client gone.
(define (%drag-changes who answer indexes)
  (cond
    [(or (not answer) (eq? answer 'null)) '()]
    [(vector? answer)
     (let ([changes (map (lambda (e) (%drag-change who e)) (vector->list answer))])
       (let loop ([seen '()] [cs changes])
         (unless (null? cs)
           (let ([k (drag-change-index (car cs))])
             (when (or (memv k seen) (not (memv k indexes)))
               (%not-a-drag-answer who answer))
             (loop (cons k seen) (cdr cs)))))
       changes)]
    [else (%not-a-drag-answer who answer)]))

;; The page leaves the lengths it reached until a screen brings the
;; stored ones, so a drag that ends any other way has it put them back. A
;; stop passes every handler, so a wind sees the task leave; its after
;; thunk also runs at each pause, which is no leaving.
(define (ask-drag who client part name question indexes store!)
  (unless (symbol? who)
    (assertion-violation 'layout:ask-drag "not a symbol" who))
  (unless (web:client? client)
    (assertion-violation 'layout:ask-drag "not a client" client))
  (let-values ([(ix n) (part-of 'layout:ask-drag part)])
    (unless (eq? ix (current-index))
      (assertion-violation 'layout:ask-drag "not a part of the layout" part)))
  (unless (and (list? indexes) (for-all fixnum? indexes))
    (assertion-violation 'layout:ask-drag "not a list of part indexes" indexes))
  (unless (procedure? store!)
    (assertion-violation 'layout:ask-drag "not a procedure" store!))
  (let ([t (current-task)] [start (document:node-start part)] [version (buffers:version buffer)]
        [was (node-datum (current-index) part)] [ended #f])
    (dynamic-wind
      void
      (lambda ()
        (let ([changes (%drag-changes who (web:ask-page client name question) indexes)])
          (when (pair? changes)
            (let* ([p (buffers:map-position-after buffer start version)]
                   [now (and p (document:token (buffers:document buffer) p))])
              (unless (and (document:node? now) (equal? (node-datum (current-index) now) was))
                (error who "the layout changed during the drag"))
              (store! now changes))))
        (set! ended #t))
      (lambda ()
        (unless (or ended (and t (memq (task-state t) '(paused woken))))
          (web:call-page! client "layout-drag-restore" #f))))))

(define (draw-view-atom node view client)
  (list (views:draw view client)))

(define (%check-action-result who result)
  (unless (or (not result) (views:view? result))
    (assertion-violation who "an action returned what is not a view or #f" result))
  (unless (or (not result) (atom-of (views:id result)))
    (assertion-violation who "an action returned a view not in the layout" result))
  result)

(define (%showing b vs)
  (let ([shown (filter (lambda (v) (eq? (views:buffer v) b)) vs)])
    (cond
      [(null? shown) #f]
      [(memq (selected-view) shown) (selected-view)]
      [else (car shown)])))

(define (find-view b)
  (unless (buffers:buffer? b)
    (assertion-violation 'layout:find-view "not a buffer" b))
  (check-main-thread 'layout:find-view)
  (%showing b (map view-of (index-atoms))))

(define inhibit-same-view?
  (make-thread-parameter #f
    (lambda (v)
      (unless (boolean? v)
        (assertion-violation 'layout:inhibit-same-view? "not a boolean" v))
      v)))

(define (reuse-view b)
  (unless (buffers:buffer? b)
    (assertion-violation 'layout:reuse-view "not a buffer" b))
  (check-main-thread 'layout:reuse-view)
  (%showing b (if (inhibit-same-view?) (remq (selected-view) (views)) (views))))

;; The commands that mean the other views act in the level of the view
;; selected last in the layout, so in a popup, such as a prompt, they act
;; where the user was.
(define (%level-units)
  (let* ([ix (current-index)] [a (reference-atom ix)])
    (values ix a (level-units ix (enclosing-level ix a) (visible-atoms)))))

(define (use-other-view b)
  (unless (buffers:buffer? b)
    (assertion-violation 'layout:use-other-view "not a buffer" b))
  (or (reuse-view b)
      (let-values ([(ix a units) (%level-units)])
        (let* ([selected (selected-id)]
               [level (enclosing-level ix a)]
               [candidates (filter (lambda (u) (not (or (eqv? (atom-id u) selected) (locked-in? ix u) (unit-placed? ix u level))))
                                   units)]
               [order (current-order)]
               [age (lambda (u) (let ([m (memv (atom-id u) order)]) (if m (length m) 0)))]
               [showed (filter (lambda (u) (memq b (views:previous-buffers (view-of u)))) candidates)]
               [newest (lambda (us) (fold-left (lambda (best u) (if (> (age u) (age best)) u best)) (car us) (cdr us)))]
               [oldest (lambda (us) (fold-left (lambda (best u) (if (< (age u) (age best)) u best)) (car us) (cdr us)))])
          (and (pair? candidates)
               (let ([v (view-of (if (pair? showed) (newest showed) (oldest candidates)))])
                 (views:set-buffer! v b)
                 v))))))

(options:define-option display-action use-other-view procedure?
  "The action layout:display-buffer tries after the rules and the caller's.")

(define-record-type %display
  (sealed #t)
  (fields buffer made?))

;; Weak, so a dropped view takes its record with it.
(define %displays (make-weak-eq-hashtable))

(define (%views-and-buffers)
  (map (lambda (a) (let ([v (view-of a)]) (cons v (views:buffer v))))
       (append (index-atoms) (index-atom-list (popups-index)))))

;; A view that already showed the buffer keeps its record, so a second
;; display of it is undone as the first.
(define (%note-display! v b before)
  (let ([was (assq v before)])
    (cond
      [(not was) (eq-hashtable-set! %displays v (make-%display b #t))]
      [(eq? (cdr was) b) (void)]
      [else (eq-hashtable-set! %displays v (make-%display b #f))])
    v))

(define display-buffer
  (case-lambda
    [(b) (display-buffer b #f)]
    [(b action)
     (unless (buffers:buffer? b)
       (assertion-violation 'layout:display-buffer "not a buffer" b))
     (unless (or (not action) (procedure? action))
       (assertion-violation 'layout:display-buffer "not a procedure" action))
     (check-main-thread 'layout:display-buffer)
     (let ([before (%views-and-buffers)] [overriding (%overriding)])
       (%note-display!
         (or (and overriding (unbox overriding) (not (buffers:internal-name? (buffers:name b)))
                  (let ([action (unbox overriding)])
                    (set-box! overriding #f)
                    (%check-action-result 'layout:display-buffer (action b))))
             (exists (lambda (rule)
                       (and ((car rule) b) (%check-action-result 'layout:display-buffer ((cdr rule) b))))
                     (reverse (tables:entries display-rules)))
             (and action (%check-action-result 'layout:display-buffer (action b)))
             (%check-action-result 'layout:display-buffer ((display-action) b))
             (let ([v (selected-view)])
               (unless (eq? (views:buffer v) b) (views:set-buffer! v b))
               v))
         b before))]))

(hooks:define-hook after-switch-to-buffer
  "Called with the selected view, the buffer it showed and its point there, after layout:switch-to-buffer shows another buffer in it.")

(define (switch-to-buffer b)
  (unless (buffers:buffer? b)
    (assertion-violation 'layout:switch-to-buffer "not a buffer" b))
  (let* ([v (selected-view)] [ix (index-of-id (views:id v))] [overriding (%overriding)])
    (cond
      [(or (locked-in? ix (index-atom ix (views:id v)))
           (and overriding (unbox overriding) (not (buffers:internal-name? (buffers:name b)))))
       (let* ([overridden? (not (locked-in? ix (index-atom ix (views:id v))))]
              [before (map (lambda (shown) (list (car shown) (cdr shown) (views:point (car shown)))) (%views-and-buffers))]
              [shown (display-buffer b)]
              [was (assq shown before)])
         (select! shown)
         ;; A prefix such as C-x 4 4 sends the buffer to another view,
         ;; which is no jump from the place the selected view shows.
         (when (and was (cadr was) (not (eq? (cadr was) b)) (or (not overridden?) (eq? shown v)))
           (after-switch-to-buffer shown (cadr was) (caddr was))))]
      [else
       (let ([left (views:buffer v)])
         (unless (eq? left b)
           (let ([point (views:point v)])
             (views:set-buffer! v b)
             (when left (after-switch-to-buffer v left point)))))])
    (unless (buffers:internal-name? (buffers:name b))
      (buffers:move-to-front! b))))

(define %overriding (make-thread-parameter #f))

(define (call-with-overriding-action action thunk)
  (unless (procedure? action)
    (assertion-violation 'layout:call-with-overriding-action "not a procedure" action))
  (unless (procedure? thunk)
    (assertion-violation 'layout:call-with-overriding-action "not a procedure" thunk))
  (parameterize ([%overriding (box action)])
    (thunk)))

;; The action picks a view other than the selected one, and while a read
;; waits its prompt is selected, so the user's view is selected for it,
;; else it could take that view. It may also change what a view shows, as
;; use-other-view does, which would enter that view's history, so each
;; view is held in a preview while it runs; a view already in a preview is
;; an outer read's, and is left as it is.
(define (%display-view-for b selected overriding)
  (let* ([before (%views-and-buffers)]
         [held (filter (lambda (shown) (and (cdr shown) (not (views:previewing? (car shown))))) before)]
         [now (selected-view)])
    (for-each (lambda (shown) (views:preview-buffer! (car shown) (cdr shown))) held)
    (unless (eq? now selected) (select! selected))
    (let ([v (parameterize ([%overriding overriding]) (display-buffer b))])
      (unless (eq? now selected) (select! now))
      (for-each (lambda (shown) (unless (eq? (car shown) v) (views:end-preview! (car shown)))) held)
      (values v (not (assq v before)) (and (assq v held) #t)))))

;; The read starts from the view the user worked in, which at a prompt is
;; not the selected view. Its buffer, not the one asked about, is shown in
;; a view made for the read, so no buffer passed while previewing enters
;; that view's history.
;; A preview asks from a task of its own, outside the extent the overriding
;; action was given in, so the action is the one this call saw.
(define (call-with-display-view proc)
  (unless (procedure? proc)
    (assertion-violation 'layout:call-with-display-view "not a procedure" proc))
  (check-main-thread 'layout:call-with-display-view)
  (let ([overriding (%overriding)] [selected (view-of (reference-atom (current-index)))] [found #f] [made #f] [held? #f])
    (define (view b)
      (unless (buffers:buffer? b)
        (assertion-violation 'layout:call-with-display-view "not a buffer" b))
      (unless found
        (if (and overriding (unbox overriding))
            (let-values ([(v new? held) (%display-view-for (or (views:buffer selected) b) selected overriding)])
              (set! found v)
              (set! held? held)
              (when new? (set! made v))
              (set-box! overriding (lambda (b) (unless (eq? (views:buffer v) b) (views:set-buffer! v b)) v)))
            (set! found selected)))
      found)
    (define (release!)
      (when (and held? (views:previewing? found))
        (views:end-preview! found)))
    (call-with-values
      (lambda ()
        (guard (c [#t (release!)
                      (when (and made (atom-of (views:id made)))
                        (let ([ix (index-of-id (views:id made))])
                          (remove-part! ix (index-atom ix (views:id made)))))
                      (raise-object c)])
          (proc view)))
      (lambda results
        (release!)
        (apply values results)))))

(define (display-in-other-view b)
  (unless (buffers:buffer? b)
    (assertion-violation 'layout:display-in-other-view "not a buffer" b))
  (parameterize ([inhibit-same-view? #t])
    ((display-action) b)))

(define (display-in-selected-view b)
  (unless (buffers:buffer? b)
    (assertion-violation 'layout:display-in-selected-view "not a buffer" b))
  (let* ([v (selected-view)] [id (views:id v)] [ix (index-of-id id)])
    (and (eq? ix (current-index))
         (not (locked-in? ix (index-atom ix id)))
         (begin
           (unless (eq? (views:buffer v) b) (views:set-buffer! v b))
           v))))

;; Emacs's override waits through mouse events, as a click that only
;; moves point may come before the double click that shows a buffer, so a
;; click whose command displayed nothing hands the wrapper on.
(define (%overriding-wrapper action description)
  (letrec ([wrap (lambda (run)
                   (let ([overriding (box action)])
                     (call-with-values
                       (lambda () (parameterize ([%overriding overriding]) (run)))
                       (lambda results
                         (when (and (unbox overriding) (keys:event? (keys:command-event)))
                           (keys:wrap-next-command! wrap description))
                         (apply values results)))))])
    wrap))

;; Under M-x the keys that ran the prefix are M-x's, so the prefix is
;; named instead, set apart as Emacs shows [other-window].
(define (%prefix-description command)
  (let ([typed (keys:command-keys)])
    (if (and typed (eq? (keys:lookup (web:current-client) typed) command))
        typed
        (string-append "[" (symbol->string (commands:command-name command)) "]"))))

(commands:define-command (other-view-prefix)
  "Shows the buffer the next command displays in another view, which it selects."
  (let ([description (%prefix-description other-view-prefix)])
    (keys:wrap-next-command! (%overriding-wrapper display-in-other-view description) description)))

(commands:define-command (same-view-prefix)
  "Shows the buffer the next command displays in the selected view."
  (let ([description (%prefix-description same-view-prefix)])
    (keys:wrap-next-command! (%overriding-wrapper display-in-selected-view description) description)))

(commands:define-command (kill-buffer-and-view)
  "Kills the selected view's buffer and, when it is killed, deletes the view's part."
  (let* ([v (selected-view)] [id (views:id v)] [ix (index-of-id id)])
    (check-unlocked 'layout:kill-buffer-and-view ix (index-atom ix id))
    (when (buffers:kill! (views:buffer v))
      (let* ([ix (index-of-id id)] [a (index-atom ix id)])
        (check-removable 'layout:kill-buffer-and-view ix a)
        (remove-part! ix a)))))

(define (%after-other-view ix)
  (let ([b (reference-atom ix)] [selected (selected-id)])
    (filter (lambda (u) (not (or (eqv? (atom-id u) selected) (locked-in? ix u))))
            (level-units ix (enclosing-level ix b) (visible-atoms)))))

(define (other-views)
  (check-main-thread 'layout:other-views)
  (let-values ([(ix a units) (%level-units)])
    (let* ([id (selected-id)] [sx (index-of-id id)])
      (map view-of
           (if (other-view-in? sx (index-atom sx id))
               (%after-other-view ix)
               (%cycle-atoms ix a units))))))

(define (%select-other n)
  (let ([others (other-views)])
    (if (null? others)
        (ask:message "No other view to select")
        (let ([k (mod n (+ (length others) 1))])
          (unless (zero? k) (select! (list-ref others (- k 1))))))))

(commands:define-command (other-view [n (commands:prefix-number)])
  "Selects the view n places on in layout:other-views, back for a negative n."
  (%select-other n))

(commands:define-command (other-view-backward [n (commands:prefix-number)])
  "Selects the view n places back in layout:other-views."
  (%select-other (- n)))

(tables:define-table other-view-keymap "Keys that go on selecting views after C-x o or C-x O.")

(define (other-view-for-scrolling)
  (check-main-thread 'layout:other-view-for-scrolling)
  (let* ([id (selected-id)] [sx (index-of-id id)] [ix (current-index)])
    (or (if (or (not (eq? sx ix)) (other-view-in? sx (index-atom sx id)))
            (view-of (reference-atom ix))
            (find (lambda (v) (let ([b (views:buffer v)]) (and b (not (buffers:internal-name? (buffers:name b))))))
                  (other-views)))
        (error 'layout:other-view-for-scrolling "no other view"))))

(define (%in-other-view command)
  (views:call-with-view (other-view-for-scrolling) (lambda () (commands:run command))))

(commands:define-command (scroll-other-view)
  "Runs views:scroll-up in layout:other-view-for-scrolling."
  (%in-other-view views:scroll-up))

(commands:define-command (scroll-other-view-down)
  "Runs views:scroll-down in layout:other-view-for-scrolling."
  (%in-other-view views:scroll-down))

(commands:define-command (recenter-other-view)
  "Runs views:recenter-top-bottom in layout:other-view-for-scrolling."
  (%in-other-view views:recenter-top-bottom))

(define (%cycle-atoms ix a units)
  (let* ([selected (selected-id)]
         [level (enclosing-level ix a)]
         [px (popups-index)]
         [outside (append
                    (filter (lambda (u)
                              (and (not (holds-range? u (document:node-start level) (document:node-end level)))
                                   (other-view-in? ix u)))
                            (visible-atoms))
                    (filter (lambda (u) (other-view-in? px u)) (index-atom-list px)))]
         [joined (append units outside)]
         [m (memp (lambda (u) (eqv? (atom-id u) (atom-id a))) joined)]
         [from-a (if m (append m (list-head joined (fx- (length joined) (length m)))) joined)]
         [after (if (and m (eqv? (atom-id a) selected)) (cdr from-a) from-a)])
    (filter (lambda (u)
              (not (or (eqv? (atom-id u) selected)
                       (and (not (memq u outside)) (locked-in? ix u)))))
            after)))

(commands:define-command (delete-view)
  "Deletes the selected view's part; in the part mode, the selected part, then selects the part before it, else the one after."
  (let ([ix (current-index)])
    (if (in-part-mode?)
        (let* ([n (selection-in ix)] [next (and n (deletion-successor ix n))])
          (when n
            (check-holds-no-locked 'layout:delete-view ix n)
            (check-removable 'layout:delete-view ix n)
            (remove-part! ix n)
            (choose-datum! next)))
        (let* ([id (selected-id)] [ix (index-of-id id)] [a (index-atom ix id)])
          (check-unlocked 'layout:delete-view ix a)
          (check-removable 'layout:delete-view ix a)
          (remove-part! ix a)))))

(define (%other-unlocked-view? ix a)
  (exists (lambda (x) (and (not (same-node? x a)) (same-level? ix x a) (not (locked-in? ix x))))
          (index-atom-list ix)))

(define (%bury! who v)
  (let ([b (views:buffer v)])
    (when b (buffers:move-to-back! b))
    (unless (views:replace-buffer! v)
      (error who "no other buffer to show"))))

(commands:define-command (quit-view)
  "Moves the selected view's buffer to the back of buffers:all. Deletes the view's part if layout:display-buffer made it for the buffer the view shows; otherwise shows the view's previous buffer where the view left it, or deletes the part when there is none."
  (let* ([v (selected-view)] [id (views:id v)] [ix (index-of-id id)] [a (index-atom ix id)]
         [d (eq-hashtable-ref %displays v #f)]
         [d (and d (eq? (%display-buffer d) (views:buffer v)) d)])
    (check-unlocked 'layout:quit-view ix a)
    (eq-hashtable-delete! %displays v)
    (let ([deletable? (or (not (eq? ix (current-index))) (%other-unlocked-view? ix a))] [b (views:buffer v)])
      (cond
        [(and d (%display-made? d) deletable?)
         (remove-part! ix a)
         (when (and b (buffers:live? b)) (buffers:move-to-back! b))]
        [else
         (when b (buffers:move-to-back! b))
         (unless (views:replace-buffer! v)
           (if deletable?
               (remove-part! ix a)
               (error 'layout:quit-view "no other buffer to show")))]))
    (void)))

(define (%check-switchable who v)
  (let* ([id (views:id v)] [ix (index-of-id id)])
    (unless (eq? ix (current-index))
      (error who "Cannot switch buffers in a popup"))
    (check-unlocked who ix (index-atom ix id))))

(commands:define-command (bury-buffer)
  "Moves the selected view's buffer to the back of buffers:all and shows the view's previous buffer."
  (let ([v (selected-view)])
    (%check-switchable 'layout:bury-buffer v)
    (%bury! 'layout:bury-buffer v)))

(commands:define-command (previous-buffer [n (commands:prefix-number)])
  "Shows in the selected view its previous buffer, n times."
  (let ([v (selected-view)])
    (%check-switchable 'layout:previous-buffer v)
    (do ([k 0 (fx+ k 1)]) ((>= k n))
      (unless (views:previous-buffer! v)
        (error 'layout:previous-buffer "No previous buffer")))))

(commands:define-command (next-buffer [n (commands:prefix-number)])
  "Shows in the selected view its next buffer, n times."
  (let ([v (selected-view)])
    (%check-switchable 'layout:next-buffer v)
    (do ([k 0 (fx+ k 1)]) ((>= k n))
      (unless (views:next-buffer! v)
        (error 'layout:next-buffer "No next buffer")))))

(tables:define-table buffer-navigation-keymap "Keys that go on through a view's buffers after C-x <left> or C-x <right>.")

(commands:define-command (zoom [prefix (commands:prefix-argument)])
  "Zooms the selected view to fill its level; with a number n, the level n out; with C-u, the screen. When zoomed, shows the whole layout again."
  (if (current-zoom)
      (set-zoom! #f)
      (let* ([ix (current-index)] [a (index-atom ix (selected-id))])
        (when a
          (check-unlocked 'layout:zoom ix a)
          (let ([target (cond
                          [(pair? prefix) 'root]
                          [(and (fixnum? prefix) (fx> prefix 1)) prefix]
                          [else 1])])
            (when (same-node? (car (children (zoom-level ix a target))) a)
              (error 'layout:zoom "no other views in this level"))
            (set-zoom! (cons (atom-id a) target))))))
  (void))

(commands:define-command (mouse-select-view [event (keys:command-event)])
  "Selects the most recently used view of the part clicked in the layout's drawing, unless it is locked."
  (unless (keys:event? event)
    (assertion-violation 'layout:mouse-select-view "not an event" event))
  (let* ([posn (keys:event-start event)] [v (views:posn-view posn)] [p (views:posn-point posn)])
    (when (and v p (eq? (views:buffer v) buffer))
      (let* ([doc (buffers:document buffer)]
             [t (and (fx< p (document:length doc)) (document:token doc p))]
             [named (views:posn-node posn)]
             ;; A strip's placeholder or band stands for its column and is
             ;; sent as the column's start, whose next token is only the
             ;; column's first child.
             [part (cond
                     [(document:node? named) named]
                     [(and (document:node? t) (document:atom? t)) t]
                     [else (document:enclosing doc p)])]
             [ix (current-index)]
             [atom (and part (most-recent-atom ix (atoms-in ix part) (current-order)))])
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
  "Deletes every view in the selected view's level but the selected view, locked views and the views of the levels inside it, and ends the zoom."
  (let* ([ix (current-index)] [a (reference-atom ix)]
         [doomed (map atom-id
                      (filter (lambda (x)
                                (not (or (same-node? x a) (locked-in? ix x) (not (same-level? ix x a)))))
                              (index-atoms)))])
    (set-zoom! #f)
    ;; Each view goes in its own edit, and a cancel between two would leave
    ;; some; Tuna's dynamic-wind holds cancels off while its in runs.
    (dynamic-wind
      (lambda () (for-each (lambda (id) (let ([ix (current-index)]) (remove-part! ix (index-atom ix id)))) doomed))
      void void)
    (select! (view-of (index-atom (current-index) (atom-id a))))))

(tables:define-table part-mode-keymap
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
  "Moves the selected part out of its container, to beside it, passing through levels."
  (%edit! (lambda (ix n) (lift-part! 'layout:lift ix n))))

(commands:define-command (lower)
  "Moves the selected part into the nearest container among its siblings after it, as its first child, else before it, as its last, passing through levels."
  (%edit! (lambda (ix n) (lower-part! 'layout:lower ix n))))

(commands:define-command (raise)
  "Makes the selected part take its container's place, deleting its siblings."
  (%edit! (lambda (ix n) (raise-part! 'layout:raise ix n))))

(commands:define-command (splice)
  "Replaces the selected container with its children."
  (%edit! (lambda (ix n) (splice-part! 'layout:splice ix n))))

(commands:define-command (history-back)
  "Restores the selected view's level's interior as it was before the last command that changed it."
  (history-step! 'layout:history-back #t))

(commands:define-command (history-forward)
  "Restores the selected view's level's interior as it was before the last history-back."
  (history-step! 'layout:history-forward #f))

(tables:define-table history-keymap "Keys that go on through the window history after C-c <left> or C-c <right>.")

(define (%history-before command)
  (unless (or (eq? command history-back) (eq? command history-forward))
    (note-before!)))

(define (%history-after command) (note-after! command))

(commands:define-command (wrap-in-level)
  "Wraps the selected part in a level."
  (wrap! (lambda (parts) (apply level '() parts))))

(define %mode-press (make-thread-parameter #f))

(define (%handle-key client item)
  (let ([key (keys:item-key item)])
    (cond
      [(mode-key? part-mode-keymap client key)
       (parameterize ([%mode-press #t])
         (views:call-with-view screen-view (lambda () (keys:press! client key))))]
      [else
       (when (in-part-mode?) (leave-part-mode!))
       (views:call-with-view (selected-view) (lambda () (keys:press! client key)))])))

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
  (cond
    [(not posn) (if (view-node (selected-view)) (append (enclosing-keymaps) (list keymap)) (enclosing-keymaps))]
    [(let ([v (views:posn-view posn)]) (and v (eq? (views:buffer v) buffer))) (list keymap)]
    [else '()]))

(define (%keep-layout b) (not (or (eq? b buffer) (eq? b popups-buffer))))

;; Weak, so a client web has removed leaves no entry behind.
(define %failing (make-weak-eq-hashtable))

;; After a warning the code that raised it continues, so a guard here
;; lets a warning pass on to the core, which reports it and returns.
(define (%warning-only? c)
  (and (warning? c) (not (serious-condition? c))))

(define (%condition-text c)
  (call-with-string-output-port (lambda (p) (display-condition c p))))

;; A cancel is not a failure: whoever cancelled asked to stop work, and
;; the next batch draws this client again. The draw has succeeded once the
;; screen is made; clearing the mark after the send instead would leave
;; the client marked when a cancel lands between the two.
(define (%draw client title)
  (guard (c [(cancelled? c) (void)]
            [(not (%warning-only? c))
             (unless (hashtable-ref %failing client #f)
               (report c)
               (hashtable-set! %failing client #t))
             (web:send-screen! client (haml (:pre.layout-error (%condition-text c))) title)])
    (let ([html (screen client)])
      (hashtable-delete! %failing client)
      (web:send-screen! client html title))))

(define %title-failing #f)

;; Every client shows the one title, so a failure to make it is reported
;; once and costs the pages their name, not their screens.
(define (%page-title)
  (guard (c [(not (or (cancelled? c) (%warning-only? c)))
             (unless %title-failing
               (report c)
               (set! %title-failing #t))
             "Tuna"])
    (let ([title ((page-title) (shown-buffer-name (atom-of (selected-id))))])
      (unless (string? title)
        (assertion-violation 'layout:page-title "returned what is not a string" title))
      (set! %title-failing #f)
      title)))

;; A raise in note-batch, or in telling a selection, must not skip the
;; advice it encloses, which ends the batch for the plugins loaded before
;; this one; nor may a raise there stop the clients being drawn, or every
;; screen would freeze with nothing on it to act on.
(define (%end-batch ended)
  (guard (c [#t (report c)]) (note-batch))
  (guard (c [#t (report c)]) (%tell-selection!))
  (guard (c [(not (%warning-only? c)) (report c)])
    (ended))
  (let ([clients (web:clients)])
    (unless (null? clients)
      (let ([title (%page-title)])
        (for-each (lambda (client) (%draw client title)) clients)))))

(keys:bind! modes:special-keymap "q" quit-view)
(keys:bind! keys:global "C-x o" other-view)
(keys:bind! keys:global "C-x 0" delete-view)
(keys:bind! keys:global "C-x 1" zoom)
(keys:bind! keys:global "C-x O" other-view-backward)
(keys:bind! other-view-keymap "o" other-view)
(keys:bind! other-view-keymap "O" other-view-backward)
(tables:set! keys:repeat-keymaps other-view-keymap)
(keys:bind! keys:global "C-x 4 4" other-view-prefix)
(keys:bind! keys:global "C-x 4 1" same-view-prefix)
(keys:bind! keys:global "C-x 4 0" kill-buffer-and-view)
(keys:bind! keys:global "C-M-v" scroll-other-view)
(keys:bind! keys:global "M-<next>" scroll-other-view)
(keys:bind! keys:global "C-M-V" scroll-other-view-down)
(keys:bind! keys:global "M-<prior>" scroll-other-view-down)
(keys:bind! keys:global "C-M-L" recenter-other-view)
(keys:bind! keys:global "C-x <left>" previous-buffer)
(keys:bind! keys:global "C-x C-<left>" previous-buffer)
(keys:bind! keys:global "C-x <right>" next-buffer)
(keys:bind! keys:global "C-x C-<right>" next-buffer)
(keys:bind! buffer-navigation-keymap "<left>" previous-buffer)
(keys:bind! buffer-navigation-keymap "<right>" next-buffer)
(tables:set! keys:repeat-keymaps buffer-navigation-keymap)
(keys:bind! keys:global "s-i" select-up)
(keys:bind! keys:global "s-j" select-left)
(keys:bind! keys:global "s-k" select-down)
(keys:bind! keys:global "s-l" select-right)
(keys:bind! keys:global "s-<up>" select-up)
(keys:bind! keys:global "s-<left>" select-left)
(keys:bind! keys:global "s-<down>" select-down)
(keys:bind! keys:global "s-<right>" select-right)
(keys:bind! keys:global "s-'" part-mode)
(keys:bind! keys:global "C-x w w" part-mode)
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
(keys:bind! part-mode-keymap "w l" wrap-in-level)
(keys:bind! keymap "C-c <left>" history-back)
(keys:bind! keymap "C-c <right>" history-forward)
(keys:bind! history-keymap "<left>" history-back)
(keys:bind! history-keymap "<right>" history-forward)
(tables:set! keys:repeat-keymaps history-keymap)
(keys:bind! keymap "<mouse-1>" mouse-select-view)
(keys:bind! keymap "<down-mouse-1>" keys:ignore)
(hooks:add! keys:find-keymaps cursor-keymaps)
(hooks:add! keys:find-keymaps container-keymaps 90)
(hooks:add! commands:before-command %leave-on-other-input)
(hooks:add! commands:before-command %history-before)
(hooks:add! commands:after-command %history-after)
(hooks:add! buffers:kill-queries %keep-layout)
(tables:set! web:input-handlers "key" %handle-key)
(tables:set! web:stylesheets 'layout "layout/layout.css")
(tables:set! web:scripts 'layout "layout/layout.js")
(advice-add! batch-ended %end-batch)
(on-unload save-now!)
(on-unload (lambda () (views:drop! screen-view)))
