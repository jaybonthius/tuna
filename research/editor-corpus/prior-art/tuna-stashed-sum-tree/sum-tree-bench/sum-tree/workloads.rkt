#lang racket/base

(require file/sha1
         racket/list
         sum-tree
         (only-in sum-tree/private/build
                  vector->sum-tree/instrumented)
         sum-tree/private/instrument
         (only-in sum-tree/private/node
                  internal-node-children
                  leaf-node-items
                  leaf-node?
                  node-capacity
                  sum-tree-root-node)
         (only-in sum-tree/private/splice
                  sum-tree-splice/instrumented
                  sum-tree-splice*/instrumented))

(provide benchmark-hash-algorithm
         workload?
         workload-name
         workload-parameters
         workload-corpus-hash
         workload-replay-hash
         workload-validation-digest
         workload-prepare
         workload-operate
         workload-validate
         workload-evidence
         operation-result?
         operation-result-value
         operation-result-memory-checkpoints
         make-operation-result
         make-workload-descriptor
         make-benchmark-digests
         benchmark-content-hash
         make-stage1-workloads)

(define benchmark-hash-algorithm "sha1")
(define workload-version 1)

(struct workload
  (name
    parameters
    corpus-hash
    replay-hash
    validation-digest
    prepare
    operate
    validate
    evidence))

(struct operation-result (value memory-checkpoints))
(struct weighted-summary (extent count checksum) #:transparent)
(struct retained-result (tree roots cursors indexes))

(define (write-canonical value output)
  (cond
    [(hash? value)
     (write-string "{" output)
     (for ([key (in-list (sort (hash-keys value)
                               string<?
                               #:key (lambda (item) (format "~a" item))))]
           [index (in-naturals)])
       (when (positive? index) (write-string "," output))
       (write-canonical key output)
       (write-string ":" output)
       (write-canonical (hash-ref value key) output))
     (write-string "}" output)]
    [(vector? value)
     (write-canonical (vector->list value) output)]
    [(pair? value)
     (write-string "(" output)
     (let loop ([remaining value]
                [first? #t])
       (cond
         [(pair? remaining)
          (unless first? (write-string " " output))
          (write-canonical (car remaining) output)
          (loop (cdr remaining) #f)]
         [(null? remaining) (void)]
         [else
          (write-string " . " output)
          (write-canonical remaining output)]))
     (write-string ")" output)]
    [else (write value output)]))

(define (stable-digest value)
  (define output (open-output-bytes))
  (write-canonical value output)
  (sha1 (open-input-bytes (get-output-bytes output))))

(define benchmark-content-hash stable-digest)

(define (make-benchmark-digests seed name parameters corpus trace validation)
  (values
    (stable-digest
      (list 'sum-tree-workload workload-version seed name parameters corpus))
    (stable-digest
      (list 'sum-tree-replay workload-version seed name parameters corpus trace))
    (stable-digest
      (list 'sum-tree-validation workload-version name validation))))

(define make-operation-result operation-result)

(define (make-workload-descriptor
          name parameters corpus-hash replay-hash validation-digest
          prepare operate validate evidence)
  (unless (and (string? name)
               (hash? parameters)
               (andmap string? (list corpus-hash replay-hash validation-digest))
               (andmap procedure? (list prepare operate validate evidence)))
    (raise-arguments-error 'make-workload-descriptor
                           "invalid workload descriptor fields"
                           "name" name
                           "parameters" parameters))
  (workload name
            parameters
            corpus-hash
            replay-hash
            validation-digest
            prepare
            operate
            validate
            evidence))

(define make-digests make-benchmark-digests)

(define (make-numeric-spec)
  (make-sum-tree-spec
    #:summary? exact-nonnegative-integer?
    #:zero 0
    #:summarize values
    #:combine +))

(define (make-unit-spec)
  (make-sum-tree-spec
    #:summary? exact-nonnegative-integer?
    #:zero 0
    #:summarize (lambda (_) 1)
    #:combine +))

(define (make-weighted-spec)
  (make-sum-tree-spec
    #:summary? weighted-summary?
    #:zero (weighted-summary 0 0 0)
    #:summarize
    (lambda (item)
      (weighted-summary (vector-ref item 0) 1 (vector-ref item 1)))
    #:combine
    (lambda (left right)
      (weighted-summary
        (+ (weighted-summary-extent left) (weighted-summary-extent right))
        (+ (weighted-summary-count left) (weighted-summary-count right))
        (+ (weighted-summary-checksum left)
           (weighted-summary-checksum right))))))

(define (ensure who condition message . fields)
  (unless condition
    (apply raise-arguments-error who message fields)))

(define (tree-height tree)
  (sum-tree-invariants-height (check-sum-tree-invariants tree)))

(define (hash-add base . entries)
  (for/fold ([result base])
            ([entry (in-list entries)])
    (hash-set result (car entry) (cdr entry))))

(define (snapshot->structural-counters snapshot)
  (for/hasheq ([(name value) (in-hash snapshot)]
               #:unless (memq name '(node-slot-slack chunk-byte-slack)))
    (values name value)))

(define (instrumented-numeric-scan tree counters)
  (define (scan node)
    (sum-tree-counter-add! counters 'node-visits)
    (cond
      [(leaf-node? node)
       (sum-tree-counter-add! counters 'leaf-metadata-visits)
       (sum-tree-counter-add! counters 'leaf-visits)
       (define items (leaf-node-items node))
       (sum-tree-counter-add! counters 'item-visits (vector-length items))
       (for/sum ([item (in-vector items)]) item)]
      [else
       (define children (internal-node-children node))
       (sum-tree-counter-add! counters 'child-slot-visits
                              (vector-length children))
       (for/sum ([child (in-vector children)])
         (scan child))]))
  (scan (sum-tree-root-node tree)))

(define (packed-build-workload seed)
  (define count 4097)
  (define corpus
    (list->vector
      (build-list count (lambda (index) (remainder (+ index seed) 97)))))
  (define parameters
    (hasheq 'itemCount count
            'iterationCount 1
            'seed seed))
  (define expected-sum
    (for/sum ([item (in-vector corpus)]) item))
  (define validation (list count expected-sum expected-sum))
  (define-values (corpus-hash replay-hash validation-digest)
    (make-digests seed 'packed-build-scan parameters corpus '(build scan) validation))
  (define (prepare) corpus)
  (define (operate source)
    (define tree (vector->sum-tree (make-numeric-spec) source))
    (define after-build-memory (current-memory-use))
    (define scanned
      (for/sum ([item (in-sum-tree tree)]) item))
    (operation-result (cons tree scanned)
                      (list after-build-memory (current-memory-use))))
  (define (validate value)
    (define tree (car value))
    (define scanned (cdr value))
    (ensure 'packed-build-scan (= (sum-tree-count tree) count)
            "unexpected result count" "expected" count "actual" (sum-tree-count tree))
    (ensure 'packed-build-scan (= (sum-tree-summary tree) expected-sum)
            "unexpected total summary" "expected" expected-sum "actual" (sum-tree-summary tree))
    (ensure 'packed-build-scan (= scanned expected-sum)
            "unexpected scan digest" "expected" expected-sum "actual" scanned)
    (check-sum-tree-invariants tree)
    validation-digest)
  (define (evidence)
    (define counters (make-sum-tree-counters))
    (define tree
      (vector->sum-tree/instrumented
        (make-numeric-spec) corpus counters))
    (define scanned (instrumented-numeric-scan tree counters))
    (ensure 'packed-build-scan-evidence (= scanned expected-sum)
            "instrumented scan differs from the corpus sum")
    (define snapshot (sum-tree-counters-snapshot counters))
    (define invariants (check-sum-tree-invariants tree))
    (values
      (hash-add
        (snapshot->structural-counters snapshot)
        (cons 'buildOperationCount 1)
        (cons 'scanOperationCount 1)
        (cons 'operationCount 2)
        (cons 'scannedItemCount count)
        (cons 'treeHeight (sum-tree-invariants-height invariants))
        (cons 'resultNodeCount (sum-tree-invariants-node-count invariants))
        (cons 'finalNodeSlotSlack
              (sum-tree-invariants-node-slot-slack invariants))
        (cons 'finalChunkByteSlack 0))
      (hasheq 'B node-capacity
              'itemCount count
              'buildOperationCount 1
              'scanOperationCount 1
              'buildItemCount count
              'scanItemCount count
              'operationCount 2
              'treeHeightUpperBound
              (sum-tree-invariants-height invariants))
      "one instrumented vector build and one complete instrumented scan"))
  (workload "packed-build-scan"
            parameters corpus-hash replay-hash validation-digest
            prepare operate validate evidence))

(define (prefix-extents corpus)
  (define prefixes (make-vector (add1 (vector-length corpus)) 0))
  (for ([item (in-vector corpus)]
        [index (in-naturals 1)])
    (vector-set! prefixes
                 index
                 (+ (vector-ref prefixes (sub1 index))
                    (vector-ref item 0))))
  (vector->immutable-vector prefixes))

(define (oracle-seek prefixes target bias)
  (define equal-indexes
    (for/list ([prefix (in-vector prefixes)]
               [index (in-naturals)]
               #:when (= prefix target))
      index))
  (cond
    [(pair? equal-indexes)
     (if (eq? bias 'left) (car equal-indexes) (last equal-indexes))]
    [else
     (for/first ([index (in-range (sub1 (vector-length prefixes)))]
                 #:when (< (vector-ref prefixes index)
                           target
                           (vector-ref prefixes (add1 index))))
       index)]))

(define (cursor-range-workload seed)
  (define count 4097)
  (define query-count 256)
  (define corpus
    (for/vector #:length count
      ([index (in-range count)])
      (vector (remainder (+ index seed) 5) (remainder (* (add1 index) 17) 1009))))
  (define prefixes (prefix-extents corpus))
  (define total (vector-ref prefixes count))
  (define trace
    (for/list ([ordinal (in-range query-count)])
      (define target (remainder (+ (* ordinal 37) seed) (add1 total)))
      (define bias (if (even? ordinal) 'left 'right))
      (define start (remainder (+ (* ordinal 19) seed) (add1 count)))
      (define width (remainder (+ ordinal 11) (add1 (- count start))))
      (list target bias start (+ start width))))
  (define expected
    (for/fold ([selected 0]
               [extent 0]
               [checksum 0]
               #:result (list selected extent checksum))
              ([query (in-list trace)])
      (define start (caddr query))
      (define end (cadddr query))
      (values
        (+ selected (oracle-seek prefixes (car query) (cadr query)))
        (+ extent (- (vector-ref prefixes end) (vector-ref prefixes start)))
        (+ checksum
           (for/sum ([index (in-range start end)])
             (vector-ref (vector-ref corpus index) 1))))))
  (define parameters
    (hasheq 'itemCount count
            'queryCount query-count
            'seed seed
            'zeroExtentPeriod 5))
  (define-values (corpus-hash replay-hash validation-digest)
    (make-digests seed 'cursor-range-seek parameters corpus trace expected))
  (define (prepare)
    (cons (vector->sum-tree (make-weighted-spec) corpus) trace))
  (define (operate prepared)
    (define tree (car prepared))
    (define cursor (sum-tree-cursor tree))
    (define-values (selected extent checksum)
      (for/fold ([selected 0]
                 [extent 0]
                 [checksum 0])
                ([query (in-list (cdr prepared))])
        (define target (car query))
        (sum-tree-cursor-seek!
          cursor
          (lambda (summary)
            (cond
              [(< (weighted-summary-extent summary) target) 'before]
              [(= (weighted-summary-extent summary) target) 'at]
              [else 'after]))
          #:bias (cadr query))
        (define range
          (sum-tree-range-summary tree (caddr query) (cadddr query)))
        (values
          (+ selected (sum-tree-cursor-index cursor))
          (+ extent (weighted-summary-extent range))
          (+ checksum (weighted-summary-checksum range)))))
    (operation-result (list selected extent checksum)
                      (list (current-memory-use))))
  (define (validate value)
    (ensure 'cursor-range-seek (equal? value expected)
            "cursor/range observation mismatch" "expected" expected "actual" value)
    validation-digest)
  (define (evidence)
    (define prepared (prepare))
    (define observed (operation-result-value (operate prepared)))
    (ensure 'cursor-range-seek-evidence (equal? observed expected)
            "full cursor/range evidence trace disagrees with the oracle")
    (define tree (car prepared))
    (define invariants (check-sum-tree-invariants tree))
    (define height (sum-tree-invariants-height invariants))
    (values
      (hasheq 'treeHeight height
              'seekOperationCount query-count
              'rangeOperationCount query-count
              'operationCount (* 2 query-count)
              'resultNodeCount (sum-tree-invariants-node-count invariants)
              'finalNodeSlotSlack
              (sum-tree-invariants-node-slot-slack invariants)
              'finalChunkByteSlack 0)
      (hasheq 'B node-capacity
              'itemCount count
              'seekOperationCount query-count
              'rangeOperationCount query-count
              'operationCount (* 2 query-count)
              'seekHeightBound (* query-count (add1 height))
              'rangeHeightBoundaryBound
              (* query-count (+ (* 2 (add1 height))
                                (* 2 node-capacity)))
              'treeHeightUpperBound height)
      "256 cursor seeks and 256 ranges with explicit operation-count and height bounds"))
  (workload "cursor-range-seek"
            parameters corpus-hash replay-hash validation-digest
            prepare operate validate evidence))

(define (local-edit-workload seed)
  (define count 4097)
  (define edit-count 120)
  (define corpus (build-list count values))
  (define trace
    (for/list ([ordinal (in-range edit-count)])
      (remainder (+ seed (* ordinal 43)) (add1 count))))
  (define parameters
    (hasheq 'itemCount count
            'editCount edit-count
            'replacementSize 1
            'seed seed))
  (define validation (list count count (car corpus) (last corpus)))
  (define-values (corpus-hash replay-hash validation-digest)
    (make-digests seed 'local-insert-delete parameters corpus trace validation))
  (define (prepare)
    (define spec (make-unit-spec))
    (list (list->sum-tree spec corpus)
          (list->sum-tree spec '(inserted))
          (sum-tree-empty spec)
          trace))
  (define (operate prepared)
    (define inserted (cadr prepared))
    (define empty (caddr prepared))
    (define tree
      (for/fold ([tree (car prepared)])
                ([position (in-list (cadddr prepared))])
        (define with-insert
          (sum-tree-splice tree position position inserted))
        (sum-tree-splice with-insert position (add1 position) empty)))
    (operation-result tree (list (current-memory-use))))
  (define (validate tree)
    (ensure 'local-insert-delete (= (sum-tree-count tree) count)
            "local edits changed item count" "expected" count "actual" (sum-tree-count tree))
    (ensure 'local-insert-delete (equal? (for/list ([item (in-sum-tree tree)]) item) corpus)
            "local insert/delete did not restore the corpus")
    (check-sum-tree-invariants tree)
    validation-digest)
  (define (evidence)
    (define prepared (prepare))
    (define inserted (cadr prepared))
    (define empty (caddr prepared))
    (define counters (make-sum-tree-counters))
    (define-values (result maximum-height)
      (for/fold ([tree (car prepared)]
                 [maximum-height (tree-height (car prepared))])
                ([position (in-list (cadddr prepared))])
        (define with-insert
          (sum-tree-splice/instrumented
            tree position position inserted counters))
        (define restored
          (sum-tree-splice/instrumented
            with-insert position (add1 position) empty counters))
        (values restored
                (max maximum-height
                     (tree-height with-insert)
                     (tree-height restored)))))
    (ensure 'local-insert-delete-evidence
            (equal? (for/list ([item (in-sum-tree result)]) item) corpus)
            "full instrumented edit trace did not restore the corpus")
    (define operation-count (* 2 edit-count))
    (define snapshot (sum-tree-counters-snapshot counters))
    (define invariants (check-sum-tree-invariants result))
    (values
      (hash-add
        (snapshot->structural-counters snapshot)
        (cons 'spliceOperationCount operation-count)
        (cons 'operationCount operation-count)
        (cons 'maximumTreeHeight maximum-height)
        (cons 'resultNodeCount (sum-tree-invariants-node-count invariants))
        (cons 'finalNodeSlotSlack
              (sum-tree-invariants-node-slot-slack invariants))
        (cons 'finalChunkByteSlack 0))
      (hasheq 'B node-capacity
              'itemCount count
              'spliceOperationCount operation-count
              'operationCount operation-count
              'maximumTreeHeight maximum-height
              'operationHeightBound
              (* operation-count (add1 maximum-height))
              'nodeVisitCeiling
              (* 4 node-capacity node-capacity
                 operation-count (add1 maximum-height)))
      "240 instrumented splice operations share one counter object"))
  (workload "local-insert-delete"
            parameters corpus-hash replay-hash validation-digest
            prepare operate validate evidence))

(define (sparse-batch-workload seed)
  (define count 32769)
  (define corpus (build-list count values))
  (define edit-data
    (list (list 10 11 '(left))
          (list 16000 16002 '(middle one two))
          (list 32750 32751 '(right))))
  (define edit-count (length edit-data))
  (define replacement-count
    (for/sum ([data (in-list edit-data)]) (length (caddr data))))
  (define expected
    (let-values ([(reversed position)
                  (for/fold ([reversed '()]
                             [position 0])
                            ([data (in-list edit-data)])
                    (values
                      (append (reverse (caddr data))
                              (reverse
                                (take (drop corpus position)
                                      (- (car data) position)))
                              reversed)
                      (cadr data)))])
      (append (reverse reversed) (drop corpus position))))
  (define parameters
    (hasheq 'itemCount count
            'editCount edit-count
            'replacementItemCount replacement-count
            'seed seed))
  (define validation (list (length expected) (for/sum ([item (in-list expected)]) 1)))
  (define-values (corpus-hash replay-hash validation-digest)
    (make-digests seed 'normalized-sparse-batch parameters corpus edit-data validation))
  (define (prepare)
    (define spec (make-unit-spec))
    (define tree (list->sum-tree spec corpus))
    (define replacements
      (for/list ([data (in-list edit-data)])
        (list->sum-tree spec (caddr data))))
    (list tree
          replacements
          (for/list ([data (in-list edit-data)]
                     [replacement (in-list replacements)])
            (sum-tree-edit (car data) (cadr data) replacement))))
  (define (operate prepared)
    (define result
      (sum-tree-splice* (car prepared) (caddr prepared)))
    (operation-result result (list (current-memory-use))))
  (define (validate tree)
    (ensure 'normalized-sparse-batch
            (equal? (for/list ([item (in-sum-tree tree)]) item) expected)
            "sparse batch differs from old-snapshot oracle")
    (check-sum-tree-invariants tree)
    validation-digest)
  (define (evidence)
    (define prepared (prepare))
    (define old-tree (car prepared))
    (define replacements (cadr prepared))
    (define counters (make-sum-tree-counters))
    (define result
      (sum-tree-splice*/instrumented old-tree (caddr prepared) counters))
    (define operation-snapshot (sum-tree-counters-snapshot counters))
    (define inputs (cons old-tree replacements))
    (define final-changed (final-changed-node-identities inputs result))
    (define retained (retained-input-node-identities inputs result))
    (define space (final-result-space-metrics result))
    (define post-pass-snapshot (sum-tree-counters-snapshot counters))
    (define height
      (apply max
             (map tree-height (cons result inputs))))
    (define work (hash-ref operation-snapshot 'batch-work-node-identities))
    (define locality-ceiling
      (* 2 node-capacity (add1 edit-count) (add1 height)))
    (define work-bound
      (+ (* (add1 edit-count) (add1 height))
         work
         replacement-count))
    (define content-leaf-ceiling
      (* 2 (add1 edit-count) (add1 height)))
    (define item-visit-ceiling
      (* node-capacity content-leaf-ceiling))
    (define copied-item-ceiling
      (+ item-visit-ceiling replacement-count))
    (ensure 'normalized-sparse-batch-evidence
            (equal? operation-snapshot post-pass-snapshot)
            "post-result scans changed operation counters")
    (ensure 'normalized-sparse-batch-evidence
            (<= final-changed work locality-ceiling)
            "locality model failed"
            "F_final" final-changed
            "F_work" work
            "locality ceiling" locality-ceiling)
    (for ([name (in-list '(untouched-interior-node-visits
                            untouched-interior-leaf-visits
                            untouched-interior-item-visits))])
      (ensure 'normalized-sparse-batch-evidence
              (zero? (hash-ref operation-snapshot name))
              "retained interior was traversed"
              "counter" name
              "value" (hash-ref operation-snapshot name)))
    (ensure 'normalized-sparse-batch-evidence
            (positive? (hash-ref operation-snapshot
                                 'retained-subtree-handoffs))
            "sparse trace retained no untouched subtrees")
    (ensure 'normalized-sparse-batch-evidence
            (= (hash-ref operation-snapshot 'retained-subtree-handoffs)
               (hash-ref operation-snapshot 'retained-subtree-guards))
            "retained subtree handoff/guard counts disagree")
    (for ([name (in-list '(leaf-visits item-visits copied-items))]
          [ceiling (in-list (list content-leaf-ceiling
                                  item-visit-ceiling
                                  copied-item-ceiling))])
      (ensure 'normalized-sparse-batch-evidence
              (<= (hash-ref operation-snapshot name) ceiling)
              "sparse boundary content work exceeded its ceiling"
              "counter" name
              "value" (hash-ref operation-snapshot name)
              "ceiling" ceiling))
    (values
      (hash-add
        (snapshot->structural-counters operation-snapshot)
        (cons 'batchOperationCount 1)
        (cons 'operationCount 1)
        (cons 'FFinal final-changed)
        (cons 'FWork work)
        (cons 'retainedInputNodeIdentities retained)
        (cons 'finalNodeSlotSlack
              (sum-tree-space-metrics-node-slot-slack space))
        (cons 'finalChunkByteSlack
              (sum-tree-space-metrics-chunk-byte-slack space))
        (cons 'postPassCounterDelta 0))
      (hasheq 'B node-capacity
              'E edit-count
              'H height
              'R replacement-count
              'W work-bound
              'operationCount 1
              'contentLeafVisitCeiling content-leaf-ceiling
              'itemVisitCeiling item-visit-ceiling
              'copiedItemCeiling copied-item-ceiling
              'localityCeiling locality-ceiling)
      "one complete sparse batch; F_final <= F_work <= locality ceiling; content work is boundary-bounded"))
  (workload "normalized-sparse-batch"
            parameters corpus-hash replay-hash validation-digest
            prepare operate validate evidence))

(define (alternating-ends-workload seed)
  (define count 4097)
  (define edit-count 120)
  (define corpus (build-list count values))
  (define trace
    (build-list edit-count (lambda (ordinal) (if (even? ordinal) 'left 'right))))
  (define parameters
    (hasheq 'itemCount count
            'editCount edit-count
            'replacementSize 1
            'seed seed))
  (define validation (list count (car corpus) (last corpus)))
  (define-values (corpus-hash replay-hash validation-digest)
    (make-digests seed 'alternating-document-ends parameters corpus trace validation))
  (define (prepare)
    (define spec (make-unit-spec))
    (list (list->sum-tree spec corpus)
          (list->sum-tree spec '(temporary))
          (sum-tree-empty spec)
          trace))
  (define (operate prepared)
    (define singleton (cadr prepared))
    (define empty (caddr prepared))
    (define tree
      (for/fold ([tree (car prepared)])
                ([side (in-list (cadddr prepared))])
        (define position (if (eq? side 'left) 0 (sum-tree-count tree)))
        (define inserted (sum-tree-splice tree position position singleton))
        (sum-tree-splice inserted position (add1 position) empty)))
    (operation-result tree (list (current-memory-use))))
  (define (validate tree)
    (ensure 'alternating-document-ends
            (equal? (for/list ([item (in-sum-tree tree)]) item) corpus)
            "alternating end edits did not restore the corpus")
    (check-sum-tree-invariants tree)
    validation-digest)
  (define (evidence)
    (define prepared (prepare))
    (define singleton (cadr prepared))
    (define empty (caddr prepared))
    (define counters (make-sum-tree-counters))
    (define-values (result maximum-height)
      (for/fold ([tree (car prepared)]
                 [maximum-height (tree-height (car prepared))])
                ([side (in-list (cadddr prepared))])
        (define position (if (eq? side 'left) 0 (sum-tree-count tree)))
        (define inserted
          (sum-tree-splice/instrumented
            tree position position singleton counters))
        (define restored
          (sum-tree-splice/instrumented
            inserted position (add1 position) empty counters))
        (values restored
                (max maximum-height
                     (tree-height inserted)
                     (tree-height restored)))))
    (ensure 'alternating-document-ends-evidence
            (equal? (for/list ([item (in-sum-tree result)]) item) corpus)
            "full alternating trace did not restore the corpus")
    (define operation-count (* 2 edit-count))
    (define snapshot (sum-tree-counters-snapshot counters))
    (define invariants (check-sum-tree-invariants result))
    (values
      (hash-add
        (snapshot->structural-counters snapshot)
        (cons 'spliceOperationCount operation-count)
        (cons 'operationCount operation-count)
        (cons 'maximumTreeHeight maximum-height)
        (cons 'resultNodeCount (sum-tree-invariants-node-count invariants))
        (cons 'finalNodeSlotSlack
              (sum-tree-invariants-node-slot-slack invariants))
        (cons 'finalChunkByteSlack 0))
      (hasheq 'B node-capacity
              'itemCount count
              'spliceOperationCount operation-count
              'operationCount operation-count
              'maximumTreeHeight maximum-height
              'operationHeightBound
              (* operation-count (add1 maximum-height))
              'nodeVisitCeiling
              (* 4 node-capacity node-capacity
                 operation-count (add1 maximum-height)))
      "240 instrumented alternating-end splices share one counter object"))
  (workload "alternating-document-ends"
            parameters corpus-hash replay-hash validation-digest
            prepare operate validate evidence))

(define (retained-snapshots-workload seed)
  (define count 4097)
  (define retention-count 64)
  (define corpus (build-list count values))
  (define trace
    (for/list ([ordinal (in-range retention-count)])
      (remainder (+ seed (* ordinal 61)) count)))
  (define parameters
    (hasheq 'itemCount count
            'editCount retention-count
            'retentionCount retention-count
            'seed seed))
  (define validation (list count retention-count retention-count))
  (define-values (corpus-hash replay-hash validation-digest)
    (make-digests seed 'retained-roots-cursors parameters corpus trace validation))
  (define (prepare)
    (define spec (make-unit-spec))
    (list (list->sum-tree spec corpus)
          (list->sum-tree spec '(replacement))
          trace))
  (define (operate prepared)
    (define replacement (cadr prepared))
    (define-values (tree roots cursors indexes)
      (for/fold ([tree (car prepared)]
                 [roots '()]
                 [cursors '()]
                 [indexes '()])
                ([index (in-list (caddr prepared))])
        (values
          (sum-tree-splice tree index (add1 index) replacement)
          (cons tree roots)
          (cons (sum-tree-cursor tree index) cursors)
          (cons index indexes))))
    (operation-result
      (retained-result tree roots cursors indexes)
      (list (current-memory-use))))
  (define (validate value)
    (define tree (retained-result-tree value))
    (ensure 'retained-roots-cursors (= (sum-tree-count tree) count)
            "retained workload changed final count")
    (for ([root (in-list (retained-result-roots value))]
          [cursor (in-list (retained-result-cursors value))]
          [index (in-list (retained-result-indexes value))])
      (ensure 'retained-roots-cursors (= (sum-tree-count root) count)
              "retained root changed count")
      (ensure 'retained-roots-cursors (= (sum-tree-cursor-index cursor) index)
              "retained cursor changed index")
      (ensure 'retained-roots-cursors
              (= (sum-tree-cursor-prefix-summary cursor) index)
              "retained cursor changed prefix"))
    (check-sum-tree-invariants tree)
    validation-digest)
  (define (evidence)
    (define prepared (prepare))
    (define replacement (cadr prepared))
    (define counters (make-sum-tree-counters))
    (define-values (tree roots cursors indexes maximum-height)
      (for/fold ([tree (car prepared)]
                 [roots '()]
                 [cursors '()]
                 [indexes '()]
                 [maximum-height (tree-height (car prepared))])
                ([index (in-list (caddr prepared))])
        (define next-tree
          (sum-tree-splice/instrumented
            tree index (add1 index) replacement counters))
        (values next-tree
                (cons tree roots)
                (cons (sum-tree-cursor tree index) cursors)
                (cons index indexes)
                (max maximum-height (tree-height next-tree)))))
    (ensure 'retained-roots-cursors-evidence
            (= (length roots) retention-count)
            "instrumented retention trace has the wrong root count")
    (for ([cursor (in-list cursors)]
          [index (in-list indexes)])
      (ensure 'retained-roots-cursors-evidence
              (= (sum-tree-cursor-index cursor) index)
              "retained cursor moved during evidence collection"))
    (define snapshot (sum-tree-counters-snapshot counters))
    (define invariants (check-sum-tree-invariants tree))
    (define operation-count (* 2 retention-count))
    (values
      (hash-add
        (snapshot->structural-counters snapshot)
        (cons 'spliceOperationCount retention-count)
        (cons 'cursorOperationCount retention-count)
        (cons 'operationCount operation-count)
        (cons 'maximumTreeHeight maximum-height)
        (cons 'resultNodeCount (sum-tree-invariants-node-count invariants))
        (cons 'retainedRootCount (length roots))
        (cons 'retainedCursorCount (length cursors))
        (cons 'finalNodeSlotSlack
              (sum-tree-invariants-node-slot-slack invariants))
        (cons 'finalChunkByteSlack 0))
      (hasheq 'B node-capacity
              'itemCount count
              'retentionCount retention-count
              'spliceOperationCount retention-count
              'cursorOperationCount retention-count
              'operationCount operation-count
              'maximumTreeHeight maximum-height
              'spliceOperationHeightBound
              (* retention-count (add1 maximum-height))
              'cursorOperationHeightBound
              (* retention-count (add1 maximum-height)))
      "64 instrumented edits and 64 root-local cursor operations match the retained trace"))
  (workload "retained-roots-cursors"
            parameters corpus-hash replay-hash validation-digest
            prepare operate validate evidence))

(define (make-stage1-workloads seed)
  (unless (exact-nonnegative-integer? seed)
    (raise-argument-error 'make-stage1-workloads
                          "exact-nonnegative-integer?"
                          seed))
  (list (packed-build-workload seed)
        (cursor-range-workload seed)
        (local-edit-workload seed)
        (sparse-batch-workload seed)
        (alternating-ends-workload seed)
        (retained-snapshots-workload seed)))

