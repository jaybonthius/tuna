;;; Integration: the real plugins of a browser editor, driven over real
;;; loopback HTTP. Every client's stream receives the new screen, C-g
;;; sent from the browser stops a running command, and keys and clicks are
;;; handled in the order they were sent. This tests the web transport
;;; together with keys, buffers, layout, view commands, rendering, help, and
;;; quitting; tuna/plugins/web-test.ss tests the transport alone.
(import :std/io
        :std/test
        :tuna/kernel
        :tuna/services/buffers
        :tuna/services/layout
        :tuna/services/echo-area
        :tuna/plugins/keys
        :tuna/plugins/web
        :tuna/plugins/echo-area
        :tuna/plugins/help-buffer
        :tuna/plugins/rope
        :tuna/plugins/settings
        :tuna/plugins/buffers
        :tuna/plugins/layout
        :tuna/plugins/view-commands
        :tuna/plugins/html-renderer
        :tuna/plugins/basic-editing
        "../test-support/session"
        "../test-support/endless-commands"
        "../test-support/services-help"
        "../test-support/web-client")
(export web-test)

(def browser-editor-plugins
  [keys-plugin web-transport-plugin echo-area-plugin help-buffer-plugin
   rope-text-store-plugin settings-plugin no-session-plugin buffers-plugin layout-plugin
   view-commands-plugin html-renderer-plugin basic-editing-plugin endless-commands-plugin services-help-plugin])

(def (with-tuna thunk)
  (with-web-tuna browser-editor-plugins thunk))

(def (wait-until ready?)
  (let lp ((tries 300))
    (cond
     ((ready?) #t)
     ((zero? tries) #f)
     (else (thread-sleep! 0.01) (lp (- tries 1))))))


(def (settled-message) (call-on-editor-loop current-message))

;; Show a new buffer NAME, holding one empty text node, in V.
(def (show-new-buffer! v name)
  (let (b (new-buffer name (new-text-node (new-text ""))))
    (add-buffer! b)
    (set-view-buffer v b)))

(def (buffer-string name)
  (text-string (text-node-content (buffer-point-node (get-buffer name)))))

(def web-test
  (test-suite "integration: the browser editor over HTTP"
    (test-case "every client's stream receives the new screen; C-h s lists the services"
      (with-tuna
       (lambda ()
         (let ((first (open-screen-stream))
               (second (open-screen-stream)))
           (check (and (string-search "datastar-patch-elements" (read-until first (cut string-search "id=\"screen\"" <>))) #t)
                  => #t)
           (post-key "h" ctrl?: #t)
           (post-key "s")
           (for-each
             (lambda (stream)
               (let (text (read-until stream (cut string-search "text-store (live)" <>)))
                 (check (and (string-search "input (startup)  provider: keys-plugin  dependents: " text) #t)
                        => #t)
                 (check (and (string-search "renderer (live)  provider: html-renderer-plugin" text) #t)
                        => #t)
                 (check (and (string-search "text-store (live)  provider: rope-text-store-plugin" text) #t)
                        => #t)
                 (check (and (string-search "display (startup)  provider: web-transport-plugin" text) #t)
                        => #t)))
             [first second])
           (Socket-close first)
           (Socket-close second)))))

    (test-case "C-c l then C-g recovers; so does C-c L, by force"
      (with-tuna
       (lambda ()
         (post-key "c" ctrl?: #t)
         (post-key "l")
         (check (wait-until (lambda () (eq? (current-task-name) 'loop-forever))) => #t)
         (post-key "g" ctrl?: #t)
         (check (settled-message) => "Quit")
         (post-key "c" ctrl?: #t)
         (post-key "L")
         (check (wait-until (lambda () (eq? (current-task-name) 'loop-forever-ignoring-quit))) => #t)
         (post-key "g" ctrl?: #t)
         (check (settled-message) => "Quit (forced: plugin or library state may be inconsistent)")
         (post-key "h" ctrl?: #t)
         (post-key "s")
         (check (settled-message) => ""))))

    (test-case "keys and clicks sent back to back are handled in the order sent"
      (with-tuna
       (lambda ()
         ;; left | (tab one | tab two), left selected.
         (let* ((ids (call-on-editor-loop
                      (lambda ()
                        (let* ((left (selected-view))
                               (one (split-view left 'right)))
                          (show-new-buffer! left "left")
                          (show-new-buffer! one "one")
                          (select-view one)
                          [left one]))))
                (left (car ids))
                (one (cadr ids)))
           (post-key "x" ctrl?: #t)
           (post-key "t")
           (post-key "2")
           (let* ((two (call-on-editor-loop
                        (lambda ()
                          (let (two (selected-view))
                            (show-new-buffer! two "two")
                            (select-view left)
                            two))))
                  (tab (lambda (v) (string-append "tab-line:" (number->string (view-id v)))))
                  (revision (page-revision)))
             (check (and (string-search (string-append "data-part=\"" (tab two) "\" data-clickable") 
                                        (reply-body (http "GET" "/")))
                         #t)
                    => #t)
             (for-each (lambda (step) (if (pair? step) (post-click (car step) revision: revision) (post-key step)))
                       ["1" "2" [(tab one)] "3" "4" [(tab two)] "5"
                        [(string-append "view:" (number->string (view-id left)))] "6"])
             (check (call-on-editor-loop (lambda () (map buffer-string ["left" "one" "two"])))
                    => ["126" "34" "5"])
             ;; Close tab two, then click it on the screen that still showed it.
             (post-click (tab two) revision: revision)
             (post-key "x" ctrl?: #t)
             (post-key "t")
             (post-key "0")
             (post-click (tab two) revision: revision)
             (check (settled-message)
                    => (string-append "Stale click: the tab is gone (clicked on screen "
                                      (number->string revision) ")"))
             (post-key "7")
             (check (call-on-editor-loop (lambda () (map buffer-string ["left" "one" "two"])))
                    => ["126" "347" "5"]))))))))