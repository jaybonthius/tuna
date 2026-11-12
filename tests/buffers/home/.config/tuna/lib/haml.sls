;; Stands in for the HTML library, which this configuration lacks. It
;; writes what the library writes for the forms views uses: elements with
;; dotted classes and attribute lists, text escaped, and children that are
;; strings, exact integers, html values or lists of them, and when and
;; unless holding markup. Like the library, it refuses a quoted datum as a
;; child.
(library (haml)
  (export haml html? html->string raw-html)
  (import (chezscheme))

  (define-record-type html (fields write))

  (define (raw-html s) (make-html (lambda (p) (put-string p s))))

  (define (plain? s attribute?)
    (let loop ([i 0])
      (or (fx= i (string-length s))
          (let ([c (string-ref s i)])
            (and (not (or (char=? c #\&) (char=? c #\<) (char=? c #\>) (and attribute? (char=? c #\"))))
                 (loop (fx+ i 1)))))))

  (define (escape s p attribute?)
    (if (plain? s attribute?)
        (put-string p s)
        (string-for-each
          (lambda (c)
            (case c
              [(#\&) (put-string p "&amp;")]
              [(#\<) (put-string p "&lt;")]
              [(#\>) (put-string p "&gt;")]
              [(#\") (put-string p (if attribute? "&quot;" "\""))]
              [else (put-char p c)]))
          s)))

  (define (write-child v p)
    (cond
      [(string? v) (escape v p #f)]
      [(html? v) ((html-write v) p)]
      [(pair? v) (write-child (car v) p) (write-child (cdr v) p)]
      [(null? v)]
      [(and (integer? v) (exact? v)) (put-string p (number->string v))]
      [else (assertion-violation 'haml "not html" v)]))

  (define (write-part v p)
    (cond
      [(string? v) (escape v p #t)]
      [(and (integer? v) (exact? v)) (put-string p (number->string v))]
      [else (assertion-violation 'haml "not an attribute value" v)]))

  (define (element open tag classes void? names values children)
    (make-html
      (lambda (p)
        (put-string p open)
        (let ([extra (let loop ([names names] [values values] [acc '()])
                       (cond
                         [(null? names) (reverse acc)]
                         [(and (string=? (car names) "class") (not (member (car values) '(() (#f)))))
                          (loop (cdr names) (cdr values) (cons (car values) acc))]
                         [else (loop (cdr names) (cdr values) acc)]))])
          (unless (and (null? classes) (null? extra))
            (put-string p " class=\"")
            (let loop ([cs (append classes extra)] [first? #t])
              (unless (null? cs)
                (unless first? (put-char p #\space))
                (for-each (lambda (part) (write-part part p)) (if (list? (car cs)) (car cs) (list (car cs))))
                (loop (cdr cs) #f)))
            (put-char p #\")))
        (for-each
          (lambda (name parts)
            (cond
              [(string=? name "class")]
              [(equal? parts '(#f))]
              [(or (null? parts) (equal? parts '(#t))) (put-char p #\space) (put-string p name)]
              [else
               (put-char p #\space) (put-string p name) (put-string p "=\"")
               (for-each (lambda (part) (write-part part p)) parts)
               (put-char p #\")]))
          names values)
        (put-char p #\>)
        (unless void?
          (write-child children p)
          (put-string p "</")
          (put-string p tag)
          (put-char p #\>)))))

  (define (html->string h)
    (call-with-string-output-port (lambda (p) (write-child h p))))

  (define-syntax haml
    (lambda (x)
      (define (element-head? k)
        (and (identifier? k)
             (let ([s (symbol->string (syntax->datum k))])
               (and (> (string-length s) 1) (char=? (string-ref s 0) #\:)))))
      (define (split s)
        (let loop ([cs (string->list s)] [part '()] [parts '()])
          (cond
            [(null? cs) (reverse (cons (list->string (reverse part)) parts))]
            [(char=? (car cs) #\.) (loop (cdr cs) '() (cons (list->string (reverse part)) parts))]
            [else (loop (cdr cs) (cons (car cs) part) parts)])))
      (define (attributes? a)
        (syntax-case a ()
          [() #t]
          [((n . v) ...) (for-all (lambda (n) (or (identifier? n) (string? (syntax->datum n)))) #'(n ...))]
          [_ #f]))
      (define (attribute-name a)
        (syntax-case a ()
          [(n . v) (if (identifier? #'n) (symbol->string (syntax->datum #'n)) (syntax->datum #'n))]))
      (define (attribute-value a)
        (syntax-case a ()
          [(n v ...) #'(list v ...)]))
      (define (form f)
        (syntax-case f ()
          [(k (a ...) child ...)
           (and (element-head? #'k) (attributes? #'(a ...)))
           (build #'k #'(a ...) #'(child ...))]
          [(k child ...)
           (element-head? #'k)
           (build #'k '() #'(child ...))]
          [(k test child ...)
           (and (identifier? #'k) (free-identifier=? #'k #'when))
           #`(if test (list #,@(map form #'(child ...))) '())]
          [(k test child ...)
           (and (identifier? #'k) (free-identifier=? #'k #'unless))
           #`(if test '() (list #,@(map form #'(child ...))))]
          [(k d)
           (and (identifier? #'k) (free-identifier=? #'k #'quote))
           (syntax-violation 'haml "a quoted datum cannot be a child" f)]
          [_ f]))
      (define (build k attributes children)
        (let* ([name (symbol->string (syntax->datum k))]
               [parts (split (substring name 1 (string-length name)))]
               [tag (car parts)])
          #`(element #,(string-append "<" tag) #,tag '#,(cdr parts) #,(and (member tag '("br" "img" "input" "hr")) #t)
                     '#,(map attribute-name attributes) (list #,@(map attribute-value attributes))
                     (list #,@(map form children)))))
      (syntax-case x ()
        [(_ f) (form #'f)]))))
