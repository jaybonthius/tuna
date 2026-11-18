(library (lexer-check)
  (export check-text check-files scheme-files)
  (import (chezscheme) (chez-scheme lexer))

  (define (expected-kind type value)
    (case type
      [(lparen lbrack record-brack vparen vnparen vfxparen vflparen vu8paren vsparen
        vfxnparen vflnparen vu8nparen vsnparen) 'open]
      [(rparen rbrack) 'close]
      [(quote box mark) 'prefix]
      [(insert fasl) 'object]
      [(dot) 'dot]
      [(atomic)
       (cond
         [(or (symbol? value) (pair? value)) 'symbol]
         [(number? value) 'number]
         [(boolean? value) 'boolean]
         [(char? value) 'character]
         [(string? value) 'string]
         [else 'object])]
      [else type]))

  ;; Chez's load skips a first line starting #! and a space or slash, as
  ;; the lexer makes it one directive; read-token alone does not.
  (define (skip-script-line! ip text)
    (let ([n (string-length text)])
      (when (and (>= n 3) (char=? (string-ref text 0) #\#) (char=? (string-ref text 1) #\!)
                 (memv (string-ref text 2) '(#\space #\/)))
        (let loop ([i 0])
          (if (or (= i n) (char=? (string-ref text i) #\newline))
              (set-port-position! ip i)
              (loop (+ i 1)))))))

  (define (check-text text)
    (let ([lexemes (make-eqv-hashtable)] [ip (open-string-input-port text)]
          [count 0] [disagreements '()])
      (define (disagree! what)
        (set! disagreements (cons what disagreements)))
      (define (next)
        (let ([before (port-position ip)])
          (guard (c [(lexical-violation? c)
                     (when (= (port-position ip) before)
                       (set-port-position! ip (+ before 1)))
                     (next)])
            (let-values ([(type value start end) (read-token ip)])
              (values type value start end)))))
      (define (datum-end)
        (let-values ([(type value start end) (next)])
          (set! count (+ count 1))
          (case type
            [(eof) end]
            [(quote box mark)
             (if (eq? value 'datum-comment)
                 (begin (datum-end) (datum-end))
                 (datum-end))]
            [(lparen lbrack record-brack vparen vnparen vfxparen vflparen vu8paren vsparen
              vfxnparen vflnparen vu8nparen vsnparen)
             (let loop ([depth 1])
               (let-values ([(type value start end) (next)])
                 (set! count (+ count 1))
                 (case type
                   [(eof) end]
                   [(rparen rbrack) (if (= depth 1) end (loop (- depth 1)))]
                   [(lparen lbrack record-brack vparen vnparen vfxparen vflparen vu8paren vsparen
                     vfxnparen vflnparen vu8nparen vsnparen)
                    (loop (+ depth 1))]
                   [else (loop depth)])))]
            [else end])))
      (skip-script-line! ip text)
      (vector-for-each (lambda (t) (hashtable-set! lexemes (lexeme-start t) t)) (lex text))
      (let loop ()
        (let-values ([(type value start end) (next)])
          (unless (eq? type 'eof)
            (set! count (+ count 1))
            (let ([t (hashtable-ref lexemes start #f)])
              (cond
                [(and (eq? type 'quote) (eq? value 'datum-comment))
                 (let ([reader-end (datum-end)])
                   (unless (and t (eq? (lexeme-kind t) 'datum-comment) (= (lexeme-end t) reader-end))
                     (disagree! (list 'datum-comment start reader-end
                                      (and t (list (lexeme-kind t) (lexeme-start t) (lexeme-end t)))))))]
                [(not (and t (eq? (lexeme-kind t) (expected-kind type value)) (= (lexeme-end t) end)))
                 (disagree! (list (expected-kind type value) start end
                                  (and t (list (lexeme-kind t) (lexeme-start t) (lexeme-end t)))))]))
            (loop))))
      (values count (reverse disagreements))))

  (define (read-text path)
    (call-with-port (open-file-input-port path (file-options) (buffer-mode block) (native-transcoder))
      (lambda (p)
        (let ([text (get-string-all p)])
          (if (eof-object? text) "" text)))))

  (define (check-files paths)
    (let loop ([paths paths] [files 0] [count 0] [disagreements '()])
      (if (null? paths)
          (values files count (reverse disagreements))
          (let-values ([(n found) (check-text (read-text (car paths)))])
            (loop (cdr paths) (+ files 1) (+ count n)
                  (append (reverse (map (lambda (d) (cons (car paths) d)) found)) disagreements))))))

  (define (scheme-file? name)
    (exists (lambda (extension)
              (let ([n (string-length name)] [m (string-length extension)])
                (and (> n m) (string=? (substring name (- n m) n) extension))))
            '(".ss" ".sls" ".sps" ".scm")))

  (define (scheme-files folder)
    (let loop ([names (sort string<? (directory-list folder))] [found '()])
      (if (null? names)
          (reverse found)
          (let ([path (string-append folder "/" (car names))])
            (loop (cdr names)
                  (cond
                    [(file-directory? path)
                     (if (string=? (car names) ".git") found (append (reverse (scheme-files path)) found))]
                    [(scheme-file? (car names)) (cons path found)]
                    [else found])))))))
