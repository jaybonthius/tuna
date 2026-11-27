#!tuna
(import (buffers) (document) (views) (layout) (editing) (files) (commands) (keys) (ask) (jump-history) (hooks) (options))

(define-record-type (%backend %make-backend %backend?)
  (sealed #t)
  (fields name identifier-at-point identifiers definitions references apropos))

(define (%check-and-make-backend name identifier-at-point identifiers definitions references apropos)
  (unless (string? name)
    (assertion-violation 'xref:backend "not a string" name))
  (for-each (lambda (p) (unless (or (not p) (procedure? p)) (assertion-violation 'xref:backend "not a procedure" p)))
            (list identifier-at-point identifiers definitions references apropos))
  (%make-backend name identifier-at-point identifiers definitions references apropos))

(define-syntax backend
  (lambda (x)
    (define (invalid c) (syntax-violation 'xref:backend "invalid clause" x c))
    (syntax-case x ()
      [(_ name clause ...)
       (let loop ([clauses #'(clause ...)] [given '()])
         (define (given-or-false n) (let ([g (assq n given)]) (if g (cdr g) #'#f)))
         (if (null? clauses)
             #`(%check-and-make-backend name #,(given-or-false 'identifier-at-point) #,(given-or-false 'identifiers)
                                        #,(given-or-false 'definitions) #,(given-or-false 'references)
                                        #,(given-or-false 'apropos))
             (let* ([c (car clauses)]
                    [n (syntax-case c () [(k . _) (identifier? #'k) (syntax->datum #'k)] [_ (invalid c)])])
               (when (assq n given)
                 (syntax-violation 'xref:backend "clause given twice" x c))
               (loop (cdr clauses)
                     (cons (case n
                             [(identifier-at-point identifiers definitions references apropos)
                              (syntax-case c () [(_ e) (cons n #'e)] [_ (invalid c)])]
                             [else (invalid c)])
                           given)))))])))

(hooks:define-hook backends
  "Called with the current view, in order, until an entry returns a backend.")

(define-record-type (%item %make-item item?)
  (sealed #t)
  (fields (immutable summary item-summary) (immutable path item-path) (immutable line item-line)
          (immutable column item-column) (immutable kind item-kind)))

(define make-item
  (case-lambda
    [(summary path line column) (make-item summary path line column #f)]
    [(summary path line column kind)
     (define who 'xref:make-item)
     (unless (string? summary) (assertion-violation who "not a string" summary))
     (unless (and (string? path) (fx> (string-length path) 0) (char=? (string-ref path 0) #\/))
       (assertion-violation who "not an absolute path" path))
     (unless (and (fixnum? line) (fx>= line 1)) (assertion-violation who "not a line number" line))
     (unless (and (fixnum? column) (fx>= column 0)) (assertion-violation who "not a column" column))
     (unless (or (not kind) (string? kind)) (assertion-violation who "neither a string nor #f" kind))
     (%make-item summary path line column kind)]))

(define (%backend-for who)
  (%backend-in who (views:current)))

(define (%backend-in who view)
  (or (exists (lambda (entry)
                (let ([b (entry view)])
                  (unless (or (not b) (%backend? b))
                    (assertion-violation 'xref:backends "an entry returned neither a backend nor #f" b))
                  b))
              (views:call-with-view view (lambda () (hooks:entries backends))))
      (error who "No xref backend")))

(define (%ask-of who b field what)
  (or (field b)
      (error who (format "The xref backend ~a cannot ~a" (%backend-name b) what))))

(define (%items who b field what argument)
  (let ([items ((%ask-of who b field what) argument)])
    (unless (and (list? items) (for-all item? items))
      (assertion-violation who "a backend returned what is not a list of items" items))
    items))

(define (go-to-item item)
  (unless (item? item)
    (assertion-violation 'xref:go-to-item "not an item" item))
  (let ([b (files:visit (item-path item))])
    (layout:switch-to-buffer b)
    (let ([view (layout:selected-view)])
      (views:set-point! view (editing:line-position b (item-line item) (item-column item)))
      (jump-history:after-jump view))))

(define (choose-and-go items title)
  (unless (and (pair? items) (for-all item? items))
    (assertion-violation 'xref:choose-and-go "not a list of items" items))
  (go-to-item
    (if (null? (cdr items))
        (car items)
        (ask:choice (string-append title ": ")
          (map (lambda (item)
                 (cons (format "~a:~a: ~a" (files:abbreviated-path (item-path item)) (item-line item) (item-summary item))
                       item))
               items)))))

(define (apropos view pattern)
  (unless (views:view? view)
    (assertion-violation 'xref:apropos "not a view" view))
  (unless (string? pattern)
    (assertion-violation 'xref:apropos "not a string" pattern))
  (%items 'xref:apropos (%backend-in 'xref:apropos view) %backend-apropos "search identifiers" pattern))

(options:define-option definitions-display choose-and-go procedure?
  "Shows the items of xref:find-definitions: a procedure of a list of one or more items and a title.")

(options:define-option references-display choose-and-go procedure?
  "Shows the items of xref:find-references, xref:find-apropos and xref:show-items, as xref:definitions-display shows definitions.")

(options:define-option auto-jump-to-first-definition? #f boolean?
  "Whether xref:find-definitions goes to the first of several definitions without asking.")

(options:define-option auto-jump-to-first-reference? #f boolean?
  "Whether xref:find-references goes to the first of several references without asking.")

;; The place is recorded once the display returns, so a cancel while
;; choosing records nothing.
(define (%show! items title display auto-jump?)
  (let* ([view (layout:selected-view)] [left (views:buffer view)] [at (views:point view)])
    (if auto-jump? (go-to-item (car items)) (display items title))
    (when (buffers:live? left)
      (jump-history:push! left at))))

(define (show-items items title)
  (unless (and (list? items) (for-all item? items))
    (assertion-violation 'xref:show-items "not a list of items" items))
  (unless (string? title)
    (assertion-violation 'xref:show-items "not a string" title))
  (unless (null? items)
    (%show! items title (references-display) #f)))

(define (%asks? command)
  (let ([which (prompt-for-identifier)])
    (or (eq? which #t) (and (list? which) (memq command which) #t))))

(define (%read-identifier who command question)
  (let* ([b (%backend-for who)] [at-point (%backend-identifier-at-point b)]
         [here (and at-point (at-point (views:current)))])
    (if (and here (not (commands:prefix-argument)) (not (%asks? command)))
        here
        (ask:line-with-candidates (if here (string-append question " (default " here "): ") (string-append question ": "))
          (let ([identifiers (%backend-identifiers b)])
            (if identifiers (lambda (input) (identifiers input)) '()))
          here))))

(commands:define-command (find-definitions [identifier (%read-identifier 'xref:find-definitions find-definitions "Find definitions of")])
  "Shows the definitions of IDENTIFIER, by default the one at point, and records the place point left in jump-history."
  (let ([items (%items 'xref:find-definitions (%backend-for 'xref:find-definitions) %backend-definitions "find definitions" identifier)])
    (when (null? items)
      (error 'xref:find-definitions (string-append "No definitions found for: " identifier)))
    (%show! items (string-append "Definitions of " identifier) (definitions-display) (auto-jump-to-first-definition?))))

(commands:define-command (find-definitions-other-view [identifier (%read-identifier 'xref:find-definitions-other-view find-definitions-other-view "Find definitions of")])
  "As xref:find-definitions, in another view, which it selects."
  (layout:call-with-overriding-action layout:display-in-other-view (lambda () (find-definitions identifier))))

(commands:define-command (find-references [identifier (%read-identifier 'xref:find-references find-references "Find references of")])
  "Shows the places that use IDENTIFIER, by default the one at point, and records the place point left in jump-history."
  (let ([items (%items 'xref:find-references (%backend-for 'xref:find-references) %backend-references "find references" identifier)])
    (when (null? items)
      (error 'xref:find-references (string-append "No references found for: " identifier)))
    (%show! items (string-append "References of " identifier) (references-display) (auto-jump-to-first-reference?))))

(commands:define-command (find-apropos [pattern (ask:line "Search for symbols matching: ")])
  "Shows the backend's identifiers that match PATTERN, and records the place point left in jump-history."
  (let ([items (%items 'xref:find-apropos (%backend-for 'xref:find-apropos) %backend-apropos "search identifiers" pattern)])
    (when (null? items)
      (error 'xref:find-apropos (string-append "No matches for: " pattern)))
    (%show! items (string-append "Symbols matching " pattern) (references-display) #f)))

(options:define-option prompt-for-identifier (list find-references)
  (lambda (v) (or (boolean? v) (and (list? v) (for-all commands:command? v))))
  "Which commands ask for the identifier when there is one at point: #t for all, #f for none, or a list of commands.")

(keys:bind! keys:global "M-." find-definitions)
(keys:bind! keys:global "C-x 4 ." find-definitions-other-view)
(keys:bind! keys:global "M-?" find-references)
(keys:bind! keys:global "C-M-." find-apropos)
