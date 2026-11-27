#!tuna
(import (search) (buffers) (document) (views) (keys) (commands) (editing) (syntax) (kill-ring) (minibuffer)
        (jump-history) (faces) (web) (hooks) (options) (tables) (timers))

(define %self (current-owner))

(options:define-option default-style search:literal search:style?
  "The style C-s and C-r start with.")

(options:define-option lazy-highlight 'selected (lambda (v) (memq v '(none selected all)))
  "Where a search highlights its matches other than the current one: none, selected or all.")

(options:define-option lazy-highlight-delay 0.25 (lambda (v) (and (real? v) (>= v 0)))
  "Seconds without a change before a search shorter than isearch:lazy-highlight-no-delay-length characters highlights its other matches.")

(options:define-option lazy-highlight-no-delay-length 3 (lambda (v) (and (fixnum? v) (fx>= v 0)))
  "The length from which a search highlights at once.")

(options:define-option lazy-highlight-cleanup #t boolean?
  "Whether a search's highlights go when it ends; off, they stay in its view until the next search there or isearch:clear-highlights.")

(options:define-option lazy-count #f boolean?
  "Whether the prompt starts with the current match's number and the total.")

(options:define-option wrap 'pause (lambda (v) (memq v '(pause immediately never)))
  "What a search does past its last match: pause, immediately or never.")

(options:define-option repeat-on-direction-change #f boolean?
  "Whether turning a search around goes to another match.")

(options:define-option search-folds #t boolean?
  "Whether searches find matches in folds.")

(hooks:define-hook started "Called with a search after its first state.")

(hooks:define-hook updated "Called with a search after each key that changed it, and when its count arrives.")

(hooks:define-hook ended "Called with a search and whether it was cancelled, after its keymap and highlights are gone.")

(tables:define-table keymap "The keymap of a search, a temporary keymap of its client.")

(tables:define-table edit-keymap "Added to isearch:edit-string's prompt.")

(define fail 'isearch.fail)

;; A key that adds to the text makes it partial, so a word or symbol
;; search finds the words the text starts, as Emacs's lax search does
;; until a repeat.
(define-record-type %state
  (sealed #t)
  (fields text style case spaces filter folds? partial? direction match success? wrapped? overwrapped? error matched-length
          (mutable query)))

(define-record-type (%search %new-search search?)
  (sealed #t)
  (fields view client origin folds-filter (mutable states) (mutable scan) (mutable scan-bounds) (mutable highlights)
          (mutable end-keymap)
          (mutable reading?) (mutable opened) (mutable timer) (mutable note) (mutable ring-index) (mutable yanked?)
          (mutable ended?)))

(define %searches (make-weak-eq-hashtable))

(define %lingering (make-weak-eq-hashtable))

(define (%top s) (car (%search-states s)))

(define (current client) (eq-hashtable-ref %searches client #f))

(define (%check who s)
  (unless (search? s) (assertion-violation who "not a search" s)))

(define (search-view s) (%check 'isearch:search-view s) (%search-view s))
(define (search-client s) (%check 'isearch:search-client s) (%search-client s))
(define (search-direction s) (%check 'isearch:search-direction s) (%state-direction (%top s)))
(define (search-match s) (%check 'isearch:search-match s) (%state-match (%top s)))
(define (search-origin s) (%check 'isearch:search-origin s) (buffers:anchor-position (%search-origin s)))
(define (search-scan s) (%check 'isearch:search-scan s) (%search-scan s))

(define (%buffer s) (views:buffer (%search-view s)))

;; A state's query is made once, so its finds and its scan share it, and a
;; state that keeps the text and its rules keeps the query.
(define (%query-of s state)
  (or (%state-query state)
      (let* ([q (%whole-query s state)] [q (if (%state-partial? state) (search:query-with-partial q) q)])
        (%state-query-set! state q)
        q)))

(define (%whole-query s state)
  (search:make-query (%state-text state) (%state-style state) (%state-case state) (%state-spaces state)
                     (if (%state-folds? state) (%state-filter state) (%search-folds-filter s))))

;; Made once per search, with the given query's own filter, so every
;; state's query has the same filter and its scan stays.
(define (%folds-filter view own)
  (if own
      (lambda (buffer start end) (and (own buffer start end) (not (%hidden? view start end))))
      (lambda (buffer start end) (not (%hidden? view start end)))))

;; A match is hidden when one fold holds all of it, as Emacs skips a match
;; only when all of it is invisible.
(define (%hidden? view start end)
  (exists (lambda (f) (and (< start (cdr f)) (<= end (cdr f)))) (views:folds-at view start)))

(define (search-query s)
  (%check 'isearch:search-query s)
  (%whole-query s (%top s)))

(define (%last-success s)
  (let loop ([states (%search-states s)])
    (cond
      [(null? states) #f]
      [(%state-success? (car states)) (car states)]
      [else (loop (cdr states))])))

(define (%count-text s state)
  (let ([scan (%search-scan s)] [m (%state-match state)])
    (if (and scan m)
        (let ([i (search:scan-index scan (search:match-start m))])
          (format "~a/~a " (if i (+ i 1) "?") (if (search:scan-done? scan) (search:scan-count scan) "?")))
        "")))

(define (prompt s)
  (%check 'isearch:prompt s)
  (let* ([state (%top s)] [text (%state-text state)]
         [description (search:style-description (%state-style state))]
         [words (filter (lambda (w) (not (string=? w "")))
                        (list (if (or (%state-success? state) (string=? text "")) "" "failing")
                              (cond [(%state-overwrapped? state) "overwrapped"] [(%state-wrapped? state) "wrapped"] [else ""])
                              (string-downcase description)
                              "I-search"
                              (if (eq? (%state-direction state) 'backward) "backward" "")))]
         [head (apply string-append (map (lambda (w) (string-append w " ")) words))]
         [head (string-append (string (char-upcase (string-ref head 0))) (substring head 1 (- (string-length head) 1)) ": ")]
         [matched (min (%state-matched-length state) (string-length text))]
         [error (%state-error state)])
    (append
      (list (string-append (if (lazy-count) (%count-text s state) "") head))
      (if (> matched 0) (list (cons #f (substring text 0 matched))) '())
      (if (< matched (string-length text))
          (list (cons fail (substring text matched (string-length text))))
          '())
      (cond
        [(%search-note s) => (lambda (note) (list (string-append " [" note "]")))]
        [error (list (string-append " [" error "]"))]
        [else '()]))))

(define (%bounds s)
  (views:bounds (%search-view s)))

(define (%pattern-error c state)
  (if (and (search:pattern-error-offset c) (= (search:pattern-error-offset c) (string-length (%state-text state))))
      "incomplete input"
      (if (search:pattern-error-offset c) (condition-message c) "pattern too complex")))

;; A quit key stops a long find and then runs as the next key, so the
;; state the find was making fails and C-g goes back to the last state
;; that matched, as Emacs's isearch turns a quit in its search into C-g.
(define (%find s state position direction)
  (let-values ([(start end) (%bounds s)])
    (guard (c [(search:pattern-error? c) (values #f (%pattern-error c state))]
              [(cancelled? c) (values #f #f)])
      (values (search:find (%buffer s) (%query-of s state) (max start (min end position)) direction start end start end) #f))))

(define (%with state . fields)
  (let* ([get (lambda (key default) (let ([p (memq key fields)]) (if p (cadr p) default)))]
         [text (get 'text (%state-text state))] [style (get 'style (%state-style state))] [rule (get 'case (%state-case state))]
         [spaces (get 'spaces (%state-spaces state))] [folds? (get 'folds? (%state-folds? state))]
         [partial? (get 'partial? (%state-partial? state))])
    (make-%state text style rule spaces (%state-filter state) folds? partial?
                 (get 'direction (%state-direction state)) (get 'match (%state-match state))
                 (get 'success? (%state-success? state)) (get 'wrapped? (%state-wrapped? state))
                 (get 'overwrapped? (%state-overwrapped? state)) (get 'error (%state-error state))
                 (get 'matched-length (%state-matched-length state))
                 (and (string=? text (%state-text state)) (eq? style (%state-style state)) (eq? rule (%state-case state))
                      (eq? spaces (%state-spaces state)) (eq? folds? (%state-folds? state)) (eq? partial? (%state-partial? state))
                      (%state-query state)))))

(define (%searched s state position)
  (let ([direction (%state-direction state)])
    (if (string=? (%state-text state) "")
        (%with state 'match #f 'success? #t 'error #f 'matched-length 0)
        (let-values ([(m error) (%find s state position direction)])
          (cond
            [m (%with state 'match m 'success? #t 'error #f 'matched-length (string-length (%state-text state))
                      'overwrapped? (and (%state-wrapped? state)
                                         (let ([o (search-origin s)])
                                           (if (eq? direction 'forward) (>= (search:match-start m) o) (<= (search:match-end m) o)))))]
            [else (%with state 'success? #f 'error error
                         'matched-length (let ([last (%last-success s)]) (if last (%state-matched-length last) 0)))])))))

(define (%point-of state)
  (let ([m (%state-match state)])
    (cond
      [(not m) #f]
      [(eq? (%state-direction state) 'forward) (search:match-end m)]
      [else (search:match-start m)])))

(define (%show-match! s m)
  (let-values ([(kept closed) (partition (lambda (f) (and m (<= (car f) (search:match-start m) (cdr f))))
                                         (%search-opened s))])
    (let ([v (%search-view s)])
      (for-each (lambda (f) (views:fold! v (car f) (cdr f))) closed)
      (%search-opened-set! s (if m
                                 (let ([folds (views:folds-at v (search:match-start m))])
                                   (unless (null? folds) (views:unfold! v (search:match-start m)))
                                   (append kept folds))
                                 '())))))

;; Folds a search opened stay open once it ends at a match inside them,
;; as Emacs's isearch-open-invisible does, and their makers are told.
(define (%reveal-match! s m)
  (let ([v (%search-view s)] [opened (%search-opened s)])
    (%search-opened-set! s '())
    (unless (null? opened)
      (for-each (lambda (f) (views:fold! v (car f) (cdr f))) opened)
      (when m (views:reveal! v (search:match-start m) (search:match-end m))))))

(define (%push! s state)
  (%search-states-set! s (cons state (%search-states s)))
  (%after-change! s))

(define (%pop-failing! s)
  (let loop ()
    (when (and (pair? (cdr (%search-states s))) (or (not (%state-success? (%top s))) (%state-error (%top s))))
      (%search-states-set! s (cdr (%search-states s)))
      (loop))))

(define (%after-change! s)
  (let ([state (%top s)])
    (let ([p (%point-of state)])
      (when p (views:set-point! (%search-view s) p)))
    (%show-match! s (%state-match state))
    (%rescan! s)
    (updated s)))

(define (%end-highlights! s)
  (for-each search:end-highlight! (%search-highlights s))
  (%search-highlights-set! s '())
  (%cancel-timer! s))

(define (%cancel-timer! s)
  (when (%search-timer s) (timers:cancel! (%search-timer s)) (%search-timer-set! s #f)))

;; The first highlight, in the search's own view, always draws the current
;; match; isearch:lazy-highlight and its delay decide only where the
;; scan's other matches are drawn.
(define (%show-other-matches! s)
  (%search-timer-set! s #f)
  (let ([scan (%search-scan s)] [scope (lazy-highlight)] [own (car (%search-highlights s))])
    (when (and scan (not (eq? scope 'none)))
      (search:set-scan! own scan)
      (when (eq? scope 'all)
        (%search-highlights-set! s
          (cons own (map (lambda (v) (search:highlight! v (%search-client s) scan))
                         (remq (%search-view s) (views:showing (%buffer s))))))
        (%set-current! s)))))

(define (%hide-other-matches! s)
  (%cancel-timer! s)
  (let ([own (car (%search-highlights s))])
    (for-each search:end-highlight! (cdr (%search-highlights s)))
    (search:set-scan! own #f)
    (%search-highlights-set! s (list own))))

;; A failing state keeps the last match, which stays drawn, as Emacs keeps
;; the part of the text that matched highlighted.
(define (%set-current! s)
  (let ([m (%state-match (%top s))])
    (for-each (lambda (h) (search:set-current! h m faces:match)) (%search-highlights s))))

;; A scan stands while the new state's query has its matches, as after a
;; repeat, a wrap or a turn, so the count and the highlights stay.
(define (%rescan! s)
  (let* ([state (%top s)] [old (%search-scan s)] [text (%state-text state)]
         [bounds (call-with-values (lambda () (%bounds s)) cons)]
         [query (and (not (string=? text "")) (%query-of s state))])
    (unless (and old query (equal? bounds (%search-scan-bounds s)) (search:scan-answers? old query))
      (when old (search:stop-scan! old))
      (%hide-other-matches! s)
      (%search-scan-set! s #f)
      (when query
        (let ([m (%state-match state)])
          (guard (c [(search:pattern-error? c) (void)])
            (%search-scan-set! s
              (search:scan (%buffer s) query (car bounds) (cdr bounds)
                           (if m (search:match-start m) (search-origin s))
                           (lambda (scan)
                             (when (and (eq? scan (%search-scan s)) (search:scan-done? scan))
                               (updated s)))))
            (%search-scan-bounds-set! s bounds)))
        (if (or (>= (string-length text) (lazy-highlight-no-delay-length)) (zero? (lazy-highlight-delay)))
            (%show-other-matches! s)
            (%search-timer-set! s (call-as-owner %self (lambda () (timers:run-after (lazy-highlight-delay) (lambda () (%show-other-matches! s)))))))))
    (%set-current! s)))

(define (%keep found command)
  (or (eq? found keymap) (eq? found keys:universal-argument-keymap)))

(define (%push-keymap! s)
  (%search-end-keymap-set! s
    (keys:push-keymap! (%search-client s) keymap %keep (lambda () (%keymap-ended s)) (lambda () (prompt s)))))

(define (%keymap-ended s)
  (unless (or (%search-reading? s) (%search-ended? s))
    (%finish! s #f)))

(define (%clear-lingering! view)
  (let ([h (eq-hashtable-ref %lingering view #f)])
    (when h
      (search:end-highlight! h)
      (eq-hashtable-delete! %lingering view))))

(define (%finish! s cancelled?)
  (%search-ended?-set! s #t)
  (let* ([client (%search-client s)] [view (%search-view s)] [state (%top s)]
         [success (%last-success s)] [origin (search-origin s)])
    (when (eq? (eq-hashtable-ref %searches client #f) s)
      (eq-hashtable-delete! %searches client))
    (when (%search-end-keymap s) ((%search-end-keymap s)))
    (if cancelled?
        (begin
          (views:set-point! view origin)
          (%show-match! s #f))
        (begin
          (let ([last (or success state)])
            (unless (string=? (%state-text last) "")
              (search:add-to-history! (%whole-query s last))))
          (%reveal-match! s (and success (%state-match success)))
          (unless (= (views:point view) origin)
            (jump-history:push! (%buffer s) origin))))
    (%end-highlights! s)
    (let ([scan (%search-scan s)])
      (when scan
        (if (and (not cancelled?) (not (lazy-highlight-cleanup)) (%state-match state))
            (begin
              (%clear-lingering! view)
              (eq-hashtable-set! %lingering view (search:highlight! view #f scan)))
            (search:stop-scan! scan))))
    (ended s cancelled?)))

(define (%new view client query direction)
  (let* ([b (views:buffer view)] [point (views:point view)]
         [s (%new-search view client (buffers:anchor b point) (%folds-filter view (search:query-filter query))
                         (list (make-%state (search:query-text query) (search:query-style query) (search:query-case query)
                                            (search:query-spaces query) (search:query-filter query) (search-folds)
                                            (search:query-partial? query)
                                            direction #f #t #f #f #f 0 #f))
                         #f #f '() #f #f '() #f #f #f #f #f)])
    (let ([old (current client)]) (when old (%finish! old #f)))
    (%clear-lingering! view)
    (%search-highlights-set! s (list (search:highlight! view client #f)))
    (eq-hashtable-set! %searches client s)
    (%push-keymap! s)
    s))

(define (start! view client query direction)
  (unless (views:view? view) (assertion-violation 'isearch:start! "not a view" view))
  (unless (search:query? query) (assertion-violation 'isearch:start! "not a query" query))
  (unless (memq direction '(forward backward)) (assertion-violation 'isearch:start! "not a direction" direction))
  (let ([s (%new view client query direction)])
    (unless (string=? (search:query-text query) "")
      (let ([state (%searched s (%top s) (views:point view))])
        (%search-states-set! s (list state))))
    (%after-change! s)
    (started s)
    s))

(define (%start style direction)
  (let ([s (%new (views:current) (web:current-client) (search:make-query "" style) direction)])
    (%after-change! s)
    (started s)
    s))

(define (end! s)
  (%check 'isearch:end! s)
  (unless (%search-ended? s)
    (%finish! s #f)))

(define (%current who)
  (or (current (web:current-client))
      (assertion-violation who "no search runs for this client")))

(commands:define-command (forward [regexp? (commands:prefix-argument)])
  "Starts a search forward in isearch:default-style; with a prefix argument, a regexp search."
  (%start (if regexp? search:regexp (default-style)) (search:direction forward)))

(commands:define-command (backward [regexp? (commands:prefix-argument)])
  "Starts a search backward, as isearch:forward."
  (%start (if regexp? search:regexp (default-style)) (search:direction backward)))

(commands:define-command (forward-regexp [literal? (commands:prefix-argument)])
  "Starts a regexp search forward; with a prefix argument, a literal one."
  (%start (if literal? search:literal search:regexp) (search:direction forward)))

(commands:define-command (backward-regexp [literal? (commands:prefix-argument)])
  "Starts a regexp search backward; with a prefix argument, a literal one."
  (%start (if literal? search:literal search:regexp) (search:direction backward)))

(commands:define-command (forward-word [literal? (commands:prefix-argument)])
  "Starts a search forward in search:word; with a prefix argument, a literal one."
  (%start (if literal? search:literal search:word) (search:direction forward)))

(commands:define-command (forward-symbol)
  "Starts a search forward in search:symbol."
  (%start search:symbol (search:direction forward)))

(define (%symbol-at view)
  (let-values ([(a z) (syntax:symbol-bounds (views:buffer view) (views:point view))])
    (and a (< a z) (cons a z))))

(commands:define-command (forward-symbol-at-point [n (and (commands:prefix-argument) (commands:prefix-number))])
  "Starts a symbol search forward for the symbol at point, from its start; with a count n, goes n matches on, backward for a negative n."
  (let* ([view (views:current)] [bounds (%symbol-at view)])
    (unless bounds (error 'isearch:forward-symbol-at-point "No symbol at point"))
    (views:set-point! view (car bounds))
    (let ([s (start! view (web:current-client)
                     (search:make-query (buffers:text-between (buffers:document (views:buffer view)) (car bounds) (cdr bounds)) search:symbol)
                     (search:direction forward))])
      (cond
        [(not n) (void)]
        [(< n 0) (%repeat! s (search:direction backward) (- n))]
        [else (%repeat! s (search:direction forward) n)]))))

(commands:define-command (forward-thing-at-point)
  "Starts a search forward for the active region's text, deactivating the region, or else the symbol at point."
  (let* ([view (views:current)] [mark (views:mark view)] [point (views:point view)]
         [bounds (if (and mark (not (= mark point)))
                     (begin (views:set-mark! view #f) (cons (min mark point) (max mark point)))
                     (%symbol-at view))])
    (unless bounds (error 'isearch:forward-thing-at-point "No thing at point"))
    (views:set-point! view (car bounds))
    (start! view (web:current-client)
            (search:make-query (buffers:text-between (buffers:document (views:buffer view)) (car bounds) (cdr bounds)))
            (search:direction forward))))

;; Under the smart case rule, text added from the buffer is downcased, so
;; it adds no capital that would make the search exact.
(define (%downcased s text)
  (if (eq? (%state-case (%top s)) (search:case smart)) (string-downcase text) text))

;; Adding to a failing search searches again only for a regexp, which
;; added characters can make match; a longer literal, word or symbol text
;; cannot.
(define (%add! s added)
  (let* ([state (%top s)] [text (string-append (%state-text state) added)]
         [new (%with state 'text text 'partial? #t)])
    (%search-yanked?-set! s #f)
    (if (and (not (%state-success? state)) (not (string=? (%state-text state) "")) (not (eq? (%state-style state) search:regexp)))
        (%push! s (%with new 'error #f))
        (let* ([m (%state-match state)]
               [origin (search-origin s)]
               [position (if m (search:match-start m) (views:point (%search-view s)))]
               [stay (and m (eq? (%state-direction state) 'backward)
                          (let-values ([(here error) (%find s new (search:match-start m) (search:direction forward))])
                            (and here (= (search:match-start here) (search:match-start m)) (<= (search:match-end here) origin) here)))])
          (%push! s (if stay
                        (%with new 'match stay 'success? #t 'error #f 'matched-length (string-length text))
                        (%searched s new (if (eq? (%state-direction state) 'backward)
                                             (if m (min origin (search:match-end m)) position)
                                             position))))))))

(define (%add-repeated! s text n) (%add! s (apply string-append (make-list (max n 0) text))))

(commands:define-command (printing-char [n (commands:prefix-number)])
  "Adds the typed character, n times, and searches again."
  (let ([c (keys:typed-char)])
    (unless c (assertion-violation 'isearch:printing-char "no character was typed"))
    (%add-repeated! (%current 'isearch:printing-char) (string c) n)))

(define (%key-char key)
  (cond
    [(and (string? key) (= (string-length key) 1)) (string-ref key 0)]
    [(equal? key "SPC") #\space]
    [(equal? key "TAB") #\tab]
    [(equal? key "RET") #\return]
    [(and (string? key) (= (string-length key) 3) (string=? (substring key 0 2) "C-")
          (char<=? #\@ (char-upcase (string-ref key 2)) #\_))
     (integer->char (- (char->integer (char-upcase (string-ref key 2))) 64))]
    [else #f]))

(commands:define-command (quote-char [n (commands:prefix-number)])
  "Reads a key and adds its character, n times."
  (let* ([s (%current 'isearch:quote-char)] [c (%key-char (keys:read-key))])
    (unless c (error 'isearch:quote-char "not a character"))
    (%add-repeated! s (string c) n)))

(commands:define-command (delete-char)
  "Goes back to the state before the last key that changed the search."
  (let ([s (%current 'isearch:delete-char)])
    (when (pair? (cdr (%search-states s)))
      (%search-states-set! s (cdr (%search-states s)))
      (unless (%state-match (%top s))
        (views:set-point! (%search-view s) (search-origin s)))
      (%after-change! s))))

(commands:define-command (del-char [n (commands:prefix-number)])
  "Deletes n characters from the end of the text and searches again from the current match."
  (let* ([s (%current 'isearch:del-char)] [state (%top s)] [text (%state-text state)]
         [kept (substring text 0 (max 0 (- (string-length text) n)))] [m (%state-match state)])
    (%push! s (%searched s (%with state 'text kept 'partial? #t) (if m (search:match-start m) (search-origin s))))))

(define (%repeat! s direction n)
  (let loop ([n n])
    (when (> n 0)
      (let* ([state (%top s)] [turned? (not (eq? direction (%state-direction state)))]
             [text (if (string=? (%state-text state) "")
                       (let ([h (if (eq? (%state-style state) search:regexp) (search:regexp-history) (search:history))])
                         (if (null? h) "" (car h)))
                       (%state-text state))]
             [state (%with state 'text text 'direction direction 'partial? #f)]
             [m (%state-match state)])
        (cond
          [(string=? text "") (void)]
          [(and turned? m (not (repeat-on-direction-change)))
           (%push! s (%with state 'success? #t 'error #f))]
          [(and (not (%state-success? state)) (not (eq? (wrap) 'never)) (%state-error state)) (void)]
          [(and (not (%state-success? state)) (eq? (wrap) 'pause))
           (%push! s (%wrapped s state direction))]
          [else
           (let ([next (%searched s state (cond
                                            [(not m) (views:point (%search-view s))]
                                            [(eq? direction 'forward)
                                             (if (= (search:match-start m) (search:match-end m)) (+ (search:match-end m) 1) (search:match-end m))]
                                            [else (if (= (search:match-start m) (search:match-end m)) (- (search:match-start m) 1) (search:match-start m))]))])
             (%push! s (if (and (not (%state-success? next)) (eq? (wrap) 'immediately))
                           (%wrapped s state direction)
                           next)))])
        (loop (- n 1))))))

(define (%wrapped s state direction)
  (let-values ([(start end) (%bounds s)])
    (%searched s (%with state 'wrapped? #t) (if (eq? direction 'forward) start end))))

(commands:define-command (repeat-forward [n (commands:prefix-number)])
  "Goes to the nth next match, turning the search forward; backward for a negative n."
  (let ([s (%current 'isearch:repeat-forward)])
    (if (< n 0) (%repeat! s (search:direction backward) (- n)) (%repeat! s (search:direction forward) n))))

(commands:define-command (repeat-backward [n (commands:prefix-number)])
  "As isearch:repeat-forward, backward."
  (let ([s (%current 'isearch:repeat-backward)])
    (if (< n 0) (%repeat! s (search:direction forward) (- n)) (%repeat! s (search:direction backward) n))))

(define (%from-end! s from-start? n)
  (let-values ([(start end) (%bounds s)])
    (let* ([state (%with (%top s) 'direction (if from-start? (search:direction forward) (search:direction backward)) 'wrapped? #f 'partial? #f)])
      (let loop ([k n] [position (if from-start? start end)] [last #f])
        (if (= k 0)
            (%push! s last)
            (let ([next (%searched s state position)])
              (if (and (%state-success? next) (%state-match next))
                  (let ([m (%state-match next)])
                    (loop (- k 1) (if from-start? (search:match-end m) (search:match-start m)) next))
                  (%push! s next))))))))

(commands:define-command (beginning-of-buffer [n (commands:prefix-number)])
  "Goes to the nth match from the start of the view's bounds."
  (%from-end! (%current 'isearch:beginning-of-buffer) #t (max n 1)))

(commands:define-command (end-of-buffer [n (commands:prefix-number)])
  "Goes to the nth match from the end."
  (%from-end! (%current 'isearch:end-of-buffer) #f (max n 1)))

(commands:define-command (cancel)
  "Ends the search, puts point back where it started, and raises &cancelled."
  (let ([s (%current 'isearch:cancel)])
    (%finish! s #t)
    (raise (%quit))))

(define (%quit) (make-cancelled #f))

(commands:define-command (abort)
  "In a failing search, or one whose pattern is unfinished, goes back to the last state that matched; otherwise cancels."
  (let* ([s (%current 'isearch:abort)] [state (%top s)])
    (if (or (not (%state-success? state)) (%state-error state))
        (begin (%pop-failing! s) (%after-change! s))
        (cancel))))

(commands:define-command (exit)
  "Ends the search at the current match; with no text typed, reads one and searches once."
  (let ([s (%current 'isearch:exit)])
    (if (string=? (%state-text (%top s)) "")
        (begin (edit-string) (let ([s (current (web:current-client))]) (when s (%finish! s #f))))
        (%finish! s #f))))

(define (%after-match s)
  (let ([m (%state-match (%top s))])
    (if m (search:match-end m) (views:point (%search-view s)))))

(define (%yank-to! s to)
  (let ([from (%after-match s)])
    (when (> to from)
      (%add! s (%downcased s (buffers:text-between (buffers:document (%buffer s)) from to))))))

(define (%word-char? s c)
  (or (char-alphabetic? c) (char-numeric? c)
      (exists (lambda (x) (char=? c x)) (string->list (syntax:buffer-word-characters (%buffer s))))))

(define (%char-after s p)
  (let ([doc (buffers:document (%buffer s))])
    (and (< p (document:length doc)) (let ([t (document:token doc p)]) (and (char? t) t)))))

(commands:define-command (yank-word-or-char [n (commands:prefix-number)])
  "Adds the next n words after the match, or the next character when one that is not a word character follows."
  (let* ([s (%current 'isearch:yank-word-or-char)] [from (%after-match s)] [c (%char-after s from)])
    (%yank-to! s (if (and c (%word-char? s c))
                     (editing:forward-word-position (%buffer s) from (max n 1))
                     (%char-end s from)))))

(define (%char-end s from)
  (min (+ from 1) (document:length (buffers:document (%buffer s)))))

(commands:define-command (yank-symbol-or-char [n (commands:prefix-number)])
  "Adds the next n symbols after the match, or the next character when no symbol follows."
  (let* ([s (%current 'isearch:yank-symbol-or-char)] [b (%buffer s)] [from (%after-match s)])
    (let-values ([(a z) (syntax:symbol-bounds b from)])
      (%yank-to! s (if (and a (> z from)) (%symbols-end b from (max n 1)) (%char-end s from))))))

(define (%symbols-end b from n)
  (let ([len (document:length (buffers:document b))])
    (let loop ([k n] [p from])
      (if (= k 0)
          p
          (let-values ([(a z) (syntax:symbol-bounds b p)])
            (cond
              [(and a (> z p)) (loop (- k 1) z)]
              [(< p len) (loop k (+ p 1))]
              [else p]))))))

(commands:define-command (yank-char [n (commands:prefix-number)])
  "Adds the next n characters after the match."
  (let ([s (%current 'isearch:yank-char)])
    (%yank-to! s (min (+ (%after-match s) (max n 1)) (document:length (buffers:document (%buffer s)))))))

(commands:define-command (yank-until-char [char (%key-char (keys:read-key))] [n (commands:prefix-number)])
  "Reads a character and adds the text after the match up to the nth following one, inclusive."
  (let* ([s (%current 'isearch:yank-until-char)] [doc (buffers:document (%buffer s))] [len (document:length doc)])
    (let loop ([p (%after-match s)] [k (max n 1)])
      (cond
        [(>= p len) (error 'isearch:yank-until-char "Not found")]
        [(eqv? (document:token doc p) char) (if (= k 1) (%yank-to! s (+ p 1)) (loop (+ p 1) (- k 1)))]
        [else (loop (+ p 1) k)]))))

(commands:define-command (yank-line [n (commands:prefix-number)])
  "Adds the rest of the line after the match, and n - 1 lines more."
  (let* ([s (%current 'isearch:yank-line)] [doc (buffers:document (%buffer s))] [from (%after-match s)]
         [line (+ (document:line doc from) (max n 1) -1)]
         [last (document:line doc (- (document:length doc) 1))]
         [to (if (< line last) (- (document:line-start doc (+ line 1)) 1) (- (document:length doc) 1))])
    (%yank-to! s (max to from))))

(commands:define-command (yank-kill)
  "Adds the newest kill's text."
  (let ([s (%current 'isearch:yank-kill)] [kill (kill-ring:current)])
    (unless kill (error 'isearch:yank-kill "Kill ring is empty"))
    (let ([text (%downcased s (kill-ring:text kill))])
      (%add! s text)
      (%search-yanked?-set! s #t))))

(commands:define-command (yank-pop [n (commands:prefix-number)])
  "Replaces the text the last yank added with the nth older kill."
  (let ([s (%current 'isearch:yank-pop)])
    (if (not (%search-yanked? s))
        (yank-kill)
        (let* ([kill (kill-ring:rotate! n)] [text (%downcased s (kill-ring:text kill))])
          (%search-states-set! s (cdr (%search-states s)))
          (%add! s text)
          (%search-yanked?-set! s #t)))))

(commands:define-command (paste text)
  "Adds pasted TEXT, for editing:paste, which the search's keymap remaps here."
  (unless (string? text) (assertion-violation 'isearch:paste "not a string" text))
  (%add! (%current 'isearch:paste) text))

(define (%ring s)
  (if (eq? (%state-style (%top s)) search:regexp) (search:regexp-history) (search:history)))

(define (%ring-move! s step)
  (let ([ring (%ring s)])
    (unless (null? ring)
      (let* ([i (mod (+ (or (%search-ring-index s) (if (< step 0) 0 -1)) step) (length ring))] [text (list-ref ring i)])
        (%search-ring-index-set! s i)
        (%search-states-set! s (cons (%with (%top s) 'text text 'partial? #f 'error #f 'matched-length (string-length text))
                                     (%search-states s)))
        (updated s)))))

(commands:define-command (ring-retreat)
  "Replaces the text with the previous one of the search's history, round from the oldest to the newest, without searching until the next key."
  (%ring-move! (%current 'isearch:ring-retreat) 1))

(commands:define-command (ring-advance)
  "As isearch:ring-retreat, toward newer texts."
  (%ring-move! (%current 'isearch:ring-advance) -1))

(define (%edit-exit direction)
  (lambda ()
    (let ([p (minibuffer:current-prompt)])
      (minibuffer:exit! p (cons direction (minibuffer:input p))))))

(commands:define-command (edit-forward)
  "Ends isearch:edit-string's read and searches forward."
  ((%edit-exit (search:direction forward))))

(commands:define-command (edit-backward)
  "Ends isearch:edit-string's read and searches backward."
  ((%edit-exit (search:direction backward))))

;; The search's keymap is off while THUNK reads, since it binds the
;; printing characters, which must edit the prompt.
(define (call-suspended s thunk)
  (%check 'isearch:call-suspended s)
  (unless (procedure? thunk) (assertion-violation 'isearch:call-suspended "not a procedure" thunk))
  (%search-reading?-set! s #t)
  ((%search-end-keymap s))
  (let ([v (guard (c [(or (serious-condition? c) (cancelled? c)) (%search-reading?-set! s #f) (%push-keymap! s) (raise c)])
             (thunk))])
    (%search-reading?-set! s #f)
    (%push-keymap! s)
    v))

(commands:define-command (edit-string)
  "Reads the text in the minibuffer, starting with the current text, then searches with what was read."
  (let* ([s (%current 'isearch:edit-string)] [state (%top s)])
    (let ([answer (guard (c [(cancelled? c) (abort) (raise c)])
                    (call-suspended s
                      (lambda ()
                        (minibuffer:call-with-setup
                          (lambda (p)
                            (minibuffer:set-input! p (%state-text state))
                            (minibuffer:add-keymap! p edit-keymap))
                          (lambda ()
                            (minibuffer:read (string-append (car (prompt s)) "")
                                             (if (eq? (%state-style state) search:regexp) search:regexp-history search:history)))))))])
      (let* ([text (if (pair? answer) (cdr answer) answer)]
             [direction (if (pair? answer) (car answer) (%state-direction state))]
             [m (%state-match state)])
        (%push! s (%searched s (%with state 'text text 'direction direction 'wrapped? #f 'partial? #f)
                             (if m (search:match-start m) (search-origin s))))))))

(define (%toggled! s . fields)
  (let* ([state (apply %with (%top s) 'partial? #f fields)] [m (%state-match state)])
    (%push! s (%searched s state (if m (search:match-start m) (search-origin s))))))

(define (%note! s text)
  (%search-note-set! s text)
  (call-as-owner %self (lambda () (timers:run-after 1 (lambda () (%search-note-set! s #f))))))

(commands:define-command (toggle-case-fold)
  "Switches the search between the fold and exact case rules."
  (let* ([s (%current 'isearch:toggle-case-fold)]
         [exact? (guard (c [(search:pattern-error? c) (eq? (%state-case (%top s)) (search:case exact))])
                   (not (search:query-caseless? (%query-of s (%top s)) (%buffer s))))])
    (%toggled! s 'case (if exact? (search:case fold) (search:case exact)))
    (%note! s (if exact? "case insensitive" "case sensitive"))))

(define (%toggle-style! who style)
  (let ([s (%current who)])
    (%toggled! s 'style (if (eq? (%state-style (%top s)) style) search:literal style))))

(commands:define-command (toggle-regexp)
  "Switches between search:regexp and search:literal."
  (%toggle-style! 'isearch:toggle-regexp search:regexp))

(commands:define-command (toggle-word)
  "Switches between search:word and search:literal."
  (%toggle-style! 'isearch:toggle-word search:word))

(commands:define-command (toggle-symbol)
  "Switches between search:symbol and search:literal."
  (%toggle-style! 'isearch:toggle-symbol search:symbol))

(commands:define-command (toggle-lax-whitespace)
  "Switches the search's whitespace rule between lax and literal."
  (let ([s (%current 'isearch:toggle-lax-whitespace)])
    (%toggled! s 'spaces (if (eq? (%state-spaces (%top s)) (search:spaces lax)) (search:spaces literal) (search:spaces lax)))))

(commands:define-command (toggle-search-folds)
  "Switches whether this search finds matches in folds."
  (let ([s (%current 'isearch:toggle-search-folds)])
    (%toggled! s 'folds? (not (%state-folds? (%top s))))))

(commands:define-command (clear-highlights [view (views:current)])
  "Removes the highlights that ended searches left in VIEW."
  (%clear-lingering! view))

(define (%end-all!)
  (vector-for-each (lambda (s) (%finish! s #t)) (hashtable-values %searches))
  (vector-for-each search:end-highlight! (hashtable-values %lingering)))

(keys:bind! keys:global "C-s" forward)
(keys:bind! keys:global "C-r" backward)
(keys:bind! keys:global "C-M-s" forward-regexp)
(keys:bind! keys:global "C-M-r" backward-regexp)
(keys:bind! keys:global "M-s w" forward-word)
(keys:bind! keys:global "M-s _" forward-symbol)
(keys:bind! keys:global "M-s ." forward-symbol-at-point)
(keys:bind! keys:global "M-s M-." forward-thing-at-point)
(for-each (lambda (key) (keys:bind! keymap key printing-char)) '("<printing-char>" "SPC" "TAB" "C-j" "S-SPC"))
(keys:bind! keymap "C-q" quote-char)
(keys:bind! keymap "DEL" delete-char)
(keys:bind! keymap "C-M-d" del-char)
(keys:bind! keymap "C-s" repeat-forward)
(keys:bind! keymap "C-M-s" repeat-forward)
(keys:bind! keymap "C-r" repeat-backward)
(keys:bind! keymap "C-M-r" repeat-backward)
(keys:bind! keymap "M-s M-<" beginning-of-buffer)
(keys:bind! keymap "M-s M->" end-of-buffer)
(keys:bind! keymap "C-g" abort)
(keys:bind! keymap "ESC" cancel)
(keys:bind! keymap "RET" exit)
(keys:bind! keymap "C-w" yank-word-or-char)
(keys:bind! keymap "C-M-w" yank-symbol-or-char)
(keys:bind! keymap "C-M-y" yank-char)
(keys:bind! keymap "C-M-z" yank-until-char)
(keys:bind! keymap "M-s C-e" yank-line)
(keys:bind! keymap "C-y" yank-kill)
(keys:bind! keymap "M-y" yank-pop)
(keys:remap! keymap editing:paste paste)
(keys:bind! keymap "M-p" ring-retreat)
(keys:bind! keymap "M-n" ring-advance)
(keys:bind! keymap "M-e" edit-string)
(keys:bind! keymap "M-s e" edit-string)
(keys:bind! keymap "M-s c" toggle-case-fold)
(keys:bind! keymap "M-c" toggle-case-fold)
(keys:bind! keymap "M-s r" toggle-regexp)
(keys:bind! keymap "M-r" toggle-regexp)
(keys:bind! keymap "M-s w" toggle-word)
(keys:bind! keymap "M-s _" toggle-symbol)
(keys:bind! keymap "M-s SPC" toggle-lax-whitespace)
(keys:bind! keymap "M-s i" toggle-search-folds)
;; Bound here as well as globally, the prefix-argument keys keep the
;; search, so a count can come before one of its keys.
(keys:bind! keymap "C-u" keys:universal-argument)
(keys:bind! keymap "M--" keys:negative-argument)
(for-each (lambda (d) (keys:bind! keymap (string-append "M-" (number->string d)) keys:digit-argument)) (iota 10))
(keys:bind! edit-keymap "C-s" edit-forward)
(keys:bind! edit-keymap "C-r" edit-backward)
(tables:set! web:stylesheets 'isearch "isearch/isearch.css")
(on-unload %end-all!)
