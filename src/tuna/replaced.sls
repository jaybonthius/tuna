(library (tuna replaced)
  (export exit dynamic-wind with-mutex condition-wait sleep register-signal-handler
          fork-thread set-timer timer-interrupt-handler make-engine with-interrupts-disabled
          critical-section disable-interrupts enable-interrupts $primitive generate-interrupt-trap
          library-search-handler collect-request-handler keyboard-interrupt-handler)
  (import (only (chezscheme) define define-syntax syntax-rules _ ... lambda let quote syntax-violation case-lambda)
          (prefix (only (chezscheme) mutex-acquire mutex-release) chez:)
          (rename (only (tuna kernel) exit tuna-dynamic-wind tuna-condition-wait tuna-sleep
                        tuna-register-signal-handler)
                  (tuna-dynamic-wind dynamic-wind*)
                  (tuna-condition-wait condition-wait)
                  (tuna-sleep sleep)
                  (tuna-register-signal-handler register-signal-handler)))

  (define-syntax define-withheld
    (syntax-rules ()
      [(_ name reason)
       (define-syntax name
         (lambda (x) (syntax-violation 'name reason x)))]))

  (define-withheld fork-thread "withheld because a thread is a task of its owner; use fork-task")
  (define-withheld set-timer "withheld because each thread's timer delivers cancels and stops")
  (define-withheld timer-interrupt-handler "withheld because each thread's timer delivers cancels and stops")
  (define-withheld make-engine "withheld because each thread's timer delivers cancels and stops")
  (define-withheld with-interrupts-disabled "withheld because nothing could stop the code inside; use call-with-cancellation-masked")
  (define-withheld critical-section "withheld because nothing could stop the code inside; use call-with-cancellation-masked")
  (define-withheld disable-interrupts "withheld because nothing could stop the code inside; use call-with-cancellation-masked")
  (define-withheld enable-interrupts "withheld because nothing could stop the code inside; use call-with-cancellation-masked")
  (define-withheld $primitive "withheld because a primitive reached this way escapes the names Tuna replaces")
  (define-withheld generate-interrupt-trap "withheld because code compiled without traps could not be stopped")
  (define-withheld library-search-handler "withheld because the kernel resolves modules; set library-directories")
  ;; Both handlers run in whichever task holds the thread when the interrupt
  ;; comes, so a raise from one lands in code that never asked for it.
  (define-withheld collect-request-handler "withheld because it runs in whichever task the collection interrupts")
  (define-withheld keyboard-interrupt-handler "withheld because it runs in whichever task the interrupt lands in")

  (define dynamic-wind
    (case-lambda
      [(in body out) (dynamic-wind* in body out)]
      [(critical? in body out) (dynamic-wind* in body out)]))

  (define-syntax with-mutex
    (syntax-rules ()
      [(_ m-expr e1 e2 ...)
       (let ([m m-expr])
         (dynamic-wind*
           (lambda () (chez:mutex-acquire m))
           (lambda () e1 e2 ...)
           (lambda () (chez:mutex-release m))))])))
