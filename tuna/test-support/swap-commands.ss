;;; C-c v, C-c w, and C-c B: swap the renderer, the layout, and the buffers
;;; provider for the contract doubles (plain-text-renderer.ss, two-views.ss,
;;; toy-buffers.ss) while Tuna runs, for tests that swap a live slot through
;;; the editor.
;;; Optional services:
;;; - messages-service: notices via the kernel's guarded message dispatcher
;;;   (including stale-click reports); without it, nonempty notices go to stderr.
prelude: :gerbil/core

(import :tuna/services/commands
        :tuna/kernel
        :tuna/services/keys
        "plain-text-renderer"
        "two-views"
        "toy-buffers")
(export swap-commands-plugin)

(def (toggle-plugin! (p : plugin)) => :void
  (if (plugin-active? p)
    (deactivate-plugin! p)
    (activate-plugin! p)))

(defplugin (swap-commands-plugin ctx)
  "C-c v swaps the renderer, C-c w the layout, C-c B the buffers provider, for their doubles."
  requires: [commands-service input-service]
  (define-command ctx (swap-renderer) "Switch between the HTML and the plain-text renderer."
    (toggle-plugin! plain-text-renderer-plugin)
    (message (if (plugin-active? plain-text-renderer-plugin)
               "Renderer: plain text"
               "Renderer: HTML")))
  (define-command ctx (swap-layout) "Switch between one view and two side by side."
    (toggle-plugin! two-views-plugin)
    (message (if (plugin-active? two-views-plugin)
               "Layout: two views"
               "Layout: one view")))
  (define-command ctx (swap-buffers) "Switch between the default and the toy buffers provider."
    (toggle-plugin! toy-buffers-plugin)
    (message (if (plugin-active? toy-buffers-plugin)
               "Buffers: toy"
               "Buffers: default")))
  (keymap-set ctx "C-c v" 'swap-renderer)
  (keymap-set ctx "C-c w" 'swap-layout)
  (keymap-set ctx "C-c B" 'swap-buffers))
