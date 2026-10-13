;;; Integration: the layout slot swapped live (C-c w) to the two-view
;;; contract double (tuna/test-support/two-views.ss) and back, and C-x o
;;; between two views of one buffer, with editing, a prompt, and a tree
;;; buffer, driven by keys through the real editor loop.
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
        :tuna/plugins/single-view
        :tuna/plugins/view-commands
        :tuna/plugins/html-renderer
        :tuna/plugins/basic-editing
        :tuna/plugins/minibuffer
        "../test-support/kernel"
        "../test-support/keys"
        "../test-support/session"
        "../test-support/two-views"
        "../test-support/swap-commands"
        "../test-support/rename-command"
        "../test-support/tree-buffer")
(export layout-swap-test)

(def layout-plugins
  [keys-plugin echo-area-plugin help-panel-plugin rope-text-store-plugin
   settings-plugin no-session-plugin buffers-plugin single-view-plugin
   view-commands-plugin
   html-renderer-plugin basic-editing-plugin minibuffer-plugin
   swap-commands-plugin rename-command-plugin tree-buffer-plugin])

(def (on-baton thunk) (call-on-editor-loop thunk))

;; Each view's buffer name and point, in order, and the selected one's
;; index.
(def (views-state)
  (on-baton
   (lambda ()
     (let (views (view-list))
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
    (test-case "C-c w hands the view over to two views and back, keeping points"
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
         (type! "C-c" "w")
         (check (views-state) => [[["*scratch*" 6]] 0])
         (type! "C-c" "w")
         (check (views-state) => [[["*scratch*" 6] ["*scratch*" 6]] 0]))))

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

    (test-case "a prompt keeps the focus while C-x o selects another view"
      (call-with-fresh-kernel layout-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "a" "C-c" "w" "C-c" "r" "C-x" "o" "n")
         (check (views-state) => [[["*scratch*" 2] ["*scratch*" 2]] 1])
         (type! "RET")
         (check (on-baton (lambda () (buffer-name (current-buffer)))) => "n")
         ;; The focus returns to the view selected meanwhile.
         (type! "b")
         (check (views-state) => [[["n" 2] ["n" 3]] 1]))))

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
                                 ["html-renderer-plugin" "view-commands-plugin"])))))))))
