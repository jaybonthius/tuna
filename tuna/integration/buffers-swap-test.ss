;;; Integration: the buffers provider swapped live (C-c B) to the toy
;;; (tuna/test-support/toy-buffers.ss) and back while the editor runs, with
;;; typing, undo, a renamed buffer, a tree buffer, two views, and the
;;; renderer, driven by keys through the real editor loop. Every buffer's
;;; text, the selected view, and its point carry over.
(import :std/test
        :tuna/kernel
        :tuna/services/renderer
        :tuna/services/buffers
        :tuna/services/layout
        :tuna/plugins/keys
        :tuna/plugins/echo-area
        :tuna/plugins/help-panel
        :tuna/plugins/rope
        :tuna/plugins/settings
        :tuna/plugins/buffers
        :tuna/plugins/layout
        :tuna/plugins/view-commands
        :tuna/plugins/html-renderer
        :tuna/plugins/basic-editing
        :tuna/plugins/minibuffer
        "../test-support/kernel"
        "../test-support/keys"
        "../test-support/session"
        "../test-support/toy-buffers"
        "../test-support/swap-commands"
        "../test-support/rename-command"
        "../test-support/tree-buffer")
(export buffers-swap-test)

(def swap-plugins
  [keys-plugin echo-area-plugin help-panel-plugin rope-text-store-plugin
   settings-plugin no-session-plugin buffers-plugin layout-plugin
   view-commands-plugin html-renderer-plugin basic-editing-plugin minibuffer-plugin
   swap-commands-plugin rename-command-plugin tree-buffer-plugin])

(def (on-baton thunk) (call-on-editor-loop thunk))

;; Every buffer's name and text, oldest first.
(def (buffer-texts-state)
  (on-baton
   (lambda ()
     (map (lambda (b) [(buffer-name b) (node-text-projection (buffer-root b))])
          (buffer-list)))))

;; The selected view's buffer and point.
(def (selected-state)
  (on-baton (lambda () [(buffer-name (current-buffer)) (point)])))

(def (toy?) (on-baton (lambda () (plugin-active? toy-buffers-plugin))))

(def (screen)
  (on-baton (lambda () (Renderer-render-screen (Renderer (service-provider renderer-service))))))

(def buffers-swap-test
  (test-suite "integration: swapping the buffers provider live"
    (test-case "C-c B hands every buffer over to the toy and back, keeping text and point"
      (call-with-fresh-kernel swap-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "h" "e" "l" "l" "o" "RET" "w" "o" "r" "l" "d" "C-p" "C-e")
         (type! "C-c" "r" "n" "o" "t" "e" "s" "RET")
         (let (before (buffer-texts-state))
           (check (selected-state) => ["notes" 6])
           (type! "C-c" "B")
           (check (toy?) => #t)
           (check (buffer-texts-state) => before)
           (check (selected-state) => ["notes" 6])
           ;; Editing, undo, and the renderer work under the toy.
           (type! "!" "C-n" "?")
           (check (on-baton (lambda () (text-string (current-text)))) => "hello!\nworld?")
           (type! "C-/")
           (check (on-baton (lambda () (text-string (current-text)))) => "hello!\nworld")
           (check (and (string-contains (screen) "hello!") #t) => #t)
           (type! "C-c" "B")
           (check (toy?) => #f)
           (check (selected-state) => ["notes" 13])
           (check (on-baton (lambda () (text-string (current-text)))) => "hello!\nworld")
           (check (map car (buffer-texts-state)) => (map car before))))))

    (test-case "two views and the tree buffer survive a swap"
      (call-with-fresh-kernel swap-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "a" "b" "c" "C-c" "b" "X")
         (check (selected-state) => ["*welcome*" 2])
         (let (welcome (assoc "*welcome*" (buffer-texts-state)))
           (type! "C-c" "B")
           ;; The tree buffer's plugin restarts with the swap and adds a fresh
           ;; *welcome*; the selected view fell back to *scratch*, at the
           ;; point it left there.
           (check (assoc "*scratch*" (buffer-texts-state)) => ["*scratch*" "abc"])
           (check (and (assoc "*welcome*" (buffer-texts-state)) #t) => #t)
           (check (equal? (assoc "*welcome*" (buffer-texts-state)) welcome) => #f)
           (check (selected-state) => ["*scratch*" 4])
           (type! "C-c" "w" "C-e" "C-x" "o" "Z")
           (check (on-baton (lambda () (map (lambda (v) (buffer-name (view-showing v))) (view-list))))
                  => ["*scratch*" "*scratch*"])
           (check (on-baton (lambda () (text-string (current-text)))) => "abcZ")
           (type! "C-c" "B")
           (check (on-baton (lambda () (text-string (current-text)))) => "abcZ")))))

    (test-case "C-h s shows the toy providing buffers, and the default waiting behind it"
      (call-with-fresh-kernel swap-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "C-c" "B")
         (check (on-baton (lambda ()
                            (service-info-provider
                             (find (lambda (info) (eq? (service-info-name info) 'buffers))
                                   (describe-services)))))
                => 'toy-buffers-plugin)
         (check (on-baton (lambda () (plugin-active? buffers-plugin))) => #t))))))
