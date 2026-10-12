;;; The plain-text renderer, and swapping renderers live (C-c v), driven
;;; through the real editor loop.
(import :std/test
        :tuna/kernel
        :tuna/services/renderer
        :tuna/services/buffers
        :tuna/plugins/keys
        :tuna/plugins/echo-area
        :tuna/plugins/help-panel
        :tuna/plugins/rope
        :tuna/plugins/settings
        :tuna/plugins/buffers
        :tuna/plugins/single-window
        :tuna/plugins/window-commands
        :tuna/plugins/html-renderer
        :tuna/plugins/plain-text-renderer
        :tuna/plugins/basic-editing
        :tuna/plugins/minibuffer
        :tuna/plugins/demo)
(export plain-text-renderer-test)

(include "test-keys.ss")

(def (with-renderers thunk)
  (call-with-editor [keys-plugin echo-area-plugin help-panel-plugin rope-text-store-plugin
                     settings-plugin buffers-plugin single-window-plugin window-commands-plugin
                     html-renderer-plugin basic-editing-plugin minibuffer-plugin demo-plugin]
                    thunk))

(def (on-baton thunk) (call-on-editor-loop thunk))

(def (screen)
  (on-baton (lambda () (Renderer-render-screen (Renderer (service-provider renderer-service))))))

(def (contains? html needle)
  (and (string-contains html needle) #t))

(def plain-text-renderer-test
  (test-suite "tuna/plugins/plain-text-renderer"
    (test-case "C-c v swaps to plain text and back without losing text or point"
      (with-renderers
       (lambda ()
         (type! "a" "<" "b" "RET" "c" "C-p")
         (check (contains? (screen) "class=\"text\"") => #t)
         (type! "C-c" "v")
         (check (on-baton (lambda () (plugin-active? plain-text-renderer-plugin))) => #t)
         (let (html (screen))
           (check (contains? html "data-renderer=\"plain-text\"") => #t)
           (check (contains? html "class=\"text\"") => #f)
           (check (contains? html "<pre class=\"plain-text\" aria-label=\"*scratch*\">a<span class=\"cursor\">&lt;</span>b\nc\n── Tuna · *scratch* · line 1, column 1")
                  => #t)
           (check (contains? html "Renderer: plain text") => #t))
         ;; Editing goes on under the plain-text renderer.
         (type! "C-e" "!")
         (check (contains? (screen) "a&lt;b!<span class=\"cursor\"> </span>\nc") => #t)
         (type! "C-c" "v")
         (let (html (screen))
           (check (contains? html "data-renderer") => #f)
           (check (contains? html "a&lt;b!<span class=\"cursor\"> </span>") => #t)
           (check (contains? html "line 1, column 4") => #t)
           (check (contains? html "Renderer: HTML") => #t)))))

    (test-case "kinds render through their plain-text procedures, or their children"
      (with-renderers
       (lambda ()
         (type! "C-c" "v" "C-c" "b")
         (check (contains? (screen) "Welcome to Tuna\n===============\n<span class=\"cursor\">T</span>his buffer")
                => #t))))

    (test-case "two windows render side by side, each with its cursor"
      (with-renderers
       (lambda ()
         (type! "x" "y" "C-c" "v" "C-c" "w" "C-b")
         (let (html (screen))
           (check (contains? html "x<span class=\"cursor\">y</span>") => #t)
           (check (contains? html "xy<span class=\"inactive-cursor\"> </span>") => #t)
           (check (contains? html "data-selected=\"true\"") => #t)))))

    (test-case "a prompt shows its question and answer in the footer"
      (with-renderers
       (lambda ()
         (type! "C-c" "v" "C-c" "r" "o" "k")
         (check (contains? (screen) "<pre class=\"plain-text\" role=\"status\">New name: ok<span class=\"cursor\"> </span>\n</pre>")
                => #t)
         (type! "C-g"))))))
