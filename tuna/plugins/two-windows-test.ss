;;; Window managers swapped live (C-c w), and C-x o between two views of one
;;; buffer, driven through the real editor loop.
(import :std/test
        :tuna/kernel
        :tuna/services/renderer
        :tuna/services/buffers
        :tuna/services/windows
        :tuna/plugins/keys
        :tuna/plugins/echo-area
        :tuna/plugins/help-panel
        :tuna/plugins/rope
        :tuna/plugins/settings
        :tuna/plugins/buffers
        :tuna/plugins/single-window
        :tuna/plugins/window-commands
        :tuna/plugins/html-renderer
        :tuna/plugins/basic-editing
        :tuna/plugins/minibuffer
        :tuna/plugins/demo)
(export two-windows-test)

(include "test-keys.ss")
(include "test-session.ss")

(def (with-windows thunk)
  (call-with-editor [keys-plugin echo-area-plugin help-panel-plugin rope-text-store-plugin
                     settings-plugin no-session-plugin buffers-plugin single-window-plugin
                     window-commands-plugin
                     html-renderer-plugin basic-editing-plugin minibuffer-plugin demo-plugin]
                    thunk))

(def (on-baton thunk) (call-on-editor-loop thunk))

;; Each window's buffer name and point, in order, and the selected one's
;; index.
(def (windows-state)
  (on-baton
   (lambda ()
     (let (windows (window-list))
       [(map (lambda (w)
               (let (v (window-view w))
                 [(buffer-name (view-showing v)) (view-point v)]))
             windows)
        (let lp ((rest windows) (i 0))
          (if (eq? (car rest) (selected-window)) i (lp (cdr rest) (+ i 1))))]))))

(def (text) (on-baton (lambda () (text-string (current-text)))))

(def (screen)
  (on-baton (lambda () (Renderer-render-screen (Renderer (service-provider renderer-service))))))

(def (count-of needle haystack)
  (let lp ((start 0) (n 0))
    (let (found (string-contains haystack needle start))
      (if found (lp (+ found 1) (+ n 1)) n))))

(def two-windows-test
  (test-suite "tuna/plugins/two-windows"
    (test-case "C-c w hands the window over to two windows and back, keeping points"
      (with-windows
       (lambda ()
         (type! "h" "e" "l" "l" "o" "C-a" "C-f" "C-f")
         (check (windows-state) => [[["*scratch*" 3]] 0])
         (type! "C-c" "w")
         ;; The new window starts at the selected window's point, as a split does.
         (check (windows-state) => [[["*scratch*" 3] ["*scratch*" 3]] 0])
         (check (on-baton (lambda () (plugin-active? window-commands-plugin))) => #t)
         (type! "C-x" "o" "C-e")
         (check (windows-state) => [[["*scratch*" 3] ["*scratch*" 6]] 1])
         (type! "C-c" "w")
         (check (windows-state) => [[["*scratch*" 6]] 0])
         (type! "C-c" "w")
         (check (windows-state) => [[["*scratch*" 6] ["*scratch*" 6]] 0]))))

    (test-case "C-x o moves between two views of one buffer with independent points"
      (with-windows
       (lambda ()
         (type! "a" "b" "c" "d" "C-c" "w")
         (type! "C-a" "C-f")
         (check (windows-state) => [[["*scratch*" 2] ["*scratch*" 5]] 0])
         (type! "C-x" "o" "!")
         (check (text) => "abcd!")
         (check (windows-state) => [[["*scratch*" 2] ["*scratch*" 6]] 1])
         ;; Typing in the first window moves the second window's point along.
         (type! "C-x" "o" "X")
         (check (text) => "aXbcd!")
         (check (windows-state) => [[["*scratch*" 3] ["*scratch*" 7]] 0])
         ;; Each window renders its own cursor; only the selected one is solid.
         (let (html (screen))
           (check (count-of "<section class=\"window\"" html) => 2)
           (check (count-of "data-selected=\"true\"" html) => 1)
           (check (count-of "class=\"cursor\"" html) => 1)
           (check (count-of "class=\"inactive-cursor\"" html) => 1)
           (check (count-of "line 1, column 2" html) => 1)
           (check (count-of "line 1, column 6" html) => 1))
         ;; Switching buffers in one window leaves the other alone.
         (type! "C-c" "b")
         (check (windows-state) => [[["*welcome*" 1] ["*scratch*" 7]] 0]))))

    (test-case "with one window, C-x o stays put"
      (with-windows
       (lambda ()
         (type! "a" "C-x" "o" "b")
         (check (text) => "ab")
         (check (windows-state) => [[["*scratch*" 3]] 0]))))

    (test-case "a prompt keeps the focus while C-x o selects another window"
      (with-windows
       (lambda ()
         (type! "a" "C-c" "w" "C-c" "r" "C-x" "o" "n")
         (check (windows-state) => [[["*scratch*" 2] ["*scratch*" 2]] 1])
         (type! "RET")
         (check (on-baton (lambda () (buffer-name (current-buffer)))) => "n")
         ;; The focus returns to the window selected meanwhile.
         (type! "b")
         (check (windows-state) => [[["n" 2] ["n" 3]] 1]))))

    (test-case "killing a buffer shows another in every window that showed it"
      (with-windows
       (lambda ()
         (type! "C-c" "w" "C-c" "b" "C-x" "o" "C-c" "b")
         (check (map car (car (windows-state))) => ["*welcome*" "*welcome*"])
         (on-baton (lambda () (deactivate-plugin! demo-plugin)))
         (check (map car (car (windows-state))) => ["*scratch*" "*scratch*"]))))

    (test-case "C-h s shows the window manager, its provider, and its dependents"
      (with-windows
       (lambda ()
         (type! "C-c" "w")
         (check (on-baton (lambda ()
                            (find (lambda (info) (eq? (service-info-name info) 'window-manager))
                                  (describe-services))))
                ? (lambda (info)
                    (and (eq? (service-info-provider info) 'two-windows-plugin)
                         (equal? (list-sort string<? (map symbol->string (service-info-dependents info)))
                                 ["html-renderer-plugin" "window-commands-plugin"])))))))))
