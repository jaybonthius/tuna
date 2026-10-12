;;; Plugin runtime: plugins, contexts and receipts, services, commands
;;; (ADR 2, ADR 12). Runs on the editor baton.
prelude: :gerbil/core

(import :std/error
        :std/interface
        :std/list/list
        ./ids
        ./entries
        ./state)
(export (struct-out plugin)
        defplugin
        context
        context?
        current-context
        context-plugin-name
        context-defer!
        context-add-entry!
        context-provide!
        (struct-out service)
        new-service
        service-provider
        StartupServiceError
        startup-service-error?
        activate-plugin!
        deactivate-plugin!
        plugin-active?
        active-plugin-names
        deactivate-all-plugins!
        (struct-out service-info)
        describe-services
        (struct-out command)
        define-command
        context-define-command!
        defcommand
        command-ref
        command-entry
        (interface-out Messages)
        messages-service
        message
        (phi: +1 stx-source-string))

;;; Plugins and contexts

;; A named unit whose activation registers everything through its context.
(defstruct plugin ((name     : :symbol)
                   (doc      : :string)
                   (requires : :list)            ; services
                   (activate : :procedure)       ; context -> void
                   (source   :? :string))
  final: #t)

;; What one activation registered: inverse thunks, newest first.
(defclass context ((owner   : plugin)
                   (receipt : :list))
  final: #t)

(defclass plugin-record ((definition : plugin)
                         (wanted?    : :boolean)     ; activate whenever requirements are met
                         (active     :? context)     ; its context while active
                         (registered : :fixnum)
                         (activated  : :fixnum))
  final: #t)

;; The context of the plugin being activated, for the declarative forms
;; (defcommand, keymap-set) that register into it implicitly.
(def current-context (make-parameter #f))

(def (context-plugin-name (ctx : context)) => :symbol
  (plugin-name (context-owner ctx)))

;; Record UNDO to run when the context's plugin is deactivated.
(def (context-defer! (ctx : context) (undo : :procedure)) => :void
  (set! (context-receipt ctx) (cons undo (context-receipt ctx))))

;; Run the receipt newest first; an inverse that fails does not stop the rest.
(def (run-receipt! (ctx : context)) => :list
  (let (undos (context-receipt ctx))
    (set! (context-receipt ctx) [])
    (let loop ((rest undos) (failures []))
      (match rest
        ([] (reverse failures))
        ([undo . more]
         (loop more
               (with-catch (lambda (e) (cons e failures))
                           (lambda () (undo) failures))))))))

;; Add an owner-tagged entry to TABLE and undo it on deactivation.
(def (context-add-entry! (ctx      : context)
                         (table    : entry-table)
                         (key      : :t)
                         (value    : :t)
                         priority: (priority : :fixnum := 0)
                         doc:      (doc      :? :string := #f)
                         source:   (source   :? :string := #f))
  => entry
  (let (new (make-entry (context-plugin-name ctx) priority (next-id!) value doc source))
    (entry-table-add! table key new)
    (context-defer! ctx (lambda () (entry-table-remove! table key new)))
    new))

(begin-syntax
  (def (stx-source-string stx)
    (let (src (stx-source stx))
      (and src
           (let ((path (##locat-container src))
                 (line (fx1+ (##filepos-line (##locat-start-position src)))))
             (string-append (if (string? path) path (object->string path))
                            ":" (number->string line)))))))

;; (defplugin (name ctx) "doc" [requires: services] body ...)
;; (defplugin name "doc" [requires: services] body ...), whose body
;; registers through (current-context).
(defsyntax (defplugin stx)
  (syntax-case stx ()
    ((_ name doc clause ...)
     (and (identifier? #'name) (stx-string? #'doc))
     (with-syntax ((source (stx-source-string stx)))
       (syntax-case #'(clause ...) ()
         ((requires: services body ...)
          #'(def name
              (make-plugin 'name doc services
                           (lambda ((ctx : context)) => :void body ... (void))
                           source)))
         ((body ...)
          #'(def name
              (make-plugin 'name doc []
                           (lambda ((ctx : context)) => :void body ... (void))
                           source))))))
    ((_ (name ctx) doc requires: services body ...)
     (and (identifier? #'name) (identifier? #'ctx) (stx-string? #'doc))
     (with-syntax ((source (stx-source-string stx)))
       #'(def name
           (make-plugin 'name doc services
                        (lambda ((ctx : context)) => :void body ... (void))
                        source))))
    ((_ (name ctx) doc body ...)
     (and (identifier? #'name) (identifier? #'ctx) (stx-string? #'doc))
     (with-syntax ((source (stx-source-string stx)))
       #'(def name
           (make-plugin 'name doc []
                        (lambda ((ctx : context)) => :void body ... (void))
                        source))))))

;;; Services

;; A named slot for one implementation of an interface at a time.
(defstruct service ((name        : :symbol)
                    (tier        : :symbol)      ; startup or live
                    (implements? : :procedure)
                    (doc         : :string))
  final: #t)

(def (new-service (name : :symbol)
                  (implements? : :procedure)
                  tier: (tier : :symbol)
                  doc:  (doc  : :string))
  => service
  (unless (memq tier '(startup live))
    (raise-bad-argument new-service "tier startup or live" tier))
  (make-service name tier implements? doc))

(deferror-class StartupServiceError () startup-service-error?)

(def (remember-service! (k : kernel) (svc : service)) => :void
  (hash-put! (kernel-services k) (service-name svc) svc))

;; The current provider of SVC, or #f.
(def (service-provider (svc : service)) => :t
  (let (best (entry-table-ref (kernel-providers (the-kernel)) (service-name svc)))
    (and best (entry-value best))))

;; Provide IMPL for SVC. A provider that outranks the current one replaces
;; it: the service's dependents are deactivated now and reactivated against
;; IMPL once this activation completes.
(def (context-provide! (ctx  : context)
                       (svc  : service)
                       (impl : :t)
                       priority: (priority : :fixnum := 0))
  => :void
  (unless ((service-implements? svc) impl)
    (raise-bad-argument context-provide! "an implementation of the service" (service-name svc) impl))
  (let* ((k (the-kernel))
         (name (service-name svc))
         (current (entry-table-ref (kernel-providers k) name))
         (new (make-entry (context-plugin-name ctx) priority (next-id!) impl
                          (service-doc svc) (plugin-source (context-owner ctx)))))
    (remember-service! k svc)
    (when (and current (entry-outranks? new current))
      (check-live-change! k svc)
      (let (closure (deactivation-closure k (service-dependents k name)))
        (check-removable! k closure)
        (deactivate-records! k closure)))
    (entry-table-add! (kernel-providers k) name new)
    (context-defer! ctx (lambda () (entry-table-remove! (kernel-providers k) name new)))))

(def (check-live-change! (k : kernel) (svc : service)) => :void
  (when (and (kernel-live? k) (eq? (service-tier svc) 'startup))
    (raise (StartupServiceError "startup-tier service refuses live replacement; restart Tuna to change it"
                                irritants: [(service-name svc)]))))

;; Names of the services whose effective provider is REC's plugin.
(def (provided-service-names (k : kernel) (rec : plugin-record)) => :list
  (let (owner (plugin-name (plugin-record-definition rec)))
    (filter (lambda ((name : :symbol))
              (let (best (entry-table-ref (kernel-providers k) name))
                (and best (eq? (entry-owner best) owner))))
            (hash-keys (kernel-services k)))))

;; Active plugins that require the service named NAME.
(def (service-dependents (k : kernel) (name : :symbol)) => :list
  (filter (lambda ((rec : plugin-record))
            (and (plugin-record-active rec)
                 (ormap (lambda ((svc : service)) (eq? (service-name svc) name))
                        (plugin-requires (plugin-record-definition rec)))))
          (hash-values (kernel-plugins k))))

;; ROOTS plus every active plugin that transitively depends on a service
;; they provide.
(def (deactivation-closure (k : kernel) (roots : :list)) => :list
  (let loop ((pending roots) (seen []))
    (match pending
      ([] seen)
      ([rec . rest]
       (if (memq rec seen)
         (loop rest seen)
         (loop (append (append-map (cut service-dependents k <>)
                                   (provided-service-names k rec))
                       rest)
               (cons rec seen)))))))

(def (check-removable! (k : kernel) (records : :list)) => :void
  (for-each
    (lambda ((rec : plugin-record))
      (for-each (lambda ((name : :symbol))
                  (check-live-change! k (hash-ref (kernel-services k) name)))
                (provided-service-names k rec)))
    records))

;; Deactivate RECORDS, newest activation first, so dependents go before
;; the providers they use.
(def (deactivate-records! (k : kernel) (records : :list)) => :void
  (for-each
    (lambda ((rec : plugin-record))
      (let (ctx (plugin-record-active rec))
        (when ctx
          (set! (plugin-record-active rec) #f)
          (for-each (cut report-failure! (plugin-record-definition rec) "deactivating" <>)
                    (run-receipt! ctx)))))
    (reverse (by-activation records))))

(def (by-activation (records : :list)) => :list
  (list-sort (lambda ((a : plugin-record) (b : plugin-record))
               (fx< (plugin-record-activated a) (plugin-record-activated b)))
             records))

(def (report-failure! (p : plugin) (what : :string) (e : :t)) => :void
  (let (text (string-append "Plugin " (symbol->string (plugin-name p)) " failed while "
                            what ": " (exception-summary e)))
    (message text)
    (displayln text (current-error-port))))

;;; Activation

(def (plugin-record! (k : kernel) (p : plugin)) => plugin-record
  (let (plugins (kernel-plugins k))
    (cond
     ((hash-get plugins (plugin-name p))
      => (lambda ((rec : plugin-record))
           ;; A reloaded definition replaces an inactive one.
           (unless (plugin-record-active rec)
             (set! (plugin-record-definition rec) p))
           rec))
     (else
      (let (rec (plugin-record definition: p wanted?: #f active: #f
                               registered: (next-id!) activated: 0))
        (hash-put! plugins (plugin-name p) rec)
        rec)))))

(def (requirements-met? (k : kernel) (rec : plugin-record)) => :boolean
  (andmap (lambda ((svc : service))
            (and (entry-table-ref (kernel-providers k) (service-name svc)) #t))
          (plugin-requires (plugin-record-definition rec))))

;; Run REC's activation. On failure its partial receipt is undone.
(def (run-activation! (k : kernel) (rec : plugin-record)) => :void
  (let (ctx (context owner: (plugin-record-definition rec) receipt: []))
    (with-catch
     (lambda (e)
       (run-receipt! ctx)
       (raise e))
     (lambda ()
       (parameterize ((current-context ctx))
         ((plugin-activate (plugin-record-definition rec)) ctx))))
    (set! (plugin-record-active rec) ctx)
    (set! (plugin-record-activated rec) (next-id!))))

;; Activate wanted plugins whose services are all provided, until nothing
;; changes. Returns failures as (record . exception) pairs.
(def (activate-wanted! (k : kernel)) => :list
  (let loop ((failures []))
    (let (ready (find (lambda ((rec : plugin-record))
                        (and (plugin-record-wanted? rec)
                             (not (plugin-record-active rec))
                             (requirements-met? k rec)))
                      (list-sort (lambda ((a : plugin-record) (b : plugin-record))
                                   (fx< (plugin-record-registered a) (plugin-record-registered b)))
                                 (hash-values (kernel-plugins k)))))
      (if ready
        (loop (with-catch
               (lambda (e)
                 (set! (plugin-record-wanted? ready) #f)
                 (cons (cons ready e) failures))
               (lambda ()
                 (run-activation! k ready)
                 failures)))
        failures))))

;; Settle activations after a change. A plugin whose activation fails is
;; turned off; TARGET's failure is raised and any other is reported.
(def (settle! (k : kernel) (target :? plugin-record)) => :void
  (let (failures (activate-wanted! k))
    (for-each (lambda ((failure : :pair))
                (unless (eq? (car failure) target)
                  (report-failure! (plugin-record-definition (car failure)) "activating" (cdr failure))))
              failures)
    (cond
     ((assq target failures) => (lambda ((failure : :pair)) (raise (cdr failure)))))))

;; Turn P on. It activates now if its services are provided, otherwise as
;; soon as they are.
(def (activate-plugin! (p : plugin)) => :void
  (let* ((k (the-kernel))
         (rec (plugin-record! k p)))
    (for-each (cut remember-service! k <>) (plugin-requires p))
    (unless (plugin-record-active rec)
      (set! (plugin-record-wanted? rec) #t)
      (settle! k rec))))

;; Turn P off, with everything that depends on what it provides. Dependents
;; stay wanted and come back when their services are provided again.
(def (deactivate-plugin! (p : plugin)) => :void
  (let* ((k (the-kernel))
         (rec (hash-get (kernel-plugins k) (plugin-name p))))
    (when rec
      (when (plugin-record-active rec)
        (let (closure (deactivation-closure k [rec]))
          (check-removable! k closure)
          (set! (plugin-record-wanted? rec) #f)
          (deactivate-records! k closure)))
      (set! (plugin-record-wanted? rec) #f)
      (settle! k #f))))

(def (plugin-active? (p : plugin)) => :boolean
  (let (rec (hash-get (kernel-plugins (the-kernel)) (plugin-name p)))
    (and rec (plugin-record-active rec) #t)))

;; Active plugin names, in activation order.
(def (active-plugin-names) => :list
  (map (lambda ((rec : plugin-record)) (plugin-name (plugin-record-definition rec)))
       (by-activation (filter plugin-record-active (hash-values (kernel-plugins (the-kernel)))))))

;; Shutdown: deactivate everything, newest first. Only allowed once the
;; editor loop has stopped.
(def (deactivate-all-plugins!) => :void
  (let (k (the-kernel))
    (when (kernel-live? k)
      (error "Stop the editor loop before deactivating every plugin"))
    (for-each (lambda ((rec : plugin-record)) (set! (plugin-record-wanted? rec) #f))
              (hash-values (kernel-plugins k)))
    (deactivate-records! k (filter plugin-record-active (hash-values (kernel-plugins k))))))

;;; describe-services

(defstruct service-info ((name       : :symbol)
                         (tier       : :symbol)
                         (provider   :? :symbol)
                         (dependents : :list)          ; plugin names
                         (doc        : :string))
  final: #t)

(def (describe-services) => :list
  (let (k (the-kernel))
    (map (lambda ((svc : service))
           (let (best (entry-table-ref (kernel-providers k) (service-name svc)))
             (make-service-info (service-name svc)
                                (service-tier svc)
                                (and best (entry-owner best))
                                (map (lambda ((rec : plugin-record))
                                       (plugin-name (plugin-record-definition rec)))
                                     (service-dependents k (service-name svc)))
                                (service-doc svc))))
         (list-sort (lambda ((a : service) (b : service))
                      (string<? (symbol->string (service-name a))
                                (symbol->string (service-name b))))
                    (hash-values (kernel-services k))))))

;;; Commands

(defstruct command ((name      : :symbol)
                    (procedure : :procedure)          ; thunk, run as a task
                    (doc       : :string))
  final: #t)

(def (context-define-command! (ctx       : context)
                              (name      : :symbol)
                              (procedure : :procedure)
                              doc:    (doc    : :string := "")
                              source: (source :? :string := #f))
  => :void
  (context-add-entry! ctx (kernel-commands (the-kernel)) name
                      (make-command name procedure doc)
                      doc: doc source: source)
  (void))

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

;; The effective command named NAME, or #f.
(def (command-ref (name : :symbol)) => (Maybe command)
  (let (best (command-entry name))
    (and best (entry-value best))))

;; NAME's effective entry, with provenance.
(def (command-entry (name : :symbol)) => (Maybe entry)
  (entry-table-ref (kernel-commands (the-kernel)) name))

;;; Messages

;; Where the kernel and plugins report to the user (ADR 12: the echo area is
;; a plugin).
(interface Messages
  ;; Show TEXT to the user; "" clears the message.
  (message! (text : :string)) => :void)

(def messages-service
  (new-service 'messages is-Messages? tier: 'live
               doc: "Shows messages to the user."))

;; Show TEXT in the echo area, or on stderr while no plugin shows messages.
(def (message (text : :string)) => :void
  (let (provider (service-provider messages-service))
    (cond
     (provider (Messages-message! (Messages provider) text))
     ((not (string-empty? text)) (displayln text (current-error-port))))))
