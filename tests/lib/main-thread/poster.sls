#!tuna
(define go (box #f))
(define posted (box #f))
(define ran (box #f))
(fork-task
  (lambda (restore)
    (let loop () (unless (unbox go) (loop)))
    (spawn-task (lambda (restore) (set-box! ran #t)))
    (set-box! posted #t)))
