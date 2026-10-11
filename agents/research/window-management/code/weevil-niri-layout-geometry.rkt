#lang racket/base

;; Pure layout geometry for the Niri-style scrolling tiling strip. Dependency-free
;; (no web, no session state) so the command layer, the render path, and the unit
;; tests all share ONE source of truth for the arithmetic -- mirroring how
;; `virtual-scroll.rkt` owns the vertical windowing math.
;;
;; Faithful port of the Niri model (see plans/niri-research/01-scrolling-strip-model.md):
;;   * a COLUMN has one width policy shared by all its panes;
;;   * each PANE in a column has a height policy; a column auto-distributes the
;;     leftover vertical space among its `auto` panes by weight;
;;   * the strip's horizontal VIEW-OFFSET is stored relative to the active column
;;     and recomputed by a least-motion "fit" rule.
;;
;; Simplifications vs Niri that we model deliberately (see the design doc):
;;   * weevil panes have NO border, so window-size == tile-size (no border insets);
;;   * proportions are gaps-aware but carry no tab-indicator `extra` term in v1;
;;   * centering modes other than the default ("never"/fit) are deferred.
;;
;; Units are logical pixels (reals). Heights are rounded to integer px at the
;; distribution step (matching Niri) so the per-pane sum stays exact.

(require racket/contract/base
         racket/list)

;; --- Width policy ----------------------------------------------------------
;; A column's desired width: a fraction of the working area, or a fixed px count.
(struct cw-proportion (p) #:transparent)
(struct cw-fixed (px) #:transparent)

(define (column-width? v)
  (or (cw-proportion? v) (cw-fixed? v)))

;; --- Height policy (per pane) ----------------------------------------------
;; `auto` panes share the leftover column height by weight; `fixed` pins a pane
;; to an exact px height. (Presets resolve to `wh-fixed` via `resolve-preset`
;; before distribution, mirroring how Niri freezes a chosen preset to a height.)
(struct wh-auto (weight) #:transparent)
(struct wh-fixed (px) #:transparent)

(define (window-height? v)
  (or (wh-auto? v) (wh-fixed? v)))

;; Per-pane input to the height distributor: its policy + min/max window height
;; hints (0 max means "no maximum"). Bundled in one struct so there are no
;; parallel index-locked lists to keep in sync.
(struct height-spec (policy min-h max-h) #:transparent)

(provide
 (contract-out
  [struct cw-proportion ([p (>=/c 0)])]
  [struct cw-fixed ([px (>=/c 0)])]
  [column-width? (-> any/c boolean?)]
  [struct wh-auto ([weight (>/c 0)])]
  [struct wh-fixed ([px (>=/c 0)])]
  [window-height? (-> any/c boolean?)]
  [struct height-spec ([policy window-height?] [min-h (>=/c 0)] [max-h (>=/c 0)])]
  ;; widths
  [resolve-column-width (->* (column-width? real? real?) (real?) real?)]
  [clamp-range (-> real? real? real? real?)]
  ;; horizontal positions + scroll
  [column-xs (-> (listof real?) real? (listof real?))]
  [column-x (-> (listof real?) real? exact-nonnegative-integer? real?)]
  [view-pos (-> real? real? real?)]
  [fit-view-offset (-> real? real? real? real? real? real?)]
  ;; vertical height distribution
  [distribute-heights (-> (listof height-spec?) real? real? (listof exact-nonnegative-integer?))]
  [convert-heights-to-auto (-> (listof real?) (listof wh-auto?))]
  [resolve-preset (-> column-width? real? real? real?)]
  ;; preset cycling
  [next-preset-index
   (-> (listof column-width?) (or/c #f exact-nonnegative-integer?) real? real? real? boolean?
       (or/c #f exact-nonnegative-integer?))]))

;; --- helpers ---------------------------------------------------------------

(define (clamp-range v lo hi)
  (max lo (min hi v)))

(define (iround x)
  (inexact->exact (round x)))

;; --- Width resolution ------------------------------------------------------
;; Gaps-aware: a proportion `p` resolves so that the column's on-screen FOOTPRINT
;; (width + one trailing gap) is exactly `(working-w - gaps) * p`. Hence N columns
;; of `1/N` tile the working area precisely regardless of the gap size -- Niri's
;; headline guarantee. `extra` (default 0) is reserved for a future tab indicator.
(define (resolve-column-width width working-w gaps [extra 0])
  (cond
    [(cw-proportion? width) (- (* (- working-w gaps) (cw-proportion-p width)) gaps extra)]
    [else (cw-fixed-px width)]))

;; A fixed/proportion PRESET resolved to px (same formula as a live width). Used
;; by `next-preset-index` to compare presets against the current realized width.
(define (resolve-preset preset working-w gaps)
  (resolve-column-width preset working-w gaps))

;; --- Column x positions (strip coordinates, left -> right) -----------------
;; NO leading gap: column 0 starts at x=0; each subsequent column starts a
;; `gaps` past the previous column's right edge. (The left screen margin is
;; produced entirely by the view-offset, never by a leading gap -- see the design
;; doc's leading-gap note.) `widths` are the REALIZED column widths in px.
(define (column-xs widths gaps)
  (let loop ([ws widths] [x 0] [acc '()])
    (cond
      [(null? ws) (reverse acc)]
      [else (loop (cdr ws) (+ x (car ws) gaps) (cons x acc))])))

(define (column-x widths gaps i)
  (list-ref (column-xs widths gaps) i))

;; --- View offset / fit -----------------------------------------------------
;; The viewport's left edge in strip coordinates. `view-offset` is stored
;; relative to the active column, so adding the active column's x gives the
;; absolute scroll position.
(define (view-pos active-col-x view-offset)
  (+ active-col-x view-offset))

;; Niri's `compute_new_view_offset` (least-motion fit, centering = "never").
;; Given the CURRENT absolute view position (`cur-view-pos` = left edge), the
;; viewport width, and the target column's strip-x + width, return the new
;; VIEW-OFFSET (relative to that column, i.e. new-view-pos - col-x):
;;   * a column wider than the viewport is left-aligned (offset 0);
;;   * a column already fully visible doesn't move (offset preserves cur-view-pos);
;;   * otherwise snap to whichever edge is the smaller motion, leaving <= `gaps`
;;     of peek padding.
(define (fit-view-offset cur-view-pos view-w col-x col-w gaps)
  (cond
    [(<= view-w col-w) 0]
    [else
     (define padding (clamp-range (/ (- view-w col-w) 2) 0 gaps))
     (define new-x (- col-x padding))
     (define new-right-x (+ col-x col-w padding))
     (cond
       ;; already fully visible: keep the current position (offset rebased to col-x)
       [(and (<= cur-view-pos new-x) (<= new-right-x (+ cur-view-pos view-w)))
        (- cur-view-pos col-x)]
       [else
        (define dist-left (abs (- cur-view-pos new-x)))
        (define dist-right (abs (- (+ cur-view-pos view-w) new-right-x)))
        (if (<= dist-left dist-right)
            (- padding)
            (- (- view-w padding col-w)))])]))

;; --- Vertical height distribution ------------------------------------------
;; Distribute a column's working height among its panes (top -> bottom),
;; returning one integer px height per pane in order. Algorithm (Niri
;; `update_tile_sizes`, brief 01 section 3.3):
;;   budget = working-h - gaps*(n+1)              ; gaps above, below, and between
;;   1. pin every `fixed` pane (and every min==max pane) to its clamped height,
;;      subtracting from the budget;
;;   2. iteratively split the remaining budget among the `auto` panes by weight;
;;      if any auto pane's share is below its min height, pin it to min and
;;      restart (so min heights are always respected); else commit the rounded
;;      shares. Each committed share is rounded to integer px and removed from the
;;      budget so the running total stays exact (max heights are intentionally
;;      NOT enforced in the auto loop, matching Niri).
;; With no auto panes, the (clamped) fixed heights are returned as-is.
(define (distribute-heights specs working-h gaps)
  (define n (length specs))
  (cond
    [(zero? n) '()]
    [else
     (define budget0 (- working-h (* gaps (add1 n))))
     (define heights (make-vector n #f)) ; #f = still-auto, else a committed px
     ;; pass 1: pin fixed / exact-constraint panes
     (define-values (budget auto-idxs total-weight)
       (for/fold ([budget budget0] [auto-idxs '()] [total-weight 0.0])
                 ([spec (in-list specs)] [i (in-naturals)])
         (define policy (height-spec-policy spec))
         (define min-h (height-spec-min-h spec))
         (define max-h (height-spec-max-h spec))
         (define exact? (and (> max-h 0) (= min-h max-h)))
         (cond
           [(or exact? (wh-fixed? policy))
            (define raw (if (wh-fixed? policy) (wh-fixed-px policy) min-h))
            (define capped (if (> max-h 0) (min raw max-h) raw))
            (define h (max 1 (iround (max capped min-h))))
            (vector-set! heights i h)
            (values (- budget h) auto-idxs total-weight)]
           [else
            (values budget (cons i auto-idxs) (+ total-weight (wh-auto-weight policy)))])))
     (define auto-order (reverse auto-idxs))
     ;; pass 2: weighted fill of the auto panes with min-height pinning + restart
     (let loop ([budget budget] [pool auto-order] [total-weight total-weight])
       (cond
         [(null? pool) (void)]
         [else
          ;; find an auto pane whose proportional share is below its min height
          (define under
            (for/or ([i (in-list pool)])
              (define spec (list-ref specs i))
              (define weight (wh-auto-weight (height-spec-policy spec)))
              (define share (if (> total-weight 0) (* budget (/ weight total-weight)) 0))
              (and (< share (height-spec-min-h spec)) i)))
          (cond
            [under
             ;; pin the underflowing pane to its min and restart with the rest
             (define spec (list-ref specs under))
             (define min-h (max 1 (iround (height-spec-min-h spec))))
             (define weight (wh-auto-weight (height-spec-policy spec)))
             (vector-set! heights under min-h)
             (loop (- budget min-h) (remove under pool) (- total-weight weight))]
            [else
             ;; commit all remaining shares (rounded; budget absorbs rounding)
             (let commit ([pool pool] [budget budget] [total-weight total-weight])
               (cond
                 [(null? pool) (void)]
                 [else
                  (define i (car pool))
                  (define weight (wh-auto-weight (height-spec-policy (list-ref specs i))))
                  (define h (max 1 (iround (if (> total-weight 0)
                                               (* budget (/ weight total-weight))
                                               budget))))
                  (vector-set! heights i h)
                  (commit (cdr pool) (- budget h) (- total-weight weight))]))])]))
     (for/list ([h (in-vector heights)]) (or h 0))]))

;; Recompute auto weights from the panes' CURRENT pixel heights so a manual
;; resize preserves the visual proportions (Niri `convert_heights_to_auto`):
;; normalize by the MEDIAN height (weights are scale-invariant, so 2,2,1 == 4,4,2),
;; giving the median pane weight 1.0.
(define (convert-heights-to-auto pixel-heights)
  (cond
    [(null? pixel-heights) '()]
    [else
     (define sorted (sort pixel-heights <))
     (define median (list-ref sorted (quotient (length sorted) 2)))
     (define divisor (if (> median 0) median 1))
     (for/list ([h (in-list pixel-heights)])
       (wh-auto (/ (exact->inexact (max h 1)) divisor)))]))

;; --- Preset width cycling --------------------------------------------------
;; Pick the next preset index for switch-preset-column-width (Niri `toggle_width`):
;;   * if already ON a preset (`current-idx` set), step cyclically (+1 forwards,
;;     -1 backwards, mod count);
;;   * otherwise pick by the current realized width: the first preset strictly
;;     WIDER than current (forwards) or the last preset strictly NARROWER
;;     (backwards); if none qualifies, wrap to 0 (forwards) / last (backwards).
;; Returns #f for an empty preset list.
(define (next-preset-index presets current-idx current-px working-w gaps forwards?)
  (define count (length presets))
  (cond
    [(zero? count) #f]
    [current-idx
     (modulo (+ current-idx (if forwards? 1 (sub1 count))) count)]
    [else
     (define resolved (for/list ([p (in-list presets)]) (resolve-preset p working-w gaps)))
     (cond
       [forwards?
        (or (for/first ([r (in-list resolved)] [i (in-naturals)]
                        #:when (< (+ current-px 1) r))
              i)
            0)]
       [else
        (for/fold ([found (sub1 count)])
                  ([r (in-list resolved)] [i (in-naturals)]
                   #:when (< (+ r 1) current-px))
          i)])]))
