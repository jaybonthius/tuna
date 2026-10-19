#lang :tuna/prelude
;;; Scrolling a view (live tier): what the browser reports after a view
;;; scrolled becomes the view's anchor (buffers contract). The browser
;;; scrolls natively; the renderer draws only the lines near the anchor.
;;;
;;; `view-scrolled`, bound to scroll reports (the keys contract's
;;; `scroll-key`), ignores a report older than the view's last scroll
;;; request or about another text node, records the facts it carries, and
;;; anchors the view at what the browser has at its top:
;;; - a line is at the top: that line, exactly where the browser has it;
;;;   the browser's scroll anchoring absorbs estimate errors above it;
;;; - the top is in a spacer: the line found by counting from the nearest
;;;   drawn line by the average height of the drawn lines, put at the top.
;;; It never maps a scroll offset through estimates of the whole text,
;;; which drift away from the browser's real positions over a long scroll.
(import :tuna/kernel
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract)
(export scrolling)

(def (clamp-line (line : :fixnum) (line-count : :fixnum)) => :fixnum
  (fxmax 1 (fxmin line line-count)))

;; The average height of the lines EVENT says were drawn, or #f when the
;; report cannot tell.
(def (drawn-line-height (event : scroll-event)) => (Maybe :flonum)
  (using (event : scroll-event)
    (let (height (fl/ (fl- event.drawn-end event.drawn-start)
                      (exact->inexact (fx1+ (fx- event.drawn-last event.drawn-first)))))
      (and (fl>= height 1.) height))))

;; Where EVENT puts the anchor of a text of LINE-COUNT lines whose lines
;; are LINE-HEIGHT px on average: (LINE . OFFSET), the line and the px of
;; it above the view's top; or #f when the top is on something drawn that
;; is not a line, such as another node above the text.
(def (anchor-placement (event : scroll-event) (line-count : :fixnum) (line-height : :flonum))
  => (Maybe :pair)
  (using (event : scroll-event)
    (let ((top event.top-line)
          (at event.viewport-top))
      (cond
       (top
        (cons (clamp-line top line-count) event.top-offset))
       ((fl< at event.drawn-start)
        ;; Count back from the first line drawn; stop at line 1.
        (let* ((distance (fl- event.drawn-start at))
               (first (clamp-line event.drawn-first line-count))
               (steps (fxmin (fx1- first)
                             (inexact->exact (flceiling (fl/ distance line-height)))))
               (rest (fl- distance (fl* (exact->inexact steps) line-height))))
          (cons (fx- first steps) (if (fl> rest 0.) 0. (fl- 0. rest)))))
       ((fl>= at event.drawn-end)
        ;; Count on from the line after the last one drawn.
        (let* ((distance (fl- at event.drawn-end))
               (after (clamp-line (fx1+ event.drawn-last) line-count))
               (steps (fxmin (fx- line-count after)
                             (inexact->exact (flfloor (fl/ distance line-height)))))
               (rest (fl- distance (fl* (exact->inexact steps) line-height))))
          (cons (fx+ after steps) rest)))
       (else #f)))))

;; Anchor the view EVENT names where the browser has it, and keep its facts.
(def (view-scrolled! (event : scroll-event)) => :void
  (let* ((p (scroll-event-start event))
         (v (posn-view p))
         (n (and v (view-anchor-node v))))
    (when (and n
               (eqv? (node-id n) (posn-node-id p))
               (fx>= (scroll-event-request event) (view-scroll-request v)))
      (let* ((t (text-node-content n))
             (line-count (text-line-count t))
             (facts (view-facts v))
             (line-height (or (drawn-line-height event)
                              (and facts (scroll-facts-line-height facts)))))
        (when line-height
          (let (placement (anchor-placement event line-count line-height))
            (when placement
              (set-view-anchor! v n (text-line-start t (car placement)) (cdr placement))))
          (set-view-facts! v (make-scroll-facts (scroll-event-top-line event)
                                                (scroll-event-last-line event)
                                                (scroll-event-viewport-top event)
                                                (scroll-event-viewport-height event)
                                                line-height
                                                (scroll-event-drawn-first event)
                                                (scroll-event-drawn-last event))))))))

(defplugin (scrolling ctx)
  "Keeps each view's anchor where the browser reports it scrolled to."
  requires: [commands-service input-service buffers-service layout-service]
  (defcommand (view-scrolled) "Anchor the view a scroll report names at what the browser shows at its top."
    (let (event (last-command-event))
      (if (scroll-event? event)
        (view-scrolled! event)
        (message "view-scrolled runs only from a scroll report"))))
  (keymap-set ctx scroll-key 'view-scrolled))
