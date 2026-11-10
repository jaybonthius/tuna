#!tuna
(define go (box #f))
(define posted (box #f))
(fork-thread
  (lambda ()
    (let loop () (unless (unbox go) (loop)))
    (post! (lambda () (on-unload (lambda () (display "forker's unload action\n")))))
    (set-box! posted #t)))
