#lang :tuna/prelude
;;; View commands that work under any layout, because they use only the
;;; layout contract (ADR 13).
(import :tuna/kernel
        :tuna/services/keys
        :tuna/services/buffers
        :tuna/services/layout)
(export view-commands-plugin)

(defplugin view-commands-plugin
  "View commands for any layout: C-x o selects the next view."
  requires: [input-service buffers-service layout-service]
  (defcommand (other-view) "Select the next view, cyclically."
    (select-view (next-view (selected-view))))
  (keymap-set "C-x o" 'other-view))
