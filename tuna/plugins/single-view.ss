;;; The one-view layout (live tier): one view fills the frame. At first it
;;; is the selected view; taking over several views from another layout, it
;;; keeps the selected one.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        :tuna/services/buffers
        :tuna/services/session
        :tuna/services/layout)
(export single-view-plugin)

(defclass single-view ((only : view))           ; the one view
  final: #t)

(def (check-own-view (self : single-view) (v : view)) => :void
  (unless (eq? v self.only)
    (error "Not a view of this frame" (view-id v))))

(implement Layout single-view
  (views (lambda (self) [self.only]))
  (selected-view (lambda (self) self.only))
  (select-view! (lambda (self v)
                  (check-own-view self v)
                  (set-selected-view! v)))
  (next-view (lambda (self v) self.only))
  (show-buffer! (lambda (self v b)
                  (check-own-view self v)
                  (set-view-showing! v b)))
  (render-layout (lambda (self target render-view)
                   (let (rendered (render-view self.only #t))
                     (case target
                       ((html) `(div (@ (class "layout")) ,rendered))
                       (else [rendered])))))
  (describe-views (lambda (self) (make-layout-description [self.only] self.only)))
  (adopt-views! (lambda (self description)
                  (let (v (layout-description-selected description))
                    (set! self.only v)
                    (set-selected-view! v)))))

(defplugin (single-view-plugin ctx)
  "Arranges views: one view fills the frame."
  requires: [buffers-service session-service]
  (using (self (single-view only: (selected-view)) : single-view)
    (context-add-hook! ctx kill-buffer-hook 'replace-buffer-in-views
                       (lambda (b) (replace-buffer-in-views [self.only] b)))
    (context-add-layout-session-slot! ctx (Layout self))
    (context-provide! ctx layout-service (Layout self))))
