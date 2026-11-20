(library (syntax-highlighting job)
  (export serve)
  (import (chezscheme) (document))

  ;; A file buffer's text sits in one root node, one position after its
  ;; offset, which spares a search of the tree for each span.
  (define (position-mapping doc n)
    (let ([size (document:length doc)])
      (cond
        [(fx= size n) (values (lambda (offset) offset) (lambda (offset) offset))]
        [(and (fx= size (fx+ n 2))
              (not (char? (document:token doc 0)))
              (eq? (document:token doc (fx- size 1)) 'close))
         (values (lambda (offset) (fx+ offset 1)) (lambda (offset) (fx+ offset 1)))]
        [else
         (let ([unit (document:unit characters)])
           (values (lambda (offset) (fx- (document:position doc (fx+ offset 1) unit) 1))
                   (lambda (offset) (document:position doc offset unit))))])))

  (define (text-length doc)
    (document:offset doc (document:length doc) (document:unit characters)))

  (define (moved position edit)
    (let ([start (car edit)] [removed (cadr edit)] [inserted (caddr edit)])
      (cond
        [(fx<= position start) position]
        [(fx>= position (fx+ start removed)) (fx+ position (fx- inserted removed))]
        [else start])))

  ;; The record's spans take no text inserted at their edges, unlike a
  ;; sticky layer's, since the edited range is always sent again and so
  ;; the difference never reaches the buffer.
  (define (moved-start position edit)
    (if (and (fx= position (car edit)) (fx= (cadr edit) 0))
        (fx+ position (caddr edit))
        (moved position edit)))

  (define (moved-spans spans edits)
    (let ([acc '()])
      (vector-for-each
        (lambda (span)
          (let loop ([start (car span)] [end (cadr span)] [edits edits])
            (cond
              [(fx>= start end) (void)]
              [(null? edits)
               (set! acc (cons (if (and (fx= start (car span)) (fx= end (cadr span)))
                                   span
                                   (list start end (caddr span)))
                               acc))]
              [else (loop (moved-start start (car edits)) (moved end (car edits)) (cdr edits))])))
        spans)
      (list->vector (reverse acc))))

  (define (clipped spans start end)
    (let ([acc '()])
      (vector-for-each
        (lambda (span)
          (let ([a (fxmax start (car span))] [b (fxmin end (cadr span))])
            (when (fx< a b)
              (set! acc (cons (if (and (fx= a (car span)) (fx= b (cadr span))) span (list a b (caddr span)))
                              acc)))))
        spans)
      (list->vector (reverse acc))))

  ;; The parts of old spans outside the range stay, as buffers:set-spans!
  ;; keeps them, so the record stays what the buffer holds.
  (define (spliced old start end new)
    (let ([before '()] [after '()])
      (vector-for-each
        (lambda (span)
          (when (fx< (car span) start)
            (set! before (cons (if (fx<= (cadr span) start) span (list (car span) start (caddr span))) before)))
          (when (fx> (cadr span) end)
            (set! after (cons (if (fx>= (car span) end) span (list end (cadr span) (caddr span))) after))))
        old)
      (list->vector (append (reverse before) (vector->list new) (reverse after)))))

  (define (difference old new)
    (let* ([on (vector-length old)] [nn (vector-length new)]
           [first (let loop ([i 0])
                    (if (and (fx< i on) (fx< i nn) (equal? (vector-ref old i) (vector-ref new i)))
                        (loop (fx+ i 1))
                        i))]
           [last (let loop ([i 0])
                   (if (and (fx< (fx+ first i) on) (fx< (fx+ first i) nn)
                            (equal? (vector-ref old (fx- on i 1)) (vector-ref new (fx- nn i 1))))
                       (loop (fx+ i 1))
                       i))])
      (and (not (and (fx= first on) (fx= first nn)))
           (let ([starts (append (if (fx< first on) (list (car (vector-ref old first))) '())
                                 (if (fx< first nn) (list (car (vector-ref new first))) '()))]
                 [ends (append (if (fx< first (fx- on last)) (list (cadr (vector-ref old (fx- on last 1)))) '())
                               (if (fx< first (fx- nn last)) (list (cadr (vector-ref new (fx- nn last 1)))) '()))])
             (cons (apply fxmin starts) (apply fxmax ends))))))

  (define (hull a b)
    (cond
      [(not a) b]
      [(not b) a]
      [else (cons (fxmin (car a) (car b)) (fxmax (cdr a) (cdr b)))]))

  (define (ranges-moved ranges edit)
    (fold-right
      (lambda (r acc)
        (let ([a (moved (car r) edit)] [b (moved (cdr r) edit)])
          (if (fx< a b) (cons (cons a b) acc) acc)))
      '() ranges))

  (define (ranges-with ranges start end)
    (if (fx>= start end)
        ranges
        (let loop ([rs ranges] [start start] [end end] [before '()])
          (cond
            [(null? rs) (append (reverse before) (list (cons start end)))]
            [(fx< (cdar rs) start) (loop (cdr rs) start end (cons (car rs) before))]
            [(fx> (caar rs) end) (append (reverse before) (cons (cons start end) rs))]
            [else (loop (cdr rs) (fxmin start (caar rs)) (fxmax end (cdar rs)) before)]))))

  (define (ranges-without ranges start end)
    (fold-right
      (lambda (r acc)
        (let ([a (car r)] [b (cdr r)])
          (if (or (fx<= b start) (fx>= a end))
              (cons r acc)
              (let ([acc (if (fx> b end) (cons (cons end b) acc) acc)])
                (if (fx< a start) (cons (cons a start) acc) acc)))))
      '() ranges))

  (define (ranges-hull ranges start end)
    (fold-left
      (lambda (acc r)
        (let ([a (fxmax start (car r))] [b (fxmin end (cdr r))])
          (if (fx< a b) (hull acc (cons a b)) acc)))
      #f ranges))

  ;; The range widens to hold whole spans, since set-spans! keeps the part
  ;; of a span outside its range.
  (define (update index record range n size start-of end-of)
    (let* ([spans (filter (lambda (s) (and (fx< (car s) (cdr range)) (fx> (cadr s) (car range))))
                          (vector->list record))]
           [start (fold-left (lambda (m s) (fxmin m (car s))) (car range) spans)]
           [end (fold-left (lambda (m s) (fxmax m (cadr s))) (cdr range) spans)])
      (list index
            (if (fx= start 0) 0 (start-of start))
            (if (fx= end n) size (end-of end))
            (map (lambda (s) (list (start-of (car s)) (end-of (cadr s)) (caddr s))) spans))))

  (define (answer-range answer n)
    (cond
      [(vector? answer) (values 0 n answer)]
      [(and (list? answer) (fx= (length answer) 3)
            (fixnum? (car answer)) (fixnum? (cadr answer)) (fx<= 0 (car answer) (cadr answer) n)
            (vector? (caddr answer)))
       (values (car answer) (cadr answer) (caddr answer))]
      [else (assertion-violation 'serve "not a layer's spans" answer)]))

  (define (serve input emit receive highlight)
    (let ([version (list-ref input 0)] [doc (list-ref input 1)] [given (list-ref input 2)]
          [faces? (list-ref input 3)] [faces-index (list-ref input 4)] [count (list-ref input 5)])
      (let ([records (make-vector count #f)] [edited (make-vector count '())]
            [edits '()] [unmoved '()] [dirty? #t] [more? #f] [last-data #f])
        (define (settle!)
          (unless (null? unmoved)
            (let ([in-order (reverse unmoved)])
              (do ([i 0 (fx+ i 1)]) ((fx= i count))
                (let ([record (vector-ref records i)])
                  (when record (vector-set! records i (moved-spans record in-order))))))
            (set! unmoved '())))
        (define (shown? i) (or faces? (not (eqv? i faces-index))))
        (define (emit-updates! updates)
          (unless (null? updates)
            (emit (list 'spans version updates))))
        (define (whole-updates indices)
          (settle!)
          (let ([n (text-length doc)])
            (let-values ([(start-of end-of) (position-mapping doc n)])
              (fold-right
                (lambda (i acc)
                  (let ([record (vector-ref records i)])
                    (if record (cons (update i record (cons 0 n) n (document:length doc) start-of end-of) acc) acc)))
                '() indices))))
        (define (answer! i answer n start-of end-of)
          (let-values ([(start end spans) (answer-range answer n)])
            (let* ([old (or (vector-ref records i) '#())]
                   [whole? (vector? answer)]
                   [new (if whole? spans (clipped spans start end))]
                   [changed (if whole? (difference old new) (difference (clipped old start end) new))]
                   [range (hull changed (ranges-hull (vector-ref edited i) start end))])
              (vector-set! records i (if whole? new (spliced old start end new)))
              (vector-set! edited i (ranges-without (vector-ref edited i) start end))
              (and range (shown? i) (update i (vector-ref records i) range n (document:length doc) start-of end-of)))))
        (define (answered! layers data more)
          (unless (and (list? layers) (fx= (length layers) count))
            (assertion-violation 'serve "not a list of spans for each layer" layers))
          (let ([n (text-length doc)])
            (let-values ([(start-of end-of) (position-mapping doc n)])
              (let loop ([i 0] [layers layers] [updates '()])
                (if (null? layers)
                    (emit-updates! (reverse updates))
                    (let ([u (answer! i (car layers) n start-of end-of)])
                      (loop (fx+ i 1) (cdr layers) (if u (cons u updates) updates)))))))
          (when (and data (not (equal? data last-data)))
            (emit (cons 'data data)))
          (set! last-data data)
          (set! more? (and more #t)))
        (define (run!)
          (settle!)
          (let ([since (reverse edits)])
            (set! edits '())
            (set! dirty? #f)
            (call-with-values (lambda () (highlight doc given since))
              (case-lambda
                [(layers data) (answered! layers data #f)]
                [(layers data more) (answered! layers data more)]))))
        (define (take! message)
          (case (car message)
            [(edit)
             (let* ([start (list-ref message 2)] [inserted (list-ref message 4)]
                    [edit (list start (list-ref message 3) inserted)])
               (set! version (cadr message))
               (set! doc (list-tail message 5))
               (set! edits (cons edit edits))
               (set! unmoved (cons edit unmoved))
               (do ([i 0 (fx+ i 1)]) ((fx= i count))
                 (vector-set! edited i (ranges-with (ranges-moved (vector-ref edited i) edit)
                                                    start (fx+ start inserted))))
               (set! dirty? #t))]
            [(input)
             (set! given (cdr message))
             (set! dirty? #t)]
            [(faces)
             (set! faces? (cdr message))
             (when (and faces? faces-index)
               (emit-updates! (whole-updates (list faces-index))))]
            [(resend) (emit-updates! (whole-updates (filter shown? (iota count))))]))
        (let loop ()
          (when (or dirty? more?) (run!))
          (unless more? (take! (receive)))
          (let drain ()
            (let ([message (receive 0)])
              (unless (eof-object? message)
                (take! message)
                (drain))))
          (loop))))))
