(import (tuna) (test) (test-runner) (document) (jobs) (buffers)
        (rename (only (chezscheme) sleep) (sleep chez:sleep)))

(jobs:define-worker (long-lines version emit)
  (import (document))
  (let* ([doc (cdr version)]
         [size (document:length doc)]
         [last (document:line doc size)])
    (do ([line 1 (+ line 1)]) ((> line last))
      (let ([start (document:line-start doc line)]
            [end (if (= line last) size (document:line-start doc (+ line 1)))])
        (when (> (- end start) 100)
          (emit (list (car version) start end)))))))

(jobs:define-worker (summarize version emit)
  (import (document))
  (let ([doc (cdr version)])
    (emit (list (car version) (document:length doc) (document:line doc (document:length doc))
                (string-length (document:text doc)) (document:datums (document:slice doc 0 3))))))

(define (job-results worker input)
  (let ([results '()] [ended (box #f)])
    (jobs:start worker input (lambda (v) (set! results (cons v results))) (lambda (how) (set-box! ended (list how))))
    (test-runner:wait-until (lambda () (unbox ended)))
    (check-equal? '(#f) (unbox ended))
    (reverse results)))

(test "a job reads the version of a buffer it was given"
  (let ([buffer (buffers:make "lines" (string-append (make-string 120 #\a) "\nshort\n" (make-string 101 #\b) "\n"))])
    (check-equal? '((0 0 122) (0 128 230))
      (job-results long-lines (cons (buffers:version buffer) (buffers:document buffer))))
    (buffers:replace! buffer 1 1 (make-string 10 #\c))
    (check-equal? '((1 0 132) (1 138 240))
      (job-results long-lines (cons (buffers:version buffer) (buffers:document buffer))))
    (buffers:kill! buffer)))

(define (summary k doc)
  (list k (document:length doc) (document:line doc (document:length doc))
        (string-length (document:text doc)) (document:datums (document:slice doc 0 3))))

(test "jobs read versions of one document while the main thread makes new ones from it, each as the main thread reads it"
  (let* ([answers '()]
         [expected
          (let loop ([k 0] [doc (document:from-datum (make-string 50000 #\a) "\n" '(p () "x\ny"))] [acc '()])
            (if (= k 60)
                acc
                (let ([f (document:freeze doc jobs:freeze)])
                  (jobs:start summarize (cons k f) (lambda (a) (set! answers (cons a answers))))
                  (loop (+ k 1)
                        (document:replace f (* k 7) (+ (* k 7) 2) (document:from-datum (if (even? k) "\n\n\n" "λ")))
                        (cons (summary k f) acc)))))])
    (test-runner:wait-until (lambda () (= (length answers) 60)))
    (check-equal? (reverse expected) (list-sort (lambda (a b) (< (car a) (car b))) answers))))

;; While the main thread itself waits busily, it keeps its own deadline.
(define (spin-until done?)
  (let ([deadline (add-duration (current-time 'time-monotonic) (make-time 'time-duration 0 30))])
    (let loop ()
      (unless (done?)
        (when (time>? (current-time 'time-monotonic) deadline)
          (errorf 'spin-until "~s did not hold within 30 s" done?))
        (loop)))))

(test "quits landing in document code on the main thread leave every document as it was"
  (let* ([base (document:from-datum (make-string 20000 #\a) '(p () "b"))]
         [base-text (document:text base)]
         [quitting #t]
         [stopped #f]
         [quits 0]
         [stressed (current-task)]
         [until (+ (real-time) 2000)])
    ;; A user's quit cancels the main thread's running task from another
    ;; thread, landing up to a thousand calls after it is asked for, so the
    ;; one guard holds from before the first until after the last has
    ;; landed: a quit between two guards would end the test.
    (let again ()
      (guard (c [(cancelled? c) (set! quits (+ quits 1)) (again)])
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
        (let loop ([doc base] [k 0])
          (when (< (real-time) until)
            (let* ([p (mod (* k 7919) (document:length doc))]
                   [doc (document:freeze (document:replace doc p p (document:from-datum "xy" '(q () "z"))) jobs:freeze)])
              (document:text doc)
              (loop (if (> (document:length doc) 40000) base doc) (+ k 1)))))
        (set! quitting #f)
        (spin-until (lambda () stopped))
        (let settle ([n 0]) (when (< n 100000) (settle (+ n 1))))))
    (check (> quits 100))
    (check-equal? base-text (document:text base))
    (check-equal? 20003 (document:length base))
    (check-equal? "cb" (document:text (document:replace base 0 20000 (document:from-datum "c"))))))
