(library (buffers spans)
  (export make-spans spans-empty? spans-map! spans-split! spans-add! spans-take! spans-overlapping
          spans-touching spans-taking spans-all)
  (import (chezscheme))

  ;; An edit moves every span after it, so spans sit in chunks whose
  ;; positions count from a base, and the bases' moves are kept in a
  ;; Fenwick tree by chunk index: one addition moves all the chunks after
  ;; an edit. Chunks are sorted by their first start and no span is longer
  ;; than longest, so the chunks an edit or a query reaches are found by
  ;; binary search.
  (define chunk-size 64)

  (define-record-type chunk
    (sealed #t)
    (fields (mutable own) (mutable count) starts ends values (mutable last-end))
    (protocol
      (lambda (new)
        (lambda (own)
          (new own 0 (make-fxvector chunk-size 0) (make-fxvector chunk-size 0) (make-vector chunk-size #f) 0)))))

  (define-record-type (spans new-spans spans?)
    (sealed #t)
    (fields (mutable chunks) (mutable used) (mutable shifts) (mutable longest)))

  (define (make-spans) (new-spans (make-vector 4 #f) 0 (make-fxvector 5 0) 0))

  (define (spans-empty? store) (fx= (spans-used store) 0))

  (define (chunk-at store k) (vector-ref (spans-chunks store) k))

  (define (shift-of store k)
    (let ([t (spans-shifts store)])
      (let loop ([i (fx+ k 1)] [sum 0])
        (if (fx= i 0) sum (loop (fxand i (fx- i 1)) (fx+ sum (fxvector-ref t i)))))))

  (define (shift-from! store k delta)
    (let ([t (spans-shifts store)])
      (let loop ([i (fx+ k 1)])
        (when (fx< i (fxvector-length t))
          (fxvector-set! t i (fx+ (fxvector-ref t i) delta))
          (loop (fx+ i (fxand i (fx- i))))))))

  (define (base store k) (fx+ (chunk-own (chunk-at store k)) (shift-of store k)))

  ;; A chunk that moves to another index would take that index's shifts,
  ;; so the shifts are folded into the chunks' own bases first.
  (define (settle! store)
    (let ([n (spans-used store)])
      (do ([k 0 (fx+ k 1)]) ((fx= k n))
        (let ([c (chunk-at store k)])
          (chunk-own-set! c (fx+ (chunk-own c) (shift-of store k)))))
      (spans-shifts-set! store (make-fxvector (fx+ (vector-length (spans-chunks store)) 1) 0))))

  (define (first-of store k) (fx+ (base store k) (fxvector-ref (chunk-starts (chunk-at store k)) 0)))
  (define (last-start-of store k)
    (let ([c (chunk-at store k)])
      (fx+ (base store k) (fxvector-ref (chunk-starts c) (fx- (chunk-count c) 1)))))
  (define (limit-of store k) (fx+ (base store k) (chunk-last-end (chunk-at store k))))

  (define (lengthen! store a e)
    (when (fx> (fx- e a) (spans-longest store))
      (spans-longest-set! store (fx- e a))))

  (define (chunks-above store p)
    (let loop ([lo 0] [hi (spans-used store)])
      (if (fx< lo hi)
          (let ([mid (fxsrl (fx+ lo hi) 1)])
            (if (fx> (first-of store mid) p) (loop lo mid) (loop (fx+ mid 1) hi)))
          lo)))

  ;; The first chunk that may hold a span ending at p or after: a chunk
  ;; before the last to start below p − longest starts its spans there too.
  (define (chunks-reaching store p)
    (fxmax 0 (fx- (chunks-above store (fx- (fx- p (spans-longest store)) 1)) 1)))

  (define (for-each-reaching store lo hi visit)
    (let ([n (spans-used store)])
      (let loop ([k (chunks-reaching store lo)])
        (when (and (fx< k n) (fx<= (first-of store k) hi))
          (when (fx>= (limit-of store k) lo) (visit k))
          (loop (fx+ k 1))))))

  (define (spans-all store)
    (let ([acc '()])
      (do ([k 0 (fx+ k 1)]) ((fx= k (spans-used store)))
        (let ([c (chunk-at store k)] [b (base store k)])
          (do ([j 0 (fx+ j 1)]) ((fx= j (chunk-count c)))
            (set! acc (cons (list (fx+ b (fxvector-ref (chunk-starts c) j)) (fx+ b (fxvector-ref (chunk-ends c) j))
                              (vector-ref (chunk-values c) j))
                            acc)))))
      (reverse acc)))

  (define (by-start a b) (fx< (car a) (car b)))

  ;; Results come by start, then by end, so equal starts read the same way
  ;; whatever order the chunks hold them in.
  (define (by-position a b)
    (or (fx< (car a) (car b)) (and (fx= (car a) (car b)) (fx< (cadr a) (cadr b)))))

  (define (rebuild! store spans)
    (spans-chunks-set! store (make-vector 4 #f))
    (spans-used-set! store 0)
    (spans-shifts-set! store (make-fxvector 5 0))
    (spans-longest-set! store 0)
    (for-each (lambda (s) (spans-add! store (car s) (cadr s) (caddr s))) (list-sort by-start spans)))

  (define (refresh-limit! c)
    (let ([ends (chunk-ends c)] [n (chunk-count c)])
      (let loop ([j 0] [m (if (fx= n 0) 0 (fxvector-ref ends 0))])
        (if (fx= j n)
            (chunk-last-end-set! c m)
            (loop (fx+ j 1) (fxmax m (fxvector-ref ends j)))))))

  (define (truncate-chunk! c n)
    (do ([j n (fx+ j 1)]) ((fx= j (chunk-count c)))
      (vector-set! (chunk-values c) j #f))
    (chunk-count-set! c n))

  ;; A chunk whose spans an edit mapped can hold some out of order, where
  ;; several started at the edit.
  (define (sort-chunk! c)
    (let ([n (chunk-count c)] [starts (chunk-starts c)] [ends (chunk-ends c)] [items (chunk-values c)])
      (let ([spans (list-sort by-start
                     (let loop ([j (fx- n 1)] [acc '()])
                       (if (fx< j 0)
                           acc
                           (loop (fx- j 1) (cons (list (fxvector-ref starts j) (fxvector-ref ends j) (vector-ref items j)) acc)))))])
        (let loop ([j 0] [spans spans])
          (unless (null? spans)
            (let ([s (car spans)])
              (fxvector-set! starts j (car s))
              (fxvector-set! ends j (cadr s))
              (vector-set! items j (caddr s))
              (loop (fx+ j 1) (cdr spans))))))))

  (define (ordered-around? store k)
    (let ([n (spans-used store)])
      (define (ordered? k)
        (or (fx<= k 0) (fx>= k n) (fx<= (last-start-of store (fx- k 1)) (first-of store k))))
      (and (ordered? k) (ordered? (fx+ k 1)))))

  ;; Only the chunks a change reached can be empty or out of order with a
  ;; neighbour.
  (define (tidy! store changed)
    (unless (null? changed)
      (cond
        [(exists (lambda (k) (fx= (chunk-count (chunk-at store k)) 0)) changed)
         (settle! store)
         (let ([chunks (spans-chunks store)] [n (spans-used store)])
           (let loop ([k 0] [w 0])
             (cond
               [(fx< k n)
                (let ([c (vector-ref chunks k)])
                  (if (fx= (chunk-count c) 0)
                      (loop (fx+ k 1) w)
                      (begin (vector-set! chunks w c) (loop (fx+ k 1) (fx+ w 1)))))]
               [else
                (do ([j w (fx+ j 1)]) ((fx= j n)) (vector-set! chunks j #f))
                (spans-used-set! store w)])))
         (unless (let loop ([k 1]) (or (fx>= k (spans-used store)) (and (ordered-around? store k) (loop (fx+ k 1)))))
           (rebuild! store (spans-all store)))]
        [(not (for-all (lambda (k) (ordered-around? store k)) changed))
         (rebuild! store (spans-all store))])))

  (define (cut x s b)
    (cond [(fx<= x s) x] [(fx>= x b) (fx- x (fx- b s))] [else s]))

  ;; The rules Emacs applies to an overlay's markers: front? and rear? say
  ;; whether text inserted at the start or the end goes inside. An empty
  ;; span that does not take text at its end keeps its start.
  (define (insert-start a e s i front? rear?)
    (cond
      [(fx> a s) (fx+ a i)]
      [(fx< a s) a]
      [front? a]
      [(or (fx< a e) rear?) (fx+ a i)]
      [else a]))

  (define (insert-end e s i rear?)
    (cond
      [(fx> e s) (fx+ e i)]
      [(and (fx= e s) rear?) (fx+ e i)]
      [else e]))

  (define (reaching-below store k s)
    (let ([lowest (fx- s (spans-longest store))])
      (let loop ([k (fx- k 1)] [acc '()])
        (if (and (fx>= k 0) (fx>= (last-start-of store k) lowest))
            (loop (fx- k 1) (if (fx>= (limit-of store k) s) (cons k acc) acc))
            acc))))

  ;; With evaporate?, a span that the removal empties goes. Only a span
  ;; that starts within the edit can move before another, so only then is
  ;; a chunk sorted.
  (define (spans-map! store s r i front? rear? evaporate?)
    (unless (spans-empty? store)
      (let* ([b (fx+ s r)] [above (chunks-above store b)] [changed (reaching-below store above s)])
        (for-each (lambda (k) (remap-chunk! store k s b i front? rear? evaporate?)) changed)
        (when (fx< above (spans-used store))
          (shift-from! store above (fx- i r)))
        (tidy! store changed))))

  (define (remap-chunk! store k s b i front? rear? evaporate?)
    (let* ([c (chunk-at store k)] [base (base store k)]
           [starts (chunk-starts c)] [ends (chunk-ends c)] [items (chunk-values c)] [n (chunk-count c)])
      (let loop ([j 0] [w 0] [last-end #f] [unsorted? #f])
        (if (fx= j n)
            (begin
              (truncate-chunk! c w)
              (chunk-last-end-set! c (or last-end 0))
              (when unsorted? (sort-chunk! c)))
            (let ([a0 (fx+ base (fxvector-ref starts j))] [e0 (fx+ base (fxvector-ref ends j))] [v (vector-ref items j)])
              (define (keep! a e unsorted?)
                (fxvector-set! starts w (fx- a base))
                (fxvector-set! ends w (fx- e base))
                (vector-set! items w v)
                (lengthen! store a e)
                (loop (fx+ j 1) (fx+ w 1) (if last-end (fxmax last-end (fx- e base)) (fx- e base)) unsorted?))
              (cond
                [(fx> a0 b) (let ([d (fx- i (fx- b s))]) (keep! (fx+ a0 d) (fx+ e0 d) unsorted?))]
                [(fx< e0 s) (keep! a0 e0 unsorted?)]
                [else
                 (let ([a (cut a0 s b)] [e (cut e0 s b)])
                   (cond
                     [(and evaporate? (fx= a e) (fx< a0 e0)) (loop (fx+ j 1) w last-end unsorted?)]
                     [(fx= i 0) (keep! a e (or unsorted? (fx>= a0 s)))]
                     [else (keep! (insert-start a e s i front? rear?) (insert-end e s i rear?) (or unsorted? (fx>= a0 s)))]))]))))))

  (define (spans-split! store s i)
    (unless (spans-empty? store)
      (let* ([above (chunks-above store (fx- s 1))] [right '()])
        (for-each
          (lambda (k)
            (let* ([c (chunk-at store k)] [base (base store k)] [starts (chunk-starts c)] [ends (chunk-ends c)])
              (do ([j 0 (fx+ j 1)]) ((fx= j (chunk-count c)))
                (let ([a (fx+ base (fxvector-ref starts j))] [e (fx+ base (fxvector-ref ends j))])
                  (cond
                    [(fx>= a s)
                     (fxvector-set! starts j (fx+ (fxvector-ref starts j) i))
                     (fxvector-set! ends j (fx+ (fxvector-ref ends j) i))]
                    [(fx> e s)
                     (fxvector-set! ends j (fx- s base))
                     (set! right (cons (list (fx+ s i) (fx+ e i) (vector-ref (chunk-values c) j)) right))])))
              (refresh-limit! c)))
          (reaching-below store above s))
        (when (fx< above (spans-used store))
          (shift-from! store above i))
        (for-each (lambda (r) (spans-add! store (car r) (cadr r) (caddr r))) right))))

  (define (insert-chunk! store k c)
    (settle! store)
    (let* ([chunks (spans-chunks store)] [n (spans-used store)]
           [chunks (if (fx< n (vector-length chunks))
                       chunks
                       (let ([v (make-vector (fx* 2 n) #f)])
                         (do ([j 0 (fx+ j 1)]) ((fx= j n)) (vector-set! v j (vector-ref chunks j)))
                         (spans-chunks-set! store v)
                         (spans-shifts-set! store (make-fxvector (fx+ (fx* 2 n) 1) 0))
                         v))])
      (do ([j n (fx- j 1)]) ((fx= j k)) (vector-set! chunks j (vector-ref chunks (fx- j 1))))
      (vector-set! chunks k c)
      (spans-used-set! store (fx+ n 1))))

  (define (split-chunk! store k)
    (settle! store)
    (let* ([c (chunk-at store k)] [n (chunk-count c)] [half (fxsrl n 1)] [own (chunk-own c)]
           [upper (make-chunk (fx+ own (fxvector-ref (chunk-starts c) half)))])
      (do ([j half (fx+ j 1)]) ((fx= j n))
        (let ([d (fx- own (chunk-own upper))])
          (fxvector-set! (chunk-starts upper) (fx- j half) (fx+ d (fxvector-ref (chunk-starts c) j)))
          (fxvector-set! (chunk-ends upper) (fx- j half) (fx+ d (fxvector-ref (chunk-ends c) j)))
          (vector-set! (chunk-values upper) (fx- j half) (vector-ref (chunk-values c) j))))
      (chunk-count-set! upper (fx- n half))
      (truncate-chunk! c half)
      (refresh-limit! c)
      (refresh-limit! upper)
      (insert-chunk! store (fx+ k 1) upper)))

  (define (spans-add! store a e v)
    (when (fx= (spans-used store) 0)
      (insert-chunk! store 0 (make-chunk a)))
    (lengthen! store a e)
    (let* ([k (fxmax 0 (fx- (chunks-above store a) 1))]
           [k (if (fx= (chunk-count (chunk-at store k)) chunk-size)
                  (begin (split-chunk! store k) (fxmax 0 (fx- (chunks-above store a) 1)))
                  k)]
           [c (chunk-at store k)] [n (chunk-count c)] [base (base store k)]
           [starts (chunk-starts c)] [ends (chunk-ends c)] [items (chunk-values c)])
      (let ([at (let loop ([j n]) (if (and (fx> j 0) (fx> (fx+ base (fxvector-ref starts (fx- j 1))) a)) (loop (fx- j 1)) j))])
        (do ([j n (fx- j 1)]) ((fx= j at))
          (fxvector-set! starts j (fxvector-ref starts (fx- j 1)))
          (fxvector-set! ends j (fxvector-ref ends (fx- j 1)))
          (vector-set! items j (vector-ref items (fx- j 1))))
        (fxvector-set! starts at (fx- a base))
        (fxvector-set! ends at (fx- e base))
        (vector-set! items at v)
        (chunk-count-set! c (fx+ n 1))
        (when (or (fx= n 0) (fx> (fx- e base) (chunk-last-end c)))
          (chunk-last-end-set! c (fx- e base))))))

  (define (spans-take! store lo hi keep?)
    (let ([taken '()] [changed '()])
      (for-each-reaching store lo hi
        (lambda (k)
          (let* ([c (chunk-at store k)] [base (base store k)] [n (chunk-count c)]
                 [starts (chunk-starts c)] [ends (chunk-ends c)] [items (chunk-values c)])
            (let loop ([j 0] [w 0])
              (if (fx= j n)
                  (unless (fx= w n)
                    (truncate-chunk! c w)
                    (refresh-limit! c)
                    (set! changed (cons k changed)))
                  (let ([a (fx+ base (fxvector-ref starts j))] [e (fx+ base (fxvector-ref ends j))] [v (vector-ref items j)])
                    (if (and (fx>= e lo) (fx<= a hi) (keep? a e v))
                        (begin (set! taken (cons (list a e v) taken)) (loop (fx+ j 1) w))
                        (begin
                          (fxvector-set! starts w (fxvector-ref starts j))
                          (fxvector-set! ends w (fxvector-ref ends j))
                          (vector-set! items w v)
                          (loop (fx+ j 1) (fx+ w 1))))))))))
      (tidy! store changed)
      (list-sort by-position (reverse taken))))

  (define (gather store lo hi wanted?)
    (let ([acc '()])
      (for-each-reaching store lo hi
        (lambda (k)
          (let ([c (chunk-at store k)] [base (base store k)])
            (do ([j 0 (fx+ j 1)]) ((fx= j (chunk-count c)))
              (let ([a (fx+ base (fxvector-ref (chunk-starts c) j))] [e (fx+ base (fxvector-ref (chunk-ends c) j))])
                (when (wanted? a e)
                  (set! acc (cons (list a e (vector-ref (chunk-values c) j)) acc))))))))
      (list-sort by-position (reverse acc))))

  ;; A span overlaps a range when they share a position's token; an empty
  ;; span or range counts as the token after it.
  (define (spans-overlapping store start end)
    (gather store start end
      (lambda (a e)
        (if (fx< start end)
            (if (fx< a e) (and (fx< a end) (fx< start e)) (and (fx<= start a) (fx< a end)))
            (if (fx< a e) (and (fx<= a start) (fx< start e)) (fx= a start))))))

  (define (spans-touching store lo hi)
    (gather store lo hi (lambda (a e) (and (fx>= e lo) (fx<= a hi)))))

  ;; The spans that text inserted at s, once the r positions after s are
  ;; removed, would join. Travelling spans are values of the text itself,
  ;; so the text takes those of the token before it when spans stick at
  ;; their end, else those of the token after it when they stick at their
  ;; start, as Emacs's inherited text properties do.
  (define (spans-taking store s r front? rear? travels?)
    (let* ([b (fx+ s r)] [near (spans-touching store s b)])
      (define (cut-start x) (cut (car x) s b))
      (define (cut-end x) (cut (cadr x) s b))
      (if travels?
          (let ([before (if rear? (filter (lambda (x) (and (fx< (cut-start x) s) (fx>= (cut-end x) s))) near) '())])
            (cond
              [(pair? before) before]
              [front? (filter (lambda (x) (and (fx<= (cut-start x) s) (fx> (cut-end x) s))) near)]
              [else '()]))
          (filter (lambda (x)
                    (let ([a (cut-start x)] [e (cut-end x)])
                      (and (fx<= (insert-start a e s 1 front? rear?) s)
                           (fx>= (insert-end e s 1 rear?) (fx+ s 1)))))
                  near)))))
