;;; The default layout plugin, through the layout contract and its own
;;; commands (tabs, zooming), driven through the real editor loop:
;;; splitting and deleting, neighbors and focus memory, tabs, the frame
;;; and its zoom (onto a node too), frame marks, display-buffer and
;;; dedicated views, and the session slot.
(import :std/test
        :tuna/kernel
        :tuna/services/buffers
        :tuna/services/session
        :tuna/services/layout
        :tuna/plugins/keys
        :tuna/plugins/rope
        :tuna/plugins/settings
        :tuna/plugins/session
        :tuna/plugins/buffers
        :tuna/plugins/layout
        "../test-support/kernel"
        "../test-support/keys"
        "../test-support/session"
        (only-in "../test-support/string-input" test-messages-plugin current-message))
(export layout-test)

(def layout-plugins
  [keys-plugin test-messages-plugin rope-text-store-plugin settings-plugin no-session-plugin
   buffers-plugin layout-plugin])

(def (with-layout thunk)
  (call-with-fresh-kernel layout-plugins
    (lambda ()
      (start-editor-loop!)
      (thunk))))

(def (on-baton thunk) (call-on-editor-loop thunk))

(def (index-of v)
  (let lp ((views (view-list)) (i 0))
    (cond
     ((null? views) #f)
     ((eq? (car views) v) i)
     (else (lp (cdr views) (+ i 1))))))

(def (nth i) (on-baton (lambda () (list-ref (view-list) i))))

(def (selected-index) (on-baton (lambda () (index-of (selected-view)))))

;; Each view's buffer name and point, in order.
(def (views-state)
  (on-baton (lambda () (map (lambda (v) [(buffer-name (view-showing v)) (view-point v)]) (view-list)))))

;; What the frame shows: each view drawn, as its index, whether it is
;; selected, and the kind of the node it is drawn from.
(def (shown)
  (on-baton
   (lambda ()
     (render-layout 'test (lambda (v selected? start) [(index-of v) selected? (node-kind start)])))))

;; The layout as 'html, each view drawn as (view INDEX).
(def (layout-html)
  (on-baton (lambda () (render-layout 'html (lambda (v selected? start) ['view (index-of v)])))))

(def (target-part)
  (on-baton (lambda () (frame-target-part (current-frame-target)))))

(def (split! i side) (on-baton (lambda () (split-view (list-ref (view-list) i) side))))
(def (select! i) (on-baton (lambda () (select-view (list-ref (view-list) i)))))
(def (frame-on! i) (on-baton (lambda () (move-frame (make-frame-target (view-id (list-ref (view-list) i)) #f)))))
(def (neighbor i direction)
  (on-baton (lambda () (let (v (neighbor-view (list-ref (view-list) i) direction)) (and v (index-of v))))))
(def (message-now) (on-baton current-message))

;; Every element of TREE, at any depth, for which (MATCH? element) holds.
(def (elements-where match? tree)
  (cond
   ((not (pair? tree)) [])
   ((match? tree) (cons tree (append-elements match? (cdr tree))))
   (else (append-elements match? tree))))

(def (append-elements match? trees)
  (let lp ((rest trees) (out []))
    (if (pair? rest)
      (lp (cdr rest) (append out (elements-where match? (car rest))))
      out)))

(def (attribute element name)
  (match element
    ([_ ['@ . attributes] . _] (let (pair (assq name attributes)) (and pair (cadr pair))))
    (else #f)))

(def (with-class class)
  (lambda (element)
    (and (symbol? (car element))
         (equal? (attribute element 'class) class))))

(def (call-with-state-directory proc)
  (let (directory (path-expand (string-append "tuna-layout-test-"
                                              (number->string (random-integer 1000000000)))
                               (getenv "TMPDIR" "/tmp")))
    (create-directory* directory)
    (try
     (proc directory)
     (finally
      (delete-file-or-directory directory #t)))))

(def layout-test
  (test-suite "tuna/plugins/layout"
    (test-case "splitting shows the same buffer at the same point; deleting keeps the last view"
      (with-layout
       (lambda ()
         (on-baton (lambda () (insert "hello") (goto-char 3)))
         (split! 0 'right)
         (check (views-state) => [["*scratch*" 3] ["*scratch*" 3]])
         (check (shown) => [[0 #t 'text] [1 #f 'text]])
         (split! 1 'below)
         (check (length (views-state)) => 3)
         (check (selected-index) => 0)
         (on-baton (lambda () (delete-view (list-ref (view-list) 0))))
         ;; The selected view went; another under the frame is selected.
         (check (length (views-state)) => 2)
         (check (and (selected-index) #t) => #t)
         (on-baton (lambda () (delete-view (list-ref (view-list) 0))))
         (check (on-baton (lambda ()
                            (with-catch (lambda (e) 'refused)
                                        (lambda () (delete-view (selected-view)) 'deleted))))
                => 'refused)
         (check (length (views-state)) => 1))))

    (test-case "moving to neighbors returns into containers where the focus was"
      (with-layout
       (lambda ()
         ;; 0 | (1 / 2)
         (split! 0 'right)
         (split! 1 'below)
         (check (neighbor 0 'right) => 1)
         (select! 2)
         (check (neighbor 2 'left) => 0)
         (check (neighbor 2 'up) => 1)
         (check (neighbor 2 'down) => #f)
         (select! 0)
         ;; The right-hand container remembers 2.
         (check (neighbor 0 'right) => 2)
         (select! 1)
         (select! 0)
         (check (neighbor 0 'right) => 1))))

    (test-case "tabs: a new tab, switching, focus memory inside a tab, closing"
      (with-layout
       (lambda ()
         (type! "C-x" "t" "o")
         (check (message-now) => "No tabs here")
         (type! "C-x" "t" "2")
         (check (selected-index) => 1)
         (check (shown) => [[1 #t 'text]])
         (let (tabs (elements-where (with-class "tab") (layout-html)))
           (check (map (lambda (tab) (attribute tab 'aria-selected)) tabs) => ["false" "true"])
           (check (map last tabs) => ["*scratch*" "*scratch*"]))
         (type! "C-x" "t" "O")
         (check (shown) => [[0 #t 'text]])
         (type! "C-x" "t" "o")
         (check (selected-index) => 1)
         ;; Inside the second tab: 1 / 2, with 2 focused.
         (split! 1 'below)
         (select! 2)
         (type! "C-x" "t" "o")
         (check (selected-index) => 0)
         (type! "C-x" "t" "o")
         (check (selected-index) => 2)
         (check (shown) => [[1 #f 'text] [2 #t 'text]])
         (type! "C-x" "t" "0")
         (check (length (views-state)) => 1)
         (check (shown) => [[0 #t 'text]])
         (type! "C-x" "t" "0")
         (check (message-now) => "Cannot close the last view"))))

    (test-case "zooming the frame in and out one level at a time"
      (with-layout
       (lambda ()
         ;; 0 | (1 / 2), 2 selected.
         (split! 0 'right)
         (split! 1 'below)
         (select! 2)
         (check (target-part) => #f)
         (type! "C-x" "n" "i")
         (check (shown) => [[1 #f 'text] [2 #t 'text]])
         (type! "C-x" "n" "i")
         (check (shown) => [[2 #t 'text]])
         (check (target-part) => (on-baton (lambda () (view-id (selected-view)))))
         (type! "C-x" "n" "i")
         (check (message-now) => "The frame is on the selected view")
         ;; C-x o cycles through what the frame shows only.
         (check (on-baton (lambda () (index-of (next-view (selected-view))))) => 2)
         (type! "C-x" "n" "o")
         (check (shown) => [[1 #f 'text] [2 #t 'text]])
         (type! "C-x" "n" "o")
         (check (shown) => [[0 #f 'text] [1 #f 'text] [2 #t 'text]])
         (type! "C-x" "n" "o")
         (check (message-now) => "The frame is at the top")
         ;; Moving the frame onto another view selects it.
         (frame-on! 0)
         (check (selected-index) => 0)
         ;; Selecting a view outside the frame moves the frame up to hold it.
         (select! 2)
         (check (target-part) => #f))))

    (test-case "the frame onto a node inside a buffer, and back out"
      (with-layout
       (lambda ()
         (let (text-node
               (on-baton
                (lambda ()
                  (let* ((text (new-text-node (new-text "inside")))
                         (b (new-buffer "tree" (new-node 'column
                                                         children: [(new-node 'heading) text]))))
                    (add-buffer! b)
                    (set-view-buffer (selected-view) b)
                    text))))
           (check (shown) => [[0 #t 'column]])
           (on-baton (lambda () (move-frame (make-frame-target (view-id (selected-view)) text-node))))
           (check (shown) => [[0 #t 'text]])
           (check (on-baton (lambda () (frame-target-start (current-frame-target)))) => text-node)
           (type! "C-x" "n" "o")
           (check (shown) => [[0 #t 'column]])
           (check (on-baton (lambda () (frame-target-start (current-frame-target)))) => #f)
           (type! "C-x" "n" "o")
           (check (message-now) => "The frame is at the top")
           ;; Showing another buffer in the view leaves the node behind.
           (on-baton (lambda () (move-frame (make-frame-target (view-id (selected-view)) text-node))))
           (on-baton (lambda () (set-view-buffer (selected-view) (get-buffer "*scratch*"))))
           (check (on-baton (lambda () (frame-target-start (current-frame-target)))) => #f)
           (check (shown) => [[0 #t 'text]])))))

    (test-case "an edit that removes the frame's target moves the frame to what replaces it"
      (with-layout
       (lambda ()
         ;; 0 | (1 / 2); the frame on (1 / 2), 2 selected.
         (split! 0 'right)
         (split! 1 'below)
         (select! 2)
         (type! "C-x" "n" "i")
         (on-baton (lambda () (delete-view (selected-view))))
         ;; (1 / 2) collapsed into 1: the frame follows it.
         (check (shown) => [[1 #t 'text]])
         (check (target-part) => (on-baton (lambda () (view-id (list-ref (view-list) 1))))))))

    (test-case "frame marks point at parts, survive rearranging, and drop when the part is gone"
      (with-layout
       (lambda ()
         (split! 0 'right)
         (frame-on! 1)
         (on-baton (lambda () (set-frame-mark "one")))
         (on-baton (lambda () (set-frame-mark "top-view")))
         (on-baton (lambda () (move-frame (make-frame-target #f #f))))
         (on-baton (lambda () (set-frame-mark "all")))
         (check (on-baton frame-mark-names) => ["one" "top-view" "all"])
         ;; Rearrange: split 0 below (0 / 1) | 2, make 2 a tab.
         (split! 0 'below)
         (select! 2)
         (type! "C-x" "t" "2")
         (check (on-baton (lambda () (jump-to-frame-mark "one"))) => 'jumped)
         (check (target-part) => (on-baton (lambda () (view-id (list-ref (view-list) 2)))))
         (check (shown) => [[2 #t 'text]])
         (check (on-baton (lambda () (jump-to-frame-mark "all"))) => 'jumped)
         (check (target-part) => #f)
         (on-baton (lambda () (delete-view (list-ref (view-list) 2))))
         (check (on-baton (lambda () (jump-to-frame-mark "one"))) => 'gone)
         (check (on-baton frame-mark-names) => ["top-view" "all"])
         (check (on-baton (lambda () (jump-to-frame-mark "nope"))) => 'unknown))))

    (test-case "display-buffer: side views are dedicated and close with their buffer"
      (with-layout
       (lambda ()
         (let (side (on-baton (lambda ()
                                (let (b (new-buffer "side" (new-text-node (new-text "s"))))
                                  (add-buffer! b)
                                  (display-buffer b side: 'left size: 1/5)
                                  b))))
           (check (views-state) => [["side" 1] ["*scratch*" 1]])
           ;; The selected view stays; the side view is not selected.
           (check (selected-index) => 1)
           (let (fit (car (elements-where (with-class "container fit horizontal") (layout-html))))
             (check (map (lambda (child) (attribute child 'style)) (cddr fit))
                    => ["--tuna-size: .2" "--tuna-size: .8"]))
           ;; Displaying it again reuses its view.
           (on-baton (lambda () (display-buffer side side: 'right)))
           (check (length (views-state)) => 2)
           (on-baton (lambda () (kill-buffer side)))
           (check (views-state) => [["*scratch*" 1]])))))

    (test-case "display-buffer without a side, and killing a buffer in ordinary views"
      (with-layout
       (lambda ()
         (let* ((make (lambda (name)
                        (on-baton (lambda ()
                                    (let (b (new-buffer name (new-text-node (new-text name))))
                                      (add-buffer! b)
                                      b)))))
                (a (make "a"))
                (b (make "b")))
           ;; With no other view: a dedicated view below the selected one.
           (on-baton (lambda () (display-buffer a)))
           (check (views-state) => [["*scratch*" 1] ["a" 1]])
           (on-baton (lambda () (kill-buffer a)))
           (check (views-state) => [["*scratch*" 1]])
           ;; Another ordinary view is reused; killing its buffer shows another.
           (split! 0 'right)
           (on-baton (lambda () (display-buffer b)))
           (check (views-state) => [["*scratch*" 1] ["b" 1]])
           (on-baton (lambda () (kill-buffer b)))
           (check (views-state) => [["*scratch*" 1] ["*scratch*" 1]])))))

    (test-case "a side view joins what the frame shows"
      (with-layout
       (lambda ()
         (split! 0 'right)
         (frame-on! 0)
         (on-baton (lambda ()
                     (let (b (new-buffer "side" (new-text-node (new-text "s"))))
                       (add-buffer! b)
                       (display-buffer b side: 'top))))
         (check (shown) => [[0 #f 'text] [1 #t 'text]])
         (check (map car (views-state)) => ["side" "*scratch*" "*scratch*"]))))

    (test-case "the session slot saves the tree, the frame and frame marks, and skips missing buffers"
      (call-with-state-directory
       (lambda (directory)
         (def (run thunk)
           (call-with-fresh-kernel []
             (lambda ()
               (parameterize ((session-state-directory directory))
                 (for-each activate-plugin!
                           (map (lambda (p) (if (eq? p no-session-plugin) session-plugin p))
                                layout-plugins)))
               (restore-session)
               (start-editor-loop!)
               (thunk))))
         (run (lambda ()
                (on-baton (lambda ()
                            (let (b (new-buffer "temporary" (new-text-node (new-text "t"))))
                              (add-buffer! b)
                              (display-buffer b side: 'right))))
                (split! 0 'below)
                (type! "C-x" "t" "2")
                (on-baton (lambda () (set-frame-mark "tabs")))
                (frame-on! 2)
                (check (map car (views-state)) => ["*scratch*" "*scratch*" "*scratch*" "temporary"])
                (on-baton save-session)))
         (run (lambda ()
                ;; "temporary" is not restored (nothing saves it), so its view is skipped.
                (check (map car (views-state)) => ["*scratch*" "*scratch*" "*scratch*"])
                (check (selected-index) => 2)
                (check (shown) => [[2 #t 'text]])
                (check (on-baton frame-mark-names) => ["tabs"])
                (check (on-baton (lambda () (jump-to-frame-mark "tabs"))) => 'jumped)
                (check (shown) => [[1 #f 'text] [2 #t 'text]])
                (check (length (elements-where (with-class "tab") (layout-html))) => 2))))))))
