;; Every query of the model is a scan, so that it is plainly right.
(library (document-checks)
  (export edit-checks typing-checks)
  (import (chezscheme) (document))

  (define failures 0)
  (define checks 0)

  (define (check! what expected actual)
    (set! checks (+ checks 1))
    (unless (equal? expected actual)
      (set! failures (+ failures 1))
      (when (< failures 10)
        (printf "~a: expected ~s, got ~s\n" what expected actual))))

  (define chars
    (string->list "abcdefgh  \n\nλé日本🙂x"))

  (define (random-char) (list-ref chars (random (length chars))))

  (define (random-string n)
    (list->string (map (lambda (i) (random-char)) (iota n))))

  (define kinds '(p q r))

  (define (random-attributes)
    (case (random 3)
      [(0) '()]
      [(1) (list (cons 'key (random 100)))]
      [else (list (cons 'name (random-string 3)) (cons 'tags (list "a" (vector 1 2))))]))

  (define (random-datum depth)
    (case (if (> depth 2) (random 3) (random 6))
      [(0 1) (random-string (random (if (= (random 10) 0) 3000 12)))]
      [(2) (if (= (random 4) 0)
               (vector 'document:raw-byte (list (cons 'byte (+ 128 (random 128)))))
               (vector (list-ref kinds (random 3)) (random-attributes)))]
      [else
       (cons* (list-ref kinds (random 3)) (random-attributes)
              (map (lambda (i) (random-datum (+ depth 1))) (iota (random 4))))]))

  (define (random-datums n) (map (lambda (i) (random-datum 0)) (iota n)))

  (define (datum->tokens d)
    (cond
      [(string? d) (string->list d)]
      [(vector? d) (list (list 'atom (vector-ref d 0) (vector-ref d 1)))]
      [else (append (list (list 'open (car d) (cadr d)))
                    (apply append (map datum->tokens (cddr d)))
                    (list 'close))]))

  (define (model . datums) (list->vector (apply append (map datum->tokens datums))))

  (define (opening? t) (and (pair? t) (eq? (car t) 'open)))
  (define (closing? t) (eq? t 'close))
  (define (atom-token? t) (and (pair? t) (eq? (car t) 'atom)))

  (define (sub v s e) (vector->list (vector-copy v s (- e s))))

  (define (depth-at v p)
    (let loop ([i 0] [d 0])
      (if (= i p) d
          (loop (+ i 1) (cond [(opening? (vector-ref v i)) (+ d 1)] [(closing? (vector-ref v i)) (- d 1)] [else d])))))

  (define (text-of tokens)
    (list->string
      (filter values (map (lambda (t) (cond [(char? t) t] [(atom-token? t) #\xFFFC] [else #f])) tokens))))

  (define (utf8-of tokens)
    (apply bytevector-append
      (map (lambda (t)
             (cond
               [(char? t) (string->utf8 (string t))]
               [(and (atom-token? t) (eq? (cadr t) 'document:raw-byte)) (bytevector (cdr (assq 'byte (caddr t))))]
               [(atom-token? t) (string->utf8 "\xFFFC;")]
               [else #vu8()]))
           tokens)))

  (define (bytevector-append . bvs)
    (let ([r (make-bytevector (apply + (map bytevector-length bvs)))])
      (let loop ([bvs bvs] [at 0])
        (if (null? bvs) r
            (begin (bytevector-copy! (car bvs) 0 r at (bytevector-length (car bvs)))
                   (loop (cdr bvs) (+ at (bytevector-length (car bvs)))))))))

  (define (units t unit)
    (cond
      [(char? t)
       (case unit
         [(characters) 1]
         [(bytes) (bytevector-length (string->utf8 (string t)))]
         [(atoms) 0]
         [else (if (> (char->integer t) #xFFFF) 2 1)])]
      [(atom-token? t)
       (case unit
         [(bytes) (if (eq? (cadr t) 'document:raw-byte) 1 3)]
         [else 1])]
      [else 0]))

  (define (offset-of v p unit)
    (let loop ([i 0] [n 0]) (if (= i p) n (loop (+ i 1) (+ n (units (vector-ref v i) unit))))))

  (define (in-line? v start end)
    (let ([after (let loop ([i end])
                   (cond
                     [(= i (vector-length v)) #f]
                     [(atom-token? (vector-ref v i)) (loop (+ i 1))]
                     [else (vector-ref v i)]))]
          [before (let loop ([i (- start 1)])
                    (cond
                      [(< i 0) #f]
                      [(atom-token? (vector-ref v i)) (loop (- i 1))]
                      [else (vector-ref v i)]))])
      (or (char? after) (and (char? before) (not (char=? before #\newline))))))

  (define (in-line-offsets v)
    (let* ([n (vector-length v)] [r (make-vector (+ n 1) 0)])
      (do ([i 0 (+ i 1)]) ((= i n) r)
        (vector-set! r (+ i 1)
          (+ (vector-ref r i) (if (and (atom-token? (vector-ref v i)) (in-line? v i (+ i 1))) 1 0))))))

  (define (enclosing v p)
    (let loop ([i (- p 1)] [depth 0])
      (cond
        [(< i 0) #f]
        [(closing? (vector-ref v i)) (loop (- i 1) (+ depth 1))]
        [(opening? (vector-ref v i)) (if (= depth 0) i (loop (- i 1) (- depth 1)))]
        [else (loop (- i 1) depth)])))

  (define (node-end v start)
    (if (atom-token? (vector-ref v start))
        (+ start 1)
        (let loop ([i (+ start 1)] [depth 0])
          (cond
            [(= i (vector-length v)) i]
            [(and (closing? (vector-ref v i)) (= depth 0)) (+ i 1)]
            [(opening? (vector-ref v i)) (loop (+ i 1) (+ depth 1))]
            [(closing? (vector-ref v i)) (loop (+ i 1) (- depth 1))]
            [else (loop (+ i 1) depth)]))))

  (define (tokens->datums tokens)
    (let loop ([ts tokens] [stack (list (list 'root))] [text '()])
      (define (flush stack)
        (if (null? text) stack
            (cons (cons (list->string (reverse text)) (car stack)) (cdr stack))))
      (define (add d stack) (cons (cons d (car stack)) (cdr stack)))
      (define (close stack)
        (let* ([frame (reverse (car stack))] [head (car frame)])
          (add (cons* (cadr head) (caddr head) (cdr frame)) (cdr stack))))
      (cond
        [(null? ts)
         (let finish ([stack (flush stack)])
           (if (null? (cdr stack)) (cdr (reverse (car stack))) (finish (close stack))))]
        [(char? (car ts)) (loop (cdr ts) stack (cons (car ts) text))]
        [(atom-token? (car ts)) (loop (cdr ts) (add (vector (cadr (car ts)) (caddr (car ts))) (flush stack)) '())]
        [(opening? (car ts)) (loop (cdr ts) (cons (list (car ts)) (flush stack)) '())]
        [else (loop (cdr ts) (close (flush stack)) '())])))

  (define (line-of v p)
    (+ 1 (length (filter (lambda (t) (eqv? t #\newline)) (sub v 0 p)))))

  (define (line-start v line)
    (let loop ([i 0] [line line])
      (cond
        [(= line 1) i]
        [(eqv? (vector-ref v i) #\newline) (loop (+ i 1) (- line 1))]
        [else (loop (+ i 1) line)])))

  (define (token-of doc p)
    (let ([t (document:token doc p)])
      (cond
        [(document:node? t)
         (list (if (document:atom? t) 'atom 'open) (document:node-kind t) (document:node-start t))]
        [else t])))

  (define (model-token v p)
    (if (= p (vector-length v))
        (eof-object)
        (let ([t (vector-ref v p)])
          (if (pair? t) (list (car t) (cadr t) p) t))))

  (define (sample-positions n k)
    (if (<= n k)
        (iota (+ n 1))
        (cons* 0 n (map (lambda (i) (random (+ n 1))) (iota k)))))

  (define (chunks doc s e)
    (let ([parts '()])
      (document:for-each-utf8-chunk doc s e
        (lambda (bv from to) (set! parts (cons (bytevector-copy (subbytes bv from to)) parts))))
      (apply bytevector-append (reverse parts))))

  (define (subbytes bv from to)
    (let ([r (make-bytevector (- to from))]) (bytevector-copy! bv from r 0 (- to from)) r))

  (define (children doc start s e)
    (let ([out '()])
      (document:for-each-child (document:token doc start) s e
        (lambda (child at)
          (set! out (cons (list at (if (document:node? child) (document:node-start child) child)) out))))
      (reverse out)))

  (define (model-children v start s e)
    (let ([end (- (node-end v start) 1)])
      (let loop ([i (+ start 1)] [out '()] [text '()] [text-at #f])
        (define (flush out)
          (if (null? text) out (cons (list text-at (list->string (reverse text))) out)))
        (cond
          [(>= i end) (reverse (flush out))]
          [(char? (vector-ref v i))
           (if (and (>= i s) (< i e))
               (loop (+ i 1) out (cons (vector-ref v i) text) (or text-at i))
               (loop (+ i 1) (flush out) '() #f))]
          [else
           (let ([j (node-end v i)])
             (loop j (if (and (< i e) (> j s)) (cons (list i i) (flush out)) (flush out)) '() #f))]))))

  (define (prefix-vector v f)
    (let* ([n (vector-length v)] [r (make-vector (+ n 1) 0)])
      (do ([i 0 (+ i 1)]) ((= i n) r)
        (vector-set! r (+ i 1) (+ (vector-ref r i) (f (vector-ref v i)))))))

  (define (first-index r x)
    (let loop ([q 0]) (if (= (vector-ref r q) x) q (loop (+ q 1)))))

  (define (check-document! what doc v sample)
    (let* ([n (vector-length v)]
           [offsets (cons (cons 'in-line-atoms (in-line-offsets v))
                          (map (lambda (unit) (cons unit (prefix-vector v (lambda (t) (units t unit)))))
                               '(characters bytes utf-16 atoms)))]
           [newlines (prefix-vector v (lambda (t) (if (eqv? t #\newline) 1 0)))])
      (check! (list what 'length) n (document:length doc))
      (check! (list what 'datums) (tokens->datums (vector->list v)) (document:datums doc))
      (check! (list what 'text) (text-of (vector->list v)) (document:text doc))
      (check! (list what 'utf8) (utf8-of (vector->list v)) (chunks doc 0 n))
      (for-each
        (lambda (p)
          (check! (list what 'token p) (model-token v p) (token-of doc p))
          (check! (list what 'line p) (+ 1 (vector-ref newlines p)) (document:line doc p))
          (check! (list what 'enclosing p) (enclosing v p)
                  (let ([e (document:enclosing doc p)]) (and e (document:node-start e))))
          (for-each
            (lambda (unit+offsets)
              (let* ([unit (car unit+offsets)] [r (cdr unit+offsets)] [off (vector-ref r p)])
                (check! (list what 'offset unit p) off (document:offset doc p unit))
                (check! (list what 'position unit off) (first-index r off) (document:position doc off unit))))
            offsets)
          (let ([q (random (+ n 1))])
            (let ([s (min p q)] [e (max p q)])
              (check! (list what 'text s e) (text-of (sub v s e)) (document:text doc s e))
              (check! (list what 'chunks s e) (utf8-of (sub v s e)) (chunks doc s e))
              (let ([slice (document:slice doc s e)] [tokens (sub v s e)])
                (let ([low (let loop ([ts tokens] [d 0] [low 0])
                             (if (null? ts) low
                                 (let ([d (cond [(opening? (car ts)) (+ d 1)] [(closing? (car ts)) (- d 1)] [else d])])
                                   (loop (cdr ts) d (min low d)))))]
                      [net (depth-at (list->vector tokens) (length tokens))])
                  (check! (list what 'slice-open s e) (list (- low) (- net low))
                          (list (document:open-start slice) (document:open-end slice)))
                  (check! (list what 'slice-datums s e)
                          (tokens->datums
                            (append (let loop ([p s] [k (- low)] [acc '()])
                                      (if (= k 0) acc
                                          (let ([a (enclosing v p)]) (loop a (- k 1) (cons (vector-ref v a) acc)))))
                                    tokens))
                          (document:datums slice))))
              (when (and (< p n) (pair? (vector-ref v p)))
                (check! (list what 'node-end p) (node-end v p) (document:node-end (document:token doc p)))
                (check! (list what 'in-line p) (in-line? v p (node-end v p)) (document:in-line? (document:token doc p)))
                (check! (list what 'children p s e) (model-children v p s e) (children doc p s e))))))
        (sample-positions n sample))
      (let ([lines (+ 1 (vector-ref newlines n))])
        (for-each
          (lambda (line) (check! (list what 'line-start line) (first-index newlines (- line 1)) (document:line-start doc line)))
          (if (<= lines 50) (map (lambda (i) (+ i 1)) (iota lines)) (cons* 1 lines (map (lambda (i) (+ 1 (random lines))) (iota 50))))))))

  ;; A balanced range: from s, to a gap of the same depth with no lower gap
  ;; between, so replacing it with balanced content keeps the document
  ;; balanced.
  (define (balanced-end v s)
    (let ([d (depth-at v s)])
      (let loop ([i s] [depth d] [ends (list s)])
        (if (= i (vector-length v))
            (list-ref ends (random (length ends)))
            (let* ([t (vector-ref v i)]
                   [depth (cond [(opening? t) (+ depth 1)] [(closing? t) (- depth 1)] [else depth])])
              (cond
                [(< depth d) (list-ref ends (random (length ends)))]
                [(and (= depth d) (< (length ends) 40)) (loop (+ i 1) depth (cons (+ i 1) ends))]
                [(= depth d) (list-ref ends (random (length ends)))]
                [else (loop (+ i 1) depth ends)]))))))

  (define (vector-replace v s e new)
    (list->vector (append (sub v 0 s) (vector->list new) (sub v e (vector-length v)))))

  (define (edit-checks seed rounds edits sample)
    (random-seed seed)
    (set! failures 0)
    (set! checks 0)
    (do ([round 0 (+ round 1)]) ((= round rounds))
      (let ([datums (random-datums (if (even? round) (+ 1 (random 4)) (+ 100 (random 400))))])
        (let loop ([k 0] [doc (apply document:from-datum datums)] [v (apply model datums)])
          (check-document! (list 'round round 'edit k) doc v sample)
          (when (< k edits)
            (let* ([n (vector-length v)]
                   [s (random (+ n 1))]
                   [e (balanced-end v s)]
                   [new-datums (if (= (random 3) 0)
                                   (list (random-string (random 3)))
                                   (random-datums (random 3)))]
                   [content (apply document:from-datum new-datums)])
              (loop (+ k 1) (document:replace doc s e content)
                    (vector-replace v s e (apply model new-datums))))))))
    (list checks failures))

  ;; Typing at one place grows a run past its limit, so it splits, and
  ;; deleting shrinks runs until they go.
  (define (typing-checks seed steps sample)
    (random-seed seed)
    (set! failures 0)
    (set! checks 0)
    (let ([datums (random-datums 40)])
      (let loop ([k 0] [doc (apply document:from-datum datums)] [v (apply model datums)] [p 0])
        (when (= (mod k 1000) 0)
          (check-document! (list 'typing k) doc v sample))
        (when (< k steps)
          (let ([n (vector-length v)] [r (random 10)])
            (cond
              [(< r 8)
               (let ([s (string (random-char))])
                 (loop (+ k 1) (document:replace doc p p (document:from-datum s))
                       (vector-replace v p p (model s)) (+ p 1)))]
              [(and (= r 8) (> p 0) (or (char? (vector-ref v (- p 1))) (atom-token? (vector-ref v (- p 1)))))
               (loop (+ k 1) (document:replace doc (- p 1) p (document:from-datum))
                     (vector-replace v (- p 1) p (vector)) (- p 1))]
              [else (loop (+ k 1) doc v (random (+ n 1)))])))))
    (list checks failures)))
