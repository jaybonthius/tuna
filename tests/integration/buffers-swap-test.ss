;;; Integration: the buffers provider swapped live (C-c B) to the toy
;;; (tuna/test-support/toy-buffers.ss) and back while the editor runs, with
;;; typing, undo, a renamed buffer, a tree buffer, two views, and the
;;; renderer, driven by keys through the real editor loop. Every buffer's
;;; saved plain text, the selected view, and its point carry over; unsaved
;;; rich trees are recreated by their owning plugins.
(import (only-in :tuna/boot session-owner restart-plugin!)
        :std/test
        :tuna/kernel
        :tuna/plugins/renderer/contract
        :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/layout/contract
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/plugin
        :tuna/plugins/echo-area/plugin
        :tuna/plugins/help/plugin
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/buffers/plugin
        :tuna/plugins/layout/plugin
        :tuna/plugins/view-commands/plugin
        :tuna/plugins/renderer/plugin
        :tuna/plugins/editing/plugin
        :tuna/plugins/minibuffer/plugin
        "../../tuna/tests/support/kernel"
        "../../plugins/keys/tests/support/keys"
        :tuna/plugins/autosave/plugin
        :tuna/plugins/session/plugin
        :tuna/plugins/session/contract
        "../../plugins/buffers/tests/support/toy-buffers"
        "../support/swap-commands"
        "../support/rename-command"
        "../support/tree-buffer")
(export buffers-swap-test)

(defplugin (swap-configuration ctx)
  "Selects the default providers for swap commands in this test configuration."
  (context-set-swap-providers! ctx html-renderer layout buffers))


(def (call-with-state-kernel (plugins : :list) (thunk : :procedure)) => :t
  (let (directory (path-expand (string-append "tuna-swap-" (number->string (random-integer 1000000000)))
                              (getenv "TMPDIR" "/tmp")))
    (create-directory* directory)
    (unwind-protect
      (parameterize ((session-state-directory directory))
        (call-with-fresh-kernel plugins
          (lambda () (when (service-provider session-service) (restore-session)) (thunk))))
      (delete-file-or-directory directory #t))))

;; A command from a plugin that the buffers swap itself restarts, as M-x
;; is: the swap must complete although the command's task is cancelled.
(defplugin (dependent-swapper ctx)
  "Runs swap-buffers from a command of a plugin that requires buffers."
  requires: [commands-service input-service buffers-service]
  (define-command ctx (swap-from-dependent) "Swap buffers from a dependent plugin's command."
    (call-command 'swap-buffers))
  (keymap-set ctx "C-c D" 'swap-from-dependent))

(def swap-plugins
  [session-owner commands keys echo-area help rope-text-store
   settings session buffers autosave layout
   view-commands html-renderer editing minibuffer
   swap-configuration swap-commands rename-command tree-buffer dependent-swapper])

(def (on-baton thunk) (call-on-editor-loop thunk))

;; Every buffer's name and text, oldest first.
;; Each buffer's name and text, internal ones (the bar's, which their
;; plugins rebuild on a swap) left out.
(def (buffer-texts-state)
  (on-baton
   (lambda ()
     (map (lambda (b) [(buffer-name b) (node-text-projection (buffer-root b))])
          (list-sort (lambda (a b) (string<? (buffer-name a) (buffer-name b)))
                     (filter (lambda (b) (not (internal-buffer? b))) (buffer-list)))))))

;; The views outside the bar, whose plugins put them back on a swap.
(def (own-views)
  (filter (lambda (v) (not (internal-buffer? (view-showing v)))) (view-list)))

;; The selected view's buffer and point.
(def (selected-state)
  (on-baton (lambda () [(buffer-name (current-buffer)) (point)])))

(def (toy?) (on-baton (lambda () (plugin-active? toy-buffers))))

(def (screen)
  (on-baton (lambda () (html->string (Renderer-render-screen (Renderer (service-provider renderer-service)) #f)))))

(def buffers-swap-test
  (test-suite "integration: swapping the buffers provider live"
    (test-case "C-c B restores saved plain-text buffers to the toy and back, keeping text and point"
      (call-with-state-kernel swap-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "h" "e" "l" "l" "o" "RET" "w" "o" "r" "l" "d" "C-p" "C-e")
         (type! "C-c" "r" "n" "o" "t" "e" "s" "RET")
         (on-baton (lambda () (add-buffer! (new-buffer "*scratch*" (new-text-node (new-text ""))))))
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

    (test-case "a swap run by a command whose plugin the swap restarts completes"
      (call-with-state-kernel swap-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "h" "i")
         (type! "C-c" "D")
         (check (toy?) => #t)
         (check (on-baton (lambda () (plugin-active? html-renderer))) => #t)
         (check (and (string-contains (screen) "hi") #t) => #t)
         (type! "C-c" "D")
         (check (toy?) => #f)
         (check (and (string-contains (screen) "hi") #t) => #t))))

    (test-case "two views and the tree buffer survive a swap"
      (call-with-state-kernel swap-plugins
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
           (check (selected-state) => ["*welcome*" 2])
           (on-baton (lambda () (switch-to-buffer (get-buffer "*scratch*"))))
           (type! "C-c" "w" "C-e" "C-x" "o" "Z")
           (check (on-baton (lambda () (map (lambda (v) (buffer-name (view-showing v))) (own-views))))
                  => ["*scratch*" "*scratch*"])
           (check (on-baton (lambda () (text-string (current-text)))) => "abcZ")
           (type! "C-c" "B")
           (check (on-baton (lambda () (text-string (current-text)))) => "abcZ")))))

    (test-case "the layout restarts across a swap: split views, tabs, points and the frame stay"
      (call-with-state-kernel swap-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "h" "e" "l" "l" "o" "C-x" "3" "C-a" "C-f" "C-x" "o" "C-x" "t" "2" "C-b")
         (let ((views (on-baton own-views))
               (state (lambda ()
                        (on-baton (lambda ()
                                    [(map (lambda (v) [(buffer-name (view-showing v)) (view-point v)])
                                          (own-views))
                                     (let loop ((rest (own-views)) (i 0))
                                       (if (eq? (car rest) (selected-view)) i (loop (cdr rest) (fx1+ i))))])))))
           (check (map car (car (state))) => ["*scratch*" "*scratch*" "*scratch*"])
           (check (map cadr (car (state))) => [2 6 5])
           (type! "C-x" "1")
           (let (before (state))
             (type! "C-c" "B")
             (check (toy?) => #t)
             ;; Fresh views, restored from the layout slot.
             (check (eq? (car (on-baton own-views)) (car views)) => #f)
             (check (state) => before)
             (check (on-baton (lambda () (frame-target-part (current-frame-target))))
                    => (on-baton (lambda () (view-id (selected-view)))))
             (type! "!")
             (check (on-baton (lambda () (text-string (current-text)))) => "hell!o")
             (type! "C-x" "n" "w" "C-c" "B")
             (check (toy?) => #f)
             (check (eq? (car (on-baton own-views)) (car views)) => #f)
             (check (state) => [[["*scratch*" 2] ["*scratch*" 7] ["*scratch*" 6]] (cadr before)]))))))

    (test-case "C-h s shows the toy providing buffers, and the default inactive"
      (call-with-state-kernel swap-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "C-c" "B")
         (check (on-baton (lambda ()
                            (service-info-provider
                             (find (lambda (info) (eq? (service-info-name info) 'buffers))
                                   (describe-services)))))
                => 'toy-buffers)
         (check (on-baton (lambda () (plugin-active? buffers))) => #f))))))
