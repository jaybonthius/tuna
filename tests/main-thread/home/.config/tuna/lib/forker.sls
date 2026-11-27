#!tuna
(define go (box #f))
(define posted (box #f))
(fork-task (lambda (restore) (let loop () (unless (unbox go) (loop)))
    (spawn-task (lambda (restore) (on-unload (lambda () (display "forker's unload action\n")))))
    (set-box! posted #t)))
