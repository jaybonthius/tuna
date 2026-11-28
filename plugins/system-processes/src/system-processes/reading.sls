(library (system-processes reading)
  (export processes-reading)
  (import (chezscheme) (procfs) (host) (timeseries) (system-processes rows))

  ;; A process's CPU time is kept with its start, so a reused pid is not
  ;; taken for the same process; account names are kept, since a lookup
  ;; may ask a network directory. Nothing else is kept per process, so a
  ;; process that changes its user, arguments or cgroup shows the change
  ;; at the next reading.
  (define-record-type kept
    (sealed #t)
    (fields monotonic times users groups))

  (define (processes-reading root before)
    (let* ([now (timeseries-monotonic)]
           [times (make-eqv-hashtable)]
           [users (if before (kept-users before) (make-eqv-hashtable))]
           [groups (if before (kept-groups before) (make-eqv-hashtable))]
           [rows (read-rows (make-procfs root) (and before (- now (kept-monotonic before)))
                            (if before (kept-times before) (make-eqv-hashtable)) times users groups)])
      (values (make-kept now times users groups) rows)))

  (define (named table lookup id)
    (if (hashtable-contains? table id)
        (hashtable-ref table id #f)
        (let ([name (lookup id)])
          (hashtable-set! table id name)
          name)))

  (define (status-ids status key)
    (let ([kv (assq key status)]) (and kv (pair? (cdr kv)) (cdr kv))))

  (define (read-rows fs seconds before-times times users groups)
    (let* ([meminfo (procfs-meminfo fs)]
           [memory (let ([kv (and meminfo (assq 'mem-total meminfo))]) (and kv (cdr kv)))]
           [kernel (procfs-kernel-stat fs)]
           [boot (and kernel (kernel-stat-boot-time kernel))])
      (fold-right
        (lambda (pid rows)
          (let ([row (read-row fs pid seconds before-times times users groups memory boot)])
            (if row (cons row rows) rows)))
        '() (procfs-pids fs))))

  ;; The uptime is read after the process's files, as Emacs reads it, so
  ;; its elapsed time is never negative.
  (define (read-row fs pid seconds before-times times users groups memory boot)
    (let* ([stat (procfs-process-stat fs pid)]
           [status (and stat (procfs-process-status fs pid))]
           [args (and status (procfs-process-command-line fs pid))]
           [cgroups (and args (procfs-process-cgroup fs pid))]
           [uptime (and cgroups (procfs-uptime fs))])
      (and uptime
           (let* ([uids (or (status-ids status 'uid) '(#f #f))]
                  [gids (or (status-ids status 'gid) '(#f #f))]
                  [start (proc-stat-start-time stat)]
                  [etime (- (uptime-up uptime) start)]
                  [time (+ (proc-stat-user-time stat) (proc-stat-system-time stat))]
                  [ctime (+ (proc-stat-children-user-time stat) (proc-stat-children-system-time stat))]
                  [earlier (hashtable-ref before-times pid #f)]
                  [v (make-vector row-size #f)])
             (hashtable-set! times pid (cons start time))
             (vector-set! v 0 row-tag)
             (vector-set! v pid-field pid)
             (vector-set! v ppid-field (proc-stat-parent stat))
             (vector-set! v pgrp-field (proc-stat-group stat))
             (vector-set! v sess-field (proc-stat-session stat))
             (vector-set! v tpgid-field (proc-stat-foreground-group stat))
             (vector-set! v comm-field (proc-stat-name stat))
             (vector-set! v args-field args)
             (vector-set! v state-field (string (proc-stat-state stat)))
             (vector-set! v uid-field (car uids))
             (vector-set! v euid-field (cadr uids))
             (vector-set! v gid-field (car gids))
             (vector-set! v egid-field (cadr gids))
             (vector-set! v user-field (and (cadr uids) (named users host-user-name (cadr uids))))
             (vector-set! v group-field (and (cadr gids) (named groups host-group-name (cadr gids))))
             (vector-set! v ttname-field (procfs-tty-name fs (proc-stat-tty stat)))
             (vector-set! v minflt-field (proc-stat-minor-faults stat))
             (vector-set! v majflt-field (proc-stat-major-faults stat))
             (vector-set! v cminflt-field (proc-stat-children-minor-faults stat))
             (vector-set! v cmajflt-field (proc-stat-children-major-faults stat))
             (vector-set! v utime-field (proc-stat-user-time stat))
             (vector-set! v stime-field (proc-stat-system-time stat))
             (vector-set! v time-field time)
             (vector-set! v cutime-field (proc-stat-children-user-time stat))
             (vector-set! v cstime-field (proc-stat-children-system-time stat))
             (vector-set! v ctime-field ctime)
             (vector-set! v pri-field (proc-stat-priority stat))
             (vector-set! v nice-field (proc-stat-nice stat))
             (vector-set! v thcount-field (proc-stat-threads stat))
             (vector-set! v start-field (and boot (+ boot start)))
             (vector-set! v etime-field etime)
             (vector-set! v vsize-field (proc-stat-virtual stat))
             (vector-set! v rss-field (proc-stat-resident stat))
             (vector-set! v cpu-usage-field
               (and seconds earlier (= (car earlier) start) (positive? seconds)
                    (inexact (/ (- time (cdr earlier)) seconds))))
             (vector-set! v cpu-average-field (and (positive? etime) (inexact (/ time etime))))
             (vector-set! v memory-share-field
               (and memory (positive? memory) (inexact (min 1 (/ (proc-stat-resident stat) memory)))))
             (vector-set! v flags-field (proc-stat-flags stat))
             (vector-set! v processor-field (proc-stat-processor stat))
             (vector-set! v rtprio-field (proc-stat-realtime-priority stat))
             (vector-set! v policy-field (proc-stat-policy stat))
             (vector-set! v blkio-field (proc-stat-block-io-time stat))
             (vector-set! v gtime-field (proc-stat-guest-time stat))
             (vector-set! v cgroup-field
               (let ([v2 (or (find (lambda (g) (= 0 (process-cgroup-hierarchy g))) cgroups)
                             (and (pair? cgroups) (car cgroups)))])
                 (and v2 (process-cgroup-path v2))))
             (vector-set! v boot-start-field start)
             (vector->immutable-vector v))))))
