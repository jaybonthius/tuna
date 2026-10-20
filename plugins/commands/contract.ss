;;; Named commands, independent of the input provider (ADR 8, ADR 14).
prelude: :gerbil/core

(import :std/interface :tuna/kernel :tuna/lib/advice)
(export (struct-out command)
        (interface-out Commands)
        commands-service context-define-command! define-command defcommand command-target
        command-entry command-ref command-names call-command call-special-command
        this-command last-command
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
  ;; Advice on command NAME wraps whichever definition is current.
  (advice-target (name : :symbol)) => advice-target
  (command-entry (name : :symbol)) => (Maybe entry)
  (command-names) => :list
  (call-command (name : :symbol)) => :t
  ;; Run command NAME, with its advice, as the binding of a special event
  ;; (Emacs's special-event-map): outside the command loop's bookkeeping,
  ;; so it becomes neither this-command nor last-command, and no pre- or
  ;; post-command hook runs for it.
  (call-special-command (name : :symbol)) => :t
  (this-command) => (Maybe :symbol)
  (last-command) => (Maybe :symbol))

(def commands-service
  (new-service 'commands is-Commands? tier: 'live doc: "Named commands and their activation identity."))

(def (context-define-command! (ctx : context) (name : :symbol) (procedure : :procedure)
                              doc: (doc : :string := "")
                              visible?: (visible? : :procedure := (lambda (c origin) #t))
                              source: (source :? :string := #f)) => :void
  ;; A command may restart its own owner through swap/reload. Its receipt
  ;; cancels that same task after the operation finishes; end quietly then,
  ;; but keep quits from another task (including suspended commands) visible.
  (let (retiring-task #f)
    (context-defer! ctx (lambda () (set! retiring-task (current-task-id))))
    (:- (with-service-provider (provider commands-service Commands)
      (Commands-define-command! provider ctx
        (make-command name: name
          procedure: (lambda ()
                       (with-catch
                        (lambda (e)
                          (unless (and (quit-condition? e) retiring-task
                                       (eqv? retiring-task (current-task-id)))
                            (raise e)))
                        (lambda () (call-with-task-owner ctx procedure))))
          doc: doc visible?: visible?) source)) :void)))

;; The advice target of command NAME, for advise!. It exists before the
;; command is defined and outlives its definitions, as Emacs advice does.
(def (command-target (name : :symbol)) => advice-target
  (:- (with-service-provider (provider commands-service Commands)
        (Commands-advice-target provider name)) advice-target))

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

;; Run command NAME as a special event's binding: what the user did last
;; stays the last command, and the command hooks do not run. Input
;; providers call this for events the user did not make, such as the
;; browser reporting what it measured.
(def (call-special-command (name : :symbol)) => :t
  (with-service-provider (provider commands-service Commands) (Commands-call-special-command provider name)))

(def (this-command) => (Maybe :symbol)
  (:? (with-service-provider (provider commands-service Commands) (Commands-this-command provider)) :symbol))

(def (last-command) => (Maybe :symbol)
  (:? (with-service-provider (provider commands-service Commands) (Commands-last-command provider)) :symbol))
