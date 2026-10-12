;;; Key bindings: the key events a transport submits as input items, the
;;; part of the input service that plugins bind keys through, and the
;;; input-target stack prompts push (ADR 3, ADR 8). Plugins that bind keys
;;; require `input-service`.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel)
(export (struct-out key-event)
        (interface-out Keys)
        keymap-set
        keymap-set!
        keymap-set-in
        keymap-set-in!
        new-keymap
        (struct-out input-target)
        push-input-target!
        remove-input-target!
        key-binding
        printing-char-key
        last-command
        last-command-event)

;; One keydown from a client, with the client's id and sequence number
;; (ADR 7, ADR 10). The web transport submits it as an input item; the
;; input service resolves it.
(defstruct key-event ((client     : :string)
                      (sequence   : :fixnum)
                      (key        : :string)
                      (code       : :string)
                      (location   : :fixnum)
                      (repeat?    : :boolean)
                      (composing? : :boolean)
                      (alt?       : :boolean)
                      (ctrl?      : :boolean)
                      (meta?      : :boolean)
                      (shift?     : :boolean))
  final: #t)

;; Binds every printing character that has no binding of its own.
(def printing-char-key "<printing-char>")

;; What a waiting prompt pushes: while it is the innermost target, keys
;; resolve in KEYMAP before the global keymap.
(defstruct input-target ((name   : :symbol)
                         (keymap : entry-table))
  final: #t)

;; A keymap other than the global one: key sequence -> command name entries.
(def (new-keymap) => entry-table
  (new-entry-table))

(interface (Keys Input)
  ;; Bind KEYS, in `keymap-set` syntax ("C-c l"), to the command named
  ;; COMMAND, owned by CTX's plugin and defined at SOURCE.
  (keymap-set! (ctx : context) (keys : :string) (command : :symbol) (source : :t)) => :void
  ;; The same, in KEYMAP instead of the global keymap.
  (keymap-set-in! (ctx : context) (keymap : entry-table) (keys : :string) (command : :symbol)
                  (source : :t))
  => :void
  ;; Make TARGET the innermost input target.
  (push-input-target! (target : input-target)) => :void
  ;; Remove TARGET, wherever it is in the stack.
  (remove-input-target! (target : input-target)) => :void
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

(def (keymap-set-in! (ctx : context) (keymap : entry-table) (keys : :string) (command : :symbol)
                     (source :? :string))
  => :void
  (Keys-keymap-set-in! (current-keys) ctx keymap keys command source))

;; (keymap-set-in ctx keymap "RET" 'command), or without CTX in a plugin
;; body. Records the source.
(defsyntax (keymap-set-in stx)
  (syntax-case stx ()
    ((_ ctx keymap keys command)
     (with-syntax ((source (stx-source-string stx)))
       #'(keymap-set-in! ctx keymap keys command source)))
    ((_ keymap keys command)
     (with-syntax ((source (stx-source-string stx)))
       #'(keymap-set-in! (current-context) keymap keys command source)))))

(def (push-input-target! (target : input-target)) => :void
  (Keys-push-input-target! (current-keys) target))

(def (remove-input-target! (target : input-target)) => :void
  (Keys-remove-input-target! (current-keys) target))

(def (key-binding (keys : :string)) => :t
  (Keys-key-binding (current-keys) keys))

(def (last-command) => (Maybe :symbol)
  (Keys-last-command (current-keys)))

(def (last-command-event) => (Maybe key-event)
  (Keys-last-command-event (current-keys)))
