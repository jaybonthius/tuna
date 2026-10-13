;;; The sidebar demo, for development only (demo/init.ss): C-c d shows a
;;; *sidebar* tree buffer pinned to the left with display-buffer, as the
;;; buffers, views and layout brief's walkthrough does; its view is
;;; dedicated, so pressing C-c d again kills the buffer and the view
;;; closes. Turning the plugin off kills it too.
prelude: :gerbil/core

(import :tuna/kernel
        :tuna/services/keys
        :tuna/services/buffers
        :tuna/services/layout)
(export sidebar-demo-plugin)

(def sidebar-name "*sidebar*")

;; (column (heading "Sidebar") (text "…")); the kinds come from the
;; tree-buffer fixture, and show as plain text without it.
(def (sidebar-buffer) => buffer
  (new-buffer sidebar-name
              (new-node 'column
                        children: [(new-node 'heading attributes: [['content . "Sidebar"]])
                                   (new-text-node
                                    (new-text "A buffer pinned to the left, in a dedicated view.\nC-c d again kills it, and its view closes.\n"))])))

(def (kill-sidebar!) => :void
  (let (b (get-buffer sidebar-name))
    (when b
      (kill-buffer b))))

(defplugin (sidebar-demo-plugin ctx)
  "C-c d shows a *sidebar* buffer pinned to the left; again, kills it and its view closes."
  requires: [input-service buffers-service layout-service]
  (define-command ctx (toggle-sidebar) "Show *sidebar* at the left side, or kill it."
    (if (get-buffer sidebar-name)
      (kill-sidebar!)
      (let (b (sidebar-buffer))
        (add-buffer! b)
        (display-buffer b side: 'left size: 1/4))))
  (keymap-set ctx "C-c d" 'toggle-sidebar)
  (context-defer! ctx kill-sidebar!))
