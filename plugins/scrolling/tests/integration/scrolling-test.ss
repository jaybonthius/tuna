;;; The scrolling plugin: scroll reports, resolved through the keys plugin
;;; to view-scrolled, become the scroll state of the view they name, also
;;; from a spacer, and set how many items it draws and its average item
;;; height; the keys C-v, M-v and C-l place items; a view and its point
;;; are kept together. The layout is the
;;; two-views double; a text of 5,000 lines is shown in its left view.
;;; Point moves by a command of this test's (`goto-test-line`), standing in
;;; for editing commands.
(import :std/test
        :tuna/kernel
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/settings/contract
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
        "../../../layout/tests/support/two-views"
        "../../../keys/tests/support/keys")
(export scrolling-test)

;; The line goto-test-line moves point to, in the focused text.
(def test-line 1)

(defplugin (test-motion ctx)
  "goto-test-line: point to test-line, as editing commands move it."
  requires: [commands-service buffers-service]
  (defcommand (goto-test-line) "Move point to the start of test-line."
    (goto-char (text-line-start (current-text) test-line)))
  (defcommand (insert-test-text) "Insert x at point."
    (insert "x")))

(defplugin (test-rows ctx)
  "Row nodes: each one item, under a node opening into their items."
  requires: [buffers-service]
  (context-define-node-kind! ctx 'rows items: 'children)
  (context-define-node-kind! ctx 'row items: 'whole))

(def scrolling-plugins
  [commands keys rope-text-store settings no-session buffers two-views scrolling test-motion test-rows])

;; Press KEYS, then wait until the editor loop has handled them.
(def (keys! . keys)
  (apply type! keys)
  (on-baton void))

;; Move point to the start of LINE by a command.
(def (goto-line! line)
  (set! test-line line)
  (on-baton (lambda () (call-command 'goto-test-line))))

(def line-count 5000)

(def (numbered-lines)
  (string-join (let lp ((n line-count) (out [])) (if (zero? n) out (lp (- n 1) (cons (number->string n) out))))
               "\n"))

(def (on-baton thunk) (call-on-editor-loop thunk))

;; Fill *scratch* with the numbered lines and return the selected view.
(def (long-view!)
  (on-baton (lambda () (insert (numbered-lines)) (goto-char 1) (selected-view))))

;; The token of item K, from 1, of ROOT's items: by default V's text's
;; lines.
(def (line-token v line root: (root (view-node v)))
  (on-baton (lambda () (item-token (node-item-at root (- line 1))))))

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
;; them beyond the view, DRAWN px from the first one's top to the last
;; one's bottom, in a 800 x 744 px view; LAST, by default 30 lines below
;; TOP, is the last in view. With SPACER ('above or 'below), the view's top
;; edge is DISTANCE px into that spacer, TOP is the drawn line next to it,
;; and no line is wholly in view.
(def (report! v top: (top 300) offset: (offset 0.) last: (last #f)
              spacer: (spacer #f) distance: (distance 0.)
              before: (before 100) after: (after 400) above: (above 2000.) below: (below 2000.)
              drawn: (drawn (+ above below 744.))
              placement: (placement 0) root: (root (view-node v)) node: (node (node-id root)))
  (submit! (make-scroll-event (next-sequence!) (make-posn 'view (view-id v) node 0) placement
                              (and top (line-token v top root: root)) offset
                              (and (not spacer) (line-token v (or last (+ top 30)) root: root))
                              spacer distance before after drawn above below 800 744)))

;; Report what the browser measured of V's newest placement: TOP and LAST
;; as report! takes them.
(def (placed! v top last root: (root (view-node v)))
  (report! v top: top last: last root: root placement: (placement-number (view-placement v))))

;; The browser has placed V at its start and measured it there, with 100
;; lines of 20 px drawn, so later reports are V scrolled by hand.
(def (measured! v)
  (report! v top: 1 last: 31 before: 0 after: 99 above: 0. below: 1256. drawn: 2000.
           placement: (placement-number (view-placement v))))

;; The line of IT, or #f.
(def (line-of it)
  (on-baton (lambda () (and it (item-line it)))))

;; V's newest placement: its number, item's line, alignment and offset.
(def (placement-of v)
  (let (p (view-placement v))
    [(placement-number p) (line-of (placement-target p)) (placement-align p) (placement-offset p)]))

;; V's newest placement's item's line and alignment.
(def (placed-at v)
  (match (placement-of v) ([_ line align _] [line align])))

;; The line and column of V's point.
(def (point-at v)
  (on-baton (lambda ()
              (let ((t (text-node-content (view-node v))) (p (view-point v)))
                [(text-line-at t p) (text-column t p)]))))

;; A buffer of 2,000 row nodes, each one item, under a node opening into
;; their items; row 1,000 holds a text node, the buffer's only one, so
;; point is in it. Returned with its root and the row holding the text.
(def (rows-with-text!)
  (on-baton
   (lambda ()
     (let* ((rows (let lp ((k 2000) (out []))
                    (if (zero? k) out
                        (lp (- k 1) (cons (new-node 'row children: (if (= k 1000) [(new-text-node (new-text "row text"))] []))
                                          out)))))
            (root (new-node 'rows children: rows))
            (b (new-buffer "rows" root)))
       (add-buffer! b)
       [b root (list-ref rows 999)]))))


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
         (check (drawn v) => [initial-drawn-items initial-drawn-items]))))

    (test-case "a report's top item becomes the scroll state, where the browser has it"
      (with-scrolling
       (lambda (v)
         (let (number (placement-number (view-placement v)))
           (measured! v)
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
         (measured! v)
         (report! v top: 300 offset: 5.)
         (on-baton (lambda () (goto-char 1) (insert "0\n")))
         (check (scroll-state v) => [301 5.]))))

    (test-case "the counts grow by the measured density of what is drawn, toward two view heights"
      (with-scrolling
       (lambda (v)
         ;; 51 items in 1,184 px; two view heights are 1,488 px: 1,488 - 240
         ;; px more above need 54 more items, and 1,488 - 200 below need 56.
         (measured! v)
         (report! v top: 2500 before: 10 after: 40 above: 240. below: 200. drawn: 1184.)
         (check (drawn v) => [64 96]))))

    (test-case "drawn-screens sets how much is drawn beyond the view, in view heights"
      (with-scrolling
       (lambda (v)
         (on-baton (lambda () (set-buffer-setting! (view-showing v) drawn-screens 1)))
         (measured! v)
         ;; One view height, 744 px: 744 - 240 px above need 22 more items.
         (report! v top: 2500 before: 10 after: 40 above: 240. below: 200. drawn: 1184.)
         (check (car (drawn v)) => 32))))

    (test-case "the counts stop at the first and the last item"
      (with-scrolling
       (lambda (v)
         (measured! v)
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

    (test-case "near an end, every item to it is drawn rather than a short spacer"
      ;; 50 items fill 1,000 px at .05 items a px.
      (check (to-the-end 100 50 1000. .05) => 50)
      (check (to-the-end 100 60 1000. .05) => 100)
      (check (to-the-end 10 50 1000. .05) => 10)
      (with-scrolling
       (lambda (v)
         (measured! v)
         ;; 64 items would be drawn above line 100, leaving 35: fewer than
         ;; the 65 that fill two view heights.
         (report! v top: 100 before: 10 after: 40 above: 240. below: 200. drawn: 1184.)
         (check (car (drawn v)) => 99))))

    (test-case "a report measured before the view's newest placement is ignored"
      (with-scrolling
       (lambda (v)
         ;; Point in what the report finds in view, so the view stays there.
         (on-baton (lambda () (goto-char (text-line-start (current-text) 310))
                      (place-view! v (node-item-at (view-node v) 99) 'top)))
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

    (test-case "a report from a spacer above counts back from the first drawn item by the average"
      (with-scrolling
       (lambda (v)
         (measured! v)
         (let (number (placement-number (view-placement v)))
           ;; The top edge is 450 px above line 1,000, the first drawn; at
           ;; 20 px an item, that is 22.5 items: line 977, 10 px of it above.
           (report! v top: 1000 spacer: 'above distance: 450. before: 0 after: 99 above: 0. below: 0.
                    drawn: 2000.)
           (check (scroll-state v) => [977 10.])
           ;; The placement names it, exactly, under the same number.
           (check (placement-of v) => [number 977 'top 10.])
           ;; Drawn around it: two view heights above, three below.
           (check (drawn v) => [75 112])))))

    (test-case "a report from a spacer below counts on from the last drawn item by the average"
      (with-scrolling
       (lambda (v)
         (measured! v)
         ;; 455 px below line 2,000, the last drawn: 22 items of 20 px after
         ;; line 2,001, and 15 px into the next.
         (report! v top: 2000 spacer: 'below distance: 455. before: 99 after: 0 above: 0. below: 0.
                  drawn: 2000.)
         (check (scroll-state v) => [2023 15.]))))

    (test-case "counting across a spacer stops at the first and the last item, the rest their offset"
      (with-scrolling
       (lambda (v)
         (measured! v)
         (report! v top: 10 spacer: 'above distance: 5000. before: 0 after: 99 above: 0. below: 0.
                  drawn: 2000.)
         ;; 4,820 px above line 1: the start of the view is above it.
         (check (scroll-state v) => [1 -4820.])
         (report! v top: 4990 spacer: 'below distance: 5000. before: 99 after: 0 above: 0. below: 0.
                  drawn: 2000.)
         (check (scroll-state v) => [5000 4820.]))))

    (test-case "an item across a spacer: the one whose share holds the edge, the rest its offset"
      ;; Above, from item 100: 45 px is 2.25 items up, so item 97, 15 px above.
      (check (item-across-spacer 'above 100 1000 45. 20.) => (cons 97 15.))
      ;; Exactly two items up: item 98, at its top.
      (check (item-across-spacer 'above 100 1000 40. 20.) => (cons 98 0.))
      ;; Below, from item 100: 45 px past its bottom is 2 items after 101.
      (check (item-across-spacer 'below 100 1000 45. 20.) => (cons 103 5.))
      (check (item-across-spacer 'below 100 1000 0. 20.) => (cons 101 0.))
      ;; Stopped at the first and the last item, the rest their offset.
      (check (item-across-spacer 'above 3 1000 100. 20.) => (cons 0 -40.))
      (check (item-across-spacer 'below 995 1000 100. 20.) => (cons 999 40.)))

    (test-case "the average item height is measured on the first report and on reports from a spacer only"
      (with-scrolling
       (lambda (v)
         (check (view-average-item-height v) => #f)
         ;; 100 items in 2,000 px.
         (measured! v)
         (check (view-average-item-height v) => 20.)
         ;; Another report measuring 30 px an item leaves the spacers as they are.
         (report! v top: 300 before: 50 after: 49 above: 1000. below: 256. drawn: 3000.)
         (check (view-average-item-height v) => 20.)
         ;; A report from a spacer counts by the 20 px the spacer was drawn
         ;; with, then keeps what it measured, 25 px, for the next spacers.
         (report! v top: 1000 spacer: 'above distance: 50. before: 0 after: 99 above: 0. below: 0.
                  drawn: 2500.)
         (check (scroll-state v) => [997 10.])
         (check (view-average-item-height v) => 25.)
         ;; Showing another buffer forgets it.
         (let (b (car (rows-with-text!)))
           (on-baton (lambda () (set-view-buffer v b))))
         (check (view-average-item-height v) => #f))))

    (test-case "C-v puts the last two items wholly in view at the top, and point there when it was above"
      (with-scrolling
       (lambda (v)
         (measured! v)
         (on-baton (lambda () (goto-char 3)))
         (keys! "C-v")
         ;; Lines 1 to 31 were wholly in view: 30 and 31 stay in view.
         (check (placed-at v) => [30 'top])
         (check (point-at v) => [30 0])
         ;; Pressed again before the browser measured that, C-v waits for it.
         (let (number (placement-number (view-placement v)))
           (keys! "C-v")
           (check (placement-number (view-placement v)) => number)
           (placed! v 30 60)
           (check (placed-at v) => [59 'top])))))

    (test-case "C-v with the last item in view, and M-v at the start, scroll nothing"
      (with-scrolling
       (lambda (v)
         (measured! v)
         (let (before (placement-of v))
           (keys! "M-v")
           (check (placement-of v) => before))
         (report! v top: 4970 last: 5000)
         (let (before (placement-of v))
           (keys! "C-v")
           (check (placement-of v) => before)))))

    (test-case "M-v puts the first two items in view at the bottom, and point there when it was below"
      (with-scrolling
       (lambda (v)
         (measured! v)
         (report! v top: 300 last: 330)
         (goto-line! 320)
         (keys! "M-v")
         (check (placed-at v) => [301 'bottom])
         (check (point-at v) => [301 0]))))

    (test-case "C-l puts point's item at the centre, then the top, then the bottom"
      (with-scrolling
       (lambda (v)
         (measured! v)
         (report! v top: 300 last: 330)
         (goto-line! 310)
         (keys! "C-l")
         (check (placed-at v) => [310 'center])
         ;; The browser's report in between is not a command: the next C-l
         ;; still follows the last.
         (placed! v 295 325)
         (check (on-baton last-command) => 'recenter-top-bottom)
         (keys! "C-l")
         (check (placed-at v) => [310 'top])
         (keys! "C-l")
         (check (placed-at v) => [310 'bottom])
         (keys! "C-l")
         (check (placed-at v) => [310 'center])
         (goto-line! 311)
         (keys! "C-l")
         (check (placed-at v) => [311 'center]))))

    (test-case "point moved out of view brings the view: to the edge it passed, or the centre from afar"
      (with-scrolling
       (lambda (v)
         (measured! v)
         (report! v top: 300 last: 330)
         (goto-line! 300)
         (let (before (placement-of v))
           (goto-line! 330)
           (check (placement-of v) => before))
         (goto-line! 335)
         (check (placed-at v) => [335 'bottom])
         ;; Until the browser measures that, what lies below line 335 is
         ;; known to be out of view, and what lies above it is not known.
         (goto-line! 336)
         (check (placed-at v) => [336 'bottom])
         (let (before (placement-of v))
           (goto-line! 320)
           (check (placement-of v) => before)
           ;; The browser's measure decides: with lines taller than before,
           ;; line 320 is out of view.
           (placed! v 325 336)
           (check (placed-at v) => [320 'top]))
         (placed! v 320 350)
         (goto-line! 290)
         (check (placed-at v) => [290 'top])
         (placed! v 290 320)
         (goto-line! 2000)
         (check (placed-at v) => [2000 'center]))))

    (test-case "a placement for point that the browser could not make is not made again"
      (with-scrolling
       (lambda (v)
         (measured! v)
         (goto-line! 2000)
         (check (placed-at v) => [2000 'center])
         (let (before (placement-of v))
           ;; Measured under that placement, but the view is where it was.
           (placed! v 1 31)
           (check (placement-of v) => (match before ([number _ _ _] [number 1 'top 0.])))
           (goto-line! 2001)
           (check (placed-at v) => [2001 'center])))))

    (test-case "scrolling by hand moves point into view, keeping its column"
      (with-scrolling
       (lambda (v)
         (measured! v)
         (on-baton (lambda () (goto-char 3)))
         (report! v top: 300 last: 330)
         (check (point-at v) => [300 0])
         (on-baton (lambda () (goto-char (+ 2 (text-line-start (current-text) 1000)))))
         (report! v top: 400 last: 430)
         (check (point-at v) => [430 2])
         ;; A top item partly above the edge is not wholly in view.
         (report! v top: 500 offset: 3. last: 530)
         (check (point-at v) => [501 2]))))

    (test-case "with scroll-moves-point off, point stays out of view until a command moves it"
      (with-scrolling
       (lambda (v)
         (on-baton (lambda () (set-buffer-setting! (view-showing v) scroll-moves-point #f)))
         (measured! v)
         (report! v top: 300 last: 330)
         (check (point-at v) => [1 0])
         (keys! "C-v")
         (check (point-at v) => [1 0])
         (placed! v 330 360)
         (check (point-at v) => [1 0])
         (goto-line! 2)
         (check (placed-at v) => [2 'center]))))

    (test-case "items that are nodes: the view goes to the row holding point, and scroll commands page rows"
      (with-scrolling
       (lambda (v)
         (match (rows-with-text!)
           ([b root row]
            (let (row-item (lambda () (on-baton (lambda () (node-item-index root (view-point-item v root))))))
              (on-baton (lambda () (set-view-buffer v b)))
              ;; Showing a buffer places point's item, the row, at the centre.
              (check (row-item) => 999)
              (let (p (view-placement v))
                (check [(eq? (item-node (placement-target p)) row) (placement-align p)] => [#t 'center]))
              (placed! v 985 1015 root: root)
              (keys! "C-l")
              (check (placement-align (view-placement v)) => 'center)
              (keys! "C-l")
              (check (placement-align (view-placement v)) => 'top)
              (placed! v 1000 1030 root: root)
              (check (row-item) => 999)
              ;; C-v pages rows, and leaves point in the row it cannot leave.
              (keys! "C-v")
              (let (p (view-placement v))
                (check [(on-baton (lambda () (node-item-index root (placement-target p)))) (placement-align p)]
                       => [1028 'top]))
              (placed! v 1029 1059 root: root)
              (check (row-item) => 999)
              ;; Editing point's text brings its row back into view.
              (on-baton (lambda () (call-command 'insert-test-text)))
              (let (p (view-placement v))
                (check [(eq? (item-node (placement-target p)) row) (placement-align p)] => [#t 'top]))))))))))

