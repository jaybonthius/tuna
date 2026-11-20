#!tuna
(import (search) (isearch) (buffers) (document) (jobs) (views) (layout) (keys) (commands) (modes) (minibuffer)
        (jump-history) (faces) (web) (haml))

(define-option context-lines 0 (lambda (v) (and (fixnum? v) (fx>= v 0)))
  "How many lines around each match occur:occur lists without a prefix argument.")

(define-option jump-to-current-line #f boolean?
  "Whether *Occur* lists the line point was on when it was made, and starts with point there.")

(define match 'occur.match)

(define-table keymap "The keys of occur:mode.")

(define-table edit-keymap "The keys of occur:edit-mode.")

(define-hook mode-hook "Called in each buffer that turns on occur:mode.")

(define-hook edit-mode-hook "Called in each buffer that turns on occur:edit-mode.")

(modes:define-major-mode mode (parent modes:special) (lighter "Occur") (keymap keymap) (hook mode-hook))

(modes:define-major-mode edit-mode (lighter "Occur-Edit") (keymap edit-keymap) (hook edit-mode-hook))

;; A listed line's source is held by anchors at its start and at its
;; first match, so going to it lands on the match after edits there. Text
;; inserted at the line's start is not listed, so the anchor goes after
;; it, and an edit in place lands where the listed text has it.
(define-record-type %entry
  (sealed #t)
  (fields line match number))

(define-record-type %listing
  (sealed #t)
  (fields source query context template region origin
          (mutable entries) (mutable building?) (mutable job) (mutable scan)))

(define %listings (make-weak-eq-hashtable))

(define (%listing-of b) (eq-hashtable-ref %listings b #f))

(define (%refuse-newlines node edit)
  (not (or (%has-newline? (buffers:edit-removed edit)) (%has-newline? (buffers:edit-inserted edit)))))

(define (%has-newline? piece)
  (let* ([doc (buffers:piece-document piece)] [n (document:length doc)])
    (let loop ([p 0])
      (and (fx< p n) (or (eqv? (document:token doc p) #\newline) (loop (fx+ p 1)))))))

(define (%draw-line node view)
  (let ([number (document:node-attribute node 'number)] [context? (document:node-attribute node 'context?)]
        [current? (document:node-attribute node 'current?)])
    (haml (:div.occur-line ([data-face (cond [current? "match.other"] [context? "shadow"] [else #f])])
            (:span.occur-number ([data-face "shadow"]) (format "~7@a:" number))
            (views:draw-children view node)))))

(define (%draw-separator node view)
  (haml (:div.occur-separator ([data-face "shadow"]) "-------")))

(buffers:define-kind %listing-root (content nodes))
(buffers:define-kind %heading)
(buffers:define-kind %line (consent %refuse-newlines) (draw %draw-line))
(buffers:define-kind %separator (content atom) (stops none) (text (lambda (node) "")) (draw %draw-separator))

;; The buffer takes edits only to its lines' text, and only in
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

(define (%line-nodes doc)
  (filter (lambda (n) (eq? (document:node-kind n) (%kind-name %line))) (%children doc)))

(jobs:define-worker (%group-lines input emit receive)
  (import (document))
  (let* ([doc (vector-ref input 0)] [starts (vector-ref input 1)] [ends (vector-ref input 2)]
         [context (vector-ref input 3)] [extra (vector-ref input 4)] [n (vector-length starts)]
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
                    (let* ([k (caar lines)] [from (fxmax 1 (fx- k context) (fx+ shown 1))]
                           [next (if (null? (cdr lines)) (fx+ last 1) (caadr lines))]
                           [to (fxmin last (fx+ k context) (fx- next 1))]
                           [acc (if (and (fx> context 0) (fx> shown 0) (fx> from (fx+ shown 1))) (cons 'separator acc) acc)]
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

(define (%heading-text l count lines)
  (let ([source (%listing-source l)] [query (%listing-query l)] [region (%listing-region l)])
    (string-append
      (format "~a ~a~a for \"~a\" in buffer: ~a"
              count (if (= count 1) "match" "matches")
              (if (= lines count) "" (format " in ~a ~a" lines (if (= lines 1) "line" "lines")))
              (search:query-text query) (buffers:name source))
      (if region (format " within region: ~a-~a" (buffers:anchor-position (car region)) (buffers:anchor-position (cdr region))) "")
      "\n")))

(define (%current-line l source)
  (and (jump-to-current-line)
       (document:line (buffers:document source) (buffers:anchor-position (%listing-origin l)))))

;; A group's matches are none for the line point was on, and #f for a
;; context line.
(define (%fill! b l groups matches)
  (let* ([source (%listing-source l)] [template (%listing-template l)] [here (%current-line l source)]
         [count 0] [lines 0] [entries '()] [listed 0] [spans (make-eqv-hashtable)] [line-faces (make-eqv-hashtable)])
    (define (entry! line-start match-start number)
      (set! entries (cons (make-%entry (buffers:anchor-after source line-start) (and match-start (buffers:anchor source match-start)) number)
                          entries))
      (set! listed (+ listed 1))
      (- listed 1))
    (define (line-node k index context? current? text)
      (list (%kind-name %line) (list (cons 'number k) (cons 'entry index) (cons 'context? context?) (cons 'current? current?))
            (string-append text "\n")))
    (define (nodes-of g)
      (if (eq? g 'separator)
          (list (vector (%kind-name %separator) '()))
          (let* ([k (vector-ref g 0)] [start (vector-ref g 1)] [end (vector-ref g 2)] [found (vector-ref g 3)]
                 [ranges (or found '())] [current? (and found (null? found))])
            (unless (null? ranges) (set! lines (+ lines 1)))
            (cond
              [(and template (pair? ranges))
               (map (lambda (r)
                      (let ([text (search:expand source (hashtable-ref matches (car r) #f) template count)])
                        (set! count (+ count 1))
                        (line-node k (entry! start (car r) k) #f #f text)))
                    ranges)]
              [template '()]
              [else
               (let ([index (entry! start (and (pair? ranges) (caar ranges)) k)])
                 (set! count (+ count (length ranges)))
                 (unless (null? ranges)
                   (hashtable-set! spans index (map (lambda (r) (cons (- (car r) start) (- (cdr r) start))) ranges)))
                 (let ([faces (%line-faces source start end)])
                   (unless (null? faces) (hashtable-set! line-faces index faces)))
                 (list (line-node k index (not found) current? (%text source start end))))]))))
    (let* ([nodes (apply append (map nodes-of (vector->list groups)))]
           [heading (list (%kind-name %heading) '() (%heading-text l count lines))])
      (%listing-entries-set! l (list->vector (reverse entries)))
      (%listing-building?-set! l #t)
      (buffers:with-silent-edits b
        (buffers:splice! b 1 (- (%end-of b) 1) (apply document:from-datum heading nodes)))
      (%listing-building?-set! l #f)
      (let ([doc (buffers:document b)])
        (buffers:set-spans! (buffers:layer b %matches) 0 (%end-of b)
          (apply append
                 (map (lambda (n)
                        (let ([text-start (+ (document:node-start n) 1)])
                          (map (lambda (r) (list (+ text-start (car r)) (+ text-start (cdr r)) (list (cons 'face match))))
                               (hashtable-ref spans (document:node-attribute n 'entry) '()))))
                      (%line-nodes doc)))))
      (let ([doc (buffers:document b)])
        (buffers:set-spans! (buffers:layer b %faces) 0 (%end-of b)
          (apply append
                 (map (lambda (n)
                        (let ([text-start (+ (document:node-start n) 1)])
                          (map (lambda (f) (list (+ text-start (car f)) (+ text-start (cadr f)) (caddr f)))
                               (hashtable-ref line-faces (document:node-attribute n 'entry) '()))))
                      (%line-nodes doc)))))
      (%protect! b (eq? (modes:major-mode b) edit-mode))
      (let ([target (and here (find (lambda (n) (= (document:node-attribute n 'number) here)) (%line-nodes (buffers:document b))))])
        (for-each (lambda (v) (views:set-point! v (if target (+ (document:node-start target) 1) (%first-line b))))
                  (views:showing b))))))

(define (%first-line b)
  (let ([nodes (%line-nodes (buffers:document b))])
    (if (null? nodes) 1 (+ (document:node-start (car nodes)) 1))))

(define (%list! b)
  (let* ([l (%listing-of b)] [source (%listing-source l)] [doc (buffers:document source)] [region (%listing-region l)])
    (let-values ([(lo hi) (if region
                              (values (document:line-start doc (document:line doc (buffers:anchor-position (car region))))
                                      (buffers:anchor-position (cdr region)))
                              (values 0 (document:length doc)))])
      (let ([old (%listing-scan l)]) (when old (search:stop-scan! old)))
      (let ([old (%listing-job l)]) (when old (jobs:stop! old)))
      (%listing-scan-set! l
        (search:scan source (%listing-query l) lo hi lo
          (lambda (scan)
            (when (and (search:scan-done? scan) (eq? scan (%listing-scan l)))
              (%listing-scan-set! l #f)
              (%group! b l (search:scan-matches scan lo hi))))
          0 (document:length doc))))))

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
  (let* ([b (or (buffers:find "*Occur*") (buffers:make "*Occur*" (list (%kind-name %listing-root) '())))]
         [mark (views:mark view)] [point (views:point view)]
         [region (and mark (not (= mark point))
                      (cons (buffers:anchor source (min mark point)) (buffers:anchor-after source (max mark point))))]
         [l (make-%listing source query context template region (buffers:anchor source point) '#() #f #f #f)])
    (eq-hashtable-set! %listings b l)
    (unless (eq? (modes:major-mode b) mode) (modes:set-major-mode mode b))
    (%list! b)
    (layout:display-buffer b)
    b))

(define (%read-template)
  (minibuffer:read "Text to collect (\\1 for a group): " #f "\\&"))

(define (%read-query)
  (let* ([default (or (and (pair? (search:prompt-regexp-history)) (car (search:prompt-regexp-history)))
                      (and (pair? (search:regexp-history)) (car (search:regexp-history)))
                      (and (pair? (search:history)) (search:regexp-quote (car (search:history)))))]
         [text (minibuffer:read (if default (string-append "List lines matching regexp (default " default "): ") "List lines matching regexp: ")
                                search:prompt-regexp-history default)])
    (search:make-query text search:regexp)))

(define (%context-arg)
  (let ([p (commands:prefix-argument)])
    (if (and p (not (pair? p))) (commands:prefix-number) (context-lines))))

(define (%template-arg)
  (and (pair? (commands:prefix-argument)) (%read-template)))

(commands:define-command (occur [query (%read-query)] [context (%context-arg)] [template (%template-arg)])
  "Lists the lines of the current buffer, or of the region, that match QUERY in *Occur*, with CONTEXT lines around each; with TEMPLATE, what search:expand makes of it for each match in place of the lines."
  (unless (search:query? query) (assertion-violation 'occur:occur "not a query" query))
  (unless (and (fixnum? context) (fx>= context 0)) (assertion-violation 'occur:occur "not a number of lines" context))
  (unless (or (not template) (string? template)) (assertion-violation 'occur:occur "neither a string nor #f" template))
  (let ([view (views:current)])
    (%occur! (views:buffer view) view query context template)))

(commands:define-command (isearch-occur [context (%context-arg)])
  "Ends the search and lists the lines that match its query."
  (let* ([s (or (isearch:current (web:current-client)) (assertion-violation 'occur:isearch-occur "no search runs for this client"))]
         [view (isearch:search-view s)] [query (isearch:search-query s)])
    (isearch:end! s)
    (%occur! (views:buffer view) view query context #f)))

(define (%entry-at b position)
  (let* ([doc (buffers:document b)] [l (%listing-of b)])
    (and l
         (let ([n (find (lambda (n) (<= (document:node-start n) position (document:node-end n))) (%line-nodes doc))])
           (and n (vector-ref (%listing-entries l) (document:node-attribute n 'entry)))))))

(define (%target who)
  (let* ([view (views:current)] [b (views:buffer view)] [l (%listing-of b)]
         [e (and l (%entry-at b (views:point view)))])
    (unless e (error who "No occurrence on this line"))
    (values view b (%listing-source l) (buffers:anchor-position (or (%entry-match e) (%entry-line e))))))

(define (%show-in! view source position)
  (unless (eq? (views:buffer view) source) (views:set-buffer! view source))
  (views:set-point! view position))

(commands:define-command (goto-occurrence)
  "Shows the source of the line at point in the selected view and moves point to its match."
  (let-values ([(view b source position) (%target 'occur:goto-occurrence)])
    (jump-history:push! b (views:point view))
    (layout:switch-to-buffer source)
    (views:set-point! (layout:selected-view) position)))

(commands:define-command (goto-occurrence-other-view)
  "As occur:goto-occurrence, in another view."
  (let-values ([(view b source position) (%target 'occur:goto-occurrence-other-view)])
    (let ([other (layout:display-buffer source)])
      (jump-history:push! source (views:point other))
      (views:set-point! other position)
      (layout:select! other))))

(define (%display! who)
  (let-values ([(view b source position) (%target who)])
    (let ([other (layout:display-buffer source)])
      (views:set-point! other position)
      (layout:select! view))))

(commands:define-command (display-occurrence)
  "Shows the line's match in another view and keeps point in *Occur*."
  (%display! 'occur:display-occurrence))

(define (%move! who n)
  (let* ([view (views:current)] [b (views:buffer view)] [doc (buffers:document b)] [point (views:point view)]
         [nodes (filter (lambda (node) (not (or (document:node-attribute node 'context?) (document:node-attribute node 'current?)))) (%line-nodes doc))]
         [starts (map (lambda (node) (+ (document:node-start node) 1)) nodes)])
    (let loop ([k (abs n)] [p point])
      (if (= k 0)
          (views:set-point! view p)
          (let ([next (if (> n 0)
                          (find (lambda (s) (> s p)) starts)
                          (let ([before (filter (lambda (s) (< s (if (= p point) (%line-start-at doc p starts) p))) starts)])
                            (and (pair? before) (car (last-pair before)))))])
            (if next
                (loop (- k 1) next)
                (error who (if (> n 0) "No more matches" "No earlier matches"))))))))

(define (%line-start-at doc p starts)
  (let ([at (filter (lambda (s) (<= s p)) starts)])
    (if (null? at) p (car (last-pair at)))))

(commands:define-command (next [n (commands:prefix-number)])
  "Moves point to the nth next listed match."
  (%move! 'occur:next n))

(commands:define-command (previous [n (commands:prefix-number)])
  "Moves point to the nth previous listed match."
  (%move! 'occur:previous (- n)))

(commands:define-command (show-next [n (commands:prefix-number)])
  "Moves as occur:next, then shows the match."
  (%move! 'occur:show-next n)
  (%display! 'occur:show-next))

(commands:define-command (show-previous [n (commands:prefix-number)])
  "Moves as occur:previous, then shows the match."
  (%move! 'occur:show-previous (- n))
  (%display! 'occur:show-previous))

(commands:define-command (rename-buffer)
  "Renames *Occur* after its source, so the next occur:occur makes a new one."
  (let* ([b (buffers:current)] [l (or (%listing-of b) (assertion-violation 'occur:rename-buffer "not an occur buffer" b))])
    (buffers:rename! b (string-append "*Occur: " (buffers:name (%listing-source l)) "*"))))

(commands:define-command (refresh)
  "Lists the lines again from the sources as they are now."
  (let ([b (buffers:current)])
    (unless (%listing-of b) (assertion-violation 'occur:refresh "not an occur buffer" b))
    (%list! b)))

(commands:define-command (edit)
  "Switches *Occur* to occur:edit-mode."
  (let ([b (buffers:current)])
    (unless (%listing-of b) (assertion-violation 'occur:edit "not an occur buffer" b))
    (modes:set-major-mode edit-mode b)
    (%protect! b #t)))

(commands:define-command (finish-edit)
  "Switches back to occur:mode."
  (let ([b (buffers:current)])
    (modes:set-major-mode mode b)
    (%protect! b #f)))

;; An edit to a listed line is made at the same place in its source line,
;; as Emacs's occur-after-change-function does; an undo in *Occur* is an
;; edit too, so it reaches the source.
(define (%mirror! b edit)
  (let ([l (%listing-of b)])
    (when (and l (not (%listing-building? l)) (eq? (modes:major-mode b) edit-mode))
      (let* ([doc (buffers:document b)] [p (buffers:edit-start edit)]
             [n (find (lambda (n) (< (document:node-start n) p (document:node-end n))) (%line-nodes doc))])
        (when n
          (let* ([e (vector-ref (%listing-entries l) (document:node-attribute n 'entry))]
                 [offset (- p (+ (document:node-start n) 1))]
                 [at (+ (buffers:anchor-position (%entry-line e)) offset)]
                 [removed (buffers:piece-length (buffers:edit-removed edit))]
                 [inserted (buffers:piece-text (buffers:edit-inserted edit))])
            (buffers:replace! (%listing-source l) at (+ at removed) inserted)))))))

(define (%set-revert) (set-option-local! buffers:revert-function refresh))

(add-hook! mode-hook %set-revert)
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
(table-set! web:stylesheets 'occur "occur/occur.css")
