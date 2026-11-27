#!tuna
(define (wait-forever)
  (spawn-task (lambda (restore) (guard (c [(cancelled? c) (display "waiter's task quit") (newline)])
        (suspend (lambda (resume) (void)))))))

(define (later)
  (spawn-task (lambda (restore) (display "never runs"))))

(define (stubborn)
  (spawn-task (lambda (restore) (guard (c [(cancelled? c) #f])
        (suspend (lambda (resume) (void))))
      (on-unload void))))
