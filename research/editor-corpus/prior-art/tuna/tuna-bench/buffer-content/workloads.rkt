#lang racket/base

(require json
         openssl/sha1
         racket/list
         tuna/api/private/buffer-content)

(provide
  (struct-out workload)
  (struct-out workload-execution)
  all-workloads
  find-workload
  build-corpus-bytes
  canonical-corpus-bytes
  canonical-workload-bytes
  sha256-hex
  corpus-hash
  workload-hash
  workload-gate-definition
  approval-identity
  approval-eligible?
  workload-execution-valid?
  replay-and-validate!
  report-validation-errors
  valid-report?)

(struct workload
  (id kind corpus-id corpus-bytes parameters expected-bytes thunk-builder)
  #:transparent)
(struct workload-execution (content thunk expected-bytes expected-result)
  #:transparent)

(define mib 1048576)
(define checksum-seed 1469598103934665603)
(define checksum-multiplier 1099511628211)
(define checksum-modulus 18446744073709551616)

(define approval-identity
  (hasheq 'hostname "tungo"
          'os "unix"
          'machine "x86_64"
          'kernel "6.8.0-47-generic"
          'cpuModel "AMD Ryzen 9 7940HS w/ Radeon 780M Graphics"
          'memTotalKb 63556260
          'vm "chez-scheme"
          'racketVersion "9.2"))

(define (approval-eligible? expected actual)
  (and (equal? expected approval-identity)
       (hash? actual)
       (for/and ([(key value) (in-hash approval-identity)])
         (equal? (hash-ref actual key #f) value))))

(define (checksum-fields checksum fields)
  (for/fold ([result checksum]) ([value (in-list fields)])
    (modulo (+ (* result checksum-multiplier) value) checksum-modulus)))
(define ordinary-line
  (bytes->immutable-bytes (bytes-append (make-bytes 79 (char->integer #\o)) #"\n")))

(define (repeated-byte byte length)
  (bytes->immutable-bytes (make-bytes length byte)))

(define (repeat-pattern pattern length)
  (define result (make-bytes length))
  (define width (bytes-length pattern))
  (let loop ([position 0])
    (when (< position length)
      (bytes-copy! result position pattern 0 (min width (- length position)))
      (loop (+ position width))))
  (bytes->immutable-bytes result))

(define empty-corpus #"")
(define local-trace-corpus (repeated-byte (char->integer #\l) mib))
(define ordinary-corpus (repeat-pattern ordinary-line (* 10 mib)))
(define high-lines-corpus (repeat-pattern #"x\n" (* 10 mib)))
(define long-line-corpus (repeated-byte (char->integer #\a) (* 10 mib)))
(define snapshot-1m-corpus (repeated-byte (char->integer #\s) mib))
(define snapshot-10m-corpus (repeated-byte (char->integer #\s) (* 10 mib)))
(define snapshot-100m-corpus (repeated-byte (char->integer #\s) (* 100 mib)))

(define (build-corpus-bytes id)
  (cond
    [(equal? id "empty") empty-corpus]
    [(equal? id "local-trace-1m") local-trace-corpus]
    [(equal? id "ordinary-10m") ordinary-corpus]
    [(equal? id "high-lines-10m") high-lines-corpus]
    [(equal? id "long-line-10m") long-line-corpus]
    [(equal? id "snapshot-1m") snapshot-1m-corpus]
    [(equal? id "snapshot-10m") snapshot-10m-corpus]
    [(equal? id "snapshot-100m") snapshot-100m-corpus]
    [else (raise-arguments-error 'build-corpus-bytes "unknown corpus" "id" id)]))

(define (canonical-corpus-bytes id)
  (build-corpus-bytes id))

(define (sha256-hex bytes)
  (bytes->hex-string (sha256-bytes bytes)))

(define (corpus-hash value)
  (sha256-hex
    (if (workload? value)
        (workload-corpus-bytes value)
        (build-corpus-bytes value))))

(define (canonical-workload-bytes item)
  (string->bytes/utf-8
    (jsexpr->string
      (hasheq 'id (workload-id item)
              'kind (symbol->string (workload-kind item))
              'corpus
              (hasheq 'id (workload-corpus-id item)
                      'byteLength (bytes-length (workload-corpus-bytes item))
                      'sha256 (corpus-hash item))
              'parameters (workload-parameters item)))))

(define (workload-hash item)
  (sha256-hex (canonical-workload-bytes item)))

(define (immutable-replace old start end replacement)
  (bytes->immutable-bytes
    (bytes-append (subbytes old 0 start)
                  replacement
                  (subbytes old end))))

(define (apply-one! content start end replacement)
  (buffer-content-apply!
    content
    (list (content-edit start end (bytes->immutable-bytes replacement)))))

(define (even-offsets length count #:include-end? [include-end? #f])
  (cond
    [(= count 1) '(0)]
    [else
     (define maximum (if include-end? length (- length 1)))
     (for/list ([index (in-range count)])
       (quotient (* index maximum) (- count 1)))]))

(define (sequential-expected initial operations)
  (define result (bytes-copy initial))
  (for ([operation (in-list operations)])
    (define start (car operation))
    (define end (cadr operation))
    (define replacement (caddr operation))
    (unless (= (- end start) (bytes-length replacement))
      (raise-arguments-error 'sequential-expected
                             "operation must preserve length"
                             "operation" operation))
    (bytes-copy! result start replacement))
  (bytes->immutable-bytes result))

(define (batch-expected initial edits)
  (define output (open-output-bytes))
  (let loop ([position 0] [remaining edits])
    (cond
      [(null? remaining)
       (write-bytes initial output position)
       (bytes->immutable-bytes (get-output-bytes output))]
      [else
       (define edit (car remaining))
       (define start (content-edit-start edit))
       (define end (content-edit-end edit))
       (write-bytes initial output position start)
       (write-bytes (content-edit-replacement edit) output)
       (loop end (cdr remaining))])))

(define (base-parameters #:operation-count operation-count
                         #:warmup-count warmup-count
                         #:sample-count sample-count
                         #:gap-start gap-start
                         #:aggregation aggregation
                         #:positions positions
                         #:replacement replacement
                         #:edit-count [edit-count operation-count]
                         #:extra [extra (hasheq)])
  (for/fold ([result
              (hasheq 'seed 'null
                      'editCount edit-count
                      'positions positions
                      'replacementBytesHex (bytes->hex-string replacement)
                      'replacementSha256 (sha256-hex replacement)
                      'operationCount operation-count
                      'warmupCount warmup-count
                      'sampleCount sample-count
                      'gapPreparation gap-start
                      'metricAggregation aggregation)])
            ([(key value) (in-hash extra)])
    (hash-set result key value)))

(define (make-local-trace)
  (define corpus local-trace-corpus)
  (define replacement (bytes->immutable-bytes #"x"))
  (define pair-count 10000)
  (define operation-count (* 2 pair-count))
  (define corpus-length (bytes-length corpus))
  (define positions
    (for/list ([pair-index (in-range pair-count)])
      (modulo (+ (* pair-index 7919) 17) (+ corpus-length 1))))
  (define batches
    (append-map
      (lambda (position)
        (list (list (content-edit position position replacement))
              (list (content-edit position (+ position 1) #""))))
      positions))
  (define expected-checksum
    (for/fold ([checksum checksum-seed]) ([position (in-list positions)])
      (define after-insert
        (checksum-fields checksum
                         (list corpus-length
                               (+ corpus-length 1)
                               1
                               position
                               position
                               position
                               (+ position 1)
                               (+ corpus-length 1))))
      (checksum-fields after-insert
                       (list (+ corpus-length 1)
                             corpus-length
                             1
                             position
                             (+ position 1)
                             position
                             position
                             corpus-length))))
  (define parameters
    (base-parameters
      #:operation-count operation-count
      #:warmup-count 1
      #:sample-count 5
      #:gap-start "eof"
      #:aggregation "median"
      #:positions positions
      #:replacement replacement
      #:extra
      (hasheq 'trace "insert-then-backspace-pairs"
              'pairCount pair-count
              'positionFormula "modulo(+(* i 7919)17)(add1 n)"
              'corpusGenerator "repeat-byte"
              'corpusByteHex "6c"
              'corpusByteLength corpus-length
              'rollingChecksumSeed checksum-seed
              'rollingChecksumMultiplier checksum-multiplier
              'rollingChecksumModulus checksum-modulus
              'rollingChecksumFields
              '("beforeByteLength"
                "afterByteLength"
                "changeCount"
                "oldStart"
                "oldEnd"
                "newStart"
                "newEnd"
                "intermediateByteLength")
              'expectedRollingChecksum expected-checksum)))
  (define (builder)
    (define content (make-buffer-content corpus))
    (define (thunk)
      (define checksum
        (for/fold ([checksum checksum-seed]) ([batch (in-list batches)])
          (define result (buffer-content-apply! content batch))
          (define changes (content-change-set-changes result))
          (for/fold
            ([next
              (checksum-fields
                checksum
                (list (content-change-set-before-byte-length result)
                      (content-change-set-after-byte-length result)
                      (length changes)))])
            ([change (in-list changes)])
            (checksum-fields
              next
              (list (content-change-old-start change)
                    (content-change-old-end change)
                    (content-change-new-start change)
                    (content-change-new-end change)
                    (buffer-content-byte-length content))))))
      (list (buffer-content-byte-length content) checksum))
    (workload-execution content
                        thunk
                        corpus
                        (list corpus-length expected-checksum)))
  (workload "local-trace/20000"
            'aggregate
            "local-trace-1m"
            corpus
            parameters
            corpus
            builder))

(define (make-local-latency)
  (define corpus (build-corpus-bytes "ordinary-10m"))
  (define point (quotient (bytes-length corpus) 2))
  (define replacement (bytes->immutable-bytes #"A"))
  (define operations
    (for/list ([index (in-range 220)])
      (list point (+ point 1) (if (even? index) #"A" #"B"))))
  (define expected (sequential-expected corpus operations))
  (define parameters
    (base-parameters #:operation-count 1
                     #:warmup-count 20
                     #:sample-count 200
                     #:gap-start "local-edit-point"
                     #:aggregation "nearest-rank-p99"
                     #:positions (list point)
                     #:replacement replacement
                     #:edit-count 220
                     #:extra (hasheq 'timedOperationCount 200
                                     'replacementSequence '("41" "42"))))
  (define (builder)
    (define content (make-buffer-content corpus))
    (apply-one! content point point #"p")
    (apply-one! content point (+ point 1) #"")
    (define index 0)
    (define (thunk)
      (define operation (list-ref operations index))
      (set! index (+ index 1))
      (apply-one! content (car operation) (cadr operation) (caddr operation))
      index)
    (workload-execution content thunk expected 220))
  (workload "local-latency/10m"
            'latency
            "ordinary-10m"
            corpus
            parameters
            expected
            builder))

(define (make-far-latency)
  (define corpus (build-corpus-bytes "snapshot-100m"))
  (define last (- (bytes-length corpus) 1))
  (define operations
    (for/list ([index (in-range 220)])
      (define endpoint (if (even? index) 0 last))
      (define replacement (if (even? (quotient index 2)) #"A" #"B"))
      (list endpoint (+ endpoint 1) replacement)))
  (define expected (sequential-expected corpus operations))
  (define parameters
    (base-parameters #:operation-count 1
                     #:warmup-count 20
                     #:sample-count 200
                     #:gap-start "eof"
                     #:aggregation "nearest-rank-p99"
                     #:positions (list 0 last)
                     #:replacement (bytes->immutable-bytes #"A")
                     #:edit-count 220
                     #:extra (hasheq 'timedOperationCount 200
                                     'endpointOrder "alternating-start-eof"
                                     'warmupParity "even"
                                     'replacementSequence '("41" "42"))))
  (define (builder)
    (define content (make-buffer-content corpus))
    (define index 0)
    (define (thunk)
      (define operation (list-ref operations index))
      (set! index (+ index 1))
      (apply-one! content (car operation) (cadr operation) (caddr operation))
      index)
    (workload-execution content thunk expected 220))
  (workload "far-latency/100m"
            'latency
            "snapshot-100m"
            corpus
            parameters
            expected
            builder))

(define (make-scattered count)
  (define corpus (build-corpus-bytes "ordinary-10m"))
  (define positions (even-offsets (bytes-length corpus) count))
  (define replacement (bytes->immutable-bytes #"Z"))
  (define edits
    (for/list ([position (in-list positions)])
      (content-edit position (+ position 1) replacement)))
  (define expected (batch-expected corpus edits))
  (define parameters
    (base-parameters #:operation-count count
                     #:warmup-count 1
                     #:sample-count 5
                     #:gap-start "eof"
                     #:aggregation "median"
                     #:positions positions
                     #:replacement replacement
                     #:extra (hasheq 'batchOrder "ascending-nonoverlapping"
                                     'applyOrder "right-to-left")))
  (define (builder)
    (define content (make-buffer-content corpus))
    (define (thunk)
      (buffer-content-apply! content edits)
      (buffer-content-byte-length content))
    (workload-execution content thunk expected (bytes-length expected)))
  (workload (format "scattered/~a/10m" count)
            'aggregate
            "ordinary-10m"
            corpus
            parameters
            expected
            builder))

(define (make-coordinates corpus-id characterization?)
  (define corpus (build-corpus-bytes corpus-id))
  (define query-count (if characterization? 1 10000))
  (define positions
    (if characterization?
        (list (bytes-length corpus))
        (even-offsets (bytes-length corpus) query-count #:include-end? #t)))
  (define checksum (for/sum ([position (in-list positions)]) position))
  (define parameters
    (base-parameters #:operation-count query-count
                     #:warmup-count 1
                     #:sample-count 5
                     #:gap-start "eof"
                     #:aggregation "median"
                     #:positions positions
                     #:replacement #""
                     #:edit-count 0
                     #:extra
                     (hasheq 'coordinateOrder "locate-then-resolve"
                             'expectedChecksum checksum
                             'queryShape
                             (if characterization?
                                 "single-worst-case-eof"
                                 "evenly-distributed-including-eof")
                             'queryCount query-count)))
  (define (builder)
    (define content (make-buffer-content corpus))
    (define (thunk)
      (for/sum ([position (in-list positions)])
        (define location (buffer-content-locate-byte content position))
        (buffer-content-resolve-position
          content
          (content-location-line location)
          (content-location-utf16-column location))))
    (workload-execution content thunk corpus checksum))
  (workload (format "coordinates/~a" corpus-id)
            (if characterization? 'characterization 'aggregate)
            corpus-id
            corpus
            parameters
            corpus
            builder))

(define (make-snapshot size-mib cached? expected)
  (define corpus-id (format "snapshot-~am" size-mib))
  (define corpus (build-corpus-bytes corpus-id))
  (define point (quotient (bytes-length corpus) 2))
  (define replacement (bytes->immutable-bytes #"q"))
  (define repeat-count (if cached? 100000 1))
  (define parameters
    (base-parameters #:operation-count repeat-count
                     #:warmup-count 1
                     #:sample-count 5
                     #:gap-start "mutation-point"
                     #:aggregation "median"
                     #:positions (list point)
                     #:replacement replacement
                     #:edit-count 1
                     #:extra (hasheq 'snapshotState (if cached? "cached" "cold")
                                     'repeatCount repeat-count
                                     'cachePreparation
                                     (if cached?
                                         "untimed-snapshot-after-retained-edit"
                                         "none-after-retained-edit"))))
  (define (builder)
    (define content (make-buffer-content corpus))
    (apply-one! content point (+ point 1) replacement)
    (when cached? (buffer-content-snapshot content))
    (define (thunk)
      (for/last ([_ (in-range repeat-count)])
        (bytes-length (buffer-content-snapshot content))))
    (workload-execution content
                        thunk
                        expected
                        (bytes-length expected)))
  (workload (format "snapshot/~a/~am" (if cached? "cached" "cold") size-mib)
            (if cached? 'characterization 'aggregate)
            corpus-id
            corpus
            parameters
            expected
            builder))

(define snapshot-1m-expected
  (immutable-replace snapshot-1m-corpus
                     (quotient (bytes-length snapshot-1m-corpus) 2)
                     (+ (quotient (bytes-length snapshot-1m-corpus) 2) 1)
                     #"q"))
(define snapshot-10m-expected
  (immutable-replace snapshot-10m-corpus
                     (quotient (bytes-length snapshot-10m-corpus) 2)
                     (+ (quotient (bytes-length snapshot-10m-corpus) 2) 1)
                     #"q"))
(define snapshot-100m-expected
  (immutable-replace snapshot-100m-corpus
                     (quotient (bytes-length snapshot-100m-corpus) 2)
                     (+ (quotient (bytes-length snapshot-100m-corpus) 2) 1)
                     #"q"))

(define all-workloads
  (list (make-local-trace)
        (make-local-latency)
        (make-far-latency)
        (make-scattered 200)
        (make-scattered 10000)
        (make-coordinates "ordinary-10m" #f)
        (make-coordinates "high-lines-10m" #f)
        (make-coordinates "long-line-10m" #t)
        (make-snapshot 1 #f snapshot-1m-expected)
        (make-snapshot 10 #f snapshot-10m-expected)
        (make-snapshot 100 #f snapshot-100m-expected)
        (make-snapshot 1 #t snapshot-1m-expected)
        (make-snapshot 10 #t snapshot-10m-expected)
        (make-snapshot 100 #t snapshot-100m-expected)))

(define (find-workload id)
  (for/first ([item (in-list all-workloads)]
              #:when (equal? id (workload-id item)))
    item))

(define (workload-execution-valid? execution result)
  (and (equal? result (workload-execution-expected-result execution))
       (equal? (buffer-content-snapshot (workload-execution-content execution))
               (workload-execution-expected-bytes execution))))

(define (replay-and-validate! item)
  (define execution ((workload-thunk-builder item)))
  (define parameters (workload-parameters item))
  (define repetitions
    (+ (hash-ref parameters 'warmupCount)
       (hash-ref parameters 'sampleCount)))
  (define result
    (if (eq? (workload-kind item) 'latency)
        (for/last ([_ (in-range repetitions)])
          ((workload-execution-thunk execution)))
        ((workload-execution-thunk execution))))
  (values (workload-execution-valid? execution result)
          (sha256-hex (workload-execution-expected-bytes execution))))

(define (workload-gate-definition id)
  (cond
    [(equal? id "local-trace/20000")
     (list 'medianWallMilliseconds 50 "ms")]
    [(equal? id "local-latency/10m")
     (list 'p99WallMilliseconds 1 "ms")]
    [(equal? id "far-latency/100m")
     (list 'p99WallMilliseconds 16 "ms")]
    [(equal? id "scattered/200/10m")
     (list 'medianWallMilliseconds 16 "ms")]
    [(equal? id "scattered/10000/10m")
     (list 'medianWallMilliseconds 250 "ms")]
    [(or (equal? id "coordinates/ordinary-10m")
         (equal? id "coordinates/high-lines-10m"))
     (list 'medianWallMilliseconds 100 "ms")]
    [(equal? id "snapshot/cold/1m")
     (list 'medianWallMilliseconds 10 "ms")]
    [(equal? id "snapshot/cold/10m")
     (list 'medianWallMilliseconds 50 "ms")]
    [(equal? id "snapshot/cold/100m")
     (list 'medianWallMilliseconds 250 "ms")]
    [else #f]))

(define hash-pattern #px"^[0-9a-f]{64}$")

(define (hash-string? value)
  (and (string? value) (regexp-match? hash-pattern value)))

(define (object-ref object key [failure #f])
  (if (hash? object) (hash-ref object key failure) failure))

(define (number-list samples key)
  (and (list? samples)
       (for/list ([sample (in-list samples)])
         (object-ref sample key #f))))

(define (median values)
  (define sorted (sort values <))
  (list-ref sorted (quotient (length sorted) 2)))

(define (nearest-rank-p99 values)
  (define sorted (sort values <))
  (list-ref sorted (- (ceiling (* 99/100 (length sorted))) 1)))

(define (report-validation-errors report)
  (define errors '())
  (define (reject! message) (set! errors (cons message errors)))
  (unless (and (hash? report)
               (equal? (object-ref report 'schema) "gap-buffer-benchmark"))
    (reject! "unknown schema"))
  (unless (equal? (object-ref report 'schemaVersion) 1)
    (reject! "unknown schema version"))
  (unless (equal? (object-ref report 'hashAlgorithm) "sha256")
    (reject! "unknown hash algorithm"))
  (unless (equal? (object-ref report 'validationScope)
                  "structural-consistency")
    (reject! "unknown validation scope"))
  (define approval (object-ref report 'approval))
  (define expected-host (object-ref approval 'expectedHost))
  (define actual-host (object-ref approval 'actualHost))
  (define eligible? (approval-eligible? expected-host actual-host))
  (unless (equal? expected-host approval-identity)
    (reject! "approval expected host mismatch"))
  (unless (eq? (object-ref approval 'eligible) eligible?)
    (reject! "approval eligibility mismatch"))
  (define expected-approval-reason
    (if eligible?
        "approval host identity matches"
        "system hostname, OS, machine, kernel, CPU, memory, VM, or Racket version mismatch"))
  (unless (equal? (object-ref approval 'reason) expected-approval-reason)
    (reject! "approval reason mismatch"))
  (define rows (object-ref report 'workloads '()))
  (unless (list? rows) (reject! "workloads must be a list"))
  (when (list? rows)
    (define expected-ids (map workload-id all-workloads))
    (define actual-ids
      (for/list ([row (in-list rows)]) (object-ref row 'id)))
    (unless (equal? actual-ids expected-ids)
      (reject! "workload inventory or order mismatch"))
    (for ([row (in-list rows)])
      (define id (object-ref row 'id))
      (define item (and (string? id) (find-workload id)))
      (unless item (reject! "unknown workload"))
      (when item
        (define corpus (object-ref row 'corpus))
        (unless (and (equal? (object-ref corpus 'id) (workload-corpus-id item))
                     (equal? (object-ref corpus 'byteLength)
                             (bytes-length (workload-corpus-bytes item)))
                     (equal? (object-ref corpus 'sha256) (corpus-hash item)))
          (reject! "corpus hash or metadata mismatch"))
        (unless (and (hash-string? (object-ref row 'workloadSha256))
                     (equal? (object-ref row 'workloadSha256)
                             (workload-hash item)))
          (reject! "workload hash mismatch"))
        (unless (equal? (object-ref row 'parameters) (workload-parameters item))
          (reject! "workload parameters mismatch"))
        (define sampling (object-ref row 'sampling))
        (define samples (object-ref row 'rawSamples))
        (define expected-count (object-ref sampling 'sampleCount -1))
        (unless (and (exact-nonnegative-integer? expected-count)
                     (list? samples)
                     (= expected-count (length samples)))
          (reject! "wrong sample count"))
        (when (list? samples)
          (define walls (number-list samples 'wallMilliseconds))
          (define cpus (number-list samples 'cpuMilliseconds))
          (unless (and (andmap real? walls) (andmap real? cpus))
            (reject! "missing raw timing field"))
          (for ([sample (in-list samples)])
            (define allocation (object-ref sample 'allocation))
            (unless (and (hash? allocation)
                         (member (object-ref allocation 'status)
                                 '("available" "unsupported"))
                         (if (equal? (object-ref allocation 'status) "available")
                             (exact-nonnegative-integer?
                               (object-ref allocation 'bytes #f))
                             (string? (object-ref allocation 'reason #f))))
              (reject! "malformed allocation field")))
          (when (and (pair? samples) (andmap real? walls) (andmap real? cpus))
            (define summary (object-ref row 'summary))
            (unless (equal? (object-ref summary 'medianWallMilliseconds)
                            (median walls))
              (reject! "invalid wall median"))
            (unless (equal? (object-ref summary 'medianCpuMilliseconds)
                            (median cpus))
              (reject! "invalid CPU median"))
            (define allocations
              (for/list ([sample (in-list samples)]
                         #:when
                         (equal? (object-ref (object-ref sample 'allocation)
                                             'status)
                                 "available"))
                (object-ref (object-ref sample 'allocation) 'bytes)))
            (define expected-allocation
              (if (= (length allocations) (length samples))
                  (median allocations)
                  'null))
            (unless (equal? (object-ref summary 'medianAllocationBytes)
                            expected-allocation)
              (reject! "invalid allocation median"))
            (define p99 (object-ref summary 'p99WallMilliseconds))
            (if (eq? (workload-kind item) 'latency)
                (unless (equal? p99 (nearest-rank-p99 walls))
                  (reject! "invalid p99"))
                (unless (eq? p99 'null)
                  (reject! "aggregate p99 must be null")))))
        (unless (equal? (object-ref row 'kind)
                        (symbol->string (workload-kind item)))
          (reject! "workload kind mismatch"))
        (unless (equal? (object-ref row 'gapStart)
                        (object-ref (workload-parameters item) 'gapPreparation))
          (reject! "gap preparation mismatch"))
        (unless (and (equal? (object-ref sampling 'warmupCount)
                             (object-ref (workload-parameters item) 'warmupCount))
                     (equal? (object-ref sampling 'sampleCount)
                             (object-ref (workload-parameters item) 'sampleCount))
                     (equal? (object-ref sampling 'operationCount)
                             (object-ref (workload-parameters item)
                                         'operationCount)))
          (reject! "sampling metadata mismatch"))
        (define validation (object-ref row 'validation))
        (unless (and (eq? (object-ref validation 'passed) #t)
                     (hash-string? (object-ref validation 'oracleSha256))
                     (equal? (object-ref validation 'oracleSha256)
                             (sha256-hex (workload-expected-bytes item))))
          (reject! "validation failure"))
        (define gate (object-ref row 'gate))
        (define definition (workload-gate-definition id))
        (cond
          [(not eligible?)
           (unless (equal? (object-ref gate 'decision) "not-applicable")
             (reject! "non-approval gate must be not-applicable"))]
          [definition
           (define metric (car definition))
           (define limit (cadr definition))
           (define metric-decision
             (if (<= (object-ref (object-ref row 'summary) metric +inf.0)
                     limit)
                 "pass"
                 "fail"))
           (define allocation
             (object-ref (object-ref row 'summary)
                         'medianAllocationBytes
                         'null))
           (define allocation-decision
             (if (and (exact-nonnegative-integer? allocation)
                      (<= allocation 134217728))
                 "pass"
                 "fail"))
           (define expected-decision
             (if (equal? id "local-trace/20000")
                 (if (and (equal? metric-decision "pass")
                          (equal? allocation-decision "pass"))
                     "pass"
                     "fail")
                 metric-decision))
           (unless (and (equal? (object-ref gate 'metric)
                                (symbol->string metric))
                        (equal? (object-ref (object-ref gate 'limit) 'value)
                                limit)
                        (equal? (object-ref gate 'decision) expected-decision))
             (reject! "gate decision or limit mismatch"))
           (when (equal? id "local-trace/20000")
             (define allocation-gate (object-ref gate 'allocationGate))
             (unless (and (equal? (object-ref allocation-gate 'metric)
                                  "medianAllocationBytes")
                          (equal? (object-ref
                                    (object-ref allocation-gate 'limit)
                                    'value)
                                  134217728)
                          (equal? (object-ref allocation-gate 'decision)
                                  allocation-decision))
               (reject! "allocation gate decision or limit mismatch")))]
          [else
           (unless (equal? (object-ref gate 'decision) "not-applicable")
             (reject! "characterization gate must be not-applicable"))]))))
  (when (list? rows)
    (define validations-passed?
      (andmap (lambda (row)
                (eq? (object-ref (object-ref row 'validation) 'passed) #t))
              rows))
    (define failed-applicable-gate?
      (ormap (lambda (row)
               (equal? (object-ref (object-ref row 'gate) 'decision) "fail"))
             rows))
    (define allocation-unsupported?
      (for/or ([row (in-list rows)]
               #:when (equal? (object-ref row 'id) "local-trace/20000"))
        (eq? (object-ref (object-ref row 'summary)
                         'medianAllocationBytes)
             'null)))
    (define expected-status
      (cond
        [(not validations-passed?) "invalid"]
        [(and eligible? allocation-unsupported?) "unsupported"]
        [else "complete"]))
    (define expected-decision
      (cond
        [(not validations-passed?) "invalid"]
        [(not eligible?) "not-approval-host"]
        [failed-applicable-gate? "fail"]
        [else "pass"]))
    (unless (equal? (object-ref report 'status) expected-status)
      (reject! "report status mismatch"))
    (unless (equal? (object-ref report 'decision) expected-decision)
      (reject! "report decision mismatch"))
    (define provenance (object-ref report 'executionProvenance))
    (unless (and (equal? (object-ref provenance 'method)
                         "runner-in-process-flat-oracle")
                 (eq? (object-ref provenance 'allWorkloadsPassed)
                      validations-passed?))
      (reject! "execution provenance fields mismatch")))
  (reverse errors))

(define (valid-report? report)
  (null? (report-validation-errors report)))
