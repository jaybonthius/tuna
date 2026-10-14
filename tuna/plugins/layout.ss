;;; The default layout (live tier; ADR 11, ADR 13): views arranged in a
;;; tree of containers (tuna/plugins/layout/tree.ss), a movable frame, and
;;; frame marks.
;;;
;;; The layout is a frozen value held in one mutable field: every change
;;; builds a new tree sharing the unchanged parts and goes through
;;; `commit!`, which keeps the frame's invariants. The frame targets the
;;; whole layout, a part (by id), or a node of a view's buffer; its
;;; selected view lies under the target and is pushed to the buffers
;;; service. Each container remembers its last-focused child, and a tabbed
;;; container's active tab is that child. Container kinds come from an
;;; entry table, so another plugin can add one
;;; (`context-define-container-kind!`); this plugin adds `fit` and `tabbed`.
;;;
;;; Pins (ADR 13, "Pinning") are flags on links: the frame draws the tree
;;; through `drawn-part`, so each container on the way from the frame's
;;; target to the top draws its child on the way and its pinned children.
;;; The views drawn are the visible ones; the selected view is always one
;;; of them. The selected part is the selected view or one of its
;;; containers (as i3's "focus parent"); pinning, unpinning, moving and
;;; wrapping in a new container act on it, and changing a container's kind
;;; or direction acts on it or, for a view, on the container around it.
;;; Locked views belong to plugins (`add-locked-view!`): the user cannot
;;; unpin or delete them, nor wrap or reshape them or a part holding them,
;;; and they close with their buffers.
;;;
;;; The plugin adapts to a new buffers provider instead of restarting: it
;;; re-points its views by buffer name and node id, which the buffers
;;; handover keeps. Its session slot `layout` holds the tree with its pins
;;; and locks, the frame and the frame marks as plain data; restoring skips
;;; views of missing buffers, and is skipped when the layout took views
;;; over from another layout, so a saved slot never overwrites a live
;;; handover. After restoring or taking over views, plugins' locked views
;;; that went missing are put back.
prelude: :gerbil/core

(import :std/interface
        :tuna/services/commands
        :tuna/kernel
        :tuna/services/keys
        :tuna/services/buffers
        :tuna/services/session
        :tuna/services/settings
        :tuna/services/layout
        ./layout/tree)
(export layout-plugin
        context-define-container-kind!)

;; The frame: its target, the part with id PART (#f for the whole layout)
;; and, with a view's part, START, a node of that view's buffer; and the
;; selected view, which lies under the target.
(defstruct frame-state ((part     :? :fixnum)
                        (start    :? node)
                        (selected : view))
  final: #t)

;; A saved frame target, by part id (#f for the whole layout) and node id.
(defstruct frame-mark ((name : :string)
                       (part :? :fixnum)
                       (node :? :fixnum))
  final: #t)

;; A plugin's request for a locked view of SHOWING (add-locked-view!).
(defstruct locked-request ((showing : buffer)
                           (side    : :symbol)
                           (size    : :t))
  final: #t)

(defclass tree-layout ((root         : :t)           ; the tree's root part
                       (frame        : frame-state)
                       (level        : :fixnum)      ; the selected part: 0 the selected view, 1 its container, ...
                       (marks        : :list)        ; frame marks, oldest first
                       (locked       : :list)        ; locked requests, oldest first
                       (kinds        : entry-table)  ; kind name -> layout-kind
                       (handed-over? : :boolean))    ; took views over from another layout
  final: #t)

;;; Container kinds

(def (container-element-id (c : container)) => :string
  (string-append "container-" (number->string (container-id c))))

(def (container-attributes (c : container) (kind : :string)) => :list
  ['@ ['class (string-append "container " kind " " (symbol->string (container-direction c)))]
      ['id (container-element-id c)]
      ['data-container (number->string (container-id c))]])

;; Children side by side along the direction, sharing the space by weight.
(def (render-fit (c : container) (render-link : :procedure) (label : :procedure)) => :list
  (cons* 'div (container-attributes c "fit") (map render-link (container-links c))))

;; A tab strip (on top when horizontal, down the side when vertical) and
;; the active child, which is the one last focused. A tab is the part
;; "tab-line:P" (Emacs's area name for a window's tabs), P being the id of
;; the part it shows, and is clickable while a click on a tab line has a
;; binding ("<tab-line> <mouse-1>").
(def (render-tabbed (c : container) (render-link : :procedure) (label : :procedure)) => :list
  (let ((active (focused-link c))
        (clickable (if (part-clickable? 'tab-line) '((data-clickable "")) '())))
    `(div ,(container-attributes c "tabbed")
          (ul (@ (class "tabs") (role "tablist")
                 (aria-orientation ,(symbol->string (container-direction c))))
              ,@(map (lambda ((l : link))
                       `(li (@ (class "tab") (role "tab")
                               (aria-selected ,(if (eq? l active) "true" "false"))
                               (data-part ,(string-append "tab-line:" (number->string (part-id l.part))))
                               ,@clickable)
                            ,(label l.part)))
                     (container-links c)))
          ;; Only one child is drawn, so its stored split share must not
          ;; leave unused space. The layout value keeps that share.
          (div (@ (class "tab-panel") (role "tabpanel"))
               ,(render-link (make-link 1 (link-part active)
                                        (link-pinned? active) (link-locked? active)))))))

(def fit-kind
  (make-layout-kind 'fit "Children side by side, sized by weight." #t #f render-fit))

(def tabbed-kind
  (make-layout-kind 'tabbed "One child at a time, with tabs." #f #t render-tabbed))

(def (kind-of (self : tree-layout)) => :procedure
  (lambda ((name : :symbol))
    (let (best (entry-table-ref self.kinds name))
      (if best (entry-value best) fit-kind))))

;; Add the container KIND to the default layout for CTX's plugin, until
;; that plugin is turned off. The current layout must be this plugin's.
(def (context-define-container-kind! (ctx : context) (kind : layout-kind)) => :void
  (let (provider (service-provider layout-service))
    (unless (tree-layout? provider)
      (error "The current layout does not take container kinds"))
    (context-add-entry! ctx (tree-layout-kinds provider) (layout-kind-name kind) kind
                        doc: (layout-kind-doc kind))
    (void)))

;;; The frame

(def (effective? (self : tree-layout)) => :boolean
  (eq? (service-provider layout-service) self))

;; PART as the frame stores it: #f for ROOT itself, unless a START node
;; needs the view's id.
(def (normal-part (root : :t) (part :? :fixnum) (start :? node)) => (Maybe :fixnum)
  (and part (or start (not (fx= part (part-id root)))) part))

;; The part the frame shows.
(def (frame-top (self : tree-layout)) => :t
  (let (part (frame-state-part self.frame))
    (or (and part (find-part self.root part)) self.root)))

(def (node-of-view? (n : node) (v : view)) => :boolean
  (let (root (buffer-root (view-showing v)))
    (let up ((m n))
      (cond
       ((eq? m root) #t)
       ((node-parent m) => up)
       (else #f)))))

;; The frame's node, while it is still a node of its view's buffer.
(def (shown-node (self : tree-layout)) => (Maybe node)
  (let ((n (frame-state-start self.frame))
        (top (frame-top self)))
    (and n (leaf? top) (node-of-view? n (leaf-view top)) n)))

;; The node with id ID in the tree at N, or #f.
(def (find-node (n : node) (id : :fixnum)) => (Maybe node)
  (if (fx= (node-id n) id)
    n
    (ormap (cut find-node <> id) (node-children n))))

(def (under? (self : tree-layout) (v : view)) => :boolean
  (and (find-part (frame-top self) (view-id v)) #t))

;; The tree as the frame draws it (drawn-part).
(def (drawn (self : tree-layout)) => :t
  (drawn-part self.root (part-id (frame-top self))))

;; The leaves drawn, in order.
(def (visible (self : tree-layout)) => :list
  (visible-leaves (drawn self) (kind-of self)))

(def (visible? (self : tree-layout) (v : view)) => :boolean
  (and (find (lambda ((l : leaf)) (eq? (leaf-view l) v)) (visible self)) #t))

;; Whether V can be the selected view without moving the frame: under the
;; frame's target (focus memory will show it), or visible in a pinned part.
(def (selectable? (self : tree-layout) (v : view)) => :boolean
  (and (find-part self.root (view-id v))
       (or (under? self v) (visible? self v))))

;; Keep the selected view selectable (else take the target's focused
;; view), focus memory pointing at it, and the buffers service's selected
;; view the same. A new selected view is its own selected part.
(def (settle-selection! (self : tree-layout)) => :void
  (let* ((f self.frame)
         (v (if (selectable? self (frame-state-selected f))
              (frame-state-selected f)
              (leaf-view (focused-leaf (frame-top self))))))
    (set! self.root (select-path self.root (view-id v)))
    (unless (eq? v (frame-state-selected f))
      (set! self.level 0)
      (set! self.frame (make-frame-state (frame-state-part f) (frame-state-start f) v)))
    (when (effective? self)
      (set-selected-view! v))))

;; Where a frame targeting PART of OLD points in NEW: PART if it is still
;; there; else the lowest part holding what survives of PART's views; else
;; PART's nearest ancestor still there; else the whole layout.
(def (repair-part (old : :t) (new : :t) (part :? :fixnum)) => (Maybe :fixnum)
  (cond
   ((not part) #f)
   ((find-part new part) part)
   (else
    (let* ((before (find-part old part))
           (survivors (if before
                        (filter (lambda ((l : leaf)) (find-part new (part-id l))) (part-leaves before))
                        [])))
      (if (pair? survivors)
        (common-ancestor-id new (map part-id survivors))
        (let (path (part-path old part))
          (and path
               (find (lambda ((id : :fixnum)) (find-part new id))
                     (map part-id (cdr (reverse path)))))))))))

;; Make ROOT the layout, repairing the frame.
(def (commit! (self : tree-layout) (root : :t)) => :void
  (let* ((f self.frame)
         (part (repair-part self.root root (frame-state-part f)))
         (node (and (eqv? part (frame-state-part f)) (frame-state-start f))))
    (set! self.root root)
    (set! self.frame (make-frame-state (normal-part root part node) node (frame-state-selected f)))
    (settle-selection! self)))

;; Commit ROOT, in which the part ID now sits in a new container beside
;; something new; a frame that targeted that part moves out to its
;; container, so it shows what was added.
(def (commit-around! (self : tree-layout) (id : :fixnum) (root : :t)) => :void
  (let (framed? (eqv? (frame-state-part self.frame) id))
    (commit! self root)
    (when framed?
      (let (parent (parent-container self.root id))
        (point-frame! self (and parent (container-id parent)) #f)))))

;; Point the frame at PART and START. Moving the frame selects a view under
;; its new target: the selected view if it is there, else the target's
;; focused view.
(def (point-frame! (self : tree-layout) (part :? :fixnum) (start :? node)) => :void
  (set! self.frame (make-frame-state (normal-part self.root part start) start (frame-state-selected self.frame)))
  (unless (under? self (frame-state-selected self.frame))
    (set! self.level 0)
    (set! self.frame (make-frame-state (frame-state-part self.frame) start
                                       (leaf-view (focused-leaf (frame-top self))))))
  (settle-selection! self))

(def (own-leaf (self : tree-layout) (v : view)) => leaf
  (let (p (find-part self.root (view-id v)))
    (unless (leaf? p)
      (error "Not a view of this layout" (view-id v)))
    p))

;; Select V; a V neither under the frame's target nor in a visible pinned
;; part moves the frame up to hold it.
(def (select! (self : tree-layout) (v : view)) => :void
  (own-leaf self v)
  (let (f self.frame)
    (unless (eq? v (frame-state-selected f))
      (set! self.level 0))
    (set! self.frame
      (if (selectable? self v)
        (make-frame-state (frame-state-part f) (frame-state-start f) v)
        (let (part (and (frame-state-part f) (common-ancestor-id self.root [(frame-state-part f) (view-id v)])))
          (make-frame-state (normal-part self.root part #f) #f v)))))
  (settle-selection! self))

;;; Changing the layout

(def (split! (self : tree-layout) (v : view) (new : leaf) (direction : :symbol)) => :void
  (commit-around! self (view-id v)
                  (split-part self.root (view-id v) new direction (next-id!) (kind-of self))))

(def (hint (hints : :list) (name : :symbol)) => :t
  (let (pair (assq name hints))
    (and pair (cdr pair))))

;; The weight of what stays beside a part of share SIZE: the rest of the
;; space, or all of it beside a part as big as its content.
(def (rest-size (size : :t)) => :real
  (if (real? size) (- 1 size) 1))

(def (side-axis (side : :symbol)) => :symbol
  (if (memq side '(left right)) 'horizontal 'vertical))

;; The locked links at SIDE's end of C's links, if C is a fit container
;; along SIDE's axis, nearest the edge first.
(def (locked-edge (c : :t) (side : :symbol)) => :list
  (if (and (container? c)
           (eq? (container-kind c) 'fit)
           (eq? (container-direction c) (side-axis side)))
    (let lp ((links (if (memq side '(right bottom)) (reverse (container-links c)) (container-links c))))
      (match links
        ([l . more] (if (link-locked? l) (cons l (lp more)) []))
        ([] [])))
    []))

;; ROOT with a view at SIDE of the part TOP, on a link of SIZE: inside TOP
;; next to its locked parts at that edge (the bar stays outermost), with
;; the share SIZE of the other weights; or else TOP and the view in a new
;; fit container.
(def (beside-part (self : tree-layout) (top : :t) (side : :symbol) (side-link : link)) => :t
  (let ((edge (locked-edge top side))
        (size (link-size side-link)))
    (if (pair? edge)
      (let* ((others (foldl (lambda ((l : link) (sum : :real)) (if (real? l.size) (+ sum l.size) sum))
                            0 (container-links top)))
             (weight (if (and (real? size) (> others 0)) (/ (* others size) (- 1 size)) size)))
        (insert-link self.root (part-id top)
                     (cons (if (memq side '(right bottom)) 'before 'after) (part-id (link-part (last edge))))
                     (make-link weight (link-part side-link) (link-pinned? side-link) (link-locked? side-link))))
      (let (c (make-container (next-id!) 'fit (side-axis side)
                              (if (memq side '(left top))
                                [side-link (new-link (rest-size size) top)]
                                [(new-link (rest-size size) top) side-link])
                              (part-id top)))
        (replace-part self.root (part-id top) c (kind-of self))))))

;; display-buffer: a visible view already showing B; with a side, a new
;; dedicated view at that side of what the frame shows; else another
;; visible view that is neither selected nor dedicated; else a new
;; dedicated view below the selected one.
(def (display-in! (self : tree-layout) (b : buffer) (hints : :list)) => view
  (let* ((side (hint hints 'side))
         (shown (visible self))
         (showing (find (lambda ((l : leaf)) (eq? (view-showing (leaf-view l)) b)) shown)))
    (cond
     (showing (leaf-view showing))
     ((memq side '(left right top bottom))
      (let* ((v (new-view b))
             (top (frame-top self)))
        (commit-around! self (part-id top)
                        (beside-part self top side (new-link (or (hint hints 'size) 1/4) (make-leaf v #t))))
        v))
     (else
      (let (other (find (lambda ((l : leaf))
                          (not (or (leaf-dedicated? l) (eq? (leaf-view l) (frame-state-selected self.frame)))))
                        shown))
        (if other
          (let (v (leaf-view other))
            (set-view-showing! v b)
            v)
          (let (v (new-view b))
            (split! self (frame-state-selected self.frame) (make-leaf v #t) 'vertical)
            v)))))))

;; A leaf showing B, or #f.
(def (leaf-showing (self : tree-layout) (b : buffer)) => (Maybe leaf)
  (find (lambda ((l : leaf)) (eq? (view-showing (leaf-view l)) b)) (part-leaves self.root)))

;; Put a locked, pinned, dedicated view of B at SIDE of the whole layout:
;; into the locked part at that edge of the top (a container of them, or a
;; view that becomes one), or beside the top.
(def (place-locked! (self : tree-layout) (b : buffer) (side : :symbol) (size : :t)) => view
  (let* ((v (new-view b))
         (new (make-link size (make-leaf v #t) #t #t))
         (root self.root)
         (edge (locked-edge root side)))
    (commit! self
             (if (pair? edge)
               (let (group (link-part (car edge)))
                 (if (and (container? group)
                          (eq? (container-kind group) 'fit)
                          (eq? (container-direction group) 'vertical))
                   (insert-link root (container-id group) 'last new)
                   (replace-part root (part-id group)
                                 (make-container (next-id!) 'fit 'vertical
                                                 [(make-link (link-size (car edge)) group #t #t) new]
                                                 (part-id group))
                                 (kind-of self))))
               (beside-part self root side new)))
    v))

;; add-locked-view!: remember the request, and show B unless a view shows it.
(def (add-locked! (self : tree-layout) (b : buffer) (side : :symbol) (size : :t)) => view
  (let (live (buffer-list))
    (set! self.locked
      (append (filter (lambda ((r : locked-request)) (and (memq r.showing live) (not (eq? r.showing b))))
                      self.locked)
              [(make-locked-request b side size)])))
  (let (l (leaf-showing self b))
    (if l (leaf-view l) (place-locked! self b side size))))

;; Put back the locked views whose buffers live but no view shows.
(def (ensure-locked! (self : tree-layout)) => :void
  (let (live (buffer-list))
    (for-each (lambda ((r : locked-request))
                (when (and (memq r.showing live) (not (leaf-showing self r.showing)))
                  (place-locked! self r.showing r.side r.size)))
              self.locked)))

;; On kill-buffer-hook: dedicated views of B close (the last view stays);
;; other views of B show another buffer.
(def (buffer-killed! (self : tree-layout) (b : buffer)) => :void
  (set! self.locked (filter (lambda ((r : locked-request)) (not (eq? r.showing b))) self.locked))
  (commit! self
           (foldl (lambda ((l : leaf) (root : :t))
                    (cond
                     ((not (eq? (view-showing (leaf-view l)) b)) root)
                     ((and (leaf-dedicated? l) (pair? (cdr (part-leaves root))))
                      (remove-part root (part-id l) (kind-of self)))
                     (else
                      (let (other (other-buffer b))
                        (when other
                          (set-view-showing! (leaf-view l) other)))
                      root)))
                  self.root
                  (part-leaves self.root))))

;; Take over the views of D: views this layout holds keep their places,
;; the others go, and new ones are split to the right of the view before
;; them in D.
(def (adopt! (self : tree-layout) (d : layout-description)) => :void
  (let* ((views (layout-description-views d))
         (kind-of (kind-of self))
         (kept (foldl (lambda ((l : leaf) (root : :t))
                        (if (or (not root) (memq (leaf-view l) views))
                          root
                          (remove-part root (part-id l) kind-of)))
                      self.root
                      (part-leaves self.root)))
         (root (let lp ((rest views) (previous #f) (root kept))
                 (match rest
                   ([] root)
                   ([v . more]
                    (using (v : view)
                      (cond
                       ((and root (find-part root v.id)) (lp more v root))
                       ((not root) (lp more v (make-leaf v #f)))
                       (else
                        (lp more v (split-part root
                                               (if previous
                                                 (view-id previous)
                                                 (part-id (car (part-leaves root))))
                                               (make-leaf v #f) 'horizontal (next-id!) kind-of))))))))))
    (set! self.handed-over? #t)
    (commit! self root)
    (ensure-locked! self)
    (select! self (layout-description-selected d))))

;; Re-point V, a view of OLD's buffers, at the current provider's buffer of
;; the same name and node of the same id, at the same point. A view whose
;; buffer is gone shows another one.
(def (re-point-view! (old : Buffers) (v : view)) => :void
  (let* ((name (Buffers-buffer-name old (view-showing v)))
         (focus (view-node v))
         (position (with-catch
                    (lambda (e) (view-position v))
                    (lambda ()
                      (if focus
                        (let* ((t (Buffers-node-text old focus))
                               (s (: (Buffers-text-snapshot old t) snapshot)))
                          (if (fx= (snapshot-revision s) (view-revision v))
                            (view-position v)
                            (Buffers-relocate-position old t (view-position v) (view-revision v))))
                        (view-position v)))))
         (b (or (get-buffer name)
                (find (lambda ((b : buffer)) (not (internal-buffer? b))) (buffer-list)))))
    (when b
      (let (n (or (and focus (find-node (buffer-root b) (node-id focus)))
                  (buffer-point-node b)))
        (reset-view! v b n 1 (if n (text-chars-revision (text-node-content n)) 0))
        (set-view-point! v position)))))

;; After the buffers provider changed from OLD: views showing buffers of
;; the old provider are re-pointed (the selected view, which the buffers
;; handover re-points itself, already shows a new buffer).
(def (adapt-to-buffers! (self : tree-layout) (old : :t) (new : :t)) => :void
  (when old
    (let ((old (Buffers old))
          (current (buffer-list))
          (top (frame-top self))
          (n (frame-state-start self.frame)))
      (for-each (lambda ((l : leaf))
                  (let (v (leaf-view l))
                    (unless (memq (view-showing v) current)
                      (re-point-view! old v))))
                (part-leaves self.root))
      (set! self.frame
        (make-frame-state (frame-state-part self.frame)
                    (and n (leaf? top)
                         (find-node (buffer-root (view-showing (leaf-view top))) (node-id n)))
                    (frame-state-selected self.frame)))
      (settle-selection! self))))

;; The neutral description: the views outside locked parts, which belong
;; to plugins that put them back in the next layout, and the selected view,
;; or the first of them when a locked view is selected.
(def (describe (self : tree-layout)) => layout-description
  (let* ((views (filter-map (lambda ((l : leaf))
                              (and (not (inside-locked? self.root (part-id l))) (leaf-view l)))
                            (part-leaves self.root)))
         (selected (frame-state-selected self.frame)))
    (make-layout-description views (if (memq selected views) selected (car views)))))

;;; Rendering

;; A link's size, as CSS reads it: "--tuna-size: W" for a weight, or
;; data-size="content".
(def (size-attribute (size : :t)) => :list
  (if (real? size)
    (let (x (exact->inexact size))
      ['style (string-append "--tuna-size: "
                             (if (integer? x) (number->string (inexact->exact x)) (number->string x)))])
    ['data-size "content"]))

(def (with-attribute (element : :t) (attribute : :list)) => :t
  (match element
    ([tag ['@ . attributes] . body] (cons* tag (cons '@ (append attributes [attribute])) body))
    ([tag . body] (cons* tag ['@ attribute] body))
    (else element)))

;; What C's weights are multiplied by for CSS: flex children whose grow
;; factors sum below 1 share only that part of the free space, so weights
;; that do (left by a removal beside a part sized by content) are scaled
;; up to sum to 1.
(def (weight-scale (c : container)) => :real
  (let (sum (foldl (lambda ((l : link) (sum : :real)) (if (real? l.size) (+ sum l.size) sum))
                   0 (container-links c)))
    (if (< 0 sum 1) (/ 1 sum) 1)))

;; The id of the selected part when it is a container, or #f.
(def (selected-container-id (self : tree-layout)) => (Maybe :fixnum)
  (let (p (selected-part self))
    (and (container? p) (container-id p))))

;; The drawn part P for 'html. The target leaf TOP is drawn from START
;; when given.
(def (render-html (self : tree-layout) (p : :t) (top : :t) (start :? node) (render-view : :procedure)) => :t
  (let ((selected (frame-state-selected self.frame))
        (marked (selected-container-id self))
        (kind-of (kind-of self)))
    (let render ((p p))
      (if (leaf? p)
        (let (v (leaf-view p))
          (render-view v (eq? v selected) (or (and (eq? p top) start) (buffer-root (view-showing v)))))
        (let* ((scale (weight-scale p))
               (element ((layout-kind-render (kind-of (container-kind p)))
                         p
                         (lambda ((l : link))
                           (with-attribute (render l.part)
                                           (size-attribute (if (real? l.size) (* scale l.size) l.size))))
                         (lambda (part) (buffer-name (view-showing (leaf-view (focused-leaf part))))))))
          (if (eqv? (container-id p) marked)
            (with-attribute element ['data-selected-part "true"])
            element))))))

;;; Session data:
;;;   ((tree PART)
;;;    (frame PART-ID NODE-ID SELECTED-VIEW-ID)
;;;    (marks (NAME PART-ID NODE-ID) ...))
;;; PART is (view ID BUFFER-NAME POINT DEDICATED?) or
;;; (container ID KIND DIRECTION FOCUS-ID ((SIZE FLAGS PART) ...)), where
;;; SIZE is a weight or `content` and FLAGS lists `pinned` and `locked`.
;;; Ids are renumbered on restore; PART-ID #f is the whole layout.

;; Fresh lists: session data may share no pair.
(def (link-flags (l : link)) => :list
  (filter identity [(and l.pinned? 'pinned) (and l.locked? 'locked)]))

(def (part->data (p : :t)) => :list
  (if (leaf? p)
    (let (v (leaf-view p))
      ['view (view-id v) (buffer-name (view-showing v)) (view-point v) (leaf-dedicated? p)])
    ['container (container-id p) (container-kind p) (container-direction p) (container-focus p)
     (map (lambda ((l : link)) [l.size (link-flags l) (part->data l.part)]) (container-links p))]))

(def (layout->data (self : tree-layout)) => :list
  (let ((f self.frame)
        (start (shown-node self)))
    [['tree (part->data self.root)]
     ['frame (frame-state-part f) (and start (node-id start)) (view-id (frame-state-selected f))]
     (cons 'marks (map (lambda ((m : frame-mark)) [m.name m.part m.node]) self.marks))]))

;; The id that saved id ID now has, allocating one on first sight.
(def (fresh-id! (ids : :t) (id : :fixnum)) => :fixnum
  (or (hash-get ids id)
      (let (new (next-id!))
        (hash-put! ids id new)
        new)))

(def (saved-size? (size : :t)) => :boolean
  (or (eq? size 'content) (and (real? size) (> size 0))))

;; The part DATA describes, or #f when it shows no existing buffer.
(def (data->part (data : :t) (ids : :t) (kind-of : :procedure)) => :t
  (match data
    (['view (? fixnum? id) (? string? name) (? fixnum? position) (? boolean? dedicated?)]
     (let (b (get-buffer name))
       (and b
            (let (v (new-view b))
              (set-view-point! v position)
              (hash-put! ids id (view-id v))
              (make-leaf v dedicated?)))))
    (['container (? fixnum? id) (? symbol? kind) (? symbol? direction) (? fixnum? focus) (? list? entries)]
     (and (memq direction '(horizontal vertical))
          (let* ((new-id (fresh-id! ids id))
                 (links (filter-map (lambda (entry)
                                      (match entry
                                        ([(? saved-size? size) (? list? flags) part]
                                         (let (p (data->part part ids kind-of))
                                           (and p (make-link size p
                                                             (and (memq 'pinned flags) #t)
                                                             (and (memq 'locked flags) #t)))))
                                        (else #f)))
                                    entries)))
            ;; As in the tree: a container left with one child by parts
            ;; that were skipped collapses; one saved with one child stays.
            (cond
             ((null? links) #f)
             ((and (null? (cdr links))
                   (pair? (cdr entries))
                   (not (layout-kind-keep-one-child? (kind-of kind))))
              (link-part (car links)))
             (else
              (let (focus (hash-get ids focus))
                (make-container new-id kind direction links
                                (if (and focus (find (lambda ((l : link)) (fx= (part-id l.part) focus)) links))
                                  focus
                                  (part-id (link-part (car links)))))))))))
    (else #f)))

(def (restore! (self : tree-layout) (data : :t)) => :void
  (unless self.handed-over?
    (match data
      ([['tree tree] ['frame part node selected] ['marks . marks]]
       (let* ((ids (make-hash-table-eqv))
              (root (data->part tree ids (kind-of self))))
         (when root
           (let* ((part (and (fixnum? part) (find-part root (fresh-id! ids part)) (fresh-id! ids part)))
                  (top (or (and part (find-part root part)) root))
                  (start (and (fixnum? node) (leaf? top)
                              (find-node (buffer-root (view-showing (leaf-view top))) node)))
                  (chosen (and (fixnum? selected) (hash-get ids selected)
                               (find-part root (hash-get ids selected)))))
             (set! self.root root)
             (set! self.frame (make-frame-state (normal-part root part start) start
                                          (leaf-view (if (leaf? chosen) chosen (focused-leaf top)))))
             (set! self.marks
               (filter-map (lambda (entry)
                             (match entry
                               ([(? string? name) part node]
                                (and (or (not part) (fixnum? part))
                                     (or (not node) (fixnum? node))
                                     (make-frame-mark name (and part (fresh-id! ids part)) node)))
                               (else #f)))
                           (if (list? marks) marks [])))
             (settle-selection! self)
             (ensure-locked! self)))))
      (else (void)))))

;;; Frame marks

(def (set-mark! (self : tree-layout) (name : :string)) => :void
  (let* ((start (shown-node self))
         (part (or (frame-state-part self.frame) (and start (part-id self.root)))))
    (set! self.marks
      (append (filter (lambda ((m : frame-mark)) (not (string=? m.name name))) self.marks)
              [(make-frame-mark name part (and start (node-id start)))]))))

(def (jump! (self : tree-layout) (name : :string)) => :symbol
  (let (m (find (lambda ((m : frame-mark)) (string=? m.name name)) self.marks))
    (if (not m)
      'unknown
      (using (m : frame-mark)
        (let* ((target (if m.part (find-part self.root m.part) self.root))
               (n (and m.node target (leaf? target)
                       (find-node (buffer-root (view-showing (leaf-view target))) m.node))))
          (if (or (not target) (and m.node (not n)))
            (begin
              (set! self.marks (remq m self.marks))
              'gone)
            (begin
              (point-frame! self m.part n)
              'jumped)))))))

;;; Commands: tabs and zooming

;; The nearest tabbed container inside the frame's target that holds the
;; selected view, paired with its child on the way, or #f.
(def (enclosing-tabs (self : tree-layout)) => (Maybe :pair)
  (let (path (part-path (frame-top self) (view-id (frame-state-selected self.frame))))
    (and path
         (let up ((ancestors (cdr (reverse path))) (child (last path)))
           (match ancestors
             ([] #f)
             ([c . more] (if (eq? (container-kind c) 'tabbed) (cons c child) (up more c))))))))

;; A new tab showing the selected view's buffer at its point, after the
;; current tab; outside tabs, the selected view becomes the first tab.
(def (new-tab! (self : tree-layout)) => :void
  (let* ((v (frame-state-selected self.frame))
         (new (make-leaf (copy-view v) #f))
         (tabs (enclosing-tabs self)))
    (if tabs
      (commit! self (insert-link self.root (container-id (car tabs)) (cons 'after (part-id (cdr tabs)))
                                 (new-link 1 new)))
      (commit-around! self (view-id v)
                      (replace-part self.root (view-id v)
                                    (make-container (next-id!) 'tabbed 'horizontal
                                                    [(new-link 1 (own-leaf self v)) (new-link 1 new)]
                                                    (view-id v))
                                    (kind-of self))))
    (select! self (leaf-view new))))

;; Select the tab the click P names: the view last focused in the part it
;; shows. A tab whose part is gone reports the stale click.
(def (select-clicked-tab! (self : tree-layout) (p : posn)) => :void
  (let (part (find-part self.root (posn-part p)))
    (if part
      (select! self (leaf-view (focused-leaf part)))
      (report-stale-click p what: "tab"))))

(def (switch-tab! (self : tree-layout) (step : :fixnum)) => :void
  (let (tabs (enclosing-tabs self))
    (if (not tabs)
      (message "No tabs here")
      (let* ((links (container-links (car tabs)))
             (count (length links)))
        (if (fx= count 1)
          (message "Only one tab")
          (let (index (modulo (fx+ (link-index links (part-id (cdr tabs))) step) count))
            (select! self (leaf-view (focused-leaf (link-part (list-ref links index)))))))))))

;; Whether the user may remove the part P: neither it nor a part below it
;; is locked.
(def (removable? (self : tree-layout) (p : :t)) => :boolean
  (let (l (part-link self.root (part-id p)))
    (not (or (and l (link-locked? l)) (holds-locked? p)))))

;; Whether removing the part P leaves a view outside locked parts.
(def (leaves-a-view? (self : tree-layout) (p : :t)) => :boolean
  (let (going (part-leaves p))
    (and (find (lambda ((l : leaf))
                 (not (or (memq l going) (inside-locked? self.root (part-id l)))))
               (part-leaves self.root))
         #t)))

(def (close-tab! (self : tree-layout)) => :void
  (let (tabs (enclosing-tabs self))
    (if (not tabs)
      (message "No tabs here")
      (let (going (if (null? (cdr (container-links (car tabs)))) (car tabs) (cdr tabs)))
        (cond
         ((not (removable? self going)) (message "Cannot close a tab holding a locked part"))
         ((not (leaves-a-view? self going)) (message "Cannot close the last view"))
         (else (commit! self (remove-part self.root (part-id going) (kind-of self)))))))))

;; Move the frame one level down, toward the selected view (or the
;; target's focused child, when the selected view is in a pinned part
;; outside it).
(def (zoom-in! (self : tree-layout)) => :void
  (let (top (frame-top self))
    (if (leaf? top)
      (message "The frame is on a view")
      (point-frame! self
                    (part-id (or (child-toward top (view-id (frame-state-selected self.frame)))
                                 (link-part (focused-link top))))
                    #f))))

;; Move the frame one level up: from a node to its parent node, then to
;; the view, then up the containers.
(def (zoom-out! (self : tree-layout)) => :void
  (let ((top (frame-top self))
        (start (shown-node self)))
    (cond
     (start
      (let ((parent (node-parent start))
            (root (buffer-root (view-showing (leaf-view top)))))
        (point-frame! self (part-id top) (and parent (not (eq? parent root)) parent))))
     ((eq? top self.root) (message "The frame is at the top"))
     (else (point-frame! self (container-id (parent-container self.root (part-id top))) #f)))))

;;; Commands: the selected part, pins and moves

;; The selected part: the selected view, or its container LEVEL levels up.
(def (selected-part (self : tree-layout)) => :t
  (let (above (reverse (or (part-path self.root (view-id (frame-state-selected self.frame)))
                           [self.root])))
    (list-ref above (fxmin self.level (fx1- (length above))))))

(def (describe-part (p : :t)) => :string
  (if (leaf? p)
    (string-append "the view of " (buffer-name (view-showing (leaf-view p))))
    (let (count (length (part-leaves p)))
      (string-append "a " (symbol->string (container-kind p)) " " (symbol->string (container-direction p))
                     " container of " (number->string count) (if (fx= count 1) " view" " views")))))

;; Select the selected part's container (STEP 1) or the part below it on
;; the way to the selected view (STEP -1).
(def (select-part-level! (self : tree-layout) (step : :fixnum)) => :void
  (let* ((depth (fx1- (length (or (part-path self.root (view-id (frame-state-selected self.frame))) [#f]))))
         (level (fx+ self.level step)))
    (if (fx<= 0 level depth)
      (begin
        (set! self.level level)
        (message (string-append "Selected part: " (describe-part (selected-part self)))))
      (message (if (fx< level 0) "The selected part is the selected view" "The selected part is the whole layout")))))

(def (set-pinned! (self : tree-layout) (pinned? : :boolean)) => :void
  (let* ((p (selected-part self))
         (l (part-link self.root (part-id p))))
    (cond
     ((not l) (message "The whole layout cannot be pinned or unpinned"))
     ((and (not pinned?) (link-locked? l)) (message "Locked: the plugin that owns it keeps it pinned"))
     (else
      (commit! self (update-link self.root (part-id p)
                                 (lambda ((l : link)) (make-link l.size l.part pinned? l.locked?))))
      (message (string-append (if pinned? "Pinned " "Unpinned ") (describe-part p)))))))

;; Move the selected part toward DIRECTION; the frame moves up if needed
;; to keep the selected view visible.
(def (move-selected-part! (self : tree-layout) (direction : :symbol)) => :void
  (let* ((p (selected-part self))
         (v (frame-state-selected self.frame))
         (level self.level)
         (moved (move-part self.root (part-id p) (if (memq direction '(left right)) 'horizontal 'vertical)
                           (and (memq direction '(right down)) #t) (kind-of self))))
    (if (not moved)
      (message "Cannot move further that way")
      (begin
        (commit! self moved)
        (select! self v)
        (set! self.level level)))))

(def (check-effective! (self : tree-layout)) => :void
  (unless (effective? self)
    (error "This command needs the default layout, which another layout outranks")))

;;; Commands: wrapping parts and reshaping containers

;; Why the user may not wrap or reshape the part P, or #f. A locked part
;; keeps the place and shape its plugin gave it: wrapping it, or making
;; the container holding it tabbed or turning it, could hide or misplace
;; it (the bar holding the minibuffer), so neither a part that is locked or
;; inside a locked part nor a part holding one may change this way.
(def (rearranging-refusal (self : tree-layout) (p : :t)) => (Maybe :string)
  (cond
   ((inside-locked? self.root (part-id p)) "Locked: the plugin that owns it arranges it")
   ((holds-locked? p) "It holds a locked part, which the plugin that owns it arranges")
   (else #f)))

;; Wrap the selected part in a new container of KIND and DIRECTION, which
;; takes its link (size and pin). The selected view and the selected part
;; stay selected; wrapping the whole layout makes a new root.
(def (wrap-selected-part! (self : tree-layout) (kind : :symbol) (direction : :symbol)) => :void
  (let* ((p (selected-part self))
         (refusal (rearranging-refusal self p)))
    (if refusal
      (message refusal)
      (let (id (next-id!))
        (commit! self (wrap-part self.root (part-id p) kind direction id))
        (message (string-append "Wrapped " (describe-part p) " in "
                                (describe-part (find-part self.root id))))))))

;; The container the kind and direction commands act on: the selected
;; part, or the container around it when it is a view; #f for a view that
;; is the whole layout.
(def (selected-container (self : tree-layout)) => (Maybe container)
  (let (p (selected-part self))
    (if (container? p) p (parent-container self.root (part-id p)))))

;; Change the selected container's kind (KIND? true: fit becomes tabbed,
;; any other kind fit) or its direction, keeping its children, their links
;; and its focus memory.
(def (reshape-selected-container! (self : tree-layout) (kind? : :boolean)) => :void
  (let (c (selected-container self))
    (if (not c)
      (message "The selected view is in no container")
      (using (c : container)
        (let (refusal (rearranging-refusal self c))
          (if refusal
            (message refusal)
            (let ((kind (cond ((not kind?) c.kind) ((eq? c.kind 'fit) 'tabbed) (else 'fit)))
                  (direction (cond (kind? c.direction) ((eq? c.direction 'horizontal) 'vertical) (else 'horizontal))))
              (commit! self (reshape-container self.root c.id kind direction))
              (message (string-append "Now " (describe-part (find-part self.root c.id)))))))))))

;; The view nearest V for which MATCH? holds: V, or else, walking up from
;; V in the drawn tree, the first visible one in a pinned child beside the
;; way.
(def (nearest (self : tree-layout) (v : view) (match? : :procedure)) => (Maybe view)
  (let* ((top (drawn self))
         (kind-of (kind-of self))
         (path (part-path top (view-id v))))
    (cond
     ((match? v) v)
     ((not path) #f)
     (else
      (let up ((ancestors (cdr (reverse path))) (on-way (view-id v)))
        (match ancestors
          ([] #f)
          ([c . more]
           (let (found (ormap (lambda ((l : link))
                                (and l.pinned?
                                     (not (fx= (part-id l.part) on-way))
                                     (find (lambda ((x : leaf)) (match? (leaf-view x)))
                                           (visible-leaves l.part kind-of))))
                              (container-links c)))
             (if found (leaf-view found) (up more (container-id c)))))))))))

(implement Layout tree-layout
  (views (lambda (self) (map leaf-view (part-leaves self.root))))
  (selected-view (lambda (self) (frame-state-selected self.frame)))
  (select-view! (lambda (self v) (select! self v)))
  (next-view (lambda (self v)
               (let* ((shown (filter (lambda ((w : view)) (or (eq? w v) (not (view-skipped? w))))
                                     (map leaf-view (visible self))))
                      (tail (memq v shown)))
                 (cond
                  ((and tail (pair? (cdr tail))) (cadr tail))
                  ((pair? shown) (car shown))
                  (else v)))))
  ;; A dedicated view showing another buffer is no longer dedicated, unless
  ;; it is locked: a plugin's view stays its plugin's.
  (show-buffer! (lambda (self v b)
                  (let (l (own-leaf self v))
                    (set-view-showing! v b)
                    (when (and (leaf-dedicated? l) (not (inside-locked? self.root (view-id v))))
                      (commit! self (replace-part self.root (view-id v) (make-leaf v #f) (kind-of self)))))))
  (split-view! (lambda (self v side)
                 (own-leaf self v)
                 (let (new (copy-view v))
                   (split! self v (make-leaf new #f) (if (eq? side 'right) 'horizontal 'vertical))
                   new)))
  (delete-view! (lambda (self v)
                  (let (l (own-leaf self v))
                    (unless (removable? self l)
                      (error "This view is locked: the plugin that owns it removes it"))
                    (unless (leaves-a-view? self l)
                      (error "Cannot delete the only view"))
                    (commit! self (remove-part self.root (view-id v) (kind-of self))))))
  (neighbor-view (lambda (self v direction)
                   (and (visible? self v)
                        (let ((top (drawn self))
                              (axis (if (memq direction '(left right)) 'horizontal 'vertical))
                              (forward? (and (memq direction '(right down)) #t)))
                          (let lp ((id (view-id v)))
                            (let (l (neighbor-leaf top id axis forward? (kind-of self)))
                              (cond
                               ((not l) #f)
                               ((view-skipped? (leaf-view l)) (lp (part-id l)))
                               (else (leaf-view l)))))))))
  (display-buffer! (lambda (self b hints) (display-in! self b hints)))
  (add-locked-view! (lambda (self b side size) (add-locked! self b side size)))
  (nearest-view (lambda (self v match?) (nearest self v match?)))
  (current-frame-target (lambda (self)
                          (make-frame-target (frame-state-part self.frame) (shown-node self))))
  (move-frame! (lambda (self target)
                 (let* ((part (frame-target-part target))
                        (p (and part (find-part self.root part)))
                        (n (frame-target-start target)))
                   (point-frame! self (and p part)
                                 (and n (leaf? p)
                                      (node-of-view? n (leaf-view p))
                                      (not (eq? n (buffer-root (view-showing (leaf-view p)))))
                                      n)))))
  (frame-mark-names (lambda (self) (map frame-mark-name self.marks)))
  (set-frame-mark! (lambda (self name) (set-mark! self name)))
  (jump-to-frame-mark! (lambda (self name) (jump! self name)))
  (render-layout (lambda (self target render-view)
                   (let ((top (frame-top self))
                         (start (shown-node self))
                         (selected (frame-state-selected self.frame)))
                     (case target
                       ((html) `(div (@ (class "layout")) ,(render-html self (drawn self) top start render-view)))
                       (else
                        (map (lambda ((l : leaf))
                               (let (v (leaf-view l))
                                 (render-view v (eq? v selected)
                                              (or (and (eq? l top) start) (buffer-root (view-showing v))))))
                             (visible self)))))))
  (describe-views (lambda (self) (describe self)))
  (adopt-views! (lambda (self description) (adopt! self description))))

(defplugin (layout-plugin ctx)
  "Arranges views in fit and tabbed containers, with pins, a movable frame and frame marks."
  requires: [commands-service buffers-service session-service input-service settings-service]
  optional: [layout-service messages-service]
  (let (v (selected-view))
    (using (self (tree-layout root: (make-leaf v #f) frame: (make-frame-state #f #f v) level: 0
                              marks: [] locked: [] kinds: (new-entry-table) handed-over?: #f)
                 : tree-layout)
      (context-add-entry! ctx self.kinds 'fit fit-kind doc: (layout-kind-doc fit-kind))
      (context-add-entry! ctx self.kinds 'tabbed tabbed-kind doc: (layout-kind-doc tabbed-kind))
      (context-add-hook! ctx kill-buffer-hook 'layout (lambda (b) (buffer-killed! self b)))
      (context-adapt! ctx buffers-service (lambda (old new) (adapt-to-buffers! self old new)))
      (context-add-session-slot! ctx 'layout
                                 version: 3
                                 save: (lambda () (layout->data self))
                                 restore: (lambda (data) (restore! self data)))
      (defcommand (tab-new) "Open a new tab on the selected view's buffer; outside tabs, make the view a tab first."
        (check-effective! self)
        (new-tab! self))
      (defcommand (tab-next) "Select the next tab."
        (check-effective! self)
        (switch-tab! self 1))
      (defcommand (tab-previous) "Select the previous tab."
        (check-effective! self)
        (switch-tab! self -1))
      (defcommand (tab-close) "Close the current tab."
        (check-effective! self)
        (close-tab! self))
      (defcommand (tab-select) "Switch to the tab clicked on."
        (check-effective! self)
        (let (p (event-start (last-command-event)))
          (if p
            (select-clicked-tab! self p)
            (message "tab-select runs only from a click"))))
      (defcommand (frame-zoom-in) "Move the frame one level down, toward the selected view."
        (check-effective! self)
        (zoom-in! self))
      (defcommand (frame-zoom-out) "Move the frame one level up."
        (check-effective! self)
        (zoom-out! self))
      (defcommand (select-parent-part) "Select the container of the selected part, for pinning and moving."
        (check-effective! self)
        (select-part-level! self 1))
      (defcommand (select-child-part) "Select the part below the selected part, toward the selected view."
        (check-effective! self)
        (select-part-level! self -1))
      (defcommand (pin-part) "Pin the selected part: it stays drawn when the frame zooms past it."
        (check-effective! self)
        (set-pinned! self #t))
      (defcommand (unpin-part) "Unpin the selected part, unless a plugin locked it."
        (check-effective! self)
        (set-pinned! self #f))
      (defcommand (move-part-left) "Move the selected part left: past its neighbor, into it, or out of its container."
        (check-effective! self)
        (move-selected-part! self 'left))
      (defcommand (move-part-right) "Move the selected part right: past its neighbor, into it, or out of its container."
        (check-effective! self)
        (move-selected-part! self 'right))
      (defcommand (move-part-up) "Move the selected part up: past its neighbor, into it, or out of its container."
        (check-effective! self)
        (move-selected-part! self 'up))
      (defcommand (move-part-down) "Move the selected part down: past its neighbor, into it, or out of its container."
        (check-effective! self)
        (move-selected-part! self 'down))
      (defcommand (wrap-part-tabbed) "Wrap the selected part in a new tabbed container, as its only tab."
        (check-effective! self)
        (wrap-selected-part! self 'tabbed 'horizontal))
      (defcommand (wrap-part-vertical) "Wrap the selected part in a new fit container that lays out top to bottom."
        (check-effective! self)
        (wrap-selected-part! self 'fit 'vertical))
      (defcommand (wrap-part-horizontal) "Wrap the selected part in a new fit container that lays out left to right."
        (check-effective! self)
        (wrap-selected-part! self 'fit 'horizontal))
      (defcommand (toggle-container-kind) "Make the selected container, or the selected view's, tabbed if it is fit, else fit."
        (check-effective! self)
        (reshape-selected-container! self #t))
      (defcommand (toggle-container-direction) "Turn the selected container, or the selected view's, between horizontal and vertical."
        (check-effective! self)
        (reshape-selected-container! self #f))
      (keymap-set "C-x t 2" 'tab-new)
      (keymap-set "C-x t o" 'tab-next)
      (keymap-set "C-x t O" 'tab-previous)
      (keymap-set "C-x t 0" 'tab-close)
      (keymap-set "<tab-line> <mouse-1>" 'tab-select)
      (keymap-set "C-x n i" 'frame-zoom-in)
      (keymap-set "C-x n o" 'frame-zoom-out)
      (keymap-set "C-x w a" 'select-parent-part)
      (keymap-set "C-x w c" 'select-child-part)
      (keymap-set "C-x w p" 'pin-part)
      (keymap-set "C-x w u" 'unpin-part)
      (keymap-set "C-x w <left>" 'move-part-left)
      (keymap-set "C-x w <right>" 'move-part-right)
      (keymap-set "C-x w <up>" 'move-part-up)
      (keymap-set "C-x w <down>" 'move-part-down)
      (keymap-set "C-x w t" 'wrap-part-tabbed)
      (keymap-set "C-x w 2" 'wrap-part-vertical)
      (keymap-set "C-x w 3" 'wrap-part-horizontal)
      (keymap-set "C-x w k" 'toggle-container-kind)
      (keymap-set "C-x w d" 'toggle-container-direction)
      (context-provide! ctx layout-service self))))
