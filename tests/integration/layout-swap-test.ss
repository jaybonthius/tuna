;;; Integration: the layout slot swapped live (C-c w) to the two-view
;;; contract double (tuna/test-support/two-views.ss) and back, and C-x o
;;; between two views of one buffer, with editing, a prompt, and a tree
;;; buffer, driven by keys through the real editor loop.
(import (only-in :tuna/boot session-owner restart-plugin!)
        :std/test
        :tuna/kernel
        :tuna/plugins/renderer/contract
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
        :tuna/plugins/basic-editing/plugin
        :tuna/plugins/minibuffer/plugin
        :tuna/plugins/autosave/plugin
        :tuna/plugins/session/plugin
        (only-in :tuna/plugins/session/contract session-service save-session restore-session)
        "../../tuna/tests/support/kernel"
        "../../plugins/keys/tests/support/keys"
        "../../plugins/layout/tests/support/two-views"
        "../support/swap-commands"
        "../support/rename-command"
        "../support/tree-buffer")
(export layout-swap-test)

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

(def layout-plugins
  [session-owner commands keys echo-area help-buffer rope-text-store
   settings session buffers autosave layout
   view-commands
   html-renderer basic-editing minibuffer
   swap-configuration swap-commands rename-command tree-buffer])

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
         (on-baton (lambda () (deactivate-plugin! tree-buffer)))
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
                    (and (eq? (service-info-provider info) 'two-views)
                         (equal? (list-sort string<? (map symbol->string (service-info-dependents info)))
                                 ["echo-area" "help-buffer" "html-renderer"
                                  "minibuffer" "view-commands"])))))))))
