#lang racket/base

(require json
         racket/file
         "workloads.rkt")

(provide run-benchmarks
         normalize-host-identity)

(define (identity-value value)
  (if (symbol? value) (symbol->string value) value))

(define (last-value values)
  (if (null? (cdr values))
      (car values)
      (last-value (cdr values))))

(define (matched-field pattern text [fallback ""])
  (define match (regexp-match pattern text))
  (if match (cadr match) fallback))

(define (normalize-host-identity environment-hostname
                                 raw-machine
                                 os
                                 vm
                                 racket-version
                                 cpu-information
                                 memory-information)
  (define machine-string (identity-value raw-machine))
  (define machine-parts (regexp-split #px" +" machine-string))
  (define system-hostname
    (if (> (length machine-parts) 1) (cadr machine-parts) ""))
  (define kernel
    (if (> (length machine-parts) 2) (caddr machine-parts) ""))
  (define architecture
    (if (> (length machine-parts) 1)
        (last-value machine-parts)
        machine-string))
  (define cpu-model
    (matched-field #px"(?m:^model name\\s*:\\s*(.*)$)"
                   cpu-information))
  (define memory-kb
    (string->number
      (matched-field #px"(?m:^MemTotal:\\s*([0-9]+)\\s+kB$)"
                     memory-information
                     "0")))
  (hasheq 'hostname system-hostname
          'hostnameEnvironment (or environment-hostname "")
          'hostnameSource "system-machine-uname"
          'os (identity-value os)
          'machine architecture
          'systemMachine machine-string
          'kernel kernel
          'kernelSource "system-machine-uname"
          'cpuModel cpu-model
          'cpuModelSource "/proc/cpuinfo"
          'memTotalKb memory-kb
          'memTotalSource "/proc/meminfo"
          'vm (identity-value vm)
          'racketVersion racket-version))

(define (read-system-file path)
  (with-handlers ([exn:fail? (lambda (_error) "")])
    (file->string path)))

(define (actual-identity)
  (normalize-host-identity (getenv "HOSTNAME")
                           (system-type 'machine)
                           (system-type 'os)
                           (system-type 'vm)
                           (version)
                           (read-system-file "/proc/cpuinfo")
                           (read-system-file "/proc/meminfo")))

(define (allocation-reading)
  (with-handlers ([exn:fail:unsupported?
                   (lambda (error) (cons #f (exn-message error)))]
                  [exn:fail?
                   (lambda (error) (cons #f (exn-message error)))])
    (cons (current-memory-use 'cumulative) #f)))

(define (measure thunk #:gc? gc?)
  (when gc? (collect-garbage))
  (define allocation-before (allocation-reading))
  (define wall-before (current-inexact-monotonic-milliseconds))
  (define cpu-before (current-process-milliseconds))
  (define result (thunk))
  (define cpu-after (current-process-milliseconds))
  (define wall-after (current-inexact-monotonic-milliseconds))
  (define allocation-after
    (if (car allocation-before)
        (allocation-reading)
        allocation-before))
  (define allocation
    (if (and (car allocation-before) (car allocation-after))
        (hasheq 'status "available"
                'bytes (- (car allocation-after) (car allocation-before)))
        (hasheq 'status "unsupported"
                'reason (or (cdr allocation-before)
                            (cdr allocation-after)
                            "cumulative allocation unavailable"))))
  (values result
          (hasheq 'wallMilliseconds (- wall-after wall-before)
                  'cpuMilliseconds (- cpu-after cpu-before)
                  'allocation allocation)))

(define (median values)
  (list-ref (sort values <) (quotient (length values) 2)))

(define (nearest-rank-p99 values)
  (define sorted (sort values <))
  (list-ref sorted (- (ceiling (* 99/100 (length sorted))) 1)))

(define (run-aggregate item)
  (define warmup ((workload-thunk-builder item)))
  (define warmup-result ((workload-execution-thunk warmup)))
  (define valid? (workload-execution-valid? warmup warmup-result))
  (define samples '())
  (for ([_ (in-range 5)])
    (define execution ((workload-thunk-builder item)))
    (define-values (result sample)
      (measure (workload-execution-thunk execution) #:gc? #t))
    (set! samples (cons sample samples))
    (unless (workload-execution-valid? execution result) (set! valid? #f)))
  (values (reverse samples) valid?))

(define (run-latency item)
  (define execution ((workload-thunk-builder item)))
  (for ([_ (in-range 20)])
    ((workload-execution-thunk execution)))
  (define samples
    (for/list ([_ (in-range 200)])
      (define-values (_result sample)
        (measure (workload-execution-thunk execution) #:gc? #f))
      sample))
  (values samples (workload-execution-valid? execution 220)))

(define (summarize item samples)
  (define walls (map (lambda (sample) (hash-ref sample 'wallMilliseconds)) samples))
  (define cpus (map (lambda (sample) (hash-ref sample 'cpuMilliseconds)) samples))
  (define available-allocations
    (for/list ([sample (in-list samples)]
               #:when (equal? (hash-ref (hash-ref sample 'allocation) 'status)
                              "available"))
      (hash-ref (hash-ref sample 'allocation) 'bytes)))
  (hasheq 'medianWallMilliseconds (median walls)
          'medianCpuMilliseconds (median cpus)
          'medianAllocationBytes
          (if (= (length available-allocations) (length samples))
              (median available-allocations)
              'null)
          'p99WallMilliseconds
          (if (eq? (workload-kind item) 'latency)
              (nearest-rank-p99 walls)
              'null)))

(define (gate-for item summary eligible? valid?)
  (define definition (workload-gate-definition (workload-id item)))
  (define reason
    (cond
      [(not valid?) "oracle replay failed"]
      [(not eligible?) "approval host identity mismatch"]
      [(not definition) "characterization only"]
      [else "measured value compared with fixed limit"]))
  (define decision
    (cond
      [(or (not eligible?) (not definition)) "not-applicable"]
      [(not valid?) "fail"]
      [(<= (hash-ref summary (car definition)) (cadr definition)) "pass"]
      [else "fail"]))
  (define gate
    (hasheq 'metric (if definition (symbol->string (car definition)) "none")
            'limit
            (if definition
                (hasheq 'value (cadr definition) 'unit (caddr definition))
                'null)
            'decision decision
            'reason reason))
  (if (equal? (workload-id item) "local-trace/20000")
      (let* ([allocation (hash-ref summary 'medianAllocationBytes)]
             [allocation-decision
              (cond
                [(not eligible?) "not-applicable"]
                [(not (exact-nonnegative-integer? allocation)) "fail"]
                [(<= allocation 134217728) "pass"]
                [else "fail"])]
             [overall
              (cond
                [(and (equal? decision "pass")
                      (equal? allocation-decision "pass"))
                 "pass"]
                [eligible? "fail"]
                [else "not-applicable"])])
        (hash-set
          (hash-set gate 'decision overall)
          'allocationGate
          (hasheq 'metric "medianAllocationBytes"
                  'limit (hasheq 'value 134217728 'unit "bytes")
                  'decision allocation-decision
                  'reason
                  (if (exact-nonnegative-integer? allocation)
                      "measured value compared with fixed limit"
                      "cumulative allocation unavailable"))))
      gate))

(define (sampling-for item)
  (define parameters (workload-parameters item))
  (hasheq 'warmupCount (hash-ref parameters 'warmupCount)
          'sampleCount (hash-ref parameters 'sampleCount)
          'operationCount (hash-ref parameters 'operationCount)
          'gc (if (eq? (workload-kind item) 'latency)
                  "none"
                  "before-aggregate-sample")))

(define (run-row item eligible?)
  (define-values (samples valid?)
    (if (eq? (workload-kind item) 'latency)
        (run-latency item)
        (run-aggregate item)))
  (define summary (summarize item samples))
  (define parameters (workload-parameters item))
  (hasheq 'id (workload-id item)
          'kind (symbol->string (workload-kind item))
          'corpus
          (hasheq 'id (workload-corpus-id item)
                  'byteLength (bytes-length (workload-corpus-bytes item))
                  'sha256 (corpus-hash item))
          'workloadSha256 (workload-hash item)
          'gapStart (hash-ref parameters 'gapPreparation)
          'parameters parameters
          'sampling (sampling-for item)
          'rawSamples samples
          'summary summary
          'validation
          (hasheq 'passed valid?
                  'oracleSha256 (sha256-hex (workload-expected-bytes item)))
          'gate (gate-for item summary eligible? valid?)))

(define (run-benchmarks)
  (define identity (actual-identity))
  (define eligible? (approval-eligible? approval-identity identity))
  (define rows
    (for/list ([item (in-list all-workloads)])
      (eprintf "benchmark: starting ~a\n" (workload-id item))
      (define row (run-row item eligible?))
      (eprintf "benchmark: completed ~a\n" (workload-id item))
      row))
  (define valid-replays?
    (andmap (lambda (row)
              (hash-ref (hash-ref row 'validation) 'passed))
            rows))
  (define failed-applicable-gate?
    (ormap (lambda (row)
             (equal? (hash-ref (hash-ref row 'gate) 'decision) "fail"))
           rows))
  (define allocation-unsupported?
    (for/or ([row (in-list rows)]
             #:when (equal? (hash-ref row 'id) "local-trace/20000"))
      (eq? (hash-ref (hash-ref row 'summary) 'medianAllocationBytes) 'null)))
  (define decision
    (cond
      [(not valid-replays?) "invalid"]
      [(not eligible?) "not-approval-host"]
      [failed-applicable-gate? "fail"]
      [else "pass"]))
  (define report
    (hasheq 'schema "gap-buffer-benchmark"
            'schemaVersion 1
            'validationScope "structural-consistency"
            'executionProvenance
            (hasheq 'method "runner-in-process-flat-oracle"
                    'allWorkloadsPassed valid-replays?)
            'status (cond
                      [(not valid-replays?) "invalid"]
                      [(and eligible? allocation-unsupported?) "unsupported"]
                      [else "complete"])
            'approval
            (hasheq 'eligible eligible?
                    'expectedHost approval-identity
                    'actualHost identity
                    'reason
                    (if eligible?
                        "approval host identity matches"
                        "system hostname, OS, machine, kernel, CPU, memory, VM, or Racket version mismatch"))
            'racket (hasheq 'version (version)
                            'vm (identity-value (system-type 'vm)))
            'hashAlgorithm "sha256"
            'workloads rows
            'decision decision))
  (define validation-errors (report-validation-errors report))
  (if (null? validation-errors)
      report
      (hash-set
        (hash-set (hash-set report 'status "invalid") 'decision "invalid")
        'reportValidationErrors
        validation-errors)))

(define (write-report-atomically path report)
  (define-values (base _name _directory?) (split-path path))
  (define directory (if (path? base) base (current-directory)))
  (make-directory* directory)
  (define temporary (make-temporary-file "gap-buffer-benchmark-~a.json" #f directory))
  (with-handlers ([exn:fail?
                   (lambda (error)
                     (when (file-exists? temporary) (delete-file temporary))
                     (raise error))])
    (call-with-output-file temporary
      (lambda (output)
        (write-json report output)
        (newline output))
      #:exists 'truncate)
    (rename-file-or-directory temporary path #t)))

(module+ main
  (define arguments (vector->list (current-command-line-arguments)))
  (define report-path
    (and (= (length arguments) 2)
         (equal? (car arguments) "--report")
         (cadr arguments)))
  (unless report-path
    (raise-user-error 'buffer-content-benchmark
                      "expected exactly --report PATH"))
  (define report (run-benchmarks))
  (write-report-atomically report-path report)
  (unless (member (hash-ref report 'decision) '("pass" "not-approval-host"))
    (exit 1)))
