(library (dabbrev words)
  (export make-expansion-finder search-words)
  (import (chezscheme) (document) (syntax characters))

  ;; Chunks start small, so the first press costs about the distance to
  ;; the nearest expansion, and grow, so a long search takes few of them.
  (define first-chunk 4096)
  (define largest-chunk 262144)

  (define (word-token? doc p in-word?)
    (let ([t (document:token doc p)])
      (and (char? t) (in-word? t))))

  ;; A chunk's edges move out of any word they would cut, so every word
  ;; in a chunk is whole.
  (define (for-each-chunk-before doc in-word? position proc)
    (let loop ([hi position] [size first-chunk])
      (when (fx> hi 0)
        (let ([lo (let back ([p (fxmax 0 (fx- hi size))])
                    (if (and (fx> p 0) (word-token? doc (fx- p 1) in-word?)) (back (fx- p 1)) p))])
          (proc (document:text doc lo hi))
          (loop lo (fxmin largest-chunk (fx* size 2)))))))

  (define (for-each-chunk-after doc in-word? position proc)
    (let ([n (document:length doc)])
      (let loop ([lo position] [size first-chunk])
        (when (fx< lo n)
          (let ([hi (let forward ([p (fxmin n (fx+ lo size))])
                      (if (and (fx< p n) (word-token? doc p in-word?)) (forward (fx+ p 1)) p))])
            (proc (document:text doc lo hi))
            (loop hi (fxmin largest-chunk (fx* size 2))))))))

  (define (for-each-word text in-word? backward? proc)
    (let ([size (string-length text)]
          [in? (lambda (i) (in-word? (string-ref text i)))])
      (if backward?
          (let loop ([j size])
            (when (fx> j 0)
              (if (in? (fx- j 1))
                  (let ([i (let start ([i (fx- j 1)]) (if (and (fx> i 0) (in? (fx- i 1))) (start (fx- i 1)) i))])
                    (proc i j)
                    (loop i))
                  (loop (fx- j 1)))))
          (let loop ([i 0])
            (when (fx< i size)
              (if (in? i)
                  (let ([j (let end ([j (fx+ i 1)]) (if (and (fx< j size) (in? j)) (end (fx+ j 1)) j))])
                    (proc i j)
                    (loop j))
                  (loop (fx+ i 1))))))))

  ;; One finder serves every buffer of a search, so an expansion found in
  ;; one buffer is not offered again from the next. A word becomes a
  ;; string only once it is an expansion, so reading a buffer allocates
  ;; little beyond its chunks.
  (define (make-expansion-finder abbrev fold? fold-distinct?)
    (let ([n (string-length abbrev)] [same? (if fold? char-ci=? char=?)]
          [seen (make-hashtable string-hash string=?)])
      (define (starts-with-abbrev? text i)
        (let loop ([k 0])
          (or (fx= k n)
              (and (same? (string-ref abbrev k) (string-ref text (fx+ i k))) (loop (fx+ k 1))))))
      (lambda (text in-word? backward?)
        (let ([found '()])
          (for-each-word text in-word? backward?
            (lambda (i j)
              (when (and (fx> (fx- j i) n) (starts-with-abbrev? text i))
                (let* ([word (substring text i j)] [key (if fold-distinct? (string-downcase word) word)])
                  (unless (hashtable-contains? seen key)
                    (hashtable-set! seen key #t)
                    (set! found (cons word found)))))))
          (reverse found)))))

  (define (search-words doc characters before after find report)
    (let ([in-word? (word-char-predicate characters)])
      (define (read-chunk backward?)
        (lambda (text)
          (let ([found (find text in-word? backward?)])
            (unless (null? found) (report found)))))
      (for-each-chunk-before doc in-word? before (read-chunk #t))
      (for-each-chunk-after doc in-word? after (read-chunk #f)))))
