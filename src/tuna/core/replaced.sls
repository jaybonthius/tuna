(library (tuna core replaced)
  (export exit fork-thread dynamic-wind with-mutex sleep set-timer timer-interrupt-handler make-engine)
  (import (only (chezscheme) define define-syntax syntax-rules _ ... lambda let let* set! quote unless if or
                not case-lambda procedure? syntax-violation assertion-violation)
          (prefix (only (chezscheme) fork-thread dynamic-wind mutex-acquire mutex-release) chez:)
          (only (tuna core changes) current-owner-record current-instance current-thread-state make-thread-state
                this-thread-state on-main-thread? thread-state-quits-allowed thread-state-quits-allowed-set!)
          (only (tuna core main-thread) exit))

  (define-syntax define-withheld
    (syntax-rules ()
      [(_ name reason)
       (define-syntax name
         (lambda (x) (syntax-violation 'name reason x)))]))

  (define-withheld sleep "withheld because it would block the main thread")
  (define-withheld set-timer "withheld because the main thread's timer delivers quits and tick")
  (define-withheld timer-interrupt-handler "withheld because the main thread's timer delivers quits and tick")
  (define-withheld make-engine "withheld because the main thread's timer delivers quits and tick")

  ;; A thread forked by Chez acts for no module, since nothing tells it
  ;; which module's code forked it.
  (define (fork-thread thunk)
    (unless (procedure? thunk)
      (assertion-violation 'fork-thread "not a procedure" thunk))
    (let* ([owner (current-owner-record)] [instance (current-instance owner)])
      (chez:fork-thread
        (lambda ()
          (current-thread-state (make-thread-state owner instance))
          (thunk)))))

  ;; Chez's dynamic-wind forgets the body's winder before it calls out, so
  ;; a quit landing as out starts would skip it. The flag changes only in
  ;; critical winds, which a quit cannot split, while in and out run with
  ;; interrupts on, so they may wait for a mutex or let a collection run.
  (define (main-thread-wind in body out)
    (let ([s (this-thread-state)] [other #f])
      (define (swap!)
        (let ([v (thread-state-quits-allowed s)])
          (thread-state-quits-allowed-set! s other)
          (set! other v)))
      (chez:dynamic-wind #t swap!
        (lambda () (chez:dynamic-wind in (lambda () (chez:dynamic-wind #t swap! body swap!)) out))
        swap!)))

  (define dynamic-wind
    (case-lambda
      [(in body out)
       (if (on-main-thread?)
           (main-thread-wind in body out)
           (chez:dynamic-wind in body out))]
      [(critical? in body out)
       (if (or critical? (not (on-main-thread?)))
           (chez:dynamic-wind critical? in body out)
           (main-thread-wind in body out))]))

  (define-syntax with-mutex
    (syntax-rules ()
      [(_ m-expr e1 e2 ...)
       (let ([m m-expr])
         (dynamic-wind
           (lambda () (chez:mutex-acquire m))
           (lambda () e1 e2 ...)
           (lambda () (chez:mutex-release m))))])))
