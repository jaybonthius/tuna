#!tuna
(import (buffers) (document) (files) (modes) (syntax) (views) (commands) (faces) (ask) (docs-at-point))

(define %severities '(error warning info hint))

(define-syntax severity
  (lambda (x)
    (syntax-case x ()
      [(_ name) (and (identifier? #'name) (memq (syntax->datum #'name) '(error warning info hint))) #''name]
      [_ (syntax-violation 'diagnostics:severity "not a severity" x)])))

(define (%severity-rank s)
  (case s [(error) 0] [(warning) 1] [(info) 2] [else 3]))

(define (%severity-face s)
  (case s
    [(error) faces:diagnostic.error]
    [(warning) faces:diagnostic.warning]
    [(info) faces:diagnostic.info]
    [else faces:diagnostic.hint]))

(define-enumeration %tag (unnecessary deprecated) %tag-set)

(define-syntax tags
  (lambda (x)
    (syntax-case x ()
      [(_ name ...)
       (for-all (lambda (n) (and (identifier? n) (memq (syntax->datum n) '(unnecessary deprecated))))
                #'(name ...))
       #'(%tag-set name ...)]
      [_ (syntax-violation 'diagnostics:tags "not a tag" x)])))

(define %no-tags (%tag-set))

(define-record-type %details
  (sealed #t)
  (fields origin code tags keymap data))

(define (%check-and-make-details origin code tags keymap data)
  (define who 'diagnostics:details)
  (unless (or (not origin) (string? origin))
    (assertion-violation who "neither a string nor #f" origin))
  (unless (or (not code) (string? code))
    (assertion-violation who "neither a string nor #f" code))
  (unless (and (enum-set? tags) (enum-set-subset? tags (enum-set-universe %no-tags)))
    (assertion-violation who "not a set of tags" tags))
  (unless (or (not keymap) (table? keymap))
    (assertion-violation who "neither a keymap nor #f" keymap))
  (make-%details origin code tags keymap data))

(define-syntax details
  (lambda (x)
    (define (invalid c) (syntax-violation 'diagnostics:details "invalid clause" x c))
    (syntax-case x ()
      [(_ clause ...)
       (let loop ([clauses #'(clause ...)] [given '()])
         (define (given-or name default) (let ([g (assq name given)]) (if g (cdr g) default)))
         (if (null? clauses)
             #`(%check-and-make-details #,(given-or 'origin #'#f) #,(given-or 'code #'#f)
                                        #,(given-or 'tags #'%no-tags) #,(given-or 'keymap #'#f)
                                        #,(given-or 'data #'#f))
             (let* ([c (car clauses)]
                    [name (syntax-case c () [(k . _) (identifier? #'k) (syntax->datum #'k)] [_ (invalid c)])])
               (when (assq name given)
                 (syntax-violation 'diagnostics:details "clause given twice" x c))
               (loop (cdr clauses)
                     (cons (case name
                             [(origin code tags keymap data) (syntax-case c () [(_ e) (cons name #'e)] [_ (invalid c)])]
                             [else (invalid c)])
                           given)))))])))

(define %no-details (make-%details #f #f %no-tags #f #f))

;; The given range is kept apart from where the diagnostic is now, so a
;; report placing it again counts from what its maker gave.
(define-record-type (%diagnostic %make-diagnostic diagnostic?)
  (sealed #t)
  (fields (immutable given-start %given-start) (immutable given-end %given-end)
          (immutable severity diagnostic-severity) (immutable message diagnostic-message)
          (immutable details %diagnostic-details) (immutable maker %diagnostic-maker)
          (mutable source %source %set-source!) (mutable buffer %buffer %set-buffer!)
          (mutable path %path %set-path!) (mutable start %start %set-start!) (mutable end %end %set-end!)))

(define (%line-column? v)
  (and (pair? v) (fixnum? (car v)) (fx>= (car v) 1) (fixnum? (cdr v)) (fx>= (cdr v) 0)))

(define (%position? v) (and (fixnum? v) (fx>= v 0)))

(define make-diagnostic
  (case-lambda
    [(start end severity message) (make-diagnostic start end severity message %no-details)]
    [(start end severity message details)
     (define who 'diagnostics:make-diagnostic)
     (cond
       [(%position? start)
        (unless (and (%position? end) (fx<= start end))
          (assertion-violation who "not an end position after the start" end))]
       [(%line-column? start)
        (unless (or (not end) (%line-column? end))
          (assertion-violation who "not a line and column or #f" end))]
       [else (assertion-violation who "neither a position nor a line and column" start)])
     (unless (memq severity %severities)
       (assertion-violation who "not a severity" severity))
     (unless (string? message)
       (assertion-violation who "not a string" message))
     (unless (%details? details)
       (assertion-violation who "not details" details))
     (%make-diagnostic start end severity message details (current-owner) #f #f #f start end)]))

(define (%check-diagnostic who d)
  (unless (diagnostic? d)
    (assertion-violation who "not a diagnostic" d)))

(define (%start-of d)
  (let ([s (%start d)]) (if (buffers:anchor? s) (buffers:anchor-position s) s)))

(define (%end-of d)
  (let ([e (%end d)]) (if (buffers:anchor? e) (buffers:anchor-position e) e)))

(define (diagnostic-start d)
  (%check-diagnostic 'diagnostics:diagnostic-start d)
  (%start-of d))

(define (diagnostic-end d)
  (%check-diagnostic 'diagnostics:diagnostic-end d)
  (%end-of d))

(define (diagnostic-buffer d)
  (%check-diagnostic 'diagnostics:diagnostic-buffer d)
  (%buffer d))

(define (diagnostic-path d)
  (%check-diagnostic 'diagnostics:diagnostic-path d)
  (%path d))

(define (diagnostic-origin d)
  (%check-diagnostic 'diagnostics:diagnostic-origin d)
  (%details-origin (%diagnostic-details d)))

(define (diagnostic-code d)
  (%check-diagnostic 'diagnostics:diagnostic-code d)
  (%details-code (%diagnostic-details d)))

(define (diagnostic-tags d)
  (%check-diagnostic 'diagnostics:diagnostic-tags d)
  (%details-tags (%diagnostic-details d)))

(define (diagnostic-keymap d)
  (%check-diagnostic 'diagnostics:diagnostic-keymap d)
  (%details-keymap (%diagnostic-details d)))

(define (diagnostic-data d)
  (%check-diagnostic 'diagnostics:diagnostic-data d)
  (%details-data (%diagnostic-details d)))

(define (diagnostic-source d)
  (%check-diagnostic 'diagnostics:diagnostic-source d)
  (%source d))

(define (text d)
  (%check-diagnostic 'diagnostics:text d)
  (let ([origin (diagnostic-origin d)] [code (diagnostic-code d)])
    (if (or origin code)
        (string-append (or origin "") (if (and origin code) " " "") (if code (string-append "[" code "]") "")
                       ": " (diagnostic-message d))
        (diagnostic-message d))))

(define-record-type (%source-record %make-source source?)
  (sealed #t)
  (fields owner))

(define-hook changed "Called with a buffer or a path after its diagnostics change.")

(define %in-buffers (make-weak-eq-hashtable))
(define %in-paths (make-hashtable string-hash string=?))

(define (%by-source table key)
  (or (hashtable-ref table key #f)
      (let ([h (make-eq-hashtable)])
        (hashtable-set! table key h)
        h)))

(define (%all-of table key)
  (let ([h (hashtable-ref table key #f)])
    (if h (apply append (vector->list (hashtable-values h))) '())))

(define (make-source)
  (let ([s (%make-source (current-owner))])
    (on-unload (lambda () (clear! s)))
    s))

(modes:define-minor-mode mode
  "Whether a buffer's diagnostics are drawn and its checkers run."
  (on-change (lambda (on?) (%follow-mode!))))

(define-table mark-keymap "Keys active at a drawn diagnostic, after the diagnostic's own keymap.")

(buffers:define-layer error-marks (priority 53) (sticky neither) (evaporate) (keymap mark-keymap))
(buffers:define-layer warning-marks (priority 52) (sticky neither) (evaporate) (keymap mark-keymap))
(buffers:define-layer info-marks (priority 51) (sticky neither) (evaporate) (keymap mark-keymap))
(buffers:define-layer hint-marks (priority 50) (sticky neither) (evaporate) (keymap mark-keymap))

(define (%layer-type s)
  (case s [(error) error-marks] [(warning) warning-marks] [(info) info-marks] [else hint-marks]))

(define (%mode-in? b) (buffers:with-buffer b (mode)))

(define %drawn (make-weak-eq-hashtable))

(define (%span-value d)
  (let* ([ds (%diagnostic-details d)] [tags (%details-tags ds)] [keymap (%details-keymap ds)])
    (append
      (list (cons 'face (append (list (%severity-face (diagnostic-severity d)))
                                (if (enum-set-member? 'unnecessary tags) (list faces:diagnostic.unnecessary) '())
                                (if (enum-set-member? 'deprecated tags) (list faces:diagnostic.deprecated) '())))
            (cons 'title (text d)))
      (if keymap (list (cons 'keymap keymap)) '()))))

(define (%draw! b)
  (%follow-at-point! b)
  (let ([on? (%mode-in? b)])
    (when (or on? (eq-hashtable-ref %drawn b #f))
      (let ([len (document:length (buffers:document b))] [all (if on? (%all-of %in-buffers b) '())])
        (for-each
          (lambda (s)
            (buffers:set-spans! (buffers:layer b (%layer-type s)) 0 len
              (fold-right
                (lambda (d acc)
                  (if (eq? (diagnostic-severity d) s)
                      (cons (list (%start-of d) (%end-of d) (%span-value d)) acc)
                      acc))
                '() all)))
          %severities)
        (if on? (eq-hashtable-set! %drawn b #t) (eq-hashtable-delete! %drawn b))))))

(define (%line-end doc line)
  (let ([last (document:line doc (document:length doc))])
    (if (fx< line last)
        (fx- (document:line-start doc (fx+ line 1)) 1)
        (document:length doc))))

(define (%line-column-position doc lc)
  (let* ([chars (document:unit characters)]
         [line (fxmin (car lc) (document:line doc (document:length doc)))]
         [start (document:line-start doc line)] [end (%line-end doc line)])
    (document:position doc (fxmin (fx+ (document:offset doc start chars) (cdr lc)) (document:offset doc end chars))
                       chars)))

(define (%symbol-or-line b start)
  (let-values ([(a e) (guard (c [(not (quit-condition? c)) (values #f #f)]) (syntax:symbol-bounds b start))])
    (if (and a (fx< a e))
        (values a e)
        (let* ([doc (buffers:document b)] [line (document:line doc start)] [end (%line-end doc line)])
          (if (fx< start end)
              (values start end)
              (values (document:line-start doc line) end))))))

;; Only a range empty as given is widened, after the move, since
;; syntax:symbol-bounds reads the buffer as it is now. One the edits since
;; have emptied marked text that is gone, so it is dropped, as an edit
;; that empties a live range drops it.
(define (%place! d source b then version)
  (let* ([len (document:length then)]
         [counted (lambda (p) (if (pair? p) (%line-column-position then p) (fxmin p len)))]
         [cs (counted (%given-start d))] [ce (and (%given-end d) (counted (%given-end d)))]
         [after (lambda (p) (if version (buffers:map-position-after b p version) p))]
         [before (lambda (p) (if version (buffers:map-position b p version) p))])
    (let-values ([(s e) (if (and ce (fx< cs ce)) (values (after cs) (before ce)) (%symbol-or-line b (after cs)))])
      (and (fx< s e)
           (begin
             (%set-source! d source)
             (%set-buffer! d b)
             (%set-path! d (files:path b))
             (%set-start! d (buffers:anchor-after b s))
             (%set-end! d (buffers:anchor b e))
             d)))))

(define (%put-path! d source path)
  (%set-source! d source)
  (%set-buffer! d #f)
  (%set-path! d path)
  (%set-start! d (%given-start d))
  (%set-end! d (%given-end d))
  d)

(define (%absolute-path? v)
  (and (string? v) (fx> (string-length v) 0) (char=? (string-ref v 0) #\/)))

(define (%report-to-buffer! source b diagnostics version)
  (let ([then (if version (buffers:document-at b version) (buffers:document b))]
        [version (and version (not (fx= version (buffers:version b))) version)])
    (and then
         (let* ([placed (filter values (map (lambda (d) (%place! d source b then version)) diagnostics))]
                [h (%by-source %in-buffers b)])
           (if (null? placed) (hashtable-delete! h source) (hashtable-set! h source placed))
           (%draw! b)
           (changed b)
           #t))))

(define report!
  (case-lambda
    [(source where diagnostics) (%report! source where diagnostics #f)]
    [(source where diagnostics version)
     (unless (and (fixnum? version) (fx>= version 0))
       (assertion-violation 'diagnostics:report! "not a version" version))
     (%report! source where diagnostics version)]))

(define (%report! source where diagnostics version)
  (define who 'diagnostics:report!)
  (unless (source? source)
    (assertion-violation who "not a source" source))
  (unless (and (list? diagnostics) (for-all diagnostic? diagnostics))
    (assertion-violation who "not a list of diagnostics" diagnostics))
  (cond
    [(buffers:buffer? where)
     (when version
       (unless (fx<= version (buffers:version where))
         (assertion-violation who "not a version of the buffer" version)))
     (%report-to-buffer! source where diagnostics version)]
    [(%absolute-path? where)
     (let ([b (files:buffer-visiting where)])
       (cond
         [b (%report-to-buffer! source b diagnostics (and version (fx<= version (buffers:version b)) version))]
         [else
          (for-each
            (lambda (d)
              (unless (pair? (%given-start d))
                (assertion-violation who "positions in a report to a path" d)))
            diagnostics)
          (let ([h (%by-source %in-paths where)])
            (if (null? diagnostics)
                (hashtable-delete! h source)
                (hashtable-set! h source (map (lambda (d) (%put-path! d source where)) diagnostics)))
            (when (fx= (hashtable-size h) 0) (hashtable-delete! %in-paths where)))
          (changed where)
          #t]))]
    [else (assertion-violation who "neither a buffer nor an absolute path" where)]))

(define (%clear-in! source table where)
  (let ([h (hashtable-ref table where #f)])
    (when (and h (hashtable-contains? h source))
      (hashtable-delete! h source)
      (when (and (string? where) (fx= (hashtable-size h) 0)) (hashtable-delete! %in-paths where))
      (when (buffers:buffer? where) (%draw! where))
      (changed where))))

(define clear!
  (case-lambda
    [(source)
     (unless (source? source)
       (assertion-violation 'diagnostics:clear! "not a source" source))
     (for-each (lambda (b) (when (buffers:live? b) (%clear-in! source %in-buffers b)))
               (vector->list (hashtable-keys %in-buffers)))
     (for-each (lambda (p) (%clear-in! source %in-paths p)) (vector->list (hashtable-keys %in-paths)))]
    [(source where)
     (unless (source? source)
       (assertion-violation 'diagnostics:clear! "not a source" source))
     (cond
       [(buffers:buffer? where) (%clear-in! source %in-buffers where)]
       [(%absolute-path? where)
        (let ([b (files:buffer-visiting where)])
          (if b (%clear-in! source %in-buffers b) (%clear-in! source %in-paths where)))]
       [else (assertion-violation 'diagnostics:clear! "neither a buffer nor an absolute path" where)])]))

(define (%before? a b)
  (let ([sa (%start-of a)] [sb (%start-of b)])
    (cond
      [(and (pair? sa) (pair? sb))
       (or (fx< (car sa) (car sb))
           (and (fx= (car sa) (car sb))
                (or (fx< (cdr sa) (cdr sb))
                    (and (fx= (cdr sa) (cdr sb))
                         (fx< (%severity-rank (diagnostic-severity a)) (%severity-rank (diagnostic-severity b)))))))]
      [else
       (or (fx< sa sb)
           (and (fx= sa sb) (fx< (%severity-rank (diagnostic-severity a)) (%severity-rank (diagnostic-severity b)))))])))

(define in
  (case-lambda
    [(b)
     (unless (buffers:buffer? b)
       (assertion-violation 'diagnostics:in "not a buffer" b))
     (list-sort %before? (%all-of %in-buffers b))]
    [(b start)
     (filter (lambda (d) (let ([s (%start-of d)]) (and (fx<= s start) (or (fx= s start) (fx< start (%end-of d))))))
             (in b))]
    [(b start end)
     (filter (lambda (d) (let ([s (%start-of d)]) (or (fx= s start) (and (fx< s end) (fx< start (%end-of d))))))
             (in b))]))

(define (%under? path folder)
  (let ([n (string-length folder)])
    (and (fx> (string-length path) n) (string=? (substring path 0 n) folder))))

(define (under folder)
  (unless (%absolute-path? folder)
    (assertion-violation 'diagnostics:under "not an absolute path" folder))
  (let* ([folder (if (char=? (string-ref folder (fx- (string-length folder) 1)) #\/) folder (string-append folder "/"))]
         [from-buffers
          (filter (lambda (entry) (and (car entry) (%under? (car entry) folder)))
                  (map (lambda (b) (cons (files:path b) (in b)))
                       (filter buffers:live? (vector->list (hashtable-keys %in-buffers)))))]
         [from-paths
          (map (lambda (p) (cons p (list-sort %before? (%all-of %in-paths p))))
               (filter (lambda (p) (%under? p folder)) (vector->list (hashtable-keys %in-paths))))])
    (apply append (map cdr (list-sort (lambda (a b) (string<? (car a) (car b))) (append from-buffers from-paths))))))

(define (%text-face s)
  (case s [(error) faces:error] [(warning) faces:warning] [else faces:success]))

(define (at-point view)
  (and (views:call-with-view view mode)
       (let ([b (views:buffer view)])
         (map (lambda (d)
                (let ([t (text d)])
                  (docs-at-point:make-doc t
                    (docs-at-point:doc-options [spans (list (list 0 (string-length t) (%text-face (diagnostic-severity d))))]))))
              (in b (views:point view))))))

;; The entry is local to buffers with the mode on, so docs-at-point asks
;; only where diagnostics may answer.
(define (%follow-at-point! b)
  (as-module (this-module)
    (buffers:with-buffer b
      (if (mode)
          (add-local-hook! docs-at-point:sources at-point 90)
          (remove-local-hook! docs-at-point:sources at-point)))))

;; An edit that empties a diagnostic's range removes it, so its anchors
;; never pass each other.
(define (%drop-emptied! b)
  (let ([h (hashtable-ref %in-buffers b #f)] [dropped? #f])
    (when h
      (vector-for-each
        (lambda (source)
          (let* ([ds (hashtable-ref h source '())]
                 [kept (filter (lambda (d) (fx< (%start-of d) (%end-of d))) ds)])
            (unless (fx= (length kept) (length ds))
              (set! dropped? #t)
              (if (null? kept) (hashtable-delete! h source) (hashtable-set! h source kept)))))
        (hashtable-keys h))
      (when dropped?
        (changed b)))))

(define-record-type %checks
  (sealed #t)
  (fields (mutable running) (mutable failed) (mutable sources) (mutable timer)))

(define %checks-of (make-weak-eq-hashtable))

(define (%checks-for b)
  (or (eq-hashtable-ref %checks-of b #f)
      (let ([c (make-%checks '() '() '() #f)])
        (eq-hashtable-set! %checks-of b c)
        c)))

(define-hook checkers
  "Its entries are procedures of a buffer that check it, pausing until they have, and return the diagnostics they found.")

(define-option check-delay 0.5 (lambda (v) (or (not v) (and (real? v) (>= v 0))))
  "Seconds without edits before a buffer's checkers run again; #f runs them only when the mode turns on, on save and on diagnostics:check.")

(define-option check-on-save? #t boolean? "Whether a save runs the buffer's checkers.")

(define-option wrap-around? #t boolean? "Whether diagnostics:next goes round the buffer's ends.")

(define %quit (record-constructor (record-constructor-descriptor &quit)))

(define (%entries b) (buffers:with-buffer b (hook-entries checkers)))

;; An entry's source is made in the name of its diagnostics' maker,
;; since the module that added an entry is known only inside its call.
(define (%entry-source! cs entry found)
  (let ([known (assq entry (%checks-sources cs))])
    (cond
      [known (cdr known)]
      [(null? found) #f]
      [else
       (let* ([maker (%diagnostic-maker (car found))]
              [s (guard (c [(not (quit-condition? c)) (make-source)]) (as-module maker (make-source)))])
         (%checks-sources-set! cs (cons (cons entry s) (%checks-sources cs)))
         s)])))

(define (%check-one! b cs entry)
  (let ([last (assq entry (%checks-running cs))])
    (when last
      (%checks-running-set! cs (remq last (%checks-running cs)))
      (unless (task-done? (cdr last)) (signal-task (cdr last) (%quit)))))
  (letrec ([task
            (spawn-task
              (lambda ()
                (define (current?) (let ([r (assq entry (%checks-running cs))]) (and r (eq? (cdr r) task))))
                (guard (c [(quit-condition? c) (void)]
                          [else
                           (when (current?)
                             (%checks-failed-set! cs (cons entry (%checks-failed cs))))
                           (report c)])
                  (when (buffers:live? b)
                    (let* ([version (buffers:version b)]
                           [found (buffers:with-buffer b (entry b))])
                      (unless (and (list? found) (for-all diagnostic? found))
                        (assertion-violation 'diagnostics:checkers "a checker returned what is not a list of diagnostics" found))
                      (when (and (current?) (buffers:live? b))
                        (let ([s (%entry-source! cs entry found)])
                          (when s (report! s b found version)))))))
                (when (current?)
                  (%checks-running-set! cs (remp (lambda (r) (eq? (cdr r) task)) (%checks-running cs))))))])
    (%checks-running-set! cs (cons (cons entry task) (%checks-running cs)))))

(define (%run-checks! b force?)
  (when (buffers:live? b)
    (let ([cs (%checks-for b)])
      (when force? (%checks-failed-set! cs '()))
      (for-each (lambda (entry) (unless (memq entry (%checks-failed cs)) (%check-one! b cs entry)))
                (%entries b)))))

(define (checking? b)
  (unless (buffers:buffer? b)
    (assertion-violation 'diagnostics:checking? "not a buffer" b))
  (let ([cs (eq-hashtable-ref %checks-of b #f)])
    (and cs (exists (lambda (r) (not (task-done? (cdr r)))) (%checks-running cs)) #t)))

(define (check-failed? b)
  (unless (buffers:buffer? b)
    (assertion-violation 'diagnostics:check-failed? "not a buffer" b))
  (let ([cs (eq-hashtable-ref %checks-of b #f)])
    (and cs (pair? (%checks-failed cs)))))

(commands:define-command (check)
  "Runs the current buffer's checkers now; with C-u, those that raised too."
  (%run-checks! (buffers:current) (and (commands:prefix-argument) #t)))

;; Turning the mode on in a buffer checks it once the code that turned it
;; on has run, as a mode hook adds its checkers after it may turn it on.
(define (%follow-mode!)
  (for-each
    (lambda (b)
      (let ([was? (eq-hashtable-ref %drawn b #f)])
        (%draw! b)
        (when (and (not was?) (%mode-in? b))
          (spawn-task (lambda () (when (and (buffers:live? b) (%mode-in? b)) (%run-checks! b #f)))))))
    (buffers:all)))

(define (%stop-timer! cs)
  (when (%checks-timer cs)
    (cancel-timer! (%checks-timer cs))
    (%checks-timer-set! cs #f)))

(define (%after-edit b edit)
  (when (and (buffers:edit-moves? edit) (fx> (buffers:piece-length (buffers:edit-removed edit)) 0))
    (%drop-emptied! b))
  (when (mode)
    (let ([delay (check-delay)])
      (when delay
        (let ([cs (%checks-for b)])
          (%stop-timer! cs)
          (%checks-timer-set! cs
            (as-module (this-module)
              (run-with-timer delay
                (lambda ()
                  (%checks-timer-set! cs #f)
                  (when (and (buffers:live? b) (%mode-in? b)) (%run-checks! b #f)))))))))))

(define (%after-save b)
  (when (and (%mode-in? b) (buffers:with-buffer b (check-on-save?)))
    (%run-checks! b #f)))

;; A major mode's change drops the buffer's scope and its local checkers
;; with it, whose diagnostics no check would replace.
(define (%after-major-mode b)
  (let ([cs (eq-hashtable-ref %checks-of b #f)] [entries (%entries b)])
    (when cs
      (for-each
        (lambda (r) (unless (memq (car r) entries) (unless (task-done? (cdr r)) (signal-task (cdr r) (%quit)))))
        (%checks-running cs))
      (%checks-running-set! cs (filter (lambda (r) (memq (car r) entries)) (%checks-running cs)))
      (%checks-failed-set! cs (filter (lambda (e) (memq e entries)) (%checks-failed cs)))
      (let-values ([(kept gone) (partition (lambda (s) (memq (car s) entries)) (%checks-sources cs))])
        (%checks-sources-set! cs kept)
        (for-each (lambda (s) (clear! (cdr s) b)) gone))))
  (%draw! b)
  (when (%mode-in? b)
    (spawn-task (lambda () (when (and (buffers:live? b) (%mode-in? b)) (%run-checks! b #f))))))

(define (%after-visit b)
  (let* ([path (files:path b)] [h (and path (hashtable-ref %in-paths path #f))])
    (when h
      (hashtable-delete! %in-paths path)
      (vector-for-each
        (lambda (source) (%report-to-buffer! source b (hashtable-ref h source '()) #f))
        (hashtable-keys h)))))

(define (%killed b)
  (let ([cs (eq-hashtable-ref %checks-of b #f)])
    (when cs
      (%stop-timer! cs)
      (for-each (lambda (r) (unless (task-done? (cdr r)) (signal-task (cdr r) (%quit)))) (%checks-running cs))
      (eq-hashtable-delete! %checks-of b)))
  (when (hashtable-ref %in-buffers b #f)
    (hashtable-delete! %in-buffers b)
    (changed b)))

(define (%move! n)
  (let* ([skip? (pair? (commands:prefix-argument))]
         [n (if skip? (if (fx< n 0) -1 1) n)])
    (unless (fx= n 0)
      (let* ([view (views:current)] [b (views:buffer view)] [p (views:point view)]
             [all (filter (lambda (d) (not (and skip? (memq (diagnostic-severity d) '(info hint))))) (in b))]
             [forward? (fx> n 0)]
             [ahead (if forward?
                        (filter (lambda (d) (fx> (%start-of d) p)) all)
                        (reverse (filter (lambda (d) (fx< (%start-of d) p)) all)))]
             [behind (if forward?
                         (filter (lambda (d) (fx<= (%start-of d) p)) all)
                         (reverse (filter (lambda (d) (fx>= (%start-of d) p)) all)))]
             [order (if (wrap-around?) (append ahead behind) ahead)]
             [k (fx- (fxabs n) 1)])
        (unless (fx< k (length order))
          (error (if forward? 'diagnostics:next 'diagnostics:previous) (if skip? "No more errors or warnings" "No more diagnostics")))
        (let* ([d (list-ref order k)] [at (%start-of d)])
          (views:set-point! view at)
          (ask:message (%join-lines (map text (in b at)))))))))

(define (%join-lines texts)
  (fold-left (lambda (acc t) (if (string=? acc "") t (string-append acc "\n" t))) "" texts))

(commands:define-command (next [n (commands:prefix-number)])
  "Moves point to the start of the Nth diagnostic after point and tells the text of each diagnostic there; C-u, or any prefix that is not a number, moves by one, skipping infos and hints."
  (%move! n))

(commands:define-command (previous [n (commands:prefix-number)])
  "Moves point to the start of the Nth diagnostic before point and tells the text of each diagnostic there; C-u, or any prefix that is not a number, moves by one, skipping infos and hints."
  (%move! (fx- 0 n)))

(add-hook! buffers:after-edit %after-edit)
(add-hook! files:after-save %after-save)
(add-hook! files:after-visit %after-visit)
(add-hook! modes:major-mode-changed %after-major-mode)
(add-hook! buffers:killed %killed)
(for-each
  (lambda (b) (buffers:with-buffer b (when (mode) (add-local-hook! docs-at-point:sources at-point 90))))
  (buffers:all))
