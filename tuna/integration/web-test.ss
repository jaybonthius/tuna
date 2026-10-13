;;; Integration: the real plugins of a browser editor, driven over real
;;; loopback HTTP. Every client's stream receives the new screen, and C-g
;;; sent from the browser stops a running command. This tests the web
;;; transport together with keys, buffers, rendering, help, and quitting;
;;; tuna/plugins/web-test.ss tests the transport alone.
(import :std/io
        :std/test
        :tuna/kernel
        :tuna/services/echo-area
        :tuna/plugins/keys
        :tuna/plugins/web
        :tuna/plugins/echo-area
        :tuna/plugins/help-buffer
        :tuna/plugins/rope
        :tuna/plugins/settings
        :tuna/plugins/buffers
        :tuna/plugins/layout
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
   html-renderer-plugin basic-editing-plugin endless-commands-plugin services-help-plugin])

(def (with-tuna thunk)
  (with-web-tuna browser-editor-plugins thunk))

(def (wait-until ready?)
  (let lp ((tries 300))
    (cond
     ((ready?) #t)
     ((zero? tries) #f)
     (else (thread-sleep! 0.01) (lp (- tries 1))))))


(def (settled-message) (call-on-editor-loop current-message))

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
         (check (settled-message) => ""))))))
