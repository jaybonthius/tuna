#!tuna
(import (buffers) (document) (languages) (modes) (syntax characters) (hooks) (tables))

(tables:define-table lexers
  "Maps a major mode to its lexer, a procedure of a document that returns the document's lexemes.")

(tables:define-table resumers
  "Maps a lexer to the procedure that lexes a document from a line start, given the lexer's state there: called with the document, the line start, the state, #f at the start of the text, and a position, it returns the lexemes up to the first line start at or after the position that no lexeme spans, or the end of the text, the position it stopped at, and a vector of its state at each line start it passed. The plugin keeps a buffer's states and lexes from the last line it holds.")

(define %self (current-owner))

(tables:define-table word-characters
  "Maps a major mode to the characters besides letters and digits that are part of its words, as a string, ahead of its language's.")

(tables:define-table symbol-characters
  "Maps a major mode to the characters besides letters, digits and its word characters that are part of its symbols, as a string, ahead of its language's.")

(tables:define-table bracket-pairs
  "Maps a major mode to the opening and closing characters of its brackets, as a list of pairs of characters, ahead of its language's.")

(tables:define-table escapes
  "Maps a major mode to the character that escapes the next character, in its code and inside its strings.")

(define-enumeration class (open close prefix atom string comment) %classes)

(define-enumeration %lexeme-mark (open-ended mismatched) lexeme-marks)

(buffers:define-layer brackets (priority -5) (evaporate))

(tables:define-table bracket-users
  "Maps a key to a procedure of a buffer that returns true while its plugin draws that buffer's bracket spans.")

(module %internals
  (check-main-thread make-lexeme-record lexeme-record? lexeme-record-class lexeme-record-start
   lexeme-record-end lexeme-record-depth lexeme-record-open-ended? lexeme-record-mismatched?
   check-lexeme all-marks lexer-of buffer-mode lexed-of local-lexed-of follow-edit! lexed-lexeme-at lexed-lexemes-between lexed-openings
   lexed-sexp-before lexed-sexp-after lexed-top-level-form lexed-top-level-forms comment-sexp-before
   partners-touched? seam-balanced? check-question lex-range entry-of lexed-inserted-lexeme lexed-lexeme-starting lexed-lexeme-ending lexed-match)

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

  (define (entry-of table mode otherwise)
    (let loop ([modes (modes:ancestry mode)])
      (cond
        [(null? modes) otherwise]
        [(tables:ref table (car modes) #f)]
        [else (loop (cdr modes))])))

  ;; The text is read a chunk of lines at a time from a line start whose
  ;; state is given, so the plugin can lex from the last line it holds
  ;; the state of rather than from the start of the text.
  (define-record-type line-state
    (sealed #t)
    (fields open open-start shapes depth))

  (define start-state (make-line-state #f #f '() 0))

  (define-record-type opener
    (sealed #t)
    (fields text kind delimiter))

  (define-record-type facts
    (sealed #t)
    (fields openers firsts brackets word?))

  (define (scan-text facts text state start-of end-of last? emit! line-started!)
    (let ([n (string-length text)] [openers (facts-openers facts)] [firsts (facts-firsts facts)]
          [brackets (facts-brackets facts)] [word? (facts-word? facts)])
      (define (text-at? i t)
        (let ([m (string-length t)])
          (and (fx<= (fx+ i m) n)
               (let loop ([j 0]) (or (fx= j m) (and (char=? (string-ref text (fx+ i j)) (string-ref t j)) (loop (fx+ j 1))))))))
      (define (opener-at i)
        (and (memv (string-ref text i) firsts)
             (find (lambda (o)
                     (and (text-at? i (opener-text o))
                          (or (not (languages:delimiter-word-start? (opener-delimiter o)))
                              (fx= i 0)
                              (not (word? (string-ref text (fx- i 1)))))))
                   openers)))
      (define (closer? c) (exists (lambda (p) (char=? (cdr p) c)) brackets))
      (define (line-end i)
        (let loop ([j i]) (if (or (fx= j n) (char=? (string-ref text j) #\newline)) j (loop (fx+ j 1)))))
      (define (body-end o open-start j shapes depth)
        (let* ([d (opener-delimiter o)] [close (languages:delimiter-end d)]
               [escape (and (eq? (opener-kind o) 'string) (languages:delimiter-escape d))]
               [line-bound? (languages:delimiter-line-bound? d)])
          (let loop ([k j])
            (cond
              [(fx= k n) (values n #t)]
              [(and escape (char=? (string-ref text k) escape) (fx< (fx+ k 1) n))
               (when (char=? (string-ref text (fx+ k 1)) #\newline)
                 (line-started! (make-line-state o open-start shapes depth)))
               (loop (fx+ k 2))]
              [(text-at? k close) (values (fx+ k (string-length close)) #f)]
              [(char=? (string-ref text k) #\newline)
               (if line-bound?
                   (values k #t)
                   (begin (line-started! (make-line-state o open-start shapes depth)) (loop (fx+ k 1))))]
              [else (loop (fx+ k 1))]))))
      (define (delimited o open-start j shapes depth)
        (let-values ([(end open?) (body-end o open-start j shapes depth)])
          (if (and open? (fx= end n) (not last?))
              (make-line-state o open-start shapes depth)
              (begin
                (emit! (if (eq? (opener-kind o) 'string) 'string 'comment) open-start (end-of end) depth open? #f)
                (scan end shapes depth)))))
      (define (scan i shapes depth)
        (if (fx= i n)
            (make-line-state #f #f shapes depth)
            (let ([c (string-ref text i)])
              (cond
                [(char=? c #\newline)
                 (line-started! (make-line-state #f #f shapes depth))
                 (scan (fx+ i 1) shapes depth)]
                [(char-whitespace? c) (scan (fx+ i 1) shapes depth)]
                [(opener-at i)
                 => (lambda (o)
                      (if (eq? (opener-kind o) 'line)
                          (let ([end (line-end i)])
                            (emit! 'comment (start-of i) (end-of end) depth #t #f)
                            (scan end shapes depth))
                          (delimited o (start-of i) (fx+ i (string-length (opener-text o))) shapes depth)))]
                [(assv c brackets)
                 => (lambda (p)
                      (emit! 'open (start-of i) (end-of (fx+ i 1)) (fx+ depth 1) #f #f)
                      (scan (fx+ i 1) (cons (cdr p) shapes) (fx+ depth 1)))]
                [(closer? c)
                 (if (null? shapes)
                     (begin (emit! 'close (start-of i) (end-of (fx+ i 1)) 0 #f #f) (scan (fx+ i 1) shapes 0))
                     (begin
                       (emit! 'close (start-of i) (end-of (fx+ i 1)) depth #f (not (char=? c (car shapes))))
                       (scan (fx+ i 1) (cdr shapes) (fx- depth 1))))]
                [else
                 (let ([end (let loop ([k (fx+ i 1)])
                              (if (or (fx= k n)
                                      (let ([c (string-ref text k)])
                                        (or (char-whitespace? c) (assv c brackets) (closer? c) (opener-at k))))
                                  k
                                  (loop (fx+ k 1))))])
                   (emit! 'atom (start-of i) (end-of end) depth #f #f)
                   (scan end shapes depth))]))))
      (let ([open (line-state-open state)])
        (if open
            (delimited open (line-state-open-start state) 0 (line-state-shapes state) (line-state-depth state))
            (scan 0 (line-state-shapes state) (line-state-depth state))))))

  ;; A text that holds nodes besides characters has positions its
  ;; characters do not count. A file's text sits inside its root node,
  ;; whose opening and closing are the only such tokens at the edges of
  ;; its first and last lines, so they are told apart without a lookup
  ;; per lexeme.
  (define (chunk-mapping doc from to text)
    (let* ([lead (if (and (fx< from to) (document:node? (document:token doc from))) 1 0)]
           [trail (if (and (fx< (fx+ from lead) to) (eq? (document:token doc (fx- to 1)) 'close)) 1 0)])
      (if (fx= (string-length text) (fx- (fx- to from) (fx+ lead trail)))
          (let ([shift (fx+ from lead)])
            (values (lambda (i) (fx+ shift i)) (lambda (i) (fx+ shift i))))
          (let ([unit (document:unit characters)] [base (document:offset doc from (document:unit characters))])
            (values (lambda (i) (fx- (document:position doc (fx+ base i 1) unit) 1))
                    (lambda (i) (if (fx= i 0) from (document:position doc (fx+ base i) unit))))))))

  (define (lex-from facts doc from state end)
    (let* ([size (document:length doc)] [last-line (document:line doc size)])
      (if (and (fx>= from end) (not (line-state-open state)) (fx< from size))
          (values '#() from '#())
          (let loop ([from from] [state state] [lines (fxmax 1 (fx+ 1 (fx- (document:line doc (fxmin end size)) (document:line doc from))))]
                     [lexemes '()] [states '()])
            (let* ([last-of (fx+ (document:line doc from) lines)]
                   [to (if (fx> last-of last-line) size (document:line-start doc last-of))]
                   [text (document:text doc from to)]
                   [last? (fx= to size)])
              (let-values ([(start-of end-of) (chunk-mapping doc from to text)])
                (let* ([acc lexemes] [started states]
                       [state (scan-text facts text state start-of end-of last?
                                (lambda (class start end depth open-ended? mismatched?)
                                  (set! acc (cons (make-lexeme-record class start end depth open-ended? mismatched?) acc)))
                                (lambda (s) (set! started (cons s started))))])
                  (if (or last? (and (fx>= to end) (not (line-state-open state))))
                      (values (list->vector (reverse acc)) to (list->vector (reverse started)))
                      (loop to state (fx* lines 2) acc started)))))))))

  ;; The plugin's own entry, so it goes when the plugin unloads, whatever
  ;; asked the question that made the lexer.
  (define (make-generic-lexer facts)
    (let ([lexer (lambda (doc)
                   (unless (document? doc)
                     (assertion-violation 'syntax:lexer "not a document" doc))
                   (let-values ([(lexemes stop states) (lex-from facts doc 0 start-state (document:length doc))])
                     lexemes))])
      (call-as-owner %self
        (lambda ()
          (tables:set! resumers lexer
            (lambda (doc start state end) (lex-from facts doc start (or state start-state) end)))))
      lexer))

  (define (language-facts lines blocks strings brackets words symbols)
    (let ([openers (list-sort
                     (lambda (a b) (fx> (string-length (opener-text a)) (string-length (opener-text b))))
                     (append (map (lambda (d) (make-opener (languages:delimiter-start d) 'line d)) lines)
                             (map (lambda (d) (make-opener (languages:delimiter-start d) 'block d)) blocks)
                             (map (lambda (d) (make-opener (languages:delimiter-start d) 'string d)) strings)))])
      (make-facts openers (map (lambda (o) (string-ref (opener-text o) 0)) openers) brackets
        (word-char-predicate (string-append words symbols)))))

  ;; One lexer per language while its facts are the same values, since
  ;; the questions tell whose lexer lexed a text by eq?. A word-start
  ;; delimiter reads the language's own word and symbol characters, not a
  ;; mode's, since the lexer is the language's.
  (define generic-lexers (make-hashtable string-hash string=?))

  (define (generic-lexer-of language)
    (let ([seen (vector (languages:line-comments-of language)
                        (languages:block-comments-of language)
                        (languages:strings-of language)
                        (languages:brackets-of language)
                        (or (languages:word-characters-of language) "")
                        (or (languages:symbol-characters-of language) ""))]
          [known (hashtable-ref generic-lexers language #f)])
      (cond
        [(and known (let ([old (car known)])
                      (let loop ([i 0])
                        (or (fx= i (vector-length seen))
                            (and (eq? (vector-ref seen i) (vector-ref old i)) (loop (fx+ i 1)))))))
         (cdr known)]
        [else
         (when known
           (hashtable-delete! generic-lexers language)
           (call-as-owner %self (lambda () (tables:remove! resumers (cdr known)))))
         (and (exists pair? (list (vector-ref seen 0) (vector-ref seen 1) (vector-ref seen 2) (vector-ref seen 3)))
              (let ([lexer (make-generic-lexer (apply language-facts (vector->list seen)))])
                (hashtable-set! generic-lexers language (cons seen lexer))
                lexer))])))

  (define (lexer-of mode)
    (or (entry-of lexers mode #f)
        (let ([language (languages:of mode)])
          (and language (generic-lexer-of language)))))

  (define (resumer-of lexer) (tables:ref resumers lexer #f))

  ;; A list with no match ends with the last lexeme, so the end of that
  ;; one is kept beside the matches.
  (define-record-type (lexed new-lexed lexed?)
    (sealed #t)
    (fields document lexemes matches openers last-end (mutable forms)))

  (define (open? l) (eq? (lexeme-record-class l) 'open))
  (define (close? l) (eq? (lexeme-record-class l) 'close))

  ;; The opening waiting at each depth is kept in a vector by depth, since
  ;; a text of hundreds of thousands of brackets is matched after each
  ;; edit.
  (define (matches-of v)
    (let ([n (vector-length v)])
      (let ([matches (make-fxvector n -1)])
        (let loop ([i 0] [waiting (make-fxvector 16 -1)])
          (if (fx= i n)
              matches
              (let* ([l (vector-ref v i)] [d (lexeme-record-depth l)])
                (cond
                  [(open? l)
                   (let ([waiting (if (fx< d (fxvector-length waiting))
                                      waiting
                                      (let ([w (make-fxvector (fx* 2 (fx+ d 1)) -1)])
                                        (do ([k 0 (fx+ k 1)]) ((fx= k (fxvector-length waiting)) w)
                                          (fxvector-set! w k (fxvector-ref waiting k)))))])
                     (fxvector-set! waiting d i)
                     (loop (fx+ i 1) waiting))]
                  [(and (close? l) (fx< d (fxvector-length waiting)) (fx>= (fxvector-ref waiting d) 0))
                   (fxvector-set! matches (fxvector-ref waiting d) i)
                   (fxvector-set! waiting d -1)
                   (loop (fx+ i 1) waiting)]
                  [else (loop (fx+ i 1) waiting)])))))))

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
    (fields (mutable document) (mutable version) (mutable lexes) (mutable walks) (mutable lines)))

  ;; An edit keeps the lexemes and states above the line it touches, as
  ;; Emacs's syntax-ppss keeps its states above an edit.
  (define-record-type lines
    (sealed #t)
    (fields lexer (mutable lexemes) (mutable end) (mutable line) (mutable states) (mutable lexed)))

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
          (let ([k (make-known doc (buffers:version buffer) '() '() #f)])
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

  ;; The lexemes that end before the start of the edited line stay, with
  ;; the states through that line, whose text before them is unchanged. A
  ;; lexeme that ends at a line start ends there only because the text
  ;; did, so it goes: the text may now go on.
  (define (lines-above! ls doc position)
    (let ([line (fxmin (lines-line ls) (document:line doc position))])
      (unless (and (fx= line (lines-line ls)) (fx= (lines-end ls) (document:line-start doc line)))
        (let* ([end (document:line-start doc line)] [v (lines-lexemes ls)]
               [kept (let loop ([low 0] [high (vector-length v)])
                       (if (fx= low high)
                           low
                           (let ([mid (fxsrl (fx+ low high) 1)])
                             (if (fx< (lexeme-record-end (vector-ref v mid)) end) (loop (fx+ mid 1) high) (loop low mid)))))])
          (lines-lexemes-set! ls (if (fx= kept (vector-length v)) v (vector-copy v 0 kept)))
          (lines-end-set! ls end)
          (lines-line-set! ls line)
          (lines-lexed-set! ls #f)))))

  (define (follow-edit! buffer edit)
    (let ([k (eq-hashtable-ref known-by-buffer buffer #f)] [doc (buffers:document buffer)])
      (when k
        (cond
          [(eq? (known-document k) doc) (known-version-set! k (buffers:version buffer))]
          [(not (fx= (fx+ (known-version k) 1) (buffers:edit-version edit))) (eq-hashtable-delete! known-by-buffer buffer)]
          [else
           (let ([ls (known-lines k)])
             (when ls (lines-above! ls doc (buffers:edit-start edit)))
             (known-document-set! k doc)
             (known-version-set! k (buffers:edit-version edit))
             (known-walks-set! k '())
             (known-lexes-set! k
               (if (and (whitespace? (buffers:edit-removed edit)) (whitespace? (buffers:edit-inserted edit))
                        (not (joins? edit doc)))
                   (filter values (map (lambda (l) (followed l edit doc)) (known-lexes k)))
                   '())))]))))

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

  (define (run-resumed who mode lexer doc ls need)
    (let-values ([(v stop states)
                  (guard (c [(not (cancelled? c))
                             (assertion-violation who
                               (format "the lexer of ~s raised: ~a" mode (if (condition? c) (condition-text c) c))
                               lexer)])
                    ((resumer-of lexer) doc (lines-end ls) (vector-ref (lines-states ls) (lines-line ls)) need))])
      (let ([size (document:length doc)] [old (lines-lexemes ls)])
        (unless (and (vector? v) (vector? states) (fixnum? stop) (fx<= (lines-end ls) stop size)
                     (let loop ([i 0] [after (let ([n (vector-length old)])
                                               (if (fx= n 0) 0 (lexeme-record-end (vector-ref old (fx- n 1)))))])
                       (or (fx= i (vector-length v))
                           (let ([l (vector-ref v i)])
                             (and (lexeme-record? l)
                                  (fx>= (lexeme-record-start l) after)
                                  (fx<= (lexeme-record-end l) size)
                                  (loop (fx+ i 1) (lexeme-record-end l)))))))
          (assertion-violation who "the lexer did not return lexemes in order within the document" mode lexer))
        (values v stop states))))

  ;; The questions about one text read one lex of it, kept from the start
  ;; of the text up to as far as any question needed, so typing on a line
  ;; costs the lines between it and the farthest position asked about.
  (define (lexed-from-lines who buffer doc mode lexer need)
    (let* ([k (known-of buffer doc)]
           [ls (let ([ls (known-lines k)])
                 (if (and ls (eq? (lines-lexer ls) lexer))
                     ls
                     (let ([ls (make-lines lexer '#() 0 1 (make-vector 2 #f) #f)])
                       (known-lines-set! k ls)
                       ls)))])
      (unless (fx= (lines-end ls) (document:length doc))
        (let-values ([(v stop states) (run-resumed who mode lexer doc ls need)])
          (unless (and (fx= (vector-length v) 0) (fx= (vector-length states) 0))
            (let* ([line (fx+ (lines-line ls) (vector-length states))] [old (lines-states ls)]
                   [grown (if (fx< line (vector-length old))
                              old
                              (let ([new (make-vector (fxmax (fx+ line 1) (fx* 2 (vector-length old))) #f)])
                                (do ([i 0 (fx+ i 1)]) ((fx= i (vector-length old)) new) (vector-set! new i (vector-ref old i)))))])
              (do ([i 0 (fx+ i 1)]) ((fx= i (vector-length states)))
                (vector-set! grown (fx+ (lines-line ls) i 1) (vector-ref states i)))
              (lines-states-set! ls grown)
              (lines-lexemes-set! ls (vector-append (lines-lexemes ls) v))
              (lines-end-set! ls stop)
              (lines-line-set! ls line)
              (lines-lexed-set! ls #f)))))
      (or (lines-lexed ls)
          (let ([lexed (make-lexed doc (lines-lexemes ls))])
            (lines-lexed-set! ls lexed)
            lexed))))

  ;; Another mode's lexer reads only from the last line at or above the
  ;; position's that starts with an opening bracket, or with none from the
  ;; position's own line, so prose above, such as a lone " in Markdown,
  ;; does not turn the code below into a string.
  (define (lexed-of who buffer position mode)
    (let-values ([(doc lexer) (check-question who buffer position mode)])
      (if (and (own-lexer? buffer lexer) (resumer-of lexer))
          (lexed-from-lines who buffer doc mode lexer (document:length doc))
          (lexed-of-start who buffer doc lexer position mode))))

  (define (lexed-of-start who buffer doc lexer position mode)
    (let* ([k (known-of buffer doc)]
           [start (if (own-lexer? buffer lexer)
                      0
                      (let ([line (document:line doc position)])
                        (document:line-start doc
                          (or (walked k lexer line (lambda () (start-line who mode lexer doc position))) line))))])
      (known-lex k 'whole lexer (lambda (s e) (fx= s start))
        (lambda () (values start #f (lex-range who mode lexer doc start (document:length doc)) #t)))))

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
      (cond
        [(not (own-lexer? buffer lexer)) (lexed-of-start who buffer doc lexer low mode)]
        [(resumer-of lexer) (lexed-from-lines who buffer doc mode lexer high)]
        [else
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
                      (values start end (lex-range who mode lexer doc start end) #f))])))))])))

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

  (define (lexed-lexeme-starting lexed position)
    (let* ([v (lexed-lexemes lexed)] [i (fx+ (last-before v position) 1)])
      (and (fx< i (vector-length v))
           (fx= (lexeme-record-start (vector-ref v i)) position)
           (vector-ref v i))))

  (define (lexed-lexeme-ending lexed position)
    (let* ([v (lexed-lexemes lexed)] [i (last-before v position)])
      (and (fx>= i 0)
           (fx= (lexeme-record-end (vector-ref v i)) position)
           (vector-ref v i))))

  ;; The lexeme is found again by its start, since each answer makes its
  ;; own lexeme records.
  (define (lexed-match who lexed lexeme)
    (let* ([v (lexed-lexemes lexed)] [i (fx+ (last-before v (lexeme-record-start lexeme)) 1)])
      (unless (and (fx< i (vector-length v))
                   (let ([l (vector-ref v i)])
                     (and (fx= (lexeme-record-start l) (lexeme-record-start lexeme))
                          (fx= (lexeme-record-end l) (lexeme-record-end lexeme))
                          (eq? (lexeme-record-class l) (lexeme-record-class lexeme))
                          (memq (lexeme-record-class l) '(open close)))))
        (assertion-violation who "not a bracket of the buffer's text" lexeme))
      (let ([m (if (open? (vector-ref v i)) (fxvector-ref (lexed-matches lexed) i) (fxvector-ref (lexed-openers lexed) i))])
        (and (fx>= m 0) (vector-ref v m)))))

  ;; Read from the start of the lexeme the position touches, so text that
  ;; joins it, as ( after # does, is read as joined.
  (define (lexed-inserted-lexeme who mode lexed position text)
    (let* ([doc (lexed-document lexed)]
           [v (lexed-lexemes lexed)]
           [from (let ([i (last-before v position)])
                   (if (and (fx>= i 0) (fx>= (lexeme-record-end (vector-ref v i)) position))
                       (lexeme-record-start (vector-ref v i))
                       position))]
           [line (document:line doc position)]
           [to (if (fx< line (document:line doc (fx- (document:length doc) 1)))
                   (fx- (document:line-start doc (fx+ line 1)) 1)
                   (fxmax position (fx- (document:length doc) 1)))]
           [at (fx- position from)]
           [read (run-lexer who mode (lexer-of mode)
                   (document:replace (document:slice doc from to) at at (document:from-datum text)))]
           [i (last-before read (fx+ at 1))])
      (and (fx>= i 0)
           (let ([l (vector-ref read i)])
             (and (fx< at (lexeme-record-end l))
                  (make-lexeme-record (lexeme-record-class l) (fx+ (lexeme-record-start l) from)
                    (fx+ (lexeme-record-end l) from) (fx+ (lexeme-record-depth l) (length (openings-of lexed from)))
                    (lexeme-record-open-ended? l) (lexeme-record-mismatched? l)))))))

  (define (lexed-top-level-forms lexed start end)
    (map (lambda (f) (cons (car f) (cdr f)))
         (filter (lambda (f)
                   (if (fx= start end)
                       (fx<= (car f) start (cdr f))
                       (and (fx< (car f) end) (fx> (cdr f) start))))
                 (forms-of lexed))))

  ;; A bracket lexeme the range cuts, as #( cut after its #, is taken
  ;; with the range, so its partner must be taken too.
  (define (partners-touched? lexed from to)
    (let* ([v (lexed-lexemes lexed)] [n (vector-length v)]
           [touched? (lambda (l) (and (fx< (lexeme-record-start l) to) (fx> (lexeme-record-end l) from)))])
      (let loop ([i (fxmax 0 (last-before v from))])
        (or (fx>= i n)
            (let ([l (vector-ref v i)])
              (or (fx>= (lexeme-record-start l) to)
                  (and (or (not (touched? l))
                           (not (memq (lexeme-record-class l) '(open close)))
                           (let ([m (if (open? l) (fxvector-ref (lexed-matches lexed) i) (fxvector-ref (lexed-openers lexed) i))])
                             (or (fx< m 0) (touched? (vector-ref v m)))))
                       (loop (fx+ i 1)))))))))

  ;; Brackets the inserted text makes or touches are its own, so each must
  ;; have its partner in it too; a stray one would close or open a list
  ;; outside.
  (define (inserted-partnered? lexed from to)
    (or (fx= from to)
        (let* ([v (lexed-lexemes lexed)] [n (vector-length v)]
               [touched? (lambda (l) (and (fx< (lexeme-record-start l) to) (fx> (lexeme-record-end l) from)))])
          (let loop ([i (fxmax 0 (last-before v from))])
            (or (fx>= i n)
                (let ([l (vector-ref v i)])
                  (or (fx>= (lexeme-record-start l) to)
                      (and (or (not (touched? l))
                               (not (memq (lexeme-record-class l) '(open close)))
                               (let ([m (if (open? l) (fxvector-ref (lexed-matches lexed) i) (fxvector-ref (lexed-openers lexed) i))])
                                 (and (fx>= m 0) (touched? (vector-ref v m)))))
                           (loop (fx+ i 1))))))))))

  ;; A comment the end of its line closes is open-ended by nature; any
  ;; other lexeme left open, a string or a comment that runs over a line
  ;; break, has lost its end.
  (define (alone-balanced? doc v)
    (let loop ([i 0] [depth 0])
      (if (fx= i (vector-length v))
          (fx= depth 0)
          (let ([l (vector-ref v i)])
            (cond
              [(open? l) (loop (fx+ i 1) (fx+ depth 1))]
              [(close? l) (and (fx> depth 0) (not (lexeme-record-mismatched? l)) (loop (fx+ i 1) (fx- depth 1)))]
              [(and (lexeme-record-open-ended? l)
                    (or (not (eq? (lexeme-record-class l) 'comment))
                        (let ([text (document:text doc (lexeme-record-start l) (lexeme-record-end l))])
                          (exists (lambda (c) (char=? c #\newline)) (string->list text)))))
               #f]
              [else (loop (fx+ i 1) depth)])))))

  ;; Each position's lexeme, as its class and its ends, the ends moved as
  ;; the edit moves them, so a string or comment whose edge moved differs
  ;; everywhere in it.
  (define (lexeme-places v n move-start move-end)
    (let ([places (make-vector n #f)])
      (vector-for-each
        (lambda (l)
          (let ([place (list (lexeme-record-class l) (move-start (lexeme-record-start l)) (move-end (lexeme-record-end l)))])
            (do ([i (lexeme-record-start l) (fx+ i 1)]) ((fx>= i (fxmin n (lexeme-record-end l))))
              (vector-set! places i place))))
        v)
      places))

  ;; An edit changes how the text after it reads only through the lexemes
  ;; it touches, as when it moves a comment's edge or starts a lexeme that
  ;; runs on, so the lines around the seam are enough; text read on to
  ;; their end could run to the end of the buffer, so it is refused.
  ;; Paredit checks the same at a line comment's edge.
  (define (seam-balanced? who mode lexer lexed doc start end text)
    (let* ([last (fx- (document:length doc) 1)]
           [line-start (document:line-start doc (document:line doc start))]
           [near (lexed-lexemes-between lexed line-start (fxmin last (fx+ end 1)))]
           [from (fold-left (lambda (q l) (fxmin q (lexeme-record-start l))) line-start near)]
           [reach (fold-left (lambda (q l) (fxmax q (lexeme-record-end l))) end near)]
           [to (let ([line (document:line doc (fxmin reach last))])
                 (if (fx< line (document:line doc last))
                     (fxmin last (line-end doc (fx+ line 1) (document:line doc last)))
                     last))]
           [old (document:slice doc from to)]
           [at (fx- start from)] [gone (fx- end start)] [added (string-length text)]
           [new (document:replace old at (fx+ at gone) (document:from-datum text))]
           [n (document:length new)]
           [moved (lambda (q) (fx+ q (fx- added gone)))]
           [new-start (lambda (q) (cond [(fx< q at) q] [(fx>= q (fx+ at gone)) (moved q)] [else (fx+ at added)]))]
           [new-end (lambda (q) (cond [(fx<= q at) q] [(fx> q (fx+ at gone)) (moved q)] [else at]))]
           [old-places (lexeme-places (run-lexer who mode lexer old) (document:length old) new-start new-end)]
           [new-lexed (make-lexed new (run-lexer who mode lexer new))]
           [new-places (lexeme-places (lexed-lexemes new-lexed) n values values)]
           [old-position (lambda (q) (if (fx< q at) q (fx+ q (fx- gone added))))]
           [old-end (lambda (q) (if (fx<= q at) q (fx+ q (fx- gone added))))]
           [crossing? (lambda (q)
                        (and (not (and (fx<= at q) (fx< q (fx+ at added))))
                             (not (equal? (vector-ref new-places q) (vector-ref old-places (old-position q))))))])
      (let loop ([q 0])
        (cond
          [(fx>= q n) (inserted-partnered? new-lexed at (fx+ at added))]
          [(crossing? q)
           (let ([run-end (let run ([k q]) (if (and (fx< k n) (crossing? k)) (run (fx+ k 1)) k))])
             (and (or (fx< run-end n) (fx= to last))
                  (let ([run (document:slice new q run-end)]) (alone-balanced? run (run-lexer who mode lexer run)))
                  (let ([run (document:slice old (old-position q) (old-end run-end))]) (alone-balanced? run (run-lexer who mode lexer run)))
                  (loop run-end)))]
          [else (loop (fx+ q 1))]))))

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

(define lexeme-starting-at
  (case-lambda
    [(buffer position) (lexeme-starting-at buffer position (buffer-mode 'syntax:lexeme-starting-at buffer))]
    [(buffer position mode)
     (unless (buffers:buffer? buffer)
       (assertion-violation 'syntax:lexeme-starting-at "not a buffer" buffer))
     ;; From the position to the next, so a bracket at the start of a line
     ;; that starts a form is read with that form.
     (let ([high (if (and (fixnum? position) (fx< position (document:length (buffers:document buffer)))) (fx+ position 1) position)])
       (lexed-lexeme-starting (local-lexed-of 'syntax:lexeme-starting-at buffer position high mode) position))]))

(define lexeme-ending-at
  (case-lambda
    [(buffer position) (lexeme-ending-at buffer position (buffer-mode 'syntax:lexeme-ending-at buffer))]
    [(buffer position mode)
     (let ([low (if (and (fixnum? position) (fx> position 0)) (fx- position 1) position)])
       (lexed-lexeme-ending (local-lexed-of 'syntax:lexeme-ending-at buffer low position mode) position))]))

(define inserted-lexeme
  (case-lambda
    [(buffer position text) (inserted-lexeme buffer position text (buffer-mode 'syntax:inserted-lexeme buffer))]
    [(buffer position text mode)
     (unless (and (string? text) (fx> (string-length text) 0))
       (assertion-violation 'syntax:inserted-lexeme "not a non-empty string" text))
     (lexed-inserted-lexeme 'syntax:inserted-lexeme mode
       (local-lexed-of 'syntax:inserted-lexeme buffer position position mode) position text)]))

(define match
  (case-lambda
    [(buffer lexeme) (match buffer lexeme (buffer-mode 'syntax:match buffer))]
    [(buffer lexeme mode)
     (check-lexeme 'syntax:match lexeme)
     (unless (buffers:buffer? buffer)
       (assertion-violation 'syntax:match "not a buffer" buffer))
     ;; The forms around the bracket, as the questions that return brackets
     ;; read them, so a bracket they return is always found here.
     (let ([start (lexeme-record-start lexeme)])
       (lexed-match 'syntax:match
         (local-lexed-of 'syntax:match buffer start (fxmin (fx+ start 1) (document:length (buffers:document buffer))) mode)
         lexeme))]))

(define string-or-comment-at
  (case-lambda
    [(buffer position) (string-or-comment-at buffer position (buffer-mode 'syntax:string-or-comment-at buffer))]
    [(buffer position mode)
     (let ([l (lexed-lexeme-at (local-lexed-of 'syntax:string-or-comment-at buffer position position mode) position)])
       (and l (memq (lexeme-record-class l) '(string comment)) l))]))

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

(define top-level-forms
  (case-lambda
    [(buffer start end) (top-level-forms buffer start end (buffer-mode 'syntax:top-level-forms buffer))]
    [(buffer start end mode)
     (unless (and (fixnum? start) (fixnum? end) (fx<= 0 start end))
       (assertion-violation 'syntax:top-level-forms "not a range" start end))
     (let ([lexed (lexed-of 'syntax:top-level-forms buffer start mode)])
       (unless (fx<= end (document:length (buffers:document buffer)))
         (assertion-violation 'syntax:top-level-forms "not a position in the buffer" end))
       (lexed-top-level-forms lexed start end))]))

(define balanced?
  (case-lambda
    [(buffer start end text) (balanced? buffer start end text (buffer-mode 'syntax:balanced? buffer))]
    [(buffer start end text mode)
     (unless (and (fixnum? start) (fixnum? end) (fx<= 0 start end))
       (assertion-violation 'syntax:balanced? "not a range" start end))
     (unless (string? text)
       (assertion-violation 'syntax:balanced? "not a string" text))
     (let-values ([(doc lexer) (check-question 'syntax:balanced? buffer end mode)])
       (or (and (fx= start end) (string=? text ""))
           (let ([lexed (local-lexed-of 'syntax:balanced? buffer start end mode)])
             (and (partners-touched? lexed start end)
                  (seam-balanced? 'syntax:balanced? mode lexer lexed doc start end text)))))]))

(define (mode-escape mode)
  (unless (symbol? mode)
    (assertion-violation 'syntax:mode-escape "not a mode" mode))
  (let ([escape (entry-of escapes mode #f)])
    (unless (or (not escape) (char? escape))
      (assertion-violation 'syntax:mode-escape "the mode's entry is not a character" mode escape))
    escape))

(define (%language-entry read mode)
  (let ([language (languages:of mode)])
    (and language (read language))))

(define (mode-bracket-pairs mode)
  (unless (symbol? mode)
    (assertion-violation 'syntax:mode-bracket-pairs "not a mode" mode))
  (let ([pairs (entry-of bracket-pairs mode (or (%language-entry languages:brackets-of mode) '()))])
    (unless (and (list? pairs) (for-all (lambda (p) (and (pair? p) (char? (car p)) (char? (cdr p)))) pairs))
      (assertion-violation 'syntax:mode-bracket-pairs "the mode's entry is not a list of pairs of characters" mode pairs))
    pairs))

(define (%characters-of who table read mode)
  (unless (symbol? mode)
    (assertion-violation who "not a mode" mode))
  (let ([characters (entry-of table mode
                      (or (%language-entry read mode) (tables:ref table modes:fundamental "")))])
    (unless (string? characters)
      (assertion-violation who "the mode's entry is not a string" mode characters))
    characters))

(define (mode-word-characters mode)
  (%characters-of 'syntax:mode-word-characters word-characters languages:word-characters-of mode))

(define (mode-symbol-characters mode)
  (%characters-of 'syntax:mode-symbol-characters symbol-characters languages:symbol-characters-of mode))

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
