(library (system-processes rows)
  (export row-tag row? row-size row-field
          pid-field ppid-field pgrp-field sess-field tpgid-field comm-field args-field state-field uid-field
          euid-field gid-field egid-field user-field group-field ttname-field minflt-field majflt-field
          cminflt-field cmajflt-field utime-field stime-field time-field cutime-field cstime-field ctime-field
          pri-field nice-field thcount-field start-field etime-field vsize-field rss-field cpu-usage-field
          cpu-average-field memory-share-field flags-field processor-field rtprio-field policy-field blkio-field
          gtime-field cgroup-field boot-start-field)
  (import (chezscheme))

  ;; A row crosses from the worker that reads it as plain data, an
  ;; immutable vector; the tag, the same symbol in every process and
  ;; after a reload, tells a row from any other vector.
  (define row-tag (gensym "system-processes-row" "s7d2q9v4k1x8m3p6n0z5wbtcgyfhjr-0"))

  (define pid-field 1) (define ppid-field 2) (define pgrp-field 3) (define sess-field 4) (define tpgid-field 5)
  (define comm-field 6) (define args-field 7) (define state-field 8) (define uid-field 9) (define euid-field 10)
  (define gid-field 11) (define egid-field 12) (define user-field 13) (define group-field 14) (define ttname-field 15)
  (define minflt-field 16) (define majflt-field 17) (define cminflt-field 18) (define cmajflt-field 19)
  (define utime-field 20) (define stime-field 21) (define time-field 22) (define cutime-field 23)
  (define cstime-field 24) (define ctime-field 25) (define pri-field 26) (define nice-field 27)
  (define thcount-field 28) (define start-field 29) (define etime-field 30) (define vsize-field 31)
  (define rss-field 32) (define cpu-usage-field 33) (define cpu-average-field 34) (define memory-share-field 35)
  (define flags-field 36) (define processor-field 37) (define rtprio-field 38) (define policy-field 39)
  (define blkio-field 40) (define gtime-field 41) (define cgroup-field 42) (define boot-start-field 43)
  (define row-size 44)

  (define (row? v)
    (and (vector? v) (fx= (vector-length v) row-size) (eq? (vector-ref v 0) row-tag)))

  (define (row-field r i) (vector-ref r i)))
