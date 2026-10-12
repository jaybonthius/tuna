;;; Plugin runtime: plugins, contexts and receipts, services (ADR 2,
;;; ADR 12). Runs on the editor baton.
prelude: :gerbil/core

(import :std/error
        :std/interface
        :std/list/list
        ./ids
        ./entries
        ./state
        ./hooks)
(export (struct-out plugin)
        defplugin
        context
        context?
        current-context
        context-plugin-name
        context-defer!
        context-add-entry!
        context-provide!
        context-adapt!
        context-add-hook!
        run-hook
        plugin-activated-hook
        plugin-deactivated-hook
        service-changed-hook
        run-lifecycle-hook
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
;; that register into it implicitly.
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

;;; Hooks

;; Add PROCEDURE to H under NAME for CTX's plugin; it is removed when the
;; plugin is deactivated.
(def (context-add-hook! (ctx : context)
                        (h : hook)
                        (name : :symbol)
                        (procedure : :procedure)
                        depth: (depth : :fixnum := 0))
  => :void
  (let (callback (add-hook-callback! h name (context-plugin-name ctx) depth procedure))
    (context-defer! ctx (lambda () (remove-hook-callback! h callback)))))

;; Call each of H's callbacks with ARGS. A callback that fails is removed
;; and reported; the others still run.
(def (run-hook (h : hook) . args) => :void
  (for-each
    (lambda ((callback : hook-callback))
      (with-catch
       (lambda (e)
         (remove-hook-callback! h callback)
         (message (string-append "Hook " (symbol->string (hook-name h)) " callback "
                                 (symbol->string (hook-callback-name callback)) " (from "
                                 (symbol->string (hook-callback-owner callback))
                                 ") failed and was removed: " (exception-summary e))))
       (lambda () (apply (hook-callback-procedure callback) args))))
    (current-hook-callbacks h)))

;;; Lifecycle hooks (ADR 12)
;;;
;;; The kernel announces its own events on these hooks. A callback runs
;;; after the event's state change is complete, on the thread that holds the
;;; baton: the thread that activated or deactivated the plugin, or the loop
;;; thread for tasks. A failing callback is removed and reported like any
;;; other; the operation, the loop, and the task carry on. Callbacks may read
;;; kernel state, but must not activate or deactivate plugins: those calls
;;; raise, which removes the callback. To react with such a change, queue a
;;; task with spawn-task!. Callbacks must not wait for the loop either
;;; (call-on-editor-loop, suspend).
;;;
;;; Plugin and service events are recorded while an activation or
;;; deactivation runs, including everything it cascades into (dependents
;;; restarting, providers handing over), and announced in order once the
;;; outermost operation has finished, even if it raised. Callbacks therefore
;;; see the kernel as the whole operation left it: a dependent that restarted
;;; is already active again when its deactivation is announced. A plugin's
;;; own callbacks are gone by the time its deactivation is announced.

(def plugin-activated-hook
  (new-hook 'plugin-activated
            doc: "Runs with a plugin after it has activated."))

(def plugin-deactivated-hook
  (new-hook 'plugin-deactivated
            doc: "Runs with a plugin after it has deactivated and its receipt has run."))

;; Arguments: the service, its old provider or #f, and its new provider or
;; #f. Runs only when the effective provider becomes a different object: one
;; is provided where there was none, a provider replaces another (after the
;; handover), or the last provider is withdrawn.
(def service-changed-hook
  (new-hook 'service-changed
            doc: "Runs with a service, its old provider or #f, and its new provider or #f."))

;; Lifecycle events of the plugin operation in progress, newest first, as
;; (hook . arguments); #f outside one.
(def pending-events (make-parameter #f))

;; True while lifecycle callbacks run.
(def announcing? (make-parameter #f))

;; Run the lifecycle hook H with ARGS, refusing plugin operations meanwhile.
(def (run-lifecycle-hook (h : hook) . args) => :void
  (parameterize ((announcing? #t))
    (apply run-hook h args)))

(def (record-event! (h : hook) . args) => :void
  (let (events (pending-events))
    (if events
      (set-box! events (cons (cons h args) (unbox events)))
      (apply run-lifecycle-hook h args))))

;; Run THUNK as a plugin operation, then announce the lifecycle events it
;; recorded. A nested operation records into the outermost one.
(def (call-as-plugin-operation (thunk : :procedure)) => :void
  (when (announcing?)
    (error "Lifecycle hook callbacks must not activate or deactivate plugins"))
  (if (pending-events)
    (thunk)
    (let (events (box []))
      (unwind-protect
        (parameterize ((pending-events events))
          (thunk))
        (for-each (lambda ((event : :pair)) (apply run-lifecycle-hook (car event) (cdr event)))
                  (reverse (unbox events)))))))

;;; Services

;; A named slot for one implementation of an interface at a time.
(defstruct service ((name        : :symbol)
                    (tier        : :symbol)      ; startup or live
                    (implements? : :procedure)
                    (doc         : :string)
                    (handover    :? :procedure)) ; outgoing, incoming provider -> void
  final: #t)

;; With HANDOVER, whenever the effective provider changes from one provider
;; to another, HANDOVER receives both and moves the outgoing provider's
;; state into the incoming one through the service's interface (ADR 11,
;; ADR 12). It runs before the service's dependents restart.
(def (new-service (name : :symbol)
                  (implements? : :procedure)
                  tier:     (tier     : :symbol)
                  doc:      (doc      : :string)
                  handover: (handover :? :procedure := #f))
  => service
  (unless (memq tier '(startup live))
    (raise-bad-argument new-service "tier startup or live" tier))
  (make-service name tier implements? doc handover))

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
      (let (closure (deactivation-closure k (restarting-dependents k name)))
        (check-removable! k closure)
        (deactivate-records! k closure)))
    (entry-table-add! (kernel-providers k) name new)
    (context-defer! ctx (lambda () (withdraw-provider! k svc new)))
    (cond
     ((not current)
      (record-event! service-changed-hook svc #f impl))
     ((entry-outranks? new current)
      (hand-over! svc (entry-value current) impl)
      (unless (eq? (entry-value current) impl)
        (record-event! service-changed-hook svc (entry-value current) impl))))))

;; Remove the provider entry OLD of SVC; if it was effective, hand over to
;; the provider that takes its place.
(def (withdraw-provider! (k : kernel) (svc : service) (old : entry)) => :void
  (let* ((name (service-name svc))
         (effective? (eq? (entry-table-ref (kernel-providers k) name) old)))
    (entry-table-remove! (kernel-providers k) name old)
    (when effective?
      (let* ((next (entry-table-ref (kernel-providers k) name))
             (incoming (and next (entry-value next))))
        (when next
          (hand-over! svc (entry-value old) incoming))
        (unless (eq? (entry-value old) incoming)
          (record-event! service-changed-hook svc (entry-value old) incoming))))))

;; Run SVC's handover from OUTGOING to INCOMING; a failure is reported.
(def (hand-over! (svc : service) (outgoing : :t) (incoming : :t)) => :void
  (let (handover (service-handover svc))
    (when (and handover (not (eq? outgoing incoming)))
      (with-catch
       (lambda (e)
         (let (text (string-append "Service " (symbol->string (service-name svc))
                                   " failed to hand over to its new provider: "
                                   (exception-summary e)))
           (message text)
           (let (port (current-error-port))
             (display text port)
             (newline port))))
       (lambda () (handover outgoing incoming))))))

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

;; Whether REC's plugin adapts to a new provider of the service named NAME
;; instead of restarting.
(def (adapting? (k : kernel) (name : :symbol) (rec : plugin-record)) => :boolean
  (let (owner (plugin-name (plugin-record-definition rec)))
    (ormap (lambda ((e : entry)) (eq? (entry-owner e) owner))
           (entry-table-entries (kernel-adapters k) name))))

(def (restarting-dependents (k : kernel) (name : :symbol)) => :list
  (filter (lambda ((rec : plugin-record)) (not (adapting? k name rec)))
          (service-dependents k name)))

;; ROOTS plus every active plugin that transitively depends on a service
;; they provide. Adapting dependents stay unless no provider would remain.
(def (deactivation-closure (k : kernel) (roots : :list)) => :list
  (let loop ((pending roots) (seen []))
    (match pending
      ([]
       (let (stranded (stranded-adapters k seen))
         (if (null? stranded)
           seen
           (loop stranded seen))))
      ([rec . rest]
       (if (memq rec seen)
         (loop rest seen)
         (loop (append (append-map (cut restarting-dependents k <>)
                                   (provided-service-names k rec))
                       rest)
               (cons rec seen)))))))

;; Adapting dependents, outside GOING, of services GOING provides that no
;; plugin outside GOING also provides.
(def (stranded-adapters (k : kernel) (going : :list)) => :list
  (let (owners (map (lambda ((rec : plugin-record)) (plugin-name (plugin-record-definition rec)))
                    going))
    (append-map
     (lambda ((name : :symbol))
       (if (ormap (lambda ((e : entry)) (not (memq (entry-owner e) owners)))
                  (entry-table-entries (kernel-providers k) name))
         []
         (filter (lambda ((rec : plugin-record)) (not (memq rec going)))
                 (service-dependents k name))))
     (append-map (cut provided-service-names k <>) going))))

;; A dependent's handler for a new provider, and the provider it last saw.
(defclass adapter ((handler : :procedure)       ; old provider, new provider -> void
                   (seen    : :t))
  final: #t)

;; Declare that CTX's plugin adapts to a new provider of SVC, which it
;; requires, instead of restarting: HANDLER receives the old and new
;; providers and migrates the plugin's state in place (ADR 2).
(def (context-adapt! (ctx : context) (svc : service) (handler : :procedure)) => :void
  (context-add-entry! ctx (kernel-adapters (the-kernel)) (service-name svc)
                      (adapter handler: handler seen: (service-provider svc)))
  (void))

;; Tell each adapter whose service changed provider since it last looked.
(def (reconcile-adapters! (k : kernel)) => :void
  (let (adapters (kernel-adapters k))
    (for-each
      (lambda ((name : :symbol))
        (let (best (entry-table-ref (kernel-providers k) name))
          (when best
            (for-each
              (lambda ((e : entry))
                (using (a (entry-value e) : adapter)
                  (let ((old a.seen)
                        (new (entry-value best)))
                    (unless (eq? old new)
                      (set! a.seen new)
                      (with-catch (cut report-failure! (entry-owner e) "adapting" <>)
                                  (lambda () (a.handler old new)))))))
              (entry-table-entries adapters name)))))
      (entry-table-keys adapters))))

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
          (for-each (cut report-failure! (plugin-name (plugin-record-definition rec)) "deactivating" <>)
                    (run-receipt! ctx))
          (record-event! plugin-deactivated-hook (plugin-record-definition rec)))))
    (reverse (by-activation records))))

(def (by-activation (records : :list)) => :list
  (list-sort (lambda ((a : plugin-record) (b : plugin-record))
               (fx< (plugin-record-activated a) (plugin-record-activated b)))
             records))

(def (report-failure! (name : :symbol) (what : :string) (e : :t)) => :void
  (let (text (string-append "Plugin " (symbol->string name) " failed while "
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
    (set! (plugin-record-activated rec) (next-id!))
    (record-event! plugin-activated-hook (plugin-record-definition rec))))

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
                  (report-failure! (plugin-name (plugin-record-definition (car failure)))
                                   "activating" (cdr failure))))
              failures)
    (reconcile-adapters! k)
    (cond
     ((assq target failures) => (lambda ((failure : :pair)) (raise (cdr failure)))))))

;; Turn P on. It activates now if its services are provided, otherwise as
;; soon as they are.
(def (activate-plugin! (p : plugin)) => :void
  (call-as-plugin-operation
   (lambda ()
     (let* ((k (the-kernel))
            (rec (plugin-record! k p)))
       (for-each (cut remember-service! k <>) (plugin-requires p))
       (unless (plugin-record-active rec)
         (set! (plugin-record-wanted? rec) #t)
         (settle! k rec))))))

;; Turn P off, with everything that depends on what it provides. Dependents
;; stay wanted and come back when their services are provided again.
(def (deactivate-plugin! (p : plugin)) => :void
  (call-as-plugin-operation
   (lambda ()
     (let* ((k (the-kernel))
            (rec (hash-get (kernel-plugins k) (plugin-name p))))
       (when rec
         (when (plugin-record-active rec)
           (let (closure (deactivation-closure k [rec]))
             (check-removable! k closure)
             (set! (plugin-record-wanted? rec) #f)
             (deactivate-records! k closure)))
         (set! (plugin-record-wanted? rec) #f)
         (settle! k #f))))))

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
  (call-as-plugin-operation
   (lambda ()
     (let (k (the-kernel))
       (when (kernel-live? k)
         (error "Stop the editor loop before deactivating every plugin"))
       (for-each (lambda ((rec : plugin-record)) (set! (plugin-record-wanted? rec) #f))
                 (hash-values (kernel-plugins k)))
       (deactivate-records! k (filter plugin-record-active (hash-values (kernel-plugins k))))))))

;;; describe-services

(defstruct service-info ((name       : :symbol)
                         (tier       : :symbol)
                         (provider   :? :symbol)
                         (dependents : :list)          ; plugin names
                         (adapting   : :list)          ; the dependents that adapt
                         (doc        : :string))
  final: #t)

(def (describe-services) => :list
  (let (k (the-kernel))
    (map (lambda ((svc : service))
           (let* ((name (service-name svc))
                  (best (entry-table-ref (kernel-providers k) name))
                  (dependents (service-dependents k name))
                  (names (lambda (records)
                           (map (lambda ((rec : plugin-record))
                                  (plugin-name (plugin-record-definition rec)))
                                records))))
             (make-service-info name
                                (service-tier svc)
                                (and best (entry-owner best))
                                (names dependents)
                                (names (filter (cut adapting? k name <>) dependents))
                                (service-doc svc))))
         (list-sort (lambda ((a : service) (b : service))
                      (string<? (symbol->string (service-name a))
                                (symbol->string (service-name b))))
                    (hash-values (kernel-services k))))))

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
