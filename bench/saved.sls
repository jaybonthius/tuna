#!tuna
;; The writer thread shares the one CPU the bench is pinned to, so wall
;; time would charge its work to the main thread; the main thread's own
;; CPU time is what a command waits for.
(define (thread-ns)
  (let ([t (current-time 'time-thread)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (median xs)
  (list-ref (list-sort < xs) (quotient (length xs) 2)))

(define (ns-per-op batch thunk)
  (median
    (map (lambda (k)
           (collect-rendezvous)
           (let ([start (thread-ns)])
             (do ([i 0 (fx+ i 1)]) ((fx= i batch)) (thunk))
             (/ (- (thread-ns) start) (exact->inexact batch))))
         (iota 9))))

(define (show name value)
  (printf "~a ~,2f\n" name value))

(define-saved ring '() list?)
(define-saved history '() list?)

;; The core writes saved data in a task posted after the code that set
;; it, so joining a task spawned after the set includes the writing.
(define (save-cost datum make-value)
  (ns-per-op 20
    (lambda ()
      (set-saved! datum (make-value))
      (join-task (spawn-task void)))))

(define (run)
  (let ([entries (map (lambda (i)
                        (list (string->immutable-string
                                (make-string 4096 (integer->char (fx+ 97 (fxmod i 26)))))))
                      (iota 119))])
    (show "saved-ring-4096"
      (save-cost ring (lambda () (cons (list (string->immutable-string (make-string 4096 #\z))) entries)))))
  (let ([entries (map (lambda (i) (string->immutable-string (format "a line of history number ~a" i)))
                      (iota 10000))])
    (show "saved-history-10000" (save-cost history (lambda () entries))))
  (remove-saved! ring)
  (remove-saved! history))
