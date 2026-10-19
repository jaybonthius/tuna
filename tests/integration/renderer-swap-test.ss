;;; Integration: the renderer slot swapped live (C-c v) to the bare HTML
;;; contract double (plugins/renderer/tests/support/bare-renderer.ss) and back
;;; while editing, with tree buffers, two views, and a prompt, driven by
;;; keys through the real editor loop.
(import (only-in :tuna/boot session-owner restart-plugin!)
        :std/test
        :tuna/kernel
        :tuna/plugins/renderer/contract
        :tuna/plugins/buffers/contract
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
        "../../tuna/tests/support/kernel"
        "../../plugins/keys/tests/support/keys"
        "../../plugins/session/tests/support/session"
        "../../plugins/renderer/tests/support/bare-renderer"
        "../../plugins/layout/tests/support/two-views"
        "../support/swap-commands"
        "../support/rename-command"
        "../support/tree-buffer")
(export renderer-swap-test)

(defplugin (swap-configuration ctx)
  "Selects the default providers for swap commands in this test configuration."
  (context-set-swap-providers! ctx html-renderer layout buffers))


(def renderer-plugins
  [session-owner commands keys echo-area help-buffer rope-text-store
   settings no-session buffers layout
   view-commands
   html-renderer basic-editing minibuffer
   swap-configuration swap-commands rename-command tree-buffer])

(def (on-baton thunk) (call-on-editor-loop thunk))

(def (screen)
  (on-baton (lambda () (Renderer-render-screen (Renderer (service-provider renderer-service))))))

(def (contains? html needle)
  (and (string-contains html needle) #t))

(def renderer-swap-test
  (test-suite "integration: swapping the renderer live"
    (test-case "C-c v swaps to the bare renderer and back without losing text or point"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "a" "<" "b" "RET" "c" "C-p")
         (check (contains? (screen) "class=\"line\"") => #t)
         (type! "C-c" "v")
         (check (on-baton (lambda () (plugin-active? bare-renderer))) => #t)
         (let (html (screen))
           (check (contains? html "data-renderer=\"bare\"") => #t)
           (check (contains? html "class=\"line\"") => #f)
           (check (contains? html "<pre class=\"text\">a<span class=\"cursor\">&lt;</span>b\nc</pre>")
                  => #t)
           (check (contains? html "<p class=\"status-line\">Tuna · *scratch* · line 1, column 1") => #t)
           (check (contains? html "Renderer: bare") => #t))
         ;; Editing goes on under the bare renderer.
         (type! "C-e" "!")
         (check (contains? (screen) "a&lt;b!<span class=\"cursor\"> </span>\nc") => #t)
         (type! "C-c" "v")
         (let (html (screen))
           (check (contains? html "data-renderer") => #f)
           (check (contains? html "a&lt;b!<span class=\"cursor\"> </span>") => #t)
           (check (contains? html "line 1, column 4") => #t)
           (check (contains? html "Renderer: HTML") => #t)))))

    (test-case "kinds render through their node renderers, or their children"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "C-c" "v" "C-c" "b")
         (check (contains? (screen) "<div class=\"column\"><h1 class=\"heading\">Welcome to Tuna</h1><pre class=\"text\"><span class=\"cursor\">T</span>his buffer")
                => #t))))

    (test-case "two views render side by side, each with its cursor"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "x" "y" "C-c" "v" "C-c" "w" "C-b")
         (let (html (screen))
           (check (contains? html "x<span class=\"cursor\">y</span>") => #t)
           (check (contains? html "xy<span class=\"inactive-cursor\"> </span>") => #t)
           (check (contains? html "data-selected=\"true\"") => #t)))))

    (test-case "a prompt shows its question and answer in its view, which has no status line"
      (call-with-fresh-kernel renderer-plugins
       (lambda ()
         (start-editor-loop!)
         (type! "C-c" "v" "C-c" "r" "o" "k")
         (check (contains? (screen) "<span class=\"prompt\">New name: </span><pre class=\"text\">ok<span class=\"cursor\"> </span></pre></div></article></section>") => #t)
         (type! "C-g")
         (check (contains? (screen) "New name: ") => #f)
         (check (contains? (screen) "Quit</p></article></section>") => #t))))))
