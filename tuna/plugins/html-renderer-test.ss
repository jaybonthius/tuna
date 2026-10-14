;;; The HTML renderer: nodes, highlights and cursors, element ids, the
;;; parts a click can name, the layout drawn from the frame, and HTML reuse.
(import :std/test
        :tuna/kernel
        (only-in :tuna/services/keys keymap-set!)
        :tuna/services/settings
        :tuna/services/renderer
        :tuna/services/buffers
        :tuna/services/layout
        :tuna/plugins/keys
        :tuna/plugins/rope
        :tuna/plugins/settings
        :tuna/plugins/buffers
        :tuna/plugins/layout
        :tuna/plugins/html-renderer
        "../test-support/kernel"
        "../test-support/session")
(export html-renderer-test)

(def renderer-plugins
  [keys-plugin rope-text-store-plugin settings-plugin no-session-plugin
   buffers-plugin layout-plugin html-renderer-plugin])

;; A *welcome* buffer built as a tree: (column (heading "Welcome to Tuna")
;; (text "…")), with HTML renderers for both kinds.
(defplugin (tree-buffer-plugin ctx)
  "Defines the column and heading kinds and adds a *welcome* tree buffer."
  requires: [buffers-service]
  (context-define-node-kind! ctx 'column doc: "Children stacked vertically.")
  (context-define-node-kind! ctx 'heading doc: "A heading."
                             project: (lambda (n) (node-attribute n 'content)))
  (context-define-node-renderer! ctx 'column 'html
                                 (lambda (n children) `(div (@ (class "column")) ,@children)))
  (context-define-node-renderer! ctx 'heading 'html
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
  (context-define-node-renderer! ctx 'counted 'html
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

;; Position of NEEDLE in HAYSTACK, or #f.
(def (offset needle haystack)
  (string-contains haystack needle))

(def html-renderer-test
  (test-suite "tuna/plugins/html-renderer"
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
      (call-with-fresh-kernel (append renderer-plugins [tree-buffer-plugin])
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
      (call-with-fresh-kernel (append renderer-plugins [tree-buffer-plugin])
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
      (call-with-fresh-kernel (append renderer-plugins [tree-buffer-plugin])
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
         (check [(renders-of "a") (renders-of "b")] => [2 3]))))))
