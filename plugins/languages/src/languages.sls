#!tuna
(import (modes) (tables))

(tables:define-table mode
  "Maps a language, the identifier the Language Server Protocol gives it, to the major mode that edits it.")

(tables:define-table file-names
  "Maps a language to the patterns of its files' names, a list of strings, as auto-mode reads them.")

(tables:define-table interpreters
  "Maps a language to the programs a #! line of its files names, a list of strings.")

(tables:define-table grammar
  "Maps a language to its tree-sitter grammar, made with languages:define-grammar.")

(tables:define-table line-comments
  "Maps a language to the delimiters of its comments that end at the line's end, a list.")

(tables:define-table block-comments
  "Maps a language to the delimiters of its comments that have an end, a list.")

(tables:define-table strings
  "Maps a language to the delimiters of its strings, a list.")

(tables:define-table brackets
  "Maps a language to its brackets, a list of pairs of an opening and a closing character.")

(tables:define-table word-characters
  "Maps a language to the characters besides letters and digits that are part of its words, as a string.")

(tables:define-table symbol-characters
  "Maps a language to the characters besides letters, digits and its word characters that are part of its symbols, as a string.")

(define-record-type (%delimiter %make-delimiter delimiter?)
  (sealed #t)
  (fields (immutable start delimiter-start) (immutable end delimiter-end) (immutable escape delimiter-escape)
          (immutable word-start? delimiter-word-start?) (immutable line-bound? delimiter-line-bound?)))

(define-record-type (%grammar %make-grammar grammar?)
  (sealed #t)
  (fields (immutable name grammar-name) (immutable url grammar-url) (immutable commit grammar-commit)
          (immutable location grammar-location) (immutable prebuilt grammar-prebuilt)))

(module %internals (check-strings check-characters set-mode! make-git-grammar make-file-grammar)

  (define (check-strings who what v)
    (unless (and (list? v) (for-all (lambda (s) (and (string? s) (fx> (string-length s) 0))) v))
      (assertion-violation who (string-append "not a list of " what) v)))

  (define (check-characters who v)
    (unless (string? v)
      (assertion-violation who "not a string" v)))

  (define (set-mode! who language m)
    (unless (and (symbol? m) (tables:ref modes:hooks m #f))
      (assertion-violation who "not a mode" m))
    (tables:set! mode language m))

  (define (hex-digit? c) (or (char<=? #\0 c #\9) (char<=? #\a c #\f) (char<=? #\A c #\F)))

  (define (make-git-grammar who name url commit location)
    (unless (string? url)
      (assertion-violation who "not a URL or folder" url))
    (unless (and (string? commit) (fx= (string-length commit) 40) (for-all hex-digit? (string->list commit)))
      (assertion-violation who "not a full commit: 40 hexadecimal digits" commit))
    (unless (and (string? location) (fx> (string-length location) 0))
      (assertion-violation who "not a folder in the repository" location))
    (%make-grammar name url commit location #f))

  (define (make-file-grammar who name path)
    (unless (string? path)
      (assertion-violation who "not a file name" path))
    (%make-grammar name #f #f #f path)))

(import %internals)

(meta define (%clauses who form clauses names)
  (let loop ([clauses clauses] [found '()])
    (if (null? clauses)
        (lambda (name) (let ([c (assq name found)]) (and c (cdr c))))
        (let* ([c (car clauses)]
               [name (syntax-case c () [(k . _) (identifier? #'k) (syntax->datum #'k)] [_ #f])])
          (unless (memq name names)
            (syntax-violation who "invalid clause" form c))
          (when (assq name found)
            (syntax-violation who "clause given twice" form c))
          (loop (cdr clauses) (cons (cons name c) found))))))

;; Delimiters are data written in the form, so a misspelt flag fails when
;; the form expands rather than when a buffer is first lexed.
(meta define (%delimiters who form clause kind)
  (define (text x)
    (let ([s (syntax->datum x)])
      (unless (and (string? s) (fx> (string-length s) 0))
        (syntax-violation who "not a non-empty string" form x))
      s))
  (syntax-case clause ()
    [(_ (d ...) ...)
     (map (lambda (d)
            (let-values ([(start end flags)
                          (syntax-case d ()
                            [(s . flags) (eq? kind 'line) (values (text #'s) #f #'flags)]
                            [(s e . flags) (not (eq? kind 'line)) (values (text #'s) (text #'e) #'flags)]
                            [_ (syntax-violation who "invalid delimiter" form d)])])
              (let loop ([flags flags] [escape #f] [word-start? #f] [line-bound? #f])
                (syntax-case flags ()
                  [() (list start end escape word-start? line-bound?)]
                  [((k c) . rest)
                   (and (eq? (syntax->datum #'k) 'escape) (eq? kind 'string) (char? (syntax->datum #'c)) (not escape))
                   (loop #'rest (syntax->datum #'c) word-start? line-bound?)]
                  [(k . rest)
                   (and (eq? (syntax->datum #'k) 'word-start) (not word-start?))
                   (loop #'rest escape #t line-bound?)]
                  [(k . rest)
                   (and (eq? (syntax->datum #'k) 'line-bound) (eq? kind 'string) (not line-bound?))
                   (loop #'rest escape word-start? #t)]
                  [(f . rest) (syntax-violation who "invalid flag" form #'f)]))))
          #'((d ...) ...))]
    [_ (syntax-violation who "invalid clause" form clause)]))

(meta define (%brackets who form clause)
  (define (character x)
    (let ([s (syntax->datum x)])
      (unless (and (string? s) (fx= (string-length s) 1))
        (syntax-violation who "not a string of one character" form x))
      (string-ref s 0)))
  (syntax-case clause ()
    [(_ (open close) ...)
     (map (lambda (o c) (cons (character o) (character c))) #'(open ...) #'(close ...))]
    [_ (syntax-violation who "invalid clause" form clause)]))

(define-syntax define-language
  (lambda (x)
    (define who 'languages:define-language)
    (syntax-case x ()
      [(_ id clause ...)
       (let ([clause (%clauses who x #'(clause ...)
                       '(mode file-names interpreters grammar line-comments block-comments strings brackets
                         word-characters symbol-characters))])
         (define (expression name)
           (syntax-case (clause name) () [(_ e) #'e] [c (syntax-violation who "invalid clause" x #'c)]))
         (define (string-list name)
           (syntax-case (clause name) () [(_ e ...) #'(list e ...)] [c (syntax-violation who "invalid clause" x #'c)]))
         (define (delimiters name kind)
           #`(list #,@(map (lambda (d) #`(%make-delimiter #,@(map (lambda (v) #`'#,v) d)))
                           (%delimiters who x (clause name) kind))))
         (with-syntax ([(set ...)
                        (filter values
                          (list
                            (and (clause 'mode) #`(set-mode! 'languages:define-language language #,(expression 'mode)))
                            (and (clause 'file-names)
                                 #`(let ([v #,(string-list 'file-names)])
                                     (check-strings 'languages:define-language "file name patterns" v)
                                     (tables:set! file-names language v)))
                            (and (clause 'interpreters)
                                 #`(let ([v #,(string-list 'interpreters)])
                                     (check-strings 'languages:define-language "programs" v)
                                     (tables:set! interpreters language v)))
                            (and (clause 'grammar)
                                 #`(let ([v #,(expression 'grammar)])
                                     (unless (grammar? v) (assertion-violation 'languages:define-language "not a grammar" v))
                                     (tables:set! grammar language v)))
                            (and (clause 'line-comments)
                                 #`(tables:set! line-comments language #,(delimiters 'line-comments 'line)))
                            (and (clause 'block-comments)
                                 #`(tables:set! block-comments language #,(delimiters 'block-comments 'block)))
                            (and (clause 'strings)
                                 #`(tables:set! strings language #,(delimiters 'strings 'string)))
                            (and (clause 'brackets)
                                 #`(tables:set! brackets language '#,(%brackets who x (clause 'brackets))))
                            (and (clause 'word-characters)
                                 #`(let ([v #,(expression 'word-characters)])
                                     (check-characters 'languages:define-language v)
                                     (tables:set! word-characters language v)))
                            (and (clause 'symbol-characters)
                                 #`(let ([v #,(expression 'symbol-characters)])
                                     (check-characters 'languages:define-language v)
                                     (tables:set! symbol-characters language v)))))])
           #`(define-values ()
               (let ([language id])
                 (unless (and (string? language) (fx> (string-length language) 0))
                   (assertion-violation 'languages:define-language "not a language" language))
                 set ...
                 (values)))))]
      [_ (syntax-violation who "expected (languages:define-language id-expr clause ...)" x)])))

(define-syntax define-grammar
  (lambda (x)
    (define who 'languages:define-grammar)
    (syntax-case x ()
      [(_ id source)
       (identifier? #'id)
       (let ([name (symbol->string (syntax->datum #'id))])
         (unless (and (fx> (string-length name) 0)
                      (for-all (lambda (c) (or (char<=? #\a c #\z) (char<=? #\A c #\Z) (char<=? #\0 c #\9) (char=? c #\_)))
                               (string->list name)))
           (syntax-violation who "a grammar's name holds letters, digits and _ only" x #'id))
         (syntax-case #'source ()
           [(k url commit)
            (eq? (syntax->datum #'k) 'git)
            #`(define-public id (make-git-grammar 'languages:define-grammar #,name url commit "."))]
           [(k url commit location)
            (eq? (syntax->datum #'k) 'git)
            #`(define-public id (make-git-grammar 'languages:define-grammar #,name url commit location))]
           [(k path)
            (eq? (syntax->datum #'k) 'file)
            #`(define-public id (make-file-grammar 'languages:define-grammar #,name path))]
           [_ (syntax-violation who "expected (git url commit [location]) or (file path)" x #'source)]))]
      [_ (syntax-violation who "expected (languages:define-grammar id source)" x)])))

;; Entries set with tables:set! skip the form's checks, so each reader
;; checks the shape of what it returns, for every plugin that reads it.
(define (%reader who table empty shape? what)
  (lambda (language)
    (unless (string? language)
      (assertion-violation who "not a language" language))
    (let ([entry (tables:ref table language #f)])
      (cond
        [(not entry) empty]
        [(shape? entry) entry]
        [else (assertion-violation who (string-append "the entry is not " what) language entry)]))))

(define (%strings? v) (and (list? v) (for-all (lambda (s) (and (string? s) (fx> (string-length s) 0))) v)))

(define (%delimiters? v) (and (list? v) (for-all delimiter? v)))

(define (%pairs? v) (and (list? v) (for-all (lambda (p) (and (pair? p) (char? (car p)) (char? (cdr p)))) v)))

(define file-names-of (%reader 'languages:file-names-of file-names '() %strings? "a list of file name patterns"))
(define interpreters-of (%reader 'languages:interpreters-of interpreters '() %strings? "a list of programs"))
(define line-comments-of (%reader 'languages:line-comments-of line-comments '() %delimiters? "a list of delimiters"))
(define block-comments-of (%reader 'languages:block-comments-of block-comments '() %delimiters? "a list of delimiters"))
(define strings-of (%reader 'languages:strings-of strings '() %delimiters? "a list of delimiters"))
(define brackets-of (%reader 'languages:brackets-of brackets '() %pairs? "a list of pairs of characters"))
(define word-characters-of (%reader 'languages:word-characters-of word-characters #f string? "a string"))
(define symbol-characters-of (%reader 'languages:symbol-characters-of symbol-characters #f string? "a string"))
(define grammar-of (%reader 'languages:grammar-of grammar #f grammar? "a grammar"))

(define (of m)
  (unless (symbol? m)
    (assertion-violation 'languages:of "not a mode" m))
  (let ([entries (tables:entries mode)])
    (exists (lambda (ancestor)
              (let ([entry (find (lambda (e) (eq? (cdr e) ancestor)) entries)])
                (and entry (car entry))))
            (modes:ancestry m))))
