(import :std/test
        :tuna/kernel
        :tuna/services/renderer
        :tuna/services/buffers
        :tuna/plugins/rope
        :tuna/plugins/settings
        :tuna/plugins/buffers
        :tuna/plugins/single-view
        :tuna/plugins/html-renderer
        "../test-support/kernel"
        "../test-support/session")
(export html-renderer-test)

(def renderer-plugins
  [rope-text-store-plugin settings-plugin no-session-plugin
   buffers-plugin single-view-plugin html-renderer-plugin])

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
         (check (buffer-name (current-buffer)) => "*scratch*"))))))
