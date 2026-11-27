(import (tuna) (test) (test-runner) (timers) (jobs) (jobs-test) (jobs-test client) (jobs-test searcher))

(define notes '())

(define (note! x) (set! notes (cons x notes)))

(define (taken!) (let ([l (reverse notes)]) (set! notes '()) l))

(define (home-file name) (string-append (getenv "HOME") "/" name))

(test "a job started while a module's body runs belongs to the module"
  (test-runner:wait-until (lambda () (pair? (jobs-test/client:from-the-body))))
  (check-equal? '(started-in-the-body) (jobs-test/client:from-the-body)))

(test "a raise is reported as the owner that started the job"
  (let ([owner-of-report (lambda (thunk)
                           (let ([owner #f])
                             (let ([keep (lambda (next c) (set! owner (task-owner (current-task))))])
                               (advice-add! report keep)
                               (thunk)
                               (test-runner:wait-until (lambda () owner))
                               (advice-remove! report keep)
                               owner)))])
    (check-equal? (current-owner) (owner-of-report (lambda () (jobs-test:finished jobs-test/client:fails 1))))
    (let ([client (module-owner '(jobs-test client))])
      (check-equal? client
        (owner-of-report (lambda () (call-as-owner client (lambda () (jobs-test:finished jobs-test/client:fails 1)))))))))

(test "a job belongs to the current owner, whichever module's code starts it, so unloading that module leaves it running"
  (let ([from-here (jobs-test/client:start-waiting (lambda (ended) (note! (list 'from-here ended))))])
    (unload-owner! (module-owner '(jobs-test client)))
    (timers:sleep 0.05)
    (check-equal? '() (taken!))
    (jobs:stop! from-here)
    (test-runner:wait-until (lambda () (pair? notes)))
    (check-equal? '((from-here stopped)) (taken!))))

(define (start-searching! path)
  (call-as-owner (module-owner '(jobs-test searcher))
    (lambda () (jobs:start jobs-test/searcher:count-slowly path note! (lambda (ended) (note! (list 'ended ended)))))))

(test "unloading the owner stops its jobs, drops their values not yet run, and skips on-end"
  (let ([path (home-file "unloaded")])
    (start-searching! path)
    (test-runner:wait-until (lambda () (pair? notes)))
    (check (not (file-exists? path)))
    (unload-owner! (module-owner '(jobs-test searcher)))
    (let ([seen (length notes)])
      (test-runner:wait-until (lambda () (file-exists? path)))
      (timers:sleep 0.05)
      (check-equal? seen (length notes))
      (check (not (exists pair? notes)))))
  (taken!))

(test "so does reloading it"
  (load-module! '(jobs-test searcher))
  (let ([path (home-file "reloaded")])
    (start-searching! path)
    (test-runner:wait-until (lambda () (pair? notes)))
    (reload-modules! '((jobs-test searcher)))
    (let ([seen (length notes)])
      (test-runner:wait-until (lambda () (file-exists? path)))
      (timers:sleep 0.05)
      (check-equal? seen (length notes))
      (check (not (exists pair? notes)))))
  (taken!))

(test "a running job keeps its code when its worker's module reloads"
  (let* ([path (home-file "kept")]
         [job (jobs:start jobs-test/searcher:count-slowly path note! (lambda (ended) (note! (list 'ended ended))))])
    (test-runner:wait-until (lambda () (pair? notes)))
    (reload-modules! '((jobs-test searcher)))
    (let ([seen (length notes)])
      (test-runner:wait-until (lambda () (> (length notes) seen))))
    (check (not (file-exists? path)))
    (jobs:stop! job)
    (test-runner:wait-until (lambda () (member '(ended stopped) notes)))
    (check (file-exists? path)))
  (taken!))
