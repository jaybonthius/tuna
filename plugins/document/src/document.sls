(library (document)
  (export document? document:from-datum document:from-utf8 document:datums
          document:length document:token document:text document:for-each-utf8-chunk
          document:unit document:offset document:position document:text-position document:line document:line-start
          document:column document:column-position
          document:enclosing document:node? document:atom? document:node-kind
          document:node-attribute document:node-start document:node-end document:in-line?
          document:for-each-child document:grapheme-boundary?
          document:slice document:open-start document:open-end document:replace document:repeat
          document:same-tokens? document:freeze)
  (import (chezscheme))

  ;; A document is built of vectors, bytevectors, symbols and lists, never
  ;; records, because a job accepts plain data only. Nothing this library
  ;; makes is changed after it is made, so an immutable vector is one
  ;; already frozen.

  ;; The same symbol in every process and after this library reloads, which
  ;; no other value carries.
  (define tag (gensym "document" "f6hdbqx9z1lk3n0m8wyr2e7tsc-0"))

  (define leaf-max 32)
  (define leaf-fill 24)
  (define branch-max 16)
  (define branch-fill 12)
  (define run-cut 1024)
  (define run-max 2048)

  (define (make-document tree open-start open-end openings)
    (vector tag tree open-start open-end openings))

  (define (document? v)
    (and (vector? v) (fx= (vector-length v) 5) (eq? (vector-ref v 0) tag)))

  (define (document-tree d) (vector-ref d 1))
  (define (document-open-start d) (vector-ref d 2))
  (define (document-open-end d) (vector-ref d 3))
  (define (document-openings d) (vector-ref d 4))

  (define stride 48)

  (define (entry i) (fx* i stride))
  (define (tokens-ref s i) (bytevector-u32-native-ref s (entry i)))
  (define (newlines-ref s i) (bytevector-u32-native-ref s (fx+ (entry i) 4)))
  (define (chars-ref s i) (bytevector-u32-native-ref s (fx+ (entry i) 8)))
  (define (bytes-ref s i) (bytevector-u32-native-ref s (fx+ (entry i) 12)))
  (define (astral-ref s i) (bytevector-u32-native-ref s (fx+ (entry i) 16)))
  (define (atoms-ref s i) (bytevector-u32-native-ref s (fx+ (entry i) 20)))
  (define (net-ref s i) (bytevector-s32-native-ref s (fx+ (entry i) 24)))
  ;; The lowest depth at any gap of a child, relative to its start, lets a
  ;; search for a depth skip the children that cannot hold it.
  (define (low-ref s i) (bytevector-s32-native-ref s (fx+ (entry i) 28)))
  (define (lead-ref s i) (bytevector-u32-native-ref s (fx+ (entry i) 32)))
  (define (trail-ref s i) (bytevector-u32-native-ref s (fx+ (entry i) 36)))
  (define (inner-ref s i) (bytevector-u32-native-ref s (fx+ (entry i) 40)))
  (define (first-ref s i) (bytevector-u8-ref s (fx+ (entry i) 44)))
  (define (last-ref s i) (bytevector-u8-ref s (fx+ (entry i) 45)))

  (define (entry-set! s i tokens newlines chars bytes astral atoms net low)
    (let ([e (entry i)])
      (bytevector-u32-native-set! s e tokens)
      (bytevector-u32-native-set! s (fx+ e 4) newlines)
      (bytevector-u32-native-set! s (fx+ e 8) chars)
      (bytevector-u32-native-set! s (fx+ e 12) bytes)
      (bytevector-u32-native-set! s (fx+ e 16) astral)
      (bytevector-u32-native-set! s (fx+ e 20) atoms)
      (bytevector-s32-native-set! s (fx+ e 24) net)
      (bytevector-s32-native-set! s (fx+ e 28) low)))

  ;; Whether an atom is in a line depends on the tokens on both sides of
  ;; its run of atoms, which may lie in other entries, so an entry keeps
  ;; the atoms before its first other token and after its last unjudged,
  ;; with those tokens' classes. An entry of atoms alone has no class.
  (define (shape-set! s i lead first inner trail last)
    (let ([e (entry i)])
      (bytevector-u32-native-set! s (fx+ e 32) lead)
      (bytevector-u32-native-set! s (fx+ e 36) trail)
      (bytevector-u32-native-set! s (fx+ e 40) inner)
      (bytevector-u8-set! s (fx+ e 44) first)
      (bytevector-u8-set! s (fx+ e 45) last)))

  (define no-class 0)
  (define newline-class 1)
  (define char-class 2)
  (define node-class 3)

  (define (byte-class x) (if (fx= x 10) newline-class char-class))

  ;; A newline belongs to the line it ends, so a newline after a run puts
  ;; the run in that line, and a newline before it does not.
  (define (in-line-between? before after)
    (or (fx= after newline-class) (fx= after char-class) (fx= before char-class)))

  (define (run-shape! s i run)
    (shape-set! s i 0 (byte-class (bytevector-u8-ref run 0)) 0
                0 (byte-class (bytevector-u8-ref run (fx- (bytevector-length run) 1)))))

  (define (shape-total! s j t)
    (let ([ts (tree-sums t)] [n (tree-count t)])
      (let loop ([i 0] [lead 0] [first no-class] [inner 0] [trail 0] [last no-class])
        (if (fx= i n)
            (shape-set! s j lead first inner trail last)
            (let ([f (first-ref ts i)])
              (cond
                [(fx= f no-class)
                 (let ([k (lead-ref ts i)])
                   (loop (fx+ i 1) (if (fx= first no-class) (fx+ lead k) lead) first inner (fx+ trail k) last))]
                [(fx= first no-class)
                 (loop (fx+ i 1) (fx+ lead (lead-ref ts i)) f (inner-ref ts i) (trail-ref ts i) (last-ref ts i))]
                [else
                 (loop (fx+ i 1) lead first
                       (fx+ inner (inner-ref ts i) (if (in-line-between? last f) (fx+ trail (lead-ref ts i)) 0))
                       (trail-ref ts i) (last-ref ts i))]))))))

  ;; UTF-16 units need no count of their own: they are characters plus
  ;; characters above U+FFFF.
  (define (utf-16-ref s i) (fx+ (chars-ref s i) (astral-ref s i)))

  (define (unit-ref unit)
    (case unit
      [(characters) chars-ref]
      [(bytes) bytes-ref]
      [(utf-16) utf-16-ref]
      [(atoms) atoms-ref]
      [(newlines) newlines-ref]))

  (define (tree-height t) (vector-ref t 0))
  (define (tree-sums t) (vector-ref t 1))
  (define (tree-count t) (fx- (vector-length t) 2))
  (define (tree-child t i) (vector-ref t (fx+ i 2)))
  (define (leaf? t) (fx= (vector-ref t 0) 0))

  (define (make-tree height n)
    (let ([t (make-vector (fx+ n 2) #f)])
      (vector-set! t 0 height)
      (vector-set! t 1 (make-bytevector (entry n)))
      t))

  (define (empty-tree) (make-tree 0 0))

  (define (empty-tree? t) (fx= (tree-count t) 0))

  (define (tree-tokens t)
    (let ([s (tree-sums t)] [n (tree-count t)])
      (let loop ([i 0] [sum 0])
        (if (fx= i n) sum (loop (fx+ i 1) (fx+ sum (tokens-ref s i)))))))

  (define (total! s j t)
    (let ([ts (tree-sums t)] [n (tree-count t)])
      (let loop ([i 0] [tokens 0] [newlines 0] [chars 0] [bytes 0] [astral 0] [atoms 0] [net 0] [low 0])
        (if (fx= i n)
            (entry-set! s j tokens newlines chars bytes astral atoms net low)
            (loop (fx+ i 1)
                  (fx+ tokens (tokens-ref ts i))
                  (fx+ newlines (newlines-ref ts i))
                  (fx+ chars (chars-ref ts i))
                  (fx+ bytes (bytes-ref ts i))
                  (fx+ astral (astral-ref ts i))
                  (fx+ atoms (atoms-ref ts i))
                  (fx+ net (net-ref ts i))
                  (fxmin low (fx+ net (low-ref ts i)))))))
    (shape-total! s j t))

  (define (tree-depths t)
    (let ([s (tree-sums t)] [n (tree-count t)])
      (let loop ([i 0] [net 0] [low 0])
        (if (fx= i n)
            (values net low)
            (loop (fx+ i 1) (fx+ net (net-ref s i)) (fxmin low (fx+ net (low-ref s i))))))))

  (define (opening? item) (and (vector? item) (eq? (vector-ref item 0) 'open)))
  (define (atom-item? item) (and (vector? item) (eq? (vector-ref item 0) 'atom)))
  (define (item-kind item) (vector-ref item 1))
  (define (item-attributes item) (vector-ref item 2))

  (define (raw-byte item)
    (and (eq? (item-kind item) 'document:raw-byte)
         (cdr (assq 'byte (item-attributes item)))))

  (define (token-sums! s i item)
    (cond
      [(eq? item 'close)
       (entry-set! s i 1 0 0 0 0 0 -1 -1)
       (shape-set! s i 0 node-class 0 0 node-class)]
      [(opening? item)
       (entry-set! s i 1 0 0 0 0 0 1 0)
       (shape-set! s i 0 node-class 0 0 node-class)]
      [else
       (entry-set! s i 1 0 1 (if (raw-byte item) 1 3) 0 1 0 0)
       (shape-set! s i 1 no-class 0 1 no-class)]))

  (define (run-sums! s i run chars newlines astral)
    (entry-set! s i chars newlines chars (bytevector-length run) astral 0 0 0)
    (run-shape! s i run))

  (define object-replacement (bytevector->immutable-bytevector (string->utf8 "\xFFFC;")))

  (define single-bytes
    (let ([v (make-vector 256)])
      (do ([b 0 (fx+ b 1)]) ((fx= b 256) v)
        (vector-set! v b (bytevector->immutable-bytevector (bytevector b))))))

  (define (continuation? x) (fx= (fxand x #xC0) #x80))

  (define (lead-length x)
    (cond [(fx< x #x80) 1] [(fx< x #xE0) 2] [(fx< x #xF0) 3] [else 4]))

  ;; A run with as many characters as bytes is ASCII and needs no scan.
  (define (run-index run k c)
    (let ([n (bytevector-length run)])
      (cond
        [(fx= c n) k]
        [(fx<= (fx* 2 k) c)
         (let loop ([i 0] [j 0])
           (if (fx= j k) i (loop (fx+ i (lead-length (bytevector-u8-ref run i))) (fx+ j 1))))]
        [else
         (let loop ([i n] [j c])
           (if (fx= j k)
               i
               (let back ([i (fx- i 1)])
                 (if (continuation? (bytevector-u8-ref run i)) (back (fx- i 1)) (loop i (fx- j 1))))))])))

  (define (range-stats bv from to)
    (let loop ([i from] [chars 0] [newlines 0] [astral 0])
      (if (fx= i to)
          (values chars newlines astral)
          (let ([x (bytevector-u8-ref bv i)])
            (loop (fx+ i 1)
                  (if (continuation? x) chars (fx+ chars 1))
                  (if (fx= x 10) (fx+ newlines 1) newlines)
                  (if (fx>= x #xF0) (fx+ astral 1) astral))))))

  (define (count-chars bv from to)
    (let loop ([i from] [chars 0])
      (if (fx= i to)
          chars
          (loop (fx+ i 1) (if (continuation? (bytevector-u8-ref bv i)) chars (fx+ chars 1))))))

  (define (decode bv i)
    (let ([x (bytevector-u8-ref bv i)])
      (define (more k) (fxand (bytevector-u8-ref bv (fx+ i k)) #x3F))
      (integer->char
        (cond
          [(fx< x #x80) x]
          [(fx< x #xE0) (fxior (fxsll (fxand x #x1F) 6) (more 1))]
          [(fx< x #xF0) (fxior (fxsll (fxand x #x0F) 12) (fxsll (more 1) 6) (more 2))]
          [else (fxior (fxsll (fxand x #x07) 18) (fxsll (more 1) 12) (fxsll (more 2) 6) (more 3))]))))

  (define (decode-into! bv from to s at)
    (let loop ([i from] [at at])
      (if (fx= i to)
          at
          (let ([x (bytevector-u8-ref bv i)])
            (if (fx< x #x80)
                (begin (string-set! s at (integer->char x)) (loop (fx+ i 1) (fx+ at 1)))
                (begin (string-set! s at (decode bv i)) (loop (fx+ i (lead-length x)) (fx+ at 1))))))))

  (define (put-utf8! bv at k size)
    (case size
      [(1) (bytevector-u8-set! bv at k)]
      [(2)
       (bytevector-u8-set! bv at (fxior #xC0 (fxsrl k 6)))
       (bytevector-u8-set! bv (fx+ at 1) (fxior #x80 (fxand k #x3F)))]
      [(3)
       (bytevector-u8-set! bv at (fxior #xE0 (fxsrl k 12)))
       (bytevector-u8-set! bv (fx+ at 1) (fxior #x80 (fxand (fxsrl k 6) #x3F)))
       (bytevector-u8-set! bv (fx+ at 2) (fxior #x80 (fxand k #x3F)))]
      [else
       (bytevector-u8-set! bv at (fxior #xF0 (fxsrl k 18)))
       (bytevector-u8-set! bv (fx+ at 1) (fxior #x80 (fxand (fxsrl k 12) #x3F)))
       (bytevector-u8-set! bv (fx+ at 2) (fxior #x80 (fxand (fxsrl k 6) #x3F)))
       (bytevector-u8-set! bv (fx+ at 3) (fxior #x80 (fxand k #x3F)))]))

  ;; Overlong forms, surrogates and code points past U+10FFFF are not
  ;; UTF-8, so their bytes become raw bytes and are written back as read.
  (define (valid-length bv i n)
    (let ([x (bytevector-u8-ref bv i)])
      (define (in? k lo hi)
        (let ([j (fx+ i k)])
          (and (fx< j n) (fx<= lo (bytevector-u8-ref bv j) hi))))
      (cond
        [(fx< x #x80) 1]
        [(fx< x #xC2) 0]
        [(fx< x #xE0) (if (in? 1 #x80 #xBF) 2 0)]
        [(fx< x #xF0)
         (if (and (in? 1 (if (fx= x #xE0) #xA0 #x80) (if (fx= x #xED) #x9F #xBF))
                  (in? 2 #x80 #xBF))
             3
             0)]
        [(fx< x #xF5)
         (if (and (in? 1 (if (fx= x #xF0) #x90 #x80) (if (fx= x #xF4) #x8F #xBF))
                  (in? 2 #x80 #xBF)
                  (in? 3 #x80 #xBF))
             4
             0)]
        [else 0])))

  (define (subbytes bv from to)
    (let ([r (make-bytevector (fx- to from))])
      (bytevector-copy! bv from r 0 (fx- to from))
      (bytevector->immutable-bytevector r)))

  (define-record-type builder
    (fields (mutable leaf) (mutable count) (mutable leaves))
    (protocol (lambda (new) (lambda () (new (make-tree 0 leaf-fill) 0 '())))))

  (define (builder-add! b item chars newlines astral)
    (let ([t (builder-leaf b)] [i (builder-count b)])
      (vector-set! t (fx+ i 2) item)
      (if (bytevector? item)
          (run-sums! (tree-sums t) i item chars newlines astral)
          (token-sums! (tree-sums t) i item))
      (if (fx= (fx+ i 1) leaf-fill)
          (begin
            (builder-leaves-set! b (cons t (builder-leaves b)))
            (builder-leaf-set! b (make-tree 0 leaf-fill))
            (builder-count-set! b 0))
          (builder-count-set! b (fx+ i 1)))))

  (define (builder-add-token! b item)
    (builder-add! b item 0 0 0))

  (define (builder-tree b)
    (let* ([n (builder-count b)]
           [leaves (reverse
                     (if (fx= n 0)
                         (builder-leaves b)
                         (cons (sub-tree (builder-leaf b) 0 n) (builder-leaves b))))])
      (if (null? leaves)
          (empty-tree)
          (let level ([nodes leaves] [height 1])
            (if (null? (cdr nodes))
                (car nodes)
                (level (group nodes height) (fx+ height 1)))))))

  (define (group nodes height)
    (let* ([n (length nodes)]
           [groups (fxquotient (fx+ n (fx- branch-fill 1)) branch-fill)]
           [size (fxquotient n groups)]
           [extra (fxremainder n groups)])
      (let loop ([nodes nodes] [g 0] [acc '()])
        (if (null? nodes)
            (reverse acc)
            (let ([k (if (fx< g extra) (fx+ size 1) size)])
              (loop (list-tail nodes k) (fx+ g 1)
                    (cons (assemble-one height (list-head nodes k)) acc)))))))

  (define-record-type span (fields node from to))

  (define (piece-count p)
    (if (span? p) (fx- (span-to p) (span-from p)) 1))

  (define (assemble-one height pieces)
    (let* ([n (fold-left (lambda (n p) (fx+ n (piece-count p))) 0 pieces)]
           [t (make-tree height n)]
           [s (tree-sums t)])
      (let loop ([ps pieces] [j 0])
        (unless (null? ps)
          (let ([p (car ps)])
            (if (span? p)
                (let ([from (span-from p)] [k (piece-count p)] [src (span-node p)])
                  (vector-copy! src (fx+ from 2) t (fx+ j 2) k)
                  (bytevector-copy! (tree-sums src) (entry from) s (entry j) (entry k))
                  (loop (cdr ps) (fx+ j k)))
                (begin
                  (vector-set! t (fx+ j 2) p)
                  (total! s j p)
                  (loop (cdr ps) (fx+ j 1)))))))
      t))

  (define (assemble height pieces)
    (let* ([t (assemble-one height pieces)]
           [n (tree-count t)]
           [limit (if (fx= height 0) leaf-max branch-max)])
      (if (fx<= n limit)
          (list t)
          (let* ([parts (fxquotient (fx+ n (fx- limit 1)) limit)]
                 [size (fxquotient n parts)]
                 [extra (fxremainder n parts)])
            (let loop ([g 0] [from 0] [acc '()])
              (if (fx= g parts)
                  (reverse acc)
                  (let ([to (fx+ from size (if (fx< g extra) 1 0))])
                    (loop (fx+ g 1) to (cons (sub-tree t from to) acc)))))))))

  (define (sub-tree t from to)
    (assemble-one (tree-height t) (list (make-span t from to))))

  (define (run-leaf run chars newlines astral)
    (let ([t (make-tree 0 1)])
      (vector-set! t 2 run)
      (run-sums! (tree-sums t) 0 run chars newlines astral)
      t))

  (define (trim t)
    (if (and (fx> (tree-height t) 0) (fx= (tree-count t) 1))
        (trim (tree-child t 0))
        t))

  ;; Both halves keep t's height, which join relies on.
  (define (split-node t p)
    (let ([s (tree-sums t)] [n (tree-count t)] [height (tree-height t)])
      (let find ([i 0] [acc 0])
        (let ([next (fx+ acc (tokens-ref s i))])
          (cond
            [(fx<= next p) (find (fx+ i 1) next)]
            [(fx= acc p) (values (sub-tree t 0 i) (sub-tree t i n))]
            [(fx= height 0)
             (let-values ([(l r) (split-run (tree-child t i) s i (fx- p acc))])
               (values (assemble-one 0 (list (make-span t 0 i) (make-span l 0 1)))
                       (assemble-one 0 (list (make-span r 0 1) (make-span t (fx+ i 1) n)))))]
            [else
             (let-values ([(l r) (split-node (tree-child t i) (fx- p acc))])
               (values (assemble-one height (list (make-span t 0 i) l))
                       (assemble-one height (list r (make-span t (fx+ i 1) n)))))])))))

  (define (split-run run s i k)
    (let* ([chars (chars-ref s i)]
           [n (bytevector-length run)]
           [b (run-index run k chars)])
      (let-values ([(c newlines astral) (range-stats run 0 b)])
        (values (run-leaf (subbytes run 0 b) k newlines astral)
                (run-leaf (subbytes run b n) (fx- chars k)
                  (fx- (newlines-ref s i) newlines) (fx- (astral-ref s i) astral))))))

  (define (tree-split t p)
    (cond
      [(fx= p 0) (values (empty-tree) t)]
      [(fx= p (tree-tokens t)) (values t (empty-tree))]
      [else (let-values ([(l r) (split-node t p)]) (values (trim l) (trim r)))]))

  (define (join a b)
    (cond
      [(empty-tree? a) b]
      [(empty-tree? b) a]
      [else
       (let ([ha (tree-height a)] [hb (tree-height b)])
         (let ([nodes (cond
                        [(fx= ha hb) (join-equal a b)]
                        [(fx> ha hb) (join-right a b)]
                        [else (join-left a b)])])
           (if (null? (cdr nodes))
               (car nodes)
               (assemble-one (fx+ (fxmax ha hb) 1) nodes))))]))

  ;; Joins the seam all the way down, so that the nodes and runs an edit
  ;; leaves small are merged with their neighbours.
  (define (join-equal a b)
    (let ([height (tree-height a)] [na (tree-count a)] [nb (tree-count b)])
      (if (fx= height 0)
          (let ([x (tree-child a (fx- na 1))] [y (tree-child b 0)])
            (if (and (bytevector? x) (bytevector? y)
                     (fx<= (fx+ (bytevector-length x) (bytevector-length y)) run-max))
                (assemble 0 (list (make-span a 0 (fx- na 1))
                                  (make-span (merge-runs a (fx- na 1) b 0) 0 1)
                                  (make-span b 1 nb)))
                (assemble 0 (list (make-span a 0 na) (make-span b 0 nb)))))
          (assemble height
            (cons (make-span a 0 (fx- na 1))
                  (append (join-equal (tree-child a (fx- na 1)) (tree-child b 0))
                          (list (make-span b 1 nb))))))))

  (define (join-right a b)
    (let* ([na (tree-count a)]
           [last (tree-child a (fx- na 1))]
           [middle (if (fx= (tree-height last) (tree-height b)) (join-equal last b) (join-right last b))])
      (assemble (tree-height a) (cons (make-span a 0 (fx- na 1)) middle))))

  (define (join-left a b)
    (let* ([first (tree-child b 0)]
           [middle (if (fx= (tree-height first) (tree-height a)) (join-equal a first) (join-left a first))])
      (assemble (tree-height b) (append middle (list (make-span b 1 (tree-count b)))))))

  (define (merge-runs a i b j)
    (let* ([x (tree-child a i)] [y (tree-child b j)]
           [nx (bytevector-length x)] [ny (bytevector-length y)]
           [r (make-bytevector (fx+ nx ny))]
           [sa (tree-sums a)] [sb (tree-sums b)])
      (bytevector-copy! x 0 r 0 nx)
      (bytevector-copy! y 0 r nx ny)
      (run-leaf (bytevector->immutable-bytevector r)
        (fx+ (chars-ref sa i) (chars-ref sb j))
        (fx+ (newlines-ref sa i) (newlines-ref sb j))
        (fx+ (astral-ref sa i) (astral-ref sb j)))))

  (define (no-edit) (values #f 0 0 0 0 #f))

  ;; Typing changes one run, so only the path to it is copied, and every
  ;; count changes by the same amount at each level. No atom changes, so
  ;; the runs of atoms are judged again only when the class of the run's
  ;; first or last character changes.
  (define (edit-run t s e c)
    (let ([sums (tree-sums t)] [n (tree-count t)])
      (let find ([i 0] [acc 0])
        (if (fx= i n)
            (no-edit)
            (let ([next (fx+ acc (tokens-ref sums i))])
              (cond
                [(if (fx= s e) (fx< next s) (fx<= next s)) (find (fx+ i 1) next)]
                [(fx> e next) (no-edit)]
                [(fx> (tree-height t) 0)
                 (let-values ([(child dt dn db da reshaped?) (edit-run (tree-child t i) (fx- s acc) (fx- e acc) c)])
                   (if child
                       (values (with-child t i child dt dn db da reshaped?) dt dn db da reshaped?)
                       (no-edit)))]
                [(bytevector? (tree-child t i)) (edit-item t i (fx- s acc) (fx- e acc) c)]
                [(and (fx= s e next) (fx< (fx+ i 1) n) (bytevector? (tree-child t (fx+ i 1))))
                 (edit-item t (fx+ i 1) 0 0 c)]
                [else (no-edit)]))))))

  (define (edit-item t i cs ce c)
    (let* ([sums (tree-sums t)]
           [run (tree-child t i)]
           [chars (chars-ref sums i)]
           [n (bytevector-length run)]
           [bs (run-index run cs chars)]
           [be (if (fx= cs ce) bs (run-index run ce chars))]
           [ins (and (fx> (tree-count c) 0) (tree-child c 0))]
           [ib (if ins (bytevector-length ins) 0)]
           [len (fx+ (fx- n (fx- be bs)) ib)])
      (if (or (fx= len 0) (fx> len run-max))
          (no-edit)
          (let-values ([(rc rn ra) (range-stats run bs be)])
            (let ([r (make-bytevector len)] [content-sums (tree-sums c)])
              (bytevector-copy! run 0 r 0 bs)
              (when ins (bytevector-copy! ins 0 r bs ib))
              (bytevector-copy! run be r (fx+ bs ib) (fx- n be))
              (let ([dt (fx- (if ins (chars-ref content-sums 0) 0) rc)]
                    [dn (fx- (if ins (newlines-ref content-sums 0) 0) rn)]
                    [db (fx- ib (fx- be bs))]
                    [da (fx- (if ins (astral-ref content-sums 0) 0) ra)]
                    [reshaped? (not (and (fx= (byte-class (bytevector-u8-ref r 0)) (first-ref sums i))
                                         (fx= (byte-class (bytevector-u8-ref r (fx- len 1))) (last-ref sums i))))])
                (values (with-child t i (bytevector->immutable-bytevector r) dt dn db da reshaped?)
                        dt dn db da reshaped?)))))))

  (define (with-child t i child dt dn db da reshaped?)
    (let ([v (vector-set/copy t (fx+ i 2) child)] [s (bytevector-copy (tree-sums t))])
      (let ([e (entry i)])
        (bytevector-u32-native-set! s e (fx+ (tokens-ref s i) dt))
        (bytevector-u32-native-set! s (fx+ e 4) (fx+ (newlines-ref s i) dn))
        (bytevector-u32-native-set! s (fx+ e 8) (fx+ (chars-ref s i) dt))
        (bytevector-u32-native-set! s (fx+ e 12) (fx+ (bytes-ref s i) db))
        (bytevector-u32-native-set! s (fx+ e 16) (fx+ (astral-ref s i) da)))
      (when reshaped?
        (if (bytevector? child)
            (run-shape! s i child)
            (shape-total! s i child)))
      (vector-set! v 1 s)
      v))

  (define (item-at t p)
    (let down ([t t] [p p] [base 0])
      (let ([s (tree-sums t)])
        (let loop ([i 0] [p p] [base base])
          (let ([tokens (tokens-ref s i)])
            (cond
              [(fx<= tokens p) (loop (fx+ i 1) (fx- p tokens) (fx+ base tokens))]
              [(leaf? t) (values (tree-child t i) base s i)]
              [else (down (tree-child t i) p base)]))))))

  (define (measure-before t p unit)
    (define ref (unit-ref unit))
    (let down ([t t] [p p] [sum 0])
      (let ([s (tree-sums t)])
        (let loop ([i 0] [p p] [sum sum])
          (if (fx= p 0)
              sum
              (let ([tokens (tokens-ref s i)])
                (cond
                  [(fx<= tokens p) (loop (fx+ i 1) (fx- p tokens) (fx+ sum (ref s i)))]
                  [(leaf? t) (fx+ sum (run-measure (tree-child t i) s i p unit))]
                  [else (down (tree-child t i) p sum)])))))))

  ;; Counting from the nearer end of the run halves the scan; the far
  ;; side is the run's total less the near one.
  (define (run-measure run s i k unit)
    (let ([chars (chars-ref s i)])
      (cond
        [(eq? unit 'characters) k]
        [(eq? unit 'bytes) (run-index run k chars)]
        [(eq? unit 'atoms) 0]
        [else
         (let ([newlines? (eq? unit 'newlines)] [n (bytevector-length run)])
           (define (counted? x) (if newlines? (fx= x 10) (fx>= x #xF0)))
           (let ([c (if (fx<= (fx* 2 k) chars)
                        (let loop ([j 0] [seen 0] [c 0])
                          (let ([x (and (fx< j n) (bytevector-u8-ref run j))])
                            (if (and x (or (continuation? x) (fx< seen k)))
                                (loop (fx+ j 1) (if (continuation? x) seen (fx+ seen 1)) (if (counted? x) (fx+ c 1) c))
                                c)))
                        (let loop ([j (fx- n 1)] [seen 0] [c 0])
                          (if (fx= seen (fx- chars k))
                              (fx- (if newlines? (newlines-ref s i) (astral-ref s i)) c)
                              (let ([x (bytevector-u8-ref run j)])
                                (loop (fx- j 1) (if (continuation? x) seen (fx+ seen 1)) (if (counted? x) (fx+ c 1) c))))))])
             (if newlines? c (fx+ k c))))])))

  (define (depth-at t p)
    (let down ([t t] [p p] [depth 0])
      (let ([s (tree-sums t)])
        (let loop ([i 0] [p p] [depth depth])
          (if (fx= p 0)
              depth
              (let ([tokens (tokens-ref s i)])
                (cond
                  [(fx<= tokens p) (loop (fx+ i 1) (fx- p tokens) (fx+ depth (net-ref s i)))]
                  [(leaf? t) depth]
                  [else (down (tree-child t i) p depth)])))))))

  ;; The depth at p must be at least d. Then an opening follows the gap
  ;; sought, so only the gaps before items are checked.
  (define (last-gap-below t p d)
    (and (fx> p 0)
         (let down ([t t] [p p] [base 0] [depth 0])
           (let ([s (tree-sums t)] [n (tree-count t)])
             (let forward ([i 0] [acc 0] [depth depth])
               (let ([next (fx+ acc (tokens-ref s i))])
                 (if (and (fx< next p) (fx< (fx+ i 1) n))
                     (forward (fx+ i 1) next (fx+ depth (net-ref s i)))
                     (let back ([i i] [acc acc] [depth depth])
                       (define (skip)
                         (and (fx> i 0)
                              (let ([j (fx- i 1)])
                                (back j (fx- acc (tokens-ref s j)) (fx- depth (net-ref s j))))))
                       (cond
                         [(fx>= (fx+ depth (low-ref s i)) d) (skip)]
                         [(leaf? t) (if (fx< depth d) (fx+ base acc) (skip))]
                         [else (or (down (tree-child t i) (fx- p acc) (fx+ base acc) depth) (skip))])))))))))

  ;; The depth at from must be at least d. Then a closing comes before the
  ;; gap sought, so only the gaps after items are checked.
  (define (gap-below-after t from d)
    (let down ([t t] [from from] [base 0] [depth 0])
      (let ([s (tree-sums t)] [n (tree-count t)])
        (let loop ([i 0] [acc 0] [depth depth])
          (if (fx= i n)
              #f
              (let ([next (fx+ acc (tokens-ref s i))] [after (fx+ depth (net-ref s i))])
                (cond
                  [(fx<= next from) (loop (fx+ i 1) next after)]
                  [(leaf? t) (if (fx< after d) (fx+ base next) (loop (fx+ i 1) next after))]
                  [(and (fx>= acc from) (fx>= (fx+ depth (low-ref s i)) d)) (loop (fx+ i 1) next after)]
                  [else
                   (or (down (tree-child t i) (fx- from acc) (fx+ base acc) depth)
                       (loop (fx+ i 1) next after))])))))))

  (define (walk-items t p visit)
    (let walk ([t t] [p p] [base 0])
      (let ([s (tree-sums t)] [n (tree-count t)] [at-leaf? (leaf? t)])
        (let loop ([i 0] [acc 0])
          (or (fx= i n)
              (let ([next (fx+ acc (tokens-ref s i))])
                (cond
                  [(fx<= next p) (loop (fx+ i 1) next)]
                  [at-leaf? (and (visit (tree-child t i) (fx+ base acc) s i) (loop (fx+ i 1) next))]
                  [else (and (walk (tree-child t i) (fx- p acc) (fx+ base acc)) (loop (fx+ i 1) next))])))))))

  (define (check-document who d)
    (unless (document? d) (assertion-violation who "not a document" d)))

  (define (check-position who d p)
    (unless (and (fixnum? p) (fx<= 0 p (tree-tokens (document-tree d))))
      (assertion-violation who "not a position in the document" p)))

  (define (check-range who d start end)
    (check-position who d start)
    (check-position who d end)
    (unless (fx<= start end)
      (assertion-violation who "start is after end" start end)))

  (define (check-procedure who p)
    (unless (procedure? p) (assertion-violation who "not a procedure" p)))

  ;; Chez's printer raises a warning on a value that holds itself, and a
  ;; report that meets the warning loses its message, so such a value is
  ;; left out of the error.
  (define (value-violation who message v)
    (if (holds-itself? v)
        (assertion-violation who message)
        (assertion-violation who message v)))

  (define (holds-itself? v)
    (let ([state (make-eq-hashtable)])
      (let walk ([v v])
        (and (or (pair? v) (vector? v) (box? v))
             (case (eq-hashtable-ref state v #f)
               [(walking) #t]
               [(done) #f]
               [else
                (eq-hashtable-set! state v 'walking)
                (let ([found (cond
                               [(pair? v) (or (walk (car v)) (walk (cdr v)))]
                               [(vector? v) (exists walk (vector->list v))]
                               [else (walk (unbox v))])])
                  (eq-hashtable-set! state v 'done)
                  found)])))))

  ;; Strings, bytevectors and vectors come back immutable; pairs cannot,
  ;; so a value holding one is copied again on its way out.
  (define (copy-plain who v)
    (let ([seen #f])
      (let copy ([v v])
        (cond
          [(or (pair? v) (vector? v))
           (unless seen (set! seen (make-eq-hashtable)))
           (let ([c (eq-hashtable-ref seen v #f)])
             (cond
               [(eq? c 'walking) (assertion-violation who "not plain data: a value holds itself")]
               [c c]
               [else
                (eq-hashtable-set! seen v 'walking)
                (let ([r (if (pair? v)
                             (let* ([a (copy (car v))] [d (copy (cdr v))]) (cons a d))
                             (vector->immutable-vector (vector-map copy v)))])
                  (eq-hashtable-set! seen v r)
                  r)]))]
          [(string? v) (string->immutable-string v)]
          [(bytevector? v) (bytevector->immutable-bytevector v)]
          [(or (symbol? v) (number? v) (char? v) (boolean? v) (null? v)) v]
          [else (value-violation who "not plain data" v)]))))

  (define (copy-out v)
    (if (or (pair? v) (vector? v)) (copy-plain 'document v) v))

  (define (copy-attributes who attributes)
    (unless (and (list? attributes)
                 (for-all (lambda (a) (and (pair? a) (symbol? (car a)))) attributes))
      (value-violation who "not an association list from symbols" attributes))
    (map (lambda (a) (cons (car a) (copy-plain who (cdr a)))) attributes))

  (define (attributes-out attributes)
    (map (lambda (a) (cons (car a) (copy-out (cdr a)))) attributes))

  (define (add-string! b s)
    (let ([n (string-length s)] [buf (make-bytevector run-cut)])
      (define (flush! len chars newlines astral)
        (when (fx> len 0)
          (builder-add! b (subbytes buf 0 len) chars newlines astral)))
      (let loop ([i 0] [len 0] [chars 0] [newlines 0] [astral 0])
        (if (fx= i n)
            (flush! len chars newlines astral)
            (let* ([k (char->integer (string-ref s i))]
                   [size (cond [(fx< k #x80) 1] [(fx< k #x800) 2] [(fx< k #x10000) 3] [else 4])])
              (if (fx> (fx+ len size) run-cut)
                  (begin
                    (flush! len chars newlines astral)
                    (loop i 0 0 0 0))
                  (begin
                    (if (fx= size 1) (bytevector-u8-set! buf len k) (put-utf8! buf len k size))
                    (loop (fx+ i 1) (fx+ len size) (fx+ chars 1)
                          (if (fx= k 10) (fx+ newlines 1) newlines)
                          (if (fx= size 4) (fx+ astral 1) astral)))))))))

  (define (check-raw-byte who attributes)
    (let ([a (assq 'byte attributes)])
      (unless (and a (fixnum? (cdr a)) (fx<= 0 (cdr a) 255))
        (assertion-violation who "a raw byte needs a byte from 0 to 255" attributes))))

  ;; A node is marked while its children are added, so a datum that holds
  ;; itself raises instead of never ending.
  (define (add-datum! b d nesting)
    (define who 'document:from-datum)
    (cond
      [(string? d) (add-string! b d)]
      [(vector? d)
       (unless (and (fx= (vector-length d) 2) (symbol? (vector-ref d 0)))
         (value-violation who "not a datum" d))
       (let ([attributes (copy-attributes who (vector-ref d 1))])
         (when (eq? (vector-ref d 0) 'document:raw-byte) (check-raw-byte who attributes))
         (builder-add-token! b (vector 'atom (vector-ref d 0) attributes)))]
      [(and (pair? d) (symbol? (car d)) (pair? (cdr d)) (list? (cddr d)))
       (when (eq-hashtable-contains? nesting d) (assertion-violation who "a datum holds itself"))
       (eq-hashtable-set! nesting d #t)
       (builder-add-token! b (vector 'open (car d) (copy-attributes who (cadr d))))
       (for-each (lambda (child) (add-datum! b child nesting)) (cddr d))
       (builder-add-token! b 'close)
       (eq-hashtable-delete! nesting d)]
      [else (value-violation who "not a datum" d)]))

  (define (document:from-datum . datums)
    (let ([b (make-builder)] [nesting (make-eq-hashtable)])
      (for-each (lambda (d) (add-datum! b d nesting)) datums)
      (make-document (builder-tree b) 0 0 '())))

  (define (document:from-utf8 bv)
    (unless (bytevector? bv) (assertion-violation 'document:from-utf8 "not a bytevector" bv))
    (let ([b (make-builder)] [n (bytevector-length bv)])
      (define (flush! from to chars newlines astral)
        (when (fx< from to)
          (builder-add! b (subbytes bv from to) chars newlines astral)))
      (let loop ([i 0] [from 0] [chars 0] [newlines 0] [astral 0])
        (if (fx= i n)
            (flush! from i chars newlines astral)
            (let ([x (bytevector-u8-ref bv i)])
              (if (fx< x #x80)
                  (if (fx= (fx- i from) run-cut)
                      (begin
                        (flush! from i chars newlines astral)
                        (loop (fx+ i 1) i 1 (if (fx= x 10) 1 0) 0))
                      (loop (fx+ i 1) from (fx+ chars 1) (if (fx= x 10) (fx+ newlines 1) newlines) astral))
                  (let ([k (valid-length bv i n)])
                    (cond
                      [(fx= k 0)
                       (flush! from i chars newlines astral)
                       (builder-add-token! b (vector 'atom 'document:raw-byte (list (cons 'byte x))))
                       (loop (fx+ i 1) (fx+ i 1) 0 0 0)]
                      [(fx> (fx+ (fx- i from) k) run-cut)
                       (flush! from i chars newlines astral)
                       (loop (fx+ i k) i 1 0 (if (fx= k 4) 1 0))]
                      [else (loop (fx+ i k) from (fx+ chars 1) newlines (if (fx= k 4) (fx+ astral 1) astral))]))))))
      (make-document (builder-tree b) 0 0 '())))

  (define (document:datums doc)
    (check-document 'document:datums doc)
    (let ([stack (list (list #f '()))] [text '()] [text-chars 0])
      (define (add! datum)
        (let ([frame (car stack)])
          (set-cdr! (cdr frame) (cons datum (cddr frame)))))
      (define (flush-text!)
        (unless (null? text)
          (let ([s (make-string text-chars)])
            (fold-left (lambda (at run) (decode-into! run 0 (bytevector-length run) s at)) 0 (reverse text))
            (set! text '())
            (set! text-chars 0)
            (add! s))))
      (define (open! item)
        (set! stack (cons (list (item-kind item) (item-attributes item)) stack)))
      (define (close!)
        (let ([frame (car stack)])
          (set! stack (cdr stack))
          (add! (cons* (car frame) (attributes-out (cadr frame)) (reverse (cddr frame))))))
      (for-each open! (document-openings doc))
      (walk-items (document-tree doc) 0
        (lambda (item at s i)
          (cond
            [(bytevector? item)
             (set! text (cons item text))
             (set! text-chars (fx+ text-chars (chars-ref s i)))]
            [else
             (flush-text!)
             (cond
               [(eq? item 'close) (close!)]
               [(opening? item) (open! item)]
               [else (add! (vector (item-kind item) (attributes-out (item-attributes item))))])])
          #t))
      (flush-text!)
      (let loop ()
        (unless (null? (cdr stack))
          (close!)
          (loop)))
      (reverse (cddr (car stack)))))

  (define (document:length doc)
    (check-document 'document:length doc)
    (tree-tokens (document-tree doc)))

  (define (document:open-start doc)
    (check-document 'document:open-start doc)
    (document-open-start doc))

  (define (document:open-end doc)
    (check-document 'document:open-end doc)
    (document-open-end doc))

  (define (document:token doc p)
    (check-document 'document:token doc)
    (check-position 'document:token doc p)
    (let ([t (document-tree doc)])
      (if (fx= p (tree-tokens t))
          (eof-object)
          (let-values ([(item at s i) (item-at t p)])
            (cond
              [(bytevector? item) (decode item (run-index item (fx- p at) (chars-ref s i)))]
              [(eq? item 'close) 'close]
              [else (make-node doc p item)])))))

  ;; The rules of Unicode's grapheme clusters (UAX #29) that can join two
  ;; code points; a pair no rule joins is always a boundary, so the text
  ;; before it need not be read.
  (define (may-join? a b)
    (let ([pa (char-grapheme-break-property a)] [pb (char-grapheme-break-property b)])
      (or (and (eq? pa 'CR) (eq? pb 'LF))
          (and (memq pb '(Extend ZWJ SpacingMark)) #t)
          (eq? pa 'Prepend)
          (and (eq? pa 'ZWJ) (char-extended-pictographic? b))
          (and (eq? pa 'Regional_Indicator) (eq? pb 'Regional_Indicator))
          (and (eq? pa 'L) (memq pb '(L V LV LVT)) #t)
          (and (memq pa '(LV V)) (memq pb '(V T)) #t)
          (and (memq pa '(LVT T)) (eq? pb 'T))
          (and (eq? (char-indic-break-property b) 'Consonant)
               (memq (char-indic-break-property a) '(Linker Extend))
               #t))))

  ;; Below the combining marks, every code point but CR stands alone.
  (define (lone? c) (and (fx< (char->integer c) #x300) (not (char=? c #\return))))

  (define (document:grapheme-boundary? doc p)
    (check-document 'document:grapheme-boundary? doc)
    (check-position 'document:grapheme-boundary? doc p)
    (let ([n (tree-tokens (document-tree doc))])
      (or (fx= p 0) (fx= p n)
          (let ([a (document:token doc (fx- p 1))] [b (document:token doc p)])
            (or (not (char? a)) (not (char? b)) (and (lone? a) (lone? b)) (not (may-join? a b))
                (let ([start (let back ([q (fx- p 1)])
                               (let ([c (and (fx> q 0) (document:token doc (fx- q 1)))])
                                 (if (and (char? c) (may-join? c (document:token doc q))) (back (fx- q 1)) q)))])
                  (let step ([q start] [state 0])
                    (if (fx= q p)
                        (or (fx= state 0)
                            (let-values ([(done? next) (char-grapheme-step b state)])
                              (and done? (not (fx= next 0)))))
                        (let-values ([(done? next) (char-grapheme-step (document:token doc q) state)])
                          (step (fx+ q 1) next))))))))))

  (define document:text
    (case-lambda
      [(doc) (document:text doc 0)]
      [(doc start)
       (check-document 'document:text doc)
       (document:text doc start (tree-tokens (document-tree doc)))]
      [(doc start end) (document:text doc start end '())]
      [(doc start end atom-texts)
       (check-document 'document:text doc)
       (check-range 'document:text doc start end)
       (check-atom-texts 'document:text doc start end atom-texts)
       (let* ([t (document-tree doc)]
              [s (make-string (fold-left (lambda (n a) (fx+ n (fx- (string-length (cdr a)) 1)))
                                         (fx- (measure-before t end 'characters) (measure-before t start 'characters))
                                         atom-texts))]
              [k 0])
         (walk-items t start
           (lambda (item at sums i)
             (and (fx< at end)
                  (begin
                    (cond
                      [(bytevector? item)
                       (let ([c (chars-ref sums i)])
                         (set! k (decode-into! item
                                   (if (fx< at start) (run-index item (fx- start at) c) 0)
                                   (if (fx> (fx+ at c) end) (run-index item (fx- end at) c) (bytevector-length item))
                                   s k)))]
                      [(atom-item? item)
                       (if (and (pair? atom-texts) (fx= (caar atom-texts) at))
                           (let ([text (cdar atom-texts)])
                             (string-copy! text 0 s k (string-length text))
                             (set! k (fx+ k (string-length text)))
                             (set! atom-texts (cdr atom-texts)))
                           (begin
                             (string-set! s k #\xFFFC)
                             (set! k (fx+ k 1))))])
                    #t))))
         s)]))

  ;; A position that holds no atom would leave the string's length wrong,
  ;; so each is checked before the string is made.
  (define (check-atom-texts who doc start end atom-texts)
    (unless (list? atom-texts)
      (assertion-violation who "not a list of positions and texts" atom-texts))
    (let ([t (document-tree doc)])
      (fold-left
        (lambda (after a)
          (unless (and (pair? a) (fixnum? (car a)) (string? (cdr a)))
            (assertion-violation who "not a position and a text" a))
          (unless (and (fx<= after (car a)) (fx< (car a) end)
                       (let-values ([(item at s i) (item-at t (car a))]) (atom-item? item)))
            (assertion-violation who "not the position of an atom in the range, after the one before" (car a)))
          (fx+ (car a) 1))
        start
        atom-texts)))

  (define (document:for-each-utf8-chunk doc start end proc)
    (define who 'document:for-each-utf8-chunk)
    (check-document who doc)
    (check-range who doc start end)
    (check-procedure who proc)
    (walk-items (document-tree doc) start
      (lambda (item at s i)
        (and (fx< at end)
             (begin
               (cond
                 [(bytevector? item)
                  (let ([c (chars-ref s i)])
                    (proc item
                          (if (fx< at start) (run-index item (fx- start at) c) 0)
                          (if (fx> (fx+ at c) end) (run-index item (fx- end at) c) (bytevector-length item))))]
                 [(atom-item? item)
                  (let ([b (raw-byte item)])
                    (if b
                        (proc (vector-ref single-bytes b) 0 1)
                        (proc object-replacement 0 3)))])
               #t))))
    (void))

  (define-enumeration document:unit (characters bytes utf-16 atoms in-line-atoms) document:units)

  (define (check-unit who unit)
    (unless (memq unit '(characters bytes utf-16 atoms in-line-atoms))
      (assertion-violation who "not a unit" unit)))

  (define (document:offset doc p unit)
    (check-document 'document:offset doc)
    (check-position 'document:offset doc p)
    (check-unit 'document:offset unit)
    (if (eq? unit 'in-line-atoms)
        (in-line-atoms-before (document-tree doc) p)
        (measure-before (document-tree doc) p unit)))

  ;; An atom stands for one character, U+FFFC, three bytes, in a document's
  ;; own measures; its text in the range's text may stand for more.
  (define (document:text-position doc start atom-texts offset unit)
    (define who 'document:text-position)
    (check-document who doc)
    (check-position who doc start)
    (unless (memq unit '(characters bytes))
      (assertion-violation who "not a unit of text, characters or bytes" unit))
    (unless (and (fixnum? offset) (fx>= offset 0))
      (assertion-violation who "not an offset" offset))
    (check-atom-texts who doc start (tree-tokens (document-tree doc)) atom-texts)
    (let ([base (measure-before (document-tree doc) start unit)]
          [standing (if (eq? unit 'bytes) 3 1)])
      (define (size text) (if (eq? unit 'bytes) (bytevector-length (string->utf8 text)) (string-length text)))
      (let loop ([atoms atom-texts] [extra 0])
        (if (null? atoms)
            (document:position doc (fx- (fx+ base offset) extra) unit)
            (let* ([at (caar atoms)] [size (size (cdar atoms))]
                   [from (fx+ (fx- (measure-before (document-tree doc) at unit) base) extra)])
              (cond
                [(fx<= offset from) (document:position doc (fx- (fx+ base offset) extra) unit)]
                [(fx< offset (fx+ from size)) at]
                [else (loop (cdr atoms) (fx+ extra (fx- size standing)))]))))))

  (define (shape-before t p)
    (let down ([t t] [p p] [done 0] [pending 0] [before no-class])
      (let ([s (tree-sums t)])
        (let loop ([i 0] [p p] [done done] [pending pending] [before before])
          (if (fx= p 0)
              (values done pending before)
              (let ([tokens (tokens-ref s i)] [f (first-ref s i)])
                (cond
                  [(and (fx<= tokens p) (fx= f no-class))
                   (loop (fx+ i 1) (fx- p tokens) done (fx+ pending (lead-ref s i)) before)]
                  [(fx<= tokens p)
                   (loop (fx+ i 1) (fx- p tokens)
                         (fx+ done (inner-ref s i) (if (in-line-between? before f) (fx+ pending (lead-ref s i)) 0))
                         (trail-ref s i) (last-ref s i))]
                  [(leaf? t)
                   (let* ([run (tree-child t i)] [b (run-index run p (chars-ref s i))])
                     (values (fx+ done pending) 0 (byte-class (bytevector-u8-ref run (fx- b 1)))))]
                  [else (down (tree-child t i) p done pending before)])))))))

  (define (class-after t p)
    (let down ([t t] [p p])
      (let ([s (tree-sums t)] [n (tree-count t)])
        (let loop ([i 0] [p p])
          (if (fx= i n)
              no-class
              (let ([tokens (tokens-ref s i)])
                (cond
                  [(fx<= tokens p) (loop (fx+ i 1) (fx- p tokens))]
                  [(fx= p 0)
                   (let ([f (first-ref s i)]) (if (fx= f no-class) (loop (fx+ i 1) 0) f))]
                  [(leaf? t)
                   (let ([run (tree-child t i)])
                     (byte-class (bytevector-u8-ref run (run-index run p (chars-ref s i)))))]
                  [else
                   (let ([f (down (tree-child t i) p)]) (if (fx= f no-class) (loop (fx+ i 1) 0) f))])))))))

  (define (in-line-atoms-before t p)
    (let-values ([(done pending before) (shape-before t p)])
      (if (and (fx> pending 0) (in-line-between? before (class-after t p)))
          (fx+ done pending)
          done)))

  ;; The run that holds the atom sought is judged once its last atom is
  ;; passed, and its atoms are adjacent, so the atom is found from the
  ;; run's start. An entry's first and last runs of atoms may go on into
  ;; its neighbours, so only its inner runs are sought inside it.
  (define (in-line-position t offset who)
    (let down ([t t] [at 0] [done 0] [pending 0] [start 0] [before no-class])
      (let ([s (tree-sums t)] [n (tree-count t)])
        (let loop ([i 0] [at at] [done done] [pending pending] [start start] [before before])
          (if (fx= i n)
              (if (and (in-line-between? before no-class) (fx<= offset (fx+ done pending)))
                  (fx+ start (fx- offset done))
                  (assertion-violation who "offset past the end" offset))
              (let ([tokens (tokens-ref s i)] [f (first-ref s i)] [lead (lead-ref s i)]
                    [start (if (fx= pending 0) at start)])
                (if (fx= f no-class)
                    (loop (fx+ i 1) (fx+ at tokens) done (fx+ pending lead) start before)
                    (let ([run (if (in-line-between? before f) (fx+ pending lead) 0)] [inner (inner-ref s i)])
                      (cond
                        [(fx<= offset (fx+ done run)) (fx+ start (fx- offset done))]
                        [(fx<= offset (fx+ done run inner)) (down (tree-child t i) at done pending start before)]
                        [else
                         (let ([trail (trail-ref s i)] [next (fx+ at tokens)])
                           (loop (fx+ i 1) next (fx+ done run inner) trail (fx- next trail) (last-ref s i)))])))))))))

  (define (document:position doc offset unit)
    (define who 'document:position)
    (check-document who doc)
    (check-unit who unit)
    (unless (and (fixnum? offset) (fx>= offset 0))
      (assertion-violation who "not an offset" offset))
    (cond
      [(fx= offset 0) 0]
      [(eq? unit 'in-line-atoms) (in-line-position (document-tree doc) offset who)]
      [else
       (let ([ref (unit-ref unit)])
         (let down ([t (document-tree doc)] [off offset] [pos 0])
           (let ([s (tree-sums t)] [n (tree-count t)])
             (let loop ([i 0] [off off] [pos pos])
               (if (fx= i n)
                   (assertion-violation who "offset past the end" offset)
                   (let ([x (ref s i)])
                     (cond
                       [(fx< x off) (loop (fx+ i 1) (fx- off x) (fx+ pos (tokens-ref s i)))]
                       [(not (leaf? t)) (down (tree-child t i) off pos)]
                       [(bytevector? (tree-child t i))
                        (fx+ pos (run-position (tree-child t i) off (chars-ref s i) unit who offset))]
                       [(fx= off x) (fx+ pos 1)]
                       [else (assertion-violation who "offset inside a character" offset)])))))))]))

  (define (run-position run off chars unit who offset)
    (define (inside) (assertion-violation who "offset inside a character" offset))
    (cond
      [(eq? unit 'characters) off]
      [(eq? unit 'bytes)
       (cond
         [(fx= chars (bytevector-length run)) off]
         [(and (fx< off (bytevector-length run)) (continuation? (bytevector-u8-ref run off))) (inside)]
         [else (count-chars run 0 off)])]
      [else
       (let loop ([i 0] [k 0] [units 0])
         (cond
           [(fx= units off) k]
           [(fx> units off) (inside)]
           [else
            (let ([len (lead-length (bytevector-u8-ref run i))])
              (loop (fx+ i len) (fx+ k 1) (fx+ units (if (fx= len 4) 2 1))))]))]))

  (define (document:line doc p)
    (check-document 'document:line doc)
    (check-position 'document:line doc p)
    (fx+ 1 (measure-before (document-tree doc) p 'newlines)))

  (define (document:line-start doc line)
    (define who 'document:line-start)
    (check-document who doc)
    (unless (and (fixnum? line) (fx>= line 1))
      (assertion-violation who "not a line number" line))
    (if (fx= line 1)
        0
        (let down ([t (document-tree doc)] [k (fx- line 1)] [pos 0])
          (let ([s (tree-sums t)] [n (tree-count t)])
            (let loop ([i 0] [k k] [pos pos])
              (if (fx= i n)
                  (assertion-violation who "the document has fewer lines" line)
                  (let ([newlines (newlines-ref s i)])
                    (cond
                      [(fx< newlines k) (loop (fx+ i 1) (fx- k newlines) (fx+ pos (tokens-ref s i)))]
                      [(leaf? t) (fx+ pos (run-after-newline (tree-child t i) s i k))]
                      [else (down (tree-child t i) k pos)]))))))))

  (define (column-after c column tab-width)
    (if (char=? c #\tab) (fx* tab-width (fx+ (fxquotient column tab-width) 1)) (fx+ column 1)))

  (define (check-tab-width who tab-width)
    (unless (and (fixnum? tab-width) (fx> tab-width 0))
      (assertion-violation who "not a tab width" tab-width)))

  (define (document:column doc p tab-width)
    (check-document 'document:column doc)
    (check-position 'document:column doc p)
    (check-tab-width 'document:column tab-width)
    (let ([text (document:text doc (document:line-start doc (document:line doc p)) p)])
      (let loop ([i 0] [column 0])
        (if (fx= i (string-length text))
            column
            (loop (fx+ i 1) (column-after (string-ref text i) column tab-width))))))

  (define (document:column-position doc line column tab-width)
    (check-document 'document:column-position doc)
    (unless (and (fixnum? column) (fx>= column 0))
      (assertion-violation 'document:column-position "not a column" column))
    (check-tab-width 'document:column-position tab-width)
    (let* ([start (document:line-start doc line)]
           [end (if (fx< line (document:line doc (tree-tokens (document-tree doc))))
                    (fx- (document:line-start doc (fx+ line 1)) 1)
                    (tree-tokens (document-tree doc)))]
           [text (document:text doc start end)])
      (let loop ([i 0] [at 0])
        (cond
          [(fx= i (string-length text)) end]
          [(fx> (column-after (string-ref text i) at tab-width) column)
           (document:position doc (fx+ (measure-before (document-tree doc) start 'characters) i) 'characters)]
          [else (loop (fx+ i 1) (column-after (string-ref text i) at tab-width))]))))

  (define (run-after-newline run s i k)
    (let ([n (bytevector-length run)] [newlines (newlines-ref s i)] [chars (chars-ref s i)])
      (if (fx<= (fx* 2 k) newlines)
          (let loop ([j 0] [k k] [c 0])
            (let* ([x (bytevector-u8-ref run j)] [c (if (continuation? x) c (fx+ c 1))])
              (if (fx= x 10)
                  (if (fx= k 1) c (loop (fx+ j 1) (fx- k 1) c))
                  (loop (fx+ j 1) k c))))
          (let loop ([j (fx- n 1)] [after (fx- newlines k)] [c 0])
            (let ([x (bytevector-u8-ref run j)])
              (if (and (fx= x 10) (fx= after 0))
                  (fx- chars c)
                  (loop (fx- j 1) (if (fx= x 10) (fx- after 1) after) (if (continuation? x) c (fx+ c 1)))))))))

  (define-record-type (node make-node document:node?)
    (sealed #t)
    (fields (immutable document node-document)
            (immutable start node-start)
            (immutable item node-item)))

  (define (check-node who n)
    (unless (document:node? n) (assertion-violation who "not a node" n)))

  (define (document:atom? n)
    (check-node 'document:atom? n)
    (atom-item? (node-item n)))

  (define (document:node-kind n)
    (check-node 'document:node-kind n)
    (item-kind (node-item n)))

  (define document:node-attribute
    (case-lambda
      [(n key) (document:node-attribute n key #f)]
      [(n key default)
       (check-node 'document:node-attribute n)
       (unless (symbol? key) (assertion-violation 'document:node-attribute "not a symbol" key))
       (let ([a (assq key (item-attributes (node-item n)))])
         (if a (copy-out (cdr a)) default))]))

  (define (document:node-start n)
    (check-node 'document:node-start n)
    (node-start n))

  ;; A slice can leave a node open; its end stands for the closing.
  (define (node-closing n)
    (let* ([a (node-start n)] [t (document-tree (node-document n))])
      (or (let ([after (gap-below-after t (fx+ a 1) (fx+ (depth-at t a) 1))])
            (and after (fx- after 1)))
          (tree-tokens t))))

  (define (document:node-end n)
    (check-node 'document:node-end n)
    (if (atom-item? (node-item n))
        (fx+ (node-start n) 1)
        (let ([closing (node-closing n)] [t (document-tree (node-document n))])
          (if (fx= closing (tree-tokens t)) closing (fx+ closing 1)))))

  ;; Atoms next to the node are looked past, so a run of raw bytes inside
  ;; text is in the text's line. Only the nearest other tokens are read,
  ;; so a node among other nodes on a line that holds text further along
  ;; is not in that line.
  (define (document:in-line? n)
    (check-node 'document:in-line? n)
    (let ([t (document-tree (node-document n))])
      (let-values ([(done pending before) (shape-before t (node-start n))])
        (in-line-between? before (class-after t (document:node-end n))))))

  (define (document:enclosing doc p)
    (check-document 'document:enclosing doc)
    (check-position 'document:enclosing doc p)
    (let* ([t (document-tree doc)] [a (last-gap-below t p (depth-at t p))])
      (and a (let-values ([(item at s i) (item-at t a)]) (make-node doc a item)))))

  (define (document:for-each-child n start end proc)
    (define who 'document:for-each-child)
    (check-node who n)
    (let* ([doc (node-document n)] [t (document-tree doc)] [a (node-start n)])
      (check-range who doc start end)
      (check-procedure who proc)
      (unless (atom-item? (node-item n))
        (let ([lo (fxmax start (fx+ a 1))] [hi (fxmin end (node-closing n))])
          (when (fx< lo hi)
            (let* ([depth (fx+ (depth-at t a) 1)]
                   [first (if (fx> (depth-at t lo) depth) (last-gap-below t lo (fx+ depth 1)) lo)])
              (let next ([at first])
                (when (fx< at hi)
                  (let-values ([(item item-start sums i) (item-at t at)])
                    (cond
                      [(bytevector? item)
                       (let ([stop (text-end t at hi)])
                         (proc (document:text doc at stop) at)
                         (next stop))]
                      [(opening? item)
                       (let ([child (make-node doc at item)])
                         (proc child at)
                         (next (fx+ (node-closing child) 1)))]
                      [else
                       (proc (make-node doc at item) at)
                       (next (fx+ at 1))]))))))))
      (void)))

  (define (text-end t p hi)
    (let ([end hi])
      (walk-items t p
        (lambda (item at s i)
          (cond
            [(fx>= at hi) #f]
            [(bytevector? item) #t]
            [else (set! end at) #f])))
      end))

  ;; A slice's own tokens cannot show the nodes it cut at its start; its
  ;; recorded openings stand for them.
  (define (open-ancestors doc p k)
    (let ([t (document-tree doc)])
      (let loop ([p p] [d (depth-at t p)] [k k] [acc '()])
        (if (fx= k 0)
            acc
            (let ([a (last-gap-below t p d)])
              (if a
                  (let-values ([(item at s i) (item-at t a)])
                    (loop a (fx- d 1) (fx- k 1) (cons item acc)))
                  (let* ([outer (document-openings doc)]
                         [still-open (fx+ (length outer) d)])
                    (append (list-head (list-tail outer (fx- still-open k)) k) acc))))))))

  (define (document:slice doc start end)
    (check-document 'document:slice doc)
    (check-range 'document:slice doc start end)
    (let*-values ([(t) (document-tree doc)]
                  [(before rest) (tree-split t start)]
                  [(middle after) (tree-split rest (fx- end start))]
                  [(net low) (tree-depths middle)])
      (make-document middle (fx- low) (fx- net low) (open-ancestors doc start (fx- low)))))

  (define (document:replace doc start end content)
    (define who 'document:replace)
    (check-document who doc)
    (check-document who content)
    (check-range who doc start end)
    (let ([t (document-tree doc)] [c (document-tree content)])
      (define (result tree) (make-document tree (document-open-start doc) (document-open-end doc) (document-openings doc)))
      (cond
        [(and (fx= start end) (empty-tree? c)) doc]
        [(and (leaf? c) (fx<= (tree-count c) 1) (or (empty-tree? c) (bytevector? (tree-child c 0)))
              (let-values ([(tree dt dn db da reshaped?) (edit-run t start end c)]) tree))
         => result]
        [else
         (let*-values ([(before rest) (tree-split t start)]
                       [(middle after) (tree-split rest (fx- end start))]
                       [(tree) (join (join before c) after)]
                       [(net low) (tree-depths tree)])
           (unless (and (fx= (fx- low) (document-open-start doc))
                        (fx= (fx- net low) (document-open-end doc)))
             (assertion-violation who "openings and closings would not match" start end))
           (result tree))])))

  (define (document:repeat doc n)
    (define who 'document:repeat)
    (check-document who doc)
    (unless (and (fixnum? n) (fx>= n 0))
      (assertion-violation who "not a count" n))
    (unless (and (fx= (document-open-start doc) 0) (fx= (document-open-end doc) 0))
      (assertion-violation who "the document leaves a node open"))
    (let loop ([n n] [unit (document-tree doc)] [acc (empty-tree)])
      (if (fx= n 0)
          (make-document acc 0 0 '())
          (loop (fxsrl n 1)
                (if (fx> n 1) (join unit unit) unit)
                (if (fxodd? n) (join acc unit) acc)))))

  (define (cursor-down t path)
    (let ([path (cons (cons t 0) path)])
      (if (leaf? t) path (cursor-down (tree-child t 0) path))))

  (define (cursor-first t)
    (if (empty-tree? t) '() (cursor-down t '())))

  (define (cursor-next path)
    (if (null? path)
        '()
        (let ([t (caar path)] [i (fx+ (cdar path) 1)])
          (cond
            [(fx= i (tree-count t)) (cursor-next (cdr path))]
            [(leaf? t) (cons (cons t i) (cdr path))]
            [else (cursor-down (tree-child t i) (cons (cons t i) (cdr path)))]))))

  (define (cursor-item path)
    (tree-child (caar path) (cdar path)))

  (define (shared-levels x y)
    (let loop ([x x] [y y] [k 0])
      (if (and (pair? x) (pair? y) (fx= (cdar x) 0) (fx= (cdar y) 0) (eq? (caar x) (caar y)))
          (loop (cdr x) (cdr y) (fx+ k 1))
          (and (fx> k 0) k))))

  (define (cursor-past path levels)
    (cursor-next (list-tail path levels)))

  (define (bytes=? a i b j n)
    (let loop ([k 0])
      (or (fx= k n)
          (and (fx= (bytevector-u8-ref a (fx+ i k)) (bytevector-u8-ref b (fx+ j k)))
               (loop (fx+ k 1))))))

  ;; Two documents split the same text into runs at different places, so
  ;; the walk keeps an offset into each one's current run.
  (define (document:same-tokens? a b)
    (define who 'document:same-tokens?)
    (check-document who a)
    (check-document who b)
    (let ([ta (document-tree a)] [tb (document-tree b)])
      (and (fx= (tree-tokens ta) (tree-tokens tb))
           (let loop ([x (cursor-first ta)] [xo 0] [y (cursor-first tb)] [yo 0])
             (cond
               [(null? x) (null? y)]
               [(null? y) #f]
               [(and (fx= xo 0) (fx= yo 0) (shared-levels x y))
                => (lambda (k) (loop (cursor-past x k) 0 (cursor-past y k) 0))]
               [else
                (let ([u (cursor-item x)] [v (cursor-item y)])
                  (cond
                    [(bytevector? u)
                     (and (bytevector? v)
                          (let* ([nu (fx- (bytevector-length u) xo)] [nv (fx- (bytevector-length v) yo)]
                                 [n (fxmin nu nv)])
                            (and (bytes=? u xo v yo n)
                                 (loop (if (fx= n nu) (cursor-next x) x) (if (fx= n nu) 0 (fx+ xo n))
                                       (if (fx= n nv) (cursor-next y) y) (if (fx= n nv) 0 (fx+ yo n))))))]
                    [else (and (not (bytevector? v)) (equal? u v) (loop (cursor-next x) 0 (cursor-next y) 0))]))])))))

  (define (document:freeze doc freeze)
    (check-document 'document:freeze doc)
    (check-procedure 'document:freeze freeze)
    (if (immutable-vector? doc)
        doc
        (freeze (make-document (freeze-tree (document-tree doc) freeze (make-eq-hashtable))
                  (document-open-start doc) (document-open-end doc)
                  (map (lambda (o) (if (immutable-vector? o) o (freeze o))) (document-openings doc))))))

  ;; Children first, so that freeze finds each of them frozen already. A
  ;; repeated document reaches one node or atom through many parents, so
  ;; each is frozen once and its copies stay shared.
  (define (freeze-tree t freeze frozen)
    (define (once v make)
      (or (eq-hashtable-ref frozen v #f)
          (let ([r (make)]) (eq-hashtable-set! frozen v r) r)))
    (if (immutable-vector? t)
        t
        (once t
          (lambda ()
            (let ([n (tree-count t)] [at-leaf? (leaf? t)])
              (define (thawed? c) (and (vector? c) (not (immutable-vector? c))))
              (if (let loop ([i 0]) (and (fx< i n) (or (thawed? (tree-child t i)) (loop (fx+ i 1)))))
                  (let ([v (vector-copy t)])
                    (do ([i 0 (fx+ i 1)]) ((fx= i n))
                      (let ([c (tree-child t i)])
                        (when (thawed? c)
                          (vector-set! v (fx+ i 2)
                            (if at-leaf? (once c (lambda () (freeze c))) (freeze-tree c freeze frozen))))))
                    (freeze v))
                  (freeze t)))))))

  (record-writer (record-type-descriptor node)
    (lambda (n p wr)
      (fprintf p "#<node ~s ~s>" (item-kind (node-item n)) (node-start n)))))
