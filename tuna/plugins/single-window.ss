;;; The default window manager (live tier): one window fills the frame. At
;;; first it shows the selected view; taking over several windows from
;;; another window manager, it keeps the selected one.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        :tuna/services/buffers
        :tuna/services/windows)
(export single-window-plugin)

(defclass single-window ((only : window))       ; the one window
  final: #t)

(def (check-own-window (self : single-window) (w : window)) => :void
  (unless (eq? w self.only)
    (error "Not a window of this frame" (window-id w))))

(implement WindowManager single-window
  (windows (lambda (self) [self.only]))
  (selected-window (lambda (self) self.only))
  (select-window! (lambda (self w)
                    (check-own-window self w)
                    (select-view! (window-view w))))
  (next-window (lambda (self w) self.only))
  (show-buffer! (lambda (self w b)
                  (check-own-window self w)
                  (set-view-buffer! (window-view w) b)))
  (render-window-area (lambda (self target render-window)
                        (let (rendered (render-window self.only #t))
                          (case target
                            ((html) `(div (@ (class "windows")) ,rendered))
                            (else [rendered])))))
  (describe-windows (lambda (self) (make-window-description [self.only] self.only)))
  (adopt-windows! (lambda (self description)
                    (let (w (window-description-selected description))
                      (set! self.only w)
                      (select-view! (window-view w))))))

(defplugin (single-window-plugin ctx)
  "Manages windows: one window fills the frame."
  requires: [buffers-service]
  (using (self (single-window only: (new-window (selected-view))) : single-window)
    (context-add-hook! ctx kill-buffer-hook 'replace-buffer-in-windows
                       (lambda (b) (replace-buffer-in-windows [self.only] b)))
    (context-add-windows-session-slot! ctx (WindowManager self))
    (context-provide! ctx window-manager-service (WindowManager self))))
