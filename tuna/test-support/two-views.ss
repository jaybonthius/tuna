;;; The toy layout (live tier): two views side by side, each with its own
;;; point even on the same buffer. It proves the layout slot can be swapped
;;; while Tuna runs (ADR 11, ADR 12, ADR 13), and implements the rest of
;;; the contract minimally: it cannot split or delete views, ignores
;;; display-buffer's hints, and its frame always shows the whole layout,
;;; the contract's fallback, so its frame marks all point there. It saves
;;; no session slot. Taking over one view, it adds a second on the same
;;; buffer at the same point, as splitting a view does; taking over more,
;;; it keeps the selected view and one neighbor.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        :tuna/services/buffers
        :tuna/services/layout)
(export two-views-plugin)

(defclass two-views ((left     : view)
                     (right    : view)
                     (selected : view)
                     (marks    : :list))     ; frame mark names, oldest first
  final: #t)

(def (own-views (self : two-views)) => :list
  [self.left self.right])

(def (check-own-view (self : two-views) (v : view)) => :void
  (unless (memq v (own-views self))
    (error "Not a view of this frame" (view-id v))))

;; The two views to keep of VIEWS, in their order, with SELECTED among them.
(def (two-of (views : :list) (selected : view)) => :list
  (match views
    ([_] [selected (copy-view selected)])
    ([first second . _]
     (if (memq selected [first second])
       [first second]
       [first selected]))))

(implement Layout two-views
  (views (lambda (self) (own-views self)))
  (selected-view (lambda (self) self.selected))
  (select-view! (lambda (self v)
                  (check-own-view self v)
                  (set! self.selected v)
                  (set-selected-view! v)))
  (next-view (lambda (self v)
               (check-own-view self v)
               (if (eq? v self.left) self.right self.left)))
  (show-buffer! (lambda (self v b)
                  (check-own-view self v)
                  (set-view-showing! v b)))
  (split-view! (lambda (self v side) (error "The two-view layout cannot split views")))
  (delete-view! (lambda (self v) (error "The two-view layout keeps both views")))
  (neighbor-view (lambda (self v direction)
                   (check-own-view self v)
                   (case direction
                     ((left) (and (eq? v self.right) self.left))
                     ((right) (and (eq? v self.left) self.right))
                     (else #f))))
  (display-buffer! (lambda (self b hints)
                     (or (find (lambda ((v : view)) (eq? (view-showing v) b)) (own-views self))
                         (let (v (if (eq? self.selected self.left) self.right self.left))
                           (set-view-showing! v b)
                           v))))
  (current-frame-target (lambda (self) (make-frame-target #f #f)))
  (move-frame! (lambda (self target) (void)))
  (frame-mark-names (lambda (self) self.marks))
  (set-frame-mark! (lambda (self name)
                     (set! self.marks (append (remove name self.marks) [name]))))
  (jump-to-frame-mark! (lambda (self name) (if (member name self.marks) 'jumped 'unknown)))
  (render-layout (lambda (self target render-view)
                   (let (rendered (map (lambda ((v : view))
                                         (render-view v (eq? v self.selected) (buffer-root (view-showing v))))
                                       (own-views self)))
                     (case target
                       ((html) `(div (@ (class "layout")) ,@rendered))
                       (else rendered)))))
  (describe-views (lambda (self) (make-layout-description (own-views self) self.selected)))
  (adopt-views! (lambda (self description)
                  (let* ((selected (layout-description-selected description))
                         (kept (two-of (layout-description-views description) selected)))
                    (set! self.left (car kept))
                    (set! self.right (cadr kept))
                    (set! self.selected selected)
                    (set-selected-view! selected)))))

(defplugin (two-views-plugin ctx)
  "Arranges views: two side by side (a toy). Outranks the default layout while active."
  requires: [buffers-service]
  (let* ((left (selected-view))
         (right (copy-view left)))
    (using (self (two-views left: left right: right selected: left marks: []) : two-views)
      (context-add-hook! ctx kill-buffer-hook 'replace-buffer-in-views
                         (lambda (b) (replace-buffer-in-views (own-views self) b)))
      (context-provide! ctx layout-service (Layout self) priority: 10))))
