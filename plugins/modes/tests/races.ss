(import (tuna) (test) (test-runner) (test-user) (modes) (prog) (buffers) (views) (layout) (keys) (options) (tables) (editing)
        (modes-test text) (modes-test fill) (modes-test code) (rename (only (chezscheme) sleep) (sleep chez:sleep)))

(define request-quit! (test-runner:running-task-canceller))

(define (local option b) (buffers:with-buffer b (option)))

(define (view) (layout:selected-view))

(define buffers (map (lambda (i) (buffers:make (format "b~a" i) "f(x)\n")) (iota 6)))

(views:set-buffer! (view) (car buffers))

(define modes (list modes-test/code:mode modes-test/text:mode modes:fundamental prog:mode))

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
            (let ([b (list-ref buffers (mod k 6))])
              (case (mod k 8)
                [(0 1 2) (modes:set-major-mode (list-ref modes (mod k 4)) b)]
                [(3) (modes:run-mode-hooks b)]
                [(4) (views:call-with-view (view) (lambda () (keys:active-keymaps (test-user:client))))]
                [(5) (buffers:with-buffer b (options:set-local! modes-test/fill:mode (even? k)))]
                [(6) (modes:active-minor-modes (view))]
                [else (views:call-with-view (view) (lambda () (keys:press! (test-user:client) "C-a")))]))
            (set! rounds (+ rounds 1))
            (loop (+ k 1))))
        (set! quitting #f)
        (let spin () (unless (or stopped (> (real-time) (+ until 30000))) (spin)))
        (let settle ([n 0]) (when (< n 100000) (settle (+ n 1))))))
    (values quits rounds)))

(test "quits landing in mode switches, their hooks, key lookups and minor-mode changes leave every buffer a defined mode that sets its values"
  (let ([quiet (lambda (next c) (unless (cancelled? c) (next c)))])
    (advice-add! report quiet)
    (let-values ([(quits rounds) (stress! 2)])
      (advice-remove! report quiet)
      (check (> quits 0))
      (check (> rounds 1000))))
  (check (for-all (lambda (b) (and (tables:ref modes:hooks (modes:major-mode b) #f) #t)) buffers))
  (for-each (lambda (b) (modes:set-major-mode modes-test/code:mode b)) buffers)
  (check-equal? (map (lambda (b) (list modes-test/code:mode 79 #f)) buffers)
                (map (lambda (b) (list (modes:major-mode b) (local modes-test/fill:column b) (local modes-test/fill:mode b))) buffers))
  (for-each (lambda (b) (modes:set-major-mode modes-test/text:mode b)) buffers)
  (check-equal? (map (lambda (b) (list modes-test/text:mode 70)) buffers)
                (map (lambda (b) (list (modes:major-mode b) (local modes-test/fill:column b))) buffers)))

(test "after the storm a reload of a mode's plugin gives its values back, and keys find the modes' keymaps"
  (let ([b (car buffers)])
    (buffers:with-buffer b (options:set-local! modes-test/fill:column 20))
    (modes:set-major-mode modes-test/code:mode b)
    (buffers:with-buffer b (options:set-local! modes-test/fill:mode #t))
    (reload-modules! '((modes-test code)))
    (check-equal? '(#t 79) (list (local modes-test/fill:mode b) (local modes-test/fill:column b)))
    (views:set-buffer! (view) b)
    (let ([found (views:call-with-view (view) (lambda () (keys:active-keymaps (test-user:client))))])
      (check-equal? (list modes-test/fill:keymap modes-test/code:keymap prog:keymap)
                    (filter (lambda (k) (memq k (list modes-test/fill:keymap modes-test/code:keymap prog:keymap))) found)))))
