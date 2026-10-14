;;; C-c r (rename-buffer): a command that asks in the minibuffer, for tests
;;; of prompts.
;;; Optional services:
;;; - messages-service: notices via the kernel's guarded message dispatcher
;;;   (including stale-click reports); without it, nonempty notices go to stderr.
prelude: :gerbil/core

(import :tuna/services/commands
        :tuna/kernel
        :tuna/services/keys
        :tuna/services/buffers
        :tuna/services/minibuffer)
(export rename-command-plugin)

(defplugin (rename-command-plugin ctx)
  "C-c r renames the current buffer, asking the new name in the minibuffer."
  requires: [commands-service input-service buffers-service minibuffer-service]
  (define-command ctx (rename-buffer) "Give the current buffer a new name, asked in the minibuffer."
    (let (name (read-string "New name: " history: 'rename-buffer))
      (when (string-empty? name)
        (error "Empty string is invalid as a buffer name"))
      (rename-buffer! (current-buffer) name)
      (message (string-append "Renamed to " name))))
  (keymap-set ctx "C-c r" 'rename-buffer))
