#lang :tuna/config
;;; The demo configuration, for development only: run
;;; `tuna --config demo/init.ss`. It declares the starter's plugins
;;; (starter/init.ss) plus the demo: the demo plugins (demo.ss, sidebar.ss) and the
;;; command fixtures from tuna/test-support/ that it builds on. Tuna's
;;; executable does not link any of them; they load from source.

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
        :tuna/plugins/advice-help/plugin
        :tuna/plugins/orderless/plugin
        :tuna/plugins/command-annotations/plugin
        :tuna/plugins/settings/contract
        (only-in :tuna/kernel current-context)
        :tuna/plugins/reload-config/plugin
        "../tests/support/endless-commands"
        "../tests/support/services-help"
        "../tests/support/rename-command"
        "../tests/support/swap-commands"
        "../tests/support/digit-highlighter"
        "../tests/support/tree-buffer"
        "demo"
        "sidebar")

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
(use-plugin advice-help)         ; M-x describe-advice: current function advice
(use-plugin endless-commands)    ; C-c l and C-c L: loops to quit with C-g
(use-plugin services-help)       ; C-h s: describe-services
(use-plugin rename-command)      ; C-c r: rename the buffer in the minibuffer
;; C-c v, C-c w, C-c B: swap renderer, layout, buffers.
(use-plugin swap-commands
  config:
  (context-set-swap-providers! (current-context)
                               html-renderer layout buffers))
(use-plugin digit-highlighter)   ; colors digits from a slow job
(use-plugin tree-buffer)         ; C-c b: the *welcome* buffer, built as a tree
(use-plugin demo)                ; C-c s text store, C-c p basic editing
(use-plugin sidebar-demo)        ; C-c d: a sidebar of buffer buttons pinned to the left, or killed
(use-plugin reload-config        ; reload this file; show the last report
  config: (keymap-set "C-c R" 'reload-config)
          (keymap-set "C-c C-r" 'show-config-report))
