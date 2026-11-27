#!tuna
;; Kept on the property list, which outlives the module's instances.
(define (note! x) (putprop 'main-thread 'log (cons x (getprop 'main-thread 'log '()))))

(define (wait-forever)
  (spawn-task (lambda (restore) (guard (c [(cancelled? c) (note! 'handler-ran)]) (suspend (lambda (resume) (void)))))))

(define (later x) (spawn-task (lambda (restore) (note! x))))
