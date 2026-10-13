;;; Texts, buffers, views, and nodes (ADR 6), and the buffers service that
;;; holds them.
;;;
;;; A text holds content: a text-store version, revisions, a journal of
;;; change records, and undo history. A buffer is a named tree of nodes; text nodes refer to
;;; texts, and any other node kind is defined by a plugin. A view is one
;;; place in the layout (or a prompt) showing a buffer: the focused text
;;; node, point, and the goal column, so two views of one buffer have their
;;; own points (ADR 13).
;;; Editing primitives act on the current view's focused text node.
;;; Positions are 1-based character positions within that node's text.
prelude: :gerbil/core

(import (only-in :std/list/list append-map)
        :std/interface
        :tuna/kernel
        :tuna/lib/jobs
        :tuna/services/text-store
        :tuna/services/settings)
(export (interface-out Buffers)
        buffers-service
        ;; texts
        (struct-out change) (struct-out span) rebase-spans
        text text? new-text text-id
        text-chars-revision text-content-revision text-decoration-revision
        text-journal text-changes-since text-move-to-store!
        text-size text-substring text-string
        text-line-count text-line-at text-line-start text-line-end
        text-column text-position-at
        text-replace! undo-boundary! undo-amalgamate! text-undo! text-clear-undo!
        relocate-position
        after-change-hook
        ;; snapshots
        (struct-out snapshot) text-snapshot snapshot-size snapshot-for-each-chunk
        ;; decorations
        set-highlights! text-highlights text-all-highlights
        ;; nodes and node kinds
        node node? node-id node-kind node-attributes node-children
        text-node text-node? text-node-content
        new-node new-text-node node-attribute first-text-node
        (struct-out node-kind-info)
        context-define-node-kind! context-define-node-renderer!
        node-kind-ref node-renderer node-text-projection
        ;; buffers and the view
        buffer buffer? buffer-name buffer-root new-buffer rename-buffer!
        buffer-setting set-buffer-setting! buffer-point set-buffer-point! internal-buffer?
        view view? view-id view-showing view-node new-view copy-view
        view-point set-view-point! set-view-showing!
        buffer-list get-buffer add-buffer! context-add-buffer! kill-buffer kill-buffer-hook
        other-buffer buffer-texts
        current-view selected-view set-selected-view! push-focus-view! remove-focus-view!
        current-buffer switch-to-buffer
        current-text-node current-text
        point point-min point-max goto-char
        insert delete-region
        goal-column set-goal-column!)

;;; Texts

;; One edit of a text: at START, REMOVED was replaced by INSERTED, producing
;; character revision REVISION. Positions are 1-based. Texts produce these
;; records; markers, undo, and rebased job results consume them.
(defstruct change ((revision : :fixnum)
                   (start    : :fixnum)
                   (removed  : :string)
                   (inserted : :string))
  final: #t)

;; A range START..END of a text, 1-based and end-exclusive, carrying VALUE
;; (such as a face). Highlights, and job results that rebase, are lists of
;; spans.
(defstruct span ((start : :fixnum)
                 (end   : :fixnum)
                 (value : :t))
  final: #t)

(defclass text ((id               : :fixnum)
                (store            : :t)       ; the TextStore that made VERSION
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
                (live?            : :boolean)) ; false once its buffer is killed
  final: #t)

(def journal-limit 1000)

(def (new-text (initial : :string := "")) => text
  (let (store (current-text-store))
    (text id: (next-id!) store: store version: (TextStore-from-string store initial)
          chars-revision: 0 content-revision: 0 journal: [] journal-length: 0
          undo-list: [] undo-pending: [] last-undo-task: #f
          decorations: [] decoration-revision: 0 live?: #t)))

;; Runs on the baton after each change to a text, with the text and the
;; change. Callbacks must be cheap: slow reactions start jobs (ADR 3).
(def after-change-hook
  (new-hook 'after-change doc: "Runs after each change to a text, with the text and the change."))

;; Jobs over a text depend on its characters. A result that rebases is a
;; list of spans, moved past the text's changes since the job started; it
;; is dropped once the journal no longer reaches back that far.
(implement JobTarget text
  (job-revision (lambda (self) self.chars-revision))
  (job-target-alive? (lambda (self) self.live?))
  (job-rebase (lambda (self result revision)
                (let (changes (text-changes-since self revision))
                  (and changes [(rebase-spans result changes)])))))

;; The store that made T's version. A text keeps using it until it is
;; moved, so a text the buffers plugin has not moved yet still works.
(def (store-of (t : text)) => TextStore
  (TextStore t.store))

;; Move T's content into STORE (when the text-store provider is replaced).
(def (text-move-to-store! (t : text) (store : TextStore)) => :void
  (unless (eq? store t.store)
    (let (old (store-of t))
      (set! t.version (TextStore-from-string
                       store (TextStore-slice old t.version 1 (fx1+ (TextStore-size old t.version)))))
      (set! t.store store))))

;; A text's content at one character revision: plain, immutable data that
;; jobs may read on any thread, because store versions are persistent and
;; store operations are pure.
(defstruct snapshot ((store    : TextStore)
                     (version  : :t)
                     (revision : :fixnum))
  final: #t)

(def (text-snapshot (t : text)) => snapshot
  (make-snapshot (store-of t) t.version t.chars-revision))

(def (snapshot-size (s : snapshot)) => :fixnum
  (TextStore-size (snapshot-store s) (snapshot-version s)))

;; Call PROC with each chunk of S's characters, in order.
(def (snapshot-for-each-chunk (s : snapshot) (proc : :procedure)) => :void
  (TextStore-for-each-chunk (snapshot-store s) (snapshot-version s)
                            1 (fx1+ (snapshot-size s)) proc))

(def (text-size (t : text)) => :fixnum
  (TextStore-size (store-of t) t.version))

(def (check-range (t : text) (start : :fixnum) (end : :fixnum)) => :void
  (unless (fx<= 1 start end (fx1+ (text-size t)))
    (error "Args out of range" start end)))

(def (text-substring (t : text) (start : :fixnum) (end : :fixnum)) => :string
  (check-range t start end)
  (TextStore-slice (store-of t) t.version start end))

(def (text-string (t : text)) => :string
  (text-substring t 1 (fx1+ (text-size t))))

(def (text-line-count (t : text)) => :fixnum
  (TextStore-line-count (store-of t) t.version))

;; The line, counting from 1, that contains POSITION.
(def (text-line-at (t : text) (position : :fixnum)) => :fixnum
  (check-range t position position)
  (TextStore-line-at (store-of t) t.version position))

(def (check-line (t : text) (line : :fixnum)) => :void
  (unless (fx<= 1 line (text-line-count t))
    (error "Line out of range" line)))

(def (text-line-start (t : text) (line : :fixnum)) => :fixnum
  (check-line t line)
  (TextStore-line-start (store-of t) t.version line))

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
;; POINT-BEFORE is where the editing command's point was, which undo
;; restores.
(def (text-replace! (t : text) (start : :fixnum) (end : :fixnum) (replacement : :string)
                    point-before: (point-before :? :fixnum := #f))
  => :void
  (check-range t start end)
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
      (run-hook after-change-hook t c))))

(def (record-journal! (t : text) (c : change)) => :void
  (if (fx< t.journal-length journal-limit)
    (begin
      (set! t.journal (cons c t.journal))
      (set! t.journal-length (fx1+ t.journal-length)))
    ;; Keep the newest half, so trimming is rare.
    (let (kept (fxquotient journal-limit 2))
      (set! t.journal (cons c (take t.journal kept)))
      (set! t.journal-length (fx1+ kept)))))

;; T's changes after character revision REVISION, oldest first, or #f when
;; the journal no longer reaches back that far.
(def (text-changes-since (t : text) (revision : :fixnum)) => (Maybe :list)
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
(def (record-undo! (t : text) (c : change) (point-before :? :fixnum)) => :void
  (let (task (current-task-id))
    (unless (eqv? task t.last-undo-task)
      (undo-boundary! t))
    (set! t.last-undo-task task)
    (set! t.undo-list (cons (cons c point-before) t.undo-list))))

;; Let the running command's changes to T join the newest undo group if it
;; holds fewer than LIMIT changes, as Emacs groups consecutive self-inserts.
(def (undo-amalgamate! (t : text) (limit : :fixnum)) => :void
  (let count ((rest t.undo-list) (n 0))
    (match rest
      ([(? pair?) . more] (count more (fx1+ n)))
      (else
       (when (fx< n limit)
         (set! t.last-undo-task (current-task-id)))))))

;; Forget T's undo history, as after restoring its content from a file.
(def (text-clear-undo! (t : text)) => :void
  (set! t.undo-list [])
  (set! t.undo-pending [])
  (set! t.last-undo-task #f))

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

;; Undo one group of T's changes and return where point belongs: where it
;; was before the group's first change, if known, or else after the text
;; the oldest undone change restored. With CONTINUE?, undo the group
;; before the one the previous undo undid; otherwise the newest group. The
;; undoing is itself recorded, so undoing it again redoes (as in Emacs).
(def (text-undo! (t : text) (continue? : :boolean)) => :fixnum
  (let (pending (drop-boundaries (if continue? t.undo-pending t.undo-list)))
    (when (null? pending)
      (error "No further undo information"))
    (undo-boundary! t)
    (let lp ((rest pending) (position 1))
      (match rest
        ([[c . point-before] . more]
         (using (c : change)
           (text-replace! t c.start (fx+ c.start (string-length c.inserted)) c.removed)
           (lp more (or point-before (fx+ c.start (string-length c.removed))))))
        (else
         (undo-boundary! t)
         (set! t.undo-pending rest)
         position)))))

;;; Decorations

;; Replace T's highlight layer NAME with SPANS, whose values are face
;; names. Highlights are decorations: they bump the decoration revision,
;; not the content revision (ADR 4).
(def (set-highlights! (t : text) (name : :symbol) (spans : :list)) => :void
  (let (size (text-size t))
    (set! t.decorations
      (cons (cons name (filter (lambda ((s : span))
                                 (fx<= 1 (span-start s) (span-end s) (fx1+ size)))
                               spans))
            (remove-layer t.decorations name)))
    (set! t.decoration-revision (fx1+ t.decoration-revision))))

(def (remove-layer (layers : :list) (name : :symbol)) => :list
  (filter (lambda ((layer : :pair)) (not (eq? (car layer) name))) layers))

;; T's highlight spans in layer NAME.
(def (text-highlights (t : text) (name : :symbol)) => :list
  (let (layer (assq name t.decorations))
    (if layer (cdr layer) [])))

;; Every highlight span of T, in no particular order.
(def (text-all-highlights (t : text)) => :list
  (append-map cdr t.decorations))

;; Where POSITION is after change C: the one rule that points, highlights,
;; and rebased spans all follow. A position before C stays; one inside the
;; removed range moves to C's start; one at or after the removed range's
;; end shifts by the change in length. BEFORE-INSERTION? matters only when
;; nothing is removed: a pure insertion exactly at POSITION goes after it,
;; unless BEFORE-INSERTION? (then the position moves past the insertion, as
;; a span's start does). A replacement starting at POSITION moves nothing:
;; POSITION stays at C's start, before the inserted text.
(def (position-after-change (c : change) (position : :fixnum) (before-insertion? : :boolean))
  => :fixnum
  (let* ((removed (string-length c.removed))
         (edit-end (fx+ c.start removed)))
    (cond
     ((fx< position c.start) position)
     ((and (fx= position c.start) (not before-insertion?)) position)
     ((fx>= position edit-end) (fx+ position (fx- (string-length c.inserted) removed)))
     (else c.start))))

;; S after change C, or #f if it is empty afterwards, which includes an
;; already-empty span after any change. A pure insertion at either edge
;; stays outside; one inside joins it; deleting part of it shrinks it. For
;; a replacement, an end of S inside the removed range moves to C's start,
;; so the inserted text lands inside S when the removed range ends after
;; S's start and at or before its end, and outside when it runs past S's
;; end; a replacement that removes all of S empties it.
(def (span-after-change (s : span) (c : change)) => (Maybe span)
  (let ((start (position-after-change c s.start #t))
        (end (position-after-change c s.end #f)))
    (and (fx< start end)
         (if (and (fx= start s.start) (fx= end s.end))
           s
           (make-span start end s.value)))))

;; Move highlights with an edit (span-after-change).
(def (relocate-decorations! (t : text) (c : change)) => :void
  (unless (null? t.decorations)
    (set! t.decorations
      (map (lambda ((layer : :pair))
             (cons (car layer)
                   (filter-map (cut span-after-change <> c) (cdr layer))))
           t.decorations))))

;; SPANS moved through CHANGES (oldest first), as highlights move with
;; edits (span-after-change); a span is dropped once it is empty.
(def (rebase-spans (spans : :list) (changes : :list)) => :list
  (filter-map
   (lambda ((s : span))
     (let lp ((rest changes) (s s))
       (match rest
         ([] s)
         ([c . more]
          (let (moved (span-after-change s c))
            (and moved (lp more moved)))))))
   spans))

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
      ([c . more] (lp more (position-after-change c position #f)))
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
                  (point-revision : :fixnum)
                  (settings       : :list))       ; buffer-local (setting . value) pairs
  final: #t)

(defclass view ((id          : :fixnum)
                (showing     : buffer)
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
  ;; The view that receives editing: the innermost focus view (a waiting
  ;; prompt's), or else the selected view.
  (current-view) => :t
  ;; The selected view: the layout's, set by the layout.
  (selected-view) => :t
  (set-selected-view! (v : view)) => :void
  ;; Give V the focus over the selected view until it is removed.
  (push-focus-view! (v : view)) => :void
  (remove-focus-view! (v : view)) => :void
  ;; Entry tables of node kinds (by name) and node renderers (by kind and
  ;; render target).
  (node-kinds) => :t
  (node-renderers) => :t)

(def buffers-service
  (new-service 'buffers is-Buffers? tier: 'live
               doc: "Keeps buffers, their views, and node kinds."))

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
            point-revision: (if focus (text-chars-revision (text-node-content focus)) 0)
            settings: [])))

;; Give B a new NAME, which no other buffer may have.
(def (rename-buffer! (b : buffer) (name : :string)) => :void
  (let (other (get-buffer name))
    (when (and other (not (eq? other b)))
      (error "A buffer with this name exists" name))
    (set! b.name name)))

;; Buffers whose names start with a space are internal (as in Emacs):
;; prompts' buffers, for example. Commands that pick a buffer skip them.
(def (internal-buffer? (b : buffer)) => :boolean
  (string-prefix? " " b.name))

;; B's point while no view shows it.
(def (buffer-point (b : buffer)) => :fixnum
  (let (n b.point-node)
    (if n
      (let (t (text-node-content n))
        (relocate-position t b.point-position b.point-revision))
      b.point-position)))

(def (set-buffer-point! (b : buffer) (position : :fixnum)) => :void
  (let (n b.point-node)
    (when n
      (let (t (text-node-content n))
        (set! b.point-position (fxmax 1 (fxmin position (fx1+ (text-size t)))))
        (set! b.point-revision (text-chars-revision t))))))

;; B's own value for S, as a (setting . value) pair, or #f.
(def (buffer-setting (b : buffer) (s : setting)) => (Maybe :pair)
  (assq s b.settings))

(def (set-buffer-setting! (b : buffer) (s : setting) (value : :t)) => :void
  (set! b.settings (cons (cons s value)
                         (filter (lambda ((pair : :pair)) (not (eq? (car pair) s))) b.settings))))

(def (new-view (b : buffer)) => view
  (view id: (next-id!) showing: b node: b.point-node position: b.point-position
        revision: b.point-revision goal-column: #f))

;; A new view of V's buffer at V's point, as when a view is split.
(def (copy-view (v : view)) => view
  (view id: (next-id!) showing: v.showing node: v.node position: (view-point v)
        revision: (if v.node (text-chars-revision (text-node-content v.node)) 0)
        goal-column: #f))

;; V's point, relocated through the changes made since V last looked.
(def (view-point (v : view)) => :fixnum
  (let (n v.node)
    (when n
      (let* ((t (text-node-content n))
             (revision (text-chars-revision t)))
        (unless (fx= v.revision revision)
          (set! v.position (relocate-position t v.position v.revision))
          (set! v.revision revision))))
    v.position))

;; Move V's point to POSITION, limited to its text.
(def (set-view-point! (v : view) (position : :fixnum)) => :void
  (let (n v.node)
    (when n
      (let (t (text-node-content n))
        (set! v.position (fxmax 1 (fxmin position (fx1+ (text-size t)))))
        (set! v.revision (text-chars-revision t))))))

(def (buffer-list) => :list
  (Buffers-buffer-list (current-buffers)))

(def (get-buffer (name : :string)) => (Maybe buffer)
  (find (lambda ((b : buffer)) (string=? b.name name)) (buffer-list)))

;; Add B, whose name must be new.
(def (add-buffer! (b : buffer)) => :void
  (when (get-buffer b.name)
    (error "A buffer with this name exists" b.name))
  (Buffers-add-buffer! (current-buffers) b))

;; Add B for CTX's plugin; it is killed when the plugin is deactivated.
(def (context-add-buffer! (ctx : context) (b : buffer)) => :void
  (add-buffer! b)
  (context-defer! ctx (lambda () (kill-buffer b))))

;; Runs with a buffer about to be killed, so whatever shows it (views)
;; can show another buffer instead.
(def kill-buffer-hook
  (new-hook 'kill-buffer doc: "Runs with a buffer about to be killed."))

;; The buffer to show instead of B: the oldest other buffer that is not
;; internal, or #f.
(def (other-buffer (b : buffer)) => (Maybe buffer)
  (find (lambda ((other : buffer)) (not (or (eq? other b) (internal-buffer? other))))
        (buffer-list)))

;; Remove B. Views showing it show another buffer instead.
(def (kill-buffer (b : buffer)) => :void
  (run-hook kill-buffer-hook b)
  (let (selected (selected-view))
    (when (eq? b (view-showing selected))
      (let (other (other-buffer b))
        (when other (set-view-showing! selected other)))))
  (Buffers-remove-buffer! (current-buffers) b)
  (for-each (lambda ((t : text)) (set! t.live? #f)) (buffer-texts b)))

;; The texts of B's text nodes, depth first.
(def (buffer-texts (b : buffer)) => :list
  (let walk ((n (buffer-root b)))
    (if (text-node? n)
      [(text-node-content n)]
      (append-map walk (node-children n)))))

(def (current-view) => view
  (: (Buffers-current-view (current-buffers)) view))

(def (selected-view) => view
  (: (Buffers-selected-view (current-buffers)) view))

;; Make V the selected view, which receives editing while no focus view is
;; pushed. The layout calls this when it selects a view.
(def (set-selected-view! (v : view)) => :void
  (Buffers-set-selected-view! (current-buffers) v))

;; Make V receive editing until it is removed; prompts push their views.
(def (push-focus-view! (v : view)) => :void
  (Buffers-push-focus-view! (current-buffers) v))

(def (remove-focus-view! (v : view)) => :void
  (Buffers-remove-focus-view! (current-buffers) v))

(def (current-buffer) => buffer
  (using (v (current-view) : view)
    v.showing))

(def (switch-to-buffer (b : buffer)) => :void
  (set-view-showing! (current-view) b))

;; Show B in V. The buffer V showed keeps V's point as its own. Layouts
;; call this; commands call `set-view-buffer`, which asks the layout.
(def (set-view-showing! (v : view) (b : buffer)) => :void
  (unless (eq? b v.showing)
    (using (old v.showing : buffer)
      (set! old.point-node v.node)
      (set! old.point-position (view-point v))
      (set! old.point-revision v.revision))
    (set! v.showing b)
    (set! v.node b.point-node)
    (set! v.position b.point-position)
    (set! v.revision b.point-revision)
    (set! v.goal-column #f)))

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
  (current-text)                        ; signals when there is no text here
  (view-point (current-view)))

(def (point-min) => :fixnum
  1)

(def (point-max) => :fixnum
  (fx1+ (text-size (current-text))))

;; Move point to POSITION, limited to the text.
(def (goto-char (position : :fixnum)) => :void
  (current-text)
  (set-view-point! (current-view) position))

;; Insert INSERTION at point, leaving point after it.
(def (insert (insertion : :string)) => :void
  (let (start (point))
    (text-replace! (current-text) start start insertion point-before: start)
    (goto-char (fx+ start (string-length insertion)))))

(def (delete-region (start : :fixnum) (end : :fixnum)) => :void
  (text-replace! (current-text) (fxmin start end) (fxmax start end) "" point-before: (point)))

(def (goal-column) => (Maybe :fixnum)
  (using (v (current-view) : view)
    v.goal-column))

(def (set-goal-column! (column :? :fixnum)) => :void
  (set! (view-goal-column (current-view)) column))
