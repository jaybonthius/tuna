(import (tuna) (test) (test-user) (layout) (layout-split) (views) (buffers) (commands) (tables)
        (status-line) (status-line-test) (quits)
        (rename (only (chezscheme) sleep) (sleep chez:sleep)))

(define view status-line-test:view)

(define notes (buffers:make "notes" "one\ntwo\n"))
(views:set-buffer! (view) notes)

(define other (test-user:open-client))

(status-line:define-segment seg-a (show (lambda (v) "a")))

(define (step! k)
  (case (mod k 6)
    [(0) (layout:screen (test-user:client)) (layout:screen other)]
    [(1) (if (even? (quotient k 6))
             (tables:set! status-line:segments seg-a (status-line:left (mod k 50)))
             (tables:remove! status-line:segments seg-a))]
    [(2) (if (< (length (layout:views)) 4)
             (views:with-view (view) (commands:run layout-split:split-right))
             (views:with-view (view) (commands:run layout:delete-view)))]
    [(3) (status-line-test:click! (view) 1)]
    [(4) (batch-ended)]
    [else (status-line:draw (view) (test-user:client))]))

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
                      (quits:request-quit!)
                      (chez:sleep (make-time 'time-duration 1000000 0))
                      (loop))
                    (set! stopped #t))))))
        (let loop ([k 0])
          (when (< (real-time) until)
            (step! k)
            (set! rounds (+ rounds 1))
            (loop (+ k 1))))
        (set! quitting #f)
        (let spin () (unless (or stopped (> (real-time) (+ until 30000))) (spin)))
        (let settle ([n 0]) (when (< n 100000) (settle (+ n 1))))))
    (values quits rounds)))

;; A quit that lands in a task a click started is reported there, not
;; caught by the stress's guard, so both count. A click posted while a
;; split or a deletion is pending can name a window gone by the time it is
;; handled, so stale clicks are the stress's reports too.
(test "quits landing in drawing status lines, changing the segments, window commands and clicks leave every status line drawing as before"
  (let* ([elsewhere 0] [quiet (lambda (next c) (when (cancelled? c) (set! elsewhere (+ elsewhere 1))))])
    (advice-add! report quiet)
    (let-values ([(quits rounds) (stress! 2)])
      (check (> (+ quits elsewhere) 100))
      (check (> rounds 1000)))
    (test-user:settle)
    (advice-remove! report quiet))
  (tables:set! status-line:segments seg-a (status-line:left 25))
  (for-each (lambda (v) (views:set-buffer! v notes)) (layout:views))
  (let ([lines (status-line-test:status-lines)])
    (check-equal? (length (layout:views)) (length lines))
    (check (for-all (lambda (l) (equal? l (car lines))) lines))
    (check-equal? (list (cons "status-line:modified" "") (cons "status-line:buffer-name" "notes") (cons (symbol->string seg-a) "a")
                        (cons "status-line:position" "L1") (cons "status-line:percent-position" "Top")
                        (cons "status-line:region-size" "") (cons "status-line:major-mode" "Fundamental")
                        (cons "status-line:minor-modes" ""))
                  (car lines))
    (check-equal? lines (status-line-test:status-lines other))))
