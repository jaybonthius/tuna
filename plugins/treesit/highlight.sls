(library (treesit highlight)
  (export query-files make-highlight piece-size)
  ;; tree-sitter finds a node's parent by descending from the root, so the
  ;; ancestor predicates read a walk of the queried range instead.
  (import (chezscheme) (document) (except (tree-sitter) node-parent))

  (define (string-prefix? prefix s)
    (let ([n (string-length prefix)])
      (and (fx<= n (string-length s)) (string=? prefix (substring s 0 n)))))

  (define (lua-space? c) (memv c '(#\space #\tab #\newline #\vtab #\page #\return)))

  (define (skip-spaces line i)
    (if (and (fx< i (string-length line)) (lua-space? (string-ref line i))) (skip-spaces line (fx+ i 1)) i))

  (define (blank-from? line i) (fx= (skip-spaces line i) (string-length line)))

  (define (after-semicolons line)
    (let loop ([i 0])
      (if (and (fx< i (string-length line)) (char=? (string-ref line i) #\;)) (loop (fx+ i 1)) i)))

  (define (word-at? line i word)
    (let ([n (string-length word)])
      (and (fx<= (fx+ i n) (string-length line)) (string=? (substring line i (fx+ i n)) word))))

  (define (inherited-names line)
    (let* ([i (skip-spaces line (after-semicolons line))])
      (and (fx> i 0) (word-at? line i "inherits")
           (let* ([i (skip-spaces line (fx+ i 8))]
                  [i (if (and (fx< i (string-length line)) (char=? (string-ref line i) #\:))
                         (skip-spaces line (fx+ i 1))
                         i)]
                  [end (let loop ([j i])
                         (if (and (fx< j (string-length line))
                                  (let ([c (string-ref line j)])
                                    (or (char<=? #\a c #\z) (memv c '(#\_ #\, #\( #\))))))
                             (loop (fx+ j 1))
                             j))])
             (and (fx< i end) (blank-from? line end)
                  (let split ([start i] [j i] [acc '()])
                    (cond
                      [(fx= j end) (reverse (cons (substring line start end) acc))]
                      [(char=? (string-ref line j) #\,)
                       (split (fx+ j 1) (fx+ j 1) (cons (substring line start j) acc))]
                      [else (split start (fx+ j 1) acc)])))))))

  (define (extends-line? line)
    (let ([i (skip-spaces line (after-semicolons line))])
      (and (fx> (after-semicolons line) 0) (word-at? line i "extends") (blank-from? line (fx+ i 7)))))

  (define (modelines path)
    (call-with-input-file path
      (lambda (p)
        (let loop ([acc '()])
          (let ([line (get-line p)])
            (if (and (string? line) (string-prefix? ";" line))
                (loop (cons line acc))
                (reverse acc)))))))

  (define (folder-file folder language kind)
    (let ([n (string-length folder)])
      (format "~a~a~a/~a.scm" folder (if (and (fx> n 0) (char=? (string-ref folder (fx- n 1)) #\/)) "" "/")
        language kind)))

  ;; Extending files come in the reverse of the folders' order, where
  ;; Neovim keeps it, so the first folder's come last and win.
  (define (query-files folders language kind)
    (unless (and (list? folders) (for-all string? folders))
      (assertion-violation 'query-files "not a list of folders" folders))
    (unless (string? language) (assertion-violation 'query-files "not a language's name" language))
    (unless (string? kind) (assertion-violation 'query-files "not a kind of query" kind))
    (let resolve ([language language] [included? #f] [resolving '()])
      (if (member language resolving)
          '()
          (let ([found (fold-left (lambda (acc f) (if (member f acc) acc (append acc (list f))))
                         '()
                         (filter file-exists? (map (lambda (folder) (folder-file folder language kind)) folders)))])
            (let loop ([found found] [base #f] [extensions '()] [inherited '()])
              (if (null? found)
                  (append (apply append (map (lambda (name) (resolve name #t (cons language resolving))) (reverse inherited)))
                          (if base (list base) '())
                          extensions)
                  (let-values ([(extends? names)
                                (let scan ([lines (modelines (car found))] [extends? #f] [names '()])
                                  (cond
                                    [(null? lines) (values extends? names)]
                                    [(inherited-names (car lines))
                                     => (lambda (listed)
                                          (let add ([listed listed] [extends? extends?] [names names])
                                            (if (null? listed)
                                                (scan (cdr lines) extends? names)
                                                (let* ([name (car listed)]
                                                       [optional? (and (fx> (string-length name) 1)
                                                                       (char=? (string-ref name 0) #\())]
                                                       [name (if optional? (substring name 1 (fx- (string-length name) 1)) name)])
                                                  (cond
                                                    [(and optional? included?) (add (cdr listed) extends? names)]
                                                    [(string=? name language) (add (cdr listed) #t names)]
                                                    [else (add (cdr listed) extends? (cons name names))])))))]
                                    [(extends-line? (car lines)) (scan (cdr lines) #t names)]
                                    [else (scan (cdr lines) extends? names)]))])
                    (let ([inherited (append names inherited)])
                      (cond
                        [extends? (loop (cdr found) base (cons (car found) extensions) inherited)]
                        [base (loop (cdr found) base extensions inherited)]
                        [else (loop (cdr found) (car found) extensions inherited)])))))))))


  (define-condition-type &dialect-error &error make-dialect-error dialect-error?
    (position dialect-error-position))

  (define (dialect-fail position message . irritants)
    (raise (condition (make-dialect-error position) (make-who-condition 'treesit)
             (make-message-condition message) (make-irritants-condition irritants))))

  (define-record-type token (sealed #t) (fields kind value start end))

  (define (word-char? c)
    (not (or (char-whitespace? c) (memv c '(#\( #\) #\[ #\] #\" #\;)))))

  (define (read-string-token text i)
    (let ([n (string-length text)] [out (open-output-string)])
      (let loop ([j (fx+ i 1)])
        (cond
          [(fx>= j n) (dialect-fail i "an unclosed string")]
          [(char=? (string-ref text j) #\") (make-token 'string (get-output-string out) i (fx+ j 1))]
          [(and (char=? (string-ref text j) #\\) (fx< (fx+ j 1) n))
           (let ([c (string-ref text (fx+ j 1))])
             (write-char (case c [(#\n) #\newline] [(#\t) #\tab] [(#\r) #\return] [(#\0) #\nul] [else c]) out)
             (loop (fx+ j 2)))]
          [else (write-char (string-ref text j) out) (loop (fx+ j 1))]))))

  (define (skip-blank text i)
    (let ([n (string-length text)])
      (cond
        [(fx>= i n) i]
        [(char-whitespace? (string-ref text i)) (skip-blank text (fx+ i 1))]
        [(char=? (string-ref text i) #\;)
         (let line ([j i]) (if (or (fx>= j n) (char=? (string-ref text j) #\newline)) (skip-blank text j) (line (fx+ j 1))))]
        [else i])))

  (define (read-predicate text i)
    (let* ([n (string-length text)]
           [name-end (let loop ([j (fx+ i 1)]) (if (and (fx< j n) (word-char? (string-ref text j))) (loop (fx+ j 1)) j))]
           [name (make-token 'word (substring text (fx+ i 1) name-end) i name-end)])
      (let loop ([j name-end] [args '()])
        (let ([j (skip-blank text j)])
          (cond
            [(fx>= j n) (dialect-fail i "an unclosed predicate")]
            [(char=? (string-ref text j) #\)) (values name (reverse args) (fx+ j 1))]
            [(char=? (string-ref text j) #\") (let ([t (read-string-token text j)]) (loop (token-end t) (cons t args)))]
            [(memv (string-ref text j) '(#\( #\[ #\])) (dialect-fail j "a predicate's arguments are captures, strings and words")]
            [else
             (let ([end (let w ([k j]) (if (and (fx< k n) (word-char? (string-ref text k))) (w (fx+ k 1)) k))])
               (loop end
                 (cons (if (char=? (string-ref text j) #\@)
                           (make-token 'capture (substring text (fx+ j 1) end) j end)
                           (make-token 'word (substring text j end) j end))
                       args)))])))))

  (define (query-string s)
    (call-with-string-output-port
      (lambda (out)
        (write-char #\" out)
        (string-for-each
          (lambda (c)
            (case c
              [(#\" #\\) (write-char #\\ out) (write-char c out)]
              [(#\newline) (display "\\n" out)]
              [(#\tab) (display "\\t" out)]
              [(#\return) (display "\\r" out)]
              [else (write-char c out)]))
          s)
        (write-char #\" out))))

  (define regex-predicates '("match?" "vim-match?" "lua-match?"))
  (define handled-predicates
    '("eq?" "any-of?" "contains?" "kind-eq?" "has-ancestor?" "has-parent?"))
  (define handled-any-predicates '("eq?" "contains?" "kind-eq?"))

  (define-record-type handled-predicate (sealed #t) (fields name negated? args))

  (define (check-args name position args shapes)
    (unless (let loop ([args args] [shapes shapes])
              (cond
                [(null? shapes) (null? args)]
                [(eq? (car shapes) '...) (for-all (lambda (a) (memq (token-kind a) (cadr shapes))) args)]
                [(null? args) #f]
                [(memq (token-kind (car args)) (car shapes)) (loop (cdr args) (cdr shapes))]
                [else #f]))
      (dialect-fail position (format "wrong arguments to #~a" name))))

  (define text-args '(string word))

  (define (rewrite-predicate name args position handled!)
    (let* ([negated? (and (string-prefix? "not-" name) #t)]
           [base (if negated? (substring name 4 (string-length name)) name)]
           [any? (and (string-prefix? "any-" base) (not (string=? base "any-of?")))]
           [plain (if any? (substring base 4 (string-length base)) base)])
      (cond
        [(member plain regex-predicates)
         (check-args name position args `((capture) (string word)))
         (let ([regex (let ([pattern (token-value (cadr args))])
                        (guard (c [(and (message-condition? c) (dialect-error? c))
                                   (dialect-fail position (condition-message c))])
                          (if (string=? plain "lua-match?") (lua->regex pattern) (vim->regex pattern))))])
           ;; Neovim tests every node of a capture, or any node with any-,
           ;; and negates the whole test with not-.
           (format "#~a @~a ~a"
             (cond
               [(and negated? any?) "not-match?"]
               [negated? "any-not-match?"]
               [any? "any-match?"]
               [else "match?"])
             (token-value (car args)) (query-string regex)))]
        [(or (member base handled-predicates) (and any? (member plain handled-any-predicates)))
         (case plain
           [("eq?") (check-args name position args '((capture) (capture string word)))]
           [("any-of?" "contains?") (check-args name position args `((capture) ... ,text-args))]
           [else (check-args name position args `((capture) (string word) ... ,text-args))])
         (apply string-append
           (format "#treesit-~a?" (handled! (make-handled-predicate (if any? (string-append "any-" plain) plain) negated? args)))
           (map (lambda (a) (format " @~a" (token-value a))) (filter (lambda (a) (eq? (token-kind a) 'capture)) args)))]
        [(string=? name "set!")
         (let* ([capture (and (pair? args) (eq? (token-kind (car args)) 'capture) (car args))]
                [rest (if capture (cdr args) args)])
           (unless (and (pair? rest) (fx<= (length rest) 2) (memq (token-kind (car rest)) text-args))
             (dialect-fail position "wrong arguments to #set!"))
           ;; A value that is a capture, such as a link's url, colours
           ;; nothing, and tree-sitter's library takes one capture only.
           (and (pair? (cdr rest)) (eq? (token-kind (cadr rest)) 'capture)
                (format "#set!~@[ @~a~] ~a" (and capture (token-value capture)) (token-value (car rest)))))]
        [(string=? name "offset!")
         (check-args name position args '((capture) ... (word)))
         (unless (and (fx<= (length args) 5)
                      (for-all (lambda (a) (let ([v (string->number (token-value a))]) (and (fixnum? v)))) (cdr args)))
           (dialect-fail position "#offset! takes a capture and up to four integers"))
         #f]
        [(string=? name "trim!")
         (check-args name position args '((capture) ... (word string)))
         (unless (and (memv (length args) '(1 5))
                      (for-all (lambda (a) (member (token-value a) '("0" "1"))) (cdr args)))
           (dialect-fail position "#trim! takes a capture and none or four of 0 and 1"))
         #f]
        [(string=? name "gsub!")
         (check-args name position args '((capture) (string word) (string word)))
         #f]
        [(string-suffix? "!" name) (dialect-fail position (format "unknown directive #~a" name))]
        [else (dialect-fail position (format "unknown predicate #~a" name))])))

  (define (string-suffix? suffix s)
    (let ([n (string-length suffix)] [m (string-length s)])
      (and (fx<= n m) (string=? suffix (substring s (fx- m n) m)))))

  (define-record-type replacement (sealed #t) (fields from to new-from new-to))

  (define (rewrite-query text first)
    (let ([n (string-length text)] [out (open-output-string)] [handled '()] [count first] [replaced '()])
      (define (handled! p)
        (set! handled (cons (cons count p) handled))
        (set! count (fx+ count 1))
        (fx- count 1))
      (let loop ([i 0] [copied 0] [written 0])
        (define (finish)
          (display (substring text copied n) out)
          (values (get-output-string out) (reverse handled) count (reverse replaced)))
        (cond
          [(fx>= i n) (finish)]
          [(char=? (string-ref text i) #\;)
           (let line ([j i]) (if (or (fx>= j n) (char=? (string-ref text j) #\newline)) (loop j copied written) (line (fx+ j 1))))]
          [(char=? (string-ref text i) #\") (loop (token-end (read-string-token text i)) copied written)]
          [(and (char=? (string-ref text i) #\() (let ([j (skip-blank text (fx+ i 1))]) (and (fx< j n) (char=? (string-ref text j) #\#) j)))
           => (lambda (hash)
                (let-values ([(name args end) (read-predicate text hash)])
                  (let ([new (rewrite-predicate (token-value name) args hash handled!)])
                    (if new
                        (let ([close (fx- end 1)])
                          ;; Only the form's head and arguments are replaced; the
                          ;; parentheses and the lines inside stay, so rows hold.
                          (display (substring text copied hash) out)
                          (display new out)
                          (display (make-string (count-newlines text hash close) #\newline) out)
                          (let ([written (fx+ written (fx- hash copied))])
                            (let ([new-to (fx+ written (string-length new) (count-newlines text hash close))])
                              (set! replaced (cons (make-replacement hash close written new-to) replaced))
                              (loop end close new-to))))
                        (loop end copied written)))))]
          [else (loop (fx+ i 1) copied written)]))))

  (define (count-newlines text from to)
    (let loop ([i from] [k 0])
      (if (fx>= i to) k (loop (fx+ i 1) (if (char=? (string-ref text i) #\newline) (fx+ k 1) k)))))

  (define (original-index replacements index)
    (let loop ([rs replacements] [shift 0])
      (cond
        [(or (null? rs) (fx< index (replacement-new-from (car rs)))) (fx- index shift)]
        [(fx< index (replacement-new-to (car rs))) (replacement-from (car rs))]
        [else (loop (cdr rs) (fx- (replacement-new-to (car rs)) (replacement-to (car rs))))])))

  ;; tree-sitter's library reads Rust's syntax and translates it to POSIX;
  ;; these write that syntax, so a construct POSIX lacks fails here.

  (define regex-special (string->list ".[]()*+?{}|^$\\"))

  (define (put-literal c out)
    (when (memv c regex-special) (write-char #\\ out))
    (write-char c out))

  (define (no-translation construct)
    (raise (condition (make-dialect-error #f) (make-message-condition
                                                (format "~a has no POSIX translation" construct)))))

  (define (lua-class c)
    (case (char-downcase c)
      [(#\a) "alpha"] [(#\c) "cntrl"] [(#\d) "digit"] [(#\g) "graph"] [(#\l) "lower"] [(#\p) "punct"]
      [(#\s) "space"] [(#\u) "upper"] [(#\w) "alnum"] [(#\x) "xdigit"] [else #f]))

  (define (bracket-member c)
    (if (memv c '(#\] #\- #\^ #\\ #\[)) (string #\\ c) (string c)))

  (define (lua->regex pattern)
    (let ([n (string-length pattern)])
      (call-with-string-output-port
        (lambda (out)
          (define (check-ascii c)
            (when (char>? c #\x7f) (no-translation "a quantifier after a non-ASCII character in a Lua pattern")))
          ;; Lua quantifies only a single-character item; elsewhere a
          ;; quantifier character is itself.
          (let loop ([i 0] [item #f])
            (when (fx< i n)
              (let ([c (string-ref pattern i)])
                (cond
                  [(and item (memv c '(#\* #\+ #\? #\-)))
                   (check-ascii item)
                   (write-char (if (char=? c #\-) #\* c) out)
                   (loop (fx+ i 1) #f)]
                  [(and (fx= i 0) (char=? c #\^)) (write-char #\^ out) (loop 1 #f)]
                  [(and (fx= i (fx- n 1)) (char=? c #\$)) (write-char #\$ out) (loop n #f)]
                  [(char=? c #\%)
                   (when (fx= (fx+ i 1) n) (no-translation "a Lua pattern ending in %"))
                   (let ([e (string-ref pattern (fx+ i 1))])
                     (cond
                       [(lua-class e)
                        => (lambda (class)
                             (display (if (char-upper-case? e) (format "[^[:~a:]]" class) (format "[[:~a:]]" class)) out)
                             (loop (fx+ i 2) #\a))]
                       [(or (char-alphabetic? e) (char-numeric? e)) (no-translation (format "Lua's %~a" e))]
                       [else (put-literal e out) (loop (fx+ i 2) e)]))]
                  [(char=? c #\[) (loop (lua-set pattern (fx+ i 1) out) #\a)]
                  [(char=? c #\()
                   (if (and (fx< (fx+ i 1) n) (char=? (string-ref pattern (fx+ i 1)) #\)))
                       (loop (fx+ i 2) #f)
                       (begin (write-char #\( out) (loop (fx+ i 1) #f)))]
                  [(char=? c #\)) (write-char #\) out) (loop (fx+ i 1) #f)]
                  [(char=? c #\.) (write-char #\. out) (loop (fx+ i 1) c)]
                  [else (put-literal c out) (loop (fx+ i 1) c)]))))))))

  ;; As in Lua, a ] just after the [ or [^ is a member.
  (define (lua-set pattern i out)
    (let* ([n (string-length pattern)]
           [negated? (and (fx< i n) (char=? (string-ref pattern i) #\^))]
           [i (if negated? (fx+ i 1) i)])
      (write-char #\[ out)
      (when negated? (write-char #\^ out))
      (let loop ([i i] [first? #t])
        (when (fx>= i n) (no-translation "an unclosed [ in a Lua pattern"))
        (let ([c (string-ref pattern i)])
          (cond
            [(and (char=? c #\]) (not first?)) (write-char #\] out) (fx+ i 1)]
            [(char=? c #\%)
             (when (fx= (fx+ i 1) n) (no-translation "a Lua pattern ending in %"))
             (let ([e (string-ref pattern (fx+ i 1))])
               (cond
                 [(lua-class e)
                  => (lambda (class)
                       (when (char-upper-case? e) (no-translation (format "Lua's %~a in a set" e)))
                       (display (format "[:~a:]" class) out))]
                 [(or (char-alphabetic? e) (char-numeric? e)) (no-translation (format "Lua's %~a" e))]
                 [else (display (bracket-member e) out)])
               (loop (fx+ i 2) #f))]
            [(char>? c #\x7f) (no-translation "a non-ASCII character in a set")]
            [(and (fx< (fx+ i 2) n) (char=? (string-ref pattern (fx+ i 1)) #\-) (not (char=? (string-ref pattern (fx+ i 2)) #\])))
             (let ([hi (string-ref pattern (fx+ i 2))])
               (when (or (memv c '(#\] #\- #\^ #\\ #\[)) (memv hi '(#\] #\- #\^ #\\ #\[)) (char>? hi #\x7f))
                 (no-translation "a range of special characters in a set"))
               (write-char c out) (write-char #\- out) (write-char hi out)
               (loop (fx+ i 3) #f))]
            [else (display (bracket-member c) out) (loop (fx+ i 1) #f)])))))

  (define vim-classes
    '((#\d . "0-9") (#\w . "0-9A-Za-z_") (#\a . "A-Za-z") (#\l . "a-z") (#\u . "A-Z")
      (#\x . "0-9A-Fa-f") (#\h . "A-Za-z_") (#\o . "0-7") (#\s . " \t")))

  ;; Neovim's match? is Vim's regular expression, very magic unless it
  ;; starts with another mode.
  (define (vim->regex pattern)
    (when (and (fx>= (string-length pattern) 2) (char=? (string-ref pattern 0) #\\) (memv (string-ref pattern 1) '(#\m #\M #\V)))
      (no-translation (format "Vim's \\~a mode" (string-ref pattern 1))))
    (let* ([n (string-length pattern)]
           [start (if (and (fx>= n 2) (char=? (string-ref pattern 0) #\\) (char=? (string-ref pattern 1) #\v)) 2 0)]
           [fold? (let loop ([i start])
                    (cond
                      [(fx>= (fx+ i 1) n) #f]
                      [(char=? (string-ref pattern i) #\\)
                       (or (char=? (string-ref pattern (fx+ i 1)) #\c) (loop (fx+ i 2)))]
                      [else (loop (fx+ i 1))]))])
      (call-with-string-output-port
        (lambda (out)
          (define (letter c)
            (if (and fold? (char-alphabetic? c) (char<=? c #\x7f))
                (format "[~a~a]" (char-downcase c) (char-upcase c))
                (string c)))
          (define (class c)
            (let ([members (cdr (assv (char-downcase c) vim-classes))])
              (display (format (if (char-upper-case? c) "[^~a]" "[~a]") (if (char=? (char-downcase c) #\s) " \\t" members)) out)))
          ;; ^ is an anchor where Vim reads one: first, or after | or (.
          (let loop ([i start] [anchor? #t])
            (when (fx< i n)
              (let ([c (string-ref pattern i)] [at-end? (or (fx= (fx+ i 1) n) (memv (string-ref pattern (fx+ i 1)) '(#\| #\))))])
                (cond
                  [(char=? c #\\)
                   (when (fx= (fx+ i 1) n) (no-translation "a trailing \\"))
                   (let ([e (string-ref pattern (fx+ i 1))])
                     (cond
                       [(memv e '(#\c #\C)) (loop (fx+ i 2) anchor?)]
                       [(assv (char-downcase e) vim-classes) (class e) (loop (fx+ i 2) #f)]
                       [(char=? e #\n) (display "\\n" out) (loop (fx+ i 2) #f)]
                       [(char=? e #\t) (display "\\t" out) (loop (fx+ i 2) #f)]
                       [(char=? e #\r) (display "\\r" out) (loop (fx+ i 2) #f)]
                       [(char=? e #\e) (write-char #\x1b out) (loop (fx+ i 2) #f)]
                       [(or (char-alphabetic? e) (char-numeric? e) (char=? e #\_)) (no-translation (format "Vim's \\~a" e))]
                       [else (put-literal e out) (loop (fx+ i 2) #f)]))]
                  [(and (char=? c #\^) anchor?) (write-char #\^ out) (loop (fx+ i 1) #f)]
                  [(and (char=? c #\$) at-end?) (write-char #\$ out) (loop (fx+ i 1) #f)]
                  [(memv c '(#\( #\|)) (write-char c out) (loop (fx+ i 1) #t)]
                  [(and (char=? c #\%) (fx< (fx+ i 1) n) (char=? (string-ref pattern (fx+ i 1)) #\())
                   (write-char #\( out) (loop (fx+ i 2) #t)]
                  [(memv c '(#\) #\* #\+ #\?)) (write-char c out) (loop (fx+ i 1) #f)]
                  [(char=? c #\=) (write-char #\? out) (loop (fx+ i 1) #f)]
                  [(char=? c #\.) (display "[^\\n]" out) (loop (fx+ i 1) #f)]
                  [(char=? c #\<) (display "\\<" out) (loop (fx+ i 1) #f)]
                  [(char=? c #\>) (display "\\>" out) (loop (fx+ i 1) #f)]
                  [(char=? c #\{) (loop (vim-count pattern (fx+ i 1) out) #f)]
                  [(char=? c #\[) (loop (vim-collection pattern (fx+ i 1) out fold?) #f)]
                  [(memv c '(#\% #\@ #\~ #\&)) (no-translation (format "Vim's ~a" c))]
                  [else (display (if (char-alphabetic? c) (letter c) (let ([s (open-output-string)]) (put-literal c s) (get-output-string s))) out)
                        (loop (fx+ i 1) #f)]))))))))

  (define (vim-count pattern i out)
    (let* ([n (string-length pattern)]
           [close (let loop ([j i]) (cond [(fx>= j n) (no-translation "an unclosed { in a Vim pattern")]
                                          [(char=? (string-ref pattern j) #\}) j]
                                          [else (loop (fx+ j 1))]))]
           [body (let ([b (substring pattern i close)]) (if (string-prefix? "-" b) (substring b 1 (string-length b)) b))]
           [body (if (and (fx> (string-length body) 0) (char=? (string-ref body (fx- (string-length body) 1)) #\\))
                     (substring body 0 (fx- (string-length body) 1))
                     body)])
      (unless (for-all (lambda (c) (or (char-numeric? c) (char=? c #\,))) (string->list body))
        (no-translation "a count other than digits and a comma"))
      (cond
        [(or (string=? body "") (string=? body ",")) (write-char #\* out)]
        [(string-prefix? "," body) (display (format "{0~a}" body) out)]
        [else (display (format "{~a}" body) out)])
      (fx+ close 1)))

  (define (vim-collection pattern i out fold?)
    (let* ([n (string-length pattern)]
           [negated? (and (fx< i n) (char=? (string-ref pattern i) #\^))]
           [i (if negated? (fx+ i 1) i)])
      (write-char #\[ out)
      (when negated? (write-char #\^ out))
      (let loop ([i i] [first? #t])
        (when (fx>= i n) (no-translation "an unclosed [ in a Vim pattern"))
        (let ([c (string-ref pattern i)])
          (cond
            [(and (char=? c #\]) (not first?)) (write-char #\] out) (fx+ i 1)]
            [(and (char=? c #\[) (fx< (fx+ i 1) n) (char=? (string-ref pattern (fx+ i 1)) #\:))
             (let find ([j (fx+ i 2)])
               (cond
                 [(fx>= (fx+ j 1) n) (no-translation "an unclosed [: in a Vim pattern")]
                 [(and (char=? (string-ref pattern j) #\:) (char=? (string-ref pattern (fx+ j 1)) #\]))
                  (display (substring pattern i (fx+ j 2)) out)
                  (loop (fx+ j 2) #f)]
                 [else (find (fx+ j 1))]))]
            [(char=? c #\\)
             (when (fx= (fx+ i 1) n) (no-translation "a trailing \\"))
             (let ([e (string-ref pattern (fx+ i 1))])
               (case e
                 [(#\n) (display "\\n" out)]
                 [(#\t) (display "\\t" out)]
                 [(#\r) (display "\\r" out)]
                 [(#\e) (write-char #\x1b out)]
                 [(#\\ #\] #\^ #\-) (display (bracket-member e) out)]
                 [else (no-translation (format "Vim's \\~a in a collection" e))])
               (loop (fx+ i 2) #f))]
            [(char>? c #\x7f) (no-translation "a non-ASCII character in a collection")]
            [(and (fx< (fx+ i 2) n) (char=? (string-ref pattern (fx+ i 1)) #\-) (not (char=? (string-ref pattern (fx+ i 2)) #\])))
             (let ([hi (string-ref pattern (fx+ i 2))])
               (when (or (memv c '(#\] #\- #\^ #\\ #\[)) (memv hi '(#\] #\- #\^ #\\ #\[)) (char>? hi #\x7f))
                 (no-translation "a range of special characters in a collection"))
               (write-char c out) (write-char #\- out) (write-char hi out)
               (when (and fold? (char-alphabetic? c) (char-alphabetic? hi) (char<=? c #\x7f))
                 (if (char-lower-case? c)
                     (begin (write-char (char-upcase c) out) (write-char #\- out) (write-char (char-upcase hi) out))
                     (begin (write-char (char-downcase c) out) (write-char #\- out) (write-char (char-downcase hi) out))))
               (loop (fx+ i 3) #f))]
            [else
             (display (bracket-member c) out)
             (when (and fold? (char-alphabetic? c) (char<=? c #\x7f))
               (write-char (if (char-lower-case? c) (char-upcase c) (char-downcase c)) out))
             (loop (fx+ i 1) #f)])))))

  ;; tree-sitter counts bytes, a job's spans characters, and an edit's
  ;; points rows; where each chunk starts in all three spares a scan from
  ;; the start.
  (define-record-type source
    (sealed #t)
    (fields bytes byte-starts char-starts line-starts))

  (define (continuation? b) (fx= (fxand b #xc0) #x80))

  (define (document-source doc)
    (let-values ([(port extract) (open-bytevector-output-port)])
      (let ([bytes '()] [chars '()] [lines '()] [b 0] [c 0] [l 0])
        (document:for-each-utf8-chunk doc 0 (document:length doc)
          (lambda (bv from to)
            (set! bytes (cons b bytes)) (set! chars (cons c chars)) (set! lines (cons l lines))
            (put-bytevector port bv from (fx- to from))
            (set! b (fx+ b (fx- to from)))
            ;; A raw byte stands for a character of its own, whatever its
            ;; value.
            (set! c (fx+ c (if (fx= (fx- to from) 1)
                               1
                               (let loop ([i from] [k 0])
                                 (if (fx= i to) k (loop (fx+ i 1) (if (continuation? (bytevector-u8-ref bv i)) k (fx+ k 1))))))))
            (set! l (fx+ l (let loop ([i from] [k 0])
                             (if (fx= i to) k (loop (fx+ i 1) (if (fx= (bytevector-u8-ref bv i) 10) (fx+ k 1) k))))))))
        (make-source (extract)
          (list->fxvector (reverse (cons b bytes)))
          (list->fxvector (reverse (cons c chars)))
          (list->fxvector (reverse (cons l lines)))))))

  (define (source-length s) (bytevector-length (source-bytes s)))

  (define (chunk-of starts x)
    (let loop ([lo 0] [hi (fx- (fxvector-length starts) 1)])
      (if (fx>= lo hi)
          lo
          (let ([mid (fxsrl (fx+ lo hi 1) 1)])
            (if (fx<= (fxvector-ref starts mid) x) (loop mid hi) (loop lo (fx- mid 1)))))))

  (define (chunk-raw-byte? s k)
    (and (fx= (fx- (fxvector-ref (source-byte-starts s) (fx+ k 1)) (fxvector-ref (source-byte-starts s) k)) 1)
         (fx= (fx- (fxvector-ref (source-char-starts s) (fx+ k 1)) (fxvector-ref (source-char-starts s) k)) 1)))

  (define (byte->char s byte)
    (let* ([k (chunk-of (source-byte-starts s) byte)]
           [from (fxvector-ref (source-byte-starts s) k)]
           [c (fxvector-ref (source-char-starts s) k)])
      (if (and (fx> byte from) (chunk-raw-byte? s k))
          (fx+ c 1)
          (let loop ([i from] [c c])
            (if (fx>= i byte) c (loop (fx+ i 1) (if (continuation? (bytevector-u8-ref (source-bytes s) i)) c (fx+ c 1))))))))

  (define (char->byte s char)
    (let* ([k (chunk-of (source-char-starts s) char)]
           [from (fxvector-ref (source-byte-starts s) k)]
           [c (fxvector-ref (source-char-starts s) k)]
           [bv (source-bytes s)] [n (bytevector-length bv)])
      (if (and (fx> char c) (chunk-raw-byte? s k))
          (fx+ from 1)
          (let loop ([i from] [c c])
            (cond
              [(fx>= i n) n]
              [(and (fx= c char) (not (continuation? (bytevector-u8-ref bv i)))) i]
              [else (loop (fx+ i 1) (if (continuation? (bytevector-u8-ref bv i)) c (fx+ c 1)))])))))

  (define (byte->point s byte)
    (let* ([k (chunk-of (source-byte-starts s) byte)]
           [bv (source-bytes s)]
           [row (let loop ([i (fxvector-ref (source-byte-starts s) k)] [row (fxvector-ref (source-line-starts s) k)])
                  (if (fx>= i byte) row (loop (fx+ i 1) (if (fx= (bytevector-u8-ref bv i) 10) (fx+ row 1) row))))]
           [line-start (let loop ([i byte]) (if (or (fx= i 0) (fx= (bytevector-u8-ref bv (fx- i 1)) 10)) i (loop (fx- i 1))))])
      (make-point row (fx- byte line-start))))

  (define (moved-by-rows s byte rows columns)
    (let* ([bv (source-bytes s)] [n (bytevector-length bv)]
           [line-start (let loop ([i byte]) (if (or (fx= i 0) (fx= (bytevector-u8-ref bv (fx- i 1)) 10)) i (loop (fx- i 1))))])
      (if (fx= rows 0)
          (fxmax 0 (fxmin n (fx+ byte columns)))
          (let loop ([i line-start] [rows rows] [columns (fx+ (fx- byte line-start) columns)])
            (cond
              [(fx> rows 0)
               (let next ([j i]) (cond [(fx>= j n) n] [(fx= (bytevector-u8-ref bv j) 10) (loop (fx+ j 1) (fx- rows 1) columns)] [else (next (fx+ j 1))]))]
              [(fx< rows 0)
               (if (fx= i 0)
                   (fxmax 0 (fxmin n columns))
                   (let back ([j (fx- i 1)]) (if (or (fx= j 0) (fx= (bytevector-u8-ref bv (fx- j 1)) 10)) (loop j (fx+ rows 1) columns) (back (fx- j 1)))))]
              [else (fxmax 0 (fxmin n (fx+ i columns)))])))))

  (define-record-type highlights
    (sealed #t)
    (fields query language priorities capture-priorities directives faces watched
            (mutable walk-table) (mutable walk-root) (mutable source)))

  (define-record-type query-text (sealed #t) (fields file text rewritten predicates replacements))

  ;; tree-sitter's errors count bytes of the rewritten text and add the row
  ;; and column to the message; the problem gives the file's own.
  (define (query-problem q c)
    (let* ([bytes (string->utf8 (query-text-rewritten q))]
           [before (utf8->string (subbytevector bytes 0 (fxmin (query-error-offset c) (bytevector-length bytes))))]
           [index (original-index (query-text-replacements q) (string-length before))])
      (located-problem (query-text-file q) (query-text-text q) index
        (let* ([m (condition-message c)] [cut (find-last " at row " m)]) (if cut (substring m 0 cut) m)))))

  (define (subbytevector bv from to)
    (let ([out (make-bytevector (fx- to from))]) (bytevector-copy! bv from out 0 (fx- to from)) out))

  (define (find-last needle s)
    (let ([n (string-length needle)])
      (let loop ([i (fx- (string-length s) n)])
        (cond
          [(fx< i 0) #f]
          [(string=? needle (substring s i (fx+ i n))) i]
          [else (loop (fx- i 1))]))))

  ;; A problem names its file, the row counted from 1 and the column from
  ;; 0, as editors show them.
  (define (located-problem file text index message)
    (let loop ([i 0] [row 1] [column 0])
      (if (fx>= i (fxmin index (string-length text)))
          (list 'query-error file row column message)
          (if (char=? (string-ref text i) #\newline) (loop (fx+ i 1) (fx+ row 1) 0) (loop (fx+ i 1) row (fx+ column 1))))))

  (define (read-file path) (call-with-input-file path get-string-all))

  (define (compile-highlights language files)
    (let loop ([files files] [first 0] [entries '()] [problems '()])
      (if (pair? files)
          (let ([file (car files)])
            (guard (c [(dialect-error? c)
                       (loop (cdr files) first entries
                         (cons (located-problem file (read-file file) (or (dialect-error-position c) 0) (condition-message c)) problems))]
                      [(i/o-error? c)
                       (loop (cdr files) first entries
                         (cons (list 'query-error file 1 0 (condition-message c)) problems))])
              (let ([text (read-file file)])
                (let-values ([(rewritten predicates next replacements) (rewrite-query text first)])
                  (loop (cdr files) next (cons (make-query-text file text rewritten predicates replacements) entries) problems)))))
          ;; The files are compiled one by one only when all of them together
          ;; fail, so a good query costs one compile.
          (let* ([entries (reverse entries)]
                 [whole (and (pair? entries) (guard (c [(query-error? c) #f]) (build-highlights language entries)))])
            (if (or whole (null? entries))
                (values whole (reverse problems))
                (let check ([es entries] [kept '()] [problems (reverse problems)])
                  (if (null? es)
                      (values (and (pair? kept) (build-highlights language (reverse kept))) problems)
                      (let ([failure (guard (c [(query-error? c) c])
                                       (make-query language (query-text-rewritten (car es)) (lambda (name args) #f))
                                       #f)])
                        (if failure
                            (check (cdr es) kept (append problems (list (query-problem (car es) failure))))
                            (check (cdr es) (cons (car es) kept) problems))))))))))

  (define (build-highlights language entries)
    (let* ([predicates (let ([t (make-eqv-hashtable)])
                         (for-each (lambda (e) (for-each (lambda (p) (hashtable-set! t (car p) (cdr p))) (query-text-predicates e)))
                           entries)
                         t)]
           [watched (fold-left (lambda (acc p)
                                 (if (string=? (handled-predicate-name p) "has-ancestor?")
                                     (fold-left (lambda (acc t) (if (member t acc) acc (append acc (list t))))
                                       acc (map token-value (cdr (handled-predicate-args p))))
                                     acc))
                      '() (vector->list (hashtable-values predicates)))]
           [h #f]
           [tests (make-eq-hashtable)]
           [query (make-query language (apply string-append (map query-text-rewritten entries))
                    (lambda (name args)
                      ((or (eq-hashtable-ref tests name #f)
                           (let ([t (predicate-test
                                      (hashtable-ref predicates (string->number (substring name 8 (fx- (string-length name) 1))) #f)
                                      (lambda () h))])
                             (eq-hashtable-set! tests name t)
                             t))
                       args)))]
           [count (query-pattern-count query)])
      (set! h (make-highlights query language
                (let ([v (make-vector count 100)])
                  (do ([p 0 (fx+ p 1)]) ((fx= p count) v)
                    (for-each
                      (lambda (s)
                        (when (and (string=? (query-property-key s) "priority") (not (query-property-capture s)))
                          (let ([n (and (query-property-value s) (string->number (query-property-value s)))])
                            (when (real? n) (vector-set! v p n)))))
                      (query-pattern-settings query p))))
                (let ([v (make-vector count '())])
                  (do ([p 0 (fx+ p 1)]) ((fx= p count) v)
                    (vector-set! v p
                      (fold-right
                        (lambda (s acc)
                          (let ([n (and (string=? (query-property-key s) "priority") (query-property-capture s)
                                        (query-property-value s) (string->number (query-property-value s)))])
                            (if (real? n) (cons (cons (query-property-capture s) n) acc) acc)))
                        '() (query-pattern-settings query p)))))
                (let ([v (make-vector count '())])
                  (do ([p 0 (fx+ p 1)]) ((fx= p count) v)
                    (vector-set! v p (filter (lambda (d) (member (car d) '("offset!" "trim!"))) (query-pattern-directives query p)))))
                (list->vector (map face-of (query-capture-names query)))
                (list->vector watched) #f #f #f))
      h))

  (define (face-of name)
    (if (or (fx= (string-length name) 0) (char=? (string-ref name 0) #\_)
            (member name '("spell" "nospell" "conceal" "noconceal")))
        #f
        (string->symbol name)))

  (define (node-bytes=? bv node text)
    (let ([s (node-start-byte node)] [e (node-end-byte node)])
      (and (fx= (fx- e s) (bytevector-length text))
           (let loop ([i 0])
             (or (fx= i (bytevector-length text))
                 (and (fx= (bytevector-u8-ref bv (fx+ s i)) (bytevector-u8-ref text i)) (loop (fx+ i 1))))))))

  (define (node-contains? bv node text)
    (let ([s (node-start-byte node)] [e (node-end-byte node)] [m (bytevector-length text)])
      (let loop ([i s])
        (and (fx<= (fx+ i m) e)
             (or (let same ([j 0]) (or (fx= j m) (and (fx= (bytevector-u8-ref bv (fx+ i j)) (bytevector-u8-ref text j)) (same (fx+ j 1)))))
                 (loop (fx+ i 1)))))))

  (define (node-bytes bv node)
    (let ([s (node-start-byte node)]) (subbytevector bv s (node-end-byte node))))

  ;; Neovim's test of a capture with no node passes, and not- negates the
  ;; whole test, so (#not-eq? @a "x") of no node fails.
  (define (every-or-any any? nodes ok?)
    (or (null? nodes) (if any? (and (exists ok? nodes) #t) (for-all ok? nodes))))

  (define (predicate-test p highlights)
    (let* ([name (handled-predicate-name p)] [negated? (handled-predicate-negated? p)]
           [any? (string-prefix? "any-" name)]
           [base (if (and any? (not (string=? name "any-of?"))) (substring name 4 (string-length name)) name)]
           [strings (map token-value (cdr (handled-predicate-args p)))]
           [texts (map string->utf8 strings)]
           [test
            (case base
              [("eq?")
               (if (eq? (token-kind (cadr (handled-predicate-args p))) 'capture)
                   (lambda (bv args)
                     (let ([other (cadr args)])
                       (every-or-any any? (car args)
                         (lambda (n) (and (pair? other) (bytevector=? (node-bytes bv n) (node-bytes bv (car other))))))))
                   (let ([text (car texts)])
                     (lambda (bv args) (every-or-any any? (car args) (lambda (n) (node-bytes=? bv n text))))))]
              [("any-of?")
               (let ([set (make-hashtable equal-hash equal?)] [lengths (map bytevector-length texts)])
                 (for-each (lambda (t) (hashtable-set! set t #t)) texts)
                 (lambda (bv args)
                   (every-or-any #t (car args)
                     (lambda (n)
                       (and (memv (fx- (node-end-byte n) (node-start-byte n)) lengths)
                            (hashtable-ref set (node-bytes bv n) #f))))))]
              [("contains?")
               (lambda (bv args)
                 (every-or-any any? (car args)
                   (lambda (n) ((if any? exists for-all) (lambda (t) (node-contains? bv n t)) texts))))]
              [("kind-eq?")
               (lambda (bv args) (every-or-any any? (car args) (lambda (n) (and (member (node-type n) strings) #t))))]
              [("has-ancestor?")
               (let ([mask #f])
                 (lambda (bv args)
                   (unless mask (set! mask (watched-mask (highlights) strings)))
                   (every-or-any #t (car args) (lambda (n) (not (eqv? 0 (logand mask (walked-ancestors (highlights) n))))))))]
              [("has-parent?")
               (lambda (bv args)
                 (every-or-any #t (car args)
                   (lambda (n) (let ([parent (walked-parent-type (highlights) n)]) (and parent (member parent strings) #t)))))]
              [else (assertion-violation 'treesit "not a predicate of the dialect" name)])])
      (lambda (args)
        (let ([passed? (test (source-bytes (highlights-source (highlights))) args)])
          (if negated? (not passed?) passed?)))))

  (define-record-type walk-entry (sealed #t) (fields node end symbol ancestors parent))

  ;; A mask may outgrow a fixnum: a language's queries may name any number
  ;; of ancestor types.
  (define (watched-mask h types)
    (let ([watched (highlights-watched h)])
      (let loop ([i 0] [mask 0])
        (if (fx= i (vector-length watched))
            mask
            (loop (fx+ i 1) (if (member (vector-ref watched i) types) (logor mask (ash 1 i)) mask))))))

  (define (symbol-mask h symbol)
    (watched-mask h (list (language-symbol-name (highlights-language h) symbol))))

  (define (walked-entry h node)
    (define (lookup)
      (let* ([e (node-end-byte node)] [sym (node-symbol node)]
             [same (filter (lambda (w) (and (fx= (walk-entry-end w) e) (fx= (walk-entry-symbol w) sym)))
                           (hashtable-ref (highlights-walk-table h) (node-start-byte node) '()))])
        ;; Nested nodes of one type and range differ only in tree-sitter's
        ;; own node equality, which costs a foreign call.
        (if (and (pair? same) (pair? (cdr same)))
            (find (lambda (w) (node=? (walk-entry-node w) node)) same)
            (and (pair? same) (car same)))))
    ;; A match may hold a capture outside the queried range.
    (or (lookup)
        (begin (walk! h (highlights-walk-root h) (node-start-byte node) (fxmax (node-end-byte node) (fx+ (node-start-byte node) 1)))
               (lookup))))

  (define (walked-ancestors h node)
    (let ([w (walked-entry h node)]) (if w (walk-entry-ancestors w) 0)))

  (define (walked-parent-type h node)
    (let ([w (walked-entry h node)])
      (and w (walk-entry-parent w) (language-symbol-name (highlights-language h) (walk-entry-parent w)))))

  (define (walk! h root from to)
    (let ([table (highlights-walk-table h)] [masks (make-eqv-hashtable)] [c (make-tree-cursor root)])
      (define (mask-of symbol)
        (or (hashtable-ref masks symbol #f)
            (let ([m (symbol-mask h symbol)]) (hashtable-set! masks symbol m) m)))
      (define (inside? s e) (if (fx= s e) (fx<= from s to) (and (fx< s to) (fx> e from))))
      (let visit ([node root] [ancestors 0] [parent #f])
        (let ([s (node-start-byte node)] [e (node-end-byte node)] [sym (node-symbol node)])
          (let ([at (hashtable-ref table s '())])
            (unless (exists (lambda (w) (node=? (walk-entry-node w) node))
                            (filter (lambda (w) (and (fx= (walk-entry-end w) e) (fx= (walk-entry-symbol w) sym))) at))
              (hashtable-set! table s (cons (make-walk-entry node e sym ancestors parent) at))))
          (when (tree-cursor-goto-first-child-for-byte! c from)
            (let ([inner (logor ancestors (mask-of sym))])
              (let siblings ()
                (let ([child (tree-cursor-node c)])
                  (when (fx< (node-start-byte child) to)
                    (when (inside? (node-start-byte child) (node-end-byte child))
                      (visit child inner sym))
                    (when (tree-cursor-goto-next-sibling! c) (siblings)))))
              (tree-cursor-goto-parent! c)))))))

  (define (lua-space-byte? b) (memv b '(32 9 10 11 12 13)))

  (define (trimmed bv s e flags)
    (let* ([flags (if (null? flags) '("0" "0" "1" "0") flags)]
           [on? (lambda (k) (string=? (list-ref flags k) "1"))]
           [blank? (lambda (from to) (let loop ([i from]) (or (fx>= i to) (and (lua-space-byte? (bytevector-u8-ref bv i)) (loop (fx+ i 1))))))]
           [line-start (lambda (i) (let loop ([j i]) (if (or (fx<= j s) (fx= (bytevector-u8-ref bv (fx- j 1)) 10)) (fxmax j s) (loop (fx- j 1)))))]
           [e (if (on? 2)
                  (let loop ([e e])
                    (let ([ls (line-start e)])
                      (if (and (fx> ls s) (blank? ls e)) (loop (fx- ls 1)) e)))
                  e)]
           [e (if (on? 3) (let loop ([e e]) (if (and (fx> e s) (lua-space-byte? (bytevector-u8-ref bv (fx- e 1)))) (loop (fx- e 1)) e)) e)]
           [s (if (on? 0)
                  (let loop ([s s])
                    (let ([nl (let find ([i s]) (cond [(fx>= i e) #f] [(fx= (bytevector-u8-ref bv i) 10) i] [else (find (fx+ i 1))]))])
                      (if (and nl (blank? s nl)) (loop (fx+ nl 1)) s)))
                  s)]
           [s (if (on? 1) (let loop ([s s]) (if (and (fx< s e) (lua-space-byte? (bytevector-u8-ref bv s)) (not (fx= (bytevector-u8-ref bv s) 10))) (loop (fx+ s 1)) s)) s)])
      (values s e)))

  (define (capture-range h source pattern index node)
    (let loop ([ds (vector-ref (highlights-directives h) pattern)] [s (node-start-byte node)] [e (node-end-byte node)])
      (cond
        [(null? ds) (values s e)]
        [(and (string=? (car (car ds)) "offset!") (eqv? (cadr (car ds)) index))
         (let* ([numbers (map string->number (cddr (car ds)))]
                [ref (lambda (k) (if (fx< k (length numbers)) (list-ref numbers k) 0))])
           (loop (cdr ds) (moved-by-rows source s (ref 0) (ref 1)) (moved-by-rows source e (ref 2) (ref 3))))]
        [(and (string=? (car (car ds)) "trim!") (eqv? (cadr (car ds)) index))
         (let-values ([(ts te) (trimmed (source-bytes source) s e (cddr (car ds)))])
           (if (fx<= ts te) (loop (cdr ds) ts te) (loop (cdr ds) s e)))]
        [else (loop (cdr ds) s e)])))

  (define (capture-priority h pattern name)
    (cond
      [(assoc name (vector-ref (highlights-capture-priorities h) pattern)) => cdr]
      [else (vector-ref (highlights-priorities h) pattern)]))

  (define-record-type candidate (sealed #t) (fields end priority pattern sequence face))

  (define (beats? a b)
    (let ([pa (candidate-priority a)] [pb (candidate-priority b)])
      (or (> pa pb)
          (and (= pa pb)
               (or (fx> (candidate-pattern a) (candidate-pattern b))
                   (and (fx= (candidate-pattern a) (candidate-pattern b))
                        (fx> (candidate-sequence a) (candidate-sequence b))))))))

  (define-record-type winner (sealed #t) (fields start end face))

  (define (winners-and-extents h tree source from to)
    (highlights-source-set! h source)
    (highlights-walk-table-set! h (make-eqv-hashtable))
    (highlights-walk-root-set! h (tree-root-node tree))
    (walk! h (tree-root-node tree) from to)
    (let ([best (make-eqv-hashtable)] [extents '()] [wide '()] [seq 0])
      (for-each
        (lambda (m)
          (let ([p (query-match-pattern m)])
            (let loop ([cs (query-match-captures m)] [lo #f] [hi #f] [ranges '()])
              (if (null? cs)
                  (when lo
                    (set! extents (cons (cons lo hi) extents))
                    (when (fx> (length ranges) 1) (set! wide (cons (cons lo hi) wide))))
                  (let* ([c (car cs)] [node (query-capture-node c)] [index (query-capture-index c)]
                         [face (vector-ref (highlights-faces h) index)])
                    (let-values ([(s e) (capture-range h source p index node)])
                      (when face
                        (set! seq (fx+ seq 1))
                        (let* ([new (make-candidate e (capture-priority h p (query-capture-name c)) p seq face)]
                               [at (hashtable-ref best s '())]
                               [old (find (lambda (x) (fx= (candidate-end x) e)) at)])
                          (when (or (not old) (beats? new old))
                            (hashtable-set! best s (cons new (if old (remq old at) at))))))
                      (let ([lo (fxmin (or lo s) s (node-start-byte node))] [hi (fxmax (or hi e) e (node-end-byte node))])
                        (loop (cdr cs) lo hi
                          (if (member (cons (node-start-byte node) (node-end-byte node)) ranges)
                              ranges
                              (cons (cons (node-start-byte node) (node-end-byte node)) ranges))))))))))
        (query-matches (highlights-query h) (tree-root-node tree) from to))
      (highlights-walk-table-set! h #f)
      (highlights-walk-root-set! h #f)
      (values
        (let-values ([(starts ends) (hashtable-entries best)])
          (apply append
            (map (lambda (s at) (map (lambda (x) (make-winner s (candidate-end x) (candidate-face x))) at))
                 (vector->list starts) (vector->list ends))))
        extents wide)))

  (define (flat-spans winners from to excluded)
    (let* ([nodes (filter (lambda (w) (and (not (memq (winner-face w) excluded))
                                           (fx< (winner-start w) (winner-end w))
                                           (fx< (winner-start w) to) (fx> (winner-end w) from)))
                          winners)]
           [cuts (sort fx< (fold-left (lambda (acc w) (cons* (fxmax from (winner-start w)) (fxmin to (winner-end w)) acc)) '() nodes))]
           [cuts (let dedupe ([cs cuts] [acc '()]) (cond [(null? cs) (reverse acc)] [(and (pair? acc) (fx= (car cs) (car acc))) (dedupe (cdr cs) acc)] [else (dedupe (cdr cs) (cons (car cs) acc))]))]
           [nodes (sort (lambda (a b) (fx< (winner-start a) (winner-start b))) nodes)]
           [size (lambda (w) (fx- (winner-end w) (winner-start w)))])
      (let loop ([cuts cuts] [pending nodes] [active '()] [acc '()])
        (if (or (null? cuts) (null? (cdr cuts)))
            (reverse acc)
            (let* ([x (car cuts)] [y (cadr cuts)]
                   [active (filter (lambda (w) (fx> (winner-end w) x)) active)]
                   [entering (let take ([ps pending] [in '()]) (if (and (pair? ps) (fx<= (winner-start (car ps)) x)) (take (cdr ps) (cons (car ps) in)) (cons in ps)))]
                   [active (append (car entering) active)]
                   [pending (cdr entering)]
                   [faces (let collect ([ws (sort (lambda (a b) (fx< (size a) (size b))) active)])
                            (cond
                              [(null? ws) '()]
                              [(eq? (winner-face (car ws)) 'none) '()]
                              [else (cons (winner-face (car ws)) (collect (cdr ws)))]))])
              (loop (cdr cuts) pending active
                (cond
                  [(null? faces) acc]
                  [(and (pair? acc) (fx= (cadr (car acc)) x) (equal? (caddr (car acc)) faces))
                   (cons (list (car (car acc)) y faces) (cdr acc))]
                  [else (cons (list x y faces) acc)])))))))

  (define (span-value faces)
    (list (if (null? (cdr faces)) (cons 'face (car faces)) (cons 'face faces))))

  (define (ranges-add ranges start end)
    (if (fx>= start end)
        ranges
        (let loop ([rs ranges] [start start] [end end] [before '()])
          (cond
            [(null? rs) (append (reverse before) (list (cons start end)))]
            [(fx< (cdar rs) start) (loop (cdr rs) start end (cons (car rs) before))]
            [(fx> (caar rs) end) (append (reverse before) (cons (cons start end) rs))]
            [else (loop (cdr rs) (fxmin start (caar rs)) (fxmax end (cdar rs)) before)]))))

  (define (ranges-remove ranges start end)
    (fold-right
      (lambda (r acc)
        (if (or (fx<= (cdr r) start) (fx>= (car r) end))
            (cons r acc)
            (let ([acc (if (fx> (cdr r) end) (cons (cons end (cdr r)) acc) acc)])
              (if (fx< (car r) start) (cons (cons (car r) start) acc) acc))))
      '() ranges))

  (define (ranges-within ranges start end)
    (fold-right
      (lambda (r acc)
        (let ([a (fxmax start (car r))] [b (fxmin end (cdr r))]) (if (fx< a b) (cons (cons a b) acc) acc)))
      '() ranges))

  ;; A range that reached into replaced text reaches over the text that
  ;; replaced it, which must be coloured too.
  (define (moved-start x start old-end new-end)
    (cond [(fx>= x old-end) (fx+ x (fx- new-end old-end))] [(fx> x start) start] [else x]))

  (define (moved-end x start old-end new-end)
    (cond [(fx>= x old-end) (fx+ x (fx- new-end old-end))] [(fx> x start) new-end] [else x]))

  (define (ranges-moved ranges start old-end new-end)
    (fold-left
      (lambda (acc r)
        (ranges-add acc (moved-start (car r) start old-end new-end) (moved-end (cdr r) start old-end new-end)))
      '() ranges))

  (define (merged-edit edits)
    (let loop ([edits edits] [lo #f] [old-hi #f] [new-hi #f])
      (if (null? edits)
          (values lo old-hi new-hi)
          (let* ([e (car edits)] [s (car e)] [r (cadr e)] [i (caddr e)])
            (if (not lo)
                (loop (cdr edits) s (fx+ s r) (fx+ s i))
                (let ([hi (fxmax new-hi (fx+ s r))])
                  (loop (cdr edits) (fxmin lo s) (fx+ old-hi (fx- hi new-hi)) (fx+ hi (fx- i r)))))))))

  ;; Measured on Python's library files, with Tuna's own query file: a
  ;; piece of this many bytes takes the job 8 to 16 ms and gives the main
  ;; thread at most about 900 spans to set.
  (define piece-size 16384)

  (define (char-start bv i)
    (let ([n (bytevector-length bv)])
      (let loop ([i i]) (if (and (fx< i n) (continuation? (bytevector-u8-ref bv i))) (loop (fx+ i 1)) i))))

  ;; A job sends its data whenever it changes and is not #f, and the main
  ;; thread answers each with a new input.
  (define (told problems) (and (pair? problems) problems))

  (define (highlighter-input? given)
    (and (list? given) (fx= (length given) 5)
         (string? (list-ref given 0)) (string? (list-ref given 1))
         (list? (list-ref given 2)) (for-all string? (list-ref given 2))
         (list? (list-ref given 3)) (for-all symbol? (list-ref given 3))
         (list? (list-ref given 4))
         (for-all (lambda (r) (and (pair? r) (fixnum? (car r)) (fixnum? (cdr r)))) (list-ref given 4))))

  (define (make-highlight)
    (let ([setup #f] [language #f] [highlights #f] [problems '()] [excluded #f]
          [parser #f] [tree #f] [source #f]
          [pending '()] [done '()] [records '()] [drawn '()])
      (define (reset!)
        (set! setup #f) (set! language #f) (set! highlights #f) (set! problems '()) (set! excluded #f)
        (set! parser #f) (set! tree #f) (set! source #f) (set! pending '()) (set! done '()) (set! records '()))
      (define (start! file name files)
        (reset!)
        (set! setup (list file name files))
        (guard (c [(or (language-load-error? c) (language-version-error? c))
                   (set! problems (list (list 'grammar-error file (condition-message c))))])
          (set! language (load-language file name))
          (let-values ([(h ps) (compile-highlights language files)])
            (set! highlights h)
            (set! problems ps))
          (set! parser (make-parser language))))
      (define (whole!)
        (set! pending (if (fx> (source-length source) 0) (list (cons 0 (source-length source))) '()))
        (set! done '()))
      (define (parse! doc)
        (set! source (document-source doc))
        (set! tree (parser-parse parser (source-bytes source)))
        (set! records '())
        (whole!))
      (define (edit! doc since)
        (let*-values ([(old) source] [(new) (document-source doc)] [(start old-end new-end) (merged-edit since)])
         (let* ([start (char->byte old start)] [old-end (char->byte old old-end)] [new-end (char->byte new new-end)]
               [edited (tree-edit tree (make-input-edit start old-end new-end
                                         (byte->point old start) (byte->point old old-end) (byte->point new new-end)))]
               [parsed (parser-parse parser (source-bytes new) edited)]
               [n (source-length new)])
          (set! source new)
          (set! tree parsed)
          (set! records (fold-left (lambda (acc r)
                                     (let ([a (moved-start (car r) start old-end new-end)] [b (moved-end (cdr r) start old-end new-end)])
                                       (if (fx< a b) (cons (cons a b) acc) acc)))
                          '() records))
          (set! pending
            (fold-left (lambda (acc r) (ranges-add acc (range-start-byte r) (range-end-byte r)))
              (ranges-add (ranges-moved pending start old-end new-end)
                (fxmax 0 (fx- start 1)) (fxmin n (fx+ new-end 1)))
              (tree-changed-ranges edited parsed)))
          (set! done '()))))
      (define (drawn-bytes doc positions)
        (let ([n (document:length doc)] [chars (document:unit characters)])
          (filter (lambda (r) (fx< (car r) (cdr r)))
            (map (lambda (r)
                   (let ([at (lambda (p) (char-start (source-bytes source)
                                           (char->byte source (document:offset doc (fxmax 0 (fxmin n p)) chars))))])
                     (cons (at (car r)) (at (cdr r)))))
                 positions))))
      (define (next-piece)
        (let ([bv (source-bytes source)])
          (or (exists (lambda (d)
                        (let ([inside (ranges-within pending (car d) (cdr d))])
                          (and (pair? inside) (cons (caar inside) (cdr (list-ref inside (fx- (length inside) 1)))))))
                      drawn)
              (let* ([anchors (if (null? drawn) (list (cons 0 0)) drawn)]
                     [distance (lambda (r)
                                 (apply fxmin (map (lambda (d) (cond [(fx>= (car r) (cdr d)) (fx- (car r) (cdr d))]
                                                                     [(fx<= (cdr r) (car d)) (fx- (car d) (cdr r))]
                                                                     [else 0]))
                                                   anchors)))]
                     [r (fold-left (lambda (best r) (if (fx< (distance r) (distance best)) r best)) (car pending) (cdr pending))]
                     [after? (exists (lambda (d) (fx>= (car r) (cdr d))) anchors)])
                (if (or after? (fx<= (fx- (cdr r) (car r)) piece-size))
                    (cons (car r) (fxmax (char-start bv (fxmin (cdr r) (fx+ (car r) piece-size))) (fxmin (cdr r) (fx+ (car r) 1))))
                    (cons (char-start bv (fxmax (car r) (fx- (cdr r) piece-size))) (cdr r)))))))
      (define (answer-piece!)
        (let* ([piece (next-piece)] [from (car piece)] [to (cdr piece)])
          (let-values ([(winners extents wide) (winners-and-extents highlights tree source from to)])
            (let ([touched (append extents (filter (lambda (r) (and (fx< (car r) to) (fx> (cdr r) from))) records))])
              (set! records (append wide (filter (lambda (r) (not (and (fx< (car r) to) (fx> (cdr r) from)))) records)))
              (set! pending (ranges-remove pending from to))
              (set! done (ranges-add done from to))
              (for-each
                (lambda (r)
                  (for-each (lambda (gap) (set! pending (ranges-add pending (car gap) (cdr gap))))
                    (fold-left (lambda (gaps d) (ranges-remove gaps (car d) (cdr d)))
                      (list r) (append done pending))))
                touched))
            (list (byte->char source from) (byte->char source to)
                  (list->vector
                    (map (lambda (s) (list (byte->char source (car s)) (byte->char source (cadr s)) (span-value (caddr s))))
                         (flat-spans winners from to excluded)))))))
      (lambda (doc given since)
        (unless (or (not given) (highlighter-input? given))
          (assertion-violation 'make-highlight "not a grammar file, its name, query files, excluded captures and drawn ranges" given))
        (cond
          [(not given) (reset!) (values (list '#()) #f)]
          [else
           (let ([file (list-ref given 0)] [name (list-ref given 1)] [files (list-ref given 2)])
             (unless (equal? setup (list file name files)) (start! file name files))
             (cond
               [(not highlights) (values (list '#()) (told problems))]
               [else
                (unless (equal? excluded (list-ref given 3))
                  (set! excluded (list-ref given 3))
                  (when source (whole!)))
                (cond
                  [(not tree) (parse! doc)]
                  [(pair? since) (edit! doc since)])
                (set! drawn (drawn-bytes doc (list-ref given 4)))
                (if (null? pending)
                    (values (list (list 0 0 '#())) (told problems) #f)
                    (let ([answer (answer-piece!)])
                      (values (list answer) (told problems) (pair? pending))))]))])))))
