;;; The default layout plugin, through the layout contract and its own
;;; commands (tabs, zooming), driven through the real editor loop:
;;; splitting and deleting, neighbors and focus memory, tabs, the frame
;;; and its zoom (onto a node too), frame marks, display-buffer and
;;; dedicated views, pins, locks and moves, and the session slot.
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

;; Show a new buffer NAME, holding one text node, in view I.
(def (named! i name)
  (on-baton (lambda ()
              (let (b (new-buffer name (new-text-node (new-text name))))
                (add-buffer! b)
                (set-view-buffer (list-ref (view-list) i) b)))))

;; The views drawn, by their buffers' names; the selected one as [name].
(def (drawn-names)
  (on-baton
   (lambda ()
     (render-layout 'test (lambda (v selected? start)
                            (let (name (buffer-name (view-showing v)))
                              (if selected? [name] name)))))))

(def (view-named name)
  (find (lambda (v) (equal? (buffer-name (view-showing v)) name)) (view-list)))

(def (select-named! name) (on-baton (lambda () (select-view (view-named name)))))
(def (frame-on-named! name)
  (on-baton (lambda () (move-frame (make-frame-target (view-id (view-named name)) #f)))))

;; A locked view of a new buffer NAME in the bar.
(def (lock-new! name)
  (on-baton (lambda ()
              (let (b (new-buffer name (new-text-node (new-text name))))
                (add-buffer! b)
                (add-locked-view b side: 'bottom size: 'content)
                b))))

;; The classes of the containers drawn, outermost first.
(def (container-classes)
  (map (lambda (e) (attribute e 'class))
       (elements-where (lambda (e)
                         (and (symbol? (car e))
                              (let (class (attribute e 'class))
                                (and (string? class) (string-prefix? "container " class)))))
                       (layout-html))))

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

    (test-case "clicking a tab switches to it; a click on a tab that is gone says so and does nothing"
      (with-layout
       (lambda ()
         ;; Tabs: view 0, and (1 / 2) with 2 focused.
         (type! "C-x" "t" "2")
         (split! 1 'below)
         (select! 2)
         (let* ((first (on-baton (lambda () (view-id (list-ref (view-list) 0)))))
                (tabs (elements-where (with-class "tab") (layout-html)))
                (second-part (attribute (cadr tabs) 'data-part))
                (second (string->number (substring second-part 9 (string-length second-part)))))
           (check (attribute (car tabs) 'data-part) => (string-append "tab-line:" (number->string first)))
           (check (string-prefix? "tab-line:" second-part) => #t)
           (check (map (lambda (tab) (attribute tab 'data-clickable)) tabs) => ["" ""])
           (click 'tab-line first)
           (check (selected-index) => 0)
           (check (shown) => [[0 #t 'text]])
           ;; A tab showing a container selects its last-focused view; a
           ;; double click falls back to the single click.
           (click 'tab-line second clicks: 2)
           (check (selected-index) => 2)
           (select! 0)
           (type! "C-x" "t" "0")
           (check (length (views-state)) => 2)
           (click 'tab-line first revision: 41)
           (check (message-now) => "Stale click: the tab is gone (clicked on screen 41)")
           (check (selected-index) => 1)
           (check (shown) => [[0 #f 'text] [1 #t 'text]])))))

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
         (check (message-now) => "The frame is on a view")
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
                (check (length (elements-where (with-class "tab") (layout-html))) => 2))))))

    (test-case "several pins stay drawn while zoomed; moving between views visits only the drawn ones"
      (with-layout
       (lambda ()
         ;; a | (b / c / d)
         (split! 0 'right)
         (split! 1 'below)
         (split! 2 'below)
         (for-each named! [0 1 2 3] ["a" "b" "c" "d"])
         (check (drawn-names) => [["a"] "b" "c" "d"])
         (type! "C-x" "w" "p")
         (select-named! "d")
         (type! "C-x" "w" "p")
         ;; With no zoom, pins make no difference.
         (check (drawn-names) => ["a" "b" "c" ["d"]])
         (frame-on-named! "b")
         (check (drawn-names) => ["a" ["b"] "d"])
         (check (on-baton (lambda () (buffer-name (view-showing (next-view (selected-view)))))) => "d")
         (check (on-baton (lambda () (buffer-name (view-showing (neighbor-view (selected-view) 'down)))))
                => "d")
         ;; The child on the way takes the space the pinned children leave.
         (let (column (car (elements-where (with-class "container fit vertical") (layout-html))))
           (check (map (lambda (child) (attribute child 'style)) (cddr column))
                  => ["--tuna-size: 1.5" "--tuna-size: .5"])))))

    (test-case "selecting a pinned view keeps the zoom; unpinning it while zoomed selects a drawn view"
      (with-layout
       (lambda ()
         (split! 0 'right)
         (split! 1 'below)
         (for-each named! [0 1 2] ["a" "b" "c"])
         (select-named! "c")
         (type! "C-x" "w" "p")
         (frame-on-named! "b")
         (let (target (target-part))
           (select-named! "c")
           (check (target-part) => target)
           (check (drawn-names) => ["b" ["c"]])
           (type! "C-x" "w" "u")
           (check (message-now) => "Unpinned the view of c")
           (check (drawn-names) => [["b"]])
           (check (target-part) => target)))))

    (test-case "the selected part: pinning a container"
      (with-layout
       (lambda ()
         ;; a | (b / c), the column pinned.
         (split! 0 'right)
         (split! 1 'below)
         (for-each named! [0 1 2] ["a" "b" "c"])
         (select-named! "b")
         (type! "C-x" "w" "a")
         (check (message-now) => "Selected part: a fit vertical container of 2 views")
         (check (length (elements-where (lambda (e) (and (symbol? (car e)) (attribute e 'data-selected-part)))
                                        (layout-html)))
                => 1)
         (type! "C-x" "w" "p")
         (type! "C-x" "w" "a" "C-x" "w" "a")
         (check (message-now) => "The selected part is the whole layout")
         (type! "C-x" "w" "c" "C-x" "w" "c")
         (check (message-now) => "Selected part: the view of b")
         (type! "C-x" "w" "c")
         (check (message-now) => "The selected part is the selected view")
         (frame-on-named! "a")
         (check (drawn-names) => [["a"] "b" "c"]))))

    (test-case "moving the selected part; a pinned part keeps its pin when it moves"
      (with-layout
       (lambda ()
         ;; a | (b / c), c pinned.
         (split! 0 'right)
         (split! 1 'below)
         (for-each named! [0 1 2] ["a" "b" "c"])
         (select-named! "c")
         (type! "C-x" "w" "p")
         (type! "C-x" "w" "<up>")
         (check (on-baton (lambda () (map (lambda (v) (buffer-name (view-showing v))) (view-list))))
                => ["a" "c" "b"])
         ;; Out of the column to the left: a | c | b.
         (type! "C-x" "w" "<left>")
         (check (on-baton (lambda () (map (lambda (v) (buffer-name (view-showing v))) (view-list))))
                => ["a" "c" "b"])
         (check (length (elements-where (with-class "container fit vertical") (layout-html))) => 0)
         (type! "C-x" "w" "<left>")
         (check (on-baton (lambda () (map (lambda (v) (buffer-name (view-showing v))) (view-list))))
                => ["c" "a" "b"])
         (type! "C-x" "w" "<left>")
         (check (message-now) => "Cannot move further that way")
         ;; The pin moved with it.
         (frame-on-named! "b")
         (check (drawn-names) => ["c" ["b"]])
         ;; Moving the selected view out of the zoom moves the frame to keep it drawn.
         (select-named! "c")
         (type! "C-x" "w" "<right>" "C-x" "w" "<right>")
         (check (on-baton (lambda () (map (lambda (v) (buffer-name (view-showing v))) (view-list))))
                => ["a" "b" "c"])
         (check (member ["c"] (drawn-names)) ? pair?))))

    (test-case "a locked part refuses unpinning and deleting, and goes with its buffer"
      (with-layout
       (lambda ()
         (named! 0 "a")
         (let ((bar (lock-new! "bar"))
               (status (lock-new! "status")))
           (check (drawn-names) => [["a"] "bar" "status"])
           ;; The two share one container in the bar, all sized by content.
           (check (length (elements-where (lambda (e) (and (symbol? (car e))
                                                           (equal? (attribute e 'data-size) "content")))
                                          (layout-html)))
                  => 3)
           (frame-on-named! "a")
           (check (drawn-names) => [["a"] "bar" "status"])
           (select-named! "bar")
           (type! "C-x" "w" "u")
           (check (message-now) => "Locked: the plugin that owns it keeps it pinned")
           (check (on-baton (lambda ()
                              (with-catch (lambda (e) 'refused)
                                          (lambda () (delete-view (selected-view)) 'deleted))))
                  => 'refused)
           ;; Nor may the last view outside locked parts go.
           (select-named! "a")
           (check (on-baton (lambda ()
                              (with-catch (lambda (e) 'refused)
                                          (lambda () (delete-view (selected-view)) 'deleted))))
                  => 'refused)
           ;; Showing the buffer again reuses its view.
           (check (on-baton (lambda () (eq? (add-locked-view bar) (view-named "bar")))) => #t)
           (on-baton (lambda () (kill-buffer bar) (kill-buffer status)))
           (check (drawn-names) => [["a"]])))))

    (test-case "weights left summing below 1 beside a part sized by content still fill the space"
      (with-layout
       (lambda ()
         (lock-new! "bar")
         ;; (a 1/2 / b 1/2 / bar); deleting b leaves a's 1/2 beside the bar.
         (split! 0 'below)
         (on-baton (lambda () (delete-view (list-ref (view-list) 1))))
         (check (map (lambda (e) (attribute e 'style))
                     (elements-where (lambda (e) (eq? (car e) 'view)) (layout-html)))
                => ["--tuna-size: 1" #f]))))

    (test-case "zooming into a tab with a pinned sibling tab shows both tabs"
      (with-layout
       (lambda ()
         (named! 0 "a")
         (type! "C-x" "t" "2")
         (named! 1 "b")
         (type! "C-x" "w" "p")
         (type! "C-x" "t" "2")
         (named! 2 "c")
         (select-named! "a")
         (frame-on-named! "a")
         (let (tabs (elements-where (with-class "tab") (layout-html)))
           (check (map last tabs) => ["a" "b"])
           (check (map (lambda (tab) (attribute tab 'aria-selected)) tabs) => ["true" "false"]))
         (check (drawn-names) => [["a"]]))))

    (test-case "the frame's target inside a pinned part"
      (with-layout
       (lambda ()
         ;; a | b | c, a and b pinned.
         (split! 0 'right)
         (split! 1 'right)
         (for-each named! [0 1 2] ["a" "b" "c"])
         (type! "C-x" "w" "p")
         (select-named! "b")
         (type! "C-x" "w" "p")
         (frame-on-named! "b")
         (check (drawn-names) => ["a" ["b"]])
         (frame-on-named! "c")
         (check (drawn-names) => ["a" "b" ["c"]]))))

    (test-case "nested tabs: wrapping a view in tabs, then a new tab joins the inner group"
      (with-layout
       (lambda ()
         ;; a | b, b selected.
         (split! 0 'right)
         (for-each named! [0 1] ["a" "b"])
         (select-named! "b")
         (type! "C-x" "w" "t")
         (check (message-now) => "Wrapped the view of b in a tabbed horizontal container of 1 view")
         (check (drawn-names) => ["a" ["b"]])
         (type! "C-x" "t" "2")
         (check (map car (views-state)) => ["a" "b" "b"])
         (check (selected-index) => 2)
         (check (container-classes) => ["container fit horizontal" "container tabbed horizontal"])
         (let (tabs (elements-where (with-class "tab") (layout-html)))
           (check (map (lambda (tab) (attribute tab 'aria-selected)) tabs) => ["false" "true"]))
         (check (drawn-names) => ["a" ["b"]])
         ;; Once more inside the new tab: tabs within tabs.
         (type! "C-x" "w" "t" "C-x" "t" "2")
         (check (map car (views-state)) => ["a" "b" "b" "b"])
         (check (container-classes)
                => ["container fit horizontal" "container tabbed horizontal" "container tabbed horizontal"])
         (check (length (elements-where (with-class "tab") (layout-html))) => 4)
         ;; The inner group's tabs switch inside it.
         (type! "C-x" "t" "o")
         (check (selected-index) => 2)
         (type! "C-x" "t" "o")
         (check (selected-index) => 3))))

    (test-case "wrapping the selected container: its pin moves to the wrapper, its views stay selected"
      (with-layout
       (lambda ()
         ;; a | (b / c), the column selected and pinned.
         (split! 0 'right)
         (split! 1 'below)
         (for-each named! [0 1 2] ["a" "b" "c"])
         (select-named! "b")
         (type! "C-x" "w" "a" "C-x" "w" "p" "C-x" "w" "3")
         (check (message-now)
                => "Wrapped a fit vertical container of 2 views in a fit horizontal container of 2 views")
         (check (container-classes)
                => ["container fit horizontal" "container fit horizontal" "container fit vertical"])
         (check (drawn-names) => ["a" ["b"] "c"])
         ;; The column is still the selected part.
         (check (map (lambda (e) (attribute e 'class))
                     (elements-where (lambda (e) (and (symbol? (car e)) (attribute e 'data-selected-part)))
                                     (layout-html)))
                => ["container fit vertical"])
         ;; The wrapper took the pin: zoomed on a, the column still shows.
         (frame-on-named! "a")
         (check (drawn-names) => [["a"] "b" "c"]))))

    (test-case "changing a container's kind and direction; for a view, its container's"
      (with-layout
       (lambda ()
         (type! "C-x" "w" "k")
         (check (message-now) => "The selected view is in no container")
         ;; a | (b / c), b selected.
         (split! 0 'right)
         (split! 1 'below)
         (for-each named! [0 1 2] ["a" "b" "c"])
         (select-named! "b")
         (type! "C-x" "w" "k")
         (check (message-now) => "Now a tabbed vertical container of 2 views")
         (check (container-classes) => ["container fit horizontal" "container tabbed vertical"])
         (check (drawn-names) => ["a" ["b"]])
         (type! "C-x" "w" "d")
         (check (container-classes) => ["container fit horizontal" "container tabbed horizontal"])
         ;; The focus memory stays: c, focused inside the tabs, comes back.
         (select-named! "c")
         (select-named! "a")
         (type! "C-x" "w" "d")
         (check (container-classes) => ["container fit vertical" "container tabbed horizontal"])
         (check (drawn-names) => [["a"] "c"])
         ;; The selected part's container: the tabs, made fit again.
         (select-named! "c")
         (type! "C-x" "w" "a" "C-x" "w" "k")
         (check (container-classes) => ["container fit vertical" "container fit horizontal"])
         (check (drawn-names) => ["a" "b" ["c"]]))))

    (test-case "wrapping the whole layout makes a new root; C-x t 2 then adds a tab beside everything"
      (with-layout
       (lambda ()
         ;; a | b, b selected.
         (split! 0 'right)
         (for-each named! [0 1] ["a" "b"])
         (select-named! "b")
         (type! "C-x" "w" "a" "C-x" "w" "t")
         (check (container-classes) => ["container tabbed horizontal" "container fit horizontal"])
         (check (drawn-names) => ["a" ["b"]])
         (type! "C-x" "t" "2")
         (check (drawn-names) => [["b"]])
         (type! "C-x" "t" "O")
         (check (drawn-names) => ["a" ["b"]]))))

    (test-case "a locked part, or a part holding one, is neither wrapped nor reshaped"
      (with-layout
       (lambda ()
         (named! 0 "a")
         (lock-new! "bar")
         (check (container-classes) => ["container fit vertical"])
         ;; a's container holds the bar.
         (type! "C-x" "w" "k")
         (check (message-now) => "It holds a locked part, which the plugin that owns it arranges")
         (type! "C-x" "w" "d")
         (type! "C-x" "w" "a" "C-x" "w" "t")
         (check (message-now) => "It holds a locked part, which the plugin that owns it arranges")
         (check (container-classes) => ["container fit vertical"])
         (select-named! "bar")
         (type! "C-x" "w" "2")
         (check (message-now) => "Locked: the plugin that owns it arranges it")
         ;; a itself may be wrapped; the bar stays drawn.
         (select-named! "a")
         (type! "C-x" "w" "t")
         (check (container-classes) => ["container fit vertical" "container tabbed horizontal"])
         (check (drawn-names) => [["a"] "bar"]))))

    (test-case "the session slot keeps nested and wrapped containers"
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
         (def nested
           ["container fit horizontal" "container fit vertical"
            "container tabbed horizontal" "container tabbed vertical"])
         (run (lambda ()
                ;; 0 alone in a column | tabs (1, tabs (2, 3) turned vertical)
                (split! 0 'right)
                (select! 1)
                (type! "C-x" "w" "t" "C-x" "t" "2" "C-x" "w" "t" "C-x" "t" "2" "C-x" "w" "d")
                (select! 0)
                (type! "C-x" "w" "2")
                (check (container-classes) => nested)
                (check (shown) => [[0 #t 'text] [3 #f 'text]])
                (on-baton save-session)))
         (run (lambda ()
                (check (container-classes) => nested)
                (check (shown) => [[0 #t 'text] [3 #f 'text]])
                (check (length (elements-where (with-class "tab") (layout-html))) => 4)
                ;; The column around 0 came back with its one child.
                (type! "C-x" "w" "k")
                (check (container-classes)
                       => ["container fit horizontal" "container tabbed vertical"
                           "container tabbed horizontal" "container tabbed vertical"]))))))

    (test-case "the session slot keeps pins, locks and content sizes"
      (call-with-state-directory
       (lambda (directory)
         (defplugin (bar-plugin ctx)
           "Puts a locked view of its own buffer in the bar."
           requires: [buffers-service layout-service]
           (let (b (new-buffer " *bar*" (new-text-node (new-text ""))))
             (context-add-buffer! ctx b)
             (add-locked-view b)))
         (def (run thunk)
           (call-with-fresh-kernel []
             (lambda ()
               (parameterize ((session-state-directory directory))
                 (for-each activate-plugin!
                           (append (map (lambda (p) (if (eq? p no-session-plugin) session-plugin p))
                                        layout-plugins)
                                   [bar-plugin])))
               (restore-session)
               (start-editor-loop!)
               (thunk))))
         (run (lambda ()
                ;; *scratch* | (*scratch* / *scratch*), the bottom one pinned, zoomed on the top one.
                (split! 0 'right)
                (split! 1 'below)
                (select! 2)
                (type! "C-x" "w" "p")
                (frame-on! 1)
                (check (length (drawn-names)) => 3)
                (on-baton save-session)))
         (run (lambda ()
                (check (map car (views-state)) => ["*scratch*" "*scratch*" "*scratch*" " *bar*"])
                (check (drawn-names) => [["*scratch*"] "*scratch*" " *bar*"])
                (on-baton (lambda () (select-view (view-named " *bar*"))))
                (type! "C-x" "w" "u")
                (check (message-now) => "Locked: the plugin that owns it keeps it pinned")
                (check (length (elements-where (lambda (e) (and (symbol? (car e))
                                                                (equal? (attribute e 'data-size) "content")))
                                               (layout-html)))
                       => 1))))))))
