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
;;;
;;; A view is a scroller: it lays out the items of the node it draws from
;;; one after another (see Items below), and the browser scrolls it. Its
;;; scroll state (Emacs's window-start plus vscroll) is the item at its top
;;; edge and how many pixels of that item are above the edge, as the
;;; browser measured: never a size or position the server worked out. The
;;; item moves with edits as point does. Beside it are what the browser
;;; last measured of the view (`scroll-facts`), and the view's placement:
;;; the server asking the browser, once, to put an item at the top, centre
;;; or bottom of the view. Each placement has a larger number than the
;;; last, and reports measured before the newest placement are stale.
;;; Editing primitives act on the selected view's focused text node. Positions are 1-based character positions within that node's
;;; text.
;;;
;;; Texts, nodes, and buffers are the provider's objects: the classes here
;;;; hold only their identity, and providers extend them. Views belong to
;;; the layout and are plain data here.
;;;

;;; Replacing the provider restores plain-text buffers from autosave's
;;; `buffers` session slot, version 1:
;;; ((BUFFER-NAME POINT AUTOSAVE-FILE ROOT-NODE-ID) ...).
;;; Text lives in AUTOSAVE-FILE. Objects, undo history, change journals,
;;; highlights, local keymaps and rich node trees are not transferred.
;;;
;;; `buffer-list-update-hook` runs after a buffer is added, killed or
;;; renamed through this contract (Emacs `buffer-list-update-hook`).
prelude: :gerbil/core

(import (only-in :gerbil/runtime/hash HashTable)
        :std/interface
        :tuna/kernel
        :tuna/plugins/text-store/contract
        :tuna/plugins/settings/contract)
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
        ;; items
        item item? item-node node-opening item-line item=?
        node-item node-item-count node-item-at node-item-index node-child-items
        item-token token-item node-line-item
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
        view-point set-view-point! set-view-showing! view-point-item
        view-scroll-item view-scroll-offset set-view-scroll!
        (struct-out placement) view-placement place-view!
        (struct-out scroll-facts) view-facts set-view-facts! view-last-visible-item
        view-drawn-before view-drawn-after set-view-drawn-items! initial-drawn-items
        drawn-above drawn-below
        selected-view set-selected-view!
        current-buffer switch-to-buffer
        current-text-node current-text
        point point-min point-max goto-char
        insert delete-region
        goal-column set-goal-column!
)

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

;; An item (see Items): NODE when it is one item; or the line of text
;; node NODE holding POSITION, valid at its text's character revision
;; REVISION.
(defstruct item ((of       : node)    ; `item-node`
                 (position :? :fixnum)
                 (revision : :fixnum))
  final: #t)

(def (item-node (it : item)) => node
  (item-of it))

;; A text's content at one character revision: plain, immutable data that
;; jobs may read on any thread, because store versions are persistent and
;; store operations are pure.
(defstruct snapshot ((store    : TextStore)
                     (version  : :t)
                     (revision : :fixnum))
  final: #t)

;; A node kind: PROJECT returns a node's text projection (for search, copy,
;; and renderers without a procedure of their own for the kind); ITEMS
;; says how its nodes open into items (see Items): 'children or 'whole,
;; or #f to open a node with children into theirs and make one without
;; children one item.
(defstruct node-kind-info ((name    : :symbol)
                           (doc     : :string)
                           (project :? :procedure)
                           (items   :? :symbol))
  final: #t)

;;; Views

;; A placement: the server asking the browser, once, to put item TARGET
;; (#f: the first item the view draws) at the view's top, centre or
;; bottom (ALIGN 'top, 'center or 'bottom); with 'top, OFFSET px of it
;; above the top edge. NUMBER is larger than every earlier placement's in
;; the view. Once the browser confirms it, the placement names where the
;; view is (`set-view-scroll!`), so a page loaded later puts the view
;; there again.
(defstruct placement ((number : :fixnum)
                      (target :? item)
                      (align  : :symbol)
                      (offset : :flonum))
  final: #t)

;; What the browser last measured of a view: under which placement (its
;; number), drawing which node's items (ROOT), the last item wholly in
;; view, how many items there are from the item at the top to it, and the
;; view's width and height in px. Facts measured under an older placement
;; than the view's newest describe where the view was before it.
(defstruct scroll-facts ((placement     : :fixnum)
                         (root          : node)
                         (last-visible  :? item)
                         (visible-count : :fixnum)
                         (width         : :fixnum)
                         (height        : :fixnum))
  final: #t)

;; DRAWN-BEFORE and DRAWN-AFTER are how many items the renderer draws
;; before and after the scroll item. They are derived state, never saved
;; with the session: only a fetching step, which the scrolling plugin
;; works out from what the browser last measured (its `view-scrolled`
;; writes them; a placement or a new buffer starts them again), and which
;; the next report corrects. They live on the view, beside the scroll
;; state they count from, so the renderer can read them without a service
;; of their own (primary agent, 2026-10-17).
(defclass view ((id            : :fixnum)
                (showing       : buffer)
                (focus         :? node)         ; the focused text node
                (position      : :fixnum)       ; point, valid at REVISION
                (revision      : :fixnum)       ; of the node's text
                (goal-column   :? :fixnum)
                (top-item      :? item)         ; the item at the top edge; #f: the first
                (scroll-offset : :flonum)       ; px of it above the edge
                (last-placement : placement)    ; the newest
                (facts         :? scroll-facts)
                (drawn-before  : :fixnum)
                (drawn-after   : :fixnum))
  final: #t)

;; How many items a view draws on each side of its scroll item before the
;; browser has measured anything.
(def initial-drawn-items 200)

;; How much a view keeps drawn beyond what is in view, in pixels as the
;; browser measures them: it asks for more when less than half of this is
;; left, and for less when more than twice this is drawn. More costs
;; drawing time and page size, and spares a fast scroll from running past
;; what is drawn before the next screen arrives. The scrolling plugin turns
;; these into how many items to draw (drawn-before and drawn-after).
(defsetting drawn-above 20000 "Pixels a view keeps drawn above its top edge.")
(defsetting drawn-below 20000 "Pixels a view keeps drawn below its bottom edge.")

;; Neutral saved buffers (the autosave slot `buffers`, version 1):
;; (NAME POINT AUTOSAVE-FILE ROOT-NODE-ID), oldest first. Only ordinary
;; single-text-root buffers survive; owning plugins rebuild rich trees.
;; A layout resolves a saved node id in the rebuilt buffer or uses its root.

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
  ;; Entry tables of node kinds (by name) and node renderers (by kind).
  (node-kinds) => :t
  (node-renderers) => :t
)

(def buffers-service
  (new-service 'buffers is-Buffers? tier: 'live
               doc: "Keeps buffers, their texts and nodes, the selected view, and node kinds."))

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
                                project: (project :? :procedure := #f)
                                items:   (items   :? :symbol := #f))
  => :void
  (unless (memq items '(#f children whole))
    (error "A kind's nodes open into their children's items or are one item, not" items))
  (:- (with-service-provider (provider buffers-service Buffers)
    (context-add-entry! ctx (: (Buffers-node-kinds provider) entry-table) name
                        (make-node-kind-info name doc project items)
                        doc: doc)
    (void)) :void))

;; Render nodes of KIND to HTML with RENDER, called with the node and its
;; children already rendered, and returning SXML (ADR 7).
(def (context-define-node-renderer! (ctx    : context)
                                    (kind   : :symbol)
                                    (render : :procedure))
  => :void
  (:- (with-service-provider (provider buffers-service Buffers)
    (context-add-entry! ctx (: (Buffers-node-renderers provider) entry-table)
                        kind render)
    (void)) :void))

(def (node-kind-ref (kind : :symbol)) => (Maybe node-kind-info)
  (:? (with-service-provider (provider buffers-service Buffers)
    (let (best (entry-table-ref (: (Buffers-node-kinds provider) entry-table) kind))
      (and best (entry-value best)))) node-kind-info))

(def (node-renderer (kind : :symbol)) => (Maybe :procedure)
  (:? (with-service-provider (provider buffers-service Buffers)
    (let (best (entry-table-ref (: (Buffers-node-renderers provider) entry-table) kind))
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

;;; Items
;;;
;;; A scroller lays out items one after another. How a node opens into
;;; items depends on it: a text node's items are its lines; a node whose
;;; kind says 'children, or whose kind does not say and which has children,
;;; opens into its children's items, in order; any other node is one item.
;;; Items count from 0 within the node they are counted in. An item keeps
;;; its identity through edits around it: a node that is one item is
;;; itself, and a line is a text position on it that relocates as point
;;; does.
;;;
;;; An item's token names it in HTML and in what the browser reports: "N"
;;; for node N, "N.P.R" for the line holding position P of text node N's
;;; text at character revision R, so a report about a screen drawn before
;;; an edit still finds its line.
;;;
;;; Counting a node's children's items is kept per node and revision (a
;;; change to a node or below it gives it a new revision), so counting
;;; them again, or finding an item by index, does not walk every child. A
;;; kept count holds no node, so a tree it counted can still be collected.
;;; On the baton only.

;; How a node opening into its children did at REVISION: the index of each
;; child's first item, then the item count (STARTS), and each child's
;; place among its siblings by node id (PLACES).
(defstruct children-items ((revision : :fixnum)
                           (starts   : :vector)
                           (places   : HashTable))
  final: #t)

(def children-items-kept (make-hash-table test: eq? weak-keys: #t))

;; How N opens into items: 'lines, 'children or 'whole.
(def (node-opening (n : node)) => :symbol
  (if (text-node? n)
    'lines
    (let* ((kind (node-kind-ref (node-kind n)))
           (items (and kind (node-kind-info-items kind))))
      (cond
       (items items)
       ((fx> (node-child-count n) 0) 'children)
       (else 'whole)))))

(def (children-items-of (n : node)) => children-items
  (let ((revision (node-revision n))
        (kept (hash-get children-items-kept n)))
    (if (and kept (fx= (children-items-revision kept) revision))
      kept
      (let* ((children (node-children n))
             (starts (make-vector (fx1+ (length children)) 0))
             (places (make-hash-table-eqv)))
        (let lp ((rest children) (place 0) (start 0))
          (vector-set! starts place start)
          (match rest
            ([child . more]
             (hash-put! places (node-id child) place)
             (lp more (fx1+ place) (fx+ start (node-item-count child))))
            ([] (void))))
        (let (counted (make-children-items revision starts places))
          (hash-put! children-items-kept n counted)
          counted)))))

;; How many items N opens into.
(def (node-item-count (n : node)) => :fixnum
  (case (node-opening n)
    ((lines) (text-line-count (text-node-content n)))
    ((children) (let (starts (children-items-starts (children-items-of n)))
                  (vector-ref starts (fx1- (vector-length starts)))))
    (else 1)))

;; N as one item.
(def (node-item (n : node)) => item
  (make-item n #f 0))

;; The item at INDEX among N's items.
(def (node-item-at (n : node) (index : :fixnum)) => item
  (unless (fx< -1 index (node-item-count n))
    (error "Item index out of range" index))
  (case (node-opening n)
    ((lines)
     (let (t (text-node-content n))
       (make-item n (text-line-start t (fx1+ index)) (text-chars-revision t))))
    ((children)
     (let* ((starts (children-items-starts (children-items-of n)))
            (place (child-place starts index)))
       (node-item-at (car (node-children n place (fx1+ place)))
                     (fx- index (vector-ref starts place)))))
    (else (node-item n))))

;; The place of the child whose items hold INDEX, by STARTS: the last
;; child starting at or before INDEX, which skips children with no items.
(def (child-place (starts : :vector) (index : :fixnum)) => :fixnum
  (let lp ((low 0) (high (fx- (vector-length starts) 2)))
    (if (fx>= low high)
      low
      (let (middle (fxquotient (fx+ low high 1) 2))
        (if (fx<= (vector-ref starts middle) index)
          (lp middle high)
          (lp low (fx1- middle)))))))

;; The children of N whose items overlap N's items FIRST to LAST, with
;; the index among N's items of each one's first item: ((CHILD . START)
;; ...), in order. For drawing a run of N's items inside N.
(def (node-child-items (n : node) (first : :fixnum) (last : :fixnum)) => :list
  (let* ((starts (children-items-starts (children-items-of n)))
         (from (child-place starts (fxmax first 0)))
         (to (child-place starts (fxmax first last))))
    (if (fx> first last)
      []
      (let lp ((children (node-children n from (fx1+ to))) (place from) (out []))
        (match children
          ([child . more]
           (let (start (vector-ref starts place))
             (lp more (fx1+ place)
                 (if (fx< start (vector-ref starts (fx1+ place)))
                   (cons (cons child start) out)
                   out))))
          ([] (reverse out)))))))

;; The line IT stands for now, or #f when IT is a node.
(def (item-line (it : item)) => (Maybe :fixnum)
  (let (position (item-position it))
    (and position
         (let (t (text-node-content (item-node it)))
           (text-line-at t (relocated-position t position (item-revision it)))))))

;; POSITION, valid at T's character revision REVISION, where it is now,
;; within T. Positions from a revision T never had (a forged token) stay
;; in range.
(def (relocated-position (t : text) (position : :fixnum) (revision : :fixnum)) => :fixnum
  (fxmax 1 (fxmin (relocate-position t position revision) (fx1+ (text-size t)))))

;; Whether A and B are the same item now.
(def (item=? (a : item) (b : item)) => :boolean
  (and (eq? (item-node a) (item-node b))
       (eqv? (item-line a) (item-line b))))

;; Where IT is among ROOT's items, or #f when it is not one of them: its
;; node is not under ROOT, or a node on the way opens no further.
(def (node-item-index (root : node) (it : item)) => (Maybe :fixnum)
  (let* ((n (item-node it))
         (line (item-line it))
         (opening (node-opening n)))
    (and (if line (eq? opening 'lines) (eq? opening 'whole))
         (let up ((n n) (index (if line (fx1- line) 0)))
           (if (eq? n root)
             index
             (let (parent (node-parent n))
               (and parent
                    (eq? (node-opening parent) 'children)
                    (let* ((counted (children-items-of parent))
                           (place (hash-get (children-items-places counted) (node-id n))))
                      (and place
                           (up parent (fx+ index (vector-ref (children-items-starts counted) place))))))))))))

;; The line of text node N holding POSITION, as an item: named by where
;; the line starts, as every line item is (item-token).
(def (node-line-item (n : node) (position : :fixnum)) => item
  (let (t (text-node-content n))
    (make-item n (text-line-start t (text-line-at t (fxmax 1 (fxmin position (fx1+ (text-size t))))))
               (text-chars-revision t))))

;; IT's token (see Items).
(def (item-token (it : item)) => :string
  (let ((id (number->string (node-id (item-node it))))
        (position (item-position it)))
    (if position
      (let* ((t (text-node-content (item-node it)))
             (revision (text-chars-revision t))
             ;; A line item's position is its line's start at its revision.
             (start (if (fx= revision (item-revision it))
                      position
                      (text-line-start t (text-line-at t (relocated-position t position (item-revision it)))))))
        (string-append id "." (number->string start) "." (number->string revision)))
      id)))

;; The item of ROOT's items that TOKEN names, or #f.
(def (token-item (root : node) (token : :string)) => (Maybe item)
  (let (numbers (map (lambda ((part : :string))
                       (and (fx< 0 (string-length part) 16)
                            (andmap char-numeric? (string->list part))
                            (string->number part)))
                     (string-split token #\.)))
    (match numbers
      ([(? fixnum? id)]
       (let (n (node-under root id))
         (and n
              (let (it (node-item n))
                (and (node-item-index root it) it)))))
      ([(? fixnum? id) (? fixnum? position) (? fixnum? revision)]
       (let (n (node-under root id))
         (and n (eq? (node-opening n) 'lines)
              (let (it (make-item n position revision))
                (and (node-item-index root it) it)))))
      (else #f))))

;; The node with id ID in the tree at ROOT, or #f.
(def (node-under (root : node) (id : :fixnum)) => (Maybe node)
  (cond
   ((fx= (node-id root) id) root)
   ((eq? (node-opening root) 'children)
    (let (place (hash-get (children-items-places (children-items-of root)) id))
      (if place
        (car (node-children root place (fx1+ place)))
        (ormap (cut node-under <> id) (node-children root)))))
   (else
    (ormap (cut node-under <> id) (node-children root)))))

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
;; text revision REVISION, scrolled to the top. For buffers providers,
;; which must not call the dispatchers before they provide the service.
(def (new-view-at (b : buffer) (n :? node) (position : :fixnum) (revision : :fixnum)) => view
  (view id: (next-id!) showing: b focus: n position: position revision: revision goal-column: #f
        top-item: #f scroll-offset: 0. last-placement: (make-placement 0 #f 'top 0.)
        facts: #f drawn-before: initial-drawn-items drawn-after: initial-drawn-items))

;; Point V, keeping its identity, at B with its point at POSITION in N,
;; valid at N's text revision REVISION, scrolled to the top. For buffers
;; providers adopting the selected view when rebuilding state.
(def (reset-view! (v : view) (b : buffer) (n :? node) (position : :fixnum) (revision : :fixnum))
  => :void
  (set! v.showing b)
  (set! v.focus n)
  (set! v.position position)
  (set! v.revision revision)
  (set! v.facts #f)
  (set-view-drawn-items! v initial-drawn-items initial-drawn-items)
  (place-view! v #f 'top))

;; Forget what the browser measured of what V showed before, and place
;; V's point's item, among the items of the root of the buffer V shows, at
;; its centre (Emacs recomputes a window's start so that point shows),
;; which the browser's scroll range turns into the top or the bottom near
;; either end; or, without a point, V's first item at its top.
(def (show-point! (v : view)) => :void
  (set! v.facts #f)
  (set-view-drawn-items! v initial-drawn-items initial-drawn-items)
  (let (it (view-point-item v (buffer-root v.showing)))
    (if it
      (place-view! v it 'center)
      (place-view! v #f 'top))))

;; The character revision of N's text, or 0 without one.
(def (node-chars-revision (n :? node)) => :fixnum
  (if n (text-chars-revision (text-node-content n)) 0))

;; A view of B at B's point, which it shows (show-point!).
(def (new-view (b : buffer)) => view
  (let* ((n (buffer-point-node b))
         (v (new-view-at b n (buffer-point b) (node-chars-revision n))))
    (show-point! v)
    v))

;; A new view of V's buffer at V's point, placed where V's newest placement
;; puts V, and drawing as much: when a view is split, both halves start
;; where it was (Emacs keeps the window start).
(def (copy-view (v : view)) => view
  (let ((new (new-view-at v.showing v.focus (view-point v) (node-chars-revision v.focus)))
        (p v.last-placement))
    (place-view! new (placement-target p) (placement-align p) offset: (placement-offset p))
    (set-view-drawn-items! new v.drawn-before v.drawn-after)
    new))

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
          (set! v.goal-column #f)
          (show-point! v))))) :void))

;; The item among ROOT's items that holds V's point: the line of V's
;; focused text node holding it, or the node above that line that is one
;; of ROOT's items. #f when V has no point or its text is not under ROOT.
(def (view-point-item (v : view) (root : node)) => (Maybe item)
  (let (n v.focus)
    (and n
         (let up ((m n) (it (node-line-item n (view-point v))))
           (if (eq? m root)
             it
             (let (parent (node-parent m))
               (and parent
                    (up parent (if (eq? (node-opening parent) 'children) it (node-item parent))))))))))

;; IT as it is now: a line item moved to the start of the line its
;; position relocated into, valid at its text's current revision.
(def (current-item (it : item)) => item
  (let (position (item-position it))
    (if position
      (let* ((n (item-node it))
             (t (text-node-content n))
             (revision (text-chars-revision t)))
        (if (fx= revision (item-revision it))
          it
          (make-item n (text-line-start t (text-line-at t (relocated-position t position (item-revision it))))
                     revision)))
      it)))

;; The item at V's top edge, moved with edits since, or #f for the first
;; item V draws.
(def (view-scroll-item (v : view)) => (Maybe item)
  (let (it v.top-item)
    (and it
         (let (now (current-item it))
           (set! v.top-item now)
           now))))

;; Adopt what the browser measured of V: IT at the top edge, OFFSET px of
;; it above the edge. V's placement names it from now on, keeping its
;; number, so a page loaded later puts V where it is.
(def (set-view-scroll! (v : view) (it : item) (offset : :flonum)) => :void
  (set! v.top-item it)
  (set! v.scroll-offset offset)
  (set! v.last-placement (make-placement (placement-number v.last-placement) it 'top offset)))

;; V's newest placement.
(def (view-placement (v : view)) => placement
  v.last-placement)

;; Ask the browser to put IT (#f: the first item V draws) at V's top,
;; centre or bottom (ALIGN 'top, 'center or 'bottom); with 'top, OFFSET px
;; of it above the edge. Until the browser reports, V draws around IT, as
;; many items on each side as it draws on its longer side now: the target
;; may lie anywhere, and a side cut short by an end of the buffer says
;; nothing about how many items fill the view elsewhere.
(def (place-view! (v : view) (it :? item) (align : :symbol) offset: (offset : :flonum := 0.)) => :void
  (unless (memq align '(top center bottom))
    (error "Place an item at the top, center or bottom, not" align))
  (set! v.last-placement (make-placement (fx1+ (placement-number v.last-placement)) it align
                                    (if (eq? align 'top) offset 0.)))
  (set! v.top-item it)
  (set! v.scroll-offset (if (eq? align 'top) offset 0.))
  (let (drawn (fxmax v.drawn-before v.drawn-after))
    (set-view-drawn-items! v drawn drawn)))

(def (set-view-facts! (v : view) (facts : scroll-facts)) => :void
  (set! v.facts facts))

;; The last item wholly in V, as last measured, moved with edits since;
;; or #f.
(def (view-last-visible-item (v : view)) => (Maybe item)
  (let* ((facts v.facts)
         (it (and facts (scroll-facts-last-visible facts))))
    (and it (current-item it))))

;; Draw BEFORE items before V's scroll item and AFTER after it.
(def (set-view-drawn-items! (v : view) (before : :fixnum) (after : :fixnum)) => :void
  (set! v.drawn-before (fxmax 0 before))
  (set! v.drawn-after (fxmax 0 after)))

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
