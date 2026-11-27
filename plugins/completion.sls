#!tuna
(import (hooks) (options) (tables) (timers) (saved))
;; This plugin's substring is a style, so Chez's goes by another name.
(import (minibuffer) (buffers) (document) (views) (layout) (keys) (commands) (jobs) (web) (ask) (editing) (kill-ring) (faces)
        (modes) (syntax) (browse-url) (files)
        (completion matcher)
        (rename (only (chezscheme) substring) (substring string-part)))

(define %self (current-owner))

(hooks:define-hook started "Called with a session when it starts, before its first matches.")

(hooks:define-hook updated "Called with a session after its matches or its selection change.")

(hooks:define-hook ended "Called with a session after it ends.")

(hooks:define-hook find-region
  "Its entries take no arguments and return a region for point in the current view, or #f.")

(hooks:define-hook target-finders
  "Its entries take a view and return a completion:target for what is at its point, or #f.")

(tables:define-table category-styles
  "Maps a category to the styles tried before its default styles: its completion:category-default-styles entry while completion:styles holds its default, else completion:styles.")

(tables:define-table category-default-styles
  "Maps a category to the styles used in place of completion:styles while that option holds its default.")

(tables:define-table annotators "Maps a category to a procedure of a session that returns its annotator, a procedure of a candidate's value and details.")

(tables:define-table action-keymaps "Maps a category to the list of keymaps of the actions on its candidates, searched in order.")

(tables:define-table any-order-dispatch
  "Maps a character to a procedure of the rest of a component that returns a term.")

(tables:define-table keymap "Added to the prompt of each read.")

(tables:define-table region-keymap "The temporary keymap of a session at point.")

(tables:define-table region-selected-keymap "The temporary keymap of a session at point while a match is selected.")

(tables:define-table narrowing-keymap "Added to the prompt of each read whose sources have narrow characters.")

(tables:define-table narrow-key-keymap "Narrows by the character typed; a prefix key in completion:narrowing-keymap leads to it.")

(tables:define-table narrow-keymap "Searched in a read while its input is one of its sources' narrow characters.")

(tables:define-table widen-keymap "Searched in a narrowed read while its input is empty.")

(define-syntax define-category
  (lambda (x)
    (syntax-case x ()
      [(_ id doc) (and (identifier? #'id) (string? (syntax->datum #'doc)))
       #'(define-public id (%category-name 'id))]
      [_ (syntax-violation 'completion:define-category "expected (completion:define-category id doc-string)" x)])))

(define (%category-name id)
  (let ([owner (owner-name (current-owner))])
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

(define-category location-category "Lines of files, valued by a location: a path, a line number and a column, as (path line . column).")

(define-category name-category "Scheme names exported by Tuna's libraries and Chez's, valued by the exported name.")

(define-category identifier-category "Names in a program that no plugin describes, valued by their text.")

(define-category url-category "Web addresses, valued by their text.")

(define-category region-category "The active region, valued by its text.")

(define-category expression-category "A string or list in a program, valued by its text.")

(define-category top-level-form-category "A top-level form in a program, valued by its text.")

;; Several plugins bind actions on the shared categories, so their
;; keymaps are defined beside them.
(tables:define-table buffer-action-keymap "The actions on buffers.")

(tables:define-table command-action-keymap "The actions on commands.")

(tables:define-table file-action-keymap "The actions on file names.")

(tables:define-table location-action-keymap "The actions on locations.")

(tables:define-table name-action-keymap "The actions on Scheme names.")

(tables:define-table identifier-action-keymap "The actions on identifiers.")

(tables:define-table url-action-keymap "The actions on web addresses.")

(tables:define-table region-action-keymap "The actions on the active region.")

(tables:define-table expression-action-keymap "The actions on expressions.")

(tables:define-table top-level-form-action-keymap "The actions on top-level forms.")

;; A target lives here, not with the actions on it, so that a plugin
;; finding what is at point makes one without importing them.
(define-record-type target
  (sealed #t)
  (fields category value text start end)
  (protocol
    (lambda (new)
      (lambda (category value text start end)
        (unless (or (not category) (symbol? category))
          (assertion-violation 'completion:make-target "neither a category nor #f" category))
        (unless (string? text)
          (assertion-violation 'completion:make-target "not a string" text))
        (unless (or (and (not start) (not end)) (and (fixnum? start) (fixnum? end) (fx<= 0 start end)))
          (assertion-violation 'completion:make-target "neither a start and an end nor #f and #f" start end))
        (new category value text start end)))))

(define-record-type (%source %make-source source?)
  (sealed #t)
  (fields candidates stream category title split in-order? rank preview preview-end preview-delay exit styles group row
          narrow faces prefix lookup))

(define (%check-source candidates stream category title split in-order? rank preview preview-end preview-delay exit styles
                       group row narrow faces prefix lookup)
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
  (unless (or (not preview-end) (procedure? preview-end))
    (assertion-violation who "not a procedure" preview-end))
  (unless (or (not preview-delay) (and (real? preview-delay) (>= preview-delay 0)))
    (assertion-violation who "not a number of seconds" preview-delay))
  (unless (or (not exit) (procedure? exit))
    (assertion-violation who "not a procedure" exit))
  (unless (or (not styles) (and (list? styles) (for-all procedure? styles)))
    (assertion-violation who "not a list of styles" styles))
  (unless (or (not group) (procedure? group))
    (assertion-violation who "not a procedure" group))
  (unless (or (not row) (procedure? row))
    (assertion-violation who "neither a procedure nor #f" row))
  (unless (or (not narrow) (and (char? narrow) (not (char=? narrow #\space))))
    (assertion-violation who "neither a character other than a space nor #f" narrow))
  (for-each (lambda (p) (unless (or (not p) (procedure? p)) (assertion-violation who "not a procedure" p)))
            (list faces prefix lookup))
  (%make-source candidates stream category title split in-order? rank preview preview-end preview-delay exit styles
                group row narrow faces prefix lookup))

(define (%candidates-clause candidates)
  (unless (or (procedure? candidates) (%candidates? candidates))
    (assertion-violation 'completion:source "neither a vector of candidates nor a procedure" candidates))
  candidates)

(define (%stream-clause stream)
  (unless (procedure? stream)
    (assertion-violation 'completion:source "not a procedure" stream))
  stream)

(define (%candidate? c)
  (or (string? c)
      (and (pair? c) (string? (car c)))
      (and (vector? c) (fx= (vector-length c) 3) (string? (vector-ref c 0)))))

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
                                #,(given-or-false 'preview-end) #,(given-or-false 'preview-delay)
                                #,(given-or-false 'exit) #,(given-or-false 'styles) #,(given-or-false 'group) #,(given-or-false 'row)
                                #,(given-or-false 'narrow) #,(given-or-false 'faces) #,(given-or-false 'prefix)
                                #,(given-or-false 'lookup)))
             (let* ([c (car clauses)]
                    [name (syntax-case c () [(k . _) (identifier? #'k) (syntax->datum #'k)] [_ (invalid c)])])
               (when (assq name given)
                 (syntax-violation 'completion:source "clause given twice" x c))
               (when (and (memq name '(candidates job stream))
                          (exists (lambda (k) (assq k given)) '(candidates job stream)))
                 (syntax-violation 'completion:source "more than one of the candidates, job and stream clauses" x))
               (loop (cdr clauses)
                     (append
                       (case name
                         [(candidates stream category title split rank preview-delay exit styles narrow faces prefix lookup)
                          (syntax-case c () [(_ e) (list (cons name #'e))] [_ (invalid c)])]
                         [(preview)
                          (syntax-case c () [(_ show end) (list (cons 'preview #'show) (cons 'preview-end #'end))] [_ (invalid c)])]
                         [(group)
                          (syntax-case c ()
                            [(_ t) (list (cons 'group #'t))]
                            [(_ t r) (list (cons 'group #'t) (cons 'row #'r))]
                            [_ (invalid c)])]
                         [(job) (syntax-case c () [(_ w i) (list (cons name #'(%job-stream w i)))] [_ (invalid c)])]
                         [(in-order) (syntax-case c () [(_) (list (cons name #'#t))] [_ (invalid c)])]
                         [else (invalid c)])
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
               (call-as-owner %self
                 (lambda ()
                   (jobs:start worker input emit
                     (lambda (how)
                       (set! job #f)
                       (emit 'done)))))))
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

(options:define-option any-order-faces (list match-0 match-1 match-2 match-3) (lambda (v) (and (list? v) (for-all symbol? v)))
  "The faces completion:any-order draws its components' matches in, in turn; with none, as other styles' matches.")

(define (%component-term component)
  (let* ([n (string-length component)]
         [at-start (tables:ref any-order-dispatch (string-ref component 0) #f)]
         [at-end (and (fx> n 1) (tables:ref any-order-dispatch (string-ref component (fx- n 1)) #f))])
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

(options:define-option styles (list prefix partial) (lambda (v) (and (list? v) (for-all procedure? v)))
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

(define (%default-match pattern texts ranks groups)
  (let ([kept (eq-hashtable-ref %stores texts #f)])
    (store-matches
      (if (and kept (eq? (vector-ref kept 0) ranks) (eq? (vector-ref kept 1) groups))
          (vector-ref kept 2)
          (let ([s (make-store texts ranks groups)])
            (eq-hashtable-set! %stores texts (vector ranks groups s))
            s))
      pattern)))

(define (%default-spans pattern text) (pattern-spans pattern text))

(define default-matcher (make-matcher %default-match %default-spans %match-worker))

(options:define-option matcher default-matcher matcher?
  "The matcher sessions use.")

(options:define-option read-preselect 'first (lambda (v) (memq v '(first none)))
  "What a read selects when its matches change: first or none.")

(options:define-option point-preselect 'none (lambda (v) (memq v '(first none)))
  "What a session at point selects when its matches change: none or first.")

(options:define-option async-min-input 3 (lambda (v) (and (fixnum? v) (fx>= v 0)))
  "How many characters a search that asks as you type, such as grep:grep, waits for before it asks.")

(options:define-option async-delay 0.2 (lambda (v) (and (real? v) (>= v 0)))
  "Seconds without typing before a search that asks as you type asks again.")

(define %inline-candidates 1000)
(define %inline-bytes 50000)

(module %internals
  (check-main-thread check-session session-record? make-session session-record-view session-record-ended?
   session-record-matches session-record-selected session-record-input session-record-input-set!
   session-record-bounds session-record-prompt candidate-match?
   session-record-states session-categories-of session-record-accept session-record-default sessions open-session!
   start-session! end-session! input-of rematch! select-match! match-text match-value match-title match-category
   match-row-text match-spans match-annotation match-whole-text match-exit match-faces match-prefix match-answer busy? query-start find-named! sole-match?
   common-input-start narrow-chars session-record-narrowed narrowed-title source-title-of narrow! combine!
   match-list? make-match-list match-list-count match-list-ref match-list-index no-matches candidate-valued
   choose! choose-match!)

  (define main-thread (get-thread-id))

  (define (check-main-thread who)
    (unless (fx= (get-thread-id) main-thread)
      (assertion-violation who "not on the main thread")))

  (define-record-type (session-record make-session session-record?)
    (sealed #t)
    (fields view (mutable states) width bounds accept preselect history default prompt
            (mutable input) (mutable matches) (mutable selected) (mutable locked?) (mutable ended?)
            (mutable inline?) (mutable annotators) (mutable next-id) history-ranks (mutable dirty?)
            (mutable finding) (mutable narrowed) (mutable previewed) (mutable chosen) (mutable preview-timer)))

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
            (mutable base) (mutable more?) (mutable prefers-input?) (mutable grouping) (mutable details)
            (mutable rank-high)))

  ;; Each candidate holds its title's number, so a match job orders
  ;; matches by group without the titles; the numbers sit in a bytevector,
  ;; which the collector does not scan. A stream's new matches
  ;; go at the end of its matches only while the numbers do not fall, so
  ;; the last number of the matches, and of those a match under way
  ;; keeps, is kept.
  (define-record-type grouping
    (sealed #t)
    (fields (mutable groups) (mutable titles) (mutable count) numbers (mutable last-title) (mutable last-number)
            (mutable matched-last) (mutable matched-rising?) (mutable kept-last) (mutable kept-rising?)))

  (define (empty-grouping)
    (make-grouping #vu8() (vector) 0 (make-hashtable string-hash string=?) #f 0 #f #t #f #t))

  (define (group-ref groups i) (bytevector-u32-native-ref groups (fx* 4 i)))

  (define (append-groups-at groups n more)
    (let* ([at (fx* 4 n)] [need (fx+ at (bytevector-length more))]
           [groups (if (fx>= (bytevector-length groups) need)
                       groups
                       (let ([w (make-bytevector (fxmax need (fx* 2 (bytevector-length groups))))])
                         (bytevector-copy! groups 0 w 0 at)
                         w))])
      (bytevector-copy! more 0 groups at (bytevector-length more))
      groups))

  (define (group-number! g title)
    (unless (string? title)
      (assertion-violation 'completion:source "a group's title procedure returned what is not a string" title))
    (if (eq? title (grouping-last-title g))
        (grouping-last-number g)
        (let ([n (or (hashtable-ref (grouping-numbers g) title #f)
                     (let ([n (grouping-count g)])
                       (hashtable-set! (grouping-numbers g) title n)
                       (grouping-titles-set! g (append-at (grouping-titles g) n (vector title) #f))
                       (grouping-count-set! g (fx+ n 1))
                       n))])
          (grouping-last-title-set! g title)
          (grouping-last-number-set! g n)
          n)))

  (define (state-groups st) (let ([g (state-grouping st)]) (and g (grouping-groups g))))

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

  (define (candidate-text c)
    (cond [(string? c) c] [(pair? c) (car c)] [else (vector-ref c 0)]))
  (define (candidate-value c)
    (cond [(string? c) c] [(pair? c) (cdr c)] [else (vector-ref c 1)]))

  (define (styles-for source)
    (let* ([c (%source-category source)]
           [chosen (append (or (%source-styles source) '()) (if c (tables:ref category-styles c '()) '()))]
           [defaults (or (and c (equal? (styles) (options:default styles)) (tables:ref category-default-styles c #f))
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
           [base (state-count st)] [rank-of (ranker s st given)] [g (state-grouping st)]
           [title-of (and g (%source-group (state-source st)))] [groups (and g (make-bytevector (fx* 4 k)))])
      (do ([i 0 (fx+ i 1)]) ((fx= i k))
        (let* ([c (vector-ref cands i)] [text (candidate-text c)] [value (candidate-value c)] [rank (rank-of i text)]
               [high (state-rank-high st)])
          (vector-set! texts i (string->utf8 text))
          (vector-set! vals i value)
          (vector-set! ranks i rank)
          (state-rank-high-set! st (and high (fx< high rank) rank))
          (when g (bytevector-u32-native-set! groups (fx* 4 i) (group-number! g (title-of text value))))))
      (state-count-set! st (fx+ base k))
      (if (fx= base 0)
          (begin
            (state-texts-set! st texts) (state-vals-set! st vals) (state-ranks-set! st ranks)
            (when g (grouping-groups-set! g groups)))
          (begin
            (state-texts-set! st (append-at (state-texts st) base texts #vu8()))
            (state-vals-set! st (append-at (state-vals st) base vals #f))
            (state-ranks-set! st (append-at (state-ranks st) base ranks 0))
            (when g (grouping-groups-set! g (append-groups-at (grouping-groups g) base groups)))))
      (add-details! st base cands)
      (let ([job (state-match-job st)])
        (when job (jobs:send! job (list 'add (jobs:freeze texts) ranks groups))))))

  ;; Most sources carry no details, so a state keeps a vector of them only
  ;; once one of its candidates has some.
  (define (add-details! st base cands)
    (let ([k (vector-length cands)])
      (when (or (state-details st)
                (let loop ([i 0]) (and (fx< i k) (or (vector? (vector-ref cands i)) (loop (fx+ i 1))))))
        (let ([ds (make-vector k #f)])
          (do ([i 0 (fx+ i 1)]) ((fx= i k))
            (let ([c (vector-ref cands i)])
              (when (vector? c) (vector-set! ds i (vector-ref c 2)))))
          (state-details-set! st (append-at (or (state-details st) (make-vector base #f)) base ds #f))))))

  ;; A streamed source may emit thousands of times, a few candidates
  ;; each, so its texts and ranks grow by doubling, not by a copy per
  ;; emission; only the first state-count entries are candidates.
  (define (append-at v n w fill)
    (let ([v (grow v (fx+ n (vector-length w)) fill)])
      (vector-copy! w 0 v n (vector-length w))
      v))

  (define (trim-candidates! st)
    (let ([n (state-count st)] [g (state-grouping st)])
      (unless (fx= (vector-length (state-texts st)) n)
        (state-texts-set! st (vector-copy (state-texts st) 0 n))
        (state-ranks-set! st (vector-copy (state-ranks st) 0 n)))
      (when (and g (not (fx= (bytevector-length (grouping-groups g)) (fx* 4 n))))
        (let ([w (make-bytevector (fx* 4 n))])
          (bytevector-copy! (grouping-groups g) 0 w 0 (fx* 4 n))
          (grouping-groups-set! g w)))))

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

  ;; A prefix is a candidate's base only where the source emits one, as
  ;; for a file's folder: a search typed before a filter is a prefix that
  ;; no candidate continues.
  (define (base st)
    (let ([b (state-base st)])
      (if b (string-part (or (state-prefix st) "") 0 (fxmin b (state-prefix-length st))) "")))

  (define (update-query! s st)
    (let ([input (or (session-record-input s) "")])
      (state-query-set! st (string-part input (fxmin (string-length input) (lead-length st)) (string-length input)))))

  (define (match-job-of s st)
    (or (state-match-job st)
        (let ([job (call-as-owner %self
                     (lambda ()
                       (jobs:start (%matcher-worker (matcher)) #f
                         (lambda (result) (match-arrived! s st result)))))])
          (state-match-job-set! st job)
          (state-job-dropped-set! st (state-dropped st))
          (state-sorted?-set! st #f)
          (trim-candidates! st)
          (unless (fx= (state-count st) 0)
            (jobs:send! job (list 'add (jobs:freeze (state-texts st)) (state-ranks st) (state-groups st))))
          (when (state-done? st) (sort-unless-held! st))
          job)))

  ;; Candidates whose ranks rise in the order they came, as an in-order
  ;; source's do, are already in the sorted order, so sorting them would
  ;; only match every one of them again into new matches: a list showing
  ;; them would start afresh at the stream's end, and a view scrolled by
  ;; hand would go back to the selection.
  (define (sort-unless-held! st)
    (unless (state-rank-high st) (send-sort! st)))

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
    (state-rank-high-set! st (least-fixnum))
    (state-texts-set! st (vector))
    (state-vals-set! st (vector))
    (state-details-set! st #f)
    (state-ranks-set! st (vector))
    (when (state-grouping st) (state-grouping-set! st (empty-grouping)))
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

  (define (inline-matches s st)
    (trim-candidates! st)
    (let ([match (%matcher-match (matcher))] [n (length (state-styles st))])
      (let loop ([k 0])
        (let* ([pattern (pattern-of st k)]
               [locals (match pattern (state-texts st) (state-ranks st) (state-groups st))])
          (if (and (fx= (vector-length locals) 0) (fx< (fx+ k 1) n))
              (loop (fx+ k 1))
              (begin
                (state-pattern-set! st pattern)
                (numbers->match-list s st (state-dropped st) locals)))))))

  (define (match-inline! s st)
    (set-state-matches! s st (inline-matches s st)))

  ;; Matches equal to the last stay the same list, so the rows showing
  ;; them are not written afresh and a view scrolled by hand stays where
  ;; it is.
  (define (match-inline-keeping! s st)
    (let ([ms (inline-matches s st)])
      (set-state-matches! s st (if (same-matches? ms (state-matches st)) (state-matches st) ms))))

  (define (same-matches? a b)
    (let ([n (match-list-count a)])
      (and (fx= n (match-list-count b))
           (let loop ([i 0])
             (or (fx= i n) (and (fx= (match-list-ref a i) (match-list-ref b i)) (loop (fx+ i 1))))))))

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
      (let ([g (state-grouping st)])
        (when g
          (grouping-kept-last-set! g (and from (grouping-matched-last g)))
          (grouping-kept-rising?-set! g (or (not from) (grouping-matched-rising? g)))))
      (jobs:send! job (list 'match id pattern (or from 0)))))

  (define (groups-after st numbers)
    (let* ([g (state-grouping st)] [groups (grouping-groups g)] [offset (fx- (state-job-dropped st) (state-dropped st))]
           [n (vector-length numbers)])
      (let loop ([i 0] [last (grouping-kept-last g)] [rising? (grouping-kept-rising? g)])
        (if (or (fx= i n) (not rising?))
            (values last rising?)
            (let ([group (group-ref groups (fx+ offset (vector-ref numbers i)))])
              (loop (fx+ i 1) group (or (not last) (fx<= last group))))))))

  ;; A first part of a match's results is the start of the whole, so the
  ;; whole adds to the matches that took the part.
  (define (take-matches! s st id numbers)
    (let* ([kept (state-pending-kept st)]
           [ms (if (or (fx> kept 0) (eqv? id (state-matches-id st))) (state-matches st) (make-match-list (vector) 0))])
      (match-list-count-set! ms kept)
      (match-list-add! ms numbers (state-job-dropped st) (session-record-width s) (state-index st))
      (state-matches-id-set! st id)
      (let ([g (state-grouping st)])
        (when (and g (not (state-sorted? st)))
          (let-values ([(last rising?) (groups-after st numbers)])
            (grouping-matched-last-set! g last)
            (grouping-matched-rising?-set! g rising?))))
      (set-state-matches! s st ms)))

  ;; A match that adds to kept matches may find candidates of a group the
  ;; kept matches hold, and its matches cannot then go at their end
  ;; without splitting that group, so every candidate is matched again.
  (define (adds-in-group-order? st numbers)
    (or (not (state-grouping st))
        (fx= (state-pending-kept st) 0)
        (let-values ([(last rising?) (groups-after st numbers)]) rising?)))

  (define (matches-arrived! s st id done? numbers)
    (when (eqv? id (state-pending st))
      (when done? (state-matched-to-set! st (state-pending-end st)))
      (cond
        [(not (adds-in-group-order? st numbers))
         (state-matched-to-set! st #f)
         (send-match! s st (state-style st))]
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
       (when (state-match-job st) (sort-unless-held! st))]
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
            (cond
              [(eq? was (session-record-inline? s)) (match-state! s st)]
              [(session-record-inline? s)
               (for-each (lambda (st) (match-inline-keeping! s st)) (session-record-states s))]
              [else (for-each (lambda (st) (match-state! s st)) (session-record-states s))])
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

  (define (stop-preview-timer! s)
    (let ([t (session-record-preview-timer s)])
      (when t
        (session-record-preview-timer-set! s #f)
        (timers:cancel! t))))

  (define (preview! s st v)
    (let* ([source (state-source st)] [show (%source-preview source)] [delay (%source-preview-delay source)])
      (when show
        (stop-preview-timer! s)
        (if (and v delay (> delay 0))
            (session-record-preview-timer-set! s
              (call-as-owner %self
                (lambda ()
                  (timers:run-after delay
                    (lambda ()
                      (session-record-preview-timer-set! s #f)
                      (unless (session-record-ended? s) (show v)))))))
            (show v)))))

  ;; A preview's end learns which candidate was chosen, so a picker keeps
  ;; what its previews opened for that one and undoes the rest.
  (define (choose! s st answer)
    (session-record-chosen-set! s (cons st answer)))

  (define (choose-match! s m)
    (choose! s (owner-of s m) (match-answer s m)))

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
          (when (and was (not (eq? was now))) (preview! s was #f))
          (when now
            (let ([answer (match-answer s m)])
              (session-record-previewed-set! s answer)
              (preview! s now answer)))))))

  (define (prefers-input? s)
    (exists (lambda (st) (and (state-prefers-input? st) (string=? (state-query st) "")))
            (shown-states s)))

  (define (shown-states s)
    (let ([c (session-record-narrowed s)])
      (if c
          (filter (lambda (st) (eqv? (%source-narrow (state-source st)) c)) (session-record-states s))
          (session-record-states s))))

  ;; Narrowing chooses among a read's sources, so a read of one source
  ;; keeps its narrow character's key for typing.
  (define (narrow-chars s)
    (let ([sts (session-record-states s)])
      (if (and (pair? sts) (pair? (cdr sts)))
          (fold-right (lambda (st cs) (let ([c (%source-narrow (state-source st))]) (if (and c (not (memv c cs))) (cons c cs) cs)))
                      '() sts)
          '())))

  (define (source-title-of s c)
    (exists (lambda (st) (let ([source (state-source st)])
                           (and (eqv? (%source-narrow source) c) (%source-title source))))
            (session-record-states s)))

  (define (narrowed-title s)
    (let ([c (session-record-narrowed s)])
      (and c (or (source-title-of s c) (string c)))))

  ;; Hidden sources go on matching, so widening shows their matches at
  ;; once.
  (define (narrow! s c)
    (session-record-narrowed-set! s (and (memv c (narrow-chars s)) c))
    (session-record-dirty?-set! s #t))

  ;; Only new matches set the session's matches and select again, so a
  ;; selection cleared while a job matches stays clear until they come.
  (define (combine! s)
    (when (session-record-dirty? s)
      (session-record-dirty?-set! s #f)
      (let ([matches (let ([sts (shown-states s)])
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
                                  (match-list-ref matches 0))))
          ;; A lookup reads the match's spans, which new input moves, so the
          ;; place previewed follows the input while the selection stays.
          ;; A stream's batches leave the answer as it was, and previewing it
          ;; again would pull back a view the user scrolled.
          (let ([now (session-record-selected s)])
            (when (and now (eqv? now sel) (%source-lookup (state-source (owner-of s now))))
              (let ([answer (match-answer s now)])
                (unless (equal? answer (session-record-previewed s))
                  (session-record-previewed-set! s answer)
                  (preview! s (owner-of s now) answer))))))))
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
                           #f #f #f #f #f #t '() 0 (history-ranks h default) #t #f #f #f #f #f)])
      (session-record-states-set! s
        (let loop ([sources sources] [index 0])
          (if (null? sources)
              '()
              (cons (make-state (car sources) (styles-for (car sources)) index 0 0 (vector) (vector) (vector)
                                (make-eqv-hashtable) #f #f #f 0 #f #f #t (make-match-list (vector) 0) 0 #f #f #f
                                '() 0 "" #f #f #f (and (%source-group (car sources)) (empty-grouping)) #f
                                (least-fixnum))
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
                  (let ([make (tables:ref annotators c #f)])
                    (if make
                        (cons (cons c (guard (e [(not (cancelled? e)) (report e) #f]) (make s))) acc)
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
              (guard (e [(not (cancelled? e)) (report e)]) (receiver (eof-object))))))
        (session-record-states s))
      (stop-preview-timer! s)
      (ended s)
      (let ([chosen (session-record-chosen s)])
        (for-each
          (lambda (st)
            (let ([end (%source-preview-end (state-source st))])
              (when end
                (guard (e [(not (cancelled? e)) (report e)])
                  (end (and chosen (eq? (car chosen) st) (cdr chosen)))))))
          (session-record-states s)))))

  ;; A session holds its texts as UTF-8: a broad search holds millions of
  ;; them, and a string takes four bytes a character.
  (define (match-bytes s m) (let ([st (owner-of s m)]) (vector-ref (state-texts st) (local-of s st m))))
  (define (match-text s m) (utf8->string (match-bytes s m)))
  (define (match-value s m) (let ([st (owner-of s m)]) (vector-ref (state-vals st) (local-of s st m))))
  (define (match-details s m)
    (let* ([st (owner-of s m)] [ds (state-details st)])
      (and ds (vector-ref ds (local-of s st m)))))
  (define (match-exit s m) (%source-exit (state-source (owner-of s m))))

  ;; A faces or prefix procedure is called for every row drawn, so one that
  ;; raises is reported once and its rows draw without it.
  (define failed-procedures (make-weak-eq-hashtable))

  (define (row-look s m clause who check)
    (let ([p (clause (state-source (owner-of s m)))])
      (if (or (not p) (eq-hashtable-contains? failed-procedures p))
          #f
          (guard (c [(not (cancelled? c)) (eq-hashtable-set! failed-procedures p #t) (report c) #f])
            (let ([v (p (match-text s m) (match-value s m))])
              (unless (check v)
                (assertion-violation who "a source's procedure returned what its clause does not take" v))
              v)))))

  (define (spans-in? text)
    (let ([n (string-length text)])
      (lambda (v)
        (and (list? v)
             (for-all (lambda (x) (and (list? x) (fx= (length x) 3) (fixnum? (car x)) (fixnum? (cadr x))
                                       (fx<= 0 (car x) (cadr x) n)))
                      v)))))

  (define (match-faces s m)
    (or (row-look s m %source-faces 'completion:source (spans-in? (match-row-text s m))) '()))

  (define (match-prefix s m)
    (row-look s m %source-prefix 'completion:source
      (lambda (v) (or (string? v) (and (pair? v) (symbol? (car v)) (string? (cdr v)))))))

  ;; A source's exit procedure gets the candidate's own value, not this
  ;; one, since it acts on the candidate as it stands in the text completed.
  (define (match-answer s m)
    (let ([lookup (%source-lookup (state-source (owner-of s m)))] [v (match-value s m)])
      (if lookup (lookup v (match-spans s m)) v)))
  (define (match-title s m)
    (let* ([st (owner-of s m)] [g (state-grouping st)])
      (if g
          (vector-ref (grouping-titles g) (group-ref (grouping-groups g) (local-of s st m)))
          (%source-title (state-source st)))))

  (define (match-row-text s m)
    (let* ([st (owner-of s m)] [row (%source-row (state-source st))])
      (if row
          (let ([text (row (match-text s m) (match-value s m))])
            (unless (string? text)
              (assertion-violation 'completion:source "a group's row procedure returned what is not a string" text))
            text)
          (match-text s m))))

  (define (match-category s m) (%source-category (state-source (owner-of s m))))
  (define (session-categories-of s) (map (lambda (st) (%source-category (state-source st))) (shown-states s)))

  (define (match-whole-text s m) (string-append (base (owner-of s m)) (match-text s m)))

  (define (match-spans s m)
    (let ([st (owner-of s m)])
      ((%matcher-spans (matcher)) (state-pattern st) (match-row-text s m))))

  (define (match-annotation s m)
    (let* ([st (owner-of s m)] [cache (state-annotations st)])
      (or (hashtable-ref cache m #f)
          (let* ([c (%source-category (state-source st))]
                 [a (and c (assq c (session-record-annotators s)))]
                 [columns (if (and a (cdr a))
                              (guard (e [(not (cancelled? e)) (report e) '()])
                                ((cdr a) (match-value s m) (match-details s m)))
                              '())])
            (hashtable-set! cache m columns)
            columns))))

  (define (busy? s)
    (exists (lambda (st) (not (and (state-done? st) (not (state-pending st))))) (shown-states s)))

  (define (same-chars? a a-start b b-start count)
    (let loop ([i 0])
      (or (fx= i count)
          (and (char=? (string-ref a (fx+ a-start i)) (string-ref b (fx+ b-start i)))
               (loop (fx+ i 1))))))

  (define (query-start s m)
    (let-values ([(start end) ((session-record-bounds s))])
      (fx+ start (lead-length (owner-of s m)))))

  (define (candidate-valued s category value)
    (exists
      (lambda (st)
        (let ([source (state-source st)])
          (and category (eq? (%source-category source) category) (vector? (%source-candidates source))
               (let ([v (%source-candidates source)])
                 (let loop ([i 0])
                   (and (fx< i (vector-length v))
                        (let ([c (vector-ref v i)])
                          (if (equal? (candidate-value c) value)
                              (list (string-append (base st) (candidate-text c)) value st)
                              (loop (fx+ i 1))))))))))
      (session-record-states s)))

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
        (shown-states s))))

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
                (if (and (fx<= lead n) (same-chars? (state-prefix st) 0 text 0 lead) (fx> (state-count st) 0)
                         (memq st (shown-states s)))
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

  ;; TAB with nothing selected may compare every match, millions in a
  ;; broad search, so the inputs they make are read in place, as UTF-8,
  ;; and the scan ends once their common start can no longer pass the
  ;; input.
  (define (common-input-start s input)
    (let* ([matches (or (session-record-matches s) no-matches)] [count (match-list-count matches)]
           [leads (map (lambda (st) (string->utf8 (lead st))) (session-record-states s))]
           [shortest (string-length input)])
      (define (lead-of st) (list-ref leads (state-index st)))
      (define (made-length st text) (fx+ (bytevector-length (lead-of st)) (bytevector-length text)))
      (define (made-ref st text i)
        (let* ([lead (lead-of st)] [n (bytevector-length lead)])
          (if (fx< i n) (bytevector-u8-ref lead i) (bytevector-u8-ref text (fx- i n)))))
      (define (continuation? b) (fx= (fxand b #xC0) #x80))
      (and (fx> count 0)
           (let* ([m0 (match-list-ref matches 0)] [st0 (owner-of s m0)] [t0 (match-bytes s m0)]
                  [total (made-length st0 t0)])
             (let loop ([i 1] [n total])
               (cond
                 [(fx<= n shortest) #f]
                 [(fx= i count)
                  (let* ([n (let back ([n n])
                              (if (and (fx< n total) (continuation? (made-ref st0 t0 n))) (back (fx- n 1)) n))]
                         [common (make-bytevector n)])
                    (do ([k 0 (fx+ k 1)]) ((fx= k n))
                      (bytevector-u8-set! common k (made-ref st0 t0 k)))
                    (let ([c (utf8->string common)]) (and (fx> (string-length c) shortest) c)))]
                 [else
                  (let* ([m (match-list-ref matches i)] [st (owner-of s m)] [t (match-bytes s m)]
                         [limit (fxmin n (made-length st t))])
                    (loop (fx+ i 1)
                          (let scan ([k 0])
                            (if (and (fx< k limit) (fx= (made-ref st0 t0 k) (made-ref st t k)))
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

(define (narrowed s)
  (check-session 'completion:narrowed s)
  (narrowed-title s))

(define (narrow-characters s)
  (check-session 'completion:narrow-characters s)
  (map (lambda (c) (cons c (source-title-of s c))) (narrow-chars s)))

(define (%check-match who s m)
  (check-session who s)
  (unless (and (fixnum? m) (fx>= m 0) (candidate-match? s m))
    (assertion-violation who "not a match of the session" m)))

(define (text s m) (%check-match 'completion:text s m) (match-text s m))

(define (value s m) (%check-match 'completion:value s m) (match-value s m))

(define (title s m) (%check-match 'completion:title s m) (match-title s m))

(define (row-text s m) (%check-match 'completion:row-text s m) (match-row-text s m))

(define (category s m) (%check-match 'completion:category s m) (match-category s m))

(define (whole-text s m) (%check-match 'completion:whole-text s m) (match-whole-text s m))

(define (spans s m) (%check-match 'completion:spans s m) (match-spans s m))

(define (annotation s m) (%check-match 'completion:annotation s m) (match-annotation s m))

(define (row-faces s m) (%check-match 'completion:row-faces s m) (match-faces s m))

(define (row-prefix s m) (%check-match 'completion:row-prefix s m) (match-prefix s m))

;; Keyed by the previewing view, so the highlight shows in that view
;; alone and a buffer's other readers, such as M-s l's rows, see none of it.
(buffers:define-layer %preview-highlight (priority 10))

(define %previewed #f)

(define (preview-place view buffer position spans)
  (define who 'completion:preview-place)
  (unless (views:view? view) (assertion-violation who "not a view" view))
  (unless (buffers:buffer? buffer) (assertion-violation who "not a buffer" buffer))
  (let ([n (document:length (buffers:document buffer))])
    (unless (and (fixnum? position) (fx<= 0 position n))
      (assertion-violation who "not a position in the buffer" position))
    (unless (and (list? spans)
                 (for-all (lambda (r) (and (list? r) (fx= (length r) 2) (fixnum? (car r)) (fixnum? (cadr r))
                                           (fx<= 0 (car r) (cadr r) n)))
                          spans))
      (assertion-violation who "not a list of ranges in the buffer" spans)))
  (end-preview-place)
  (unless (eq? (views:buffer view) buffer) (views:set-buffer! view buffer))
  (views:set-point! view position)
  (let* ([doc (buffers:document buffer)] [line (document:line doc position)] [start (document:line-start doc line)]
         [end (if (fx< line (document:line doc (document:length doc))) (document:line-start doc (fx+ line 1)) (document:length doc))]
         [layer (buffers:layer buffer %preview-highlight view)])
    (buffers:add-span! layer start end (list (cons 'face faces:highlight)))
    (for-each (lambda (r) (buffers:add-span! layer (car r) (cadr r) (list (cons 'face faces:match)))) spans)
    (set! %previewed (cons buffer layer))))

(define (end-preview-place)
  (let ([p %previewed])
    (set! %previewed #f)
    (when (and p (buffers:live? (car p)))
      (buffers:set-spans! (cdr p) 0 (document:length (buffers:document (car p))) '()))))

;; A visit pauses its task, and show runs inside the session's selection
;; update, so it must not pause.
(define (location-preview view shown)
  (unless (views:view? view)
    (assertion-violation 'completion:location-preview "not a view" view))
  (unless (procedure? shown)
    (assertion-violation 'completion:location-preview "not a procedure" shown))
  (let ([newest 0] [ended? #f] [chosen-path #f] [opened '()] [buffer (views:buffer view)] [point (views:point view)])
    ;; Previewing the view's own buffer is no buffer preview, so its point
    ;; is put back by hand.
    (define (restore!)
      (end-preview-place)
      (views:end-preview! view)
      (when (and (eq? (views:buffer view) buffer) (buffers:live? buffer))
        (views:set-point! view (fxmin point (document:length (buffers:document buffer))))))
    ;; A buffer the user visited meanwhile is temporary no longer, and
    ;; stays.
    (define (kill-opened! keep)
      (for-each (lambda (b)
                  (when (and (buffers:live? b) (files:temporary? b) (not (equal? (files:path b) keep)))
                    (buffers:kill! b)))
                opened)
      (set! opened '()))
    (define (show location)
      (set! newest (fx+ newest 1))
      (if (not location)
          (restore!)
          (let ([n newest])
            (spawn-task
              (lambda (restore)
                (when (fx= n newest)
                  (let* ([path (car location)] [existing (files:buffer-visiting path)]
                         [b (or existing (guard (c [(not (cancelled? c)) (report c) #f]) (files:visit-temporarily path)))])
                    (when (and b (not existing))
                      (if (and ended? (not (equal? path chosen-path)))
                          (when (and (buffers:live? b) (files:temporary? b)) (buffers:kill! b))
                          (unless (memq b opened) (set! opened (cons b opened)))))
                    (when (and b (fx= n newest) (not ended?) (buffers:live? b))
                      (views:preview-buffer! view b)
                      (preview-place view b (editing:line-position b (cadr location) (cddr location)) '())
                      (shown view)))))))))
    (define (end location)
      (set! ended? #t)
      (set! newest (fx+ newest 1))
      (set! chosen-path (and location (car location)))
      (restore!)
      (kill-opened! chosen-path))
    (values show end)))

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
          [named (choose-match! s named) (minibuffer:exit! prompt (match-answer s named))]
          [(%read-state-any? r) (minibuffer:exit! prompt input)]
          [else (minibuffer:message! prompt "No match")])))))

(define (answer-input! p)
  (unless (minibuffer:prompt? p)
    (assertion-violation 'completion:answer-input! "not a prompt" p))
  (check-main-thread 'completion:answer-input!)
  (let ([r (%read-of-prompt p)] [input (minibuffer:input p)])
    (if r (%answer-input! r input) (minibuffer:exit! p input))))

;; A target's text depends on where it was found: insert! in buffers.sls
;; is buffers:insert!, so a text match would not find its candidate.
(define (answer-target! p target)
  (unless (minibuffer:prompt? p)
    (assertion-violation 'completion:answer-target! "not a prompt" p))
  (unless (target? target)
    (assertion-violation 'completion:answer-target! "not a target" target))
  (check-main-thread 'completion:answer-target!)
  (let* ([r (%read-of-prompt p)]
         [found (and r (candidate-valued (%read-state-session r) (target-category target) (target-value target)))])
    (cond
      [found
       (minibuffer:set-input! p (car found))
       (choose! (%read-state-session r) (caddr found) (cadr found))
       (minibuffer:exit! p (cadr found))]
      [else
       (minibuffer:set-input! p (target-text target))
       (answer-input! p)])))

(define (%answer! s m)
  (let* ([r (%read-of s)] [prompt (%read-state-prompt r)] [input (minibuffer:input prompt)]
         [default (and (string=? input "") (%read-default r))])
    (cond
      [m (choose-match! s m) (minibuffer:exit! prompt (match-answer s m))]
      [default
       (find-named! s default
         (lambda (named)
           (when named (choose-match! s named))
           (minibuffer:exit! prompt (if named (match-answer s named) default))))]
      [else (%answer-input! r input)])))

(define (%read-default r) (session-record-default (%read-state-session r)))

(define (%read who question sources h default any?)
  (unless (string? question)
    (assertion-violation who "not a string" question))
  (%check-sources who sources)
  (unless (or (not h) (saved:saved? h))
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
          (when (pair? (narrow-chars s))
            (minibuffer:add-keymap! prompt narrowing-keymap))
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

(define-record-type (%region %make-region %region?)
  (sealed #t)
  (fields (immutable start region-start) (immutable end region-end) (immutable sources region-sources)
          (immutable exclusive? %region-exclusive?) (immutable triggers region-trigger-characters)))

(define (%checked-region who start end sources exclusive? triggers)
  (unless (and (fixnum? start) (fixnum? end) (fx<= 0 start end))
    (assertion-violation who "not a start and an end" start end))
  (%check-sources who sources)
  (unless (and (list? triggers) (for-all char? triggers))
    (assertion-violation who "not a list of characters" triggers))
  (%make-region start end sources exclusive? triggers))

(define region
  (case-lambda
    [(start end sources) (region start end sources '())]
    [(start end sources triggers) (%checked-region 'completion:region start end sources #t triggers)]))

(define fallback-region
  (case-lambda
    [(start end sources) (fallback-region start end sources '())]
    [(start end sources triggers) (%checked-region 'completion:fallback-region start end sources #f triggers)]))

(define (%triggered? r doc point)
  (and (fx> point 0)
       (let ([c (document:token doc (fx- point 1))])
         (and (char? c) (memv c (region-trigger-characters r)) #t))))

(define-record-type %point-state
  (sealed #t)
  (fields session entry client start end give-way (mutable found-nothing) (mutable end-keymap)
          (mutable end-selected-keymap) (mutable tabbed)))

(define-record-type %tabbed
  (sealed #t)
  (fields buffer text exit))

(define %points '())

(define (%point-of s) (find (lambda (p) (eq? (%point-state-session p) s)) %points))

(define (%find-region entries)
  (let loop ([entries entries])
    (if (null? entries)
        (values #f #f '())
        (let ([r ((car entries))])
          (cond
            [(not r) (loop (cdr entries))]
            [(%region? r) (values r (car entries) (cdr entries))]
            [else (assertion-violation 'completion:find-region "an entry returned what is not a region or #f" r)])))))

(define (%settled? s) (and (session-record-matches s) (not (busy? s))))

(define (%found-nothing? s) (and (%settled? s) (fx= (match-list-count (session-record-matches s)) 0)))

;; Only the first answer of the sources is reported, as Emacs says "No
;; match" once for the command, not for each key typed after it.
(define (%report-first-answer! p)
  (let ([found-nothing (%point-state-found-nothing p)] [s (%point-state-session p)])
    (when (and found-nothing (%settled? s))
      (%point-state-found-nothing-set! p #f)
      (when (%found-nothing? s) (found-nothing)))))

(define (%start-from-entries view client entries minimum found-nothing)
  (let-values ([(r entry rest) (%find-region entries)])
    (and r
         (let ([point (views:point view)])
           (and (fx<= (region-start r) point (region-end r))
                (or (fx>= (fx- point (region-start r)) minimum)
                    (%triggered? r (buffers:document (views:buffer view)) point))))
         (begin
           (for-each (lambda (p) (when (eq? (session-record-view (%point-state-session p)) view)
                                   (end-session! (%point-state-session p))))
                     %points)
           (call-as-owner %self
             (lambda ()
               (let* ([b (views:buffer view)] [start (buffers:anchor b (region-start r))]
                      [end (buffers:anchor-after b (region-end r))]
                      [s (start-session! view (region-sources r)
                           (lambda () (values (buffers:anchor-position start) (buffers:anchor-position end)))
                           (lambda (s m) (end-session! s))
                           (point-preselect))]
                      [give-way (and (not (%region-exclusive? r))
                                     (lambda (found-nothing)
                                       (unless (%start-from-entries view client rest minimum found-nothing)
                                         (found-nothing))))])
                 (if (and give-way (%found-nothing? s))
                     (begin (end-session! s) (give-way found-nothing))
                     (let ([p (make-%point-state s entry client start end give-way found-nothing #f #f #f)])
                       (set! %points (cons p %points))
                       (%point-state-end-keymap-set! p
                         (keys:push-keymap! client region-keymap (lambda (found command) #t)
                                            (lambda () (end-session! s))))
                       (%sync-keymaps! s)
                       (%report-first-answer! p)
                       (when (session-record-ended? s) (%point-ended s))))
                 #t)))))))

(define start-at-point
  (case-lambda
    [(minimum) (start-at-point minimum void)]
    [(minimum found-nothing)
     (check-main-thread 'completion:start-at-point)
     (unless (and (fixnum? minimum) (fx>= minimum 0))
       (assertion-violation 'completion:start-at-point "not a count" minimum))
     (unless (procedure? found-nothing)
       (assertion-violation 'completion:start-at-point "not a procedure" found-nothing))
     (let ([view (views:current)] [client (web:current-client)])
       (and view client (%start-from-entries view client (hooks:entries find-region) minimum found-nothing)))]))

(define start-from-entry
  (case-lambda
    [(entry) (start-from-entry entry void)]
    [(entry found-nothing)
     (check-main-thread 'completion:start-from-entry)
     (unless (procedure? entry)
       (assertion-violation 'completion:start-from-entry "not a procedure" entry))
     (unless (procedure? found-nothing)
       (assertion-violation 'completion:start-from-entry "not a procedure" found-nothing))
     (let ([view (views:current)] [client (web:current-client)])
       (and view client (%start-from-entries view client (list entry) 0 found-nothing)))]))

(define (%after-update s)
  (let ([p (%point-of s)])
    (when (and p (not (session-record-ended? s)))
      (if (and (%point-state-give-way p) (%found-nothing? s))
          (let ([view (session-record-view s)] [client (%point-state-client p)]
                [found-nothing (or (%point-state-found-nothing p) void)])
            (end-session! s)
            (when (and (views:find (views:id view)) (views:buffer view))
              (parameterize ([web:current-client client])
                (views:call-with-view view (lambda () ((%point-state-give-way p) found-nothing))))))
          (%report-first-answer! p)))))

(define (%sync-keymaps! s)
  (let ([p (%point-of s)])
    (when (and p (not (session-record-ended? s)) (%point-state-end-keymap p))
      (let ([pushed (%point-state-end-selected-keymap p)])
        (cond
          [(and (session-record-selected s) (not pushed))
           (%point-state-end-selected-keymap-set! p
             (call-as-owner %self
               (lambda ()
                 (keys:push-keymap! (%point-state-client p) region-selected-keymap (lambda (found command) #t)))))]
          [(and (not (session-record-selected s)) pushed)
           (%point-state-end-selected-keymap-set! p #f)
           (pushed)])))))

;; A key that ends the session, as SPC, has already typed past the
;; region's end, so only the region's start is compared.
(define (%region-starts-with-tabbed? p)
  (let ([t (%point-state-tabbed p)])
    (and t (buffers:live? (%tabbed-buffer t))
         (let* ([doc (buffers:document (%tabbed-buffer t))] [start (buffers:anchor-position (%point-state-start p))]
                [end (fx+ start (string-length (%tabbed-text t)))])
           (and (fx<= end (document:length doc))
                (string=? (document:text doc start end) (%tabbed-text t)))))))

(define (%region-is-tabbed? p)
  (let ([t (%point-state-tabbed p)])
    (and t
         (string=? (document:text (buffers:document (%tabbed-buffer t)) (buffers:anchor-position (%point-state-start p))
                                  (buffers:anchor-position (%point-state-end p)))
                   (%tabbed-text t)))))

(define (%point-ended s)
  (let ([p (%point-of s)])
    (when p
      (set! %points (remq p %points))
      (let ([a (%point-state-end-selected-keymap p)] [b (%point-state-end-keymap p)])
        (%point-state-end-selected-keymap-set! p #f)
        (%point-state-end-keymap-set! p #f)
        (when a (a))
        (when b (b)))
      (when (%region-starts-with-tabbed? p)
        ((%tabbed-exit (%point-state-tabbed p)) 'exact)))))

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
                        (guard (c [(not (cancelled? c)) (report c) #f])
                          (views:call-with-view view (%point-state-entry p))))])
            (if (and (%region? r)
                     (fx= (region-start r) (buffers:anchor-position (%point-state-start p)))
                     (fx<= (region-start r) (views:point view) (region-end r)))
                (begin
                  (buffers:set-anchor! (%point-state-end p) (region-end r))
                  (rematch! s #f)
                  (cond
                    [(sole-match? s) (%end-sole! s)]
                    [(not (%region-is-tabbed? p)) (%point-state-tabbed-set! p #f)]))
                (end-session! s))))))
    %points))

(define (%no-match) (ask:message "No match"))

;; Taken before the session moves on: a match names nothing once its
;; source drops it.
(define (%exit-of s m)
  (let ([exit (match-exit s m)] [v (match-value s m)])
    (if exit (lambda (status) (exit v status)) %no-exit)))

(define (%no-exit status) (void))

(define (%end-sole! s)
  (let ([exit! (%exit-of s (match-list-ref (session-record-matches s) 0))])
    (%forget-tabbed! s)
    (end-session! s)
    (exit! 'finished)))

(define (%forget-tabbed! s)
  (let ([p (%point-of s)])
    (when p (%point-state-tabbed-set! p #f))))

(commands:define-command (complete-at-point)
  "Completes the text at point from the sources of completion:find-region, saying No match when they find nothing."
  (start-at-point 0 %no-match))

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
  (let* ([s (%current 'completion:exit)] [m (session-record-selected s)]
         [exit! (if (and m (%point-of s)) (%exit-of s m) %no-exit)])
    (when m (%replace-unmatched! s (query-start s m) (match-text s m)))
    (%forget-tabbed! s)
    (when m (choose-match! s m))
    ((session-record-accept s) s m)
    (exit! 'finished)))

(commands:define-command (exit-input)
  "Answers the innermost prompt with its input as typed, as completion:answer-input! does."
  (answer-input! (or (minibuffer:current-prompt) (assertion-violation 'completion:exit-input "no prompt waits"))))

(commands:define-command (complete)
  "Replaces the query with the selected match's text; with none selected, replaces the input with the longest common start of the inputs the matches make when it is longer."
  (let* ([s (%current 'completion:complete)] [m (session-record-selected s)] [p (%point-of s)]
         [tabbed (and m p (make-%tabbed (views:buffer (session-record-view s)) (match-text s m) (%exit-of s m)))])
    (if m
        (%replace! s (query-start s m) (match-text s m))
        (let-values ([(start end) ((session-record-bounds s))])
          (let ([common (common-input-start s (input-of s))])
            (when common (%replace! s start common)))))
    (rematch! s #f)
    (cond
      [(and p (sole-match? s)) (%end-sole! s)]
      [tabbed (%point-state-tabbed-set! p tabbed)])))

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

;; Titles are compared by their text, as a list draws a heading wherever
;; the text changes, so a move stops only at a heading.
(define (%group-start s matches k)
  (let ([t (match-title s (match-list-ref matches k))])
    (let loop ([k k])
      (if (and (fx> k 0) (equal? (match-title s (match-list-ref matches (fx- k 1))) t)) (loop (fx- k 1)) k))))

(define (%next-group-start s matches k)
  (let ([n (match-list-count matches)] [t (match-title s (match-list-ref matches k))])
    (let loop ([j (fx+ k 1)])
      (cond
        [(fx= j n) k]
        [(equal? (match-title s (match-list-ref matches j)) t) (loop (fx+ j 1))]
        [else j]))))

(define (%previous-group-start s matches k)
  (let ([start (%group-start s matches k)])
    (if (fx= start 0) 0 (%group-start s matches (fx- start 1)))))

(define (%move-group who n)
  (unless (fixnum? n)
    (assertion-violation who "not a count" n))
  (let* ([s (%current who)] [matches (session-matches s)] [m (session-record-selected s)]
         [k (and m (match-list-index matches m))] [step (if (fx< n 0) %previous-group-start %next-group-start)])
    (unless (fx= (match-list-count matches) 0)
      (select-match! s (match-list-ref matches
                         (if k
                             (let loop ([k k] [n (fxabs n)]) (if (fx= n 0) k (loop (step s matches k) (fx- n 1))))
                             0))))))

(commands:define-command (next-group [n (commands:prefix-number)])
  "Selects the first match of the group N after the selected match's, stopping at the last group, or N before with a negative N; with none selected, the first match."
  (%move-group 'completion:next-group n))

(commands:define-command (previous-group [n (commands:prefix-number)])
  "Selects the first match of the group N before the selected match's, stopping at the first match, or N after with a negative N; with none selected, the first match."
  (%move-group 'completion:previous-group (fx- 0 n)))

(define (%current-read who)
  (let ([r (%read-of (%current who))])
    (unless r
      (assertion-violation who "not a read"))
    r))

(commands:define-command (narrow [c (keys:typed-char)])
  "Narrows the read to its sources whose narrow character is C, keeping its input; a C no source narrows by widens."
  (unless c
    (assertion-violation 'completion:narrow "no character was typed"))
  (unless (char? c)
    (assertion-violation 'completion:narrow "not a character" c))
  (let ([s (%read-state-session (%current-read 'completion:narrow))])
    (narrow! s c)
    (combine! s)))

(commands:define-command (narrow-by-input)
  "Narrows the read to its sources whose narrow character is its input's one character, and clears the input."
  (let* ([r (%current-read 'completion:narrow-by-input)] [s (%read-state-session r)]
         [input (minibuffer:input (%read-state-prompt r))])
    (unless (and (fx= (string-length input) 1) (memv (string-ref input 0) (narrow-chars s)))
      (assertion-violation 'completion:narrow-by-input "the input is not one narrow character" input))
    (narrow! s (string-ref input 0))
    (minibuffer:set-input! (%read-state-prompt r) "")
    (combine! s)))

(commands:define-command (widen)
  "Shows the matches of every source of the read again."
  (let ([s (%read-state-session (%current-read 'completion:widen))])
    (narrow! s #f)
    (combine! s)))

;; Point is in the prompt's input, not in its list, so a region there is
;; text the user marked, which M-w saves as anywhere else.
(commands:define-command (kill-ring-save)
  "Puts the selected match's whole text on the kill ring; with none selected, the input, or the read's default when the input is empty; with a region in the session's view, runs editing:kill-ring-save."
  (let* ([s (%current 'completion:kill-ring-save)] [m (session-record-selected s)])
    (if (exists views:cursor-mark (views:cursors (session-record-view s)))
        (editing:kill-ring-save)
        (kill-ring:push!
          (list (cond
                  [m (match-whole-text s m)]
                  [(and (string=? (input-of s) "") (session-record-default s))]
                  [else (input-of s)]))))))

(define (%narrowing-keymaps client posn)
  (let* ([s (and (not posn) (current-session))] [r (and s (%read-of s))])
    (if (and r (not (session-record-ended? s)) (pair? (narrow-chars s)))
        (let ([input (minibuffer:input (%read-state-prompt r))])
          (cond
            [(and (fx= (string-length input) 1) (memv (string-ref input 0) (narrow-chars s))) (list narrow-keymap)]
            [(and (string=? input "") (session-record-narrowed s)) (list widen-keymap)]
            [else '()]))
        '())))

;; An entry is recalled by its place, as M-p recalls it, so a read-entry
;; prompt knows it was chosen rather than typed.
(commands:define-command (search-history)
  "Replaces the input of the innermost prompt with an entry of its own entries or its history, read with completion."
  (let* ([p (or (minibuffer:current-prompt) (assertion-violation 'completion:search-history "no prompt waits"))]
         [h (minibuffer:prompt-history p)]
         [entries (append (minibuffer:prompt-entries p) (if h (h) '()))])
    (when (null? entries)
      (error 'completion:search-history "History is empty"))
    (let ([k (minibuffer:call-with-setup
               (lambda (q) (minibuffer:set-input! q (minibuffer:input p)))
               (lambda ()
                 (read "History: "
                       (list (source (candidates (list->vector (map (lambda (e k) (cons e (fx+ k 1))) entries (iota (length entries))))) (in-order)))
                       #f)))])
      (minibuffer:recall! p k))))

(define (%quit) (make-cancelled #f))

(define-category choice-category "The choices of ask:choice, valued by the choice's value; an annotated choice's annotation is its details.")

(define (%read-choice question choices)
  (read question (list (source (candidates (list->vector choices)) (category choice-category) (in-order)))))

(define (%choice-annotator session)
  (lambda (value annotation)
    (if annotation (list (cons faces:shadow annotation)) '())))

;; A stream's receiver must return at once, and the procedure may pause,
;; as one asking a server does.
(define (%asked-candidates ask)
  (lambda (emit)
    (let ([asking #f])
      (define (stop!)
        (when asking
          (unless (eq? (task-state asking) 'done) (cancel-task asking))
          (set! asking #f)))
      (lambda (input)
        (stop!)
        (unless (eof-object? input)
          (let ([task #f])
            (set! task
              (spawn-task
                (lambda (restore)
                  (let ([found (guard (c [(cancelled? c) #f] [else (report c) '()])
                                 (let ([found (ask input)])
                                   (unless (and (list? found) (for-all string? found))
                                     (assertion-violation 'ask:line-with-candidates "not a list of strings" found))
                                   found))])
                    (when (and found (eq? asking task))
                      (set! asking #f)
                      (emit 'clear)
                      (emit '(base 0))
                      (emit (list->vector found))
                      (emit 'done))))))
            (set! asking task)))))))

;; The procedure has already chosen and ordered its candidates by its
;; own rule, as a server's symbol search does.
(define (%match-all query) '())

(define (%read-line-with-candidates question offered default)
  (read-or-input question
    (list (if (procedure? offered)
              (source (stream (%asked-candidates offered)) (split string-length) (in-order) (styles (list %match-all)))
              (source (candidates (list->vector offered)))))
    minibuffer:history default))

(define (%text-target category buffer start end)
  (let ([text (document:text (buffers:document buffer) start end)])
    (make-target category text text start end)))

(define (%region-target view)
  (let ([point (views:point view)] [mark (views:mark view)])
    (and mark (not (fx= mark point))
         (%text-target region-category (views:buffer view) (fxmin point mark) (fxmax point mark)))))

(define (%url-target view)
  (let ([buffer (views:buffer view)])
    (let-values ([(start end) (browse-url:url-at buffer (views:point view))])
      (and start (%text-target url-category buffer start end)))))

(define (%identifier-target view)
  (let ([buffer (views:buffer view)])
    (let-values ([(start end) (syntax:symbol-bounds buffer (views:point view))])
      (and start (%text-target identifier-category buffer start end)))))

;; syntax raises for a mode with no lexer, where nothing is a form.
(define (%lexed-buffer view)
  (let ([buffer (views:buffer view)])
    (and (syntax:lexer (modes:major-mode buffer)) buffer)))

;; syntax:top-level-form also answers with the next form when point is
;; between forms.
(define (%form-around buffer point)
  (let-values ([(start end) (syntax:top-level-form buffer point)])
    (and start (fx<= start point end) (cons start end))))

(define (%lexeme-covering buffer position)
  (and (fx<= 0 position) (fx< position (document:length (buffers:document buffer)))
       (let ([found (syntax:lexemes buffer position (fx+ position 1))])
         (and (pair? found) (car found)))))

;; As Emacs's scan-sexps fails on a list left open, a list with no closing
;; bracket is no expression. Depths count from the forms one answer of
;; syntax:lexemes read, so both brackets come from the same answer.
(define (%closed-list buffer start end)
  (let* ([lexemes (syntax:lexemes buffer start end)]
         [open (find (lambda (l) (eq? (syntax:lexeme-class l) (syntax:class open))) lexemes)]
         [close (and (pair? lexemes) (car (last-pair lexemes)))])
    (and (or (not open)
             (and (eq? (syntax:lexeme-class close) (syntax:class close))
                  (fx= (syntax:lexeme-end close) end)
                  (fx= (syntax:lexeme-depth close) (syntax:lexeme-depth open))))
         (cons start end))))

(define (%expression-bounds buffer point)
  (define (of-class l class) (and l (eq? (syntax:lexeme-class l) class) l))
  (let ([at (%lexeme-covering buffer point)] [before (%lexeme-covering buffer (fx- point 1))])
    (cond
      [(or (of-class at (syntax:class string))
           (let ([l (of-class before (syntax:class string))]) (and l (fx= (syntax:lexeme-end l) point) l)))
       => (lambda (l) (and (not (syntax:lexeme-open-ended? l)) (cons (syntax:lexeme-start l) (syntax:lexeme-end l))))]
      [(and at (fx= (syntax:lexeme-start at) point)
            (memq (syntax:lexeme-class at) (list (syntax:class open) (syntax:class prefix))))
       (let ([end (syntax:sexp-after buffer point)])
         (and end (%closed-list buffer point end)))]
      [(let ([l (of-class before (syntax:class close))]) (and l (fx= (syntax:lexeme-end l) point)))
       (let ([start (syntax:sexp-before buffer point)])
         (and start (%closed-list buffer start point)))]
      [else
       (let ([openings (syntax:openings buffer point)])
         (and (pair? openings)
              (let* ([start (syntax:lexeme-start (list-ref openings (fx- (length openings) 1)))]
                     [end (syntax:sexp-after buffer start)])
                (and end (%closed-list buffer start end)))))])))

;; What starts where the top-level form does is that form, which its own
;; finder gives.
(define (%expression-target view)
  (let ([buffer (%lexed-buffer view)])
    (and buffer
         (let* ([point (views:point view)] [found (%expression-bounds buffer point)])
           (and found
                (let ([form (%form-around buffer point)])
                  (not (and form (fx= (car form) (car found)))))
                (%text-target expression-category buffer (car found) (cdr found)))))))

(define (%top-level-form-target view)
  (let ([buffer (%lexed-buffer view)])
    (and buffer
         (let ([form (%form-around buffer (views:point view))])
           (and form (%text-target top-level-form-category buffer (car form) (cdr form)))))))

(define (%unload)
  (for-each (lambda (r) (cancel-task (%read-state-task r))) %reads)
  (for-each end-session! sessions)
  (end-preview-place))

(tables:set! any-order-dispatch #\! %dispatch-not)
(tables:set! any-order-dispatch #\= %dispatch-literal)
(tables:set! any-order-dispatch #\^ %dispatch-starts)
(tables:set! any-order-dispatch #\~ %dispatch-flex)
(tables:set! any-order-dispatch #\$ %dispatch-ends)
(tables:set! category-default-styles buffer-category (list prefix substring))
(tables:set! category-default-styles location-category (list substring))
(tables:set! category-default-styles name-category (list prefix substring))
(tables:set! category-default-styles identifier-category (list prefix substring))
;; Every command's name starts with its plugin's name, so matching only at
;; the start would not find a command by the word it is known by.
(tables:set! category-default-styles command-category (list prefix substring))
(tables:set! action-keymaps buffer-category (list buffer-action-keymap))
(tables:set! action-keymaps command-category (list command-action-keymap))
(tables:set! action-keymaps file-category (list file-action-keymap))
(tables:set! action-keymaps location-category (list location-action-keymap))
(tables:set! action-keymaps name-category (list name-action-keymap identifier-action-keymap))
(tables:set! action-keymaps identifier-category (list identifier-action-keymap))
(tables:set! action-keymaps url-category (list url-action-keymap))
(tables:set! action-keymaps region-category (list region-action-keymap))
(tables:set! action-keymaps expression-category (list expression-action-keymap))
(tables:set! action-keymaps top-level-form-category (list top-level-form-action-keymap expression-action-keymap))
(tables:set! web:stylesheets 'completion "completion/completion.css")
(options:set! ask:choice-reader %read-choice)
(tables:set! annotators choice-category %choice-annotator)
(options:set! ask:line-with-candidates-reader %read-line-with-candidates)
(keys:bind! minibuffer:keymap "M-r" search-history)
(keys:bind! minibuffer:keymap "M-s" search-history)
(keys:bind! keymap "RET" exit)
(keys:bind! keymap "M-RET" exit-input)
(keys:bind! keymap "TAB" complete)
(keys:bind! region-keymap "TAB" complete)
(keys:bind! region-selected-keymap "RET" exit)
(keys:bind! narrow-keymap "SPC" narrow-by-input)
(keys:bind! widen-keymap "DEL" widen)
(keys:bind! narrow-key-keymap "<printing-char>" narrow)
(keys:bind! keys:global "C-M-i" complete-at-point)
(keys:bind! keys:global "M-TAB" complete-at-point)
;; Exit, complete and the moves stay offered everywhere: they also act on
;; a session that start runs over a field in any view. M-x cannot reach a
;; session at point, since its own prompt ends that session.
(tables:set! commands:command-modes exit-input (list minibuffer:mode))
(tables:set! commands:command-modes search-history (list minibuffer:mode))
(tables:set! commands:command-modes narrow (list minibuffer:mode))
(tables:set! commands:command-modes narrow-by-input (list minibuffer:mode))
(tables:set! commands:command-modes widen (list minibuffer:mode))
(tables:set! commands:region-commands kill-ring-save #t)
(hooks:add! minibuffer:input-changed %prompt-input-changed)
(hooks:add! minibuffer:prompt-started %prompt-input-changed)
(hooks:add! minibuffer:prompt-ended %prompt-ended)
(hooks:add! updated %sync-keymaps!)
(hooks:add! updated %after-update)
;; Ahead of the prompt's own keymaps, which hold completion:keymap.
(hooks:add! keys:find-keymaps %narrowing-keymaps 30)
(hooks:add! ended %point-ended)
(hooks:add! commands:after-command %continue-at-point)
(hooks:add! target-finders %region-target -40)
(hooks:add! target-finders %url-target -30)
(hooks:add! target-finders %identifier-target 20)
(hooks:add! target-finders %expression-target 30)
(hooks:add! target-finders %top-level-form-target 60)
(on-unload %unload)
