;;; Effective service slots: no advice policy, only test-owned composition.
prelude: :gerbil/core
(import :std/test :std/interface
        :tuna/kernel
        (only-in :tuna/kernel/plugins make-plugin)
        (only-in :tuna/kernel/state the-kernel kernel-providers)
        (only-in :gerbil/runtime/mop slot-ref)
        "../support/kernel"
        "../support/service-interfaces/base"
        "../support/service-interfaces/derived")
(export service-cache-test)

(def qualified-service
  (new-service 'cache-qualified is-QualifiedBase? tier: 'live doc: "Cache fixture."))
(def diamond-service
  (new-service 'cache-diamond is-Base? tier: 'live doc: "Mutable fixture."))

(def (provider-plugin (name : :symbol) (svc : service) (raw : :t)
                      (description : service-view)) => plugin
  (make-plugin name "Cache provider." [] [svc] []
    (lambda ((ctx : context)) => :void
      (context-provide! ctx svc raw view: description)) #f))

;; This provider really lacks the derived interface, not just its description.
(defclass base-provider () final: #t)
(implement QualifiedBase base-provider
  (run (lambda (self) 'replacement))
  (widen (lambda (self value) 'replacement-value))
  (choose (lambda (self value) value)))

(def (tracing-builder (builds : :box) (calls : :box) (descriptions : :box)) => :procedure
  (lambda ((raw : :t) (description : service-view)) => :t
    (set-box! builds (fx1+ (unbox builds)))
    (set-box! descriptions (cons description (unbox descriptions)))
    ((service-view-build description) raw
      (lambda ((operation : :symbol) (base : :procedure)) => :procedure
        (if (eq? operation 'run)
          (lambda args
            (set-box! calls (fx1+ (unbox calls)))
            (apply base args))
          base)))))

(def (caught (thunk : :procedure)) => :t
  (with-catch (lambda (e) e) (lambda () (thunk) #f)))

(def service-cache-test
  (test-suite "tuna/kernel/service-cache"
    (test-case "raw identity, qualified paths, snapshots and mutation-only rebuilds"
      (let* ((raw (new-qualified-provider))
             (provider (provider-plugin 'cache-provider qualified-service raw QualifiedExtra-service-view)))
        (call-with-fresh-kernel [provider]
          (lambda ()
            (check (eq? (service-provider qualified-service) raw) => #t)
            (let* ((builds (box 0)) (calls (box 0)) (descriptions (box []))
                   (install (service-decoration-state! qualified-service (lambda (install-decoration) install-decoration)))
                   (builder (tracing-builder builds calls descriptions)))
              (install builder)
              (let (snapshot (service-provider qualified-service))
                (check (is-QualifiedExtra? snapshot) => #t)
                (check (QualifiedBase-run snapshot) => 'base)
                (check (QualifiedExtra-run snapshot) => 'extra-run)
                (check (QualifiedSibling-run snapshot) => 'sibling)
                (check (QualifiedExtra-special (QualifiedExtra (QualifiedBase snapshot))) => 7)
                (check (unbox calls) => 3)
                (check (unbox descriptions) => [QualifiedExtra-service-view])
                (let loop ((i 100))
                  (unless (fxzero? i)
                    (with-service-provider (p qualified-service QualifiedBase)
                      (check (QualifiedBase-run p) => 'base))
                    (loop (fx1- i))))
                (check (unbox builds) => 1)
                (install builder)
                (check (unbox builds) => 2)
                (QualifiedBase-run (service-provider qualified-service))
                (check (unbox calls) => 104)
                (install #f)
                (check (eq? (service-provider qualified-service) raw) => #t)
                ;; Previously captured wrappers remain snapshots.
                (check (QualifiedExtra-run snapshot) => 'extra-run)
                (check (unbox calls) => 105)
                (QualifiedBase-run (service-provider qualified-service))
                (check (unbox calls) => 105)))))))
    (test-case "complete derived facade shares raw mutable state"
      (let* ((raw (new-provider))
             (provider (provider-plugin 'cache-diamond diamond-service raw Diamond-service-view)))
        (call-with-fresh-kernel [provider]
          (lambda ()
            (let (install (service-decoration-state! diamond-service (lambda (install-decoration) install-decoration)))
              (install
                (lambda (raw description)
                  ((service-view-build description) raw
                    (lambda (operation base)
                      (if (eq? operation 'run)
                        (lambda (n) (fx+ (base n) 100)) base)))))
              (let (wrapped (service-provider diamond-service))
                (check (Base-run wrapped 2) => 102)
                (check (Extra-extra wrapped) => 2)
                (check (Diamond-extra raw) => 2)
                (check (Auxiliary-side wrapped) => "side")
                (check (Diamond-leaf wrapped) => 'leaf)
                (Base-run raw 3)
                (check (Diamond-extra wrapped) => 5))
              (install #f)
              (check (eq? (service-provider diamond-service) raw) => #t))))))
    (test-case "absence, reinstall and a different complete registration retain one opaque state"
      (call-with-fresh-kernel []
        (lambda ()
          (let* ((builds (box 0)) (calls (box 0)) (descriptions (box []))
                 (initializations 0) (install #f)
                 (state (service-decoration-state! qualified-service
                          (lambda (install-decoration)
                            (set! initializations (fx1+ initializations))
                            (set! install install-decoration)
                            (install-decoration (tracing-builder builds calls descriptions))
                            (box 'opaque))))
                 (raw (new-qualified-provider))
                 (first (provider-plugin 'cache-first qualified-service raw QualifiedExtra-service-view))
                 (replacement-raw (QualifiedBase (base-provider)))
                 (replacement-service (new-service (service-name qualified-service) is-QualifiedBase?
                                        tier: 'startup doc: "Replacement metadata."))
                 (replacement (provider-plugin 'cache-second replacement-service replacement-raw QualifiedBase-service-view)))
            (check (service-provider qualified-service) => #f)
            (check (unbox builds) => 0)
            (activate-plugin! first)
            (check (QualifiedExtra-special (service-provider qualified-service)) => 7)
            (deactivate-plugin! first)
            (check (service-provider qualified-service) => #f)
            (check (service-decoration-states) => [state])
            (activate-plugin! first)
            (check (QualifiedExtra-run (service-provider qualified-service)) => 'extra-run)
            (deactivate-plugin! first)
            (activate-plugin! replacement)
            (check (service-info-doc (car (describe-services))) => "Replacement metadata.")
            (check (service-info-tier (car (describe-services))) => 'startup)
            (check (eq? (service-provider qualified-service) (service-provider replacement-service)) => #t)
            (check (QualifiedBase-run (service-provider qualified-service)) => 'replacement)
            (check (is-QualifiedExtra? (service-provider qualified-service)) => #f)
            (check (unbox descriptions) => [QualifiedBase-service-view QualifiedExtra-service-view QualifiedExtra-service-view])
            (check (unbox builds) => 3)
            (check (eq? state (service-decoration-state! qualified-service (lambda (_) (error "initialized twice")))) => #t)
            (check initializations => 1)
            (install #f)
            (check (eq? (service-provider qualified-service) replacement-raw) => #t)))))
    (test-case "initialization and builder failures publish no poisoned state or cache"
      (let* ((raw (new-qualified-provider))
             (provider (provider-plugin 'cache-errors qualified-service raw QualifiedExtra-service-view)))
        (call-with-fresh-kernel [provider]
          (lambda ()
            (let (failure (box 'failure))
              (check (eq? (caught (lambda ()
                                    (service-decoration-state! qualified-service
                                      (lambda (install-decoration)
                                        (install-decoration (lambda (raw description) 'unpublished))
                                        (raise failure))))) failure) => #t)
              (check (service-decoration-states) => [])
              (check (eq? (service-provider qualified-service) raw) => #t)
              (let (install (service-decoration-state! qualified-service (lambda (install-decoration) install-decoration)))
                (check (eq? (caught (lambda () (install (lambda (raw description) (raise failure))))) failure) => #t)
                (check (eq? (service-provider qualified-service) raw) => #t)
                (install #f)
                (check (service-decoration-states) => [install])))))))
    (test-case "descriptor mismatch on arrival and decoration errors propagate"
      (call-with-fresh-kernel []
        (lambda ()
          (let* ((raw (new-qualified-provider))
                 (bad (provider-plugin 'cache-bad qualified-service raw Diamond-service-view))
                 (good (provider-plugin 'cache-good qualified-service raw QualifiedExtra-service-view))
                 (install (service-decoration-state! qualified-service (lambda (install-decoration) install-decoration)))
                 (build (lambda (raw description)
                          ((service-view-build description) raw (lambda (operation base) base)))))
            (install build)
            (check (not (not (caught (lambda () (activate-plugin! bad))))) => #t)
            (check (plugin-active? bad) => #f)
            (check (service-provider qualified-service) => #f)
            (check (entry-table-entries (kernel-providers (the-kernel)) (service-name qualified-service)) => [])
            (activate-plugin! good)
            (check (QualifiedExtra-special (service-provider qualified-service)) => 7)
            (check (not (not (caught (lambda ()
                                      (install (lambda (raw description)
                                                 ((service-view-build Diamond-service-view) raw (lambda (op base) base)))))))) => #t)
            (check (QualifiedExtra-special (service-provider qualified-service)) => 7)))))
    (test-case "opaque enumeration and bound setters stay in their own kernel after switching"
      (let* ((raw-a (new-qualified-provider))
             (raw-b (new-qualified-provider))
             (provider-a (provider-plugin 'cache-a qualified-service raw-a QualifiedExtra-service-view))
             (provider-b (provider-plugin 'cache-b qualified-service raw-b QualifiedExtra-service-view)))
        (call-with-fresh-kernel [provider-a]
          (lambda ()
            (let* ((builds (box 0)) (calls (box 0)) (descriptions (box []))
                   (install-a (service-decoration-state! qualified-service (lambda (install-decoration) install-decoration)))
                   (builder (tracing-builder builds calls descriptions)) (snapshot #f))
              (call-with-fresh-kernel [provider-b]
                (lambda ()
                  (check (service-decoration-states) => [])
                  ;; Cache B in the common service object's last-kernel cell.
                  (check (eq? (service-provider qualified-service) raw-b) => #t)
                  (check (service-decoration-state! qualified-service (lambda (_) #f)) => #f)
                  (check (service-decoration-state! qualified-service (lambda (_) (error "twice"))) => #f)
                  (check (service-decoration-states) => [#f])
                  (install-a builder)
                  (check (eq? (service-provider qualified-service) raw-b) => #t)
                  (check (unbox builds) => 1)))
              (check (service-decoration-states) => [install-a])
              (set! snapshot (service-provider qualified-service))
              (check (eq? snapshot raw-a) => #f)
              (check (QualifiedBase-run snapshot) => 'base)
              (check (unbox calls) => 1)
              (check (unbox builds) => 1)
              ;; Also remove A's decoration while a fresh B is current.
              (call-with-fresh-kernel [provider-b]
                (lambda () (install-a #f) (check (eq? (service-provider qualified-service) raw-b) => #t)))
              (check (eq? (service-provider qualified-service) raw-a) => #t))))))
    (test-case "decoration preserves raw provenance, receipts, lifecycle and dependent activation"
      (let* ((raw (new-qualified-provider)) (provider-context #f)
             (provider (make-plugin 'cache-provenance "Cache provider." [] [qualified-service] []
                         (lambda (ctx)
                           (set! provider-context ctx)
                           (context-provide! ctx qualified-service raw view: QualifiedExtra-service-view)) #f))
             (events []) (starts 0) (stops 0)
             (observer (make-plugin 'cache-observer "Observe raw changes." [] [] []
                         (lambda (ctx)
                           (context-add-hook! ctx service-changed-hook 'cache-events
                             (lambda (svc old new)
                               (when (eq? svc qualified-service)
                                 (set! events (append events [[old new]])))))) #f))
             (dependent (make-plugin 'cache-dependent "Required user." [qualified-service] [] []
                          (lambda (ctx)
                            (set! starts (fx1+ starts))
                            (context-defer! ctx (lambda () (set! stops (fx1+ stops))))) #f)))
        (call-with-fresh-kernel [observer provider dependent]
          (lambda ()
            (let* ((table (kernel-providers (the-kernel)))
                   (entry (entry-table-ref table (service-name qualified-service)))
                   (value (entry-value entry)) (serial (entry-serial entry))
                   (info (describe-services))
                   (install (service-decoration-state! qualified-service (lambda (install-decoration) install-decoration))))
              (check events => [[#f raw]])
              (check (length (slot-ref provider-context 'receipt)) => 2)
              (check (eq? (slot-ref value 'raw) raw) => #t)
              (check (entry-owner entry) => 'cache-provenance)
              (check (entry-doc entry) => "Cache fixture.")
              (check (entry-source entry) => #f)
              (install (tracing-builder (box 0) (box 0) (box [])))
              (check (eq? (entry-table-ref table (service-name qualified-service)) entry) => #t)
              (check (eq? (entry-value entry) value) => #t)
              (check (entry-serial entry) => serial)
              (check (length (slot-ref provider-context 'receipt)) => 2)
              (check (describe-services) => info)
              (check (length (entry-table-entries table (service-name qualified-service))) => 1)
              (check events => [[#f raw]])
              (check [starts stops] => [1 0])
              (install #f)
              (check (length (slot-ref provider-context 'receipt)) => 2)
              (check events => [[#f raw]])
              (deactivate-plugin! provider)
              (check events => [[#f raw] [raw #f]])
              (check [starts stops] => [1 1])
              (activate-plugin! provider)
              (check events => [[#f raw] [raw #f] [#f raw]])
              (check [starts stops] => [2 1]))))))))
