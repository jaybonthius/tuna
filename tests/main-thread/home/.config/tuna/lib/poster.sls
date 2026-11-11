#!tuna
(define go (box #f))
(define posted (box #f))
;; The thread outlives the instance, whose definitions then raise.
(let ([go go] [posted posted])
  (fork-thread
    (lambda ()
      (let loop () (unless (unbox go) (loop)))
      (post! (lambda () (display "poster's thread posted\n")))
      (set-box! posted #t))))
