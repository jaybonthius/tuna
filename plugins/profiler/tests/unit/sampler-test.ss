;;; The sampler and the profiler's readings rest on Gambit internals
;;; (`##` primitives) that gxprof uses and that may change between Gambit
;;; versions. These tests fail loudly when they do: each primitive exists
;;; and behaves as the profiler expects.
(import (only-in :gerbil/runtime/thread spawn-thread)
        :std/test
        :tuna/plugins/profiler/clock
        :tuna/plugins/profiler/sampler)
(export sampler-test)

;; Keep the processor busy for SECONDS, in compiled code (list-sort).
(def (busy-for seconds)
  (let (deadline (+ (time->seconds (current-time)) seconds))
    (let lp ((n 0))
      (if (< (time->seconds (current-time)) deadline)
        (begin (list-sort < (map (lambda (i) (modulo (* i 7919) 1000)) (iota 500))) (lp (+ n 1)))
        n))))

(def (heartbeat-interval)
  (let (v (make-f64vector 1 0.))
    (##get-heartbeat-interval! v 0)
    (f64vector-ref v 0)))

(def sampler-test
  (test-suite "profiler: the Gambit internals it relies on"
    (test-case "the primitives exist"
      (for-each (lambda (p) (check (procedure? p) => #t))
                [##get-heartbeat-interval! ##set-heartbeat-interval! ##interrupt-vector-set!
                 ##thread-heartbeat! ##continuation-capture ##continuation-next-frame
                 ##continuation-creator ##procedure-name ##process-statistics
                 ##get-monotonic-time! ##get-monotonic-time-frequency!]))

    (test-case "process statistics: 20 numbers, bytes allocated and GC time growing"
      (let (before (##process-statistics))
        (check (f64vector? before) => #t)
        (check (f64vector-length before) => 20)
        (make-vector 100000 0)
        (let (after (take-reading))
          (check (> (reading-allocated after) (+ (f64vector-ref before 7) 800000.)) => #t)
          (check (>= (reading-gc after) (* 1000. (f64vector-ref before 5))) => #t))))

    (test-case "the monotonic clock never goes back and counts milliseconds"
      (let* ((a (now-ms))
             (_ (thread-sleep! 0.05))
             (b (now-ms)))
        (check (> b a) => #t)
        (check (< 40. (- b a) 500.) => #t)))

    (test-case "sampling on the heartbeat takes stacks of named procedures, labelled; stopping restores it"
      (let (interval (heartbeat-interval))
        (sampler-start! .001 (lambda () "item tab#1 a"))
        (check (sampler-running?) => #t)
        (check (heartbeat-interval) => .001)
        (busy-for .3)
        (let (samples (sampler-stop!))
          (check (sampler-running?) => #f)
          (check (heartbeat-interval) => interval)
          (check (> (length samples) 50) => #t)
          (check (andmap (lambda (s) (equal? (car s) "item tab#1 a")) samples) => #t)
          (check (and (find (lambda (s) (find (lambda (frame) (string-contains frame "sort")) (caddr s)))
                            samples)
                      #t)
                 => #t)
          (let (lines (folded-lines samples))
            (check (pair? lines) => #t)
            (for-each (lambda (line)
                        (let (fields (string-split line #\space))
                          (check (length fields) => 2)
                          (check (string-prefix? "item_tab#1_a;" (car fields)) => #t)
                          (check (fixnum? (string->number (cadr fields))) => #t)))
                      lines)
            (check (apply + (map (lambda (line) (string->number (cadr (string-split line #\space)))) lines))
                   => (length samples))))
        ;; Threads are still preempted after sampling: two busy threads
        ;; both make progress.
        (let* ((counts (make-vector 2 0))
               (threads (map (lambda (i)
                               (spawn-thread (lambda ()
                                               (let (deadline (+ (time->seconds (current-time)) .2))
                                                 (let lp ()
                                                   (when (< (time->seconds (current-time)) deadline)
                                                     (vector-set! counts i (+ 1 (vector-ref counts i)))
                                                     (lp)))))))
                             [0 1])))
          (for-each thread-join! threads)
          (check (and (> (vector-ref counts 0) 0) (> (vector-ref counts 1) 0)) => #t))))))
