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
        :tuna/plugins/stylesheets/contract
        (only-in :tuna/kernel current-context)
        :tuna/plugins/configuration/plugin)

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
(use-plugin layout)
(use-plugin view-commands)
;; To select the view on a side with Shift and an arrow (Emacs's windmove;
;; the S-arrows then no longer select text), give the line above
;; config: (keymap-set "S-<left>" 'select-view-left), and so on.
(use-plugin scrolling)           ; views scroll natively; the server draws what is near
(use-plugin html-renderer)
(use-plugin buttons)             ; buttons in buffers: a click runs their action
(use-plugin editing)             ; typing and moving; C-SPC, C-x C-x and shift-select (the
                                 ; delete-selection setting); C-w, M-w, C-y, M-y; clicking and dragging
(use-plugin minibuffer)
(use-plugin completion    ; M-x, matching styles, command annotations
  config: (context-set-setting! (current-context) completion-styles '(any-order substring)))
(use-plugin completion-list)     ; the candidates in rows under the minibuffer
(use-plugin files)               ; C-x C-f opens a file, C-x C-s saves it, C-x s saves all, C-x C-w saves as
(use-plugin echo-area)           ; in the bar, under the minibuffer
(use-plugin help)         ; *Help*; C-h q closes it; M-x describe-advice,
                                 ; describe-stylesheets, reload-stylesheets
(use-plugin configuration        ; reload this file; show the last report
  config: (keymap-set "C-c R" 'reload-config)
          (keymap-set "C-c C-r" 'show-config-report))

;; Restyle Tuna with CSS. Each plugin's look is in its own stylesheets,
;; usually (PLUGIN tokens), its colours and sizes as CSS custom properties,
;; and (PLUGIN rules); M-x describe-stylesheets lists them. Add your own
;; file, which comes after every plugin's, to redefine a few properties, or
;; replace a plugin's file to rewrite it. Paths are relative to this file;
;; M-x reload-stylesheets reads them again after you edit them.
;; (add-stylesheet 'mine "my.css")
;; (replace-stylesheet 'completion-list 'tokens "my-completion-tokens.css")
