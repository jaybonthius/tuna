#!tuna
(import (buffers) (document) (views) (ui) (commands) (keys) (editing) (faces) (web) (haml) (browse-url)
        (md4c) (markdown unfinished))

;; This module defines quote and list as kind constructors, so its own
;; code writes symbols and lists with quasiquote and cons.

(define-table table-keymap "Keys in a Markdown table.")

(module %convert (blocks->datums)

  (define (blocks->datums records first)
    (let loop ([records records] [key first] [acc `()])
      (if (null? records)
          (reverse acc)
          (loop (cdr records) (fx+ key 1) (cons (block->datum (car records) key) acc)))))

  (define (block->datum b key)
    (cond
      [(markdown-paragraph? b) (apply paragraph `((key . ,key)) (text-content (markdown-paragraph-inlines b)))]
      [(markdown-heading? b)
       (apply heading `((key . ,key) (level . ,(markdown-heading-level b))) (text-content (markdown-heading-inlines b)))]
      [(markdown-code-block? b)
       (let ([text (markdown-code-block-text b)])
         (apply code-block `((key . ,key) (language . ,(markdown-code-block-language b)))
           (if (string=? text "") `() (cons text `()))))]
      [(markdown-quote? b) (apply quote `((key . ,key)) (blocks->datums (markdown-quote-blocks b) 0))]
      [(markdown-list? b)
       (apply list
         (if (markdown-list-ordered? b)
             `((key . ,key) (ordered . #t) (start . ,(markdown-list-first-number b)) (tight . ,(markdown-list-tight? b)))
             `((key . ,key) (ordered . #f) (tight . ,(markdown-list-tight? b))))
         (blocks->datums (markdown-list-items b) 0))]
      [(markdown-item? b)
       (apply item
         (if (markdown-item-task? b)
             `((key . ,key) (task . ,(if (markdown-item-checked? b) `checked `unchecked)))
             `((key . ,key)))
         (blocks->datums (markdown-item-blocks b) 0))]
      [(markdown-table? b)
       (let ([alignments (markdown-table-alignments b)])
         (apply table `((key . ,key) (columns . ,(length alignments)))
           (table-row-datum (markdown-table-header b) alignments `((key . 0) (header . #t)))
           (let loop ([rows (markdown-table-rows b)] [key 1])
             (if (null? rows)
                 `()
                 (cons (table-row-datum (car rows) alignments `((key . ,key))) (loop (cdr rows) (fx+ key 1)))))))]
      [(markdown-rule? b) (rule `((key . ,key)))]
      [else (assertion-violation `markdown "unknown md4c block" b)]))

  (define (table-row-datum cells alignments attributes)
    (apply table-row attributes
      (let loop ([cells cells] [alignments alignments] [key 0])
        (if (null? cells)
            `()
            (let ([align (and (pair? alignments) (car alignments))])
              (cons (apply table-cell (if align `((key . ,key) (align . ,align)) `((key . ,key))) (text-content (car cells)))
                    (loop (cdr cells) (if (pair? alignments) (cdr alignments) alignments) (fx+ key 1))))))))

  (define (text-content inlines)
    (joined (inlines->datums inlines #f) "\n"))

  (define (inlines->datums inlines in-link?)
    (fold-right (lambda (x acc) (inline->datums x in-link? acc)) `() inlines))

  ;; A link cannot hold another, so a link or image in a link's label is
  ;; its label.
  (define (inline->datums x in-link? acc)
    (cond
      [(markdown-text? x) (cons (markdown-text-string x) acc)]
      [(markdown-line-break? x) (cons (if (markdown-line-break-hard? x) "\n" " ") acc)]
      [(markdown-span? x)
       (cons (apply (case (markdown-span-kind x)
                      [(emphasis) emphasis]
                      [(strong) strong]
                      [(strikethrough) strikethrough]
                      [(code) code]
                      [else (assertion-violation `markdown "unknown md4c span" (markdown-span-kind x))])
               `()
               (joined (inlines->datums (markdown-span-inlines x) in-link?) ""))
             acc)]
      [(markdown-link? x)
       (let ([label (inlines->datums (markdown-link-inlines x) #t)])
         (if in-link?
             (append label acc)
             (cons (apply link `((href . ,(markdown-link-href x))) (joined label "")) acc)))]
      [(markdown-image? x)
       (let ([label (let ([text (markdown-inlines-text (markdown-image-inlines x))])
                      (if (string=? text "") "image" text))])
         (cons (if in-link? label (link `((href . ,(markdown-image-src x))) label)) acc))]
      [else (assertion-violation `markdown "unknown md4c inline" x)]))

  ;; Adjacent strings are one, as a document reads them back, so that an
  ;; unchanged block is equal? to what the buffer holds.
  (define (joined datums end)
    (let loop ([ds datums] [acc `()])
      (cond
        [(null? ds)
         (reverse
           (cond
             [(string=? end "") acc]
             [(and (pair? acc) (string? (car acc))) (cons (string-append (car acc) end) (cdr acc))]
             [else (cons end acc)]))]
        [(not (string? (car ds))) (loop (cdr ds) (cons (car ds) acc))]
        [(string=? (car ds) "") (loop (cdr ds) acc)]
        [(and (pair? acc) (string? (car acc))) (loop (cdr ds) (cons (string-append (car acc) (car ds)) (cdr acc)))]
        [else (loop (cdr ds) (cons (car ds) acc))]))))

(import %convert)

(define (%check-text who text)
  (unless (string? text)
    (assertion-violation who "not a string" text)))

(define (blocks text)
  (%check-text `markdown:blocks text)
  (blocks->datums (markdown-parse text) 0))

(define (unfinished-blocks text)
  (%check-text `markdown:unfinished-blocks text)
  (let ([records (markdown-parse text)])
    (if (null? records)
        `()
        (let* ([n (fx- (length records) 1)] [source (unfinished-source text (list-ref records n))])
          (if source
              (append (blocks->datums (list-head records n) 0) (blocks->datums (markdown-parse source) n))
              (blocks->datums records 0))))))

(define (%wrap kind attribute parent children)
  (case kind
    [(markdown:paragraph) (haml (:div.markdown-paragraph children))]
    [(markdown:heading)
     (haml (:div.markdown-heading ([role "heading"] [aria-level (attribute `level)]) children))]
    [(markdown:code-block)
     (let ([language (attribute `language)])
       (haml (:div.markdown-code-block ([data-language (and language (not (string=? language "")) language)]
                                        [data-face (symbol->string faces:markup.raw)])
               children)))]
    [(markdown:quote) (haml (:blockquote.markdown-quote children))]
    [(markdown:list) (haml (:div.markdown-list ([role "list"] [data-tight (attribute `tight)]) children))]
    [(markdown:item) (haml (:div.markdown-item ([role "listitem"]) (%item-marker attribute parent) children))]
    [(markdown:table)
     (haml (:div.markdown-table ([role "table"] [style "--markdown-table-columns:" (attribute `columns)]) children))]
    [(markdown:table-row) (haml (:div.markdown-table-row ([role "row"] [data-header (attribute `header)]) children))]
    [(markdown:table-cell)
     (let ([align (attribute `align)])
       (haml (:div.markdown-table-cell ([role (if (parent `header) "columnheader" "cell")]
                                        [data-align (and align (symbol->string align))])
               children)))]
    [(markdown:rule) (haml (:hr.markdown-rule))]
    [(markdown:strong) (haml (:strong.markdown-strong children))]
    [(markdown:emphasis) (haml (:em.markdown-emphasis children))]
    [(markdown:strikethrough) (haml (:del.markdown-strikethrough children))]
    [(markdown:code) (haml (:code.markdown-code ([data-face (symbol->string faces:markup.raw)]) children))]
    [(markdown:link) (haml (:span.markdown-link children))]))

(define (%item-marker attribute parent)
  (let ([task (attribute `task)])
    (if task
        (haml (:input.markdown-item-box ([type "checkbox"] [tabindex "-1"] [disabled] [checked (eq? task `checked)])))
        (haml (:span.markdown-item-marker
                (if (parent `ordered)
                    (string-append (number->string (+ (parent `start) (attribute `key))) ".")
                    "•"))))))

(define (%draw node view)
  (let ([doc (buffers:document (views:buffer view))])
    (%wrap (document:node-kind node)
      (lambda (name) (document:node-attribute node name #f))
      (lambda (name)
        (let ([holder (document:enclosing doc (document:node-start node))])
          (and holder (document:node-attribute holder name #f))))
      (if (document:atom? node) `() (views:draw-children view node)))))

(define (%datums->html datums parent)
  (map (lambda (d)
         (cond
           [(string? d) d]
           [(vector? d) (%wrap (vector-ref d 0) (%alist-attribute (vector-ref d 1)) parent `())]
           [else
            (let ([attribute (%alist-attribute (cadr d))])
              (%wrap (car d) attribute parent (%datums->html (cddr d) attribute)))]))
       datums))

(define (%alist-attribute attributes)
  (lambda (name) (let ([a (assq name attributes)]) (and a (cdr a)))))

(define (html text)
  (%check-text `markdown:html text)
  (haml (:div.markdown (%datums->html (blocks text) (lambda (name) #f)))))

(commands:define-command (follow-link [link (ui:pushed-button)])
  "Opens the address of the link pushed in a new tab of the browser whose click or key ran the command."
  (unless (and (document:node? link) (eq? (document:node-kind link) `markdown:link))
    (assertion-violation `markdown:follow-link "not a Markdown link" link))
  (browse-url:open (document:node-attribute link `href) (web:current-client)))

(buffers:define-kind paragraph (draw %draw))
(buffers:define-kind heading (draw %draw))
(buffers:define-kind code-block (draw %draw))
(buffers:define-kind quote (content nodes) (draw %draw))
(buffers:define-kind list (content nodes) (draw %draw))
(buffers:define-kind item (content nodes) (draw %draw))
(buffers:define-kind table (content nodes) (whole) (keymap table-keymap) (draw %draw))
(buffers:define-kind table-row (content nodes) (draw %draw))
(buffers:define-kind table-cell (isolating) (draw %draw))
(buffers:define-kind rule (content atom) (draw %draw))
(buffers:define-kind strong (inline) (draw %draw))
(buffers:define-kind emphasis (inline) (draw %draw))
(buffers:define-kind strikethrough (inline) (draw %draw))
(buffers:define-kind code (inline) (draw %draw))
(ui:define-link link follow-link)

(define (%children doc node)
  (let ([acc `()])
    (document:for-each-child node (document:node-start node) (document:node-end node)
      (lambda (child at) (when (document:node? child) (set! acc (cons child acc)))))
    (reverse acc)))

(define (%number-of node nodes)
  (let loop ([nodes nodes] [k 1])
    (if (fx= (document:node-start (car nodes)) (document:node-start node)) k (loop (cdr nodes) (fx+ k 1)))))

(define (%holder doc node) (document:enclosing doc (document:node-start node)))

(define (describe-cell cell view)
  (unless (and (document:node? cell) (eq? (document:node-kind cell) `markdown:table-cell))
    (assertion-violation `markdown:describe-cell "not a Markdown table cell" cell))
  (unless (and (views:view? view) (views:buffer view))
    (assertion-violation `markdown:describe-cell "not a view showing a buffer" view))
  (let* ([doc (buffers:document (views:buffer view))] [row (%holder doc cell)] [table (%holder doc row)]
         [column (%number-of cell (%children doc row))])
    (if (document:node-attribute row `header #f)
        (format "header, column ~a" column)
        (format "row ~a, column ~a" (fx- (%number-of row (%children doc table)) 1) column))))

(define (%cell-at doc p)
  (let loop ([n (document:enclosing doc p)])
    (cond
      [(not n) #f]
      [(eq? (document:node-kind n) `markdown:table-cell) n]
      [else (loop (%holder doc n))])))

(define (%row-line doc cell n)
  (let* ([row (%holder doc cell)] [table (%holder doc row)] [rows (%children doc table)]
         [r (+ (fx- (%number-of row rows) 1) n)])
    (cond
      [(< r 0) (+ (document:line doc (document:node-start table)) r)]
      [(>= r (length rows)) (+ (document:line doc (fx- (document:node-end table) 1)) (- r (length rows)))]
      [else
       (let* ([target (list-ref rows r)] [cells (%children doc target)])
         (document:line doc
           (document:node-start
             (if (null? cells)
                 target
                 (list-ref cells (fxmin (fx- (%number-of cell (%children doc row)) 1) (fx- (length cells) 1)))))))])))

(define (%check-count who n)
  (unless (and (integer? n) (exact? n))
    (assertion-violation who "not an exact integer" n)))

(define (%move-rows who n)
  (let ([view (views:current)])
    (unless (and view (views:buffer view))
      (assertion-violation who "no view showing a buffer is current"))
    (editing:move-cursors! who view n
      (lambda (c doc lo hi)
        (let* ([p (views:cursor-point c)] [cell (%cell-at doc p)])
          ((editing:line-motion-target (if cell (- (%row-line doc cell n) (document:line doc p)) n)) c doc lo hi))))))

(commands:define-command (next-row [n (commands:prefix-number)])
  "Moves each cursor in a Markdown table cell to the cell in its column N rows down, or past the last row to the lines after the table, and each other cursor N lines down, as next-line does."
  (%check-count `markdown:next-row n)
  (%move-rows `markdown:next-row n))

(commands:define-command (previous-row [n (commands:prefix-number)])
  "Moves each cursor in a Markdown table cell to the cell in its column N rows up, or past the header to the lines before the table, and each other cursor N lines up, as previous-line does."
  (%check-count `markdown:previous-row n)
  (%move-rows `markdown:previous-row (- n)))

(keys:remap! table-keymap editing:next-line next-row)
(keys:remap! table-keymap editing:previous-line previous-row)
(table-set! views:position-describers code-block views:describe-line)
(table-set! views:position-describers table-cell describe-cell)
(table-set! web:stylesheets `markdown "markdown/markdown.css")
