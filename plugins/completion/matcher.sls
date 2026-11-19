(library (completion matcher)
  (export pattern? pattern-matcher partial-pattern make-store store? store-add! store-clear! store-sort! store-matches pattern-spans serve)
  (import (chezscheme))

  (define (term? t)
    (and (pair? t) (list? t)
         (case (car t)
           [(contains starts) (and (pair? (cdr t)) (for-all non-empty-string? (cdr t)))]
           [(ends) (and (pair? (cdr t)) (null? (cddr t)) (non-empty-string? (cadr t)))]
           [(not) (and (pair? (cdr t)) (null? (cddr t)) (term? (cadr t)))]
           [(face) (and (pair? (cdr t)) (symbol? (cadr t)) (pair? (cddr t)) (null? (cdddr t)) (term? (caddr t)))]
           [else #f])))

  (define (non-empty-string? s) (and (string? s) (fx> (string-length s) 0)))

  (define (pattern? v) (and (list? v) (for-all term? v)))

  (define (fold s)
    (let ([n (string-length s)])
      (let scan ([i 0])
        (cond
          [(fx= i n) s]
          [(char=? (char-downcase (string-ref s i)) (string-ref s i)) (scan (fx+ i 1))]
          [else
           (let ([f (make-string n)])
             (do ([j 0 (fx+ j 1)]) ((fx= j n) f)
               (string-set! f j (char-downcase (string-ref s j)))))]))))

  ;; Texts are folded as they are read rather than kept folded, which
  ;; would hold a second copy of every text with a capital letter.
  (define-syntax char-at
    (syntax-rules ()
      [(_ hay i fold?)
       (let ([c (string-ref hay i)])
         (cond
           [(not fold?) c]
           [(char<=? #\A c #\Z) (integer->char (fx+ (char->integer c) 32))]
           [(char<? c #\x80) c]
           [else (char-downcase c)]))]))

  (define (capital? s)
    (let ([n (string-length s)])
      (let loop ([i 0])
        (and (fx< i n)
             (or (not (char=? (char-downcase (string-ref s i)) (string-ref s i)))
                 (loop (fx+ i 1)))))))

  (define (compile-term t)
    (let walk ([t t] [face #f])
      (case (car t)
        [(not) (vector 'not #f (walk (cadr t) #f) #f)]
        [(face) (walk (caddr t) (cadr t))]
        [else
         (let ([fold? (not (exists capital? (cdr t)))])
           (vector (car t) fold? (if fold? (map fold (cdr t)) (cdr t)) face))])))

  (define (compile-pattern pattern) (map compile-term pattern))

  (define (multi-piece? terms)
    (exists (lambda (t) (and (memq (vector-ref t 0) '(contains starts)) (pair? (cdr (vector-ref t 2))))) terms))

  ;; The first piece's first character is sought at every place, so
  ;; there a text's character is folded only when it could match.
  (define (find-piece hay fold? piece start)
    (let* ([hn (string-length hay)] [nn (string-length piece)] [c0 (string-ref piece 0)] [last (fx- hn nn)]
           [capital (if (and fold? (char<=? #\a c0 #\z)) (integer->char (fx- (char->integer c0) 32)) c0)])
      (let outer ([i start])
        (and (fx<= i last)
             (if (let ([c (string-ref hay i)])
                   (or (char=? c c0) (char=? c capital)
                       (and fold? (char>? c #\x7f) (char=? (char-downcase c) c0))))
                 (let inner ([j 1])
                   (cond
                     [(fx= j nn) i]
                     [(char=? (char-at hay (fx+ i j) fold?) (string-ref piece j)) (inner (fx+ j 1))]
                     [else (outer (fx+ i 1))]))
                 (outer (fx+ i 1)))))))

  (define (starts-at? hay fold? piece at)
    (let ([nn (string-length piece)])
      (and (fx<= (fx+ at nn) (string-length hay))
           (let loop ([j 0])
             (or (fx= j nn)
                 (and (char=? (char-at hay (fx+ at j) fold?) (string-ref piece j)) (loop (fx+ j 1))))))))

  (define (pieces-gaps hay fold? pieces anchored? found)
    (let loop ([ps pieces] [from 0] [first? #t] [gaps 0])
      (if (null? ps)
          gaps
          (let ([at (if (and first? anchored?)
                        (and (starts-at? hay fold? (car ps) 0) 0)
                        (find-piece hay fold? (car ps) from))])
            (and at
                 (begin
                   (when found (found at (string-length (car ps))))
                   (loop (cdr ps) (fx+ at (string-length (car ps))) #f (if first? gaps (fx+ gaps (fx- at from))))))))))

  (define (term-gaps t text)
    (let ([fold? (vector-ref t 1)])
      (case (vector-ref t 0)
        [(not) (and (not (term-gaps (vector-ref t 2) text)) 0)]
        [(ends)
         (let ([piece (car (vector-ref t 2))])
           (and (fx>= (string-length text) (string-length piece))
                (starts-at? text fold? piece (fx- (string-length text) (string-length piece)))
                0))]
        [else (pieces-gaps text fold? (vector-ref t 2) (eq? (vector-ref t 0) 'starts) #f)])))

  (define (gaps-of terms text)
    (let loop ([ts terms] [total 0])
      (if (null? ts)
          total
          (let ([g (term-gaps (car ts) text)])
            (and g (loop (cdr ts) (fx+ total g)))))))

  (define (partial-pattern query)
    (let loop ([cs (string->list query)] [word '()] [words '()])
      (define (finish) (if (null? word) words (cons (list->string (reverse word)) words)))
      (cond
        [(null? cs)
         (let ([words (reverse (finish))])
           (if (null? words) '() (list (cons 'starts words))))]
        [(char=? (car cs) #\*) (loop (cdr cs) '() (finish))]
        [(memv (car cs) '(#\- #\_ #\. #\/ #\: #\| #\space)) (loop (cdr cs) (list (car cs)) (finish))]
        [else (loop (cdr cs) (cons (car cs) word) words)])))

  (define (pattern-matcher pattern)
    (let ([terms (compile-pattern pattern)])
      (lambda (text) (and (gaps-of terms text) #t))))

  (define (pattern-spans pattern text)
    (join-spans
      (fold-left
        (lambda (spans t)
          (let ([fold? (vector-ref t 1)] [face (vector-ref t 3)])
            (case (vector-ref t 0)
              [(not) spans]
              [(ends)
               (let* ([piece (car (vector-ref t 2))] [at (fx- (string-length text) (string-length piece))])
                 (if (and (fx>= at 0) (starts-at? text fold? piece at))
                     (paint spans at (string-length text) face)
                     spans))]
              [else
               (let ([found '()])
                 (if (pieces-gaps text fold? (vector-ref t 2) (eq? (vector-ref t 0) 'starts)
                       (lambda (at len) (set! found (cons (cons at (fx+ at len)) found))))
                     (fold-left (lambda (spans f) (paint spans (car f) (cdr f) face)) spans found)
                     spans))])))
        '()
        (compile-pattern pattern))))

  (define (paint spans start end face)
    (list-sort (lambda (a b) (fx< (car a) (car b)))
      (cons (list start end face)
            (fold-right
              (lambda (s acc)
                (let ([a (car s)] [b (cadr s)] [f (caddr s)])
                  (append (if (fx< a start) (list (list a (fxmin b start) f)) '())
                          (if (fx> b end) (list (list (fxmax a end) b f)) '())
                          acc)))
              '()
              spans))))

  (define (join-spans spans)
    (cond
      [(or (null? spans) (null? (cdr spans))) spans]
      [(and (fx= (cadr (car spans)) (car (cadr spans))) (eq? (caddr (car spans)) (caddr (cadr spans))))
       (join-spans (cons (list (car (car spans)) (cadr (cadr spans)) (caddr (car spans))) (cddr spans)))]
      [else (cons (car spans) (join-spans (cdr spans)))]))

  ;; Candidates may come a few at a time, thousands of times, so those
  ;; added to a sorted store wait at the end of order, past merged, and
  ;; are sorted into it once, by the next match. A cleared store numbers
  ;; its candidates on from those it dropped, so a number names one
  ;; candidate for the store's life.
  (define-record-type (store %make-store store?)
    (sealed #t)
    (fields (mutable base) (mutable texts) (mutable ranks) (mutable count)
            (mutable order) (mutable merged) (mutable sorted?)))

  (define (make-empty) (%make-store 0 (vector) (vector) 0 (vector) 0 #f))

  (define (grow v n fill)
    (if (fx>= (vector-length v) n)
        v
        (let ([w (make-vector (fxmax n (fx* 2 (vector-length v))) fill)])
          (do ([i 0 (fx+ i 1)]) ((fx= i (vector-length v)) w)
            (vector-set! w i (vector-ref v i))))))

  (define (before? s)
    (let ([texts (store-texts s)] [ranks (store-ranks s)])
      (lambda (a b)
        (let ([ra (vector-ref ranks a)] [rb (vector-ref ranks b)])
          (or (fx< ra rb)
              (and (fx= ra rb)
                   (let ([ta (vector-ref texts a)] [tb (vector-ref texts b)])
                     (or (fx< (string-length ta) (string-length tb))
                         (and (fx= (string-length ta) (string-length tb)) (string<? ta tb))))))))))

  (define (store-add! s texts ranks)
    (let* ([n (store-count s)] [k (vector-length texts)] [m (fx+ n k)])
      (store-texts-set! s (grow (store-texts s) m ""))
      (store-ranks-set! s (grow (store-ranks s) m 0))
      (vector-copy! texts 0 (store-texts s) n k)
      (if ranks
          (vector-copy! ranks 0 (store-ranks s) n k)
          (do ([i n (fx+ i 1)]) ((fx= i m)) (vector-set! (store-ranks s) i 0)))
      (store-order-set! s (grow (store-order s) m 0))
      (do ([i n (fx+ i 1)]) ((fx= i m)) (vector-set! (store-order s) i i))
      (store-count-set! s m)))

  (define (store-clear! s)
    (store-base-set! s (fx+ (store-base s) (store-count s)))
    (store-texts-set! s (vector))
    (store-ranks-set! s (vector))
    (store-order-set! s (vector))
    (store-count-set! s 0)
    (store-merged-set! s 0)
    (store-sorted?-set! s #f))

  (define (merge-added! s)
    (let ([n (store-count s)] [m (store-merged s)])
      (when (and (store-sorted? s) (fx< m n))
        (let ([order (store-order s)] [less? (before? s)])
          (store-order-set! s (vector-merge less? (vector-copy order 0 m) (vector-sort less? (vector-copy order m (fx- n m)))))
          (store-merged-set! s n)))))

  (define (vector-merge less? a b)
    (let* ([na (vector-length a)] [nb (vector-length b)] [v (make-vector (fx+ na nb))])
      (let loop ([i 0] [j 0] [k 0])
        (cond
          [(and (fx< i na) (or (fx= j nb) (not (less? (vector-ref b j) (vector-ref a i)))))
           (vector-set! v k (vector-ref a i)) (loop (fx+ i 1) j (fx+ k 1))]
          [(fx< j nb) (vector-set! v k (vector-ref b j)) (loop i (fx+ j 1) (fx+ k 1))]
          [else v]))))

  (define (store-sort! s)
    (unless (store-sorted? s)
      (store-order-set! s (vector-sort (before? s) (vector-copy (store-order s) 0 (store-count s))))
      (store-merged-set! s (store-count s))
      (store-sorted?-set! s #t)))

  ;; A scan may find every one of millions of candidates, so it keeps
  ;; what it finds in vectors, a word for each, not in lists. Candidates
  ;; in arrival order are in order of number, so a scan from a number
  ;; starts there.
  (define (scan s pattern from stop first)
    (merge-added! s)
    (let* ([terms (compile-pattern pattern)] [gaps? (and (store-sorted? s) (multi-piece? terms))]
           [order (store-order s)] [n (store-count s)] [texts (store-texts s)] [base (store-base s)]
           [lowest (fx- from base)])
      (define (numbers found count)
        (let ([v (make-vector count)])
          (do ([j 0 (fx+ j 1)]) ((fx= j count) v)
            (vector-set! v j (fx+ base (vector-ref found j))))))
      (let loop ([k (if (store-sorted? s) 0 (fxmax 0 lowest))] [found (make-vector 64)]
                 [gaps (if gaps? (make-vector 64) (vector))] [count 0])
        (cond
          [(fx= k n)
           (if gaps?
               (let ([ranks (store-ranks s)] [v (make-vector count)])
                 (do ([j 0 (fx+ j 1)]) ((fx= j count)) (vector-set! v j j))
                 (vector-sort!
                   (lambda (a b)
                     (let ([ra (vector-ref ranks (vector-ref found a))] [rb (vector-ref ranks (vector-ref found b))])
                       (or (fx< ra rb)
                           (and (fx= ra rb)
                                (let ([ga (vector-ref gaps a)] [gb (vector-ref gaps b)])
                                  (or (fx< ga gb) (and (fx= ga gb) (fx< a b))))))))
                   v)
                 (do ([j 0 (fx+ j 1)]) ((fx= j count) v)
                   (vector-set! v j (fx+ base (vector-ref found (vector-ref v j))))))
               (numbers found count))]
          [(and stop (fx= (fxand k 4095) 4095) (stop k)) #f]
          [else
           (let* ([i (vector-ref order k)] [g (and (fx>= i lowest) (gaps-of terms (vector-ref texts i)))])
             (if g
                 (let ([found (grow found (fx+ count 1) 0)] [gaps (if gaps? (grow gaps (fx+ count 1) 0) gaps)])
                   (vector-set! found count i)
                   (when gaps? (vector-set! gaps count g))
                   (when (and first (not gaps?) (fx= count 49))
                     (first (numbers found 50)))
                   (loop (fx+ k 1) found gaps (fx+ count 1)))
                 (loop (fx+ k 1) found gaps count)))]))))

  (define store-matches
    (case-lambda
      [(s pattern) (scan s pattern 0 #f #f)]
      [(s pattern from) (scan s pattern from #f #f)]))

  (define (serve emit receive)
    (let ([s (make-empty)] [queue '()])
      (define (take!)
        (if (pair? queue)
            (let ([m (car queue)]) (set! queue (cdr queue)) m)
            (receive)))
      (define (drain!)
        (let loop ()
          (let ([m (receive 0)])
            (unless (eof-object? m)
              (set! queue (append queue (list m)))
              (loop)))))
      (define (newer-match?) (exists (lambda (m) (and (pair? m) (eq? (car m) 'match))) queue))
      (define (handle! m)
        (when (pair? m)
          (case (car m)
            [(add) (store-add! s (cadr m) (caddr m))]
            [(clear) (store-clear! s)]
            [(sort) (store-sort! s)])))
      (let loop ()
        (let ([m (take!)])
          (unless (eof-object? m)
            (if (and (pair? m) (eq? (car m) 'match))
                (begin
                  (drain!)
                  (if (newer-match?)
                      (void)
                      (let* ([id (cadr m)] [pattern (caddr m)] [from (cadddr m)]
                             [all (scan s pattern from
                                    (lambda (k) (drain!) (newer-match?))
                                    (lambda (part) (emit (cons* id #f part))))])
                        (when all (emit (cons* id #t all))))))
                (handle! m))
            (loop))))))

  (define make-store
    (case-lambda
      [() (make-empty)]
      [(texts ranks)
       (let ([s (make-empty)])
         (store-add! s texts ranks)
         (store-sort! s)
         s)])))
