;;; The HTML renderer: nodes, highlights and cursors, element ids, the
;;; parts a click can name, the layout drawn from the frame, HTML reuse, and
;;; drawing only the run of a view's items around its scroll state.
(import (only-in :gerbil/runtime/mop slot-ref)
        (only-in :gerbil/runtime/interface interface-instance-object)
        :std/test
        :tuna/kernel
        :tuna/lib/memo
        :tuna/plugins/clients/contract
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
        "../../plugins/text-store/tests/support/string-text-store"
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

(def (screen (c #f))
  (Renderer-render-screen (Renderer (service-provider renderer-service)) c))

;; Calls of the counted kind's HTML renderer, by the name of the buffer
;; holding the node, which each counted node carries (its 'in attribute):
;; a renderer may read only its own node.
(def renders (make-hash-table))

(def (renders-of name) (hash-ref renders name 0))

;; A counted node in the buffer named IN.
(def (counted in children: (children [])) (new-node 'counted attributes: [(cons 'in in)] children: children))

;; The counted kind, and two buffers: "a", a counted root holding a
;; counted child and a text node; "b", a counted root holding two counted
;; children.
(defplugin (counted-kind ctx)
  "Defines the counted kind, whose HTML renderer counts its calls, and buffers a and b."
  requires: [buffers-service]
  (context-define-node-kind! ctx 'counted)
  (context-define-node-renderer! ctx 'counted
                                 (lambda (n children)
                                   (unless (memo-from-scratch?)
                                     (hash-update! renders (node-attribute n 'in) 1+ 0))
                                   `(div (@ (class "counted")) ,(or (node-attribute n 'label) "") ,@children)))
  (context-add-buffer! ctx (new-buffer "a" (counted "a" children: [(counted "a") (new-text-node (new-text "a"))])))
  (context-add-buffer! ctx (new-buffer "b" (counted "b" children: [(counted "b") (counted "b")]))))

(defplugin (remapping ctx)
  "Draws digits as keywords."
  requires: [settings-service]
  (context-set-setting! ctx face-remapping [(cons 'digit 'keyword)]))

(defplugin (no-status-lines ctx)
  "Turns status lines off."
  requires: [settings-service]
  (context-set-setting! ctx show-status-line #f))

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

;; The token of line K of text node N drawn for the first time now: by its
;; end and the text's revision (the renderer's line births).
(def (new-line-token n k)
  (let (t (text-node-content n))
    (string-append (number->string (node-id n)) "." (number->string (text-line-end t k))
                   "." (number->string (text-chars-revision t)))))

;; The value of the attribute ending in NAME=" that comes last before
;; position AT in HTML.
(def (attribute-before html name at)
  (let lp ((i at))
    (cond
     ((< i 0) #f)
     ((string-prefix? name (substring html i (min (string-length html) (+ i (string-length name)))))
      (let* ((start (+ i (string-length name)))
             (end (string-index html #\" start)))
        (substring html start end)))
     (else (lp (- i 1))))))

;; The element id of the line drawn as CONTENT in HTML, or #f.
(def (line-id html content)
  (let (at (string-contains html (string-append "\">" content "</div>")))
    (and at (attribute-before html " id=\"" at))))

;; The token (data-item) of the line drawn as CONTENT in HTML, or #f.
(def (line-token html content)
  (let (at (string-contains html (string-append "\">" content "</div>")))
    (and at (attribute-before html "data-item=\"" at))))

;; The keys of the pieces (DRAW) draws through the renderer's cache.
(def (pieces-drawn draw)
  (let (keys [])
    (parameterize ((current-memo-draw-observer (lambda (key) (set! keys (cons key keys)))))
      (draw))
    keys))

;; How many of KEYS are of line pieces, of view V's when V is given.
(def (lines-drawn keys (v #f))
  (length (filter (lambda (key) (and (pair? key) (eq? (car key) 'line) (or (not v) (eqv? (cadr key) (view-id v)))))
                  keys)))

;; How many of KEYS are of the pieces holding what each text node's lines
;; are drawn from.
(def (line-runs-drawn keys)
  (length (filter (lambda (key) (and (pair? key) (eq? (car key) 'lines))) keys)))

;; The checks of drawing lines by value, with PLUGINS.
(def (check-lines-by-value plugins)
  ;; A key draws one line again; point moving within a line one, across
  ;; lines two.
  (call-with-fresh-kernel plugins
   (lambda ()
     (insert "one\ntwo\nthree\nfour")
     (goto-char 6)
     (screen)
     (check (lines-drawn (pieces-drawn (lambda () (insert "x") (screen)))) => 1)
     (check (lines-drawn (pieces-drawn (lambda () (goto-char (+ (point) 1)) (screen)))) => 1)
     (goto-char (text-line-end (current-text) 2))
     (screen)
     (check (lines-drawn (pieces-drawn (lambda () (goto-char (+ (point) 1)) (screen)))) => 2)
     ;; Nothing changed: no piece at all.
     (check (pieces-drawn screen) => [])))
  ;; A line inserted above the drawn lines draws none of them; RET at the
  ;; end of a drawn line draws that line and the new one.
  (call-with-fresh-kernel plugins
   (lambda ()
     (insert (fifty-thousand-lines))
     (let* ((v (selected-view))
            (n (view-node v))
            (t (text-node-content n)))
       (set-view-scroll! v #f (node-item-at n 24999) 0.)
       (set-client-view-drawn-items! (view-client v #f) 10 10)
       (goto-char 1)
       (screen)
       (check (lines-drawn (pieces-drawn (lambda () (insert "new\n") (screen)))) => 0)
       (goto-char (text-line-end t 25001))
       (check (has? (screen) ">25000<span class=\"cursor\">") => #t)
       (check (lines-drawn (pieces-drawn (lambda () (insert "\n") (screen)))) => 2))))
  ;; A highlight result draws again only the lines whose spans changed;
  ;; the same spans draw nothing and give the same screen.
  (call-with-fresh-kernel plugins
   (lambda ()
     (insert "a1\nb2\nc3\nd4")
     (goto-char 1)
     (let (t (current-text))
       (set-highlights! t 'digits [(make-span 2 3 'digit) (make-span 5 6 'digit) (make-span 8 9 'digit)])
       (screen)
       (check (lines-drawn (pieces-drawn (lambda ()
                                           (set-highlights! t 'digits [(make-span 2 3 'digit) (make-span 4 6 'digit)
                                                                       (make-span 8 9 'digit)])
                                           (screen))))
              => 1)
       (let (before (screen))
         (check (pieces-drawn (lambda ()
                                (set-highlights! t 'digits [(make-span 2 3 'digit) (make-span 4 6 'digit)
                                                            (make-span 8 9 'digit)])
                                (check (eq? (screen) before) => #t)))
                => []))))))

;; The buffer "blocks": a column of a block holding the text "a1".."a3",
;; a block holding "x1".."x7", and a label.
(defplugin (block-kinds ctx)
  "Defines the block and label kinds and adds the buffer blocks."
  requires: [buffers-service]
  (context-define-node-kind! ctx 'block)
  (context-define-node-kind! ctx 'label items: 'whole)
  (context-define-node-renderer! ctx 'block
                                 (lambda (n children)
                                   (unless (memo-from-scratch?) (hash-update! renders "block" 1+ 0))
                                   `(div (@ (class "block")) ,@children)))
  (context-define-node-renderer! ctx 'label (lambda (n children) `(p ,(node-attribute n 'label))))
  (context-add-buffer!
   ctx (new-buffer "blocks"
                   (new-node 'column
                             children: [(new-node 'block children: [(new-text-node (new-text "a1\na2\na3"))])
                                        (new-node 'block children: [(new-text-node (new-text "x1\nx2\nx3\nx4\nx5\nx6\nx7"))])
                                        (new-node 'label attributes: [['label . "one"]])]))))

;; A status line click binding, so status lines are marked clickable.
(defplugin (status-line-click ctx)
  "Binds a click on a status line."
  requires: [input-service]
  (keymap-set! ctx "<status-line> <mouse-1>" 'ignore #f))

;; Rows, a node opening into its children, each one item: the buffer
;; "rows" holds 1,000 of them.
(defplugin (row-kinds ctx)
  "Defines the rows and row kinds and adds the buffer rows."
  requires: [buffers-service]
  (context-define-node-kind! ctx 'rows items: 'children)
  (context-define-node-kind! ctx 'row items: 'whole)
  (context-define-node-renderer! ctx 'rows
                                 (lambda (n children)
                                   (unless (memo-from-scratch?) (hash-update! renders "rows" 1+ 0))
                                   `(div (@ (class "rows")) ,@children)))
  (context-define-node-renderer! ctx 'row
                                 (lambda (n children)
                                   (unless (memo-from-scratch?) (hash-update! renders "row" 1+ 0))
                                   `(div (@ (class "row")) ,(node-attribute n 'label))))
  (context-add-buffer! ctx (new-buffer "rows"
                                       (new-node 'rows
                                                 children: (map (lambda (k) (new-node 'row attributes: [(cons 'label (number->string k))]))
                                                                (iota 1000))))))

;; Whether labels are drawn in capitals.
(defsetting shouting #f "Whether the shouted kind draws its label in capitals.")

;; The shouted kind, whose renderer reads a setting, and the buffer
;; "shouted", which holds one.
(defplugin (shouted-kind ctx)
  "Defines the shouted kind and adds the buffer shouted."
  requires: [buffers-service settings-service]
  (context-define-node-kind! ctx 'shouted)
  (context-define-node-renderer! ctx 'shouted
                                 (lambda (n children)
                                   (unless (memo-from-scratch?) (hash-update! renders "shouted" 1+ 0))
                                   (let (label (node-attribute n 'label))
                                     `(p ,(if (setting-value shouting) (string-upcase label) label)))))
  (context-add-buffer! ctx (new-buffer "shouted" (new-node 'shouted attributes: [['label . "hello"]]))))

(defplugin (shouts ctx)
  "Turns shouting on."
  requires: [settings-service]
  (context-set-setting! ctx shouting #t))

;; What the hidden kind draws, read behind every accessor.
(def hidden-label "one")

(defplugin (hidden-kind ctx)
  "Defines the hidden kind, whose renderer draws a global variable, and the buffer hidden."
  requires: [buffers-service]
  (context-define-node-kind! ctx 'hidden)
  (context-define-node-renderer! ctx 'hidden (lambda (n children) `(p ,hidden-label)))
  (context-add-buffer! ctx (new-buffer "hidden" (new-node 'hidden))))

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

    (test-case "a node is clickable while its own keymap binds a plain click; a rebind draws it, and what holds it, again"
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
           ;; Binding the click changes no node, but the keymap's source:
           ;; the next screen draws the node holding it again, marked, and
           ;; its parent; not its sibling.
           (activate-plugin! node-click)
           (let (html (screen))
             (check (and (offset marked html) #t) => #t)
             (check (renders-of "b") => 2))
           (hash-clear! renders)
           (deactivate-plugin! node-click)
           (let (html (screen))
             (check (offset "data-clickable" html) => #f)
             (check (renders-of "b") => 2))))))

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
                 (kept (counted "b" children: [(counted "b")]))
                 (rendering (interface-instance-object (service-provider renderer-service)))
                 (pieces (lambda () (memo-cache-size (slot-ref rendering 'pieces)))))
            (for-each (lambda (_)
                        (set-node-children! root [kept (counted "b")])
                        (screen))
                      (iota 1000))
            ;; The screen, its view, and four nodes.
            (check (pieces) => 6)
            (hash-clear! renders)
            (screen)
            (check (renders-of "b") => 0)
            (set-node-children! root [kept])
            (screen)
            (check (renders-of "b") => 1)
            (check (pieces) => 5)
            (set-node-children! root [])
            (screen)
            (check (pieces) => 3)))))

    (test-case "HTML reuse: an unchanged buffer's node renderers are not called again"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (two-counted-views!)
         (hash-clear! renders)
         (let (first (screen))
           (check [(renders-of "a") (renders-of "b")] => [2 3])
           (hash-clear! renders)
           ;; Nothing changed: the very same screen, without calling them.
           (check (eq? (screen) first) => #t)
           (check [(renders-of "a") (renders-of "b")] => [0 0])))))

    (test-case "idle: a screen is drawn again after a change by any owner of what it shows"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (two-counted-views!)
         (let* ((c (make-client "a"))
                (last (screen c))
                (changed? (lambda (change)
                            (change)
                            (let (now (screen c))
                              (begin0 (not (eq? now last))
                                (set! last now))))))
           ;; Buffers: a node, a buffer's name, its own setting, the
           ;; selected view, and what the client measured.
           (check (changed? (lambda () (set-node-attribute! (buffer-root (get-buffer "b")) 'label "b!"))) => #t)
           (check (changed? (lambda () (rename-buffer! (get-buffer "a") "a2"))) => #t)
           (check (changed? (lambda () (set-buffer-setting! (get-buffer "a2") show-status-line #f))) => #t)
           (check (changed? (lambda () (set-client-view-drawn-items! (view-client (selected-view) c) 3 3))) => #t)
           ;; The layout: selecting the other view.
           (check (changed? (lambda () (select-view (cadr (view-list))))) => #t)
           ;; Settings: a global value.
           (check (changed? (lambda () (activate-plugin! no-status-lines))) => #t)
           (check (changed? (lambda () (deactivate-plugin! no-status-lines))) => #t)
           ;; Keymaps: a binding a status line's click reads.
           (activate-plugin! status-line-click)
           (check (and (string-contains (screen c) "data-clickable") #t) => #t)
           (set! last (screen c))
           (check (changed? void) => #f)))))

    (test-case "the status line names the running task, and stops when it ends"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (let (idle (screen))
           (check (string-contains idle "running") => #f)
           (start-editor-loop!)
           (let (running (call-on-editor-loop screen))
             (check (and (string-contains running " · running call") #t) => #t)
             (check (eq? (screen) running) => #f)
             (check (string-contains (screen) "running") => #f))))))

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

    (test-case "HTML reuse: a face-remapping change redraws what drew faces, and what holds it"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (two-counted-views!)
         (set-highlights! (text-node-content (cadr (node-children (buffer-root (get-buffer "a")))))
                          'digits [(make-span 1 2 'digit)])
         (check (and (string-contains (screen) "face-digit") #t) => #t)
         (hash-clear! renders)
         (activate-plugin! remapping)
         (let (html (screen))
           (check [(renders-of "a") (renders-of "b")] => [1 0])
           (check (and (string-contains html "face-keyword") #t) => #t)
           (check (string-contains html "face-digit") => #f))
         (hash-clear! renders)
         (deactivate-plugin! remapping)
         (check (and (string-contains (screen) "face-digit") #t) => #t)
         (check [(renders-of "a") (renders-of "b")] => [1 0]))))

    (test-case "a renderer reading a setting is drawn again when its global or the buffer's own value changes"
      (call-with-fresh-kernel (append renderer-plugins [shouted-kind])
       (lambda ()
         (switch-to-buffer (get-buffer "shouted"))
         (check (and (string-contains (screen) ">hello</p>") #t) => #t)
         (hash-clear! renders)
         (check (and (string-contains (screen) ">hello</p>") #t) => #t)
         (check (renders-of "shouted") => 0)
         (activate-plugin! shouts)
         (check (and (string-contains (screen) ">HELLO</p>") #t) => #t)
         (check (renders-of "shouted") => 1)
         (set-buffer-setting! (current-buffer) shouting #f)
         (check (and (string-contains (screen) ">hello</p>") #t) => #t)
         (check (renders-of "shouted") => 2))))

    (test-case "moving point draws again the text node holding it and what holds that, not other text"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (activate-plugin! block-kinds)
         (set-view-buffer (selected-view) (get-buffer "blocks"))
         (screen)
         (hash-clear! renders)
         (goto-char 2)
         (screen)
         (check (renders-of "block") => 1))))

    (test-case "two clients share the HTML of nodes drawn the same for both"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (activate-plugin! row-kinds)
         (set-view-buffer (selected-view) (get-buffer "rows"))
         (let ((a (make-client "a")) (b (make-client "b")))
           (hash-clear! renders)
           (screen a)
           (screen b)
           ;; The rows node and its 200 rows: drawn once, for both.
           (check [(renders-of "rows") (renders-of "row")] => [1 201])
           ;; B draws fewer rows: the rows node again, for B; no row.
           (set-client-view-drawn-items! (view-client (selected-view) b) 3 3)
           (screen b)
           (screen a)
           (check [(renders-of "rows") (renders-of "row")] => [2 201])))))

    (test-case "test mode: a renderer drawing state read behind the accessors fails the double render"
      (call-with-fresh-kernel (append renderer-plugins [hidden-kind])
       (lambda ()
         (switch-to-buffer (get-buffer "hidden"))
         (check (and (string-contains (screen) ">one</p>") #t) => #t)
         (set! hidden-label "two")
         (check (with-catch (lambda (e) 'failed) (lambda () (screen) 'drawn)) => 'failed)
         (set! hidden-label "one"))))

    (test-case "scrolling: a new view draws its first items, from its start"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (insert (fifty-thousand-lines))
         (goto-char 1)
         (let* ((v (selected-view))
                (n (view-node v))
                (line (lambda (k) (string-append "data-item=\"" (new-line-token n k) "\"")))
                (html (screen)))
           (check (has? html (line 1)) => #t)
           (check (has? html (line (+ 1 initial-drawn-items))) => #t)
           (check (has? html (line (+ 2 initial-drawn-items))) => #f)
           ;; No spacers until the browser has measured the view's items,
           ;; and no scroll sizer: the scroller is as high as what is drawn.
           (check (has? html "spacer") => #f)
           (check (has? html "scroll-sizer") => #f)
           (check (has? html "data-run-at-start") => #t)
           (check (has? html "data-run-at-end") => #f)
           (check (has? html "data-measured-height") => #f)
           ;; Each trigger is the scroller's own: no page-wide signal, whose
           ;; change would run every scroller's effect, even one being removed.
           (check (has? html "data-on:scroll=\"@tunaScroll('moved')\"") => #t)
           (check (has? html "data-effect=\"@tunaScroll('moved')\"") => #t)
           (check (has? html "data-signals") => #f)
           (check (has? html (string-append "data-scroll-root=\"" (number->string (node-id n)) "\"")) => #t)
           (check (has? html "data-drawn-screens=\"2.\"") => #t)
           ;; The placement marker names no item: the view stays at its start.
           ;; The first placement sent to this client.
           (check (has? html (string-append "id=\"view-" (number->string (view-id v)) "-placement-1\"")) => #t)
           (check (has? html "data-target") => #f)))))

    (test-case "scrolling: a view draws its counts of items around its scroll item, between spacers"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (insert (fifty-thousand-lines))
         (let* ((v (selected-view))
                (n (view-node v))
                (item (lambda (k) (node-item-at n (- k 1))))
                (line (lambda (k) (string-append "data-item=\"" (new-line-token n k) "\""))))
           (set-view-scroll! v #f (item 25000) 5.)
           (let (cv (view-client v #f))
             (set-client-view-drawn-items! cv 100 300)
             (set-client-view-facts! cv (make-scroll-facts (placement-number (client-view-placement cv))
                                                           n (item 25030) 31 800 744))
             (set-client-view-average-item-height! cv 20.25))
           (let (html (screen))
             (check (has? html (line 24899)) => #f)
             (check (has? html (line 24900)) => #t)
             (check (has? html (line 25300)) => #t)
             (check (has? html (line 25301)) => #f)
             (check (has? html "data-run-at-start") => #f)
             (check (has? html "data-measured-width=\"800\" data-measured-height=\"744\"") => #t)
             ;; Between placements the marker names the scroll state.
             (check (has? html (string-append "data-target=\"" (new-line-token n 25000)
                                              "\" data-align=\"top\" data-offset=\"5.\""))
                    => #t)
             ;; Spacers stand in for the 24,899 items before the run and the
             ;; 24,700 after it, beside a scroll sizer as high as all 50,000
             ;; items at the measured average of 20.25 px each: the spacer
             ;; above as high as its items, the one below with no height of
             ;; its own, filling the rest. In view, each asks for a report
             ;; naming the run (from 0).
             (let ((above (string-contains html "data-spacer=\"above\" style=\"--spacer-block-size: 504205px\""))
                   (first (string-contains html (line 24900)))
                   (last (string-contains html (line 25300)))
                   (below (string-contains html "data-spacer=\"below\" data-on-intersect"))
                   (sizer (string-contains html "class=\"scroll-sizer\" aria-hidden=\"true\" style=\"--scroll-sizer-block-size: 1012500px\"")))
               (check (and above first last below sizer (< above first last below sizer) #t) => #t))
             (check (has? html "--spacer-block-size: 500175px") => #f)
             (check (has? html "@tunaScroll('spacer', 24899, 25299)") => #t)
             (check (has? html "scroll-bar") => #f))
           ;; At the end of the buffer, no spacer below.
           (set-view-scroll! v #f (item 49990) 0.)
           (let (html (screen))
             (check (has? html "data-spacer=\"above\"") => #t)
             (check (has? html "data-spacer=\"below\"") => #f)
             (check (has? html "--scroll-sizer-block-size: 1012500px") => #t))
           ;; A placement is a new marker, with a larger number.
           (let (number (placement-number (client-view-placement (view-client v #f))))
             (place-view! v (item 100) 'center)
             (let (html (screen))
               (check (has? html (string-append "-placement-" (number->string (+ number 1)) "\"")) => #t)
               (check (has? html (string-append "data-target=\"" (new-line-token n 100)
                                                "\" data-align=\"center\""))
                      => #t)
               (check (has? html (line 100)) => #t)))))))

    (test-case "scrolling: each client's screen draws the run, spacers and total height its browser measured"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (insert (fifty-thousand-lines))
         (let* ((v (selected-view))
                (n (view-node v))
                (item (lambda (k) (node-item-at n (- k 1))))
                (line (lambda (k) (string-append "data-item=\"" (new-line-token n k) "\"")))
                (a (make-client "a"))
                (b (make-client "b")))
           (place-view! v (item 25000) 'top)
           ;; A, short: 100 items drawn before and 300 after, 20.25 px each;
           ;; B, tall: 500 and 500, 40 px each.
           (for-each (lambda (setup)
                       (let (cv (view-client v (car setup)))
                         (apply set-client-view-drawn-items! cv (cadr setup))
                         (set-client-view-average-item-height! cv (caddr setup))
                         (set-client-view-facts! cv (make-scroll-facts (placement-number (client-view-placement cv))
                                                                       n (item 25030) 31 800 (cadddr setup)))))
                     [[a [100 300] 20.25 744] [b [500 500] 40. 1600]])
           (let ((short (screen a))
                 (tall (screen b)))
             (check [(has? short (line 24899)) (has? short (line 24900)) (has? short (line 25300))
                     (has? short (line 25301))]
                    => [#f #t #t #f])
             (check [(has? tall (line 24499)) (has? tall (line 24500)) (has? tall (line 25500))
                     (has? tall (line 25501))]
                    => [#f #t #t #f])
             (check (has? short "data-measured-height=\"744\"") => #t)
             (check (has? tall "data-measured-height=\"1600\"") => #t)
             (check (has? short "--spacer-block-size: 504205px") => #t)
             (check (has? tall "--spacer-block-size: 979960px") => #t)
             (check (has? short "--scroll-sizer-block-size: 1012500px") => #t)
             (check (has? tall "--scroll-sizer-block-size: 2000000px") => #t)
             ;; Each is sent its own placements: the first, for each.
             (check (has? short (string-append "-placement-1\"")) => #t)
             (check (has? tall (string-append "-placement-1\"")) => #t)
             ;; Moving the view sends both a new one.
             (place-view! v (item 100) 'center)
             (check (has? (screen a) (string-append "-placement-2\"")) => #t)
             (check (has? (screen b) (string-append "-placement-2\"")) => #t))))))

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
             (set-view-scroll! v #f (node-item (list-ref rows 500)) 0.)
             (set-client-view-drawn-items! (view-client v #f) 10 10)
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
                (n (view-node v)))
           (set-view-scroll! v #f (node-item-at n 24999) 0.)
           (let (id (line-id (screen) "25000"))
             (check (string-prefix? (string-append "view-" (number->string (view-id v)) "-node-"
                                                   (number->string (node-id n)) "-line-")
                                    id)
                    => #t)
             ;; Two lines inserted at the top: the text "25000" is line 25002
             ;; now, and keeps its element.
             (goto-char 1)
             (insert "a\nb\n")
             (check (line-id (screen) "25000") => id))))))

    (test-case "scrolling: line ids stay with their text inside a block whose HTML was reused"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (activate-plugin! block-kinds)
         (let* ((v (selected-view))
                (b (get-buffer "blocks")))
           (set-view-buffer v b)
           (let* ((blocks (node-children (buffer-root b)))
                  (x (car (node-children (cadr blocks))))
                  (label (caddr blocks))
                  (html (screen))
                  (x1 (line-id html "x1"))
                  (x7 (line-id html "x7")))
             ;; X's block is drawn from its kept HTML, X not visited.
             (set-node-attribute! label 'label "two")
             (check (line-id (screen) "x7") => x7)
             ;; A line inserted at X's start: "x1" and "x7" keep their ids;
             ;; the new line has a new one.
             (text-replace! (text-node-content x) 1 1 "x0\n")
             (let* ((html (screen))
                    (x0 (line-id html "x0")))
               (check (line-id html "x1") => x1)
               (check (line-id html "x7") => x7)
               (check (and x0 (not (member x0 [x1 x7])) #t) => #t)))))))

    (test-case "scrolling: line ids stay with their text through a line inserted where drawing starts"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (insert (fifty-thousand-lines))
         (let* ((v (selected-view))
                (n (view-node v)))
           (set-view-scroll! v #f (node-item-at n 9) 0.)
           (let* ((html (screen))
                  (five (line-id html "5"))
                  (ten (line-id html "10")))
             (check (has? html "data-run-at-start") => #t)
             ;; A line inserted before the first line drawn: the text "5" is
             ;; line 6 now, and keeps its element, as "10" does.
             (goto-char 1)
             (insert "\n")
             (let (html (screen))
               (check (line-id html "5") => five)
               (check (line-id html "10") => ten)))))))

    (test-case "lines: drawn by value, each line again only when what it draws from changed"
      (check-lines-by-value renderer-plugins))

    (test-case "lines: the same with the toy text store"
      (check-lines-by-value [commands keys string-text-store settings no-session buffers layout html-renderer]))

    (test-case "lines: three views of one buffer: point moving in one draws one of its lines; a key draws the line in each"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (insert "one\ntwo\nthree")
         (goto-char 6)
         (let* ((a (selected-view))
                (b (split-view a 'right))
                (c (split-view a 'below)))
           (screen)
           (let (keys (pieces-drawn (lambda () (goto-char (+ (point) 1)) (screen))))
             (check [(lines-drawn keys a) (lines-drawn keys b) (lines-drawn keys c)] => [1 0 0]))
           (let (keys (pieces-drawn (lambda () (insert "x") (screen))))
             (check [(lines-drawn keys a) (lines-drawn keys b) (lines-drawn keys c)] => [1 1 1]))))))

    (test-case "lines: a scroll report keeping the drawn run draws no text node or its lines again"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (insert (fifty-thousand-lines))
         (let* ((v (selected-view))
                (n (view-node v))
                (it (node-item-at n 24999)))
           (set-view-scroll! v #f it 0.)
           (set-client-view-drawn-items! (view-client v #f) 10 10)
           (screen)
           ;; The view scrolled 5 px further into the same item: a new
           ;; scroll position, the same items drawn.
           (let (keys (pieces-drawn (lambda () (set-view-scroll! v #f it 5.) (screen))))
             (check (and (member ['view (view-id v)] keys) #t) => #t)
             (check (member ['node (view-id v) (node-id n)] keys) => #f)
             (check (line-runs-drawn keys) => 0)
             (check (lines-drawn keys) => 0))))))

    (test-case "lines: the placement marker names its line by the token the line is drawn with"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (insert (fifty-thousand-lines))
         (let* ((v (selected-view))
                (n (view-node v)))
           (place-view! v (node-item-at n 99) 'center)
           (screen)
           ;; "100" was born before the edit above it, which moved it.
           (goto-char 1)
           (insert "x\n")
           (place-view! v (node-item-at n 100) 'top)
           (let* ((html (screen))
                  (target (attribute-before html "data-target=\"" (string-contains html "data-align"))))
             (check target => (line-token html "100"))
             (check (item-line (token-item n target)) => 101))))))

    (test-case "lines: a line kept past the text's journal is born again; its old token names nothing"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (insert "a\nb\nc")
         (let* ((n (view-node (selected-view)))
                (t (text-node-content n))
                (old (line-token (screen) "b")))
           (check (item-line (token-item n old)) => 2)
           (for-each (lambda (_) (text-replace! t (fx1+ (text-size t)) (fx1+ (text-size t)) "x")) (iota 1100))
           (let (new (line-token (screen) "b"))
             (check (equal? new old) => #f)
             (check (token-item n old) => #f)
             (check (item-line (token-item n new)) => 2))))))))
