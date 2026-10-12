;;; Commands and key bindings: the key events a transport submits as input
;;; items, the part of the input service that plugins define commands and
;;; bind keys through, and the input-target stack prompts push (ADR 3,
;;; ADR 8). Plugins that define commands or bind keys require
;;; `input-service`.
prelude: :gerbil/core

(import :std/interface
        :tuna/kernel)
(export (struct-out key-event)
        (interface-out Keys)
        (struct-out command)
        context-define-command!
        define-command
        defcommand
        command-entry
        command-ref
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

;; A named action that runs as a task, usually bound to keys.
(defstruct command ((name      : :symbol)
                    (procedure : :procedure)          ; thunk, run as a task
                    (doc       : :string))
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
  ;; Define the command NAME, which runs PROCEDURE, owned by CTX's plugin
  ;; and defined at SOURCE.
  (define-command! (ctx : context) (name : :symbol) (procedure : :procedure) (doc : :string)
                   (source : :t))
  => :void
  ;; The effective entry for the command named NAME, or #f.
  (command-entry (name : :symbol)) => :t
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

(def (context-define-command! (ctx       : context)
                              (name      : :symbol)
                              (procedure : :procedure)
                              doc:    (doc    : :string := "")
                              source: (source :? :string := #f))
  => :void
  (Keys-define-command! (current-keys) ctx name procedure doc source))

;; (define-command ctx (name) "doc" body ...)
(defsyntax (define-command stx)
  (syntax-case stx ()
    ((_ ctx (name) doc body ...)
     (and (identifier? #'name) (stx-string? #'doc))
     (with-syntax ((source (stx-source-string stx)))
       #'(context-define-command! ctx 'name (lambda () body ...)
                                  doc: doc source: source)))))

;; (defcommand (name) "doc" body ...) in a plugin body defines a command
;; through (current-context).
(defsyntax (defcommand stx)
  (syntax-case stx ()
    ((_ (name) doc body ...)
     (and (identifier? #'name) (stx-string? #'doc))
     (with-syntax ((source (stx-source-string stx)))
       #'(context-define-command! (current-context) 'name (lambda () body ...)
                                  doc: doc source: source)))))

;; The effective entry for the command named NAME, with provenance, or #f.
(def (command-entry (name : :symbol)) => (Maybe entry)
  (Keys-command-entry (current-keys) name))

;; The effective command named NAME, or #f.
(def (command-ref (name : :symbol)) => (Maybe command)
  (let (best (command-entry name))
    (and best (entry-value best))))

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
