;;; The toy layout (live tier): two views side by side, each with its own
;;; point even on the same buffer. It proves the layout slot can be swapped
;;; while Tuna runs (ADR 11, ADR 12, ADR 13), and implements the rest of
;;; the contract minimally: it cannot split or delete views, ignores
;;; display-buffer's hints, and its frame always shows the whole layout,
;;; the contract's fallback, so its frame marks all point there. It saves
;;; its own private slot, or the neutral layout slot on its first use.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/session/contract
        :tuna/plugins/stylesheets/contract)
(export two-views)

(defclass two-view-layout ((left     : view)
                     (right    : view)
                     (selected : view)
                     (marks    : :list)      ; frame mark names, oldest first
                     (generation : :fixnum)) ; new from next-id! when it selects or restores
  final: #t)

(def (own-views (self : two-view-layout)) => :list
  [self.left self.right])

(def (check-own-view (self : two-view-layout) (v : view)) => :void
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

(implement Layout two-view-layout
  (views (lambda (self) (own-views self)))
  (selected-view (lambda (self) self.selected))
  (select-view! (lambda (self v)
                  (check-own-view self v)
                  (set! self.selected v)
                  (set! self.generation (next-id!))
                  (layout-changed!)
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
  (add-locked-view! (lambda (self b side size) #f))
  (nearest-view (lambda (self v match?)
                  (check-own-view self v)
                  (find match? (if (eq? v self.left) [self.left self.right] [self.right self.left]))))
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
  (generation (lambda (self) self.generation))
)

(def (saved-layout (self : two-view-layout)) => :list
  [(cons 'views (map saved-view-data (own-views self)))
   ['selected (view-id self.selected)]
   (cons 'marks (map (lambda (name) [name #f #f]) self.marks))])

(def (restore-layout! (self : two-view-layout) (data : :t)) => :void
  (match data
    ([['views . saved] ['selected selected] ['marks . marks]]
     (let (pairs (filter-map (lambda (d) (let (v (restore-view-data d)) (and v (cons (car d) v)))) saved))
       (when (pair? pairs)
         (let* ((selected (cond ((assv selected pairs) => cdr) (else (cdar pairs))))
                (kept (two-of (map cdr pairs) selected)))
           (set! self.left (car kept))
           (set! self.right (cadr kept))
           (set! self.selected selected)
           (set! self.marks (filter-map (lambda (m) (and (pair? m) (string? (car m)) (car m))) marks))
           (set! self.generation (next-id!))
           (layout-changed!)
           (set-selected-view! selected)))))
    (else (void))))

(defplugin (two-views ctx)
  "Arranges views: two side by side (a toy). Selected instead of the default layout."
  provides: [layout-service]
  requires: [buffers-service session-service]
  optional: [input-service]
  (add-stylesheet 'rules "two-views.css")
  (let* ((left (selected-view))
         (right (copy-view left)))
    (using (self (two-view-layout left: left right: right selected: left marks: [] generation: (next-id!))
                 : two-view-layout)
      (layout-changed!)
      (context-defer! ctx layout-changed!)
      (let (input (service-provider input-service))
        (when (and input (is-Keys? input))
          (context-set-click-resolver! ctx posn-start-node)))
      (context-add-hook! ctx kill-buffer-hook 'replace-buffer-in-views
                         (lambda (b) (replace-buffer-in-views (own-views self) b)))
      (context-add-session-slot! ctx 'layout version: 2 save: (lambda () (saved-layout self)) restore: void)
      (context-add-session-slot! ctx 'layout-two-views version: 2 fallback: 'layout
                                 save: (lambda () (saved-layout self))
                                 restore: (lambda (data) (restore-layout! self data)))
      (context-provide! ctx layout-service (Layout self)))))
