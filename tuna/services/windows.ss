;;; The window manager service (live tier; ADR 11): the small,
;;; layout-agnostic window contract that renderers and commands such as
;;; `other-window` use, so any window manager can fill the slot.
;;;
;;; A window is a place that shows one view (ADR 6); views own point, so two
;;; windows on one buffer have independent points. The frame (there is one)
;;; has windows in an order and a selected window, whose view is the
;;; selected view of the buffers service.
;;;
;;; Replacing the provider hands the windows over through a neutral
;;; description: the windows in order, each with its view, and the selected
;;; one. Session slots save the same description as plain data.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        :tuna/services/buffers
        :tuna/services/session)
(export (interface-out WindowManager)
        window-manager-service
        window window? new-window window-id window-view
        (struct-out window-description)
        window-list
        selected-window
        select-window
        next-window
        set-window-buffer
        render-window-area
        replace-buffer-in-windows
        window-description->data
        data->window-description
        context-add-windows-session-slot!)

(defclass window ((id    : :fixnum)
                  (shows : view))
  final: #t)

(def (new-window (v : view)) => window
  (window id: (next-id!) shows: v))

;; The view W shows; it stays W's for W's life.
(def (window-view (w : window)) => view
  w.shows)

;; What one window manager hands the next: the frame's windows in order and
;; the selected one, which is one of them.
(defstruct window-description ((windows  : :list)
                               (selected : window))
  final: #t)

(interface WindowManager
  ;; The frame's windows, in order.
  (windows) => :list
  (selected-window) => :t
  ;; Select W: its view becomes the selected view.
  (select-window! (w : window)) => :void
  ;; The window after W in cyclic order (`other-window`).
  (next-window (w : window)) => :t
  ;; Show B in W.
  (show-buffer! (w : window) (b : buffer)) => :void
  ;; The frame's window area for the renderer TARGET. RENDER-WINDOW receives
  ;; a window and whether it is selected, and returns the window rendered
  ;; for TARGET; the window manager arranges the results. For 'html both
  ;; are SXML elements. For a target it does not know, the result is the
  ;; list of rendered windows, in order.
  (render-window-area (target : :symbol) (render-window : :procedure)) => :t
  ;; The neutral description of the frame's windows.
  (describe-windows) => :t
  ;; Take over the windows of DESCRIPTION, arranged in this window manager's
  ;; own way, and select its selected window.
  (adopt-windows! (description : window-description)) => :void)

(def window-manager-service
  (new-service 'window-manager is-WindowManager? tier: 'live
               doc: "Arranges the frame's windows, each showing a view."
               handover: (lambda (outgoing incoming)
                           (WindowManager-adopt-windows!
                            (WindowManager incoming)
                            (WindowManager-describe-windows (WindowManager outgoing))))))

(def (current-window-manager) => WindowManager
  (let (provider (service-provider window-manager-service))
    (unless provider
      (error "No plugin manages windows"))
    (WindowManager provider)))

(def (window-list) => :list
  (WindowManager-windows (current-window-manager)))

(def (selected-window) => window
  (: (WindowManager-selected-window (current-window-manager)) window))

(def (select-window (w : window)) => :void
  (WindowManager-select-window! (current-window-manager) w))

(def (next-window (w : window)) => window
  (: (WindowManager-next-window (current-window-manager) w) window))

;; Show B in W (Emacs `set-window-buffer`).
(def (set-window-buffer (w : window) (b : buffer)) => :void
  (WindowManager-show-buffer! (current-window-manager) w b))

(def (render-window-area (target : :symbol) (render-window : :procedure)) => :t
  (WindowManager-render-window-area (current-window-manager) target render-window))

;; For window managers, on `kill-buffer-hook`: show another buffer in each
;; of WINDOWS that shows B.
(def (replace-buffer-in-windows (windows : :list) (b : buffer)) => :void
  (for-each (lambda ((w : window))
              (when (eq? (view-showing w.shows) b)
                (let (other (other-buffer b))
                  (when other
                    (set-view-buffer! w.shows other)))))
            windows))

;;; The description as plain data, for session slots (ADR 5):
;;;   ((selected INDEX) (windows (BUFFER-NAME POINT) ...))

(def (window-description->data (d : window-description)) => :list
  (let (windows (window-description-windows d))
    [['selected (let lp ((rest windows) (index 0))
                  (match rest
                    ([w . more] (if (eq? w (window-description-selected d)) index (lp more (fx1+ index))))
                    ([] 0)))]
     (cons 'windows
           (map (lambda ((w : window))
                  (using (v w.shows : view)
                    [(buffer-name (view-showing v)) (view-point v)]))
                windows))]))

;; A description with new windows and views for DATA, or #f when DATA is
;; malformed or names no existing buffer. Windows on missing buffers are
;; dropped.
(def (data->window-description (data : :t)) => (Maybe window-description)
  (match data
    ([['selected (? fixnum? index)] ['windows . entries]]
     (let (windows (filter-map (lambda (entry)
                                 (match entry
                                   ([(? string? name) (? fixnum? position)]
                                    (let (b (get-buffer name))
                                      (and b
                                           (let (v (new-view b))
                                             (set-view-point! v position)
                                             (new-window v)))))
                                   (else #f)))
                               (if (list? entries) entries [])))
       (and (pair? windows)
            (make-window-description windows
                                     (if (fx< -1 index (length windows))
                                       (list-ref windows index)
                                       (car windows))))))
    (else #f)))

;; Save and restore WM's windows in the session slot `windows`. Alternative
;; window managers share the slot and its neutral format, so a session saved
;; under one restores under another. CTX's plugin requires `session-service`.
(def (context-add-windows-session-slot! (ctx : context) (wm : WindowManager)
                                        priority: (priority : :fixnum := 0))
  => :void
  (context-add-session-slot!
   ctx 'windows
   version: 1
   save: (lambda () (window-description->data (WindowManager-describe-windows wm)))
   restore: (lambda (data)
              (let (d (data->window-description data))
                (when d
                  (WindowManager-adopt-windows! wm d))))
   priority: priority))
