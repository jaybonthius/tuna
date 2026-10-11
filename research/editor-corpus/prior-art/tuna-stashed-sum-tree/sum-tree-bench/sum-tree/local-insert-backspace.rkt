#lang racket/base

(require racket/cmdline
         racket/list
         "text-workloads.rkt"
         "workloads.rkt")

(define seed 20260714)
(define workload-id "text/local-insert-backspace/1048576/e0/r0")
(define sample-count 3)

(command-line
  #:program "local-insert-backspace.rkt"
  #:once-each
  [("-n" "--count") count
   "Measured run count"
   (define parsed (string->number count))
   (unless (exact-positive-integer? parsed)
     (raise-user-error 'local-insert-backspace.rkt
                       "--count requires an exact positive integer"))
   (set! sample-count parsed)])

(define descriptor
  (for/first ([candidate
               (in-list (make-text-workloads seed #:profile 'stage2))]
              #:when (equal? (workload-name candidate) workload-id))
    candidate))

(unless descriptor
  (raise-user-error 'local-insert-backspace.rkt
                    "Stage-2 workload is unavailable: ~a"
                    workload-id))

(define samples
  (for/list ([ordinal (in-range 1 (add1 sample-count))])
    (define prepared ((workload-prepare descriptor)))
    (collect-garbage 'major)
    (define allocation-start (current-memory-use 'cumulative))
    (define wall-start (current-inexact-monotonic-milliseconds))
    (define result ((workload-operate descriptor) prepared))
    (define wall-end (current-inexact-monotonic-milliseconds))
    (define allocation-end (current-memory-use 'cumulative))
    (unless (operation-result? result)
      (raise-user-error 'local-insert-backspace.rkt
                        "workload operation did not return an operation-result"))
    (define digest
      ((workload-validate descriptor) (operation-result-value result)))
    (unless (equal? digest (workload-validation-digest descriptor))
      (raise-user-error 'local-insert-backspace.rkt
                        "workload validation digest mismatch"))
    (define wall (- wall-end wall-start))
    (define allocation (- allocation-end allocation-start))
    (printf "run ~a: wall ~a ms; allocation ~a B\n"
            ordinal wall allocation)
    (cons wall allocation)))

(define (median values)
  (define sorted (sort values <))
  (define count (length sorted))
  (define middle (quotient count 2))
  (if (odd? count)
      (list-ref sorted middle)
      (/ (+ (list-ref sorted (sub1 middle))
            (list-ref sorted middle))
         2.0)))

(printf "median: wall ~a ms; allocation ~a B\n"
        (median (map car samples))
        (median (map cdr samples)))

