(import (tuna) (test) (test-runner) (jobs) (timers) (hooks) (options) (sampler) (metrics) (timeseries)
        (metrics-test first) (metrics-test second)
        (rename (only (chezscheme) fork-thread thread-join) (fork-thread chez:fork-thread) (thread-join chez:thread-join)))

(define (messages reports) (map condition-message reports))

(define first-load metrics-test/first:load)

(metrics:define-metric build-duration
  (unit seconds) (labels project) (retain (raw 86400)) (documentation "Wall time of a finished build."))

(metrics:define-metric temperature (unit celsius) (labels chip))

(test "two label sets are two series, each with its own newest point"
  (metrics:record! temperature '("k10temp") 50)
  (metrics:record! temperature '("nvme") 40.5)
  (check-equal? '(("k10temp") ("nvme")) (metrics:label-sets temperature))
  (check-equal? 50.0 (cdr (metrics:latest temperature '("k10temp"))))
  (check-equal? 40.5 (cdr (metrics:latest temperature '("nvme")))))

(test "labels must be one plain datum per label name"
  (check-raises assertion-violation? (metrics:record! temperature '("a" "b") 1.0))
  (check-raises assertion-violation? (metrics:record! temperature "a" 1.0))
  (check-raises assertion-violation? (metrics:record! temperature (list (make-mutex)) 1.0))
  (check-raises assertion-violation? (metrics:record! temperature '("a") +nan.0)))

(test "a point not after the series' newest is dropped and counted; a metric with no source warns once until a point is kept"
  (let* ([t (timeseries-now)] [labels '("drops")])
    (check-equal? #t (metrics:record! build-duration labels 1.0 t))
    (let ([reports (test-runner:reports-during
                     (lambda ()
                       (check-equal? #f (metrics:record! build-duration labels 2.0 t))
                       (check-equal? #f (metrics:record! build-duration labels 2.0 (- t 1)))))])
      (check-equal? 1 (length reports))
      (check (warning? (car reports)))
      (check-equal? (list build-duration) (condition-irritants (car reports))))
    (check-equal? 2 (metrics:dropped build-duration labels))
    (check-equal? (list (cons t 1.0)) (metrics:points build-duration labels))
    (check-equal? 1 (length (test-runner:reports-during
                              (lambda ()
                                (metrics:record! build-duration labels 3.0 (+ t 1))
                                (metrics:record! build-duration labels 3.0 t)))))))

(test "a clock stepped back loses points until it passes the series' newest, and nothing raises"
  (let* ([t (timeseries-now)] [labels '("step")])
    (metrics:record! build-duration labels 1.0 t)
    (test-runner:reports-during
      (lambda ()
        (check-equal? #f (metrics:record! build-duration labels 1.0 (- t 5)))
        (check-equal? #f (metrics:record! build-duration labels 1.0 (- t 3)))))
    (check-equal? #t (metrics:record! build-duration labels 1.0 (+ t 0.001)))
    (check-equal? 2 (length (metrics:points build-duration labels)))))

(test "two records in a row with no time are two points, and two builds in one second too"
  (let ([labels '("tuna")])
    (metrics:record! build-duration labels 41.5)
    (metrics:record! build-duration labels 39.0)
    (let ([points (metrics:points build-duration labels)])
      (check-equal? 2 (length points))
      (check (< (car (car points)) (car (cadr points))))
      (check (< (- (car (cadr points)) (car (car points))) 1)))))

(metrics:define-metric brief (unit count) (retain (raw 10)))
(metrics:define-metric fleeting (unit count) (labels name) (retain (raw 1)))

(test "a point older than the retention is gone when read; the metric stays"
  (metrics:record! brief '() 1 (- (timeseries-now) 20))
  (check-equal? #f (metrics:latest brief '()))
  (check-equal? '() (metrics:label-sets brief))
  (check (memq brief (metrics:all))))

(test "an exact value is kept as a flonum"
  (metrics:record! brief '() 1/3)
  (check-equal? 0.3333333333333333 (cdr (metrics:latest brief '()))))

(test "two modules may give a metric the same name; they are two metrics"
  (check (not (eq? metrics-test/first:load metrics-test/second:load)))
  (check-equal? 'ratio (metrics:unit metrics-test/first:load))
  (check-equal? 'count (metrics:unit metrics-test/second:load))
  (check-equal? '(cpu) (metrics:label-names metrics-test/first:load))
  (check-equal? '() (metrics:label-names metrics-test/second:load)))

(test "unloading the defining module takes its metric out of the list, and with it its history"
  (let ([first first-load])
    (metrics:record! first '(0) 0.5)
    (check (memq first (metrics:all)))
    (unload-owner! (module-owner '(metrics-test first)))
    (check-equal? #f (memq first (metrics:all)))
    (check-equal? #f (metrics:latest first '(0)))
    (check-raises assertion-violation? (metrics:record! first '(0) 0.5))))

(define recorded '())
(define (note-recorded m labels value time) (set! recorded (cons (list m labels value) recorded)))
(define (fail-on-record m labels value time) (error 'listener "broken"))

(test "recorded runs after each kept point and not after a dropped one; an entry that raises is reported and recording goes on"
  (hooks:add! metrics:recorded note-recorded)
  (let ([t (timeseries-now)])
    (metrics:record! temperature '("hook") 60 t)
    (test-runner:reports-during (lambda () (metrics:record! temperature '("hook") 61 t)))
    (check-equal? (list (list temperature '("hook") 60.0)) recorded)
    (hooks:add! metrics:recorded fail-on-record)
    (check-equal? '("broken") (messages (test-runner:reports-during (lambda () (metrics:record! temperature '("hook") 62 (+ t 1))))))
    (check-equal? 62.0 (cdr (metrics:latest temperature '("hook"))))
    (hooks:remove! metrics:recorded fail-on-record)
    (hooks:remove! metrics:recorded note-recorded)))

(test "points from and to a time, oldest first; an unknown label set has none"
  (let ([t (timeseries-now)] [labels '("range")])
    (for-each (lambda (i) (metrics:record! build-duration labels i (+ t i))) '(0 1 2 3))
    (check-equal? '(1.0 2.0) (map cdr (metrics:points build-duration labels (+ t 1) (+ t 2))))
    (check-equal? '(2.0 3.0) (map cdr (metrics:points build-duration labels (+ t 2))))
    (check-equal? '() (metrics:points build-duration '("nobody")))))

(metrics:define-metric tiered (unit count) (retain (raw 60) (step 60 86400)))

(test "buckets come from the raw points or the tier, as the time series gives them"
  (let ([t (* 60 (floor (/ (- (timeseries-now) 7200) 60)))])
    (for-each (lambda (i) (metrics:record! tiered '() (+ i 1) (+ t i))) (iota 120))
    (let ([b (metrics:buckets tiered '() t (+ t 119) 60)])
      (check-equal? 2 (length b))
      (check-equal? '(60 1830.0) (list (bucket-count (car b)) (bucket-sum (car b)))))))

(test "only the main thread records and reads"
  (let ([message #f])
    (chez:thread-join
      (chez:fork-thread
        (lambda () (set! message (guard (c [#t (condition-message c)]) (metrics:latest temperature '("nvme")))))))
    (check-equal? "not on the main thread" message)))

;; A source whose readings carry the times on-sample records with, so a
;; test can make a reading drop points.
(jobs:define-worker (ticking input emit receive)
  (import (timeseries))
  (let loop ()
    (receive)
    (emit (cons (timeseries-now) '()))
    (loop)))

(define fill-labels '(("a") ("b")))
(define (fill time data)
  (for-each (lambda (labels) (metrics:record! filled labels 1.0 time)) fill-labels))
(sampler:define-source ticks ticking (lambda () #f) fill)
(metrics:define-metric filled (unit count) (labels name) (retain (raw 1)) (source ticks))

(define offset 0)
(define (shift time data)
  (for-each (lambda (labels) (metrics:record! shifted labels 1.0 (- time offset))) '(("a") ("b"))))
(sampler:define-source shifts ticking (lambda () #f) shift)
(metrics:define-metric shifted (unit count) (labels name) (source shifts))

(test "a metric names its source; one recorded by events has none; a source clause must name a source"
  (check-equal? ticks (metrics:source filled))
  (check-equal? #f (metrics:source build-duration))
  (check-equal? "Wall time of a finished build." (metrics:documentation build-duration))
  (check-equal? #f (metrics:documentation brief))
  (check-raises assertion-violation? (let () (metrics:define-metric wrong (unit count) (source 'ticks)) wrong)))

(test "a generic loop makes every metric that has a source live"
  (let ([o (make-owner '(viewer generic))])
    (call-as-owner o
      (lambda ()
        (for-each (lambda (m) (when (metrics:source m) (sampler:want (metrics:source m) 2))) (metrics:all))))
    (check-equal? 2 (sampler:interval ticks))
    (test-runner:wait-until (lambda () (metrics:latest filled '("a"))))
    (unload-owner! o)))

(define (reading-after source)
  (let ([before (sampler:last-time source)])
    (sampler:read-now! source)
    (test-runner:wait-until (lambda () (not (eqv? before (sampler:last-time source)))))))

(test "a reading that drops points warns once, with the count, and no more until a reading keeps them all"
  (let ([o (make-owner '(viewer drops))])
    (call-as-owner o (lambda () (sampler:want shifts 3600)))
    (test-runner:wait-until (lambda () (sampler:last-time shifts)))
    (set! offset 100)
    (let ([reports (test-runner:reports-during (lambda () (reading-after shifts)))])
      (check-equal? 1 (length reports))
      (check-equal? (list shifts 2) (condition-irritants (car reports))))
    (check-equal? '() (test-runner:reports-during (lambda () (reading-after shifts))))
    (set! offset 0)
    (check-equal? '() (test-runner:reports-during (lambda () (reading-after shifts))))
    (set! offset 100)
    (check-equal? 1 (length (test-runner:reports-during (lambda () (reading-after shifts)))))
    (set! offset 0)
    (unload-owner! o)))

(test "a series its source stops filling is gone a retention later, after a reading; a metric with no source prunes at each record"
  (let ([o (make-owner '(viewer stops))])
    (call-as-owner o (lambda () (sampler:want ticks 3600)))
    (reading-after ticks)
    (set! fill-labels '(("b")))
    (timers:sleep 1.2)
    (reading-after ticks)
    (check-equal? '(("b")) (metrics:label-sets filled))
    (set! fill-labels '(("a") ("b")))
    (unload-owner! o))
  (metrics:record! fleeting '("old") 1)
  (timers:sleep 1.2)
  (metrics:record! fleeting '("new") 2)
  (check-equal? '(("new")) (metrics:label-sets fleeting)))

(metrics:define-metric configured (unit count))

(test "the default retention is ten minutes of raw points, read when a series is made"
  (check-equal? '((raw 600)) (metrics:retention))
  (options:set! metrics:retention '((raw 1)))
  (metrics:record! configured '() 1 (- (timeseries-now) 2))
  (check-equal? #f (metrics:latest configured '()))
  (options:unset! metrics:retention)
  (check-raises assertion-violation? (options:set! metrics:retention '((hourly 1)))))
