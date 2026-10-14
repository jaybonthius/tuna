;;; Integration: the layout slot swapped live (C-c w) to the two-view
;;; contract double (tuna/test-support/two-views.ss) and back, and C-x o
;;; between two views of one buffer, with editing, a prompt, and a tree
;;; buffer, driven by keys through the real editor loop.
(import (only-in :tuna/boot config-service restart-plugin!)
        :std/test
        :tuna/kernel
        :tuna/services/renderer
        :tuna/services/buffers
        :tuna/services/layout
        :tuna/plugins/commands
        :tuna/plugins/keys
        :tuna/plugins/echo-area
        :tuna/plugins/help-buffer
        :tuna/plugins/rope
        :tuna/plugins/settings
        :tuna/plugins/buffers
        :tuna/plugins/layout
        :tuna/plugins/view-commands
        :tuna/plugins/html-renderer
        :tuna/plugins/basic-editing
        :tuna/plugins/minibuffer
        :tuna/plugins/autosave
        :tuna/plugins/session
        (only-in :tuna/services/session session-service save-session restore-session)
        "../test-support/kernel"
        "../test-support/keys"
        "../test-support/two-views"
        "../test-support/swap-commands"
        "../test-support/rename-command"
        "../test-support/tree-buffer")
(export layout-swap-test)

(defplugin (swap-configuration ctx)
  "Selects the default providers for swap commands in this test configuration."
  (context-set-swap-providers! ctx html-renderer-plugin layout-plugin buffers-plugin))


(def (call-with-state-kernel (plugins : :list) (thunk : :procedure)) => :t
  (let (directory (path-expand (string-append "tuna-swap-" (number->string (random-integer 1000000000)))
                              (getenv "TMPDIR" "/tmp")))
    (create-directory* directory)
    (unwind-protect
      (parameterize ((session-state-directory directory))
        (call-with-fresh-kernel plugins
          (lambda () (when (service-provider session-service) (restore-session)) (thunk))))
      (delete-file-or-directory directory #t))))

(def layout-plugins
  [commands-plugin keys-plugin echo-area-plugin help-buffer-plugin rope-text-store-plugin
   settings-plugin session-plugin buffers-plugin autosave-plugin layout-plugin
   view-commands-plugin
   html-renderer-plugin basic-editing-plugin minibuffer-plugin
   config-service swap-configuration swap-commands-plugin rename-command-plugin tree-buffer-plugin])

(def (on-baton thunk) (call-on-editor-loop thunk))

;; The same plugins with the real session plugin, saving in DIRECTORY.
(def (call-with-session directory thunk)
  (call-with-state-kernel []
    (lambda ()
      (parameterize ((session-state-directory directory))
        (for-each activate-plugin!
                  (map (lambda (p) p) layout-plugins)))
      (restore-session)
      (start-editor-loop!)
      (thunk))))

(def (call-with-state-directory proc)
  (let (directory (path-expand (string-append "tuna-layout-swap-test-"
                                              (number->string (random-integer 1000000000)))
                               (getenv "TMPDIR" "/tmp")))
    (create-directory* directory)
    (try
     (proc directory)
     (finally
      (delete-file-or-directory directory #t)))))

;; Each view's buffer name and point, in order, and the selected one's
;; index; views of internal buffers (the bar's) left out.
(def (views-state)
  (on-baton
   (lambda ()
     (let (views (filter (lambda (v) (not (internal-buffer? (view-showing v)))) (view-list)))
       [(map (lambda (v) [(buffer-name (view-showing v)) (view-point v)]) views)
        (let lp ((rest views) (i 0))
          (if (eq? (car rest) (selected-view)) i (lp (cdr rest) (+ i 1))))]))))

(def (text) (on-baton (lambda () (text-string (current-text)))))

(def (screen)
  (on-baton (lambda () (Renderer-render-screen (Renderer (service-provider renderer-service))))))

(def (count-of needle haystack)
  (let lp ((start 0) (n 0))
    (let (found (string-contains haystack needle start))
      (if found (lp (+ found 1) (+ n 1)) n))))

(def layout-swap-test
  (test-suite "integration: swapping the layout live"
    (test-case "C-c w restores neutral points and then each provider's private slot"
      (call-with-state-kernel layout-plugins
        (lambda ()
          (start-editor-loop!)
          (type! "h" "e" "l" "l" "o" "C-a" "C-f" "C-f")
          (type! "C-c" "w")
          (check (views-state) => [[["*scratch*" 3] ["*scratch*" 3]] 0])
          (type! "C-x" "o" "C-e")
          (type! "C-c" "w")
          (check (views-state) => [[["*scratch*" 3]] 0])
          (type! "C-c" "w")
          (check (views-state) => [[["*scratch*" 3] ["*scratch*" 6]] 1]))))

    (test-case "capture uses points newer than the last disk save"
      (call-with-state-kernel layout-plugins
        (lambda ()
          (start-editor-loop!)
          (type! "h" "e" "l" "l" "o" "C-a" "C-f")
          (on-baton save-session)
          (type! "C-e" "C-c" "w")
          (check (views-state) => [[["*scratch*" 6] ["*scratch*" 6]] 0])
          (type! "C-a" "C-c" "w")
          (check (views-state) => [[["*scratch*" 6]] 0]))))

    (test-case "switching back restores the default's full private split arrangement"
      (call-with-state-kernel layout-plugins
        (lambda ()
          (start-editor-loop!)
          (type! "a" "b" "c" "C-x" "2" "C-x" "3" "C-b")
          (type! "C-c" "w")
          (check (views-state) => [[["*scratch*" 3] ["*scratch*" 4]] 0])
          (type! "C-c" "w")
          (check (views-state) => [[["*scratch*" 3] ["*scratch*" 4] ["*scratch*" 4]] 0])
          (check (count-of "class=\"container fit horizontal\"" (screen)) => 1))))

    (test-case "C-x o moves between two views of one buffer with independent points"
      (call-with-state-kernel layout-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "a" "b" "c" "d" "C-c" "w")
         (type! "C-a" "C-f")
         (check (views-state) => [[["*scratch*" 2] ["*scratch*" 5]] 0])
         (type! "C-x" "o" "!")
         (check (text) => "abcd!")
         (check (views-state) => [[["*scratch*" 2] ["*scratch*" 6]] 1])
         ;; Typing in the first view moves the second view's point along.
         (type! "C-x" "o" "X")
         (check (text) => "aXbcd!")
         (check (views-state) => [[["*scratch*" 3] ["*scratch*" 7]] 0])
         ;; Each view renders its own cursor; only the selected one is solid.
         (let (html (screen))
           (check (count-of "<section class=\"view\"" html) => 2)
           (check (count-of "data-selected=\"true\"" html) => 1)
           (check (count-of "class=\"cursor\"" html) => 1)
           (check (count-of "class=\"inactive-cursor\"" html) => 1)
           (check (count-of "line 1, column 2" html) => 1)
           (check (count-of "line 1, column 6" html) => 1))
         ;; Switching buffers in one view leaves the other alone.
         (type! "C-c" "b")
         (check (views-state) => [[["*welcome*" 1] ["*scratch*" 7]] 0]))))

    (test-case "with one view, C-x o stays put"
      (call-with-state-kernel layout-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "a" "C-x" "o" "b")
         (check (text) => "ab")
         (check (views-state) => [[["*scratch*" 3]] 0]))))

    (test-case "under the toy, which has no bar, a prompt shows in the other view while it waits"
      (call-with-state-kernel layout-plugins
       (lambda ()
         (def (shows)
           (on-baton (lambda ()
                       (map (lambda (v)
                              (let (b (view-showing v))
                                [(if (internal-buffer? b) 'prompt (buffer-name b)) (eq? v (selected-view))]))
                            (view-list)))))
         (start-editor-loop!)
         (type! "a" "C-c" "w" "C-c" "r" "n")
         (check (shows) => [["*scratch*" #f] ['prompt #t]])
         (check (text) => "n")
         (type! "RET")
         (check (on-baton (lambda () (buffer-name (current-buffer)))) => "n")
         ;; The other view shows its buffer again, and the first is selected.
         (check (shows) => [["n" #t] ["n" #f]])
         (type! "b")
         (check (views-state) => [[["n" 3] ["n" 2]] 0]))))

    (test-case "killing a buffer shows another in every view that showed it"
      (call-with-state-kernel layout-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "C-c" "w" "C-c" "b" "C-x" "o" "C-c" "b")
         (check (map car (car (views-state))) => ["*welcome*" "*welcome*"])
         (on-baton (lambda () (deactivate-plugin! tree-buffer-plugin)))
         (check (map car (car (views-state))) => ["*scratch*" "*scratch*"]))))

    (test-case "C-h s shows the layout, its provider, and its dependents"
      (call-with-state-kernel layout-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "C-c" "w")
         (check (on-baton (lambda ()
                            (find (lambda (info) (eq? (service-info-name info) 'layout))
                                  (describe-services))))
                ? (lambda (info)
                    (and (eq? (service-info-provider info) 'two-views-plugin)
                         (equal? (list-sort string<? (map symbol->string (service-info-dependents info)))
                                 ["echo-area-plugin" "help-buffer-plugin" "html-renderer-plugin"
                                  "minibuffer-plugin" "view-commands-plugin"])))))))))
