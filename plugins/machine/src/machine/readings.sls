(library (machine readings)
  (export cpu-reading cpufreq-reading memory-reading load-reading pressure-reading disks-reading
          file-systems-reading network-reading gpu-reading)
  (import (chezscheme) (procfs) (sysfs) (host) (timeseries) (machine data))

  ;; A rate is taken over the worker's own monotonic interval, so a step of
  ;; the wall clock never enters it.
  (define (with-interval previous now read)
    (and previous (read (- now (car previous)) (cdr previous))))

  (define (find-by name-of name items)
    (find (lambda (x) (equal? (name-of x) name)) items))

  (define (cpu-reading root before)
    (let ([after (procfs-cpu-times (make-procfs root))])
      (values after
        (if (and before after)
            (make-cpu-reading
              (cpu-times-usage (car before) (car after))
              (fold-right
                (lambda (a acc)
                  (let ([b (find-by cpu-times-cpu (cpu-times-cpu a) (cdr before))])
                    (if b (cons (cons (cpu-times-cpu a) (cpu-times-usage b a)) acc) acc)))
                '() (cdr after))
              (or (cpu-times-shares (car before) (car after)) '()))
            (make-cpu-reading #f '() '())))))

  (define (cpufreq-reading root kept)
    (values #f
      (map (lambda (f) (cons (cpu-frequency-cpu f) (cpu-frequency-current f)))
           (filter cpu-frequency-current (sysfs-cpu-frequencies (make-sysfs root))))))

  (define (memory-reading root kept)
    (let ([m (procfs-meminfo (make-procfs root))])
      (define (value key) (and m (let ([kv (assq key m)]) (and kv (cdr kv)))))
      (values #f
        (make-memory-reading
          (value 'mem-total) (value 'mem-available) (value 'mem-free) (value 'cached) (value 'buffers)
          (and (value 'mem-total) (value 'mem-available) (- (value 'mem-total) (value 'mem-available)))
          (value 'swap-total) (value 'swap-free)))))

  (define (load-reading root kept)
    (let ([l (procfs-loadavg (make-procfs root))])
      (values #f
        (if l
            (make-load-reading (loadavg-one l) (loadavg-five l) (loadavg-fifteen l) (loadavg-running l))
            (make-load-reading #f #f #f #f)))))

  (define (stall-total p line)
    (and p (line p) (pressure-line-total (line p))))

  (define (pressure-reading root previous)
    (let* ([fs (make-procfs root)]
           [now (timeseries-monotonic)]
           [totals (map (lambda (resource read)
                          (let ([p (read fs)])
                            (make-stall resource (stall-total p pressure-some) (stall-total p pressure-full))))
                        '(cpu memory io)
                        (list procfs-cpu-pressure procfs-memory-pressure procfs-io-pressure))])
      (values (cons now totals)
        (or (with-interval previous now
              (lambda (seconds before)
                (map (lambda (t b)
                       (define (rate total) (and (total t) (total b) (counter-rate (total b) (total t) seconds)))
                       (make-stall (stall-resource t) (rate stall-some) (rate stall-full)))
                     totals before)))
            '()))))

  (define (disks-reading root previous)
    (let* ([now (timeseries-monotonic)]
           [stats (or (procfs-disk-stats (make-procfs root)) '())])
      (values (cons now stats)
        (or (with-interval previous now
              (lambda (seconds before)
                (fold-right
                  (lambda (d acc)
                    (let ([b (find-by disk-stats-name (disk-stats-name d) before)])
                      (define (rate count) (counter-rate (count b) (count d) seconds))
                      (if b
                          (cons (make-disk-rates (disk-stats-name d) (rate disk-stats-bytes-read)
                                                 (rate disk-stats-bytes-written) (rate disk-stats-io-time))
                                acc)
                          acc)))
                  '() stats)))
            '()))))

  ;; As psutil's disk_partitions: a file system that needs no device is
  ;; left out, zfs excepted, and so is a mount with no source. A mount
  ;; point mounted over is listed once, for the mount that shows.
  (define (file-systems-reading root kept)
    (let* ([fs (make-procfs root)]
           [types (or (procfs-filesystems fs) '())]
           [mounts (filter (lambda (m)
                             (let ([type (assoc (mount-fstype m) types)])
                               (and (or (equal? (mount-fstype m) "zfs") (and type (not (cdr type))))
                                    (not (member (mount-source m) '("" "none"))))))
                           (or (procfs-mounts fs) '()))]
           [points (fold-left (lambda (points m) (if (member (mount-point m) points) points (cons (mount-point m) points)))
                              '() (reverse mounts))])
      (values #f
        (fold-right
          (lambda (point acc)
            (let ([space (guard (c [(i/o-error? c) #f]) (host-file-system-space point))])
              (if space
                  (cons (make-mount-space point (file-system-space-total space) (file-system-space-free space)
                                          (file-system-space-available space))
                        acc)
                  acc)))
          '() points))))

  (define (network-reading root previous)
    (let* ([now (timeseries-monotonic)]
           [counters (or (procfs-net-dev (make-procfs root)) '())])
      (values (cons now counters)
        (or (with-interval previous now
              (lambda (seconds before)
                (fold-right
                  (lambda (n acc)
                    (let ([b (find-by net-counters-interface (net-counters-interface n) before)])
                      (define (rate count) (counter-rate (count b) (count n) seconds))
                      (if b
                          (cons (make-interface-rates (net-counters-interface n) (rate net-counters-rx-bytes)
                                                      (rate net-counters-tx-bytes))
                                acc)
                          acc)))
                  '() counters)))
            '()))))

  ;; The input is the root and the names of the files the table names, so a
  ;; table entry added later takes effect when the job starts again.
  (define (gpu-reading input kept)
    (let ([fs (make-sysfs (car input))])
      (values #f
        (apply append
          (map (lambda (card)
                 (fold-right
                   (lambda (name acc)
                     (let ([v (drm-card-attribute fs card name)])
                       (if (real? v) (cons (make-card-value (drm-card-name card) name v) acc) acc)))
                   '() (cdr input)))
               (sysfs-drm-cards fs)))))))
