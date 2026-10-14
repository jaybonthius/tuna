;;; Integration: the layout slot swapped live (C-c w) to the two-view
;;; contract double (tuna/test-support/two-views.ss) and back, and C-x o
;;; between two views of one buffer, with editing, a prompt, and a tree
;;; buffer, driven by keys through the real editor loop.
(import :std/test
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
        :tuna/plugins/session
        (only-in :tuna/services/session save-session restore-session)
        "../test-support/kernel"
        "../test-support/keys"
        "../test-support/session"
        "../test-support/two-views"
        "../test-support/swap-commands"
        "../test-support/rename-command"
        "../test-support/tree-buffer")
(export layout-swap-test)

(def layout-plugins
  [commands-plugin keys-plugin echo-area-plugin help-buffer-plugin rope-text-store-plugin
   settings-plugin no-session-plugin buffers-plugin layout-plugin
   view-commands-plugin
   html-renderer-plugin basic-editing-plugin minibuffer-plugin
   swap-commands-plugin rename-command-plugin tree-buffer-plugin])

(def (on-baton thunk) (call-on-editor-loop thunk))

;; The same plugins with the real session plugin, saving in DIRECTORY.
(def (call-with-session directory thunk)
  (call-with-fresh-kernel []
    (lambda ()
      (parameterize ((session-state-directory directory))
        (for-each activate-plugin!
                  (map (lambda (p) (if (eq? p no-session-plugin) session-plugin p)) layout-plugins)))
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
    (test-case "C-c w hands the views over to two views and back, keeping views and points"
      (call-with-fresh-kernel layout-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "h" "e" "l" "l" "o" "C-a" "C-f" "C-f")
         (check (views-state) => [[["*scratch*" 3]] 0])
         (type! "C-c" "w")
         ;; The new view starts at the selected view's point, as a split does.
         (check (views-state) => [[["*scratch*" 3] ["*scratch*" 3]] 0])
         (check (on-baton (lambda () (plugin-active? view-commands-plugin))) => #t)
         (type! "C-x" "o" "C-e")
         (check (views-state) => [[["*scratch*" 3] ["*scratch*" 6]] 1])
         ;; Back under the default layout, the toy's second view is split in.
         (type! "C-c" "w")
         (check (views-state) => [[["*scratch*" 3] ["*scratch*" 6]] 1])
         (type! "C-c" "w")
         (check (views-state) => [[["*scratch*" 3] ["*scratch*" 6]] 1]))))

    (test-case "a saved layout slot never overwrites views handed over live"
      (call-with-state-directory
       (lambda (directory)
         (call-with-session directory
           (lambda ()
             (type! "h" "e" "l" "l" "o" "C-a" "C-f")
             (on-baton save-session)
             (type! "C-e")
             (type! "C-c" "w")
             (check (views-state) => [[["*scratch*" 6] ["*scratch*" 6]] 0])
             (type! "C-a" "C-c" "w")
             (check (views-state) => [[["*scratch*" 1] ["*scratch*" 6]] 0]))))))

    (test-case "the default layout keeps its arrangement for views the toy hands back"
      (call-with-fresh-kernel layout-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "a" "b" "c" "C-x" "2" "C-x" "3" "C-b")
         (check (views-state) => [[["*scratch*" 3] ["*scratch*" 4] ["*scratch*" 4]] 0])
         (type! "C-c" "w")
         ;; The toy keeps the selected view and its neighbor.
         (check (views-state) => [[["*scratch*" 3] ["*scratch*" 4]] 0])
         (type! "C-c" "w")
         (check (views-state) => [[["*scratch*" 3] ["*scratch*" 4]] 0])
         (let (html (screen))
           (check (count-of "class=\"container fit horizontal\"" html) => 1)
           ;; Only the bar's: the bar itself, and the container holding it
           ;; under the rest.
           (check (count-of "class=\"container fit vertical\"" html) => 2)))))

    (test-case "C-x o moves between two views of one buffer with independent points"
      (call-with-fresh-kernel layout-plugins
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
      (call-with-fresh-kernel layout-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "a" "C-x" "o" "b")
         (check (text) => "ab")
         (check (views-state) => [[["*scratch*" 3]] 0]))))

    (test-case "under the toy, which has no bar, a prompt shows in the other view while it waits"
      (call-with-fresh-kernel layout-plugins
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
      (call-with-fresh-kernel layout-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "C-c" "w" "C-c" "b" "C-x" "o" "C-c" "b")
         (check (map car (car (views-state))) => ["*welcome*" "*welcome*"])
         (on-baton (lambda () (deactivate-plugin! tree-buffer-plugin)))
         (check (map car (car (views-state))) => ["*scratch*" "*scratch*"]))))

    (test-case "C-h s shows the layout, its provider, and its dependents"
      (call-with-fresh-kernel layout-plugins
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
