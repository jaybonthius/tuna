;;; The scrolling plugin: scroll reports, resolved through the keys plugin
;;; to view-scrolled, become the scroll state of the view they name, and
;;; set how many items it draws; scroll bar events, resolved to
;;; scroll-bar-drag and scroll-bar-page, place items. The layout is the
;;; two-views double; a text of 5,000 lines is shown in its left view.
(import :std/test
        :tuna/kernel
        :tuna/plugins/keys/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/plugin
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/buffers/plugin
        :tuna/plugins/scrolling/plugin
        "../../../../tuna/tests/support/kernel"
        "../../../session/tests/support/session"
        "../../../layout/tests/support/two-views")
(export scrolling-test)

(def scrolling-plugins
  [commands keys rope-text-store settings no-session buffers two-views scrolling])

(def line-count 5000)

(def (numbered-lines)
  (string-join (let lp ((n line-count) (out [])) (if (zero? n) out (lp (- n 1) (cons (number->string n) out))))
               "\n"))

(def (on-baton thunk) (call-on-editor-loop thunk))

;; Fill *scratch* with the numbered lines and return the selected view.
(def (long-view!)
  (on-baton (lambda () (insert (numbered-lines)) (goto-char 1) (selected-view))))

;; The token of line LINE of V's text.
(def (line-token v line)
  (on-baton (lambda () (item-token (node-item-at (view-node v) (- line 1))))))

(def sequence 0)

(def (submit! event)
  ((input-submitter) event)
  (on-baton void))

(def (next-sequence!)
  (set! sequence (+ sequence 1))
  sequence)

;; Submit a report about V's scroller, which draws V's text, then wait
;; until the editor loop has handled it. By default: line TOP at the top,
;; BEFORE items drawn before it and AFTER after it, ABOVE and BELOW px of
;; them beyond the view, in a 800 x 744 px view; LAST, by default 30
;; lines below TOP, is the last in view.
(def (report! v top: (top 300) offset: (offset 0.) last: (last #f)
              before: (before 100) after: (after 400) above: (above 20000.) below: (below 20000.)
              placement: (placement 0) node: (node (node-id (view-node v))))
  (submit! (make-scroll-event (next-sequence!) (make-posn 'view (view-id v) node 0) placement
                              (and top (line-token v top)) offset (line-token v (or last (+ top 30)))
                              before after above below 800 744)))

(def (scroll-bar! v part fraction)
  (submit! (make-scroll-bar-event (next-sequence!)
                                  (make-posn 'vertical-scroll-bar (view-id v) (node-id (view-node v)) 0)
                                  part fraction)))

;; The line of IT, or #f.
(def (line-of it)
  (on-baton (lambda () (and it (item-line it)))))

;; V's scroll state: the line at its top and the px of it above the edge.
(def (scroll-state v)
  [(line-of (on-baton (lambda () (view-scroll-item v)))) (view-scroll-offset v)])

(def (drawn v)
  [(view-drawn-before v) (view-drawn-after v)])

(def (with-scrolling thunk)
  (call-with-fresh-kernel scrolling-plugins
    (lambda ()
      (start-editor-loop!)
      (thunk (long-view!)))))

(def scrolling-test
  (test-suite "tuna/plugins/scrolling"
    (test-case "a new view is at the start of its buffer and draws a first fetching step"
      (with-scrolling
       (lambda (v)
         (check (scroll-state v) => [#f 0.])
         (check (view-facts v) => #f)
         (check (drawn v) => [0 initial-drawn-after]))))

    (test-case "a report's top item becomes the scroll state, where the browser has it"
      (with-scrolling
       (lambda (v)
         (let (number (placement-number (view-placement v)))
           (report! v top: 300 offset: 5.)
           (check (scroll-state v) => [300 5.])
           (let (facts (view-facts v))
             (check (line-of (scroll-facts-last-visible facts)) => 330)
             (check (scroll-facts-visible-count facts) => 31)
             (check [(scroll-facts-width facts) (scroll-facts-height facts)] => [800 744]))
           ;; The placement names the scroll state now, under the same number,
           ;; so a page loaded later puts the view there.
           (let (p (view-placement v))
             (check (placement-number p) => number)
             (check [(line-of (placement-target p)) (placement-align p) (placement-offset p)]
                    => [300 'top 5.]))))))

    (test-case "the scroll item stays with its text through edits above it"
      (with-scrolling
       (lambda (v)
         (report! v top: 300 offset: 5.)
         (on-baton (lambda () (goto-char 1) (insert "0\n")))
         (check (scroll-state v) => [301 5.]))))

    (test-case "the counts grow by the measured density of what is drawn"
      (with-scrolling
       (lambda (v)
         ;; 51 items in 240 + 744 + 200 px: 20,000 - 240 px more above need
         ;; 852 more items, and 20,000 - 200 below need 853.
         (report! v top: 2500 before: 10 after: 40 above: 240. below: 200.)
         (check (drawn v) => [862 893]))))

    (test-case "the counts stop at the first and the last item"
      (with-scrolling
       (lambda (v)
         (report! v top: 20 before: 10 after: 40 above: 240. below: 200.)
         (check (car (drawn v)) => 19)
         (report! v top: 4990 last: 5000 before: 10 after: 9 above: 240. below: 200.)
         (check (cadr (drawn v)) => 10))))

    (test-case "adjusting a count: grow by density, at least a step; shrink to one and a half settings"
      ;; Too little drawn: grow by the px missing times the density.
      (check (adjusted-count 100 0 5000. 20000. 0.05) => 850)
      ;; Barely too little: grow by at least the fetching step.
      (check (adjusted-count 100 0 19999. 20000. 0.05) => (+ 100 fetching-step))
      ;; Within the band: unchanged.
      (check (adjusted-count 100 0 30000. 20000. 0.05) => 100)
      ;; Far too much: about 1.5 times the setting's worth, beyond what is in view.
      (check (adjusted-count 3000 30 50000. 20000. 0.05) => 1530)
      ;; Never more than one fewer, and never fewer than are in view.
      (check (adjusted-count 1000 30 50000. 20000. 0.05) => 999)
      (check (adjusted-count 31 30 50000. 20000. 0.05) => 30))

    (test-case "a report measured before the view's newest placement is ignored"
      (with-scrolling
       (lambda (v)
         (on-baton (lambda () (place-view! v (node-item-at (view-node v) 99) 'top)))
         (let (number (placement-number (view-placement v)))
           (check (scroll-state v) => [100 0.])
           (report! v top: 300 offset: 5. placement: (- number 1))
           (check (scroll-state v) => [100 0.])
           (check (view-facts v) => #f)
           (report! v top: 300 offset: 5. placement: number)
           (check (scroll-state v) => [300 5.])))))

    (test-case "a report about a node the view's buffer does not hold is ignored"
      (with-scrolling
       (lambda (v)
         (report! v top: 300 offset: 5. node: 999999)
         (check (scroll-state v) => [#f 0.])
         (check (view-facts v) => #f))))

    (test-case "dragging the scroll bar's handle places the item at that fraction at the top"
      (with-scrolling
       (lambda (v)
         (let (number (placement-number (view-placement v)))
           (scroll-bar! v 'handle .5)
           (let (p (view-placement v))
             (check (placement-number p) => (+ number 1))
             (check [(line-of (placement-target p)) (placement-align p)] => [2501 'top]))
           (check (scroll-state v) => [2501 0.])
           (scroll-bar! v 'handle 1.)
           (check (scroll-state v) => [5000 0.])
           (scroll-bar! v 'handle 0.)
           (check (scroll-state v) => [1 0.])))))

    (test-case "clicking the scroll bar's track pages: the last item in view to the top, or the top one to the bottom"
      (with-scrolling
       (lambda (v)
         (report! v top: 300 last: 330)
         (scroll-bar! v 'below-handle .9)
         (let (p (view-placement v))
           (check [(line-of (placement-target p)) (placement-align p)] => [330 'top]))
         (report! v top: 330 last: 360 placement: (placement-number (view-placement v)))
         (scroll-bar! v 'above-handle .1)
         (let (p (view-placement v))
           (check [(line-of (placement-target p)) (placement-align p)] => [330 'bottom])))))))
