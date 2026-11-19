#!tuna
;; This plugin's substring is a style, so Chez's goes by another name.
(import (minibuffer) (buffers) (document) (views) (layout) (keys) (commands) (jobs) (web) (completion matcher)
        (rename (only (chezscheme) substring) (substring string-part)))

(define-hook started "Called with a session when it starts, before its first matches.")

(define-hook updated "Called with a session after its matches or its selection change.")

(define-hook ended "Called with a session after it ends.")

(define-hook find-region
  "Its entries take no arguments and return a region for point in the current view, or #f.")

(define-table category-styles
  "Maps a category to the styles tried before its default styles: its completion:category-default-styles entry while completion:styles holds its default, else completion:styles.")

(define-table category-default-styles
  "Maps a category to the styles used in place of completion:styles while that option holds its default.")

(define-table annotators "Maps a category to a procedure of a session that returns its annotator.")

(define-table action-keymaps "Maps a category to the list of keymaps of the actions on its candidates, searched in order.")

(define-table any-order-dispatch
  "Maps a character to a procedure of the rest of a component that returns a term.")

(define-table keymap "Added to the prompt of each read.")

(define-table region-keymap "The temporary keymap of a session at point.")

(define-table region-selected-keymap "The temporary keymap of a session at point while a match is selected.")

(define-syntax define-category
  (lambda (x)
    (syntax-case x ()
      [(_ id doc) (and (identifier? #'id) (string? (syntax->datum #'doc)))
       #'(define-public id (%category-name 'id))]
      [_ (syntax-violation 'completion:define-category "expected (completion:define-category id doc-string)" x)])))

(define (%category-name id)
  (let ([owner (current-owner)])
    (if (member owner '((init) (repl)))
        id
        (string->symbol
          (call-with-string-output-port
            (lambda (p)
              (let loop ([parts owner])
                (display (car parts) p)
                (unless (null? (cdr parts))
                  (put-char p #\/)
                  (loop (cdr parts))))
              (put-char p #\:)
              (display id p)))))))

;; Categories that more than one plugin reads, defined here so that none
;; of them imports another for a name.
(define-category buffer-category "Live buffers, valued by the buffer.")

(define-category command-category "Loaded commands, valued by the command.")

(define-category file-category "File names, valued by the whole path.")

(define-category location-category "Lines of files, valued by a location: a pair of a path and a line number.")

;; Several plugins bind actions on the shared categories, so their
;; keymaps are defined beside them.
(define-table buffer-action-keymap "The actions on buffers.")

(define-table command-action-keymap "The actions on commands.")

(define-table file-action-keymap "The actions on file names.")

(define-table location-action-keymap "The actions on locations.")

(define-record-type (%source %make-source source?)
  (sealed #t)
  (fields candidates stream category title split in-order? rank preview styles))

(define (%check-source candidates stream category title split in-order? rank preview styles)
  (define who 'completion:source)
  (unless (or (not category) (symbol? category))
    (assertion-violation who "not a category" category))
  (unless (or (not title) (string? title))
    (assertion-violation who "neither a string nor #f" title))
  (unless (or (not split) (procedure? split))
    (assertion-violation who "not a procedure" split))
  (unless (or (not rank) (and (vector? rank) (for-all fixnum? (vector->list rank))
                              (vector? candidates) (fx= (vector-length rank) (vector-length candidates))))
    (assertion-violation who "not a vector of fixnums, one for each candidate" rank))
  (unless (or (not preview) (procedure? preview))
    (assertion-violation who "not a procedure" preview))
  (unless (or (not styles) (and (list? styles) (for-all procedure? styles)))
    (assertion-violation who "not a list of styles" styles))
  (%make-source candidates stream category title split in-order? rank preview styles))

(define (%candidates-clause candidates)
  (unless (or (procedure? candidates) (%candidates? candidates))
    (assertion-violation 'completion:source "neither a vector of candidates nor a procedure" candidates))
  candidates)

(define (%stream-clause stream)
  (unless (procedure? stream)
    (assertion-violation 'completion:source "not a procedure" stream))
  stream)

(define (%candidate? c) (or (string? c) (and (pair? c) (string? (car c)))))

(define (%candidates? v)
  (and (vector? v)
       (let loop ([i 0]) (or (fx= i (vector-length v)) (and (%candidate? (vector-ref v i)) (loop (fx+ i 1)))))))

(define-syntax source
  (lambda (x)
    (define (invalid c) (syntax-violation 'completion:source "invalid clause" x c))
    (syntax-case x ()
      [(_ clause ...)
       (let loop ([clauses #'(clause ...)] [given '()])
         (define (given-or-false name) (let ([g (assq name given)]) (if g (cdr g) #'#f)))
         (if (null? clauses)
             (let ([candidates (assq 'candidates given)] [stream (or (assq 'stream given) (assq 'job given))])
               (unless (or candidates stream)
                 (syntax-violation 'completion:source "a candidates, job or stream clause is required" x))
               #`(%check-source #,(if candidates #`(%candidates-clause #,(cdr candidates)) #'#f)
                                #,(if stream #`(%stream-clause #,(cdr stream)) #'#f)
                                #,(given-or-false 'category) #,(given-or-false 'title) #,(given-or-false 'split)
                                #,(given-or-false 'in-order) #,(given-or-false 'rank) #,(given-or-false 'preview)
                                #,(given-or-false 'styles)))
             (let* ([c (car clauses)]
                    [name (syntax-case c () [(k . _) (identifier? #'k) (syntax->datum #'k)] [_ (invalid c)])])
               (when (assq name given)
                 (syntax-violation 'completion:source "clause given twice" x c))
               (when (and (memq name '(candidates job stream))
                          (exists (lambda (k) (assq k given)) '(candidates job stream)))
                 (syntax-violation 'completion:source "more than one of the candidates, job and stream clauses" x))
               (loop (cdr clauses)
                     (cons (cons name
                                 (case name
                                   [(candidates stream category title split rank preview styles)
                                    (syntax-case c () [(_ e) #'e] [_ (invalid c)])]
                                   [(job) (syntax-case c () [(_ w i) #'(%job-stream w i)] [_ (invalid c)])]
                                   [(in-order) (syntax-case c () [(_) #'#t] [_ (invalid c)])]
                                   [else (invalid c)]))
                           given)))))])))

(define (%job-stream worker input)
  (unless (jobs:worker? worker)
    (assertion-violation 'completion:source "not a worker" worker))
  (lambda (emit)
    (let ([job #f])
      (lambda (prefix)
        (cond
          [(eof-object? prefix)
           (when job
             (jobs:stop! job)
             (set! job #f))]
          [else
           (unless job
             (set! job
               (as-module (this-module)
                 (jobs:start worker input emit
                   (lambda (how)
                     (set! job #f)
                     (emit 'done))))))
           (jobs:send! job prefix)])))))

(define (prefix query) (if (string=? query "") '() (list (list 'starts query))))

(define (substring query) (if (string=? query "") '() (list (list 'contains query))))

(define (partial query) (partial-pattern query))

(define (flex query)
  (if (string=? query "") '() (list (cons 'contains (map string (string->list query))))))

(define (components query)
  (unless (string? query)
    (assertion-violation 'completion:components "not a string" query))
  (let loop ([cs (string->list query)] [current '()] [acc '()])
    (define (finish) (if (null? current) acc (cons (list->string (reverse current)) acc)))
    (cond
      [(null? cs) (reverse (finish))]
      [(and (char=? (car cs) #\\) (pair? (cdr cs)) (char=? (cadr cs) #\space))
       (loop (cddr cs) (cons #\space current) acc)]
      [(char=? (car cs) #\space) (loop (cdr cs) '() (finish))]
      [else (loop (cdr cs) (cons (car cs) current) acc)])))

(define match-0 'completion.match-0)
(define match-1 'completion.match-1)
(define match-2 'completion.match-2)
(define match-3 'completion.match-3)

(define-option any-order-faces (list match-0 match-1 match-2 match-3) (lambda (v) (and (list? v) (for-all symbol? v)))
  "The faces completion:any-order draws its components' matches in, in turn; with none, as other styles' matches.")

(define (%component-term component)
  (let* ([n (string-length component)]
         [at-start (table-ref any-order-dispatch (string-ref component 0) #f)]
         [at-end (and (fx> n 1) (table-ref any-order-dispatch (string-ref component (fx- n 1)) #f))])
    (cond
      [(and at-start (fx> n 1)) (at-start (string-part component 1 n))]
      [at-end (at-end (string-part component 0 (fx- n 1)))]
      [at-start #f]
      [else (list 'contains component)])))

;; A negated component matches nothing to draw, so it takes no face and
;; the next component takes the face it would have had, as in Orderless.
(define (any-order query)
  (let ([faces (any-order-faces)])
    (let loop ([cs (components query)] [k 0] [terms '()])
      (if (null? cs)
          (reverse terms)
          (let ([t (%component-term (car cs))])
            (cond
              [(not t) (loop (cdr cs) k terms)]
              [(or (null? faces) (eq? (car t) 'not)) (loop (cdr cs) k (cons t terms))]
              [else (loop (cdr cs) (fx+ k 1)
                          (cons (list 'face (list-ref faces (fxmodulo k (length faces))) t) terms))]))))))

(define (%dispatch-not rest) (let ([t (%component-term rest)]) (and t (list 'not t))))
(define (%dispatch-literal rest) (list 'contains rest))
(define (%dispatch-starts rest) (list 'starts rest))
(define (%dispatch-flex rest) (cons 'contains (map string (string->list rest))))
(define (%dispatch-ends rest) (list 'ends rest))

(define-option styles (list prefix partial) (lambda (v) (and (list? v) (for-all procedure? v)))
  "The styles a source tries, in order.")

(define-record-type (%matcher make-matcher matcher?)
  (sealed #t)
  (fields match spans worker)
  (protocol
    (lambda (new)
      (lambda (match spans worker)
        (unless (procedure? match) (assertion-violation 'completion:make-matcher "not a procedure" match))
        (unless (procedure? spans) (assertion-violation 'completion:make-matcher "not a procedure" spans))
        (unless (jobs:worker? worker) (assertion-violation 'completion:make-matcher "not a worker" worker))
        (new match spans worker)))))

(jobs:define-worker (%match-worker input emit receive)
  (import (completion matcher))
  (serve emit receive))

;; A session's texts stay one vector while its candidates do, so the
;; store made for them, folded and sorted, is kept for the next key.
(define %stores (make-weak-eq-hashtable))

(define (%default-match pattern texts ranks)
  (let ([kept (eq-hashtable-ref %stores texts #f)])
    (store-matches
      (if (and kept (eq? (car kept) ranks))
          (cdr kept)
          (let ([s (make-store texts ranks)])
            (eq-hashtable-set! %stores texts (cons ranks s))
            s))
      pattern)))

(define (%default-spans pattern text) (pattern-spans pattern text))

(define default-matcher (make-matcher %default-match %default-spans %match-worker))

(define-option matcher default-matcher matcher?
  "The matcher sessions use.")

(define-option read-preselect 'first (lambda (v) (memq v '(first none)))
  "What a read selects when its matches change: first or none.")

(define-option point-preselect 'none (lambda (v) (memq v '(first none)))
  "What a session at point selects when its matches change: none or first.")

(define %inline-candidates 1000)
(define %inline-bytes 50000)

(module %internals
  (check-main-thread check-session session-record? make-session session-record-view session-record-ended?
   session-record-matches session-record-selected session-record-input session-record-input-set!
   session-record-bounds session-record-prompt candidate-match?
   session-record-states session-categories-of session-record-accept session-record-default sessions open-session! start-session!
   end-session! input-of rematch! select-match! match-text match-whole-text match-value match-title match-category
   match-spans match-annotation
   busy? query-start find-named! sole-match? common-whole-start
   match-list? make-match-list match-list-count match-list-ref match-list-index no-matches)

  (define main-thread (get-thread-id))

  (define (check-main-thread who)
    (unless (fx= (get-thread-id) main-thread)
      (assertion-violation who "not on the main thread")))

  (define-record-type (session-record make-session session-record?)
    (sealed #t)
    (fields view (mutable states) width bounds accept preselect history default prompt
            (mutable input) (mutable matches) (mutable selected) (mutable locked?) (mutable ended?)
            (mutable inline?) (mutable annotators) (mutable next-id) history-ranks (mutable dirty?)
            (mutable finding)))

  ;; A source's candidates are numbered on through those it dropped, and
  ;; a match interleaves the numbers of a session's sources, so a match
  ;; names one candidate until its source drops it and is never used again.
  ;;
  ;; A stream may bring millions of candidates, so while its pattern holds
  ;; and its job keeps them in arrival order, a match asks only for those
  ;; past matched-to and adds what it finds to the end of the same matches.
  (define-record-type state
    (sealed #t)
    (fields source styles index (mutable dropped) (mutable count) (mutable texts) (mutable vals) (mutable ranks)
            (mutable annotations) (mutable prefix) (mutable receiver) (mutable match-job) (mutable job-dropped)
            (mutable sorted?) (mutable pending) (mutable done?) (mutable matches) (mutable pending-kept) (mutable matched-to)
            (mutable pending-end) (mutable matches-id) (mutable pattern) (mutable style) (mutable query)
            (mutable base) (mutable more?) (mutable prefers-input?)))

  (define-record-type match-list
    (sealed #t)
    (fields (mutable vector) (mutable count)))

  (define no-matches (make-match-list (vector) 0))

  (define (match-list-ref ms k) (vector-ref (match-list-vector ms) k))

  (define (match-list-index ms m)
    (let ([v (match-list-vector ms)] [n (match-list-count ms)])
      (let loop ([i 0])
        (and (fx< i n) (if (eqv? (vector-ref v i) m) i (loop (fx+ i 1)))))))

  ;; A match list made afresh takes a matcher's vector as it is when its
  ;; numbers are the matches, rather than copying it.
  (define (match-list-add! ms numbers dropped width index)
    (let ([n (match-list-count ms)] [k (vector-length numbers)])
      (cond
        [(fx= k 0)]
        [(and (fx= n 0) (fx= dropped 0) (fx= width 1)) (match-list-vector-set! ms numbers)]
        [else
         (let ([v (grow (match-list-vector ms) (fx+ n k -1) 0)])
           (do ([i 0 (fx+ i 1)]) ((fx= i k))
             (vector-set! v (fx+ n i) (fx+ (fx* (fx+ dropped (vector-ref numbers i)) width) index)))
           (match-list-vector-set! ms v))])
      (match-list-count-set! ms (fx+ n k))))

  (define (numbers->match-list s st dropped numbers)
    (let ([ms (make-match-list (vector) 0)])
      (match-list-add! ms numbers dropped (session-record-width s) (state-index st))
      ms))

  (define (check-session who s)
    (unless (session-record? s)
      (assertion-violation who "not a session" s)))

  (define sessions '())

  (define (grow v n fill)
    (if (fx> (vector-length v) n)
        v
        (let ([w (make-vector (fxmax 16 (fx+ n 1) (fx* 2 (vector-length v))) fill)])
          (do ([i 0 (fx+ i 1)]) ((fx= i (vector-length v)) w)
            (vector-set! w i (vector-ref v i))))))

  (define (candidate-text c) (if (string? c) c (car c)))
  (define (candidate-value c) (if (string? c) c (cdr c)))

  (define (styles-for source)
    (let* ([c (%source-category source)]
           [chosen (append (or (%source-styles source) '()) (if c (table-ref category-styles c '()) '()))]
           [defaults (or (and c (equal? (styles) (option-default styles)) (table-ref category-default-styles c #f))
                         (styles))])
      (let loop ([all (append chosen defaults)] [kept '()])
        (cond
          [(null? all) (reverse kept)]
          [(memq (car all) kept) (loop (cdr all) kept)]
          [else (loop (cdr all) (cons (car all) kept))]))))

  (define (history-ranks h default)
    (let ([t (make-hashtable string-hash string=?)] [entries (if h (h) '())])
      (let loop ([es entries] [k 1])
        (unless (null? es)
          (unless (hashtable-contains? t (car es)) (hashtable-set! t (car es) k))
          (loop (cdr es) (fx+ k 1))))
      (when default (hashtable-set! t default 0))
      (cons t (fx+ (length entries) 1))))

  (define (ranker s st given)
    (let* ([source (state-source st)] [default (session-record-default s)] [prefix (lead st)]
           [base (state-count st)] [hr (session-record-history-ranks s)]
           [rank (cond
                   [given (lambda (local text) (vector-ref given local))]
                   [(%source-rank source) (let ([r (%source-rank source)]) (lambda (local text) (vector-ref r local)))]
                   [(%source-in-order? source) (lambda (local text) (fx+ base local))]
                   [(fx= (hashtable-size (car hr)) 0) (lambda (local text) 0)]
                   [else (lambda (local text) (hashtable-ref (car hr) (string-append prefix text) (cdr hr)))])])
      (if default
          (lambda (local text)
            (if (string=? (string-append prefix text) default) (- (greatest-fixnum)) (rank local text)))
          rank)))

  (define (add-candidates! s st cands given)
    (let* ([k (vector-length cands)] [texts (make-vector k)] [vals (make-vector k)] [ranks (make-vector k)]
           [base (state-count st)] [rank-of (ranker s st given)])
      (do ([i 0 (fx+ i 1)]) ((fx= i k))
        (let* ([c (vector-ref cands i)] [text (candidate-text c)])
          (vector-set! texts i (string->utf8 text))
          (vector-set! vals i (candidate-value c))
          (vector-set! ranks i (rank-of i text))))
      (state-count-set! st (fx+ base k))
      (if (fx= base 0)
          (begin (state-texts-set! st texts) (state-vals-set! st vals) (state-ranks-set! st ranks))
          (begin
            (state-texts-set! st (append-at (state-texts st) base texts #vu8()))
            (state-vals-set! st (append-at (state-vals st) base vals #f))
            (state-ranks-set! st (append-at (state-ranks st) base ranks 0))))
      (let ([job (state-match-job st)])
        (when job (jobs:send! job (list 'add (jobs:freeze texts) ranks))))))

  ;; A streamed source may emit thousands of times, a few candidates
  ;; each, so its texts and ranks grow by doubling, not by a copy per
  ;; emission; only the first state-count entries are candidates.
  (define (append-at v n w fill)
    (let ([v (grow v (fx+ n (vector-length w)) fill)])
      (vector-copy! w 0 v n (vector-length w))
      v))

  (define (trim-candidates! st)
    (let ([n (state-count st)])
      (unless (fx= (vector-length (state-texts st)) n)
        (state-texts-set! st (vector-copy (state-texts st) 0 n))
        (state-ranks-set! st (vector-copy (state-ranks st) 0 n)))))

  (define (check-candidates who v)
    (unless (%candidates? v)
      (assertion-violation who "not a vector of candidates" v)))

  (define (input-of s)
    (let-values ([(start end) ((session-record-bounds s))])
      (document:text (buffers:document (views:buffer (session-record-view s))) start end)))

  (define (prefix-length st input)
    (let ([split (%source-split (state-source st))])
      (if split
          (let ([n (split input)])
            (unless (and (fixnum? n) (fx<= 0 n (string-length input)))
              (assertion-violation 'completion:source "a split returned what is not a length of the input" n))
            n)
          0)))

  (define (state-prefix-length st) (string-length (or (state-prefix st) "")))

  (define (lead-length st)
    (let ([p (state-prefix-length st)] [b (state-base st)])
      (if b (fxmin b p) p)))

  (define (lead st) (string-part (or (state-prefix st) "") 0 (lead-length st)))

  (define (update-query! s st)
    (let ([input (or (session-record-input s) "")])
      (state-query-set! st (string-part input (fxmin (string-length input) (lead-length st)) (string-length input)))))

  (define (match-job-of s st)
    (or (state-match-job st)
        (let ([job (as-module (this-module)
                     (jobs:start (%matcher-worker (matcher)) #f
                       (lambda (result) (match-arrived! s st result))))])
          (state-match-job-set! st job)
          (state-job-dropped-set! st (state-dropped st))
          (state-sorted?-set! st #f)
          (trim-candidates! st)
          (unless (fx= (state-count st) 0)
            (jobs:send! job (list 'add (jobs:freeze (state-texts st)) (state-ranks st))))
          (when (state-done? st) (send-sort! st))
          job)))

  (define (send-sort! st)
    (jobs:send! (state-match-job st) '(sort))
    (state-sorted?-set! st #t)
    (state-matched-to-set! st #f)
    (state-pending-end-set! st #f))

  (define (stop-match-job! st)
    (let ([job (state-match-job st)])
      (when job
        (jobs:stop! job)
        (state-match-job-set! st #f)
        (state-pending-set! st #f)
        (state-matched-to-set! st #f)
        (state-more?-set! st #f))))

  ;; The match job stays, told to drop what it holds, so its numbers go
  ;; on counting with the state's.
  (define (drop-candidates! s st)
    (let ([job (state-match-job st)])
      (when job
        (jobs:send! job '(clear))
        (state-sorted?-set! st #f)
        (state-pending-set! st #f)
        (state-matched-to-set! st #f)
        (state-more?-set! st #f)))
    (state-dropped-set! st (fx+ (state-dropped st) (state-count st)))
    (state-count-set! st 0)
    (state-texts-set! st (vector))
    (state-vals-set! st (vector))
    (state-ranks-set! st (vector))
    (state-annotations-set! st (make-eqv-hashtable))
    (set-state-matches! s st (make-match-list (vector) 0)))

  (define (refresh-candidates! s st prefix)
    (drop-candidates! s st)
    (let ([v ((%source-candidates (state-source st)) prefix)])
      (check-candidates 'completion:source v)
      (add-candidates! s st v #f)))

  ;; A stream counts once it has said done: until then more may come.
  (define (small-enough? s)
    (let loop ([sts (session-record-states s)] [n 0] [size 0])
      (or (null? sts)
          (let ([st (car sts)])
            (and (or (state-done? st) (not (%source-stream (state-source st))))
                 (let* ([texts (state-texts st)] [k (state-count st)] [n (fx+ n k)])
                   (and (fx<= n %inline-candidates)
                        (let ([size (let sum ([i 0] [b size])
                                      (if (fx= i k) b (sum (fx+ i 1) (fx+ b (bytevector-length (vector-ref texts i))))))])
                          (and (fx<= size %inline-bytes)
                               (loop (cdr sts) n size))))))))))

  (define (decide-inline! s)
    (session-record-inline?-set! s (small-enough? s))
    (if (session-record-inline? s)
        (for-each stop-match-job! (session-record-states s))
        (for-each (lambda (st) (match-job-of s st)) (session-record-states s))))

  (define (match-state! s st)
    (if (session-record-inline? s) (match-inline! s st) (request-match! s st)))

  (define (check-pattern style pattern)
    (unless (pattern? pattern)
      (assertion-violation 'completion:styles "a style returned what is not a pattern" style pattern))
    pattern)

  (define (pattern-of st k)
    (let ([style (list-ref (state-styles st) k)])
      (check-pattern style (style (state-query st)))))

  (define (match-inline! s st)
    (trim-candidates! st)
    (let ([match (%matcher-match (matcher))] [n (length (state-styles st))])
      (let loop ([k 0])
        (let* ([pattern (pattern-of st k)]
               [locals (match pattern (state-texts st) (state-ranks st))])
          (if (and (fx= (vector-length locals) 0) (fx< (fx+ k 1) n))
              (loop (fx+ k 1))
              (begin
                (state-pattern-set! st pattern)
                (set-state-matches! s st (numbers->match-list s st (state-dropped st) locals))))))))

  (define (send-match! s st k)
    (let* ([id (session-record-next-id s)] [pattern (pattern-of st k)] [job (match-job-of s st)]
           [from (and (not (state-sorted? st)) (equal? pattern (state-pattern st)) (state-matched-to st))])
      (session-record-next-id-set! s (fx+ id 1))
      (state-style-set! st k)
      (state-pending-set! st id)
      (state-more?-set! st #f)
      (state-pattern-set! st pattern)
      (state-pending-kept-set! st (if from (match-list-count (state-matches st)) 0))
      (state-matched-to-set! st #f)
      (state-pending-end-set! st (fx- (fx+ (state-dropped st) (state-count st)) (state-job-dropped st)))
      (jobs:send! job (list 'match id pattern (or from 0)))))

  ;; A first part of a match's results is the start of the whole, so the
  ;; whole adds to the matches that took the part.
  (define (take-matches! s st id numbers)
    (let* ([kept (state-pending-kept st)]
           [ms (if (or (fx> kept 0) (eqv? id (state-matches-id st))) (state-matches st) (make-match-list (vector) 0))])
      (match-list-count-set! ms kept)
      (match-list-add! ms numbers (state-job-dropped st) (session-record-width s) (state-index st))
      (state-matches-id-set! st id)
      (set-state-matches! s st ms)))

  (define (matches-arrived! s st id done? numbers)
    (when (eqv? id (state-pending st))
      (when done? (state-matched-to-set! st (state-pending-end st)))
      (cond
        [(and done? (state-more? st))
         (take-matches! s st id numbers)
         (send-match! s st 0)
         (combine! s)]
        [(and done? (fx= (fx+ (state-pending-kept st) (vector-length numbers)) 0)
              (fx< (fx+ (state-style st) 1) (length (state-styles st))))
         (send-match! s st (fx+ (state-style st) 1))]
        [else
         (when done? (state-pending-set! st #f))
         (take-matches! s st id numbers)
         (combine! s)])))

  (define (match-arrived! s st result)
    (cond
      [(session-record-ended? s)]
      [(eq? (car result) 'found) (found-arrived! s st (cadr result) (caddr result))]
      [else (matches-arrived! s st (car result) (cadr result) (cddr result))]))

  ;; A streamed source may emit thousands of times; candidates that come
  ;; while a match is under way wait for its end, so matching keeps pace
  ;; with the matcher, not with the emissions.
  (define (request-match! s st)
    (if (state-pending st)
        (state-more?-set! st #t)
        (send-match! s st 0)))

  (define (take-emission! s st v)
    (cond
      [(and (pair? v) (eq? (car v) 'base))
       (unless (and (pair? (cdr v)) (fixnum? (cadr v)) (fx>= (cadr v) 0))
         (assertion-violation 'completion:source "a source emitted a base that is not a length" v))
       (state-base-set! st (cadr v))
       (update-query! s st)]
      [(eq? v 'done)
       (state-done?-set! st #t)
       (when (state-match-job st) (send-sort! st))]
      [(eq? v 'clear)
       (state-done?-set! st #f)
       (state-prefers-input?-set! st #f)
       (state-base-set! st #f)
       (update-query! s st)
       (drop-candidates! s st)]
      [else
       (let-values ([(cands given) (if (pair? v) (values (car v) (cdr v)) (values v #f))])
         (check-candidates 'completion:source cands)
         (unless (session-record-inline? s) (match-job-of s st))
         (add-candidates! s st cands given))]))

  ;; A stream that has said done and holds few candidates is matched on
  ;; the main thread like a vector, so a small source that only a job can
  ;; make, such as a buffer's lines, shows each key's matches with the key.
  (define (candidates-arrived! s st v)
    (unless (session-record-ended? s)
      (if (eq? v 'prefer-input)
          (state-prefers-input?-set! st #t)
          (let ([was (session-record-inline? s)])
            (take-emission! s st v)
            (when (or was (memq v '(done clear))) (decide-inline! s))
            (if (eq? was (session-record-inline? s))
                (match-state! s st)
                (for-each (lambda (st) (match-state! s st)) (session-record-states s)))
            (when (session-record-dirty? s) (combine! s))
            ;; Moving to the main thread stopped the match jobs, which
            ;; answer no finding still queued for them.
            (let ([f (session-record-finding s)])
              (when (and f (session-record-inline? s))
                (answer-finding! s f (named-match s (finding-text f)))))))))

  (define (start-stream! s st)
    (let ([receiver ((%source-stream (state-source st))
                     (lambda (v)
                       (check-main-thread 'completion:source)
                       (candidates-arrived! s st v)))])
      (unless (procedure? receiver)
        (assertion-violation 'completion:source "a stream returned what is not a receiver" receiver))
      (state-receiver-set! st receiver)))

  (define (rematch! s force?)
    (let ([input (input-of s)])
      (unless (and (not force?) (equal? input (session-record-input s)))
        (let ([changed? (not (equal? input (session-record-input s)))] [refreshed? #f])
          (session-record-input-set! s input)
          (when changed? (session-record-locked?-set! s #f))
          ;; Matches from a job lag the input, so a key such as RET pressed
          ;; before they come must not choose a candidate of an older input.
          (when (and changed? (not (session-record-inline? s)) (session-record-matches s))
            (set-selected! s #f))
          (for-each
            (lambda (st)
              (let* ([n (prefix-length st input)] [prefix (string-part input 0 n)]
                     [new-prefix? (not (equal? prefix (state-prefix st)))] [source (state-source st)])
                (when new-prefix? (state-prefix-set! st prefix))
                (update-query! s st)
                (when new-prefix?
                  (cond
                    [(%source-stream source)
                     (state-done?-set! st #f)
                     (set! refreshed? #t)
                     (unless (state-receiver st) (start-stream! s st))
                     ((state-receiver st) prefix)]
                    [(procedure? (%source-candidates source))
                     (refresh-candidates! s st prefix)
                     (set! refreshed? #t)]))))
            (session-record-states s))
          (when (or refreshed? (not (session-record-matches s))) (decide-inline! s))
          (for-each
            (lambda (st) (if (session-record-inline? s) (match-inline! s st) (send-match! s st 0)))
            (session-record-states s))
          (combine! s)))))

  (define (preview! st v)
    (let ([preview (%source-preview (state-source st))])
      (when preview (preview v))))

  (define (owner-of s m)
    (and m (list-ref (session-record-states s) (fxremainder m (session-record-width s)))))

  (define (local-of s st m) (fx- (fxquotient m (session-record-width s)) (state-dropped st)))

  (define (match-of s st local)
    (fx+ (fx* (fx+ (state-dropped st) local) (session-record-width s)) (state-index st)))

  (define (candidate-match? s m)
    (and (fx> (session-record-width s) 0)
         (let ([st (owner-of s m)])
           (fx< -1 (local-of s st m) (state-count st)))))

  (define (set-selected! s m)
    (let ([old (session-record-selected s)])
      (unless (eqv? old m)
        (session-record-selected-set! s m)
        (let ([was (owner-of s old)] [now (owner-of s m)])
          (when (and was (not (eq? was now))) (preview! was #f))
          (when now (preview! now (match-value s m)))))))

  (define (prefers-input? s)
    (exists (lambda (st) (and (state-prefers-input? st) (string=? (state-query st) "")))
            (session-record-states s)))

  ;; Only new matches set the session's matches and select again, so a
  ;; selection cleared while a job matches stays clear until they come.
  (define (combine! s)
    (when (session-record-dirty? s)
      (session-record-dirty?-set! s #f)
      (let ([matches (let ([sts (session-record-states s)])
                       (if (and (pair? sts) (null? (cdr sts)))
                           (state-matches (car sts))
                           (let* ([n (fold-left (lambda (n st) (fx+ n (match-list-count (state-matches st)))) 0 sts)]
                                  [v (make-vector n)])
                             (fold-left (lambda (at st)
                                          (let ([m (state-matches st)])
                                            (vector-copy! (match-list-vector m) 0 v at (match-list-count m))
                                            (fx+ at (match-list-count m))))
                                        0 sts)
                             (make-match-list v n))))])
        (session-record-matches-set! s matches)
        (let ([sel (session-record-selected s)])
          (unless (and sel (session-record-locked? s) (match-list-index matches sel))
            (session-record-locked?-set! s #f)
            (set-selected! s (and (eq? (session-record-preselect s) 'first) (fx> (match-list-count matches) 0)
                                  (not (prefers-input? s))
                                  (match-list-ref matches 0)))))))
    (updated s))

  (define (set-state-matches! s st matches)
    (state-matches-set! st matches)
    (session-record-dirty?-set! s #t))

  (define (select-match! s m)
    (set-selected! s m)
    (session-record-locked?-set! s #t)
    (updated s))

  (define (open-session! view sources bounds accept preselect h default prompt)
    (let ([s (make-session view '() (length sources) bounds accept preselect h default prompt
                           #f #f #f #f #f #t '() 0 (history-ranks h default) #t #f)])
      (session-record-states-set! s
        (let loop ([sources sources] [index 0])
          (if (null? sources)
              '()
              (cons (make-state (car sources) (styles-for (car sources)) index 0 0 (vector) (vector) (vector)
                                (make-eqv-hashtable) #f #f #f 0 #f #f #t (make-match-list (vector) 0) 0 #f #f #f
                                '() 0 "" #f #f #f)
                    (loop (cdr sources) (fx+ index 1))))))
      (for-each
        (lambda (st)
          (let ([c (%source-candidates (state-source st))])
            (when (vector? c) (add-candidates! s st c #f))))
        (session-record-states s))
      (set! sessions (cons s sessions))
      (session-record-annotators-set! s
        (fold-left
          (lambda (acc st)
            (let ([c (%source-category (state-source st))])
              (if (or (not c) (assq c acc))
                  acc
                  (let ([make (table-ref annotators c #f)])
                    (if make
                        (cons (cons c (guard (e [(not (quit-condition? e)) (report e) #f]) (make s))) acc)
                        acc)))))
          '()
          (session-record-states s)))
      (started s)
      s))

  (define (start-session! view sources bounds accept preselect)
    (let ([s (open-session! view sources bounds accept preselect #f #f #f)])
      ;; The caller gets no session to end when the start raises, such as
      ;; when a source's procedure fails.
      (guard (e [#t (end-session! s) (raise e)])
        (rematch! s #t))
      s))

  (define (end-session! s)
    (unless (session-record-ended? s)
      (session-record-ended?-set! s #t)
      (set! sessions (remq s sessions))
      (for-each
        (lambda (st)
          (stop-match-job! st)
          (let ([receiver (state-receiver st)])
            (when receiver
              (state-receiver-set! st #f)
              (guard (e [(not (quit-condition? e)) (report e)]) (receiver (eof-object))))))
        (session-record-states s))
      (for-each (lambda (st) (preview! st #f)) (session-record-states s))
      (ended s)))

  ;; A session holds its texts as UTF-8: a broad search holds millions of
  ;; them, and a string takes four bytes a character.
  (define (match-bytes s m) (let ([st (owner-of s m)]) (vector-ref (state-texts st) (local-of s st m))))
  (define (match-text s m) (utf8->string (match-bytes s m)))
  (define (match-value s m) (let ([st (owner-of s m)]) (vector-ref (state-vals st) (local-of s st m))))
  (define (match-title s m) (%source-title (state-source (owner-of s m))))
  (define (match-category s m) (%source-category (state-source (owner-of s m))))
  (define (session-categories-of s) (map (lambda (st) (%source-category (state-source st))) (session-record-states s)))
  (define (match-whole-text s m) (string-append (lead (owner-of s m)) (match-text s m)))

  (define (match-spans s m)
    (let ([st (owner-of s m)])
      ((%matcher-spans (matcher)) (state-pattern st) (match-text s m))))

  (define (match-annotation s m)
    (let* ([st (owner-of s m)] [cache (state-annotations st)])
      (or (hashtable-ref cache m #f)
          (let* ([c (%source-category (state-source st))]
                 [a (and c (assq c (session-record-annotators s)))]
                 [columns (if (and a (cdr a))
                              (guard (e [(not (quit-condition? e)) (report e) '()])
                                ((cdr a) (match-value s m)))
                              '())])
            (hashtable-set! cache m columns)
            columns))))

  (define (busy? s)
    (exists (lambda (st) (not (and (state-done? st) (not (state-pending st))))) (session-record-states s)))

  (define (same-chars? a a-start b b-start count)
    (let loop ([i 0])
      (or (fx= i count)
          (and (char=? (string-ref a (fx+ a-start i)) (string-ref b (fx+ b-start i)))
               (loop (fx+ i 1))))))

  (define (query-start s m)
    (let-values ([(start end) ((session-record-bounds s))])
      (fx+ start (lead-length (owner-of s m)))))

  (define (named-match s text)
    (let ([n (string-length text)])
      (exists
        (lambda (st)
          (let ([k (lead-length st)])
            (and (fx<= k n)
                 (same-chars? (state-prefix st) 0 text 0 k)
                 (let ([texts (state-texts st)] [query (string->utf8 (string-part text k n))])
                   (let loop ([i 0])
                     (and (fx< i (state-count st))
                          (if (bytevector=? (vector-ref texts i) query)
                              (match-of s st i)
                              (loop (fx+ i 1)))))))))
        (session-record-states s))))

  (define-record-type finding
    (sealed #t)
    (fields id input text answers k))

  ;; A job's source may hold millions of candidates, too many to compare
  ;; on the main thread when RET names one, so each source's match job
  ;; looks for it and the answer comes as matches do. It is given only if
  ;; the input is still the one RET was pressed on.
  (define (find-named! s text k)
    (if (session-record-inline? s)
        (k (named-match s text))
        (let* ([id (session-record-next-id s)] [sts (session-record-states s)] [n (string-length text)]
               [f (make-finding id (session-record-input s) text (make-vector (length sts) 'waiting) k)])
          (session-record-next-id-set! s (fx+ id 1))
          (session-record-finding-set! s f)
          (for-each
            (lambda (st)
              (let ([lead (lead-length st)])
                (if (and (fx<= lead n) (same-chars? (state-prefix st) 0 text 0 lead) (fx> (state-count st) 0))
                    (jobs:send! (match-job-of s st) (list 'find id (string->utf8 (string-part text lead n))))
                    (vector-set! (finding-answers f) (state-index st) #f))))
            sts)
          (finish-finding! s f))))

  (define (found-arrived! s st id number)
    (let ([f (session-record-finding s)])
      (when (and f (eqv? id (finding-id f)))
        (vector-set! (finding-answers f) (state-index st)
          (and number
               (let ([m (fx+ (fx* (fx+ (state-job-dropped st) number) (session-record-width s)) (state-index st))])
                 (and (candidate-match? s m) m))))
        (finish-finding! s f))))

  (define (finish-finding! s f)
    (let ([answers (vector->list (finding-answers f))])
      (unless (memq 'waiting answers)
        (answer-finding! s f (find (lambda (a) a) answers)))))

  (define (answer-finding! s f named)
    (session-record-finding-set! s #f)
    (when (equal? (finding-input f) (session-record-input s))
      ((finding-k f) named)))

  (define (sole-match? s)
    (let ([matches (session-record-matches s)] [input (session-record-input s)])
      (and matches (fx= (match-list-count matches) 1)
           (let* ([m (match-list-ref matches 0)] [st (owner-of s m)] [text (match-text s m)] [k (lead-length st)])
             (and (fx= (string-length input) (fx+ k (string-length text)))
                  (same-chars? input k text 0 (string-length text)))))))

  ;; A candidate's whole text is its source's lead and then its text, as
  ;; the input holds it once the candidate is chosen. TAB with nothing
  ;; selected may compare every match, millions in a broad search, so the
  ;; whole texts are read in place, as UTF-8, and the scan ends once their
  ;; common start can no longer pass the input.
  (define (common-whole-start s input)
    (let* ([matches (or (session-record-matches s) no-matches)] [count (match-list-count matches)]
           [leads (map (lambda (st) (string->utf8 (lead st))) (session-record-states s))]
           [shortest (string-length input)])
      (define (lead-of st) (list-ref leads (state-index st)))
      (define (whole-length st text) (fx+ (bytevector-length (lead-of st)) (bytevector-length text)))
      (define (whole-ref st text i)
        (let* ([lead (lead-of st)] [n (bytevector-length lead)])
          (if (fx< i n) (bytevector-u8-ref lead i) (bytevector-u8-ref text (fx- i n)))))
      (define (continuation? b) (fx= (fxand b #xC0) #x80))
      (and (fx> count 0)
           (let* ([m0 (match-list-ref matches 0)] [st0 (owner-of s m0)] [t0 (match-bytes s m0)]
                  [total (whole-length st0 t0)])
             (let loop ([i 1] [n total])
               (cond
                 [(fx<= n shortest) #f]
                 [(fx= i count)
                  (let* ([n (let back ([n n])
                              (if (and (fx< n total) (continuation? (whole-ref st0 t0 n))) (back (fx- n 1)) n))]
                         [common (make-bytevector n)])
                    (do ([k 0 (fx+ k 1)]) ((fx= k n))
                      (bytevector-u8-set! common k (whole-ref st0 t0 k)))
                    (let ([c (utf8->string common)]) (and (fx> (string-length c) shortest) c)))]
                 [else
                  (let* ([m (match-list-ref matches i)] [st (owner-of s m)] [t (match-bytes s m)]
                         [limit (fxmin n (whole-length st t))])
                    (loop (fx+ i 1)
                          (let scan ([k 0])
                            (if (and (fx< k limit) (fx= (whole-ref st0 t0 k) (whole-ref st t k)))
                                (scan (fx+ k 1))
                                k))))])))))))

(import %internals)

(define (%check-sources who sources)
  (unless (and (list? sources) (for-all source? sources))
    (assertion-violation who "not a list of sources" sources)))

(define (start view sources bounds accept preselect)
  (check-main-thread 'completion:start)
  (unless (views:view? view)
    (assertion-violation 'completion:start "not a view" view))
  (%check-sources 'completion:start sources)
  (unless (procedure? bounds)
    (assertion-violation 'completion:start "not a procedure" bounds))
  (unless (procedure? accept)
    (assertion-violation 'completion:start "not a procedure" accept))
  (unless (memq preselect '(first none))
    (assertion-violation 'completion:start "neither first nor none" preselect))
  (start-session! view sources bounds accept preselect))

(define (session? v) (session-record? v))

(define (input-changed! s)
  (check-session 'completion:input-changed! s)
  (check-main-thread 'completion:input-changed!)
  (unless (session-record-ended? s) (rematch! s #f)))

(define (end! s)
  (check-session 'completion:end! s)
  (check-main-thread 'completion:end!)
  (end-session! s))

(define (current-session)
  (check-main-thread 'completion:current-session)
  (let ([v (views:current)])
    (and v (find (lambda (s) (eq? (session-record-view s) v)) sessions))))

(define (session-view s)
  (check-session 'completion:session-view s)
  (session-record-view s))

(define (session-prompt s)
  (check-session 'completion:session-prompt s)
  (session-record-prompt s))

(define (session-start s)
  (check-session 'completion:session-start s)
  (let-values ([(start end) ((session-record-bounds s))]) start))

(define (session-input s)
  (check-session 'completion:session-input s)
  (or (session-record-input s) ""))

(define (session-categories s)
  (check-session 'completion:session-categories s)
  (session-categories-of s))

(define (session-default s)
  (check-session 'completion:session-default s)
  (session-record-default s))

(define (session-matches s)
  (check-session 'completion:session-matches s)
  (or (session-record-matches s) no-matches))

(define (matches? v) (match-list? v))

(define (matches-count ms)
  (unless (match-list? ms)
    (assertion-violation 'completion:matches-count "not matches" ms))
  (match-list-count ms))

(define (matches-index ms m)
  (unless (match-list? ms)
    (assertion-violation 'completion:matches-index "not matches" ms))
  (match-list-index ms m))

(define (matches-ref ms k)
  (unless (match-list? ms)
    (assertion-violation 'completion:matches-ref "not matches" ms))
  (unless (and (fixnum? k) (fx< -1 k (match-list-count ms)))
    (assertion-violation 'completion:matches-ref "not a place in the matches" k))
  (match-list-ref ms k))

(define (session-busy? s)
  (check-session 'completion:session-busy? s)
  (and (not (session-record-ended? s)) (busy? s)))

(define (%check-match who s m)
  (check-session who s)
  (unless (and (fixnum? m) (fx>= m 0) (candidate-match? s m))
    (assertion-violation who "not a match of the session" m)))

(define (text s m) (%check-match 'completion:text s m) (match-text s m))

(define (value s m) (%check-match 'completion:value s m) (match-value s m))

(define (title s m) (%check-match 'completion:title s m) (match-title s m))

(define (category s m) (%check-match 'completion:category s m) (match-category s m))

(define (whole-text s m) (%check-match 'completion:whole-text s m) (match-whole-text s m))

(define (spans s m) (%check-match 'completion:spans s m) (match-spans s m))

(define (annotation s m) (%check-match 'completion:annotation s m) (match-annotation s m))

(define (selected s)
  (check-session 'completion:selected s)
  (session-record-selected s))

(define (select! s m)
  (check-session 'completion:select! s)
  (check-main-thread 'completion:select!)
  (unless (or (not m) (and (fixnum? m) (match-list-index (session-matches s) m)))
    (assertion-violation 'completion:select! "not one of the matches" m))
  (select-match! s m))

(define-record-type %read-state
  (sealed #t)
  (fields session prompt task any?))

(define %reads '())

(define (%read-of s) (find (lambda (r) (eq? (%read-state-session r) s)) %reads))

(define (%read-of-prompt p) (find (lambda (r) (eq? (%read-state-prompt r) p)) %reads))

(define (%answer-input! r input)
  (let ([s (%read-state-session r)] [prompt (%read-state-prompt r)])
    (find-named! s input
      (lambda (named)
        (cond
          [named (minibuffer:exit! prompt (match-value s named))]
          [(%read-state-any? r) (minibuffer:exit! prompt input)]
          [else (minibuffer:message! prompt "No match")])))))

(define (answer-input! p)
  (unless (minibuffer:prompt? p)
    (assertion-violation 'completion:answer-input! "not a prompt" p))
  (check-main-thread 'completion:answer-input!)
  (let ([r (%read-of-prompt p)] [input (minibuffer:input p)])
    (if r (%answer-input! r input) (minibuffer:exit! p input))))

(define (%answer! s m)
  (let* ([r (%read-of s)] [prompt (%read-state-prompt r)] [input (minibuffer:input prompt)]
         [default (and (string=? input "") (%read-default r))])
    (cond
      [m (minibuffer:exit! prompt (match-value s m))]
      [default
       (find-named! s default
         (lambda (named) (minibuffer:exit! prompt (if named (match-value s named) default))))]
      [else (%answer-input! r input)])))

(define (%read-default r) (session-record-default (%read-state-session r)))

(define (%read who question sources h default any?)
  (unless (string? question)
    (assertion-violation who "not a string" question))
  (%check-sources who sources)
  (unless (or (not h) (saved? h))
    (assertion-violation who "neither saved data nor #f" h))
  (unless (or (not default) (string? default))
    (assertion-violation who "neither a string nor #f" default))
  (let ([task (current-task)])
    (minibuffer:call-with-setup
      (lambda (prompt)
        (minibuffer:add-keymap! prompt keymap)
        (let ([s (open-session! (minibuffer:prompt-view prompt) sources
                   (lambda () (values (minibuffer:input-start prompt) (minibuffer:input-end prompt)))
                   %answer! (read-preselect) h default prompt)])
          (set! %reads (cons (make-%read-state s prompt task any?) %reads))))
      (lambda () (minibuffer:read question h default)))))

(define read
  (case-lambda
    [(question sources) (read question sources minibuffer:history #f)]
    [(question sources h) (read question sources h #f)]
    [(question sources h default) (%read 'completion:read question sources h default #f)]))

(define read-or-input
  (case-lambda
    [(question sources) (read-or-input question sources minibuffer:history #f)]
    [(question sources h) (read-or-input question sources h #f)]
    [(question sources h default) (%read 'completion:read-or-input question sources h default #t)]))

;; A read's session starts in its setup, the innermost, so its first
;; match waits for the input the outer setups give: the first change of
;; the input, or the prompt's start, whichever comes first.
(define (%prompt-input-changed p)
  (let ([r (%read-of-prompt p)])
    (when r (rematch! (%read-state-session r) #f))))

(define (%prompt-ended p)
  (let ([r (%read-of-prompt p)])
    (when r
      (set! %reads (remq r %reads))
      (end-session! (%read-state-session r)))))

(define-record-type (%region region %region?)
  (sealed #t)
  (fields (immutable start region-start) (immutable end region-end) (immutable sources region-sources))
  (protocol
    (lambda (new)
      (lambda (start end sources)
        (unless (and (fixnum? start) (fixnum? end) (fx<= 0 start end))
          (assertion-violation 'completion:region "not a start and an end" start end))
        (%check-sources 'completion:region sources)
        (new start end sources)))))

(define-record-type %point-state
  (sealed #t)
  (fields session entry client start end (mutable end-keymap) (mutable end-selected-keymap)))

(define %points '())

(define (%point-of s) (find (lambda (p) (eq? (%point-state-session p) s)) %points))

(define (%find-region)
  (let loop ([entries (hook-entries find-region)])
    (if (null? entries)
        (values #f #f)
        (let ([r ((car entries))])
          (cond
            [(not r) (loop (cdr entries))]
            [(%region? r) (values r (car entries))]
            [else (assertion-violation 'completion:find-region "an entry returned what is not a region or #f" r)])))))

(define (start-at-point minimum)
  (check-main-thread 'completion:start-at-point)
  (unless (and (fixnum? minimum) (fx>= minimum 0))
    (assertion-violation 'completion:start-at-point "not a count" minimum))
  (let ([view (views:current)] [client (web:current-client)])
    (and view client
         (let-values ([(r entry) (%find-region)])
           (and r
                (let ([point (views:point view)])
                  (and (fx<= (region-start r) point (region-end r))
                       (fx>= (fx- point (region-start r)) minimum)))
                (begin
                  (for-each (lambda (p) (when (eq? (session-record-view (%point-state-session p)) view)
                                          (end-session! (%point-state-session p))))
                            %points)
                  (as-module (this-module)
                    (let* ([b (views:buffer view)] [start (buffers:anchor b (region-start r))]
                           [end (buffers:anchor-after b (region-end r))]
                           [s (start-session! view (region-sources r)
                                (lambda () (values (buffers:anchor-position start) (buffers:anchor-position end)))
                                (lambda (s m) (end-session! s))
                                (point-preselect))]
                           [p (make-%point-state s entry client start end #f #f)])
                      (set! %points (cons p %points))
                      (%point-state-end-keymap-set! p
                        (keys:push-keymap! client region-keymap (lambda (found command) #t)
                                           (lambda () (end-session! s))))
                      (%sync-keymaps! s)
                      (when (session-record-ended? s) (%point-ended s))
                      #t))))))))

(define (%sync-keymaps! s)
  (let ([p (%point-of s)])
    (when (and p (not (session-record-ended? s)) (%point-state-end-keymap p))
      (let ([pushed (%point-state-end-selected-keymap p)])
        (cond
          [(and (session-record-selected s) (not pushed))
           (%point-state-end-selected-keymap-set! p
             (as-module (this-module)
               (keys:push-keymap! (%point-state-client p) region-selected-keymap (lambda (found command) #t))))]
          [(and (not (session-record-selected s)) pushed)
           (%point-state-end-selected-keymap-set! p #f)
           (pushed)])))))

(define (%point-ended s)
  (let ([p (%point-of s)])
    (when p
      (set! %points (remq p %points))
      (let ([a (%point-state-end-selected-keymap p)] [b (%point-state-end-keymap p)])
        (%point-state-end-selected-keymap-set! p #f)
        (%point-state-end-keymap-set! p #f)
        (when a (a))
        (when b (b))))))

;; Emacs's rule for completion in a region: the session goes on while the
;; entry that gave the region gives one with the same start, holding
;; point, in the same view and buffer. The view is the selected one, not
;; the current one, since a click on the popup runs in the popup's view.
(define (%continue-at-point command)
  (for-each
    (lambda (p)
      (let* ([s (%point-state-session p)] [view (session-record-view s)])
        (unless (session-record-ended? s)
          (let ([r (and (eq? (layout:selected-view) view)
                        (guard (c [(not (quit-condition? c)) (report c) #f])
                          (views:call-with-view view (%point-state-entry p))))])
            (if (and (%region? r)
                     (fx= (region-start r) (buffers:anchor-position (%point-state-start p)))
                     (fx<= (region-start r) (views:point view) (region-end r)))
                (begin
                  (buffers:set-anchor! (%point-state-end p) (region-end r))
                  (rematch! s #f)
                  (when (sole-match? s) (end-session! s)))
                (end-session! s))))))
    %points))

(commands:define-command (complete-at-point)
  "Completes the text at point from the sources of completion:find-region."
  (start-at-point 0))

(define (%current who)
  (or (current-session) (assertion-violation who "no completion session in the selected view")))

(define (%replace! s from text)
  (let-values ([(start end) ((session-record-bounds s))])
    (let ([b (views:buffer (session-record-view s))])
      (unless (string=? (document:text (buffers:document b) from end) text)
        (buffers:replace! b from end text)
        (views:set-point! (session-record-view s) (fx+ from (string-length text)))))))

;; The session takes the input the replacement makes before the edit, so
;; the edit is not matched: the match is being accepted, and a new prefix
;; would make a procedure source drop it and a stream start over.
(define (%replace-unmatched! s from text)
  (let-values ([(start end) ((session-record-bounds s))])
    (let ([input (input-of s)])
      (session-record-input-set! s (string-append (string-part input 0 (fxmin (fx- from start) (string-length input))) text))
      (%replace! s from text))))

(commands:define-command (exit)
  "Makes the query the selected match's text and accepts the match; with none selected, accepts none."
  (let* ([s (%current 'completion:exit)] [m (session-record-selected s)])
    (when m (%replace-unmatched! s (query-start s m) (match-text s m)))
    ((session-record-accept s) s m)))

(commands:define-command (exit-input)
  "Answers the innermost prompt with its input as typed, as completion:answer-input! does."
  (answer-input! (or (minibuffer:current-prompt) (assertion-violation 'completion:exit-input "no prompt waits"))))

(commands:define-command (complete)
  "Replaces the query with the selected match's text; with none selected, replaces the input with the longest common start of the matches' whole texts when it is longer."
  (let* ([s (%current 'completion:complete)] [m (session-record-selected s)])
    (if m
        (%replace! s (query-start s m) (match-text s m))
        (let-values ([(start end) ((session-record-bounds s))])
          (let ([common (common-whole-start s (input-of s))])
            (when common (%replace! s start common)))))
    (rematch! s #f)
    (let ([p (%point-of s)])
      (when (and p (sole-match? s)) (end-session! s)))))

(define (%move who to)
  (let* ([s (%current who)] [matches (session-matches s)] [n (match-list-count matches)] [m (session-record-selected s)]
         [k (and m (match-list-index matches m))])
    (unless (fx= n 0)
      (select-match! s (match-list-ref matches (fxmax 0 (fxmin (fx- n 1) (to k n))))))))

(commands:define-command (next [n (commands:prefix-number)])
  "Selects the match N after the selected one in the current session, stopping at the last; with none selected, the first."
  (%move 'completion:next (lambda (k count) (if k (fx+ k n) 0))))

(commands:define-command (previous [n (commands:prefix-number)])
  "Selects the match N before the selected one, stopping at the first."
  (%move 'completion:previous (lambda (k count) (if k (fx- k n) 0))))

(commands:define-command (first)
  "Selects the first match."
  (%move 'completion:first (lambda (k count) 0)))

(commands:define-command (last)
  "Selects the last match."
  (%move 'completion:last (lambda (k count) (fx- count 1))))

(commands:define-command (search-history)
  "Replaces the input of the innermost prompt with an entry of its history, read with completion."
  (let* ([p (or (minibuffer:current-prompt) (assertion-violation 'completion:search-history "no prompt waits"))]
         [h (minibuffer:prompt-history p)] [entries (if h (h) '())])
    (when (null? entries)
      (error 'completion:search-history "History is empty"))
    (let ([entry (minibuffer:call-with-setup
                   (lambda (q) (minibuffer:set-input! q (minibuffer:input p)))
                   (lambda ()
                     (read "History: " (list (source (candidates (list->vector entries)) (in-order))) #f)))])
      (minibuffer:set-input! p entry))))

(define %quit (record-constructor (record-constructor-descriptor &quit)))

(define (%unload)
  (for-each (lambda (r) (signal-task (%read-state-task r) (%quit))) %reads)
  (for-each end-session! sessions))

(table-set! any-order-dispatch #\! %dispatch-not)
(table-set! any-order-dispatch #\= %dispatch-literal)
(table-set! any-order-dispatch #\^ %dispatch-starts)
(table-set! any-order-dispatch #\~ %dispatch-flex)
(table-set! any-order-dispatch #\$ %dispatch-ends)
(table-set! category-default-styles buffer-category (list prefix substring))
(table-set! category-default-styles location-category (list substring))
;; Every command's name starts with its plugin's name, so matching only at
;; the start would not find a command by the word it is known by.
(table-set! category-default-styles command-category (list prefix substring))
(table-set! action-keymaps buffer-category (list buffer-action-keymap))
(table-set! action-keymaps command-category (list command-action-keymap))
(table-set! action-keymaps file-category (list file-action-keymap))
(table-set! action-keymaps location-category (list location-action-keymap))
(table-set! web:stylesheets 'completion "completion/completion.css")
(keys:bind! minibuffer:keymap "M-r" search-history)
(keys:bind! minibuffer:keymap "M-s" search-history)
(keys:bind! keymap "RET" exit)
(keys:bind! keymap "M-RET" exit-input)
(keys:bind! keymap "TAB" complete)
(keys:bind! region-keymap "TAB" complete)
(keys:bind! region-selected-keymap "RET" exit)
(keys:bind! keys:global "C-M-i" complete-at-point)
(keys:bind! keys:global "M-TAB" complete-at-point)
;; Exit, complete and the moves stay offered everywhere: they also act on
;; a session that start runs over a field in any view. M-x cannot reach a
;; session at point, since its own prompt ends that session.
(table-set! commands:command-modes exit-input (list minibuffer:mode))
(table-set! commands:command-modes search-history (list minibuffer:mode))
(add-hook! minibuffer:input-changed %prompt-input-changed)
(add-hook! minibuffer:prompt-started %prompt-input-changed)
(add-hook! minibuffer:prompt-ended %prompt-ended)
(add-hook! updated %sync-keymaps!)
(add-hook! ended %point-ended)
(add-hook! commands:after-command %continue-at-point)
(on-unload %unload)
