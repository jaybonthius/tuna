;;; C-c r (rename-buffer): a command that asks in the minibuffer, for tests
;;; of prompts.
prelude: :gerbil/core

(import :tuna/plugins/commands/contract
        :tuna/kernel
        :tuna/plugins/keys/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/minibuffer/contract)
(export rename-command)

(defplugin (rename-command ctx)
  "C-c r renames the current buffer, asking the new name in the minibuffer."
  requires: [commands-service input-service buffers-service minibuffer-service]
  (define-command ctx (rename-buffer) "Give the current buffer a new name, asked in the minibuffer."
    (let (name (read-string "New name: " history: 'rename-buffer))
      (when (string-empty? name)
        (error "Empty string is invalid as a buffer name"))
      (rename-buffer! (current-buffer) name)
      (message (string-append "Renamed to " name))))
  (keymap-set ctx "C-c r" 'rename-buffer))
