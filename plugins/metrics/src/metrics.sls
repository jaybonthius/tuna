#!tuna
(import (sampler) (hooks) (options) (plain-data) (timeseries))

(define (%level? v)
  (and (list? v)
       (or (and (= (length v) 2) (eq? (car v) 'raw) (real? (cadr v)) (finite? (cadr v)) (positive? (cadr v)))
           (and (= (length v) 3) (eq? (car v) 'step)
                (for-all (lambda (n) (and (real? n) (finite? n) (positive? n))) (cdr v))))))

(define (%levels? v)
  (and (list? v) (pair? v) (for-all %level? v) (<= (length (filter (lambda (l) (eq? (car l) 'raw)) v)) 1)))

(options:define-option retention '((raw 600)) %levels?
  "The levels a metric keeps when it names none: (raw seconds) keeps raw points, (step width retention) keeps buckets.")

(hooks:define-hook recorded "Called with a metric, its labels, the value and the time after each point is kept.")

;; A metric keeps its identity when its module reloads, so a view that
;; holds it goes on; its history goes with the module's unload.
(define-record-type (%metric %make-metric metric?)
  (nongenerative)
  (sealed #t)
  (fields module name (mutable unit) (mutable label-names) (mutable levels) (mutable source) (mutable documentation)
          (mutable definer) series (mutable next) (mutable dropping?))
  (protocol
    (lambda (new)
      (lambda (module name)
        (new module name #f '() #f #f #f #f (make-hashtable equal-hash equal?) 0 #f)))))

(define-record-type (%series %make-series %series?)
  (nongenerative)
  (sealed #t)
  (fields points order (mutable dropped)))

(define %metrics (make-hashtable equal-hash equal?))
(define %order '())
(define %main-thread (get-thread-id))

;; A clock that steps back drops points in every series a source fills,
;; so drops are counted per source and reading, and reported once.
(define %drops (make-eq-hashtable))
(define %dropping (make-eq-hashtable))

(define (%check-main-thread who)
  (unless (eqv? (get-thread-id) %main-thread)
    (assertion-violation who "not on the main thread")))

(define (%check-metric who m)
  (unless (metric? m) (assertion-violation who "not a metric" m)))

(define (%check-live who m)
  (unless (%metric-definer m) (assertion-violation who "the metric's module is unloaded" m)))

(define (%check-labels who m labels)
  (unless (and (list? labels) (= (length labels) (length (%metric-label-names m))) (plain-data:plain-data? labels))
    (assertion-violation who "not one plain datum per label" labels (%metric-label-names m))))

(define (%define-metric module name unit label-names levels source documentation)
  (unless (symbol? unit) (assertion-violation 'metrics:define-metric "not a unit" unit))
  (unless (or (not levels) (%levels? levels)) (assertion-violation 'metrics:define-metric "not retention levels" levels))
  (unless (or (not source) (sampler:source? source))
    (assertion-violation 'metrics:define-metric "not a source" source))
  (unless (or (not documentation) (string? documentation))
    (assertion-violation 'metrics:define-metric "not a documentation string" documentation))
  (let* ([key (cons module name)]
         [m (or (hashtable-ref %metrics key #f)
                (let ([m (%make-metric module name)])
                  (hashtable-set! %metrics key m)
                  m))])
    (hashtable-clear! (%metric-series m))
    (%metric-unit-set! m unit)
    (%metric-label-names-set! m label-names)
    (%metric-levels-set! m levels)
    (%metric-source-set! m source)
    (%metric-documentation-set! m documentation)
    (%metric-definer-set! m (current-owner))
    (%metric-dropping?-set! m #f)
    (unless (memq m %order) (set! %order (append %order (list m))))
    m))

(define-syntax define-metric
  (lambda (x)
    (define (clause-named? c name)
      (syntax-case c ()
        [(k . rest) (and (identifier? #'k) (eq? (syntax->datum #'k) name))]
        [_ #f]))
    (define (find-clause clauses name)
      (let ([found (filter (lambda (c) (clause-named? c name)) clauses)])
        (when (> (length found) 1) (syntax-violation 'metrics:define-metric "a clause given twice" x (car found)))
        (and (pair? found) (car found))))
    (syntax-case x ()
      [(_ id clause ...)
       (identifier? #'id)
       (let ([clauses #'(clause ...)])
         (for-each
           (lambda (c)
             (unless (exists (lambda (name) (clause-named? c name)) '(unit labels retain source documentation))
               (syntax-violation 'metrics:define-metric "not a clause: unit, labels, retain, source or documentation" x c)))
           clauses)
         (with-syntax ([unit (syntax-case (find-clause clauses 'unit) ()
                               [(_ u) (identifier? #'u) #''u]
                               [#f (syntax-violation 'metrics:define-metric "a metric needs a unit" x)]
                               [c (syntax-violation 'metrics:define-metric "expected (unit symbol)" x #'c)])]
                       [labels (syntax-case (find-clause clauses 'labels) ()
                                 [(_ name ...) (for-all identifier? #'(name ...)) #''(name ...)]
                                 [#f #''()]
                                 [c (syntax-violation 'metrics:define-metric "expected (labels name ...)" x #'c)])]
                       [levels (syntax-case (find-clause clauses 'retain) ()
                                 [(_ level ...) #''(level ...)]
                                 [#f #'#f])]
                       [source (syntax-case (find-clause clauses 'source) ()
                                 [(_ s) #'s]
                                 [#f #'#f]
                                 [c (syntax-violation 'metrics:define-metric "expected (source source)" x #'c)])]
                       [documentation (syntax-case (find-clause clauses 'documentation) ()
                                        [(_ d) #'d]
                                        [#f #'#f]
                                        [c (syntax-violation 'metrics:define-metric "expected (documentation string)" x #'c)])])
           #'(define-public id
               (%define-metric (owner-name (current-owner)) 'id unit labels levels source documentation))))]
      [(_ . rest) (syntax-violation 'metrics:define-metric "expected (metrics:define-metric id clause ...)" x)])))

;; The retention is read when a series is made, so a setting made after
;; a metric was defined still applies to it.
(define (%new-series m)
  (let* ([levels (or (%metric-levels m) (retention))]
         [raw (find (lambda (l) (eq? (car l) 'raw)) levels)])
    (%metric-next-set! m (+ (%metric-next m) 1))
    (%make-series
      (apply make-timeseries (if raw (cadr raw) 0)
             (map (lambda (l) (make-tier (cadr l) (caddr l))) (filter (lambda (l) (eq? (car l) 'step)) levels)))
      (%metric-next m)
      0)))

(define (%prune! m labels series now)
  (timeseries-prune! (%series-points series) now)
  (unless (timeseries-latest (%series-points series))
    (hashtable-delete! (%metric-series m) labels)))

(define (%prune-all! m)
  (let ([now (timeseries-now)])
    (let-values ([(keys all-series) (hashtable-entries (%metric-series m))])
      (vector-for-each (lambda (labels series) (%prune! m labels series now)) keys all-series))))

(define (%series-now m labels)
  (let ([series (hashtable-ref (%metric-series m) labels #f)])
    (when series (%prune! m labels series (timeseries-now)))
    (hashtable-ref (%metric-series m) labels #f)))

(define (%warn who message . irritants)
  (report (condition (make-warning) (make-who-condition who) (make-message-condition message)
                     (make-irritants-condition irritants))))

(define (%dropped! m series)
  (%series-dropped-set! series (+ (%series-dropped series) 1))
  (let ([source (%metric-source m)])
    (cond
      [source (hashtable-update! %drops source (lambda (n) (+ n 1)) 0)]
      [(not (%metric-dropping? m))
       (%metric-dropping?-set! m #t)
       (%warn 'metrics:record! "a point not after its series' newest was dropped" m)])))

(define (%kept! m)
  (unless (%metric-source m) (%metric-dropping?-set! m #f)))

(define record!
  (case-lambda
    [(m labels value) (record! m labels value (timeseries-now))]
    [(m labels value time)
     (%check-main-thread 'metrics:record!)
     (%check-metric 'metrics:record! m)
     (%check-live 'metrics:record! m)
     (%check-labels 'metrics:record! m labels)
     (unless (and (real? value) (finite? value)) (assertion-violation 'metrics:record! "not a finite value" value))
     (unless (and (real? time) (finite? time)) (assertion-violation 'metrics:record! "not a finite time" time))
     (let* ([table (%metric-series m)]
            [series (or (hashtable-ref table labels #f)
                        (let ([series (%new-series m)])
                          (hashtable-set! table labels series)
                          series))]
            [points (%series-points series)]
            [newest (timeseries-latest points)]
            [time (inexact time)]
            [value (inexact value)])
       (cond
         [(and newest (<= time (car newest)))
          (%dropped! m series)
          #f]
         [else
          (timeseries-add! points time value)
          (%kept! m)
          (recorded m labels value time)
          (unless (%metric-source m) (%prune-all! m))
          #t]))]))

;; After each reading of a source, its drops are reported once and the
;; series of its metrics are pruned, so history stays bounded while
;; nobody reads it.
(define (%after-reading source time)
  (let ([drops (hashtable-ref %drops source 0)])
    (hashtable-delete! %drops source)
    (cond
      [(zero? drops) (hashtable-delete! %dropping source)]
      [(not (hashtable-ref %dropping source #f))
       (hashtable-set! %dropping source #t)
       (%warn 'metrics:record! "points not after their series' newest were dropped from a reading" source drops)]))
  (for-each (lambda (m) (when (eq? (%metric-source m) source) (%prune-all! m))) %order))

(define (latest m labels)
  (%check-main-thread 'metrics:latest)
  (%check-metric 'metrics:latest m)
  (let ([series (%series-now m labels)])
    (and series (timeseries-latest (%series-points series)))))

(define points
  (case-lambda
    [(m labels) (points m labels -inf.0 +inf.0)]
    [(m labels from) (points m labels from +inf.0)]
    [(m labels from to)
     (%check-main-thread 'metrics:points)
     (%check-metric 'metrics:points m)
     (let ([series (%series-now m labels)])
       (if series (timeseries-points (%series-points series) from to) '()))]))

(define (buckets m labels from to step)
  (%check-main-thread 'metrics:buckets)
  (%check-metric 'metrics:buckets m)
  (let ([series (%series-now m labels)])
    (if series (timeseries-buckets (%series-points series) from to step) '())))

(define (label-sets m)
  (%check-main-thread 'metrics:label-sets)
  (%check-metric 'metrics:label-sets m)
  (%prune-all! m)
  (let-values ([(keys all-series) (hashtable-entries (%metric-series m))])
    (map car
         (list-sort (lambda (a b) (< (cdr a) (cdr b)))
                    (map (lambda (labels series) (cons labels (%series-order series)))
                         (vector->list keys) (vector->list all-series))))))

(define (dropped m labels)
  (%check-metric 'metrics:dropped m)
  (let ([series (hashtable-ref (%metric-series m) labels #f)])
    (if series (%series-dropped series) 0)))

(define (source m) (%check-metric 'metrics:source m) (%metric-source m))

(define (unit m) (%check-metric 'metrics:unit m) (%metric-unit m))

(define (label-names m) (%check-metric 'metrics:label-names m) (%metric-label-names m))

(define (documentation m) (%check-metric 'metrics:documentation m) (%metric-documentation m))

(define (all) (filter %metric-definer %order))

(hooks:add! sampler:sampled %after-reading)

(advice-add! owner-unloading
  (lambda (next owner)
    (next owner)
    (for-each
      (lambda (m)
        (when (eq? (%metric-definer m) owner)
          (%metric-definer-set! m #f)
          (hashtable-clear! (%metric-series m))))
      %order)))

(record-writer (record-type-descriptor %metric)
  (lambda (m p wr) (fprintf p "#<metric ~s ~a>" (%metric-module m) (%metric-name m))))
