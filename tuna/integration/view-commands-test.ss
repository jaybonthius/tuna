;;; Integration: the view and frame commands of view-commands, bound by
;;; keys, under the default layout: C-x 2, C-x 3, C-x 0, C-x 1, C-x o,
;;; S-<arrows>, C-x n s, C-x n w, and the frame marks on C-x r w, C-x r j
;;; and C-x r l, read in the minibuffer; and the same commands under the
;;; toy layout, which falls back as the contract allows. The bar (the
;;; minibuffer's and echo area's views, pinned and locked) is left out of
;;; the views these tests count, except where they check it stays.
(import :std/test
        :tuna/kernel
        :tuna/services/buffers
        :tuna/services/echo-area
        :tuna/services/layout
        :tuna/plugins/keys
        :tuna/plugins/echo-area
        :tuna/plugins/rope
        :tuna/plugins/settings
        :tuna/plugins/buffers
        :tuna/plugins/layout
        :tuna/plugins/view-commands
        :tuna/plugins/basic-editing
        :tuna/plugins/minibuffer
        "../test-support/kernel"
        "../test-support/keys"
        "../test-support/session"
        "../test-support/swap-commands"
        "../test-support/tree-buffer")
(export view-commands-test)

(def command-plugins
  [keys-plugin echo-area-plugin rope-text-store-plugin settings-plugin no-session-plugin
   buffers-plugin layout-plugin view-commands-plugin basic-editing-plugin minibuffer-plugin
   swap-commands-plugin tree-buffer-plugin])

(def (with-commands thunk)
  (call-with-fresh-kernel command-plugins
    (lambda ()
      (start-editor-loop!)
      (thunk))))

(def (on-baton thunk) (call-on-editor-loop thunk))

;; The views outside the bar, whose buffers are not internal.
(def (own-views)
  (filter (lambda (v) (not (internal-buffer? (view-showing v)))) (view-list)))

(def (index-of v)
  (let lp ((views (own-views)) (i 0))
    (cond
     ((null? views) #f)
     ((eq? (car views) v) i)
     (else (lp (cdr views) (+ i 1))))))

;; Each view's buffer name and point, in order, and the selected index.
(def (views-state)
  (on-baton (lambda () [(map (lambda (v) [(buffer-name (view-showing v)) (view-point v)]) (own-views))
                        (index-of (selected-view))])))

;; The indexes of the views the frame shows outside the bar, and the kinds
;; of the nodes they are drawn from.
(def (shown)
  (on-baton (lambda ()
              (filter identity
                      (render-layout 'test (lambda (v selected? start)
                                             (and (index-of v) [(index-of v) (node-kind start)])))))))

;; The names of the bar's buffers the frame shows.
(def (bar-shown)
  (on-baton (lambda ()
              (filter identity
                      (render-layout 'test (lambda (v selected? start)
                                             (and (internal-buffer? (view-showing v))
                                                  (buffer-name (view-showing v)))))))))

(def (message-now) (on-baton current-message))

(def view-commands-test
  (test-suite "integration: view and frame commands"
    (test-case "C-x 2, C-x 3 and C-x 0 split and delete; S-arrows and C-x o move"
      (with-commands
       (lambda ()
         (type! "a" "b" "c" "C-x" "3")
         (check (views-state) => [[["*scratch*" 4] ["*scratch*" 4]] 0])
         (type! "S-<right>" "C-x" "2")
         ;; 0 | (1 / 2)
         (check (views-state) => [[["*scratch*" 4] ["*scratch*" 4] ["*scratch*" 4]] 1])
         (type! "S-<down>" "C-a")
         (check (views-state) => [[["*scratch*" 4] ["*scratch*" 4] ["*scratch*" 1]] 2])
         (type! "S-<down>")
         (check (message-now) => "No view below")
         (type! "S-<left>")
         (check (cadr (views-state)) => 0)
         ;; Back right: the column remembers its lower view.
         (type! "S-<right>")
         (check (cadr (views-state)) => 2)
         (type! "S-<up>" "C-x" "o")
         (check (cadr (views-state)) => 2)
         (type! "C-x" "0")
         (check (views-state) => [[["*scratch*" 4] ["*scratch*" 4]] 1])
         (type! "C-x" "0" "C-x" "0")
         (check (views-state) => [[["*scratch*" 4]] 0]))))

    (test-case "C-x 1 points the frame at the selected view; C-x n w back at the whole layout"
      (with-commands
       (lambda ()
         (type! "C-x" "3" "C-x" "2")
         (check (length (shown)) => 3)
         (type! "C-x" "1")
         (check (shown) => [[0 'text]])
         ;; The bar is pinned: it stays.
         (check (bar-shown) => [" *Echo Area*" " *Minibuf-0*"])
         ;; Splitting the view the frame is on keeps both in the frame.
         (type! "C-x" "3")
         (check (shown) => [[0 'text] [1 'text]])
         (type! "C-x" "n" "w")
         (check (length (shown)) => 4))))

    (test-case "C-x n s points the frame at the node holding point"
      (with-commands
       (lambda ()
         ;; *scratch* is one text node: the frame goes to the whole view.
         (type! "C-x" "3" "C-x" "n" "s")
         (check (shown) => [[0 'text]])
         (type! "C-x" "n" "w" "C-c" "b")
         (check (shown) => [[0 'column] [1 'text]])
         (type! "C-x" "n" "s")
         (check (shown) => [[0 'text]])
         (check (on-baton (lambda () (node-kind (frame-target-start (current-frame-target)))))
                => 'text)
         ;; Typing goes on in the framed node.
         (type! "H" "i")
         (check (on-baton (lambda () (string-prefix? "Hi" (text-string (current-text))))) => #t))))

    (test-case "frame marks: C-x r w sets, C-x r j jumps, C-x r l lists"
      (with-commands
       (lambda ()
         (type! "C-x" "r" "l")
         (check (message-now) => "No frame marks")
         (type! "C-x" "3" "C-x" "1" "C-x" "r" "w" "o" "n" "e" "RET")
         (check (message-now) => "Frame mark one set")
         (type! "C-x" "n" "w" "C-x" "r" "w" "a" "l" "l" "RET" "C-x" "r" "l")
         (check (message-now) => "Frame marks: one, all")
         (type! "C-x" "r" "j" "o" "n" "e" "RET")
         (check (shown) => [[0 'text]])
         (type! "C-x" "r" "j" "a" "l" "l" "RET")
         (check (length (shown)) => 2)
         (type! "C-x" "0")
         (type! "C-x" "r" "j" "o" "n" "e" "RET")
         (check (message-now) => "Frame mark one pointed at a part that is gone; dropped it")
         (type! "C-x" "r" "j" "o" "n" "e" "RET")
         (check (message-now) => "No frame mark named one"))))

    (test-case "clicking a view or its status line selects it; the bar's views refuse; a gone view says so"
      (with-commands
       (lambda ()
         (type! "a" "b" "C-x" "3")
         (let ((left (on-baton (lambda () (view-id (car (own-views))))))
               (right (on-baton (lambda () (view-id (cadr (own-views))))))
               (echo-area (on-baton (lambda ()
                                      (view-id (find (lambda (v)
                                                       (equal? (buffer-name (view-showing v)) " *Echo Area*"))
                                                     (view-list)))))))
           (click 'view right)
           (check (cadr (views-state)) => 1)
           ;; Keys typed after the click go to the view it selected.
           (type! "C-a")
           (check (views-state) => [[["*scratch*" 3] ["*scratch*" 1]] 1])
           (click 'status-line left)
           (check (cadr (views-state)) => 0)
           (click 'view right clicks: 2)
           (check (cadr (views-state)) => 1)
           ;; The echo area's view is skipped by other-view: a click
           ;; leaves the selection, and the message, alone.
           (on-baton (lambda () (message "still here")))
           (click 'view echo-area)
           (check (cadr (views-state)) => 1)
           (check (message-now) => "still here")
           (type! "C-x" "0")
           (click 'view right revision: 7)
           (check (message-now) => "Stale click: the view is gone (clicked on screen 7)")
           (check (views-state) => [[["*scratch*" 3]] 0])
           ;; The binding uses only the layout contract: it works under the toy layout.
           (type! "C-c" "w")
           (click 'view (on-baton (lambda () (view-id (cadr (own-views))))))
           (check (cadr (views-state)) => 1)))))

    (test-case "under the toy layout the commands fall back as the contract allows"
      (with-commands
       (lambda ()
         (type! "C-c" "w" "C-x" "1")
         ;; The toy's frame always shows the whole layout.
         (check (shown) => [[0 'text] [1 'text]])
         (type! "S-<right>")
         (check (cadr (views-state)) => 1)
         (type! "S-<right>")
         (check (message-now) => "No view to the right")
         (type! "C-x" "2")
         (check (length (car (views-state))) => 2)
         (type! "C-x" "r" "w" "m" "RET" "C-x" "r" "j" "m" "RET")
         (check (shown) => [[0 'text] [1 'text]]))))))
