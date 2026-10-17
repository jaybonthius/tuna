#lang :tuna/prelude
(import :tuna/kernel
        :tuna/plugins/commands/contract
        :tuna/plugins/buffers/contract)
(export hungry-delete)

(def (hungry-backspace (original : :procedure)) => :t
  (if (current-text-node)
    (let* ((t (current-text))
           (end (point))
           (minimum (point-min))
           (start (let scan ((position end))
                    (if (and (fx> position minimum)
                             (string=? (text-substring t (fx1- position) position) " "))
                      (scan (fx1- position))
                      position))))
      (if (fx< start end)
        (delete-region start end)
        (original)))
    (original)))

(defplugin (hungry-delete ctx)
  "Backspace deletes the consecutive literal spaces before point in one edit."
  requires: [commands-service buffers-service]
  (advise! ctx (command-target 'delete-backward-char) 'hungry around: hungry-backspace))
