;;; C-c r (rename-buffer): a command that asks in the minibuffer, for tests
;;; of prompts.
prelude: :gerbil/core

(import :tuna/kernel
        :tuna/services/keys
        :tuna/services/buffers
        :tuna/services/minibuffer)
(export rename-command-plugin)

(defplugin (rename-command-plugin ctx)
  "C-c r renames the current buffer, asking the new name in the minibuffer."
  requires: [input-service buffers-service]
  (define-command ctx (rename-buffer) "Give the current buffer a new name, asked in the minibuffer."
    (let (name (read-string "New name: " history: 'rename-buffer))
      (when (string-empty? name)
        (error "Empty string is invalid as a buffer name"))
      (rename-buffer! (current-buffer) name)
      (message (string-append "Renamed to " name))))
  (keymap-set ctx "C-c r" 'rename-buffer))
