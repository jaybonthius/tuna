#!tuna
;; This plugin's substring is a style, so Chez's goes by another name.
(import (minibuffer) (buffers) (document) (views) (layout) (keys) (commands) (jobs) (web) (completion matcher)
        (rename (only (chezscheme) substring) (substring string-part)))

(define-hook started "Called with a session when it starts, before its first matches.")

(define-hook updated "Called with a session after its matches or its selection change.")

(define-hook ended "Called with a session after it ends.")

(define-hook find-region
  "Its entries take no arguments and return a region for point in the current view, or #f.")

(define-table category-styles "Maps a category to the styles used in place of completion:styles.")

(define-table category-prefers-input
  "Maps a category to a predicate of a session's input; while it holds for a category of the session's sources, new matches select none, so RET acts as with nothing selected: completion:read-or-input answers with the input.")

(define-table annotators "Maps a category to a procedure of a session that returns its annotator.")

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

(define-record-type (%source %make-source source?)
  (sealed #t)
  (fields candidates worker input category title split in-order? rank preview))

(define (%check-source candidates worker input category title split in-order? rank preview)
  (define who 'completion:source)
  (unless (or (procedure? candidates) (%candidates? candidates))
    (assertion-violation who "neither a vector of candidates nor a procedure" candidates))
  (unless (or (not worker) (jobs:worker? worker))
    (assertion-violation who "not a worker" worker))
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
  (%make-source candidates worker input category title split in-order? rank preview))

(define (%candidate? c) (or (string? c) (and (pair? c) (string? (car c)))))

(define (%candidates? v)
  (and (vector? v)
       (let loop ([i 0]) (or (fx= i (vector-length v)) (and (%candidate? (vector-ref v i)) (loop (fx+ i 1)))))))

(define-syntax source
  (lambda (x)
    (define (invalid c) (syntax-violation 'completion:source "invalid clause" x c))
    (syntax-case x ()
      [(_ clause ...)
       (let loop ([clauses #'(clause ...)] [seen '()] [candidates #f] [worker #f] [input #f]
                  [category #'#f] [title #'#f] [split #'#f] [in-order #'#f] [rank #'#f] [preview #'#f])
         (if (null? clauses)
             (begin
               (unless (or candidates worker)
                 (syntax-violation 'completion:source "a candidates or job clause is required" x))
               (when (and candidates worker)
                 (syntax-violation 'completion:source "both a candidates and a job clause" x))
               #`(%check-source #,(or candidates #'(vector)) #,(or worker #'#f) #,(or input #'#f)
                                #,category #,title #,split #,in-order #,rank #,preview))
             (let* ([c (car clauses)] [rest (cdr clauses)]
                    [name (syntax-case c () [(k . _) (identifier? #'k) (syntax->datum #'k)] [_ (invalid c)])])
               (when (memq name seen)
                 (syntax-violation 'completion:source "clause given twice" x c))
               (let ([seen (cons name seen)])
                 (define (one) (syntax-case c () [(_ e) #'e] [_ (invalid c)]))
                 (case name
                   [(candidates) (loop rest seen (one) worker input category title split in-order rank preview)]
                   [(job) (syntax-case c ()
                            [(_ w i) (loop rest seen candidates #'w #'i category title split in-order rank preview)]
                            [_ (invalid c)])]
                   [(category) (loop rest seen candidates worker input (one) title split in-order rank preview)]
                   [(title) (loop rest seen candidates worker input category (one) split in-order rank preview)]
                   [(split) (loop rest seen candidates worker input category title (one) in-order rank preview)]
                   [(in-order) (syntax-case c ()
                                 [(_) (loop rest seen candidates worker input category title split #'#t rank preview)]
                                 [_ (invalid c)])]
                   [(rank) (loop rest seen candidates worker input category title split in-order (one) preview)]
                   [(preview) (loop rest seen candidates worker input category title split in-order rank (one))]
                   [else (invalid c)])))))])))

(define (prefix query) (if (string=? query "") '() (list (list 'starts query))))

(define (substring query) (if (string=? query "") '() (list (list 'contains query))))

(define (partial query) (partial-pattern query))

(define (flex query)
  (if (string=? query "") '() (list (cons 'contains (map string (string->list query))))))

(define (%components query)
  (let loop ([cs (string->list query)] [current '()] [acc '()])
    (define (finish) (if (null? current) acc (cons (list->string (reverse current)) acc)))
    (cond
      [(null? cs) (reverse (finish))]
      [(and (char=? (car cs) #\\) (pair? (cdr cs)) (char=? (cadr cs) #\space))
       (loop (cddr cs) (cons #\space current) acc)]
      [(char=? (car cs) #\space) (loop (cdr cs) '() (finish))]
      [else (loop (cdr cs) (cons (car cs) current) acc)])))

(define (any-order query)
  (fold-right
    (lambda (component terms)
      (let* ([n (string-length component)]
             [first (table-ref any-order-dispatch (string-ref component 0) #f)]
             [last (and (fx> n 1) (table-ref any-order-dispatch (string-ref component (fx- n 1)) #f))]
             [term (cond
                     [(and first (fx> n 1)) (first (string-part component 1 n))]
                     [last (last (string-part component 0 (fx- n 1)))]
                     [(or first (and (fx= n 1) (table-ref any-order-dispatch (string-ref component 0) #f))) #f]
                     [else (list 'contains component)])])
        (if term (cons term terms) terms)))
    '()
    (%components query)))

(define (%dispatch-not rest) (let ([t (any-order rest)]) (and (pair? t) (list 'not (car t)))))
(define (%dispatch-literal rest) (list 'contains rest))
(define (%dispatch-starts rest) (list 'starts rest))
(define (%dispatch-flex rest) (cons 'contains (map string (string->list rest))))
(define (%dispatch-ends rest) (list 'ends rest))

(define-option styles (list any-order) (lambda (v) (and (list? v) (for-all procedure? v)))
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
(define %inline-characters 50000)

(module %internals
  (check-main-thread check-session session? make-session session-record-view session-record-ended?
   session-record-matches session-record-selected session-record-input session-record-bounds session-record-count
   session-record-states session-record-accept session-record-default sessions start-session! end-session!
   rematch! select-match! match-text match-value match-title match-spans match-annotation
   busy? query-start named-match common-start state-source lead-length vector-index)

  (define main-thread (get-thread-id))

  (define (check-main-thread who)
    (unless (fx= (get-thread-id) main-thread)
      (assertion-violation who "not on the main thread")))

  (define-record-type (session-record make-session session?)
    (sealed #t)
    (fields view (mutable states) bounds accept preselect history default
            (mutable texts) (mutable vals) (mutable owners) (mutable live) (mutable count)
            (mutable input) (mutable matches) (mutable selected) (mutable locked?) (mutable ended?)
            (mutable inline?) (mutable annotators) annotations (mutable next-id) history-ranks (mutable dirty?)))

  (define-record-type state
    (sealed #t)
    (fields source styles (mutable globals) (mutable count) (mutable texts) (mutable ranks)
            (mutable prefix) (mutable candidate-job) (mutable match-job) (mutable pending)
            (mutable done?) (mutable matches) (mutable pattern) (mutable style) (mutable query) (mutable base)
            (mutable more?)))

  (define (check-session who s)
    (unless (session? s)
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
    (let ([c (%source-category source)])
      (or (and c (table-ref category-styles c #f)) (styles))))

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
    (let* ([k (vector-length cands)] [texts (make-vector k)] [ranks (make-vector k)] [base (state-count st)]
           [g0 (session-record-count s)] [end (fx+ g0 k)])
      (session-record-texts-set! s (grow (session-record-texts s) end ""))
      (session-record-vals-set! s (grow (session-record-vals s) end #f))
      (session-record-owners-set! s (grow (session-record-owners s) end #f))
      (session-record-live-set! s (grow (session-record-live s) end #f))
      (state-globals-set! st (grow (state-globals st) (fx+ base k) 0))
      (let ([all-texts (session-record-texts s)] [vals (session-record-vals s)] [owners (session-record-owners s)]
            [live (session-record-live s)] [globals (state-globals st)] [rank-of (ranker s st given)])
        (do ([i 0 (fx+ i 1)]) ((fx= i k))
          (let* ([c (vector-ref cands i)] [text (candidate-text c)] [g (fx+ g0 i)])
            (vector-set! all-texts g text)
            (vector-set! vals g (candidate-value c))
            (vector-set! owners g st)
            (vector-set! live g #t)
            (vector-set! globals (fx+ base i) g)
            (vector-set! texts i text)
            (vector-set! ranks i (rank-of i text)))))
      (session-record-count-set! s end)
      (state-count-set! st (fx+ base k))
      (if (fx= base 0)
          (begin (state-texts-set! st texts) (state-ranks-set! st ranks))
          (begin
            (state-texts-set! st (append-at (state-texts st) base texts ""))
            (state-ranks-set! st (append-at (state-ranks st) base ranks 0))))
      (values texts ranks)))

  ;; A job source may emit thousands of times, a few candidates each, so
  ;; its texts and ranks grow by doubling, not by a copy per emission;
  ;; only the first state-count entries are candidates.
  (define (append-at v n w fill)
    (let ([v (grow v (fx+ n (vector-length w)) fill)])
      (vector-copy! w 0 v n (vector-length w))
      v))

  (define (trim-candidates! st)
    (let ([n (state-count st)])
      (unless (fx= (vector-length (state-texts st)) n)
        (state-texts-set! st (vector-copy (state-texts st) 0 n))
        (state-ranks-set! st (vector-copy (state-ranks st) 0 n)))))

  (define (retire-locals! s st)
    (do ([i 0 (fx+ i 1)]) ((fx= i (state-count st)))
      (vector-set! (session-record-live s) (vector-ref (state-globals st) i) #f)))

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
          (trim-candidates! st)
          (unless (fx= (state-count st) 0)
            (jobs:send! job (list 'add (jobs:freeze (state-texts st)) (state-ranks st))))
          (when (state-done? st) (jobs:send! job '(sort)))
          job)))

  (define (stop-match-job! st)
    (let ([job (state-match-job st)])
      (when job
        (jobs:stop! job)
        (state-match-job-set! st #f)
        (state-pending-set! st #f)
        (state-more?-set! st #f))))

  (define (refresh-candidates! s st prefix)
    (let ([proc (%source-candidates (state-source st))])
      (retire-locals! s st)
      (stop-match-job! st)
      (set-state-matches! s st (vector))
      (state-globals-set! st (vector))
      (state-count-set! st 0)
      (state-texts-set! st (vector))
      (state-ranks-set! st (vector))
      (let ([v (proc prefix)])
        (check-candidates 'completion:source v)
        (add-candidates! s st v #f))))

  (define (decide-inline! s)
    (let loop ([sts (session-record-states s)] [n 0] [chars 0])
      (cond
        [(null? sts)
         (session-record-inline?-set! s #t)]
        [(%source-worker (state-source (car sts))) (session-record-inline?-set! s #f)]
        [else
         (let* ([texts (state-texts (car sts))] [k (state-count (car sts))] [n (fx+ n k)])
           (if (fx> n %inline-candidates)
               (session-record-inline?-set! s #f)
               (let ([chars (let sum ([i 0] [c chars])
                              (if (fx= i k) c (sum (fx+ i 1) (fx+ c (string-length (vector-ref texts i))))))])
                 (if (fx> chars %inline-characters)
                     (session-record-inline?-set! s #f)
                     (loop (cdr sts) n chars)))))]))
    (if (session-record-inline? s)
        (for-each stop-match-job! (session-record-states s))
        (for-each (lambda (st) (match-job-of s st)) (session-record-states s))))

  (define (check-pattern style pattern)
    (unless (pattern? pattern)
      (assertion-violation 'completion:styles "a style returned what is not a pattern" style pattern))
    pattern)

  (define (pattern-of st k)
    (let ([style (list-ref (state-styles st) k)])
      (check-pattern style (style (state-query st)))))

  (define (to-globals st locals)
    (let ([g (state-globals st)])
      (vector-map (lambda (i) (vector-ref g i)) locals)))

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
                (set-state-matches! s st (to-globals st locals))))))))

  (define (send-match! s st k)
    (let ([id (session-record-next-id s)] [pattern (pattern-of st k)])
      (session-record-next-id-set! s (fx+ id 1))
      (state-style-set! st k)
      (state-pending-set! st id)
      (state-more?-set! st #f)
      (state-pattern-set! st pattern)
      (jobs:send! (match-job-of s st) (list 'match id pattern))))

  (define (match-arrived! s st result)
    (unless (session-record-ended? s)
      (let ([id (car result)] [done? (cadr result)] [locals (cddr result)])
        (when (eqv? id (state-pending st))
          (cond
            [(and done? (state-more? st))
             (set-state-matches! s st (to-globals st locals))
             (send-match! s st 0)
             (combine! s)]
            [(and done? (fx= (vector-length locals) 0) (fx< (fx+ (state-style st) 1) (length (state-styles st))))
             (send-match! s st (fx+ (state-style st) 1))]
            [else
             (when done? (state-pending-set! st #f))
             (set-state-matches! s st (to-globals st locals))
             (combine! s)])))))

  ;; Each match walks all of a source's candidates, and a job source may
  ;; emit thousands of times; candidates that come while a match is under
  ;; way wait for its end, so matching keeps pace with the matcher, not
  ;; with the emissions.
  (define (request-match! s st)
    (if (state-pending st)
        (state-more?-set! st #t)
        (send-match! s st 0)))

  (define (candidates-arrived! s st v)
    (unless (session-record-ended? s)
      (cond
        [(and (pair? v) (eq? (car v) 'base))
         (unless (and (pair? (cdr v)) (fixnum? (cadr v)) (fx>= (cadr v) 0))
           (assertion-violation 'completion:source "a job emitted a base that is not a length" v))
         (state-base-set! st (cadr v))
         (update-query! s st)]
        [(eq? v 'clear)
         (state-base-set! st #f)
         (update-query! s st)
         (retire-locals! s st)
         (let ([job (state-match-job st)] [k (state-count st)])
           (when job
             (jobs:send! job (list 'retire (let ([r (make-vector k)]) (do ([i 0 (fx+ i 1)]) ((fx= i k) r) (vector-set! r i i)))))))
         (set-state-matches! s st (vector))]
        [else
         (let-values ([(cands given) (if (pair? v) (values (car v) (cdr v)) (values v #f))])
           (check-candidates 'completion:source cands)
           (let-values ([(texts ranks) (add-candidates! s st cands given)])
             (jobs:send! (match-job-of s st) (list 'add (jobs:freeze texts) ranks))))])
      (request-match! s st)
      (when (session-record-dirty? s) (combine! s))))

  (define (candidates-ended! s st how)
    (unless (session-record-ended? s)
      (state-done?-set! st #t)
      (state-candidate-job-set! st #f)
      (let ([job (state-match-job st)])
        (when job
          (jobs:send! job '(sort))
          (send-match! s st 0)))
      (combine! s)))

  (define (start-candidate-job! s st)
    (let ([source (state-source st)])
      (state-done?-set! st #f)
      (state-candidate-job-set! st
        (as-module (this-module)
          (jobs:start (%source-worker source) (%source-input source)
            (lambda (v) (candidates-arrived! s st v))
            (lambda (how) (candidates-ended! s st how)))))))

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
                (when new-prefix?
                  (state-prefix-set! st prefix)
                  (cond
                    [(procedure? (%source-candidates source))
                     (refresh-candidates! s st prefix)
                     (set! refreshed? #t)]
                    [(%source-worker source)
                     (unless (state-candidate-job st) (start-candidate-job! s st))
                     (jobs:send! (state-candidate-job st) prefix)]))
                (update-query! s st)))
            (session-record-states s))
          (when (or refreshed? (not (session-record-matches s))) (decide-inline! s))
          (for-each
            (lambda (st) (if (session-record-inline? s) (match-inline! s st) (send-match! s st 0)))
            (session-record-states s))
          (combine! s)))))

  (define (preview! st v)
    (let ([preview (%source-preview (state-source st))])
      (when preview (preview v))))

  (define (owner-of s m) (and m (vector-ref (session-record-owners s) m)))

  (define (set-selected! s m)
    (let ([old (session-record-selected s)])
      (unless (eqv? old m)
        (session-record-selected-set! s m)
        (let ([was (owner-of s old)] [now (owner-of s m)])
          (when (and was (not (eq? was now))) (preview! was #f))
          (when now (preview! now (vector-ref (session-record-vals s) m)))))))

  (define (prefers-input? s)
    (let ([input (session-record-input s)])
      (exists (lambda (st)
                (let* ([c (%source-category (state-source st))]
                       [prefers? (and c (table-ref category-prefers-input c #f))])
                  (and prefers?
                       (guard (e [(not (quit-condition? e)) (report e) #f]) (prefers? input)))))
              (session-record-states s))))

  (define (vector-index m v)
    (let loop ([i 0])
      (and (fx< i (vector-length v)) (if (eqv? (vector-ref v i) m) i (loop (fx+ i 1))))))

  ;; Only new matches rebuild the session's vector and select again, so a
  ;; selection cleared while a job matches stays clear until they come.
  (define (combine! s)
    (when (session-record-dirty? s)
      (session-record-dirty?-set! s #f)
      (let ([matches (let ([sts (session-record-states s)])
                       (if (and (pair? sts) (null? (cdr sts)))
                           (state-matches (car sts))
                           (apply vector-append (map state-matches sts))))])
        (session-record-matches-set! s matches)
        (let ([sel (session-record-selected s)])
          (unless (and sel (session-record-locked? s) (vector-index sel matches))
            (session-record-locked?-set! s #f)
            (set-selected! s (and (eq? (session-record-preselect s) 'first) (fx> (vector-length matches) 0)
                                  (not (prefers-input? s))
                                  (vector-ref matches 0)))))))
    (updated s))

  (define (set-state-matches! s st matches)
    (state-matches-set! st matches)
    (session-record-dirty?-set! s #t))

  (define (select-match! s m)
    (set-selected! s m)
    (session-record-locked?-set! s #t)
    (updated s))

  (define (start-session! view sources bounds accept preselect h default)
    (let ([s (make-session view '() bounds accept preselect h default (vector) (vector) (vector) (vector) 0
                           #f #f #f #f #f #t '() (make-eqv-hashtable) 0 (history-ranks h default) #t)])
      (session-record-states-set! s
        (map (lambda (source)
               (make-state source (styles-for source) (vector) 0 (vector) (vector) #f #f #f #f #t (vector) '() 0 "" #f #f))
             sources))
      (for-each
        (lambda (st)
          (let ([c (%source-candidates (state-source st))])
            (when (and (vector? c) (not (%source-worker (state-source st))))
              (add-candidates! s st c #f))))
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
      (rematch! s #t)
      s))

  (define (end-session! s)
    (unless (session-record-ended? s)
      (session-record-ended?-set! s #t)
      (set! sessions (remq s sessions))
      (for-each
        (lambda (st)
          (stop-match-job! st)
          (let ([job (state-candidate-job st)])
            (when job (jobs:stop! job) (state-candidate-job-set! st #f))))
        (session-record-states s))
      (for-each (lambda (st) (preview! st #f)) (session-record-states s))
      (ended s)))

  (define (match-text s m) (vector-ref (session-record-texts s) m))
  (define (match-value s m) (vector-ref (session-record-vals s) m))
  (define (match-title s m) (%source-title (state-source (owner-of s m))))

  (define (match-spans s m)
    (let ([st (owner-of s m)])
      ((%matcher-spans (matcher)) (state-pattern st) (match-text s m))))

  (define (match-annotation s m)
    (let ([cache (session-record-annotations s)])
      (or (hashtable-ref cache m #f)
          (let* ([c (%source-category (state-source (owner-of s m)))]
                 [a (and c (assq c (session-record-annotators s)))]
                 [columns (if (and a (cdr a))
                              (guard (e [(not (quit-condition? e)) (report e) '()])
                                ((cdr a) (match-value s m)))
                              '())])
            (hashtable-set! cache m columns)
            columns))))

  (define (busy? s)
    (exists (lambda (st) (or (state-pending st) (state-candidate-job st))) (session-record-states s)))

  (define (query-start s m)
    (let-values ([(start end) ((session-record-bounds s))])
      (let ([st (or (owner-of s m) (car (session-record-states s)))])
        (fx+ start (lead-length st)))))

  (define (named-match s text)
    (let loop ([g 0])
      (and (fx< g (session-record-count s))
           (if (and (vector-ref (session-record-live s) g)
                    (let ([st (vector-ref (session-record-owners s) g)])
                      (string=? (string-append (lead st) (vector-ref (session-record-texts s) g)) text)))
               g
               (loop (fx+ g 1))))))

  (define (common-start s)
    (let ([matches (session-record-matches s)])
      (and (fx> (vector-length matches) 0)
           (let loop ([i 1] [common (match-text s (vector-ref matches 0))])
             (if (fx= i (vector-length matches))
                 common
                 (let* ([t (match-text s (vector-ref matches i))]
                        [n (let scan ([k 0])
                             (if (and (fx< k (string-length common)) (fx< k (string-length t))
                                      (char=? (string-ref common k) (string-ref t k)))
                                 (scan (fx+ k 1))
                                 k))])
                   (loop (fx+ i 1) (string-part common 0 n)))))))))

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
  (start-session! view sources bounds accept preselect #f #f))

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

(define (session-start s)
  (check-session 'completion:session-start s)
  (let-values ([(start end) ((session-record-bounds s))]) start))

(define (session-input s)
  (check-session 'completion:session-input s)
  (or (session-record-input s) ""))

(define (session-matches s)
  (check-session 'completion:session-matches s)
  (or (session-record-matches s) (vector)))

(define (session-busy? s)
  (check-session 'completion:session-busy? s)
  (and (not (session-record-ended? s)) (busy? s)))

(define (%check-match who s m)
  (check-session who s)
  (unless (and (fixnum? m) (fx< -1 m (session-record-count s)))
    (assertion-violation who "not a match of the session" m)))

(define (text s m) (%check-match 'completion:text s m) (match-text s m))

(define (value s m) (%check-match 'completion:value s m) (match-value s m))

(define (title s m) (%check-match 'completion:title s m) (match-title s m))

(define (spans s m) (%check-match 'completion:spans s m) (match-spans s m))

(define (annotation s m) (%check-match 'completion:annotation s m) (match-annotation s m))

(define (selected s)
  (check-session 'completion:selected s)
  (session-record-selected s))

(define (select! s m)
  (check-session 'completion:select! s)
  (check-main-thread 'completion:select!)
  (unless (or (not m) (and (fixnum? m) (vector-index m (session-matches s))))
    (assertion-violation 'completion:select! "not one of the matches" m))
  (select-match! s m))

(define-record-type %read-state
  (sealed #t)
  (fields session prompt task any?))

(define %reads '())

(define (%read-of s) (find (lambda (r) (eq? (%read-state-session r) s)) %reads))

(define (%read-of-prompt p) (find (lambda (r) (eq? (%read-state-prompt r) p)) %reads))

(define (%answer! s m)
  (let* ([r (%read-of s)] [prompt (%read-state-prompt r)] [input (minibuffer:input prompt)]
         [default (and (string=? input "") (%read-default r))])
    (cond
      [m (minibuffer:exit! prompt (match-value s m))]
      [default
       (let ([named (named-match s default)])
         (minibuffer:exit! prompt (if named (match-value s named) default)))]
      [(named-match s input) => (lambda (named) (minibuffer:exit! prompt (match-value s named)))]
      [(%read-state-any? r) (minibuffer:exit! prompt input)]
      [else (minibuffer:message! prompt "No match")])))

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
        (let ([s (start-session! (minibuffer:prompt-view prompt) sources
                   (lambda () (values (minibuffer:input-start prompt) (minibuffer:input-end prompt)))
                   %answer! (read-preselect) h default)])
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

(define (start-at-point client minimum)
  (check-main-thread 'completion:start-at-point)
  (unless (and (fixnum? minimum) (fx>= minimum 0))
    (assertion-violation 'completion:start-at-point "not a count" minimum))
  (let ([view (views:current)])
    (and view
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
                                (point-preselect) #f #f)]
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

(define (%sole-match? s)
  (let ([matches (session-record-matches s)])
    (and matches (fx= (vector-length matches) 1)
         (string=? (match-text s (vector-ref matches 0))
                   (let ([input (session-record-input s)] [st (car (session-record-states s))])
                     (string-part input (fxmin (string-length input) (lead-length st)) (string-length input)))))))

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
                  (when (%sole-match? s) (end-session! s)))
                (end-session! s))))))
    %points))

(commands:define-command (complete-at-point)
  "Completes the text at point from the sources of completion:find-region."
  (start-at-point (web:current-client) 0))

(define (%current who)
  (or (current-session) (assertion-violation who "no completion session in the selected view")))

(define (%replace-query! s m text)
  (let-values ([(start end) ((session-record-bounds s))])
    (let ([from (query-start s m)] [b (views:buffer (session-record-view s))])
      (unless (string=? (document:text (buffers:document b) from end) text)
        (buffers:replace! b from end text)
        (views:set-point! (session-record-view s) (fx+ from (string-length text))))
      (rematch! s #f))))

(commands:define-command (exit)
  "Makes the query the selected match's text and accepts the match; with none selected, accepts none."
  (let* ([s (%current 'completion:exit)] [m (session-record-selected s)])
    (when m (%replace-query! s m (match-text s m)))
    ((session-record-accept s) s m)))

(commands:define-command (exit-input)
  "Answers the read with its input as typed, when it names a candidate or the read takes any input."
  (let* ([s (%current 'completion:exit-input)] [r (%read-of s)])
    (unless r
      (assertion-violation 'completion:exit-input "not a read" s))
    (let* ([prompt (%read-state-prompt r)] [input (minibuffer:input prompt)] [named (named-match s input)])
      (cond
        [named (minibuffer:exit! prompt (match-value s named))]
        [(%read-state-any? r) (minibuffer:exit! prompt input)]
        [else (minibuffer:message! prompt "No match")]))))

(commands:define-command (complete)
  "Replaces the query with the selected match's text, or with the longest common start of the matches."
  (let* ([s (%current 'completion:complete)] [m (session-record-selected s)])
    (if m
        (%replace-query! s m (match-text s m))
        (let ([common (common-start s)])
          (when common
            (let-values ([(start end) ((session-record-bounds s))])
              (when (fx> (string-length common) (fx- end (query-start s #f)))
                (%replace-query! s #f common))))))
    (let ([p (%point-of s)])
      (when (and p (%sole-match? s)) (end-session! s)))))

(define (%move who to)
  (let* ([s (%current who)] [matches (session-matches s)] [n (vector-length matches)] [m (session-record-selected s)]
         [k (and m (vector-index m matches))])
    (unless (fx= n 0)
      (select-match! s (vector-ref matches (fxmax 0 (fxmin (fx- n 1) (to k n))))))))

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
(add-hook! minibuffer:prompt-ended %prompt-ended)
(add-hook! updated %sync-keymaps!)
(add-hook! ended %point-ended)
(add-hook! commands:after-command %continue-at-point)
(on-unload %unload)
