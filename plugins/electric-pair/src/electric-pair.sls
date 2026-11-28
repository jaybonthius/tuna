#!tuna
(import (syntax) (indentation) (editing) (buffers) (document) (views) (modes) (commands) (options))

(modes:define-minor-mode mode
  "Whether typing an opening bracket or quote inserts its closing one, typing a closing one moves over it, and DEL deletes an empty pair.")

(options:define-option pairs (list (cons #\" #\") (cons #\x2018 #\x2019) (cons #\x201C #\x201D))
  (lambda (v) (and (list? v) (for-all (lambda (p) (and (pair? p) (char? (car p)) (char? (cdr p)))) v)))
  "Pairs that need no lexer: each pairs by its characters where the lexer gives the opening character no meaning of its own, and everywhere inside strings and comments.")

(define (%class? lexeme class) (eq? (syntax:lexeme-class lexeme) class))

(define (%bracket-pairs b) (syntax:mode-bracket-pairs (modes:major-mode b)))

(define (%acts? b)
  (and b (syntax:lexer (modes:major-mode b)) (buffers:with-buffer b (mode)) #t))

(define (%text doc start end) (buffers:text-between doc start end))

(define (%text-matches text pairs)
  (let ([n (string-length text)] [matched (make-vector (string-length text) #f)])
    (let loop ([i 0] [open '()])
      (when (fx< i n)
        (let ([c (string-ref text i)])
          (cond
            [(assv c pairs) (loop (fx+ i 1) (cons i open))]
            [(and (exists (lambda (p) (char=? (cdr p) c)) pairs) (pair? open))
             (vector-set! matched (car open) #t)
             (vector-set! matched i #t)
             (loop (fx+ i 1) (cdr open))]
            [else (loop (fx+ i 1) open)]))))
    matched))

(define (%text-unmatched-closer-after? text at pairs)
  (let ([matched (%text-matches text pairs)])
    (let loop ([i at])
      (and (fx< i (string-length text))
           (or (and (not (vector-ref matched i)) (exists (lambda (p) (char=? (cdr p) (string-ref text i))) pairs))
               (loop (fx+ i 1)))))))

(define (%unmatched-closer-after? b p)
  (let ([in (syntax:string-or-comment-at b p)])
    (if in
        (let ([start (syntax:lexeme-start in)])
          (%text-unmatched-closer-after? (%text (buffers:document b) start (syntax:lexeme-end in)) (fx- p start) (%bracket-pairs b)))
        (exists (lambda (l) (and (%class? l (syntax:class close)) (fx>= (syntax:lexeme-start l) p) (fx= (syntax:lexeme-depth l) 0)))
                (syntax:lexemes b p (document:length (buffers:document b)))))))

(define (pair-typed? buffer position char)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'electric-pair:pair-typed? "not a buffer" buffer))
  (unless (and (fixnum? position) (fx<= 0 position (document:length (buffers:document buffer))))
    (assertion-violation 'electric-pair:pair-typed? "not a position in the buffer" position))
  (unless (char? char)
    (assertion-violation 'electric-pair:pair-typed? "not a character" char))
  (or (not (assv char (%bracket-pairs buffer)))
      (not (%unmatched-closer-after? buffer position))))

(define (%typed-lexeme b p char)
  (let ([l (syntax:inserted-lexeme b p (string char))])
    (values l (or (not l) (fx= (syntax:lexeme-start l) p)))))

(define (%reads-as? b p char class)
  (let-values ([(l own?) (%typed-lexeme b p char)])
    (and l own? (%class? l class))))

(define (%own-lexeme? b p char)
  (let-values ([(l own?) (%typed-lexeme b p char)]) own?))

(define (%ends-in-open-string? b doc)
  (let ([v ((syntax:lexer (modes:major-mode b)) doc)])
    (and (fx> (vector-length v) 0)
         (let ([last (vector-ref v (fx- (vector-length v) 1))])
           (and (%class? last (syntax:class string)) (syntax:lexeme-open-ended? last))))))

(define (%quote-pairs? b p char)
  (let ([doc (buffers:document b)])
    (and (not (%ends-in-open-string? b doc))
         (%ends-in-open-string? b (document:replace doc p p (document:from-datum (string char)))))))

(define (%blank? t) (memv t '(#\space #\tab #\newline)))

(define (%skip-blanks doc p)
  (let ([last (fx- (document:length doc) 1)])
    (let loop ([q p]) (if (and (fx< q last) (%blank? (document:token doc q))) (loop (fx+ q 1)) q))))

(define (%closer-to-skip b p char)
  (let* ([doc (buffers:document b)] [openings (syntax:openings b p)])
    (and (pair? openings)
         (let ([closes (map (lambda (o) (syntax:match b o)) openings)])
           (and (for-all values closes)
                (let ([close (car (last-pair closes))])
                  (and (fx= (syntax:lexeme-start close) (%skip-blanks doc p))
                       (eqv? (document:token doc (syntax:lexeme-start close)) char)
                       (syntax:lexeme-end close))))))))

(define (%text-closer-to-skip text at char pairs)
  (let ([matched (%text-matches text pairs)] [n (string-length text)])
    (let ([q (let loop ([q at]) (if (and (fx< q n) (%blank? (string-ref text q))) (loop (fx+ q 1)) q))])
      (and (fx< q n) (char=? (string-ref text q) char)
           (let loop ([i 0] [open '()])
             (cond
               [(fx= i at) (and (for-all (lambda (o) (vector-ref matched o)) open) (fx+ q 1))]
               [(assv (string-ref text i) pairs) (loop (fx+ i 1) (cons i open))]
               [(and (exists (lambda (p) (char=? (cdr p) (string-ref text i))) pairs) (pair? open)) (loop (fx+ i 1) (cdr open))]
               [else (loop (fx+ i 1) open)]))))))

(define (%count text char)
  (let loop ([i 0] [k 0])
    (if (fx= i (string-length text)) k (loop (fx+ i 1) (if (char=? (string-ref text i) char) (fx+ k 1) k)))))

(define (%pair-text b p)
  (let ([doc (buffers:document b)] [in (syntax:string-or-comment-at b p)])
    (if in
        (%text doc (syntax:lexeme-start in) (syntax:lexeme-end in))
        (let loop ([ls (syntax:lexemes b 0 (document:length doc))] [from 0] [acc '()])
          (cond
            [(null? ls) (apply string-append (reverse (cons (%text doc from (fx- (document:length doc) 1)) acc)))]
            [(or (%class? (car ls) (syntax:class string)) (%class? (car ls) (syntax:class comment)))
             (loop (cdr ls) (syntax:lexeme-end (car ls)) (cons (%text doc from (fxmax from (syntax:lexeme-start (car ls)))) acc))]
            [else (loop (cdr ls) from acc)])))))

(define (%pair-of-pairs-pairs? b p char closer)
  (or (not (char=? char closer))
      (even? (%count (%pair-text b p) char))))

(define (%plan b p m char n)
  (let* ([doc (buffers:document b)]
         [brackets (%bracket-pairs b)]
         [in (syntax:string-or-comment-at b p)]
         [opener (assv char brackets)]
         [closer-of (find (lambda (pr) (char=? (cdr pr) char)) brackets)]
         [text-pair (assv char (pairs))]
         [text-closer (find (lambda (pr) (char=? (cdr pr) char)) (pairs))]
         [string-start? (and (not in) (%reads-as? b p char (syntax:class string)))]
         [pairing (lambda (close) (and (pair-typed? b p char) (list 'insert char close)))])
    (cond
      [(and m (not (fx= m p)))
       (let ([start (fxmin p m)] [end (fxmax p m)])
         (cond
           [(and opener (not in)) (list 'wrap start end char (cdr opener) #f)]
           [(and closer-of (not in)) (list 'wrap start end (car closer-of) char #t)]
           [string-start? (list 'wrap start end char char #f)]
           [text-pair (list 'wrap start end char (cdr text-pair) #f)]
           [else #f]))]
      [(and in (%class? in (syntax:class string))
            (let ([last (fx- (syntax:lexeme-end in) 1)])
              (and (not (syntax:lexeme-open-ended? in)) (eqv? (document:token doc last) char))))
       (if (fx= p (fx- (syntax:lexeme-end in) 1))
           (list 'skip (syntax:lexeme-end in))
           (and (%quote-pairs? b p char) (pairing char)))]
      [in
       (let* ([start (syntax:lexeme-start in)] [text (%text doc start (syntax:lexeme-end in))] [at (fx- p start)])
         (cond
           [opener (pairing (cdr opener))]
           [closer-of
            (let ([q (%text-closer-to-skip text at char brackets)])
              (and q (list 'skip (fx+ start q))))]
           [(and text-closer (eqv? (document:token doc p) char) (not text-pair)) (list 'skip (fx+ p 1))]
           [(and text-pair (%pair-of-pairs-pairs? b p char (cdr text-pair))) (pairing (cdr text-pair))]
           [else #f]))]
      [(and opener (let-values ([(l own?) (%typed-lexeme b p char)]) (and l (%class? l (syntax:class open)))))
       (pairing (cdr opener))]
      [closer-of (let ([q (%closer-to-skip b p char)]) (and q (list 'skip q)))]
      [string-start? (and (%quote-pairs? b p char) (pairing char))]
      [(and text-closer (not text-pair) (eqv? (document:token doc p) char)) (list 'skip (fx+ p 1))]
      [(and text-pair (%own-lexeme? b p char) (%pair-of-pairs-pairs? b p char (cdr text-pair))) (pairing (cdr text-pair))]
      [else #f])))

(define (%act! view b c p plan char n)
  (case (car plan)
    [(insert)
     (let ([open (make-string n (cadr plan))] [close (make-string n (caddr plan))])
       (buffers:replace! b p p (string-append open close))
       (editing:place-cursor! view c (fx+ p n) #f))]
    [(skip) (editing:place-cursor! view c (cadr plan) #f)]
    [(wrap)
     (apply (lambda (start end open close after-close?)
              (buffers:replace! b end end (string close))
              (buffers:replace! b start start (string open))
              (editing:place-cursor! view c (if after-close? (fx+ end 2) (fx+ start 1)) #f))
            (cdr plan))]
    [else
     (buffers:replace! b p p (make-string n char))
     (editing:place-cursor! view c (fx+ p n) #f)]))

(define (%self-insert next n char)
  (let* ([view (views:current)] [b (and view (views:buffer view))])
    (if (not (and (%acts? b) (char? char) (and (integer? n) (exact? n) (> n 0))))
        (next n char)
        (let ([plans (map (lambda (c) (%plan b (views:cursor-point c) (views:cursor-mark c) char n)) (views:cursors view))])
          (if (not (exists values plans))
              (next n char)
              (editing:for-each-cursor view
                (lambda (c p m)
                  (let ([plan (%plan b p m char n)])
                    (if plan
                        (%act! view b c p plan char n)
                        (%act! view b c p '(plain) char n))))))))))

(define (%opener-closer b char)
  (or (assv char (%bracket-pairs b)) (assv char (pairs))))

(define (%empty-pair? b p)
  (let* ([doc (buffers:document b)])
    (and (fx> p 0) (fx< p (fx- (document:length doc) 1))
         (let ([before (document:token doc (fx- p 1))] [after (document:token doc p)])
           (and (char? before) (char? after)
                (let ([pr (%opener-closer b before)])
                  (and pr (char=? (cdr pr) after))))))))

(define (%delete-backward-char next n)
  (let* ([view (views:current)] [b (and view (views:buffer view))])
    (when (and (%acts? b) (eqv? n 1))
      (let ([regions? (or (editing:delete-selection) (editing:delete-active-region))])
        (editing:for-each-cursor view
          (lambda (c p m)
            (when (and (not (and regions? m (not (fx= m p)))) (%empty-pair? b p))
              (buffers:replace! b p (fx+ p 1) ""))))))
    (next n)))

(define (%between-pair? b p)
  (let ([doc (buffers:document b)])
    (and (fx< p (fx- (document:length doc) 1))
         (not (syntax:string-or-comment-at b p))
         (let ([after (document:token doc p)]
               [before (let loop ([q p]) (if (and (fx> q 0) (memv (document:token doc (fx- q 1)) '(#\space #\tab))) (loop (fx- q 1)) q))])
           (and (fx> before 0) (char? after)
                (let ([open (document:token doc (fx- before 1))])
                  (and (char? open)
                       (let ([pr (assv open (%bracket-pairs b))])
                         (and pr (char=? (cdr pr) after))))))))))

(define (%newline next n)
  (let* ([view (views:current)] [b (and view (views:buffer view))])
    (if (and (%acts? b) (eq? (commands:this-command) editing:newline) (and (integer? n) (exact? n) (> n 0)))
        (let ([closers (filter values
                         (map (lambda (c) (and (%between-pair? b (views:cursor-point c)) (buffers:anchor-after b (views:cursor-point c))))
                              (views:cursors view)))])
          (next n)
          (for-each
            (lambda (a)
              (let* ([q (buffers:anchor-position a)]
                     [here (filter (lambda (c) (fx= (views:cursor-point c) q)) (views:cursors view))])
                (buffers:replace! b q q "\n")
                (for-each (lambda (c) (editing:place-cursor! view c q #f)) here)
                (indentation:line! b (fx+ q 1))))
            closers))
        (next n))))

(advice-add! editing:self-insert %self-insert)
(advice-add! editing:delete-backward-char %delete-backward-char)
(advice-add! editing:newline %newline)
