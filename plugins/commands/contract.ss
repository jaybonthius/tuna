;;; Named commands, independent of the input provider (ADR 8, ADR 14).
prelude: :gerbil/core

(import :std/interface :tuna/kernel :tuna/lib/advice)
(export (struct-out command)
        (interface-out Commands)
        commands-service command-advice-target advised-commands context-define-command! define-command defcommand
        command-entry command-ref command-names call-command this-command last-command
        pre-command-hook post-command-hook)

;; Visibility receives this command and the caller's origin (usually a
;; buffer). Modes and argument specifications are reserved, not interpreted.
(defstruct command ((name : :symbol)
                    (procedure : :procedure)
                    (doc : :string)
                    (visible? : :procedure := (lambda (c origin) #t))
                    (modes : :list := [])
                    (arguments : :list := []))
  final: #t)

(def pre-command-hook (new-hook 'pre-command doc: "Before each command body; this-command identifies it."))
(def post-command-hook (new-hook 'post-command doc: "After each command body, before the following redraw."))

(interface Commands
  (define-command! (ctx : context) (c : command) (source :? :string)) => :void
  (add-advice! (ctx : context) (name : :symbol) (advice-name : :symbol)
               (kind : :symbol) (callback : :procedure)
               source: (source :? :string := #f) depth: (depth : :fixnum := 0)) => :void
  (remove-advice! (ctx : context) (name : :symbol) (advice-name : :symbol)) => :void
  (inspect-advice (name : :symbol)) => advice-target-info
  (advised-commands) => :list
  (command-entry (name : :symbol)) => (Maybe entry)
  (command-names) => :list
  (call-command (name : :symbol)) => :t
  (this-command) => (Maybe :symbol)
  (last-command) => (Maybe :symbol))

(def commands-service
  (new-service 'commands is-Commands? tier: 'live doc: "Named commands and their activation identity."))

(def (context-define-command! (ctx : context) (name : :symbol) (procedure : :procedure)
                              doc: (doc : :string := "")
                              visible?: (visible? : :procedure := (lambda (c origin) #t))
                              source: (source :? :string := #f)) => :void
  (:- (with-service-provider (provider commands-service Commands)
        (Commands-define-command! provider ctx
          (make-command name: name procedure: procedure doc: doc visible?: visible?) source)) :void))

;; The prelude supplies normalized callbacks and source. Keyword controls and
;; definition-site operation bindings cannot capture the caller's identifiers.
(defrules command-advice-target ()
  ((_ add: ctx name advice-name kind callback option ...)
   (with-service-provider (provider commands-service Commands)
     (Commands-add-advice! provider ctx name advice-name kind callback option ...)))
  ((_ remove: ctx name advice-name)
   (with-service-provider (provider commands-service Commands)
     (Commands-remove-advice! provider ctx name advice-name)))
  ((_ inspect: name)
   (with-service-provider (provider commands-service Commands)
     (Commands-inspect-advice provider name))))

;; Installed advice, including names whose defining plugin is currently absent.
(def (advised-commands) => :list
  (:- (with-service-provider (provider commands-service Commands)
        (Commands-advised-commands provider)) :list))

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
  (:? (with-service-provider (provider commands-service Commands) (Commands-command-entry provider name)) entry))

(def (command-ref (name : :symbol)) => (Maybe command)
  (let (best (command-entry name)) (and best (entry-value best))))

;; Every effective name, including hidden commands; callers filter visibility.
(def (command-names) => :list
  (:- (with-service-provider (provider commands-service Commands) (Commands-command-names provider)) :list))

;; Call from a task: prompts remain direct-style yield points. Returns the
;; procedure's value; missing names raise rather than silently doing nothing.
(def (call-command (name : :symbol)) => :t
  (with-service-provider (provider commands-service Commands) (Commands-call-command provider name)))

(def (this-command) => (Maybe :symbol)
  (:? (with-service-provider (provider commands-service Commands) (Commands-this-command provider)) :symbol))

(def (last-command) => (Maybe :symbol)
  (:? (with-service-provider (provider commands-service Commands) (Commands-last-command provider)) :symbol))
