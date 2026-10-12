;;; Texts, buffers, views, and nodes (ADR 6), and the buffers service that
;;; holds them.
;;;
;;; A text holds content: a text-store version, revisions, a change journal,
;;; and undo history. A buffer is a named tree of nodes; text nodes refer to
;;; texts, and any other node kind is defined by a plugin. The view is the
;;; buffer as the one window shows it: the focused text node, point, and the
;;; goal column. Editing primitives act on the view's focused text node.
;;; Positions are 1-based character positions within that node's text.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        :tuna/services/text-store)
(export (interface-out Buffers)
        buffers-service
        ;; texts
        text text? new-text
        text-chars-revision text-content-revision text-journal text-snapshot
        text-size text-substring text-string
        text-line-count text-line-at text-line-start text-line-end
        text-column text-position-at
        text-replace! undo-boundary! text-undo!
        relocate-position
        ;; nodes and node kinds
        node node? node-id node-kind node-attributes node-children
        text-node text-node? text-node-content
        new-node new-text-node node-attribute first-text-node
        (struct-out node-kind-info)
        context-define-node-kind! context-define-node-renderer!
        node-kind-ref node-renderer node-text-projection
        ;; buffers and the view
        buffer buffer? buffer-name buffer-root new-buffer
        view view? view-showing view-node new-view
        buffer-list get-buffer context-add-buffer! kill-buffer
        current-view current-buffer switch-to-buffer
        current-text-node current-text
        point point-min point-max goto-char
        insert delete-region
        goal-column set-goal-column!)

;;; Texts

(defclass text ((store            : :t)       ; the TextStore that made VERSION
                (version          : :t)
                (chars-revision   : :fixnum)  ; characters changed
                (content-revision : :fixnum)  ; characters or properties changed
                (journal          : :list)    ; recent changes, newest first
                (journal-length   : :fixnum)
                (undo-list        : :list)    ; changes and #f boundaries, newest first
                (undo-pending     : :list)    ; what a continued undo undoes next
                (last-undo-task   :? :fixnum)); the task that recorded the newest change
  final: #t)

(def journal-limit 1000)

(def (new-text (initial : :string := "")) => text
  (let (store (current-text-store))
    (text store: store version: (TextStore-from-string store initial)
          chars-revision: 0 content-revision: 0 journal: [] journal-length: 0
          undo-list: [] undo-pending: [] last-undo-task: #f)))

;; T's store, after moving T into the current store if it was swapped.
;; Versions are persistent, so the outgoing store's version stays readable.
(def (text-store! (t : text)) => TextStore
  (let (store (current-text-store))
    (unless (eq? store t.store)
      (let* ((old (TextStore t.store))
             (content (TextStore-slice old t.version 1 (fx1+ (TextStore-size old t.version)))))
        (set! t.version (TextStore-from-string store content))
        (set! t.store store)))
    store))

;; T's current version in the current store: a persistent snapshot that
;; later edits leave unchanged.
(def (text-snapshot (t : text)) => :t
  (text-store! t)
  t.version)

(def (text-size (t : text)) => :fixnum
  (TextStore-size (text-store! t) t.version))

(def (check-range (t : text) (start : :fixnum) (end : :fixnum)) => :void
  (unless (fx<= 1 start end (fx1+ (text-size t)))
    (error "Args out of range" start end)))

(def (text-substring (t : text) (start : :fixnum) (end : :fixnum)) => :string
  (check-range t start end)
  (TextStore-slice (text-store! t) t.version start end))

(def (text-string (t : text)) => :string
  (text-substring t 1 (fx1+ (text-size t))))

(def (text-line-count (t : text)) => :fixnum
  (TextStore-line-count (text-store! t) t.version))

;; The line, counting from 1, that contains POSITION.
(def (text-line-at (t : text) (position : :fixnum)) => :fixnum
  (check-range t position position)
  (TextStore-line-at (text-store! t) t.version position))

(def (check-line (t : text) (line : :fixnum)) => :void
  (unless (fx<= 1 line (text-line-count t))
    (error "Line out of range" line)))

(def (text-line-start (t : text) (line : :fixnum)) => :fixnum
  (check-line t line)
  (TextStore-line-start (text-store! t) t.version line))

;; The position at the end of LINE, before its newline.
(def (text-line-end (t : text) (line : :fixnum)) => :fixnum
  (check-line t line)
  (if (fx= line (text-line-count t))
    (fx1+ (text-size t))
    (fx1- (text-line-start t (fx1+ line)))))

;; Characters between the start of POSITION's line and POSITION, from 0 as
;; in Emacs. Counts characters; display width is the browser's business.
(def (text-column (t : text) (position : :fixnum)) => :fixnum
  (fx- position (text-line-start t (text-line-at t position))))

;; The position at COLUMN of LINE, or the line's end if it is shorter.
(def (text-position-at (t : text) (line : :fixnum) (column : :fixnum)) => :fixnum
  (fxmin (fx+ (text-line-start t line) column) (text-line-end t line)))

;; Replace START..END of T with REPLACEMENT, recording the change.
(def (text-replace! (t : text) (start : :fixnum) (end : :fixnum) (replacement : :string)) => :void
  (check-range t start end)
  (unless (and (fx= start end) (string-empty? replacement))
    (let* ((store (text-store! t))
           (removed (TextStore-slice store t.version start end))
           (revision (fx1+ t.chars-revision))
           (c (make-change revision start removed replacement)))
      (set! t.version (TextStore-replace store t.version start end replacement))
      (set! t.chars-revision revision)
      (set! t.content-revision (fx1+ t.content-revision))
      (record-journal! t c)
      (record-undo! t c))))

(def (record-journal! (t : text) (c : change)) => :void
  (if (fx< t.journal-length journal-limit)
    (begin
      (set! t.journal (cons c t.journal))
      (set! t.journal-length (fx1+ t.journal-length)))
    ;; Keep the newest half, so trimming is rare.
    (let (kept (fxquotient journal-limit 2))
      (set! t.journal (cons c (take t.journal kept)))
      (set! t.journal-length (fx1+ kept)))))

;; Each command's changes form one undo group: a change from a different
;; task than the previous one starts a new group.
(def (record-undo! (t : text) (c : change)) => :void
  (let (task (current-task-id))
    (unless (eqv? task t.last-undo-task)
      (undo-boundary! t))
    (set! t.last-undo-task task)
    (set! t.undo-list (cons c t.undo-list))))

;; End the current undo group of T.
(def (undo-boundary! (t : text)) => :void
  (match t.undo-list
    ([#f . _] (void))
    ([] (void))
    (else (set! t.undo-list (cons #f t.undo-list)))))

(def (drop-boundaries (entries : :list)) => :list
  (match entries
    ([#f . rest] (drop-boundaries rest))
    (else entries)))

;; Undo one group of T's changes and return the position where the last
;; undone change was. With CONTINUE?, undo the group before the one the
;; previous undo undid; otherwise the newest group. The undoing is itself
;; recorded, so undoing it again redoes (as in Emacs).
(def (text-undo! (t : text) (continue? : :boolean)) => :fixnum
  (let (pending (drop-boundaries (if continue? t.undo-pending t.undo-list)))
    (when (null? pending)
      (error "No further undo information"))
    (undo-boundary! t)
    (let lp ((rest pending) (position 1))
      (match rest
        ([(? change? c) . more]
         (text-replace! t (change-start c)
                        (fx+ (change-start c) (string-length (change-inserted c)))
                        (change-removed c))
         (lp more (fx+ (change-start c) (string-length (change-removed c)))))
        (else
         (undo-boundary! t)
         (set! t.undo-pending rest)
         position)))))

;; Where POSITION, valid at T's character revision REVISION, is now.
;; Positions inside a deleted range move to its start; insertions at a
;; position stay after it. Changes older than the journal clamp.
(def (relocate-position (t : text) (position : :fixnum) (revision : :fixnum)) => :fixnum
  (let collect ((rest t.journal) (newer []))
    (match rest
      ([c . more]
       (if (fx> (change-revision c) revision)
         (collect more (cons c newer))
         (relocate-through newer position)))
      ([]
       (if (and (pair? newer) (fx> (change-revision (car newer)) (fx1+ revision)))
         (fxmax 1 (fxmin position (fx1+ (text-size t))))
         (relocate-through newer position))))))

(def (relocate-through (changes : :list) (position : :fixnum)) => :fixnum
  (let lp ((rest changes) (position position))
    (match rest
      ([c . more]
       (using (c : change)
         (let ((removed (string-length c.removed))
               (inserted (string-length c.inserted)))
           (lp more
               (cond
                ((fx<= position c.start) position)
                ((fx>= position (fx+ c.start removed)) (fx+ position (fx- inserted removed)))
                (else c.start))))))
      ([] position))))

;;; Nodes

(defclass node ((id         : :fixnum)
                (kind       : :symbol)
                (attributes : :list)       ; alist of symbol -> value
                (children   : :list)))     ; nodes

;; A node whose content is a text that users edit.
(defclass (text-node node) ((content : text))
  final: #t)

(def (new-node (kind       : :symbol)
               attributes: (attributes : :list := [])
               children:   (children   : :list := []))
  => node
  (node id: (next-id!) kind: kind attributes: attributes children: children))

(def (new-text-node (t : text)) => text-node
  (text-node id: (next-id!) kind: 'text attributes: [] children: [] content: t))

(def (node-attribute (n : node) (name : :symbol)) => :t
  (let (pair (assq name n.attributes))
    (and pair (cdr pair))))

;; The first text node of the tree at N, depth first.
(def (first-text-node (n : node)) => (Maybe text-node)
  (if (text-node? n)
    n
    (let lp ((children n.children))
      (match children
        ([child . more] (or (first-text-node child) (lp more)))
        ([] #f)))))

;;; Node kinds

;; A node kind: PROJECT returns a node's text projection (for search, copy,
;; and renderers without a procedure of their own for the kind).
(defstruct node-kind-info ((name    : :symbol)
                           (doc     : :string)
                           (project :? :procedure))
  final: #t)

;;; The buffers service

(defclass buffer ((name           : :string)
                  (root           : node)
                  (point-node     :? text-node)   ; point while not displayed
                  (point-position : :fixnum)
                  (point-revision : :fixnum))
  final: #t)

(defclass view ((showing     : buffer)
                (node        :? text-node)        ; the focused text node
                (position    : :fixnum)           ; point, valid at REVISION
                (revision    : :fixnum)
                (goal-column :? :fixnum))
  final: #t)

(interface Buffers
  ;; Every buffer, oldest first.
  (buffer-list) => :list
  (add-buffer! (b : buffer)) => :void
  (remove-buffer! (b : buffer)) => :void
  ;; The view of the one window.
  (current-view) => :t
  ;; Entry tables of node kinds (by name) and node renderers (by kind and
  ;; render target).
  (node-kinds) => :t
  (node-renderers) => :t)

(def buffers-service
  (new-service 'buffers is-Buffers? tier: 'live
               doc: "Keeps buffers, the view, and node kinds."))

(def (current-buffers) => Buffers
  (let (provider (service-provider buffers-service))
    (unless provider
      (error "No plugin provides buffers"))
    (Buffers provider)))

(def (context-define-node-kind! (ctx : context)
                                (name : :symbol)
                                doc:     (doc     : :string := "")
                                project: (project :? :procedure := #f))
  => :void
  (context-add-entry! ctx (: (Buffers-node-kinds (current-buffers)) entry-table) name
                      (make-node-kind-info name doc project)
                      doc: doc)
  (void))

;; Render nodes of KIND for TARGET (such as 'html) with RENDER, called with
;; the node and its children already rendered.
(def (context-define-node-renderer! (ctx    : context)
                                    (kind   : :symbol)
                                    (target : :symbol)
                                    (render : :procedure))
  => :void
  (context-add-entry! ctx (: (Buffers-node-renderers (current-buffers)) entry-table)
                      [kind target] render)
  (void))

(def (node-kind-ref (kind : :symbol)) => (Maybe node-kind-info)
  (let (best (entry-table-ref (: (Buffers-node-kinds (current-buffers)) entry-table) kind))
    (and best (entry-value best))))

(def (node-renderer (kind : :symbol) (target : :symbol)) => (Maybe :procedure)
  (let (best (entry-table-ref (: (Buffers-node-renderers (current-buffers)) entry-table)
                              [kind target]))
    (and best (entry-value best))))

;; N as plain text: a text node's text, the kind's projection, or the
;; children's projections on separate lines.
(def (node-text-projection (n : node)) => :string
  (cond
   ((text-node? n) (text-string (text-node-content n)))
   ((let (kind (node-kind-ref n.kind))
      (and kind (node-kind-info-project kind)))
    => (lambda ((project : :procedure)) (project n)))
   (else (string-join (map node-text-projection n.children) "\n"))))

(def (new-buffer (name : :string) (root : node)) => buffer
  (let (focus (first-text-node root))
    (buffer name: name root: root point-node: focus point-position: 1
            point-revision: (if focus (text-chars-revision (text-node-content focus)) 0))))

(def (new-view (b : buffer)) => view
  (view showing: b node: b.point-node position: b.point-position
        revision: b.point-revision goal-column: #f))

(def (buffer-list) => :list
  (Buffers-buffer-list (current-buffers)))

(def (get-buffer (name : :string)) => (Maybe buffer)
  (find (lambda ((b : buffer)) (string=? b.name name)) (buffer-list)))

;; Add B for CTX's plugin; it is killed when the plugin is deactivated.
(def (context-add-buffer! (ctx : context) (b : buffer)) => :void
  (when (get-buffer b.name)
    (error "A buffer with this name exists" b.name))
  (Buffers-add-buffer! (current-buffers) b)
  (context-defer! ctx (lambda () (kill-buffer b))))

;; Remove B. If the view shows it, show another buffer first.
(def (kill-buffer (b : buffer)) => :void
  (when (eq? b (view-showing (current-view)))
    (let (other (find (lambda (other) (not (eq? other b))) (buffer-list)))
      (when other (switch-to-buffer other))))
  (Buffers-remove-buffer! (current-buffers) b))

(def (current-view) => view
  (: (Buffers-current-view (current-buffers)) view))

(def (current-buffer) => buffer
  (using (v (current-view) : view)
    v.showing))

(def (switch-to-buffer (b : buffer)) => :void
  (using (v (current-view) : view)
    (unless (eq? b v.showing)
      (using (old v.showing : buffer)
        (set! old.point-node v.node)
        (set! old.point-position v.position)
        (set! old.point-revision v.revision))
      (set! v.showing b)
      (set! v.node b.point-node)
      (set! v.position b.point-position)
      (set! v.revision b.point-revision)
      (set! v.goal-column #f))))

(def (current-text-node) => (Maybe text-node)
  (using (v (current-view) : view)
    v.node))

;; The focused text of the current view.
(def (current-text) => text
  (let (n (current-text-node))
    (unless n
      (error "No text to edit here"))
    (using (n : text-node)
      n.content)))

(def (point) => :fixnum
  (using ((v (current-view) : view)
          (t (current-text) : text))
    (let (revision t.chars-revision)
      (unless (fx= v.revision revision)
        (set! v.position (relocate-position t v.position v.revision))
        (set! v.revision revision))
      v.position)))

(def (point-min) => :fixnum
  1)

(def (point-max) => :fixnum
  (fx1+ (text-size (current-text))))

;; Move point to POSITION, limited to the text.
(def (goto-char (position : :fixnum)) => :void
  (using ((v (current-view) : view)
          (t (current-text) : text))
    (set! v.position (fxmax 1 (fxmin position (fx1+ (text-size t)))))
    (set! v.revision t.chars-revision)))

;; Insert INSERTION at point, leaving point after it.
(def (insert (insertion : :string)) => :void
  (let (start (point))
    (text-replace! (current-text) start start insertion)
    (goto-char (fx+ start (string-length insertion)))))

(def (delete-region (start : :fixnum) (end : :fixnum)) => :void
  (text-replace! (current-text) (fxmin start end) (fxmax start end) ""))

(def (goal-column) => (Maybe :fixnum)
  (using (v (current-view) : view)
    v.goal-column))

(def (set-goal-column! (column :? :fixnum)) => :void
  (set! (view-goal-column (current-view)) column))
