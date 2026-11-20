(library (search scanning)
  (export make-subject subject? subject-bytes subject-start subject-end subject-offset subject-position
          scan-text text-doc text-from text-to text->report text-report? report->text compile-pattern next-match scan-pass characters-before next-character piece-size)
  (import (chezscheme) (document) (pcre2))

  (define piece-size 65536)

  (define bytes (document:unit bytes))
  (define characters (document:unit characters))

  ;; atoms-of gives the texts of the atoms in a range, as
  ;; buffers:atom-texts does, so only the atoms of the text read are asked
  ;; for. A flat subject, with no structure inside, counts a position on
  ;; from the last offset asked for, since a scan asks in order.
  (define-record-type (subject new-subject subject?)
    (sealed #t)
    (fields doc start end atoms bytes base flat lo hi (mutable last-offset) (mutable last-count)))

  (define (structure? t) (or (eq? t 'close) (and (document:node? t) (not (document:atom? t)))))

  (define (flat-start doc start end)
    (let ([first (let loop ([p start]) (if (and (fx< p end) (structure? (document:token doc p))) (loop (fx+ p 1)) p))]
          [last (let loop ([p end]) (if (and (fx> p start) (structure? (document:token doc (fx- p 1)))) (loop (fx- p 1)) p))])
      (and (fx<= first last)
           (fx= (fx- last first) (fx- (document:offset doc last characters) (document:offset doc first characters)))
           first)))

  ;; An atom counts as U+FFFC, as the document's byte offsets count it, so
  ;; a subject with no atom reads the bytes in place; a vector, since a
  ;; scan's job hands it back.
  (define (make-text doc from to)
    (let* ([base (document:offset doc from bytes)] [out (make-bytevector (fx- (document:offset doc to bytes) base))] [at 0])
      (document:for-each-utf8-chunk doc from to
        (lambda (bv a z)
          (bytevector-copy! bv a out at (fx- z a))
          (set! at (fx+ at (fx- z a)))))
      (vector doc from to base out)))

  ;; A scan's range and a piece on each side, which holds the subjects of
  ;; its finds and of the scans after it.
  (define (scan-text doc start end seen seen-end)
    (make-text doc (characters-before doc start piece-size seen)
               (document:position doc (fxmin (document:offset doc seen-end characters) (fx+ (document:offset doc end characters) piece-size))
                                  characters)))

  (define (text-doc t) (vector-ref t 0))
  (define (text-from t) (vector-ref t 1))
  (define (text-to t) (vector-ref t 2))
  (define (text-base t) (vector-ref t 3))
  (define (text-bytes t) (vector-ref t 4))

  ;; The job's report holds no document: the main thread has it, and gives
  ;; it back.
  (define (text->report t) (vector 'text (text-from t) (text-to t) (text-base t) (text-bytes t)))

  (define (text-report? v) (and (vector? v) (fx= (vector-length v) 5) (eq? (vector-ref v 0) 'text)))

  (define (report->text doc r) (vector doc (vector-ref r 1) (vector-ref r 2) (vector-ref r 3) (vector-ref r 4)))

  ;; Where no atom stands in the range, which is most text, the subject
  ;; reads text in place when it holds the range, and copies the range
  ;; chunk by chunk otherwise, rather than making a string and encoding it.
  (define (make-subject doc start end atoms-of text)
    (let ([atoms (if (fx< start end) (atoms-of start end) '())])
      (cond
        [(and (null? atoms) text (eq? (text-doc text) doc) (fx<= (text-from text) start) (fx<= end (text-to text)))
         (let ([base (text-base text)])
           (new-subject doc start end atoms (text-bytes text) base (flat-start doc start end)
                        (fx- (document:offset doc start bytes) base) (fx- (document:offset doc end bytes) base)
                        (fx- (document:offset doc start bytes) base) 0))]
        [(null? atoms)
         (let* ([base (document:offset doc start bytes)]
                [out (make-bytevector (fx- (document:offset doc end bytes) base))]
                [at 0])
           (document:for-each-utf8-chunk doc start end
             (lambda (bv from to)
               (bytevector-copy! bv from out at (fx- to from))
               (set! at (fx+ at (fx- to from)))))
           (new-subject doc start end atoms out base (flat-start doc start end) 0 (bytevector-length out) 0 0))]
        [else
         (let ([out (string->utf8 (document:text doc start end atoms))])
           (new-subject doc start end atoms out (document:offset doc start bytes) #f 0 (bytevector-length out) 0 0))])))

  (define (flat-position s off)
    (let ([b (subject-bytes s)])
      (let-values ([(from count) (if (fx>= off (subject-last-offset s))
                                     (values (subject-last-offset s) (subject-last-count s))
                                     (values (subject-lo s) 0))])
        (let loop ([i from] [count count])
          (if (fx< i off)
              (loop (fx+ i 1) (if (fx= (fxand (bytevector-u8-ref b i) #xc0) #x80) count (fx+ count 1)))
              (begin
                (subject-last-offset-set! s off)
                (subject-last-count-set! s count)
                (fx+ (subject-flat s) count)))))))

  (define (subject-offset s p)
    (fold-left
      (lambda (off a)
        (if (fx< (car a) p) (fx+ off (fx- (bytevector-length (string->utf8 (cdr a))) 3)) off))
      (fx- (document:offset (subject-doc s) p bytes) (subject-base s))
      (subject-atoms s)))

  ;; A match covers characters only, so its start goes after a run of
  ;; closings and openings and its end stays before one.
  (define (after-structure doc p)
    (let ([n (document:length doc)])
      (let loop ([p p])
        (if (fx< p n)
            (let ([t (document:token doc p)])
              (if (or (eq? t 'close) (and (document:node? t) (not (document:atom? t))))
                  (loop (fx+ p 1))
                  p))
            p))))

  ;; An offset inside an atom's text gives the atom's position, so a
  ;; match's end there moves past the atom, which the match then covers.
  (define (subject-position s off end?)
    (if (subject-flat s)
        (flat-position s off)
        (structured-position s off end?)))

  (define (structured-position s off end?)
    (let* ([doc (subject-doc s)] [start (subject-start s)]
           [p (if (null? (subject-atoms s))
                  (document:position doc (fx+ (subject-base s) off) bytes)
                  (document:text-position doc start (subject-atoms s) off bytes))]
           [p (fxmax p start)])
      (cond
        [(and end? (pair? (subject-atoms s)) (assv p (subject-atoms s)) (fx< (subject-offset s p) off)) (fx+ p 1)]
        [end? p]
        [else (fxmin (subject-end s) (after-structure doc p))])))

  ;; ^ and $ match at every line's start and end, as Emacs's do.
  (define (compile-pattern pattern caseless?)
    (pcre2-compile pattern (if caseless? (pcre2-options utf ucp multiline caseless) (pcre2-options utf ucp multiline))
                   (pcre2-jit-modes complete partial-hard)))

  (define (characters-before doc p n floor)
    (let* ([at (document:offset doc p characters)] [target (fxmax (document:offset doc floor characters) (fx- at n))])
      (fxmax floor (document:position doc target characters))))

  (define (next-character doc p)
    (let ([n (document:length doc)])
      (let loop ([p (fx+ p 1)])
        (if (and (fx< p n)
                 (let ([t (document:token doc p)])
                   (or (eq? t 'close) (and (document:node? t) (not (document:atom? t))))))
            (loop (fx+ p 1))
            p))))

  ;; An empty match's end is its start, which went past the structure
  ;; before it.
  (define (positions s offsets)
    (let ([v (make-vector (vector-length offsets) #f)])
      (do ([i 0 (fx+ i 1)]) ((fx= i (vector-length offsets)) v)
        (let ([o (vector-ref offsets i)])
          (when o
            (vector-set! v i (if (fx= (fxand i 1) 1)
                                 (fxmax (vector-ref v (fx- i 1)) (subject-position s o #t))
                                 (subject-position s o #f))))))))

  (define (found-offsets found groups)
    (let ([v (make-vector (fx* 2 (fx+ groups 1)) #f)])
      (do ([n 0 (fx+ n 1)]) ((fx> n groups) v)
        (let-values ([(a z) (pcre2-found-group found n)])
          (vector-set! v (fx* 2 n) a)
          (vector-set! v (fx+ (fx* 2 n) 1) z)))))

  (define (next-match doc atoms-of text code position start end seen seen-end piece)
    (define lookbehind (fx+ (pcre2-code-max-lookbehind code) 1))
    (define groups (pcre2-code-group-count code))
    (define (subject-for from to)
      (make-subject doc (characters-before doc from lookbehind seen) to atoms-of text))
    (define (run s from options)
      (pcre2-match code (subject-bytes s) (subject-lo s) (subject-hi s) (subject-offset s from) options))
    (define (options-to to)
      (if (fx< to seen-end) (pcre2-match-options partial-hard no-utf-check) (pcre2-match-options no-utf-check)))
    (define (anchored-at-end from)
      (let* ([s (subject-for from end)]
             [r (run s from (pcre2-match-options anchored no-utf-check))])
        (and (pcre2-found? r) (positions s (found-offsets r groups)))))
    (define (resolve ps size)
      (let loop ([to (fxmin seen-end (fx+ end size))] [size (fx* size 2)])
        (let* ([s (subject-for ps to)] [r (run s ps (options-to to))])
          (cond
            [(pcre2-partial? r)
             (if (fx< (subject-position s (pcre2-partial-start r) #f) end)
                 (loop (fxmin seen-end (fx+ to size)) (fx* size 2))
                 #f)]
            [(pcre2-found? r)
             (let ([found (positions s (found-offsets r groups))])
               (cond
                 [(fx>= (vector-ref found 0) end) #f]
                 [(fx<= (vector-ref found 1) end) found]
                 [(anchored-at-end (vector-ref found 0))]
                 [else (let ([next (next-character doc (vector-ref found 0))])
                         (and (fx< next end) (search next size)))]))]
            [else #f]))))
    (define (search from size)
      (let loop ([from from] [to (fxmin end (fx+ from size))] [size size])
        (let* ([s (subject-for from to)] [r (run s from (options-to to))])
          (cond
            [(pcre2-found? r) (positions s (found-offsets r groups))]
            [(pcre2-partial? r)
             (let ([ps (subject-position s (pcre2-partial-start r) #f)])
               (if (fx< to end)
                   (loop ps (fxmin end (fx+ to size)) (fx* size 2))
                   (resolve ps size)))]
            [(fx< to end) (loop to (fxmin end (fx+ to (fx* size 2))) (fx* size 2))]
            [else #f]))))
    (search position piece))

  (define (scan-pass doc atoms-of text code position to start end seen seen-end visit overlapping?)
    (define lookbehind (fx+ (pcre2-code-max-lookbehind code) 1))
    (define groups (pcre2-code-group-count code))
    (define stop (fxmin end (fx+ to piece-size)))
    (define s (make-subject doc (characters-before doc position lookbehind seen) stop atoms-of text))
    (define b (subject-bytes s))
    (define lo (subject-lo s))
    (define n (subject-hi s))
    (define options
      (if (fx< stop seen-end) (pcre2-match-options partial-hard no-utf-check) (pcre2-match-options no-utf-check)))
    (define (after-empty off)
      (let loop ([off (fx+ off 1)])
        (if (and (fx< off n) (fx= (fxand (bytevector-u8-ref b off) #xc0) #x80)) (loop (fx+ off 1)) off)))
    (let loop ([position position] [off (subject-offset s position)])
      (if (or (fx>= position to) (fx> off n))
          to
          (let ([r (pcre2-match code b lo n off options)])
            (cond
              [(pcre2-found? r)
               (let ([found (positions s (found-offsets r groups))])
                 (cond
                   [(fx>= (vector-ref found 0) to) to]
                   [(not (visit found)) (vector-ref found 1)]
                   [overlapping?
                    (let ([next (next-character doc (vector-ref found 0))])
                      (loop next (subject-offset s next)))]
                   [else
                    (let ([e (pcre2-found-end r)])
                      (if (fx= e (pcre2-found-start r))
                          (loop (next-character doc (vector-ref found 1)) (after-empty e))
                          (loop (vector-ref found 1) e)))]))]
              [(pcre2-partial? r)
               (let ([found (next-match doc atoms-of text code (subject-position s (pcre2-partial-start r) #f) start end seen seen-end piece-size)])
                 (cond
                   [(or (not found) (fx>= (vector-ref found 0) to)) to]
                   [(not (visit found)) (vector-ref found 1)]
                   [else
                    (let ([next (if (or overlapping? (fx= (vector-ref found 0) (vector-ref found 1)))
                                    (next-character doc (vector-ref found 0))
                                    (vector-ref found 1))])
                      (if (fx< next stop)
                          (loop next (subject-offset s next))
                          (scan-pass doc atoms-of text code next to start end seen seen-end visit overlapping?)))]))]
              [else (if (fx< stop to) (scan-pass doc atoms-of text code stop to start end seen seen-end visit overlapping?) to)]))))))
