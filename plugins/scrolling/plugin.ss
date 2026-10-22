#lang :tuna/prelude
;;; Scrolling views (live tier): what the browser measures of a view
;;; becomes its scroll state (buffers contract); commands place items in
;;; it; and a view and its point are kept together. The browser scrolls
;;; natively, with its own scroll bar; the renderer draws only the run of
;;; items around the scroll state, between spacers standing in for the
;;; rest. Nothing here knows lines, rows or any other kind of item, and
;;; every position comes from what the browser measured or from a
;;; placement.
;;;
;;; `view-scrolled`, bound to scroll reports (the keys contract's
;;; `scroll-key`, a special event: it is not what the user did, so it
;;; becomes no one's last command and runs no command hooks), ignores a
;;; report measured before the view's newest placement, adopts the item
;;; the browser found at the view's top edge, and how far above the edge
;;; it is, as the view's scroll state, keeps what else it measured (the
;;; last item wholly in view, the view's size), and sets how many items to
;;; draw before and after the scroll item. Those counts are only a
;;; fetching step: where anything is comes only from what the browser
;;; measures, and the next report corrects them. Each side follows the
;;; density of what is drawn (items per px, both measured): with fewer px
;;; drawn than the drawn-screens setting's view heights, as many more
;;; items as that density says fill the difference, at least
;;; `fetching-step`; with more than twice that, about as many as fill one
;;; and a half times it, and at least one fewer than now; and all the
;;; items to that end of the buffer when fewer than fill those view heights
;;; would be left, so no short spacer is drawn near an end.
;;;
;;; When the view's top edge is in a spacer (a fling or a drag of the
;;; scroll bar outran what is drawn), the report says how far it is from
;;; the drawn item next to that spacer, and the item there is counted from
;;; that item by the average item height the spacer was drawn with: the
;;; item whose share of the spacer holds the edge, with the rest as its
;;; offset, but never beyond the first or the last item, so the top of the
;;; spacer above is the first item and the end of the one below the last.
;;; That becomes the scroll state, the view's placement names it with its
;;; exact offset, and the renderer draws around it, so its items appear
;;; about where the spacer said they were, give or take how far the items
;;; drawn before it differ from the average; the page then measures what
;;; it shows. Counting starts from the nearest drawn item, never from the
;;; top of the buffer, so no estimate of everything above adds up.
;;;
;;; The average item height (the drawn items' height over their count, as
;;; measured) is the spacers' height per item, so it changes only when it
;;; must: on the view's first report, and on a report from a spacer with
;;; drawn items in view, after counting, for the spacers drawn next. Taken
;;; from every report, it would swing the spacers by thousands of px deep
;;; in a long buffer as the drawn items vary, moving the scroll bar under
;;; the user's pointer. Never from a report with nothing drawn in view: a
;;; new average moves everything below a spacer by its items times the
;;; change, and the browser's scroll anchoring holds the view still only
;;; with a drawn item in view to hold.
;;;
;;; Scroll commands place items (Emacs's names and keys): `C-v` puts the
;;; last items wholly in view at the top and `M-v` the first ones at the
;;; bottom, keeping `next-screen-context-items` of them in view; `C-l`
;;; puts point's item at the centre, then the top, then the bottom. The
;;; paging ones need to know what is in view, so they wait for the browser
;;; to measure the view's newest placement first: a view owes at most one,
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
        spacer-item-height
        next-screen-context-items
        fetching-step
        adjusted-count
        to-the-end
        item-across-spacer)

;; Whether scrolling a view moves its point into view (as in Emacs). Off,
;; point stays where it was, out of view, until a command moves it or
;; edits its text, which brings the view back to it (as in VS Code).
;; How tall a spacer counts each undrawn item. The browser's scroll bar is
;; sized by the spacers, so a value that changes while you drag moves the
;; handle away from the pointer.
;; - 'measured: the average item height measured, updated on the view's
;;   first report and on each report from a spacer with drawn items in
;;   view;
;; - 'first: the average measured on the view's first report, then kept;
;; - a number: that many px for every undrawn item, never measured.
(defsetting spacer-item-height 'measured
  "How tall a spacer counts each undrawn item: 'measured, 'first, or a number of px.")

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
;; view (or is the item they placed), not the view point. (view-scrolled
;; runs as a special event, outside the command hooks.)
(def view-moving-commands
  '(scroll-up-command scroll-down-command recenter-top-bottom))

;; The px V, HEIGHT px high, keeps drawn beyond each edge: the
;; drawn-screens setting's view heights, for its buffer.
(def (wanted-pixels (v : view) (height : :fixnum)) => :flonum
  (let (screens (buffer-local-value drawn-screens (view-showing v)))
    (fl* (exact->inexact height)
         (:- (exact->inexact (if (and (real? screens) (> screens 0)) screens (setting-default drawn-screens)))
             :flonum))))

(def (ceiling-count (x : :flonum)) => :fixnum
  (inexact->exact (flceiling x)))

(def (floor-count (x : :flonum)) => :fixnum
  (inexact->exact (flfloor x)))

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

;; How many items to draw on one side of a view's scroll item, where
;; there are THERE items, when COUNT would be drawn: all of them, when the
;; spacer standing for the rest would be shorter than WANTED px at DENSITY
;; items per px. A short spacer would be near an end of the buffer, where
;; the browser's scroll range stops, and nothing could hold what is in
;; view still when its items are drawn shorter than it.
(def (to-the-end (there : :fixnum) (count : :fixnum) (wanted : :flonum) (density : :flonum)) => :fixnum
  (if (fx< (fx- there count) (ceiling-count (fl* wanted density))) there count))

;; The item at a view's top edge when it is DISTANCE px inside the spacer
;; on SIDE ('above or 'below) of the drawn items, EDGE being the index of
;; the drawn item next to that spacer among COUNT items, at AVERAGE px an
;; item: (INDEX . OFFSET), the item whose share of the spacer holds the
;; edge, counted from EDGE, and the px of it above the edge. Where the
;; count runs past the first or the last item, that item, with the rest as
;; its offset: negative above the first item, as the view's start is.
(def (item-across-spacer (side : :symbol) (edge : :fixnum) (count : :fixnum) (distance : :flonum)
                         (average : :flonum))
  => :pair
  (if (eq? side 'above)
    (let (steps (fxmin edge (ceiling-count (fl/ distance average))))
      (cons (fx- edge steps) (fl- (fl* (exact->inexact steps) average) distance)))
    (let (steps (fxmin (fx- count edge 2) (floor-count (fl/ distance average))))
      (cons (fx+ edge (fx1+ steps)) (fl- distance (fl* (exact->inexact steps) average))))))

;;; What the plugin keeps

;; For each view: which moved last, its point or the view ('point or
;; 'view; 'point until the view first moves), the scroll it owes, and the
;; last placement made to show its point's item, as (NUMBER . ITEM). The
;; points of the views commands run in, innermost command first, as they
;; were before it. Where C-l last put point's item.
(defclass scrolling-state ((moved-last       : HashTable)
                           (owed             : HashTable)
                           (point-placements : HashTable)
                           (before           : :list)
                           (recentered       : :symbol))
  final: #t)

(def (new-scrolling-state) => scrolling-state
  (scrolling-state moved-last: (make-hash-table test: eq? weak-keys: #t)
                   owed: (make-hash-table test: eq? weak-keys: #t)
                   point-placements: (make-hash-table test: eq? weak-keys: #t)
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
(def (show-point-item! (state : scrolling-state) (v : view)) => :void
  (let (s (view-shown v))
    (when s
      (using (s : shown)
        (let (p (point-index v s.root))
          (when p
            (let* ((index (car p))
                   (it (cdr p))
                   (align (cond
                           ((and s.first (fx< index s.first))
                            (if (fx<= (fx- s.first index) s.count) 'top 'center))
                           ((and s.last (fx> index s.last))
                            (if (fx<= (fx- index s.last) s.count) 'bottom 'center))
                           (else #f))))
              (when align
                (place-view! v it align)
                (hash-put! (scrolling-state-point-placements state) v
                           (cons (placement-number (view-placement v)) it))))))))))

;; Whether the browser has just measured V under the placement last made
;; to show its point's item, and point is in that item still: then placing
;; it again would not show it either (the browser could not put it there).
(def (point-placement-measured? (state : scrolling-state) (v : view)) => :boolean
  (let ((placed (hash-get (scrolling-state-point-placements state) v))
        (facts (current-facts v)))
    (and placed facts
         (fx= (car placed) (scroll-facts-placement facts))
         (let (p (point-index v (scroll-facts-root facts)))
           (and p (item=? (cdr p) (cdr placed)))))))

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
    (show-point-item! state v)
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

;; The average item height EVENT measured: the drawn items' height over
;; their count; or #f when nothing drawn has a height.
(def (measured-average (event : scroll-event)) => (Maybe :flonum)
  (using (event : scroll-event)
    (and (fl> event.drawn-height 0.)
         (fl/ event.drawn-height (exact->inexact (fx+ event.drawn-before event.drawn-after 1))))))

;; Whether EVENT's view had a drawn item in it: not when its top edge was
;; in the spacer below the drawn items, or as far in the spacer above them
;; as the view is high.
(def (drawn-in-view? (event : scroll-event)) => :boolean
  (using (event : scroll-event)
    (case event.spacer
      ((above) (fl< event.spacer-distance (exact->inexact event.viewport-height)))
      ((below) #f)
      (else #t))))

;; Adopt what EVENT measured of its view, returning the view and how the
;; report found it, or #f when it was measured before the view's newest
;; placement or about another node: 'placed when it is the first measured
;; under that placement, 'moved when the view has scrolled since the last
;; report (another item or offset at the top, the same size), and 'still
;; otherwise. The node its view's scroller draws from is the one EVENT
;; names, while the view's buffer holds it. The item at the top is the one
;; EVENT names, or, when its top edge is in a spacer, the one counted
;; across the spacer from the drawn item EVENT names (item-across-spacer).
(def (view-scrolled! (event : scroll-event)) => (Maybe :pair)
  (using (event : scroll-event)
    (let* ((p event.start)
           (v (posn-view p))
           (root (and v (posn-node p))))
      (and root (fx>= event.placement (placement-number (view-placement v)))
           (let* ((resolve (lambda ((token :? :string)) (and token (token-item root token))))
                  (count (node-item-count root))
                  (measured (measured-average event))
                  (drawn-average (view-average-item-height v))
                  (rule (buffer-local-value spacer-item-height (view-showing v)))
                  (average (cond
                            ((and (real? rule) (> rule 0)) (exact->inexact rule))
                            ((eq? rule 'first) (or drawn-average measured))
                            ((and measured (or (not drawn-average) (and event.spacer (drawn-in-view? event))))
                             measured)
                            (else drawn-average)))
                  (named (resolve event.top-item))
                  (named-index (and named (node-item-index root named)))
                  ;; Counted by the average the spacer was drawn with.
                  (across (and named-index event.spacer drawn-average
                               (item-across-spacer event.spacer named-index count
                                                   event.spacer-distance drawn-average)))
                  (top-index (if across (car across) named-index))
                  (top (if across (node-item-at root top-index) named))
                  (offset (if across (cdr across) event.top-offset))
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
                                  (fl>= (flabs (fl- (view-scroll-offset v) offset)) edge-tolerance)))
                         'moved)
                        (else 'still))))
             (set-view-facts! v (make-scroll-facts event.placement root last-visible visible
                                                   event.viewport-width event.viewport-height))
             (when average
               (set-view-average-item-height! v average))
             (when top-index
               (set-view-scroll! v top offset)
               (let* ((density (if measured (fl/ 1. measured) 0.))
                      (wanted (wanted-pixels v event.viewport-height))
                      (height (exact->inexact event.viewport-height))
                      (after-last (fx- count top-index 1)))
                 (set-view-drawn-items!
                  v
                  (to-the-end top-index
                              (if across
                                ;; Nothing is drawn around the new top item yet.
                                (adjusted-count 0 0 0. wanted density)
                                (adjusted-count event.drawn-before 0 event.px-above wanted density))
                              wanted density)
                  (to-the-end after-last
                              (if across
                                (adjusted-count 0 0 0. (fl+ wanted height) density)
                                (adjusted-count event.drawn-after visible event.px-below wanted density))
                              wanted density))))
             (cons v how))))))

;; After a report adopted by view-scrolled!: a view that moved by hand
;; moved last; then V runs the scroll it owes, or V and its point are
;; brought together, unless this report measured the placement made to
;; show point's item and point is still in it.
(def (after-report! (state : scrolling-state) (v : view) (how : :symbol)) => :void
  (when (eq? how 'moved)
    (set-moved-last! state v 'view))
  (let (owed (hash-get (scrolling-state-owed state) v))
    (cond
     (owed
      (hash-remove! (scrolling-state-owed state) v)
      (owed))
     ((and (eq? how 'placed) (point-placement-measured? state v)) (void))
     (else (settle-point! state v)))))

;;; Scroll commands

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
            (show-point-item! state v)))
         (else (void)))))))

(defplugin (scrolling ctx)
  "Keeps each view's scroll state where the browser measured it, scrolls views by command, and keeps views and their points together."
  requires: [commands-service input-service buffers-service layout-service settings-service]
  (let (state (new-scrolling-state))
    (defcommand (view-scrolled) "Adopt what the browser measured of the view a scroll report names."
      (let (event (last-command-event))
        (if (scroll-event? event)
          (let (adopted (view-scrolled! event))
            (when adopted
              (after-report! state (car adopted) (cdr adopted))))
          (message "view-scrolled runs only from a scroll report"))))
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
  (keymap-set ctx "C-v" 'scroll-up-command)
  (keymap-set ctx "<next>" 'scroll-up-command)
  (keymap-set ctx "M-v" 'scroll-down-command)
  (keymap-set ctx "<prior>" 'scroll-down-command)
  (keymap-set ctx "C-l" 'recenter-top-bottom))
