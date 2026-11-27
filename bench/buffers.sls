#!tuna
(import (document) (buffers) (hooks))

(define (now-ns)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (median xs)
  (list-ref (list-sort < xs) (quotient (length xs) 2)))

;; Text like source code: one word in fifty is not ASCII.
(define (sample-text megabytes)
  (let-values ([(port extract) (open-bytevector-output-port)])
    (let ([target (* megabytes 1000000)])
      (let loop ([size 0] [word 0])
        (if (>= size target)
            (extract)
            (let ([bytes (string->utf8
                           (string-append
                             (cond [(= (mod word 50) 0) "café"] [(= (mod word 50) 25) "λx"] [else "word"])
                             (if (= (mod word 9) 8) "\n" " ")))])
              (put-bytevector port bytes)
              (loop (+ size (bytevector-length bytes)) (+ word 1))))))))

(define batch 2000)

(define (randoms low high)
  (let ([v (make-vector batch)])
    (do ([i 0 (fx+ i 1)]) ((fx= i batch) v)
      (vector-set! v i (+ low (random (- high low)))))))

(define (ns-per-op make-arguments run)
  (median
    (map (lambda (k)
           (let ([args (make-arguments)])
             (collect-rendezvous)
             (let ([start (now-ns)])
               (run args)
               (/ (- (now-ns) start) (exact->inexact batch)))))
         (iota 9))))

(define (show name megabytes value)
  (printf "~a-~amb ~,2f\n" name megabytes value))

(buffers:define-layer highlights (priority 10))
(buffers:define-layer responses (travels) (sticky after))

(define %made 0)

;; Collected into the oldest generation at once, so that no measurement
;; pays for copying a new document between generations.
(define (text-buffer bytes)
  (set! %made (+ %made 1))
  (let ([b (buffers:make (format "bench-~a" %made)
             (document:replace (document:from-datum '(buffers:text ())) 1 1 (document:from-utf8 bytes)))])
    (collect (collect-maximum-generation))
    b))

(define (typing-cost b) (ns-per-op (lambda () (inner b)) (typing b)))

(define (snapshot-cost b)
  (median
    (map (lambda (k)
           (let ([ps (inner b)] [spent 0])
             (collect-rendezvous)
             (buffers:with-buffer b
               (vector-for-each
                 (lambda (p)
                   (buffers:replace! b p p "x")
                   (let ([start (now-ns)])
                     (buffers:document b)
                     (set! spent (+ spent (- (now-ns) start)))))
                 ps))
             (/ spent (exact->inexact batch))))
         (iota 9))))

(define (inner b) (randoms 1 (- (document:length (buffers:document b)) 1)))

;; Commands run with their buffer current, so typing does too.
(define (typing b)
  (lambda (ps)
    (buffers:with-buffer b
      (vector-for-each (lambda (p) (buffers:replace! b p p "x")) ps))))

(define (add-highlights! b count)
  (let ([size (document:length (buffers:document b))])
    (buffers:set-spans! (buffers:layer b highlights) 0 size
      (map (lambda (i)
             (let ([at (+ 1 (* i (quotient (- size 2) count)))])
               (list at (+ at 4) 'keyword)))
           (iota count)))))

(define (add-responses! b count)
  (let ([size (document:length (buffers:document b))] [l (buffers:layer b responses)])
    (for-each (lambda (i)
                (let ([at (+ 1 (* i (quotient (- size 2) count)))])
                  (buffers:add-span! l at (+ at 3) 'reply)))
              (iota count))))

(define (bench megabytes)
  (let ([bytes (sample-text megabytes)])
    (let* ([plain (text-buffer bytes)]
           [insert (ns-per-op (lambda () (inner plain)) (typing plain))])
      (show "insert" megabytes insert)
      (show "snapshot" megabytes (snapshot-cost plain))
      (show "stop" megabytes
        (ns-per-op (lambda () (inner plain)) (lambda (ps) (vector-for-each (lambda (p) (buffers:stop plain p)) ps))))
      (show "next-stop" megabytes
        (ns-per-op (lambda () (inner plain)) (lambda (ps) (vector-for-each (lambda (p) (buffers:next-stop plain p)) ps))))
      (let ([anchors (map (lambda (p) (buffers:anchor plain p)) (vector->list (inner plain)))])
        (show "anchor-read" megabytes
          (median
            (map (lambda (k)
                   (buffers:replace! plain 1 1 "x")
                   (let ([start (now-ns)])
                     (for-each buffers:anchor-position anchors)
                     (/ (- (now-ns) start) (exact->inexact batch))))
                 (iota 9))))))
    (let ([b (text-buffer bytes)])
      (add-highlights! b 10000)
      (collect (collect-maximum-generation))
      (show "layer-move" megabytes (- (typing-cost b) (typing-cost (text-buffer bytes)))))
    (let ([b (text-buffer bytes)])
      (add-responses! b 1000)
      (collect (collect-maximum-generation))
      (show "travelling" megabytes (- (typing-cost b) (typing-cost (text-buffer bytes)))))
    (let ([b (text-buffer bytes)] [quiet (lambda (b e) #f)])
      (add-highlights! b 10000)
      (add-responses! b 1000)
      (for-each (lambda (p) (buffers:anchor b p)) (vector->list (inner b)))
      (hooks:add! buffers:after-edit quiet)
      (collect (collect-maximum-generation))
      (show "keystroke" megabytes
        (ns-per-op (lambda () (inner b))
          (lambda (ps)
            (buffers:with-buffer b
              (vector-for-each (lambda (p) (let ([at (or (buffers:stop b p) p)]) (buffers:replace! b at at "x"))) ps)))))
      (hooks:remove! buffers:after-edit quiet))))

;; A buffer that code built, with a node per line, where stops take the
;; general path through openings and closings.
(buffers:define-kind section (content nodes))
(buffers:define-kind line)

(define (structured-buffer megabytes)
  (set! %made (+ %made 1))
  (let ([b (buffers:make (format "bench-~a" %made)
             (apply section '()
               (map (lambda (i) (line '() "word word café word λx word word word.\n"))
                    (iota (quotient (* megabytes 1000000) 40)))))])
    (collect (collect-maximum-generation))
    b))

(define (bench-structured megabytes)
  (let ([b (structured-buffer megabytes)])
    (show "stop-structured" megabytes
      (ns-per-op (lambda () (inner b)) (lambda (ps) (vector-for-each (lambda (p) (buffers:stop b p)) ps))))
    (show "next-stop-structured" megabytes
      (ns-per-op (lambda () (inner b)) (lambda (ps) (vector-for-each (lambda (p) (buffers:next-stop b p)) ps))))
    (show "keystroke-structured" megabytes
      (ns-per-op (lambda () (inner b))
        (lambda (ps)
          (buffers:with-buffer b
            (vector-for-each (lambda (p) (let ([at (buffers:stop b p)]) (buffers:replace! b at at "x"))) ps)))))))

;; A status buffer of two thousand keyed sections, one of them changed.
(buffers:define-kind status (content nodes))

(define (sections changed)
  (map (lambda (i)
         (list 'buffers:text (list (cons 'key i))
           (if (= i changed) "changed line\n" (format "section ~a\n" i))))
       (iota 2000)))

(define (bench-reconcile)
  (let ([b (buffers:make "bench-status" (apply status '() (sections -1)))])
    (show "reconcile" 0
      (median
        (map (lambda (k)
               (let ([children (sections k)])
                 (collect-rendezvous)
                 (let ([start (now-ns)])
                   (buffers:reconcile! b (document:token (buffers:document b) 0) children)
                   (/ (- (now-ns) start) 1e6))))
             (iota 9))))))

;; Trimming a log at idle moves each live anchor through the edits it
;; has not seen: here a thousand anchors through a thousand edits.
(define (bench-trim-anchors)
  (let ([b (text-buffer (sample-text 1))])
    (show "trim-anchors" 1
      (median
        (map (lambda (k)
               (let ([anchors (map (lambda (p) (buffers:anchor b p)) (map (lambda (i) (+ i 1)) (iota 1000)))])
                 (do ([i 0 (+ i 1)]) ((= i 1000)) (buffers:replace! b 1 1 "x"))
                 (collect-rendezvous)
                 (let ([start (now-ns)])
                   (for-each buffers:anchor-position anchors)
                   (/ (- (now-ns) start) 1e6))))
             (iota 9))))))

(define list-rows 3880000)

(define (rows generation)
  (document:repeat (document:from-datum (vector 'row (list (cons 'generation generation)))) list-rows))

;; A new set of rows differs from the old at its first row; the same set
;; again is read to its end.
(define (bench-replace-rows)
  (let ([b (buffers:make "bench-rows" (document:replace (document:from-datum '(buffers:text ())) 1 1 (rows 0)))]
        [generation 0])
    (define (replace-ms next-generation)
      (median
        (map (lambda (k)
               (let ([content (rows (next-generation))])
                 (collect-rendezvous)
                 (let ([start (now-ns)])
                   (buffers:splice! b 1 (+ list-rows 1) content)
                   (/ (- (now-ns) start) 1e6))))
             (iota 9))))
    (show "replace-rows" 0 (replace-ms (lambda () (set! generation (+ generation 1)) generation)))
    (show "replace-same-rows" 0 (replace-ms (lambda () generation)))))

(buffers:define-kind page (content nodes))
(buffers:define-kind paragraph)
(buffers:define-kind heading)
(buffers:define-kind grid (content nodes))
(buffers:define-kind row (content nodes))
(buffers:define-kind cell (isolating))

(define paragraph-text "Buy milk and café, then λx words.\n")

(define (paragraphs count) (map (lambda (i) (paragraph '() paragraph-text)) (iota count)))

(define (paragraph-start k) (+ 1 (* k (+ (string-length paragraph-text) 2))))

(define (line-start k) (+ 1 (* k (string-length paragraph-text))))

(define (blocks-buffer)
  (set! %made (+ %made 1))
  (let ([b (buffers:make (format "bench-~a" %made)
             (apply page '()
               (append (paragraphs 1000) (list (grid '() (row '() (cell '() "a\n") (cell '() "b\n")))) (paragraphs 1000))))])
    (collect (collect-maximum-generation))
    b))

(define (lines-buffer)
  (text-buffer (string->utf8 (apply string-append (make-list 2000 paragraph-text)))))

(define (op-cost op)
  (median
    (map (lambda (k)
           (collect-rendezvous)
           (let ([start (now-ns)])
             (do ([i 0 (fx+ i 1)]) ((fx= i batch)) (op))
             (/ (- (now-ns) start) (exact->inexact batch))))
         (iota 9))))

;; splice! is not fitted, so it takes an edit back exactly.
(define (undone! b version)
  (for-each
    (lambda (e)
      (let ([start (buffers:edit-start e)])
        (buffers:splice! b start (+ start (buffers:piece-length (buffers:edit-inserted e))) (buffers:edit-removed e))))
    (reverse (buffers:edits-since b version))))

(define (with-undo b edit!)
  (lambda ()
    (let ([v (buffers:version b)])
      (edit!)
      (undone! b v))))

(define (show-blocks name value) (printf "~a ~,2f\n" name value))

(define (bench-blocks)
  (let* ([b (blocks-buffer)] [t (lines-buffer)]
         [text (+ (paragraph-start 500) 1)] [next-text (+ (paragraph-start 501) 1)]
         [line (line-start 500)] [cell-text (+ (paragraph-start 1000) 3)])
    (define (retype buffer at) (lambda () (buffers:replace! buffer at (+ at 1) "") (buffers:replace! buffer at at "B")))
    (show-blocks "delete-reinsert-start-blocks" (op-cost (retype b text)))
    (show-blocks "delete-reinsert-start-text" (op-cost (retype t line)))
    (show-blocks "insert-delete-start-blocks" (op-cost (lambda () (buffers:replace! b text text "x") (buffers:replace! b text (+ text 1) ""))))
    (show-blocks "delete-reinsert-inside-blocks" (op-cost (retype b (+ text 3))))
    (show-blocks "delete-reinsert-inside-text" (op-cost (retype t (+ line 4))))
    (show-blocks "delete-across-blocks" (op-cost (with-undo b (lambda () (buffers:replace! b (+ text 18) (+ next-text 10) "")))))
    (show-blocks "delete-whole-block" (op-cost (with-undo b (lambda () (buffers:replace! b text (- next-text 2) "")))))
    (show-blocks "delete-into-table" (op-cost (with-undo b (lambda () (buffers:replace! b (+ (paragraph-start 999) 10) (+ cell-text 1) "")))))
    (show-blocks "yank-heading-mid-paragraph" (op-cost (with-undo b (lambda () (buffers:insert! b (+ text 8) (heading '() "Plan\n"))))))))

;; A selection of a view moves its buffer to the front of the order of
;; use: here among a hundred live buffers.
(define (bench-move-to-front)
  (let ([bs (map (lambda (i) (buffers:make (format "front-~a" i) "")) (iota 100))])
    (show "move-to-front" 0
      (median
        (map (lambda (k)
               (let ([picks (map (lambda (i) (list-ref bs (random 100))) (iota 200))])
                 (collect-rendezvous)
                 (let ([start (now-ns)])
                   (for-each buffers:move-to-front! picks)
                   (/ (- (now-ns) start) 200.0))))
             (iota 9))))))

(define (run)
  (random-seed 7)
  (bench-move-to-front)
  (for-each bench '(1 10 100))
  (for-each bench-structured '(1 10))
  (bench-reconcile)
  (bench-trim-anchors)
  (bench-replace-rows)
  (bench-blocks))
