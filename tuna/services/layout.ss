;;; The layout service (live tier; ADR 11, ADR 13): the small,
;;; layout-agnostic contract that renderers and commands such as
;;; `other-view` use, so any layout plugin can fill the slot.
;;;
;;; The layout arranges views. A view is one place showing one buffer, with
;;; its own point (ADR 6, ADR 13), so two views of one buffer have
;;; independent points. The frame (there is one) has views in an order and
;;; a selected view, which is the selected view of the buffers service.
;;;
;;; Replacing the provider hands the views over through a neutral
;;; description: the views in order and the selected one. The session slot
;;; `layout` saves the same description as plain data.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel
        :tuna/services/buffers
        :tuna/services/session)
(export (interface-out Layout)
        layout-service
        (struct-out layout-description)
        view-list
        select-view
        next-view
        set-view-buffer
        render-layout
        replace-buffer-in-views
        layout-description->data
        data->layout-description
        context-add-layout-session-slot!)

;; What one layout hands the next: the frame's views in order and the
;; selected one, which is one of them.
(defstruct layout-description ((views    : :list)
                               (selected : view))
  final: #t)

(interface Layout
  ;; The frame's views, in order.
  (views) => :list
  (selected-view) => :t
  ;; Select V: it becomes the selected view of the buffers service.
  (select-view! (v : view)) => :void
  ;; The view after V in cyclic order (`other-view`).
  (next-view (v : view)) => :t
  ;; Show B in V.
  (show-buffer! (v : view) (b : buffer)) => :void
  ;; The frame's layout for the renderer TARGET. RENDER-VIEW receives a view
  ;; and whether it is selected, and returns the view rendered for TARGET;
  ;; the layout arranges the results. For 'html both are SXML elements. For
  ;; a target it does not know, the result is the list of rendered views,
  ;; in order.
  (render-layout (target : :symbol) (render-view : :procedure)) => :t
  ;; The neutral description of the frame's views.
  (describe-views) => :t
  ;; Take over the views of DESCRIPTION, arranged in this layout's own way,
  ;; and select its selected view.
  (adopt-views! (description : layout-description)) => :void)

(def layout-service
  (new-service 'layout is-Layout? tier: 'live
               doc: "Arranges the frame's views, each showing a buffer."
               handover: (lambda (outgoing incoming)
                           (Layout-adopt-views!
                            (Layout incoming)
                            (Layout-describe-views (Layout outgoing))))))

(def (current-layout) => Layout
  (let (provider (service-provider layout-service))
    (unless provider
      (error "No plugin provides the layout"))
    (Layout provider)))

;; The frame's views, in order (Emacs `window-list`).
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

;;; The description as plain data, for the session slot (ADR 5):
;;;   ((selected INDEX) (views (BUFFER-NAME POINT) ...))

(def (layout-description->data (d : layout-description)) => :list
  (let (views (layout-description-views d))
    [['selected (let lp ((rest views) (index 0))
                  (match rest
                    ([v . more] (if (eq? v (layout-description-selected d)) index (lp more (fx1+ index))))
                    ([] 0)))]
     (cons 'views
           (map (lambda ((v : view))
                  [(buffer-name (view-showing v)) (view-point v)])
                views))]))

;; A description with new views for DATA, or #f when DATA is malformed or
;; names no existing buffer. Views of missing buffers are dropped.
(def (data->layout-description (data : :t)) => (Maybe layout-description)
  (match data
    ([['selected (? fixnum? index)] ['views . entries]]
     (let (views (filter-map (lambda (entry)
                               (match entry
                                 ([(? string? name) (? fixnum? position)]
                                  (let (b (get-buffer name))
                                    (and b
                                         (let (v (new-view b))
                                           (set-view-point! v position)
                                           v))))
                                 (else #f)))
                             (if (list? entries) entries [])))
       (and (pair? views)
            (make-layout-description views
                                     (if (fx< -1 index (length views))
                                       (list-ref views index)
                                       (car views))))))
    (else #f)))

;; Save and restore LAYOUT's views in the session slot `layout`. Alternative
;; layouts share the slot and its neutral format, so a session saved under
;; one restores under another. CTX's plugin requires `session-service`.
(def (context-add-layout-session-slot! (ctx : context) (layout : Layout)
                                       priority: (priority : :fixnum := 0))
  => :void
  (context-add-session-slot!
   ctx 'layout
   version: 1
   save: (lambda () (layout-description->data (Layout-describe-views layout)))
   restore: (lambda (data)
              (let (d (data->layout-description data))
                (when d
                  (Layout-adopt-views! layout d))))
   priority: priority))
