#lang :tuna/prelude
;;; Scrolling views (live tier): what the browser measures of a view
;;; becomes its scroll state (buffers contract); commands and the view's
;;; scroll bar place items in it; and a view and its point are kept
;;; together. The browser scrolls natively; the renderer draws only the run
;;; of items around the scroll state. Nothing here knows lines, rows or any
;;; other kind of item, and every position comes from what the browser
;;; measured or from a placement.
;;;
;;; `view-scrolled`, bound to scroll reports (the keys contract's
;;; `scroll-key`), ignores a report measured before the view's newest
;;; placement, adopts the item the browser found at the view's top edge,
;;; and how far above the edge it is, as the view's scroll state, keeps
;;; what else it measured (the last item wholly in view, the view's size),
;;; and sets how many items to draw before and after the scroll item. Those
;;; counts are only a fetching step: where anything is comes only from what
;;; the browser measures, and the next report corrects them. Each side
;;; follows the density of what is drawn (items per px, both measured):
;;; with fewer px drawn than the drawn-above (drawn-below) setting, as
;;; many more items as that density says fill the difference, at least
;;; `fetching-step`; with more than twice the setting, about as many as
;;; fill one and a half times it, and at least one fewer than now.
;;;
;;; Scroll commands place items (Emacs's names and keys): `C-v` puts the
;;; last items wholly in view at the top and `M-v` the first ones at the
;;; bottom, keeping `next-screen-context-items` of them in view; `C-l`
;;; puts point's item at the centre, then the top, then the bottom. The
;;; scroll bar (keys contract's scroll bar events): dragging its handle to
;;; a fraction of the track puts the item at that fraction of the item
;;; count at the top (`scroll-bar-drag`); clicking the track pages
;;; (`scroll-bar-page`): below the handle, the last item wholly in view goes
;;; to the top; above it, the item at the top goes to the bottom. Those that
;;; need to know what is in view, the paging ones, wait for the browser to
;;; measure the view's newest placement first: a view owes at most one,
;;; the newest, and runs it when the report comes.
;;;
;;; Point and the view. Point's item is the item of the view's items that
;;; holds point. When it is known to be out of view, whichever of the two
;;; moved last wins. After a command that moves point or edits its text,
;;; the view goes to point: point's item is placed at the edge it lies
;;; beyond, or at the centre when it lies more than a screen beyond (a
;;; screen being the items last measured in view), as Emacs recenters on a
;;; far jump. After scrolling, by hand or by a scroll command, point goes
;;; to the view: to the first item of its text in view if it was above,
;;; the last if below, keeping its column (Emacs moves point into the
;;; window after scrolling) - unless `scroll-moves-point` is off, when it
;;; stays out of view until a command moves it. What is in view is what
;;; the browser measured under the view's newest placement; until it has
;;; measured that, only the placement's item is known to be in view, and
;;; the items beyond the edge it was placed at known to be out of it.
(import (only-in :gerbil/runtime/hash HashTable)
        :tuna/kernel
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/settings/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract)
(export scrolling
        scroll-moves-point
        next-screen-context-items
        fetching-step
        adjusted-count)

;; Whether scrolling a view moves its point into view (as in Emacs). Off,
;; point stays where it was, out of view, until a command moves it or
;; edits its text, which brings the view back to it (as in VS Code).
(defsetting scroll-moves-point #t
  "Whether scrolling a view moves its point into view; off, point stays and the view returns to it when a command moves it.")

;; How many items C-v and M-v keep in view of what was in view before
;; (Emacs's next-screen-context-lines, 2).
(def next-screen-context-items 2)

;; The fewest items a view draws more of when it asks for more.
(def fetching-step 16)

;; How many px of an item may lie beyond a view's edge for it still to
;; count as wholly in view: what the browser rounds to a device pixel.
(def edge-tolerance .5)

;; Commands that move a view themselves, after which point follows the
;; view (or is the item they placed), not the view point.
(def view-moving-commands
  '(view-scrolled scroll-bar-drag scroll-bar-page scroll-up-command scroll-down-command
    recenter-top-bottom))

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

;;; What the plugin keeps

;; For each view: which moved last, its point or the view ('point or
;; 'view; 'point until the view first moves), and the scroll it owes. The
;; points of the views commands run in, innermost command first, as they
;; were before it. Where C-l last put point's item.
(defclass scrolling-state ((moved-last : HashTable)
                           (owed       : HashTable)
                           (before     : :list)
                           (recentered : :symbol))
  final: #t)

(def (new-scrolling-state) => scrolling-state
  (scrolling-state moved-last: (make-hash-table test: eq? weak-keys: #t)
                   owed: (make-hash-table test: eq? weak-keys: #t)
                   before: [] recentered: 'bottom))

(def (moved-last (state : scrolling-state) (v : view)) => :symbol
  (hash-ref (scrolling-state-moved-last state) v 'point))

(def (set-moved-last! (state : scrolling-state) (v : view) (which : :symbol)) => :void
  (hash-put! (scrolling-state-moved-last state) v which))

;;; What is in a view

;; What is known of what a view shows of ROOT's items: those before index
;; FIRST are above it and those after LAST below it, either #f when not
;; known, and about COUNT items fill it, as last measured.
(defstruct shown ((root  : node)
                  (first :? :fixnum)
                  (last  :? :fixnum)
                  (count : :fixnum))
  final: #t)

;; V's facts if the browser measured them under V's newest placement, so
;; they say where V is; else #f.
(def (current-facts (v : view)) => (Maybe scroll-facts)
  (let (facts (view-facts v))
    (and facts
         (fx= (scroll-facts-placement facts) (placement-number (view-placement v)))
         facts)))

;; What is known of what V shows, or #f before the browser has measured V.
;; Measured under the newest placement: the items wholly in view, from
;; the scroll item, or the one after it when the scroll item is partly
;; above the edge, to the last measured. Placed since: the placement's
;; item, and on the side it was placed at, the items beyond.
(def (view-shown (v : view)) => (Maybe shown)
  (let (facts (view-facts v))
    (and facts
         (let* ((root (scroll-facts-root facts))
                (index (lambda ((it :? item)) (if it (node-item-index root it) 0))))
           (if (current-facts v)
             (let ((top (index (view-scroll-item v)))
                   (last-visible (view-last-visible-item v)))
               (and top
                    (let* ((first (if (fl>= (view-scroll-offset v) edge-tolerance) (fx1+ top) top))
                           (last (fxmax top (or (and last-visible (node-item-index root last-visible)) top))))
                      (make-shown root first last (fxmax 1 (fx1+ (fx- last first)))))))
             (let* ((p (view-placement v))
                    (target (index (placement-target p)))
                    (count (fxmax 1 (scroll-facts-visible-count facts))))
               (and target
                    (case (placement-align p)
                      ((top) (make-shown root target #f count))
                      ((bottom) (make-shown root #f target count))
                      (else (make-shown root #f #f count))))))))))

;; The index of V's point's item among ROOT's items, with the item; or #f.
(def (point-index (v : view) (root : node)) => (Maybe :pair)
  (let* ((it (view-point-item v root))
         (index (and it (node-item-index root it))))
    (and index (cons index it))))

;;; Point and the view

;; Place V's point's item in V when it is known to be out of V: at the
;; edge it lies beyond, or at the centre when more than a screen beyond.
(def (show-point-item! (v : view)) => :void
  (let (s (view-shown v))
    (when s
      (using (s : shown)
        (let (p (point-index v s.root))
          (when p
            (let ((index (car p)) (it (cdr p)))
              (cond
               ((and s.first (fx< index s.first))
                (place-view! v it (if (fx<= (fx- s.first index) s.count) 'top 'center)))
               ((and s.last (fx> index s.last))
                (place-view! v it (if (fx<= (fx- index s.last) s.count) 'bottom 'center)))))))))))

;; Move V's point into V when it is known to be out of V and its text's
;; lines are among V's items: to the first line of its text known to be in
;; view if it is above, or the last if below, at its column.
(def (move-point-into-view! (v : view)) => :void
  (let ((s (view-shown v))
        (n (view-node v)))
    (when (and s n)
      (using (s : shown)
        (let ((p (point-index v s.root))
              (base (node-item-index s.root (node-line-item n 1))))
          (when (and p base)
            (let* ((t (text-node-content n))
                   (index (car p))
                   (above? (and s.first (fx< index s.first)))
                   (below? (and s.last (fx> index s.last))))
              (when (or above? below?)
                ;; What is known to be in view, and of point's text.
                (let ((low (fxmax base (or s.first s.last)))
                      (high (fxmin (fx+ base (fx1- (text-line-count t))) (or s.last s.first))))
                  (when (fx<= low high)
                    (set-view-point! v (text-position-at t (fx1+ (fx- (if above? low high) base))
                                                         (text-column t (view-point v))))))))))))))

;; Bring V and its point together after the browser measured V: the view
;; to point if point moved last, else point to the view unless
;; scroll-moves-point is off for V's buffer.
(def (settle-point! (state : scrolling-state) (v : view)) => :void
  (if (eq? (moved-last state v) 'point)
    (show-point-item! v)
    (when (buffer-local-value scroll-moves-point (view-showing v))
      (move-point-into-view! v))))

;; V was scrolled by a command, which placed an item: point follows.
(def (scrolled! (state : scrolling-state) (v : view)) => :void
  (set-moved-last! state v 'view)
  (when (buffer-local-value scroll-moves-point (view-showing v))
    (move-point-into-view! v)))

;; Run SCROLL, a scroll of V that needs to know what is in V, now if the
;; browser has measured V's newest placement, or else once it has.
(def (scroll-when-measured! (state : scrolling-state) (v : view) (scroll : :procedure)) => :void
  (if (current-facts v)
    (scroll)
    (hash-put! (scrolling-state-owed state) v scroll)))

;;; Reports

;; Adopt what EVENT measured of its view, returning the view and how the
;; report found it, or #f when it was measured before the view's newest
;; placement or about another node: 'placed when it is the first measured
;; under that placement, 'moved when the view has scrolled since the last
;; report (another item or offset at the top, the same size), and 'still
;; otherwise. The node its view's scroller draws from is the one EVENT
;; names, while the view's buffer holds it.
(def (view-scrolled! (event : scroll-event)) => (Maybe :pair)
  (using (event : scroll-event)
    (let* ((p event.start)
           (v (posn-view p))
           (root (and v (posn-node p))))
      (and root (fx>= event.placement (placement-number (view-placement v)))
           (let* ((resolve (lambda ((token :? :string)) (and token (token-item root token))))
                  (top (resolve event.top-item))
                  (top-index (and top (node-item-index root top)))
                  (last-visible (resolve event.last-visible-item))
                  (last-index (and last-visible (node-item-index root last-visible)))
                  (visible (if (and top-index last-index) (fxmax 1 (fx1+ (fx- last-index top-index))) 0))
                  (before (view-facts v))
                  (was (view-scroll-item v))
                  (how (cond
                        ((or (not before) (fx< (scroll-facts-placement before) event.placement)) 'placed)
                        ((and top
                              (fx= (scroll-facts-width before) event.viewport-width)
                              (fx= (scroll-facts-height before) event.viewport-height)
                              (or (not was) (not (item=? was top))
                                  (fl>= (flabs (fl- (view-scroll-offset v) event.top-offset)) edge-tolerance)))
                         'moved)
                        (else 'still))))
             (set-view-facts! v (make-scroll-facts event.placement root last-visible visible
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
                         (adjusted-count event.drawn-after visible event.px-below
                                         (setting-pixels drawn-below) density)))))
             (cons v how))))))

;; After a report adopted by view-scrolled!: a view that moved by hand
;; moved last; then V runs the scroll it owes, or V and its point are
;; brought together.
(def (after-report! (state : scrolling-state) (v : view) (how : :symbol)) => :void
  (when (eq? how 'moved)
    (set-moved-last! state v 'view))
  (let (owed (hash-get (scrolling-state-owed state) v))
    (if owed
      (begin
        (hash-remove! (scrolling-state-owed state) v)
        (owed))
      (settle-point! state v))))

;;; Scroll commands

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
(def (place-at-fraction! (state : scrolling-state) (v : view) (root : node) (fraction : :flonum)) => :void
  (let (count (node-item-count root))
    (when (fx> count 0)
      (place-view! v (node-item-at root (fxmax 0 (fxmin (fx1- count)
                                                        (inexact->exact
                                                         (flfloor (fl* fraction (exact->inexact count)))))))
                   'top)
      (scrolled! state v))))

;; Page V toward PART of its track: the last item wholly in view to the
;; top, or the top item to the bottom.
(def (page! (state : scrolling-state) (v : view) (part : :symbol)) => :void
  (let (s (view-shown v))
    (when s
      (using (s : shown)
        (let ((top (node-item-index s.root (or (view-scroll-item v) (node-item-at s.root 0)))))
          (when top
            (if (eq? part 'below-handle)
              (place-view! v (node-item-at s.root (or s.last top)) 'top)
              (place-view! v (node-item-at s.root top) 'bottom))
            (scrolled! state v)))))))

;; C-v in V: the item next-screen-context-items before the end of what is
;; wholly in view to the top, or at least the item after the top one.
(def (scroll-up! (state : scrolling-state) (v : view)) => :void
  (let (s (view-shown v))
    (when s
      (using (s : shown)
        (let ((top (node-item-index s.root (or (view-scroll-item v) (node-item-at s.root 0))))
              (count (node-item-count s.root)))
          (when (and top s.last)
            (when (fx>= s.last (fx1- count))
              (error "End of buffer"))
            (place-view! v (node-item-at s.root (fxmax (fx1+ top)
                                                       (fx- s.last (fx1- next-screen-context-items))))
                         'top)
            (scrolled! state v)))))))

;; M-v in V: the item next-screen-context-items after the start of what is
;; in view to the bottom, or at least the item before the last one wholly
;; in view.
(def (scroll-down! (state : scrolling-state) (v : view)) => :void
  (let (s (view-shown v))
    (when s
      (using (s : shown)
        (let ((top (node-item-index s.root (or (view-scroll-item v) (node-item-at s.root 0)))))
          (when (and top s.last)
            (when (and (fx= top 0) (fl< (view-scroll-offset v) edge-tolerance))
              (error "Beginning of buffer"))
            (place-view! v (node-item-at s.root (fxmax 0 (fxmin (fx+ top (fx1- next-screen-context-items))
                                                               (fx1- s.last))))
                         'bottom)
            (scrolled! state v)))))))

;; C-l in V: point's item at the centre, then on repeating at the top, at
;; the bottom, and at the centre again (Emacs's recenter-positions).
(def (recenter! (state : scrolling-state) (v : view)) => :void
  (let* ((facts (view-facts v))
         (root (if facts (scroll-facts-root facts) (buffer-root (view-showing v))))
         (p (point-index v root)))
    (when p
      (let (align (if (eq? (last-command) 'recenter-top-bottom)
                    (case (scrolling-state-recentered state)
                      ((center) 'top)
                      ((top) 'bottom)
                      (else 'center))
                    'center))
        (place-view! v (cdr p) align)
        (set! (scrolling-state-recentered state) align)
        (set-moved-last! state v 'point)))))

;;; Commands that move point

;; Where point is in the selected view: the view, its focused text node,
;; point, and that text's character revision.
(def (point-place) => :list
  (let* ((v (selected-view))
         (n (view-node v)))
    [v n (view-point v) (if n (text-chars-revision (text-node-content n)) 0)]))

;; After a command other than the view-moving ones: if it moved point in
;; the selected view, or edited point's text, the view goes to point.
(def (after-command! (state : scrolling-state) (before : :list)) => :void
  (unless (memq (this-command) view-moving-commands)
    (match (point-place)
      ([v n position revision]
       (match before
         ([(? (cut eq? <> v)) before-n before-position before-revision]
          (unless (and (eq? n before-n) (eqv? position before-position) (eqv? revision before-revision))
            (set-moved-last! state v 'point)
            (show-point-item! v)))
         (else (void)))))))

(defplugin (scrolling ctx)
  "Keeps each view's scroll state where the browser measured it, scrolls views by command and scroll bar, and keeps views and their points together."
  requires: [commands-service input-service buffers-service layout-service settings-service]
  (let (state (new-scrolling-state))
    (defcommand (view-scrolled) "Adopt what the browser measured of the view a scroll report names."
      (let (event (last-command-event))
        (if (scroll-event? event)
          (let (adopted (view-scrolled! event))
            (when adopted
              (after-report! state (car adopted) (cdr adopted))))
          (message "view-scrolled runs only from a scroll report"))))
    (defcommand (scroll-bar-drag) "Put the item at the fraction of the view's items the scroll bar's handle was dragged to at its top."
      (let (target (scroll-bar-target))
        (if target
          (place-at-fraction! state (car target) (cdr target)
                              (scroll-bar-event-fraction (last-command-event)))
          (message "scroll-bar-drag runs only from the scroll bar"))))
    (defcommand (scroll-bar-page) "Page the view toward where its scroll bar's track was clicked."
      (let (target (scroll-bar-target))
        (if target
          (let ((v (car target))
                (part (scroll-bar-event-part (last-command-event))))
            (scroll-when-measured! state v (lambda () (page! state v part))))
          (message "scroll-bar-page runs only from the scroll bar"))))
    (defcommand (scroll-up-command) "Scroll forward by nearly a screen: the last items in view go to the top."
      (let (v (selected-view))
        (scroll-when-measured! state v (lambda () (scroll-up! state v)))))
    (defcommand (scroll-down-command) "Scroll back by nearly a screen: the first items in view go to the bottom."
      (let (v (selected-view))
        (scroll-when-measured! state v (lambda () (scroll-down! state v)))))
    (defcommand (recenter-top-bottom) "Put point's item at the centre of the view; repeated, at the top, then the bottom."
      (recenter! state (selected-view)))
    (context-add-hook! ctx pre-command-hook 'point-before
      (lambda ()
        (set! (scrolling-state-before state) (cons (point-place) (scrolling-state-before state)))))
    (context-add-hook! ctx post-command-hook 'point-after
      (lambda ()
        (let (before (scrolling-state-before state))
          (when (pair? before)
            (set! (scrolling-state-before state) (cdr before))
            (after-command! state (car before)))))))
  (keymap-set ctx scroll-key 'view-scrolled)
  (keymap-set ctx "<vertical-scroll-bar> <drag-mouse-1>" 'scroll-bar-drag)
  (keymap-set ctx "<vertical-scroll-bar> <mouse-1>" 'scroll-bar-page)
  (keymap-set ctx "C-v" 'scroll-up-command)
  (keymap-set ctx "<next>" 'scroll-up-command)
  (keymap-set ctx "M-v" 'scroll-down-command)
  (keymap-set ctx "<prior>" 'scroll-down-command)
  (keymap-set ctx "C-l" 'recenter-top-bottom))
