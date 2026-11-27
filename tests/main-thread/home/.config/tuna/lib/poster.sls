#!tuna
(define go (box #f))
(define posted (box #f))
(let ([go go] [posted posted])
  (fork-task (lambda (restore) (let loop () (unless (unbox go) (loop)))
      (spawn-task (lambda (restore) (display "poster's thread posted\n")))
      (set-box! posted #t))))
