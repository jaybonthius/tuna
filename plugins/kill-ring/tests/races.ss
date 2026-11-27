(import (tuna) (test) (test-runner) (options) (kill-ring)
        (rename (only (chezscheme) sleep) (sleep chez:sleep)))

(define saved-file (string-append (getenv "HOME") "/.local/share/tuna/saved/tuna/kill-ring/texts.ss"))

(define (saved-texts) (and (file-exists? saved-file) (call-with-input-file saved-file read)))

(define (ring-texts)
  (map (lambda (entry) (map (lambda (kill) (kill-ring:text (list kill))) entry)) (kill-ring:entries)))

(define (whole-entry? e) (and (pair? e) (list? e) (for-all string? e)))

(define (change! i)
  (case (mod i 4)
    [(0) (kill-ring:push! (list (number->string i) "b"))]
    [(1) (kill-ring:append! (list "+" "-"))]
    [(2) (kill-ring:prepend! (list "<" ">"))]
    [(3) (kill-ring:rotate! i)]))

;; While the main thread itself waits busily, it keeps its own deadline.
(define (spin-until done?)
  (let ([deadline (add-duration (current-time 'time-monotonic) (make-time 'time-duration 0 30))])
    (let loop ()
      (unless (done?)
        (when (time>? (current-time 'time-monotonic) deadline)
          (errorf 'spin-until "~s did not hold within 30 s" done?))
        (loop)))))

(test "threads reading while the main thread pushes, appends, prepends and rotates past the cap see an entry and entries from one moment"
  (options:with ([kill-ring:max 50])
    (let* ([reading #t] [reads 0] [torn '()]
           [reader (lambda (restore)
                     (let loop ()
                       (when reading
                         (let ([c (kill-ring:current)] [es (kill-ring:entries)])
                           (unless (and (or (not c) (whole-entry? c)) (list? es) (<= (length es) 50) (for-all whole-entry? es))
                             (set! torn (cons (list c es) torn))))
                         (set! reads (+ reads 1))
                         (loop))))]
           [readers (map (lambda (i) (fork-task reader)) '(1 2 3 4))])
      (do ([i 0 (+ i 1)]) ((= i 40000)) (change! i))
      (set! reading #f)
      (for-each join-task readers)
      (check (> reads 1000))
      (check-equal? '() torn)
      (check-equal? 50 (length (kill-ring:entries)))
      (check-equal? '("<39800+" ">b-") (kill-ring:current)))))

(test "quits landing inside pushes, appends and rotations leave the ring whole and saved"
  (options:with ([kill-ring:max 50])
    (let* ([quitting #t] [stopped #f] [quits 0] [stressed (current-task)] [until (+ (real-time) 1500)]
           [count-quits (lambda (next c) (if (cancelled? c) (set! quits (+ quits 1)) (next c)))])
      ;; A quit landing in a hook entry or in advice is reported instead of
      ;; reaching the guard.
      (advice-add! report count-quits)
      ;; A user's quit cancels the main thread's running task from another
      ;; thread, landing up to a thousand calls after it is asked for, so the
      ;; one guard holds from before the first until after the last has
      ;; landed: a quit between two guards would end the test.
      (let again ([i 0])
        (guard (c [(cancelled? c) (set! quits (+ quits 1)) (again (+ i 1))])
          (when (= quits 0)
            (fork-task
              (lambda (restore)
                (let loop ()
                  (if quitting
                      (begin
                        (cancel-task stressed)
                        (chez:sleep (make-time 'time-duration 1000000 0))
                        (loop))
                      (set! stopped #t))))))
          (let loop ([i i])
            (when (< (real-time) until)
              (change! i)
              (loop (+ i 1))))
          (set! quitting #f)
          (spin-until (lambda () stopped))
          (let settle ([n 0]) (when (< n 100000) (settle (+ n 1))))))
      (advice-remove! report count-quits)
      (check (> quits 100))
      (let* ([es (kill-ring:entries)] [c (kill-ring:current)])
        (check (<= (length es) 50))
        (check (for-all whole-entry? es))
        (check (memq c es))
        (check (eq? c (kill-ring:rotate! (length es)))))
      (kill-ring:push! (list "settled"))
      (test-runner:wait-until (lambda () (equal? (ring-texts) (saved-texts))))
      (check-equal? (ring-texts) (saved-texts)))))
