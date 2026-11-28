(import (tuna) (test) (test-runner) (jobs) (timers) (hooks) (sampler) (sampler-test idle))

(jobs:define-worker (counting input emit receive)
  (import (timeseries))
  (let loop ([n 0])
    (receive)
    (when (positive? (cdr input))
      (sleep (make-time 'time-duration (exact (round (* (cdr input) 1e9))) 0)))
    (emit (cons (timeseries-now) (list (car input) n)))
    (loop (+ n 1))))

(define starts 0)
(define delay 0)
(define readings '())

(define (next-input)
  (set! starts (+ starts 1))
  (cons starts delay))

(define (note-reading time data)
  (set! readings (cons (cons time data) readings)))

(sampler:define-source counter counting next-input note-reading)

(define sampled '())
(define (note-sampled source time) (set! sampled (cons (cons source time) sampled)))
(hooks:add! sampler:sampled note-sampled)

(define (reset!)
  (set! readings '())
  (set! sampled '()))

(define (wait-for-readings n)
  (test-runner:wait-until (lambda () (>= (length readings) n))))

(define (remove-duplicates items)
  (fold-right (lambda (x kept) (if (member x kept) kept (cons x kept))) '() items))

(define (with-owner name thunk)
  (let ([o (make-owner name)])
    (call-as-owner o thunk)
    o))

(test "a source nobody wants has no interval, reads nothing and holds no timer"
  (check-equal? #f (sampler:interval counter))
  (check-equal? '() (sampler:wants counter))
  (check-equal? #f (sampler:last-time counter))
  (check-equal? 0 starts)
  (check (memq counter (sampler:all))))

(test "a want of 1 s reads at once, then about each second; sampled runs once per reading with a flonum time"
  (reset!)
  (let* ([timers-before (length (timers:live))]
         [viewer (with-owner '(viewer every-second) (lambda () (sampler:want counter 1)))])
    (wait-for-readings 1)
    (check-equal? 1 (sampler:interval counter))
    (check-equal? (+ timers-before 1) (length (timers:live)))
    (timers:sleep 2.5)
    (check (<= 3 (length readings) 4))
    (check-equal? (length readings) (length sampled))
    (check (for-all (lambda (r) (flonum? (car r))) readings))
    (check-equal? (sampler:last-time counter) (car (car readings)))
    (check (for-all (lambda (s) (eq? (car s) counter)) sampled))
    (unload-owner! viewer)
    (check-equal? #f (sampler:interval counter))
    (check-equal? timers-before (length (timers:live)))))

(test "two owners share one job at the shorter interval, and each reading reaches on-sample once"
  (reset!)
  (let* ([starts-before starts]
         [fast (with-owner '(viewer fast) (lambda () (sampler:want counter 1)))]
         [slow (with-owner '(viewer slow) (lambda () (sampler:want counter 5)))])
    (check-equal? 1 (sampler:interval counter))
    (check-equal? (list (cons fast 1) (cons slow 5)) (sampler:wants counter))
    (timers:sleep 2.5)
    (check-equal? (+ starts-before 1) starts)
    (check (<= 3 (length readings) 4))
    (check (apply = (map cadr readings)))
    (test "when the faster owner unloads, the interval lengthens with no new job; the last unload stops both"
      (unload-owner! fast)
      (check-equal? 5 (sampler:interval counter))
      (let ([count (length readings)])
        (timers:sleep 2)
        (check-equal? count (length readings)))
      (check-equal? (+ starts-before 1) starts)
      (unload-owner! slow)
      (check-equal? #f (sampler:interval counter))
      (check-equal? '() (sampler:wants counter)))))

(test "a reading longer than the interval makes the ticks in between skip; readings never queue"
  (reset!)
  (set! delay 0.8)
  (let ([viewer (with-owner '(viewer slow-reads) (lambda () (sampler:want counter 0.25)))])
    (timers:sleep 3)
    (unload-owner! viewer)
    (let ([times (reverse (map car readings))])
      (check (<= 2 (length times) 5))
      (check (let loop ([times times])
               (or (null? (cdr times)) (and (>= (- (cadr times) (car times)) 0.7) (loop (cdr times))))))
      (check-equal? (length readings) (length sampled))))
  (set! delay 0))

(test "read-now! reads at once and leaves the timer's rhythm; with no want it raises"
  (reset!)
  (let ([viewer (with-owner '(viewer hourly) (lambda () (sampler:want counter 3600)))])
    (wait-for-readings 1)
    (sampler:read-now! counter)
    (wait-for-readings 2)
    (check-equal? '(1 0) (map caddr readings))
    (unload-owner! viewer))
  (check-raises assertion-violation? (sampler:read-now! counter)))

(test "a want must be a finite positive number of seconds; half a second is one"
  (reset!)
  (let ([o (make-owner '(viewer half))])
    (call-as-owner o
      (lambda ()
        (check-raises assertion-violation? (sampler:want counter 0))
        (check-raises assertion-violation? (sampler:want counter +nan.0))
        (check-raises assertion-violation? (sampler:want counter +inf.0))
        (check-raises assertion-violation? (sampler:want 'counter 1))
        (sampler:want counter 0.5)))
    (timers:sleep 1.3)
    (unload-owner! o)
    (let ([times (map car readings)])
      (check (>= (length times) 3))
      (check-equal? (length times) (length (remove-duplicates times))))))

(test "an owner with no want takes nothing back by unwant; wants lists each owner's"
  (let ([o (make-owner '(viewer none))] [p (make-owner '(viewer some))])
    (call-as-owner p (lambda () (sampler:want counter 30)))
    (call-as-owner o (lambda () (sampler:unwant counter)))
    (check-equal? (list (cons p 30)) (sampler:wants counter))
    (call-as-owner p (lambda () (sampler:want counter 20)))
    (check-equal? (list (cons p 20)) (sampler:wants counter))
    (call-as-owner p (lambda () (sampler:unwant counter)))
    (check-equal? '() (sampler:wants counter))
    (unload-owner! o)
    (unload-owner! p)))

(test "sources are offered, checked and shown by name"
  (check (sampler:source? counter))
  (check (not (sampler:source? 'counter)))
  (check-raises assertion-violation? (sampler:interval 'counter))
  (check-raises assertion-violation? (let () (sampler:define-source broken 'worker next-input note-reading) broken))
  (check-equal? "#<source (test-file sampler sampler) counter>" (format "~s" counter)))

(define idle sampler-test/idle:idle)

(test "a source whose module unloads leaves the list of sources, and a want of it raises"
  (check (memq idle (sampler:all)))
  (unload-owner! (module-owner '(sampler-test idle)))
  (check-equal? #f (memq idle (sampler:all)))
  (check-raises assertion-violation? (sampler:want idle 1)))

(load-module! '(sampler-test idle))

(test "when the module loads again the source is the same, listed and wanted again"
  (check (eq? idle sampler-test/idle:idle))
  (check (memq idle (sampler:all)))
  (sampler:want idle 3600)
  (check-equal? 3600 (sampler:interval idle))
  (sampler:unwant idle))
