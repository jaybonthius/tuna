#!tuna
(import (buffers) (document) (jobs) (syntax) (modes) (views) (faces) (web) (pcre2) (search scanning) (options) (tables) (saved))

(define %self (current-owner))

(define-enumeration case (smart fold exact) %cases)

(define-enumeration spaces (lax literal) %spaces)

(define-enumeration direction (forward backward) %directions)

(options:define-option case-fold 'smart (lambda (v) (memq v '(smart fold exact)))
  "The case rule of queries made without one: smart, fold or exact.")

(options:define-option lax-whitespace #t boolean?
  "Whether queries made without a whitespace rule, other than regexps, match a run of spaces with search:whitespace.")

(options:define-option regexp-lax-whitespace #f boolean?
  "Whether regexp queries made without a whitespace rule match a run of spaces with search:whitespace.")

(options:define-option whitespace "[ \\t]+" string?
  "The pattern a run of spaces matches under a lax whitespace rule; it must hold no capturing group.")

(options:define-option history-length 16 (lambda (v) (and (fixnum? v) (fx>= v 0)))
  "How many texts search:history and search:regexp-history each keep.")

(saved:define-saved history '() (lambda (v) (and (list? v) (for-all string? v))))

(saved:define-saved regexp-history '() (lambda (v) (and (list? v) (for-all string? v))))

(saved:define-saved prompt-regexp-history '() (lambda (v) (and (list? v) (for-all string? v))))

(tables:define-table filters
  "Maps predicates of a buffer and a match's start and end to #t; a match of any query counts only when every one returns true.")

(define group-1 'search.group-1)

(define group-2 'search.group-2)

(define-record-type (%style make-style style?)
  (sealed #t)
  (fields (immutable description style-description) (immutable procedure %style-procedure))
  (protocol
    (lambda (new)
      (lambda (description procedure)
        (unless (string? description)
          (assertion-violation 'search:make-style "not a string" description))
        (unless (procedure? procedure)
          (assertion-violation 'search:make-style "not a procedure" procedure))
        (new description procedure)))))

(define-record-type (%classes %make-classes classes?)
  (sealed #t)
  (fields %word %symbol %whitespace))

(define (%check-classes who v)
  (unless (classes? v)
    (assertion-violation who "not the classes a style receives" v)))

(define (classes-word classes)
  (%check-classes 'search:classes-word classes)
  (string-append "[" (%classes-%word classes) "]"))

(define (classes-symbol classes)
  (%check-classes 'search:classes-symbol classes)
  (string-append "[" (%classes-%symbol classes) "]"))

(define (classes-whitespace classes)
  (%check-classes 'search:classes-whitespace classes)
  (%classes-%whitespace classes))

(define %metacharacters "\\^$.|?*+()[]{}")

(define (regexp-quote text)
  (unless (string? text)
    (assertion-violation 'search:regexp-quote "not a string" text))
  (call-with-string-output-port
    (lambda (out)
      (string-for-each
        (lambda (c)
          (when (exists (lambda (m) (char=? c m)) (string->list %metacharacters))
            (put-char out #\\))
          (put-char out c))
        text))))

;; Each extra character is written \x{hex}, which PCRE2 takes literally
;; whatever it is, and the contents start and end with a property escape,
;; so a hyphen a user puts next to \w in a class stays an error, as
;; PCRE2 makes [\w-z] one, rather than a range.
(define (%class-contents extras)
  (call-with-string-output-port
    (lambda (out)
      (put-string out "\\p{Alphabetic}")
      (string-for-each (lambda (c) (put-string out (format "\\x{~x}" (char->integer c)))) extras)
      (put-string out "\\p{N}"))))

(define (%buffer-classes buffer spaces)
  (let ([words (syntax:buffer-word-characters buffer)])
    (%make-classes (%class-contents words)
                   (%class-contents (string-append words (syntax:buffer-symbol-characters buffer)))
                   (and (eq? spaces 'lax) (whitespace)))))

(define (%lax text pattern-of)
  (let ([ws (lambda (classes) (classes-whitespace classes))])
    (lambda (classes)
      (let ([run (ws classes)] [n (string-length text)])
        (let loop ([i 0] [acc '()])
          (cond
            [(fx= i n) (apply string-append (reverse acc))]
            [(and run (char=? (string-ref text i) #\space))
             (let skip ([j i]) (if (and (fx< j n) (char=? (string-ref text j) #\space)) (skip (fx+ j 1)) (loop j (cons run acc))))]
            [else (loop (fx+ i 1) (cons (pattern-of (string (string-ref text i))) acc))]))))))

(define literal
  (make-style "" (lambda (text partial? classes) ((%lax text regexp-quote) classes))))

(define (%word-char? c extras)
  (or (char-alphabetic? c) (char-numeric? c) (exists (lambda (x) (char=? c x)) (string->list extras))))

(define (%runs text in?)
  (let ([n (string-length text)])
    (let loop ([i 0] [acc '()])
      (cond
        [(fx= i n) (reverse acc)]
        [(in? (string-ref text i))
         (let run ([j i]) (if (and (fx< j n) (in? (string-ref text j))) (run (fx+ j 1)) (loop j (cons (substring text i j) acc))))]
        [else (loop (fx+ i 1) acc)]))))

(define (%whole-runs runs contents partial?)
  (let ([in (string-append "[" contents "]")] [out (string-append "[^" contents "]+")])
    (string-append
      "(?<!" in ")"
      (fold-left (lambda (acc r) (string-append acc out (regexp-quote r))) (regexp-quote (car runs)) (cdr runs))
      (if partial? "" (string-append "(?!" in ")")))))

(define %words-of (make-thread-parameter ""))

(define word
  (make-style "Word"
    (lambda (text partial? classes)
      (let ([runs (%runs text (lambda (c) (%word-char? c (%words-of))))])
        (if (null? runs) (regexp-quote text) (%whole-runs runs (%classes-%word classes) partial?))))))

(define %symbols-of (make-thread-parameter ""))

(define symbol
  (make-style "Symbol"
    (lambda (text partial? classes)
      (let ([runs (%runs text (lambda (c) (%word-char? c (%symbols-of))))])
        (if (null? runs) (regexp-quote text) (%whole-runs runs (%classes-%symbol classes) partial?))))))

(define (%read-regexp text word-contents lax-run)
  (define n (string-length text))
  (define out (open-output-string))
  (define exact? #f)
  (define W (string-append "[" word-contents "]"))
  (define N (string-append "[^" word-contents "]"))
  (define (emit . parts) (for-each (lambda (p) (put-string out p)) parts))
  (define (at i) (and (fx< i n) (string-ref text i)))
  (define (capital! c) (when (char-upper-case? c) (set! exact? #t)))
  (define (until i close)
    (let loop ([j i]) (if (and (fx< j n) (not (char=? (string-ref text j) close))) (loop (fx+ j 1)) (fxmin n (fx+ j 1)))))
  (define (case-property? name)
    (member name '("Lu" "Ll" "Lt" "Upper" "Lower" "Uppercase" "Lowercase")))
  (define (escape i)
    (let ([c (at (fx+ i 1))])
      (cond
        [(not c) (emit "\\") (fx+ i 1)]
        [(char=? c #\w) (emit W) (fx+ i 2)]
        [(char=? c #\W) (emit N) (fx+ i 2)]
        ;; A conditional tests the character before once, which made a
        ;; failing search over Japanese text about a fifth faster than the
        ;; alternation of two lookbehinds.
        [(char=? c #\b) (emit "(?(?<=" W ")(?!" W ")|(?=" W "))") (fx+ i 2)]
        [(char=? c #\B) (emit "(?(?<=" W ")(?=" W ")|(?!" W "))") (fx+ i 2)]
        [(char=? c #\Q)
         (let loop ([j (fx+ i 2)])
           (cond
             [(fx>= j n) (emit (substring text i n)) n]
             [(and (char=? (string-ref text j) #\\) (eqv? (at (fx+ j 1)) #\E))
              (emit (substring text i (fx+ j 2))) (fx+ j 2)]
             [else (capital! (string-ref text j)) (loop (fx+ j 1))]))]
        [else (emit-escape i) ]))
    )
  ;; An escape's arguments name no letter the pattern matches, so they
  ;; count no capital.
  (define (emit-escape i)
    (let* ([c (at (fx+ i 1))]
           [end (cond
                  [(and (memv c '(#\x #\o #\N #\p #\P #\g #\k)) (eqv? (at (fx+ i 2)) #\{))
                   (until (fx+ i 3) #\})]
                  [(and (memv c '(#\g #\k)) (memv (at (fx+ i 2)) '(#\< #\')))
                   (until (fx+ i 3) (if (eqv? (at (fx+ i 2)) #\<) #\> #\'))]
                  [(and (memv c '(#\p #\P)) (at (fx+ i 2))) (fx+ i 3)]
                  [(eqv? c #\x)
                   (let loop ([j (fx+ i 2)] [k 0])
                     (if (and (fx< k 2) (at j) (char-numeric? (at j))) (loop (fx+ j 1) (fx+ k 1))
                         (if (and (fx< k 2) (at j) (memv (char-downcase (at j)) '(#\a #\b #\c #\d #\e #\f))) (loop (fx+ j 1) (fx+ k 1)) j)))]
                  [(eqv? c #\c) (fxmin n (fx+ i 3))]
                  [else (fx+ i 2)])])
      (when (memv c '(#\p #\P))
        (let ([name (if (eqv? (at (fx+ i 2)) #\{) (substring text (fx+ i 3) (fxmax (fx+ i 3) (fx- end 1))) (substring text (fx+ i 2) end))])
          (when (case-property? name) (set! exact? #t))))
      (emit (substring text i end))
      end))
  (define (bracket i)
    (let* ([negated? (eqv? (at (fx+ i 1)) #\^)]
           [first (if negated? (fx+ i 2) (fx+ i 1))]
           [inner (open-output-string)])
      (let loop ([j first] [has-W? #f])
        (cond
          [(fx>= j n) (emit (substring text i n)) n]
          [(and (char=? (string-ref text j) #\]) (fx> j first))
           (let ([r (get-output-string inner)])
             (cond
               [(not has-W?) (emit (if negated? "[^" "[") r "]")]
               [negated? (if (string=? r "") (emit W) (emit "(?:(?![" r "])" W ")"))]
               [(string=? r "") (emit N)]
               [else (emit "(?:[" r "]|" N ")")])
             (fx+ j 1))]
          [(and (char=? (string-ref text j) #\[) (eqv? (at (fx+ j 1)) #\:))
           (let* ([end (let find ([k (fx+ j 2)]) (cond [(fx>= (fx+ k 1) n) n]
                                                       [(and (char=? (string-ref text k) #\:) (char=? (string-ref text (fx+ k 1)) #\])) (fx+ k 2)]
                                                       [else (find (fx+ k 1))]))]
                  [name (substring text j end)])
             (when (member name '("[:upper:]" "[:lower:]")) (set! exact? #t))
             (put-string inner name)
             (loop end has-W?))]
          [(char=? (string-ref text j) #\\)
           (let ([c (at (fx+ j 1))])
             (cond
               [(eqv? c #\w) (put-string inner word-contents) (loop (fx+ j 2) has-W?)]
               [(eqv? c #\W) (loop (fx+ j 2) #t)]
               [(eqv? c #\Q)
                (let q ([k (fx+ j 2)])
                  (cond
                    [(fx>= k n) (put-string inner (substring text j n)) (loop n has-W?)]
                    [(and (char=? (string-ref text k) #\\) (eqv? (at (fx+ k 1)) #\E))
                     (put-string inner (substring text j (fx+ k 2))) (loop (fx+ k 2) has-W?)]
                    [else (capital! (string-ref text k)) (q (fx+ k 1))]))]
               [else
                (let* ([saved out])
                  (set! out inner)
                  (let ([end (emit-escape j)])
                    (set! out saved)
                    (loop end has-W?)))]))]
          [else (capital! (string-ref text j)) (put-char inner (string-ref text j)) (loop (fx+ j 1) has-W?)]))))
  (define (group i)
    (cond
      [(eqv? (at (fx+ i 1)) #\*) (let ([end (until i #\))]) (emit (substring text i end)) end)]
      [(not (eqv? (at (fx+ i 1)) #\?)) (emit "(") (fx+ i 1)]
      [else
       (let ([c (at (fx+ i 2))] [d (at (fx+ i 3))])
         (cond
           [(eqv? c #\#) (let ([end (until i #\))]) (emit (substring text i end)) end)]
           [(and (eqv? c #\<) (not (memv d '(#\= #\!)))) (let ([end (until i #\>)]) (emit (substring text i end)) end)]
           [(eqv? c #\') (let ([end (until (fx+ i 3) #\')]) (emit (substring text i end)) end)]
           [(and (eqv? c #\P) (memv d '(#\< #\= #\>)))
            (let ([end (until i (if (eqv? d #\<) #\> #\)))]) (emit (substring text i end)) end)]
           [(eqv? c #\&) (let ([end (until i #\))]) (emit (substring text i end)) end)]
           [(and c (char-alphabetic? c))
            (let loop ([j (fx+ i 2)])
              (if (and (fx< j n) (or (char-alphabetic? (string-ref text j)) (char=? (string-ref text j) #\-) (char=? (string-ref text j) #\^)))
                  (loop (fx+ j 1))
                  (begin (emit (substring text i j)) j)))]
           [else (emit "(?") (fx+ i 2)]))]))
  (define (quantifier? c) (and c (memv c '(#\* #\+ #\? #\{))))
  (let loop ([i 0])
    (when (fx< i n)
      (let ([c (string-ref text i)])
        (cond
          [(char=? c #\\) (loop (escape i))]
          [(char=? c #\[) (loop (bracket i))]
          [(char=? c #\() (loop (group i))]
          [(and lax-run (char=? c #\space))
           (let skip ([j i])
             (if (and (fx< j n) (char=? (string-ref text j) #\space))
                 (skip (fx+ j 1))
                 (begin
                   (if (quantifier? (at j)) (emit (substring text i j)) (emit lax-run))
                   (loop j))))]
          [else (capital! c) (put-char out c) (loop (fx+ i 1))]))))
  (values (get-output-string out) exact?))

(define regexp
  (make-style "Regexp"
    (lambda (text partial? classes)
      (let-values ([(pattern exact?) (%read-regexp text (%classes-%word classes) (classes-whitespace classes))])
        pattern))))

(define-record-type (%query %new-query query?)
  (sealed #t)
  (fields (immutable text query-text) (immutable style query-style) (immutable case query-case)
          (immutable spaces query-spaces) (immutable filter query-filter) (immutable partial? query-partial?)))

(define make-query
  (case-lambda
    [(text) (make-query text literal)]
    [(text style)
     (make-query text style (case-fold)
                 (if (if (eq? style regexp) (regexp-lax-whitespace) (lax-whitespace)) 'lax 'literal))]
    [(text style case) (make-query text style case (if (if (eq? style regexp) (regexp-lax-whitespace) (lax-whitespace)) 'lax 'literal))]
    [(text style case spaces) (make-query text style case spaces #f)]
    [(text style case spaces filter)
     (unless (string? text) (assertion-violation 'search:make-query "not a string" text))
     (unless (style? style) (assertion-violation 'search:make-query "not a style" style))
     (unless (memq case '(smart fold exact)) (assertion-violation 'search:make-query "not a case rule" case))
     (unless (memq spaces '(lax literal)) (assertion-violation 'search:make-query "not a whitespace rule" spaces))
     (unless (or (not filter) (procedure? filter)) (assertion-violation 'search:make-query "neither a procedure nor #f" filter))
     (%new-query text style case spaces filter #f)]))

(define (query-with-filter query filter)
  (unless (query? query) (assertion-violation 'search:query-with-filter "not a query" query))
  (unless (procedure? filter) (assertion-violation 'search:query-with-filter "not a procedure" filter))
  (let ([own (query-filter query)])
    (%new-query (query-text query) (query-style query) (query-case query) (query-spaces query)
                (if own (lambda (b s e) (and (own b s e) (filter b s e))) filter)
                (query-partial? query))))

(define (query-with-partial query)
  (unless (query? query) (assertion-violation 'search:query-with-partial "not a query" query))
  (%new-query (query-text query) (query-style query) (query-case query) (query-spaces query) (query-filter query) #t))

(define (add-to-history! query)
  (unless (query? query) (assertion-violation 'search:add-to-history! "not a query" query))
  (let* ([h (if (eq? (query-style query) regexp) regexp-history history)]
         [text (query-text query)]
         [kept (cons text (remove text (h)))])
    (saved:set! h (if (> (length kept) (history-length)) (list-head kept (history-length)) kept))))

(define (%caseless? query pattern-exact?)
  (let ([c (query-case query)])
    (cond
      [(eq? c 'fold) #t]
      [(eq? c 'exact) #f]
      [(eq? (query-style query) regexp) (not pattern-exact?)]
      [else (not (exists char-upper-case? (string->list (query-text query))))])))

(define-condition-type &pattern-error &error %make-pattern-error pattern-error?
  (offset pattern-error-offset))

(define (pattern-error-description c text)
  (unless (pattern-error? c)
    (assertion-violation 'search:pattern-error-description "not a pattern error" c))
  (unless (string? text)
    (assertion-violation 'search:pattern-error-description "not a string" text))
  (let ([offset (pattern-error-offset c)])
    (cond
      [(not offset) "pattern too complex"]
      [(= offset (string-length text)) "incomplete input"]
      [else (condition-message c)])))

(define (%raise-pattern-error who c)
  (raise (condition (%make-pattern-error (pcre2-error-offset c)) (make-who-condition who)
                    (make-message-condition (condition-message c))
                    (make-irritants-condition (if (irritants-condition? c) (condition-irritants c) '())))))

(define (%pattern buffer query)
  (let ([partial? (query-partial? query)] [classes (%buffer-classes buffer (query-spaces query))] [text (query-text query)])
    (parameterize ([%words-of (syntax:buffer-word-characters buffer)]
                   [%symbols-of (string-append (syntax:buffer-word-characters buffer) (syntax:buffer-symbol-characters buffer))])
      (if (eq? (query-style query) regexp)
          (%read-regexp text (%classes-%word classes) (classes-whitespace classes))
          (values ((%style-procedure (query-style query)) text partial? classes) #f)))))

;; Compiling and its JIT take tens of microseconds, so the codes of the
;; last patterns are kept.
(define %codes '())

(define (%code who pattern caseless?)
  (let ([key (cons pattern caseless?)])
    (cond
      [(assoc key %codes) => cdr]
      [else
       (let ([code (guard (c [(pcre2-error? c) (%raise-pattern-error who c)])
                     (compile-pattern pattern caseless?))])
         (set! %codes (cons (cons key code) (if (> (length %codes) 31) (list-head %codes 31) %codes)))
         code)])))

(define (%compile who buffer query)
  (let-values ([(pattern exact?) (%pattern buffer query)])
    (values pattern (%caseless? query exact?) (%code who pattern (%caseless? query exact?)))))

(define-record-type (%match %make-match match?)
  (sealed #t)
  (fields %offsets))

(define (match-start m)
  (unless (match? m) (assertion-violation 'search:match-start "not a match" m))
  (vector-ref (%match-%offsets m) 0))

(define (match-end m)
  (unless (match? m) (assertion-violation 'search:match-end "not a match" m))
  (vector-ref (%match-%offsets m) 1))

(define (match-group m n)
  (unless (match? m) (assertion-violation 'search:match-group "not a match" m))
  (let ([v (%match-%offsets m)])
    (unless (and (fixnum? n) (fx> n 0) (fx< (fx* 2 n) (vector-length v)))
      (assertion-violation 'search:match-group "not a group of the match's pattern" n))
    (values (vector-ref v (fx* 2 n)) (vector-ref v (fx+ (fx* 2 n) 1)))))

(define (%accepter buffer query)
  (let ([own (query-filter query)] [reported '()] [entries (tables:entries filters)])
    (lambda (start end)
      (define (accepts? predicate)
        (guard (c [(not (cancelled? c))
                   (unless (memq predicate reported)
                     (set! reported (cons predicate reported))
                     (report c))
                   #t])
          (predicate buffer start end)))
      (and (or (not own) (accepts? own))
           (for-all (lambda (e) (accepts? (car e))) entries)))))

(define (expand buffer match template count)
  (define who 'search:expand)
  (unless (buffers:buffer? buffer) (assertion-violation who "not a buffer" buffer))
  (unless (match? match) (assertion-violation who "not a match" match))
  (unless (string? template) (assertion-violation who "not a string" template))
  (unless (and (fixnum? count) (fx>= count 0)) (assertion-violation who "not a count" count))
  (let ([doc (buffers:document buffer)] [v (%match-%offsets match)] [n (string-length template)])
    (define (text-of k)
      (unless (fx< (fx* 2 k) (vector-length v))
        (assertion-violation who "not a group of the match's pattern" k))
      (let ([a (vector-ref v (fx* 2 k))] [z (vector-ref v (fx+ (fx* 2 k) 1))])
        (if a (buffers:text-between doc a z) "")))
    (call-with-string-output-port
      (lambda (out)
        (let loop ([i 0])
          (when (fx< i n)
            (let ([c (string-ref template i)])
              (if (char=? c #\\)
                  (let ([d (and (fx< (fx+ i 1) n) (string-ref template (fx+ i 1)))])
                    (cond
                      [(eqv? d #\&) (put-string out (text-of 0))]
                      [(eqv? d #\#) (put-string out (number->string count))]
                      [(eqv? d #\\) (put-char out #\\)]
                      [(and d (char<=? #\1 d #\9)) (put-string out (text-of (fx- (char->integer d) (char->integer #\0))))]
                      [else (assertion-violation who "a backslash before neither &, #, \\ nor a digit" template)])
                    (loop (fx+ i 2)))
                  (begin (put-char out c) (loop (fx+ i 1)))))))))))

;; A store keeps a scan's matches sorted by start: those from the range's
;; start up to the place the scan began, then those from there on, so
;; each report adds at an end. A report of the first part that reaches
;; into the second replaces the second's matches it covers.
(define-record-type %store
  (sealed #t)
  (fields (mutable front) (mutable front-count) (mutable back) (mutable back-count) (mutable skip)))

(define (%new-store) (make-%store (make-vector 16) 0 (make-vector 16) 0 0))

(define (%store-count s) (fx+ (%store-front-count s) (fx- (%store-back-count s) (%store-skip s))))

(define (%store-ref s i)
  (if (fx< i (%store-front-count s))
      (vector-ref (%store-front s) i)
      (vector-ref (%store-back s) (fx+ (%store-skip s) (fx- i (%store-front-count s))))))

(define (%grown v n)
  (if (fx< n (vector-length v)) v (let ([w (make-vector (fx* 2 (vector-length v)))]) (vector-copy! v 0 w 0 n) w)))

(define (%store-add-front! s e)
  (let ([v (%grown (%store-front s) (%store-front-count s))])
    (vector-set! v (%store-front-count s) e)
    (%store-front-set! s v)
    (%store-front-count-set! s (fx+ (%store-front-count s) 1))))

(define (%store-add-back! s e)
  (let ([v (%grown (%store-back s) (%store-back-count s))])
    (vector-set! v (%store-back-count s) e)
    (%store-back-set! s v)
    (%store-back-count-set! s (fx+ (%store-back-count s) 1))))

(define (%store-drop-back-before! s p)
  (let loop ()
    (when (and (fx< (%store-skip s) (%store-back-count s))
               (fx< (vector-ref (vector-ref (%store-back s) (%store-skip s)) 0) p))
      (%store-skip-set! s (fx+ (%store-skip s) 1))
      (loop))))

(define (%store-search s p)
  (let search ([a 0] [z (%store-count s)])
    (if (fx< a z)
        (let ([m (fxquotient (fx+ a z) 2)])
          (if (fx< (vector-ref (%store-ref s m) 0) p) (search (fx+ m 1) z) (search a m)))
        a)))

(define-record-type (%scan %new-scan scan?)
  (sealed #t)
  (fields buffer (immutable query scan-query) start end seen seen-end position on-update
          (mutable accepted) (mutable refused) (mutable covered) (mutable done?) (mutable version)
          (mutable job) (mutable stopped?) (mutable pattern) (mutable caseless?) (mutable accept)
          (mutable old?) (mutable generation)))

(define %live-scans (make-weak-eq-hashtable))

(jobs:define-worker (%scanner input emit receive)
  (import (document) (pcre2) (search scanning))
  (let* ([doc (vector-ref input 0)] [gathered (vector-ref input 1)] [gathered-to (vector-ref input 9)]
         [code (compile-pattern (vector-ref input 2) (vector-ref input 3))]
         [start (vector-ref input 4)] [end (vector-ref input 5)] [seen (vector-ref input 6)]
         [seen-end (vector-ref input 7)] [position (vector-ref input 8)]
         ;; The copy is made here, off the main thread, and handed back, so
         ;; the finds and scans that follow read it rather than copying
         ;; again.
         [text (or (vector-ref input 10)
                   (let ([t (scan-text doc start end seen seen-end)])
                     (emit (text->report t))
                     t))]
         [chunk 1000])
    ;; The main thread gathers the atoms' texts, since kinds give them only
    ;; there: those up to a piece past end come with the job, and the rest
    ;; only when a match reaching end reads on.
    (define (atoms-of from to)
      (when (fx> to gathered-to)
        (let ([upto (fxmin seen-end (fxmax to (fx+ gathered-to piece-size)))])
          (emit (vector 'atoms gathered-to upto))
          (set! gathered (append gathered (receive)))
          (set! gathered-to upto)))
      (filter (lambda (a) (fx<= from (car a) (fx- to 1))) gathered))
    (define (pass part from to stop?)
      (let ([found '()] [k 0] [chunk-from from] [stopped-at #f])
        (define (flush! upto)
          (emit (vector part chunk-from upto (list->vector (reverse found))))
          (set! found '())
          (set! k 0)
          (set! chunk-from upto))
        (let ([reached
               (scan-pass doc atoms-of text code from to start end seen seen-end
                 (lambda (m)
                   (let ([at (stop? m)])
                     (if at
                         (begin (set! stopped-at at) #f)
                         (begin
                           (set! found (cons m found))
                           (set! k (fx+ k 1))
                           (when (fx= k chunk) (flush! (fx+ (vector-ref m 0) 1)))
                           #t))))
                 #f)])
          (flush! (or stopped-at (fxmax chunk-from (fxmin to reached))))
          reached)))
    ;; The matches near position report first; the part before goes on
    ;; past position until its chain meets the first's, so none is missed
    ;; or found twice.
    (let ([first-starts (make-eqv-hashtable)] [p1 position])
      (when (fx< p1 end)
        (pass 'back p1 end
              (lambda (m)
                (hashtable-set! first-starts (vector-ref m 0) (vector-ref m 1))
                #f)))
      (when (fx< start p1)
        (pass 'front start end
              (lambda (m)
                (and (fx>= (vector-ref m 0) p1)
                     (eqv? (hashtable-ref first-starts (vector-ref m 0) #f) (vector-ref m 1))
                     (vector-ref m 0)))))
      (emit 'done))))

(define (%add-covered covered from to)
  (let loop ([cs (list-sort (lambda (a b) (fx< (car a) (car b))) (cons (cons from to) covered))] [acc '()])
    (cond
      [(null? cs) (reverse acc)]
      [(and (pair? acc) (fx<= (car (car cs)) (cdr (car acc))))
       (loop (cdr cs) (cons (cons (car (car acc)) (fxmax (cdr (car acc)) (cdr (car cs)))) (cdr acc)))]
      [else (loop (cdr cs) (cons (car cs) acc))])))

(define (%covered? scan from to)
  (exists (lambda (c) (and (fx<= (car c) from) (fx<= to (cdr c)))) (%scan-covered scan)))

(define (%scan-range scan)
  (values (buffers:anchor-position (%scan-start scan)) (buffers:anchor-position (%scan-end scan))
          (buffers:anchor-position (%scan-seen scan)) (buffers:anchor-position (%scan-seen-end scan))))

(define (%take-report! scan report doc)
  (cond
    [(and (vector? report) (eq? (vector-ref report 0) 'atoms))
     (jobs:send! (%scan-job scan) (buffers:atom-texts doc (vector-ref report 1) (vector-ref report 2)))]
    [(text-report? report)
     (let ([b (%scan-buffer scan)])
       (when (eq? (buffers:document b) doc)
         (eq-hashtable-set! %texts b (report->text doc report))))]
    [else (%take-matches! scan report)]))

(define (%take-matches! scan report)
  (if (eq? report 'done)
      (%scan-done?-set! scan #t)
      (let ([part (vector-ref report 0)] [from (vector-ref report 1)] [to (vector-ref report 2)]
            [found (vector-ref report 3)] [accept (%scan-accept scan)])
        (when (%scan-old? scan)
          (%scan-old?-set! scan #f)
          (%scan-accepted-set! scan (%new-store))
          (%scan-refused-set! scan (%new-store)))
        (when (eq? part 'front)
          (%store-drop-back-before! (%scan-accepted scan) to)
          (%store-drop-back-before! (%scan-refused scan) to))
        (vector-for-each
          (lambda (m)
            (let ([store (if (accept (vector-ref m 0) (vector-ref m 1)) (%scan-accepted scan) (%scan-refused scan))])
              (if (eq? part 'front) (%store-add-front! store m) (%store-add-back! store m))))
          found)
        (%scan-covered-set! scan (%add-covered (%scan-covered scan) from to))))
  ((%scan-on-update scan) scan))

(define (%scan-stale? scan) (not (fx= (%scan-version scan) (buffers:version (%scan-buffer scan)))))

(define (%start-scan! scan)
  (let ([b (%scan-buffer scan)])
    (let-values ([(start end seen seen-end) (%scan-range scan)])
      (let* ([doc (buffers:document b)] [gathered-to (fxmin seen-end (fx+ end piece-size))]
             [atoms (buffers:atom-texts doc seen gathered-to)]
             [position (fxmax start (fxmin end (buffers:anchor-position (%scan-position scan))))]
             [text (%held-text b doc start end)])
        (%scan-version-set! scan (buffers:version b))
        (%scan-covered-set! scan '())
        (%scan-done?-set! scan #f)
        (%scan-generation-set! scan (fx+ (%scan-generation scan) 1))
        (let ([generation (%scan-generation scan)])
          (%scan-job-set! scan
            (call-as-owner %self
              (lambda ()
                (jobs:start %scanner
                            (vector doc atoms (%scan-pattern scan) (%scan-caseless? scan) start end seen seen-end position gathered-to text)
                            (lambda (report)
                              (when (and (fx= generation (%scan-generation scan)) (not (%scan-stopped? scan)))
                                (%take-report! scan report doc))))))))))))

(define scan
  (case-lambda
    [(buffer query start end position on-update) (scan buffer query start end position on-update start end)]
    [(buffer query start end position on-update seen) (scan buffer query start end position on-update seen end)]
    [(buffer query start end position on-update seen seen-end)
     (define who 'search:scan)
     (%check-range who buffer query start end seen seen-end)
     (unless (and (fixnum? position) (fx>= position 0)) (assertion-violation who "not a position" position))
     (unless (procedure? on-update) (assertion-violation who "not a procedure" on-update))
     (let-values ([(pattern caseless? code) (%compile who buffer query)])
       (let ([s (%new-scan buffer query (buffers:anchor buffer start) (buffers:anchor buffer end)
                           (buffers:anchor buffer seen) (buffers:anchor buffer seen-end)
                           (buffers:anchor buffer (fxmax start (fxmin end position))) on-update
                           (%new-store) (%new-store) '() #f -1 #f #f pattern caseless? (%accepter buffer query) #f 0)])
         (eq-hashtable-set! %live-scans s #t)
         (%start-scan! s)
         s))]))

(define (%check-range who buffer query start end seen seen-end)
  (unless (buffers:buffer? buffer) (assertion-violation who "not a buffer" buffer))
  (unless (query? query) (assertion-violation who "not a query" query))
  (let ([n (document:length (buffers:document buffer))])
    (unless (and (fixnum? seen) (fixnum? start) (fixnum? end) (fixnum? seen-end) (fx<= 0 seen start end seen-end n))
      (assertion-violation who "not a range inside its seen text in the buffer" (list start end seen seen-end)))))

(define (%each-live-scan proc)
  (vector-for-each (lambda (s) (unless (%scan-stopped? s) (proc s))) (hashtable-keys %live-scans)))

(define (scan-done? s)
  (unless (scan? s) (assertion-violation 'search:scan-done? "not a scan" s))
  (and (%scan-done? s) (not (%scan-stale? s))))

(define (scan-count s)
  (unless (scan? s) (assertion-violation 'search:scan-count "not a scan" s))
  (%store-count (%scan-accepted s)))

(define (scan-matches s start end)
  (unless (scan? s) (assertion-violation 'search:scan-matches "not a scan" s))
  (let* ([store (%scan-accepted s)] [n (%store-count store)])
    (let loop ([i (fxmax 0 (fx- (%store-search store start) 1))] [acc '()])
      (if (or (fx= i n) (fx> (vector-ref (%store-ref store i) 0) end))
          (reverse acc)
          (let ([m (%store-ref store i)])
            (loop (fx+ i 1)
                  (if (or (fx> (vector-ref m 1) start) (and (fx= (vector-ref m 0) (vector-ref m 1)) (fx>= (vector-ref m 0) start)))
                      (cons (%make-match m) acc)
                      acc)))))))

(define (scan-index s position)
  (unless (scan? s) (assertion-violation 'search:scan-index "not a scan" s))
  (let ([start (buffers:anchor-position (%scan-start s))])
    (and (not (%scan-stale? s))
         (%covered? s start (fxmax start position))
         (%store-search (%scan-accepted s) position))))

(define (stop-scan! s)
  (unless (scan? s) (assertion-violation 'search:stop-scan! "not a scan" s))
  (%scan-stopped?-set! s #t)
  (when (%scan-job s) (jobs:stop! (%scan-job s))))

;; Old matches follow the edits, so highlights stay in place until the
;; new scan's first report.
(define (%restart-edited-scans!)
  (%each-live-scan
    (lambda (s)
      (when (%scan-stale? s)
        (let ([b (%scan-buffer s)] [version (%scan-version s)])
          (define (moved store)
            (let ([new (%new-store)])
              (do ([i 0 (fx+ i 1)]) ((fx= i (%store-count store)) new)
                (let ([m (%store-ref store i)])
                  (%store-add-front! new (vector-map (lambda (p) (and p (buffers:map-position b p version))) m))))))
          (when (%scan-job s) (jobs:stop! (%scan-job s)))
          (%scan-accepted-set! s (moved (%scan-accepted s)))
          (%scan-refused-set! s (moved (%scan-refused s)))
          (%scan-old?-set! s #t)
          (%start-scan! s)
          ((%scan-on-update s) s))))))

;; A query's matches are fixed by its compiled pattern, its case and its
;; filter; two queries made apart, as each search state makes its own,
;; share a scan when these are the same.
(define (%same-matches? s buffer pattern caseless? query)
  (and (eq? (%scan-buffer s) buffer) (not (%scan-stale? s))
       (string=? (%scan-pattern s) pattern) (eq? (%scan-caseless? s) caseless?)
       (eq? (query-filter (scan-query s)) (query-filter query))))

(define (%running-scan buffer pattern caseless? query start end seen seen-end)
  (call/cc
    (lambda (k)
      (%each-live-scan
        (lambda (s)
          (when (%same-matches? s buffer pattern caseless? query)
            (let-values ([(a z sa sz) (%scan-range s)])
              (when (and (fx= a start) (fx= z end) (fx= sa seen) (fx= sz seen-end))
                (k s))))))
      #f)))

(define (scan-answers? s query)
  (unless (scan? s) (assertion-violation 'search:scan-answers? "not a scan" s))
  (unless (query? query) (assertion-violation 'search:scan-answers? "not a query" query))
  (and (not (%scan-stopped? s))
       (guard (c [(pattern-error? c) #f])
         (let-values ([(pattern caseless? code) (%compile 'search:scan-answers? (%scan-buffer s) query)])
           (%same-matches? s (%scan-buffer s) pattern caseless? query)))))

(define (query-caseless? query buffer)
  (unless (query? query) (assertion-violation 'search:query-caseless? "not a query" query))
  (unless (buffers:buffer? buffer) (assertion-violation 'search:query-caseless? "not a buffer" buffer))
  (let-values ([(pattern exact?) (%pattern buffer query)])
    (%caseless? query exact?)))

(define (query-group-count query buffer)
  (unless (query? query) (assertion-violation 'search:query-group-count "not a query" query))
  (unless (buffers:buffer? buffer) (assertion-violation 'search:query-group-count "not a buffer" buffer))
  (let-values ([(pattern caseless? code) (%compile 'search:query-group-count buffer query)])
    (pcre2-code-group-count code)))

(define (%from-scan s p end)
  (let ([inside? (lambda (store)
                   (let ([i (%store-search store p)])
                     (and (fx> i 0) (fx< p (vector-ref (%store-ref store (fx- i 1)) 1)))))])
    (if (or (inside? (%scan-accepted s)) (inside? (%scan-refused s)))
        'unknown
        (let* ([store (%scan-accepted s)] [i (%store-search store p)]
               [m (and (fx< i (%store-count store)) (%store-ref store i))]
               [upto (if m (vector-ref m 1) end)])
          (if (%covered? s p upto) (if m (%make-match m) #f) 'unknown)))))

(define (%forward buffer query pattern caseless? code position start end seen seen-end accept)
  (let* ([doc (buffers:document buffer)] [atoms (lambda (from to) (buffers:atom-texts doc from to))]
         [s (%running-scan buffer pattern caseless? query start end seen seen-end)] [text (%text-of buffer doc)])
    (let loop ([p position])
      (and (fx<= p end)
           (let ([from-scan (if s (%from-scan s p end) 'unknown)])
             (if (not (eq? from-scan 'unknown))
                 from-scan
                 (let ([m (next-match doc atoms text code p start end seen seen-end piece-size)])
                   (cond
                     [(not m) #f]
                     [(accept (vector-ref m 0) (vector-ref m 1)) (%make-match m)]
                     [(fx= (vector-ref m 0) (vector-ref m 1))
                      (and (fx< (vector-ref m 1) end) (loop (next-character doc (vector-ref m 1))))]
                     [else (loop (vector-ref m 1))]))))))))

;; The last match the filters accept that ends at or before position:
;; each piece back is searched from one character after each match's
;; start, so overlapping matches are found too, and only starts in the
;; piece's new text are tried.
(define (%backward buffer query pattern caseless? code position start end seen seen-end accept)
  (let* ([doc (buffers:document buffer)] [atoms (lambda (from to) (buffers:atom-texts doc from to))]
         [s (%running-scan buffer pattern caseless? query start end seen seen-end)] [text (%text-of buffer doc)]
         [floor (or (and s (%scan-floor s position start)) start)])
    (let piece ([from (fxmax floor (characters-before doc position piece-size floor))] [limit position] [size piece-size])
      (let ([best #f])
        (when (fx<= from position)
          (scan-pass doc atoms text code from (fxmin limit (fx+ position 1)) start position seen seen-end
                     (lambda (m) (when (accept (vector-ref m 0) (vector-ref m 1)) (set! best m)) #t)
                     #t))
        (cond
          [best (%make-match best)]
          [(fx> from floor) (piece (fxmax floor (characters-before doc from size floor)) from (fx* size 2))]
          [else #f])))))

;; Once a scan covers the text before position, no answer starts before
;; the scan's last accepted match that ends at or before position.
(define (%scan-floor s position start)
  (let* ([store (%scan-accepted s)])
    (and (%covered? s start position)
         (let loop ([i (fx- (%store-search store position) 1)])
           (and (fx>= i 0)
                (let ([m (%store-ref store i)])
                  (if (fx<= (vector-ref m 1) position) (vector-ref m 0) (loop (fx- i 1)))))))))

(define find
  (case-lambda
    [(buffer query position direction)
     (unless (buffers:buffer? buffer) (assertion-violation 'search:find "not a buffer" buffer))
     (let ([n (document:length (buffers:document buffer))])
       (find buffer query position direction 0 n 0 n))]
    [(buffer query position direction start end) (find buffer query position direction start end start end)]
    [(buffer query position direction start end seen) (find buffer query position direction start end seen end)]
    [(buffer query position direction start end seen seen-end)
     (define who 'search:find)
     (%check-main-thread who)
     (%check-range who buffer query start end seen seen-end)
     (unless (and (fixnum? position) (fx<= start position end))
       (assertion-violation who "not a position in the range" position))
     (unless (memq direction '(forward backward)) (assertion-violation who "not a direction" direction))
     (let-values ([(pattern caseless? code) (%compile who buffer query)])
       (guard (c [(pcre2-error? c) (%raise-pattern-error who c)])
         ((if (eq? direction 'forward) %forward %backward)
          buffer query pattern caseless? code position start end seen seen-end (%accepter buffer query))))]))

(define %main-thread (get-thread-id))

(define (%check-main-thread who)
  (unless (fx= (get-thread-id) %main-thread) (assertion-violation who "not on the main thread")))

(define-record-type (%highlight %new-highlight highlight?)
  (sealed #t)
  (fields view client (mutable scan) (mutable current) (mutable face) (mutable source)))

(define (%highlight-spans h start end)
  (let* ([current (%highlight-current h)]
         [others (filter (lambda (m) (not (and current (fx= (match-start m) (match-start current)) (fx= (match-end m) (match-end current)))))
                         (let ([scan (%highlight-scan h)]) (if scan (scan-matches scan start end) '())))])
    (append
      (map (lambda (m) (list (match-start m) (match-end m) (list (cons 'face faces:match.other)))) others)
      (if current
          (let ([v (%match-%offsets current)])
            (cons (list (match-start current) (match-end current) (list (cons 'face (%highlight-face h))))
                  (let loop ([k 1] [acc '()])
                    (if (fx>= (fx* 2 k) (vector-length v))
                        (reverse acc)
                        (loop (fx+ k 1)
                              (let ([a (vector-ref v (fx* 2 k))] [z (vector-ref v (fx+ (fx* 2 k) 1))])
                                (if (and a (fx< a z))
                                    (cons (list a z (list (cons 'face (if (odd? k) group-1 group-2)))) acc)
                                    acc)))))))
          '()))))

(define (highlight! view client scan)
  (unless (views:view? view) (assertion-violation 'search:highlight! "not a view" view))
  (unless (or (not scan) (scan? scan)) (assertion-violation 'search:highlight! "neither a scan nor #f" scan))
  (let ([h (%new-highlight view client scan #f faces:match #f)])
    (%highlight-source-set! h
      (lambda (v c start end)
        (if (and (eq? v view) (or (not client) (eq? c client)))
            (%highlight-spans h start end)
            '())))
    (call-as-owner %self (lambda () (tables:set! views:span-sources (%highlight-source h) 1000)))
    h))

(define (set-current! h match face)
  (unless (highlight? h) (assertion-violation 'search:set-current! "not a highlight" h))
  (unless (or (not match) (match? match)) (assertion-violation 'search:set-current! "neither a match nor #f" match))
  (unless (symbol? face) (assertion-violation 'search:set-current! "not a face" face))
  (%highlight-current-set! h match)
  (%highlight-face-set! h face))

(define (set-scan! h scan)
  (unless (highlight? h) (assertion-violation 'search:set-scan! "not a highlight" h))
  (unless (or (not scan) (scan? scan)) (assertion-violation 'search:set-scan! "neither a scan nor #f" scan))
  (%highlight-scan-set! h scan))

(define (end-highlight! h)
  (unless (highlight? h) (assertion-violation 'search:end-highlight! "not a highlight" h))
  (call-as-owner %self (lambda () (tables:remove! views:span-sources (%highlight-source h)))))

;; One copy of the text a scan reads serves its finds and the scans that
;; follow it while a scan of the buffer runs, rather than a copy at each
;; key: over 100 MB, the copy is most of a failing key's time.
(define %texts (make-weak-eq-hashtable))

(define (%text-of buffer doc)
  (let ([t (eq-hashtable-ref %texts buffer #f)])
    (and t (eq? (text-doc t) doc) t)))

(define (%held-text buffer doc start end)
  (let ([t (%text-of buffer doc)])
    (and t (fx<= (text-from t) start) (fx<= end (text-to t)) t)))

(define (%drop-unheld-texts!)
  (vector-for-each
    (lambda (b)
      (let ([t (eq-hashtable-ref %texts b #f)])
        (unless (and (buffers:live? b) (eq? (text-doc t) (buffers:document b))
                     (exists (lambda (s) (and (eq? (%scan-buffer s) b) (not (%scan-stopped? s)))) (vector->list (hashtable-keys %live-scans))))
          (eq-hashtable-delete! %texts b))))
    (hashtable-keys %texts)))

(define (%restart-scans ended)
  (guard (c [(not (cancelled? c)) (report c)])
    (%restart-edited-scans!)
    (%drop-unheld-texts!))
  (ended))

(record-writer (record-type-descriptor %query)
  (lambda (q port write)
    (put-string port "#<query ")
    (let ([d (style-description (query-style q))])
      (unless (string=? d "") (put-string port (string-downcase d)) (put-string port " ")))
    (write (query-text q) port)
    (put-string port ">")))

(record-writer (record-type-descriptor %match)
  (lambda (m port write)
    (put-string port (format "#<match ~a-~a>" (match-start m) (match-end m)))))

(advice-add! batch-ended %restart-scans)
(tables:set! web:stylesheets 'search "search/search.css")
