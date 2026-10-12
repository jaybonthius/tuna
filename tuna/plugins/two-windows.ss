;;; The toy window manager (live tier): two windows side by side, each with
;;; its own view, so each has its own point even on the same buffer. It
;;; proves the window-manager slot can be swapped while Tuna runs (ADR 11,
;;; ADR 12). Taking over one window, it adds a second on the same buffer at
;;; the same point, as splitting a window does; taking over more, it keeps
;;; the selected window and one neighbor.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        :tuna/services/buffers
        :tuna/services/windows)
(export two-windows-plugin)

(defclass two-windows ((left     : window)
                       (right    : window)
                       (selected : window))
  final: #t)

(def (own-windows (self : two-windows)) => :list
  [self.left self.right])

(def (check-own-window (self : two-windows) (w : window)) => :void
  (unless (memq w (own-windows self))
    (error "Not a window of this frame" (window-id w))))

;; The two windows to keep of WINDOWS, in their order, with SELECTED among
;; them.
(def (two-of (windows : :list) (selected : window)) => :list
  (match windows
    ([_] [selected (new-window (copy-view (window-view selected)))])
    ([first second . _]
     (if (memq selected [first second])
       [first second]
       [first selected]))))

(implement WindowManager two-windows
  (windows (lambda (self) (own-windows self)))
  (selected-window (lambda (self) self.selected))
  (select-window! (lambda (self w)
                    (check-own-window self w)
                    (set! self.selected w)
                    (select-view! (window-view w))))
  (next-window (lambda (self w)
                 (check-own-window self w)
                 (if (eq? w self.left) self.right self.left)))
  (show-buffer! (lambda (self w b)
                  (check-own-window self w)
                  (set-view-buffer! (window-view w) b)))
  (render-window-area (lambda (self target render-window)
                        (let (rendered (map (lambda (w) (render-window w (eq? w self.selected)))
                                            (own-windows self)))
                          (case target
                            ((html) `(div (@ (class "windows")) ,@rendered))
                            (else rendered)))))
  (describe-windows (lambda (self) (make-window-description (own-windows self) self.selected)))
  (adopt-windows! (lambda (self description)
                    (let* ((selected (window-description-selected description))
                           (kept (two-of (window-description-windows description) selected)))
                      (set! self.left (car kept))
                      (set! self.right (cadr kept))
                      (set! self.selected selected)
                      (select-view! (window-view selected))))))

(defplugin (two-windows-plugin ctx)
  "Manages windows: two side by side (a toy). Outranks the default window manager while active."
  requires: [buffers-service]
  (let* ((left (new-window (selected-view)))
         (right (new-window (copy-view (selected-view)))))
    (using (self (two-windows left: left right: right selected: left) : two-windows)
      (context-add-hook! ctx kill-buffer-hook 'replace-buffer-in-windows
                         (lambda (b) (replace-buffer-in-windows (own-windows self) b)))
      (context-add-windows-session-slot! ctx (WindowManager self) priority: 10)
      (context-provide! ctx window-manager-service (WindowManager self) priority: 10))))
