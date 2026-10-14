;;; Named commands, independent of the input provider (ADR 8, ADR 14).
prelude: :gerbil/core

(import :std/interface :tuna/kernel)
(export (struct-out command)
        (interface-out Commands)
        commands-service context-define-command! define-command defcommand
        command-entry command-ref command-names call-command this-command last-command)

;; Visibility receives this command and the caller's origin (usually a
;; buffer). Modes and argument specifications are reserved, not interpreted.
(defstruct command ((name : :symbol)
                    (procedure : :procedure)
                    (doc : :string)
                    (visible? : :procedure := (lambda (c origin) #t))
                    (modes : :list := [])
                    (arguments : :list := []))
  final: #t)

(interface Commands
  (define-command! (ctx : context) (c : command) (source :? :string)) => :void
  (command-entry (name : :symbol)) => (Maybe entry)
  (command-names) => :list
  (call-command (name : :symbol)) => :t
  (this-command) => (Maybe :symbol)
  (last-command) => (Maybe :symbol))

(def commands-service
  (new-service 'commands is-Commands? tier: 'live doc: "Named commands and their activation identity."))

(def (current-commands) => Commands
  (let (provider (service-provider commands-service))
    (unless provider (error "No plugin provides commands"))
    (Commands provider)))

(def (context-define-command! (ctx : context) (name : :symbol) (procedure : :procedure)
                              doc: (doc : :string := "")
                              visible?: (visible? : :procedure := (lambda (c origin) #t))
                              source: (source :? :string := #f)) => :void
  (Commands-define-command! (current-commands) ctx
                            (make-command name: name procedure: procedure doc: doc visible?: visible?) source))

(defsyntax (define-command stx)
  (syntax-case stx ()
    ((_ ctx (name) doc body ...)
     (and (identifier? #'name) (stx-string? #'doc))
     (with-syntax ((source (stx-source-string stx)))
       #'(context-define-command! ctx 'name (lambda () body ...) doc: doc source: source)))))

(defsyntax (defcommand stx)
  (syntax-case stx ()
    ((_ (name) doc body ...)
     (and (identifier? #'name) (stx-string? #'doc))
     (with-syntax ((source (stx-source-string stx)))
       #'(context-define-command! (current-context) 'name (lambda () body ...)
                                  doc: doc source: source)))))

(def (command-entry (name : :symbol)) => (Maybe entry)
  (Commands-command-entry (current-commands) name))

(def (command-ref (name : :symbol)) => (Maybe command)
  (let (best (command-entry name)) (and best (entry-value best))))

;; Every effective name, including hidden commands; callers filter visibility.
(def (command-names) => :list
  (Commands-command-names (current-commands)))

;; Call from a task: prompts remain direct-style yield points. Returns the
;; procedure's value; missing names raise rather than silently doing nothing.
(def (call-command (name : :symbol)) => :t
  (Commands-call-command (current-commands) name))

(def (this-command) => (Maybe :symbol)
  (Commands-this-command (current-commands)))

(def (last-command) => (Maybe :symbol)
  (Commands-last-command (current-commands)))
