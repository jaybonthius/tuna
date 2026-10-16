;;; Shared source/compiled proof of the public surface, with no concept router.
prelude: :gerbil/core
package: tuna/tests/support/service-advice
(import :std/interface :tuna/kernel
        (only-in :tuna/prelude advise! unadvise! advice-for advised-service-operations
                 advice-target-info-kind advice-target-info-name advice-target-info-source
                 advice-target-info-identity advice-target-info-advice advice-info-source
                 advice-info-name advice-error? open-definition install-open! redefine)
        "./contract" "./provider")
(export check-service-routes expect-equal)
(declare (separate))

(def (expect-equal (actual : :t) (expected : :t)) => :void
  (unless (equal? actual expected) (error "Service advice mismatch" actual expected)))
(def (named-callback (n : :fixnum)) => :void (record! ['old n]))

(def (check-service-routes (fresh : :procedure)) => :void
  (let ((owner #f) (raw (new-counter)) (evaluations 0)
        (old-body (open-definition step-body)) (old-callback named-callback))
    (defplugin (route-provider ctx) "Inline and real open function implementations."
      provides: [counter-service]
      (context-provide! ctx counter-service raw view: Counter-service-view))
    (defplugin (route-advisor ctx) "Advice has no required provider lifetime."
      optional: [counter-service]
      (set! owner ctx)
      ;; SERVICE remains a type; target tags do not capture that binding.
      (let ((svc (: counter-service service)) (add #f) (remove #f) (inspect #f))
        (advise! ctx (service (begin (set! evaluations (fx1+ evaluations)) svc) inline)
          'named before: named-callback)))
    (try
     (fresh [route-provider route-advisor]
       (lambda ()
         (expect-equal evaluations 1)
         (let* ((selected (advice-for (service counter-service inline)))
                (identity (advice-target-info-identity selected)))
           (expect-equal (advice-target-info-kind selected) 'service)
           (expect-equal (advice-target-info-name selected) 'advice-counter/inline)
           (expect-equal (advice-target-info-source selected) #f)
           (expect-equal (string? (advice-info-source (car (advice-target-info-advice selected)))) #t)
           (expect-equal (length (advised-service-operations)) 1)
           (reset-events!)
           (expect-equal (Counter-inline (service-provider counter-service) 2) 102)
           (expect-equal events '((old 2)))
           (set! named-callback (lambda (n) (record! ['new n])))
           (reset-events!)
           (expect-equal (Counter-inline (service-provider counter-service) 3) 103)
           (expect-equal events '((new 3)))
           (let ((add #f) (remove #f) (inspect #f))
             (unadvise! owner (service (begin (set! evaluations (fx1+ evaluations)) counter-service) inline) 'named)
             (expect-equal (advice-target-info-advice
                           (advice-for (service (begin (set! evaluations (fx1+ evaluations)) counter-service) inline))) []))
           (expect-equal evaluations 3)
           (expect-equal (eq? (service-provider counter-service) raw) #t)
           (expect-equal (eq? identity (advice-target-info-identity (advice-for (service counter-service inline)))) #t))
         (advise! owner (service counter-service step) 'service
           around: (lambda (original n)
                     (record! 'service-before)
                     (let (result (original n)) (record! 'service-after) result)))
         (advise! owner step-body 'function
           around: (lambda (original n)
                     (record! 'function-before)
                     (let (result (original n)) (record! 'function-after) result)))
         (reset-events!)
         (expect-equal (Counter-step (service-provider counter-service) 2) 2)
         (expect-equal events '(service-before function-before body function-after service-after))
         (redefine (step-body (n : :fixnum)) => :fixnum (record! 'new-body) (fx* n 2))
         (reset-events!)
         (expect-equal (Counter-step (service-provider counter-service) 3) 8)
         (expect-equal events '(service-before function-before new-body function-after service-after))
         (unadvise! owner (service counter-service step) 'service)
         (expect-equal (eq? (service-provider counter-service) raw) #t)
         (unadvise! owner step-body 'function)
         ;; Exercise checked result and representative non-scalar composition here;
         ;; the shared library's suite owns the exhaustive ten-kind proof.
         (advise! owner (service counter-service multiple) 'values
           filter-return: (lambda results (apply values (reverse results))))
         (expect-equal (call-with-values (lambda () (Counter-multiple (service-provider counter-service))) list) '("two" 1))
         (unadvise! owner (service counter-service multiple) 'values)
         (advise! owner (service counter-service inline) 'conditional before-until: (lambda (n) 7))
         (expect-equal (Counter-inline (service-provider counter-service) 4) 7)
         (unadvise! owner (service counter-service inline) 'conditional)
         (advise! owner (service counter-service inline) 'bad override: (lambda (n) 'invalid))
         (expect-equal (with-catch (lambda (_) 'checked)
                        (lambda () (Counter-inline (service-provider counter-service) 0) 'unchecked)) 'checked)
         (unadvise! owner (service counter-service inline) 'bad)
         (expect-equal (eq? (service-provider counter-service) raw) #t)
         (advise! owner (service counter-service inline) 'cleanup before: named-callback)))
     (finally
      (install-open! step-body old-body)
      (set! named-callback old-callback)))))
