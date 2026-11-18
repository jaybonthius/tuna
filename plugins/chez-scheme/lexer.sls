(library (chez-scheme lexer)
  (export lex lexeme? lexeme-kind lexeme-start lexeme-end lexeme-depth lexeme-open-ended? lexeme-mismatched?)
  (import (chezscheme))

  (define-record-type lexeme
    (sealed #t)
    (fields kind start end depth open-ended? mismatched?))

  ;; As Chez's reader lists them, so a lexeme ends where its token does;
  ;; a number written with a radix prefix also takes #.
  (define (delimiter? c)
    (case c
      [(#\( #\) #\[ #\] #\" #\; #\# #\{ #\} #\' #\` #\,) #t]
      [else (char-whitespace? c)]))

  (define (line-end? c)
    (case c
      [(#\newline #\return #\x85 #\x2028) #t]
      [else #f]))

  (define (ascii-digit? c) (char<=? #\0 c #\9))

  (define (ascii-letter? c)
    (or (char<=? #\a c #\z) (char<=? #\A c #\Z)))

  (define (hex-digit? c)
    (or (ascii-digit? c) (char<=? #\a c #\f) (char<=? #\A c #\F)))

  (define (octal-digit? c) (char<=? #\0 c #\7))

  ;; Text being edited is often broken, so text the reader refuses still
  ;; becomes lexemes and nothing raises.
  (define (lex s)
    (unless (string? s)
      (assertion-violation 'lex "not a string" s))
    (let ([n (string-length s)] [r6rs? #f])

      (define (at i) (string-ref s i))

      (define (to-delimiter i)
        (if (and (fx< i n) (not (delimiter? (at i)))) (to-delimiter (fx+ i 1)) i))

      (define (number-end i)
        (if (and (fx< i n) (let ([c (at i)]) (or (char=? c #\#) (not (delimiter? c)))))
            (number-end (fx+ i 1))
            i))

      (define (symbol-end i)
        (if (fx= i n)
            (values n #f)
            (let ([c (at i)])
              (cond
                [(char=? c #\\)
                 (cond
                   [(fx= (fx+ i 1) n) (values n #t)]
                   [(char=? (at (fx+ i 1)) #\x)
                    (let hex ([j (fx+ i 2)])
                      (cond
                        [(and (fx< j n) (hex-digit? (at j))) (hex (fx+ j 1))]
                        [(and (fx< j n) (char=? (at j) #\;)) (symbol-end (fx+ j 1))]
                        [else (symbol-end j)]))]
                   [else (symbol-end (fx+ i 2))])]
                [(char=? c #\|)
                 (let bar ([j (fx+ i 1)])
                   (cond
                     [(fx= j n) (values n #t)]
                     [(char=? (at j) #\|) (symbol-end (fx+ j 1))]
                     [else (bar (fx+ j 1))]))]
                [(delimiter? c) (values i #f)]
                [else (symbol-end (fx+ i 1))]))))

      (define (symbol i)
        (let-values ([(end open-ended?) (symbol-end i)])
          (values 'symbol end open-ended? #f)))

      ;; Chez's reader reads a token that starts with a digit, a sign or a
      ;; dot whole, then decides whether it is a number, so 1+ is a symbol.
      (define (number-or-symbol start j)
        (let loop ([j j])
          (define (finish)
            (values (if (string->number (substring s start j)) 'number 'symbol) j #f #f))
          (if (fx= j n)
              (finish)
              (let ([c (at j)])
                (cond
                  [(or (ascii-digit? c) (ascii-letter? c) (memv c '(#\- #\+ #\. #\/ #\@ #\|)))
                   (loop (fx+ j 1))]
                  [(char=? c #\#) (if r6rs? (finish) (loop (fx+ j 1)))]
                  [(delimiter? c) (finish)]
                  [else (symbol j)])))))

      (define (junk i) (values 'symbol (to-delimiter i) #f #f))

      (define (line-comment i)
        (let loop ([j i])
          (if (or (fx= j n) (line-end? (at j)))
              (values 'line-comment j #t #f)
              (loop (fx+ j 1)))))

      (define (string-lexeme i)
        (let loop ([j i])
          (cond
            [(fx= j n) (values 'string n #t #f)]
            [(char=? (at j) #\") (values 'string (fx+ j 1) #f #f)]
            [(char=? (at j) #\\) (if (fx= (fx+ j 1) n) (values 'string n #t #f) (loop (fx+ j 2)))]
            [else (loop (fx+ j 1))])))

      (define (block-comment i)
        (let loop ([j i] [depth 0])
          (cond
            [(fx>= (fx+ j 1) n) (values 'block-comment n #t #f)]
            [(and (char=? (at j) #\|) (char=? (at (fx+ j 1)) #\#))
             (if (fx= depth 0)
                 (values 'block-comment (fx+ j 2) #f #f)
                 (loop (fx+ j 2) (fx- depth 1)))]
            [(and (char=? (at j) #\#) (char=? (at (fx+ j 1)) #\|))
             (loop (fx+ j 2) (fx+ depth 1))]
            [else (loop (fx+ j 1) depth)])))

      (define (character i)
        (if (fx= i n)
            (values 'character n #t #f)
            (let ([c (at i)] [next (and (fx< (fx+ i 1) n) (at (fx+ i 1)))])
              (cond
                [(and next (char=? c #\x) (hex-digit? next))
                 (values 'character (to-delimiter (fx+ i 1)) #f #f)]
                [(and next (ascii-letter? c) (ascii-letter? next))
                 (values 'character (to-delimiter (fx+ i 1)) #f #f)]
                [(and next (octal-digit? c) (octal-digit? next))
                 (values 'character (fxmin n (fx+ i 3)) #f #f)]
                [else (values 'character (fx+ i 1) #f #f)]))))

      (define (vector-open name-start)
        (let ([name-end (to-delimiter name-start)])
          (if (and (fx< name-end n)
                   (char=? (at name-end) #\()
                   (member (substring s name-start name-end) '("fx" "fl" "u8" "s")))
              (values 'open (fx+ name-end 1) #f 'paren)
              (values 'symbol name-end #f #f))))

      (define (gensym-lexeme i)
        (let loop ([j i] [bar? #f])
          (cond
            [(fx= j n) (values 'symbol n #t #f)]
            [bar? (loop (fx+ j 1) (not (char=? (at j) #\|)))]
            [(char=? (at j) #\|) (loop (fx+ j 1) #t)]
            [(char=? (at j) #\\) (loop (fxmin n (fx+ j 2)) #f)]
            [(char=? (at j) #\}) (values 'symbol (fx+ j 1) #f #f)]
            [else (loop (fx+ j 1) #f)])))

      (define (hash-number i)
        (let ([k (let digits ([k i]) (if (and (fx< k n) (ascii-digit? (at k))) (digits (fx+ k 1)) k))])
          (if (fx= k n)
              (values 'symbol n #f #f)
              (case (at k)
                [(#\() (values 'open (fx+ k 1) #f 'paren)]
                [(#\r #\R) (values 'number (number-end (fx+ k 1)) #f #f)]
                [(#\#) (values 'object (fx+ k 1) #f #f)]
                [(#\=) (values 'prefix (fx+ k 1) #f #f)]
                [(#\v) (vector-open (fx+ k 1))]
                [(#\%) (if (member (substring s i k) '("2" "3")) (symbol (fx+ k 1)) (junk k))]
                [else (junk k)]))))

      (define undelimited-directives '("r6rs" "fold-case" "no-fold-case" "chezscheme"))

      ;; The four directives above need no delimiter after them, as in the
      ;; reader, so #!r6rs(a) is the directive and then a list.
      (define (hash-bang i)
        (let loop ([k 0] [names undelimited-directives])
          (cond
            [(find (lambda (name) (fx= (string-length name) k)) names)
             => (lambda (name)
                  (cond
                    [(string=? name "r6rs") (set! r6rs? #t)]
                    [(string=? name "chezscheme") (set! r6rs? #f)])
                  (values 'directive (fx+ i k) #f #f))]
            [(fx= (fx+ i k) n) (values 'directive n #f #f)]
            [else
             (let* ([c (at (fx+ i k))]
                    [names (filter (lambda (name) (char=? (string-ref name k) c)) names)])
               (if (null? names)
                   (let ([end (to-delimiter (fx+ i k))])
                     (values (if (member (substring s i end) '("eof" "bwp" "base-rtd")) 'object 'directive)
                             end #f #f))
                   (loop (fx+ k 1) names)))])))

      (define (hash i)
        (let ([j (fx+ i 1)])
          (if (fx= j n)
              (values 'symbol n #f #f)
              (case (at j)
                [(#\() (values 'open (fx+ j 1) #f 'paren)]
                [(#\[) (values 'open (fx+ j 1) #f 'bracket)]
                [(#\' #\` #\&) (values 'prefix (fx+ j 1) #f #f)]
                [(#\,) (values 'prefix (if (and (fx< (fx+ j 1) n) (char=? (at (fx+ j 1)) #\@)) (fx+ j 2) (fx+ j 1)) #f #f)]
                [(#\@) (values 'object (fx+ j 1) #f #f)]
                [(#\\) (character (fx+ j 1))]
                [(#\f #\F #\t #\T)
                 (let ([k (fx+ j 1)])
                   (values 'boolean (if (and (fx< k n) (char-alphabetic? (at k))) (to-delimiter k) k) #f #f))]
                [(#\!)
                 (if (and (fx= i 0) (fx< (fx+ j 1) n) (memv (at (fx+ j 1)) '(#\space #\/)))
                     (let-values ([(kind end open-ended? shape) (line-comment j)])
                       (values 'directive end #f #f))
                     (hash-bang (fx+ j 1)))]
                [(#\;)
                 (let-values ([(end open-ended?) (datum-end (fx+ j 1) (fx+ j 1))])
                   (values 'datum-comment end open-ended? #f))]
                [(#\|) (block-comment (fx+ j 1))]
                [(#\{) (gensym-lexeme (fx+ j 1))]
                [(#\% #\:) (symbol (fx+ j 1))]
                [(#\v) (vector-open (fx+ j 1))]
                [(#\x #\X #\o #\O #\b #\B #\d #\D #\i #\I #\e #\E) (values 'number (number-end (fx+ j 1)) #f #f)]
                [else (if (ascii-digit? (at j)) (hash-number j) (junk j))]))))

      (define (scan i)
        (if (fx= i n)
            (values #f n n #f #f)
            (let ([c (at i)])
              (define (from-here proc)
                (let-values ([(kind end open-ended? shape) (proc)])
                  (values kind i end open-ended? shape)))
              (case c
                [(#\() (values 'open i (fx+ i 1) #f 'paren)]
                [(#\)) (values 'close i (fx+ i 1) #f 'paren)]
                [(#\[) (values 'open i (fx+ i 1) #f 'bracket)]
                [(#\]) (values 'close i (fx+ i 1) #f 'bracket)]
                [(#\' #\`) (values 'prefix i (fx+ i 1) #f #f)]
                [(#\,)
                 (values 'prefix i (if (and (fx< (fx+ i 1) n) (char=? (at (fx+ i 1)) #\@)) (fx+ i 2) (fx+ i 1)) #f #f)]
                [(#\;) (from-here (lambda () (line-comment (fx+ i 1))))]
                [(#\") (from-here (lambda () (string-lexeme (fx+ i 1))))]
                [(#\#) (from-here (lambda () (hash i)))]
                [(#\{ #\}) (values 'symbol i (fx+ i 1) #f #f)]
                [(#\- #\+)
                 (let ([j (fx+ i 1)])
                   (cond
                     [(or (fx= j n) (delimiter? (at j))) (values 'symbol i j #f #f)]
                     [(and (char=? c #\-) (char=? (at j) #\>)) (from-here (lambda () (symbol j)))]
                     [else (from-here (lambda () (number-or-symbol i j)))]))]
                [(#\.)
                 (let ([j (fx+ i 1)])
                   (cond
                     [(or (fx= j n) (delimiter? (at j))) (values 'dot i j #f #f)]
                     [(char=? (at j) #\.)
                      (let ([k (fx+ j 1)])
                        (cond
                          [(fx= k n) (values 'symbol i n #f #f)]
                          [(char=? (at k) #\.) (from-here (lambda () (symbol (fx+ k 1))))]
                          [else (from-here (lambda () (symbol k)))]))]
                     [else (from-here (lambda () (number-or-symbol i j)))]))]
                [else
                 (cond
                   [(char-whitespace? c) (scan (fx+ i 1))]
                   [(ascii-digit? c) (from-here (lambda () (number-or-symbol i (fx+ i 1))))]
                   [else (from-here (lambda () (symbol i)))])]))))

      ;; The reader skips comments and other datum comments before the
      ;; datum a #; skips, and that datum's prefixes with it.
      (define (datum-end i last-end)
        (let-values ([(kind start end open-ended? shape) (scan i)])
          (case kind
            [(#f) (values n #t)]
            [(line-comment block-comment directive datum-comment)
             (if (or (fx= end n) (and open-ended? (not (eq? kind 'line-comment))))
                 (values n #t)
                 (datum-end end end))]
            [(prefix) (datum-end end end)]
            [(open) (list-end end)]
            [(close) (values last-end #f)]
            [else (values end open-ended?)])))

      (define (list-end i)
        (let loop ([i i] [depth 1])
          (let-values ([(kind start end open-ended? shape) (scan i)])
            (case kind
              [(#f) (values n #t)]
              [(open) (loop end (fx+ depth 1))]
              [(close) (if (fx= depth 1) (values end #f) (loop end (fx- depth 1)))]
              [else (if (and open-ended? (fx= end n)) (values n #t) (loop end depth))]))))

      (let loop ([i 0] [shapes '()] [depth 0] [lexemes '()])
        (let-values ([(kind start end open-ended? shape) (scan i)])
          (case kind
            [(#f) (list->vector (reverse lexemes))]
            [(open)
             (let ([depth (fx+ depth 1)])
               (loop end (cons shape shapes) depth
                     (cons (make-lexeme kind start end depth #f #f) lexemes)))]
            [(close)
             (if (null? shapes)
                 (loop end shapes 0 (cons (make-lexeme kind start end 0 #f #f) lexemes))
                 (loop end (cdr shapes) (fx- depth 1)
                       (cons (make-lexeme kind start end depth #f (not (eq? shape (car shapes)))) lexemes)))]
            [else
             (loop end shapes depth (cons (make-lexeme kind start end depth open-ended? #f) lexemes))]))))))
