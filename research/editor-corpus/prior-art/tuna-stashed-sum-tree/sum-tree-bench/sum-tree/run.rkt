#lang racket/base

(require json
         racket/file
         racket/list
         racket/port
         racket/runtime-path
         "text-workloads.rkt"
         "workloads.rkt")

(provide benchmark-schema
         benchmark-investigation-schema
         benchmark-schema-version
         benchmark-gate-budget-seconds
         benchmark-characterization-warmup-count
         benchmark-characterization-sample-count
         required-workload-keys
         required-metric-keys
         make-minimal-benchmark-report
         make-benchmark-report
         benchmark-report-exit-code
         validate-benchmark-report
         read-benchmark-report
         write-benchmark-report
         publish-benchmark-result
         authorize-benchmark-output-path
         sampled-memory-peak
         make-untimed-workload-row
         parse-command-line
         run-benchmarks)

(define benchmark-schema "sum-tree-stage2-benchmark")
(define benchmark-investigation-schema "sum-tree-non-contract-benchmark")
(define benchmark-schema-version 2)
(define authoritative-profile 'stage2)
(define-runtime-path repository-root "../..")

(define (profile-schema profile)
  (if (eq? profile authoritative-profile)
      benchmark-schema
      benchmark-investigation-schema))
(define benchmark-gate-budget-seconds 900)
(define benchmark-gate-budget-exhausted-reason
  "900-second absolute policy budget exceeded")
(define benchmark-characterization-warmup-count 2)
(define benchmark-characterization-sample-count 20)

(define required-workload-keys
  '(schema schemaVersion workloadId name profile class policy parameters seed
           hashAlgorithm replayHash corpusHash validationDigest racketVersion
           runtime host warmupCount sampleCount rawSamples metrics
           totalElapsedMilliseconds structuralCounters structuralBounds
           structuralModel structuralEvidenceProvenance))

(define required-metric-keys '(operationWallMilliseconds))
(define required-sample-keys
  '(wallMilliseconds cpuMilliseconds allocationBytes
                     liveMemoryAfterMajorGcBytes peakMemoryBytes gcMilliseconds
                     totalElapsedMilliseconds))
(define required-runtime-keys
  '(family vm gc version peakMemoryKind liveMemoryKind
           cumulativeAllocationAvailability
           cumulativeAllocationUnavailableReason))
(define required-host-keys '(os architecture machineType hostname))

(struct sample (wall cpu allocation live peak gc elapsed))
(struct cumulative-allocation-capability (available? reason))
(struct scheduled-workload (descriptor class warmup-count sample-count))

(define schedule-identity-keys
  '(workloadId name profile class policy parameters seed hashAlgorithm
               replayHash corpusHash validationDigest))

(define (scheduled-workload-identity scheduled seed profile)
  (define descriptor (scheduled-workload-descriptor scheduled))
  (define name (workload-name descriptor))
  (define class (scheduled-workload-class scheduled))
  (define warmups (scheduled-workload-warmup-count scheduled))
  (define samples (scheduled-workload-sample-count scheduled))
  (hasheq 'workloadId name
          'name name
          'profile (symbol->string profile)
          'class (symbol->string class)
          'policy (policy-for class warmups samples)
          'parameters (workload-parameters descriptor)
          'seed seed
          'hashAlgorithm benchmark-hash-algorithm
          'replayHash (workload-replay-hash descriptor)
          'corpusHash (workload-corpus-hash descriptor)
          'validationDigest (workload-validation-digest descriptor)))

(define (schedule-row-identity row)
  (for/hasheq ([key (in-list schedule-identity-keys)])
    (values key (hash-ref row key))))

(define (fail who message . fields)
  (apply raise-arguments-error who message fields))

(define (require-hash who value label)
  (unless (hash? value)
    (fail who "expected a JSON object" "field" label "value" value)))

(define (require-keys who object keys label)
  (require-hash who object label)
  (for ([key (in-list keys)] #:unless (hash-has-key? object key))
    (fail who "missing required JSON key" "object" label "key" key)))

(define (finite-nonnegative-number? value)
  (and (real? value) (rational? value) (>= value 0)))

(define (hash-digest? value)
  (and (string? value) (regexp-match? #px"^[0-9a-f]{40}$" value)))

(define (json-string-or-null? value)
  (or (string? value) (eq? value 'null)))

(define (validate-runtime who runtime allocation-values)
  (require-keys who runtime required-runtime-keys 'runtime)
  (for ([entry (in-list '((family . "racket-cs")
                          (vm . "chez-scheme")
                          (gc . "cs")
                          (peakMemoryKind . "sampled-workload-process-memory")
                          (liveMemoryKind . "post-major-gc-live-memory")))])
    (unless (equal? (hash-ref runtime (car entry)) (cdr entry))
      (fail who "runtime field mismatch"
            "field" (car entry)
            "expected" (cdr entry)
            "actual" (hash-ref runtime (car entry)))))
  (unless (string? (hash-ref runtime 'version))
    (fail who "runtime version must be a string"))
  (define availability (hash-ref runtime 'cumulativeAllocationAvailability))
  (define reason (hash-ref runtime 'cumulativeAllocationUnavailableReason))
  (case (string->symbol availability)
    [(available)
     (unless (and (andmap exact-nonnegative-integer? allocation-values)
                  (eq? reason 'null))
       (fail who "available cumulative allocation metadata is inconsistent"))]
    [(unavailable)
     (unless (and (andmap (lambda (value) (eq? value 'null)) allocation-values)
                  (string? reason)
                  (positive? (string-length reason)))
       (fail who "unavailable cumulative allocation metadata is inconsistent"))]
    [else (fail who "unsupported cumulative allocation availability"
                "value" availability)]))

(define (validate-host who host)
  (require-keys who host required-host-keys 'host)
  (for ([key (in-list required-host-keys)]
        #:unless (json-string-or-null? (hash-ref host key)))
    (fail who "host field must be string or null"
          "field" key "value" (hash-ref host key))))

(define (validate-integer-object who object label #:allow-null? [allow-null? #f])
  (require-hash who object label)
  (for ([(key value) (in-hash object)]
        #:unless (or (exact-nonnegative-integer? value)
                     (and allow-null? (eq? value 'null))))
    (fail who "structural value must be a nonnegative integer or permitted null"
          "object" label "key" key "value" value)))

(define (validate-sample who value)
  (require-keys who value required-sample-keys 'rawSample)
  (for ([key (in-list (remove 'allocationBytes required-sample-keys))]
        #:unless (finite-nonnegative-number? (hash-ref value key)))
    (fail who "sample metric must be a finite nonnegative number"
          "field" key "value" (hash-ref value key)))
  (define allocation (hash-ref value 'allocationBytes))
  (unless (or (exact-nonnegative-integer? allocation) (eq? allocation 'null))
    (fail who "sample allocation must be a nonnegative integer or null"
          "value" allocation)))

(define (validate-profile-class who row report-profile)
  (define row-profile (hash-ref row 'profile))
  (unless (equal? row-profile report-profile)
    (fail who "workload profile does not match report profile"
          "report profile" report-profile
          "workload profile" row-profile))
  (define class (hash-ref row 'class))
  (define allowed-classes
    (if (equal? report-profile "gate")
        '("timing" "stress" "evidence")
        '("characterization")))
  (unless (member class allowed-classes)
    (fail who "workload class does not belong to report profile"
          "report profile" report-profile
          "workload class" class)))

(define (validate-policy who row)
  (define class (hash-ref row 'class))
  (define policy (hash-ref row 'policy))
  (require-keys who policy '(measurement warmupCount sampleCount) 'policy)
  (define warmups (hash-ref row 'warmupCount))
  (define samples (hash-ref row 'sampleCount))
  (unless (and (exact-nonnegative-integer? warmups)
               (exact-nonnegative-integer? samples)
               (= warmups (hash-ref policy 'warmupCount))
               (= samples (hash-ref policy 'sampleCount)))
    (fail who "row policy and counts disagree"))
  (case (string->symbol class)
    [(timing)
     (unless (and (= warmups 1) (= samples 3)
                  (equal? (hash-ref policy 'measurement) "timed"))
       (fail who "gate timing policy mismatch"))]
    [(stress)
     (unless (and (zero? warmups) (= samples 1)
                  (equal? (hash-ref policy 'measurement) "timed-stress-single-sample"))
       (fail who "gate stress policy mismatch"))]
    [(evidence)
     (unless (and (zero? warmups) (zero? samples)
                  (equal? (hash-ref policy 'measurement) "untimed-single-replay"))
       (fail who "gate evidence policy mismatch"))]
    [(characterization)
     (unless (and (= warmups benchmark-characterization-warmup-count)
                  (= samples benchmark-characterization-sample-count)
                  (equal? (hash-ref policy 'measurement) "timed"))
       (fail who "characterization policy mismatch"))]
    [else (fail who "unknown row class" "value" class)]))

(define (validate-wall-summary who metrics raw-samples evidence?)
  (require-keys who metrics required-metric-keys 'metrics)
  (define wall (hash-ref metrics 'operationWallMilliseconds))
  (cond
    [evidence?
     (unless (eq? wall 'null)
       (fail who "untimed evidence must not have a wall summary"))]
    [else
     (define walls
       (sort (map (lambda (entry) (hash-ref entry 'wallMilliseconds))
                  raw-samples)
             <))
     (require-keys who wall '(median minimum maximum) 'operationWallMilliseconds)
     (for ([key (in-list '(median minimum maximum))]
           #:unless (finite-nonnegative-number? (hash-ref wall key)))
       (fail who "wall summary must be finite and nonnegative"
             "field" key "value" (hash-ref wall key)))
     (unless (and (= (hash-ref wall 'minimum) (car walls))
                  (= (hash-ref wall 'maximum) (last walls))
                  (= (hash-ref wall 'median) (median walls)))
       (fail who "wall summary does not match raw samples"))]))

(define (validate-workload-row who row report-seed report-profile)
  (require-keys who row required-workload-keys 'workload)
  (unless (and (equal? (hash-ref row 'schema)
                       (profile-schema (string->symbol report-profile)))
               (= (hash-ref row 'schemaVersion) benchmark-schema-version))
    (fail who "workload schema mismatch"))
  (unless (and (string? (hash-ref row 'workloadId))
               (equal? (hash-ref row 'workloadId) (hash-ref row 'name)))
    (fail who "workload ID and name must be the same nonempty string"))
  (validate-profile-class who row report-profile)
  (unless (= (hash-ref row 'seed) report-seed)
    (fail who "workload seed mismatch"))
  (unless (equal? (hash-ref row 'hashAlgorithm) benchmark-hash-algorithm)
    (fail who "unsupported workload hash algorithm"))
  (for ([key (in-list '(replayHash corpusHash validationDigest))]
        #:unless (hash-digest? (hash-ref row key)))
    (fail who "invalid lowercase workload digest" "field" key))
  (require-hash who (hash-ref row 'parameters) 'parameters)
  (validate-policy who row)
  (define raw-samples (hash-ref row 'rawSamples))
  (unless (and (list? raw-samples)
               (= (length raw-samples) (hash-ref row 'sampleCount)))
    (fail who "raw sample count mismatch"))
  (for ([value (in-list raw-samples)]) (validate-sample who value))
  (define evidence? (equal? (hash-ref row 'class) "evidence"))
  (validate-wall-summary who (hash-ref row 'metrics) raw-samples evidence?)
  (validate-runtime who (hash-ref row 'runtime)
                    (map (lambda (value) (hash-ref value 'allocationBytes)) raw-samples))
  (validate-host who (hash-ref row 'host))
  (unless (finite-nonnegative-number? (hash-ref row 'totalElapsedMilliseconds))
    (fail who "row total elapsed must be finite and nonnegative"))
  (define text-row?
    (equal? (hash-ref (hash-ref row 'parameters) 'domain #f) "text"))
  (validate-integer-object who (hash-ref row 'structuralCounters)
                           'structuralCounters #:allow-null? text-row?)
  (validate-integer-object who (hash-ref row 'structuralBounds)
                           'structuralBounds #:allow-null? text-row?)
  (unless (and (string? (hash-ref row 'structuralModel))
               (equal? (hash-ref row 'structuralEvidenceProvenance)
                       "untimed-single-replay"))
    (fail who "structural evidence provenance mismatch")))

(define comparison-keys
  '(corpusHash replayHash scaleBytes barrierId snapshotPopulation))

(define (comparison-value row key)
  (if (memq key '(corpusHash replayHash))
      (hash-ref row key)
      (hash-ref (hash-ref row 'parameters) key #f)))

(define (validate-comparable-controls who rows)
  (define groups (make-hash))
  (for ([row (in-list rows)])
    (define parameters (hash-ref row 'parameters))
    (define id (hash-ref parameters 'comparisonId #f))
    (when id
      (hash-set! groups id (cons row (hash-ref groups id '())))))
  (for ([(id members) (in-hash groups)] #:when (> (length members) 1))
    (define reference (car members))
    (for* ([row (in-list (cdr members))]
           [key (in-list comparison-keys)])
      (unless (equal? (comparison-value reference key) (comparison-value row key))
        (fail who "non-comparable rows share a comparison ID"
              "comparisonId" id "field" key)))))

(define (validate-benchmark-report/expected-schedule report expected-schedule)
  (define who 'validate-benchmark-report)
  (require-keys who report
                '(schema schemaVersion hashAlgorithm profile seed status
                         approvalEligible policyBudgetSeconds
                         totalElapsedMilliseconds incompleteReason workloads)
                'report)
  (define profile (hash-ref report 'profile))
  (unless (member profile '("stage2" "gate" "characterization" "tiny"))
    (fail who "report profile is unsupported" "value" profile))
  (unless (and (equal? (hash-ref report 'schema)
                       (profile-schema (string->symbol profile)))
               (= (hash-ref report 'schemaVersion) benchmark-schema-version)
               (equal? (hash-ref report 'hashAlgorithm) benchmark-hash-algorithm))
    (fail who "report schema mismatch"))
  (define seed (hash-ref report 'seed))
  (unless (exact-nonnegative-integer? seed)
    (fail who "report seed must be a nonnegative integer"))
  (define status (hash-ref report 'status))
  (unless (member status '("complete" "incomplete"))
    (fail who "report status is unsupported"))
  (define approval? (hash-ref report 'approvalEligible))
  (unless (boolean? approval?)
    (fail who "approval eligibility must be boolean"))
  (when (and approval?
             (or (not (equal? status "complete"))
                 (not (equal? profile "stage2"))))
    (fail who "only a complete Stage-2 report can be approval-eligible"))
  (define policy-budget (hash-ref report 'policyBudgetSeconds))
  (define total-elapsed (hash-ref report 'totalElapsedMilliseconds))
  (unless (and (exact-positive-integer? policy-budget)
               (finite-nonnegative-number? total-elapsed))
    (fail who "report budget metadata is invalid"))
  (when (and (equal? profile "gate")
             (not (= policy-budget benchmark-gate-budget-seconds)))
    (fail who "gate report policy budget mismatch"
          "expected" benchmark-gate-budget-seconds
          "actual" policy-budget))
  (define reason (hash-ref report 'incompleteReason))
  (unless (if (equal? status "incomplete")
              (and (string? reason) (positive? (string-length reason)))
              (eq? reason 'null))
    (fail who "incomplete reason is inconsistent with status"))
  (when (and (equal? profile "gate")
             (>= total-elapsed (* 1000 benchmark-gate-budget-seconds))
             (not (and (equal? status "incomplete")
                       (equal? reason benchmark-gate-budget-exhausted-reason))))
    (fail who "gate report exhausted policy budget without incomplete status"))
  (define rows (hash-ref report 'workloads))
  (unless (list? rows)
    (fail who "report workloads must be a JSON array"))
  (for ([row (in-list rows)])
    (validate-workload-row who row seed profile))
  (unless (= (length rows)
             (length (remove-duplicates (map (lambda (row) (hash-ref row 'workloadId)) rows))))
    (fail who "report workload IDs must be unique"))
  (validate-comparable-controls who rows)
  (let ()
    (define profile-symbol (string->symbol profile))
    (define schedule
      (or expected-schedule (benchmark-schedule seed profile-symbol)))
    (define expected-identities
      (for/list ([scheduled (in-list schedule)])
        (scheduled-workload-identity scheduled seed profile-symbol)))
    (define actual-identities (map schedule-row-identity rows))
    (case profile-symbol
      [(gate)
       (unless (and (<= (length actual-identities)
                        (length expected-identities))
                    (equal? actual-identities
                            (take expected-identities
                                  (length actual-identities))))
         (fail who "gate report workloads must be an exact ordered schedule prefix"))
       (when (and (equal? status "complete")
                  (< (length actual-identities) (length expected-identities)))
         (fail who "complete gate report schedule is incomplete"))]
      [(stage2 characterization tiny)
       (unless (and (equal? status "complete")
                    (equal? actual-identities expected-identities))
         (fail who
               "full-inventory report must be complete with its exact ordered schedule"))]))
  report)

(define (validate-benchmark-report report)
  (validate-benchmark-report/expected-schedule report #f))

(define (probe-cumulative-allocation)
  (with-handlers ([exn:fail?
                   (lambda (exception)
                     (cumulative-allocation-capability #f (exn-message exception)))])
    (define value (current-memory-use 'cumulative))
    (if (exact-nonnegative-integer? value)
        (cumulative-allocation-capability #t #f)
        (cumulative-allocation-capability
          #f
          (format "current-memory-use cumulative returned ~e" value)))))

(define (runtime-metadata capability)
  (define gc (system-type 'gc))
  (define vm (system-type 'vm))
  (hasheq 'family (if (and (eq? gc 'cs) (eq? vm 'chez-scheme))
                      "racket-cs"
                      "unsupported")
          'vm (format "~a" vm)
          'gc (format "~a" gc)
          'version (version)
          'peakMemoryKind "sampled-workload-process-memory"
          'liveMemoryKind "post-major-gc-live-memory"
          'cumulativeAllocationAvailability
          (if (cumulative-allocation-capability-available? capability)
              "available"
              "unavailable")
          'cumulativeAllocationUnavailableReason
          (if (cumulative-allocation-capability-available? capability)
              'null
              (cumulative-allocation-capability-reason capability))))

(define (host-metadata)
  (define hostname (getenv "HOSTNAME"))
  (hasheq 'os (format "~a" (system-type 'os))
          'architecture (format "~a" (system-type 'arch))
          'machineType (let ([machine (system-type 'machine)])
                         (if machine (format "~a" machine) 'null))
          'hostname (if hostname hostname 'null)))

(define (cumulative-allocation-value capability)
  (and (cumulative-allocation-capability-available? capability)
       (let ([value (current-memory-use 'cumulative)])
         (unless (exact-nonnegative-integer? value)
           (fail 'run-benchmarks
                 "current-memory-use cumulative changed capability"
                 "value" value))
         value)))

(define (sampled-memory-peak boundary-samples checkpoints)
  (unless (and (list? boundary-samples) (pair? boundary-samples)
               (andmap exact-nonnegative-integer? boundary-samples)
               (list? checkpoints)
               (andmap exact-nonnegative-integer? checkpoints))
    (raise-arguments-error 'sampled-memory-peak
                           "memory samples must be nonempty nonnegative integer lists"
                           "boundary samples" boundary-samples
                           "checkpoints" checkpoints))
  (apply max (append boundary-samples checkpoints)))

(define (measure-workload-once descriptor capability)
  (define total-start (current-inexact-monotonic-milliseconds))
  (define prepared ((workload-prepare descriptor)))
  (collect-garbage 'major)
  (define start-memory (current-memory-use))
  (define start-allocation (cumulative-allocation-value capability))
  (define start-cpu (current-process-milliseconds))
  (define start-gc (current-gc-milliseconds))
  (define start-wall (current-inexact-monotonic-milliseconds))
  (define result ((workload-operate descriptor) prepared))
  (define end-wall (current-inexact-monotonic-milliseconds))
  (define end-cpu (current-process-milliseconds))
  (define end-gc (current-gc-milliseconds))
  (define end-allocation (cumulative-allocation-value capability))
  (define end-memory (current-memory-use))
  (unless (operation-result? result)
    (fail 'run-benchmarks "workload operation did not return an operation-result"
          "workload" (workload-name descriptor)))
  (define checkpoints (operation-result-memory-checkpoints result))
  (unless (and (list? checkpoints) (andmap exact-nonnegative-integer? checkpoints))
    (fail 'run-benchmarks "workload memory checkpoints are invalid"))
  (define peak-memory
    (sampled-memory-peak (list start-memory end-memory) checkpoints))
  (collect-garbage 'major)
  (define live-memory (current-memory-use))
  (define digest ((workload-validate descriptor) (operation-result-value result)))
  (unless (equal? digest (workload-validation-digest descriptor))
    (fail 'run-benchmarks "workload validation digest mismatch"
          "workload" (workload-name descriptor)))
  (sample (- end-wall start-wall)
          (- end-cpu start-cpu)
          (if start-allocation
              (max 0 (- end-allocation start-allocation))
              'null)
          live-memory
          peak-memory
          (- end-gc start-gc)
          (- (current-inexact-monotonic-milliseconds) total-start)))

(define (median sorted)
  (define count (length sorted))
  (define middle (quotient count 2))
  (if (odd? count)
      (list-ref sorted middle)
      (/ (+ (list-ref sorted (sub1 middle)) (list-ref sorted middle)) 2.0)))

(define (sample->jsexpr value)
  (hasheq 'wallMilliseconds (sample-wall value)
          'cpuMilliseconds (sample-cpu value)
          'allocationBytes (sample-allocation value)
          'liveMemoryAfterMajorGcBytes (sample-live value)
          'peakMemoryBytes (sample-peak value)
          'gcMilliseconds (sample-gc value)
          'totalElapsedMilliseconds (sample-elapsed value)))

(define (summarize-samples values)
  (cond
    [(null? values) (hasheq 'operationWallMilliseconds 'null)]
    [else
     (define walls (sort (map sample-wall values) <))
     (hasheq 'operationWallMilliseconds
             (hasheq 'median (median walls)
                     'minimum (car walls)
                     'maximum (last walls)))]))

(define (policy-for class warmups samples)
  (hasheq 'measurement
          (case class
            [(stress) "timed-stress-single-sample"]
            [(evidence) "untimed-single-replay"]
            [else "timed"])
          'warmupCount warmups
          'sampleCount samples))

(define (measure-descriptor descriptor seed profile class warmups sample-count capability)
  (define started (current-inexact-monotonic-milliseconds))
  (define measured
    (cond
      [(eq? class 'evidence) '()]
      [else
       (for ([_ (in-range warmups)])
         (measure-workload-once descriptor capability))
       (for/list ([_ (in-range sample-count)])
         (measure-workload-once descriptor capability))]))
  (define-values (counters bounds model) ((workload-evidence descriptor)))
  (hasheq 'schema (profile-schema profile)
          'schemaVersion benchmark-schema-version
          'workloadId (workload-name descriptor)
          'name (workload-name descriptor)
          'profile (symbol->string profile)
          'class (symbol->string class)
          'policy (policy-for class warmups sample-count)
          'parameters (workload-parameters descriptor)
          'seed seed
          'hashAlgorithm benchmark-hash-algorithm
          'replayHash (workload-replay-hash descriptor)
          'corpusHash (workload-corpus-hash descriptor)
          'validationDigest (workload-validation-digest descriptor)
          'racketVersion (version)
          'runtime (runtime-metadata capability)
          'host (host-metadata)
          'warmupCount warmups
          'sampleCount sample-count
          'rawSamples (map sample->jsexpr measured)
          'metrics (summarize-samples measured)
          'totalElapsedMilliseconds
          (- (current-inexact-monotonic-milliseconds) started)
          'structuralCounters counters
          'structuralBounds bounds
          'structuralModel model
          'structuralEvidenceProvenance "untimed-single-replay"))

(define (make-untimed-workload-row descriptor seed
                                   #:profile [profile 'gate]
                                   #:class [class 'evidence])
  (unless (workload? descriptor)
    (raise-argument-error 'make-untimed-workload-row "workload?" descriptor))
  (unless (exact-nonnegative-integer? seed)
    (raise-argument-error 'make-untimed-workload-row
                          "exact-nonnegative-integer?" seed))
  (measure-descriptor descriptor seed profile class 0 0
                      (probe-cumulative-allocation)))

(define text-child-row-environment-name #"TUNA_TEXT_BENCHMARK_ROW")
(define text-child-profile-environment-name #"TUNA_TEXT_BENCHMARK_PROFILE")
(define benchmark-progress-heartbeat-seconds 30)

(define (emit-benchmark-progress phase ordinal total name class warmups samples)
  (define output (current-error-port))
  (fprintf output
           "sum-tree-benchmark: [~a/~a] ~a ~a class=~a warmups=~a samples=~a\n"
           ordinal total phase name class warmups samples)
  (flush-output output))

(define (emit-benchmark-heartbeat ordinal total name elapsed-seconds)
  (define output (current-error-port))
  (fprintf output "sum-tree-benchmark: [~a/~a] running ~a (~as elapsed)\n"
           ordinal total name elapsed-seconds)
  (flush-output output))

(define (call-with-benchmark-heartbeat ordinal total name thunk)
  (define stopped (make-semaphore 0))
  (define started (current-inexact-monotonic-milliseconds))
  (define heartbeat
    (thread
      (lambda ()
        (let loop ()
          (unless (sync/timeout benchmark-progress-heartbeat-seconds stopped)
            (emit-benchmark-heartbeat
              ordinal total name
              (inexact->exact
                (floor (/ (- (current-inexact-monotonic-milliseconds) started)
                          1000.0))))
            (loop))))))
  (dynamic-wind void thunk
                (lambda ()
                  (semaphore-post stopped)
                  (thread-wait heartbeat))))

(define (validate-workload-row/test row seed profile)
  (validate-workload-row 'validate-workload-row/test row seed profile)
  row)

(define (validate-comparable-controls/test rows)
  (validate-comparable-controls 'validate-comparable-controls/test rows))

(define (benchmark-schedule-identities/test seed profile)
  (for/list ([scheduled (in-list (benchmark-schedule seed profile))])
    (scheduled-workload-identity scheduled seed profile)))

(module+ test-support
  (provide emit-benchmark-progress emit-benchmark-heartbeat
           summarize-samples sample make-synthetic-benchmark-report
           validate-workload-row/test validate-comparable-controls/test
           benchmark-schedule-identities/test
           write-benchmark-report-json/test))

(define (make-benchmark-report* seed profile rows total-elapsed
                                expected-schedule status reason approval?)
  (validate-benchmark-report/expected-schedule
    (hasheq 'schema (profile-schema profile)
            'schemaVersion benchmark-schema-version
            'hashAlgorithm benchmark-hash-algorithm
            'profile (symbol->string profile)
            'seed seed
            'status (symbol->string status)
            'approvalEligible approval?
            'policyBudgetSeconds benchmark-gate-budget-seconds
            'totalElapsedMilliseconds total-elapsed
            'incompleteReason (or reason 'null)
            'workloads rows)
    expected-schedule))

(define (make-benchmark-report seed profile rows total-elapsed
                               #:status [status 'complete]
                               #:reason [reason #f]
                               #:approval? [approval?
                                            (and (eq? profile authoritative-profile)
                                                 (eq? status 'complete))])
  (make-benchmark-report* seed profile rows total-elapsed #f status reason approval?))

(define (make-synthetic-benchmark-report seed profile rows elapsed budget-exceeded?)
  (make-benchmark-report
    seed profile rows elapsed
    #:status (if budget-exceeded? 'incomplete 'complete)
    #:reason (and budget-exceeded? benchmark-gate-budget-exhausted-reason)))

(define (benchmark-report-exit-code report)
  (validate-benchmark-report report)
  (if (equal? (hash-ref report 'status) "complete") 0 2))

(define (entry->scheduled entry)
  (scheduled-workload (text-benchmark-entry-descriptor entry)
                      (text-benchmark-entry-class entry)
                      (text-benchmark-entry-warmup-count entry)
                      (text-benchmark-entry-sample-count entry)))

(define (characterization-stage1-schedule seed)
  (for/list ([descriptor (in-list (make-stage1-workloads seed))])
    (scheduled-workload descriptor 'characterization
                        benchmark-characterization-warmup-count
                        benchmark-characterization-sample-count)))

(define (benchmark-schedule seed profile)
  (append
    (if (eq? profile 'characterization)
        (characterization-stage1-schedule seed)
        '())
    (map entry->scheduled
         (make-text-workload-entries seed #:profile profile))))

(define (text-scheduled-workload? scheduled)
  (equal? (hash-ref
            (workload-parameters (scheduled-workload-descriptor scheduled))
            'domain
            #f)
          "text"))

(define (find-text-scheduled schedule name)
  (or (for/first ([scheduled (in-list schedule)]
                  #:when
                  (and (text-scheduled-workload? scheduled)
                       (equal? (workload-name
                                 (scheduled-workload-descriptor scheduled))
                               name)))
        scheduled)
      (fail 'run-benchmarks "unknown internal text benchmark row" "name" name)))

(define (read-child-report output-path scheduled seed profile)
  (define expected-name
    (workload-name (scheduled-workload-descriptor scheduled)))
  (define report
    (read-benchmark-report/expected-schedule output-path (list scheduled)))
  (define rows (hash-ref report 'workloads))
  (unless (and (= (hash-ref report 'seed) seed)
               (equal? (hash-ref report 'profile) (symbol->string profile))
               (= (length rows) 1)
               (equal? (hash-ref (car rows) 'name) expected-name))
    (fail 'run-benchmarks "fresh text benchmark process returned the wrong row"
          "workload" expected-name))
  (car rows))

(define (measure-text-in-fresh-process scheduled seed profile ordinal total deadline)
  (define descriptor (scheduled-workload-descriptor scheduled))
  (define name (workload-name descriptor))
  (define output-path (make-temporary-file "tuna-text-benchmark-row~a.json"))
  (define environment
    (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! environment text-child-row-environment-name
                              (string->bytes/utf-8 name))
  (environment-variables-set! environment text-child-profile-environment-name
                              (string->bytes/utf-8 (symbol->string profile)))
  (dynamic-wind
    void
    (lambda ()
      (define racket
        (or (find-executable-path "racket")
            (error 'run-benchmarks "could not find racket")))
      (define-values (process child-output child-input child-error)
        (parameterize ([current-environment-variables environment])
          (subprocess #f #f #f racket
                      (path->complete-path "sum-tree-bench/sum-tree/run.rkt")
                      "--seed" (number->string seed)
                      "--output" (path->string output-path)
                      "--profile" (symbol->string profile))))
      (close-output-port child-input)
      (define remaining
        (and deadline
             (max 0 (/ (- deadline (current-inexact-monotonic-milliseconds))
                       1000.0))))
      (define completed?
        (call-with-benchmark-heartbeat
          ordinal total name
          (lambda ()
            (cond
              [remaining (sync/timeout remaining process)]
              [else
               (subprocess-wait process)
               process]))))
      (unless completed?
        (subprocess-kill process #t)
        (subprocess-wait process))
      (define stdout (port->string child-output))
      (define stderr (port->string child-error))
      (close-input-port child-output)
      (close-input-port child-error)
      (cond
        [(not completed?) #f]
        [(not (zero? (subprocess-status process)))
         (fail 'run-benchmarks "fresh text benchmark process failed"
               "workload" name "stdout" stdout "stderr" stderr)]
        [else (read-child-report output-path scheduled seed profile)]))
    (lambda ()
      (when (file-exists? output-path) (delete-file output-path)))))

(define (run-benchmarks seed #:profile [profile authoritative-profile])
  (unless (exact-nonnegative-integer? seed)
    (raise-argument-error 'run-benchmarks "exact-nonnegative-integer?" seed))
  (unless (memq profile '(stage2 gate characterization tiny))
    (raise-argument-error 'run-benchmarks
                          "(or/c 'stage2 'gate 'characterization 'tiny)" profile))
  (define started (current-inexact-monotonic-milliseconds))
  (define deadline
    (and (eq? profile 'gate)
         (+ started (* 1000.0 benchmark-gate-budget-seconds))))
  (define schedule (benchmark-schedule seed profile))
  (define child-name-bytes
    (environment-variables-ref (current-environment-variables)
                               text-child-row-environment-name))
  (cond
    [child-name-bytes
     (define child-profile-bytes
       (environment-variables-ref (current-environment-variables)
                                  text-child-profile-environment-name))
     (unless (and child-profile-bytes
                  (equal? (bytes->string/utf-8 child-profile-bytes)
                          (symbol->string profile)))
       (fail 'run-benchmarks "child benchmark profile marker mismatch"))
     (define scheduled
       (find-text-scheduled schedule (bytes->string/utf-8 child-name-bytes)))
     (define row
       (measure-descriptor
         (scheduled-workload-descriptor scheduled) seed profile
         (scheduled-workload-class scheduled)
         (scheduled-workload-warmup-count scheduled)
         (scheduled-workload-sample-count scheduled)
         (probe-cumulative-allocation)))
     (make-benchmark-report*
       seed profile (list row)
       (- (current-inexact-monotonic-milliseconds) started)
       (list scheduled) 'complete #f #f)]
    [else
     (define stage1
       (filter-not text-scheduled-workload? schedule))
     (define text-schedule
       (filter text-scheduled-workload? schedule))
     (define total (+ (length stage1) (length text-schedule)))
     (define rows '())
     (define timed-out? #f)
     (for ([scheduled (in-list stage1)]
           [ordinal (in-naturals 1)])
       (define descriptor (scheduled-workload-descriptor scheduled))
       (emit-benchmark-progress
         "starting" ordinal total (workload-name descriptor)
         (scheduled-workload-class scheduled)
         (scheduled-workload-warmup-count scheduled)
         (scheduled-workload-sample-count scheduled))
       (define row
         (measure-descriptor descriptor seed profile
                             (scheduled-workload-class scheduled)
                             (scheduled-workload-warmup-count scheduled)
                             (scheduled-workload-sample-count scheduled)
                             (probe-cumulative-allocation)))
       (set! rows (cons row rows))
       (emit-benchmark-progress
         "completed" ordinal total (workload-name descriptor)
         (scheduled-workload-class scheduled)
         (scheduled-workload-warmup-count scheduled)
         (scheduled-workload-sample-count scheduled)))
     (for ([scheduled (in-list text-schedule)]
           [ordinal (in-naturals (add1 (length stage1)))]
           #:break timed-out?)
       (define descriptor (scheduled-workload-descriptor scheduled))
       (define name (workload-name descriptor))
       (emit-benchmark-progress
         "starting" ordinal total name
         (scheduled-workload-class scheduled)
         (scheduled-workload-warmup-count scheduled)
         (scheduled-workload-sample-count scheduled))
       (define row
         (measure-text-in-fresh-process
           scheduled seed profile ordinal total deadline))
       (cond
         [row
          (set! rows (cons row rows))
          (emit-benchmark-progress
            "completed" ordinal total name
            (scheduled-workload-class scheduled)
            (scheduled-workload-warmup-count scheduled)
            (scheduled-workload-sample-count scheduled))]
         [else (set! timed-out? #t)]))
     (define elapsed (- (current-inexact-monotonic-milliseconds) started))
     (define budget-exceeded?
       (or timed-out?
           (and (eq? profile 'gate)
                (>= elapsed (* 1000.0 benchmark-gate-budget-seconds)))))
     (define status (if budget-exceeded? 'incomplete 'complete))
     (define reason
       (and budget-exceeded? benchmark-gate-budget-exhausted-reason))
     (make-benchmark-report*
       seed profile (reverse rows) elapsed schedule status reason
       (and (eq? profile authoritative-profile)
            (eq? status 'complete)))]))

(define (make-minimal-benchmark-report)
  (define seed 20260714)
  (define scheduled
    (car (benchmark-schedule seed 'gate)))
  (define descriptor (scheduled-workload-descriptor scheduled))
  (define identity (scheduled-workload-identity scheduled seed 'gate))
  (define raw-sample
    (hasheq 'wallMilliseconds 1.0
            'cpuMilliseconds 1
            'allocationBytes 1
            'liveMemoryAfterMajorGcBytes 1
            'peakMemoryBytes 1
            'gcMilliseconds 0
            'totalElapsedMilliseconds 2.0))
  (define raw (make-list 3 raw-sample))
  (define row
    (hasheq 'schema (profile-schema 'gate)
            'schemaVersion benchmark-schema-version
            'workloadId (hash-ref identity 'workloadId)
            'name (hash-ref identity 'name)
            'profile (hash-ref identity 'profile)
            'class (hash-ref identity 'class)
            'policy (hash-ref identity 'policy)
            'parameters (workload-parameters descriptor)
            'seed seed
            'hashAlgorithm benchmark-hash-algorithm
            'replayHash (workload-replay-hash descriptor)
            'corpusHash (workload-corpus-hash descriptor)
            'validationDigest (workload-validation-digest descriptor)
            'racketVersion (version)
            'runtime
            (hasheq 'family "racket-cs" 'vm "chez-scheme" 'gc "cs"
                    'version (version)
                    'peakMemoryKind "sampled-workload-process-memory"
                    'liveMemoryKind "post-major-gc-live-memory"
                    'cumulativeAllocationAvailability "available"
                    'cumulativeAllocationUnavailableReason 'null)
            'host
            (hasheq 'os "fixture" 'architecture "fixture"
                    'machineType 'null 'hostname 'null)
            'warmupCount 1
            'sampleCount 3
            'rawSamples raw
            'metrics
            (hasheq 'operationWallMilliseconds
                    (hasheq 'median 1.0 'minimum 1.0 'maximum 1.0))
            'totalElapsedMilliseconds 2.0
            'structuralCounters (hasheq 'operationCount 1)
            'structuralBounds (hasheq 'B 32)
            'structuralModel "fixture"
            'structuralEvidenceProvenance "untimed-single-replay"))
  (make-benchmark-report seed 'gate (list row) 2.0
                         #:status 'incomplete
                         #:reason "fixture partial report"
                         #:approval? #f))

(define (json-trailing-whitespace? value)
  (for/and ([character (in-string value)])
    (memv character '(#\space #\tab #\return #\newline))))

(define (read-benchmark-report/expected-schedule input-path expected-schedule)
  (call-with-input-file input-path
    (lambda (input)
      (define report (read-json input))
      (unless (json-trailing-whitespace? (port->string input))
        (fail 'read-benchmark-report
              "trailing non-JSON whitespace follows the report"))
      (validate-benchmark-report/expected-schedule report expected-schedule))))

(define (read-benchmark-report input-path)
  (read-benchmark-report/expected-schedule input-path #f))

(define (normalized-output-path path)
  (simplify-path (path->complete-path path) #f))

(define (canonical-benchmark-output-path)
  (simplify-path
    (path->complete-path
      (build-path repository-root ".state" "sum-tree-benchmark.json"))
    #f))

(define (canonical-benchmark-output-path? target)
  (define-values (target-parent target-name _target-directory?)
    (split-path target))
  (define-values (canonical-parent canonical-name _canonical-directory?)
    (split-path (canonical-benchmark-output-path)))
  (and (equal? target-name canonical-name)
       (path? target-parent)
       (path? canonical-parent)
       (with-handlers ([exn:fail:filesystem? (lambda (_exception) #f)])
         (equal? (file-or-directory-identity target-parent)
                 (file-or-directory-identity canonical-parent)))))

(define (authorize-benchmark-output-path profile output-path
                                         #:child? [child? #f])
  (define target (normalized-output-path output-path))
  (when (canonical-benchmark-output-path? target)
    (unless (and (eq? profile authoritative-profile) (not child?))
      (fail 'sum-tree-benchmark
            "only the Stage-2 coordinator may publish the canonical artifact"
            "profile" profile
            "child mode" child?)))
  target)

(define (write-benchmark-report-json report output-path)
  (define target (path->complete-path output-path))
  (make-parent-directory* target)
  (call-with-atomic-output-file
    target
    (lambda (output _temporary-path)
      (write-json report output)
      (newline output)))
  (void))

(define write-benchmark-report-json/test write-benchmark-report-json)

(define (publish-benchmark-result report output-path
                                  #:profile
                                  [profile
                                   (string->symbol (hash-ref report 'profile))]
                                  #:exit-code [exit-code #f]
                                  #:before-publish [before-publish void])
  (define report-profile (string->symbol (hash-ref report 'profile)))
  (unless (eq? profile report-profile)
    (fail 'publish-benchmark-result
          "publication profile does not match the candidate report"
          "publication profile" profile
          "report profile" report-profile))
  (define target
    (authorize-benchmark-output-path profile output-path))
  (validate-benchmark-report report)
  (define final-exit-code
    (if exit-code exit-code (benchmark-report-exit-code report)))
  (unless (exact-nonnegative-integer? final-exit-code)
    (raise-argument-error 'publish-benchmark-result
                          "exact-nonnegative-integer?" final-exit-code))
  (unless (and (zero? final-exit-code)
               (equal? (hash-ref report 'status) "complete"))
    (fail 'publish-benchmark-result
          "only a complete zero-status result can be published"
          "status" (hash-ref report 'status)
          "exit code" final-exit-code))
  (make-parent-directory* target)
  (define-values (base _name _directory?) (split-path target))
  (define parent (if (path? base) base (current-directory)))
  (define candidate
    (make-temporary-file ".sum-tree-benchmark-candidate~a.json" #f parent))
  (with-handlers ([exn?
                   (lambda (exception)
                     (when (file-exists? candidate) (delete-file candidate))
                     (raise exception))])
    (call-with-output-file candidate
      #:exists 'truncate
      (lambda (output)
        (write-json report output)
        (newline output)))
    (define read-back (read-benchmark-report candidate))
    (unless (equal? read-back report)
      (fail 'publish-benchmark-result "candidate JSON changed during read-back"))
    (before-publish)
    (rename-file-or-directory candidate target #t)))

(define (write-benchmark-report report output-path)
  (publish-benchmark-result report output-path))

(define (write-child-benchmark-report report output-path profile)
  (define target
    (authorize-benchmark-output-path profile output-path #:child? #t))
  (write-benchmark-report-json report target))

(define (parse-seed value)
  (define parsed (string->number value))
  (unless (exact-nonnegative-integer? parsed)
    (fail 'sum-tree-benchmark
          "--seed requires an exact nonnegative integer" "value" value))
  parsed)

(define (parse-profile value)
  (define profile (string->symbol value))
  (unless (memq profile '(stage2 gate characterization tiny))
    (fail 'sum-tree-benchmark
          "--profile requires stage2, gate, characterization, or tiny"
          "value" value))
  profile)

(define (parse-command-line arguments)
  (let loop ([remaining arguments] [seed #f] [output #f]
             [profile authoritative-profile]
             [profile-seen? #f])
    (cond
      [(null? remaining)
       (unless seed (fail 'sum-tree-benchmark "missing required --seed argument"))
       (unless output (fail 'sum-tree-benchmark "missing required --output argument"))
       (values seed output profile)]
      [(and (pair? (cdr remaining))
            (string=? (car remaining) "--seed") (not seed))
       (loop (cddr remaining) (parse-seed (cadr remaining)) output
             profile profile-seen?)]
      [(and (pair? (cdr remaining))
            (string=? (car remaining) "--output") (not output))
       (loop (cddr remaining) seed (cadr remaining)
             profile profile-seen?)]
      [(and (pair? (cdr remaining))
            (string=? (car remaining) "--profile") (not profile-seen?))
       (loop (cddr remaining) seed output
             (parse-profile (cadr remaining)) #t)]
      [else
       (fail 'sum-tree-benchmark
             "unsupported or duplicate command-line argument"
             "argument" (car remaining))])))

(module+ main
  (define-values (seed output profile)
    (parse-command-line (vector->list (current-command-line-arguments))))
  (define child?
    (and (environment-variables-ref (current-environment-variables)
                                    text-child-row-environment-name)
         #t))
  (authorize-benchmark-output-path profile output #:child? child?)
  (define report (run-benchmarks seed #:profile profile))
  (cond
    [child? (write-child-benchmark-report report output profile)]
    [else
     (define exit-code (benchmark-report-exit-code report))
     (unless (zero? exit-code) (exit exit-code))
     (publish-benchmark-result report output #:profile profile
                               #:exit-code exit-code)]))

