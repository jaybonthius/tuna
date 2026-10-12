#lang :tuna/prelude
;;; Window commands that work under any window manager, because they use
;;; only the window contract (ADR 11).
(import :tuna/kernel
        :tuna/services/keys
        :tuna/services/windows)
(export window-commands-plugin)

(defplugin window-commands-plugin
  "Window commands for any window manager: C-x o selects the next window."
  requires: [input-service window-manager-service]
  (defcommand (other-window) "Select the next window, cyclically."
    (select-window (next-window (selected-window))))
  (keymap-set "C-x o" 'other-window))
