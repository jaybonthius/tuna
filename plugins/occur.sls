#!tuna
(import (search) (isearch) (buffers) (document) (jobs) (views) (layout) (keys) (commands) (modes) (minibuffer)
        (jump-history) (next-error) (pulse) (ask) (faces) (web) (haml))

(define-option context-lines 0 fixnum?
  "How many lines around each match occur:occur lists without a prefix argument; a negative number lists that many before only.")

(define-option jump-to-current-line #f boolean?
  "Whether *Occur* lists the line point was on when it was made, and starts with point at its end.")

(define-saved collect-history '("\\1") (lambda (v) (and (list? v) (for-all string? v))))

(define match 'occur.match)

(define-table keymap "The keys of occur:mode.")

(define-table edit-keymap "The keys of occur:edit-mode.")

(define-table line-keymap "The keys of a listed line, in occur:mode and occur:edit-mode.")

(define-hook mode-hook "Called in each buffer that turns on occur:mode, and on occur:edit-mode before occur:edit-mode-hook.")

(define-hook edit-mode-hook "Called in each buffer that turns on occur:edit-mode.")

(define-hook listed "Called with *Occur* after each listing that has matches, occur:refresh included.")

(modes:define-major-mode mode (parent modes:special) (lighter "Occur") (keymap keymap) (hook mode-hook) (plugin-only #t))

(modes:define-major-mode edit-mode (lighter "Occur-Edit") (keymap edit-keymap) (hook edit-mode-hook) (plugin-only #t))

;; A listed line's source is held by an anchor at its start and anchors
;; around each of its matches, so going to it lands on the match after
;; edits there. Text inserted at the line's start is not listed, so the
;; anchor goes after it.
(define-record-type %entry
  (sealed #t)
  (fields line matches number))

(define-record-type %listing
  (sealed #t)
  (fields source query context template region origin
          (mutable entries) (mutable building?) (mutable job) (mutable scan) (mutable visited)))

(define %listings (make-weak-eq-hashtable))

(define (%listing-of b) (eq-hashtable-ref %listings b #f))

(define (%has-newline? piece)
  (let* ([doc (buffers:piece-document piece)] [n (document:length doc)])
    (let loop ([p 0])
      (and (fx< p n) (or (eqv? (document:token doc p) #\newline) (loop (fx+ p 1)))))))

(define (%node-text doc node)
  (document:text doc (fx+ (document:node-start node) 1) (fx- (document:node-end node) 2)))

;; An edit reaches the source at its offset only while the source line
;; reads as the listed line does, so the offset maps exactly; otherwise
;; it would land in the wrong place.
(define (%consent node edit)
  (cond
    [(or (%has-newline? (buffers:edit-removed edit)) (%has-newline? (buffers:edit-inserted edit)))
     "An occur line takes no line break"]
    [else
     (let* ([b (buffers:edit-buffer edit)] [l (%listing-of b)])
       (cond
         [(or (not l) (%listing-building? l) (not (eq? (modes:major-mode b) edit-mode))) #t]
         [(%listing-template l) "A collected string is not a line of its source"]
         [else
           (let ([e (vector-ref (%listing-entries l) (document:node-attribute node 'entry))] [source (%listing-source l)])
             (or (not (buffers:live? source))
                 (string=? (%source-line source (buffers:anchor-position (%entry-line e)))
                           (%node-text (buffers:document b) node))
                 "The source line changed; g lists it again"))]))]))

(define (%source-line source start)
  (let* ([doc (buffers:document source)] [k (document:line doc start)]
         [last (document:line doc (fx- (document:length doc) 1))]
         [end (if (fx< k last) (fx- (document:line-start doc (fx+ k 1)) 1) (fx- (document:length doc) 1))])
    (buffers:text-between doc start (fxmax start end))))

(define (%prefix number arrow?)
  (let ([s (format "~7@a:" number)])
    (if arrow? (string-append "=>" (substring s 2 (string-length s))) s)))

(define (%draw-line node view)
  (let* ([l (%listing-of (views:buffer view))] [entry (document:node-attribute node 'entry)]
         [arrow? (and l (eqv? (%listing-visited l) entry))])
    (haml (:div.occur-line ([data-face (and (document:node-attribute node 'current?) "match.other")])
            (:span.occur-number ([data-face "shadow"]) (%prefix (document:node-attribute node 'number) arrow?))
            (views:draw-children view node)))))

(define (%draw-context node view)
  (haml (:div.occur-line ([data-face (if (document:node-attribute node 'current?) "match.other" "shadow")])
          (:span.occur-number ([data-face "shadow"]) (%prefix (document:node-attribute node 'number) #f))
          (views:draw-children view node))))

(define (%draw-heading node view)
  (haml (:div.occur-heading (views:draw-children view node))))

(define (%draw-separator node view)
  (haml (:div.occur-separator ([data-face "shadow"]) "-------")))

(buffers:define-kind %listing-root (content nodes))
(buffers:define-kind %heading (draw %draw-heading))
(buffers:define-kind %line (consent %consent) (draw %draw-line) (keymap line-keymap))
(buffers:define-kind %context (draw %draw-context))
(buffers:define-kind %separator (content atom) (stops none) (text (lambda (node) "")) (draw %draw-separator))

;; The buffer takes edits only to its listed lines' text, and only in
;; occur:edit-mode; the plugin itself writes with splice!, which asks no
;; layer.
(buffers:define-layer %read-only (read-only) (sticky before))

(buffers:define-layer %matches (priority 0))

(buffers:define-layer %faces (priority -10))

(define (%line-faces source start end)
  (fold-right
    (lambda (layer acc)
      (fold-right
        (lambda (span acc)
          (let ([face (and (list? (caddr span)) (assq 'face (caddr span)))])
            (if (and face (< (max start (car span)) (min end (cadr span))))
                (cons (list (- (max start (car span)) start) (- (min end (cadr span)) start) (list face)) acc)
                acc)))
        acc (buffers:spans layer start end)))
    '() (buffers:layers source)))

(define (%end-of b) (document:length (buffers:document b)))

(define (%protect! b editing?)
  (let ([l (buffers:layer b %read-only)] [doc (buffers:document b)])
    (buffers:set-spans! l 0 (%end-of b)
      (if editing?
          (let loop ([nodes (%children doc)] [acc '()] [from 0])
            (cond
              [(null? nodes) (reverse (if (< from (%end-of b)) (cons (list from (%end-of b) 'occur) acc) acc))]
              [(eq? (document:node-kind (car nodes)) (%kind-name %line))
               (let ([start (+ (document:node-start (car nodes)) 1)] [end (- (document:node-end (car nodes)) 2)])
                 (loop (cdr nodes) (if (< from start) (cons (list from start 'occur) acc) acc) (+ end 1)))]
              [else (loop (cdr nodes) acc from)]))
          (list (list 0 (%end-of b) 'occur))))))

(define (%kind-name constructor) (buffers:kind-name (buffers:constructor-kind constructor)))

(define (%children doc)
  (let ([root (document:enclosing doc 1)] [acc '()])
    (document:for-each-child root 0 (document:length doc) (lambda (n at) (when (document:node? n) (set! acc (cons n acc)))))
    (reverse acc)))

(define (%kind-nodes doc constructor)
  (filter (lambda (n) (eq? (document:node-kind n) (%kind-name constructor))) (%children doc)))

(define (%line-nodes doc) (%kind-nodes doc %line))

(jobs:define-worker (%group-lines input emit receive)
  (import (document))
  (let* ([doc (vector-ref input 0)] [starts (vector-ref input 1)] [ends (vector-ref input 2)]
         [context (vector-ref input 3)] [extra (vector-ref input 4)] [n (vector-length starts)]
         [before (fxabs context)] [after (fxmax context 0)]
         [last (document:line doc (fx- (document:length doc) 1))])
    (define (line-end k)
      (if (fx< k last) (fx- (document:line-start doc (fx+ k 1)) 1) (fx- (document:length doc) 1)))
    ;; The first line starts at the root's opening, which holds no text.
    (define (line-start k)
      (let skip ([p (document:line-start doc k)])
        (let ([t (document:token doc p)])
          (if (and (fx< p (line-end k)) (document:node? t) (not (document:atom? t))) (skip (fx+ p 1)) p))))
    (let loop ([i 0] [lines '()])
      (if (fx< i n)
          (let* ([k (document:line doc (vector-ref starts i))])
            (let group ([j i] [ranges '()])
              (if (and (fx< j n) (fx= (document:line doc (vector-ref starts j)) k))
                  (group (fx+ j 1) (cons (cons (vector-ref starts j) (fxmin (vector-ref ends j) (line-end k))) ranges))
                  (loop j (cons (list k (reverse ranges)) lines)))))
          (let* ([lines (reverse lines)]
                 [lines (if (and extra (not (assv extra lines)))
                            (list-sort (lambda (a b) (fx< (car a) (car b))) (cons (list extra '()) lines))
                            lines)])
            (emit
              (let expand ([lines lines] [shown 0] [acc '()])
                (if (null? lines)
                    (list->vector (reverse acc))
                    (let* ([k (caar lines)] [from (fxmax 1 (fx- k before) (fx+ shown 1))]
                           [next (if (null? (cdr lines)) (fx+ last 1) (caadr lines))]
                           [to (fxmin last (fx+ k after) (fx- next 1))]
                           [acc (if (and (fx> before 0) (fx> shown 0) (fx> from (fx+ shown 1))) (cons 'separator acc) acc)]
                           [acc (let before ([j from] [acc acc])
                                  (if (fx< j k)
                                      (before (fx+ j 1) (cons (vector j (line-start j) (line-end j) #f) acc))
                                      acc))]
                           [acc (cons (vector k (line-start k) (line-end k) (cadar lines)) acc)]
                           [acc (let after ([j (fx+ k 1)] [acc acc])
                                  (if (fx<= j to)
                                      (after (fx+ j 1) (cons (vector j (line-start j) (line-end j) #f) acc))
                                      acc))])
                      (expand (cdr lines) (fxmax to k) acc))))))))))

(define (%text b start end) (buffers:text-between (buffers:document b) start end))

(define (%described query)
  (let ([style (search:query-style query)])
    (string-append
      (if (or (eq? style search:literal) (eq? style search:regexp))
          ""
          (string-append (string-downcase (search:style-description style)) " "))
      "\"" (search:query-text query) "\"")))

(define (%count-text count)
  (format "~a ~a" count (if (= count 1) "match" "matches")))

(define (%heading-text l count lines)
  (let ([source (%listing-source l)] [query (%listing-query l)] [region (%listing-region l)])
    (string-append
      (format "~a~a for ~a in buffer: ~a"
              (%count-text count)
              (if (= lines count) "" (format " in ~a ~a" lines (if (= lines 1) "line" "lines")))
              (%described query) (buffers:name source))
      (if region (format " within region: ~a-~a" (buffers:anchor-position (car region)) (buffers:anchor-position (cdr region))) "")
      "\n")))

(define (%searched! l count)
  (ask:message (format "Searched 1 buffer; ~a for ~a" (if (= count 0) "no matches" (%count-text count)) (%described (%listing-query l)))))

(define (%current-line l source)
  (and (jump-to-current-line)
       (document:line (buffers:document source) (buffers:anchor-position (%listing-origin l)))))

(define (%discard! b)
  (eq-hashtable-delete! %listings b)
  (when (buffers:live? b) (buffers:kill! b)))

;; A group's matches are none for the line point was on, and #f for a
;; context line.
(define (%fill! b l groups matches)
  (let* ([source (%listing-source l)] [template (%listing-template l)] [here (%current-line l source)]
         [count 0] [lines 0] [entries '()] [entry-count 0] [spans (make-eqv-hashtable)] [line-faces (make-eqv-hashtable)])
    (define (entry! line-start ranges k)
      (set! entries (cons (make-%entry (buffers:anchor-after source line-start)
                                       (map (lambda (r) (cons (buffers:anchor source (car r)) (buffers:anchor-after source (cdr r)))) ranges)
                                       k)
                          entries))
      (set! entry-count (+ entry-count 1))
      (- entry-count 1))
    (define (faces! index start end)
      (let ([faces (%line-faces source start end)])
        (unless (null? faces) (hashtable-set! line-faces index faces))))
    (define (nodes-of g)
      (if (eq? g 'separator)
          (list (vector (%kind-name %separator) '()))
          (let* ([k (vector-ref g 0)] [start (vector-ref g 1)] [end (vector-ref g 2)] [found (vector-ref g 3)]
                 [ranges (or found '())] [current? (eqv? k here)])
            (unless (null? ranges) (set! lines (+ lines 1)))
            (cond
              [(and template (pair? ranges))
               (map (lambda (r)
                      (let ([text (search:expand source (hashtable-ref matches (car r) #f) template count)])
                        (set! count (+ count 1))
                        (list (%kind-name %line) (list (cons 'number k) (cons 'entry (entry! start (list r) k)) (cons 'current? #f))
                              (string-append text "\n"))))
                    ranges)]
              [template '()]
              [(null? ranges)
               (list (list (%kind-name %context) (list (cons 'number k) (cons 'current? current?))
                           (string-append (%text source start end) "\n")))]
              [else
               (let ([index (entry! start ranges k)])
                 (set! count (+ count (length ranges)))
                 (hashtable-set! spans index (map (lambda (r) (cons (- (car r) start) (- (cdr r) start))) ranges))
                 (faces! index start end)
                 (list (list (%kind-name %line) (list (cons 'number k) (cons 'entry index) (cons 'current? current?))
                             (string-append (%text source start end) "\n"))))]))))
    (let ([nodes (apply append (map nodes-of (vector->list groups)))])
      (%searched! l count)
      (if (= count 0)
          (%discard! b)
          (let ([heading (list (%kind-name %heading) '() (%heading-text l count lines))])
            (%listing-entries-set! l (list->vector (reverse entries)))
            (%listing-visited-set! l #f)
            (%listing-building?-set! l #t)
            (buffers:with-silent-edits b
              (buffers:splice! b 1 (- (%end-of b) 1) (apply document:from-datum heading nodes)))
            (%listing-building?-set! l #f)
            (%set-line-spans! b %matches spans (lambda (r) (list (car r) (cdr r) (list (cons 'face match)))))
            (%set-line-spans! b %faces line-faces (lambda (f) f))
            (%protect! b (eq? (modes:major-mode b) edit-mode))
            (when (null? (views:showing b)) (layout:display-buffer b))
            (let* ([doc (buffers:document b)]
                   [current (and here (find (lambda (n) (eqv? (document:node-attribute n 'number) here))
                                            (append (%line-nodes doc) (%kind-nodes doc %context))))]
                   [point (if current (fx- (document:node-end current) 2) (%start-of doc))])
              (for-each (lambda (v) (views:set-point! v point)) (views:showing b)))
            (listed b))))))

(define (%set-line-spans! b layer by-entry span)
  (let ([doc (buffers:document b)])
    (buffers:set-spans! (buffers:layer b layer) 0 (%end-of b)
      (apply append
             (map (lambda (n)
                    (let ([text-start (+ (document:node-start n) 1)])
                      (map (lambda (r) (let ([s (span r)]) (list (+ text-start (car s)) (+ text-start (cadr s)) (caddr s))))
                           (hashtable-ref by-entry (document:node-attribute n 'entry) '()))))
                  (%line-nodes doc))))))

(define (%start-of doc)
  (let ([heading (find (lambda (n) (eq? (document:node-kind n) (%kind-name %heading))) (%children doc))])
    (if heading (fx+ (document:node-start heading) 1) 1)))

(define (%list! b)
  (let* ([l (%listing-of b)] [source (%listing-source l)])
    (if (not (buffers:live? source))
        (begin
          (ask:message (format "Searched 0 buffers (1 killed); no matches for ~a" (%described (%listing-query l))))
          (%discard! b))
        (let* ([doc (buffers:document source)] [region (%listing-region l)])
          (let-values ([(lo hi) (if region
                                    (values (buffers:anchor-position (car region)) (buffers:anchor-position (cdr region)))
                                    (values 0 (document:length doc)))])
            (let ([old (%listing-scan l)]) (when old (search:stop-scan! old)))
            (let ([old (%listing-job l)]) (when old (jobs:stop! old)))
            (%listing-scan-set! l
              (search:scan source (%listing-query l) lo hi lo
                (lambda (scan)
                  (when (and (search:scan-done? scan) (eq? scan (%listing-scan l)))
                    (%listing-scan-set! l #f)
                    (%group! b l (search:scan-matches scan lo hi))))
                0 (document:length doc))))))))

(define (%group! b l matches)
  (let* ([source (%listing-source l)] [doc (buffers:document source)]
         [starts (list->vector (map search:match-start matches))] [ends (list->vector (map search:match-end matches))]
         [here (%current-line l source)])
    (%listing-job-set! l
      (jobs:start %group-lines (vector doc starts ends (%listing-context l) here)
        (lambda (groups)
          (when (buffers:live? b)
            (%listing-job-set! l #f)
            (%fill! b l groups (let ([by-start (make-eqv-hashtable)])
                                 (for-each (lambda (m) (hashtable-set! by-start (search:match-start m) m)) matches)
                                 by-start))))))))

(define (%occur! source view query context template)
  (when (string=? (search:query-text query) "")
    (error 'occur:occur "Occur doesn’t work with the empty regexp"))
  (when (string=? (buffers:name source) "*Occur*")
    (buffers:rename! source (buffers:free-name "*Occur*")))
  (let* ([b (or (buffers:find "*Occur*") (buffers:make "*Occur*" (list (%kind-name %listing-root) '())))]
         [mark (views:mark view)] [point (views:point view)]
         [region (and mark (not (= mark point))
                      (cons (buffers:anchor source (min mark point)) (buffers:anchor-after source (max mark point))))]
         [l (make-%listing source query context template region (buffers:anchor source point) '#() #f #f #f #f)])
    (eq-hashtable-set! %listings b l)
    (unless (eq? (modes:major-mode b) mode) (modes:set-major-mode mode b))
    (%list! b)
    b))

(define (%read-template query buffer)
  (if (> (search:query-group-count query buffer) 0)
      (minibuffer:read (string-append "Regexp to collect (default " (car (collect-history)) "): ")
                       collect-history (car (collect-history)))
      "\\&"))

(define (%read-text question)
  (let ([default (or (and (pair? (search:prompt-regexp-history)) (car (search:prompt-regexp-history)))
                     (and (pair? (search:regexp-history)) (car (search:regexp-history)))
                     (and (pair? (search:history)) (search:regexp-quote (car (search:history)))))])
    (minibuffer:read (if default (string-append question " (default " default "): ") (string-append question ": "))
                     search:prompt-regexp-history default)))

(define (%read-arguments)
  (let ([p (commands:prefix-argument)])
    (if (pair? p)
        (let ([query (search:make-query (%read-text "Collect strings matching regexp") search:regexp)])
          (values query (context-lines) (%read-template query (views:buffer (views:current)))))
        (values (search:make-query (%read-text "List lines matching regexp") search:regexp)
                (if p (commands:prefix-number) (context-lines))
                #f))))

(commands:define-command (occur [(query context template) (%read-arguments)])
  "Lists the lines of the current buffer, or of the region, that match QUERY in *Occur*, with CONTEXT lines around each, before only when it is negative; with TEMPLATE, what search:expand makes of it for each match in place of the lines."
  (unless (search:query? query) (assertion-violation 'occur:occur "not a query" query))
  (unless (fixnum? context) (assertion-violation 'occur:occur "not a number of lines" context))
  (unless (or (not template) (string? template)) (assertion-violation 'occur:occur "neither a string nor #f" template))
  (let ([view (views:current)])
    (%occur! (views:buffer view) view query context template)))

(define (%search-arguments)
  (let ([p (commands:prefix-argument)])
    (cond
      [(pair? p) (values (context-lines) #t)]
      [p (values (commands:prefix-number) #f)]
      [else (values (context-lines) #f)])))

;; The search keeps running, as Emacs's does, so a template is read with
;; its keymap off, as isearch:edit-string reads.
(commands:define-command (isearch-occur [(context collect?) (%search-arguments)])
  "Lists the lines that match the search's query, keeping the search; with COLLECT?, collects as occur:occur does under C-u."
  (let* ([s (or (isearch:current (web:current-client)) (assertion-violation 'occur:isearch-occur "no search runs for this client"))]
         [view (isearch:search-view s)] [query (isearch:search-query s)]
         [template (and collect? (isearch:call-suspended s (lambda () (%read-template query (views:buffer view)))))])
    (%occur! (views:buffer view) view query context template)))

(define (%entry-at b position)
  (let* ([doc (buffers:document b)] [l (%listing-of b)])
    (and l
         (let ([n (find (lambda (n) (<= (document:node-start n) position (document:node-end n))) (%line-nodes doc))])
           (and n (cons (document:node-attribute n 'entry) (vector-ref (%listing-entries l) (document:node-attribute n 'entry))))))))

(define (%target who view position)
  (let* ([b (views:buffer view)] [l (%listing-of b)] [found (and l (%entry-at b position))])
    (unless found (error who "No occurrence on this line"))
    (unless (buffers:live? (%listing-source l)) (error who "Buffer for this occurrence was killed"))
    (values l (car found) (cdr found))))

(define (%match-start e)
  (buffers:anchor-position (if (pair? (%entry-matches e)) (car (car (%entry-matches e))) (%entry-line e))))

;; A view split for the source records the source at the point it was
;; shown at, so M-, always undoes the jump; a view that showed a buffer
;; records that, as diagnostics-list does.
(define (%visit! who view position select? highlight? record?)
  (let-values ([(l index e) (%target who view position)])
    (let* ([source (%listing-source l)]
           [before (map (lambda (v) (cons v (and (views:buffer v) (cons (views:buffer v) (views:point v))))) (layout:views))]
           [target (layout:display-buffer source layout:display-in-other-view)])
      (%listing-visited-set! l index)
      (when select? (layout:select! target))
      (when record?
        (let ([left (assq target before)])
          (if (and left (cdr left))
              (jump-history:push! (cadr left) (cddr left))
              (jump-history:push! source (views:point target)))))
      (views:set-point! target (%match-start e))
      (let ([ranges (if highlight?
                        (map (lambda (m) (list (buffers:anchor-position (car m)) (buffers:anchor-position (cdr m)))) (%entry-matches e))
                        '())])
        ;; A show is a step, not a jump, so it marks without recentring,
        ;; as Emacs's occur-mode-display-occurrence only moves point.
        (if record?
            (parameterize ([jump-history:place-ranges ranges])
              (jump-history:after-jump target))
            (pulse:highlight! target ranges)))
      target)))

(commands:define-command (goto-occurrence)
  "Shows the source of the line at point as pop-to-buffer does and selects its view, at the line's first match, which is highlighted."
  (let ([view (views:current)])
    (%visit! 'occur:goto-occurrence view (views:point view) #t #t #t)))

(commands:define-command (mouse-goto-occurrence [event (keys:command-event)])
  "As occur:goto-occurrence, for the listed line clicked, after selecting its view."
  (unless (keys:event? event)
    (assertion-violation 'occur:mouse-goto-occurrence "not a mouse event" event))
  (let* ([posn (keys:event-start event)] [view (views:posn-view posn)] [p (views:posn-point posn)])
    (unless (and view p) (error 'occur:mouse-goto-occurrence "No occurrence on this line"))
    (layout:select! view)
    (%visit! 'occur:mouse-goto-occurrence view p #t #t #t)))

(commands:define-command (goto-occurrence-other-view)
  "Shows the source of the line at point in a view other than *Occur*'s and selects it, at the line's first match."
  (let ([view (views:current)])
    (%visit! 'occur:goto-occurrence-other-view view (views:point view) #t #f #t)))

(commands:define-command (display-occurrence)
  "Shows the line's first match in another view, highlighted, and keeps *Occur* selected."
  (let ([view (views:current)])
    (%visit! 'occur:display-occurrence view (views:point view) #f #t #f)))

(define (%match-ends b)
  (map cadr (buffers:spans (buffers:layer b %matches) 0 (%end-of b))))

(define (%find-match b from n)
  (let ([ends (%match-ends b)])
    (if (> n 0)
        (let ([after (filter (lambda (e) (> e from)) ends)])
          (and (>= (length after) n) (list-ref after (- n 1))))
        (let ([before (reverse (filter (lambda (e) (< e from)) ends))])
          (and (>= (length before) (- n)) (list-ref before (- (- n) 1)))))))

(define (%move! who n)
  (unless (= n 0)
    (let* ([view (views:current)] [b (views:buffer view)] [p (%find-match b (views:point view) n)])
      (unless p (error who (if (> n 0) "No more matches" "No earlier matches")))
      (views:set-point! view p))))

(commands:define-command (next [n (commands:prefix-number)])
  "Moves point to the end of the nth next match listed, match by match; backward for a negative n."
  (%move! 'occur:next n))

(commands:define-command (previous [n (commands:prefix-number)])
  "Moves point to the end of the nth previous match listed; forward for a negative n."
  (%move! 'occur:previous (- n)))

(define (%step! who n)
  (let* ([view (views:current)] [b (views:buffer view)] [doc (buffers:document b)] [point (views:point view)]
         [line (document:line doc point)]
         [last (document:line doc (fx- (document:length doc) 1))]
         [from (cond
                 [(< n 0) (document:line-start doc line)]
                 [(fx< line last) (fx- (document:line-start doc (fx+ line 1)) 1)]
                 [else (%end-of b)])]
         [p (%find-match b from n)])
    (unless p (error who "No more matches"))
    (views:set-point! view p)
    (%visit! who view p #f #t #f)
    (next-error:tell-locus b n)))

(commands:define-command (show-next [n (commands:prefix-number)])
  "Moves n matches forward from the line's end and shows that match's line in another view, highlighted; *Occur* stays selected."
  (%step! 'occur:show-next n))

(commands:define-command (show-previous [n (commands:prefix-number)])
  "As occur:show-next, backward from the line's start."
  (%step! 'occur:show-previous (- n)))

(commands:define-command (rename-buffer [unique? (commands:prefix-argument)])
  "Renames *Occur* after its source, so the next occur:occur makes a new one; with UNIQUE?, a name not in use."
  (let* ([b (buffers:current)] [l (or (%listing-of b) (assertion-violation 'occur:rename-buffer "not an occur buffer" b))]
         [name (string-append "*Occur: " (buffers:name (%listing-source l)) "*")])
    (cond
      [(string=? name (buffers:name b)) (void)]
      [unique? (buffers:rename! b (buffers:free-name name))]
      [(buffers:find name) (error 'occur:rename-buffer (format "Buffer name ‘~a’ is in use" name))]
      [else (buffers:rename! b name)])))

(commands:define-command (refresh)
  "Lists the lines again from the source as it is now."
  (let ([b (buffers:current)])
    (unless (%listing-of b) (assertion-violation 'occur:refresh "not an occur buffer" b))
    (%list! b)))

(commands:define-command (edit)
  "Switches *Occur* to occur:edit-mode."
  (let ([b (buffers:current)])
    (unless (%listing-of b) (assertion-violation 'occur:edit "not an occur buffer" b))
    (modes:set-major-mode edit-mode b)
    (%protect! b #t)
    (ask:message "Editing: Type C-c C-c to return to Occur mode.")))

(commands:define-command (finish-edit)
  "Switches back to occur:mode."
  (let ([b (buffers:current)])
    (modes:set-major-mode mode b)
    (%protect! b #f)
    (ask:message "Switching to Occur mode.")))

;; An undo in *Occur* is an edit too, so it reaches the source.
(define (%mirror! b edit)
  (let ([l (%listing-of b)])
    (when (and l (not (%listing-building? l)) (eq? (modes:major-mode b) edit-mode))
      (let* ([doc (buffers:document b)] [p (buffers:edit-start edit)]
             [n (find (lambda (n) (< (document:node-start n) p (document:node-end n))) (%line-nodes doc))])
        (when n
          (let* ([e (vector-ref (%listing-entries l) (document:node-attribute n 'entry))]
                 [source (%listing-source l)]
                 [at (+ (buffers:anchor-position (%entry-line e)) (- p (+ (document:node-start n) 1)))]
                 [inserted (buffers:piece-text (buffers:edit-inserted edit))])
            (guard (c [(buffers:refused? c) (ask:message (format "Buffer ‘~a’ is read only." (buffers:name source)))])
              (buffers:replace! source at (+ at (buffers:piece-length (buffers:edit-removed edit))) inserted)
              (let ([shown (or (find (lambda (v) (not (eq? v (views:current)))) (views:showing source))
                               (layout:display-buffer source layout:display-in-other-view))])
                (views:set-point! shown (+ at (string-length inserted)))
                (views:scroll-to! shown (views:point shown) (views:align center))))))))))

(define (%set-revert) (set-option-local! buffers:revert-function refresh))

(define (%as-occur-mode) (mode-hook))

(add-hook! mode-hook %set-revert)
(add-hook! edit-mode-hook %as-occur-mode -100)
(add-hook! buffers:after-edit %mirror!)
(keys:bind! keys:global "M-s o" occur)
(keys:bind! isearch:keymap "M-s o" isearch-occur)
(keys:bind! keymap "RET" goto-occurrence)
(keys:bind! keymap "C-c C-c" goto-occurrence)
(keys:bind! keymap "o" goto-occurrence-other-view)
(keys:bind! keymap "C-o" display-occurrence)
(keys:bind! keymap "M-n" next)
(keys:bind! keymap "M-p" previous)
(keys:bind! keymap "n" show-next)
(keys:bind! keymap "p" show-previous)
(keys:bind! keymap "r" rename-buffer)
(keys:bind! keymap "e" edit)
(keys:bind! edit-keymap "C-c C-c" finish-edit)
(keys:bind! edit-keymap "C-o" display-occurrence)
(keys:bind! line-keymap "<mouse-1>" mouse-goto-occurrence)
(keys:bind! line-keymap "<mouse-2>" mouse-goto-occurrence)
(table-set! web:stylesheets 'occur "occur/occur.css")
