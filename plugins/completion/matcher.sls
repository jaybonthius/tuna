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

  ;; Texts are UTF-8 bytevectors, since a broad search holds millions of
  ;; them and a string takes four bytes a character. They are folded as
  ;; they are read rather than kept folded, which would hold a second copy
  ;; of every text with a capital letter.
  (define (char-at hay i)
    (let ([b (bytevector-u8-ref hay i)])
      (cond
        [(fx< b #x80) (values (integer->char b) (fx+ i 1))]
        [(fx< b #xE0)
         (values (integer->char (fxior (fxsll (fxand b #x1F) 6) (fxand (bytevector-u8-ref hay (fx+ i 1)) #x3F)))
                 (fx+ i 2))]
        [(fx< b #xF0)
         (values (integer->char (fxior (fxsll (fxand b #x0F) 12)
                                       (fxsll (fxand (bytevector-u8-ref hay (fx+ i 1)) #x3F) 6)
                                       (fxand (bytevector-u8-ref hay (fx+ i 2)) #x3F)))
                 (fx+ i 3))]
        [else
         (values (integer->char (fxior (fxsll (fxand b #x07) 18)
                                       (fxsll (fxand (bytevector-u8-ref hay (fx+ i 1)) #x3F) 12)
                                       (fxsll (fxand (bytevector-u8-ref hay (fx+ i 2)) #x3F) 6)
                                       (fxand (bytevector-u8-ref hay (fx+ i 3)) #x3F)))
                 (fx+ i 4))])))

  (define (fold-char c)
    (cond
      [(char<=? #\A c #\Z) (integer->char (fx+ (char->integer c) 32))]
      [(char<? c #\x80) c]
      [else (char-downcase c)]))

  (define (continuation? b) (fx= (fxand b #xC0) #x80))

  (define (char-count hay from to)
    (let loop ([i from] [n 0])
      (if (fx= i to) n (loop (fx+ i 1) (if (continuation? (bytevector-u8-ref hay i)) n (fx+ n 1))))))

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

  (define (piece-end hay fold? piece i)
    (let ([n (bytevector-length hay)] [k (string-length piece)])
      (let loop ([j 0] [i i])
        (cond
          [(fx= j k) i]
          [(fx= i n) #f]
          [else
           (let-values ([(c next) (char-at hay i)])
             (and (char=? (if fold? (fold-char c) c) (string-ref piece j))
                  (loop (fx+ j 1) next)))]))))

  ;; The first piece's first character is sought at every byte, so there
  ;; a text's character is decoded only when it could match.
  (define (find-piece hay fold? piece start)
    (let* ([n (bytevector-length hay)] [c0 (string-ref piece 0)] [b0 (char->integer c0)] [ascii? (fx< b0 #x80)]
           [capital (if (and fold? (char<=? #\a c0 #\z)) (fx- b0 32) b0)])
      (let outer ([i start])
        (if (fx>= i n)
            (values #f #f)
            (let* ([b (bytevector-u8-ref hay i)]
                   [end (and (or (and ascii? (or (fx= b b0) (fx= b capital)))
                                 (and (fx>= b #xC0) (or fold? (not ascii?))))
                             (piece-end hay fold? piece i))])
              (if end (values i end) (outer (fx+ i 1))))))))

  (define (ends-at hay fold? piece)
    (let loop ([j (fx- (string-length piece) 1)] [i (bytevector-length hay)])
      (cond
        [(fx< j 0) i]
        [(fx= i 0) #f]
        [else
         (let back ([i (fx- i 1)])
           (if (and (fx> i 0) (continuation? (bytevector-u8-ref hay i)))
               (back (fx- i 1))
               (let-values ([(c next) (char-at hay i)])
                 (and (char=? (if fold? (fold-char c) c) (string-ref piece j))
                      (loop (fx- j 1) i)))))])))

  (define (pieces-gaps hay fold? pieces anchored? found)
    (let loop ([ps pieces] [from 0] [first? #t] [gaps 0])
      (if (null? ps)
          gaps
          (let-values ([(at end) (if (and first? anchored?)
                                     (let ([end (piece-end hay fold? (car ps) 0)]) (values (and end 0) end))
                                     (find-piece hay fold? (car ps) from))])
            (and at
                 (begin
                   (when found (found at end))
                   (loop (cdr ps) end #f (if first? gaps (fx+ gaps (char-count hay from at))))))))))

  (define (term-gaps t text)
    (let ([fold? (vector-ref t 1)])
      (case (vector-ref t 0)
        [(not) (and (not (term-gaps (vector-ref t 2) text)) 0)]
        [(ends) (and (ends-at text fold? (car (vector-ref t 2))) 0)]
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
      (lambda (text) (and (gaps-of terms (string->utf8 text)) #t))))

  (define (pattern-spans pattern text)
    (let ([hay (string->utf8 text)])
      (define (add spans at end face) (paint spans (char-count hay 0 at) (char-count hay 0 end) face))
      (join-spans
        (fold-left
          (lambda (spans t)
            (let ([fold? (vector-ref t 1)] [face (vector-ref t 3)])
              (case (vector-ref t 0)
                [(not) spans]
                [(ends)
                 (let ([at (ends-at hay fold? (car (vector-ref t 2)))])
                   (if at (add spans at (bytevector-length hay) face) spans))]
                [else
                 (let ([found '()])
                   (if (pieces-gaps hay fold? (vector-ref t 2) (eq? (vector-ref t 0) 'starts)
                         (lambda (at end) (set! found (cons (cons at end) found))))
                       (fold-left (lambda (spans f) (add spans (car f) (cdr f) face)) spans found)
                       spans))])))
          '()
          (compile-pattern pattern)))))

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
  ;;
  ;; Order counts a text's length in characters, as Emacs does. Each
  ;; length is counted once, as its text is added, since counting at each
  ;; comparison would read millions of texts again at every sort; lengths
  ;; sit in a bytevector, which the collector does not scan.
  (define-record-type (store %make-store store?)
    (sealed #t)
    (fields (mutable base) (mutable texts) (mutable ranks) (mutable lengths) (mutable count)
            (mutable order) (mutable merged) (mutable sorted?)))

  (define (make-empty) (%make-store 0 (vector) (vector) #vu8() 0 (vector) 0 #f))

  (define (length-ref lengths i) (bytevector-u32-native-ref lengths (fx* 4 i)))

  (define (grow v n fill)
    (if (fx>= (vector-length v) n)
        v
        (let ([w (make-vector (fxmax n (fx* 2 (vector-length v))) fill)])
          (do ([i 0 (fx+ i 1)]) ((fx= i (vector-length v)) w)
            (vector-set! w i (vector-ref v i))))))

  (define (grow-lengths v n)
    (let ([k (fxquotient (bytevector-length v) 4)])
      (if (fx>= k n)
          v
          (let ([w (make-bytevector (fx* 4 (fxmax n (fx* 2 k))))])
            (bytevector-copy! v 0 w 0 (bytevector-length v))
            w))))

  ;; UTF-8's byte order is the order of code points, so texts of one
  ;; length compare as string<? would.
  (define (before? s)
    (let ([texts (store-texts s)] [ranks (store-ranks s)] [lengths (store-lengths s)])
      (lambda (a b)
        (let ([ra (vector-ref ranks a)] [rb (vector-ref ranks b)])
          (or (fx< ra rb)
              (and (fx= ra rb)
                   (let ([la (length-ref lengths a)] [lb (length-ref lengths b)])
                     (or (fx< la lb)
                         (and (fx= la lb)
                              (let* ([ta (vector-ref texts a)] [tb (vector-ref texts b)]
                                     [n (fxmin (bytevector-length ta) (bytevector-length tb))])
                                (let loop ([i 0])
                                  (and (fx< i n)
                                       (let ([x (bytevector-u8-ref ta i)] [y (bytevector-u8-ref tb i)])
                                         (or (fx< x y) (and (fx= x y) (loop (fx+ i 1)))))))))))))))))

  (define (store-add! s texts ranks)
    (let* ([n (store-count s)] [k (vector-length texts)] [m (fx+ n k)])
      (store-texts-set! s (grow (store-texts s) m #vu8()))
      (store-ranks-set! s (grow (store-ranks s) m 0))
      (store-lengths-set! s (grow-lengths (store-lengths s) m))
      (vector-copy! texts 0 (store-texts s) n k)
      (if ranks
          (vector-copy! ranks 0 (store-ranks s) n k)
          (do ([i n (fx+ i 1)]) ((fx= i m)) (vector-set! (store-ranks s) i 0)))
      (let ([lengths (store-lengths s)])
        (do ([i 0 (fx+ i 1)]) ((fx= i k))
          (let ([text (vector-ref texts i)])
            (bytevector-u32-native-set! lengths (fx* 4 (fx+ n i)) (char-count text 0 (bytevector-length text))))))
      (store-order-set! s (grow (store-order s) m 0))
      (do ([i n (fx+ i 1)]) ((fx= i m)) (vector-set! (store-order s) i i))
      (store-count-set! s m)))

  (define (store-clear! s)
    (store-base-set! s (fx+ (store-base s) (store-count s)))
    (store-texts-set! s (vector))
    (store-ranks-set! s (vector))
    (store-lengths-set! s #vu8())
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

  (define (store-find s text)
    (let ([texts (store-texts s)] [n (store-count s)])
      (let loop ([i 0])
        (and (fx< i n)
             (if (bytevector=? (vector-ref texts i) text)
                 (fx+ (store-base s) i)
                 (loop (fx+ i 1)))))))

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
            [(sort) (store-sort! s)]
            [(find) (emit (list 'found (cadr m) (store-find s (caddr m))))])))
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
