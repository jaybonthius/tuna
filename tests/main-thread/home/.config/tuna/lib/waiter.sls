#!tuna
(define (wait-forever)
  (spawn-task
    (lambda ()
      (guard (c [(quit-condition? c) (display "waiter's task quit") (newline)])
        (suspend (lambda (resume) (void)))))))

(define (later)
  (spawn-task (lambda () (display "never runs"))))

(define (stubborn)
  (spawn-task
    (lambda ()
      (guard (c [(quit-condition? c) #f])
        (suspend (lambda (resume) (void))))
      (on-unload void))))
