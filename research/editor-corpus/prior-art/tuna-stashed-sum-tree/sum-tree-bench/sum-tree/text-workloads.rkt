#lang racket/base

(require file/sha1
         racket/list
         racket/port
         racket/vector
         (only-in sum-tree
                  sum-tree-count sum-tree-cursor sum-tree-cursor-index
                  sum-tree-cursor-seek-index!)
         (only-in sum-tree/private/instrument
                  check-sum-tree-invariants
                  retained-input-node-identities
                  sum-tree-invariants-height
                  sum-tree-invariants-node-count
                  sum-tree-invariants-node-slot-slack)
         (only-in sum-tree/private/node
                  internal-node-children leaf-node-items leaf-node?
                  sum-tree-root-node sum-tree-spec-combine-procedure
                  sum-tree-spec-summarize-procedure)
         (submod tuna/api/private/text test-support)
         tuna/api/text
         "workloads.rkt")

(provide make-text-workloads make-text-workload-entries text-workload-plan
         text-benchmark-entry? text-benchmark-entry-descriptor
         text-benchmark-entry-class text-benchmark-entry-warmup-count
         text-benchmark-entry-sample-count
         text-workload-families text-control-kinds
         text-workload-descriptor? bounded-piece? bounded-piece-byte-length
         bounded-piece-index-count bounded-piece-byte-ref bounded-piece-valid?
         bytes->bounded-pieces execute-text-workload-once
         execute-text-workload-retained-values)

(define MiB (* 1024 1024))
(define piece-capacity 1024)
(define piece-index-stride 64)

(define text-workload-families
  '(build-scan-slice-serialize local-insert-backspace distributed-batch
                               alternating-document-ends large-paste large-delete replace-all
                               coordinate-conversions multi-mebibyte-single-line millions-short-lines
                               retained-roots retained-slices retained-cursors sparse-slack-compaction
                               summary-callback-dispatch gap-snapshot-copy))
(define text-control-kinds
  '(bounded-chunks flat-bytes flat-string bounded-indexed-piece mutable-gap-buffer))

(struct text-case (family scale operations edits replacement retention shape))
(struct canonical-corpus (seed byte-count shape) #:prefab)
(struct canonical-edit (kind start end replacement) #:prefab)
(struct canonical-trace (operations ranges queries retention) #:prefab)
(struct replacement-pattern (byte-count byte) #:prefab)
(struct prepared-text (source value trace prepared-operations))
(struct prepared-edit (canonical replacement text-edit))
(struct text-result (value retained observation))
(struct callback-result (summary callback-calls))
(struct schedule-leaf (chunks))
(struct schedule-internal (children))
(struct bounded-piece (backing start end index))
(struct control-source (string bytes))
(struct control-result (value observation))
(struct text-workload-declaration (kind case control mode snapshot?))
(struct text-benchmark-entry (descriptor class warmup-count sample-count))
(struct gap-buffer ([storage #:mutable] [gap-start #:mutable] [gap-end #:mutable]
                    [movement-copied #:mutable]))
(struct prepared-gap (gap operations))
(struct prepared-gap-edit (canonical replacement-bytes))

(define (pv profile full tiny) (if (eq? profile 'tiny) tiny full))
(define (scale profile c) (pv profile (text-case-scale c) 4096))
(define (operations profile c) (pv profile (text-case-operations c)
                                   (min 8 (text-case-operations c))))
(define (edits profile c) (pv profile (text-case-edits c)
                              (min 8 (text-case-edits c))))
(define (replacement-size profile c)
  (pv profile (text-case-replacement c) (min 128 (text-case-replacement c))))
(define (retention profile c) (pv profile (text-case-retention c)
                                  (min 8 (text-case-retention c))))

(define (make-corpus c profile seed)
  (canonical-corpus seed (scale profile c) (text-case-shape c)))
(define (corpus-byte-ref corpus i)
  (case (canonical-corpus-shape corpus)
    [(short-lines) (if (odd? i) 10
                       (+ 97 (modulo (+ i (canonical-corpus-seed corpus)) 26)))]
    [(single-line) (+ 97 (modulo (+ i (canonical-corpus-seed corpus)) 26))]
    [else (if (= (modulo i 80) 79) 10
              (+ 97 (modulo (+ i (canonical-corpus-seed corpus)) 26)))]))
(define (corpus->bytes corpus)
  (define bytes (make-bytes (canonical-corpus-byte-count corpus)))
  (for ([i (in-range (bytes-length bytes))])
    (bytes-set! bytes i (corpus-byte-ref corpus i)))
  (bytes->immutable-bytes bytes))
(define (corpus->string corpus)
  (bytes->string/utf-8 (corpus->bytes corpus)))
(define (corpus-input-port corpus)
  (define position 0)
  (define length (canonical-corpus-byte-count corpus))
  (define period
    (case (canonical-corpus-shape corpus)
      [(mixed) 1040]
      [else 26]))
  (define pattern (make-bytes period))
  (for ([i (in-range period)])
    (bytes-set! pattern i (corpus-byte-ref corpus i)))
  (make-input-port
    'canonical-text-corpus
    (lambda (target)
      (cond
        [(zero? (bytes-length target)) 0]
        [(= position length) eof]
        [else
         (define amount (min (- length position) (bytes-length target)))
         (let loop ([target-start 0]
                    [source-start (modulo position period)])
           (when (< target-start amount)
             (define copied
               (min (- amount target-start) (- period source-start)))
             (bytes-copy! target target-start pattern source-start
                          (+ source-start copied))
             (loop (+ target-start copied) 0)))
         (set! position (+ position amount))
         amount]))
    (lambda _arguments (error 'corpus-input-port "peek is unsupported"))
    void))
(define corpus-hash-cache (make-hash))
(define trace-hash-cache (make-hash))
(define (corpus-content-hash corpus)
  (hash-ref!
    corpus-hash-cache
    corpus
    (lambda ()
      (define input (corpus-input-port corpus))
      (define digest (sha1 input))
      (close-input-port input)
      digest)))
(define (trace-content-hash trace)
  (hash-ref!
    trace-hash-cache
    trace
    (lambda ()
      (define payload
        (call-with-output-bytes
          (lambda (output)
            (write '(canonical-text-trace-v1) output)
            (for ([op (in-list (canonical-trace-operations trace))])
              (cond
                [(canonical-edit? op)
                 (define r (canonical-edit-replacement op))
                 (write (list (canonical-edit-kind op)
                              (canonical-edit-start op)
                              (canonical-edit-end op)
                              (replacement-pattern-byte-count r))
                        output)
                 (define chunk
                   (make-bytes (min 65536 (replacement-pattern-byte-count r))
                               (replacement-pattern-byte r)))
                 (let loop ([remaining (replacement-pattern-byte-count r)])
                   (when (positive? remaining)
                     (define amount (min remaining (bytes-length chunk)))
                     (write-bytes chunk output 0 amount)
                     (loop (- remaining amount))))]
                [else (write op output)]))
            (write (canonical-trace-ranges trace) output)
            (write (canonical-trace-queries trace) output)
            (write (canonical-trace-retention trace) output))))
      (define input (open-input-bytes payload))
      (define digest (sha1 input))
      (close-input-port input)
      digest)))
(define (replacement n [byte 120]) (replacement-pattern n byte))
(define (replacement->string r)
  (make-string (replacement-pattern-byte-count r)
               (integer->char (replacement-pattern-byte r))))
(define (distributed-positions n count)
  (for/list ([i (in-range count)]) (quotient (* i n) (max 1 count))))
(define (local-positions n count)
  (build-list count (lambda (i) (modulo (+ (* i 7919) 17) (add1 n)))))

(define (make-trace c profile)
  (define family (text-case-family c))
  (define n (scale profile c))
  (define op-count (operations profile c))
  (define edit-count (edits profile c))
  (define keep (retention profile c))
  (case family
    [(build-scan-slice-serialize)
     (define start (quotient n 4))
     (canonical-trace '(build scan slice serialize)
                      (list (cons start (- n start))) '() '())]
    [(local-insert-backspace sparse-slack-compaction slack-fragmentation)
     (canonical-trace
       (append-map (lambda (p)
                     (list (canonical-edit 'insert p p (replacement 1))
                           (canonical-edit 'delete p (add1 p) (replacement 0))))
                   (local-positions n op-count)) '() '() '())]
    [(distributed-batch)
     (canonical-trace
       (for/list ([p (in-list (distributed-positions n edit-count))])
         (canonical-edit 'insert p p (replacement 1))) '() '() '())]
    [(alternating-document-ends)
     (canonical-trace
       (append-map (lambda (i)
                     (define p (if (even? i) 0 n))
                     (list (canonical-edit 'insert p p (replacement 1))
                           (canonical-edit 'delete p (add1 p) (replacement 0))))
                   (range op-count)) '() '() '())]
    [(large-paste)
     (define p (quotient n 2))
     (canonical-trace
       (list (canonical-edit 'insert p p (replacement (replacement-size profile c))))
       '() '() '())]
    [(large-delete)
     (define start (quotient n 4))
     (canonical-trace
       (list (canonical-edit 'delete start (- n start) (replacement 0)))
       '() '() '())]
    [(replace-all)
     (canonical-trace
       (for/list ([p (in-list (distributed-positions n edit-count))]
                  #:when (< p n))
         (canonical-edit 'replace p (add1 p) (replacement 1 122))) '() '() '())]
    [(coordinate-conversions)
     (canonical-trace '() '()
                      (build-list op-count
                                  (lambda (i) (modulo (* i 65537) (add1 n)))) '())]
    [(retained-roots retained-slices retained-cursors)
     (canonical-trace
       (if (eq? family 'retained-roots)
           (for/list ([p (in-list (distributed-positions n keep))])
             (define q (min p (sub1 n)))
             (canonical-edit 'replace q (add1 q) (replacement 1 114))) '())
       '() '()
       (case family
         [(retained-roots) '()]
         [(retained-cursors)
          (distributed-positions
            (max 1 (quotient (+ n (sub1 text-chunk-capacity/test))
                             text-chunk-capacity/test))
            keep)]
         [else (distributed-positions n keep)]))]
    [else (canonical-trace '() '() '() '())]))

(define (trace-count t)
  (+ (length (canonical-trace-operations t))
     (length (canonical-trace-queries t))
     (length (canonical-trace-retention t))))
(define (comparison-id c profile)
  (format "text/~a/~a/~a/~a" (text-case-family c) (scale profile c)
          (edits profile c) (retention profile c)))
(define (barrier-id family)
  (case family
    [(build-scan-slice-serialize) "bytes-length-checksum-slice-serialize-v1"]
    [(local-insert-backspace) "restored-bytes-checksum-v1"]
    [(summary-callback-dispatch) "text-summary-fields-v1"]
    [else "text-result-string-and-lengths-v1"]))
(define (make-parameters c profile control mode seed trace
                         #:comparison-id [comparison #f]
                         #:metric-kind [metric-kind "operation"])
  (define family (text-case-family c))
  (define tree-backed? (eq? control 'bounded-chunks))
  (define edit-backed?
    (and tree-backed?
         (memq family '(local-insert-backspace distributed-batch
                                               alternating-document-ends large-paste large-delete replace-all
                                               retained-roots sparse-slack-compaction))))
  (define copied-observed?
    (and tree-backed?
         (or edit-backed? (eq? family 'retained-slices))))
  (hasheq 'domain "text" 'family (symbol->string family)
          'control (symbol->string control) 'summaryMode (symbol->string mode)
          'scaleBytes (scale profile c) 'operationCount (trace-count trace)
          'editCount (edits profile c) 'replacementBytes (replacement-size profile c)
          'retentionCount (retention profile c)
          'clientEditCount (length (canonical-trace-operations trace))
          'comparisonId (or comparison (comparison-id c profile))
          'barrierId (barrier-id family)
          'preparationBoundary "canonical-corpus-and-trace-before-timing"
          'processIsolation "fresh-process-per-row"
          'warmupPolicy "per-row-policy"
          'gcPolicy "runner-major-before-and-after-sample"
          'validationPolicy "canonical-result-barrier-after-timing"
          'snapshotPopulation (retention profile c)
          'structuralEvidenceProvenance "exact untimed canonical trace replay"
          'EProvenance (if edit-backed? "normalized instrumented splice plan length"
                           "not-applicable")
          'HProvenance (if tree-backed? "inspected old/replacement/result tree heights"
                           "not-applicable")
          'RProvenance (if edit-backed? "inspected replacement tree item counts"
                           "not-applicable")
          'FProvenance (if edit-backed? "fresh batch-work-node-identities"
                           "not-applicable")
          'copiedBytesProvenance
          (cond
            [copied-observed? "text copy observer components"]
            [tree-backed? "unavailable for uninstrumented copying"]
            [else "not-applicable"])
          'slackProvenance (if tree-backed? "inspected result nodes and chunks"
                               "not-applicable")
          'retentionProvenance "actual retained collections and identity sets or not-applicable"
          'metricKind metric-kind 'profile (symbol->string profile) 'seed seed))

(define (prepare-text c profile seed)
  (define corpus (make-corpus c profile seed))
  (define source (string->immutable-string (corpus->string corpus)))
  (define trace (make-trace c profile))
  (define prepared-operations
    (for/list ([op (in-list (canonical-trace-operations trace))]
               #:when (canonical-edit? op))
      (define replacement-text
        (string->text (replacement->string (canonical-edit-replacement op))))
      (prepared-edit op replacement-text
                     (text-edit (canonical-edit-start op)
                                (canonical-edit-end op)
                                replacement-text))))
  (prepared-text source (string->text source) trace prepared-operations))
(define (apply-operation value prepared)
  (define op (prepared-edit-canonical prepared))
  (case (canonical-edit-kind op)
    [(insert) (text-insert value (canonical-edit-start op)
                           (prepared-edit-replacement prepared))]
    [(delete) (text-delete value (canonical-edit-start op) (canonical-edit-end op))]
    [(replace) (text-replace value (canonical-edit-start op)
                             (canonical-edit-end op)
                             (prepared-edit-replacement prepared))]))
(define (bytes-observation value)
  (define bytes (string->bytes/utf-8 value))
  (vector (bytes-length bytes) (for/sum ([b (in-bytes bytes)]) b)))
(define (build-observation value range)
  (define checksum
    (for*/sum ([chunk (in-list (text-chunks/test value))]
               [byte (in-bytes chunk)])
      byte))
  (define byte-length (text-byte-length value))
  (define char-length (text-char-length value))
  (define utf16-length (text-utf-16-length value))
  (define line-count (text-line-count value))
  (define slice (text-slice value (car range) (cdr range)))
  (define serialized (text->string value))
  (define slice-string (text->string slice))
  (string-length serialized)
  (vector (vector byte-length checksum)
          byte-length char-length utf16-length line-count
          (bytes-observation slice-string)))

(define (operate-production c p)
  (define family (text-case-family c))
  (define original (prepared-text-value p))
  (define trace (prepared-text-trace p))
  (define ops (prepared-text-prepared-operations p))
  (define result
    (case family
      [(build-scan-slice-serialize)
       (define value (string->text (prepared-text-source p)))
       (text-result value '() (build-observation value (car (canonical-trace-ranges trace))))]
      [(distributed-batch replace-all)
       (define-values (value change-set)
         (text-replace* original (map prepared-edit-text-edit ops)))
       (text-result value (list change-set) #f)]
      [(local-insert-backspace alternating-document-ends)
       (define value (for/fold ([value original]) ([op (in-list ops)])
                       (apply-operation value op)))
       (text-result value '() #f)]
      [(large-paste large-delete)
       (define value (apply-operation original (car ops)))
       (text-result value '() #f)]
      [(coordinate-conversions)
       (define checksum
         (for/sum ([offset (in-list (canonical-trace-queries trace))])
           (+ (text-byte->char original offset) (text-byte->utf-16 original offset)
              (text-byte->line original offset)
              (position-line (text-byte->position original offset)))))
       (text-result original '() checksum)]
      [(multi-mebibyte-single-line millions-short-lines)
       (text-result original '() (vector (text-line-count original)
                                         (text-char-length original)
                                         (text-utf-16-length original)))]
      [(retained-roots)
       (define-values (value retained)
         (for/fold ([value original] [retained '()]) ([op (in-list ops)])
           (values (apply-operation value op) (cons value retained))))
       (text-result value retained (length retained))]
      [(retained-slices)
       (define retained
         (for/list ([offset (in-list (canonical-trace-retention trace))])
           (text-slice original offset (min (text-byte-length original) (+ offset 1024)))))
       (text-result original retained (length retained))]
      [(retained-cursors)
       (define tree (text-tree/test original))
       (define item-count (sum-tree-count tree))
       (define retained
         (for/list ([index (in-list (canonical-trace-retention trace))])
           (define cursor (sum-tree-cursor tree))
           (sum-tree-cursor-seek-index! cursor (min index item-count))
           cursor))
       (text-result original retained (length retained))]
      [(sparse-slack-compaction)
       (define edited (for/fold ([value original]) ([op (in-list ops)])
                        (apply-operation value op)))
       (define serialized (text->string edited))
       (text-result (string->text serialized) (list edited) #f)]
      [(slack-fragmentation)
       (define edited (for/fold ([value original]) ([op (in-list ops)])
                        (apply-operation value op)))
       (text-result edited '() #f)]
      [else (error 'operate-production "unsupported family ~a" family)]))
  (make-operation-result result (list (current-memory-use))))
(define (validate-text-result result digest)
  (unless (and (text-result? result) (text? (text-result-value result)))
    (raise-argument-error 'validate-text-result "text-result?" result))
  (text->string (text-result-value result))
  digest)

(define (event-ref evidence name)
  (hash-ref (text-replace-evidence/test-observer-events evidence) name 0))
(define (sum-counter evidence-list name)
  (for/sum ([e (in-list evidence-list)])
    (hash-ref (text-replace-evidence/test-counters e) name 0)))
(define (sum-event evidence-list name)
  (for/sum ([e (in-list evidence-list)]) (event-ref e name)))
(define (chunk-slack value)
  (for/sum ([chunk (in-list (text-chunks/test value))])
    (- text-chunk-capacity/test (bytes-length chunk))))
(define (instrumented-replay c p)
  (define family (text-case-family c))
  (define original (prepared-text-value p))
  (define ops (prepared-text-prepared-operations p))
  (cond
    [(memq family '(distributed-batch replace-all))
     (define e
       (text-replace*/instrumented/test original (map prepared-edit-text-edit ops)))
     (values (text-replace-evidence/test-result e) (list e))]
    [(memq family '(local-insert-backspace alternating-document-ends
                                           retained-roots sparse-slack-compaction
                                           slack-fragmentation))
     (for/fold ([value original] [reversed '()]
                #:result (values value (reverse reversed)))
               ([op (in-list ops)])
       (define e
         (text-replace*/instrumented/test value (list (prepared-edit-text-edit op))))
       (values (text-replace-evidence/test-result e) (cons e reversed)))]
    [(memq family '(large-paste large-delete))
     (define e
       (text-replace*/instrumented/test
         original (list (prepared-edit-text-edit (car ops)))))
     (values (text-replace-evidence/test-result e) (list e))]
    [else (values original '())]))
(define (slice-copied-bytes value trace)
  (define amount 0)
  (for ([range (in-list (canonical-trace-ranges trace))])
    (call-with-slice-observer/test
      (lambda (event n) (when (eq? event 'copied-boundary-bytes)
                          (set! amount (+ amount n))))
      (lambda () (text-slice value (car range) (cdr range)))))
  amount)
(define (production-evidence c profile seed)
  (define p (prepare-text c profile seed))
  (define trace (prepared-text-trace p))
  (define family (text-case-family c))
  (define edit-family?
    (memq family '(local-insert-backspace distributed-batch
                                          alternating-document-ends large-paste large-delete replace-all
                                          retained-roots sparse-slack-compaction
                                          slack-fragmentation)))
  (define observed-slice-copy 0)
  (define actual-text-result
    (and (not edit-family?)
         (if (eq? family 'retained-slices)
             (call-with-slice-observer/test
               (lambda (event amount)
                 (when (eq? event 'copied-boundary-bytes)
                   (set! observed-slice-copy (+ observed-slice-copy amount))))
               (lambda () (operation-result-value (operate-production c p))))
             (operation-result-value (operate-production c p)))))
  (define-values (replayed evidence-list) (instrumented-replay c p))
  (define result
    (cond
      [(eq? family 'sparse-slack-compaction)
       (string->text (text->string replayed))]
      [edit-family? replayed]
      [else (text-result-value actual-text-result)]))
  (define result-i (check-sum-tree-invariants (text-tree/test result)))
  (define all-i
    (append-map
      (lambda (e)
        (append (list (text-replace-evidence/test-old-invariants e)
                      (text-replace-evidence/test-result-invariants e))
                (text-replace-evidence/test-replacement-invariants e)))
      evidence-list))
  (define e-count
    (and (pair? evidence-list)
         (for/sum ([e (in-list evidence-list)])
           (length (text-replace-evidence/test-plan e)))))
  (define r-count
    (and (pair? evidence-list)
         (for*/sum ([e (in-list evidence-list)]
                    [n (in-list (text-replace-evidence/test-replacement-tree-counts e))]) n)))
  (define f-count (and (pair? evidence-list)
                       (sum-counter evidence-list 'batch-work-node-identities)))
  (define h
    (apply max
           (sum-tree-invariants-height result-i)
           (map sum-tree-invariants-height all-i)))
  (define copied-old (sum-event evidence-list 'copied-old-bytes))
  (define copied-normalization (sum-event evidence-list 'copied-normalization-bytes))
  (define copied-slice
    (if (eq? family 'retained-slices)
        observed-slice-copy
        (slice-copied-bytes (prepared-text-value p) trace)))
  (define copy-observed?
    (or (pair? evidence-list) (eq? family 'retained-slices)))
  (define unavailable 'null)
  (define copied-total
    (if copy-observed? (+ copied-old copied-normalization copied-slice) unavailable))
  (define counters
    (hasheq
      'operationCount (trace-count trace)
      'clientEditCount (for/sum ([e (in-list evidence-list)])
                         (text-replace-evidence/test-client-edit-count e))
      'normalizedPlanEditCount (or e-count unavailable)
      'batchWorkNodeIdentities (or f-count unavailable)
      'allocations (if (pair? evidence-list) (sum-counter evidence-list 'allocations) unavailable)
      'boundaryVisits (if (pair? evidence-list) (sum-counter evidence-list 'boundary-visits) unavailable)
      'rebalanceVisits (if (pair? evidence-list) (sum-counter evidence-list 'rebalance-visits) unavailable)
      'copiedOldBytes (if (pair? evidence-list) copied-old unavailable)
      'copiedNormalizationBytes (if (pair? evidence-list) copied-normalization unavailable)
      'copiedSliceBoundaryBytes
      (if (or (pair? (canonical-trace-ranges trace))
              (eq? family 'retained-slices))
          copied-slice unavailable)
      'copiedBytes copied-total
      'nodeSlotSlack (sum-tree-invariants-node-slot-slack result-i)
      'chunkByteSlack (chunk-slack result)
      'retainedRoots (if (eq? family 'retained-roots) (length evidence-list) 0)
      'retainedSlices
      (if (eq? family 'retained-slices) (length (text-result-retained actual-text-result)) 0)
      'retainedCursors
      (if (eq? family 'retained-cursors) (length (text-result-retained actual-text-result)) 0)
      'retainedCursorIndexChecksum
      (if (eq? family 'retained-cursors)
          (for/sum ([cursor (in-list (text-result-retained actual-text-result))])
            (sum-tree-cursor-index cursor))
          0)
      'retainedInputNodeIdentities
      (cond
        [(pair? evidence-list)
         (for/sum ([e (in-list evidence-list)])
           (text-replace-evidence/test-retained-input-node-identities e))]
        [(eq? family 'retained-slices)
         (for/sum ([slice (in-list (text-result-retained actual-text-result))])
           (retained-input-node-identities
             (list (text-tree/test (prepared-text-value p)))
             (text-tree/test slice)))]
        [(eq? family 'retained-cursors)
         (if (null? (text-result-retained actual-text-result)) 0
             (sum-tree-invariants-node-count result-i))]
        [else unavailable])
      'resultNodeCount (sum-tree-invariants-node-count result-i)
      'editResultNodeCount
      (if (memq family '(sparse-slack-compaction slack-fragmentation))
          (sum-tree-invariants-node-count
            (check-sum-tree-invariants (text-tree/test replayed))) unavailable)
      'compactionResultNodeCount
      (if (eq? family 'sparse-slack-compaction)
          (sum-tree-invariants-node-count result-i) unavailable)
      'oldTreeHeight
      (if (pair? evidence-list)
          (apply max (map (lambda (e)
                            (sum-tree-invariants-height
                              (text-replace-evidence/test-old-invariants e))) evidence-list))
          (sum-tree-invariants-height result-i))
      'resultTreeHeight (sum-tree-invariants-height result-i)
      'F_final
      (if (pair? evidence-list)
          (for/sum ([e (in-list evidence-list)])
            (text-replace-evidence/test-final-changed-node-identities e)) unavailable)
      'F_work (or f-count unavailable)))
  (values counters
          (hasheq 'E (or e-count unavailable) 'H h 'R (or r-count unavailable)
                  'F (or f-count unavailable) 'operationCount (trace-count trace))
          (if (pair? evidence-list)
              "instrumented replay; F=batch-work-node-identities; F_final/F_work implementation-specific"
              "inspected tree shape/slack; edit metrics not-applicable")))

(define (make-production-descriptor seed profile c)
  (define corpus (make-corpus c profile seed))
  (define trace (make-trace c profile))
  (define params (make-parameters c profile 'bounded-chunks 'production seed trace))
  (define corpus-digest (corpus-content-hash corpus))
  (define trace-digest (trace-content-hash trace))
  (define validation-digest
    (benchmark-content-hash (list 'validation corpus trace (barrier-id (text-case-family c)))))
  (make-workload-descriptor
    (format "text/~a/~a/e~a/r~a"
            (text-case-family c) (scale profile c)
            (edits profile c) (retention profile c))
    params
    corpus-digest trace-digest validation-digest
    (lambda () (prepare-text c profile seed))
    (lambda (p) (operate-production c p))
    (lambda (result) (validate-text-result result validation-digest))
    (lambda () (production-evidence c profile seed))))

(define (tree->schedule node)
  (if (leaf-node? node)
      (schedule-leaf (vector->immutable-vector (vector-copy (leaf-node-items node))))
      (schedule-internal
        (vector->immutable-vector
          (for/vector ([child (in-vector (internal-node-children node))])
            (tree->schedule child))))))
(define (reduce-schedule schedule summarize combine zero)
  (define calls 0)
  (define (dispatch procedure . arguments)
    (set! calls (add1 calls))
    (apply procedure arguments))
  (define (walk node)
    (define values (if (schedule-leaf? node) (schedule-leaf-chunks node)
                       (for/vector ([child (in-vector (schedule-internal-children node))])
                         (walk child))))
    (for/fold ([result zero]) ([value (in-vector values)])
      (dispatch combine result
                (if (schedule-leaf? node)
                    (dispatch summarize value)
                    value))))
  (values (walk schedule) calls))
(define (summarize-through-text-spec chunk)
  ((sum-tree-spec-summarize-procedure text-spec/test) chunk))

(define (combine-through-text-spec left right)
  ((sum-tree-spec-combine-procedure text-spec/test) left right))

(define callback-case
  (text-case 'summary-callback-dispatch MiB 0 0 0 0 'mixed))
(define (make-callback-descriptor seed profile mode)
  (define corpus (make-corpus callback-case profile seed))
  (define trace (canonical-trace '(extract-topology reduce) '() '() '()))
  (define comparison "text/summary-callback/actual-topology-v1")
  (define params (make-parameters callback-case profile 'bounded-chunks mode seed trace
                                  #:comparison-id comparison))
  (define corpus-digest (corpus-content-hash corpus))
  (define trace-digest (trace-content-hash trace))
  (define validation-digest (benchmark-content-hash (list corpus trace 'equal-summary)))
  (define (prepare)
    (define value (string->text (corpus->string corpus)))
    (vector value (tree->schedule (sum-tree-root-node (text-tree/test value)))))
  (define (operate prepared)
    (define generic? (eq? mode 'generic))
    (define-values (summary calls)
      (reduce-schedule
        (vector-ref prepared 1)
        (if generic?
            summarize-through-text-spec
            summarize-text-chunk/test)
        (if generic?
            combine-through-text-spec
            combine-text-summaries/direct/test)
        zero-text-summary/test))
    (make-operation-result (callback-result summary calls) (list (current-memory-use))))
  (define (validate result)
    (unless (equal? (callback-result-summary result)
                    (text-summary/test (vector-ref (prepare) 0)))
      (error 'summary-callback-dispatch "summary mismatch"))
    (unless (positive? (callback-result-callback-calls result))
      (error 'summary-callback-dispatch "callback dispatch count is zero"))
    validation-digest)
  (define (evidence)
    (define prepared (prepare))
    (define result (operation-result-value (operate prepared)))
    (define i (check-sum-tree-invariants (text-tree/test (vector-ref prepared 0))))
    (values (hasheq 'operationCount 2 'clientEditCount 0
                    'reductionCallbackCount (callback-result-callback-calls result)
                    'allocations 'null 'boundaryVisits 'null 'rebalanceVisits 'null
                    'batchWorkNodeIdentities 'null
                    'copiedBytes 'null 'copiedOldBytes 'null
                    'copiedNormalizationBytes 'null 'copiedSliceBoundaryBytes 'null
                    'nodeSlotSlack (sum-tree-invariants-node-slot-slack i)
                    'chunkByteSlack (chunk-slack (vector-ref prepared 0))
                    'retainedRoots 0 'retainedSlices 0 'retainedCursors 0
                    'retainedInputNodeIdentities 'null
                    'resultNodeCount (sum-tree-invariants-node-count i)
                    'oldTreeHeight (sum-tree-invariants-height i)
                    'resultTreeHeight (sum-tree-invariants-height i)
                    'F_final 'null 'F_work 'null)
            (hasheq 'E 'null 'H (sum-tree-invariants-height i) 'R 'null 'F 'null
                    'operationCount 2)
            "identical immutable topology reduction; generic mode dispatches through descriptor procedures"))
  (make-workload-descriptor
    (format "text/summary-callback/~a/~a" mode (scale profile callback-case)) params
    corpus-digest trace-digest validation-digest prepare operate validate evidence))

(define (bounded-piece-byte-length piece)
  (- (bounded-piece-end piece) (bounded-piece-start piece)))
(define (bounded-piece-index-count piece) (vector-length (bounded-piece-index piece)))
(define (bounded-piece-byte-ref piece index)
  (unless (and (exact-nonnegative-integer? index)
               (< index (bounded-piece-byte-length piece)))
    (raise-argument-error 'bounded-piece-byte-ref "valid piece byte index" index))
  (bytes-ref (bounded-piece-backing piece) (+ (bounded-piece-start piece) index)))
(define (bounded-piece-valid? piece)
  (and (bounded-piece? piece) (immutable? (bounded-piece-backing piece))
       (positive? (bounded-piece-byte-length piece))
       (<= (bounded-piece-byte-length piece) piece-capacity)
       (immutable? (bounded-piece-index piece))
       (for/and ([offset (in-vector (bounded-piece-index piece))]
                 [ordinal (in-naturals)])
         (= offset (* ordinal piece-index-stride)))))
(define (bytes->bounded-pieces bytes)
  (unless (bytes? bytes) (raise-argument-error 'bytes->bounded-pieces "bytes?" bytes))
  (define backing (bytes->immutable-bytes bytes))
  (vector->immutable-vector
    (for/vector ([start (in-range 0 (bytes-length backing) piece-capacity)])
      (define end (min (bytes-length backing) (+ start piece-capacity)))
      (bounded-piece backing start end
                     (vector->immutable-vector
                       (for/vector ([offset (in-range 0 (- end start) piece-index-stride)]) offset))))))

(define (make-gap-buffer bytes)
  (define length (bytes-length bytes))
  (define storage (make-bytes (+ length (max 64 (quotient length 8)))))
  (bytes-copy! storage 0 bytes)
  (gap-buffer storage length (bytes-length storage) 0))
(define (gap-length gap)
  (- (bytes-length (gap-buffer-storage gap))
     (- (gap-buffer-gap-end gap) (gap-buffer-gap-start gap))))
(define (gap-ensure! gap needed)
  (when (< (- (gap-buffer-gap-end gap) (gap-buffer-gap-start gap)) needed)
    (define old (gap-buffer-storage gap))
    (define suffix (- (bytes-length old) (gap-buffer-gap-end gap)))
    (define new (make-bytes (+ (bytes-length old) needed (max 64 (quotient (bytes-length old) 2)))))
    (bytes-copy! new 0 old 0 (gap-buffer-gap-start gap))
    (define end (- (bytes-length new) suffix))
    (bytes-copy! new end old (gap-buffer-gap-end gap))
    (set-gap-buffer-storage! gap new)
    (set-gap-buffer-gap-end! gap end)))
(define (gap-move! gap position)
  (unless (<= 0 position (gap-length gap))
    (raise-argument-error 'gap-move! "valid position" position))
  (define start (gap-buffer-gap-start gap))
  (define end (gap-buffer-gap-end gap))
  (define storage (gap-buffer-storage gap))
  (cond
    [(< position start)
     (define amount (- start position))
     (bytes-copy! storage (- end amount) storage position start)
     (set-gap-buffer-gap-start! gap position)
     (set-gap-buffer-gap-end! gap (- end amount))
     (set-gap-buffer-movement-copied! gap (+ (gap-buffer-movement-copied gap) amount))]
    [(> position start)
     (define amount (- position start))
     (bytes-copy! storage start storage end (+ end amount))
     (set-gap-buffer-gap-start! gap (+ start amount))
     (set-gap-buffer-gap-end! gap (+ end amount))
     (set-gap-buffer-movement-copied! gap
                                      (+ (gap-buffer-movement-copied gap) amount))]
    [else (void)]))
(define (gap-insert! gap position bytes)
  (gap-move! gap position) (gap-ensure! gap (bytes-length bytes))
  (bytes-copy! (gap-buffer-storage gap) (gap-buffer-gap-start gap) bytes)
  (set-gap-buffer-gap-start! gap (+ (gap-buffer-gap-start gap) (bytes-length bytes))))
(define (gap-delete! gap start end)
  (gap-move! gap start)
  (set-gap-buffer-gap-end! gap (+ (gap-buffer-gap-end gap) (- end start))))
(define (gap-snapshot gap)
  (define result (make-bytes (gap-length gap)))
  (bytes-copy! result 0 (gap-buffer-storage gap) 0 (gap-buffer-gap-start gap))
  (bytes-copy! result (gap-buffer-gap-start gap) (gap-buffer-storage gap)
               (gap-buffer-gap-end gap))
  (bytes->immutable-bytes result))
(define (replay-gap! gap prepared-operations)
  (for ([prepared (in-list prepared-operations)])
    (define op (prepared-gap-edit-canonical prepared))
    (case (canonical-edit-kind op)
      [(insert) (gap-insert! gap (canonical-edit-start op)
                             (prepared-gap-edit-replacement-bytes prepared))]
      [(delete) (gap-delete! gap (canonical-edit-start op) (canonical-edit-end op))]
      [(replace)
       (gap-delete! gap (canonical-edit-start op) (canonical-edit-end op))
       (gap-insert! gap (canonical-edit-start op)
                    (prepared-gap-edit-replacement-bytes prepared))])))

(define build-control-case
  (text-case 'build-scan-slice-serialize MiB 4 0 0 0 'mixed))
(define gap-control-case
  (text-case 'local-insert-backspace MiB 10000 0 0 0 'mixed))
(define (control-evidence trace #:client-edits [client-edits 0]
                          #:movement [movement 'null]
                          #:snapshot [snapshot 'null])
  (values (hasheq 'operationCount (trace-count trace) 'clientEditCount client-edits
                  'allocations 'null 'boundaryVisits 'null 'rebalanceVisits 'null
                  'batchWorkNodeIdentities 'null
                  'copiedBytes 'null 'copiedOldBytes 'null 'copiedNormalizationBytes 'null
                  'copiedSliceBoundaryBytes 'null 'nodeSlotSlack 'null 'chunkByteSlack 'null
                  'retainedRoots 0 'retainedSlices 0 'retainedCursors 0
                  'retainedInputNodeIdentities 'null 'resultNodeCount 'null
                  'oldTreeHeight 'null 'resultTreeHeight 'null
                  'movementCopiedBytes movement 'snapshotCopiedBytes snapshot
                  'F_final 'null 'F_work 'null)
          (hasheq 'E 'null 'H 'null 'R 'null 'F 'null
                  'operationCount (trace-count trace))
          "control replay counters; SumTree structure not-applicable"))
(define (control-observation byte-length checksum line-count slice)
  (vector (vector byte-length checksum)
          byte-length byte-length byte-length line-count
          (vector (bytes-length slice) (for/sum ([b (in-bytes slice)]) b))))
(define (make-build-control seed profile control)
  (define c build-control-case)
  (define corpus (make-corpus c profile seed))
  (define trace (make-trace c profile))
  (define comparison (comparison-id c profile))
  (define params (make-parameters c profile control 'control seed trace
                                  #:comparison-id comparison))
  (define corpus-digest (corpus-content-hash corpus))
  (define trace-digest (trace-content-hash trace))
  (define validation-digest (benchmark-content-hash (list 'validation corpus trace (barrier-id (text-case-family c)))))
  (define (prepare)
    (define string (string->immutable-string (corpus->string corpus)))
    (control-source string
                    (bytes->immutable-bytes (string->bytes/utf-8 string))))
  (define (operate source)
    (define range (car (canonical-trace-ranges trace)))
    (define-values (value observation)
      (case control
        [(flat-bytes)
         (define built
           (bytes->immutable-bytes (bytes-copy (control-source-bytes source))))
         (define checksum (for/sum ([byte (in-bytes built)]) byte))
         (define lines (add1 (for/sum ([byte (in-bytes built)] #:when (= byte 10)) 1)))
         (define slice (subbytes built (car range) (cdr range)))
         (define serialized (bytes->immutable-bytes (bytes-copy built)))
         (values built
                 (control-observation (bytes-length serialized) checksum lines slice))]
        [(flat-string)
         (define built
           (string->immutable-string (string-copy (control-source-string source))))
         (define checksum
           (for/sum ([character (in-string built)]) (char->integer character)))
         (define lines
           (add1 (for/sum ([character (in-string built)]
                           #:when (char=? character #\newline)) 1)))
         (define slice
           (string->bytes/utf-8 (substring built (car range) (cdr range))))
         (define serialized (string->bytes/utf-8 built))
         (values built
                 (control-observation (bytes-length serialized) checksum lines slice))]
        [(bounded-indexed-piece)
         (define pieces (bytes->bounded-pieces (control-source-bytes source)))
         (define checksum
           (for*/sum ([piece (in-vector pieces)]
                      [i (in-range (bounded-piece-byte-length piece))])
             (bounded-piece-byte-ref piece i)))
         (define lines
           (add1
             (for*/sum ([piece (in-vector pieces)]
                        [i (in-range (bounded-piece-byte-length piece))]
                        #:when (= (bounded-piece-byte-ref piece i) 10)) 1)))
         (define slice (make-bytes (- (cdr range) (car range))))
         (for ([i (in-range (car range) (cdr range))]
               [target (in-naturals)])
           (define piece (vector-ref pieces (quotient i piece-capacity)))
           (bytes-set! slice target
                       (bounded-piece-byte-ref piece (remainder i piece-capacity))))
         (define serialized (make-bytes (bytes-length (control-source-bytes source))))
         (for* ([piece (in-vector pieces)]
                [i (in-range (bounded-piece-byte-length piece))]
                [position (in-value (+ (bounded-piece-start piece) i))])
           (bytes-set! serialized position (bounded-piece-byte-ref piece i)))
         (values pieces
                 (control-observation (bytes-length serialized) checksum lines slice))]))
    (make-operation-result
      (control-result value observation)
      (list (current-memory-use))))
  (define (validate result)
    (unless (control-result? result) (raise-argument-error 'build-control "control-result?" result))
    validation-digest)
  (make-workload-descriptor
    (format "text/control/~a/build/~a" control (scale profile c)) params
    corpus-digest trace-digest validation-digest prepare operate validate
    (lambda () (control-evidence trace))))
(define (make-gap-control seed profile snapshot? [c gap-control-case])
  (define corpus (make-corpus c profile seed))
  (define edit-trace (make-trace c profile))
  (define timed-trace
    (if snapshot? (canonical-trace '(snapshot) '() '() '()) edit-trace))
  (define comparison
    (if snapshot?
        (format "text/gap-snapshot/~a" (scale profile c))
        (comparison-id c profile)))
  (define metric (if snapshot? "snapshot-copy" "edit"))
  (define base-params
    (make-parameters c profile 'mutable-gap-buffer 'control seed timed-trace
                     #:comparison-id comparison #:metric-kind metric))
  (define params
    (hash-set
      (hash-set
        (hash-set base-params 'snapshotPopulation
                  (if snapshot? (scale profile c) 0))
        'preparedEditCount
        (if snapshot? (length (canonical-trace-operations edit-trace)) 0))
      'family
      (if snapshot? "gap-snapshot-copy" "local-insert-backspace")))
  (define corpus-digest (corpus-content-hash corpus))
  (define trace-digest
    (if snapshot? (trace-content-hash timed-trace) (trace-content-hash edit-trace)))
  (define validation-digest
    (if snapshot?
        (benchmark-content-hash (list 'validation corpus timed-trace metric))
        (benchmark-content-hash
          (list 'validation corpus edit-trace
                (barrier-id (text-case-family c))))))
  (define (prepare)
    (define prepared-operations
      (for/list ([op (in-list (canonical-trace-operations edit-trace))])
        (prepared-gap-edit
          op
          (bytes->immutable-bytes
            (string->bytes/utf-8
              (replacement->string (canonical-edit-replacement op)))))))
    (define gap (make-gap-buffer (corpus->bytes corpus)))
    (when snapshot? (replay-gap! gap prepared-operations))
    (prepared-gap gap prepared-operations))
  (define (operate prepared)
    (define gap (prepared-gap-gap prepared))
    (cond
      [snapshot?
       (define bytes (gap-snapshot gap))
       (make-operation-result
         (control-result bytes
                         (bytes-observation (bytes->string/utf-8 bytes)))
         (list (current-memory-use)))]
      [else
       (replay-gap! gap (prepared-gap-operations prepared))
       (make-operation-result
         (control-result gap #f)
         (list (current-memory-use)))]))
  (define (validate result)
    (define value (control-result-value result))
    (define bytes (if (gap-buffer? value) (gap-snapshot value) value))
    (unless (bytes=? bytes (corpus->bytes corpus))
      (error 'gap-control "canonical trace result mismatch"))
    validation-digest)
  (define (evidence)
    (define prepared (prepare))
    (define gap (prepared-gap-gap prepared))
    (cond
      [snapshot?
       (control-evidence timed-trace
                         #:snapshot (bytes-length (gap-snapshot gap)))]
      [else
       (replay-gap! gap (prepared-gap-operations prepared))
       (control-evidence
         edit-trace
         #:client-edits (length (canonical-trace-operations edit-trace))
         #:movement (gap-buffer-movement-copied gap))]))
  (make-workload-descriptor
    (format "text/control/mutable-gap-buffer/~a/~a" metric (scale profile c)) params
    corpus-digest trace-digest validation-digest prepare operate validate evidence))

(define production-cases
  (list
    (text-case 'build-scan-slice-serialize MiB 4 0 0 0 'mixed)
    (text-case 'build-scan-slice-serialize (* 10 MiB) 4 0 0 0 'mixed)
    (text-case 'build-scan-slice-serialize (* 100 MiB) 4 0 0 0 'mixed)
    (text-case 'local-insert-backspace MiB 10000 0 0 0 'mixed)
    (text-case 'local-insert-backspace (* 10 MiB) 10000 0 0 0 'mixed)
    (text-case 'distributed-batch (* 10 MiB) 0 10 0 0 'mixed)
    (text-case 'distributed-batch (* 10 MiB) 0 100 0 0 'mixed)
    (text-case 'distributed-batch (* 10 MiB) 0 1000 0 0 'mixed)
    (text-case 'distributed-batch (* 10 MiB) 0 10000 0 0 'mixed)
    (text-case 'alternating-document-ends (* 10 MiB) 10000 0 0 0 'mixed)
    (text-case 'large-paste MiB 1 0 (* 10 MiB) 0 'mixed)
    (text-case 'large-delete (* 100 MiB) 1 0 0 0 'mixed)
    (text-case 'replace-all (* 10 MiB) 0 1000 1 0 'mixed)
    (text-case 'replace-all (* 10 MiB) 0 100000 1 0 'mixed)
    (text-case 'coordinate-conversions (* 10 MiB) 10000 0 0 0 'mixed)
    (text-case 'multi-mebibyte-single-line (* 10 MiB) 1 0 0 0 'single-line)
    (text-case 'millions-short-lines (* 10 MiB) 1 0 0 0 'short-lines)
    (text-case 'retained-roots (* 10 MiB) 0 0 0 1000 'mixed)
    (text-case 'retained-roots (* 10 MiB) 0 0 0 10000 'mixed)
    (text-case 'retained-slices (* 10 MiB) 0 0 0 1000 'mixed)
    (text-case 'retained-slices (* 10 MiB) 0 0 0 10000 'mixed)
    (text-case 'retained-cursors (* 10 MiB) 0 0 0 1000 'mixed)
    (text-case 'retained-cursors (* 10 MiB) 0 0 0 10000 'mixed)
    (text-case 'sparse-slack-compaction (* 10 MiB) 10000 0 0 0 'mixed)))

(define text-workload-declarations
  (append
    (for/list ([c (in-list production-cases)])
      (text-workload-declaration 'production c 'bounded-chunks 'production #f))
    (list
      (text-workload-declaration 'callback callback-case 'bounded-chunks 'generic #f)
      (text-workload-declaration 'callback callback-case 'bounded-chunks 'hard-coded #f)
      (text-workload-declaration 'build-control build-control-case 'flat-bytes 'control #f)
      (text-workload-declaration 'build-control build-control-case 'flat-string 'control #f)
      (text-workload-declaration 'build-control build-control-case
                                 'bounded-indexed-piece 'control #f)
      (text-workload-declaration 'gap-control gap-control-case
                                 'mutable-gap-buffer 'control #f)
      (text-workload-declaration 'gap-control gap-control-case
                                 'mutable-gap-buffer 'control #t))))

(define (make-declared-text-workload declaration seed profile)
  (case (text-workload-declaration-kind declaration)
    [(production)
     (make-production-descriptor seed profile
                                 (text-workload-declaration-case declaration))]
    [(callback)
     (make-callback-descriptor seed profile
                               (text-workload-declaration-mode declaration))]
    [(build-control)
     (make-build-control seed profile
                         (text-workload-declaration-control declaration))]
    [(gap-control)
     (make-gap-control seed profile
                       (text-workload-declaration-snapshot? declaration))]))

(define gate-build-case
  (text-case 'build-scan-slice-serialize MiB 4 0 0 0 'mixed))
(define gate-local-case
  (text-case 'local-insert-backspace MiB 1000 0 0 0 'mixed))
(define gate-distributed-case
  (text-case 'distributed-batch MiB 0 1000 0 0 'mixed))
(define gate-stress-case
  (text-case 'distributed-batch (* 10 MiB) 0 1000 0 0 'mixed))
(define gate-coordinate-case
  (text-case 'coordinate-conversions MiB 1000 0 0 0 'mixed))
(define gate-retained-roots-case
  (text-case 'retained-roots MiB 0 0 0 1000 'mixed))
(define gate-retained-slices-case
  (text-case 'retained-slices MiB 0 0 0 1000 'mixed))
(define gate-retained-cursors-case
  (text-case 'retained-cursors MiB 0 0 0 1000 'mixed))
(define gate-slack-case
  (text-case 'slack-fragmentation MiB 1000 0 0 0 'mixed))

(define (make-gate-text-workload-entries seed profile)
  (define (timing descriptor)
    (text-benchmark-entry descriptor 'timing 1 3))
  (define (stress descriptor)
    (text-benchmark-entry descriptor 'stress 0 1))
  (define (evidence descriptor)
    (text-benchmark-entry descriptor 'evidence 0 0))
  (append
    (map timing
         (list (make-production-descriptor seed profile gate-build-case)
               (make-build-control seed profile 'flat-bytes)
               (make-build-control seed profile 'flat-string)
               (make-build-control seed profile 'bounded-indexed-piece)
               (make-production-descriptor seed profile gate-local-case)
               (make-gap-control seed profile #f gate-local-case)
               (make-gap-control seed profile #t gate-local-case)
               (make-production-descriptor seed profile gate-distributed-case)
               (make-production-descriptor seed profile gate-coordinate-case)
               (make-callback-descriptor seed profile 'generic)
               (make-callback-descriptor seed profile 'hard-coded)))
    (list (stress (make-production-descriptor seed profile gate-stress-case)))
    (map evidence
         (list (make-production-descriptor seed profile gate-retained-roots-case)
               (make-production-descriptor seed profile gate-retained-slices-case)
               (make-production-descriptor seed profile gate-retained-cursors-case)
               (make-production-descriptor seed profile gate-slack-case)))))

(define (make-full-text-workload-entries seed profile)
  (for/list ([declaration (in-list text-workload-declarations)])
    (text-benchmark-entry
      (make-declared-text-workload declaration seed profile)
      'characterization
      2
      20)))

(define (make-text-workload-entries seed #:profile [profile 'stage2])
  (case profile
    [(stage2 characterization)
     (make-full-text-workload-entries seed 'full)]
    [(gate) (make-gate-text-workload-entries seed 'full)]
    [(tiny) (make-full-text-workload-entries seed 'tiny)]
    [else
     (raise-argument-error
       'make-text-workload-entries
       "(or/c 'stage2 'gate 'characterization 'tiny)"
       profile)]))

(define (make-text-workloads seed #:profile [profile 'characterization])
  (map text-benchmark-entry-descriptor
       (make-text-workload-entries seed #:profile profile)))
(define (text-workload-descriptor? descriptor)
  (and (workload? descriptor)
       (equal? (hash-ref (workload-parameters descriptor) 'domain #f) "text")))
(define (execute-text-workload-once descriptor)
  (define prepared ((workload-prepare descriptor)))
  (define operation-result ((workload-operate descriptor) prepared))
  ((workload-validate descriptor) (operation-result-value operation-result))
  (define value (operation-result-value operation-result))
  (cond
    [(text-result? value)
     (or (text-result-observation value)
         (bytes-observation (text->string (text-result-value value))))]
    [(control-result? value)
     (or (control-result-observation value)
         (bytes-observation (bytes->string/utf-8
                              (gap-snapshot (control-result-value value)))))]
    [(callback-result? value)
     (vector (summary-values (callback-result-summary value))
             (callback-result-callback-calls value))]
    [else value]))

(define (execute-text-workload-retained-values descriptor)
  (define prepared ((workload-prepare descriptor)))
  (define operation-result ((workload-operate descriptor) prepared))
  (define value (operation-result-value operation-result))
  (if (text-result? value) (text-result-retained value) '()))

(define (summary-values summary)
  (list (text-summary-bytes summary) (text-summary-chars summary)
        (text-summary-utf16 summary) (text-summary-newlines summary)
        (text-summary-trailing-bytes summary) (text-summary-trailing-chars summary)
        (text-summary-trailing-utf16 summary)))

(define (declaration-family declaration)
  (if (and (eq? (text-workload-declaration-kind declaration) 'gap-control)
           (text-workload-declaration-snapshot? declaration))
      'gap-snapshot-copy
      (text-case-family (text-workload-declaration-case declaration))))

(define (declaration-name declaration)
  (define c (text-workload-declaration-case declaration))
  (case (text-workload-declaration-kind declaration)
    [(production)
     (format "text/~a/~a/e~a/r~a"
             (text-case-family c) (text-case-scale c)
             (text-case-edits c) (text-case-retention c))]
    [(callback)
     (format "text/summary-callback/~a/~a"
             (text-workload-declaration-mode declaration)
             (text-case-scale c))]
    [(build-control)
     (format "text/control/~a/build/~a"
             (text-workload-declaration-control declaration)
             (text-case-scale c))]
    [(gap-control)
     (format "text/control/mutable-gap-buffer/~a/~a"
             (if (text-workload-declaration-snapshot? declaration)
                 'snapshot-copy
                 'edit)
             (text-case-scale c))]))

(define (text-workload-plan)
  (for/list ([declaration (in-list text-workload-declarations)])
    (define c (text-workload-declaration-case declaration))
    (hasheq 'name (declaration-name declaration)
            'family (symbol->string (declaration-family declaration))
            'control
            (symbol->string (text-workload-declaration-control declaration))
            'summaryMode
            (symbol->string (text-workload-declaration-mode declaration))
            'scaleBytes (text-case-scale c)
            'operationCount (text-case-operations c)
            'editCount (text-case-edits c)
            'replacementBytes (text-case-replacement c)
            'retentionCount (text-case-retention c)
            'shape (symbol->string (text-case-shape c)))))

(define text-workload-declarations/test text-workload-plan)

(module+ test-support
  (provide text-workload-declarations/test))

