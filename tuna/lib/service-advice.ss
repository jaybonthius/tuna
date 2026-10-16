;;; Service-slot policy; the kernel owns only raw providers and decoration caches.
prelude: :gerbil/core

(import :std/list/list
        (only-in :gerbil/runtime/hash HashTable)
        :tuna/kernel :tuna/lib/advice)
(export add-service-advice! remove-service-advice! service-operation-advice
        advised-service-operations)

(defstruct service-advice ((definition : service) (install! : :procedure)
                          (operations : HashTable))
  final: #t)

(def (operation-name (svc : service) (operation : :symbol)) => :symbol
  (string->symbol (string-append (symbol->string (service-name svc)) "/"
                                (symbol->string operation))))

(def (find-service-advice (svc : service)) => (Maybe service-advice)
  (find (lambda (state)
          (and (service-advice? state)
               (eq? (service-name (service-advice-definition state)) (service-name svc))))
        (service-decoration-states)))

(def (build-advised-service (state : service-advice) (raw : :t)
                            (description : service-view)) => :t
  ;; A registration can lack every pending operation. Preserve exact raw identity.
  (if (ormap (lambda (operation)
               (let (target (hash-get state.operations operation))
                 (and target (pair? (advice-state-records target)))))
             (service-view-operations description))
    ((service-view-build description) raw
      (lambda ((operation : :symbol) (base : :procedure)) => :procedure
        ;; Qualified interface paths supply distinct bases for the same operation.
        (let (target (hash-get state.operations operation))
          (if target (compose-advice base (advice-state-records target)) base))))
    raw))

(def (refresh-service-advice! (state : service-advice)) => :void
  ((service-advice-install! state)
   (and (ormap (lambda ((target : advice-state)) (pair? (advice-state-records target)))
               (hash-values state.operations))
        (lambda ((raw : :t) (description : service-view)) => :t
          (build-advised-service state raw description)))))

(def (prune-operation! (state : service-advice) (operation : :symbol)
                       (target : advice-state)) => :void
  ;; Callback-free owner buckets still own receipt notes. Reuse them until cleanup.
  (unless (advice-state-has-owners? target)
    (hash-remove! state.operations operation)))

(def (ensure-operation! (svc : service) (operation : :symbol)) => advice-state
  (using (state (service-decoration-state! svc
                  (lambda ((install! : :procedure)) => service-advice
                    (make-service-advice svc install! (make-hash-table))))
                : service-advice)
    (or (hash-get state.operations operation)
        (letrec ((target
                  (new-advice-state 'service (operation-name svc operation) #f
                    (lambda (records)
                      (prune-operation! state operation target)
                      (refresh-service-advice! state)))))
          (hash-put! state.operations operation target)
          target))))

(def (add-service-advice! (ctx : context) (svc : service) (operation : :symbol)
                          (name : :symbol) (kind : :symbol) (callback : :procedure)
                          depth: (depth : :fixnum := 0)
                          source: (source :? :string := #f)) => :void
  (let (target (ensure-operation! svc operation))
    (with-catch
     (lambda (e)
       (prune-operation! (: (find-service-advice svc) service-advice) operation target)
       (raise e))
     (lambda () (register-advice! ctx target name kind callback depth: depth source: source)))))

(def (remove-service-advice! (ctx : context) (svc : service) (operation : :symbol)
                             (name : :symbol)) => :void
  (let* ((state (find-service-advice svc))
         (target (and state (hash-get (service-advice-operations state) operation))))
    (when target (remove-advice! ctx target name))))

(def (service-operation-advice (svc : service) (operation : :symbol)) => advice-target-info
  (let* ((state (find-service-advice svc))
         (target (and state (hash-get (service-advice-operations state) operation))))
    (inspect-advice (or target (new-advice-state 'service (operation-name svc operation) #f void)))))

(def (advised-service-operations) => :list
  (:- (append-map
       (lambda (state)
         (if (service-advice? state)
           (filter-map (lambda ((target : advice-state))
                         (and (pair? (advice-state-records target)) (inspect-advice target)))
                       (hash-values (service-advice-operations state)))
           []))
       (service-decoration-states)) :list))
