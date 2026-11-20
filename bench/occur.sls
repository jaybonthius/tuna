#!tuna
(import (occur) (search) (search-bench) (buffers) (document) (jobs) (views) (layout) (web))

(define (now-ns)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define phases (make-eq-hashtable))

(define (add-phase! name ms) (hashtable-update! phases name (lambda (v) (+ v ms)) 0))

(define filling? #f)

(define (timed name)
  (lambda (proc . args)
    (if filling?
        (let ([start (now-ns)])
          (call-with-values (lambda () (apply proc args))
            (lambda results (add-phase! name (/ (- (now-ns) start) 1e6)) (apply values results))))
        (apply proc args))))

(define occur-start 0)

;; Only occur's grouping job is timed, told apart by its worker's name,
;; which is all a job's worker shows.
(define (time-group-job start worker input on-result . rest)
  (if (string=? (format "~a" worker) "#<worker %group-lines>")
      (let ([job-start (now-ns)])
        (add-phase! 'scan (/ (- job-start occur-start) 1e6))
        (apply start worker input
               (lambda (groups)
                 (let ([fill-start (now-ns)])
                   (add-phase! 'job (/ (- fill-start job-start) 1e6))
                   (set! filling? #t)
                   (on-result groups)
                   (set! filling? #f)
                   (add-phase! 'fill (/ (- (now-ns) fill-start) 1e6))))
               rest))
      (apply start worker input on-result rest)))

(define (occur-ms b q template)
  (let ([old (buffers:find "*Occur*")]) (when old (buffers:kill! old)))
  (layout:switch-to-buffer b)
  (collect-rendezvous)
  (set! occur-start (now-ns))
  (views:call-with-view (layout:selected-view) (lambda () (occur:occur q 0 template)))
  (let wait ()
    (let ([o (buffers:find "*Occur*")])
      (unless (and o (> (document:length (buffers:document o)) 2))
        (sleep-for 0.001)
        (wait))))
  (/ (- (now-ns) occur-start) 1e6))

(define (listing name b q template)
  (hashtable-clear! phases)
  (let ([total (occur-ms b q template)])
    (printf "occur-listed-~a ~,3f\n" name total)
    (for-each (lambda (phase)
                (printf "occur-~a-~a ~,3f\n" phase name (hashtable-ref phases phase 0)))
              '(scan job splice spans))
    (printf "occur-nodes-~a ~,3f\n" name
            (- (hashtable-ref phases 'fill 0) (hashtable-ref phases 'splice 0) (hashtable-ref phases 'spans 0)))))

(define (run)
  (web:add-client! 1)
  (advice-add! jobs:start time-group-job)
  (advice-add! buffers:splice! (timed 'splice))
  (advice-add! buffers:set-spans! (timed 'spans))
  (for-each
    (lambda (name size)
      (let ([b (search-bench:buffer-of (search-bench:sample 'code size))] [q (search:make-query "lambda")])
        (listing name b q #f)
        (listing (string-append "template-" name) b q "\\&")))
    '("1mb" "10mb") '(1000000 10000000)))
