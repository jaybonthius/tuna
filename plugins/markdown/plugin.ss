#lang :tuna/prelude
;;; Markdown (live tier; Emacs markdown-mode and shr, for a chat): provides
;;; the markdown service (contract.ss). It defines and draws the Markdown
;;; node kinds nodes.ss makes, in a proportional font with code
;;; monospace, styled by tokens.css and rules.css; and it styles texts
;;; handed to markdown-style-text! again after every change to them.
;;; Markdown is parsed by md4c, through gerbil-md4c.

(import :std/interface
        (only-in :gerbil/runtime/hash HashTable)
        :tuna/kernel
        :tuna/plugins/stylesheets/contract
        :tuna/plugins/buffers/contract
        :tuna/plugins/markdown/contract
        "nodes"
        "style")
(export markdown)

;; STYLED: the texts styled after each change, as keys; weak, so a text
;; nobody holds is not kept for it.
(defclass markdown-provider ((styled : HashTable)) final: #t)

(def (restyle! (t : text)) => :void
  (set-highlights! t 'markdown (markdown-style-spans (text-string t))))

(implement Markdown markdown-provider
  (blocks (lambda (self source) (markdown-block-nodes source)))
  (update-blocks (lambda (self nodes source) (update-markdown-block-nodes nodes source)))
  (style-text! (lambda (self t)
                 (hash-put! self.styled t #t)
                 (restyle! t))))

;; The `<a>` of a link (LABEL . HREF), opening in a new browser tab; its
;; address shows when hovered.
(def (link-element (link : :pair)) => :list
  `(a (@ (class "markdown-link") (href ,(cdr link)) (title ,(cdr link))
         (target "_blank") (rel "noopener noreferrer") (tabindex "-1"))
      ,(if (string-empty? (car link)) (cdr link) (car link))))

(def (alignment-attributes (alignment :? :symbol)) => :list
  (if alignment [['data-align (symbol->string alignment)]] []))

(def (render-table (n : node)) => :list
  (let (alignments (node-attribute n 'alignments))
    (def (cells (tag : :symbol) (row : :list)) => :list
      (let lp ((row row) (alignments alignments) (out []))
        (match row
          ([] (reverse out))
          ([cell . more]
           (lp more (if (pair? alignments) (cdr alignments) [])
               (cons `(,tag (@ ,@(alignment-attributes (and (pair? alignments) (car alignments))))
                            ,@cell)
                     out))))))
    `(div (@ (class "markdown-table"))
          (table (thead (tr ,@(cells 'th (node-attribute n 'header))))
                 (tbody ,@(map (lambda ((row : :list)) `(tr ,@(cells 'td row)))
                               (node-attribute n 'rows)))))))

(defplugin (markdown ctx)
  "Markdown drawn as buffer nodes, and Markdown being typed styled in place."
  provides: [markdown-service]
  requires: [buffers-service]
  (add-stylesheet 'tokens "tokens.css")
  (add-stylesheet 'rules "rules.css")
  (context-define-node-kind! ctx 'markdown-paragraph doc: "A Markdown paragraph: its text, then its links."
                             items: 'children)
  (context-define-node-kind! ctx 'markdown-heading doc: "A Markdown heading of level 1 to 6 (`level`)."
                             items: 'children)
  (context-define-node-kind! ctx 'markdown-code doc: "A Markdown code block in `language`, a text."
                             items: 'children)
  (context-define-node-kind! ctx 'markdown-quote doc: "A Markdown block quote, holding blocks."
                             items: 'children)
  (context-define-node-kind! ctx 'markdown-list doc: "A Markdown list (`ordered`, `tight`), holding items."
                             items: 'children)
  (context-define-node-kind! ctx 'markdown-item doc: "A Markdown list item, with its `marker`, holding blocks."
                             items: 'children
                             project: (lambda (n)
                                        (string-append (if (node-attribute n 'task)
                                                         (if (node-attribute n 'checked) "[x]" "[ ]")
                                                         (node-attribute n 'marker))
                                                       " "
                                                       (string-join (map node-text-projection (node-children n)) "\n"))))
  (context-define-node-kind! ctx 'markdown-table doc: "A Markdown table, one item."
                             items: 'whole project: (lambda (n) (node-attribute n 'text)))
  (context-define-node-kind! ctx 'markdown-rule doc: "A Markdown thematic break." items: 'whole
                             project: (lambda (n) ""))
  (context-define-node-kind! ctx 'markdown-links doc: "The links of a Markdown block, opening in a new tab."
                             items: 'whole
                             project: (lambda (n) (string-join (map cdr (node-attribute n 'links)) "\n")))
  (context-define-node-renderer! ctx 'markdown-paragraph
                                 (lambda (n children) `(div (@ (class "markdown-paragraph")) ,@children)))
  (context-define-node-renderer! ctx 'markdown-heading
                                 (lambda (n children)
                                   (let (level (number->string (node-attribute n 'level)))
                                     `(div (@ (class "markdown-heading") (role "heading") (aria-level ,level)
                                              (data-level ,level))
                                           ,@children))))
  (context-define-node-renderer! ctx 'markdown-code
                                 (lambda (n children)
                                   (let (language (node-attribute n 'language))
                                     `(div (@ (class "markdown-code"))
                                           ,@(if (string-empty? language)
                                               []
                                               [`(span (@ (class "markdown-code-language") (aria-hidden "true"))
                                                       ,language)])
                                           ,@children))))
  (context-define-node-renderer! ctx 'markdown-quote
                                 (lambda (n children) `(blockquote (@ (class "markdown-quote")) ,@children)))
  (context-define-node-renderer! ctx 'markdown-list
                                 (lambda (n children)
                                   `(,(if (node-attribute n 'ordered) 'ol 'ul)
                                     (@ (class "markdown-list") ,@(if (node-attribute n 'tight) '((data-tight "")) '()))
                                     ,@children)))
  (context-define-node-renderer! ctx 'markdown-item
                                 (lambda (n children)
                                   `(li (@ (class "markdown-item"))
                                        ,(if (node-attribute n 'task)
                                           `(input (@ (class "markdown-task") (type "checkbox") (disabled "")
                                                      (tabindex "-1")
                                                      ,@(if (node-attribute n 'checked) '((checked "")) '())))
                                           `(span (@ (class "markdown-marker") (aria-hidden "true"))
                                                  ,(node-attribute n 'marker)))
                                        ,@children)))
  (context-define-node-renderer! ctx 'markdown-table (lambda (n children) (render-table n)))
  (context-define-node-renderer! ctx 'markdown-rule (lambda (n children) '(hr (@ (class "markdown-rule")))))
  (context-define-node-renderer! ctx 'markdown-links
                                 (lambda (n children)
                                   `(p (@ (class "markdown-links"))
                                       ,@(map link-element (node-attribute n 'links)))))
  (using (self (markdown-provider styled: (make-hash-table test: eq? weak-keys: #t)) : markdown-provider)
    (context-add-hook! ctx after-change-hook 'markdown
                       (lambda ((t : text) (c : change))
                         (when (hash-get self.styled t)
                           (restyle! t))))
    (context-provide! ctx markdown-service (Markdown self))))
