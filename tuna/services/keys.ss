;;; Key bindings: the part of the input service that plugins bind keys
;;; through (ADR 8). Plugins that bind keys require `input-service`.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel)
(export (interface-out Keys)
        keymap-set
        keymap-set!
        key-binding
        printing-char-key
        last-command
        last-command-event)

;; Binds every printing character that has no binding of its own.
(def printing-char-key "<printing-char>")

(interface (Keys Input)
  ;; Bind KEYS, in `keymap-set` syntax ("C-c l"), to the command named
  ;; COMMAND, owned by CTX's plugin and defined at SOURCE.
  (keymap-set! (ctx : context) (keys : :string) (command : :symbol) (source : :t)) => :void
  ;; The effective binding entry for KEYS, or #f.
  (key-binding (keys : :string)) => :t
  ;; The name of the command whose keys were completed before the running
  ;; command's, or #f (Emacs `last-command`).
  (last-command) => :t
  ;; The key event that completed the running command's keys, or #f (Emacs
  ;; `last-command-event`).
  (last-command-event) => :t)

(def (current-keys) => Keys
  (let (input (service-provider input-service))
    (unless (and input (is-Keys? input))
      (error "The input service does not provide key bindings" input))
    (Keys input)))

(def (keymap-set! (ctx : context) (keys : :string) (command : :symbol) (source :? :string)) => :void
  (Keys-keymap-set! (current-keys) ctx keys command source))

;; (keymap-set ctx "C-c l" 'command), or (keymap-set "C-c l" 'command) in a
;; plugin body, which binds through (current-context). Records the source.
(defsyntax (keymap-set stx)
  (syntax-case stx ()
    ((_ ctx keys command)
     (with-syntax ((source (stx-source-string stx)))
       #'(keymap-set! ctx keys command source)))
    ((_ keys command)
     (with-syntax ((source (stx-source-string stx)))
       #'(keymap-set! (current-context) keys command source)))))

(def (key-binding (keys : :string)) => :t
  (Keys-key-binding (current-keys) keys))

(def (last-command) => (Maybe :symbol)
  (Keys-last-command (current-keys)))

(def (last-command-event) => (Maybe key-event)
  (Keys-last-command-event (current-keys)))
