;;; The scrolling plugin: scroll reports, resolved through the keys plugin
;;; to view-scrolled, anchor the view they name and record their facts.
;;; The layout is the two-views double; a text of 1,000 lines is shown in
;;; its left view.
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

(def line-count 1000)

(def (numbered-lines)
  (string-join (let lp ((n line-count) (out [])) (if (zero? n) out (lp (- n 1) (cons (number->string n) out))))
               "\n"))

(def (on-baton thunk) (call-on-editor-loop thunk))

;; Fill *scratch* with the numbered lines and return the selected view.
(def (long-view!)
  (on-baton (lambda () (insert (numbered-lines)) (goto-char 1) (selected-view))))

(def sequence 0)

;; Submit a report about V's text, then wait until the editor loop has
;; handled it. Lines drawn 101 to 500, 24 px each, from 2,400 px.
(def (report! v top: (top #f) offset: (offset 0.) at: (at 0.)
              drawn-first: (drawn-first 101) drawn-last: (drawn-last 500)
              drawn-start: (drawn-start 2400.) drawn-end: (drawn-end 12000.)
              request: (request 0) node: (node (node-id (view-anchor-node v))))
  (set! sequence (+ sequence 1))
  ((input-submitter)
   (make-scroll-event sequence (make-posn 'view (view-id v) node 0)
                      top offset (and top (+ top 30)) at drawn-start drawn-end
                      drawn-first drawn-last 744 request))
  (on-baton void))

;; V's anchor line and offset.
(def (anchor v)
  (on-baton (lambda ()
              [(text-line-at (text-node-content (view-anchor-node v)) (view-anchor v))
               (view-anchor-offset v)])))

(def (with-scrolling thunk)
  (call-with-fresh-kernel scrolling-plugins
    (lambda ()
      (start-editor-loop!)
      (thunk (long-view!)))))

(def scrolling-test
  (test-suite "tuna/plugins/scrolling"
    (test-case "a new view is anchored at the top of its text"
      (with-scrolling
       (lambda (v)
         (check (anchor v) => [1 0.])
         (check (view-facts v) => #f))))

    (test-case "a line at the view's top becomes the anchor, where the browser has it"
      (with-scrolling
       (lambda (v)
         (report! v top: 300 offset: 5. at: 7181.)
         (check (anchor v) => [300 5.])
         (let (facts (view-facts v))
           (check (scroll-facts-first-visible-line facts) => 300)
           (check (scroll-facts-last-visible-line facts) => 330)
           (check (scroll-facts-viewport-top facts) => 7181.)
           (check (scroll-facts-viewport-height facts) => 744)
           (check (scroll-facts-line-height facts) => 24.)
           (check [(scroll-facts-drawn-first facts) (scroll-facts-drawn-last facts)] => [101 500]))
         ;; While a line is at the top, the line height measured first stays.
         (report! v top: 310 offset: 0. at: 7400. drawn-end: 14000.)
         (check (anchor v) => [310 0.])
         (check (scroll-facts-line-height (view-facts v)) => 24.))))

    (test-case "in the spacer above, count back from the first line drawn"
      (with-scrolling
       (lambda (v)
         ;; 1,400 px above line 101: line 42 starts at 2,400 - 59 * 24 =
         ;; 984 px, 16 px above the view's top.
         (report! v at: 1000.)
         (check (anchor v) => [42 16.])
         (check (view-first-visible-line v) => #f)
         ;; Placing from a spacer measures the line height again.
         (report! v at: 1000. drawn-end: 14000.)
         (check (scroll-facts-line-height (view-facts v)) => 29.))))

    (test-case "counting back stops at line 1, which goes to the view's top"
      (with-scrolling
       (lambda (v)
         (report! v at: 0. drawn-first: 11 drawn-last: 410)
         (check (anchor v) => [1 0.]))))

    (test-case "in the spacer below, count on from the line after the last drawn"
      (with-scrolling
       (lambda (v)
         ;; 8,000 px below line 500's end: 333 lines of 24 px after line
         ;; 501, and 8 px into line 834.
         (report! v at: 20000.)
         (check (anchor v) => [834 8.]))))

    (test-case "the anchor stays on its line's start through edits above it"
      (with-scrolling
       (lambda (v)
         (report! v top: 300 offset: 5. at: 7181.)
         (on-baton (lambda () (goto-char 1) (insert "0\n")))
         (check (anchor v) => [301 5.])
         (on-baton (lambda ()
                     (let (t (current-text))
                       ;; Delete from inside line 300 to inside line 301.
                       (delete-region (+ (text-line-start t 300) 1) (+ (text-line-start t 301) 1)))))
         (check (anchor v) => [300 5.]))))

    (test-case "a report older than the view's scroll request is ignored"
      (with-scrolling
       (lambda (v)
         (on-baton (lambda () (set-view-scroll-request! v 2)))
         (report! v top: 300 offset: 5. at: 7181. request: 1)
         (check (anchor v) => [1 0.])
         (check (view-facts v) => #f)
         (report! v top: 300 offset: 5. at: 7181. request: 2)
         (check (anchor v) => [300 5.]))))

    (test-case "a report about another text node is ignored"
      (with-scrolling
       (lambda (v)
         (report! v top: 300 offset: 5. at: 7181. node: 999999)
         (check (anchor v) => [1 0.])
         (check (view-facts v) => #f))))))
