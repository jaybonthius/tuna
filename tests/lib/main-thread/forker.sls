#!tuna
(define go (box #f))
(define posted (box #f))
(fork-task
  (lambda (restore)
    (let loop () (unless (unbox go) (loop)))
    (spawn-task (lambda (restore) (on-unload void)))
    (set-box! posted #t)))
