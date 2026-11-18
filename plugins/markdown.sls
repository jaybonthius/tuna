#!tuna
(import (buffers) (document) (views) (ui) (commands) (faces) (web) (haml) (browse-url)
        (md4c) (markdown unfinished))

;; This module defines quote and list as kind constructors, so its own
;; code writes symbols and lists with quasiquote and cons.

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
  (browse-url:open (document:node-attribute link `href)))

;; Where a deeper block meets a shallower one after it, the place's stop
;; is its deepest position that consents to typing. Refusing the position
;; after a text block's last newline moves that stop to the next block's
;; first character, so line motion from a line's start reaches the block.
(define (%not-after-last-newline node edit)
  (let ([start (document:node-start node)] [end (document:node-end node)])
    (not (and (fx= (buffers:edit-start edit) (fx- end 1))
              (fx> (fx- end start) 2)))))

(buffers:define-kind paragraph (consent %not-after-last-newline) (draw %draw))
(buffers:define-kind heading (consent %not-after-last-newline) (draw %draw))
(buffers:define-kind code-block (consent %not-after-last-newline) (draw %draw))
(buffers:define-kind quote (content nodes) (draw %draw))
(buffers:define-kind list (content nodes) (draw %draw))
(buffers:define-kind item (content nodes) (draw %draw))
(buffers:define-kind table (content nodes) (whole) (draw %draw))
(buffers:define-kind table-row (content nodes) (draw %draw))
(buffers:define-kind table-cell (consent %not-after-last-newline) (draw %draw))
(buffers:define-kind rule (content atom) (draw %draw))
(buffers:define-kind strong (inline) (draw %draw))
(buffers:define-kind emphasis (inline) (draw %draw))
(buffers:define-kind strikethrough (inline) (draw %draw))
(buffers:define-kind code (inline) (draw %draw))
(ui:define-link link follow-link)

(table-set! web:stylesheets `markdown "markdown/markdown.css")
