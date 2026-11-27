(import (tuna) (test) (test-runner) (jobs) (buffers) (document) (buffers-test)
        (rename (only (chezscheme) sleep) (sleep chez:sleep)))

(define request-quit! (test-runner:running-task-canceller))

(jobs:define-worker (summarize version emit)
  (import (document))
  (let ([doc (cdr version)])
    (emit (list (car version) (document:length doc) (document:line doc (document:length doc)) (document:text doc 0 40)))))

(define (summary b)
  (let ([doc (buffers:document b)])
    (list (buffers:version b) (document:length doc) (document:line doc (document:length doc)) (document:text doc 0 40))))

(define lines (buffers-test:fresh (string-append (make-string 50000 #\a) "\n")))

(test "jobs read versions of a buffer while the main thread goes on editing it, and each answer is the main thread's for its version"
  (let ([answers '()])
    (let ([expected
           (let loop ([k 0] [acc '()])
             (if (= k 60)
                 acc
                 (begin
                   (jobs:start summarize (cons (buffers:version lines) (buffers:document lines))
                     (lambda (a) (set! answers (cons a answers))))
                   (let ([now (summary lines)])
                     (buffers:replace! lines (+ 1 (* k 7)) (+ 3 (* k 7)) (if (even? k) "\n\n\n" "λ"))
                     (loop (+ k 1) (cons now acc))))))])
      (test-runner:wait-until (lambda () (= (length answers) 60)))
      (check-equal? (reverse expected) (list-sort (lambda (a b) (< (car a) (car b))) answers)))))

(test "only the main thread changes a buffer, walks its log or finds its stops"
  (check-equal? (map (lambda (who) (list who "not on the main thread"))
                     '(buffers:replace! buffers:edits-since buffers:map-position buffers:stop buffers:next-stop buffers:previous-stop
                       buffers:document buffers:piece buffers:anchor))
    (map buffers-test:on-thread
         (list (lambda () (buffers:replace! lines 1 1 "x"))
               (lambda () (buffers:edits-since lines 0))
               (lambda () (buffers:map-position lines 1 0))
               (lambda () (buffers:stop lines 1))
               (lambda () (buffers:next-stop lines 1))
               (lambda () (buffers:previous-stop lines 2))
               (lambda () (buffers:document lines))
               (lambda () (buffers:piece lines 1 2))
               (lambda () (buffers:anchor lines 1)))))
  (check-equal? (list (buffers:name lines) (buffers:version lines))
    (let ([read #f])
      (join-task (fork-task (lambda (restore) (set! read (list (buffers:name lines) (buffers:version lines))))))
      read)))

(buffers:define-layer marks (sticky after))
(buffers:define-layer carried (travels) (sticky after))

;; A quit lands up to a thousand calls after its request, and the
;; quitter's last request may come after the stress ends, so one guard
;; holds from before the quitter starts until well after it stops: a quit
;; landing between two guards would end the test. Quits land at least a
;; thousand calls apart, so none lands in the handler before it enters
;; the guard again.
(define (stress! b watched seconds)
  (let ([until (+ (real-time) (* 1000 seconds))] [quits 0] [quitting #t] [stopped #f] [forked #f])
    (let again ()
      (guard (c [(cancelled? c) (set! quits (+ quits 1)) (again)])
        (unless forked
          (set! forked #t)
          (fork-task
            (lambda (restore)
              (let loop ()
                (if quitting
                    (begin
                      (request-quit!)
                      (chez:sleep (make-time 'time-duration 1000000 0))
                      (loop))
                    (set! stopped #t))))))
        (let loop ([k 0])
          (when (< (real-time) until)
            (let* ([size (document:length (buffers:document b))] [p (+ 1 (mod (* k 7919) (- size 2)))])
              (case (mod k 5)
                [(0) (buffers:replace! b p p "xy")]
                [(1) (buffers:replace! b p (min (- size 1) (+ p 3)) "")]
                [(2) (buffers:add-span! (buffers:layer b marks) p (min (- size 1) (+ p 4)) k)]
                [(3) (buffers:add-span! (buffers:layer b carried) p (min (- size 1) (+ p 2)) (mod k 3))]
                [else (buffers:anchor-position watched) (buffers:document b)]))
            (loop (+ k 1))))
        (set! quitting #f)
        (let spin () (unless (or stopped (> (real-time) (+ until 30000))) (spin)))
        (let settle ([n 0]) (when (< n 100000) (settle (+ n 1))))))
    quits))

(test "quits landing in edits, span changes, anchor reads and freezes leave the buffer whole"
  (let* ([b (buffers-test:fresh (string-append (make-string 2000 #\a) "\n"))]
         [first-document (buffers:document b)]
         [watched (buffers:anchor b 1000)]
         [quiet (lambda (next c) (unless (cancelled? c) (next c)))])
    (advice-add! report quiet)
    (check (> (stress! b watched 2) 100))
    (advice-remove! report quiet)
    (let ([log (buffers:edits-since b 0)])
      (check-equal? (buffers:version b) (length log))
      (check-equal? (document:datums (buffers:document b))
        (document:datums
          (fold-left
            (lambda (doc e)
              (let* ([start (buffers:edit-start e)] [end (+ start (buffers:piece-length (buffers:edit-removed e)))])
                (check-equal? (document:datums (buffers:piece-document (buffers:edit-removed e))) (document:datums (document:slice doc start end)))
                (document:replace doc start end (buffers:piece-document (buffers:edit-inserted e)))))
            first-document log))))
    (let ([size (document:length (buffers:document b))])
      (check (for-all (lambda (l) (for-all (lambda (s) (<= 0 (car s) (cadr s) size)) (buffers:spans l 0 size))) (buffers:layers b))))
    (check-equal? (buffers:map-position b 1000 0) (buffers:anchor-position watched))))
