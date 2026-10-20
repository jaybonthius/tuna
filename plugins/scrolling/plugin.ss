#lang :tuna/prelude
;;; Scrolling views (live tier): what the browser measures of a view
;;; becomes its scroll state (buffers contract), and the view's scroll bar
;;; places items in it. The browser scrolls natively; the renderer draws
;;; only the run of items around the scroll state. Nothing here knows
;;; lines, rows or any other kind of item.
;;;
;;; `view-scrolled`, bound to scroll reports (the keys contract's
;;; `scroll-key`), ignores a report measured before the view's newest
;;; placement, adopts the item the browser found at the view's top edge,
;;; and how far above the edge it is, as the view's scroll state, keeps
;;; what else it measured (the last item in view, the view's size), and
;;; sets how many items to draw before and after the scroll item. Those
;;; counts are only a fetching step: where anything is comes only from what
;;; the browser measures, and the next report corrects them. Each side
;;; follows the density of what is drawn (items per px, both measured):
;;; with fewer px drawn than the drawn-above (drawn-below) setting, as
;;; many more items as that density says fill the difference, at least
;;; `fetching-step`; with more than twice the setting, about as many as
;;; fill one and a half times it, and at least one fewer than now.
;;;
;;; The scroll bar (keys contract's scroll bar events): dragging its handle
;;; to a fraction of the track places the item at that fraction of the
;;; item count at the top (`scroll-bar-drag`); clicking the track pages
;;; (`scroll-bar-page`): below the handle, the last item in view goes to
;;; the top; above it, the item at the top goes to the bottom.
(import :tuna/kernel
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/settings/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract)
(export scrolling
        fetching-step
        adjusted-count)

;; The fewest items a view draws more of when it asks for more.
(def fetching-step 16)

;; The setting S's px.
(def (setting-pixels (s : setting)) => :flonum
  (let (px (setting-value s))
    (exact->inexact (if (and (real? px) (>= px 0)) px (setting-default s)))))

(def (ceiling-count (x : :flonum)) => :fixnum
  (inexact->exact (flceiling x)))

;; How many items to draw on one side of a view's scroll item: DRAWN are
;; drawn now, PX px of them beyond the view's edge, IN-VIEW of them inside
;; it; WANTED px should be drawn beyond the edge, and DENSITY items fill a
;; px.
(def (adjusted-count (drawn : :fixnum) (in-view : :fixnum) (px : :flonum) (wanted : :flonum)
                     (density : :flonum))
  => :fixnum
  (cond
   ((fl< px wanted)
    (fx+ drawn (fxmax fetching-step (ceiling-count (fl* (fl- wanted px) density)))))
   ((fl> px (fl* 2. wanted))
    (fxmax in-view (fxmin (fx1- drawn) (fx+ in-view (ceiling-count (fl* 1.5 wanted density))))))
   (else drawn)))

;; Adopt what EVENT measured of its view. The node its view's scroller
;; draws from is the one EVENT names, while the view's buffer holds it.
(def (view-scrolled! (event : scroll-event)) => :void
  (using (event : scroll-event)
    (let* ((p event.start)
           (v (posn-view p))
           (root (and v (posn-node p))))
      (when (and root (fx>= event.placement (placement-number (view-placement v))))
        (let* ((resolve (lambda ((token :? :string)) (and token (token-item root token))))
               (top (resolve event.top-item))
               (top-index (and top (node-item-index root top)))
               (last-visible (resolve event.last-visible-item))
               (last-index (and last-visible (node-item-index root last-visible)))
               (visible (if (and top-index last-index) (fxmax 1 (fx1+ (fx- last-index top-index))) 0)))
          (set-view-facts! v (make-scroll-facts last-visible visible
                                                event.viewport-width event.viewport-height))
          (when top-index
            (set-view-scroll! v top event.top-offset)
            (let* ((drawn-px (fl+ event.px-above event.px-below
                                  (exact->inexact event.viewport-height)))
                   (density (if (fl> drawn-px 0.)
                              (fl/ (exact->inexact (fx+ event.drawn-before event.drawn-after 1)) drawn-px)
                              0.)))
              (set-view-drawn-items!
               v
               (fxmin top-index
                      (adjusted-count event.drawn-before 0 event.px-above
                                      (setting-pixels drawn-above) density))
               (fxmin (fx- (node-item-count root) top-index 1)
                      (adjusted-count event.drawn-after (fxmax 0 (fx1- visible)) event.px-below
                                      (setting-pixels drawn-below) density))))))))))

;; The view, and the node its scroller draws from, of the scroll bar
;; event that ran the command, or #f.
(def (scroll-bar-target) => (Maybe :pair)
  (let (event (last-command-event))
    (and (scroll-bar-event? event)
         (let* ((p (scroll-bar-event-start event))
                (v (posn-view p))
                (root (and v (posn-node p))))
           (and root (cons v root))))))

;; Place the item at FRACTION of ROOT's items at V's top.
(def (place-at-fraction! (v : view) (root : node) (fraction : :flonum)) => :void
  (let (count (node-item-count root))
    (when (fx> count 0)
      (place-view! v (node-item-at root (fxmax 0 (fxmin (fx1- count)
                                                        (inexact->exact
                                                         (flfloor (fl* fraction (exact->inexact count)))))))
                   'top))))

;; Page V, whose scroller draws ROOT's items, toward PART of its track.
(def (page! (v : view) (root : node) (part : :symbol)) => :void
  (if (eq? part 'below-handle)
    (let (last (view-last-visible-item v))
      (when last (place-view! v last 'top)))
    (let (top (or (view-scroll-item v)
                  (and (fx> (node-item-count root) 0) (node-item-at root 0))))
      (when top (place-view! v top 'bottom)))))

(defplugin (scrolling ctx)
  "Keeps each view's scroll state where the browser measured it, and drives its scroll bar."
  requires: [commands-service input-service buffers-service layout-service settings-service]
  (defcommand (view-scrolled) "Adopt what the browser measured of the view a scroll report names."
    (let (event (last-command-event))
      (if (scroll-event? event)
        (view-scrolled! event)
        (message "view-scrolled runs only from a scroll report"))))
  (defcommand (scroll-bar-drag) "Put the item at the fraction of the view's items the scroll bar's handle was dragged to at its top."
    (let (target (scroll-bar-target))
      (if target
        (place-at-fraction! (car target) (cdr target)
                            (scroll-bar-event-fraction (last-command-event)))
        (message "scroll-bar-drag runs only from the scroll bar"))))
  (defcommand (scroll-bar-page) "Page the view toward where its scroll bar's track was clicked."
    (let (target (scroll-bar-target))
      (if target
        (page! (car target) (cdr target) (scroll-bar-event-part (last-command-event)))
        (message "scroll-bar-page runs only from the scroll bar"))))
  (keymap-set ctx scroll-key 'view-scrolled)
  (keymap-set ctx "<vertical-scroll-bar> <drag-mouse-1>" 'scroll-bar-drag)
  (keymap-set ctx "<vertical-scroll-bar> <mouse-1>" 'scroll-bar-page))
