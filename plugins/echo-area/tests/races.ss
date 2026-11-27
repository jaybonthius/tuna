(import (tuna) (test))

;; A form of its own, so it loads before echo-area.
(import (echo-area-test beneath))

(import (test-user) (buffers) (document) (options) (editing) (echo-area) (echo-area-test) (test-runner)
        (rename (only (chezscheme) sleep) (sleep chez:sleep)))

(define request-quit! (test-runner:running-task-canceller))

(define log-lines echo-area-test:log-lines)

(test "reports raised on four threads at once, while the main thread shows messages, reach the log once each, in each thread's order"
  (options:set! echo-area:log-max 16384)
  (let* ([done 0] [done-mutex (make-mutex)]
         [raiser (lambda (i)
                   (lambda (restore)
                     (do ([k 0 (+ k 1)]) ((= k 250))
                       (report (condition (make-error) (make-message-condition (format "t~a-~a" i k)))))
                     (with-mutex done-mutex (set! done (+ done 1)))))]
         [reported (echo-area-test:reports-during
                     (lambda ()
                       (for-each (lambda (i) (fork-task (raiser i))) '(0 1 2 3))
                       (let loop ()
                         (unless (= done 4)
                           (echo-area:message! "Working")
                           (loop)))
                       (echo-area:message! "end")))])
    (check-equal? 1000 (length reported))
    (let ([lines (log-lines)])
      (check-equal? '(#t #t #t #t)
        (map (lambda (i)
               (let ([prefix (format "t~a-" i)])
                 (equal? (filter (lambda (l) (and (>= (string-length l) 3) (string=? (substring l 0 3) prefix))) lines)
                         (map (lambda (k) (format "t~a-~a" i k)) (iota 250)))))
             '(0 1 2 3)))
      (check-equal? '("end" "end") (list (car (last-pair lines)) (echo-area:current-message))))))

;; A quit lands up to a thousand calls after its request, and the
;; quitter's last request may come after the stress ends, so one guard
;; holds from before the quitter starts until well after it stops: a quit
;; landing between two guards would end the test. Quits land at least a
;; thousand calls apart, so none lands in the handler before it enters
;; the guard again.
(define (stress! seconds)
  (let ([until (+ (real-time) (* 1000 seconds))] [quits 0] [rounds 0] [quitting #t] [stopped #f] [forked #f])
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
            (case (mod k 5)
              [(0) (echo-area:message! "line ~a~%of two" (mod k 7))]
              [(1) (report (condition (make-warning) (make-message-condition "w")))]
              [(2) (test-user:press! "C-a")]
              [(3) (echo-area:current-message)]
              [else (echo-area:message! "same")])
            (set! rounds (+ rounds 1))
            (loop (+ k 1))))
        (set! quitting #f)
        (let spin () (unless (or stopped (> (real-time) (+ until 30000))) (spin)))
        (let settle ([n 0]) (when (< n 100000) (settle (+ n 1))))))
    (values quits rounds)))

;; A quit that lands in a key's task is reported there, not caught by the
;; stress's guard, so both count.
(test "quits landing in messages, the flush of reports, clearing by keys and the log's trimming leave both buffers well formed"
  (options:set! echo-area:log-max 50)
  (let* ([quits 0] [rounds 0]
         [reported (echo-area-test:reports-during
                     (lambda ()
                       (let-values ([(q r) (stress! 2)]) (set! quits q) (set! rounds r))
                       (test-user:settle)))])
    (check (> (+ quits (length (filter cancelled? reported))) 100))
    (check (> rounds 1000))
    (check (for-all (lambda (c) (or (cancelled? c) (warning? c))) reported)))
  (let ([shape (lambda (b) (let ([d (car (document:datums (buffers:document b)))]) (list (car d) (length (cddr d)))))])
    (check (member (shape (echo-area-test:echo-buffer)) '((echo-area:area 0) (echo-area:area 1))))
    (check-equal? 1 (cadr (shape (buffers:find "*Messages*")))))
  (check-equal? #\newline (string-ref (echo-area-test:messages) (- (string-length (echo-area-test:messages)) 1)))
  (echo-area:message! "Last")
  (echo-area:message! "Last")
  (check-equal? 50 (length (log-lines)))
  (check-equal? '("Last" "Last [2 times]") (list (echo-area:current-message) (car (last-pair (log-lines)))))
  (test-user:press! "C-a")
  (check-equal? #f (echo-area:current-message)))
