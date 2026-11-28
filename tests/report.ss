(import (tuna) (test) (test-runner) (only (tuna kernel) call-reporting))

;; Chez finds a module stale when its source is newer than its object, and
;; file times step with the kernel's clock tick, 1 to 10 ms, so a rewrite
;; in the tick of the last compile would look unchanged.
(define (next-file-tick)
  (suspend (lambda (resume) (fork-task (lambda (restore) (sleep (make-time 'time-duration 10000000 0)) (resume void))))))

(define (write-module! name text)
  (next-file-tick)
  (call-with-output-file (string-append (getenv "HOME") "/.config/tuna/lib/" name ".sls")
    (lambda (p) (put-string p text))
    'replace))

;; Each report is kept with the owner its advice ran as and the owner of
;; the task it was reported in.
(define (reports-during expected thunk)
  (let* ([reported '()]
         [keep (lambda (next c)
                 (set! reported (cons (list c (current-owner) (task-owner (current-task))) reported)))])
    (advice-add! report keep)
    (thunk)
    (test-runner:wait-until (lambda () (>= (length reported) expected)))
    (advice-remove! report keep)
    (reverse reported)))

(define (loads-during thunk)
  (let* ([loaded '()] [note (lambda (next instance) (set! loaded (cons (owner-name instance) loaded)) (next instance))])
    (advice-add! module-loaded note)
    (thunk)
    (advice-remove! module-loaded note)
    (reverse loaded)))

(test "advice on report sees each report, and runs as the advice's own owner"
  (let ([reported (reports-during 1 (lambda () (join-task (spawn-task (lambda (restore) (car 1))))))])
    (check-equal? 1 (length reported))
    (check (assertion-violation? (car (car reported))))
    (check-equal? (current-owner) (cadr (car reported)))))

(test "a report is made in a task of the module the raising code ran for"
  (load-module! '(report good))
  (let* ([good (module-owner '(report good))]
         [reported (reports-during 1
                     (lambda ()
                       (join-task (call-as-owner good (lambda () (spawn-task (lambda (restore) (car '()))))))))])
    (check-equal? 1 (length reported))
    (check-equal? good (caddr (car reported)))))

(test "a raise in report's advice loses no condition: both are written"
  (let ([written (open-output-string)] [raising (lambda (next c) (car '()))])
    (advice-add! report raising)
    (parameterize ([console-error-port written])
      (call-reporting (lambda () (vector-ref (vector) 0))))
    (advice-remove! report raising)
    (check-equal? 2 (length (filter (lambda (c) (char=? c #\newline)) (string->list (get-output-string written)))))))

(test "a module's body runs when it is imported, its imports first, whether or not the importer names them"
  (check-equal? '((report a) (report b)) (loads-during (lambda () (load-module! '(report b)))))
  (check-equal? '((report c) (report unused)) (loads-during (lambda () (load-module! '(report unused))))))

(test "a module whose body raises does not load, nor does its importer"
  (check-equal? '()
    (loads-during
      (lambda ()
        (check-raises assertion-violation? (load-module! '(report dict)))
        (check-raises assertion-violation? (load-module! '(report uses-dict))))))
  ;; The failed body's unload ends between tasks, after the raise.
  (test-runner:wait-until (lambda () (not (module-owner '(report dict))))))

(test "after a reload whose body raises, the previous version loads again"
  (check-equal? '((report good))
    (loads-during
      (lambda ()
        (write-module! "report/good" "#!tuna\n(define (hello) 1)\n(error 'good \"broken\")\n")
        (check-raises error? (reload-modules! '((report good)))))))
  (check-equal? "hello" ((eval 'report/good:hello (interaction-environment)))))

(test "after a reload that fails to compile, the previous version loads again"
  (check-equal? '((report good))
    (loads-during
      (lambda ()
        (write-module! "report/good" "#!tuna\n(define (hello) (let ((y)) y))\n")
        (check-raises syntax-violation? (reload-modules! '((report good)))))))
  (write-module! "report/good" "#!tuna\n(define (hello) \"hello\")\n"))

(test "report-owner names the owner a report names, which advice on report cannot learn from current-owner"
  (check-equal? #f (report-owner))
  (load-module! '(report good))
  (let* ([seen '()] [note (lambda (next c) (set! seen (cons (list (report-owner) (current-owner)) seen)))]
         [good (module-owner '(report good))])
    (advice-add! report note)
    (join-task (call-as-owner good (lambda () (spawn-task (lambda (restore) (call-reporting (lambda () (car '()))))))))
    (call-reporting (lambda () (load-module! '(report dict))))
    (advice-remove! report note)
    (check-equal? (list (list good (current-owner))) (list (cadr seen)))
    (check-equal? '(report dict) (owner-name (car (car seen))))
    (check-equal? (current-owner) (cadr (car seen)))))

(test "a task a cancel ends is not reported, on the main thread or on another"
  (let ([reported (reports-during 0
                    (lambda ()
                      (let ([t (spawn-task (lambda (restore) (suspend (lambda (resume) (void)))))])
                        (join-task (spawn-task (lambda (restore) #t)))
                        (cancel-task t 'main)
                        (check-equal? 'cancelled (call-with-values (lambda () (join-task t)) (lambda (how detail) how))))
                      (let ([t (fork-task (lambda (restore) (let spin () (spin))))])
                        (cancel-task t 'thread)
                        (check-equal? 'cancelled (call-with-values (lambda () (join-task t)) (lambda (how detail) how))))
                      (join-task (spawn-task (lambda (restore) #t)))))])
    (check-equal? '() reported)))
