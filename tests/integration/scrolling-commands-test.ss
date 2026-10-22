;;; Integration: scrolling with the editing commands and the default
;;; layout, through the editor loop. Point moved by C-n, C-p, M-< and M->
;;; brings the view to it; scrolling moves point, so typing goes where the
;;; view is; showing a buffer places point; splitting keeps the view where
;;; it was. The browser's measurements are simulated scroll reports.
(import :std/test
        :tuna/kernel
        :tuna/plugins/keys/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/plugin
        :tuna/plugins/echo-area/plugin
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/buffers/plugin
        :tuna/plugins/layout/plugin
        :tuna/plugins/view-commands/plugin
        :tuna/plugins/basic-editing/plugin
        :tuna/plugins/minibuffer/plugin
        :tuna/plugins/scrolling/plugin
        "../../tuna/tests/support/kernel"
        "../../plugins/session/tests/support/session"
        "../../plugins/keys/tests/support/keys")
(export scrolling-commands-test)

(def scrolling-plugins
  [commands keys echo-area rope-text-store settings no-session buffers layout view-commands
   basic-editing minibuffer scrolling])

(def (on-baton thunk) (call-on-editor-loop thunk))

;; Press KEYS, then wait until the editor loop has handled them.
(def (keys! . keys)
  (apply type! keys)
  (on-baton void))

;; LINES lines, numbered from 1.
(def (numbered-lines lines)
  (string-join (let lp ((n lines) (out [])) (if (zero? n) out (lp (- n 1) (cons (number->string n) out))))
               "\n"))

;; Fill *scratch* with 5,000 numbered lines, point at the start, and
;; return the selected view.
(def (with-scrolling thunk)
  (call-with-fresh-kernel scrolling-plugins
    (lambda ()
      (start-editor-loop!)
      (thunk (on-baton (lambda () (insert (numbered-lines 5000)) (goto-char 1) (selected-view)))))))

(def sequence 0)

;; Report that V's scroller, drawing V's text, has line TOP at the top and
;; LAST as the last line wholly in view, measured under PLACEMENT (by
;; default V's newest).
(def (report! v top last offset: (offset 0.) placement: (placement #f))
  (set! sequence (+ sequence 1))
  ((input-submitter)
   (on-baton
    (lambda ()
      (let* ((n (view-node v))
             (token (lambda (line) (item-token (node-item-at n (- line 1))))))
        (make-scroll-event sequence #f (make-posn 'view (view-id v) (node-id n) 0)
                           (or placement (placement-number (view-placement v)))
                           (token top) offset (token last) #f 0. 100 400 40744. 20000. 20000. 800 744)))))
  (on-baton void))

;; V's newest placement's item's line and alignment.
(def (placed-at v)
  (on-baton (lambda ()
              (let (p (view-placement v))
                [(let (it (placement-target p)) (and it (item-line it))) (placement-align p)]))))

;; The line and column of V's point.
(def (point-at v)
  (on-baton (lambda ()
              (let ((t (text-node-content (view-node v))) (p (view-point v)))
                [(text-line-at t p) (text-column t p)]))))

(def (repeat n key) (make-list n key))

(def scrolling-commands-test
  (test-suite "integration: scrolling with editing commands"
    (test-case "C-n and C-p beyond what is in view bring it along, one item at a time"
      (with-scrolling
       (lambda (v)
         (report! v 1 31)
         (apply keys! (repeat 30 "C-n"))
         (check (point-at v) => [31 0])
         (check (placed-at v) => [1 'top])
         (keys! "C-n")
         (check (placed-at v) => [32 'bottom])
         (keys! "C-n")
         (check (placed-at v) => [33 'bottom])
         (report! v 3 33)
         (apply keys! (repeat 31 "C-p"))
         (check (point-at v) => [2 0])
         (check (placed-at v) => [2 'top]))))

    (test-case "a report between keys keeps the goal column and a pending prefix"
      (with-scrolling
       (lambda (v)
         (report! v 1 31)
         ;; From the end of line 10, "10", through line 9, "9", and back.
         (on-baton (lambda () (goto-char (text-line-end (current-text) 10))))
         (keys! "C-p")
         (check (point-at v) => [9 1])
         (report! v 1 31)
         (keys! "C-n")
         (check (point-at v) => [10 2])
         (keys! "C-x")
         (report! v 1 31)
         (keys! "2")
         (check (on-baton (lambda () (length (filter (lambda (w) (eq? (view-showing w) (view-showing v))) (view-list)))))
                => 2))))

    (test-case "M-> and M-< from afar put the end and the start in the centre, which is as far as the view goes"
      (with-scrolling
       (lambda (v)
         (report! v 1 31)
         (keys! "M->")
         (check (point-at v) => [5000 4])
         (check (placed-at v) => [5000 'center])
         ;; The placement names the line as the renderer draws it, by its start.
         (check (on-baton (lambda () (item-token (placement-target (view-placement v)))))
                => (on-baton (lambda () (item-token (node-item-at (view-node v) 4999)))))
         (report! v 4970 5000)
         (keys! "M-<")
         (check (placed-at v) => [1 'center])
         (report! v 1 31)
         ;; Near: to the edge.
         (keys! "M->")
         (report! v 4970 5000)
         (apply keys! (repeat 10 "C-p"))
         (report! v 4960 4990 placement: (placement-number (view-placement v)))
         (keys! "M->")
         (check (placed-at v) => [5000 'bottom]))))

    (test-case "after scrolling, typing goes where the view is"
      (with-scrolling
       (lambda (v)
         (report! v 1 31)
         (keys! "C-v")
         (check (placed-at v) => [30 'top])
         (report! v 30 60)
         (keys! "C-v" "X")
         (check (on-baton (lambda () (text-substring (current-text) (text-line-start (current-text) 59)
                                                     (text-line-end (current-text) 59))))
                => "X59"))))

    (test-case "showing a buffer puts its point in view"
      (with-scrolling
       (lambda (v)
         (let (b (on-baton (lambda ()
                             (let (b (new-buffer "other" (new-text-node (new-text (numbered-lines 1000)))))
                               (add-buffer! b)
                               (set-buffer-point! b (text-line-start (text-node-content (buffer-root b)) 500))
                               b))))
           (on-baton (lambda () (set-view-buffer v b)))
           (check (placed-at v) => [500 'center])))))

    (test-case "a split view starts where the view it was split from is"
      (with-scrolling
       (lambda (v)
         (report! v 1 31)
         (report! v 300 330 offset: 7.)
         (keys! "C-x" "2")
         (let (new (on-baton (lambda () (find (lambda (w) (and (not (eq? w v)) (eq? (view-showing w) (view-showing v))))
                                              (view-list)))))
           (check (placed-at new) => [300 'top])
           (check (placement-offset (view-placement new)) => 7.)
           (check [(view-drawn-before new) (view-drawn-after new)]
                  => [(view-drawn-before v) (view-drawn-after v)])
           ;; Its spacers are as high: 501 items in 40,744 px.
           (check (view-average-item-height new) => (view-average-item-height v))
           (check (view-average-item-height new) => (/ 40744. 501))))))))
