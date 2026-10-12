(import :std/test
        :tuna/kernel
        :tuna/services/renderer
        :tuna/services/buffers
        :tuna/plugins/keys
        :tuna/plugins/echo-area
        :tuna/plugins/rope
        :tuna/plugins/settings
        :tuna/plugins/buffers
        :tuna/plugins/html-renderer
        :tuna/plugins/demo)
(export html-renderer-test)

(def (with-editor thunk)
  (parameterize ((current-kernel (new-kernel)))
    (for-each activate-plugin!
              [keys-plugin echo-area-plugin rope-text-store-plugin settings-plugin buffers-plugin
               html-renderer-plugin demo-plugin])
    (thunk)))

(def (screen)
  (Renderer-render-screen (Renderer (service-provider renderer-service))))

;; Position of NEEDLE in HAYSTACK, or #f.
(def (offset needle haystack)
  (string-contains haystack needle))

(def html-renderer-test
  (test-suite "tuna/plugins/html-renderer"
    (test-case "*scratch* renders its one text node with the cursor"
      (with-editor
       (lambda ()
         (insert "a<b\nc")
         (goto-char 2)
         (let (html (screen))
           (check (and (offset "class=\"text\"" html) #t) => #t)
           (check (and (offset "a<span class=\"cursor\">&lt;</span>b" html) #t) => #t)
           (check (and (offset "line 1, column 1" html) #t) => #t)))))

    (test-case "highlights render as face classes, around and under the cursor"
      (with-editor
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
      (with-editor
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

    (test-case "a kind without an HTML renderer shows its text projection"
      (with-editor
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
