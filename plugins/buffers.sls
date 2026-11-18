#!tuna
(import (document) (jobs) (buffers spans) (buffers records))

(define-hook kill-queries)
(define-hook killed)
(define-hook after-edit)

(module %internals
  (check-main-thread check-buffer check-change check-position check-range check-layer check-anchor
   check-edit check-spans check-version check-kind check-layer-change check-layer-read
   make-buffer! find-buffer live-buffers buffer-live? rename-buffer! forget-buffer! with-current
   current-buffer frozen-document
   replace-content! splice-content! reconcile-node! edits-after map-position-through
   define-kind! find-kind stop-at next-stop-after previous-stop-before
   define-layer-type! layer-of layers-for layer-type-keymap-of
   set-layer-spans! add-layer-span! remove-layer-spans! layer-spans layer-spans-at travelling-spans-of
   make-anchor! anchor-current-position move-anchor! anchor-deleted-now?)

  (define main-thread (get-thread-id))

  (define (check-main-thread who)
    (unless (fx= (get-thread-id) main-thread)
      (assertion-violation who "not on the main thread")))

  (define (make-edit version start removed inserted removed-spans inserted-spans)
    (make-edit-record version start removed inserted removed-spans inserted-spans
      (document:length removed) (document:length inserted) (not (eq? removed inserted))))

  (define-table kinds)
  (define-table layer-types)

  (define by-name (make-hashtable string-hash string=?))
  (define made '())

  (define current-buffer (make-thread-parameter #f))

  (define empty-document (document:from-datum))
  (define typing-probe (document:from-datum "x"))

  (define (check-buffer who b)
    (unless (buffer-record? b)
      (assertion-violation who "not a buffer" b)))

  (define (buffer-live? b)
    (eq? (hashtable-ref by-name (buffer-name b) #f) b))

  (define (check-change who b)
    (check-buffer who b)
    (check-main-thread who)
    (unless (buffer-live? b)
      (assertion-violation who "not a live buffer" b)))

  (define (check-position who b p)
    (unless (and (fixnum? p) (fx<= 0 p (document:length (buffer-doc b))))
      (assertion-violation who "not a position in the buffer" p)))

  (define (check-range who b start end)
    (check-position who b start)
    (check-position who b end)
    (unless (fx<= start end)
      (assertion-violation who "the start is after the end" start end)))

  (define (check-layer who l)
    (unless (buffer-layer? l)
      (assertion-violation who "not a layer" l)))

  (define (check-anchor who a)
    (unless (buffer-anchor? a)
      (assertion-violation who "not an anchor" a)))

  (define (check-edit who e)
    (unless (edit-record? e)
      (assertion-violation who "not an edit" e)))

  (define (check-kind who k)
    (unless (kind-entry? k)
      (assertion-violation who "not a kind" k)))

  (define (check-version who b v)
    (unless (and (fixnum? v) (fx<= 0 v (buffer-version b)))
      (assertion-violation who "not a version of the buffer" v)))

  (define (check-layer-change who l)
    (check-layer who l)
    (check-change who (buffer-layer-buffer l)))

  (define (check-layer-read who l)
    (check-layer who l)
    (check-main-thread who))

  (define (span? s limit)
    (and (list? s) (fx= (length s) 3)
         (fixnum? (car s)) (fixnum? (cadr s))
         (fx<= 0 (car s) (cadr s) limit)))

  (define (check-spans who spans limit)
    (unless (and (list? spans) (for-all (lambda (s) (span? s limit)) spans))
      (assertion-violation who "not a list of spans within the range" spans)))

  (define (check-travelling who spans limit)
    (unless (and (list? spans)
                 (for-all (lambda (entry)
                            (and (pair? entry) (symbol? (car entry)) (list? (cdr entry))
                                 (for-all (lambda (s) (span? s limit)) (cdr entry))))
                          spans))
      (assertion-violation who "not a list of layer types and their spans" spans)))

  (define (refuse who message . irritants)
    (raise (condition (make-refused-condition) (make-who-condition who)
                      (make-message-condition message) (make-irritants-condition irritants))))

  (define (one-node? doc)
    (and (fx= (document:open-start doc) 0) (fx= (document:open-end doc) 0)
         (fx>= (document:length doc) 2)
         (let ([t (document:token doc 0)])
           (and (document:node? t) (not (document:atom? t))
                (fx= (document:node-end t) (document:length doc))))))

  (define (make-buffer! who name content)
    (unless (string? name)
      (assertion-violation who "not a string" name))
    (check-main-thread who)
    (when (hashtable-ref by-name name #f)
      (assertion-violation who "a live buffer has the name" name))
    (let ([doc (cond
                 [(string? content) (document:from-datum (list 'buffers:text '() content))]
                 [(document? content) content]
                 [else (document:from-datum content)])])
      (unless (one-node? doc)
        (assertion-violation who "not one node" (if (document? content) (document:datums content) content)))
      (let ([b (make-buffer-record (string->immutable-string name) doc (make-scope))])
        (with-interrupts-disabled
          (hashtable-set! by-name (buffer-name b) b)
          (set! made (cons b made)))
        b)))

  (define (find-buffer name) (hashtable-ref by-name name #f))

  (define (live-buffers) (reverse made))

  (define (rename-buffer! who b name)
    (unless (string? name)
      (assertion-violation who "not a string" name))
    (let ([other (hashtable-ref by-name name #f)])
      (when (and other (not (eq? other b)))
        (assertion-violation who "a live buffer has the name" name)))
    (let ([name (string->immutable-string name)])
      (with-interrupts-disabled
        (hashtable-delete! by-name (buffer-name b))
        (buffer-name-set! b name)
        (hashtable-set! by-name name b))))

  (define (forget-buffer! b)
    (with-interrupts-disabled
      (hashtable-delete! by-name (buffer-name b))
      (set! made (remq b made))
      (buffer-scope-set! b #f)))

  (define (with-current b thunk)
    (if (and (eq? (current-buffer) b) (eq? (current-scope) (buffer-scope b)))
        (thunk)
        (parameterize ([current-buffer b] [current-scope (buffer-scope b)])
          (thunk))))

  ;; A frozen document replaces the buffer's own, so the next freeze
  ;; passes only what later edits made.
  (define (frozen-document b)
    (if (buffer-frozen? b)
        (buffer-doc b)
        (let ([frozen (document:freeze (buffer-doc b) jobs:freeze)])
          (with-interrupts-disabled
            (buffer-doc-set! b frozen)
            (buffer-frozen?-set! b #t))
          frozen)))

  (define (find-kind name) (table-ref kinds name #f))

  (define (kind-of node) (table-ref kinds (document:node-kind node) #f))

  (define (node-content node)
    (let ([k (kind-of node)]) (if k (kind-entry-content k) 'text)))

  (define (node-stops node)
    (let ([k (kind-of node)]) (if k (kind-entry-stops k) 'all)))

  (define (exported-symbol id)
    (let ([owner (current-owner)])
      (if (member owner '((init) (repl)))
          id
          (string->symbol
            (call-with-string-output-port
              (lambda (p)
                (let loop ([parts owner])
                  (display (car parts) p)
                  (unless (null? (cdr parts))
                    (put-char p #\/)
                    (loop (cdr parts))))
                (put-char p #\:)
                (display id p)))))))

  (define (check-optional-procedure who v)
    (unless (or (not v) (procedure? v))
      (assertion-violation who "not a procedure or #f" v)))

  (define (define-kind! id content inline? sticky stops draw keymap consent whole?)
    (check-optional-procedure 'buffers:define-kind draw)
    (check-optional-procedure 'buffers:define-kind consent)
    (let ([name (exported-symbol id)])
      (table-set! kinds name
        (make-kind-entry name content inline? sticky stops draw keymap consent (or whole? (eq? content 'atom))))
      (if (eq? content 'atom)
          (lambda (attributes) (vector name attributes))
          (lambda (attributes . datums) (cons* name attributes datums)))))

  ;; A document whose only node is its root, as a file's is, needs no
  ;; search for the nodes around a position: inside, there is the root
  ;; alone.
  (define (bare-root b doc)
    (let ([known (buffer-bare b)])
      (if (eq? (car known) doc)
          (cdr known)
          (let* ([n (document:length doc)]
                 [root (and (fx= (fx- n (document:offset doc n (document:unit characters))) 2)
                            (document:token doc 0))])
            (buffer-bare-set! b (cons doc root))
            root))))

  (define (ancestors-in b doc p)
    (let ([root (bare-root b doc)])
      (if (and root (fx< 0 p (document:length doc)))
          (list root)
          (ancestors doc p))))

  (define (ancestors doc p)
    (let loop ([n (document:enclosing doc p)] [acc '()])
      (if n
          (loop (document:enclosing doc (document:node-start n)) (cons n acc))
          (reverse acc))))

  (define (same-node? a b)
    (if a (and b (fx= (document:node-start a) (document:node-start b))) (not b)))

  (define (node-member n ns)
    (memp (lambda (m) (same-node? m n)) ns))

  ;; This module defines find, so its own code searches lists with memp.
  (define (common-ancestor anc-s anc-e)
    (let ([m (memp (lambda (n) (node-member n anc-e)) anc-s)]) (and m (car m))))

  (define (below common chain)
    (if common
        (let loop ([chain chain])
          (if (same-node? (car chain) common) '() (cons (car chain) (loop (cdr chain)))))
        chain))

  (define (text-node? n) (and n (eq? (node-content n) 'text)))

  (define (node-attributes doc n)
    (let ([start (document:node-start n)])
      (cadr (car (document:datums (document:slice doc start (fx+ start 1)))))))

  (define (opening doc n) (cons (document:node-kind n) (node-attributes doc n)))

  (define (boundaries closings middle openings)
    (let* ([outer (let loop ([k closings] [inner '()])
                    (if (fx= k 0) inner (loop (fx- k 1) (list (cons* 'buffers:text '() inner)))))]
           [reopened (fold-right (lambda (o inner) (list (cons* (car o) (cdr o) inner))) '() openings)]
           [whole (apply document:from-datum (append outer middle reopened))])
      (document:slice whole closings (fx- (document:length whole) (length openings)))))

  (define (datum-fits? content d)
    (cond
      [(string? d) (eq? content 'text)]
      [(vector? d) (not (eq? content 'atom))]
      [else
       (let ([k (table-ref kinds (car d) #f)])
         (and (case content
                [(text) (and k (kind-entry-inline? k))]
                [(nodes) (not (and k (kind-entry-inline? k)))]
                [else #f])
              (datums-fit? (if k (kind-entry-content k) 'text) (cddr d))))]))

  (define (datums-fit? content ds)
    (for-all (lambda (d) (datum-fits? content d)) ds))

  (define (inline-datums? ds)
    (for-all (lambda (d)
               (or (string? d) (vector? d)
                   (let ([k (table-ref kinds (car d) #f)])
                     (and k (kind-entry-inline? k) (inline-datums? (cddr d))))))
             ds))

  ;; Characters and atoms only: a typed or pasted text needs no walk.
  (define (text-like? c)
    (let ([n (document:length c)])
      (fx= n (document:offset c n (document:unit characters)))))

  (define (fits-in? parent c)
    (and parent
         (if (text-like? c)
             (or (eq? (node-content parent) 'text)
                 (and (eq? (node-content parent) 'nodes) (for-all vector? (document:datums c))))
             (datums-fit? (node-content parent) (document:datums c)))))

  ;; A join replaces the text it moves along with the boundaries around
  ;; it, so its step also says where that text went: the travelling spans
  ;; on it go with it.
  (define-record-type step
    (sealed #t)
    (fields start old-end new-end moved-from moved-to moved-length))

  (define (plain-step start old-end new-end) (make-step start old-end new-end 0 0 0))

  (define (step-moves? st) (fx> (step-moved-length st) 0))

  ;; A span keeps only its own text, so its end stays before what is
  ;; inserted at it and its start goes after.
  (define (through steps p end?)
    (fold-left
      (lambda (p st)
        (let ([s (step-start st)] [o (step-old-end st)]
              [k (fx- p (step-moved-from st))] [n (step-moved-length st)])
          (cond
            [(if end? (fx<= p s) (fx< p s)) p]
            [(fx>= p o) (fx+ p (fx- (step-new-end st) o))]
            [(if end? (fx< 0 k (fx+ n 1)) (fx< -1 k n)) (fx+ (step-moved-to st) k)]
            [else s])))
      p steps))

  (define (compose steps)
    (let loop ([steps (cdr steps)] [lo (step-start (car steps))] [hi-old (step-old-end (car steps))]
               [hi-new (step-new-end (car steps))])
      (if (null? steps)
          (values lo hi-old hi-new)
          (let* ([next (car steps)] [top (fxmax hi-new (step-old-end next))])
            (loop (cdr steps)
                  (fxmin lo (step-start next))
                  (fx+ hi-old (fx- top hi-new))
                  (fx+ top (fx- (step-new-end next) (step-old-end next))))))))

  (define (replace-step doc start end content)
    (values (document:replace doc start end content)
            (plain-step start end (fx+ start (document:length content)))))

  ;; When a and b are children of one node, deleting the range leaves b's
  ;; closing to close a, the same document a join makes, and moves nothing,
  ;; so anchors and every span in b's text stay on it.
  (define (join doc s e a b anc-s anc-e)
    (let* ([common (common-ancestor anc-s anc-e)]
           [closings (length (below common anc-s))]
           [opens (reverse (remp (lambda (n) (same-node? n b)) (below common anc-e)))])
      (if (and (null? opens) (fx= closings 1))
          (replace-step doc s e empty-document)
          (let* ([b-end (document:node-end b)]
                 [rest (document:slice doc e (fx- b-end 1))]
                 [content (document:replace (boundaries closings '() (map (lambda (n) (opening doc n)) opens)) 0 0 rest)])
            (values (document:replace doc s b-end content)
                    (make-step s b-end (fx+ s (document:length content)) e s (document:length rest)))))))

  (define (keep-both doc s e anc-s anc-e)
    (let ([common (common-ancestor anc-s anc-e)])
      (replace-step doc s e
        (boundaries (length (below common anc-s)) '()
                    (map (lambda (n) (opening doc n)) (reverse (below common anc-e)))))))

  (define (deletion doc s e anc-s anc-e)
    (let ([a (and (pair? anc-s) (car anc-s))] [b (and (pair? anc-e) (car anc-e))])
      (cond
        [(same-node? a b) (replace-step doc s e empty-document)]
        [(and (text-node? a) (text-node? b) (fx< (document:node-start a) (document:node-start b)))
         (join doc s e a b anc-s anc-e)]
        [else (keep-both doc s e anc-s anc-e)])))

  (define (join-at doc s e)
    (let ([a (document:enclosing doc s)] [b (document:enclosing doc e)])
      (and (text-node? a) (text-node? b) (fx< (document:node-start a) (document:node-start b))
           (call-with-values (lambda () (join doc s e a b (ancestors doc s) (ancestors doc e))) list))))

  (define (empty-node-at doc p)
    (let ([n (document:token doc p)])
      (and (document:node? n) (not (document:atom? n)) (fx= (document:node-end n) (fx+ p 2)))))

  ;; A string's document is its UTF-8 text, and reading the bytes skips
  ;; the checks a datum needs, which cost more than a typed character's
  ;; whole edit.
  (define (string->document s) (document:from-utf8 (string->utf8 s)))

  (define (does-not-fit who)
    (assertion-violation who "the content does not fit here"))

  ;; A misfit sends the fitting on to the next alternative and, unlike a
  ;; refusal, never leaves it.
  (define-condition-type &misfit &condition make-misfit-condition misfit-condition?)

  (define (misfit) (raise (make-misfit-condition)))

  ;; An insertion alternative is given the nodes enclosing s before the
  ;; edit: they are the same nodes after a deletion at s, since no token
  ;; before s changes.

  (define (insert-directly doc s c anc)
    (let ([parent (and (pair? anc) (car anc))])
      (unless (fits-in? parent c) (misfit))
      (let-values ([(new st) (replace-step doc s s c)])
        (values new (list st) (lambda (x end?) (fx+ s x)) c (list parent)))))

  (define (insert-as-text doc s c anc)
    (let ([text (document:text c)])
      (when (string=? text "") (misfit))
      (let ([t (string->document text)] [parent (and (pair? anc) (car anc))])
        (unless (text-node? parent) (misfit))
        (let-values ([(new st) (replace-step doc s s t)])
          (values new (list st)
                  (lambda (x end?) (fx+ s (document:offset c x (document:unit characters))))
                  t (list parent))))))

  (define (insert-blocks doc s c anc)
    (let ([t (and (pair? anc) (car anc))])
      (unless (text-node? t) (misfit))
      (let* ([parent (and (pair? (cdr anc)) (cadr anc))]
             [t-start (document:node-start t)]
             [os (document:open-start c)] [oe (document:open-end c)]
             [closed (document:datums c)])
        (unless parent (misfit))
        (let*-values ([(cut) (boundaries 1 closed (list (opening doc t)))]
                      [(d1 st1) (replace-step doc s s cut)]
                      [(q) (fx- (step-new-end st1) 1)]
                      [(joined-end) (and (fx> oe 0) (join-at d1 (fx- q oe) (fx+ q 1)))]
                      [(d2 steps) (if joined-end
                                      (values (car joined-end) (list st1 (cadr joined-end)))
                                      (values d1 (list st1)))]
                      [(joined-start) (and (fx> os 0) (join-at d2 s (fx+ s 1 os)))]
                      [(d3 steps) (if joined-start
                                      (values (car joined-start) (append steps (list (cadr joined-start))))
                                      (values d2 steps))]
                      [(d4 steps) (let ([second (and (not joined-end) (through (cdr steps) q #f))])
                                    (if (and second (empty-node-at d3 second))
                                        (let-values ([(d st) (replace-step d3 second (fx+ second 2) empty-document)])
                                          (values d (append steps (list st))))
                                        (values d3 steps)))]
                      [(d5 steps) (if (empty-node-at d4 t-start)
                                      (let-values ([(d st) (replace-step d4 t-start (fx+ t-start 2) empty-document)])
                                        (values d (append steps (list st))))
                                      (values d4 steps))])
          (let-values ([(lo hi-old hi-new) (compose steps)])
            (let ([p (document:token d5 (document:node-start parent))]
                  [content (node-content parent)])
              (unless (and (top-level-fits? p lo hi-new content) (datums-fit-closed? closed))
                (misfit))
              (values d5 steps
                      (lambda (x end?) (through (cdr steps) (fx+ s 1 os x) end?))
                      c (list t parent))))))))

  (define (top-level-fits? parent lo hi content)
    (call/1cc
      (lambda (k)
        (document:for-each-child parent lo hi
          (lambda (child at)
            (unless (if (string? child)
                        (eq? content 'text)
                        (or (document:atom? child)
                            (let ([kind (kind-of child)])
                              (case content
                                [(text) (and kind (kind-entry-inline? kind))]
                                [(nodes) (not (and kind (kind-entry-inline? kind)))]
                                [else #f]))))
              (k #f))))
        #t)))

  (define (datums-fit-closed? ds)
    (for-all (lambda (d)
               (or (string? d) (vector? d)
                   (let ([k (table-ref kinds (car d) #f)])
                     (datums-fit? (if k (kind-entry-content k) 'text) (cddr d)))))
             ds))

  (define (insertion-alternatives c)
    (let ([edges? (not (and (fx= (document:open-start c) 0) (fx= (document:open-end c) 0)))])
      (cond
        [(fx= (document:length c) 0) '()]
        [(and (not edges?) (text-like? c)) (list insert-directly)]
        [(and (not edges?) (inline-datums? (document:datums c))) (list insert-directly insert-as-text)]
        [edges? (list insert-blocks insert-as-text)]
        [else (list insert-directly insert-blocks insert-as-text)])))

  (define (deletion-asks anc-s anc-e)
    (let ([common (common-ancestor anc-s anc-e)])
      (append (if common (list common) '()) (below common anc-s) (below common anc-e))))

  (define (ask! who nodes edit)
    (let loop ([nodes nodes] [asked '()])
      (unless (null? nodes)
        (let ([n (car nodes)])
          (if (or (not n) (node-member n asked))
              (loop (cdr nodes) asked)
              (let* ([k (kind-of n)] [consent (and k (kind-entry-consent k))])
                (when (and consent (not (consent n edit)))
                  (refuse who "the node refuses the edit" (document:node-kind n)))
                (loop (cdr nodes) (cons n asked))))))))

  (define (refuse-undefined! who nodes)
    (for-each
      (lambda (n)
        (unless (kind-of n)
          (refuse who "inside a node whose kind is not loaded" (document:node-kind n))))
      nodes))

  (define (sticks-front? t) (memq (layer-type-sticky t) '(before both)))
  (define (sticks-rear? t) (memq (layer-type-sticky t) '(after both)))

  (define (define-layer-type! id priority sticky evaporate? travels? read-only? keymap)
    (unless (real? priority)
      (assertion-violation 'buffers:define-layer "not a real number" priority))
    (let ([name (exported-symbol id)])
      (table-set! layer-types name (make-layer-type name priority sticky evaporate? travels? read-only? keymap))
      name))

  ;; A layer keeps the last definition of its type it saw, so its spans
  ;; move the same way while the type's module is unloaded.
  (define (layer-clauses l)
    (let ([t (table-ref layer-types (buffer-layer-type l) #f)])
      (when (and t (not (eq? t (buffer-layer-seen l))))
        (buffer-layer-seen-set! l t))
      (buffer-layer-seen l)))

  (define (layer-type-keymap-of l)
    (let ([t (table-ref layer-types (buffer-layer-type l) #f)])
      (and t (layer-type-keymap t))))

  ;; Travelling spans are the buffer's content; a layer limited to a key
  ;; is what is drawn for that key, so it never travels.
  (define (travelling? l)
    (and (not (buffer-layer-key l)) (layer-type-travels? (layer-clauses l))))

  (define (find-layer b type key)
    (let ([m (memp (lambda (l) (and (eq? (buffer-layer-type l) type) (equal? (buffer-layer-key l) key)))
                   (buffer-layers b))])
      (and m (car m))))

  (define (add-layer! b type key seen)
    (let ([l (make-layer b type key (make-spans) seen)])
      (buffer-layers-set! b (append (buffer-layers b) (list l)))
      l))

  (define (find-layer! who b type key)
    (or (find-layer b type key)
        (let ([t (table-ref layer-types type #f)])
          (unless t (assertion-violation who "not a defined layer type" type))
          (add-layer! b type key t))))

  (define (layer-of who b type key)
    (check-change who b)
    (find-layer! who b type key))

  (define (layers-for who b key)
    (check-buffer who b)
    (check-main-thread who)
    (layers-of b key))

  (define (layers-of b key)
    (list-sort (lambda (x y) (< (layer-type-priority (layer-clauses x)) (layer-type-priority (layer-clauses y))))
               (filter (lambda (l) (let ([k (buffer-layer-key l)]) (or (not k) (equal? k key))))
                       (buffer-layers b))))

  (define (clip spans start end)
    (fold-right
      (lambda (s acc)
        (let ([a (fxmax start (car s))] [e (fxmin end (cadr s))])
          (if (fx< a e) (cons (list (fx- a start) (fx- e start) (caddr s)) acc) acc)))
      '() spans))

  (define (travelling-spans-of b start end)
    (if (fx= start end)
        '()
        (fold-right
          (lambda (l acc)
            (if (travelling? l)
                (let ([spans (clip (spans-overlapping (buffer-layer-store l) start end) start end)])
                  (if (null? spans) acc (cons (cons (buffer-layer-type l) spans) acc)))
                acc))
          '() (buffer-layers b))))

  (define (layer-spans l start end) (spans-overlapping (buffer-layer-store l) start end))

  (define (layer-spans-at l p)
    (let ([t (layer-clauses l)])
      (spans-taking (buffer-layer-store l) p 0 (sticks-front? t) (sticks-rear? t) (travelling? l))))

  (define (coalesce! store lo hi)
    (unless (spans-empty? store)
      (let loop ([spans (spans-take! store lo hi (lambda (a e v) #t))] [acc '()])
        (cond
          [(null? spans)
           (for-each (lambda (s) (spans-add! store (car s) (cadr s) (caddr s))) acc)]
          [(and (pair? acc) (fx= (cadr (car acc)) (car (car spans))) (equal? (caddr (car acc)) (caddr (car spans))))
           (loop (cdr spans) (cons (list (car (car acc)) (cadr (car spans)) (caddr (car acc))) (cdr acc)))]
          [else (loop (cdr spans) (cons (car spans) acc))]))))

  (define (clear-range! store start end)
    (unless (spans-empty? store)
      (for-each
        (lambda (s)
          (let ([a (car s)] [e (cadr s)] [v (caddr s)])
            (when (fx< a start) (spans-add! store a (fxmin e start) v))
            (when (fx> e end) (spans-add! store (fxmax a end) e v))))
        (spans-take! store start end
          (lambda (a e v)
            (if (fx< a e) (and (fx< a end) (fx< start e)) (and (fx<= start a) (fx< a end))))))))

  (define (add-spans! store spans offset evaporate?)
    (for-each
      (lambda (s)
        (let ([a (fx+ offset (car s))] [e (fx+ offset (cadr s))])
          (unless (and evaporate? (fx= a e))
            (spans-add! store a e (caddr s)))))
      spans))

  ;; Typed text that only spans around it take grows them, as cutting them
  ;; and joining the parts again would.
  (define (move-layer! l s r i moves? carried)
    (let* ([t (layer-clauses l)] [store (buffer-layer-store l)] [front? (sticks-front? t)] [rear? (sticks-rear? t)])
      (cond
        [(not (travelling? l))
         (when (and moves? (not (spans-empty? store)))
           (spans-map! store s r i front? rear? (layer-type-evaporate? t)))]
        [(not moves?)
         (when carried
           (clear-range! store s (fx+ s r))
           (add-spans! store carried 0 #t)
           (coalesce! store s (fx+ s i)))]
        [(and (not carried) (fx= r 0) (not (eq? (layer-type-sticky t) 'neither))
              (for-all (lambda (x) (and (fx< (car x) s) (fx< s (cadr x)))) (spans-touching store s s)))
         (spans-map! store s 0 i #t #t #f)]
        [else
         (when (fx> r 0) (spans-map! store s r 0 #f #f #t))
         (when (fx> i 0)
           (let ([taken (if carried '() (spans-taking store s 0 front? rear? #t))])
             (spans-split! store s i)
             (if carried
                 (add-spans! store carried 0 #t)
                 (for-each (lambda (x) (spans-add! store s (fx+ s i) (caddr x))) taken))))
         (coalesce! store s (fx+ s i))])))

  (define (log-base b) (fx- (buffer-version b) (buffer-logged b)))

  (define (log-ref b version)
    (vector-ref (buffer-log b) (fx- (fx- version (log-base b)) 1)))

  (define (log-append! b e)
    (let* ([log (buffer-log b)] [n (buffer-logged b)]
           [log (if (fx< n (vector-length log))
                    log
                    (let ([v (make-vector (fx* 2 n) #f)])
                      (do ([j 0 (fx+ j 1)]) ((fx= j n)) (vector-set! v j (vector-ref log j)))
                      (buffer-log-set! b v)
                      v))])
      (vector-set! log n e)
      (buffer-logged-set! b (fx+ n 1))))

  (define (edits-after b version)
    (and (fx>= version (log-base b))
         (let loop ([v (buffer-version b)] [acc '()])
           (if (fx= v version) acc (loop (fx- v 1) (cons (log-ref b v) acc))))))

  (define (map-through e p)
    (let ([s (edit-record-start e)])
      (if (or (fx<= p s) (not (edit-record-moves? e)))
          p
          (let ([end (fx+ s (edit-record-removed-length e))])
            (if (fx< p end) s (fx+ p (fx- (fx+ s (edit-record-inserted-length e)) end)))))))

  (define (map-position-through who b p version)
    (let ([edits (edits-after b version)])
      (and edits
           (let ([length-then (fold-left (lambda (n e) (fx- n (fx- (edit-record-inserted-length e) (edit-record-removed-length e))))
                                         (document:length (buffer-doc b)) edits)])
             (unless (fx<= p length-then)
               (assertion-violation who "not a position in the buffer at the version" p version))
             (fold-left (lambda (p e) (map-through e p)) p edits)))))

  (define (same-tokens? a b)
    (and (fx= (document:length a) (document:length b))
         (equal? (document:datums a) (document:datums b))))

  ;; The edit is made whole or not at all: a quit landing in it would
  ;; leave the document, the version and the layers out of step.
  (define (commit! b doc start old-end new-end removed inserted carried)
    (let* ([moves? (not (same-tokens? removed inserted))]
           [inserted (if moves? inserted removed)]
           [travels? (or carried (exists travelling? (buffer-layers b)))]
           [removed-spans (if travels? (travelling-spans-of b start old-end) '())]
           [r (fx- old-end start)] [i (fx- new-end start)]
           [edit (with-interrupts-disabled
                   (when carried
                     (for-each
                       (lambda (entry)
                         (unless (find-layer b (car entry) #f)
                           (add-layer! b (car entry) #f
                             (or (table-ref layer-types (car entry) #f)
                                 (make-layer-type (car entry) 0 'neither #f #t #f #f)))))
                       carried))
                   (for-each
                     (lambda (l)
                       (move-layer! l start r i moves?
                         (and carried (travelling? l)
                              (let ([entry (assq (buffer-layer-type l) carried)])
                                (if entry (cdr entry) '())))))
                     (buffer-layers b))
                   (let ([e (make-edit (fx+ (buffer-version b) 1) start removed inserted removed-spans
                                       (if travels? (travelling-spans-of b start new-end) '()))])
                     (buffer-doc-set! b doc)
                     (buffer-frozen?-set! b #f)
                     (log-append! b e)
                     (buffer-version-set! b (fx+ (buffer-version b) 1))
                     e))])
      (with-current b (lambda () (after-edit b edit)))
      edit))

  (define (absolute-carried carried place)
    (and carried
         (map (lambda (entry)
                (cons (car entry)
                      (fold-right
                        (lambda (s acc)
                          (let ([a (place (car s) #f)] [e (place (cadr s) #t)])
                            (if (fx< a e) (cons (list a e (caddr s)) acc) acc)))
                        '() (cdr entry))))
              carried)))

  (define (taken-travelling-spans b start end place length)
    (if (fx= length 0)
        '()
        (let ([a (place 0 #f)] [e (place length #t)])
          (fold-right
            (lambda (l acc)
              (if (travelling? l)
                  (let ([t (layer-clauses l)])
                    (cons (cons (buffer-layer-type l)
                                (map (lambda (x) (list a e (caddr x)))
                                     (spans-taking (buffer-layer-store l) start (fx- end start)
                                       (sticks-front? t) (sticks-rear? t) #t)))
                          acc))
                  acc))
            '() (buffer-layers b)))))

  (define (moved-travelling-spans b steps place start end length carried lo hi)
    (fold-left
      (lambda (acc l)
        (if (travelling? l)
            (let ([type (buffer-layer-type l)]
                  [kept (fold-right
                          (lambda (sp acc)
                            (let ([a (through steps (fxmax lo (car sp)) #f)] [e (through steps (fxmin hi (cadr sp)) #t)])
                              (if (fx< a e) (cons (list a e (caddr sp)) acc) acc)))
                          '() (spans-overlapping (buffer-layer-store l) lo hi))])
              (let ([entry (assq type acc)])
                (if entry
                    (cons (cons type (append kept (cdr entry))) (remq entry acc))
                    (cons (cons type kept) acc))))
            acc))
      (or (absolute-carried carried place) (taken-travelling-spans b start end place length))
      (buffer-layers b)))

  (define (check-result who doc lo hi-old old-length)
    (when (or (fx= lo 0) (fx= hi-old old-length))
      (unless (one-node? doc) (does-not-fit who))))

  (define (refuse-read-only! who b s e inserting?)
    (for-each
      (lambda (l)
        (let ([t (layer-clauses l)] [store (buffer-layer-store l)])
          (when (and (layer-type-read-only? t) (not (spans-empty? store))
                     (or (and (fx< s e)
                              (exists (lambda (sp)
                                        (let ([a (car sp)] [z (cadr sp)])
                                          (if (fx< a z) (and (fx< a e) (fx< s z)) (and (fx< s a) (fx< a e)))))
                                      (spans-overlapping store s e)))
                         (and inserting?
                              (pair? (spans-taking store s (fx- e s) (sticks-front? t) (sticks-rear? t) (travelling? l))))))
            (refuse who "a read-only span refuses the edit" (buffer-layer-type l)))))
      (buffer-layers b)))

  (define (replace-content! who b start end content carried)
    (check-change who b)
    (check-range who b start end)
    (let* ([d0 (buffer-doc b)]
           [c (cond
                [(document? content) content]
                [(string? content) (string->document content)]
                [else (document:from-datum content)])]
           [anc-s (ancestors-in b d0 start)]
           [anc-e (if (fx= start end) anc-s (ancestors-in b d0 end))])
      (when carried (check-travelling who carried (document:length c)))
      (refuse-undefined! who anc-s)
      (refuse-undefined! who anc-e)
      (refuse-read-only! who b start end (fx> (document:length c) 0))
      (let*-values ([(d1 deleted) (if (fx< start end)
                                       (let-values ([(d st) (deletion d0 start end anc-s anc-e)]) (values d (list st)))
                                       (values d0 '()))]
                    [(asks) (if (fx< start end) (deletion-asks anc-s anc-e) '())]
                    [(removed) (if (fx< start end) (document:slice d0 start end) empty-document)])
        (define (finish doc steps place inserted)
          (let-values ([(lo hi-old hi-new) (compose (if (null? steps) (list (plain-step start start start)) steps))])
            (check-result who doc lo hi-old (document:length d0))
            (commit! b doc lo hi-old hi-new
              (if (fx= lo hi-old) empty-document (document:slice d0 lo hi-old))
              (if (and (null? deleted) (eq? inserted c) (fx= lo start)) c (document:slice doc lo hi-new))
              (if (exists step-moves? steps)
                  (moved-travelling-spans b steps place start end (document:length c) carried lo hi-old)
                  (absolute-carried carried place)))))
        (let try ([alternatives (insertion-alternatives c)] [refusal #f] [misfit? #f])
          (cond
            [(pair? alternatives)
             (let ([outcome
                    (guard (r [(or (refused-condition? r) (misfit-condition? r)) r])
                      (let-values ([(doc steps place inserted parents) ((car alternatives) d1 start c anc-s)])
                        (ask! who (append asks parents)
                              (make-edit (fx+ (buffer-version b) 1) start removed inserted '() '()))
                        (list doc (append deleted steps) place inserted)))])
               (cond
                 [(refused-condition? outcome) (try (cdr alternatives) outcome misfit?)]
                 [(misfit-condition? outcome) (try (cdr alternatives) refusal #t)]
                 [else (apply finish outcome)]))]
            [refusal (raise refusal)]
            [misfit? (does-not-fit who)]
            [else
             (ask! who asks (make-edit (fx+ (buffer-version b) 1) start removed empty-document '() '()))
             (finish d1 deleted (lambda (x end?) start) empty-document)])))))

  (define (splice-content! who b start end c carried)
    (check-change who b)
    (check-range who b start end)
    (unless (document? c)
      (assertion-violation who "not a document" c))
    (let ([d0 (buffer-doc b)])
      (when carried (check-travelling who carried (document:length c)))
      (let ([doc (guard (x [(and (assertion-violation? x) (who-condition? x) (eq? (condition-who x) 'document:replace))
                            (assertion-violation who "openings and closings would not match" start end)])
                   (document:replace d0 start end c))])
        (unless (one-node? doc)
          (assertion-violation who "the buffer would not be one node" start end))
        (commit! b doc start end (fx+ start (document:length c))
          (if (fx= start end) empty-document (document:slice d0 start end)) c
          (absolute-carried carried (lambda (x end?) (fx+ start x)))))))

  ;; Reconciling compares datums, read once for the whole node, so
  ;; unchanged children cost an equal? each.

  (define (normalize datums)
    (let loop ([ds datums] [acc '()])
      (cond
        [(null? ds) (reverse acc)]
        [(and (string? (car ds)) (string=? (car ds) "")) (loop (cdr ds) acc)]
        [(and (string? (car ds)) (pair? acc) (string? (car acc)))
         (loop (cdr ds) (cons (string-append (car acc) (car ds)) (cdr acc)))]
        [else (loop (cdr ds) (cons (car ds) acc))])))

  (define (datum-length d)
    (cond
      [(string? d) (string-length d)]
      [(vector? d) 1]
      [else (fold-left (lambda (n child) (fx+ n (datum-length child))) 2 (cddr d))]))

  (define (datums-length ds) (fold-left (lambda (n d) (fx+ n (datum-length d))) 0 ds))

  (define (datum-kind d) (cond [(pair? d) (car d)] [(vector? d) (vector-ref d 0)] [else #f]))

  (define (datum-key d)
    (let ([attributes (cond [(pair? d) (cadr d)] [(vector? d) (vector-ref d 1)] [else '()])])
      (let ([a (and (list? attributes) (assq 'key attributes))])
        (and a (cdr a)))))

  (define (matches old new)
    (let ([by-key (make-hashtable equal-hash equal?)])
      (do ([i (fx- (vector-length old) 1) (fx- i 1)]) ((fx< i 0))
        (let ([key (datum-key (vector-ref old i))])
          (when key (hashtable-update! by-key key (lambda (is) (cons i is)) '()))))
      (let loop ([j 0] [from 0] [acc '()])
        (if (fx= j (vector-length new))
            (reverse acc)
            (let* ([d (vector-ref new j)] [key (datum-key d)])
              (let next-match ([is (if key (hashtable-ref by-key key '()) '())])
                (cond
                  [(null? is) (loop (fx+ j 1) from acc)]
                  [(and (fx>= (car is) from) (eq? (datum-kind (vector-ref old (car is))) (datum-kind d)))
                   (hashtable-set! by-key key (cdr is))
                   (loop (fx+ j 1) (fx+ (car is) 1) (cons (cons (car is) j) acc))]
                  [else (next-match (cdr is))])))))))

  (define (sublist v from to)
    (let loop ([k to] [acc '()])
      (if (fx= k from) acc (loop (fx- k 1) (cons (vector-ref v (fx- k 1)) acc)))))

  (define (reconcile-child! who b at old new)
    (cond
      [(vector? new) (splice-content! who b at (fx+ at 1) (document:from-datum new) #f)]
      [else
       (unless (equal? (cadr old) (cadr new))
         (splice-content! who b at (fx+ at 1) (boundaries 0 '() (list (cons (car new) (cadr new)))) #f))
       (reconcile-children! who b (fx+ at 1) (cddr old) (normalize (cddr new)))]))

  ;; Only nodes of one kind and attributes are entered, so the count is of
  ;; tokens the two lists have in common.
  (define (shared-length old new from-end?)
    (define (string-shared a b)
      (let ([la (string-length a)] [lb (string-length b)])
        (let loop ([k 0])
          (if (and (fx< k la) (fx< k lb)
                   (char=? (string-ref a (if from-end? (fx- la k 1) k))
                           (string-ref b (if from-end? (fx- lb k 1) k))))
              (loop (fx+ k 1))
              k))))
    (let loop ([old (if from-end? (reverse old) old)] [new (if from-end? (reverse new) new)] [n 0])
      (cond
        [(or (null? old) (null? new)) n]
        [(equal? (car old) (car new)) (loop (cdr old) (cdr new) (fx+ n (datum-length (car old))))]
        [(and (string? (car old)) (string? (car new))) (fx+ n (string-shared (car old) (car new)))]
        [(and (pair? (car old)) (pair? (car new)) (eq? (caar old) (caar new)) (equal? (cadar old) (cadar new)))
         (fx+ n 1 (shared-length (cddar old) (cddar new) from-end?))]
        [else n])))

  ;; Only what lies between the content the old and new gaps share at
  ;; their start and end is replaced, so a node that grows at its end gets
  ;; an insertion, and the cursors, anchors and line items before it stay.
  (define (splice-gap! who b at old-gap new-gap)
    (let* ([old-length (datums-length old-gap)] [new-length (datums-length new-gap)]
           [start (shared-length old-gap new-gap #f)]
           [end (fxmin (shared-length old-gap new-gap #t) (fx- old-length start) (fx- new-length start))])
      (splice-content! who b (fx+ at start) (fx- (fx+ at old-length) end)
        (document:slice (apply document:from-datum new-gap) start (fx- new-length end)) #f)))

  (define (reconcile-children! who b at old new)
    (let* ([old (list->vector old)] [new (list->vector new)])
      (let loop ([pairs (matches old new)] [i 0] [j 0] [at at])
        (let* ([oi (if (null? pairs) (vector-length old) (caar pairs))]
               [nj (if (null? pairs) (vector-length new) (cdar pairs))]
               [old-gap (sublist old i oi)] [new-gap (sublist new j nj)])
          (unless (equal? old-gap new-gap)
            (splice-gap! who b at old-gap new-gap))
          (let ([at (fx+ at (datums-length new-gap))])
            (unless (null? pairs)
              (let ([od (vector-ref old oi)] [nd (vector-ref new nj)])
                (unless (equal? od nd) (reconcile-child! who b at od nd))
                (loop (cdr pairs) (fx+ oi 1) (fx+ nj 1) (fx+ at (datum-length nd))))))))))

  (define (reconcile-node! who b node children)
    (let* ([start (document:node-start node)] [doc (buffer-doc b)]
           [current (and (fx< start (document:length doc)) (document:token doc start))])
      (unless (and (document:node? current) (not (document:atom? current))
                   (eq? (document:node-kind current) (document:node-kind node))
                   (fx= (document:node-end current) (document:node-end node)))
        (assertion-violation who "not a node of the buffer's document" node))
      (unless (list? children)
        (assertion-violation who "not a list" children))
      (let ([new (normalize children)])
        (unless (datums-fit? (node-content current) new)
          (does-not-fit who))
        (reconcile-children! who b (fx+ start 1)
          (cddr (car (document:datums (document:slice doc start (document:node-end current)))))
          new))))

  (define (boundary? token)
    (or (eq? token 'close) (and (document:node? token) (not (document:atom? token)))))

  (define (plain-range? doc from to)
    (and (fx<= 0 from) (fx<= to (document:length doc))
         (let loop ([p from])
           (or (fx= p to) (and (not (boundary? (document:token doc p))) (loop (fx+ p 1)))))))

  (define (place-bounds doc p)
    (let ([n (document:length doc)])
      (let left ([a p])
        (if (and (fx> a 0) (boundary? (document:token doc (fx- a 1))))
            (left (fx- a 1))
            (let right ([z p])
              (if (and (fx< z n) (boundary? (document:token doc z)))
                  (right (fx+ z 1))
                  (values a z)))))))

  (define (candidate-depth doc q)
    (let ([as (ancestors doc q)])
      (and (pair? as)
           (for-all (lambda (n) (not (eq? (node-stops n) 'none))) as)
           (or (and (eq? (node-content (car as)) 'text) (eq? (node-stops (car as)) 'all))
               (let ([t (document:token doc q)]) (and (document:node? t) (document:atom? t))))
           (length as))))

  (define (consents-to-typing? b doc q)
    (let ([n (document:enclosing doc q)])
      (or (not n)
          (let ([k (kind-of n)])
            (and k
                 (let ([consent (kind-entry-consent k)])
                   (or (not consent)
                       (consent n (make-edit (fx+ (buffer-version b) 1) q empty-document typing-probe '() '())))))))))

  (define (sticky-edge? doc q)
    (let* ([n (document:enclosing doc q)] [k (and n (kind-of n))])
      (or (not k) (not (kind-entry-inline? k))
          (let ([start? (fx= q (fx+ (document:node-start n) 1))]
                [end? (fx= q (fx- (document:node-end n) 1))]
                [s (kind-entry-sticky k)])
            (cond
              [(and start? end?) (not (eq? s 'neither))]
              [start? (and (memq s '(before both)) #t)]
              [end? (and (memq s '(after both)) #t)]
              [else #t])))))

  ;; Consent picks the position; it never decides whether the place is a
  ;; stop, so read-only text keeps its stops.
  (define (place-stop b doc p)
    (let-values ([(a z) (if (plain-range? doc (fx- p 1) (fx+ p 1)) (values p p) (place-bounds doc p))])
      (values
        (if (fx= a z)
            (and (candidate-depth doc a) a)
            (let ([candidates (let loop ([q a] [acc '()])
                                (if (fx> q z)
                                    (reverse acc)
                                    (let ([d (candidate-depth doc q)])
                                      (loop (fx+ q 1) (if d (cons (cons q d) acc) acc)))))])
              (define (best ok?)
                (fold-left (lambda (best c)
                             (if (and (ok? (car c)) (or (not best) (fx>= (cdr c) (cdr best)))) c best))
                           #f candidates))
              (let ([chosen (or (best (lambda (q) (and (consents-to-typing? b doc q) (sticky-edge? doc q))))
                                (best (lambda (q) (consents-to-typing? b doc q)))
                                (best (lambda (q) #t)))])
                (and chosen (car chosen)))))
        a z)))

  (define (bare-text b doc)
    (let ([root (bare-root b doc)])
      (and root (eq? (node-content root) 'text) (eq? (node-stops root) 'all))))

  (define (stop-at b p)
    (let ([doc (buffer-doc b)])
      (if (bare-text b doc)
          (fxmax 1 (fxmin p (fx- (document:length doc) 1)))
          (let-values ([(stop a z) (place-stop b doc p)]) stop))))

  (define (next-stop-after b p)
    (let ([doc (buffer-doc b)])
      (cond
        [(bare-text b doc)
         (let ([q (if (fx= p 0) 2 (fx+ p 1))])
           (and (fx<= q (fx- (document:length doc) 1)) q))]
        [(and (plain-range? doc (fx- p 1) (fx+ p 2)) (candidate-depth doc (fx+ p 1))) (fx+ p 1)]
        [else (next-stop-in-places b doc p)])))

  (define (next-stop-in-places b doc p)
    (let-values ([(a z) (place-bounds doc p)])
      (let loop ([q z])
        (and (fx< q (document:length doc))
             (let-values ([(stop a z) (place-stop b doc (fx+ q 1))])
               (or stop (loop z)))))))

  (define (previous-stop-before b p)
    (let ([doc (buffer-doc b)])
      (cond
        [(bare-text b doc)
         (let ([q (if (fx= p (document:length doc)) (fx- p 2) (fx- p 1))])
           (and (fx>= q 1) q))]
        [(and (plain-range? doc (fx- p 2) (fx+ p 1)) (candidate-depth doc (fx- p 1))) (fx- p 1)]
        [else (previous-stop-in-places b doc p)])))

  (define (previous-stop-in-places b doc p)
    (let-values ([(a z) (place-bounds doc p)])
      (let loop ([q a])
        (and (fx> q 0)
             (let-values ([(stop a z) (place-stop b doc (fx- q 1))])
               (or stop (loop a)))))))

  (define (make-anchor! b p after?)
    (let ([a (make-anchor b after? p (buffer-version b) #f)])
      (with-interrupts-disabled (hashtable-set! (buffer-anchors b) a #t))
      a))

  ;; The trim moves every live anchor through up to the whole log, so the
  ;; loop reads the log's vector itself.
  (define (anchor-current-position a)
    (let* ([b (buffer-anchor-buffer a)] [now (buffer-version b)])
      (unless (fx= (buffer-anchor-version a) now)
        (let ([after? (buffer-anchor-after? a)] [log (buffer-log b)] [first (fx- now (buffer-logged b))])
          (let loop ([v (buffer-anchor-version a)] [p (buffer-anchor-position a)] [deleted? (buffer-anchor-deleted? a)])
            (if (fx= v now)
                (with-interrupts-disabled
                  (buffer-anchor-position-set! a p)
                  (buffer-anchor-deleted?-set! a deleted?)
                  (buffer-anchor-version-set! a now))
                (let* ([e (vector-ref log (fx- v first))] [s (edit-record-start e)])
                  (if (or (fx< p s) (not (edit-record-moves? e)))
                      (loop (fx+ v 1) p deleted?)
                      (let ([end (fx+ s (edit-record-removed-length e))] [i (edit-record-inserted-length e)])
                        (loop (fx+ v 1)
                              (cond
                                [(fx< p end) (if after? (fx+ s i) (if (fx= p s) p s))]
                                [(and (fx= p s) (not after?)) p]
                                [else (fx+ p (fx- (fx+ s i) end))])
                              (or deleted? (and (fx< s p) (fx<= p end)))))))))))
      (buffer-anchor-position a)))

  (define (anchor-deleted-now? a)
    (anchor-current-position a)
    (buffer-anchor-deleted? a))

  (define (move-anchor! a p)
    (let ([b (buffer-anchor-buffer a)])
      (with-interrupts-disabled
        (buffer-anchor-position-set! a p)
        (buffer-anchor-deleted?-set! a #f)
        (buffer-anchor-version-set! a (buffer-version b)))))

  (define (change-spans! who l lo hi change!)
    (let ([b (buffer-layer-buffer l)])
      (if (travelling? l)
          (let* ([doc (buffer-doc b)] [same (document:slice doc lo hi)] [before (travelling-spans-of b lo hi)])
            (let ([edit (with-interrupts-disabled
                          (change! (buffer-layer-store l))
                          (coalesce! (buffer-layer-store l) lo hi)
                          (let ([e (make-edit (fx+ (buffer-version b) 1) lo same same before
                                              (travelling-spans-of b lo hi))])
                            (log-append! b e)
                            (buffer-version-set! b (fx+ (buffer-version b) 1))
                            e))])
              (with-current b (lambda () (after-edit b edit)))))
          (with-interrupts-disabled (change! (buffer-layer-store l))))
      (void)))

  (define (spans-at-version l spans version)
    (let* ([b (buffer-layer-buffer l)] [edits (edits-after b version)])
      (and edits
           (let ([t (layer-clauses l)] [store (make-spans)])
             (for-each (lambda (s) (spans-add! store (car s) (cadr s) (caddr s))) spans)
             (for-each
               (lambda (e)
                 (when (edit-record-moves? e)
                   (spans-map! store (edit-record-start e) (edit-record-removed-length e)
                     (edit-record-inserted-length e) (sticks-front? t) (sticks-rear? t)
                     (layer-type-evaporate? t))))
               edits)
             (spans-all store)))))

  (define (set-layer-spans! who l start end spans version)
    (let* ([b (buffer-layer-buffer l)]
           [start (if version (map-position-through who b start version) start)]
           [end (and start (if version (map-position-through who b end version) end))]
           [spans (and end (if version (spans-at-version l spans version) spans))])
      (when (and spans (exists (lambda (s) (fx> (cadr s) (document:length (buffer-doc b)))) spans))
        (assertion-violation who "a span is not within the buffer" spans))
      (and spans
           (let ([evaporate? (layer-type-evaporate? (layer-clauses l))])
             (change-spans! who l (fold-left (lambda (lo s) (fxmin lo (car s))) start spans)
               (fold-left (lambda (hi s) (fxmax hi (cadr s))) end spans)
               (lambda (store)
                 (clear-range! store start end)
                 (add-spans! store spans 0 evaporate?)))
             #t))))

  (define (add-layer-span! who l a e v)
    (let ([evaporate? (layer-type-evaporate? (layer-clauses l))])
      (change-spans! who l a e
        (lambda (store) (unless (and evaporate? (fx= a e)) (spans-add! store a e v))))))

  (define (remove-layer-spans! who l v)
    (let ([matching (filter (lambda (s) (equal? (caddr s) v)) (spans-all (buffer-layer-store l)))])
      (unless (null? matching)
        (let ([lo (apply fxmin (map car matching))] [hi (apply fxmax (map cadr matching))])
          (change-spans! who l lo hi
            (lambda (store) (spans-take! store lo hi (lambda (a e x) (equal? x v)))))))))

  ;; At idle each log keeps its last thousand edits, after its anchors have
  ;; moved to the present, since an anchor is moved through the log.
  (define log-limit 1000)

  (define (trim-logs!)
    (for-each
      (lambda (b)
        (let ([n (buffer-logged b)])
          (when (fx> n log-limit)
            (vector-for-each anchor-current-position (hashtable-keys (buffer-anchors b)))
            (let ([kept (make-vector (fx* 2 log-limit) #f)])
              (do ([j 0 (fx+ j 1)]) ((fx= j log-limit))
                (vector-set! kept j (vector-ref (buffer-log b) (fx+ (fx- n log-limit) j))))
              (with-interrupts-disabled
                (buffer-log-set! b kept)
                (buffer-logged-set! b log-limit))))))
      made))

  (table-set! kinds 'document:raw-byte
    (make-kind-entry 'document:raw-byte 'atom #f 'both 'all #f #f #f #t))

  (run-with-idle-timer 1 trim-logs!))

(import %internals)

(define (make name content) (make-buffer! 'buffers:make name content))

(define (find name)
  (unless (string? name)
    (assertion-violation 'buffers:find "not a string" name))
  (find-buffer name))

(define (all) (live-buffers))

(define (name buffer)
  (check-buffer 'buffers:name buffer)
  (buffer-name buffer))

(define (internal-name? name)
  (unless (string? name)
    (assertion-violation 'buffers:internal-name? "not a string" name))
  (and (fx> (string-length name) 0) (char=? (string-ref name 0) #\space)))

(define (rename! buffer name)
  (check-change 'buffers:rename! buffer)
  (rename-buffer! 'buffers:rename! buffer name))

;; The queries may pause, and another kill may end the buffer meanwhile.
(define (kill! buffer)
  (check-change 'buffers:kill! buffer)
  (and (with-current buffer
         (lambda () (for-all (lambda (entry) (entry buffer)) (hook-entries kill-queries))))
       (begin
         (when (buffer-live? buffer)
           (with-current buffer (lambda () (killed buffer)))
           (forget-buffer! buffer))
         #t)))

(define (live? buffer)
  (check-buffer 'buffers:live? buffer)
  (buffer-live? buffer))

;; Code inside with-buffer of this buffer has the old scope bound, so
;; the innermost binding moves to the new one.
(define (reset-scope! buffer)
  (check-change 'buffers:reset-scope! buffer)
  (let ([old (buffer-scope buffer)] [new (make-scope)])
    (with-interrupts-disabled
      (buffer-scope-set! buffer new)
      (when (eq? (current-scope) old)
        (current-scope new)))))

(define (buffer? v) (buffer-record? v))

(define-syntax with-buffer
  (syntax-rules ()
    [(_ buffer-expr body1 body2 ...) (call-with-buffer buffer-expr (lambda () body1 body2 ...))]))

(define (call-with-buffer buffer thunk)
  (check-buffer 'buffers:call-with-buffer buffer)
  (unless (procedure? thunk)
    (assertion-violation 'buffers:call-with-buffer "not a procedure" thunk))
  (with-current buffer thunk))

(define (current) (current-buffer))

(define (document buffer)
  (check-buffer 'buffers:document buffer)
  (check-main-thread 'buffers:document)
  (frozen-document buffer))

(define (version buffer)
  (check-buffer 'buffers:version buffer)
  (buffer-version buffer))

(define (modified? buffer)
  (check-buffer 'buffers:modified? buffer)
  (not (eqv? (buffer-save-stamp buffer) (buffer-version buffer))))

;; The version counts edits, so marking a buffer modified cannot move it
;; past the stamp as Emacs moves its modification count; the stamp leaves
;; the versions instead, unique to the version it was marked at.
(define (set-modified! buffer flag)
  (check-change 'buffers:set-modified! buffer)
  (let ([version (buffer-version buffer)])
    (cond
      [(not flag) (buffer-save-stamp-set! buffer version)]
      [(eqv? (buffer-save-stamp buffer) version) (buffer-save-stamp-set! buffer (fx- -1 version))])))

(define (save-stamp buffer)
  (check-buffer 'buffers:save-stamp buffer)
  (buffer-save-stamp buffer))

(define replace!
  (case-lambda
    [(buffer start end content)
     (replace-content! 'buffers:replace! buffer start end content #f)]
    [(buffer start end content spans)
     (unless (list? spans)
       (assertion-violation 'buffers:replace! "not a list" spans))
     (replace-content! 'buffers:replace! buffer start end content spans)]))

(define splice!
  (case-lambda
    [(buffer start end content)
     (splice-content! 'buffers:splice! buffer start end content #f)]
    [(buffer start end content spans)
     (unless (list? spans)
       (assertion-violation 'buffers:splice! "not a list" spans))
     (splice-content! 'buffers:splice! buffer start end content spans)]))

(define (reconcile! buffer node children)
  (check-change 'buffers:reconcile! buffer)
  (unless (document:node? node)
    (assertion-violation 'buffers:reconcile! "not a node" node))
  (reconcile-node! 'buffers:reconcile! buffer node children))

(define (refused? v) (refused-condition? v))

(define (edits-since buffer version)
  (check-buffer 'buffers:edits-since buffer)
  (check-main-thread 'buffers:edits-since)
  (check-version 'buffers:edits-since buffer version)
  (edits-after buffer version))

(define (map-position buffer position version)
  (check-buffer 'buffers:map-position buffer)
  (check-main-thread 'buffers:map-position)
  (check-version 'buffers:map-position buffer version)
  (unless (and (fixnum? position) (fx>= position 0))
    (assertion-violation 'buffers:map-position "not a position" position))
  (map-position-through 'buffers:map-position buffer position version))

(define (edit-version edit)
  (check-edit 'buffers:edit-version edit)
  (edit-record-version edit))

(define (edit-start edit)
  (check-edit 'buffers:edit-start edit)
  (edit-record-start edit))

(define (edit-removed edit)
  (check-edit 'buffers:edit-removed edit)
  (edit-record-removed edit))

(define (edit-inserted edit)
  (check-edit 'buffers:edit-inserted edit)
  (edit-record-inserted edit))

(define (edit-spans edit)
  (check-edit 'buffers:edit-spans edit)
  (values (edit-record-removed-spans edit) (edit-record-inserted-spans edit)))

(define (edit? v) (edit-record? v))

;; Clause names are compared as symbols, so a module that defines text,
;; all or none for itself can still write them as clauses.
(define-syntax define-kind
  (lambda (x)
    (define (invalid c) (syntax-violation 'buffers:define-kind "invalid clause" x c))
    (syntax-case x ()
      [(_ id clause ...)
       (identifier? #'id)
       (let loop ([clauses #'(clause ...)] [seen '()] [content #''text] [inline #'#f] [sticky #''both]
                  [stops #''all] [draw #'#f] [keymap #'#f] [consent #'#f] [whole #'#f])
         (if (null? clauses)
             #`(define-public id (define-kind! 'id #,content #,inline #,sticky #,stops #,draw #,keymap #,consent #,whole))
             (let* ([c (car clauses)] [rest (cdr clauses)]
                    [name (syntax-case c () [(k . _) (identifier? #'k) (syntax->datum #'k)] [_ (invalid c)])])
               (define (choice options)
                 (syntax-case c ()
                   [(_ v) (and (identifier? #'v) (memq (syntax->datum #'v) options)) #''v]
                   [_ (invalid c)]))
               (define (expression)
                 (syntax-case c () [(_ e) #'e] [_ (invalid c)]))
               (when (memq name seen)
                 (syntax-violation 'buffers:define-kind "clause given twice" x c))
               (let ([seen (cons name seen)])
                 (case name
                   [(content) (loop rest seen (choice '(text nodes atom)) inline sticky stops draw keymap consent whole)]
                   [(inline)
                    (syntax-case c ()
                      [(_) (loop rest seen content #'#t sticky stops draw keymap consent whole)]
                      [_ (invalid c)])]
                   [(sticky) (loop rest seen content inline (choice '(before after both neither)) stops draw keymap consent whole)]
                   [(stops) (loop rest seen content inline sticky (choice '(all children none)) draw keymap consent whole)]
                   [(draw) (loop rest seen content inline sticky stops (expression) keymap consent whole)]
                   [(keymap) (loop rest seen content inline sticky stops draw (expression) consent whole)]
                   [(consent) (loop rest seen content inline sticky stops draw keymap (expression) whole)]
                   [(whole)
                    (syntax-case c ()
                      [(_) (loop rest seen content inline sticky stops draw keymap consent #'#t)]
                      [_ (invalid c)])]
                   [else (invalid c)])))))]
      [_ (syntax-violation 'buffers:define-kind "expected (buffers:define-kind id clause ...)" x)])))

(define (kind name)
  (unless (symbol? name)
    (assertion-violation 'buffers:kind "not a symbol" name))
  (find-kind name))

(define (kind-draw kind)
  (check-kind 'buffers:kind-draw kind)
  (kind-entry-draw kind))

(define (kind-keymap kind)
  (check-kind 'buffers:kind-keymap kind)
  (kind-entry-keymap kind))

(define (kind-whole? kind)
  (check-kind 'buffers:kind-whole? kind)
  (kind-entry-whole? kind))

(define (kind? v) (kind-entry? v))

(define (stop buffer position)
  (check-buffer 'buffers:stop buffer)
  (check-main-thread 'buffers:stop)
  (check-position 'buffers:stop buffer position)
  (stop-at buffer position))

(define (next-stop buffer position)
  (check-buffer 'buffers:next-stop buffer)
  (check-main-thread 'buffers:next-stop)
  (check-position 'buffers:next-stop buffer position)
  (next-stop-after buffer position))

(define (previous-stop buffer position)
  (check-buffer 'buffers:previous-stop buffer)
  (check-main-thread 'buffers:previous-stop)
  (check-position 'buffers:previous-stop buffer position)
  (previous-stop-before buffer position))

(define-syntax define-layer
  (lambda (x)
    (define (invalid c) (syntax-violation 'buffers:define-layer "invalid clause" x c))
    (syntax-case x ()
      [(_ id clause ...)
       (identifier? #'id)
       (let loop ([clauses #'(clause ...)] [seen '()] [priority #'0] [sticky #''neither]
                  [evaporate #'#f] [travels #'#f] [read-only #'#f] [keymap #'#f])
         (if (null? clauses)
             #`(define-public id
                 (define-layer-type! 'id #,priority #,sticky #,evaporate #,travels #,read-only #,keymap))
             (let* ([c (car clauses)] [rest (cdr clauses)]
                    [name (syntax-case c () [(k . _) (identifier? #'k) (syntax->datum #'k)] [_ (invalid c)])])
               (define (flag)
                 (syntax-case c () [(_) #'#t] [_ (invalid c)]))
               (define (expression)
                 (syntax-case c () [(_ e) #'e] [_ (invalid c)]))
               (when (memq name seen)
                 (syntax-violation 'buffers:define-layer "clause given twice" x c))
               (let ([seen (cons name seen)])
                 (case name
                   [(priority) (loop rest seen (expression) sticky evaporate travels read-only keymap)]
                   [(sticky)
                    (syntax-case c ()
                      [(_ v) (and (identifier? #'v) (memq (syntax->datum #'v) '(before after both neither)))
                       (loop rest seen priority #''v evaporate travels read-only keymap)]
                      [_ (invalid c)])]
                   [(evaporate) (loop rest seen priority sticky (flag) travels read-only keymap)]
                   [(travels) (loop rest seen priority sticky evaporate (flag) read-only keymap)]
                   [(read-only) (loop rest seen priority sticky evaporate travels (flag) keymap)]
                   [(keymap) (loop rest seen priority sticky evaporate travels read-only (expression))]
                   [else (invalid c)])))))]
      [_ (syntax-violation 'buffers:define-layer "expected (buffers:define-layer id clause ...)" x)])))

(define layer
  (case-lambda
    [(buffer type) (layer-of 'buffers:layer buffer type #f)]
    [(buffer type key) (layer-of 'buffers:layer buffer type key)]))

(define layers
  (case-lambda
    [(buffer) (layers-for 'buffers:layers buffer #f)]
    [(buffer key) (layers-for 'buffers:layers buffer key)]))

(define set-spans!
  (case-lambda
    [(layer start end spans)
     (check-layer-change 'buffers:set-spans! layer)
     (check-range 'buffers:set-spans! (buffer-layer-buffer layer) start end)
     (check-spans 'buffers:set-spans! spans (document:length (buffer-doc (buffer-layer-buffer layer))))
     (set-layer-spans! 'buffers:set-spans! layer start end spans #f)]
    [(layer start end spans version)
     (check-layer-change 'buffers:set-spans! layer)
     (check-version 'buffers:set-spans! (buffer-layer-buffer layer) version)
     (unless (and (fixnum? start) (fixnum? end) (fx<= 0 start end))
       (assertion-violation 'buffers:set-spans! "not a range" start end))
     (check-spans 'buffers:set-spans! spans (most-positive-fixnum))
     (set-layer-spans! 'buffers:set-spans! layer start end spans version)]))

(define (add-span! layer start end value)
  (check-layer-change 'buffers:add-span! layer)
  (check-range 'buffers:add-span! (buffer-layer-buffer layer) start end)
  (add-layer-span! 'buffers:add-span! layer start end value))

(define (remove-span! layer value)
  (check-layer-change 'buffers:remove-span! layer)
  (remove-layer-spans! 'buffers:remove-span! layer value))

(define (spans layer start end)
  (check-layer-read 'buffers:spans layer)
  (check-range 'buffers:spans (buffer-layer-buffer layer) start end)
  (layer-spans layer start end))

(define (spans-at layer position)
  (check-layer-read 'buffers:spans-at layer)
  (check-position 'buffers:spans-at (buffer-layer-buffer layer) position)
  (layer-spans-at layer position))

(define (travelling-spans buffer start end)
  (check-buffer 'buffers:travelling-spans buffer)
  (check-main-thread 'buffers:travelling-spans)
  (check-range 'buffers:travelling-spans buffer start end)
  (travelling-spans-of buffer start end))

(define (layer-keymap layer)
  (check-layer 'buffers:layer-keymap layer)
  (layer-type-keymap-of layer))

(define (layer? v) (buffer-layer? v))

(define (anchor buffer position)
  (check-change 'buffers:anchor buffer)
  (check-position 'buffers:anchor buffer position)
  (make-anchor! buffer position #f))

(define (anchor-after buffer position)
  (check-change 'buffers:anchor-after buffer)
  (check-position 'buffers:anchor-after buffer position)
  (make-anchor! buffer position #t))

(define (anchor-position anchor)
  (check-anchor 'buffers:anchor-position anchor)
  (check-main-thread 'buffers:anchor-position)
  (anchor-current-position anchor))

(define (set-anchor! anchor position)
  (check-anchor 'buffers:set-anchor! anchor)
  (check-main-thread 'buffers:set-anchor!)
  (check-position 'buffers:set-anchor! (buffer-anchor-buffer anchor) position)
  (move-anchor! anchor position))

(define (anchor-deleted? anchor)
  (check-anchor 'buffers:anchor-deleted? anchor)
  (check-main-thread 'buffers:anchor-deleted?)
  (anchor-deleted-now? anchor))

(define (anchor? v) (buffer-anchor? v))

(define-kind text)
