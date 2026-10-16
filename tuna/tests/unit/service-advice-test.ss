prelude: :gerbil/core
(import :std/test :std/interface :std/source :std/misc/process
        (only-in :gerbil/runtime/mop slot-ref)
        :tuna/kernel :tuna/lib/advice :tuna/lib/service-advice
        (only-in :tuna/prelude advise! unadvise! advice-for open-definition install-open!)
        "../support/kernel"
        "../support/service-advice/contract"
        "../support/service-advice/provider"
        "../support/service-advice/caller"
        "../support/service-interfaces/base"
        (except-in "../support/service-interfaces/derived" events reset-events!))
(export service-advice-test)

(def qualified-service
  (new-service 'advice-qualified is-QualifiedBase? tier: 'live doc: "Qualified service."))
(def (provider-for (svc : service) (raw : :t) (description : service-view)) => plugin
  (defplugin (fixture-provider ctx) "Provider with its complete registration."
    provides: [svc]
    (context-provide! ctx svc raw view: description))
  fixture-provider)
(def (layers (svc : service) (operation : :symbol)) => :list
  (map advice-info-name (advice-target-info-advice (service-operation-advice svc operation))))
(def (receipt-size (ctx : context)) => :fixnum (length (slot-ref ctx 'receipt)))
(def compiled-proof
  (path-expand "../support/service-advice/compiled.sh" (this-source-directory)))
(defclass base-only () final: #t)
(implement QualifiedBase base-only
  (run (lambda (self) 'replacement))
  (widen (lambda (self value) 'replacement-value))
  (choose (lambda (self value) value)))

(def service-advice-test
  (test-suite "tuna/lib/service-advice"
    (test-case "public routes, service type, live named callbacks, real function advice and values"
      (check (check-service-routes call-with-fresh-kernel) => (void)))
    (test-case "separately compiled targets, inline provider and callback routing"
      (check (run-process [compiled-proof]) => "SERVICE-ADVICE-PASS\n"))
    (test-case "pending advice survives absence and a different complete provider interface"
      (let ((owner #f) (calls 0) (raw (new-qualified-provider))
            (base (QualifiedBase (base-only))))
        (defplugin (pending-advisor ctx) "Optional use truly outlives the provider."
          optional: [qualified-service]
          (set! owner ctx)
          (advise! ctx (service qualified-service special) 'pending
            around: (lambda (original) (set! calls (fx1+ calls)) (fx+ (original) 10))))
        (call-with-fresh-kernel [pending-advisor]
          (lambda ()
            (let ((identity (advice-target-info-identity (advice-for (service qualified-service special))))
                  (first (provider-for qualified-service base QualifiedBase-service-view))
                  (second (provider-for qualified-service raw QualifiedExtra-service-view)))
              (check (service-provider qualified-service) => #f)
              (check (map advice-target-info-name (advised-service-operations)) => '(advice-qualified/special))
              (activate-plugin! first)
              (check (eq? (service-provider qualified-service) base) => #t)
              (check calls => 0)
              (deactivate-plugin! first)
              (check (plugin-active? pending-advisor) => #t)
              (activate-plugin! second)
              (check calls => 0) ; no callback executes during construction
              (check (QualifiedExtra-special (service-provider qualified-service)) => 17)
              (check calls => 1)
              (deactivate-plugin! second)
              (check (service-provider qualified-service) => #f)
              (activate-plugin! second)
              (check (QualifiedExtra-special (service-provider qualified-service)) => 17)
              (check (eq? identity (advice-target-info-identity (advice-for (service qualified-service special)))) => #t)
              (unadvise! owner (service qualified-service special) 'pending)
              (check (eq? (service-provider qualified-service) raw) => #t)
              (check (advised-service-operations) => [])
              (deactivate-plugin! second)
              (activate-plugin! first)
              (check (eq? (service-provider qualified-service) base) => #t))))))
    (test-case "each qualified base is composed separately and exactly once"
      (let* ((raw (new-qualified-provider)) (calls []) (owner #f)
             (provider (provider-for qualified-service raw QualifiedExtra-service-view)))
        (defplugin (qualified-advisor ctx) "Record each qualified dispatch."
          optional: [qualified-service]
          (set! owner ctx)
          (advise! ctx (service qualified-service run) 'run
            around: (lambda (original) (let (result (original)) (set! calls (cons result calls)) result))))
        (call-with-fresh-kernel [provider qualified-advisor]
          (lambda ()
            (let (wrapped (service-provider qualified-service))
              (check (QualifiedBase-run wrapped) => 'base)
              (check (QualifiedExtra-run wrapped) => 'extra-run)
              (check (QualifiedSibling-run wrapped) => 'sibling)
              (check calls => '(sibling extra-run base))
              (check (QualifiedExtra-run (QualifiedExtra (QualifiedBase wrapped))) => 'extra-run)
              (check calls => '(extra-run sibling extra-run base))
              (check (QualifiedBase-choose wrapped) => 101)
              (check (QualifiedSibling-choose wrapped) => 0)
              (check (QualifiedExtra-choose wrapped) => -102))
            (unadvise! owner (service qualified-service run) 'run)
            (check (eq? (service-provider qualified-service) raw) => #t)))))
    (test-case "mutable raw state and recasts survive actual advice"
      (let* ((raw (new-provider)) (calls 0)
             (svc (new-service 'advice-diamond is-Base? tier: 'live doc: "Mutable service."))
             (provider (provider-for svc raw Diamond-service-view)))
        (defplugin (mutable-advisor ctx) "Observe without replacing raw state."
          optional: [svc]
          (advise! ctx (service svc run) 'run before: (lambda (n) (set! calls (fx1+ calls)))))
        (call-with-fresh-kernel [provider mutable-advisor]
          (lambda ()
            (let (wrapped (service-provider svc))
              (check (Base-run wrapped 2) => 2)
              (check (Extra-extra (Extra (Base wrapped))) => 2)
              (check (Diamond-leaf (Diamond (Auxiliary wrapped))) => 'leaf)
              (check (Auxiliary-side wrapped) => "side")
              (check calls => 1)
              (check (Base-run raw 3) => 5)
              (check (Diamond-extra wrapped) => 5)
              (check (Diamond-run wrapped 4) => 9)
              (check calls => 2))
            (deactivate-plugin! mutable-advisor)
            (check (eq? (service-provider svc) raw) => #t)))))
    (test-case "two operations and owners replace, reorder and clean up without provider events"
      (let* ((raw (new-counter)) (owner-a #f) (owner-b #f) (provider-context #f)
             (events []) (starts 0) (stops 0))
        (defplugin (observed-provider ctx) "Unchanged provider receipt."
          provides: [counter-service]
          (set! provider-context ctx)
          (context-provide! ctx counter-service raw view: Counter-service-view))
        (defplugin (observer ctx) "Count actual provider changes."
          (context-add-hook! ctx service-changed-hook 'observe
            (lambda (svc old new) (when (eq? svc counter-service) (set! events (cons [old new] events))))))
        (defplugin (dependent ctx) "Only a provider change may stop me."
          requires: [counter-service]
          (set! starts (fx1+ starts))
          (context-defer! ctx (lambda () (set! stops (fx1+ stops)))))
        (defplugin (earlier ctx) "Earlier layer."
          optional: [counter-service]
          (set! owner-a ctx)
          (advise! ctx (service counter-service inline) 'a around: (lambda (original n) (fx+ 1 (original n))))
          (advise! ctx (service counter-service step) 'a before: void))
        (defplugin (later ctx) "Later layer."
          optional: [counter-service]
          (set! owner-b ctx)
          (advise! ctx (service counter-service inline) 'b around: (lambda (original n) (fx* 2 (original n)))))
        (call-with-fresh-kernel [observer observed-provider dependent]
          (lambda ()
            (let ((info (describe-services)) (notes (receipt-size provider-context)))
              (activate-plugin! earlier order: 1)
              (activate-plugin! later order: 2)
              (check (Counter-inline (service-provider counter-service) 0) => 201)
              (check (layers counter-service 'inline) => '(a b))
              (check (layers counter-service 'step) => '(a))
              (check (receipt-size owner-a) => 4)
              (advise! owner-a (service counter-service inline) 'a around: (lambda (original n) (fx+ 3 (original n))))
              (check (Counter-inline (service-provider counter-service) 0) => 203)
              (check (receipt-size owner-a) => 4)
              (set-plugin-order! earlier 3)
              (refresh-advice!)
              (check (layers counter-service 'inline) => '(b a))
              (check (Counter-inline (service-provider counter-service) 0) => 206)
              (advise! owner-a (service counter-service inline) 'a around: (lambda (original n) (fx+ 3 (original n))) depth: -1)
              (check (layers counter-service 'inline) => '(a b))
              (check (Counter-inline (service-provider counter-service) 0) => 203)
              (unadvise! owner-b (service counter-service inline) 'b)
              (check (Counter-inline (service-provider counter-service) 0) => 103)
              (deactivate-plugin! earlier)
              (check (eq? (service-provider counter-service) raw) => #t)
              (check (advised-service-operations) => [])
              (check (receipt-size owner-a) => 0)
              (deactivate-plugin! later)
              (check (receipt-size owner-b) => 0)
              (check (receipt-size provider-context) => notes)
              (check (describe-services) => info)
              (check events => [[#f raw]])
              (check [starts stops] => [1 0]))))))
    (test-case "unknown operations do not cache; three absent-target cycles keep bounded receipts"
      (let (owner #f)
        (defplugin (absent-advisor ctx) "No required service."
          optional: [counter-service]
          (set! owner ctx))
        (call-with-fresh-kernel [absent-advisor]
          (lambda ()
            (check (service-decoration-states) => [])
            (check (advice-target-info-advice (advice-for (service counter-service missing))) => [])
            (unadvise! owner (service counter-service missing) 'none)
            (check (service-decoration-states) => [])
            (let (identity #f)
              (for-each
               (lambda (cycle)
                 (advise! owner (service counter-service missing) 'pending before: void)
                 (let (current (advice-target-info-identity (advice-for (service counter-service missing))))
                   (if identity (check (eq? current identity) => #t) (set! identity current)))
                 (unadvise! owner (service counter-service missing) 'pending)
                 (check (receipt-size owner) => 2)
                 (check (advice-target-info-advice (advice-for (service counter-service missing))) => [])
                 (check (advised-service-operations) => []))
               '(1 2 3)))
            (check (eq? (advice-target-info-identity (advice-for (service counter-service unknown)))
                        (advice-target-info-identity (advice-for (service counter-service unknown)))) => #f)
            (check-exception (add-service-advice! owner counter-service 'invalid 'bad 'unknown void) exception?)
            (check (receipt-size owner) => 2)
            (check (hash-length (slot-ref (car (service-decoration-states)) 'operations)) => 1)
            (deactivate-plugin! absent-advisor)
            (check (receipt-size owner) => 0)
            (check (hash-length (slot-ref (car (service-decoration-states)) 'operations)) => 0)))))
    (test-case "rank refresh uses A's bound installer while B is current; enumeration is current-only"
      (let* ((raw-a (new-counter)) (raw-b (new-counter))
             (provider-a (provider-for counter-service raw-a Counter-service-view))
             (provider-b (provider-for counter-service raw-b Counter-service-view)))
        (defplugin (rank-a ctx) "A's earlier advisor."
          optional: [counter-service]
          (advise! ctx (service counter-service inline) 'a around: (lambda (original n) (fx+ 1 (original n)))))
        (defplugin (rank-b ctx) "A's later advisor."
          optional: [counter-service]
          (advise! ctx (service counter-service inline) 'b around: (lambda (original n) (fx* 2 (original n)))))
        (call-with-fresh-kernel [provider-a]
          (lambda ()
            (activate-plugin! rank-a order: 1)
            (activate-plugin! rank-b order: 2)
            (check (Counter-inline (service-provider counter-service) 0) => 201)
            (set-plugin-order! rank-a 3)
            (call-with-fresh-kernel [provider-b]
              (lambda ()
                (check (advised-service-operations) => [])
                ;; An initialized opaque value need not belong to this library.
                (service-decoration-state! counter-service (lambda (_) #f))
                (check (advised-service-operations) => [])
                (refresh-advice!)
                (check (eq? (service-provider counter-service) raw-b) => #t)))
            (check (layers counter-service 'inline) => '(b a))
            (check (Counter-inline (service-provider counter-service) 0) => 202)
            (check (length (advised-service-operations)) => 1)))))
    (test-case "callback ownership, caller restoration, error identity and caller thread stay shared"
      (let ((advisor-context #f) (caller-context #f) (seen []) (token (box 'original-error))
            (old-body (open-definition step-body)) (raw (new-counter)))
        (defplugin (context-advisor ctx) "Around layer with the shared context policy."
          optional: [counter-service]
          (set! advisor-context ctx)
          (advise! ctx (service counter-service step) 'around
            around: (lambda (original n)
                      (set! seen (cons [(current-thread) (current-task-id) (current-context)] seen))
                      (original n))))
        (defplugin (context-caller ctx) "Ordinary caller owner." (set! caller-context ctx))
        (try
         (call-with-fresh-kernel [(provider-for counter-service raw Counter-service-view) context-advisor context-caller]
           (lambda ()
             (let ((thread (current-thread)) (task (current-task-id)))
               (install-open! step-body
                 (lambda (n)
                   (set! seen (cons [(current-thread) (current-task-id) (current-context)] seen)) n))
               (call-with-context caller-context (lambda () (Counter-step (service-provider counter-service) 1)))
               (check seen => [[thread task caller-context] [thread task advisor-context]])
               (install-open! step-body (lambda (n) (raise token)))
               (check (eq? (with-catch values (lambda () (Counter-step (service-provider counter-service) 1))) token) => #t)
               (install-open! step-body (lambda (n) (signal-quit)))
               (check (with-catch quit-condition? (lambda () (Counter-step (service-provider counter-service) 1) #f)) => #t))))
         (finally (install-open! step-body old-body)))))))
