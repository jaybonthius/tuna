#lang :tuna/config
;;; The demo configuration, for development only: `make demo` runs
;;; `tuna --config demo/init.ss`. It declares the starter's plugins
;;; (starter/init.ss) plus the demo: the demo plugin (demo.ss) and the
;;; command fixtures from tuna/test-support/ that it builds on. Tuna's
;;; executable does not link any of them; they load from source.

(import :tuna/plugins/keys
        :tuna/plugins/web
        :tuna/plugins/settings
        :tuna/plugins/echo-area
        :tuna/plugins/help-panel
        :tuna/plugins/session
        :tuna/plugins/rope
        :tuna/plugins/buffers
        :tuna/plugins/autosave
        :tuna/plugins/single-view
        :tuna/plugins/view-commands
        :tuna/plugins/html-renderer
        :tuna/plugins/basic-editing
        :tuna/plugins/minibuffer
        :tuna/plugins/reload-config
        "../tuna/test-support/endless-commands"
        "../tuna/test-support/services-help"
        "../tuna/test-support/rename-command"
        "../tuna/test-support/swap-commands"
        "../tuna/test-support/digit-highlighter"
        "../tuna/test-support/tree-buffer"
        "demo")

(use-plugin keys-plugin)
(use-plugin web-transport-plugin        ; the browser page; `tuna --port N` overrides port:
  port: 0)                              ; 0: any free port
(use-plugin settings-plugin)
(use-plugin echo-area-plugin)
(use-plugin help-panel-plugin)
;; Session slots restore in activation order: buffers (autosave) before
;; the views that show them (single-view).
(use-plugin session-plugin)
(use-plugin rope-text-store-plugin)
(use-plugin buffers-plugin)
(use-plugin autosave-plugin)
(use-plugin single-view-plugin)
(use-plugin view-commands-plugin)
(use-plugin html-renderer-plugin)
(use-plugin basic-editing-plugin)
(use-plugin minibuffer-plugin)
(use-plugin endless-commands-plugin)    ; C-c l and C-c L: loops to quit with C-g
(use-plugin services-help-plugin)       ; C-h s: describe-services
(use-plugin rename-command-plugin)      ; C-c r: rename the buffer in the minibuffer
(use-plugin swap-commands-plugin)       ; C-c v and C-c w: swap renderer and layout
(use-plugin digit-highlighter-plugin)   ; colors digits from a slow job
(use-plugin tree-buffer-plugin)         ; C-c b: the *welcome* buffer, built as a tree
(use-plugin demo-plugin)                ; C-c s text store, C-c p basic editing
(use-plugin reload-config-plugin        ; reload this file; show the last report
  config: (keymap-set "C-c R" 'reload-config)
          (keymap-set "C-c C-r" 'show-config-report))
