;;; Plugin runtime: plugins, contexts and receipts, services (ADR 2,
;;; ADR 12). Runs on the editor baton.
prelude: :gerbil/core

(import :std/error
        :std/interface
        :std/list/list
        ./ids
        ./entries
        ./state
        ./tasks
        ./hooks)
(export (struct-out plugin)
        defplugin
        context
        context-plugin-name
        current-context
        call-with-context
        context-bind
        call-with-context-receipt
        with-service-provider
        set-plugin-order!
        context-defer!
        context-add-entry!
        context-provide!
        context-add-hook!
        run-hook
        plugin-activated-hook
        plugin-deactivated-hook
        service-changed-hook
        run-lifecycle-hook
        (struct-out service)
        new-service
        service-provider
        activate-plugin!
        deactivate-plugin!
        plugin-active?
        plugin-deactivation-closure
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
                   (provides : :list)
                   (optional : :list)
                   (activate : :procedure)       ; context -> void
                   (source   :? :string))
  final: #t)

;; What one activation registered: inverse thunks, newest first.
(defclass context ((owner   : plugin)
                   (order   : owner-order)
                   (receipt : :list))
  final: #t)

(defclass plugin-record ((definition : plugin)
                         (wanted?    : :boolean)     ; activate whenever requirements are met
                         (active     :? context)     ; its context while active
                         (order      : owner-order)
                         (registered : :fixnum)
                         (activated  : :fixnum))
  final: #t)

;; The context of the plugin being activated, for the declarative forms
;; that register into it implicitly.
(def current-context (make-parameter #f))

;; Bind later registrations to their owner, independently of task lifetime.
(def (call-with-context (ctx :? context) (thunk : :procedure)) => :t
  (if (eq? ctx (current-context))
    (thunk)
    (parameterize ((current-context ctx)) (thunk))))

(def (context-bind (ctx :? context) (procedure : :procedure)) => :procedure
  (lambda args
    (call-with-context ctx (lambda () (apply procedure args)))))

;; Temporary work owns an inverse only while its body is live.
(def (call-with-context-receipt (ctx : context) (undo : :procedure) (body : :procedure)) => :t
  (dynamic-wind
    (lambda () (set! (context-receipt ctx) (cons undo (context-receipt ctx))))
    (lambda () (call-with-context ctx body))
    (lambda () (set! (context-receipt ctx) (remq undo (context-receipt ctx))))))

(def (context-plugin-name (ctx : context)) => :symbol
  (plugin-name (context-owner ctx)))

;; Record UNDO to run when the context's plugin is deactivated.
(def (context-defer! (ctx : context) (undo : :procedure)) => :void
  (set! (context-receipt ctx)
    (cons undo (context-receipt ctx))))

;; Run the receipt newest first; an inverse that fails does not stop the rest.
(def (run-receipt! (ctx : context)) => :list
  (let (undos (context-receipt ctx))
    (set! (context-receipt ctx) [])
    (let loop ((rest undos) (failures []))
      (match rest
        ([] (reverse failures))
        ([undo . more]
         (loop more
               (with-catch (lambda (e) (if (hold-quit! e) failures (cons e failures)))
                           (lambda () (undo) failures))))))))

;; Add an owner-tagged entry for NAME to TABLE and undo it on deactivation.
(def (context-add-entry! (ctx      : context)
                         (table    : entry-table)
                         (name     : :t)
                         (value    : :t)
                         priority: (priority : :fixnum := 0)
                         doc:      (doc      :? :string := #f)
                         source:   (source   :? :string := #f))
  => entry
  (let (new (make-entry (context-plugin-name ctx) priority (context-order ctx) (next-id!) value doc source))
    (entry-table-add! table name new)
    (context-defer! ctx (lambda () (entry-table-remove! table name new)))
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
     #'(defplugin (name ctx) doc clause ...))
    ((_ (name ctx) doc clause ...)
     (and (identifier? #'name) (identifier? #'ctx) (stx-string? #'doc))
     (let loop ((rest #'(clause ...)) (required #'[]) (provided #'[]) (optional #'[])
                (have-required? #f) (have-provided? #f) (have-optional? #f))
       (syntax-case rest ()
         ((requires: services body ...)
          (not have-required?)
          (loop #'(body ...) #'services provided optional #t have-provided? have-optional?))
         ((provides: services body ...)
          (not have-provided?)
          (loop #'(body ...) required #'services optional have-required? #t have-optional?))
         ((optional: services body ...)
          (not have-optional?)
          (loop #'(body ...) required provided #'services have-required? have-provided? #t))
         ((body ...)
          (with-syntax ((source (stx-source-string stx))
                        (required required) (provided provided) (optional optional))
            #'(def name
                (make-plugin 'name doc required provided optional
                             (lambda ((ctx : context)) => :void body ... (void))
                             source)))))))))

;;; Hooks

;; Add PROCEDURE to H under NAME for CTX's plugin; it is removed when the
;; plugin is deactivated. Its later implicit registrations belong to CTX too.
(def (context-register-hook! (ctx : context)
                        (h : hook)
                        (name : :symbol)
                        (procedure : :procedure)
                        depth: (depth : :fixnum := 0))
  => :void
  (let (callback (add-hook-callback! h name (context-plugin-name ctx) depth (context-bind ctx procedure)))
    (context-defer! ctx (lambda () (remove-hook-callback! h callback)))))

;; Named bindings stay live under (declare (separate)); expressions use
;; context-add-hook! when capturing a closure is intentional.
(defsyntax (context-add-hook! stx)
  (syntax-case stx ()
    ((_ ctx h name function option ...)
     (identifier? #'function)
     #'(context-register-hook! ctx h name (lambda args (apply function args)) option ...))
    ((_ ctx h name expression option ...)
     #'(context-register-hook! ctx h name expression option ...))))

;; Call each of H's callbacks with ARGS. A callback that fails is removed
;; and reported; the others still run. A quit is not a failure, and the
;; callback stays: inside a plugin operation the quit is held (see Plugin
;; operations and quitting) and the other callbacks still run; otherwise,
;; in a task, it unwinds the task (ADR 3). Outside both, where nothing can
;; unwind, a quit counts as a failure.
(def (run-hook (h : hook) . args) => :void
  (for-each
    (lambda ((callback : hook-callback))
      (with-catch
       (lambda (e)
         (cond
          ((hold-quit! e) (void))
          ((and (quit-condition? e) (current-task)) (raise e))
          (else (remove-hook-callback! h callback)
         (report-failure-message! (string-append "Hook " (symbol->string (hook-name h)) " callback "
                                 (symbol->string (hook-callback-name callback)) " (from "
                                 (symbol->string (hook-callback-owner callback))
                                 ") failed and was removed: " (exception-summary e))))))
       (lambda () (apply (hook-callback-procedure callback) args))))
    (current-hook-callbacks h)))

;;; Lifecycle hooks (ADR 12)
;;;
;;; The kernel announces its own events on these hooks. A callback runs
;;; after the event's state change is complete, on the thread that holds the
;;; baton: the thread that activated or deactivated the plugin, or the loop
;;; thread for tasks. A failing callback is removed and reported like any
;;; other; the operation, the loop, and the task carry on. A quit in a
;;; callback is not a failure: during a plugin operation it is held until
;;; every event has been announced (see Plugin operations and quitting), and
;;; on the loop thread, where nothing can unwind, it counts as a failure.
;;; Callbacks may read
;;; kernel state, but must not activate or deactivate plugins: those calls
;;; raise, which removes the callback. To react with such a change while
;;; the editor loop runs (editor-loop-running?), queue a task with
;;; spawn-task!; while it is stopped, as during startup and shutdown, a
;;; callback cannot cause a plugin change. Callbacks must not wait for the
;;; loop either (call-on-editor-loop, suspend).
;;;
;;; Plugin and service events are recorded while an activation or
;;; deactivation runs, including everything it cascades into (dependents
;;; restarting), and announced in order once the
;;; outermost operation has finished, even if it raised or quit. Every
;;; callback of every event runs, even after one quits. Callbacks therefore
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
;; is provided where there was none, or its provider is withdrawn.
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

;;; Plugin operations and quitting (ADR 3)
;;;
;;; An activation or deactivation, with everything it cascades into and its
;;; announcements, is atomic with respect to quitting. It runs with quit
;;; inhibited, so a quit request, from one interrupt or two, waits until the
;;; operation has finished; a third interrupt overrides the inhibition, as
;;; everywhere. A quit raised inside the operation anyway (by a third
;;; interrupt, signal-quit, or a suspension resumed with quit) that reaches
;;; one of the kernel's failure catchers is held: hook callbacks, receipt
;;; undos count as done, nothing is reported, and
;;; no callback is removed. A plugin whose own activation quit cannot be
;;; done, so it is rolled back and turned off as on failure, without a
;;; report. Once the operation and its announcements have finished, a held
;;; quit is raised in the task, which unwinds; outside a task it is dropped.
;;; A quit that reaches no catcher, in practice only a third interrupt
;;; landing in the kernel's own code, ends the operation early; the events
;;; it recorded are still announced.

;; The held quit of the plugin operation in progress, in a box; #f outside
;; one.
(def held-quit (make-parameter #f))

;; If E is a quit and a plugin operation is in progress, hold E (the first
;; quit held wins) and return #t; otherwise return #f. Failure catchers call
;; this first.
(def (hold-quit! (e : :t)) => :boolean
  (let (held (held-quit))
    (and held
         (quit-condition? e)
         (begin
           (unless (unbox held)
             (set-box! held e))
           #t))))

;; Run THUNK as a plugin operation with quit inhibited, announce the
;; lifecycle events it recorded, then raise a held quit in a task. A nested
;; operation records and holds into the outermost one.
(def (call-as-plugin-operation (thunk : :procedure)) => :void
  (when (announcing?)
    (error "Lifecycle hook callbacks must not activate or deactivate plugins"))
  (if (pending-events)
    (thunk)
    (let ((events (box []))
          (held (box #f)))
      (parameterize ((held-quit held))
        (call-with-inhibit-quit
         (lambda ()
           (unwind-protect
             (parameterize ((pending-events events))
               (thunk))
             (for-each (lambda ((event : :pair))
                         (with-catch (lambda (e) (unless (hold-quit! e) (raise e)))
                                     (lambda () (apply run-lifecycle-hook (car event) (cdr event)))))
                       (reverse (unbox events))))
           ;; Raised here, it keeps a forced quit's flag; the inhibited
           ;; region's own quit check would raise an unforced one.
           (let (quit (unbox held))
             (when (and quit (current-task))
               (raise quit)))))))))

;;; Services

;; A named slot for one implementation of an interface at a time.
(defstruct service ((name        : :symbol)
                    (tier        : :symbol)      ; startup or live
                    (implements? : :procedure)
                    (doc         : :string)
                    (home        :? kernel)
                    (implementation : :t))
  final: #t)

(def (new-service (name : :symbol)
                  (implements? : :procedure)
                  tier: (tier : :symbol)
                  doc: (doc : :string))
  => service
  (unless (memq tier '(startup live))
    (raise-bad-argument new-service "tier startup or live" tier))
  (make-service name tier implements? doc #f #f))

(def (remember-service! (k : kernel) (svc : service)) => :void
  (hash-put! (kernel-services k) (service-name svc) svc))

;; Update read cells on mutations, never during a warm dispatch. A service
;; keeps only its last kernel; other kernels rebuild that cell on next use.
(def (refresh-cached-services! (k : kernel)) => :void
  (for-each (lambda ((svc : service))
              (when (eq? (service-home svc) k) (refresh-service-cache! k svc)))
            (kernel-cached-services k)))

(def (refresh-service-cache! (k : kernel) (svc : service)) => :void
  (let (best (entry-table-ref (kernel-providers k) (service-name svc)))
    (set! (service-home svc) k)
    (set! (service-implementation svc) (and best (entry-value best)))))

(defrule (with-cached-service svc body ...)
  (let (k (current-kernel))
    (unless (and k (eq? (service-home svc) k))
      (refresh-service-cache! (:- k kernel) svc)
      (unless (memq svc (kernel-cached-services k))
        (set! (kernel-cached-services k) (cons svc (kernel-cached-services k)))))
    body ...))

;; The current provider of SVC, or #f.
(def (service-provider (svc : service)) => :t
  (with-cached-service svc (service-implementation svc)))

;; The common typed dispatcher is only a cached lookup, never an owner scope.
(defrule (with-service-provider (provider svc interface) body ...)
  (let (slot (:- svc service))
    (let (provider (interface (or (service-provider slot)
                                 (error "No plugin provides" (service-name slot)))))
      body ...)))

(def (context-provide! (ctx : context) (svc : service) (impl : :t)) => :void
  (unless ((service-implements? svc) impl)
    (raise-bad-argument context-provide! "an implementation of the service" (service-name svc) impl))
  (let* ((k (the-kernel))
         (name (service-name svc))
         (current (entry-table-ref (kernel-providers k) name)))
    (when current
      (error "Service already has a provider" name (entry-owner current) (context-plugin-name ctx)))
    (remember-service! k svc)
    (let (new (context-add-entry! ctx (kernel-providers k) name impl doc: (service-doc svc)))
      (refresh-cached-services! k)
      (context-defer! ctx
        (lambda ()
          (entry-table-remove! (kernel-providers k) name new)
          (refresh-cached-services! k)
          (record-event! service-changed-hook svc impl #f))))
    (record-event! service-changed-hook svc #f impl)))

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

;; ROOTS plus every active required dependent, recursively.
(def (deactivation-closure (k : kernel) (roots : :list)) => :list
  (let loop ((pending roots) (seen []))
    (match pending
      ([] seen)
      ([rec . rest]
       (if (memq rec seen)
         (loop rest seen)
         (loop (append (append-map (cut service-dependents k <>)
                                   (provided-service-names k rec)) rest)
               (cons rec seen)))))))

;; Read-only query for orchestrators that capture state before teardown.
(def (plugin-deactivation-closure (p : plugin)) => :list
  (let* ((k (the-kernel))
         (rec (hash-get (kernel-plugins k) (plugin-name p))))
    (if (and rec (plugin-record-active rec))
      (map plugin-record-definition (by-activation (deactivation-closure k [rec])))
      [])))

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
  (report-failure-message!
   (string-append "Plugin " (symbol->string name) " failed while "
                  what ": " (exception-summary e))))

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
                               order: (owner-order rank: 0)
                               registered: (next-id!) activated: 0))
        (hash-put! plugins (plugin-name p) rec)
        rec)))))

(def (requirements-met? (k : kernel) (rec : plugin-record)) => :boolean
  (andmap (lambda ((svc : service))
            (and (entry-table-ref (kernel-providers k) (service-name svc)) #t))
          (plugin-requires (plugin-record-definition rec))))

;; Run REC's activation. On failure its partial receipt is undone.
(def (run-activation! (k : kernel) (rec : plugin-record)) => :void
  (let (ctx (context owner: (plugin-record-definition rec) order: (plugin-record-order rec) receipt: []))
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
;; changes. A plugin whose activation fails or quits is turned off. Returns
;; failures as (record . exception) pairs; a held quit is not a failure.
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
                 (if (hold-quit! e)
                   failures
                   (cons (cons ready e) failures)))
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
    (cond
     ((assq target failures) => (lambda ((failure : :pair)) (raise (cdr failure)))))))

;; The activator supplies a stable rank; later declarations win ties.
;; Without one, equal ranks break by plugin name, never registration time.
(def (set-plugin-order! (p : plugin) (rank : :fixnum)) => :void
  (let (k (the-kernel))
    (set! (owner-order-rank (plugin-record-order (plugin-record! k p))) rank)))

;; Turn P on. It activates now if its services are provided, otherwise as
;; soon as they are.
(def (activate-plugin! (p : plugin) order: (rank :? :fixnum := #f)) => :void
  (call-as-plugin-operation
   (lambda ()
     (let* ((k (the-kernel))
            (rec (plugin-record! k p)))
       (when rank
         (set! (owner-order-rank (plugin-record-order rec)) rank))
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
             (set! (plugin-record-wanted? rec) #f)
             (deactivate-records! k closure)))
         (set! (plugin-record-wanted? rec) #f)
         (settle! k #f))))))

(def (plugin-active? (p : plugin)) => :boolean
  (let (rec (hash-get (kernel-plugins (the-kernel)) (plugin-name p)))
    (and rec (plugin-record-active rec) #t)))

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
                                (service-doc svc))))
         (list-sort (lambda ((a : service) (b : service))
                      (string<? (symbol->string (service-name a))
                                (symbol->string (service-name b))))
                    (hash-values (kernel-services k))))))

;;; Messages

;; Where the kernel and plugins report to the user (ADR 12: a plugin
;; provides it). The kernel adds no other failure channel: its failures go
;; here, or to stderr while no plugin provides it; plugin and service
;; failures always go to stderr too.
(interface Messages
  ;; Show MESSAGE to the user; "" clears the shown message.
  (message! (message : :string)) => :void)

(def messages-service
  (new-service 'messages is-Messages? tier: 'live
               doc: "Shows messages to the user."))

;; Show STRING through the Messages provider, or on stderr while no plugin
;; provides it.
(def (message (string : :string)) => :void
  (let (provider (service-provider messages-service))
    (cond
     (provider (Messages-message! (Messages provider) string))
     ((not (string-empty? string)) (write-error-line string))))
  (void))

;; Report a plugin or service failure on stderr, exactly once, and then
;; through the Messages provider when there is one.
(def (report-failure-message! (string : :string)) => :void
  (write-error-line string)
  (let (provider (service-provider messages-service))
    (when provider (Messages-message! (Messages provider) string)))
  (void))

(def (write-error-line (string : :string)) => :void
  (let (port (current-error-port))
    (display string port)
    (newline port)))
