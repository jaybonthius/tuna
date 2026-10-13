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
;;; Replacing the provider hands the views over through a neutral
;;; description: the views in order and the selected one. Arrangement,
;;; frame and frame marks belong to each layout.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        :tuna/services/buffers)
(export (interface-out Layout)
        layout-service
        (struct-out layout-description frame-target)
        view-list
        select-view
        next-view
        set-view-buffer
        split-view
        delete-view
        neighbor-view
        display-buffer
        current-frame-target
        move-frame
        frame-mark-names
        set-frame-mark
        jump-to-frame-mark
        render-layout
        replace-buffer-in-views)

;; What one layout hands the next: its views in order and the selected
;; one, which is one of them.
(defstruct layout-description ((views    : :list)
                               (selected : view))
  final: #t)

;; Where the frame points: the part of the layout with id PART (a
;; container's id, or a view's `view-id`), or the whole layout when PART is
;; #f; with a view's part, START may be a node of that view's buffer, from
;; which the view is drawn.
(defstruct frame-target ((part  :? :fixnum)
                         (start :? node))
  final: #t)

(interface Layout
  ;; Every view of the layout, in order.
  (views) => :list
  (selected-view) => :t
  ;; Select V: it becomes the frame's selected view, and the selected view
  ;; of the buffers service. A V outside the frame's target moves the frame
  ;; up until it holds V.
  (select-view! (v : view)) => :void
  ;; The view after V among those the frame shows, cyclically (`other-view`).
  (next-view (v : view)) => :t
  ;; Show B in V.
  (show-buffer! (v : view) (b : buffer)) => :void
  ;; Split V: a new view of its buffer at its point, 'below or to the
  ;; 'right of V. Returns the new view; V stays selected.
  (split-view! (v : view) (side : :symbol)) => :t
  ;; Remove V from the layout; the layout's last view cannot go.
  (delete-view! (v : view)) => :void
  ;; The view next to V that the frame shows, toward DIRECTION ('left,
  ;; 'right, 'up, 'down), or #f.
  (neighbor-view (v : view) (direction : :symbol)) => :t
  ;; Show B somewhere and return the view. HINTS is an alist: (side . S)
  ;; with S one of left, right, top, bottom asks for a view at that side of
  ;; what the frame shows, (size . X) for its share, a number between 0
  ;; and 1. A view made only for B is dedicated to it: it closes when B is
  ;; killed. Killing a buffer shows another buffer in its other views.
  (display-buffer! (b : buffer) (hints : :list)) => :t
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
  ;; The neutral description of the layout's views.
  (describe-views) => :t
  ;; Take over the views of DESCRIPTION, arranged in this layout's own way,
  ;; and select its selected view.
  (adopt-views! (description : layout-description)) => :void)

(def layout-service
  (new-service 'layout is-Layout? tier: 'live
               doc: "Arranges views, each showing a buffer, and the frame that shows them."
               handover: (lambda (outgoing incoming)
                           (Layout-adopt-views!
                            (Layout incoming)
                            (Layout-describe-views (Layout outgoing))))))

(def (current-layout) => Layout
  (let (provider (service-provider layout-service))
    (unless provider
      (error "No plugin provides the layout"))
    (Layout provider)))

;; Every view, in order (Emacs `window-list`).
(def (view-list) => :list
  (Layout-views (current-layout)))

;; Select V (Emacs `select-window`).
(def (select-view (v : view)) => :void
  (Layout-select-view! (current-layout) v))

(def (next-view (v : view)) => view
  (: (Layout-next-view (current-layout) v) view))

;; Show B in V (Emacs `set-window-buffer`).
(def (set-view-buffer (v : view) (b : buffer)) => :void
  (Layout-show-buffer! (current-layout) v b))

;; Split V 'below or to the 'right; returns the new view (Emacs
;; `split-window-below`, `split-window-right`).
(def (split-view (v : view) (side : :symbol)) => view
  (unless (memq side '(below right))
    (error "Split below or right, not" side))
  (: (Layout-split-view! (current-layout) v side) view))

;; Remove V (Emacs `delete-window`).
(def (delete-view (v : view)) => :void
  (Layout-delete-view! (current-layout) v))

;; The view toward DIRECTION from V, or #f (Emacs `window-in-direction`).
(def (neighbor-view (v : view) (direction : :symbol)) => (Maybe view)
  (unless (memq direction '(left right up down))
    (error "Look left, right, up, or down, not" direction))
  (Layout-neighbor-view (current-layout) v direction))

;; Show B and return its view (Emacs `display-buffer`):
;;   (display-buffer b side: 'left size: 1/5)
(def (display-buffer (b : buffer)
                     side: (side :? :symbol := #f)
                     size: (size :? :real := #f))
  => view
  (when (and side (not (memq side '(left right top bottom))))
    (error "Display at the left, right, top, or bottom, not" side))
  (when (and size (not (< 0 size 1)))
    (error "Display with a size between 0 and 1, not" size))
  (: (Layout-display-buffer! (current-layout) b
                             (append (if side [(cons 'side side)] [])
                                     (if size [(cons 'size size)] [])))
     view))

(def (current-frame-target) => frame-target
  (: (Layout-current-frame-target (current-layout)) frame-target))

(def (move-frame (target : frame-target)) => :void
  (Layout-move-frame! (current-layout) target))

(def (frame-mark-names) => :list
  (Layout-frame-mark-names (current-layout)))

(def (set-frame-mark (name : :string)) => :void
  (Layout-set-frame-mark! (current-layout) name))

;; 'jumped, 'unknown, or 'gone (the mark is dropped).
(def (jump-to-frame-mark (name : :string)) => :symbol
  (Layout-jump-to-frame-mark! (current-layout) name))

(def (render-layout (target : :symbol) (render-view : :procedure)) => :t
  (Layout-render-layout (current-layout) target render-view))

;; For layouts, on `kill-buffer-hook`: show another buffer in each of VIEWS
;; that shows B.
(def (replace-buffer-in-views (views : :list) (b : buffer)) => :void
  (for-each (lambda ((v : view))
              (when (eq? (view-showing v) b)
                (let (other (other-buffer b))
                  (when other
                    (set-view-showing! v other)))))
            views))
