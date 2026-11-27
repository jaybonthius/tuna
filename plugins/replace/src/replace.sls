#!tuna
(import (search) (isearch) (buffers) (document) (views) (keys) (commands) (minibuffer) (ask) (jump-history) (faces)
        (web) (hooks) (options) (tables) (saved))

(options:define-option preserve-case #t boolean?
  "Whether a replacement takes the case of what it replaces.")

(options:define-option lax-whitespace #f boolean?
  "Whether a run of spaces in M-%'s text matches search:whitespace.")

(options:define-option skip-read-only #f boolean?
  "Whether a match the buffer refuses to edit is passed over rather than ending the session.")

(saved:define-saved history '()
  (lambda (v) (and (list? v) (for-all (lambda (p) (and (pair? p) (string? (car p)) (string? (cdr p)))) v))))

(saved:define-saved prompt-history '() (lambda (v) (and (list? v) (for-all string? v))))

(hooks:define-hook started "Called with a session once its keymap is pushed, before it asks about its first match.")

(hooks:define-hook updated "Called with a session each time it asks about a match, and when its scan reports.")

(hooks:define-hook ended "Called with a session and the number of replacements it made, after its keymap and highlights are gone.")

(tables:define-table keymap "The keymap of a replace session, a temporary keymap of its client.")

(tables:define-table %paused-keymap "The keymap of a paused session: only replace:resume.")

(define match 'replace.match)

;; A replacement made is kept as anchors around its text and the text it
;; replaced, so u and U take it back as new edits.
(define-record-type %replaced
  (sealed #t)
  (fields start end old))

(define-record-type (%session %new-session session?)
  (sealed #t)
  (fields view client query direction origin range-start range-end regexp?
          (mutable replacement) (mutable match) (mutable count) (mutable scan) (mutable highlight)
          (mutable end-keymap) (mutable shown) (mutable exact-case?) (mutable visited) (mutable replacements)
          (mutable skipped) (mutable help?) (mutable waiting?) (mutable resume) (mutable ended?)))

(define %sessions (make-weak-eq-hashtable))

(define (current client) (eq-hashtable-ref %sessions client #f))

(define (%check who s)
  (unless (session? s) (assertion-violation who "not a session" s)))

(define (session-view s) (%check 'replace:session-view s) (%session-view s))
(define (session-client s) (%check 'replace:session-client s) (%session-client s))
(define (session-query s) (%check 'replace:session-query s) (%session-query s))
(define (session-replacement s) (%check 'replace:session-replacement s) (%session-replacement s))
(define (session-match s) (%check 'replace:session-match s) (%session-match s))
(define (session-count s) (%check 'replace:session-count s) (%session-count s))
(define (session-scan s) (%check 'replace:session-scan s) (%session-scan s))

(define (%buffer s) (views:buffer (%session-view s)))

(define (%position a) (buffers:anchor-position a))

(define (%text b start end) (buffers:text-between (buffers:document b) start end))

(define (%capital? text) (exists char-upper-case? (string->list text)))

(define (%words text)
  (let loop ([cs (string->list text)] [word '()] [acc '()])
    (define (flush) (if (null? word) acc (cons (list->string (reverse word)) acc)))
    (cond
      [(null? cs) (reverse (flush))]
      [(or (char-alphabetic? (car cs)) (char-numeric? (car cs))) (loop (cdr cs) (cons (car cs) word) acc)]
      [else (loop (cdr cs) '() (flush))])))

(define (%capitalized word)
  (let ([letters (filter char-alphabetic? (string->list word))])
    (or (null? letters)
        (and (char-upper-case? (car letters)) (for-all (lambda (c) (not (char-upper-case? c))) (cdr letters))))))

(define (%capitalize text)
  (let ([out (string-copy text)])
    (let loop ([i 0] [start? #t])
      (when (< i (string-length out))
        (let ([c (string-ref out i)])
          (if (or (char-alphabetic? c) (char-numeric? c))
              (begin (string-set! out i (if start? (char-upcase c) (char-downcase c))) (loop (+ i 1) #f))
              (loop (+ i 1) #t)))))
    out))

;; As Emacs's replace-match, a match in capitals needs a word of more than
;; one letter to give a replacement in capitals; F alone is capitalized.
(define (match-case replacement matched)
  (unless (string? replacement) (assertion-violation 'replace:match-case "not a string" replacement))
  (unless (string? matched) (assertion-violation 'replace:match-case "not a string" matched))
  (let* ([letters (filter char-alphabetic? (string->list matched))]
         [words (filter (lambda (w) (exists char-alphabetic? (string->list w))) (%words matched))])
    (cond
      [(null? letters) replacement]
      [(and (for-all char-upper-case? letters) (exists (lambda (w) (> (string-length w) 1)) words))
       (string-upcase replacement)]
      [(for-all %capitalized words) (%capitalize replacement)]
      [else replacement])))

(define (%converts-case? s)
  (let ([q (%session-query s)] [r (%session-replacement s)])
    (and (preserve-case) (not (%session-exact-case? s))
         (not (eq? (search:query-case q) 'exact))
         (not (%capital? (search:query-text q)))
         (or (procedure? r) (not (%capital? r))))))

(define (%replacement-text s m)
  (let* ([b (%buffer s)] [r (%session-replacement s)]
         [text (if (procedure? r)
                   (let ([t (r m (%session-count s))])
                     (unless (string? t) (assertion-violation 'replace:query-replace! "a replacement procedure returned what is not a string" t))
                     t)
                   (search:expand b m r (%session-count s)))])
    (if (%converts-case? s)
        (match-case text (%text b (search:match-start m) (search:match-end m)))
        text)))

(define (%shown text)
  (call-with-string-output-port
    (lambda (out)
      (string-for-each
        (lambda (c)
          (if (and (char<? c #\space) (not (char=? c #\tab)))
              (begin (put-char out #\^) (put-char out (integer->char (+ (char->integer c) 64))))
              (put-char out c)))
        text))))

(define %help
  "y or SPC replace, n or DEL skip, ! all, . replace and exit, , replace and show, ^ back, u undo, U undo all, e edit replacement, E edit exactly, C-r edit, C-w delete and edit, q or RET exit")

(define (prompt s)
  (%check 'replace:prompt s)
  (if (%session-help? s)
      (list %help)
      (let ([r (%session-replacement s)] [m (%session-match s)])
        (list (string-append "Query replacing " (if (%session-regexp? s) "regexp " "")
                             (search:query-text (%session-query s))
                             " with "
                             (cond
                               [(procedure? r) "a procedure"]
                               [(and m (not (%session-shown s))) (%replacement-text s m)]
                               [else r])
                             ": (? for help) ")))))

(define (%range s)
  (values (%position (%session-range-start s)) (%position (%session-range-end s))))

(define (%atom-in? b start end)
  (let ([doc (buffers:document b)])
    (let loop ([p start])
      (and (< p end) (or (not (char? (document:token doc p))) (loop (+ p 1)))))))

(define (%find s position)
  (let-values ([(start end) (%range s)] [(seen seen-end) (views:bounds (%session-view s))])
    (let ([b (%buffer s)] [direction (%session-direction s)])
      (let loop ([position position])
        (and (<= start position end)
             (let ([m (search:find b (%session-query s) position direction start end seen seen-end)])
               (cond
                 [(not m) #f]
                 [(%atom-in? b (search:match-start m) (search:match-end m))
                  (%session-skipped-set! s (+ (%session-skipped s) 1))
                  (loop (%past s m))]
                 [else m])))))))

(define (%past s m)
  (let ([a (search:match-start m)] [z (search:match-end m)])
    (if (eq? (%session-direction s) 'forward)
        (if (= a z) (+ z 1) z)
        (if (= a z) (- a 1) a))))

(define (%ask! s m)
  (%session-match-set! s m)
  (%session-shown-set! s #f)
  (if m (%point-to! s) (%finish! s)))

(define (%point-to! s)
  (let ([m (%session-match s)])
    (views:set-point! (%session-view s) (if (eq? (%session-direction s) 'forward) (search:match-end m) (search:match-start m)))
    (let ([h (%session-highlight s)]) (when h (search:set-current! h m match)))
    (updated s)))

(define (%next! s position)
  (%ask! s (%find s position)))

(define (%refusal c)
  (if (message-condition? c) (condition-message c) "The buffer refuses the edit"))

(define (%replace-current! s)
  (let* ([m (%session-match s)] [b (%buffer s)] [a (search:match-start m)] [z (search:match-end m)]
         [old (%text b a z)] [new (%replacement-text s m)])
    (guard (c [(buffers:refused? c)
               (if (skip-read-only)
                   (begin (%session-skipped-set! s (+ (%session-skipped s) 1)) 'skipped)
                   (%refusal c))])
      (buffers:replace! b a z new)
      (let ([r (make-%replaced (buffers:anchor b a) (buffers:anchor-after b (+ a (string-length new))) old)])
        (%session-replacements-set! s (cons r (%session-replacements s)))
        (%session-count-set! s (+ (%session-count s) 1))
        r))))

(define (%visit! s r)
  (let ([m (%session-match s)])
    (when m
      (%session-visited-set! s (cons (or r (buffers:anchor (%buffer s) (search:match-start m))) (%session-visited s))))))

;; After , or ^ the current match may be a replacement, shown, which the
;; next answer passes rather than replacing again.
(define (%go-on! s)
  (let ([m (%session-match s)])
    (%visit! s (%session-shown s))
    (%next! s (%past s m))))

(define (%show! s r)
  (%session-match-set! s (%shown-match s r))
  (%session-shown-set! s r)
  (%point-to! s))

(define (%act! s then)
  (if (%session-shown s)
      (%go-on! s)
      (let ([r (%replace-current! s)])
        (cond
          [(string? r) (%finish! s r)]
          [(eq? r 'skipped) (%go-on! s)]
          [else (then r)]))))

;; One further after an empty match, which would otherwise be found
;; again.
(define (%after-replaced s r m)
  (let ([empty? (= (search:match-start m) (search:match-end m))])
    (if (eq? (%session-direction s) 'forward)
        (let ([end (%position (%replaced-end r))]) (if empty? (+ end 1) end))
        (let ([start (%position (%replaced-start r))]) (if empty? (- start 1) start)))))

(define (%push-keymap! s)
  (%session-end-keymap-set! s
    (keys:push-keymap! (%session-client s) keymap
                       (lambda (found command) (%session-help?-set! s #f) (eq? found keymap))
                       (lambda () (%keymap-ended s))
                       (lambda () (prompt s)))))

(define (%keymap-ended s)
  (unless (or (%session-waiting? s) (%session-ended? s))
    (%finish! s)))

(define (%end-keymap! s)
  (let ([end (%session-end-keymap s)])
    (%session-end-keymap-set! s #f)
    (when end (end))))

(define %finish!
  (case-lambda
    [(s) (%finish! s #f)]
    [(s refusal)
     (unless (%session-ended? s)
       (%session-ended?-set! s #t)
       (let ([client (%session-client s)] [view (%session-view s)])
         (when (eq? (current client) s) (eq-hashtable-delete! %sessions client))
         (%end-keymap! s)
         (let ([h (%session-highlight s)]) (when h (search:end-highlight! h)))
         (let ([scan (%session-scan s)]) (when scan (search:stop-scan! scan)))
         (let ([origin (%position (%session-origin s))])
           (unless (= (views:point view) origin)
             (jump-history:push! (%buffer s) origin)))
         (ask:message (or refusal (%summary s)))
         (ended s (%session-count s))
         (let ([resume (%session-resume s)])
           (when resume
             (%session-resume-set! s #f)
             (let ([count (%session-count s)]) (resume (lambda () count)))))))]))

(define (%summary s)
  (let ([n (%session-count s)] [skipped (%session-skipped s)])
    (string-append (format "Replaced ~a occurrence~a" n (if (= n 1) "" "s"))
                   (if (> skipped 0) (format " (skipped ~a)" skipped) ""))))

(define (%start! view client query replacement start end direction regexp?)
  (when (current client)
    (assertion-violation 'replace:query-replace! "a replace session is already running for this client"))
  (let* ([b (views:buffer view)]
         [s (%new-session view client query direction (buffers:anchor b (views:point view))
                          (buffers:anchor b start) (buffers:anchor-after b end)
                          regexp? replacement #f 0 #f #f #f #f #f '() '() 0 #f #f #f #f)])
    (eq-hashtable-set! %sessions client s)
    (let-values ([(seen seen-end) (views:bounds view)])
      (let ([scan (search:scan b query start end (if (eq? direction 'forward) start end)
                               (lambda (scan) (when (eq? (current client) s) (updated s)))
                               seen seen-end)])
        (%session-scan-set! s scan)
        (%session-highlight-set! s (search:highlight! view client scan))))
    (%push-keymap! s)
    (started s)
    (%next! s (if (eq? direction 'forward) start end))
    s))

(define (%check-replacement who r)
  (unless (or (string? r) (procedure? r)) (assertion-violation who "neither a string nor a procedure" r)))

(define (query-replace! view client query replacement start end direction)
  (define who 'replace:query-replace!)
  (unless (views:view? view) (assertion-violation who "not a view" view))
  (unless (search:query? query) (assertion-violation who "not a query" query))
  (%check-replacement who replacement)
  (unless (memq direction '(forward backward)) (assertion-violation who "not a direction" direction))
  (unless (and (fixnum? start) (fixnum? end) (fx<= 0 start end)) (assertion-violation who "not a range" start end))
  (let ([s #f])
    (guard (c [#t (when (and s (not (%session-ended? s))) (%session-resume-set! s #f) (%finish! s)) (raise c)])
      (suspend
        (lambda (resume)
          (set! s (%start! view client query replacement start end direction (eq? (search:query-style query) search:regexp)))
          (if (%session-ended? s)
              (let ([count (%session-count s)]) (resume (lambda () count)))
              (%session-resume-set! s resume)))))))

(define (%range-of view direction)
  (let* ([b (views:buffer view)]
         [regions (apply append (map (lambda (c) (views:region-ranges view c)) (views:cursors view)))]
         [regions (list-sort (lambda (x y) (< (car x) (car y))) regions)])
    (let-values ([(lo hi) (views:bounds view)])
      (cond
        [(null? regions)
         (if (eq? direction 'forward)
             (values (views:point view) hi #f)
             (values lo (views:point view) #f))]
        [(null? (cdr regions))
         (values (caar regions) (cdar regions) #f)]
        [else
         (let ([anchors (map (lambda (r) (cons (buffers:anchor b (car r)) (buffers:anchor-after b (cdr r)))) regions)])
           (values (caar regions) (cdr (car (last-pair regions)))
                   (lambda (buffer start end)
                     (exists (lambda (r) (<= (%position (car r)) start end (%position (cdr r)))) anchors))))]))))

(define (%descr pair) (string-append (%shown (car pair)) " → " (%shown (cdr pair))))

(define (%add-history! from to)
  (let ([pairs (cons (cons from to) (remove (cons from to) (history)))] [n (minibuffer:history-length)])
    (saved:set! history (if (> (length pairs) n) (list-head pairs n) pairs))))

(define (%rescan-preview! view client state text style)
  (let ([old (car state)])
    (when old (search:end-highlight! (cdr old)) (search:stop-scan! (car old))))
  (set-car! state #f)
  (unless (string=? text "")
    (let-values ([(lo hi) (views:bounds view)])
      (guard (c [(search:pattern-error? c) (void)])
        (let ([scan (search:scan (views:buffer view) (search:make-query text style) lo hi (views:point view) (lambda (scan) (void)))])
          (set-car! state (cons scan (search:highlight! view client scan))))))))

(define (%read-from question style entries)
  (let* ([view (views:current)] [client (web:current-client)] [state (list #f)] [prompt #f]
         [follow (lambda (p) (when (eq? p prompt) (%rescan-preview! view client state (minibuffer:input p) style)))])
    (define (stop!)
      (hooks:remove! minibuffer:input-changed follow)
      (%rescan-preview! view client state "" style))
    (hooks:add! minibuffer:input-changed follow)
    ;; Not dynamic-wind: its exit would run each time the task pauses.
    (let-values ([(from chosen) (guard (c [#t (stop!) (raise c)])
                                  (minibuffer:call-with-setup
                                    (lambda (p) (set! prompt p))
                                    (lambda () (minibuffer:read-entry question prompt-history entries))))])
      (stop!)
      (values from chosen))))

;; M-p shows each past pair written from → to before what was typed, as
;; Emacs builds them from query-replace-defaults as it reads; only a pair
;; chosen from them is split, so typed text is replaced as it is.
(define (%read-pair verb style)
  (let* ([pairs (history)] [default (and (pair? pairs) (car pairs))])
    (let-values ([(from chosen) (%read-from (string-append verb (if default (string-append " (default " (%descr default) ")") "") ": ")
                                            style (map %descr pairs))])
      (cond
        [chosen (let ([pair (list-ref pairs chosen)]) (values (car pair) (cdr pair)))]
        [(and (string=? from "") default) (values (car default) (cdr default))]
        [(string=? from "") (error 'replace:query-replace "Nothing to replace")]
        [else
         (let ([to (minibuffer:read (string-append verb " " (%shown from) " with: ") prompt-history)])
           (values from to))]))))

(define (%check-pair who from to)
  (unless (string? from) (assertion-violation who "not a string" from))
  (unless (string? to) (assertion-violation who "not a string" to)))

(define (%query-for from style words?)
  (let ([spaces (if (lax-whitespace) (search:spaces lax) (search:spaces literal))])
    (cond
      [(and words? (eq? style search:regexp))
       (search:make-query (string-append "\\b(?:" from ")\\b") search:regexp (search:case-fold) spaces)]
      [words? (search:make-query from search:word (search:case-fold) spaces)]
      [else (search:make-query from style (search:case-fold) spaces)])))

(define (%run view query replacement direction)
  (let-values ([(start end filter) (%range-of view direction)])
    (when (views:mark view) (views:set-mark! view #f))
    (query-replace! view (web:current-client) (if filter (search:query-with-filter query filter) query)
                    replacement start end direction)))

(define (%direction) (if (eq? (commands:prefix-argument) '-) (search:direction backward) (search:direction forward)))

(define (%words-arg) (and (commands:prefix-argument) (not (eq? (commands:prefix-argument) '-))))

(commands:define-command (query-replace [(from to) (%read-pair "Query replace" search:literal)] [words? (%words-arg)])
  "Reads the text to replace and its replacement, then asks about each match; with C-u, whole words only, with -, backward."
  (%check-pair 'replace:query-replace from to)
  (%add-history! from to)
  (%run (views:current) (%query-for from search:literal words?) to (%direction)))

(commands:define-command (query-replace-regexp [(from to) (%read-pair "Query replace regexp" search:regexp)] [words? (%words-arg)])
  "As replace:query-replace, with a regexp."
  (%check-pair 'replace:query-replace-regexp from to)
  (%add-history! from to)
  (%run (views:current) (%query-for from search:regexp words?) to (%direction)))

(define (%replace-all! view query to)
  (let-values ([(start end filter) (%range-of view (search:direction forward))])
    (let* ([b (views:buffer view)] [query (if filter (search:query-with-filter query filter) query)]
           [s (%new-session view #f query (search:direction forward) (buffers:anchor b (views:point view)) (buffers:anchor b start) (buffers:anchor-after b end)
                            (eq? (search:query-style query) search:regexp) to #f 0 #f #f #f #f #f '() '() 0 #f #f #f #f)])
      (let loop ([m (%find s start)])
        (if m
            (begin
              (%session-match-set! s m)
              (let ([r (%replace-current! s)])
                (cond
                  [(string? r) (ask:message r)]
                  [(eq? r 'skipped) (loop (%find s (%past s m)))]
                  [else (loop (%find s (%after-replaced s r m)))])))
            (ask:message (%summary s)))))))

(commands:define-command (replace-string [(from to) (%read-pair "Replace string" search:literal)])
  "Replaces every match of the text with its replacement, without asking."
  (%check-pair 'replace:replace-string from to)
  (%add-history! from to)
  (%replace-all! (views:current) (%query-for from search:literal #f) to))

(commands:define-command (replace-regexp [(from to) (%read-pair "Replace regexp" search:regexp)])
  "As replace:replace-string, with a regexp."
  (%check-pair 'replace:replace-regexp from to)
  (%add-history! from to)
  (%replace-all! (views:current) (%query-for from search:regexp #f) to))

(define (%from-search who regexp? words?)
  (let* ([client (web:current-client)] [search (or (isearch:current client) (assertion-violation who "no search runs for this client"))]
         [view (isearch:search-view search)] [query (isearch:search-query search)] [m (isearch:search-match search)]
         [query (cond
                  [(and regexp? words?) (search:make-query (string-append "\\b(?:" (search:query-text query) ")\\b") search:regexp
                                                           (search:query-case query) (search:query-spaces query) (search:query-filter query))]
                  [regexp? (search:make-query (search:query-text query) search:regexp (search:query-case query)
                                              (search:query-spaces query) (search:query-filter query))]
                  [words? (search:make-query (search:query-text query) search:word (search:query-case query)
                                             (search:query-spaces query) (search:query-filter query))]
                  [else query])]
         [from (search:query-text query)])
    (when m (views:set-point! view (search:match-start m)))
    (isearch:end! search)
    (let ([to (minibuffer:read (string-append "Query replace " (if regexp? "regexp " "") (%shown from) " with: ") prompt-history)])
      (%add-history! from to)
      (%run view query to (if (eq? (isearch:search-direction search) 'backward) (search:direction backward) (search:direction forward))))))

(commands:define-command (isearch-query-replace [words? (%words-arg)])
  "Ends the search and asks about each match of its query from the start of its current match, reading only the replacement."
  (%from-search 'replace:isearch-query-replace #f words?))

(commands:define-command (isearch-query-replace-regexp [words? (%words-arg)])
  "As replace:isearch-query-replace, taking the search's text as a regexp."
  (%from-search 'replace:isearch-query-replace-regexp #t words?))

(define (%current who)
  (or (current (web:current-client)) (assertion-violation who "no replace session runs for this client")))

(commands:define-command (act)
  "Replaces the current match and goes to the next."
  (let ([s (%current 'replace:act)])
    (%act! s (lambda (r) (%visit! s r) (%next! s (%after-replaced s r (%session-match s)))))))

(commands:define-command (skip)
  "Goes to the next match."
  (%go-on! (%current 'replace:skip)))

(commands:define-command (act-and-exit)
  "Replaces the current match and ends the session."
  (let ([s (%current 'replace:act-and-exit)])
    (let ([r (and (not (%session-shown s)) (%replace-current! s))])
      (if (string? r) (%finish! s r) (%finish! s)))))

(commands:define-command (act-and-show)
  "Replaces the current match and stays on it; the next answer goes on."
  (let ([s (%current 'replace:act-and-show)])
    (unless (%session-shown s)
      (let ([r (%replace-current! s)])
        (cond
          [(string? r) (%finish! s r)]
          [(eq? r 'skipped) (%go-on! s)]
          [else (%show! s r)])))))

(define (%shown-match s r)
  (let ([a (%position (%replaced-start r))] [z (%position (%replaced-end r))])
    (search:find (%buffer s) (search:make-query (%text (%buffer s) a z) search:literal (search:case exact) (search:spaces literal)) a (search:direction forward) a z)))

(commands:define-command (act-on-all)
  "Replaces every remaining match without asking."
  (let ([s (%current 'replace:act-on-all)])
    (let loop ()
      (unless (%session-ended? s)
        (%act! s (lambda (r) (%next! s (%after-replaced s r (%session-match s)))))
        (unless (%session-ended? s) (loop))))))

(commands:define-command (back)
  "Goes back to the previous match, without undoing it."
  (let* ([s (%current 'replace:back)] [visited (%session-visited s)])
    (if (null? visited)
        (ask:message "No previous match")
        (let ([entry (car visited)])
          (%session-visited-set! s (cdr visited))
          (if (%replaced? entry)
              (%show! s entry)
              (%ask-at! s (%position entry)))))))

(define (%take-back! s r)
  (let* ([b (%buffer s)] [a (%position (%replaced-start r))] [z (%position (%replaced-end r))])
    (buffers:replace! b a z (%replaced-old r))
    (%session-replacements-set! s (remq r (%session-replacements s)))
    (%session-visited-set! s (remq r (%session-visited s)))
    (%session-count-set! s (- (%session-count s) 1))
    a))

(define (%ask-at! s position)
  (let* ([b (%buffer s)] [m (search:find b (%session-query s) position (search:direction forward) position (document:length (buffers:document b)))])
    (%ask! s (and m (= (search:match-start m) position) m))))

(commands:define-command (undo-last)
  "Takes back the session's last replacement and asks about that match again."
  (let ([s (%current 'replace:undo-last)])
    (if (null? (%session-replacements s))
        (ask:message "Nothing to undo")
        (%ask-at! s (%take-back! s (car (%session-replacements s)))))))

(commands:define-command (undo-all)
  "Takes back every replacement of the session and asks about the first match again."
  (let ([s (%current 'replace:undo-all)])
    (if (null? (%session-replacements s))
        (ask:message "Nothing to undo")
        (let loop ([rs (%session-replacements s)] [first #f])
          (if (null? rs)
              (begin (%session-visited-set! s '()) (%ask-at! s first))
              (loop (cdr rs) (%take-back! s (car rs))))))))

;; The session's keymap is off while the minibuffer reads, since it binds
;; y, n, SPC and the others, which the new replacement may hold.
(define (%edit-replacement! who exact?)
  (let* ([s (%current who)] [r (%session-replacement s)])
    (%session-waiting?-set! s #t)
    (%end-keymap! s)
    (let ([new (guard (c [(cancelled? c) (%session-waiting?-set! s #f) (%finish! s) (raise c)])
                 (minibuffer:call-with-setup
                   (lambda (p) (when (string? r) (minibuffer:set-input! p r)))
                   (lambda () (minibuffer:read "Edit replacement string: " #f))))])
      (%session-waiting?-set! s #f)
      (%push-keymap! s)
      (%session-replacement-set! s new)
      (when exact? (%session-exact-case?-set! s #t))
      (if (%session-shown s)
          (%go-on! s)
          (act)))))

(commands:define-command (edit-replacement)
  "Reads a new replacement, replaces the current match with it, and uses it from then on."
  (%edit-replacement! 'replace:edit-replacement #f))

(commands:define-command (edit-replacement-exact-case)
  "As replace:edit-replacement, with no case conversion for the rest of the session."
  (%edit-replacement! 'replace:edit-replacement-exact-case #t))

(define (%pause! s)
  (%session-waiting?-set! s #t)
  (%end-keymap! s)
  (%session-end-keymap-set! s
    (keys:push-keymap! (%session-client s) %paused-keymap (lambda (found command) #t) void
                       "Editing; C-M-c goes on with the replace")))

(commands:define-command (edit)
  "Pauses the session so keys edit as usual; replace:resume goes on from the current match."
  (%pause! (%current 'replace:edit)))

(commands:define-command (delete-and-edit)
  "Deletes the current match, then pauses as replace:edit."
  (let* ([s (%current 'replace:delete-and-edit)] [m (%session-match s)])
    (when m (buffers:replace! (%buffer s) (search:match-start m) (search:match-end m) ""))
    (%pause! s)))

(commands:define-command (resume)
  "Takes the paused session up again."
  (let ([s (%current 'replace:resume)])
    (unless (%session-waiting? s) (assertion-violation 'replace:resume "the session is not paused"))
    (%end-keymap! s)
    (%session-waiting?-set! s #f)
    (%push-keymap! s)
    (let ([m (%session-match s)])
      (%next! s (if m
                    (if (eq? (%session-direction s) 'forward) (search:match-start m) (search:match-end m))
                    (views:point (%session-view s)))))))

(commands:define-command (exit)
  "Ends the session."
  (%finish! (%current 'replace:exit)))

(commands:define-command (help)
  "Shows the answers in the prompt until the next key."
  (%session-help?-set! (%current 'replace:help) #t))

(define (%end-all!)
  (vector-for-each (lambda (s) (%finish! s)) (hashtable-values %sessions)))

(keys:bind! keys:global "M-%" query-replace)
(keys:bind! keys:global "C-M-%" query-replace-regexp)
(keys:bind! isearch:keymap "M-%" isearch-query-replace)
(keys:bind! isearch:keymap "C-M-%" isearch-query-replace-regexp)
(keys:bind! keymap "y" act)
(keys:bind! keymap "SPC" act)
(keys:bind! keymap "n" skip)
(keys:bind! keymap "DEL" skip)
(keys:bind! keymap "." act-and-exit)
(keys:bind! keymap "," act-and-show)
(keys:bind! keymap "!" act-on-all)
(keys:bind! keymap "^" back)
(keys:bind! keymap "u" undo-last)
(keys:bind! keymap "U" undo-all)
(keys:bind! keymap "e" edit-replacement)
(keys:bind! keymap "E" edit-replacement-exact-case)
(keys:bind! keymap "C-r" edit)
(keys:bind! keymap "C-w" delete-and-edit)
(keys:bind! keymap "q" exit)
(keys:bind! keymap "RET" exit)
(keys:bind! keymap "?" help)
(keys:bind! keymap "C-h" help)
(keys:bind! keymap "C-l" views:recenter-top-bottom)
(keys:bind! keymap "C-v" views:scroll-up)
(keys:bind! keymap "M-v" views:scroll-down)
(keys:bind! %paused-keymap "C-M-c" resume)
(tables:set! web:stylesheets 'replace "replace/replace.css")
(on-unload %end-all!)
