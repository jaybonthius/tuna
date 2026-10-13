;;; The toy buffers provider (live tier): the buffers contract kept as
;;; simply as possible, differently from the default. It proves buffers can
;;; be swapped while Tuna runs (ADR 12, ADR 13): taking over, it rebuilds
;;; the outgoing provider's buffers from their neutral description.
;;;
;;; Differences from the default (tuna/plugins/buffers.ss): undo keeps,
;;; for each group, the whole text version from before it, and undoing
;;; restores that version as one minimal change (common prefix and suffix
;;; kept), so undoing a group also undoes later changes no group recorded;
;;; the journal keeps only the newest 100 changes; highlight layers live in
;;; a hash table; a node keeps its children in a vector; the buffer list is
;;; kept newest first.
prelude: :gerbil/core

(import (only-in :gerbil/runtime/hash HashTable)
        (only-in :std/list/list append-map)
        :std/interface
        :tuna/kernel
        :tuna/lib/jobs
        :tuna/services/text-store
        :tuna/services/settings
        :tuna/services/buffers)
(export toy-buffers-plugin)

;;; Texts

;; One undo group: the version before its first change and the store that
;; made it, where point was then (if known), and how many changes it holds.
(defclass undo-group ((store          : :t)
                      (version-before : :t)
                      (point-before   :? :fixnum)
                      (count          : :fixnum))
  final: #t)

(defclass (toy-text text)
  ((store               : :t)
   (version             : :t)
   (revision            : :fixnum)   ; characters changed
   (content-revision    : :fixnum)
   (decoration-revision : :fixnum)
   (journal             : :list)     ; changes, newest first, at most journal-limit
   (groups              : :list)     ; undo groups, newest first
   (open?               : :boolean)  ; whether the newest group takes more changes
   (last-task           :? :fixnum)
   (pending             : :list)     ; what a continued undo undoes next
   (layers              : HashTable) ; highlight layer name -> spans
   (live?               : :boolean)
   (nodes               : :list))
  final: #t)

(def journal-limit 100)

(def (new-toy-text (initial : :string)) => toy-text
  (let (store (current-text-store))
    (toy-text id: (next-id!) store: store version: (TextStore-from-string store initial)
              revision: 0 content-revision: 0 decoration-revision: 0 journal: []
              groups: [] open?: #f last-task: #f pending: []
              layers: (make-hash-table-eq) live?: #t nodes: [])))

(implement JobTarget toy-text
  (job-revision (lambda (self) self.revision))
  (job-target-alive? (lambda (self) self.live?))
  (job-rebase (lambda (self result revision)
                (let (changes (toy-changes-since self revision))
                  (and changes [(rebase-spans result changes)])))))

(def (toy-store (t : toy-text)) => TextStore
  (TextStore t.store))

(def (toy-size (t : toy-text)) => :fixnum
  (TextStore-size (toy-store t) t.version))

(def (toy-string (t : toy-text)) => :string
  (TextStore-slice (toy-store t) t.version 1 (fx1+ (toy-size t))))

(def (record-group! (t : toy-text) (point-before :? :fixnum)) => :void
  (let (task (current-task-id))
    (if (and t.open? (eqv? task t.last-task) (pair? t.groups))
      (using (g (car t.groups) : undo-group)
        (set! g.count (fx1+ g.count)))
      (set! t.groups (cons (undo-group store: t.store version-before: t.version
                                       point-before: point-before count: 1)
                           t.groups)))
    (set! t.open? #t)
    (set! t.last-task task)))

(def (toy-replace! (t : toy-text) (start : :fixnum) (end : :fixnum) (replacement : :string)
                   (point-before :? :fixnum))
  => :void
  (unless (and (fx= start end) (string-empty? replacement))
    (let* ((store (toy-store t))
           (c (make-change (fx1+ t.revision) start (TextStore-slice store t.version start end)
                           replacement)))
      (record-group! t point-before)
      (set! t.version (TextStore-replace store t.version start end replacement))
      (set! t.revision (change-revision c))
      (set! t.content-revision (fx1+ t.content-revision))
      (set! t.journal (let (journal (cons c t.journal))
                        (if (fx> (length journal) journal-limit) (take journal journal-limit) journal)))
      (hash-for-each (lambda (name spans)
                       (hash-put! t.layers name (filter-map (cut span-after-change <> c) spans)))
                     t.layers)
      (stamp-all! t.nodes)
      (run-hook after-change-hook t c))))

(def (toy-changes-since (t : toy-text) (revision : :fixnum)) => (Maybe :list)
  (let (newer (reverse (filter (lambda ((c : change)) (fx> c.revision revision)) t.journal)))
    (and (or (null? newer) (fx= (change-revision (car newer)) (fx1+ revision)))
         newer)))

(def (toy-relocate (t : toy-text) (position : :fixnum) (revision : :fixnum)) => :fixnum
  (let (changes (toy-changes-since t revision))
    (if changes
      (foldl (lambda ((c : change) (p : :fixnum)) (position-after-change c p #f)) position changes)
      (fxmax 1 (fxmin position (fx1+ (toy-size t)))))))

;; Make T's content VERSION of STORE again, as one change replacing what
;; differs between the two. Returns where the changed text ends now, or #f
;; when nothing differs.
(def (restore-version! (t : toy-text) (store : TextStore) (version : :t)) => (Maybe :fixnum)
  (let* ((old (toy-string t))
         (new (TextStore-slice store version 1 (fx1+ (TextStore-size store version))))
         (old-size (string-length old))
         (new-size (string-length new))
         (prefix (let lp ((i 0))
                   (if (and (fx< i old-size) (fx< i new-size)
                            (char=? (string-ref old i) (string-ref new i)))
                     (lp (fx1+ i))
                     i)))
         (suffix (let lp ((i 0))
                   (if (and (fx< i (fx- old-size prefix)) (fx< i (fx- new-size prefix))
                            (char=? (string-ref old (fx- old-size i 1)) (string-ref new (fx- new-size i 1))))
                     (lp (fx1+ i))
                     i))))
    (and (not (string=? old new))
         (let (inserted (substring new prefix (fx- new-size suffix)))
           (toy-replace! t (fx1+ prefix) (fx1+ (fx- old-size suffix)) inserted #f)
           (fx+ (fx1+ prefix) (string-length inserted))))))

(def (toy-undo! (t : toy-text) (continue? : :boolean)) => :fixnum
  (let (pending (if continue? t.pending t.groups))
    (when (null? pending)
      (error "No further undo information"))
    (set! t.open? #f)
    (using (g (car pending) : undo-group)
      (let (end (restore-version! t (TextStore g.store) g.version-before))
        (set! t.open? #f)
        (set! t.pending (cdr pending))
        (or g.point-before end 1)))))

(def (toy-amalgamate! (t : toy-text) (limit : :fixnum)) => :void
  (match t.groups
    ([g . _]
     (when (fx< (undo-group-count g) limit)
       (set! t.last-task (current-task-id))))
    ([] (void))))

(def (toy-set-highlights! (t : toy-text) (name : :symbol) (spans : :list)) => :void
  (let (size (toy-size t))
    (hash-put! t.layers name (filter (lambda ((s : span))
                                       (fx<= 1 (span-start s) (span-end s) (fx1+ size)))
                                     spans))
    (set! t.decoration-revision (fx1+ t.decoration-revision))
    (stamp-all! t.nodes)))

;;; Nodes

(defclass (toy-node node)
  ((kind       : :symbol)
   (attributes : :list)
   (children   : :vector)
   (parent     :? node)
   (revision   : :fixnum)
   (text       :? toy-text))
  final: #t)

(def (stamp-all! (nodes : :list)) => :void
  (let (revision (next-id!))
    (for-each (lambda (n)
                (let lp ((n n))
                  (when n
                    (using (n : toy-node)
                      (set! n.revision revision)
                      (lp n.parent)))))
              nodes)))

(def (attach! (parent : toy-node) (children : :list)) => :void
  (for-each (lambda ((child : toy-node))
              (unless (or (not child.parent) (eq? child.parent parent))
                (error "A node already has a parent" (node-id child)))
              (set! child.parent parent))
            children))

(def (new-toy-node (id : :fixnum) (kind : :symbol) (attributes : :list) (children : :list)
                   (text :? toy-text))
  => toy-node
  (let (n (toy-node id: id kind: kind attributes: attributes children: (list->vector children)
                    parent: #f revision: (next-id!) text: text))
    (attach! n children)
    (when text
      (set! (toy-text-nodes text) (cons n (toy-text-nodes text))))
    n))

(def (toy-tree-texts (n : toy-node)) => :list
  (if n.text
    [n.text]
    (append-map toy-tree-texts (vector->list n.children))))

(def (first-toy-text-node (n : toy-node)) => (Maybe toy-node)
  (if n.text
    n
    (let lp ((children (vector->list n.children)))
      (match children
        ([child . more] (or (first-toy-text-node child) (lp more)))
        ([] #f)))))

;;; Buffers

(defclass (toy-buffer buffer)
  ((name       : :string)
   (root       : toy-node)
   (point-node :? toy-node)
   (point      : :fixnum)
   (revision   : :fixnum)    ; of the point node's text, when POINT was set
   (settings   : :list))
  final: #t)

(def (new-toy-buffer (name : :string) (root : toy-node)) => toy-buffer
  (when root.parent
    (error "A buffer's root must have no parent" (node-id root)))
  (let (n (first-toy-text-node root))
    (toy-buffer id: (next-id!) name: name root: root point-node: n point: 1
                revision: (if n (toy-text-revision (toy-node-text n)) 0) settings: [])))

(def (toy-buffer-point-now (b : toy-buffer)) => :fixnum
  (let (n b.point-node)
    (if n (toy-relocate (toy-node-text n) b.point b.revision) b.point)))

(def (toy-set-point! (b : toy-buffer) (n :? toy-node) (position : :fixnum)) => :void
  (set! b.point-node n)
  (if n
    (let (t (toy-node-text n))
      (set! b.point (fxmax 1 (fxmin position (fx1+ (toy-size t)))))
      (set! b.revision (toy-text-revision t)))
    (begin
      (set! b.point position)
      (set! b.revision 0))))

(def (toy-scratch) => toy-buffer
  (new-toy-buffer "*scratch*" (new-toy-node (next-id!) 'text [] [] (new-toy-text ""))))

;;; The provider

(defclass toy-buffers ((newest-first : :list)   ; the buffers, newest first
                       (selected     : view)
                       (kinds        : entry-table)
                       (renderers    : entry-table))
  final: #t)

(def (toy-find (self : toy-buffers) (name : :string)) => (Maybe toy-buffer)
  (find (lambda ((b : toy-buffer)) (string=? b.name name)) self.newest-first))

(def (toy-kill! (self : toy-buffers) (b : toy-buffer)) => :void
  (run-hook kill-buffer-hook b)
  (let (v self.selected)
    (when (eq? b (view-showing v))
      (let (other (find (lambda ((o : toy-buffer)) (not (or (eq? o b) (string-prefix? " " o.name))))
                        (reverse self.newest-first)))
        (when other (set-view-showing! v other)))))
  (set! self.newest-first (remq b self.newest-first))
  (for-each (lambda ((t : toy-text)) (set! t.live? #f)) (toy-tree-texts b.root)))

(def (toy-describe (self : toy-buffers)) => buffers-description
  (let (texts (make-hash-table-eq))
    (def (describe-text (t : toy-text)) => text-description
      (or (hash-get texts t)
          (let (d (make-text-description (toy-string t) (hash->list t.layers)))
            (hash-put! texts t d)
            d)))
    (def (describe-node (n : toy-node)) => node-description
      (make-node-description (node-id n) n.kind n.attributes
                             (map describe-node (vector->list n.children))
                             (and n.text (describe-text n.text))))
    (make-buffers-description
     (map (lambda ((b : toy-buffer))
            (make-buffer-description b.name (describe-node b.root) b.settings
                                     (and b.point-node (node-id b.point-node))
                                     (toy-buffer-point-now b)))
          (reverse self.newest-first))
     (let* ((v self.selected)
            (n (view-node v)))
       (make-view-description v (toy-buffer-name (view-showing v)) (and n (node-id n))
                              (if n
                                (toy-relocate (toy-node-text n) (view-position v) (view-revision v))
                                (view-position v)))))))

(def (toy-adopt! (self : toy-buffers) (d : buffers-description)) => :void
  (for-each (lambda ((b : toy-buffer))
              (for-each (lambda ((t : toy-text)) (set! t.live? #f)) (toy-tree-texts b.root)))
            self.newest-first)
  (let ((texts (make-hash-table-eq))
        (nodes (make-hash-table-eqv)))
    (def (adopt-text (d : text-description)) => toy-text
      (or (hash-get texts d)
          (let (t (new-toy-text (text-description-content d)))
            (for-each (lambda ((layer : :pair)) (toy-set-highlights! t (car layer) (cdr layer)))
                      (text-description-highlights d))
            (hash-put! texts d t)
            t)))
    (def (adopt-node (d : node-description)) => toy-node
      (let (n (new-toy-node (node-description-id d) (node-description-kind d)
                            (node-description-attributes d)
                            (map adopt-node (node-description-children d))
                            (let (text (node-description-text d)) (and text (adopt-text text)))))
        (hash-put! nodes (node-id n) n)
        n))
    (def (text-node-in (id :? :fixnum) (b : toy-buffer)) => (Maybe toy-node)
      (let (n (and id (hash-get nodes id)))
        (if (and n (toy-node-text n)) n (first-toy-text-node b.root))))
    (let (buffers (map (lambda ((d : buffer-description))
                         (let (b (new-toy-buffer (buffer-description-name d)
                                                 (adopt-node (buffer-description-root d))))
                           (set! (toy-buffer-settings b) (buffer-description-settings d))
                           (toy-set-point! b (text-node-in (buffer-description-point-node d) b)
                                           (buffer-description-point d))
                           b))
                       (buffers-description-buffers d)))
      (set! self.newest-first (if (null? buffers) [(toy-scratch)] (reverse buffers)))
      (let* ((vd (buffers-description-selected d))
             (b (or (toy-find self (view-description-buffer vd)) (last self.newest-first)))
             (n (text-node-in (view-description-node vd) b))
             (t (and n (toy-node-text n))))
        (reset-view! (view-description-of vd) b n
                     (if t
                       (fxmax 1 (fxmin (view-description-point vd) (fx1+ (toy-size t))))
                       (view-description-point vd))
                     (if t (toy-text-revision t) 0))
        (set! self.selected (view-description-of vd))))))

(implement Buffers toy-buffers
  (make-text (lambda (self initial) (new-toy-text initial)))
  (text-snapshot (lambda (self t)
                   (using (t : toy-text) (make-snapshot (toy-store t) t.version t.revision))))
  (text-content-revision (lambda (self t) (using (t : toy-text) t.content-revision)))
  (text-decoration-revision (lambda (self t) (using (t : toy-text) t.decoration-revision)))
  (text-live? (lambda (self t) (and (toy-text? t) (using (t : toy-text) t.live?))))
  (text-replace! (lambda (self t start end replacement point-before)
                   (toy-replace! t start end replacement point-before)))
  (text-changes-since (lambda (self t revision) (toy-changes-since t revision)))
  (relocate-position (lambda (self t position revision) (toy-relocate t position revision)))
  (undo-boundary! (lambda (self t) (using (t : toy-text) (set! t.open? #f))))
  (undo-amalgamate! (lambda (self t limit) (toy-amalgamate! t limit)))
  (text-undo! (lambda (self t continue?) (toy-undo! t continue?)))
  (text-clear-undo! (lambda (self t)
                      (using (t : toy-text)
                        (set! t.groups [])
                        (set! t.pending [])
                        (set! t.open? #f))))
  (set-highlights! (lambda (self t name spans) (toy-set-highlights! t name spans)))
  (text-highlights (lambda (self t name) (using (t : toy-text) (hash-ref t.layers name []))))
  (text-all-highlights (lambda (self t)
                         (using (t : toy-text) (:- (append-map cdr (hash->list t.layers)) :list))))
  (make-node (lambda (self kind attributes children)
               (new-toy-node (next-id!) kind attributes children #f)))
  (make-text-node (lambda (self t) (new-toy-node (next-id!) 'text [] [] t)))
  (node-kind (lambda (self n) (using (n : toy-node) n.kind)))
  (node-attributes (lambda (self n) (using (n : toy-node) n.attributes)))
  (set-node-attribute! (lambda (self n name value)
                         (using (n : toy-node)
                           (set! n.attributes (cons (cons name value)
                                                    (filter (lambda ((pair : :pair)) (not (eq? (car pair) name)))
                                                            n.attributes)))
                           (stamp-all! [n]))))
  (node-parent (lambda (self n) (using (n : toy-node) n.parent)))
  (node-revision (lambda (self n) (using (n : toy-node) n.revision)))
  (node-text (lambda (self n) (using (n : toy-node) n.text)))
  (node-child-count (lambda (self n) (using (n : toy-node) (vector-length n.children))))
  (node-children (lambda (self n start end)
                   (using (n : toy-node) (:- (vector->list n.children start end) :list))))
  (set-node-children! (lambda (self n children)
                        (using (n : toy-node)
                          (vector-for-each (lambda ((child : toy-node)) (set! child.parent #f)) n.children)
                          (attach! n children)
                          (set! n.children (list->vector children))
                          (stamp-all! [n]))))
  (make-buffer (lambda (self name root) (new-toy-buffer name root)))
  (buffer-list (lambda (self) (reverse self.newest-first)))
  (add-buffer! (lambda (self b)
                 (using (b : toy-buffer)
                   (when (toy-find self b.name)
                     (error "A buffer with this name exists" b.name))
                   (set! self.newest-first (cons b self.newest-first)))))
  (kill-buffer! (lambda (self b) (toy-kill! self b)))
  (buffer-name (lambda (self b) (using (b : toy-buffer) b.name)))
  (rename-buffer! (lambda (self b name)
                    (using (b : toy-buffer)
                      (let (other (toy-find self name))
                        (when (and other (not (eq? other b)))
                          (error "A buffer with this name exists" name))
                        (set! b.name name)))))
  (buffer-root (lambda (self b) (using (b : toy-buffer) b.root)))
  (buffer-setting (lambda (self b s) (using (b : toy-buffer) (assq s b.settings))))
  (set-buffer-setting! (lambda (self b s value)
                         (using (b : toy-buffer)
                           (set! b.settings (cons (cons s value)
                                                  (filter (lambda ((pair : :pair)) (not (eq? (car pair) s)))
                                                          b.settings))))))
  (buffer-point-node (lambda (self b) (using (b : toy-buffer) b.point-node)))
  (buffer-point (lambda (self b) (toy-buffer-point-now b)))
  (set-buffer-point! (lambda (self b n position) (toy-set-point! b n position)))
  (selected-view (lambda (self) self.selected))
  (set-selected-view! (lambda (self v) (set! self.selected v)))
  (node-kinds (lambda (self) self.kinds))
  (node-renderers (lambda (self) self.renderers))
  (describe-buffers (lambda (self) (toy-describe self)))
  (adopt-buffers! (lambda (self description) (toy-adopt! self description))))

(defplugin (toy-buffers-plugin ctx)
  "Keeps buffers simply (a toy). Outranks the default buffers provider while active."
  requires: [text-store-service settings-service]
  (let* ((scratch (toy-scratch))
         (self (toy-buffers newest-first: [scratch]
                            selected: (new-view-at scratch (toy-buffer-point-node scratch) 1 0)
                            kinds: (new-entry-table) renderers: (new-entry-table))))
    (context-add-entry! ctx (toy-buffers-kinds self) 'text
                        (make-node-kind-info 'text "Text that users edit."
                                             (lambda (n) (text-string (text-node-content n))))
                        doc: "Text that users edit.")
    (context-provide! ctx buffers-service (Buffers self) priority: 10)
    (context-adapt! ctx text-store-service
                    (lambda (old new)
                      (let (store (TextStore new))
                        (for-each (lambda ((b : toy-buffer))
                                    (for-each (lambda ((t : toy-text))
                                                (set! t.version (TextStore-from-string store (toy-string t)))
                                                (set! t.store store))
                                              (toy-tree-texts b.root)))
                                  (toy-buffers-newest-first self)))))
    (context-add-setting-scope! ctx 'buffer
                                (lambda (s) (buffer-setting (settings-buffer) s)))))
