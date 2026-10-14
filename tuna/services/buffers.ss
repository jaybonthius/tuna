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
;;; change to it or below it replaces with a new, larger one. A node may
;;; carry a keymap (Emacs's `keymap` text property): keys typed with focus
;;; in it or below it, and clicks on it or below it, look there first (the
;;; keys contract gives the order). The keymap of a buffer's root node is
;;; the buffer's own (Emacs's local map); there is no separate buffer
;;; keymap. Giving a node another keymap is a change to it; bindings added
;;; to or removed from a keymap are not, the keymap generation tracks them
;;; (keys contract). A view is one
;;; place in the layout showing a buffer: the focused text node, point, and
;;; the goal column, so two views of one buffer have their own points.
;;; Editing primitives act on the selected view's focused text node. Positions are 1-based character positions within that node's
;;; text.
;;;
;;; Texts, nodes, and buffers are the provider's objects: the classes here
;;;; hold only their identity, and providers extend them. Views belong to
;;; the layout and are plain data here.
;;;
;;; Replacing the provider hands the buffers over through a neutral
;;; description: each buffer's name, settings, point, and node tree with
;;; node ids, kinds, attributes, keymaps, and texts (characters and
;;; highlights), and the selected view. Undo history and the change journal
;;; stay behind.
;;;
;;; `buffer-list-update-hook` runs after a buffer is added, killed or
;;; renamed through this contract (Emacs `buffer-list-update-hook`).
prelude: :gerbil/core

(import :std/interface
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
        node-keymap set-node-keymap!
        text-node? text-node-content
        new-node new-text-node first-text-node
        (struct-out node-kind-info)
        context-define-node-kind! context-define-node-renderer!
        node-kind-ref node-renderer node-text-projection
        ;; buffers
        buffer buffer? buffer-id buffer-name buffer-root new-buffer rename-buffer!
        buffer-setting set-buffer-setting! buffer-local-value settings-buffer
        buffer-point-node buffer-point set-buffer-point!
        internal-buffer?
        buffer-list get-buffer add-buffer! context-add-buffer! kill-buffer kill-buffer-hook
        buffer-list-update-hook
        other-buffer buffer-texts
        ;; views
        view view? view-id view-showing view-node view-position view-revision
        new-view new-view-at copy-view reset-view!
        view-point set-view-point! set-view-showing!
        selected-view set-selected-view!
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
                             (text       :? text-description)
                             (keymap     :? entry-table))
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
  ;; N's keymap, or #f.
  (node-keymap (n : node)) => :t
  ;; Give N KEYMAP (#f for none), stamping N and the nodes above it.
  (set-node-keymap! (n : node) (keymap :? entry-table)) => :void
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
  ;; Views. The selected view, which receives editing: the layout's, set
  ;; by the layout.
  (selected-view) => :t
  (set-selected-view! (v : view)) => :void
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

;;; Texts

;; Runs on the baton after each change to a text, with the text and the
;; change. Callbacks must be cheap: slow reactions start jobs (ADR 3).
(def after-change-hook
  (new-hook 'after-change doc: "Runs after each change to a text, with the text and the change."))

(def (new-text (initial : :string := "")) => text
  (:- (with-service-provider (provider buffers-service Buffers) (: (Buffers-make-text provider initial) text)) text))

(def (text-snapshot (t : text)) => snapshot
  (:- (with-service-provider (provider buffers-service Buffers) (: (Buffers-text-snapshot provider t) snapshot)) snapshot))

(def (text-chars-revision (t : text)) => :fixnum
  (snapshot-revision (text-snapshot t)))

(def (text-content-revision (t : text)) => :fixnum
  (:- (with-service-provider (provider buffers-service Buffers) (Buffers-text-content-revision provider t)) :fixnum))

(def (text-decoration-revision (t : text)) => :fixnum
  (:- (with-service-provider (provider buffers-service Buffers) (Buffers-text-decoration-revision provider t)) :fixnum))

;; False once T's buffer is killed.
(def (text-live? (t : text)) => :boolean
  (:- (with-service-provider (provider buffers-service Buffers) (Buffers-text-live? provider t)) :boolean))

(def (text-changes-since (t : text) (revision : :fixnum)) => (Maybe :list)
  (:? (with-service-provider (provider buffers-service Buffers) (Buffers-text-changes-since provider t revision)) :list))

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
  (:- (with-service-provider (provider buffers-service Buffers)
    (check-range (text-snapshot t) start end)
    (Buffers-text-replace! provider t start end replacement point-before)) :void))

;; Each command's changes form one undo group: a change from a different
;; task than the previous one starts a new group. End the current group.
(def (undo-boundary! (t : text)) => :void
  (:- (with-service-provider (provider buffers-service Buffers) (Buffers-undo-boundary! provider t)) :void))

;; Let the running command's changes to T join the newest undo group if it
;; holds fewer than LIMIT changes, as Emacs groups consecutive self-inserts.
(def (undo-amalgamate! (t : text) (limit : :fixnum)) => :void
  (:- (with-service-provider (provider buffers-service Buffers) (Buffers-undo-amalgamate! provider t limit)) :void))

;; Undo one group of T's changes and return where point belongs: where it
;; was before the group's first change, if known, or else after the text
;; the oldest undone change restored. With CONTINUE?, undo the group
;; before the one the previous undo undid; otherwise the newest group. The
;; undoing is itself recorded, so undoing it again redoes (as in Emacs).
(def (text-undo! (t : text) (continue? : :boolean)) => :fixnum
  (:- (with-service-provider (provider buffers-service Buffers) (Buffers-text-undo! provider t continue?)) :fixnum))

;; Forget T's undo history, as after restoring its content from a file.
(def (text-clear-undo! (t : text)) => :void
  (:- (with-service-provider (provider buffers-service Buffers) (Buffers-text-clear-undo! provider t)) :void))

;; Where POSITION, valid at T's character revision REVISION, is now
;; (position-after-change). Changes older than the journal clamp.
(def (relocate-position (t : text) (position : :fixnum) (revision : :fixnum)) => :fixnum
  (:- (with-service-provider (provider buffers-service Buffers) (Buffers-relocate-position provider t position revision)) :fixnum))

;;; Decorations

;; Replace T's highlight layer NAME with SPANS, whose values are face
;; names. Highlights are decorations: they bump the decoration revision,
;; not the content revision (ADR 4), and move with edits
;; (span-after-change).
(def (set-highlights! (t : text) (name : :symbol) (spans : :list)) => :void
  (:- (with-service-provider (provider buffers-service Buffers) (Buffers-set-highlights! provider t name spans)) :void))

;; T's highlight spans in layer NAME.
(def (text-highlights (t : text) (name : :symbol)) => :list
  (:- (with-service-provider (provider buffers-service Buffers) (Buffers-text-highlights provider t name)) :list))

;; Every highlight span of T, in no particular order.
(def (text-all-highlights (t : text)) => :list
  (:- (with-service-provider (provider buffers-service Buffers) (Buffers-text-all-highlights provider t)) :list))

;;; Nodes

;; A node of KIND with ATTRIBUTES (an alist of symbol -> value),
;; CHILDREN, which must have no parent yet, and KEYMAP, if any.
(def (new-node (kind       : :symbol)
               attributes: (attributes : :list := [])
               children:   (children   : :list := [])
               keymap:     (keymap     :? entry-table := #f))
  => node
  (:- (with-service-provider (provider buffers-service Buffers)
    (let* ((bs provider)
           (n (: (Buffers-make-node bs kind attributes children) node)))
      (when keymap
        (Buffers-set-node-keymap! bs n keymap))
      n)) node))

;; A node whose content is T, a text that users edit.
(def (new-text-node (t : text)) => node
  (:- (with-service-provider (provider buffers-service Buffers) (: (Buffers-make-text-node provider t) node)) node))

(def (node-kind (n : node)) => :symbol
  (:- (with-service-provider (provider buffers-service Buffers) (Buffers-node-kind provider n)) :symbol))

(def (node-attributes (n : node)) => :list
  (:- (with-service-provider (provider buffers-service Buffers) (Buffers-node-attributes provider n)) :list))

(def (node-attribute (n : node) (name : :symbol)) => :t
  (let (pair (assq name (node-attributes n)))
    (and pair (cdr pair))))

(def (set-node-attribute! (n : node) (name : :symbol) (value : :t)) => :void
  (:- (with-service-provider (provider buffers-service Buffers) (Buffers-set-node-attribute! provider n name value)) :void))

;; N's keymap, or #f.
(def (node-keymap (n : node)) => (Maybe entry-table)
  (:? (with-service-provider (provider buffers-service Buffers) (Buffers-node-keymap provider n)) entry-table))

;; Give N KEYMAP, or none with #f; a change to N.
(def (set-node-keymap! (n : node) (keymap :? entry-table)) => :void
  (:- (with-service-provider (provider buffers-service Buffers) (Buffers-set-node-keymap! provider n keymap)) :void))

;; N's parent, or #f for a buffer's root and a node not yet placed.
(def (node-parent (n : node)) => (Maybe node)
  (:? (with-service-provider (provider buffers-service Buffers) (Buffers-node-parent provider n)) node))

;; A number that a change to N or below it replaces with a larger one.
(def (node-revision (n : node)) => :fixnum
  (:- (with-service-provider (provider buffers-service Buffers) (Buffers-node-revision provider n)) :fixnum))

(def (node-child-count (n : node)) => :fixnum
  (:- (with-service-provider (provider buffers-service Buffers) (Buffers-node-child-count provider n)) :fixnum))

;; N's children from index START (from 0) up to END, exclusive; by default
;; all of them. Renderers that draw only what is in view read a range.
(def (node-children (n : node) (start : :fixnum := 0) (end :? :fixnum := #f)) => :list
  (:- (with-service-provider (provider buffers-service Buffers)
    (let* ((bs provider)
           (count (Buffers-node-child-count bs n))
           (end (or end count)))
      (unless (fx<= 0 start end count)
        (error "Child range out of range" start end))
      (Buffers-node-children bs n start end))) :list))

;; Replace N's children with CHILDREN, which must have no parent but N.
(def (set-node-children! (n : node) (children : :list)) => :void
  (:- (with-service-provider (provider buffers-service Buffers) (Buffers-set-node-children! provider n children)) :void))

(def (text-node? (n : :t)) => :boolean
  (:- (with-service-provider (provider buffers-service Buffers) (and (node? n) (Buffers-node-text provider n) #t)) :boolean))

(def (text-node-content (n : node)) => text
  (:- (with-service-provider (provider buffers-service Buffers)
    (or (Buffers-node-text provider n)
        (error "Not a text node" (node-id n)))) text))

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
  (:- (with-service-provider (provider buffers-service Buffers)
    (context-add-entry! ctx (: (Buffers-node-kinds provider) entry-table) name
                        (make-node-kind-info name doc (and project (context-bind ctx project)))
                        doc: doc)
    (void)) :void))

;; Render nodes of KIND for TARGET (such as 'html) with RENDER, called with
;; the node and its children already rendered.
(def (context-define-node-renderer! (ctx    : context)
                                    (kind   : :symbol)
                                    (target : :symbol)
                                    (render : :procedure))
  => :void
  (:- (with-service-provider (provider buffers-service Buffers)
    (context-add-entry! ctx (: (Buffers-node-renderers provider) entry-table)
                        [kind target] render)
    (void)) :void))

(def (node-kind-ref (kind : :symbol)) => (Maybe node-kind-info)
  (:? (with-service-provider (provider buffers-service Buffers)
    (let (best (entry-table-ref (: (Buffers-node-kinds provider) entry-table) kind))
      (and best (entry-value best)))) node-kind-info))

(def (node-renderer (kind : :symbol) (target : :symbol)) => (Maybe :procedure)
  (:? (with-service-provider (provider buffers-service Buffers)
    (let (best (entry-table-ref (: (Buffers-node-renderers provider) entry-table)
                                [kind target]))
      (and best (entry-value best)))) :procedure))

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
  (:- (with-service-provider (provider buffers-service Buffers) (: (Buffers-make-buffer provider name root) buffer)) buffer))

(def (buffer-name (b : buffer)) => :string
  (:- (with-service-provider (provider buffers-service Buffers) (Buffers-buffer-name provider b)) :string))

(def (buffer-root (b : buffer)) => node
  (:- (with-service-provider (provider buffers-service Buffers) (: (Buffers-buffer-root provider b) node)) node))

;; Give B a new NAME, which no other buffer may have.
(def (rename-buffer! (b : buffer) (name : :string)) => :void
  (:- (with-service-provider (provider buffers-service Buffers)
    (Buffers-rename-buffer! provider b name)
    (run-hook buffer-list-update-hook)) :void))

;; Buffers whose names start with a space are internal (as in Emacs):
;; prompts' buffers, for example. Commands that pick a buffer skip them.
(def (internal-buffer? (b : buffer)) => :boolean
  (string-prefix? " " (buffer-name b)))

;; The text node B's point is in while no view shows B, or #f.
(def (buffer-point-node (b : buffer)) => (Maybe node)
  (:? (with-service-provider (provider buffers-service Buffers) (Buffers-buffer-point-node provider b)) node))

;; B's point while no view shows it.
(def (buffer-point (b : buffer)) => :fixnum
  (:- (with-service-provider (provider buffers-service Buffers) (Buffers-buffer-point provider b)) :fixnum))

(def (set-buffer-point! (b : buffer) (position : :fixnum)) => :void
  (:- (with-service-provider (provider buffers-service Buffers)
    (let (bs provider)
      (Buffers-set-buffer-point! bs b (Buffers-buffer-point-node bs b) position))) :void))

;; B's own value for S, as a (setting . value) pair, or #f.
(def (buffer-setting (b : buffer) (s : setting)) => (Maybe :pair)
  (:? (with-service-provider (provider buffers-service Buffers) (Buffers-buffer-setting provider b s)) :pair))

(def (set-buffer-setting! (b : buffer) (s : setting) (value : :t)) => :void
  (:- (with-service-provider (provider buffers-service Buffers) (Buffers-set-buffer-setting! provider b s value)) :void))

;; The buffer whose own values the buffer settings scope reads, while
;; buffer-local-value reads another buffer's.
(def reading-buffer (make-parameter #f))

;; The buffer whose own values settings resolve through: the current
;; buffer, or the one buffer-local-value reads. Buffers providers' setting
;; scopes look here.
(def (settings-buffer) => buffer
  (let (b (reading-buffer))
    (if b (: b buffer) (current-buffer))))

;; S's value as seen from B (Emacs `buffer-local-value`): B's own value,
;; or else what S resolves to with B as the settings buffer.
(def (buffer-local-value (s : setting) (b : buffer)) => :t
  (parameterize ((reading-buffer b))
    (setting-value s)))

(def (buffer-list) => :list
  (:- (with-service-provider (provider buffers-service Buffers) (Buffers-buffer-list provider)) :list))

(def (get-buffer (name : :string)) => (Maybe buffer)
  (:? (with-service-provider (provider buffers-service Buffers)
    (let (bs provider)
      (find (lambda ((b : buffer)) (string=? (Buffers-buffer-name bs b) name))
            (Buffers-buffer-list bs)))) buffer))

;; Add B, whose name must be new.
(def (add-buffer! (b : buffer)) => :void
  (:- (with-service-provider (provider buffers-service Buffers)
    (Buffers-add-buffer! provider b)
    (run-hook buffer-list-update-hook)) :void))

;; Add B for CTX's plugin; it is killed when the plugin is deactivated.
(def (context-add-buffer! (ctx : context) (b : buffer)) => :void
  (add-buffer! b)
  (context-defer! ctx (lambda () (kill-buffer b))))

;; Runs with a buffer about to be killed, so whatever shows it (views) can
;; show another buffer instead.
(def kill-buffer-hook
  (new-hook 'kill-buffer doc: "Runs with a buffer about to be killed."))

;; Runs with no arguments after a buffer is added, killed or renamed, so
;; lists of buffers can be drawn again. Callbacks must be cheap.
(def buffer-list-update-hook
  (new-hook 'buffer-list-update doc: "Runs after a buffer is added, killed or renamed."))

;; The buffer to show instead of B: the oldest other buffer that is not
;; internal, or #f.
(def (other-buffer (b : buffer)) => (Maybe buffer)
  (find (lambda ((other : buffer)) (not (or (eq? other b) (internal-buffer? other))))
        (buffer-list)))

;; Remove B. Views showing it show another buffer instead.
(def (kill-buffer (b : buffer)) => :void
  (:- (with-service-provider (provider buffers-service Buffers)
    (Buffers-kill-buffer! provider b)
    (run-hook buffer-list-update-hook)) :void))

;; The texts of B's text nodes, depth first. (Not append-map from
;; :std/list/list, which reverses each sublist: TODO.md.)
(def (buffer-texts (b : buffer)) => :list
  (reverse
   (let walk ((n (buffer-root b)) (out []))
     (if (text-node? n)
       (cons (text-node-content n) out)
       (foldl walk out (node-children n))))))

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
  (:- (with-service-provider (provider buffers-service Buffers)
    (unless (eq? b v.showing)
      (let (bs provider)
        (Buffers-set-buffer-point! bs v.showing v.focus (view-point v))
        (let (n (Buffers-buffer-point-node bs b))
          (set! v.showing b)
          (set! v.focus n)
          (set! v.position (Buffers-buffer-point bs b))
          (set! v.revision (node-chars-revision n))
          (set! v.goal-column #f))))) :void))

(def (selected-view) => view
  (:- (with-service-provider (provider buffers-service Buffers) (: (Buffers-selected-view provider) view)) view))

;; Make V the selected view, which receives editing. The layout calls this
;; when it selects a view.
(def (set-selected-view! (v : view)) => :void
  (:- (with-service-provider (provider buffers-service Buffers) (Buffers-set-selected-view! provider v)) :void))

(def (current-buffer) => buffer
  (using (v (selected-view) : view)
    v.showing))

(def (switch-to-buffer (b : buffer)) => :void
  (set-view-showing! (selected-view) b))

(def (current-text-node) => (Maybe node)
  (using (v (selected-view) : view)
    v.focus))

;; The focused text of the current view.
(def (current-text) => text
  (let (n (current-text-node))
    (unless n
      (error "No text to edit here"))
    (text-node-content n)))

(def (point) => :fixnum
  (current-text)                        ; signals when there is no text here
  (view-point (selected-view)))

(def (point-min) => :fixnum
  1)

(def (point-max) => :fixnum
  (fx1+ (text-size (current-text))))

;; Move point to POSITION, limited to the text.
(def (goto-char (position : :fixnum)) => :void
  (current-text)
  (set-view-point! (selected-view) position))

;; Insert INSERTION at point, leaving point after it.
(def (insert (insertion : :string)) => :void
  (let (start (point))
    (text-replace! (current-text) start start insertion point-before: start)
    (goto-char (fx+ start (string-length insertion)))))

(def (delete-region (start : :fixnum) (end : :fixnum)) => :void
  (text-replace! (current-text) (fxmin start end) (fxmax start end) "" point-before: (point)))

(def (goal-column) => (Maybe :fixnum)
  (using (v (selected-view) : view)
    v.goal-column))

(def (set-goal-column! (column :? :fixnum)) => :void
  (set! (view-goal-column (selected-view)) column))
