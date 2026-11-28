(library (chez-scheme highlight)
  (export lex-document make-highlight)
  (import (chezscheme) (document) (chez-scheme lexer))

  ;; A file buffer's text sits in one root node, one position after its
  ;; offset, which spares a search of the tree for each lexeme.
  (define (position-mapping doc text)
    (let ([n (string-length text)] [size (document:length doc)])
      (cond
        [(fx= size n) (values (lambda (offset) offset) (lambda (offset) offset))]
        [(and (fx= size (fx+ n 2))
              (not (char? (document:token doc 0)))
              (eq? (document:token doc (fx- size 1)) 'close))
         (values (lambda (offset) (fx+ offset 1)) (lambda (offset) (fx+ offset 1)))]
        [else
         (let ([unit (document:unit characters)])
           (values (lambda (offset) (fx- (document:position doc (fx+ offset 1) unit) 1))
                   (lambda (offset) (document:position doc offset unit))))])))

  (define (lex-document doc proc)
    (let ([text (document:text doc)])
      (let-values ([(start-of end-of) (position-mapping doc text)])
        (vector-for-each
          (lambda (t)
            (proc (lexeme-kind t) (start-of (lexeme-start t)) (end-of (lexeme-end t))
                  (lexeme-depth t) (lexeme-open-ended? t) (lexeme-mismatched? t)))
          (lex text)))))

  (define (after-colon head)
    (let loop ([i (fx- (string-length head) 1)])
      (cond
        [(fx< i 0) head]
        [(char=? (string-ref head i) #\:) (substring head (fx+ i 1) (string-length head))]
        [else (loop (fx- i 1))])))

  (define (definer? head)
    (let ([name (after-colon head)])
      (and (fx>= (string-length name) 6)
           (string=? (substring name 0 6) "define")
           name)))

  (define (type-definer? name)
    (member name '("define-record-type" "define-enumeration" "define-condition-type" "define-ftype")))

  (define (primitive-name? text)
    (let ([n (string-length text)])
      (and (fx>= n 3) (char=? (string-ref text 0) #\#)
           (or (char=? (string-ref text 1) #\%)
               (and (fx>= n 4) (memv (string-ref text 1) '(#\2 #\3)) (char=? (string-ref text 2) #\%))))))

  (define (prefix-context text context)
    (cond
      [(string=? text "'") (if (eq? context 'code) 'quoted context)]
      [(string=? text "`") (if (eq? context 'code) 'quasi context)]
      [(or (string=? text ",") (string=? text ",@")) (if (eq? context 'quasi) 'code context)]
      [else context]))

  (define-record-type frame
    (sealed #t)
    (fields context (mutable count) (mutable head) role (mutable formals?)))

  (define (string-spans text start end open-ended? string-face escape-face)
    (let ([last (if open-ended? end (fx- end 1))])
      (let loop ([i (fx+ start 1)] [piece start] [acc '()])
        (define (escape-end i)
          (let ([j (fx+ i 1)])
            (cond
              [(fx>= j last) last]
              [(char=? (string-ref text j) #\x)
               (let hex ([k (fx+ j 1)])
                 (cond
                   [(fx>= k last) last]
                   [(char=? (string-ref text k) #\;) (fx+ k 1)]
                   [(char-whitespace? (string-ref text k)) k]
                   [else (hex (fx+ k 1))]))]
              [(char-whitespace? (string-ref text j))
               (let blank ([k j] [seen-newline? #f])
                 (cond
                   [(fx>= k last) last]
                   [(char=? (string-ref text k) #\newline) (if seen-newline? k (blank (fx+ k 1) #t))]
                   [(char-whitespace? (string-ref text k)) (blank (fx+ k 1) seen-newline?)]
                   [else k]))]
              [(char<=? #\0 (string-ref text j) #\7)
               (let octal ([k j] [count 0])
                 (if (and (fx< k last) (fx< count 3) (char<=? #\0 (string-ref text k) #\7))
                     (octal (fx+ k 1) (fx+ count 1))
                     k))]
              [else (fx+ j 1)])))
        (cond
          [(fx>= i last) (reverse (if (fx< piece end) (cons (list piece end string-face) acc) acc))]
          [(char=? (string-ref text i) #\\)
           (let ([e (escape-end i)])
             (loop e e (cons (list i e escape-face)
                             (if (fx< piece i) (cons (list piece i string-face) acc) acc))))]
          [else (loop (fx+ i 1) piece acc)]))))

  (define (face-spans lexemes text faces names)
    (define (face role) (cdr (assq role faces)))
    (let ([n (vector-length lexemes)] [acc '()])
      (define (add! start end role)
        (set! acc (cons (list start end (face role)) acc)))
      (define (followed? i)
        (let loop ([j (fx+ i 1)])
          (and (fx< j n)
               (case (lexeme-kind (vector-ref lexemes j))
                 [(line-comment block-comment datum-comment directive) (loop (fx+ j 1))]
                 [(close) #f]
                 [else #t]))))
      (define (symbol-role frame index context word)
        (let ([head (frame-head frame)])
          (cond
            [(not (eq? context 'code)) 'quoted]
            [(and (eq? (frame-role frame) 'definition) (fx= index 0)) 'function]
            [(and (eq? (frame-role frame) 'type-definition) (fx= index 0)) 'type]
            [(and head (fx= index 1) (definer? head))
             => (lambda (name) (if (type-definer? name) 'type 'function))]
            [(and head (fx= index 1) (string=? head "let")) 'function]
            [(eq? (frame-role frame) 'library-name) 'module]
            [(primitive-name? word) 'builtin]
            [(and names (hashtable-ref names word #f))
             => (lambda (class) (if (eq? class 'syntax) 'keyword 'builtin))]
            [else #f])))
      (let loop ([i 0] [frames (list (make-frame 'code 0 #f #f #f))] [pending #f])
        (if (fx= i n)
            (reverse acc)
            (let* ([t (vector-ref lexemes i)] [start (lexeme-start t)] [end (lexeme-end t)]
                   [frame (car frames)] [context (or pending (frame-context frame))])
              (define (element!)
                (let ([index (frame-count frame)])
                  (frame-count-set! frame (fx+ index 1))
                  index))
              (case (lexeme-kind t)
                [(line-comment block-comment datum-comment)
                 (add! start end 'comment)
                 (loop (fx+ i 1) frames pending)]
                [(directive)
                 (add! start end 'directive)
                 (loop (fx+ i 1) frames pending)]
                [(prefix)
                 (add! start end 'punctuation)
                 (loop (fx+ i 1) frames (prefix-context (substring text start end) context))]
                [(open)
                 (let* ([index (element!)] [head (frame-head frame)]
                        [role (cond
                                [(not (eq? context 'code)) #f]
                                [(and head (fx= index 1) (definer? head))
                                 => (lambda (name)
                                      (frame-formals?-set! frame #t)
                                      (if (type-definer? name) 'type-definition 'definition))]
                                [(and head (fx= index 1) (string=? head "library")) 'library-name]
                                [else #f])])
                   (loop (fx+ i 1) (cons (make-frame context 0 #f role #f) frames) #f))]
                [(close)
                 (loop (fx+ i 1) (if (null? (cdr frames)) frames (cdr frames)) #f)]
                [(dot) (loop (fx+ i 1) frames #f)]
                [(symbol)
                 (let* ([index (element!)] [word (substring text start end)]
                        [role (symbol-role frame index context word)])
                   (when (fx= index 0) (frame-head-set! frame word))
                   (when role (add! start end role))
                   (loop (fx+ i 1) frames #f))]
                [(string)
                 (let ([index (element!)])
                   (if (and (fx= index 2) (frame-formals? frame) (eq? context 'code) (followed? i))
                       (add! start end 'documentation)
                       (for-each (lambda (span) (set! acc (cons span acc)))
                         (string-spans text start end (lexeme-open-ended? t) (face 'string) (face 'escape))))
                   (loop (fx+ i 1) frames #f))]
                [else
                 (element!)
                 (add! start end
                   (case (lexeme-kind t)
                     [(number) 'number]
                     [(boolean) 'boolean]
                     [(character) 'character]
                     [else (if (and (fx< (fx+ start 1) end) (char=? (string-ref text (fx+ start 1)) #\!))
                               'object
                               'punctuation)]))
                 (loop (fx+ i 1) frames #f)]))))))

  (define (bracket-spans lexemes)
    (let loop ([i (fx- (vector-length lexemes) 1)] [acc '()])
      (if (fx< i 0)
          acc
          (let ([t (vector-ref lexemes i)])
            (loop (fx- i 1)
                  (if (memq (lexeme-kind t) '(open close))
                      (cons (list (lexeme-start t) (lexeme-end t)
                                  (list (cons 'bracket
                                              (cond
                                                [(lexeme-mismatched? t) 'mismatched]
                                                [(fx= (lexeme-depth t) 0) 'unmatched]
                                                [else (lexeme-depth t)]))))
                            acc)
                      acc))))))

  ;; Chez's read makes boxes, special vectors, the end-of-file object and
  ;; cycles from text, none of which a job may emit.
  (define (spec-datum? v)
    (let ([seen (make-eq-hashtable)])
      (let datum? ([v v])
        (or (symbol? v) (number? v)
            (let elements? ([p v])
              (cond
                [(null? p) #t]
                [(and (pair? p) (not (eq-hashtable-contains? seen p)))
                 (eq-hashtable-set! seen p #t)
                 (and (datum? (car p)) (elements? (cdr p)))]
                [else #f]))))))

  (define (clause-specs clause)
    (if (list? clause) (filter spec-datum? (cdr clause)) '()))

  ;; A scope lists its sources in the order that resolves a name. A
  ;; module's body imports (tuna replaced) inside its first line's
  ;; libraries and outside its own imports, and a configuration loads
  ;; into the REPL's environment, the only file with use-plugin lines.
  (define (scope-of lexemes text)
    (define (form-datum t end)
      (guard (c [(or (lexical-violation? c) (i/o-error? c)) #f])
        (read (open-string-input-port (substring text (lexeme-start t) end)))))
    (define (form-end i)
      (let loop ([j (fx+ i 1)])
        (cond
          [(fx= j (vector-length lexemes)) #f]
          [(and (eq? (lexeme-kind (vector-ref lexemes j)) 'close) (fx= (lexeme-depth (vector-ref lexemes j)) 1))
           (lexeme-end (vector-ref lexemes j))]
          [else (loop (fx+ j 1))])))
    (let* ([n (vector-length lexemes)]
           [first-line (and (fx> n 0)
                            (fx= (lexeme-start (vector-ref lexemes 0)) 0)
                            (eq? (lexeme-kind (vector-ref lexemes 0)) 'directive)
                            (substring text 0 (lexeme-end (vector-ref lexemes 0))))]
           [line-specs (cond
                         [(equal? first-line "#!tuna") '((tuna replaced) (chezscheme) (tuna))]
                         [else '()])]
           [module-file? (pair? line-specs)])
      (let loop ([i 0] [specs '()] [own #f] [found? module-file?] [configuration? #f])
        (if (fx= i n)
            (list (cond
                    [(not found?) '(repl)]
                    [configuration? (append (reverse specs) '(repl))]
                    [else (append (reverse specs) line-specs)])
                  own module-file?)
            (let ([t (vector-ref lexemes i)])
              (if (and (eq? (lexeme-kind t) 'open) (fx= (lexeme-depth t) 1)
                       (fx< (fx+ i 1) n) (eq? (lexeme-kind (vector-ref lexemes (fx+ i 1))) 'symbol))
                  (let* ([head-lexeme (vector-ref lexemes (fx+ i 1))]
                         [head (substring text (lexeme-start head-lexeme) (lexeme-end head-lexeme))]
                         [end (and (member head '("import" "library" "use-plugin")) (form-end i))]
                         [datum (and end (form-datum t end))])
                    (cond
                      [(not (and (pair? datum) (list? datum))) (loop (fx+ i 1) specs own found? configuration?)]
                      [(string=? head "import")
                       (loop (fx+ i 1) (append (reverse (clause-specs datum)) specs) own #t configuration?)]
                      [(string=? head "use-plugin")
                       (loop (fx+ i 1) (if (and (pair? (cdr datum)) (symbol? (cadr datum))) (cons (list (cadr datum)) specs) specs)
                             own #t #t)]
                      [else
                       (let ([imports (find (lambda (clause) (and (pair? clause) (eq? (car clause) 'import))) datum)]
                             [name (and (pair? (cdr datum)) (list? (cadr datum)) (spec-datum? (cadr datum)) (cadr datum))])
                         (loop (fx+ i 1) (if imports (append (reverse (clause-specs imports)) specs) specs)
                               name #t configuration?))]))
                  (loop (fx+ i 1) specs own found? configuration?)))))))

  (define (close-indices lexemes)
    (let* ([n (vector-length lexemes)] [closes (make-vector n n)])
      (let loop ([j 0] [open '()])
        (unless (fx= j n)
          (case (lexeme-kind (vector-ref lexemes j))
            [(open) (loop (fx+ j 1) (cons j open))]
            [(close)
             (if (pair? open)
                 (begin (vector-set! closes (car open) j) (loop (fx+ j 1) (cdr open)))
                 (loop (fx+ j 1) open))]
            [else (loop (fx+ j 1) open)])))
      closes))

  (define (elements lexemes closes i)
    (let ([end (vector-ref closes i)])
      (let loop ([j (fx+ i 1)] [acc '()])
        (if (fx>= j end)
            (reverse acc)
            (case (lexeme-kind (vector-ref lexemes j))
              [(line-comment block-comment datum-comment directive prefix dot close) (loop (fx+ j 1) acc)]
              [(open) (loop (fx+ (vector-ref closes j) 1) (cons j acc))]
              [else (loop (fx+ j 1) (cons j acc))])))))

  ;; A job's data is plain data, so each definition is a list: its head,
  ;; its name, its range, its name's start, whether it defines a
  ;; procedure, and a library's or named module's own definitions.
  (define (definitions lexemes text heads start-of end-of)
    (let ([closes (close-indices lexemes)] [n (vector-length lexemes)])
      (define (kind j) (lexeme-kind (vector-ref lexemes j)))
      (define (word j) (let ([t (vector-ref lexemes j)]) (substring text (lexeme-start t) (lexeme-end t))))
      (define (text-end i)
        (let ([c (vector-ref closes i)])
          (if (fx< c n) (lexeme-end (vector-ref lexemes c)) (string-length text))))
      (define (first-symbol j)
        (case (kind j)
          [(symbol) j]
          [(open) (let ([es (elements lexemes closes j)]) (and (pair? es) (first-symbol (car es))))]
          [else #f]))
      (define (headed-by? j words)
        (and (eq? (kind j) 'open)
             (let ([es (elements lexemes closes j)])
               (and (pair? es) (eq? (kind (car es)) 'symbol) (member (word (car es)) words) #t))))
      (define (definer-head? head)
        (or (definer? head) (member head heads) (member (after-colon head) heads)))
      (define (entry i head name name-start procedure? children)
        (list head name (start-of (lexeme-start (vector-ref lexemes i))) (end-of (text-end i)) (start-of name-start)
              procedure? children))
      (define (body forms)
        (fold-right (lambda (j acc) (append (form j #f) acc)) '() (filter (lambda (j) (eq? (kind j) 'open)) forms)))
      (define (form i top?)
        (let ([es (elements lexemes closes i)])
          (if (and (pair? es) (eq? (kind (car es)) 'symbol))
              (let ([head (word (car es))] [rest (cdr es)])
                (cond
                  [(null? rest) '()]
                  [(and top? (string=? head "library") (eq? (kind (car rest)) 'open))
                   (let ([name (lexeme-start (vector-ref lexemes (car rest)))])
                     (list (entry i head (substring text name (text-end (car rest))) name #f (body (cdr rest)))))]
                  [(and top? (string=? head "module") (eq? (kind (car rest)) 'open)) (body (cdr rest))]
                  [(and top? (string=? head "module") (eq? (kind (car rest)) 'symbol))
                   (list (entry i head (word (car rest)) (lexeme-start (vector-ref lexemes (car rest))) #f
                                (body (cdr rest))))]
                  [(definer-head? head)
                   (let ([name (first-symbol (car rest))])
                     (if name
                         (list (entry i head (word name) (lexeme-start (vector-ref lexemes name))
                                      (or (eq? (kind (car rest)) 'open)
                                          (and (pair? (cdr rest)) (headed-by? (cadr rest) '("lambda" "case-lambda"))))
                                      '()))
                         '()))]
                  [else '()]))
              '())))
      (let loop ([j 0] [acc '()])
        (cond
          [(fx>= j n) (reverse acc)]
          [(and (eq? (kind j) 'open) (fx= (lexeme-depth (vector-ref lexemes j)) 1))
           (loop (fx+ (vector-ref closes j) 1) (append (reverse (form j #t)) acc))]
          [else (loop (fx+ j 1) acc)]))))

  (define (names-table pairs)
    (let ([names (make-hashtable string-hash string=?)])
      (vector-for-each (lambda (pair) (hashtable-set! names (symbol->string (car pair)) (cdr pair))) pairs)
      names))

  (define (make-highlight)
    (let ([roles #f] [faces #f] [pairs #f] [names #f])
      (lambda (doc input edits)
        (let ([given-roles (car input)] [brackets? (cadr input)] [given-pairs (caddr input)] [heads (cadddr input)])
          (unless (eq? given-roles roles)
            (set! roles given-roles)
            (set! faces (map (lambda (role) (cons (car role) (list (cons 'face (cdr role))))) given-roles)))
          (unless (eq? given-pairs pairs)
            (set! pairs given-pairs)
            (set! names (and given-pairs (names-table given-pairs))))
          (let* ([text (document:text doc)] [lexemes (lex text)])
            (let-values ([(start-of end-of) (position-mapping doc text)])
              (values (list (list->vector (face-spans lexemes text faces names))
                            (if brackets? (list->vector (bracket-spans lexemes)) '#()))
                      (list (scope-of lexemes text) (definitions lexemes text heads start-of end-of))))))))))
