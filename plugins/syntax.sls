#!tuna
(import (buffers) (document) (modes) (syntax characters) (hooks) (tables))

(tables:define-table lexers
  "Maps a major mode to its lexer, a procedure of a document that returns the document's lexemes.")

(tables:define-table word-characters
  "Maps a major mode to the characters besides letters and digits that are part of its words, as a string.")

(tables:define-table symbol-characters
  "Maps a major mode to the characters besides letters, digits and its word characters that are part of its symbols, as a string.")

(define-enumeration class (open close prefix atom string comment) %classes)

(define-enumeration %lexeme-mark (open-ended mismatched) lexeme-marks)

(buffers:define-layer brackets (priority -5) (evaporate))

(tables:define-table bracket-users
  "Maps a key to a procedure of a buffer that returns true while its plugin draws that buffer's bracket spans.")

(module %internals
  (check-main-thread make-lexeme-record lexeme-record? lexeme-record-class lexeme-record-start
   lexeme-record-end lexeme-record-depth lexeme-record-open-ended? lexeme-record-mismatched?
   check-lexeme all-marks lexer-of buffer-mode lexed-of local-lexed-of follow-edit! lexed-lexeme-at lexed-lexemes-between lexed-openings
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
        [(tables:ref lexers (car modes) #f)]
        [else (loop (cdr modes))])))

  ;; A list with no match ends with the last lexeme, so the end of that
  ;; one is kept beside the matches.
  (define-record-type (lexed new-lexed lexed?)
    (sealed #t)
    (fields document lexemes matches openers last-end (mutable forms)))

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
    (let ([v (guard (c [(not (cancelled? c))
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
      (let* ([matches (matches-of v)] [openers (make-fxvector n -1)])
        (do ([o 0 (fx+ o 1)]) ((fx= o n))
          (let ([m (fxvector-ref matches o)])
            (when (fx>= m 0) (fxvector-set! openers m o))))
        (new-lexed doc v matches openers (if (fx= n 0) 0 (lexeme-record-end (vector-ref v (fx- n 1)))) #f))))

  (define (lex-range who mode lexer doc start end)
    (make-lexed doc
      (if (and (fx= start 0) (fx= end (document:length doc)))
          (run-lexer who mode lexer doc)
          (shifted (run-lexer who mode lexer (document:slice doc start end)) start))))

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

  ;; A line whose start no lexeme of one run over a block of lines spans
  ;; begins as the lexer reads it alone, so one run answers for each line
  ;; of the block, where a run per line would cost a lexer call for every
  ;; line walked; only a line inside a lexeme that spans lines, such as a
  ;; string, is lexed alone.
  (define (opening-at? who mode lexer doc v line last-line)
    (let* ([start (document:line-start doc line)]
           [i (last-before v start)]
           [j (fx+ i 1)])
      (cond
        [(and (fx>= i 0) (fx> (lexeme-record-end (vector-ref v i)) start))
         (starts-with-open? who mode lexer doc start (line-end doc line last-line))]
        [(fx< j (vector-length v))
         (let ([l (vector-ref v j)])
           (and (open? l)
                (fx< (lexeme-record-start l) (line-end doc line last-line))
                (string=? "" (document:text doc start (lexeme-record-start l)))))]
        [else #f])))

  (define (block-lexemes who mode lexer doc top bottom last-line)
    (let ([from (document:line-start doc top)])
      (shifted (run-lexer who mode lexer (document:slice doc from (line-end doc bottom last-line))) from)))

  ;; Blocks double as they go, so a walk lexes about twice the text
  ;; between the line it finds and the position.
  (define (start-line who mode lexer doc position)
    (let ([last-line (document:line doc (document:length doc))])
      (let block ([bottom (document:line doc position)] [count 16])
        (if (fx< bottom 1)
            #f
            (let* ([top (fxmax 1 (fx- bottom (fx- count 1)))]
                   [v (block-lexemes who mode lexer doc top bottom last-line)])
              (let walk ([line bottom])
                (cond
                  [(fx< line top) (block (fx- top 1) (fx* count 2))]
                  [(opening-at? who mode lexer doc v line last-line) line]
                  [else (walk (fx- line 1))])))))))

  ;; Lexemes are kept for the buffer's current document only, so the
  ;; documents an undo history holds keep no lexemes alive.
  (define-record-type known
    (sealed #t)
    (fields (mutable document) (mutable version) (mutable lexes) (mutable walks)))

  (define-record-type lex
    (sealed #t)
    (fields kind lexer start end lexed))

  (define-record-type walk
    (sealed #t)
    (fields lexer low high found))

  (define known-by-buffer (make-weak-eq-hashtable))

  (define (known-of buffer doc)
    (let ([k (eq-hashtable-ref known-by-buffer buffer #f)])
      (if (and k (eq? (known-document k) doc))
          k
          (let ([k (make-known doc (buffers:version buffer) '() '())])
            (eq-hashtable-set! known-by-buffer buffer k)
            k))))

  (define (known-lex k kind lexer covers? make)
    (let ([found (find (lambda (l) (and (eq? (lex-kind l) kind) (eq? (lex-lexer l) lexer) (covers? (lex-start l) (lex-end l))))
                       (known-lexes k))])
      (if found
          (lex-lexed found)
          (let-values ([(start end lexed keep?) (make)])
            ;; Lexes of one form start at its first line, so this one, made
            ;; because an older one ended too soon, holds all it did.
            (when keep?
              (known-lexes-set! k
                (cons (make-lex kind lexer start end lexed)
                      (filter (lambda (l)
                                (not (and (eq? (lex-kind l) kind) (eq? (lex-lexer l) lexer)
                                          (eq? kind 'local) (fx< (lex-start l) end) (fx< start (lex-end l)))))
                              (known-lexes k)))))
            lexed))))

  ;; Every line from the one a walk found to the one it started from finds
  ;; the same line, and with none found every line above finds none, so
  ;; one walk answers for each of them.
  (define (walked k lexer line find-line)
    (let ([found (find (lambda (w) (and (eq? (walk-lexer w) lexer) (fx<= (walk-low w) line (walk-high w))))
                       (known-walks k))])
      (if found
          (walk-found found)
          (let ([found (find-line)])
            (known-walks-set! k (cons (make-walk lexer (or found 1) line found) (known-walks k)))
            found))))

  (define (blank-token? t) (and (char? t) (char-whitespace? t)))

  ;; A line starting with an opening bracket starts a top-level form even
  ;; inside a string or block comment, since telling would take lexing
  ;; from the start of the buffer, the cost these forms are read to avoid.
  (define (top-line? who mode lexer doc line last-line)
    (let* ([start (document:line-start doc line)]
           [t (and (fx< start (document:length doc)) (document:token doc start))])
      (and t
           (not (blank-token? t))
           (starts-with-open? who mode lexer doc start (line-end doc line last-line)))))

  (define (top-start who mode lexer doc position)
    (let ([last-line (document:line doc (document:length doc))])
      (let loop ([line (document:line doc position)])
        (cond
          [(fx< line 1) 0]
          [(top-line? who mode lexer doc line last-line) (document:line-start doc line)]
          [else (loop (fx- line 1))]))))

  (define (top-end who mode lexer doc position)
    (let ([last-line (document:line doc (document:length doc))])
      (let loop ([line (fx+ (document:line doc position) 1)])
        (cond
          [(fx> line last-line) (document:length doc)]
          [(top-line? who mode lexer doc line last-line) (document:line-start doc line)]
          [else (loop (fx+ line 1))]))))

  (define (whitespace? piece)
    (let* ([doc (buffers:piece-document piece)] [n (document:length doc)])
      (let loop ([p 0])
        (or (fx= p n)
            (let ([t (document:token doc p)])
              (and (blank-token? t) (loop (fx+ p 1))))))))

  ;; An edit of whitespace that leaves a blank between the lexemes on
  ;; either side of it moves the lexemes after it and changes none, so a
  ;; local lex follows it rather than lexing again, as indenting each line
  ;; of a form does. An edit that may change where a form starts, at or
  ;; before its first line or putting an opening bracket at the start of a
  ;; line, drops it, as does one at its end when its last lexeme is left
  ;; open there, since the lex may then end later and that lexeme with it.
  (define (followed l edit doc)
    (let* ([e (buffers:edit-start edit)]
           [removed (buffers:piece-length (buffers:edit-removed edit))]
           [inserted (buffers:piece-length (buffers:edit-inserted edit))]
           [by (fx- inserted removed)]
           [start (lex-start l)] [end (lex-end l)]
           [lexed (lex-lexed l)] [v (lexed-lexemes lexed)]
           [old-length (fx- (document:length doc) by)])
      (cond
        [(not (eq? (lex-kind l) 'local)) #f]
        [(and (fx<= end e) (fx< end old-length))
         (let ([n (vector-length v)])
           (and (not (and (fx= e end) (fx> n 0)
                          (let ([x (vector-ref v (fx- n 1))])
                            (and (lexeme-record-open-ended? x) (fx= (lexeme-record-end x) end)))))
                l))]
        [(fx<= e start) #f]
        [(let ([i (last-before v (fx+ e removed))])
           (and (fx>= i 0)
                (let ([x (vector-ref v i)])
                  (or (fx> (lexeme-record-end x) e)
                      (and (lexeme-record-open-ended? x) (fx= (lexeme-record-end x) e))))))
         #f]
        [(let ([after (fx+ e inserted)])
           (and (fx< after (document:length doc))
                (or (fx= after 0) (eqv? (document:token doc (fx- after 1)) #\newline))
                (let ([i (fx+ (last-before v (fx+ e removed)) 1)])
                  (and (fx< i (vector-length v))
                       (fx= (lexeme-record-start (vector-ref v i)) (fx+ e removed))
                       (open? (vector-ref v i))))))
         #f]
        [else
         (let ([moved (vector-map
                        (lambda (x)
                          (if (fx< (lexeme-record-start x) e)
                              x
                              (make-lexeme-record (lexeme-record-class x) (fx+ (lexeme-record-start x) by)
                                (fx+ (lexeme-record-end x) by) (lexeme-record-depth x)
                                (lexeme-record-open-ended? x) (lexeme-record-mismatched? x))))
                        v)])
           (make-lex 'local (lex-lexer l) start (fx+ end by)
             (new-lexed doc moved (lexed-matches lexed) (lexed-openers lexed)
               (if (fx< (lexed-last-end lexed) e) (lexed-last-end lexed) (fx+ (lexed-last-end lexed) by))
               #f)))])))

  ;; Deleting the only blank between two lexemes can join them into one,
  ;; as `foo bar` becomes `foobar`, which no shift of the old lexemes
  ;; gives.
  (define (joins? edit doc)
    (let ([e (buffers:edit-start edit)])
      (and (fx= (buffers:piece-length (buffers:edit-inserted edit)) 0)
           (fx< 0 e (document:length doc))
           (not (blank-token? (document:token doc (fx- e 1))))
           (not (blank-token? (document:token doc e))))))

  (define (follow-edit! buffer edit)
    (let ([k (eq-hashtable-ref known-by-buffer buffer #f)] [doc (buffers:document buffer)])
      (when k
        (cond
          [(eq? (known-document k) doc) (known-version-set! k (buffers:version buffer))]
          [(and (fx= (fx+ (known-version k) 1) (buffers:edit-version edit))
                (whitespace? (buffers:edit-removed edit))
                (whitespace? (buffers:edit-inserted edit))
                (not (joins? edit doc)))
           (known-document-set! k doc)
           (known-version-set! k (buffers:edit-version edit))
           (known-walks-set! k '())
           (known-lexes-set! k (filter values (map (lambda (l) (followed l edit doc)) (known-lexes k))))]
          [else (eq-hashtable-delete! known-by-buffer buffer)]))))

  (define (check-question who buffer position mode)
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
      (values doc lexer)))

  (define (buffer-mode who buffer)
    (check-main-thread who)
    (unless (buffers:buffer? buffer)
      (assertion-violation who "not a buffer" buffer))
    (modes:major-mode buffer))

  (define (own-lexer? buffer lexer) (eq? lexer (lexer-of (modes:major-mode buffer))))

  ;; Another mode's lexer reads only from the last line at or above the
  ;; position's that starts with an opening bracket, or with none from the
  ;; position's own line, so prose above, such as a lone " in Markdown,
  ;; does not turn the code below into a string.
  (define (lexed-of who buffer position mode)
    (let-values ([(doc lexer) (check-question who buffer position mode)])
      (let* ([k (known-of buffer doc)]
             [start (if (own-lexer? buffer lexer)
                        0
                        (let ([line (document:line doc position)])
                          (document:line-start doc
                            (or (walked k lexer line (lambda () (start-line who mode lexer doc position))) line))))])
        (known-lex k 'whole lexer (lambda (s e) (fx= s start))
          (lambda () (values start #f (lex-range who mode lexer doc start (document:length doc)) #t))))))

  ;; Indenting a form's lines one by one can turn each line that started
  ;; a form into one inside the form above, so the lex of that form grows
  ;; a line at a time; lexing only what it gained keeps that linear. That
  ;; holds while the gained text closes no list it did not open and the
  ;; old text left no lexeme open at its end.
  (define (extended who mode lexer doc k start end)
    (let ([old (find (lambda (l) (and (eq? (lex-kind l) 'local) (eq? (lex-lexer l) lexer)
                                      (fx= (lex-start l) start) (fx< (lex-end l) end)))
                     (known-lexes k))])
      (and old
           (let* ([from (lex-end old)] [lexed (lex-lexed old)] [v (lexed-lexemes lexed)] [n (vector-length v)])
             (and (or (fx= n 0)
                      (let ([last (vector-ref v (fx- n 1))])
                        (not (and (lexeme-record-open-ended? last) (fx= (lexeme-record-end last) from)))))
                  (let ([gained (make-lexed doc (shifted (run-lexer who mode lexer (document:slice doc from end)) from))])
                    (and (not (exists (lambda (l) (and (close? l) (fx= (lexeme-record-depth l) 0)))
                                      (vector->list (lexed-lexemes gained))))
                         (let ([depth (let loop ([i 0] [d 0])
                                        (if (fx= i n)
                                            d
                                            (let ([l (vector-ref v i)])
                                              (loop (fx+ i 1)
                                                    (cond [(open? l) (fx+ d 1)] [(and (close? l) (fx> d 0)) (fx- d 1)] [else d])))))]
                               [joined (lambda (a b)
                                         (let ([c (make-fxvector (fx+ n (fxvector-length b)))])
                                           (do ([i 0 (fx+ i 1)]) ((fx= i n)) (fxvector-set! c i (fxvector-ref a i)))
                                           (do ([i 0 (fx+ i 1)]) ((fx= i (fxvector-length b)) c)
                                             (let ([x (fxvector-ref b i)]) (fxvector-set! c (fx+ n i) (if (fx< x 0) x (fx+ x n)))))))])
                           (new-lexed doc
                             (vector-append v
                               (vector-map
                                 (lambda (l)
                                   (make-lexeme-record (lexeme-record-class l) (lexeme-record-start l) (lexeme-record-end l)
                                     (fx+ (lexeme-record-depth l) depth) (lexeme-record-open-ended? l) (lexeme-record-mismatched? l)))
                                 (lexed-lexemes gained)))
                             (joined (lexed-matches lexed) (lexed-matches gained))
                             (joined (lexed-openers lexed) (lexed-openers gained))
                             (if (fx= (vector-length (lexed-lexemes gained)) 0) (lexed-last-end lexed) (lexed-last-end gained))
                             #f)))))))))

  ;; For the buffer's own mode, a question about the text near its
  ;; positions reads only the top-level forms around them, so its cost
  ;; does not grow with the buffer; the price is that a column-0 bracket
  ;; in a string or block comment starts a form. A line whose bracket
  ;; starts at `low` goes with the form above, as beginning-of-defun finds
  ;; only an opening before point.
  (define (local-lexed-of who buffer low high mode)
    (let-values ([(doc lexer) (check-question who buffer low mode)])
      (unless (fx<= high (document:length doc))
        (assertion-violation who "not a position in the buffer" high))
      (if (own-lexer? buffer lexer)
          (let* ([k (known-of buffer doc)]
                 [before (fxmax 0 (fx- low 1))]
                 [line-start (document:line-start doc (document:line doc before))])
            (known-lex k 'local lexer
              (lambda (s e) (and (fx<= high e) (or (fx<= s line-start) (and (fx< low high) (fx= s low)))))
              (lambda ()
                (let ([start (top-start who mode lexer doc before)] [end (top-end who mode lexer doc before)])
                  (cond
                    [(fx<= high end)
                     (values start end (or (extended who mode lexer doc k start end) (lex-range who mode lexer doc start end)) #t)]
                    ;; A range from the start of a line that starts a form
                    ;; reads from there, as the lexemes after it are the
                    ;; same from either start.
                    [(and (fx< low high) (fx= low end)
                          (let ([end (top-end who mode lexer doc low)]) (and (fx<= high end) end)))
                     => (lambda (end) (values low end (lex-range who mode lexer doc low end) #t))]
                    ;; Text past `end` holds the start of another form, which
                    ;; questions about the lines there must read from.
                    [else
                     (let ([end (top-end who mode lexer doc (fx- high 1))])
                       (values start end (lex-range who mode lexer doc start end) #f))])))))
          (lexed-of who buffer low mode))))

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

  ;; Walking back from the position, over each closed list at once, costs
  ;; the sexps before it in the lists holding it, not every lexeme before
  ;; it.
  (define (openings-of lexed position)
    (let ([v (lexed-lexemes lexed)] [openers (lexed-openers lexed)])
      (let loop ([i (last-before v position)] [acc '()])
        (if (fx< i 0)
            (reverse acc)
            (let ([l (vector-ref v i)])
              (cond
                [(and (close? l) (fx>= (fxvector-ref openers i) 0)) (loop (fx- (fxvector-ref openers i) 1) acc)]
                [(and (open? l) (fx<= (lexeme-record-end l) position)) (loop (fx- i 1) (cons i acc))]
                [else (loop (fx- i 1) acc)]))))))

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
     (lexed-lexemes-between (local-lexed-of 'syntax:lexemes buffer start end mode) start end)]))

(define lexeme-at
  (case-lambda
    [(buffer position) (lexeme-at buffer position (buffer-mode 'syntax:lexeme-at buffer))]
    [(buffer position mode)
     (lexed-lexeme-at (local-lexed-of 'syntax:lexeme-at buffer position position mode) position)]))

(define openings
  (case-lambda
    [(buffer position) (openings buffer position (buffer-mode 'syntax:openings buffer))]
    [(buffer position mode)
     (lexed-openings (local-lexed-of 'syntax:openings buffer position position mode) position)]))

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
                        [(null? modes) (tables:ref table modes:fundamental "")]
                        [(tables:ref table (car modes) #f)]
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
  (and (exists (lambda (entry) ((cdr entry) buffer)) (tables:entries bracket-users)) #t))

;; Emacs's standard syntax table, which every other table inherits.
(tables:set! word-characters modes:fundamental "$%")
(tables:set! symbol-characters modes:fundamental "_-+*/&|<>=")
(hooks:add! buffers:after-edit follow-edit!)
