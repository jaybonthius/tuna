#lang :tuna/config
;;; Tuna's starter configuration. Tuna never uses it on its own: run it with
;;; `tuna --config starter/init.ss`, or copy it to ~/.config/tuna/init.ss
;;; (`tuna init` does that) and make it yours.
;;;
;;; `use-plugin` declares a plugin; Tuna turns the declared plugins on in
;;; this order once the whole file has loaded, each as soon as the services
;;; it needs are provided. A plugin that fails is turned off and reported;
;;; the others still come up. Code attached with `config:` runs while its
;;; plugin is on. Any other code in this file runs last, as your own plugin.

(import :tuna/plugins/keys
        :tuna/plugins/web
        :tuna/plugins/settings
        :tuna/plugins/echo-area
        :tuna/plugins/help-panel
        :tuna/plugins/session
        :tuna/plugins/rope
        :tuna/plugins/buffers
        :tuna/plugins/autosave
        :tuna/plugins/single-window
        :tuna/plugins/window-commands
        :tuna/plugins/html-renderer
        :tuna/plugins/basic-editing
        :tuna/plugins/minibuffer
        :tuna/plugins/demo)

(use-plugin keys-plugin)
(use-plugin web-transport-plugin)
(use-plugin settings-plugin)
(use-plugin echo-area-plugin)
(use-plugin help-panel-plugin)
;; Session slots restore in activation order: buffers (autosave) before the
;; windows that show them (single-window).
(use-plugin session-plugin)
(use-plugin rope-text-store-plugin)
(use-plugin buffers-plugin)
(use-plugin autosave-plugin)
(use-plugin single-window-plugin)
(use-plugin window-commands-plugin)
(use-plugin html-renderer-plugin)
(use-plugin basic-editing-plugin)
(use-plugin minibuffer-plugin)
(use-plugin demo-plugin)                ; the skeleton demo: digit highlighting, C-c commands
