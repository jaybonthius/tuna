#!tuna
(import (jobs) (timers) (owned) (hooks))

(hooks:define-hook sampled "Called with a source and the time of its reading, after its on-sample procedure returned.")

;; A source's job and timer belong to the module that defined it, so that
;; module's unload or reload stops them; its wants live in owned, keyed by
;; the defining module's name and the source's, so they outlive a reload
;; of that module or of sampler.
(define-record-type (%source %make-source source?)
  (nongenerative)
  (sealed #t)
  (fields module name (mutable definer) (mutable worker) (mutable input) (mutable on-sample)
          (mutable job) (mutable timer) (mutable timer-interval) (mutable reading?) (mutable last-time)
          (mutable failure))
  (protocol
    (lambda (new)
      (lambda (module name)
        (new module name #f #f #f #f #f #f #f #f #f #f)))))

(define %sources (make-hashtable equal-hash equal?))
(define %order '())
(define %main-thread (get-thread-id))

(define (%check-main-thread who)
  (unless (eqv? (get-thread-id) %main-thread)
    (assertion-violation who "not on the main thread")))

(define (%check-source who s)
  (unless (source? s) (assertion-violation who "not a source" s)))

(define (%key s) (cons (%source-module s) (%source-name s)))

(define (%wants s)
  (owned:key-entries %wants-set (%key s)))

(define (%interval s)
  (let ([wants (%wants s)])
    (and (pair? wants) (apply min (map owned:entry-value wants)))))

(define (%as-definer s thunk)
  (call-as-owner (%source-definer s) thunk))

(define (%stop! s)
  (let ([job (%source-job s)] [timer (%source-timer s)])
    (%source-job-set! s #f)
    (%source-timer-set! s #f)
    (%source-timer-interval-set! s #f)
    (%source-reading?-set! s #f)
    (when job (jobs:stop! job))
    (when timer (timers:cancel! timer))))

;; A value or an end from a job that is no longer the source's, such as
;; the last value of a job a restart stopped, is not this source's news.
(define (%start-job! s)
  (let ([started (box #f)])
    (set-box! started
      (%as-definer s
        (lambda ()
          (jobs:start (%source-worker s) ((%source-input s))
            (lambda (v) (%reading-done! s (unbox started) v))
            (lambda (ended) (%job-ended! s (unbox started) ended))))))
    (%source-job-set! s (unbox started))))

(define (%read! s)
  (cond
    [(or (%source-failure s) (%source-reading? s)) (void)]
    [else
     (unless (%source-job s) (%start-job! s))
     (%source-reading?-set! s #t)
     (jobs:send! (%source-job s) 'read)]))

(define (%reading-done! s job v)
  (when (eq? job (%source-job s))
    (%source-reading?-set! s #f)
    (%source-last-time-set! s (car v))
    ((%source-on-sample s) (car v) (cdr v))
    (sampled s (car v))))

;; A worker that raised is reported once, by jobs, and the source stalls
;; until its wants change or it is restarted, so a source that always
;; fails does not fail at every tick. One whose body returned starts again
;; at the next reading.
(define (%job-ended! s job ended)
  (when (eq? job (%source-job s))
    (%source-job-set! s #f)
    (%source-reading?-set! s #f)
    (when ended
      (%source-failure-set! s ended)
      (%stop! s))))

(define (%refresh! s)
  (let ([interval (%interval s)])
    (cond
      [(and interval (not (%source-failure s)) (%live? s))
       (unless (%source-job s) (%read! s))
       (unless (eqv? interval (%source-timer-interval s))
         (when (%source-timer s) (timers:cancel! (%source-timer s)))
         (%source-timer-interval-set! s interval)
         (%source-timer-set! s (%as-definer s (lambda () (timers:run-after interval (lambda () (%read! s)) interval)))))]
      [else (%stop! s)])))

(define (%define-source module name worker input on-sample)
  (unless (jobs:worker? worker) (assertion-violation 'sampler:define-source "not a worker" worker))
  (unless (procedure? input) (assertion-violation 'sampler:define-source "not a procedure" input))
  (unless (procedure? on-sample) (assertion-violation 'sampler:define-source "not a procedure" on-sample))
  (let* ([key (cons module name)]
         [s (or (hashtable-ref %sources key #f)
                (let ([s (%make-source module name)])
                  (hashtable-set! %sources key s)
                  (set! %order (append %order (list s)))
                  s))])
    (%stop! s)
    (%source-definer-set! s (current-owner))
    (%source-worker-set! s worker)
    (%source-input-set! s input)
    (%source-on-sample-set! s on-sample)
    (%source-failure-set! s #f)
    (%refresh! s)
    s))

(define-syntax define-source
  (lambda (x)
    (syntax-case x ()
      [(_ id worker input on-sample)
       (identifier? #'id)
       #'(define-public id (%define-source (owner-name (current-owner)) 'id worker input on-sample))]
      [(_ . rest) (syntax-violation 'sampler:define-source "expected (sampler:define-source id worker input on-sample)" x)])))

(define (%live? s)
  (and (%source-definer s) (owner-live? (%source-definer s))))

(define (want source seconds)
  (%check-main-thread 'sampler:want)
  (%check-source 'sampler:want source)
  (unless (%live? source) (assertion-violation 'sampler:want "the source's module is unloaded" source))
  (unless (and (real? seconds) (finite? seconds) (positive? seconds))
    (assertion-violation 'sampler:want "not a positive number of seconds" seconds))
  (owned:add! %wants-set (%key source) seconds)
  (%source-failure-set! source #f)
  (%refresh! source))

(define (unwant source)
  (%check-main-thread 'sampler:unwant)
  (%check-source 'sampler:unwant source)
  (when (exists (lambda (e) (eq? (owned:entry-owner e) (current-owner))) (%wants source))
    (owned:withdraw! %wants-set (%key source))
    (%source-failure-set! source #f)
    (%refresh! source)))

(define (wants source)
  (%check-source 'sampler:wants source)
  (map (lambda (e) (cons (owned:entry-owner e) (owned:entry-value e))) (%wants source)))

(define (interval source)
  (%check-source 'sampler:interval source)
  (%interval source))

(define (read-now! source)
  (%check-main-thread 'sampler:read-now!)
  (%check-source 'sampler:read-now! source)
  (unless (%interval source) (assertion-violation 'sampler:read-now! "nobody wants the source" source))
  (%read! source))

(define (restart! source)
  (%check-main-thread 'sampler:restart!)
  (%check-source 'sampler:restart! source)
  (when (%interval source)
    (%stop! source)
    (%source-failure-set! source #f)
    (%refresh! source)))

(define (last-time source)
  (%check-source 'sampler:last-time source)
  (%source-last-time source))

(define (failure source)
  (%check-source 'sampler:failure source)
  (%source-failure source))

(define (all) (filter %live? %order))

(define %wants-set (owned:make 'sampler:wants (lambda () (for-each %refresh! %order))))

(record-writer (record-type-descriptor %source)
  (lambda (s p wr) (fprintf p "#<source ~s ~a>" (%source-module s) (%source-name s))))
