#!tuna
(import (buffers) (document) (modes) (syntax characters))

(define-table lexers
  "Maps a major mode to its lexer, a procedure of a document that returns the document's lexemes.")

(define-table word-characters
  "Maps a major mode to the characters besides letters and digits that are part of its words, as a string.")

(define-table symbol-characters
  "Maps a major mode to the characters besides letters, digits and its word characters that are part of its symbols, as a string.")

(define-enumeration class (open close prefix atom string comment) %classes)

(define-enumeration %lexeme-mark (open-ended mismatched) lexeme-marks)

(buffers:define-layer brackets (priority -5) (evaporate))

(define-table bracket-users
  "Maps a key to a procedure of a buffer that returns true while its plugin draws that buffer's bracket spans.")

(define-hook bracket-users-changed
  "Called with no arguments by a plugin whose entry in syntax:bracket-users may answer differently.")

(module %internals
  (check-main-thread make-lexeme-record lexeme-record? lexeme-record-class lexeme-record-start
   lexeme-record-end lexeme-record-depth lexeme-record-open-ended? lexeme-record-mismatched?
   check-lexeme all-marks lexer-of buffer-mode lexed-of lexed-lexeme-at lexed-lexemes-between lexed-openings
   lexed-sexp-before lexed-sexp-after lexed-top-level-form comment-sexp-before)

  (define main-thread (get-thread-id))

  (define (check-main-thread who)
    (unless (fx= (get-thread-id) main-thread)
      (assertion-violation who "not on the main thread")))

  (define-record-type lexeme-record
    (sealed #t)
    (fields class start end depth open-ended? mismatched?))

  (define (check-lexeme who v)
    (unless (lexeme-record? v)
      (assertion-violation who "not a lexeme" v)))

  (define all-marks (lexeme-marks open-ended mismatched))

  (define (lexer-of mode)
    (let loop ([modes (modes:ancestry mode)])
      (cond
        [(null? modes) #f]
        [(table-ref lexers (car modes) #f)]
        [else (loop (cdr modes))])))

  ;; A list with no match ends with the last lexeme, so the end of that
  ;; one is kept beside the matches.
  (define-record-type (lexed new-lexed lexed?)
    (sealed #t)
    (fields document lexemes matches last-end (mutable forms)))

  (define (open? l) (eq? (lexeme-record-class l) 'open))
  (define (close? l) (eq? (lexeme-record-class l) 'close))

  (define (matches-of v)
    (let ([n (vector-length v)] [waiting (make-eqv-hashtable)])
      (let ([matches (make-fxvector n -1)])
        (do ([i 0 (fx+ i 1)]) ((fx= i n) matches)
          (let ([l (vector-ref v i)])
            (cond
              [(open? l) (hashtable-set! waiting (lexeme-record-depth l) i)]
              [(close? l)
               (let ([o (hashtable-ref waiting (lexeme-record-depth l) #f)])
                 (when o
                   (fxvector-set! matches o i)
                   (hashtable-delete! waiting (lexeme-record-depth l))))]))))))

  (define (condition-text c)
    (call-with-string-output-port (lambda (p) (display-condition c p))))

  ;; A lexer's result is checked once, so the questions trust it.
  (define (run-lexer who mode lexer doc)
    (let ([v (guard (c [(not (quit-condition? c))
                        (assertion-violation who
                          (format "the lexer of ~s raised: ~a" mode
                            (if (condition? c) (condition-text c) c))
                          lexer)])
               (lexer doc))]
          [size (document:length doc)])
      (unless (and (vector? v)
                   (let loop ([i 0] [after 0])
                     (or (fx= i (vector-length v))
                         (let ([l (vector-ref v i)])
                           (and (lexeme-record? l)
                                (fx>= (lexeme-record-start l) after)
                                (fx<= (lexeme-record-end l) size)
                                (loop (fx+ i 1) (lexeme-record-end l)))))))
        (assertion-violation who "the lexer did not return lexemes in order within the document" mode lexer))
      v))

  (define (shifted v by)
    (if (fx= by 0)
        v
        (vector-map
          (lambda (l)
            (make-lexeme-record (lexeme-record-class l) (fx+ (lexeme-record-start l) by)
              (fx+ (lexeme-record-end l) by) (lexeme-record-depth l)
              (lexeme-record-open-ended? l) (lexeme-record-mismatched? l)))
          v)))

  (define (make-lexed doc v)
    (let ([n (vector-length v)])
      (new-lexed doc v (matches-of v) (if (fx= n 0) 0 (lexeme-record-end (vector-ref v (fx- n 1)))) #f)))

  (define (lex-from who mode lexer doc start)
    (let ([v (if (fx= start 0)
                 (run-lexer who mode lexer doc)
                 (shifted (run-lexer who mode lexer (document:slice doc start (document:length doc))) start))])
      (make-lexed doc v)))

  (define (line-end doc line last-line)
    (if (fx= line last-line)
        (document:length doc)
        (document:line-start doc (fx+ line 1))))

  (define (starts-with-open? who mode lexer doc start end)
    (let* ([line (document:slice doc start end)]
           [v (run-lexer who mode lexer line)])
      (and (fx> (vector-length v) 0)
           (let ([first (vector-ref v 0)])
             (and (open? first)
                  (string=? "" (document:text line 0 (lexeme-record-start first))))))))

  ;; Another mode's lexer reads only from the last line at or above the
  ;; position's that starts with an opening bracket, so prose above, such
  ;; as a lone " in Markdown, does not turn the code below into a string.
  (define (local-start who mode lexer doc position)
    (let ([last-line (document:line doc (document:length doc))])
      (let loop ([line (document:line doc position)])
        (if (fx= line 1)
            0
            (let ([start (document:line-start doc line)])
              (if (starts-with-open? who mode lexer doc start (line-end doc line last-line))
                  start
                  (loop (fx- line 1))))))))

  ;; Lexemes are kept per document, which never changes, so no edit needs
  ;; to flush them. Each entry holds its document, which would keep the key
  ;; of a weak table alive; an ephemeron table lets it go.
  (define cache (make-ephemeron-eq-hashtable))

  (define (cached who mode lexer doc start)
    (let* ([entries (eq-hashtable-ref cache doc '())]
           [found (find (lambda (e) (and (eq? (caar e) lexer) (fx= (cdar e) start))) entries)])
      (if found
          (cdr found)
          (let ([lexed (lex-from who mode lexer doc start)])
            (eq-hashtable-set! cache doc (cons (cons (cons lexer start) lexed) entries))
            lexed))))

  (define (buffer-mode who buffer)
    (check-main-thread who)
    (unless (buffers:buffer? buffer)
      (assertion-violation who "not a buffer" buffer))
    (modes:major-mode buffer))

  (define (lexed-of who buffer position mode)
    (check-main-thread who)
    (unless (buffers:buffer? buffer)
      (assertion-violation who "not a buffer" buffer))
    (unless (symbol? mode)
      (assertion-violation who "not a mode" mode))
    (let ([doc (buffers:document buffer)] [lexer (lexer-of mode)])
      (unless (and (fixnum? position) (fx<= 0 position (document:length doc)))
        (assertion-violation who "not a position in the buffer" position))
      (unless lexer
        (assertion-violation who "the mode has no lexer" mode))
      (cached who mode lexer doc
        (if (eq? lexer (lexer-of (modes:major-mode buffer)))
            0
            (local-start who mode lexer doc position)))))

  (define (last-before v position)
    (let loop ([low 0] [high (vector-length v)])
      (if (fx= low high)
          (fx- low 1)
          (let ([mid (fxsrl (fx+ low high) 1)])
            (if (fx< (lexeme-record-start (vector-ref v mid)) position)
                (loop (fx+ mid 1) high)
                (loop low mid))))))

  (define (lexed-lexeme-at lexed position)
    (let* ([v (lexed-lexemes lexed)] [i (last-before v position)])
      (and (fx>= i 0)
           (let ([l (vector-ref v i)])
             (and (or (fx< position (lexeme-record-end l))
                      (and (fx= position (lexeme-record-end l)) (lexeme-record-open-ended? l)))
                  l)))))

  (define (lexed-lexemes-between lexed start end)
    (let* ([v (lexed-lexemes lexed)] [n (vector-length v)]
           [first (let ([i (last-before v start)])
                    (if (and (fx>= i 0) (fx> (lexeme-record-end (vector-ref v i)) start)) i (fx+ i 1)))])
      (let loop ([i first] [acc '()])
        (if (and (fx< i n) (fx< (lexeme-record-start (vector-ref v i)) end))
            (loop (fx+ i 1) (cons (vector-ref v i) acc))
            (reverse acc)))))

  (define (list-end lexed o)
    (let ([m (fxvector-ref (lexed-matches lexed) o)])
      (if (fx= m -1)
          (lexed-last-end lexed)
          (lexeme-record-end (vector-ref (lexed-lexemes lexed) m)))))

  (define (openings-of lexed position)
    (let ([v (lexed-lexemes lexed)] [matches (lexed-matches lexed)])
      (let loop ([i 0] [stack '()])
        (if (and (fx< i (vector-length v)) (fx< (lexeme-record-start (vector-ref v i)) position))
            (let ([l (vector-ref v i)])
              (cond
                [(and (open? l) (fx<= (lexeme-record-end l) position)) (loop (fx+ i 1) (cons i stack))]
                [(and (close? l) (memv i (map (lambda (o) (fxvector-ref matches o)) stack)))
                 (loop (fx+ i 1)
                       (let pop ([stack stack])
                         (if (fx= (fxvector-ref matches (car stack)) i) (cdr stack) (pop (cdr stack)))))]
                [else (loop (fx+ i 1) stack)]))
            (filter (lambda (o)
                      (or (fx>= (fxvector-ref matches o) 0)
                          (fx<= position (lexed-last-end lexed))))
                    stack)))))

  (define (lexed-openings lexed position)
    (let ([v (lexed-lexemes lexed)])
      (reverse (map (lambda (o) (vector-ref v o)) (openings-of lexed position)))))

  (define (find-sexp lexed i end proc)
    (let ([v (lexed-lexemes lexed)] [matches (lexed-matches lexed)])
      (let loop ([i i] [prefix-start #f])
        (and (fx< i end)
             (let ([l (vector-ref v i)])
               (case (lexeme-record-class l)
                 [(comment) (loop (fx+ i 1) prefix-start)]
                 [(prefix) (loop (fx+ i 1) (or prefix-start (lexeme-record-start l)))]
                 [(close) (loop (fx+ i 1) #f)]
                 [(open)
                  (let ([m (fxvector-ref matches i)])
                    (or (proc (or prefix-start (lexeme-record-start l)) (list-end lexed i))
                        (if (fx= m -1) #f (loop (fx+ m 1) #f))))]
                 [else
                  (or (proc (or prefix-start (lexeme-record-start l)) (lexeme-record-end l))
                      (loop (fx+ i 1) #f))]))))))

  (define (container lexed position)
    (let ([openings (openings-of lexed position)] [n (vector-length (lexed-lexemes lexed))])
      (if (null? openings)
          (values 0 n)
          (let* ([o (car openings)] [m (fxvector-ref (lexed-matches lexed) o)])
            (values (fx+ o 1) (if (fx= m -1) n m))))))

  (define (lexed-sexp-before lexed position)
    (let-values ([(from to) (container lexed position)])
      (let ([found #f])
        (find-sexp lexed from to
          (lambda (start end)
            (if (fx< start position)
                (begin (set! found start) #f)
                #t)))
        found)))

  (define (lexed-sexp-after lexed position)
    (let-values ([(from to) (container lexed position)])
      (find-sexp lexed from to (lambda (start end) (and (fx> end position) end)))))

  (define (column-0? doc position)
    (or (fx= position 0)
        (let ([before (document:token doc (fx- position 1))])
          (or (not (char? before)) (char=? before #\newline)))))

  ;; A list whose opening bracket is in column 0 also ends any form
  ;; holding it, as a list left open above would otherwise run on to the
  ;; end of the text.
  (define (forms-of lexed)
    (or (lexed-forms lexed)
        (let* ([v (lexed-lexemes lexed)] [n (vector-length v)] [doc (lexed-document lexed)]
               [nested (let loop ([i 0] [acc '()])
                         (if (fx= i n)
                             (reverse acc)
                             (let ([l (vector-ref v i)])
                               (loop (fx+ i 1)
                                     (if (and (open? l) (fx> (lexeme-record-depth l) 1)
                                              (column-0? doc (lexeme-record-start l)))
                                         (cons (cons (lexeme-record-start l) (list-end lexed i)) acc)
                                         acc)))))]
               [top (let ([acc '()])
                      (find-sexp lexed 0 n (lambda (start end) (set! acc (cons (cons start end) acc)) #f))
                      (reverse acc))]
               [starts (sort (lambda (a b) (fx< (car a) (car b))) (append top nested))]
               [cut (lambda (form)
                      (let ([inner (find (lambda (f) (and (fx< (car form) (car f)) (fx< (car f) (cdr form)))) nested)])
                        (if inner
                            (let ([i (last-before v (car inner))])
                              (cons (car form) (fxmax (car form) (lexeme-record-end (vector-ref v i)))))
                            form)))]
               [forms (map cut starts)])
          (lexed-forms-set! lexed forms)
          forms)))

  (define (lexed-top-level-form lexed position)
    (let ([forms (forms-of lexed)])
      (cond
        [(or (find (lambda (f) (fx<= (car f) position (cdr f))) forms)
             (find (lambda (f) (fx> (car f) position)) forms)
             (and (pair? forms) (list-ref forms (fx- (length forms) 1))))
         => (lambda (f) (values (car f) (cdr f)))]
        [else (values #f #f)])))

  ;; Inside a comment, its text reads as code from its first whitespace or
  ;; opening bracket, so an example call in a comment is the sexp before
  ;; point, as in Emacs.
  (define (comment-sexp-before who mode lexed comment position)
    (let* ([doc (lexed-document lexed)] [lexer (lexer-of mode)]
           [end (fxmin position (lexeme-record-end comment))]
           [text-start
            (let loop ([i (lexeme-record-start comment)])
              (and (fx< i end)
                   (let ([token (document:token doc i)])
                     (if (and (char? token)
                              (or (char-whitespace? token)
                                  (let ([v (run-lexer who mode lexer (document:from-datum (string token)))])
                                    (and (fx= (vector-length v) 1) (open? (vector-ref v 0))))))
                         i
                         (loop (fx+ i 1))))))])
      (and text-start
           (lexed-sexp-before
             (make-lexed doc (shifted (run-lexer who mode lexer (document:slice doc text-start position)) text-start))
             position))))

  (record-writer (record-type-descriptor lexeme-record)
    (lambda (l p wr)
      (fprintf p "#<lexeme ~a ~s ~s ~s>" (lexeme-record-class l) (lexeme-record-start l)
               (lexeme-record-end l) (lexeme-record-depth l)))))

(import %internals)

(define (make-lexeme class start end depth marks)
  (unless (and (symbol? class) (enum-set-member? class (%classes open close prefix atom string comment)))
    (assertion-violation 'syntax:make-lexeme "not a lexeme class" class))
  (unless (and (fixnum? start) (fixnum? end) (fx<= 0 start) (fx< start end))
    (assertion-violation 'syntax:make-lexeme "not a range" start end))
  (unless (and (fixnum? depth) (fx>= depth 0))
    (assertion-violation 'syntax:make-lexeme "not a depth" depth))
  (unless (and (enum-set? marks) (enum-set-subset? marks all-marks))
    (assertion-violation 'syntax:make-lexeme "not a set of lexeme marks" marks))
  (make-lexeme-record class start end depth
    (enum-set-member? 'open-ended marks) (enum-set-member? 'mismatched marks)))

(define (lexeme-class lexeme)
  (check-lexeme 'syntax:lexeme-class lexeme)
  (lexeme-record-class lexeme))

(define (lexeme-start lexeme)
  (check-lexeme 'syntax:lexeme-start lexeme)
  (lexeme-record-start lexeme))

(define (lexeme-end lexeme)
  (check-lexeme 'syntax:lexeme-end lexeme)
  (lexeme-record-end lexeme))

(define (lexeme-depth lexeme)
  (check-lexeme 'syntax:lexeme-depth lexeme)
  (lexeme-record-depth lexeme))

(define (lexeme-open-ended? lexeme)
  (check-lexeme 'syntax:lexeme-open-ended? lexeme)
  (lexeme-record-open-ended? lexeme))

(define (lexeme-mismatched? lexeme)
  (check-lexeme 'syntax:lexeme-mismatched? lexeme)
  (lexeme-record-mismatched? lexeme))

(define (lexeme? v) (lexeme-record? v))

(define (lexer mode)
  (unless (symbol? mode)
    (assertion-violation 'syntax:lexer "not a mode" mode))
  (lexer-of mode))

(define lexemes
  (case-lambda
    [(buffer start end) (lexemes buffer start end (buffer-mode 'syntax:lexemes buffer))]
    [(buffer start end mode)
     (unless (and (fixnum? start) (fixnum? end) (fx<= 0 start end))
       (assertion-violation 'syntax:lexemes "not a range" start end))
     (let ([lexed (lexed-of 'syntax:lexemes buffer start mode)])
       (unless (fx<= end (document:length (buffers:document buffer)))
         (assertion-violation 'syntax:lexemes "not a position in the buffer" end))
       (lexed-lexemes-between lexed start end))]))

(define lexeme-at
  (case-lambda
    [(buffer position) (lexeme-at buffer position (buffer-mode 'syntax:lexeme-at buffer))]
    [(buffer position mode)
     (lexed-lexeme-at (lexed-of 'syntax:lexeme-at buffer position mode) position)]))

(define openings
  (case-lambda
    [(buffer position) (openings buffer position (buffer-mode 'syntax:openings buffer))]
    [(buffer position mode)
     (lexed-openings (lexed-of 'syntax:openings buffer position mode) position)]))

(define sexp-before
  (case-lambda
    [(buffer position) (sexp-before buffer position (buffer-mode 'syntax:sexp-before buffer))]
    [(buffer position mode)
     (let* ([lexed (lexed-of 'syntax:sexp-before buffer position mode)]
            [at (lexed-lexeme-at lexed position)])
       (or (and at (eq? (lexeme-record-class at) 'comment)
                (comment-sexp-before 'syntax:sexp-before mode lexed at position))
           (lexed-sexp-before lexed position)))]))

(define sexp-after
  (case-lambda
    [(buffer position) (sexp-after buffer position (buffer-mode 'syntax:sexp-after buffer))]
    [(buffer position mode)
     (lexed-sexp-after (lexed-of 'syntax:sexp-after buffer position mode) position)]))

(define top-level-form
  (case-lambda
    [(buffer position) (top-level-form buffer position (buffer-mode 'syntax:top-level-form buffer))]
    [(buffer position mode)
     (lexed-top-level-form (lexed-of 'syntax:top-level-form buffer position mode) position)]))

(define (%characters-of who table mode)
  (unless (symbol? mode)
    (assertion-violation who "not a mode" mode))
  (let ([characters (let loop ([modes (modes:ancestry mode)])
                      (cond
                        [(null? modes) (table-ref table modes:fundamental "")]
                        [(table-ref table (car modes) #f)]
                        [else (loop (cdr modes))]))])
    (unless (string? characters)
      (assertion-violation who "the mode's entry is not a string" mode characters))
    characters))

(define (mode-word-characters mode)
  (%characters-of 'syntax:mode-word-characters word-characters mode))

(define (mode-symbol-characters mode)
  (%characters-of 'syntax:mode-symbol-characters symbol-characters mode))

(define (buffer-word-characters buffer)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'syntax:buffer-word-characters "not a buffer" buffer))
  (mode-word-characters (modes:major-mode buffer)))

(define (buffer-symbol-characters buffer)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'syntax:buffer-symbol-characters "not a buffer" buffer))
  (mode-symbol-characters (modes:major-mode buffer)))

(define (%symbol-bounds buffer position words symbols)
  (let* ([doc (buffers:document buffer)] [n (document:length doc)])
    (unless (and (string? words) (string? symbols))
      (assertion-violation 'syntax:symbol-bounds "the characters are not strings" words symbols))
    (unless (and (fixnum? position) (fx<= 0 position n))
      (assertion-violation 'syntax:symbol-bounds "not a position in the buffer" position))
    (let* ([in? (lambda (t) (and (char? t) (symbol-char? t words symbols)))]
           [start (let loop ([p position]) (if (and (fx> p 0) (in? (document:token doc (fx- p 1)))) (loop (fx- p 1)) p))]
           [end (let loop ([p position]) (if (and (fx< p n) (in? (document:token doc p))) (loop (fx+ p 1)) p))])
      (if (fx= start end) (values #f #f) (values start end)))))

(define (%check-symbol-question buffer)
  (check-main-thread 'syntax:symbol-bounds)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'syntax:symbol-bounds "not a buffer" buffer)))

(define symbol-bounds
  (case-lambda
    [(buffer position)
     (%check-symbol-question buffer)
     (%symbol-bounds buffer position (buffer-word-characters buffer) (buffer-symbol-characters buffer))]
    [(buffer position mode)
     (%check-symbol-question buffer)
     (unless (symbol? mode)
       (assertion-violation 'syntax:symbol-bounds "not a mode" mode))
     (%symbol-bounds buffer position (mode-word-characters mode) (mode-symbol-characters mode))]))

(define (brackets-used? buffer)
  (unless (buffers:buffer? buffer)
    (assertion-violation 'syntax:brackets-used? "not a buffer" buffer))
  (and (exists (lambda (entry) ((cdr entry) buffer)) (table-entries bracket-users)) #t))

;; Emacs's standard syntax table, which every other table inherits.
(table-set! word-characters modes:fundamental "$%")
(table-set! symbol-characters modes:fundamental "_-+*/&|<>=")
