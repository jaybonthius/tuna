(library (completion matcher)
  (export pattern? pattern-matcher partial-pattern make-store store? store-add! store-retire! store-sort! store-matches pattern-spans serve)
  (import (chezscheme))

  (define (term? t)
    (and (pair? t) (list? t)
         (case (car t)
           [(contains starts) (and (pair? (cdr t)) (for-all non-empty-string? (cdr t)))]
           [(ends) (and (pair? (cdr t)) (null? (cddr t)) (non-empty-string? (cadr t)))]
           [(not) (and (pair? (cdr t)) (null? (cddr t)) (term? (cadr t)))]
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

  (define (capital? s)
    (let ([n (string-length s)])
      (let loop ([i 0])
        (and (fx< i n)
             (or (not (char=? (char-downcase (string-ref s i)) (string-ref s i)))
                 (loop (fx+ i 1)))))))

  (define (compile-term t)
    (if (eq? (car t) 'not)
        (vector 'not #f (compile-term (cadr t)))
        (let ([fold? (not (exists capital? (cdr t)))])
          (vector (car t) fold? (if fold? (map fold (cdr t)) (cdr t))))))

  (define (compile-pattern pattern) (map compile-term pattern))

  (define (multi-piece? terms)
    (exists (lambda (t) (and (memq (vector-ref t 0) '(contains starts)) (pair? (cdr (vector-ref t 2))))) terms))

  (define (find-piece hay piece start)
    (let* ([hn (string-length hay)] [nn (string-length piece)] [c0 (string-ref piece 0)] [last (fx- hn nn)])
      (let outer ([i start])
        (and (fx<= i last)
             (if (char=? (string-ref hay i) c0)
                 (let inner ([j 1])
                   (cond
                     [(fx= j nn) i]
                     [(char=? (string-ref hay (fx+ i j)) (string-ref piece j)) (inner (fx+ j 1))]
                     [else (outer (fx+ i 1))]))
                 (outer (fx+ i 1)))))))

  (define (starts-at? hay piece at)
    (let ([nn (string-length piece)])
      (and (fx<= (fx+ at nn) (string-length hay))
           (let loop ([j 0])
             (or (fx= j nn)
                 (and (char=? (string-ref hay (fx+ at j)) (string-ref piece j)) (loop (fx+ j 1))))))))

  (define (pieces-at hay pieces anchored? found)
    (let loop ([ps pieces] [from 0] [first? #t])
      (or (null? ps)
          (let ([at (if (and first? anchored?)
                        (and (starts-at? hay (car ps) 0) 0)
                        (find-piece hay (car ps) from))])
            (and at
                 (begin
                   (found at (string-length (car ps)))
                   (loop (cdr ps) (fx+ at (string-length (car ps))) #f)))))))

  (define (term-gaps t text folded)
    (let ([hay (if (vector-ref t 1) folded text)])
      (case (vector-ref t 0)
        [(not) (and (not (term-gaps (vector-ref t 2) text folded)) 0)]
        [(ends)
         (let ([piece (car (vector-ref t 2))])
           (and (fx>= (string-length hay) (string-length piece))
                (starts-at? hay piece (fx- (string-length hay) (string-length piece)))
                0))]
        [else
         (let ([gaps 0] [end #f])
           (and (pieces-at hay (vector-ref t 2) (eq? (vector-ref t 0) 'starts)
                  (lambda (at len)
                    (when end (set! gaps (fx+ gaps (fx- at end))))
                    (set! end (fx+ at len))))
                gaps))])))

  (define (gaps-of terms text folded)
    (let loop ([ts terms] [total 0])
      (if (null? ts)
          total
          (let ([g (term-gaps (car ts) text folded)])
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
      (lambda (text) (and (gaps-of terms text (fold text)) #t))))

  (define (pattern-spans pattern text)
    (let ([folded (fold text)] [spans '()])
      (for-each
        (lambda (t)
          (let ([hay (if (vector-ref t 1) folded text)])
            (case (vector-ref t 0)
              [(not) (void)]
              [(ends)
               (let* ([piece (car (vector-ref t 2))] [at (fx- (string-length hay) (string-length piece))])
                 (when (and (fx>= at 0) (starts-at? hay piece at))
                   (set! spans (cons (cons at (string-length hay)) spans))))]
              [else
               (let ([found '()])
                 (when (pieces-at hay (vector-ref t 2) (eq? (vector-ref t 0) 'starts)
                         (lambda (at len) (set! found (cons (cons at (fx+ at len)) found))))
                   (set! spans (append found spans))))])))
        (compile-pattern pattern))
      (merge-spans (list-sort (lambda (a b) (fx< (car a) (car b))) spans))))

  (define (merge-spans spans)
    (cond
      [(or (null? spans) (null? (cdr spans))) spans]
      [(fx<= (car (cadr spans)) (cdar spans))
       (merge-spans (cons (cons (caar spans) (fxmax (cdar spans) (cdr (cadr spans)))) (cddr spans)))]
      [else (cons (car spans) (merge-spans (cdr spans)))]))

  ;; Candidates may come a few at a time, thousands of times, so those
  ;; added to a sorted store wait at the end of order, past merged, and
  ;; are sorted into it once, by the next match.
  (define-record-type (store %make-store store?)
    (sealed #t)
    (fields (mutable texts) (mutable folded) (mutable ranks) (mutable live) (mutable count)
            (mutable order) (mutable merged) (mutable sorted?)))

  (define (make-empty) (%make-store (vector) (vector) (vector) (vector) 0 (vector) 0 #f))

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
      (store-folded-set! s (grow (store-folded s) m ""))
      (store-ranks-set! s (grow (store-ranks s) m 0))
      (store-live-set! s (grow (store-live s) m #t))
      (do ([i 0 (fx+ i 1)]) ((fx= i k))
        (let ([text (vector-ref texts i)])
          (vector-set! (store-texts s) (fx+ n i) text)
          (vector-set! (store-folded s) (fx+ n i) (fold text))
          (vector-set! (store-ranks s) (fx+ n i) (if ranks (vector-ref ranks i) 0))
          (vector-set! (store-live s) (fx+ n i) #t)))
      (store-order-set! s (grow (store-order s) m 0))
      (do ([i n (fx+ i 1)]) ((fx= i m)) (vector-set! (store-order s) i i))
      (store-count-set! s m)))

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

  (define (store-retire! s indices)
    (vector-for-each
      (lambda (i) (when (and (fixnum? i) (fx< -1 i (store-count s))) (vector-set! (store-live s) i #f)))
      indices))

  (define (store-sort! s)
    (unless (store-sorted? s)
      (store-order-set! s (vector-sort (before? s) (vector-copy (store-order s) 0 (store-count s))))
      (store-merged-set! s (store-count s))
      (store-sorted?-set! s #t)))

  (define (scan s pattern stop first)
    (merge-added! s)
    (let* ([terms (compile-pattern pattern)] [gaps? (and (store-sorted? s) (multi-piece? terms))]
           [order (store-order s)] [n (store-count s)]
           [texts (store-texts s)] [folded (store-folded s)] [live (store-live s)])
      (let loop ([k 0] [found '()] [count 0])
        (cond
          [(fx= k n)
           (let ([found (reverse found)])
             (list->vector
               (if gaps?
                   (map car (list-sort (lambda (a b)
                                         (let ([ra (vector-ref (store-ranks s) (car a))]
                                               [rb (vector-ref (store-ranks s) (car b))])
                                           (or (fx< ra rb) (and (fx= ra rb) (fx< (cdr a) (cdr b))))))
                                       found))
                   (map car found))))]
          [(and stop (fx= (fxand k 4095) 4095) (stop k)) #f]
          [else
           (let ([i (vector-ref order k)])
             (if (vector-ref live i)
                 (let ([g (gaps-of terms (vector-ref texts i) (vector-ref folded i))])
                   (if g
                       (begin
                         (when (and first (not gaps?) (fx= count 49))
                           (first (list->vector (reverse (map car (cons (cons i g) found))))))
                         (loop (fx+ k 1) (cons (cons i g) found) (fx+ count 1)))
                       (loop (fx+ k 1) found count)))
                 (loop (fx+ k 1) found count)))]))))

  (define (store-matches s pattern) (scan s pattern #f #f))

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
            [(retire) (store-retire! s (cadr m))]
            [(sort) (store-sort! s)])))
      (let loop ()
        (let ([m (take!)])
          (unless (eof-object? m)
            (if (and (pair? m) (eq? (car m) 'match))
                (begin
                  (drain!)
                  (if (newer-match?)
                      (void)
                      (let* ([id (cadr m)] [pattern (caddr m)]
                             [all (scan s pattern
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
