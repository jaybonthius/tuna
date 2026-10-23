;;; Integration: the real plugins of a browser editor, driven over real
;;; loopback HTTP. Every client's stream receives the new screen, C-g
;;; sent from the browser stops a running command, keys and clicks are
;;; handled in the order they were sent, and each tab's keys in progress
;;; are its own. This tests the web transport
;;; together with keys, buffers, layout, view commands, clicks in text,
;;; rendering, help, and quitting; tuna/plugins/web-test.ss tests the transport alone.
(import :std/io
        :std/test
        :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract
        :tuna/plugins/echo-area/contract
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/plugin
        :tuna/plugins/web/plugin
        :tuna/plugins/echo-area/plugin
        :tuna/plugins/help/plugin
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/buffers/plugin
        :tuna/plugins/layout/plugin
        :tuna/plugins/view-commands/plugin
        :tuna/plugins/region/plugin
        :tuna/plugins/text-mouse/plugin
        :tuna/plugins/renderer/plugin
        :tuna/plugins/basic-editing/plugin
        :tuna/plugins/minibuffer/plugin
        "../../plugins/session/tests/support/session"
        "../support/endless-commands"
        "../support/services-help"
        "../../plugins/web/tests/support/web-client")
(export web-test)

(def browser-editor-plugins
  [commands keys web-transport echo-area help-buffer
   rope-text-store settings no-session buffers layout
   minibuffer view-commands region text-mouse html-renderer basic-editing endless-commands services-help])

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
                 (check (and (string-search "input (startup)  provider: keys  dependents: " text) #t)
                        => #t)
                 (check (and (string-search "renderer (live)  provider: html-renderer" text) #t)
                        => #t)
                 (check (and (string-search "text-store (live)  provider: rope-text-store" text) #t)
                        => #t)
                 (check (and (string-search "display (startup)  provider: web-transport" text) #t)
                        => #t)))
             [first second])
           (Socket-close first)
           (Socket-close second)))))

    (test-case "a buffer holding CR and NUL is sent, and its stream stays open"
      (with-tuna
       (lambda ()
         (let (stream (open-screen-stream))
           (read-until stream (cut string-search "id=\"screen\"" <>))
           (call-on-editor-loop
            (lambda ()
              (let (b (new-buffer "*control*"
                                  (new-text-node (new-text (string #\a #\return #\b #\newline #\c #\nul #\d)))))
                (add-buffer! b)
                (set-view-buffer (selected-view) b))
              (redisplay)))
           (let (text (read-until stream (cut string-search "c&#xFFFD;d" <>)))
             (check (and (string-search "<span class=\"cursor\">a</span>&#13;b" text) #t) => #t)
             (check (and (string-search "c&#xFFFD;d" text) #t) => #t))
           ;; The stream goes on: a key typed there arrives.
           (post-key "x")
           (let (typed "x<span class=\"cursor\">a</span>&#13;b")
             (check (and (string-search typed (read-until stream (cut string-search typed <>))) #t)
                    => #t))
           (Socket-close stream)))))

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

    (test-case "each tab's keys in progress are its own: C-x in one tab, then b in another types b"
      (with-tuna
       (lambda ()
         (call-on-editor-loop (lambda () (show-new-buffer! (selected-view) "typed")))
         (let* ((a (current-tab))
                (b (new-tab!))
                (views (lambda () (call-on-editor-loop (lambda () (length (view-list))))))
                (before (views)))
           (post-key "x" ctrl?: #t tab: a)
           (post-key "b" tab: b)
           (check (wait-until (lambda () (equal? (call-on-editor-loop (lambda () (buffer-string "typed"))) "b")))
                  => #t)
           (check (views) => before)
           ;; A's next key still completes A's C-x: C-x 3 splits the view.
           (post-key "3" tab: a)
           (check (wait-until (lambda () (= (views) (+ before 1)))) => #t)
           (check (call-on-editor-loop (lambda () (buffer-string "typed"))) => "b")))))

    (test-case "a new page lands at the view's scroll position"
      (with-tuna
       (lambda ()
         (let (token (call-on-editor-loop
                      (lambda ()
                        (insert (let lp ((k 500) (out "")) (if (zero? k) out (lp (- k 1) (string-append (number->string k) "\n" out)))))
                        (let* ((v (selected-view))
                               (n (view-node v))
                               (t (text-node-content n)))
                          (place-view! v (node-item-at n 299) 'top offset: 7.)
                          ;; The token line 300 is drawn with, first drawn
                          ;; now: by its end and the text's revision.
                          (string-append (number->string (node-id n)) "." (number->string (text-line-end t 300))
                                         "." (number->string (text-chars-revision t)))))))
           (check (and (string-search (string-append "data-target=\"" token "\" data-align=\"top\" data-offset=\"7.\"")
                                      (reply-body (http "GET" "/")))
                       #t)
                  => #t)))))

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
             ;; A key's 204 arrives before the key runs, so wait for the last one.
             (check (wait-until
                     (lambda ()
                       (equal? (call-on-editor-loop
                                (lambda () (map buffer-string ["left" "one" "two"])))
                               ["126" "34" "5"])))
                    => #t)
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