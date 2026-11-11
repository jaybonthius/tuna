(library (tuna registry)
  (export make-registry registry-define!)
  (import (chezscheme) (tuna core changes) (only (tuna core modules) add-module-unloaded-handler!))

  ;; Keyed by the defined name, not the owner: the configuration and the
  ;; REPL define the same names, so either evaluating the other's form
  ;; keeps what the first made.
  (define (make-registry module-of forget!)
    (let ([registry (make-eq-hashtable)])
      (add-module-unloaded-handler!
        (lambda (name)
          (let-values ([(symbols things) (hashtable-entries registry)])
            (vector-for-each
              (lambda (symbol thing)
                (when (equal? (module-of thing) name)
                  (hashtable-delete! registry symbol)
                  (forget! thing)))
              symbols things))))
      registry))

  (define (registry-define! registry name make again)
    (let* ([module (owner-name (current-owner))] [symbol (definition-symbol module name)])
      (cond
        [(hashtable-ref registry symbol #f) => again]
        [else
         (let ([thing (make symbol module)])
           (hashtable-set! registry symbol thing)
           thing)]))))
