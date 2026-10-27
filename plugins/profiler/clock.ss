;;; The profiler's readings of the process: a monotonic clock, the bytes
;;; allocated and the time spent collecting garbage so far, from Gambit's
;;; own counters (`##get-monotonic-time!`, `##process-statistics`). They are
;;; Gambit internals, which the sampler test checks loudly.
prelude: :gerbil/core

(export reading
        make-reading
        reading?
        reading-time
        reading-allocated
        reading-gc
        take-reading
        now-ms)

;; TIME in milliseconds of the monotonic clock; ALLOCATED, bytes allocated
;; by the process so far, not counting this reading's own vector; GC,
;; milliseconds spent collecting garbage so far. The counters are the
;; whole process's: every thread's allocation counts.
(defstruct reading ((time      : :flonum)
                    (allocated : :flonum)
                    (gc        : :flonum))
  final: #t)

(def monotonic-frequency
  (let (v (make-u64vector 1 0))
    (##get-monotonic-time-frequency! v 0)
    (exact->inexact (u64vector-ref v 0))))

;; Milliseconds of the monotonic clock.
(def (now-ms) => :flonum
  (let (v (make-u64vector 1 0))
    (##get-monotonic-time! v 0)
    (fl/ (fl* 1000. (exact->inexact (u64vector-ref v 0))) monotonic-frequency)))

(def (take-reading) => reading
  (let* ((time (now-ms))
         (stats (##process-statistics)))
    (make-reading time
                  (fl- (f64vector-ref stats 7) (f64vector-ref stats 9))
                  (fl* 1000. (f64vector-ref stats 5)))))
