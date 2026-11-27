(import (tuna) (test) (test-runner) (processes) (recorder) (setting)
  (rename (only (chezscheme) sleep) (sleep chez:sleep)))

(define (violation thunk)
  (guard (c [(assertion-violation? c) (list (condition-who c) (condition-message c))])
    (thunk)
    'no-violation))

(define (ignore-output bytes end) (void))

;; As a user's interrupt from another thread would, each quit cancels the
;; task running on the main thread when it lands; tick runs in that task.
(define running-on-main (box #f))
(advice-add! tick (lambda (next) (set-box! running-on-main (current-task)) (next)))

(define (quit-running!)
  (let ([t (unbox running-on-main)])
    (when (and t (eq? (task-state t) 'running))
      (cancel-task t))))

;; The cancels land in deliveries at random, and each ends a task the
;; kernel reports; how many land is chance, so they are kept, not counted.
(define (quits-for seconds)
  (let* ([landed '()] [keep (lambda (next c) (if (cancelled? c) (set! landed (cons c landed)) (next c)))])
    (advice-add! report keep)
    (test-runner:join
      (fork-task
        (lambda (restore)
          (let ([until (+ (real-time) (* seconds 1000))])
            (let loop ()
              (when (< (real-time) until)
                (quit-running!)
                (chez:sleep (make-time 'time-duration 200000 0))
                (loop)))))))
    (advice-remove! report keep)))

(define (following)
  (let ([holes 0] [last-end 0])
    (values
      (lambda (bytes end)
        (unless (eof-object? bytes)
          (unless (= (- end (bytevector-length bytes)) last-end) (set! holes (+ holes 1)))
          (set! last-end end)))
      (lambda () holes))))

(define (advancing? p)
  (let ([before (processes:output-end p)])
    (test-runner:wait-until (lambda () (> (processes:output-end p) (+ before 100000))))
    #t))

(test "quits from another thread while an own process floods output lose and repeat nothing, and reading and the exit go on"
  (let-values ([(follow holes) (following)])
    (let* ([r (recorder:make)] [own (processes:start "cat" '("/dev/zero") follow (recorder:on-exit r))])
      (quits-for 2)
      (check-equal? 0 (holes))
      (check (advancing? own))
      (processes:stop! own)
      (check-equal? '((exit -1)) (recorder:wait-for-exit r)))))

(test "quits from another thread while a pausing user process with a small log floods output lose and repeat nothing"
  (setting:with processes:log-size 4096
    (lambda ()
      (let-values ([(follow holes) (following)])
        (let ([r (recorder:make)]
              [user (processes:start-for-user "cat" '("/dev/zero") (processes:options [full-log (processes:full-log pause)]))])
          (processes:attach! user 0 follow (recorder:on-exit r))
          (quits-for 2)
          (check-equal? 0 (holes))
          (check (advancing? user))
          (processes:stop! user)
          (check-equal? '((exit -1)) (recorder:wait-for-exit r))
          (check (not (memq user (processes:all)))))))))

(test "standard error kept apart reaches on-error-output as output reaches on-output, then its end, before the exit status"
  (let ([r (recorder:make)])
    (processes:start "sh" '("-c" "printf out; printf err >&2") (recorder:on-output r) (recorder:on-exit r)
      (processes:options) (recorder:on-error-output r))
    (let ([events (recorder:wait-for-exit r)])
      (check-equal? '((error "err" 3) (error-eof 3)) (filter (lambda (e) (memq (car e) '(error error-eof))) events))
      (check-equal? '(exit 0) (car (reverse events)))))
  (let* ([r (recorder:make)]
         [p (processes:start "sh" '("-c" "printf late >&2") (recorder:on-output r) (recorder:on-exit r)
              (processes:options) (recorder:on-error-output r))])
    (check-equal? '((error "late" 4) (error-eof 4))
      (filter (lambda (e) (memq (car e) '(error error-eof))) (recorder:wait-for-exit r)))
    (check-equal? "late" (utf8->string (processes:error-output p)))))

(test "on-error-output must be a procedure, and a terminal cannot keep standard error apart"
  (check-equal? '(processes:start "a terminal joins standard error to the output")
    (violation (lambda () (processes:start "true" '() ignore-output (lambda (s) (void)) (processes:options [terminal '(24 . 80)]) ignore-output))))
  (check-equal? '(processes:start "not a procedure")
    (violation (lambda () (processes:start "true" '() ignore-output (lambda (s) (void)) (processes:options) 'errors)))))

(test "standard error is not held back for a slow reader: past processes:log-size bytes between deliveries the oldest go, and a line receiver passes the lines after the cut whole"
  (setting:with processes:log-size 64
    (lambda ()
      (let* ([r (recorder:make)] [lines '()]
             [p (processes:start "sh" '("-c" "i=1; while [ $i -le 40 ]; do echo \"error line $i\" >&2; i=$((i+1)); done")
                  ignore-output (recorder:on-exit r) (processes:options)
                  (processes:line-receiver 0 (lambda (line end) (set! lines (cons (list line end) lines)))))]
             [give-up (+ (real-time) 5000)])
        ;; The main thread stays busy until all of it is written, so nothing
        ;; is delivered before.
        (let loop ()
          (unless (or (> (real-time) give-up)
                      (let ([text (utf8->string (processes:error-output p))])
                        (and (>= (string-length text) 14)
                             (string=? "error line 40\n" (substring text (- (string-length text) 14) (string-length text))))))
            (loop)))
        (recorder:wait-for-exit r)
        (check-equal? `(("error line 37" 509) ("error line 38" 523) ("error line 39" 537) ("error line 40" 551) (,(eof-object) 551))
          (reverse lines))))))
