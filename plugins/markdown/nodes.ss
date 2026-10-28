;;; Markdown as buffer nodes: gerbil-md4c's blocks turned into the markdown
;;; plugin's node kinds (plugin.ss draws them). Paragraphs, headings and
;;; code hold a text node with the visible text, its inline styles as
;;; highlight spans in the layer `markdown`; a block with links ends with
;;; a `markdown-links` node, whose links open in a new browser tab. Lists,
;;; items and quotes hold their blocks; a table is one node.
prelude: :gerbil/core

(import :gerbil-md4c/md4c
        :tuna/plugins/buffers/contract
        "faces")
(export markdown-block-nodes
        update-markdown-block-nodes)

;;; Inline content

;; The visible text of INLINES, the styled ranges in it and its links
;; ((LABEL . HREF), in order), as three values. Soft line breaks are
;; spaces, so a paragraph wraps as one line; hard ones are newlines.
(def (inline-content (inlines : :list))
  (let ((ranges [])
        (links [])
        (position 0)
        (port (open-output-string)))
    (def (emit! (s : :string)) => :void
      (write-string s port)
      (set! position (fx+ position (string-length s))))
    (def (styled! (start : :fixnum) (part : :symbol)) => :void
      (when (fx< start position)
        (set! ranges (cons (make-styled start position part) ranges))))
    (def (walk (inlines : :list)) => :void
      (for-each
       (lambda (inline)
         (cond
          ((markdown-text? inline) (emit! (markdown-text-string inline)))
          ((markdown-line-break? inline) (emit! (if (markdown-line-break-hard? inline) "\n" " ")))
          ((markdown-span? inline)
           (let (start position)
             (walk (markdown-span-inlines inline))
             (styled! start (markdown-span-kind inline))))
          ((markdown-link? inline)
           (let (start position)
             (walk (markdown-link-inlines inline))
             (styled! start 'link)
             (set! links (cons (cons (markdown-inlines-text (markdown-link-inlines inline)) (markdown-link-href inline))
                               links))))
          ((markdown-image? inline)
           (let ((start position)
                 (description (markdown-inlines-text (markdown-image-inlines inline))))
             (emit! (if (string-empty? description) "image" description))
             (styled! start 'link)
             (set! links (cons (cons (string-append "image: " description) (markdown-image-src inline)) links))))))
       inlines))
    (walk inlines)
    (values (get-output-string port) (reverse ranges) (reverse links))))

;; The children of a block holding INLINES: a text node, styled, and a
;; links node when there are links.
(def (inline-children (inlines : :list)) => :list
  (let-values (((string ranges links) (inline-content inlines)))
    (let (t (new-text string))
      (set-highlights! t 'markdown (styled-spans ranges 1))
      (cons (new-text-node t)
            (if (null? links)
              []
              [(new-node 'markdown-links attributes: [(cons 'links links)])])))))

;; INLINES as SXML, for a table cell.
(def (inlines-sxml (inlines : :list)) => :list
  (append-map-list
   (lambda (inline)
     (cond
      ((markdown-text? inline) [(markdown-text-string inline)])
      ((markdown-line-break? inline) (if (markdown-line-break-hard? inline) ['(br)] [" "]))
      ((markdown-span? inline)
       [(cons (case (markdown-span-kind inline)
                ((strong) 'strong) ((emphasis) 'em) ((strikethrough) 'del) (else 'code))
              (inlines-sxml (markdown-span-inlines inline)))])
      ((markdown-link? inline)
       [`(a (@ (href ,(markdown-link-href inline)) (target "_blank") (rel "noopener noreferrer") (tabindex "-1"))
            ,@(inlines-sxml (markdown-link-inlines inline)))])
      ((markdown-image? inline) (inlines-sxml (markdown-image-inlines inline)))
      (else [])))
   inlines))

(def (append-map-list (f : :procedure) (l : :list)) => :list
  (apply append (map f l)))

;;; Blocks

;; The marker drawn before the INDEX-th item (from 0) of LIST.
(def (item-marker (list : markdown-list) (index : :fixnum)) => :string
  (if (markdown-list-ordered? list)
    (string-append (number->string (+ (markdown-list-first-number list) index)) ".")
    "•"))

;; BLOCK as a node, with ATTRIBUTES besides its own.
(def (block-node (block : markdown-block) (attributes : :list)) => node
  (cond
   ((markdown-paragraph? block)
    (new-node 'markdown-paragraph attributes: attributes
              children: (inline-children (markdown-paragraph-inlines block))))
   ((markdown-heading? block)
    (new-node 'markdown-heading attributes: (cons (cons 'level (markdown-heading-level block)) attributes)
              children: (inline-children (markdown-heading-inlines block))))
   ((markdown-code-block? block)
    (let (code (markdown-code-block-text block))
      (new-node 'markdown-code attributes: (cons (cons 'language (markdown-code-block-language block)) attributes)
                children: [(new-text-node (new-text (if (string-suffix? "\n" code)
                                                      (substring code 0 (fx1- (string-length code)))
                                                      code)))])))
   ((markdown-quote? block)
    (new-node 'markdown-quote attributes: attributes
              children: (map (cut block-node <> []) (markdown-quote-blocks block))))
   ((markdown-list? block)
    (new-node 'markdown-list
              attributes: (cons* (cons 'ordered (markdown-list-ordered? block))
                                 (cons 'tight (markdown-list-tight? block))
                                 attributes)
              children: (let lp ((items (markdown-list-items block)) (index 0) (out []))
                          (match items
                            ([] (reverse out))
                            ([item . more]
                             (lp more (fx1+ index)
                                 (cons (new-node 'markdown-item
                                                 attributes: [(cons 'marker (item-marker block index))
                                                              (cons 'task (markdown-item-task? item))
                                                              (cons 'checked (markdown-item-checked? item))]
                                                 children: (map (cut block-node <> []) (markdown-item-blocks item)))
                                       out)))))))
   ((markdown-table? block)
    (let ((header (markdown-table-header block))
          (rows (markdown-table-rows block)))
      (new-node 'markdown-table
                attributes: (cons* (cons 'alignments (markdown-table-alignments block))
                                   (cons 'header (map inlines-sxml header))
                                   (cons 'rows (map (cut map inlines-sxml <>) rows))
                                   ;; Its text: a row a line, cells apart by tabs.
                                   (cons 'text (string-join (map (lambda ((row : :list))
                                                                   (string-join (map markdown-inlines-text row) "\t"))
                                                                 (cons header rows))
                                                            "\n"))
                                   attributes))))
   (else (new-node 'markdown-rule attributes: attributes))))

;; The Markdown of BLOCK in SOURCE.
(def (block-markdown (source : :string) (block : markdown-block)) => :string
  (substring source (markdown-block-start block) (markdown-block-end block)))

;; SOURCE's blocks as new nodes, each with its key and Markdown.
(def (markdown-block-nodes (source : :string)) => :list
  (update-markdown-block-nodes [] source))

;; SOURCE's blocks as nodes, taking from OLD each node whose key and
;; Markdown are its block's (contract: markdown-update-blocks).
(def (update-markdown-block-nodes (old : :list) (source : :string)) => :list
  (let (old (list->vector old))
    (let lp ((blocks (markdown-parse source)) (key 0) (out []))
      (match blocks
        ([] (reverse out))
        ([block . more]
         (let* ((markdown (block-markdown source block))
                (kept (and (fx< key (vector-length old))
                           (let (n (vector-ref old key))
                             (and (eqv? (node-attribute n 'key) key)
                                  (equal? (node-attribute n 'markdown) markdown)
                                  n)))))
           (lp more (fx1+ key)
               (cons (or kept (block-node block [(cons 'key key) (cons 'markdown markdown)])) out))))))))
