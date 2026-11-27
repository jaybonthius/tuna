(import (tuna) (document) (treesit highlight))

(define home (getenv "HOME"))
(define library (getenv "TUNA_LIBRARY"))

(define python-commit "293fdc02038ee2bf0e2e206711b69c90ac0d413f")
(define grammar
  (format "~a/test-grammars/libtree-sitter-python-~a.so"
    (path-parent (path-parent (car (command-line)))) (substring python-commit 0 12)))

(define shipped-folders
  (list (string-append library "/python/queries")
        (string-append library "/treesit/nvim-treesitter/runtime/queries")))
(define shipped (query-files shipped-folders "python" "highlights"))

(define default-excluded
  '(variable variable.member function.call function.method.call constructor module operator
    punctuation.bracket punctuation.delimiter))

(define (write-file path text)
  (let loop ([d (path-parent path)])
    (unless (or (string=? d "") (file-directory? d))
      (loop (path-parent d))
      (mkdir d)))
  (call-with-output-file path (lambda (p) (display text p)) 'replace))

(define (read-file path) (call-with-input-file path get-string-all))

(define query-count 0)
(define (query text)
  (set! query-count (+ query-count 1))
  (let ([path (format "~a/queries-~a/python/highlights.scm" home query-count)])
    (write-file path text)
    path))

;; The configuration is read again when a plugin it imports reloads.
(define-record-type session
  (nongenerative tests-treesit-highlight-session)
  (fields highlight (mutable doc) (mutable files) (mutable excluded) (mutable drawn)
          (mutable since) (mutable faces) (mutable data)))

(define (open text files excluded . drawn)
  (make-session (make-highlight) (document:from-utf8 (string->utf8 text)) files excluded drawn '()
                (make-vector (string-length text) #f) '()))

;; A job's input gives each query file with its modification time; these
;; sessions never rewrite a file, so they give none.
(define (untimed files) (map (lambda (file) (cons file #f)) files))

(define (input s) (list grammar "python" (untimed (session-files s)) (session-excluded s) (session-drawn s)))

(define (face-of value) (and value (cdr (car value))))

(define (step! s)
  (call-with-values (lambda () (let ([since (reverse (session-since s))])
                                 (session-since-set! s '())
                                 ((session-highlight s) (session-doc s) (input s) since)))
    (case-lambda
      [(layers data) (session-data-set! s data) (paint! s (car layers)) (values #f #f)]
      [(layers data more)
       (session-data-set! s data)
       (let ([a (car layers)])
         (paint! s a)
         (values (and (vector? (caddr a)) (< (car a) (cadr a)) (list (car a) (cadr a))) more))])))

(define (paint! s answer)
  (let ([v (session-faces s)])
    (if (vector? answer)
        (vector-fill! v #f)
        (begin
          (do ([i (car answer) (+ i 1)]) ((= i (cadr answer))) (vector-set! v i #f))
          (vector-for-each
            (lambda (span) (do ([i (car span) (+ i 1)]) ((= i (cadr span))) (vector-set! v i (face-of (caddr span)))))
            (caddr answer))))))

(define (settle! s)
  (let loop ([ranges '()])
    (let-values ([(range more) (step! s)])
      (let ([ranges (if range (cons range ranges) ranges)])
        (if more (loop ranges) (reverse ranges))))))

(define (text-of s) (document:text (session-doc s)))

(define (replace! s start end text)
  (let* ([doc (session-doc s)] [n (string-length text)] [v (session-faces s)])
    (session-doc-set! s (document:replace doc start end (document:from-utf8 (string->utf8 text))))
    (session-since-set! s (cons (list start (- end start) n) (session-since s)))
    (session-faces-set! s
      (vectors-append (vector-slice v 0 start) (make-vector n #f) (vector-slice v end (vector-length v))))))

(define (vector-slice v from to)
  (let ([out (make-vector (- to from))])
    (do ([i from (+ i 1)]) ((= i to) out) (vector-set! out (- i from) (vector-ref v i)))))

(define (vectors-append . vs) (list->vector (apply append (map vector->list vs))))

(define (session-problems s) (or (session-data s) '()))

(define (runs s . range)
  (let* ([text (text-of s)] [v (session-faces s)]
         [start (if (pair? range) (car range) 0)] [end (if (pair? range) (cadr range) (vector-length v))])
    (let loop ([i start] [acc '()])
      (if (>= i end)
          (reverse acc)
          (let ([face (vector-ref v i)])
            (let run ([j (+ i 1)])
              (if (and (< j end) (equal? (vector-ref v j) face))
                  (run (+ j 1))
                  (loop j (if face (cons (list (substring text i j) face) acc) acc)))))))))

(define (highlighted text files excluded)
  (let ([s (open text files excluded)])
    (settle! s)
    s))

(define (faces text files excluded) (runs (highlighted text files excluded)))

(define (queried text query-text . excluded)
  (faces text (list (query query-text)) (if (pair? excluded) (car excluded) '())))

(define (shown-path path)
  (cond
    [(offset-of path home) => (lambda (i) (string-append "~" (substring path (+ i (string-length home)) (string-length path))))]
    [(offset-of path library) => (lambda (i) (string-append "library" (substring path (+ i (string-length library)) (string-length path))))]
    [else path]))

(define (reports s)
  (map (lambda (r) (cons* (car r) (shown-path (cadr r)) (cddr r))) (session-problems s)))

(define (first-difference a b)
  (let ([va (session-faces a)] [vb (session-faces b)])
    (let loop ([i 0])
      (cond
        [(= i (vector-length va)) #f]
        [(equal? (vector-ref va i) (vector-ref vb i)) (loop (+ i 1))]
        [else (list i (vector-ref va i) (vector-ref vb i))]))))

(define (offset-of text needle . from)
  (let ([n (string-length needle)])
    (let loop ([i (if (pair? from) (car from) 0)])
      (cond
        [(> (+ i n) (string-length text)) #f]
        [(string=? (substring text i (+ i n)) needle) i]
        [else (loop (+ i 1))]))))

(define (line-start text line)
  (let loop ([i 0] [l 0])
    (cond [(= l line) i] [(char=? (string-ref text i) #\newline) (loop (+ i 1) (+ l 1))] [else (loop (+ i 1) l)])))

(define (grown-text size)
  (let ([sample (read-file (string-append home "/python/sample.py"))] [out (open-output-string)])
    (let loop ([n 0])
      (if (>= n size)
          (get-output-string out)
          (begin (display sample out) (loop (+ n (string-length sample))))))))

(define (line-count text)
  (let loop ([i 0] [k 0])
    (if (= i (string-length text)) k (loop (+ i 1) (if (char=? (string-ref text i) #\newline) (+ k 1) k)))))

(define (overlap? a b) (and (< (car a) (cadr b)) (< (car b) (cadr a))))

(define (edit-case s line typed)
  (let* ([text (text-of s)] [lines (line-count text)] [at (line-start text line)]
         [from (line-start text (max 0 (- line 20)))]
         [to (+ (line-start text (min lines (+ line 40))) (string-length typed))])
    (session-drawn-set! s (list (cons from to)))
    (replace! s at at typed)
    (let-values ([(first more) (step! s)])
      (let* ([rest (if more (settle! s) '())]
             [answers (cons first rest)]
             [n (string-length (text-of s))]
             [whole? (let ([covered (fold-left (lambda (sum r) (+ sum (- (cadr r) (car r)))) 0 answers)]) (= covered n))]
             [failed
              (filter cdr
                (list
                  (cons 'first-inside-drawn (not (and first (<= from (car first)) (<= (cadr first) to))))
                  (cons 'first-whole-drawn (and whole? (not (equal? first (list from to)))))
                  (cons 'later-outside-first (exists (lambda (r) (overlap? r first)) rest))
                  (cons 'later-in-pieces (exists (lambda (r) (> (- (cadr r) (car r)) piece-size)) rest))
                  (cons 'fresh (first-difference s (highlighted (text-of s) (session-files s) (session-excluded s))))))])
        (replace! s at (+ at (string-length typed)) "")
        (settle! s)
        (list whole? (map car failed))))))

(define (edit-cases s lines typed)
  (let ([results (map (lambda (line) (edit-case s line typed)) lines)])
    (list typed (length (filter car results)) (length results)
          (apply append (map (lambda (r line) (if (null? (cadr r)) '() (list (cons line (cadr r))))) results lines)))))

(define (spaced-lines text count)
  (let ([lines (line-count text)])
    (map (lambda (k) (quotient (* k lines) (+ count 1))) (cdr (iota (+ count 1))))))

;; emacs/NAME.LEVEL holds a letter a character: K keyword, D definition,
;; U variable use, F function name, C call, T type, B builtin, N constant,
;; 9 number, S string, O docstring, E escape, M comment, P property, and a
;; dot for none or punctuation.
(define (string-suffix? suffix s)
  (let ([n (string-length suffix)] [m (string-length s)]) (and (<= n m) (string=? suffix (substring s (- m n) m)))))
(define (string-prefix? prefix s)
  (let ([n (string-length prefix)]) (and (<= n (string-length s)) (string=? prefix (substring s 0 n)))))

(define (category face)
  (let ([name (cond [(not face) #f] [(pair? face) (symbol->string (car face))] [else (symbol->string face)])])
    (cond
      [(not name) #\.]
      [(member name '("variable.definition" "variable.parameter")) #\D]
      [(string=? name "variable") #\U]
      [(string=? name "variable.member") #\P]
      [(member name '("type.builtin" "constructor")) #\T]
      [(string=? name "string.documentation") #\O]
      [(string=? name "string.escape") #\E]
      [(string-suffix? ".builtin" name) #\B]
      [(string-prefix? "keyword" name) #\K]
      [(member name '("function.call" "function.method.call")) #\C]
      [(string-prefix? "function" name) #\F]
      [(or (string-prefix? "type" name) (string-prefix? "attribute" name)) #\T]
      [(member name '("constant" "boolean" "character")) #\N]
      [(string-prefix? "number" name) #\9]
      [(string-prefix? "string" name) #\S]
      [(string-prefix? "comment" name) #\M]
      [(string-prefix? "module" name) #\Y]
      [(or (string-prefix? "punctuation" name) (string-prefix? "operator" name) (string-prefix? "character.special" name)) #\.]
      [else #\?])))

(define (compared name level)
  (let* ([text (read-file (format "~a/python/~a.py" home name))]
         [emacs (read-file (format "~a/emacs/~a.~a" home name level))]
         [s (highlighted text shipped (if (= level 3) default-excluded '()))]
         [v (session-faces s)]
         [kinds '()])
    (let loop ([i 0] [j 0] [line 1])
      (when (< i (string-length text))
        (let ([c (string-ref text i)])
          (cond
            [(char=? c #\newline) (loop (+ i 1) (+ j 1) (+ line 1))]
            [(memv c '(#\space #\tab)) (loop (+ i 1) (+ j 1) line)]
            [else
             (let ([e (string-ref emacs j)] [t (category (vector-ref v i))])
               (if (char=? e t)
                   (loop (+ i 1) (+ j 1) line)
                   (let run ([k i] [m j])
                     (if (and (< k (string-length text)) (not (memv (string-ref text k) '(#\newline)))
                              (char=? (string-ref emacs m) e) (char=? (category (vector-ref v k)) t))
                         (run (+ k 1) (+ m 1))
                         (let ([key (string e #\- #\> t)])
                           (set! kinds
                             (let ([old (assoc key kinds)])
                               (if old
                                   (cons (list key (+ (cadr old) (- k i)) (append (caddr old) (list (list line (substring text i k)))))
                                         (remove old kinds))
                                   (cons (list key (- k i) (list (list line (substring text i k)))) kinds))))
                           (loop k m line))))))]))))
    (sort (lambda (a b) (string<? (car a) (car b))) kinds)))

(import (console))
