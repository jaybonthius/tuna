(library (markdown unfinished)
  (export unfinished-source)
  (import (chezscheme) (md4c))

  ;; A code block's text is shown as written, so nothing in it is closed.
  ;; A setext heading's underline ends its text, so what it left open stays.
  (define (unfinished-source text block)
    (let ([leaf (last-leaf block)])
      (and (not (markdown-code-block? leaf))
           (let* ([start (markdown-block-start block)]
                  [source (substring text start (string-length text))]
                  [line (last-line-start source)]
                  [underline (and (fx> line 0) (underline-length source line))])
             (if (and underline (fx>= underline 3) (markdown-heading? leaf))
                 source
                 (let ([source (if (and underline (fx<= underline 2)) (substring source 0 line) source)]
                       [from (let ([at (first-inline-start leaf)]) (and at (fx- at start)))])
                   (if (and from (fx< from (string-length source)) (not (ends-in-blank-line? source from)))
                       (string-append (substring source 0 from) (close-inlines (substring source from (string-length source))))
                       source)))))))

  (define (last-of items) (and (pair? items) (car (last-pair items))))

  (define (last-leaf block)
    (let ([inner (cond
                   [(markdown-quote? block) (last-of (markdown-quote-blocks block))]
                   [(markdown-list? block) (last-of (markdown-list-items block))]
                   [(markdown-item? block) (last-of (markdown-item-blocks block))]
                   [else #f])])
      (if inner (last-leaf inner) block)))

  ;; A table's last line is its last row, and emphasis cannot leave a cell.
  (define (leaf-inlines leaf)
    (cond
      [(markdown-paragraph? leaf) (markdown-paragraph-inlines leaf)]
      [(markdown-heading? leaf) (markdown-heading-inlines leaf)]
      [(markdown-table? leaf)
       (or (last-of (or (last-of (markdown-table-rows leaf)) (markdown-table-header leaf))) '())]
      [else '()]))

  (define (first-inline-start leaf)
    (let loop ([inlines (leaf-inlines leaf)])
      (cond
        [(null? inlines) #f]
        [(markdown-inline-start (car inlines))]
        [else (loop (cdr inlines))])))

  ;; Text that ends with a blank line has ended its paragraph, so what it
  ;; left open stays as written. In a quote, a line of markers alone is
  ;; blank, and a closer written after one could close nothing.
  (define (ends-in-blank-line? source from)
    (let loop ([i (string-length source)] [newlines 0] [marker? #f])
      (cond
        [(fx>= newlines 2) #t]
        [(fx= i from) #f]
        [else
         (case (string-ref source (fx- i 1))
           [(#\newline) (or (and marker? (fx= newlines 0)) (loop (fx- i 1) (fx+ newlines 1) #f))]
           [(#\>) (loop (fx- i 1) newlines #t)]
           [(#\space #\tab #\return) (loop (fx- i 1) newlines marker?)]
           [else #f])])))

  (define (last-line-start source)
    (let loop ([i (string-length source)])
      (if (or (fx= i 0) (char=? (string-ref source (fx- i 1)) #\newline)) i (loop (fx- i 1)))))

  (define (blank? c) (or (char=? c #\space) (char=? c #\tab)))

  ;; A list marker counts only with text after it, so the - of a lone "-"
  ;; is the underline itself.
  (define (skip-markers source i n)
    (define (text-after? j)
      (let loop ([j j]) (and (fx< j n) (or (not (blank? (string-ref source j))) (loop (fx+ j 1))))))
    (define (marker-end i)
      (cond
        [(fx>= i n) #f]
        [(memv (string-ref source i) '(#\- #\* #\+)) (fx+ i 1)]
        [(char-numeric? (string-ref source i))
         (let loop ([j i])
           (cond
             [(and (fx< j n) (char-numeric? (string-ref source j))) (loop (fx+ j 1))]
             [(and (fx< j n) (memv (string-ref source j) '(#\. #\)))) (fx+ j 1)]
             [else #f]))]
        [else #f]))
    (let loop ([i i])
      (cond
        [(and (fx< i n) (or (blank? (string-ref source i)) (char=? (string-ref source i) #\>))) (loop (fx+ i 1))]
        [(let ([j (marker-end i)])
           (and j (fx< j n) (blank? (string-ref source j)) (text-after? j) j))
         => loop]
        [else i])))

  ;; An underline of one or two - or = may be the start of a list item or
  ;; of a longer rule, and would make the line above it a heading; one of
  ;; three or more has made it one.
  (define (underline-length source line)
    (let* ([n (string-length source)] [i (skip-markers source line n)])
      (and (fx< i n)
           (memv (string-ref source i) '(#\- #\=))
           (let ([c (string-ref source i)])
             (let loop ([j i])
               (cond
                 [(and (fx< j n) (char=? (string-ref source j) c)) (loop (fx+ j 1))]
                 [(let blanks ([k j]) (or (fx= k n) (and (blank? (string-ref source k)) (blanks (fx+ k 1)))))
                  (fx- j i)]
                 [else #f]))))))

  ;; A link whose label, address or title is unfinished becomes its label.
  ;; The label may leave emphasis open, so the text is scanned again, but
  ;; the text after the label has arrived, so nothing in it is unfinished.
  (define (close-inlines s)
    (let ([found (scan s #t)])
      (if (unfinished-link? found)
          (close-open (string-append (substring s 0 (unfinished-link-start found)) (unfinished-link-label found)))
          (close-open-state s found))))

  (define (close-open s)
    (close-open-state s (scan s #f)))

  (define (close-open-state s found)
    (let* ([code (open-state-code found)] [runs (open-state-runs found)] [trailing (open-state-trailing-run-start found)]
           [s (remove-brackets (if trailing (substring s 0 trailing) s) (open-state-brackets found))])
      (if (or code (pair? runs))
          (string-append (trim-end s) (if code (make-string code #\`) "")
            (apply string-append (map (lambda (run) (make-string (cdr run) (car run))) runs)))
          s)))

  (define-record-type unfinished-link (sealed #t) (fields start label))

  (define-record-type open-state (sealed #t) (fields code runs trailing-run-start brackets))

  (define (trim-end s)
    (let loop ([n (string-length s)])
      (if (and (fx> n 0) (char-whitespace? (string-ref s (fx- n 1))))
          (loop (fx- n 1))
          (substring s 0 n))))

  (define (remove-brackets s brackets)
    (let-values ([(out done) (open-string-output-port)])
      (let loop ([from 0] [brackets (reverse brackets)])
        (if (null? brackets)
            (begin (put-string out s from (fx- (string-length s) from)) (done))
            (let ([b (car brackets)])
              (put-string out s from (fx- (car b) from))
              (loop (cdr b) (cdr brackets)))))))

  (define (run-length s i c)
    (let loop ([j i])
      (if (and (fx< j (string-length s)) (char=? (string-ref s j) c)) (loop (fx+ j 1)) (fx- j i))))

  (define (punctuation? c)
    (memq (char-general-category c) '(Pc Pd Ps Pe Pi Pf Po Sm Sc Sk So)))

  ;; Open runs are counted by what closes them, so a closer with no opener
  ;; does not search them all.
  (define (scan s unfinished?)
    (define n (string-length s))
    (define counts (make-eqv-hashtable))
    (define (run-key c k) (if (char=? c #\~) k c))
    (define (count! run d) (hashtable-update! counts (run-key (car run) (cdr run)) (lambda (m) (fx+ m d)) 0))
    (define (push run open) (count! run 1) (cons run open))
    (define (opener c k open)
      (and (fx> (hashtable-ref counts (run-key c k) 0) 0)
           (memp (lambda (run) (opener-of? run c k)) open)))
    (define (drop-above! tail open)
      (unless (eq? open tail)
        (count! (car open) -1)
        (drop-above! tail (cdr open))))
    (define (char-before i) (if (fx= i 0) #\space (string-ref s (fx- i 1))))
    (define (char-after i) (if (fx>= i n) #\space (string-ref s i)))
    (define (space? c) (char-whitespace? c))
    (let loop ([i 0] [code #f] [open '()] [brackets '()])
      (if (fx>= i n)
          (make-open-state code open #f brackets)
          (let ([c (string-ref s i)])
            (cond
              [(char=? c #\`)
               (let ([k (run-length s i c)])
                 (cond
                   [(and (not code) (fx= (fx+ i k) n)) (make-open-state #f open i brackets)]
                   [(not code) (loop (fx+ i k) k open brackets)]
                   [(fx= code k) (loop (fx+ i k) #f open brackets)]
                   [else (loop (fx+ i k) code open brackets)]))]
              [code (loop (fx+ i 1) code open brackets)]
              [(char=? c #\\) (loop (fx+ i 2) code open brackets)]
              [(autolink-end s i) => (lambda (end) (loop end code open brackets))]
              [(and (char=? c #\!) (fx< (fx+ i 1) n) (char=? (string-ref s (fx+ i 1)) #\[))
               (loop (fx+ i 2) code open (cons (cons i (fx+ i 2)) brackets))]
              [(char=? c #\[) (loop (fx+ i 1) code open (cons (cons i (fx+ i 1)) brackets))]
              [(and (char=? c #\]) (pair? brackets))
               (let ([b (car brackets)])
                 (define (cut) (make-unfinished-link (car b) (substring s (cdr b) i)))
                 (cond
                   [(fx= (fx+ i 1) n)
                    (if unfinished?
                        (cut)
                        (loop (fx+ i 1) code open (cdr brackets)))]
                   [(char=? (string-ref s (fx+ i 1)) #\()
                    (let ([end (link-tail-end s (fx+ i 2))])
                      (cond
                        [(eq? end 'unfinished)
                         (if unfinished?
                             (cut)
                             (loop (fx+ i 1) code open (cdr brackets)))]
                        [end (loop end code open (cdr brackets))]
                        [else (loop (fx+ i 1) code open (cdr brackets))]))]
                   [else (loop (fx+ i 1) code open (cdr brackets))]))]
              [(memv c '(#\* #\_ #\~))
               (let* ([k (run-length s i c)] [before (char-before i)] [after (char-after (fx+ i k))]
                      [left? (and (not (space? after))
                                  (or (not (punctuation? after)) (space? before) (punctuation? before)))]
                      [right? (and (not (space? before))
                                   (or (not (punctuation? before)) (space? after) (punctuation? after)))]
                      [opens? (if (char=? c #\_) (and left? (or (not right?) (punctuation? before))) left?)]
                      [closes? (if (char=? c #\_) (and right? (or (not left?) (punctuation? after))) right?)]
                      [tail (and closes? (opener c k open))])
                 (cond
                   [tail
                    (drop-above! tail open)
                    (let* ([run (car tail)] [m (fxmin (cdr run) k)]
                           [open (if (fx= m (cdr run))
                                     (begin (count! run -1) (cdr tail))
                                     (cons (cons c (fx- (cdr run) m)) (cdr tail)))])
                      (loop (fx+ i k) code (if (and opens? (fx> k m)) (push (cons c (fx- k m)) open) open) brackets))]
                   [(fx= (fx+ i k) n) (make-open-state #f open i brackets)]
                   [(and opens? (or (not (char=? c #\~)) (fx<= k 2))) (loop (fx+ i k) code (push (cons c k) open) brackets)]
                   [else (loop (fx+ i k) code open brackets)]))]
              [else (loop (fx+ i 1) code open brackets)])))))

  ;; md4c pairs tildes only with a run of the same length.
  (define (opener-of? run c k)
    (and (char=? (car run) c) (or (not (char=? c #\~)) (fx= (cdr run) k))))

  (define (starts-with? s i prefix)
    (let ([m (string-length prefix)])
      (and (fx<= (fx+ i m) (string-length s))
           (let loop ([k 0])
             (or (fx= k m) (and (char=? (string-ref s (fx+ i k)) (string-ref prefix k)) (loop (fx+ k 1))))))))

  (define (ascii-letter? c) (or (char<=? #\a c #\z) (char<=? #\A c #\Z)))

  ;; md4c reads a delimiter inside an address as part of it, so an address
  ;; is skipped whole, as a code span is. A bare address starts where md4c
  ;; looks for one and leaves out the punctuation that ends a sentence.
  (define (autolink-end s i)
    (define n (string-length s))
    (define (address-end j stop? escapes?)
      (cond
        [(or (fx= j n) (char-whitespace? (string-ref s j)) (char<? (string-ref s j) #\space) (stop? (string-ref s j))) j]
        [(and escapes? (char=? (string-ref s j) #\\) (fx< (fx+ j 1) n)) (address-end (fx+ j 2) stop? escapes?)]
        [else (address-end (fx+ j 1) stop? escapes?)]))
    (define (unbalanced-closings j)
      (let loop ([k i] [d 0])
        (if (fx= k j)
            d
            (loop (fx+ k 1) (case (string-ref s k) [(#\() (fx- d 1)] [(#\)) (fx+ d 1)] [else d])))))
    (define (trimmed-end j)
      (let loop ([j j] [excess (unbalanced-closings j)])
        (cond
          [(fx= j i) j]
          [(memv (string-ref s (fx- j 1)) '(#\? #\! #\. #\, #\: #\; #\* #\_ #\~ #\' #\")) (loop (fx- j 1) excess)]
          [(and (char=? (string-ref s (fx- j 1)) #\)) (fx> excess 0)) (loop (fx- j 1) (fx- excess 1))]
          [else j])))
    (define (scheme-end j)
      (and (fx< j n) (ascii-letter? (string-ref s j))
           (let loop ([k (fx+ j 1)])
             (and (fx< k n) (fx<= (fx- k j) 32)
                  (let ([c (string-ref s k)])
                    (cond
                      [(char=? c #\:) (and (fx>= (fx- k j) 2) (fx+ k 1))]
                      [(or (ascii-letter? c) (char<=? #\0 c #\9) (memv c '(#\+ #\. #\-))) (loop (fx+ k 1))]
                      [else #f]))))))
    (define (bare-start? b) (or (char-whitespace? b) (memv b '(#\( #\{ #\[ #\* #\_ #\~))))
    (let ([c (string-ref s i)])
      (cond
        [(char=? c #\<)
         (let ([j (scheme-end (fx+ i 1))])
           (and j
                (let ([end (address-end j (lambda (c) (memv c '(#\< #\>))) #f)])
                  (cond
                    [(fx= end n) n]
                    [(char=? (string-ref s end) #\>) (fx+ end 1)]
                    [else #f]))))]
        [(and (memv c '(#\h #\f #\w))
              (or (fx= i 0) (bare-start? (string-ref s (fx- i 1))))
              (or (starts-with? s i "http://") (starts-with? s i "https://") (starts-with? s i "ftp://") (starts-with? s i "www.")))
         (let ([end (trimmed-end (address-end i (lambda (c) (memv c '(#\< #\[ #\] #\`))) #t))])
           (and (fx> end i) end))]
        [else #f])))

  ;; As md4c reads a link's tail: an address in angle brackets holds no <
  ;; or line break, one without nests parentheses at most 32 deep, and a
  ;; title in parentheses holds no (. Each stops a scan that would
  ;; otherwise run on to a later link's tail.
  (define (link-tail-end s i)
    (define n (string-length s))
    (define (skip-space j) (if (and (fx< j n) (char-whitespace? (string-ref s j))) (skip-space (fx+ j 1)) j))
    (define (delimited j close refused)
      (cond
        [(fx>= j n) 'unfinished]
        [(char=? (string-ref s j) #\\) (delimited (fx+ j 2) close refused)]
        [(char=? (string-ref s j) close) (fx+ j 1)]
        [(memv (string-ref s j) refused) #f]
        [else (delimited (fx+ j 1) close refused)]))
    (define (destination j)
      (if (and (fx< j n) (char=? (string-ref s j) #\<))
          (delimited (fx+ j 1) #\> '(#\< #\newline))
          (let loop ([j j] [depth 0])
            (cond
              [(fx>= j n) 'unfinished]
              [(or (char-whitespace? (string-ref s j)) (char<? (string-ref s j) #\space)) (and (fx= depth 0) j)]
              [(char=? (string-ref s j) #\\) (loop (fx+ j 2) depth)]
              [(char=? (string-ref s j) #\() (and (fx< depth 32) (loop (fx+ j 1) (fx+ depth 1)))]
              [(char=? (string-ref s j) #\)) (if (fx= depth 0) j (loop (fx+ j 1) (fx- depth 1)))]
              [else (loop (fx+ j 1) depth)]))))
    (define (title j)
      (if (fx< j n)
          (case (string-ref s j)
            [(#\") (delimited (fx+ j 1) #\" '())]
            [(#\') (delimited (fx+ j 1) #\' '())]
            [(#\() (delimited (fx+ j 1) #\) '(#\())]
            [else j])
          'unfinished))
    (let* ([j (destination (skip-space i))]
           [j (if (fixnum? j) (let ([k (skip-space j)]) (if (fx> k j) (title k) k)) j)]
           [j (if (fixnum? j) (skip-space j) j)])
      (cond
        [(not (fixnum? j)) j]
        [(fx>= j n) 'unfinished]
        [(char=? (string-ref s j) #\)) (fx+ j 1)]
        [else #f]))))
