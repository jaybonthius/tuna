#lang :tuna/config
;;; Tuna's starter configuration. Tuna never uses it on its own: run it with
;;; `tuna --config starter/init.ss`, or copy it to ~/.config/tuna/init.ss
;;; (`tuna init` does that) and make it yours.
;;;
;;; `use-plugin` declares a plugin; Tuna turns the declared plugins on in
;;; this order once the whole file has loaded, each as soon as the services
;;; it needs are provided. A plugin that fails is turned off and reported;
;;; the others still come up. Code attached with `config:` runs while its
;;; plugin is on. Any other code in this file runs last, as your own plugin;
;;; its definitions are local to it, so put helpers that `config:` blocks
;;; also need in a module next to this file and import it by its path, as
;;; in (import "my-helpers"). Each plugin, and your own code, has 5 s to
;;; turn on; one that takes longer is stopped and turned off.
;;;
;;; `(use-plugin p key: value ...)` gives a plugin options, written as data:
;;; port: 8080, leader: "SPC". Tuna checks every option against what the
;;; plugin accepts when it loads this file; with any problem it changes
;;; nothing and reports each one with its line. `tuna check` does the same
;;; from a terminal.
;;;
;;; After editing this file, reload it without restarting: C-c R (the
;;; reload-config command) inside Tuna, or `tuna reload` in a terminal.
;;; C-c C-r (show-config-report) shows the last start-up or reload report.
;;; Only what changed is turned off and on; if a changed part fails, the
;;; version that was running is turned back on. That holds for this file,
;;; its config: blocks, your own code, and Tuna's plugins. A module of
;;; your own that this file imports by path is different: when its file
;;; changed, it is loaded again in place, so its new definitions replace
;;; the running ones as soon as it loads, even if the reload then fails.
;;;
;;; Loading this file runs only its imports and declarations. The code of
;;; the modules you import, and macro code, also run at load: they must not
;;; change the editor, since nothing could undo it.

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
        :tuna/plugins/reload-config)

(use-plugin keys-plugin)
(use-plugin web-transport-plugin        ; the browser page; `tuna --port N` overrides port:
  port: 0)                              ; 0: any free port
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
(use-plugin reload-config-plugin        ; reload this file; show the last report
  config: (keymap-set "C-c R" 'reload-config)
          (keymap-set "C-c C-r" 'show-config-report))
