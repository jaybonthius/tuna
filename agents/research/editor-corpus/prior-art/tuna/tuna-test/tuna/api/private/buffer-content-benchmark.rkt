#lang racket/base

(require rackunit
         (file "../../../../tuna-bench/buffer-content/run.rkt")
         (file "../../../../tuna-bench/buffer-content/workloads.rkt"))

(define expected-ids
  '("local-trace/20000"
    "local-latency/10m"
    "far-latency/100m"
    "scattered/200/10m"
    "scattered/10000/10m"
    "coordinates/ordinary-10m"
    "coordinates/high-lines-10m"
    "coordinates/long-line-10m"
    "snapshot/cold/1m"
    "snapshot/cold/10m"
    "snapshot/cold/100m"
    "snapshot/cached/1m"
    "snapshot/cached/10m"
    "snapshot/cached/100m"))

(define (middle values)
  (list-ref values (quotient (length values) 2)))

(define (sample value)
  (hasheq 'wallMilliseconds value
          'cpuMilliseconds value
          'allocation (hasheq 'status "available" 'bytes 1)))

(define (fabricated-row item values)
  (define parameters (workload-parameters item))
  (define p99
    (if (eq? (workload-kind item) 'latency)
        (list-ref values 197)
        'null))
  (define gate-definition (workload-gate-definition (workload-id item)))
  (define gate
    (if gate-definition
        (hasheq 'metric (symbol->string (car gate-definition))
                'limit
                (hasheq 'value (cadr gate-definition)
                        'unit (caddr gate-definition))
                'decision "pass"
                'reason "fabricated sample")
        (hasheq 'metric "none"
                'limit 'null
                'decision "not-applicable"
                'reason "characterization only")))
  (define complete-gate
    (if (equal? (workload-id item) "local-trace/20000")
        (hash-set
          gate
          'allocationGate
          (hasheq 'metric "medianAllocationBytes"
                  'limit (hasheq 'value 134217728 'unit "bytes")
                  'decision "pass"
                  'reason "fabricated sample"))
        gate))
  (hasheq 'id (workload-id item)
          'kind (symbol->string (workload-kind item))
          'corpus
          (hasheq 'id (workload-corpus-id item)
                  'byteLength (bytes-length (workload-corpus-bytes item))
                  'sha256 (corpus-hash item))
          'workloadSha256 (workload-hash item)
          'gapStart (hash-ref parameters 'gapPreparation)
          'parameters parameters
          'sampling
          (hasheq 'warmupCount (hash-ref parameters 'warmupCount)
                  'sampleCount (length values)
                  'operationCount (hash-ref parameters 'operationCount)
                  'gc (if (eq? (workload-kind item) 'latency)
                          "none"
                          "before-aggregate-sample"))
          'rawSamples (map sample values)
          'summary
          (hasheq 'medianWallMilliseconds (middle values)
                  'medianCpuMilliseconds (middle values)
                  'medianAllocationBytes 1
                  'p99WallMilliseconds p99)
          'validation
          (hasheq 'passed #t
                  'oracleSha256 (sha256-hex (workload-expected-bytes item)))
          'gate complete-gate))

(define raw-machine
  "Linux tungo 6.8.0-47-generic #47-Ubuntu SMP x86_64")
(define cpu-information
  "model name : AMD Ryzen 9 7940HS w/ Radeon 780M Graphics\n")
(define memory-information "MemTotal:       63556260 kB\n")

(define canonical-actual-host
  (normalize-host-identity "untrusted-environment-name"
                           raw-machine
                           'unix
                           'chez-scheme
                           "9.2"
                           cpu-information
                           memory-information))

(define (fabricated-values item)
  (if (eq? (workload-kind item) 'latency)
      (build-list 200 (lambda (index) (/ index 1000)))
      '(1 2 3 4 5)))

(define fabricated-rows
  (for/list ([item (in-list all-workloads)])
    (fabricated-row item (fabricated-values item))))

(define (fabricated-report [rows fabricated-rows])
  (hasheq 'schema "gap-buffer-benchmark"
          'schemaVersion 1
          'validationScope "structural-consistency"
          'executionProvenance
          (hasheq 'method "runner-in-process-flat-oracle"
                  'allWorkloadsPassed #t)
          'status "complete"
          'approval
          (hasheq 'eligible #t
                  'expectedHost approval-identity
                  'actualHost canonical-actual-host
                  'reason "approval host identity matches")
          'racket (hasheq 'version "9.2" 'vm "chez-scheme")
          'hashAlgorithm "sha256"
          'workloads rows
          'decision "pass"))

(define (replace-row report id transform)
  (hash-set
    report
    'workloads
    (for/list ([row (in-list (hash-ref report 'workloads))])
      (if (equal? (hash-ref row 'id) id) (transform row) row))))

(test-case "corpora and hashes are deterministic exact byte definitions"
  (define local-trace (build-corpus-bytes "local-trace-1m"))
  (define ordinary (build-corpus-bytes "ordinary-10m"))
  (define high-lines (build-corpus-bytes "high-lines-10m"))
  (check-equal? (bytes-length local-trace) 1048576)
  (check-equal? (bytes-ref local-trace 0) (char->integer #\l))
  (check-equal? (bytes-ref local-trace (- (bytes-length local-trace) 1))
                (char->integer #\l))
  (check-equal? (bytes-length ordinary) (* 10 1048576))
  (check-equal? (bytes-length high-lines) (* 10 1048576))
  (check-equal? (bytes-ref ordinary 79) 10)
  (check-equal? (bytes-ref ordinary (- (bytes-length ordinary) 1)) 10)
  (check-equal? (subbytes high-lines 0 4) #"x\nx\n")
  (check-equal? (sha256-hex #"")
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  (check-equal? (corpus-hash "ordinary-10m")
                (corpus-hash "ordinary-10m"))
  (check-true
    (regexp-match? #px"^[0-9a-f]{64}$"
                   (workload-hash (find-workload "scattered/200/10m")))))

(test-case "workload inventory covers every fixed trace and characterization"
  (check-equal? (map workload-id all-workloads) expected-ids)
  (for ([item (in-list all-workloads)])
    (check-equal? (workload-corpus-bytes item)
                  (canonical-corpus-bytes (workload-corpus-id item)))
    (check-true (immutable? (workload-corpus-bytes item)))
    (check-true (immutable? (workload-expected-bytes item)))))

(test-case "local trace records 10,000 canonical insert-backspace pairs"
  (define item (find-workload "local-trace/20000"))
  (define parameters (workload-parameters item))
  (define positions (hash-ref parameters 'positions))
  (check-equal? (workload-corpus-id item) "local-trace-1m")
  (check-equal? (hash-ref parameters 'pairCount) 10000)
  (check-equal? (hash-ref parameters 'editCount) 20000)
  (check-equal? (hash-ref parameters 'operationCount) 20000)
  (check-equal? (hash-ref parameters 'positionFormula)
                "modulo(+(* i 7919)17)(add1 n)")
  (check-equal? (hash-ref parameters 'expectedRollingChecksum)
                2306688552915144371)
  (check-equal? (hash-ref parameters 'rollingChecksumFields)
                '("beforeByteLength"
                  "afterByteLength"
                  "changeCount"
                  "oldStart"
                  "oldEnd"
                  "newStart"
                  "newEnd"
                  "intermediateByteLength"))
  (check-equal? (length positions) 10000)
  (for ([position (in-list positions)] [index (in-naturals)])
    (check-equal? position
                  (modulo (+ (* index 7919) 17)
                          (+ (bytes-length (workload-corpus-bytes item)) 1))))
  (check-equal? (workload-expected-bytes item)
                (workload-corpus-bytes item))
  (define execution ((workload-thunk-builder item)))
  (check-false
    (workload-execution-valid?
      execution
      (list (bytes-length (workload-corpus-bytes item))
            (hash-ref parameters 'rollingChecksumSeed)))))

(test-case "long-line characterization is one explicit worst-case EOF query"
  (define item (find-workload "coordinates/long-line-10m"))
  (define parameters (workload-parameters item))
  (check-equal? (workload-kind item) 'characterization)
  (check-equal? (hash-ref parameters 'operationCount) 1)
  (check-equal? (hash-ref parameters 'queryCount) 1)
  (check-equal? (hash-ref parameters 'queryShape) "single-worst-case-eof")
  (check-equal? (hash-ref parameters 'positions)
                (list (bytes-length (workload-corpus-bytes item)))))

(test-case "independent flat expectations validate fresh public buffer replays"
  (define local (find-workload "local-trace/20000"))
  (define-values (local-passed? local-digest)
    (replay-and-validate! local))
  (define-values (snapshot-passed? snapshot-digest)
    (replay-and-validate! (find-workload "snapshot/cold/1m")))
  (check-true local-passed?)
  (check-true snapshot-passed?)
  (check-equal? local-digest (corpus-hash local))
  (check-equal? snapshot-digest
                (sha256-hex
                  (workload-expected-bytes
                    (find-workload "snapshot/cold/1m")))))

(test-case "host identity uses system evidence and ignores environment spoofing"
  (check-equal? canonical-actual-host
                (hasheq 'hostname "tungo"
                        'hostnameEnvironment "untrusted-environment-name"
                        'hostnameSource "system-machine-uname"
                        'os "unix"
                        'machine "x86_64"
                        'systemMachine raw-machine
                        'kernel "6.8.0-47-generic"
                        'kernelSource "system-machine-uname"
                        'cpuModel
                        "AMD Ryzen 9 7940HS w/ Radeon 780M Graphics"
                        'cpuModelSource "/proc/cpuinfo"
                        'memTotalKb 63556260
                        'memTotalSource "/proc/meminfo"
                        'vm "chez-scheme"
                        'racketVersion "9.2"))
  (check-true (approval-eligible? approval-identity canonical-actual-host))
  (check-equal?
    (hash-ref
      (normalize-host-identity "spoofed-host"
                               raw-machine
                               'unix
                               'chez-scheme
                               "9.2"
                               cpu-information
                               memory-information)
      'hostname)
    "tungo")
  (for ([key (in-list '(hostname kernel cpuModel memTotalKb))])
    (check-false
      (approval-eligible?
        approval-identity
        (hash-set canonical-actual-host key "mismatch")))))

(test-case "fabricated complete report is structurally consistent"
  (define report (fabricated-report))
  (check-true (valid-report? report))
  (check-equal? (report-validation-errors report) '()))

(test-case "report validation requires the canonical workload inventory once"
  (define report (fabricated-report))
  (define rows (hash-ref report 'workloads))
  (check-false (valid-report? (hash-set report 'workloads (cdr rows))))
  (check-false
    (valid-report? (hash-set report 'workloads (cons (car rows) rows))))
  (check-false (valid-report? (hash-set report 'workloads (reverse rows)))))

(test-case "report validation recomputes approval status and decision"
  (define report (fabricated-report))
  (define approval (hash-ref report 'approval))
  (define actual (hash-ref approval 'actualHost))
  (define environment-spoofed
    (hash-set actual 'hostnameEnvironment "attacker-controlled"))
  (check-true
    (valid-report?
      (hash-set report
                'approval
                (hash-set approval 'actualHost environment-spoofed))))
  (for ([key (in-list '(hostname kernel cpuModel memTotalKb))])
    (check-false
      (valid-report?
        (hash-set report
                  'approval
                  (hash-set approval
                            'actualHost
                            (hash-set actual key "mismatch"))))))
  (check-false (valid-report? (hash-set report 'status "unsupported")))
  (check-false (valid-report? (hash-set report 'decision "fail")))
  (check-false
    (valid-report?
      (hash-set report
                'executionProvenance
                (hasheq 'method "runner-in-process-flat-oracle"
                        'allWorkloadsPassed #f)))))

(test-case "report validation rejects schema hash sample and replay failures"
  (define report (fabricated-report))
  (check-false (valid-report? (hash-set report 'schema "other")))
  (check-false (valid-report? (hash-set report 'schemaVersion 2)))
  (check-false
    (valid-report?
      (replace-row report
                   "local-trace/20000"
                   (lambda (row) (hash-set row 'workloadSha256 "bad")))))
  (check-false
    (valid-report?
      (replace-row
        report
        "local-trace/20000"
        (lambda (row)
          (hash-set row
                    'corpus
                    (hash-set (hash-ref row 'corpus) 'sha256 (make-string 64 #\0)))))))
  (check-false
    (valid-report?
      (replace-row
        report
        "local-trace/20000"
        (lambda (row)
          (hash-set row
                    'sampling
                    (hash-set (hash-ref row 'sampling) 'sampleCount 4))))))
  (check-false
    (valid-report?
      (replace-row
        report
        "local-trace/20000"
        (lambda (row)
          (hash-set row
                    'rawSamples
                    (cons (hash-remove (car (hash-ref row 'rawSamples))
                                       'cpuMilliseconds)
                          (cdr (hash-ref row 'rawSamples))))))))
  (check-false
    (valid-report?
      (replace-row
        report
        "local-trace/20000"
        (lambda (row)
          (hash-set row
                    'summary
                    (hash-set (hash-ref row 'summary)
                              'medianWallMilliseconds
                              99))))))
  (check-false
    (valid-report?
      (replace-row
        report
        "local-trace/20000"
        (lambda (row)
          (hash-set row
                    'validation
                    (hash-set (hash-ref row 'validation) 'passed #f)))))))

(test-case "report validation rejects invalid p99 and contradictory gate"
  (define report (fabricated-report))
  (check-false
    (valid-report?
      (replace-row
        report
        "local-latency/10m"
        (lambda (row)
          (hash-set row
                    'summary
                    (hash-set (hash-ref row 'summary)
                              'p99WallMilliseconds
                              196/1000))))))
  (check-false
    (valid-report?
      (replace-row
        report
        "local-trace/20000"
        (lambda (row)
          (hash-set row
                    'gate
                    (hash-set (hash-ref row 'gate) 'decision "fail")))))))
