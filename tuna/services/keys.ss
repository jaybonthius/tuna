;;; Key bindings: the part of the input service that plugins bind keys
;;; through (ADR 8). Plugins that bind keys require `input-service`.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel)
(export (interface-out Keys)
        keymap-set
        key-binding)

(interface (Keys Input)
  ;; Bind KEYS, in `keymap-set` syntax ("C-c l"), to the command named
  ;; COMMAND, owned by CTX's plugin.
  (keymap-set! (ctx : context) (keys : :string) (command : :symbol)) => :void
  ;; The effective binding entry for KEYS, or #f.
  (key-binding (keys : :string)) => :t)

(def (current-keys) => Keys
  (let (input (service-provider input-service))
    (unless (and input (is-Keys? input))
      (error "The input service does not provide key bindings" input))
    (Keys input)))

(def (keymap-set (ctx : context) (keys : :string) (command : :symbol)) => :void
  (Keys-keymap-set! (current-keys) ctx keys command))

(def (key-binding (keys : :string)) => :t
  (Keys-key-binding (current-keys) keys))
