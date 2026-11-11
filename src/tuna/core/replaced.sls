(library (tuna core replaced)
  (export exit sleep fork-thread)
  (import (only (chezscheme) define define-syntax lambda let let* quote unless procedure?
                syntax-violation assertion-violation)
          (prefix (only (chezscheme) fork-thread) chez:)
          (only (tuna core changes) current-owner current-instance current-thread-state make-thread-state)
          (only (tuna core main-thread) exit))

  (define-syntax sleep
    (lambda (x)
      (syntax-violation 'sleep "withheld because it would block the main thread" x)))

  ;; Chez's child shares its parent's record until it first calls Tuna, so
  ;; it would act for whatever owner the parent has by then.
  (define (fork-thread thunk)
    (unless (procedure? thunk)
      (assertion-violation 'fork-thread "not a procedure" thunk))
    (let* ([owner (current-owner)] [instance (current-instance owner)])
      (chez:fork-thread
        (lambda ()
          (current-thread-state (make-thread-state owner instance))
          (thunk))))))
