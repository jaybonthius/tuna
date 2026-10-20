;;; The HTML renderer: nodes, highlights and cursors, element ids, the
;;; parts a click can name, the layout drawn from the frame, HTML reuse, and
;;; drawing only the run of a view's items around its scroll state.
(import (only-in :gerbil/runtime/mop slot-ref)
        (only-in :gerbil/runtime/interface interface-instance-object)
        :std/test
        :tuna/kernel
        (only-in :tuna/plugins/keys/contract keymap-set! keymap-set-in! new-keymap)
        :tuna/plugins/settings/contract
        :tuna/plugins/renderer/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/plugin
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/buffers/plugin
        :tuna/plugins/layout/plugin
        :tuna/plugins/renderer/plugin
        "../../tuna/tests/support/kernel"
        "../../plugins/session/tests/support/session"
        "../../plugins/layout/tests/support/two-views")
(export html-renderer-test)

(def renderer-plugins
  [commands keys rope-text-store settings no-session
   buffers layout html-renderer])

;; A *welcome* buffer built as a tree: (column (heading "Welcome to Tuna")
;; (text "…")), with HTML renderers for both kinds.
(defplugin (tree-buffer ctx)
  "Defines the column and heading kinds and adds a *welcome* tree buffer."
  requires: [buffers-service]
  (context-define-node-kind! ctx 'column doc: "Children stacked vertically.")
  (context-define-node-kind! ctx 'heading doc: "A heading."
                             project: (lambda (n) (node-attribute n 'content)))
  (context-define-node-renderer! ctx 'column
                                 (lambda (n children) `(div (@ (class "column")) ,@children)))
  (context-define-node-renderer! ctx 'heading
                                 (lambda (n children) `(h1 (@ (class "heading")) ,(node-attribute n 'content))))
  (context-add-buffer! ctx
                       (new-buffer "*welcome*"
                                   (new-node 'column
                                             children: [(new-node 'heading attributes: [['content . "Welcome to Tuna"]])
                                                        (new-text-node
                                                         (new-text "This buffer is a tree: a column holding a heading and this text.\nType here; the heading stays.\n"))]))))

(def (screen)
  (Renderer-render-screen (Renderer (service-provider renderer-service))))

;; Calls of the counted kind's HTML renderer, by the name of the buffer
;; holding the node.
(def renders (make-hash-table))

(def (renders-of name) (hash-ref renders name 0))

(def (node-buffer-name n)
  (let (root (let up ((n n)) (or (and (node-parent n) (up (node-parent n))) n)))
    (buffer-name (find (lambda (b) (eq? (buffer-root b) root)) (buffer-list)))))

;; The counted kind, and two buffers: "a", a counted root holding a
;; counted child and a text node; "b", a counted root holding two counted
;; children.
(defplugin (counted-kind ctx)
  "Defines the counted kind, whose HTML renderer counts its calls, and buffers a and b."
  requires: [buffers-service]
  (context-define-node-kind! ctx 'counted)
  (context-define-node-renderer! ctx 'counted
                                 (lambda (n children)
                                   (hash-update! renders (node-buffer-name n) 1+ 0)
                                   `(div (@ (class "counted")) ,(or (node-attribute n 'label) "") ,@children)))
  (context-add-buffer! ctx (new-buffer "a" (new-node 'counted children: [(new-node 'counted)
                                                                         (new-text-node (new-text "a"))])))
  (context-add-buffer! ctx (new-buffer "b" (new-node 'counted children: [(new-node 'counted)
                                                                         (new-node 'counted)]))))

(defplugin (remapping ctx)
  "Draws digits as keywords."
  requires: [settings-service]
  (context-set-setting! ctx face-remapping [(cons 'digit 'keyword)]))

;; a | b, a selected.
(def (two-counted-views!)
  (activate-plugin! counted-kind)
  (let (right (split-view (selected-view) 'right))
    (set-view-buffer (selected-view) (get-buffer "a"))
    (set-view-buffer right (get-buffer "b"))))

;; "1\n2\n...50000".
(def (fifty-thousand-lines)
  (string-join (let lp ((n 50000) (out [])) (if (zero? n) out (lp (- n 1) (cons (number->string n) out))))
               "\n"))

;; Position of NEEDLE in HAYSTACK, or #f.
(def (offset needle haystack)
  (string-contains haystack needle))

(def (has? haystack needle)
  (and (offset needle haystack) #t))

;; Rows, a node opening into its children, each one item: the buffer
;; "rows" holds 1,000 of them.
(defplugin (row-kinds ctx)
  "Defines the rows and row kinds and adds the buffer rows."
  requires: [buffers-service]
  (context-define-node-kind! ctx 'rows items: 'children)
  (context-define-node-kind! ctx 'row items: 'whole)
  (context-define-node-renderer! ctx 'rows (lambda (n children) `(div (@ (class "rows")) ,@children)))
  (context-define-node-renderer! ctx 'row (lambda (n children) `(div (@ (class "row")) ,(node-attribute n 'label))))
  (context-add-buffer! ctx (new-buffer "rows"
                                       (new-node 'rows
                                                 children: (map (lambda (k) (new-node 'row attributes: [(cons 'label (number->string k))]))
                                                                (iota 1000))))))

(def html-renderer-test
  (test-suite "tuna/plugins/html-renderer"
    (test-case "renders without the optional input and message services"
      (call-with-fresh-kernel
        [rope-text-store settings no-session buffers two-views html-renderer]
        (lambda ()
          (check (service-provider input-service) => #f)
          (check (service-provider messages-service) => #f)
          (insert "hello")
          (let (html (screen))
            (check (and (offset "hello" html) #t) => #t)
            (check (offset "data-clickable" html) => #f)))))
    (test-case "*scratch* renders its one text node with the cursor"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (insert "a<b\nc")
         (goto-char 2)
         (let (html (screen))
           (check (and (offset "class=\"text\"" html) #t) => #t)
           (check (and (offset "a<span class=\"cursor\">&lt;</span>b" html) #t) => #t)
           (check (and (offset "line 1, column 1" html) #t) => #t)))))

    (test-case "highlights render as face classes, around and under the cursor"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (insert "a12b\n34")
         (set-highlights! (current-text) 'digits
                          [(make-span 2 4 'digit) (make-span 6 8 'digit)])
         (goto-char 3)
         (let (html (screen))
           (check (and (offset "a<span class=\"face-digit\">1</span><span class=\"cursor face-digit\">2</span>b" html) #t)
                  => #t)
           (check (and (offset "<span class=\"face-digit\">34</span>" html) #t) => #t)))))

    (test-case "*welcome* renders as a column: the heading, then the editable text"
      (call-with-fresh-kernel (append renderer-plugins [tree-buffer])
       (lambda ()
         (switch-to-buffer (get-buffer "*welcome*"))
         (insert "Hi. ")
         (let* ((html (screen))
                (column (offset "class=\"column\"" html))
                (heading (offset "class=\"heading\"" html))
                (title (offset "Welcome to Tuna" html))
                (text (offset "class=\"text\"" html))
                (cursor (offset "<span class=\"cursor\">T</span>his buffer" html)))
           (check (and column heading title text cursor #t) => #t)
           (check (< column heading title text cursor) => #t)
           (check (and (offset "Hi. " html) #t) => #t)
           (check (and (offset "data-node=" html) #t) => #t)))))

    (test-case "views and nodes carry stable element ids, so the browser keeps their scroll"
      (call-with-fresh-kernel (append renderer-plugins [tree-buffer])
       (lambda ()
         (switch-to-buffer (get-buffer "*welcome*"))
         (let* ((view-id (string-append "view-" (number->string (view-id (selected-view)))))
                (root (buffer-root (current-buffer)))
                (node-ids (map (lambda (n) (string-append view-id "-node-" (number->string (node-id n))))
                               (cons root (node-children root))))
                (html (screen)))
           (check (and (offset (string-append "id=\"" view-id "\"") html) #t) => #t)
           (for-each (lambda (id) (check (and (offset (string-append "id=\"" id "\"") html) #t) => #t))
                     node-ids)
           ;; The same ids on the next redraw, after an edit.
           (insert "x")
           (let (again (screen))
             (for-each (lambda (id) (check (and (offset (string-append "id=\"" id "\"") again) #t) => #t))
                       (cons view-id node-ids)))))))

    (test-case "views and status lines are parts a click can name; only bound status lines are clickable"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (let* ((id (number->string (view-id (selected-view))))
                (view (string-append "data-view=\"" id "\" data-part=\"view:" id "\""))
                (status-line (string-append "<p class=\"status-line\" data-part=\"status-line:" id "\"")))
           (let (html (screen))
             (check (and (offset view html) #t) => #t)
             (check (and (offset (string-append status-line ">") html) #t) => #t)
             (check (offset "data-clickable" html) => #f))
           (defplugin (clicks ctx)
             "Binds clicks on views and status lines."
             requires: [input-service]
             (keymap-set! ctx "<view> <mouse-1>" 'mouse-select-view #f)
             (keymap-set! ctx "<status-line> <mouse-1>" 'mouse-select-view #f))
           (activate-plugin! clicks)
           (let (html (screen))
             (check (and (offset (string-append status-line " data-clickable=\"\">") html) #t) => #t)
             ;; A view's click binding is the fallback for anything in it:
             ;; views, and the text nodes inside them, stay unmarked.
             (check (and (offset (string-append view " data-selected=\"true\">") html) #t) => #t)
             (check (offset "data-clickable" (substring html 0 (offset status-line html))) => #f))))))

    (test-case "a node is clickable while its own keymap binds a plain click; a rebind draws it again"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (activate-plugin! counted-kind)
         (let* ((keymap (new-keymap))
                (b (get-buffer "b"))
                (child (car (node-children (buffer-root b))))
                (marked (string-append "data-node=\"" (number->string (node-id child))
                                       "\" data-clickable=\"\"")))
           (defplugin (other-bindings ctx)
             "A global click, and a key in the node's keymap: neither marks the node."
             requires: [input-service]
             (keymap-set! ctx "<mouse-1>" 'global-click #f)
             (keymap-set! ctx "<view> <mouse-1>" 'view-click #f)
             (keymap-set-in! ctx keymap "RET" 'node-key #f))
           (defplugin (node-click ctx)
             "Binds a click in the node's keymap."
             requires: [input-service]
             (keymap-set-in! ctx keymap "<mouse-1>" 'node-click #f))
           (set-view-buffer (selected-view) b)
           (set-node-keymap! child keymap)
           (activate-plugin! other-bindings)
           (check (offset "data-clickable" (screen)) => #f)
           (hash-clear! renders)
           (check (offset "data-clickable" (screen)) => #f)
           (check (renders-of "b") => 0)
           ;; Binding the click changes no node; the keymap generation makes
           ;; the next screen draw the nodes again, marked.
           (activate-plugin! node-click)
           (let (html (screen))
             (check (and (offset marked html) #t) => #t)
             (check (renders-of "b") => 3))
           (hash-clear! renders)
           (deactivate-plugin! node-click)
           (let (html (screen))
             (check (offset "data-clickable" html) => #f)
             (check (renders-of "b") => 3))))))

    (test-case "a kind without an HTML renderer shows its text projection"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (defplugin (box-kind ctx)
           "Defines the box kind, with a projection but no HTML renderer."
           requires: [buffers-service]
           (context-define-node-kind! ctx 'box project: (lambda (n) (node-attribute n 'label)))
           (context-add-buffer! ctx (new-buffer "*box*"
                                                (new-node 'stack
                                                          children: [(new-node 'box attributes: [['label . "Boxed <label>"]])
                                                                     (new-text-node (new-text "x"))]))))
         (activate-plugin! box-kind)
         (switch-to-buffer (get-buffer "*box*"))
         (let (html (screen))
           (check (and (offset "data-kind=\"stack\"" html) #t) => #t)
           (check (and (offset "data-kind=\"box\"" html) #t) => #t)
           (check (and (offset "Boxed &lt;label&gt;" html) #t) => #t)
           (check (and (offset "<span class=\"cursor\">x</span>" html) #t) => #t))
         (deactivate-plugin! box-kind)
         (check (get-buffer "*box*") => #f)
         (check (buffer-name (current-buffer)) => "*scratch*"))))

    (test-case "the screen draws from the frame: a node inside a buffer keeps its cursor"
      (call-with-fresh-kernel (append renderer-plugins [tree-buffer])
       (lambda ()
         (switch-to-buffer (get-buffer "*welcome*"))
         (let (text-node (current-text-node))
           (move-frame (make-frame-target (view-id (selected-view)) text-node))
           (let (html (screen))
             (check (offset "Welcome to Tuna" html) => #f)
             (check (and (offset "<span class=\"cursor\">T</span>his buffer" html) #t) => #t)
             ;; The view keeps its element id and the node its own.
             (check (and (offset (string-append "id=\"view-" (number->string (view-id (selected-view))) "\"") html) #t)
                    => #t))
           (move-frame (make-frame-target #f #f))
           (check (and (offset "Welcome to Tuna" (screen)) #t) => #t)))))

    (test-case "containers carry stable ids, their kind and direction, and each child's weight"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (split-view (selected-view) 'right)
         (display-buffer (get-buffer "*scratch*") side: 'top size: 1/4)
         (let (html (screen))
           (check (and (offset "class=\"container fit horizontal\"" html) #t) => #t)
           (check (and (offset "id=\"container-" html) #t) => #t)
           (check (and (offset "data-container=" html) #t) => #t)
           (check (and (offset "style=\"--tuna-size: 1\"" html) #t) => #t)
           ;; *scratch* already shows, so display-buffer reuses its view.
           (check (offset "class=\"container fit vertical\"" html) => #f)))))

    (test-case "HTML reuse: removed nodes leave the cache, unchanged subtrees stay"
      (call-with-fresh-kernel renderer-plugins
        (lambda ()
          (activate-plugin! counted-kind)
          (set-view-buffer (selected-view) (get-buffer "b"))
          (let* ((root (buffer-root (current-buffer)))
                 (kept (new-node 'counted children: [(new-node 'counted)]))
                 (rendering (interface-instance-object (service-provider renderer-service))))
            (for-each (lambda (_)
                        (set-node-children! root [kept (new-node 'counted)])
                        (screen))
                      (iota 1000))
            (let (cached (hash-get (slot-ref rendering 'views) (view-id (selected-view))))
              (check (hash-length (slot-ref cached 'nodes)) => 4)
              (hash-clear! renders)
              (screen)
              (check (renders-of "b") => 0)
              (set-node-children! root [kept])
              (screen)
              (check (renders-of "b") => 1)
              (check (hash-length (slot-ref cached 'nodes)) => 3)
              (set-node-children! root [])
              (screen)
              (check (hash-length (slot-ref cached 'nodes)) => 1))))))

    (test-case "HTML reuse: an unchanged buffer's node renderers are not called again"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (two-counted-views!)
         (hash-clear! renders)
         (let (first (screen))
           (check [(renders-of "a") (renders-of "b")] => [2 3])
           (hash-clear! renders)
           ;; Nothing changed: the same screen, without calling them.
           (check (screen) => first)
           (check [(renders-of "a") (renders-of "b")] => [0 0])))))

    (test-case "HTML reuse: an edit redraws only the changed buffer's parts"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (two-counted-views!)
         (screen)
         (hash-clear! renders)
         ;; One of b's children: it and b's root, not its sibling, not a.
         (set-node-attribute! (car (node-children (buffer-root (get-buffer "b")))) 'label "changed")
         (let (html (screen))
           (check [(renders-of "a") (renders-of "b")] => [0 2])
           (check (and (string-contains html ">changed</div>") #t) => #t))
         (hash-clear! renders)
         ;; Typing in a: its root holds the text node, its other child is kept.
         (insert "!")
         (let (html (screen))
           (check [(renders-of "a") (renders-of "b")] => [1 0])
           (check (and (string-contains html "!<span class=\"cursor\">a</span>") #t) => #t))
         (hash-clear! renders)
         ;; Moving point is view state: the nodes holding it are drawn again.
         (goto-char 1)
         (screen)
         (check [(renders-of "a") (renders-of "b")] => [1 0])
         (hash-clear! renders)
         ;; Selecting the other view changes both views' state.
         (select-view (cadr (view-list)))
         (let (html (screen))
           (check [(renders-of "a") (renders-of "b")] => [1 0])
           (check (and (string-contains html "<span class=\"inactive-cursor\">!</span>a") #t) => #t)))))

    (test-case "HTML reuse: a face or setting change redraws everything"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (two-counted-views!)
         (set-highlights! (text-node-content (cadr (node-children (buffer-root (get-buffer "a")))))
                          'digits [(make-span 1 2 'digit)])
         (check (and (string-contains (screen) "face-digit") #t) => #t)
         (hash-clear! renders)
         (activate-plugin! remapping)
         (let (html (screen))
           (check [(renders-of "a") (renders-of "b")] => [2 3])
           (check (and (string-contains html "face-keyword") #t) => #t)
           (check (string-contains html "face-digit") => #f))
         (hash-clear! renders)
         (deactivate-plugin! remapping)
         (check (and (string-contains (screen) "face-digit") #t) => #t)
         (check [(renders-of "a") (renders-of "b")] => [2 3]))))

    (test-case "scrolling: a new view draws its first items, from its start"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (insert (fifty-thousand-lines))
         (goto-char 1)
         (let* ((v (selected-view))
                (n (view-node v))
                (line (lambda (k) (string-append "data-item=\"" (item-token (node-item-at n (- k 1))) "\"")))
                (html (screen)))
           (check (has? html (line 1)) => #t)
           (check (has? html (line (+ 1 initial-drawn-after))) => #t)
           (check (has? html (line (+ 2 initial-drawn-after))) => #f)
           (check (has? html "spacer") => #f)
           (check (has? html "data-run-at-start") => #t)
           (check (has? html "data-run-at-end") => #f)
           (check (has? html "data-measured-height") => #f)
           (check (has? html "@tunaScroll('moved')") => #t)
           (check (has? html (string-append "data-scroll-root=\"" (number->string (node-id n)) "\"")) => #t)
           (check (has? html "data-drawn-above=\"20000\" data-drawn-below=\"20000\"") => #t)
           ;; The placement marker names no item: the view stays at its start.
           (check (has? html (string-append "id=\"view-" (number->string (view-id v)) "-placement-0\"")) => #t)
           (check (has? html "data-target") => #f)
           ;; No scroll bar until the browser has measured the view.
           (check (has? html "scroll-bar") => #f)))))

    (test-case "scrolling: a view draws its counts of items around its scroll item, and its scroll bar"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (insert (fifty-thousand-lines))
         (let* ((v (selected-view))
                (n (view-node v))
                (item (lambda (k) (node-item-at n (- k 1))))
                (line (lambda (k) (string-append "data-item=\"" (item-token (item k)) "\""))))
           (set-view-scroll! v (item 25000) 5.)
           (set-view-drawn-items! v 100 300)
           (set-view-facts! v (make-scroll-facts (item 25030) 31 800 744))
           (let (html (screen))
             (check (has? html (line 24899)) => #f)
             (check (has? html (line 24900)) => #t)
             (check (has? html (line 25300)) => #t)
             (check (has? html (line 25301)) => #f)
             (check (has? html "data-run-at-start") => #f)
             (check (has? html "data-measured-width=\"800\" data-measured-height=\"744\"") => #t)
             ;; Between placements the marker names the scroll state.
             (check (has? html (string-append "data-target=\"" (item-token (item 25000))
                                              "\" data-align=\"top\" data-offset=\"5.\""))
                    => #t)
             ;; The handle runs from item 24,999 (from 0) over 31 of 50,000.
             (check (has? html "--scroll-bar-handle-start: 49.9980%; --scroll-bar-handle-size: 0.0620%") => #t))
           ;; A placement is a new marker, with a larger number.
           (let (number (placement-number (view-placement v)))
             (place-view! v (item 100) 'center)
             (let (html (screen))
               (check (has? html (string-append "-placement-" (number->string (+ number 1)) "\"")) => #t)
               (check (has? html (string-append "data-target=\"" (item-token (item 100))
                                                "\" data-align=\"center\""))
                      => #t)
               (check (has? html (line 100)) => #t)))))))

    (test-case "scrolling: a node opening into children is drawn with only the children holding drawn items"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (activate-plugin! row-kinds)
         (let* ((v (selected-view))
                (b (get-buffer "rows")))
           (set-view-buffer v b)
           (let* ((root (buffer-root b))
                  (rows (node-children root))
                  (row-id (lambda (k) (string-append "id=\"view-" (number->string (view-id v)) "-node-"
                                                     (number->string (node-id (list-ref rows k))) "\""))))
             (set-view-scroll! v (node-item (list-ref rows 500)) 0.)
             (set-view-drawn-items! v 10 10)
             (let (html (screen))
               (check (has? html (string-append "class=\"rows\"")) => #t)
               (check (has? html (row-id 489)) => #f)
               (check (has? html (row-id 490)) => #t)
               (check (has? html (row-id 510)) => #t)
               (check (has? html (row-id 511)) => #f)
               ;; Each row is one item, named by its node.
               (check (has? html (string-append "data-item=\"" (number->string (node-id (list-ref rows 500))) "\""))
                      => #t)))))))

    (test-case "scrolling: line ids stay with their text through an edit above"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (insert (fifty-thousand-lines))
         (let* ((v (selected-view))
                (n (view-node v))
                (prefix (string-append "id=\"view-" (number->string (view-id v))
                                       "-node-" (number->string (node-id n)) "-line-")))
           (set-view-scroll! v (node-item-at n 24999) 0.)
           (check (has? (screen) (string-append prefix "25000\">25000<")) => #t)
           ;; Two lines inserted at the top: the text "25000" is line 25002 now,
           ;; and keeps its element.
           (goto-char 1)
           (insert "a\nb\n")
           (check (has? (screen) (string-append prefix "25000\">25000<")) => #t)
           (check (has? (screen) (string-append prefix "25002\">25000<")) => #f)))))))
