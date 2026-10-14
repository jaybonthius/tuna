;;; The default buffers provider (live tier; ADR 6, ADR 13): texts with a
;;; change journal, undo by change records, and highlight layers that move
;;; with edits; node trees with parent links, revisions and keymaps; the
;;; buffer list; the selected view; and the node-kind registries. Starts
;;; with *scratch*, a buffer holding one empty text node, selected in a
;;; view that the layout takes over as its first view.
;;;
;;; It adapts to a new text store instead of restarting, which would discard
;;; every buffer: it moves each buffer's texts into the new store. It adds
;;; the buffer scope to settings: buffer-local values of the current buffer.
;;;
;;; Methods work on this provider's own objects through the procedures
;;; below. Describing the buffers for a handover runs while the incoming
;;; provider is already current, so it never calls the contract's
;;; dispatchers.
prelude: :gerbil/core

(import (only-in :gerbil/runtime/hash HashTable)
        (only-in :std/list/list append-map)
        :std/interface
        :tuna/kernel
        :tuna/lib/jobs
        :tuna/services/text-store
        :tuna/services/settings
        :tuna/services/buffers)
(export buffers-plugin)

;;; Texts

(defclass (default-text text)
  ((store            : :t)       ; the TextStore that made VERSION
   (version          : :t)
   (chars-revision   : :fixnum)  ; characters changed
   (content-revision : :fixnum)  ; characters or properties changed
   (journal          : :list)    ; recent changes, newest first
   (journal-length   : :fixnum)
   (undo-list        : :list)    ; changes and #f boundaries, newest first
   (undo-pending     : :list)    ; what a continued undo undoes next
   (last-undo-task   :? :fixnum) ; the task that recorded the newest change
   (decorations      : :list)    ; highlight layers: (name . spans)
   (decoration-revision : :fixnum)
   (live?            : :boolean) ; false once its buffer is killed
   (nodes            : :list))   ; the text nodes showing it
  final: #t)

(def journal-limit 1000)

(def (new-default-text (initial : :string)) => default-text
  (let (store (current-text-store))
    (default-text id: (next-id!) store: store version: (TextStore-from-string store initial)
                  chars-revision: 0 content-revision: 0 journal: [] journal-length: 0
                  undo-list: [] undo-pending: [] last-undo-task: #f
                  decorations: [] decoration-revision: 0 live?: #t nodes: [])))

;; Jobs over a text depend on its characters. A result that rebases is a
;; list of spans, moved past the text's changes since the job started; it
;; is dropped once the journal no longer reaches back that far.
(implement JobTarget default-text
  (job-revision (lambda (self) self.chars-revision))
  (job-target-alive? (lambda (self) self.live?))
  (job-rebase (lambda (self result revision)
                (let (changes (changes-since self revision))
                  (and changes [(rebase-spans result changes)])))))

;; The store that made T's version. A text keeps using it until it is
;; moved, so a text this plugin has not moved yet still works.
(def (store-of (t : default-text)) => TextStore
  (TextStore t.store))

(def (text-size-of (t : default-text)) => :fixnum
  (TextStore-size (store-of t) t.version))

(def (string-of (t : default-text)) => :string
  (TextStore-slice (store-of t) t.version 1 (fx1+ (text-size-of t))))

;; Move T's content into STORE (when the text-store provider is replaced).
(def (move-to-store! (t : default-text) (store : TextStore)) => :void
  (unless (eq? store t.store)
    (set! t.version (TextStore-from-string store (string-of t)))
    (set! t.store store)))

(def (replace! (t : default-text) (start : :fixnum) (end : :fixnum) (replacement : :string)
               (point-before :? :fixnum))
  => :void
  (unless (and (fx= start end) (string-empty? replacement))
    (let* ((store (store-of t))
           (removed (TextStore-slice store t.version start end))
           (revision (fx1+ t.chars-revision))
           (c (make-change revision start removed replacement)))
      (set! t.version (TextStore-replace store t.version start end replacement))
      (set! t.chars-revision revision)
      (set! t.content-revision (fx1+ t.content-revision))
      (record-journal! t c)
      (record-undo! t c point-before)
      (relocate-decorations! t c)
      (stamp-nodes! t.nodes)
      (run-hook after-change-hook t c))))

(def (record-journal! (t : default-text) (c : change)) => :void
  (if (fx< t.journal-length journal-limit)
    (begin
      (set! t.journal (cons c t.journal))
      (set! t.journal-length (fx1+ t.journal-length)))
    ;; Keep the newest half, so trimming is rare.
    (let (kept (fxquotient journal-limit 2))
      (set! t.journal (cons c (take t.journal kept)))
      (set! t.journal-length (fx1+ kept)))))

(def (changes-since (t : default-text) (revision : :fixnum)) => (Maybe :list)
  (let collect ((rest t.journal) (newer []))
    (match rest
      ([c . more]
       (if (fx> (change-revision c) revision)
         (collect more (cons c newer))
         newer))
      ([]
       (and (or (null? newer) (fx= (change-revision (car newer)) (fx1+ revision)))
            newer)))))

;; Each command's changes form one undo group: a change from a different
;; task than the previous one starts a new group. Entries are
;; (change . point-before) pairs.
(def (record-undo! (t : default-text) (c : change) (point-before :? :fixnum)) => :void
  (let (task (current-task-id))
    (unless (eqv? task t.last-undo-task)
      (boundary! t))
    (set! t.last-undo-task task)
    (set! t.undo-list (cons (cons c point-before) t.undo-list))))

(def (amalgamate! (t : default-text) (limit : :fixnum)) => :void
  (let count ((rest t.undo-list) (n 0))
    (match rest
      ([(? pair?) . more] (count more (fx1+ n)))
      (else
       (when (fx< n limit)
         (set! t.last-undo-task (current-task-id)))))))

(def (clear-undo! (t : default-text)) => :void
  (set! t.undo-list [])
  (set! t.undo-pending [])
  (set! t.last-undo-task #f))

(def (boundary! (t : default-text)) => :void
  (match t.undo-list
    ([#f . _] (void))
    ([] (void))
    (else (set! t.undo-list (cons #f t.undo-list)))))

(def (drop-boundaries (entries : :list)) => :list
  (match entries
    ([#f . rest] (drop-boundaries rest))
    (else entries)))

(def (undo! (t : default-text) (continue? : :boolean)) => :fixnum
  (let (pending (drop-boundaries (if continue? t.undo-pending t.undo-list)))
    (when (null? pending)
      (error "No further undo information"))
    (boundary! t)
    (let lp ((rest pending) (position 1))
      (match rest
        ([[c . point-before] . more]
         (using (c : change)
           (replace! t c.start (fx+ c.start (string-length c.inserted)) c.removed #f)
           (lp more (or point-before (fx+ c.start (string-length c.removed))))))
        (else
         (boundary! t)
         (set! t.undo-pending rest)
         position)))))

;;; Decorations

(def (set-layer! (t : default-text) (name : :symbol) (spans : :list)) => :void
  (let (size (text-size-of t))
    (set! t.decorations
      (cons (cons name (filter (lambda ((s : span))
                                 (fx<= 1 (span-start s) (span-end s) (fx1+ size)))
                               spans))
            (filter (lambda ((layer : :pair)) (not (eq? (car layer) name))) t.decorations)))
    (set! t.decoration-revision (fx1+ t.decoration-revision))
    (stamp-nodes! t.nodes)))

(def (layer-spans (t : default-text) (name : :symbol)) => :list
  (let (layer (assq name t.decorations))
    (if layer (cdr layer) [])))

(def (relocate-decorations! (t : default-text) (c : change)) => :void
  (unless (null? t.decorations)
    (set! t.decorations
      (map (lambda ((layer : :pair))
             (cons (car layer)
                   (filter-map (cut span-after-change <> c) (cdr layer))))
           t.decorations))))

;; Positions inside a deleted range move to its start; insertions at a
;; position stay after it. Changes older than the journal clamp.
(def (relocate (t : default-text) (position : :fixnum) (revision : :fixnum)) => :fixnum
  (let collect ((rest t.journal) (newer []))
    (match rest
      ([c . more]
       (if (fx> (change-revision c) revision)
         (collect more (cons c newer))
         (relocate-through newer position)))
      ([]
       (if (and (pair? newer) (fx> (change-revision (car newer)) (fx1+ revision)))
         (fxmax 1 (fxmin position (fx1+ (text-size-of t))))
         (relocate-through newer position))))))

(def (relocate-through (changes : :list) (position : :fixnum)) => :fixnum
  (let lp ((rest changes) (position position))
    (match rest
      ([c . more] (lp more (position-after-change c position #f)))
      ([] position))))

;;; Nodes

(defclass (default-node node)
  ((kind       : :symbol)
   (attributes : :list)              ; alist of symbol -> value
   (children   : :list)              ; default nodes
   (parent     :? node)           ; a default node
   (revision   : :fixnum)
   (content    :? default-text)      ; a text node's text
   (keymap     :? entry-table))
  final: #t)

;; Give N, and every node above it, one new revision. Revisions come from
;; next-id!, so they never repeat, even across providers.
(def (stamp! (n :? default-node)) => :void
  (stamp-from! n (next-id!)))

(def (stamp-from! (n :? default-node) (revision : :fixnum)) => :void
  (let lp ((n n))
    (when n
      (using (n : default-node)
        (set! n.revision revision)
        (lp n.parent)))))

(def (stamp-nodes! (nodes : :list)) => :void
  (unless (null? nodes)
    (let (revision (next-id!))
      (for-each (cut stamp-from! <> revision) nodes))))

;; Make PARENT the parent of CHILDREN, which must have none but PARENT.
(def (adopt-children! (parent : default-node) (children : :list)) => :void
  (for-each (lambda ((child : default-node))
              (when (and child.parent (not (eq? child.parent parent)))
                (error "A node already has a parent" (node-id child))))
            children)
  (for-each (lambda ((child : default-node)) (set! child.parent parent)) children))

(def (new-default-node (id : :fixnum) (kind : :symbol) (attributes : :list) (children : :list)
                        (content :? default-text) (keymap :? entry-table))
  => default-node
  (let (n (default-node id: id kind: kind attributes: attributes children: children
                        parent: #f revision: (next-id!) content: content keymap: keymap))
    (adopt-children! n children)
    (when content
      (set! (default-text-nodes content) (cons n (default-text-nodes content))))
    n))

(def (set-children! (n : default-node) (children : :list)) => :void
  (for-each (lambda ((child : default-node)) (set! child.parent #f)) n.children)
  (adopt-children! n children)
  (set! n.children children)
  (stamp! n))

(def (set-attribute! (n : default-node) (name : :symbol) (value : :t)) => :void
  (set! n.attributes (cons (cons name value)
                           (filter (lambda ((pair : :pair)) (not (eq? (car pair) name))) n.attributes)))
  (stamp! n))

(def (set-keymap! (n : default-node) (keymap :? entry-table)) => :void
  (set! n.keymap keymap)
  (stamp! n))

;; The texts of the tree at N, depth first.
(def (tree-texts (n : default-node)) => :list
  (if n.content
    [n.content]
    (append-map tree-texts n.children)))

;;; Buffers

(defclass (default-buffer buffer)
  ((name           : :string)
   (root           : default-node)
   (point-node     :? default-node)   ; point while not displayed
   (point-position : :fixnum)
   (point-revision : :fixnum)
   (settings       : :list))          ; buffer-local (setting . value) pairs
  final: #t)

;; The first text node of the tree at N, depth first.
(def (first-text (n : default-node)) => (Maybe default-node)
  (if n.content
    n
    (let lp ((children n.children))
      (match children
        ([child . more] (or (first-text child) (lp more)))
        ([] #f)))))

(def (new-default-buffer (name : :string) (root : default-node)) => default-buffer
  (when root.parent
    (error "A buffer's root must have no parent" (node-id root)))
  (let (focus (first-text root))
    (default-buffer id: (next-id!) name: name root: root point-node: focus point-position: 1
                    point-revision: (if focus (default-text-chars-revision (default-node-content focus)) 0)
                    settings: [])))

(def (point-of (b : default-buffer)) => :fixnum
  (let (n b.point-node)
    (if n
      (relocate (default-node-content n) b.point-position b.point-revision)
      b.point-position)))

(def (set-point! (b : default-buffer) (n :? default-node) (position : :fixnum)) => :void
  (set! b.point-node n)
  (if n
    (let (t (default-node-content n))
      (set! b.point-position (fxmax 1 (fxmin position (fx1+ (text-size-of t)))))
      (set! b.point-revision (default-text-chars-revision t)))
    (begin
      (set! b.point-position position)
      (set! b.point-revision 0))))

(def (set-setting! (b : default-buffer) (s : setting) (value : :t)) => :void
  (set! b.settings (cons (cons s value)
                         (filter (lambda ((pair : :pair)) (not (eq? (car pair) s))) b.settings))))

(def (new-scratch-buffer) => default-buffer
  (new-default-buffer "*scratch*" (new-default-node (next-id!) 'text [] [] (new-default-text "") #f)))

;;; The registry

(defclass buffer-registry ((buffers   : :list)          ; oldest first
                           (selected  : view)            ; the layout's selected view
                           (kinds     : entry-table)
                           (renderers : entry-table))
  final: #t)

(def (find-buffer (self : buffer-registry) (name : :string)) => (Maybe default-buffer)
  (find (lambda ((b : default-buffer)) (string=? b.name name)) self.buffers))

(def (add! (self : buffer-registry) (b : default-buffer)) => :void
  (when (find-buffer self b.name)
    (error "A buffer with this name exists" b.name))
  (set! self.buffers (append self.buffers [b])))

(def (rename! (self : buffer-registry) (b : default-buffer) (name : :string)) => :void
  (let (other (find-buffer self name))
    (when (and other (not (eq? other b)))
      (error "A buffer with this name exists" name))
    (set! b.name name)))

;; Remove B. The selected view shows another buffer if it showed B; the
;; layouts move their other views on kill-buffer-hook.
(def (kill! (self : buffer-registry) (b : default-buffer)) => :void
  (run-hook kill-buffer-hook b)
  (let (selected self.selected)
    (when (eq? b (view-showing selected))
      (let (other (find (lambda ((other : default-buffer))
                          (not (or (eq? other b) (string-prefix? " " other.name))))
                        self.buffers))
        (when other (set-view-showing! selected other)))))
  (set! self.buffers (remq b self.buffers))
  (for-each (lambda ((t : default-text)) (set! t.live? #f)) (tree-texts b.root)))

(def (move-texts! (self : buffer-registry) (store : TextStore)) => :void
  (for-each (lambda ((b : default-buffer))
              (for-each (cut move-to-store! <> store) (tree-texts b.root)))
            self.buffers))

;;; Handover

(def (describe (self : buffer-registry)) => buffers-description
  (let (texts (make-hash-table-eq))     ; default-text -> text-description
    (def (describe-text (t : default-text)) => text-description
      (or (hash-get texts t)
          (let (d (make-text-description (string-of t) t.decorations))
            (hash-put! texts t d)
            d)))
    (def (describe-node (n : default-node)) => node-description
      (make-node-description (node-id n) n.kind n.attributes (map describe-node n.children)
                             (and n.content (describe-text n.content)) n.keymap))
    (make-buffers-description
     (map (lambda ((b : default-buffer))
            (make-buffer-description b.name (describe-node b.root) b.settings
                                     (and b.point-node (node-id b.point-node)) (point-of b)))
          self.buffers)
     (let* ((v self.selected)
            (n (view-node v))
            (position (if n
                        (relocate (default-node-content n) (view-position v) (view-revision v))
                        (view-position v))))
       (make-view-description v (default-buffer-name (view-showing v))
                              (and n (node-id n)) position)))))

;; Replace this provider's buffers with those DESCRIPTION describes, and
;; point the described selected view at them. Node ids carry over, so
;; elements the browser shows keep their ids.
(def (adopt! (self : buffer-registry) (d : buffers-description)) => :void
  (for-each (lambda ((b : default-buffer))
              (for-each (lambda ((t : default-text)) (set! t.live? #f)) (tree-texts b.root)))
            self.buffers)
  (let ((texts (make-hash-table-eq))    ; text-description -> default-text
        (nodes (make-hash-table-eqv)))  ; node id -> default-node
    (def (adopt-text (d : text-description)) => default-text
      (or (hash-get texts d)
          (let (t (new-default-text (text-description-content d)))
            (set-highlights-from! t (text-description-highlights d))
            (hash-put! texts d t)
            t)))
    (def (adopt-node (d : node-description)) => default-node
      (let (n (new-default-node (node-description-id d) (node-description-kind d)
                                 (node-description-attributes d)
                                 (map adopt-node (node-description-children d))
                                 (let (text (node-description-text d))
                                   (and text (adopt-text text)))
                                 (node-description-keymap d)))
        (hash-put! nodes (node-id n) n)
        n))
    (def (adopt-buffer (d : buffer-description)) => default-buffer
      (let (b (new-default-buffer (buffer-description-name d) (adopt-node (buffer-description-root d))))
        (set! (default-buffer-settings b) (buffer-description-settings d))
        (set-point! b (text-node-of nodes (buffer-description-point-node d) b)
                    (buffer-description-point d))
        b))
    (let (buffers (map adopt-buffer (buffers-description-buffers d)))
      (set! self.buffers (if (null? buffers) [(new-scratch-buffer)] buffers))
      (let* ((vd (buffers-description-selected d))
             (b (or (find-buffer self (view-description-buffer vd)) (car self.buffers)))
             (n (text-node-of nodes (view-description-node vd) b))
             (t (and n (default-node-content n))))
        (reset-view! (view-description-of vd) b n
                     (if t
                       (fxmax 1 (fxmin (view-description-point vd) (fx1+ (text-size-of t))))
                       (view-description-point vd))
                     (if t (default-text-chars-revision t) 0))
        (set! self.selected (view-description-of vd))))))

;; The text node with id ID in NODES, or else B's first text node.
(def (text-node-of (nodes : HashTable) (id :? :fixnum) (b : default-buffer)) => (Maybe default-node)
  (let (n (and id (hash-get nodes id)))
    (if (and n (default-node-content n))
      n
      (first-text b.root))))

(def (set-highlights-from! (t : default-text) (layers : :list)) => :void
  (for-each (lambda ((layer : :pair)) (set-layer! t (car layer) (cdr layer))) layers))

(implement Buffers buffer-registry
  (make-text (lambda (self initial) (new-default-text initial)))
  (text-snapshot (lambda (self t)
                   (using (t : default-text)
                     (make-snapshot (store-of t) t.version t.chars-revision))))
  (text-content-revision (lambda (self t) (using (t : default-text) t.content-revision)))
  (text-decoration-revision (lambda (self t) (using (t : default-text) t.decoration-revision)))
  (text-live? (lambda (self t) (and (default-text? t) (using (t : default-text) t.live?))))
  (text-replace! (lambda (self t start end replacement point-before)
                   (replace! t start end replacement point-before)))
  (text-changes-since (lambda (self t revision) (changes-since t revision)))
  (relocate-position (lambda (self t position revision) (relocate t position revision)))
  (undo-boundary! (lambda (self t) (boundary! t)))
  (undo-amalgamate! (lambda (self t limit) (amalgamate! t limit)))
  (text-undo! (lambda (self t continue?) (undo! t continue?)))
  (text-clear-undo! (lambda (self t) (clear-undo! t)))
  (set-highlights! (lambda (self t name spans) (set-layer! t name spans)))
  (text-highlights (lambda (self t name) (layer-spans t name)))
  (text-all-highlights (lambda (self t) (using (t : default-text) (:- (append-map cdr t.decorations) :list))))
  (make-node (lambda (self kind attributes children)
               (new-default-node (next-id!) kind attributes children #f #f)))
  (make-text-node (lambda (self t) (new-default-node (next-id!) 'text [] [] t #f)))
  (node-kind (lambda (self n) (using (n : default-node) n.kind)))
  (node-attributes (lambda (self n) (using (n : default-node) n.attributes)))
  (set-node-attribute! (lambda (self n name value) (set-attribute! n name value)))
  (node-keymap (lambda (self n) (using (n : default-node) n.keymap)))
  (set-node-keymap! (lambda (self n keymap) (set-keymap! n keymap)))
  (node-parent (lambda (self n) (using (n : default-node) n.parent)))
  (node-revision (lambda (self n) (using (n : default-node) n.revision)))
  (node-text (lambda (self n) (using (n : default-node) n.content)))
  (node-child-count (lambda (self n) (using (n : default-node) (length n.children))))
  (node-children (lambda (self n start end)
                   (using (n : default-node)
                     (take (list-tail n.children start) (fx- end start)))))
  (set-node-children! (lambda (self n children) (set-children! n children)))
  (make-buffer (lambda (self name root) (new-default-buffer name root)))
  (buffer-list (lambda (self) self.buffers))
  (add-buffer! (lambda (self b) (add! self b)))
  (kill-buffer! (lambda (self b) (kill! self b)))
  (buffer-name (lambda (self b) (using (b : default-buffer) b.name)))
  (rename-buffer! (lambda (self b name) (rename! self b name)))
  (buffer-root (lambda (self b) (using (b : default-buffer) b.root)))
  (buffer-setting (lambda (self b s) (using (b : default-buffer) (assq s b.settings))))
  (set-buffer-setting! (lambda (self b s value) (set-setting! b s value)))
  (buffer-point-node (lambda (self b) (using (b : default-buffer) b.point-node)))
  (buffer-point (lambda (self b) (point-of b)))
  (set-buffer-point! (lambda (self b n position) (set-point! b n position)))
  (selected-view (lambda (self) self.selected))
  (set-selected-view! (lambda (self v) (set! self.selected v)))
  (node-kinds (lambda (self) self.kinds))
  (node-renderers (lambda (self) self.renderers))
  (describe-buffers (lambda (self) (describe self)))
  (adopt-buffers! (lambda (self description) (adopt! self description))))

(defplugin (buffers-plugin ctx)
  "Keeps buffers, their texts and nodes, and node kinds; starts with *scratch*."
  requires: [text-store-service settings-service]
  optional: [buffers-service messages-service]
  (let* ((scratch (new-scratch-buffer))
         (focus (default-buffer-point-node scratch))
         (registry (buffer-registry buffers: [scratch]
                                    selected: (new-view-at scratch focus 1 0)
                                    kinds: (new-entry-table)
                                    renderers: (new-entry-table))))
    ;; Into this provider's own table: another provider may be current.
    (context-add-entry! ctx (buffer-registry-kinds registry) 'text
                        (make-node-kind-info 'text "Text that users edit."
                                             (lambda (n) (text-string (text-node-content n))))
                        doc: "Text that users edit.")
    (context-provide! ctx buffers-service (Buffers registry))
    (context-adapt! ctx text-store-service
                    (lambda (old new) (move-texts! registry (TextStore new))))
    (context-add-setting-scope! ctx 'buffer
                                (lambda (s) (buffer-setting (settings-buffer) s)))))
