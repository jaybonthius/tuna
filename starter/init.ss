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

(import :tuna/plugins/commands/contract
        :tuna/plugins/keys/contract
        :tuna/plugins/commands/plugin
        :tuna/plugins/keys/plugin
        :tuna/plugins/web/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/echo-area/plugin
        :tuna/plugins/help/plugin
        :tuna/plugins/session/plugin
        :tuna/plugins/text-store/plugin
        :tuna/plugins/buffers/plugin
        :tuna/plugins/autosave/plugin
        :tuna/plugins/layout/plugin
        :tuna/plugins/view-commands/plugin
        :tuna/plugins/renderer/plugin
        :tuna/plugins/buttons/plugin
        :tuna/plugins/basic-editing/plugin
        :tuna/plugins/minibuffer/plugin
        :tuna/plugins/completion/plugin
        :tuna/plugins/completion-vertical/plugin
        :tuna/plugins/extended-command/plugin
        :tuna/plugins/orderless/plugin
        :tuna/plugins/command-annotations/plugin
        :tuna/plugins/settings/contract
        (only-in :tuna/kernel current-context)
        :tuna/plugins/reload-config/plugin)

(use-plugin commands)
(use-plugin keys)
(use-plugin web-transport        ; the browser page; `tuna --port N` overrides port:
  port: 0)                              ; 0: any free port
(use-plugin settings)
;; Session slots restore in activation order: buffers (autosave) before
;; the views that show them (layout).
(use-plugin session)
(use-plugin rope-text-store)
(use-plugin buffers)
(use-plugin autosave)
(use-plugin layout)
(use-plugin view-commands)
(use-plugin html-renderer)
(use-plugin buttons)             ; buttons in buffers: a click runs their action
(use-plugin basic-editing)
(use-plugin minibuffer)
(use-plugin completion-engine
  config: (context-set-setting! (current-context) completion-styles '(orderless substring)))
(use-plugin completion-vertical)
(use-plugin extended-command)
(use-plugin orderless)
(use-plugin annotations)
(use-plugin echo-area)           ; in the bar, under the minibuffer
(use-plugin help-buffer)         ; *Help*; C-h q closes it
(use-plugin reload-config        ; reload this file; show the last report
  config: (keymap-set "C-c R" 'reload-config)
          (keymap-set "C-c C-r" 'show-config-report))
