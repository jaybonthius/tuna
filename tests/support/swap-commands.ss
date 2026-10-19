;;; C-c v, C-c w, and C-c B: swap the renderer, the layout, and the buffers
;;; provider for the contract doubles (bare-renderer.ss, two-views.ss,
;;; toy-buffers.ss) while Tuna runs, for tests that swap a live slot through
;;; the editor.
prelude: :gerbil/core

(import :tuna/plugins/commands/contract
        :tuna/kernel
        :tuna/plugins/keys/contract
        (except-in :tuna/configuration activate-plugin!)
        "../../plugins/renderer/tests/support/bare-renderer"
        "../../plugins/layout/tests/support/two-views"
        "../../plugins/buffers/tests/support/toy-buffers")
(export swap-commands
        context-set-swap-providers!)

(def providers (new-entry-table))

(def (context-set-swap-providers! (ctx : context) (renderer : plugin) (layout : plugin) (buffers : plugin)) => :void
  (context-add-entry! ctx providers 'renderer renderer)
  (context-add-entry! ctx providers 'layout layout)
  (context-add-entry! ctx providers 'buffers buffers)
  (void))

(def (swap-double! (option : :symbol) (double : plugin)) => :void
  (let (default (:- (entry-value (or (entry-table-ref providers option)
                                    (error "No configured swap provider" option))) plugin))
    (if (plugin-active? double) (swap-plugins double default) (swap-plugins default double))))

(defplugin (swap-commands ctx)
  "C-c v swaps the renderer, C-c w the layout, C-c B the buffers provider, for their doubles."
  requires: [commands-service input-service configuration-service]
  (define-command ctx (swap-renderer) "Switch between the HTML and the bare HTML renderer."
    (swap-double! 'renderer bare-renderer)
    (message (if (plugin-active? bare-renderer)
               "Renderer: bare"
               "Renderer: HTML")))
  (define-command ctx (swap-layout) "Switch between one view and two side by side."
    (swap-double! 'layout two-views)
    (message (if (plugin-active? two-views)
               "Layout: two views"
               "Layout: default")))
  (define-command ctx (swap-buffers) "Switch between the default and the toy buffers provider."
    (swap-double! 'buffers toy-buffers)
    (message (if (plugin-active? toy-buffers)
               "Buffers: toy"
               "Buffers: default")))
  (keymap-set ctx "C-c v" 'swap-renderer)
  (keymap-set ctx "C-c w" 'swap-layout)
  (keymap-set ctx "C-c B" 'swap-buffers))
