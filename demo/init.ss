#lang :tuna/config
;;; The demo configuration, for development only: run
;;; `tuna --config demo/init.ss`. It declares the starter's plugins
;;; (starter/init.ss) plus the demo: the demo plugins (demo.ss,
;;; hungry-delete.ss, sidebar.ss, long-buffer.ss, rows.ss, mixed.ss) and the command fixtures from tuna/test-support/ that
;;; it builds on. Tuna's
;;; executable does not link any of them; they load from source.

(import :tuna/plugins/commands/contract
        :tuna/plugins/stylesheets/plugin
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
        :tuna/plugins/terminal/plugin
        :tuna/plugins/program-status/plugin
        :tuna/plugins/notifications/plugin
        :tuna/plugins/layout/plugin
        :tuna/plugins/view-commands/plugin
        :tuna/plugins/scrolling/plugin
        :tuna/plugins/renderer/plugin
        :tuna/plugins/buttons/plugin
        :tuna/plugins/editing/plugin
        :tuna/plugins/minibuffer/plugin
        :tuna/plugins/completion/plugin
        :tuna/plugins/completion-list/plugin
        :tuna/plugins/files/plugin
        :tuna/plugins/settings/contract
        (only-in :tuna/kernel current-context)
        :tuna/plugins/configuration/plugin
        :tuna/plugins/proced/plugin
        :tuna/plugins/profiler/plugin
        :tuna/plugins/microphone/plugin
        :tuna/plugins/voice/plugin
        "../tests/support/endless-commands"
        "../tests/support/services-help"
        "../tests/support/rename-command"
        "../tests/support/swap-commands"
        "../tests/support/digit-highlighter"
        "../tests/support/tree-buffer"
        "demo"
        "hungry-delete"
        "sidebar"
        "long-buffer"
        "rows"
        "mixed")

(use-plugin stylesheets        ; colours, sizes and fonts other stylesheets use;
  variant: stellar-default)      ; first, so later stylesheets can redefine them
(use-plugin commands)
(use-plugin keys)
(use-plugin web-transport        ; the browser page; `tuna --port N` overrides port:
  port: 0                               ; 0: any free port
  hosts: ())                            ; other names for this port, e.g. ("me.tailnet.ts.net") behind `tailscale serve`
(use-plugin settings)
;; Session slots restore in activation order: buffers (autosave) before
;; the views that show them (layout).
(use-plugin session)
(use-plugin rope-text-store)
(use-plugin buffers)
(use-plugin autosave)
(use-plugin terminals)           ; M-x terminal: a shell whose helper outlives Tuna; before
                                 ; layout, so its buffers are back when the views restore
(use-plugin program-status)      ; a terminal program's status (OSC 7501) in its status line
(use-plugin notifications)       ; what terminal programs ask to be told, in the echo area
(use-plugin layout)
(use-plugin view-commands)
(use-plugin scrolling)           ; views scroll natively; the server draws what is near
(use-plugin html-renderer)
(use-plugin buttons)             ; buttons in buffers: a click runs their action
(use-plugin editing)             ; typing and moving; C-SPC, C-x C-x and shift-select (the
                                 ; delete-selection setting); C-w, M-w, C-y, M-y; clicking and dragging
(use-plugin hungry-delete)       ; Backspace deletes the spaces before point in one edit (hungry-delete.ss)
(use-plugin minibuffer)
(use-plugin completion    ; M-x, matching styles, command annotations
  config: (context-set-setting! (current-context) completion-styles '(any-order substring)))
(use-plugin completion-list)     ; the candidates in rows under the minibuffer
(use-plugin files)               ; C-x C-f opens a file, C-x C-s saves it, C-x s saves all, C-x C-w saves as
(use-plugin echo-area)           ; in the bar, under the minibuffer
(use-plugin help)         ; *Help*; C-h q closes it; M-x describe-advice,
                                 ; describe-stylesheets, reload-stylesheets
(use-plugin endless-commands)    ; C-c l and C-c L: loops to quit with C-g
(use-plugin services-help)       ; C-h s: describe-services
(use-plugin rename-command)      ; C-c r: rename the buffer in the minibuffer
;; C-c V, C-c w, C-c B: swap renderer, layout, buffers.
(use-plugin swap-commands
  config:
  (context-set-swap-providers! (current-context)
                               html-renderer layout buffers))
(use-plugin digit-highlighter)   ; colors digits from a slow job
(use-plugin tree-buffer)         ; C-c b: the *welcome* buffer, built as a tree
(use-plugin demo)                ; C-c s text store, C-c p editing, C-c h hungry delete,
                                 ; C-c T the terminal theme (tests/support/theme-terminal.ss),
                                 ; C-c D the delete-selection setting,
                                 ; C-c W a wait off the editor thread that C-g quits
(use-plugin long-buffer-demo)    ; C-c g: *long*, 50,000 generated lines, for scrolling
(use-plugin rows-demo)           ; C-c G: *rows*, 10,000 row nodes, scrolled the same way
(use-plugin mixed-demo)          ; C-c M: *mixed*, headings, text, code, cards and pictures
(use-plugin sidebar-demo)        ; C-c d: a sidebar of buffer buttons pinned to the left, or killed
(use-plugin proced               ; C-c P: *Processes*, read from /proc every second
  config: (keymap-set "C-c P" 'proced))
(use-plugin profiler)            ; each input item's span tree, key to paint, as a JSON line in
                                 ; $XDG_STATE_HOME/tuna/profile/spans-*.jsonl
(use-plugin profiler-commands)   ; M-x profiler-mode turns it off and on; M-x profiler-start and
                                 ; profiler-stop sample call stacks into samples-*.folded
(use-plugin microphone)          ; a tab's microphone, for voice
;; C-c v: dictate at point; C-c v again or C-g stops. C-c c: say a
;; command's name to run it; listening ends by itself. Both need the
;; speech worker (make voice-worker); dictation's model is the voice
;; plugin's model: option, the commands' the voice-command-model setting.
(use-plugin voice
  config: (keymap-set "C-c v" 'voice-dictate)
          (keymap-set "C-c c" 'voice-command))
(use-plugin configuration        ; reload this file; show the last report
  config: (keymap-set "C-c R" 'reload-config)
          (keymap-set "C-c C-r" 'show-config-report))
