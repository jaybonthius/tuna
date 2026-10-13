;;; The buffers contract (live tier; ADR 6, ADR 13): the vocabulary of
;;; texts, nodes, buffers, and views, and thin dispatchers to the plugin
;;; that provides buffers. Everything a buffers provider decides (how texts
;;; are edited and undone, the change journal, highlights, how positions
;;; relocate, how nodes and buffers are made, kept, and killed) is behind
;;; the `Buffers` interface, so a replacement can change all of it.
;;;
;;; A text holds content: a text-store version, its revisions, a journal of
;;; change records, and undo history. A buffer is a named tree of nodes;
;;; text nodes refer to texts, and any other node kind is defined by a
;;; plugin. Each node has one parent, and a revision number that every
;;; change to it or below it replaces with a new, larger one. A view is one
;;; place in the layout (or a prompt) showing a buffer: the focused text
;;; node, point, and the goal column, so two views of one buffer have their
;;; own points. Editing primitives act on the current view's focused text
;;; node. Positions are 1-based character positions within that node's
;;; text.
;;;
;;; Texts, nodes, and buffers are the provider's objects: the classes here
;;; hold only their identity, and providers extend them. Views belong to
;;; whoever shows them (the layout, a prompt) and are plain data here.
;;;
;;; Replacing the provider hands the buffers over through a neutral
;;; description: each buffer's name, settings, point, and node tree with
;;; node ids, kinds, attributes, and texts (characters and highlights), and
;;; the selected view. Undo history and the change journal stay behind.
prelude: :gerbil/core

(import (only-in :std/list/list append-map)
        :std/interface
        :tuna/kernel
        :tuna/services/text-store
        :tuna/services/settings)
(export (interface-out Buffers)
        buffers-service
        ;; changes and the rule positions follow through them
        (struct-out change) (struct-out span)
        position-after-change span-after-change rebase-spans
        ;; texts
        text text? text-id new-text
        text-chars-revision text-content-revision text-decoration-revision
        text-live? text-changes-since
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
        node node? node-id node-kind node-attributes node-attribute
        node-parent node-revision node-child-count node-children
        set-node-attribute! set-node-children!
        text-node? text-node-content
        new-node new-text-node first-text-node
        (struct-out node-kind-info)
        context-define-node-kind! context-define-node-renderer!
        node-kind-ref node-renderer node-text-projection
        ;; buffers
        buffer buffer? buffer-id buffer-name buffer-root new-buffer rename-buffer!
        buffer-setting set-buffer-setting! buffer-point-node buffer-point set-buffer-point!
        internal-buffer?
        buffer-list get-buffer add-buffer! context-add-buffer! kill-buffer kill-buffer-hook
        other-buffer buffer-texts
        ;; views
        view view? view-id view-showing view-node view-position view-revision
        new-view new-view-at copy-view reset-view!
        view-point set-view-point! set-view-showing!
        current-view selected-view set-selected-view! push-focus-view! remove-focus-view!
        current-buffer switch-to-buffer
        current-text-node current-text
        point point-min point-max goto-char
        insert delete-region
        goal-column set-goal-column!
        ;; handover
        (struct-out buffers-description) (struct-out buffer-description)
        (struct-out node-description) (struct-out text-description)
        (struct-out view-description))

;;; Changes

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

;;; Identities. Providers extend these classes with their own state.

(defclass text ((id : :fixnum)))
(defclass node ((id : :fixnum)))
(defclass buffer ((id : :fixnum)))

;; A text's content at one character revision: plain, immutable data that
;; jobs may read on any thread, because store versions are persistent and
;; store operations are pure.
(defstruct snapshot ((store    : TextStore)
                     (version  : :t)
                     (revision : :fixnum))
  final: #t)

;; A node kind: PROJECT returns a node's text projection (for search, copy,
;; and renderers without a procedure of their own for the kind).
(defstruct node-kind-info ((name    : :symbol)
                           (doc     : :string)
                           (project :? :procedure))
  final: #t)

;;; Views

(defclass view ((id          : :fixnum)
                (showing     : buffer)
                (focus       :? node)             ; the focused text node
                (position    : :fixnum)           ; point, valid at REVISION
                (revision    : :fixnum)           ; of the node's text
                (goal-column :? :fixnum))
  final: #t)

;;; The handover description: plain values that any provider can rebuild
;;; its own buffers from. Two node descriptions that share a text share
;;; one text description (eq?).

(defstruct text-description ((content    : :string)
                             (highlights : :list))   ; (layer-name . spans)
  final: #t)

(defstruct node-description ((id         : :fixnum)
                             (kind       : :symbol)
                             (attributes : :list)
                             (children   : :list)    ; node descriptions
                             (text       :? text-description))
  final: #t)

(defstruct buffer-description ((name       : :string)
                               (root       : node-description)
                               (settings   : :list)  ; (setting . value)
                               (point-node :? :fixnum)
                               (point      : :fixnum))
  final: #t)

;; The selected view OF, to be pointed at the new buffer named BUFFER, its
;; node with id NODE, at POINT.
(defstruct view-description ((of     : view)
                             (buffer : :string)
                             (node   :? :fixnum)
                             (point  : :fixnum))
  final: #t)

(defstruct buffers-description ((buffers  : :list)   ; buffer descriptions, oldest first
                                (selected : view-description))
  final: #t)

;;; The interface. Methods receive the provider's own texts, nodes, and
;;; buffers. Positions are 1-based; child indexes count from 0, and child
;;; ranges are end-exclusive.

(interface Buffers
  ;; Texts
  (make-text (initial : :string)) => :t
  (text-snapshot (t : text)) => :t
  (text-content-revision (t : text)) => :fixnum
  (text-decoration-revision (t : text)) => :fixnum
  (text-live? (t : text)) => :boolean
  ;; Replace START..END of T with REPLACEMENT, recording the change for the
  ;; journal and undo, moving highlights, stamping the text's nodes, and
  ;; running after-change-hook. POINT-BEFORE is where the editing command's
  ;; point was, which undo restores.
  (text-replace! (t : text) (start : :fixnum) (end : :fixnum) (replacement : :string)
                 (point-before :? :fixnum)) => :void
  ;; T's changes after character revision REVISION, oldest first, or #f
  ;; when the journal no longer reaches back that far.
  (text-changes-since (t : text) (revision : :fixnum)) => :t
  ;; Where POSITION, valid at T's character revision REVISION, is now.
  (relocate-position (t : text) (position : :fixnum) (revision : :fixnum)) => :fixnum
  (undo-boundary! (t : text)) => :void
  (undo-amalgamate! (t : text) (limit : :fixnum)) => :void
  ;; Undo one group of T's changes and return where point belongs.
  (text-undo! (t : text) (continue? : :boolean)) => :fixnum
  (text-clear-undo! (t : text)) => :void
  (set-highlights! (t : text) (name : :symbol) (spans : :list)) => :void
  (text-highlights (t : text) (name : :symbol)) => :list
  (text-all-highlights (t : text)) => :list
  ;; Nodes
  (make-node (kind : :symbol) (attributes : :list) (children : :list)) => :t
  (make-text-node (t : text)) => :t
  (node-kind (n : node)) => :symbol
  (node-attributes (n : node)) => :list
  (set-node-attribute! (n : node) (name : :symbol) (value : :t)) => :void
  (node-parent (n : node)) => :t
  (node-revision (n : node)) => :fixnum
  ;; N's text if N is a text node, or #f.
  (node-text (n : node)) => :t
  (node-child-count (n : node)) => :fixnum
  (node-children (n : node) (start : :fixnum) (end : :fixnum)) => :list
  (set-node-children! (n : node) (children : :list)) => :void
  ;; Buffers
  (make-buffer (name : :string) (root : node)) => :t
  ;; Every buffer, oldest first.
  (buffer-list) => :list
  ;; Add B, whose name must be new.
  (add-buffer! (b : buffer)) => :void
  ;; Remove B: run kill-buffer-hook, show another buffer in the selected
  ;; view if it shows B, and let B's texts die.
  (kill-buffer! (b : buffer)) => :void
  (buffer-name (b : buffer)) => :string
  (rename-buffer! (b : buffer) (name : :string)) => :void
  (buffer-root (b : buffer)) => :t
  (buffer-setting (b : buffer) (s : setting)) => :t
  (set-buffer-setting! (b : buffer) (s : setting) (value : :t)) => :void
  ;; B's point while no view shows it: its text node, and its position
  ;; there, relocated through changes since it was set.
  (buffer-point-node (b : buffer)) => :t
  (buffer-point (b : buffer)) => :fixnum
  (set-buffer-point! (b : buffer) (n :? node) (position : :fixnum)) => :void
  ;; Views. The view that receives editing: the innermost focus view (a
  ;; waiting prompt's), or else the selected view.
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
  (node-renderers) => :t
  ;; Handover. DESCRIBE-BUFFERS runs while the incoming provider is already
  ;; current, so it must use only its own state, never these dispatchers.
  (describe-buffers) => :t
  (adopt-buffers! (description : buffers-description)) => :void)

(def buffers-service
  (new-service 'buffers is-Buffers? tier: 'live
               doc: "Keeps buffers, their texts and nodes, the selected view, and node kinds."
               handover: (lambda (outgoing incoming)
                           (Buffers-adopt-buffers!
                            (Buffers incoming)
                            (Buffers-describe-buffers (Buffers outgoing))))))

(def (current-buffers) => Buffers
  (let (provider (service-provider buffers-service))
    (unless provider
      (error "No plugin provides buffers"))
    (Buffers provider)))

;;; Texts

;; Runs on the baton after each change to a text, with the text and the
;; change. Callbacks must be cheap: slow reactions start jobs (ADR 3).
(def after-change-hook
  (new-hook 'after-change doc: "Runs after each change to a text, with the text and the change."))

(def (new-text (initial : :string := "")) => text
  (: (Buffers-make-text (current-buffers) initial) text))

(def (text-snapshot (t : text)) => snapshot
  (: (Buffers-text-snapshot (current-buffers) t) snapshot))

(def (text-chars-revision (t : text)) => :fixnum
  (snapshot-revision (text-snapshot t)))

(def (text-content-revision (t : text)) => :fixnum
  (Buffers-text-content-revision (current-buffers) t))

(def (text-decoration-revision (t : text)) => :fixnum
  (Buffers-text-decoration-revision (current-buffers) t))

;; False once T's buffer is killed.
(def (text-live? (t : text)) => :boolean
  (Buffers-text-live? (current-buffers) t))

(def (text-changes-since (t : text) (revision : :fixnum)) => (Maybe :list)
  (Buffers-text-changes-since (current-buffers) t revision))

(def (snapshot-size (s : snapshot)) => :fixnum
  (TextStore-size (snapshot-store s) (snapshot-version s)))

;; Call PROC with each chunk of S's characters, in order.
(def (snapshot-for-each-chunk (s : snapshot) (proc : :procedure)) => :void
  (TextStore-for-each-chunk (snapshot-store s) (snapshot-version s)
                            1 (fx1+ (snapshot-size s)) proc))

(def (text-size (t : text)) => :fixnum
  (snapshot-size (text-snapshot t)))

(def (check-range (s : snapshot) (start : :fixnum) (end : :fixnum)) => :void
  (unless (fx<= 1 start end (fx1+ (snapshot-size s)))
    (error "Args out of range" start end)))

(def (text-substring (t : text) (start : :fixnum) (end : :fixnum)) => :string
  (let (s (text-snapshot t))
    (check-range s start end)
    (TextStore-slice (snapshot-store s) (snapshot-version s) start end)))

(def (text-string (t : text)) => :string
  (let (s (text-snapshot t))
    (TextStore-slice (snapshot-store s) (snapshot-version s) 1 (fx1+ (snapshot-size s)))))

(def (text-line-count (t : text)) => :fixnum
  (let (s (text-snapshot t))
    (TextStore-line-count (snapshot-store s) (snapshot-version s))))

;; The line, counting from 1, that contains POSITION.
(def (text-line-at (t : text) (position : :fixnum)) => :fixnum
  (let (s (text-snapshot t))
    (check-range s position position)
    (TextStore-line-at (snapshot-store s) (snapshot-version s) position)))

(def (check-line (t : text) (line : :fixnum)) => :void
  (unless (fx<= 1 line (text-line-count t))
    (error "Line out of range" line)))

(def (text-line-start (t : text) (line : :fixnum)) => :fixnum
  (check-line t line)
  (let (s (text-snapshot t))
    (TextStore-line-start (snapshot-store s) (snapshot-version s) line)))

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
  (check-range (text-snapshot t) start end)
  (Buffers-text-replace! (current-buffers) t start end replacement point-before))

;; Each command's changes form one undo group: a change from a different
;; task than the previous one starts a new group. End the current group.
(def (undo-boundary! (t : text)) => :void
  (Buffers-undo-boundary! (current-buffers) t))

;; Let the running command's changes to T join the newest undo group if it
;; holds fewer than LIMIT changes, as Emacs groups consecutive self-inserts.
(def (undo-amalgamate! (t : text) (limit : :fixnum)) => :void
  (Buffers-undo-amalgamate! (current-buffers) t limit))

;; Undo one group of T's changes and return where point belongs: where it
;; was before the group's first change, if known, or else after the text
;; the oldest undone change restored. With CONTINUE?, undo the group
;; before the one the previous undo undid; otherwise the newest group. The
;; undoing is itself recorded, so undoing it again redoes (as in Emacs).
(def (text-undo! (t : text) (continue? : :boolean)) => :fixnum
  (Buffers-text-undo! (current-buffers) t continue?))

;; Forget T's undo history, as after restoring its content from a file.
(def (text-clear-undo! (t : text)) => :void
  (Buffers-text-clear-undo! (current-buffers) t))

;; Where POSITION, valid at T's character revision REVISION, is now
;; (position-after-change). Changes older than the journal clamp.
(def (relocate-position (t : text) (position : :fixnum) (revision : :fixnum)) => :fixnum
  (Buffers-relocate-position (current-buffers) t position revision))

;;; Decorations

;; Replace T's highlight layer NAME with SPANS, whose values are face
;; names. Highlights are decorations: they bump the decoration revision,
;; not the content revision (ADR 4), and move with edits
;; (span-after-change).
(def (set-highlights! (t : text) (name : :symbol) (spans : :list)) => :void
  (Buffers-set-highlights! (current-buffers) t name spans))

;; T's highlight spans in layer NAME.
(def (text-highlights (t : text) (name : :symbol)) => :list
  (Buffers-text-highlights (current-buffers) t name))

;; Every highlight span of T, in no particular order.
(def (text-all-highlights (t : text)) => :list
  (Buffers-text-all-highlights (current-buffers) t))

;;; Nodes

;; A node of KIND with ATTRIBUTES (an alist of symbol -> value) and
;; CHILDREN, which must have no parent yet.
(def (new-node (kind       : :symbol)
               attributes: (attributes : :list := [])
               children:   (children   : :list := []))
  => node
  (: (Buffers-make-node (current-buffers) kind attributes children) node))

;; A node whose content is T, a text that users edit.
(def (new-text-node (t : text)) => node
  (: (Buffers-make-text-node (current-buffers) t) node))

(def (node-kind (n : node)) => :symbol
  (Buffers-node-kind (current-buffers) n))

(def (node-attributes (n : node)) => :list
  (Buffers-node-attributes (current-buffers) n))

(def (node-attribute (n : node) (name : :symbol)) => :t
  (let (pair (assq name (node-attributes n)))
    (and pair (cdr pair))))

(def (set-node-attribute! (n : node) (name : :symbol) (value : :t)) => :void
  (Buffers-set-node-attribute! (current-buffers) n name value))

;; N's parent, or #f for a buffer's root and a node not yet placed.
(def (node-parent (n : node)) => (Maybe node)
  (Buffers-node-parent (current-buffers) n))

;; A number that a change to N or below it replaces with a larger one.
(def (node-revision (n : node)) => :fixnum
  (Buffers-node-revision (current-buffers) n))

(def (node-child-count (n : node)) => :fixnum
  (Buffers-node-child-count (current-buffers) n))

;; N's children from index START (from 0) up to END, exclusive; by default
;; all of them. Renderers that draw only what is in view read a range.
(def (node-children (n : node) (start : :fixnum := 0) (end :? :fixnum := #f)) => :list
  (let* ((bs (current-buffers))
         (count (Buffers-node-child-count bs n))
         (end (or end count)))
    (unless (fx<= 0 start end count)
      (error "Child range out of range" start end))
    (Buffers-node-children bs n start end)))

;; Replace N's children with CHILDREN, which must have no parent but N.
(def (set-node-children! (n : node) (children : :list)) => :void
  (Buffers-set-node-children! (current-buffers) n children))

(def (text-node? (n : :t)) => :boolean
  (and (node? n) (Buffers-node-text (current-buffers) n) #t))

(def (text-node-content (n : node)) => text
  (or (Buffers-node-text (current-buffers) n)
      (error "Not a text node" (node-id n))))

;; The first text node of the tree at N, depth first.
(def (first-text-node (n : node)) => (Maybe node)
  (if (text-node? n)
    n
    (let lp ((children (node-children n)))
      (match children
        ([child . more] (or (first-text-node child) (lp more)))
        ([] #f)))))

;;; Node kinds

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
   ((let (kind (node-kind-ref (node-kind n)))
      (and kind (node-kind-info-project kind)))
    => (lambda ((project : :procedure)) (project n)))
   (else (string-join (map node-text-projection (node-children n)) "\n"))))

;;; Buffers

;; A buffer named NAME holding the tree at ROOT, which must have no parent.
;; It is not in the buffer list until added.
(def (new-buffer (name : :string) (root : node)) => buffer
  (: (Buffers-make-buffer (current-buffers) name root) buffer))

(def (buffer-name (b : buffer)) => :string
  (Buffers-buffer-name (current-buffers) b))

(def (buffer-root (b : buffer)) => node
  (: (Buffers-buffer-root (current-buffers) b) node))

;; Give B a new NAME, which no other buffer may have.
(def (rename-buffer! (b : buffer) (name : :string)) => :void
  (Buffers-rename-buffer! (current-buffers) b name))

;; Buffers whose names start with a space are internal (as in Emacs):
;; prompts' buffers, for example. Commands that pick a buffer skip them.
(def (internal-buffer? (b : buffer)) => :boolean
  (string-prefix? " " (buffer-name b)))

;; The text node B's point is in while no view shows B, or #f.
(def (buffer-point-node (b : buffer)) => (Maybe node)
  (Buffers-buffer-point-node (current-buffers) b))

;; B's point while no view shows it.
(def (buffer-point (b : buffer)) => :fixnum
  (Buffers-buffer-point (current-buffers) b))

(def (set-buffer-point! (b : buffer) (position : :fixnum)) => :void
  (let (bs (current-buffers))
    (Buffers-set-buffer-point! bs b (Buffers-buffer-point-node bs b) position)))

;; B's own value for S, as a (setting . value) pair, or #f.
(def (buffer-setting (b : buffer) (s : setting)) => (Maybe :pair)
  (Buffers-buffer-setting (current-buffers) b s))

(def (set-buffer-setting! (b : buffer) (s : setting) (value : :t)) => :void
  (Buffers-set-buffer-setting! (current-buffers) b s value))

(def (buffer-list) => :list
  (Buffers-buffer-list (current-buffers)))

(def (get-buffer (name : :string)) => (Maybe buffer)
  (let (bs (current-buffers))
    (find (lambda ((b : buffer)) (string=? (Buffers-buffer-name bs b) name))
          (Buffers-buffer-list bs))))

;; Add B, whose name must be new.
(def (add-buffer! (b : buffer)) => :void
  (Buffers-add-buffer! (current-buffers) b))

;; Add B for CTX's plugin; it is killed when the plugin is deactivated.
(def (context-add-buffer! (ctx : context) (b : buffer)) => :void
  (add-buffer! b)
  (context-defer! ctx (lambda () (kill-buffer b))))

;; Runs with a buffer about to be killed, so whatever shows it (views) can
;; show another buffer instead.
(def kill-buffer-hook
  (new-hook 'kill-buffer doc: "Runs with a buffer about to be killed."))

;; The buffer to show instead of B: the oldest other buffer that is not
;; internal, or #f.
(def (other-buffer (b : buffer)) => (Maybe buffer)
  (find (lambda ((other : buffer)) (not (or (eq? other b) (internal-buffer? other))))
        (buffer-list)))

;; Remove B. Views showing it show another buffer instead.
(def (kill-buffer (b : buffer)) => :void
  (Buffers-kill-buffer! (current-buffers) b))

;; The texts of B's text nodes, depth first.
(def (buffer-texts (b : buffer)) => :list
  (let walk ((n (buffer-root b)))
    (if (text-node? n)
      [(text-node-content n)]
      (append-map walk (node-children n)))))

;;; Views

;; A view of B with its point at POSITION in text node N, valid at N's
;; text revision REVISION. For buffers providers, which must not call the
;; dispatchers before they provide the service.
(def (new-view-at (b : buffer) (n :? node) (position : :fixnum) (revision : :fixnum)) => view
  (view id: (next-id!) showing: b focus: n position: position revision: revision goal-column: #f))

;; Point V, keeping its identity, at B with its point at POSITION in N,
;; valid at N's text revision REVISION. For buffers providers adopting the
;; selected view in a handover.
(def (reset-view! (v : view) (b : buffer) (n :? node) (position : :fixnum) (revision : :fixnum))
  => :void
  (set! v.showing b)
  (set! v.focus n)
  (set! v.position position)
  (set! v.revision revision))

;; The character revision of N's text, or 0 without one.
(def (node-chars-revision (n :? node)) => :fixnum
  (if n (text-chars-revision (text-node-content n)) 0))

;; A view of B at B's point.
(def (new-view (b : buffer)) => view
  (let (n (buffer-point-node b))
    (new-view-at b n (buffer-point b) (node-chars-revision n))))

;; A new view of V's buffer at V's point, as when a view is split.
(def (copy-view (v : view)) => view
  (new-view-at v.showing v.focus (view-point v) (node-chars-revision v.focus)))

;; The text node V's point is in, or #f.
(def (view-node (v : view)) => (Maybe node)
  v.focus)

;; V's point, relocated through the changes made since V last looked.
(def (view-point (v : view)) => :fixnum
  (let (n v.focus)
    (when n
      (let* ((t (text-node-content n))
             (revision (text-chars-revision t)))
        (unless (fx= v.revision revision)
          (set! v.position (relocate-position t v.position v.revision))
          (set! v.revision revision))))
    v.position))

;; Move V's point to POSITION, limited to its text.
(def (set-view-point! (v : view) (position : :fixnum)) => :void
  (let (n v.focus)
    (when n
      (let (s (text-snapshot (text-node-content n)))
        (set! v.position (fxmax 1 (fxmin position (fx1+ (snapshot-size s)))))
        (set! v.revision (snapshot-revision s))))))

;; Show B in V. The buffer V showed keeps V's point as its own. Layouts
;; call this; commands call `set-view-buffer`, which asks the layout.
(def (set-view-showing! (v : view) (b : buffer)) => :void
  (unless (eq? b v.showing)
    (let (bs (current-buffers))
      (Buffers-set-buffer-point! bs v.showing v.focus (view-point v))
      (let (n (Buffers-buffer-point-node bs b))
        (set! v.showing b)
        (set! v.focus n)
        (set! v.position (Buffers-buffer-point bs b))
        (set! v.revision (node-chars-revision n))
        (set! v.goal-column #f)))))

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

(def (current-text-node) => (Maybe node)
  (using (v (current-view) : view)
    v.focus))

;; The focused text of the current view.
(def (current-text) => text
  (let (n (current-text-node))
    (unless n
      (error "No text to edit here"))
    (text-node-content n)))

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
