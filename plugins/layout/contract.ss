;;; The layout service (live tier; ADR 11, ADR 13): the layout-agnostic
;;; contract that renderers and commands such as `other-view` use, so any
;;; layout plugin can fill the slot.
;;;
;;; The layout arranges views. A view is one place showing one buffer, with
;;; its own point (ADR 6, ADR 13), so two views of one buffer have
;;; independent points. The frame (there is one) is a movable pointer into
;;; the layout: it targets the whole layout, one part of it (a container or
;;; a view, by id), or a node of a view's buffer as that view shows it. The
;;; renderer draws from the frame's target. The frame holds the selected
;;; view, which lies under its target and is the selected view of the
;;; buffers service. Frame marks are named, saved frame targets; they point
;;; at part identities, not paths, so rearranging keeps them valid.
;;;
;;; A layout that cannot show a target (a toy without containers, say)
;;; shows the whole layout instead, and reports that as its target. Hints a
;;; layout does not understand, such as a side for `display-buffer`, are
;;; interpreted its own way or ignored.
;;;
;;; Pins (ADR 13, "Pinning"). A layout that arranges parts in a tree may
;;; pin a part on its link to its container: the part stays drawn when the
;;; frame zooms past it. Drawing walks from the frame's target up to the
;;; top; each container on the way draws only the child the way runs
;;; through and its pinned children, as its kind always draws children, and
;;; the child on the way gets the space the pinned children do not use.
;;; Pins never move anything, and travel with a part when it moves; tree
;;; order decides placement. A part may also be locked: a plugin owns it,
;;; the user can neither unpin nor delete it, and it goes when its buffer
;;; does (`add-locked-view!`). Sizes on links are shares of the space, or
;;; `content`: as big as the part's content. The views drawn are the
;;; visible ones: the selected view is always one of them, and moving
;;; between views visits only them. A layout without pins (a toy) may
;;; ignore them and have no places for locked views.
;;;
;;; Replacing the provider restores views and frame marks from session
;;; data. The old provider's private slot keeps its arrangement for a return.
;;;
;;; Clicks name parts by id (the keys contract's `posn`): a view and its
;;; status line by the view's id. `posn-view` and `posn-node` find the view
;;; and node a click names, or #f once they are gone.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        (only-in :tuna/plugins/keys/contract posn posn-part posn-node-id)
        :tuna/plugins/settings/contract
        :tuna/plugins/buffers/contract)
(export (service-interface-out Layout)
        layout-service
        (struct-out frame-target)
        saved-view-data
        restore-view-data
        view-list
        select-view
        next-view
        set-view-buffer
        split-view
        delete-view
        neighbor-view
        display-buffer
        add-locked-view
        nearest-view
        no-other-view
        view-skipped?
        posn-view
        posn-node
        posn-start-node
        current-frame-target
        move-frame
        frame-mark-names
        set-frame-mark
        jump-to-frame-mark
        render-layout
        replace-buffer-in-views)

;; Neutral session slot `layout`, version 1:
;; ((views (VIEW-ID BUFFER-NAME NODE-ID POINT) ...) (selected VIEW-ID)
;;  (marks (NAME VIEW-ID-OR-#f NODE-ID-OR-#f) ...)).
;; Locked views are rebuilt by their owning plugins. A mark on a container
;; becomes a whole-layout mark (#f); containers are provider-private.
(def (saved-view-data (v : view)) => :list
  [(view-id v) (buffer-name (view-showing v))
   (let (n (view-node v)) (and n (node-id n))) (view-point v)])

(def (saved-node (root : node) (id : :fixnum)) => (Maybe node)
  (if (eqv? (node-id root) id) root
    (ormap (lambda ((child : node)) (saved-node child id)) (node-children root))))

(def (restore-view-data (data : :t)) => (Maybe view)
  (match data
    ([(? fixnum?) (? string? name) node-id (? fixnum? position)]
     (let (b (get-buffer name))
       (and b
            (let* ((root (buffer-root b))
                   (n (or (and (fixnum? node-id) (saved-node root node-id)) root))
                   (v (new-view b)))
              (when (text-node? n)
                (reset-view! v b n 1 (text-chars-revision (text-node-content n))))
              (set-view-point! v position)
              v))))
    (else #f)))

;; Where the frame points: the part of the layout with id PART (a
;; container's id, or a view's `view-id`), or the whole layout when PART is
;; #f; with a view's part, START may be a node of that view's buffer, from
;; which the view is drawn.
(defstruct frame-target ((part  :? :fixnum)
                         (start :? node))
  final: #t)

(service-interface Layout
  ;; Every view of the layout, in order.
  (views) => :list
  (selected-view) => :t
  ;; Select V: it becomes the frame's selected view, and the selected view
  ;; of the buffers service. A V outside the frame's target moves the frame
  ;; up until it holds V.
  (select-view! (v : view)) => :void
  ;; The view after V among the visible views that are not skipped
  ;; (`view-skipped?`), cyclically (`other-view`).
  (next-view (v : view)) => :t
  ;; Show B in V.
  (show-buffer! (v : view) (b : buffer)) => :void
  ;; Split V: a new view of its buffer at its point, 'below or to the
  ;; 'right of V. Returns the new view; V stays selected.
  (split-view! (v : view) (side : :symbol)) => :t
  ;; Remove V from the layout; the layout's last view cannot go.
  (delete-view! (v : view)) => :void
  ;; The visible view next to V toward DIRECTION ('left, 'right, 'up,
  ;; 'down) that is not skipped, or #f.
  (neighbor-view (v : view) (direction : :symbol)) => :t
  ;; Show B somewhere and return the view. HINTS is an alist: (side . S)
  ;; with S one of left, right, top, bottom asks for a view at that side of
  ;; what the frame shows, (size . X) for its share, a number between 0
  ;; and 1, or `content`. A view made only for B is dedicated to it: it
  ;; closes when B is killed. Killing a buffer shows another buffer in its
  ;; other views.
  (display-buffer! (b : buffer) (hints : :list)) => :t
  ;; Show B in a view a plugin owns, pinned and locked at SIDE (left,
  ;; right, top, bottom) of the whole layout, with SIZE (a share between 0
  ;; and 1, or `content`). Such views at one side share one container
  ;; there; at the bottom it is the bar. The view is dedicated, so it goes
  ;; when B is killed, as when its plugin turns off. A view already showing
  ;; B is reused. Returns the view, or #f for a layout without such places.
  (add-locked-view! (b : buffer) (side : :symbol) (size : :t)) => :t
  ;; The view nearest V for which (MATCH? view) holds: V itself, or else,
  ;; walking up from V, the first visible one in a part pinned beside the
  ;; way, in tree order, so one that stays drawn when the frame zooms onto
  ;; V; #f if none. Prompts and messages find their views so: the bar at
  ;; the top serves everything, a minibuffer pinned inside a split serves
  ;; that split.
  (nearest-view (v : view) (match? : :procedure)) => :t
  ;; The frame's target, as a frame-target.
  (current-frame-target) => :t
  ;; Point the frame at TARGET; the selected view moves under it if needed.
  (move-frame! (target : frame-target)) => :void
  ;; Names of the frame marks, oldest first.
  (frame-mark-names) => :list
  ;; Save the frame's target as the frame mark NAME, replacing any other.
  (set-frame-mark! (name : :string)) => :void
  ;; Point the frame at the frame mark NAME's target. Returns 'jumped,
  ;; 'unknown for no such mark, or 'gone when its part no longer exists, in
  ;; which case the mark is dropped.
  (jump-to-frame-mark! (name : :string)) => :symbol
  ;; The layout under the frame's target, for the renderer TARGET.
  ;; RENDER-VIEW receives a view, whether it is selected, and the node of
  ;; its buffer to draw from (the root, or the frame's node), and returns
  ;; the view rendered for TARGET; the layout arranges the results. For
  ;; 'html both are SXML elements. For a target it does not know, the
  ;; result is the list of the views it shows, rendered, in order.
  (render-layout (target : :symbol) (render-view : :procedure)) => :t
)

(def layout-service
  (new-service 'layout is-Layout? tier: 'live
               doc: "Arranges views, each showing a buffer, and the frame that shows them."))

;; Every view, in order (Emacs `window-list`).
(def (view-list) => :list
  (:- (with-service-provider (provider layout-service Layout) (Layout-views provider)) :list))

;; Select V (Emacs `select-window`).
(def (select-view (v : view)) => :void
  (:- (with-service-provider (provider layout-service Layout) (Layout-select-view! provider v)) :void))

(def (next-view (v : view)) => view
  (:- (with-service-provider (provider layout-service Layout) (: (Layout-next-view provider v) view)) view))

;; Show B in V (Emacs `set-window-buffer`).
(def (set-view-buffer (v : view) (b : buffer)) => :void
  (:- (with-service-provider (provider layout-service Layout) (Layout-show-buffer! provider v b)) :void))

;; Split V 'below or to the 'right; returns the new view (Emacs
;; `split-window-below`, `split-window-right`).
(def (split-view (v : view) (side : :symbol)) => view
  (:- (with-service-provider (provider layout-service Layout)
    (unless (memq side '(below right))
      (error "Split below or right, not" side))
    (: (Layout-split-view! provider v side) view)) view))

;; Remove V (Emacs `delete-window`).
(def (delete-view (v : view)) => :void
  (:- (with-service-provider (provider layout-service Layout) (Layout-delete-view! provider v)) :void))

;; The view toward DIRECTION from V, or #f (Emacs `window-in-direction`).
(def (neighbor-view (v : view) (direction : :symbol)) => (Maybe view)
  (:? (with-service-provider (provider layout-service Layout)
    (unless (memq direction '(left right up down))
      (error "Look left, right, up, or down, not" direction))
    (Layout-neighbor-view provider v direction)) view))

;; A size between 0 and 1, or `content`.
(def (check-size (size : :t)) => :void
  (unless (or (eq? size 'content) (and (real? size) (< 0 size 1)))
    (error "A size between 0 and 1, or content, not" size)))

;; Show B and return its view (Emacs `display-buffer`):
;;   (display-buffer b side: 'left size: 1/5)
(def (display-buffer (b : buffer)
                     side: (side :? :symbol := #f)
                     size: (size :? :t := #f))
  => view
  (:- (with-service-provider (provider layout-service Layout)
    (when (and side (not (memq side '(left right top bottom))))
      (error "Display at the left, right, top, or bottom, not" side))
    (when size
      (check-size size))
    (: (Layout-display-buffer! provider b
                               (append (if side [(cons 'side side)] [])
                                       (if size [(cons 'size size)] [])))
       view)) view))

;; Show B in a plugin's locked, pinned view at SIDE of the whole layout,
;; or return #f when the layout has no such places:
;;   (add-locked-view b side: 'bottom size: 'content)
(def (add-locked-view (b : buffer)
                      side: (side : :symbol := 'bottom)
                      size: (size : :t := 'content))
  => (Maybe view)
  (:? (with-service-provider (provider layout-service Layout)
    (unless (memq side '(left right top bottom))
      (error "Lock a view at the left, right, top, or bottom, not" side))
    (check-size size)
    (Layout-add-locked-view! provider b side size)) view))

;; The visible view nearest V for which (MATCH? view) holds, or #f.
(def (nearest-view (v : view) (match? : :procedure)) => (Maybe view)
  (:? (with-service-provider (provider layout-service Layout) (Layout-nearest-view provider v match?)) view))

;; Emacs's `no-other-window`, for a buffer rather than a window.
(defsetting no-other-view #f
  "Whether moving between views (other-view, the S-arrows) skips views of this buffer.")

;; Whether moving between views skips V: its buffer's no-other-view.
(def (view-skipped? (v : view)) => :boolean
  (and (buffer-local-value no-other-view (view-showing v)) #t))

;; The view whose id P names: the view clicked, or the one whose status
;; line or tab was clicked; #f when no view has that id, because it is gone
;; or the part is a container (Emacs `posn-window`).
(def (posn-view (p : posn)) => (Maybe view)
  (let (id (posn-part p))
    (find (lambda ((v : view)) (fx= (view-id v) id)) (view-list))))

;; The node clicked, in the buffer its view shows, or #f when the click
;; named no node or it is no longer there (Emacs `posn-point`, for nodes).
(def (posn-node (p : posn)) => (Maybe node)
  (let ((v (posn-view p))
        (id (posn-node-id p)))
    (and v id
         (let find-node ((n (buffer-root (view-showing v))))
           (if (fx= (node-id n) id)
             n
             (ormap find-node (node-children n)))))))

;; The node where click keymap lookup begins, falling back to the view's root.
(def (posn-start-node (p : posn)) => (Maybe node)
  (or (posn-node p)
      (let (v (posn-view p))
        (and v (buffer-root (view-showing v))))))

(def (current-frame-target) => frame-target
  (:- (with-service-provider (provider layout-service Layout) (: (Layout-current-frame-target provider) frame-target)) frame-target))

(def (move-frame (target : frame-target)) => :void
  (:- (with-service-provider (provider layout-service Layout) (Layout-move-frame! provider target)) :void))

(def (frame-mark-names) => :list
  (:- (with-service-provider (provider layout-service Layout) (Layout-frame-mark-names provider)) :list))

(def (set-frame-mark (name : :string)) => :void
  (:- (with-service-provider (provider layout-service Layout) (Layout-set-frame-mark! provider name)) :void))

;; 'jumped, 'unknown, or 'gone (the mark is dropped).
(def (jump-to-frame-mark (name : :string)) => :symbol
  (:- (with-service-provider (provider layout-service Layout) (Layout-jump-to-frame-mark! provider name)) :symbol))

(def (render-layout (target : :symbol) (render-view : :procedure)) => :t
  (with-service-provider (provider layout-service Layout) (Layout-render-layout provider target render-view)))

;; For layouts, on `kill-buffer-hook`: show another buffer in each of VIEWS
;; that shows B.
(def (replace-buffer-in-views (views : :list) (b : buffer)) => :void
  (for-each (lambda ((v : view))
              (when (eq? (view-showing v) b)
                (let (other (other-buffer b))
                  (when other
                    (set-view-showing! v other)))))
            views))
