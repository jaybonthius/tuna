#!tuna
(import (sampler) (jobs) (hooks) (options) (only (procfs) make-procfs procfs-process-stat proc-stat-start-time)
        (only (process) pid-signal! pid-set-priority!) (rename (system-processes rows) (row? %row?)))

(define (%restart-source root) (sampler:restart! source))

(options:define-option proc-root "/proc" string? "Where the kernel's process files are." %restart-source)

(hooks:define-hook updated "Called with no arguments after a reading replaced the rows.")

(define %rows '())
(define %by-pid (make-eqv-hashtable))
(define %main-thread (get-thread-id))

(define (%check-main-thread who)
  (unless (eqv? (get-thread-id) %main-thread)
    (assertion-violation who "not on the main thread")))

(define (row? v) (%row? v))

(define (%check-row who r)
  (unless (%row? r) (assertion-violation who "not a row" r)))

(define (%field who r i)
  (%check-row who r)
  (row-field r i))

(define (%record-rows time rows)
  (set! %rows rows)
  (set! %by-pid (make-eqv-hashtable))
  (for-each (lambda (r) (hashtable-set! %by-pid (row-field r pid-field) r)) rows)
  (updated))

(jobs:define-worker (%reader root emit receive)
  (import (sampler reading) (system-processes reading))
  (reading-loop processes-reading root emit receive))

(sampler:define-source source %reader proc-root %record-rows)

(define (rows)
  (%check-main-thread 'system-processes:rows)
  %rows)

(define (row pid)
  (%check-main-thread 'system-processes:row)
  (unless (and (fixnum? pid) (fx> pid 0)) (assertion-violation 'system-processes:row "not a process id" pid))
  (hashtable-ref %by-pid pid #f))

;; A pid can be reused between the reading and the call, so the process
;; is read again and its start compared; the window that remains is the
;; one kill and renice leave. It is read from Tuna's own /proc, the pid
;; namespace kill acts on, whatever tree the rows came from.
(define (%same-process? r)
  (let ([stat (procfs-process-stat (make-procfs) (row-field r pid-field))])
    (and stat (= (proc-stat-start-time stat) (row-field r boot-start-field)))))

(define (signal! r signal)
  (%check-main-thread 'system-processes:signal!)
  (%check-row 'system-processes:signal! r)
  (unless (or (and (fixnum? signal) (fx> signal 0)) (symbol? signal))
    (assertion-violation 'system-processes:signal! "not a signal name or number" signal))
  (and (%same-process? r) (pid-signal! (row-field r pid-field) signal)))

(define (set-priority! r nice)
  (%check-main-thread 'system-processes:set-priority!)
  (%check-row 'system-processes:set-priority! r)
  (unless (and (fixnum? nice) (fx<= -20 nice 19))
    (assertion-violation 'system-processes:set-priority! "not a nice value from -20 to 19" nice))
  (and (%same-process? r) (pid-set-priority! (row-field r pid-field) nice)))

(define (row-pid r) (%field 'system-processes:row-pid r pid-field))
(define (row-ppid r) (%field 'system-processes:row-ppid r ppid-field))
(define (row-pgrp r) (%field 'system-processes:row-pgrp r pgrp-field))
(define (row-sess r) (%field 'system-processes:row-sess r sess-field))
(define (row-tpgid r) (%field 'system-processes:row-tpgid r tpgid-field))
(define (row-comm r) (%field 'system-processes:row-comm r comm-field))
(define (row-args r) (%field 'system-processes:row-args r args-field))
(define (row-state r) (%field 'system-processes:row-state r state-field))
(define (row-uid r) (%field 'system-processes:row-uid r uid-field))
(define (row-euid r) (%field 'system-processes:row-euid r euid-field))
(define (row-gid r) (%field 'system-processes:row-gid r gid-field))
(define (row-egid r) (%field 'system-processes:row-egid r egid-field))
(define (row-user r) (%field 'system-processes:row-user r user-field))
(define (row-group r) (%field 'system-processes:row-group r group-field))
(define (row-ttname r) (%field 'system-processes:row-ttname r ttname-field))
(define (row-minflt r) (%field 'system-processes:row-minflt r minflt-field))
(define (row-majflt r) (%field 'system-processes:row-majflt r majflt-field))
(define (row-cminflt r) (%field 'system-processes:row-cminflt r cminflt-field))
(define (row-cmajflt r) (%field 'system-processes:row-cmajflt r cmajflt-field))
(define (row-utime r) (%field 'system-processes:row-utime r utime-field))
(define (row-stime r) (%field 'system-processes:row-stime r stime-field))
(define (row-time r) (%field 'system-processes:row-time r time-field))
(define (row-cutime r) (%field 'system-processes:row-cutime r cutime-field))
(define (row-cstime r) (%field 'system-processes:row-cstime r cstime-field))
(define (row-ctime r) (%field 'system-processes:row-ctime r ctime-field))
(define (row-pri r) (%field 'system-processes:row-pri r pri-field))
(define (row-nice r) (%field 'system-processes:row-nice r nice-field))
(define (row-thcount r) (%field 'system-processes:row-thcount r thcount-field))
(define (row-start r) (%field 'system-processes:row-start r start-field))
(define (row-etime r) (%field 'system-processes:row-etime r etime-field))
(define (row-vsize r) (%field 'system-processes:row-vsize r vsize-field))
(define (row-rss r) (%field 'system-processes:row-rss r rss-field))
(define (row-cpu-usage r) (%field 'system-processes:row-cpu-usage r cpu-usage-field))
(define (row-cpu-average r) (%field 'system-processes:row-cpu-average r cpu-average-field))
(define (row-memory-share r) (%field 'system-processes:row-memory-share r memory-share-field))
(define (row-flags r) (%field 'system-processes:row-flags r flags-field))
(define (row-processor r) (%field 'system-processes:row-processor r processor-field))
(define (row-rtprio r) (%field 'system-processes:row-rtprio r rtprio-field))
(define (row-policy r) (%field 'system-processes:row-policy r policy-field))
(define (row-blkio r) (%field 'system-processes:row-blkio r blkio-field))
(define (row-gtime r) (%field 'system-processes:row-gtime r gtime-field))
(define (row-cgroup r) (%field 'system-processes:row-cgroup r cgroup-field))
(define (row-boot-start r) (%field 'system-processes:row-boot-start r boot-start-field))
