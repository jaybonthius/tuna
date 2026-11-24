#!tuna
;; A limit long enough for a loaded machine costs a passing test nothing;
;; at the limit the wait raises, so a condition that never holds fails its
;; test instead of letting it go on without what it waited for.
(define (wait-until done?)
  (let loop ([n 0])
    (cond
      [(done?) (void)]
      [(= n 3000) (error 'testing:wait-until "timed out")]
      [else (sleep-for 0.01) (loop (+ n 1))])))
