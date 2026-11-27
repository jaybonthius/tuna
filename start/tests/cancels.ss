(import (tuna) (test) (plugins) (fixtures))

;; Each try asks for a second cancel while the first is reported, after a
;; random number of calls, so that it lands anywhere in the report and in
;; what follows it.
(define asked? #f)
(define (burn n) (if (fx= n 0) 0 (fx+ 1 (burn (fx- n 1)))))
(define (take-cancel) (guard (c [(cancelled? c) #f]) (burn 3000)))
(define (pauses?) (guard (c [#t #f]) (suspend (lambda (resume) (resume (lambda () #t))))))
(define runaway '((define (f) 2) (cancel-task (current-task)) (let loop () (loop))))

(test "a cancel while a module's failed first load is reported never leaves the module's body counted as running"
  (define (cancel-again report c)
    (cond
      [(not (cancelled? c)) (report c)]
      [(not asked?)
       (set! asked? #t)
       (cancel-task (current-task))
       (guard (q [(cancelled? q) #f]) (burn (random 1500)))]))
  (define left-running 0)
  (define (try)
    (set! asked? #f)
    (guard (c [(cancelled? c) #f])
      (call/cc
        (lambda (k)
          (with-exception-handler
            (lambda (c) (report c) (k #f))
            (lambda () (load-module! '(looper)))))))
    (take-cancel)
    (unless (pauses?) (set! left-running (+ left-running 1))))
  (fixtures:write-lib-module! '(looper) runaway)
  (advice-add! report cancel-again)
  (do ([i 0 (+ i 1)]) ((= i 2000))
    (guard (c [(cancelled? c) #f]) (try)))
  (advice-remove! report cancel-again)
  (check-equal? 0 left-running))

(test "a cancel while a failed reload is reported never leaves the new version half loaded"
  (define (cancel-again report c)
    (cond
      [(not (cancelled? c)) (report c)]
      [(not asked?)
       (set! asked? #t)
       (burn (random 1000))
       (cancel-task (current-task))]))
  (define half-loaded 0)
  (define (try)
    (set! asked? #f)
    (guard (c [(cancelled? c) #t])
      (if (module-owner '(looper)) (reload-modules! '((looper))) (load-module! '(looper)))
      #f)
    (take-cancel)
    (case (guard (c [(cancelled? c) 'cancelled] [#t 'unloaded]) (plugins:eval-form '(looper:f)))
      [(1 cancelled) #t]
      [(unloaded)
       (fixtures:write-lib-module! '(looper) '((define (f) 1)))
       (load-module! '(looper))
       (fixtures:write-lib-module! '(looper) runaway)
       #t]
      [else #f]))
  (fixtures:write-lib-module! '(looper) '((define (f) 1)))
  (load-module! '(looper))
  (advice-add! report cancel-again)
  (fixtures:write-lib-module! '(looper) runaway)
  (do ([i 0 (+ i 1)]) ((= i 2000))
    (unless (guard (c [(cancelled? c) #t]) (try))
      (set! half-loaded (+ half-loaded 1))))
  (advice-remove! report cancel-again)
  (check-equal? 0 half-loaded))
