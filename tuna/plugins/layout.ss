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
;;; The plugin adapts to a new buffers provider instead of restarting: it
;;; re-points its views by buffer name and node id, which the buffers
;;; handover keeps. Its session slot `layout` holds the tree, the frame and
;;; the frame marks as plain data; restoring skips views of missing
;;; buffers, and is skipped when the layout took views over from another
;;; layout, so a saved slot never overwrites a live handover.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        :tuna/services/keys
        :tuna/services/buffers
        :tuna/services/session
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

(defclass tree-layout ((root         : :t)           ; the tree's root part
                       (frame        : frame-state)
                       (marks        : :list)        ; frame marks, oldest first
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
;; the active child, which is the one last focused.
(def (render-tabbed (c : container) (render-link : :procedure) (label : :procedure)) => :list
  (let (active (focused-link c))
    `(div ,(container-attributes c "tabbed")
          (ul (@ (class "tabs") (role "tablist")
                 (aria-orientation ,(symbol->string (container-direction c))))
              ,@(map (lambda ((l : link))
                       `(li (@ (class "tab") (role "tab")
                               (aria-selected ,(if (eq? l active) "true" "false")))
                            ,(label l.part)))
                     (container-links c)))
          (div (@ (class "tab-panel") (role "tabpanel")) ,(render-link active)))))

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

;; Keep the selected view under the frame's target (else take the target's
;; focused view), focus memory pointing at it, and the buffers service's
;; selected view the same.
(def (settle-selection! (self : tree-layout)) => :void
  (let* ((f self.frame)
         (v (if (under? self (frame-state-selected f))
              (frame-state-selected f)
              (leaf-view (focused-leaf (frame-top self))))))
    (set! self.root (select-path self.root (view-id v)))
    (unless (eq? v (frame-state-selected f))
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

(def (point-frame! (self : tree-layout) (part :? :fixnum) (start :? node)) => :void
  (set! self.frame (make-frame-state (normal-part self.root part start) start (frame-state-selected self.frame)))
  (settle-selection! self))

(def (own-leaf (self : tree-layout) (v : view)) => leaf
  (let (p (find-part self.root (view-id v)))
    (unless (leaf? p)
      (error "Not a view of this layout" (view-id v)))
    p))

;; Select V; a V outside the frame's target moves the frame up to hold it.
(def (select! (self : tree-layout) (v : view)) => :void
  (own-leaf self v)
  (let (f self.frame)
    (set! self.frame
      (if (under? self v)
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

;; display-buffer: a view under the frame already showing B; with a side,
;; a new dedicated view at that side of what the frame shows; else another
;; view the frame shows that is neither selected nor dedicated; else a new
;; dedicated view below the selected one.
(def (display-in! (self : tree-layout) (b : buffer) (hints : :list)) => view
  (let* ((side (hint hints 'side))
         (shown (visible-leaves (frame-top self) (kind-of self)))
         (showing (find (lambda ((l : leaf)) (eq? (view-showing (leaf-view l)) b)) shown)))
    (cond
     (showing (leaf-view showing))
     ((memq side '(left right top bottom))
      (let* ((v (new-view b))
             (size (or (hint hints 'size) 1/4))
             (top (frame-top self))
             (side-link (make-link size (make-leaf v #t)))
             (rest-link (make-link (- 1 size) top))
             (c (make-container (next-id!) 'fit
                                (if (memq side '(left right)) 'horizontal 'vertical)
                                (if (memq side '(left top)) [side-link rest-link] [rest-link side-link])
                                (part-id top))))
        (commit-around! self (part-id top) (replace-part self.root (part-id top) c (kind-of self)))
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

;; On kill-buffer-hook: dedicated views of B close (the last view stays);
;; other views of B show another buffer.
(def (buffer-killed! (self : tree-layout) (b : buffer)) => :void
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

;;; Rendering

;; "--tuna-size: W": a link's size, as CSS reads it.
(def (size-property (size : :real)) => :string
  (let (x (exact->inexact size))
    (string-append "--tuna-size: "
                   (if (integer? x) (number->string (inexact->exact x)) (number->string x)))))

(def (with-attribute (element : :t) (attribute : :list)) => :t
  (match element
    ([tag ['@ . attributes] . body] (cons* tag (cons '@ (append attributes [attribute])) body))
    ([tag . body] (cons* tag ['@ attribute] body))
    (else element)))

;; The part P for 'html. A leaf is drawn from START when given.
(def (render-html (self : tree-layout) (p : :t) (start :? node) (render-view : :procedure)) => :t
  (let ((selected (frame-state-selected self.frame))
        (kind-of (kind-of self)))
    (let render ((p p))
      (if (leaf? p)
        (let (v (leaf-view p))
          (render-view v (eq? v selected) (or start (buffer-root (view-showing v)))))
        ((layout-kind-render (kind-of (container-kind p)))
         p
         (lambda ((l : link)) (with-attribute (render l.part) ['style (size-property l.size)]))
         (lambda (part) (buffer-name (view-showing (leaf-view (focused-leaf part))))))))))

;;; Session data:
;;;   ((tree PART)
;;;    (frame PART-ID NODE-ID SELECTED-VIEW-ID)
;;;    (marks (NAME PART-ID NODE-ID) ...))
;;; PART is (view ID BUFFER-NAME POINT DEDICATED?) or
;;; (container ID KIND DIRECTION FOCUS-ID ((SIZE PART) ...)). Ids are
;;; renumbered on restore; PART-ID #f is the whole layout.

(def (part->data (p : :t)) => :list
  (if (leaf? p)
    (let (v (leaf-view p))
      ['view (view-id v) (buffer-name (view-showing v)) (view-point v) (leaf-dedicated? p)])
    ['container (container-id p) (container-kind p) (container-direction p) (container-focus p)
     (map (lambda ((l : link)) [l.size (part->data l.part)]) (container-links p))]))

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
    (['container (? fixnum? id) (? symbol? kind) (? symbol? direction) (? fixnum? focus) (? list? links)]
     (and (memq direction '(horizontal vertical))
          (let* ((new-id (fresh-id! ids id))
                 (links (filter-map (lambda (entry)
                                      (match entry
                                        ([(? real? size) part]
                                         (and (> size 0)
                                              (let (p (data->part part ids kind-of))
                                                (and p (make-link size p)))))
                                        (else #f)))
                                    links)))
            (cond
             ((null? links) #f)
             ((and (null? (cdr links))
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
                               (find-part top (hash-get ids selected)))))
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
             (settle-selection! self)))))
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
    (let up ((ancestors (cdr (reverse path))) (child (last path)))
      (match ancestors
        ([] #f)
        ([c . more] (if (eq? (container-kind c) 'tabbed) (cons c child) (up more c)))))))

;; A new tab showing the selected view's buffer at its point, after the
;; current tab; outside tabs, the selected view becomes the first tab.
(def (new-tab! (self : tree-layout)) => :void
  (let* ((v (frame-state-selected self.frame))
         (new (make-leaf (copy-view v) #f))
         (tabs (enclosing-tabs self)))
    (if tabs
      (commit! self (insert-link-after self.root (container-id (car tabs)) (part-id (cdr tabs))
                                       (make-link 1 new) (kind-of self)))
      (commit-around! self (view-id v)
                      (replace-part self.root (view-id v)
                                    (make-container (next-id!) 'tabbed 'horizontal
                                                    [(make-link 1 (own-leaf self v)) (make-link 1 new)]
                                                    (view-id v))
                                    (kind-of self))))
    (select! self (leaf-view new))))

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

(def (close-tab! (self : tree-layout)) => :void
  (let (tabs (enclosing-tabs self))
    (if (not tabs)
      (message "No tabs here")
      (let (going (if (null? (cdr (container-links (car tabs)))) (car tabs) (cdr tabs)))
        (if (fx= (length (part-leaves going)) (length (part-leaves self.root)))
          (message "Cannot close the last view")
          (commit! self (remove-part self.root (part-id going) (kind-of self))))))))

;; Move the frame one level down, toward the selected view.
(def (zoom-in! (self : tree-layout)) => :void
  (let (top (frame-top self))
    (if (leaf? top)
      (message "The frame is on the selected view")
      (point-frame! self (part-id (child-toward top (view-id (frame-state-selected self.frame)))) #f))))

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

(def (check-effective! (self : tree-layout)) => :void
  (unless (effective? self)
    (error "This command needs the default layout, which another layout outranks")))

(implement Layout tree-layout
  (views (lambda (self) (map leaf-view (part-leaves self.root))))
  (selected-view (lambda (self) (frame-state-selected self.frame)))
  (select-view! (lambda (self v) (select! self v)))
  (next-view (lambda (self v)
               (let* ((shown (map leaf-view (visible-leaves (frame-top self) (kind-of self))))
                      (tail (memq v shown)))
                 (if (and tail (pair? (cdr tail)))
                   (cadr tail)
                   (car shown)))))
  (show-buffer! (lambda (self v b)
                  (let (l (own-leaf self v))
                    (set-view-showing! v b)
                    (when (leaf-dedicated? l)
                      (commit! self (replace-part self.root (view-id v) (make-leaf v #f) (kind-of self)))))))
  (split-view! (lambda (self v side)
                 (own-leaf self v)
                 (let (new (copy-view v))
                   (split! self v (make-leaf new #f) (if (eq? side 'right) 'horizontal 'vertical))
                   new)))
  (delete-view! (lambda (self v)
                  (own-leaf self v)
                  (when (null? (cdr (part-leaves self.root)))
                    (error "Cannot delete the only view"))
                  (commit! self (remove-part self.root (view-id v) (kind-of self)))))
  (neighbor-view (lambda (self v direction)
                   (and (under? self v)
                        (let (l (neighbor-leaf (frame-top self) (view-id v)
                                               (if (memq direction '(left right)) 'horizontal 'vertical)
                                               (and (memq direction '(right down)) #t)
                                               (kind-of self)))
                          (and l (leaf-view l))))))
  (display-buffer! (lambda (self b hints) (display-in! self b hints)))
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
                       ((html) `(div (@ (class "layout")) ,(render-html self top start render-view)))
                       (else
                        (map (lambda ((l : leaf))
                               (let (v (leaf-view l))
                                 (render-view v (eq? v selected)
                                              (or (and (eq? l top) start) (buffer-root (view-showing v))))))
                             (visible-leaves top (kind-of self))))))))
  (describe-views (lambda (self)
                    (make-layout-description (map leaf-view (part-leaves self.root))
                                             (frame-state-selected self.frame))))
  (adopt-views! (lambda (self description) (adopt! self description))))

(defplugin (layout-plugin ctx)
  "Arranges views in fit and tabbed containers, with a movable frame and frame marks."
  requires: [buffers-service session-service input-service]
  (let (v (selected-view))
    (using (self (tree-layout root: (make-leaf v #f) frame: (make-frame-state #f #f v) marks: []
                              kinds: (new-entry-table) handed-over?: #f)
                 : tree-layout)
      (context-add-entry! ctx self.kinds 'fit fit-kind doc: (layout-kind-doc fit-kind))
      (context-add-entry! ctx self.kinds 'tabbed tabbed-kind doc: (layout-kind-doc tabbed-kind))
      (context-add-hook! ctx kill-buffer-hook 'layout (lambda (b) (buffer-killed! self b)))
      (context-adapt! ctx buffers-service (lambda (old new) (adapt-to-buffers! self old new)))
      (context-add-session-slot! ctx 'layout
                                 version: 2
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
      (defcommand (frame-zoom-in) "Move the frame one level down, toward the selected view."
        (check-effective! self)
        (zoom-in! self))
      (defcommand (frame-zoom-out) "Move the frame one level up."
        (check-effective! self)
        (zoom-out! self))
      (keymap-set "C-x t 2" 'tab-new)
      (keymap-set "C-x t o" 'tab-next)
      (keymap-set "C-x t O" 'tab-previous)
      (keymap-set "C-x t 0" 'tab-close)
      (keymap-set "C-x n i" 'frame-zoom-in)
      (keymap-set "C-x n o" 'frame-zoom-out)
      (context-provide! ctx layout-service self))))
