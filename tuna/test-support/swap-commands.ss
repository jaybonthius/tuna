;;; C-c v and C-c w: swap the renderer and the layout for the contract
;;; doubles (plain-text-renderer.ss, two-views.ss) while Tuna
;;; runs, for tests that swap a live slot through the editor.
prelude: :gerbil/core

(import :tuna/kernel
        :tuna/services/keys
        "plain-text-renderer"
        "two-views")
(export swap-commands-plugin)

(def (toggle-plugin! (p : plugin)) => :void
  (if (plugin-active? p)
    (deactivate-plugin! p)
    (activate-plugin! p)))

(defplugin (swap-commands-plugin ctx)
  "C-c v swaps the renderer, C-c w the layout, for their doubles."
  requires: [input-service]
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
  (keymap-set ctx "C-c v" 'swap-renderer)
  (keymap-set ctx "C-c w" 'swap-layout))
